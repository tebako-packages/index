#!/usr/bin/env ruby
# frozen_string_literal: true

# intake_review.rb — the community feedstock lane's review engine
# (tebako-packages/index#23 — the commons' publish half).
#
#   ruby tools/intake_review.rb --base CATALOG.yaml --head CATALOG.yaml \
#                               [--report verdict.md] [--allow-file-refs]
#
# A community submission is a pull request that ADDS (or re-points) a
# `packages:` row in this repo's tpkg-registry.yaml — the row names a
# feedstock whose own tpkg-registry.yaml carries the payload rows. This
# tool diffs base..head, and for every submitted row gates, fail closed
# with a named error per check:
#
#   CatalogParse      the base or head catalog is not parseable YAML
#   CatalogSchema     a catalog row breaks the packages: grammar
#   RowRemoval        the PR deletes a catalog row — removal is a
#                     governance act (docs/governance.md), never intake
#   DuplicateName     a new row re-uses a name the base catalog carries
#   NoSubmission      the catalog changed but no row was added/changed
#   RegistryFetch     the referenced feedstock registry did not download
#   RegistrySchema    the feedstock registry breaks the spec 04 §2 grammar
#                     (schemas/tpkg-registry.yaml in tamatebako/tebako)
#   PayloadMissing    the registry carries no payload row under the
#                     catalog row's name
#   VersionRemoved    an update drops a version the base registry carries
#                     (yanking is `status: withdrawn` via governance)
#   VersionRegression an update's newest version sorts older than base's
#   UnsupportedRef    a reference form this lane does not speak (only
#                     `tfs:github:org/repo` catalog refs, `tfs:github:
#                     org/repo:tag` release refs, same-release asc names)
#   RefInsecure       a non-https URL where the lane fetches
#   ArtifactUnreachable  HEAD on the artifact URL is not 2xx
#   ArtifactTooLarge  the artifact exceeds the lane's size cap
#   Sha256Mismatch    the artifact's hash disagrees with the row's pin
#   UnsignedSubmission  a version row carries no signature: block (the
#                     curated commons requires signed payloads — unsigned
#                     stays first-class ONLY in self-hosted registries)
#   SignatureFetch    the asc asset did not download
#   KeyFetch          the OpenPGP public key did not download/parse
#   KeyIdentity       the served key is not the declared one (for the
#                     tamatebako root: not the published fingerprint)
#   SignatureInvalid  the detached signature does not verify
#   SignatureKeyMismatch  the signing key's primary is not the pinned
#                     keyid (the pin names the PRIMARY; subkeys rotate)
#
# Every version row of the submitted payload is probed: artifact HEAD 200,
# GET + sha256 against the row's pin, and the detached signature verified
# against the tamatebako root public key — or the submission's declared
# community key (`key_url:` on the catalog row). Rows a feedstock has
# marked `status: withdrawn` are reported, not probed (governance flows
# them verbatim; readers ignoring the field is the schema's evolution
# law, so the marker is never a parse failure).
#
# The verdict is a markdown report (stdout, and --report for the workflow's
# PR comment). Exit 0 = every gate green; 1 = at least one named failure;
# 2 = the tool itself could not run (bad arguments, unreadable input).
#
# --allow-file-refs admits file:// registry/artifact/key references and
# exists ONLY for the hermetic self-test fixtures (the workflow's
# selftest leg); a real submission carrying file:// refs fails
# UnsupportedRef, as designed.
#
# Ruby stdlib + the runner's gpg (OpenPGP verification; the same
# verification tebako-pkg performs at install — rnp/OpenPGP interop is
# exercised by every org feedstock's signed release).

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "optparse"
require "tmpdir"
require "uri"
require "yaml"

# The tamatebako root of trust (spec 09 §2). SSOT: the trust-anchor page
# on tebako.org (/.well-known/tebako-key.asc served from the same site);
# this constant plays the same role as the loader's
# EMBEDDED_ROOT_FINGERPRINT — the CI-side copy of the one trust decision.
ROOT_KEY_URL = "https://www.tebako.org/.well-known/tebako-key.asc"
ROOT_FINGERPRINT = "9E210CA8E9FDE9E6587740B2EFC3C250F7862A48"
ROOT_KEYID = ROOT_FINGERPRINT[-16, 16].downcase # "efc3c250f7862a48"

KINDS = %w[app data toolkit runtime language].freeze
NAME_GRAMMAR = /\A[A-Za-z0-9](?:[A-Za-z0-9_-]|\.(?=[A-Za-z0-9])){0,127}\z/
REPO_SEGMENT = "[A-Za-z0-9_.-]+"
REPO_GRAMMAR = /\A#{REPO_SEGMENT}\/#{REPO_SEGMENT}\z/o
KEYID_GRAMMAR = /\A[0-9a-f]{16}\z/
SHA256_GRAMMAR = /\A[0-9a-f]{64}\z/
GITHUB_REGISTRY = /\Atfs:github:(#{REPO_SEGMENT}\/#{REPO_SEGMENT})\z/o
GITHUB_RELEASE = /\Atfs:github:(#{REPO_SEGMENT}\/#{REPO_SEGMENT}):([^#]+)\z/o

MAX_ARTIFACT_BYTES = 4 * 1024 * 1024 * 1024 # 4 GiB — absurdity cap, not a budget
MAX_REDIRECTS = 5
OPEN_TIMEOUT = 30
READ_TIMEOUT = 120

# One gate's outcome. `code` is the named error (nil on pass); the report
# prints it verbatim so a contributor can act without log archaeology.
Check = Struct.new(:ok, :code, :message) do
  def line
    ok ? "✓ #{message}" : "✗ **#{code}** — #{message}"
  end
end

class LaneError < StandardError
  attr_reader :code

  def initialize(code, message)
    @code = code
    super(message)
  end
end

# ---------------------------------------------------------------- http ---

def https_uri!(url)
  uri = URI.parse(url)
  raise LaneError.new("RefInsecure", "#{url} is not https://") unless uri.is_a?(URI::HTTPS)

  uri
rescue URI::InvalidURIError
  raise LaneError.new("RefInsecure", "#{url} is not a parseable URL")
end

# GET url (https, ≤ MAX_REDIRECTS redirects), returning the body. The
# org's rate-budget convention: GITHUB_TOKEN rides GitHub hosts when
# present (aggregate.rb sets the precedent). 5xx and connection flakes
# retry with backoff — a CDN edge timeout is transient, never a verdict
# (the probe-registry-row action's `curl --retry 4 --retry-all-errors`
# sets the org precedent).
RETRIES = 4
RETRY_DELAY = 5

class TransientFetch < StandardError; end

def github_auth(req, uri)
  token = ENV["GITHUB_TOKEN"]
  if token && !token.empty? && uri.host.end_with?("github.com", "githubusercontent.com")
    req["Authorization"] = "Bearer #{token}"
  end
end

# GET url (https, ≤ MAX_REDIRECTS redirects). Returns the body; with
# `to:` it streams to that path (artifacts never sit in memory) and
# returns the path.
def http_get(url, to: nil, limit: MAX_REDIRECTS)
  raise LaneError.new("RegistryFetch", "redirect limit exceeded at #{url}") if limit.negative?

  attempt = 0
  begin
    uri = https_uri!(url)
    body = nil
    Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                    open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      req = Net::HTTP::Get.new(uri)
      github_auth(req, uri)
      http.request(req) do |res|
        case res
        when Net::HTTPRedirection
          return http_get(res["location"], to: to, limit: limit - 1)
        when Net::HTTPSuccess
          total = 0
          sink = to ? File.open(to, "wb") : nil
          buf = +""
          begin
            res.read_body do |chunk|
              total += chunk.bytesize
              if total > MAX_ARTIFACT_BYTES
                raise LaneError.new("ArtifactTooLarge",
                                    "#{url} exceeds #{MAX_ARTIFACT_BYTES} bytes")
              end
              sink ? sink.write(chunk) : buf << chunk
            end
          ensure
            sink&.close
          end
          body = to ? to : buf
        when Net::HTTPServerError
          raise TransientFetch, "HTTP #{res.code}"
        else
          raise LaneError.new("RegistryFetch", "GET #{url} → HTTP #{res.code}")
        end
      end
    end
    body
  rescue TransientFetch, Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
    if (attempt += 1) <= RETRIES
      sleep RETRY_DELAY
      retry
    end

    raise LaneError.new("RegistryFetch", "GET #{url} failed after #{RETRIES} retries: #{e.message}")
  end
end

# HEAD url, expecting 2xx. A 405/403 answers "HEAD unsupported" — the GET
# that follows is the reachability proof, so those pass through. 5xx and
# connection flakes retry like http_get (transient, never a verdict).
def head_reachable!(url, code, limit: MAX_REDIRECTS)
  raise LaneError.new(code, "redirect limit exceeded at #{url}") if limit.negative?

  attempt = 0
  begin
    uri = https_uri!(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                    open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      req = Net::HTTP::Head.new(uri)
      github_auth(req, uri)
      res = http.request(req)
      case res
      when Net::HTTPRedirection
        return head_reachable!(res["location"], code, limit: limit - 1)
      when Net::HTTPSuccess
        return
      when Net::HTTPMethodNotAllowed, Net::HTTPForbidden
        return # HEAD unsupported — the GET below decides
      when Net::HTTPServerError
        raise TransientFetch, "HTTP #{res.code}"
      else
        raise LaneError.new(code, "HEAD #{url} → HTTP #{res.code}")
      end
    end
  rescue TransientFetch, Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
    if (attempt += 1) <= RETRIES
      sleep RETRY_DELAY
      retry
    end

    raise LaneError.new(code, "HEAD #{url} failed after #{RETRIES} retries: #{e.message}")
  end
end

# ------------------------------------------------------------ grammars ---

def load_yaml_file(path, code)
  YAML.safe_load(File.read(path))
rescue Psych::Exception => e
  raise LaneError.new(code, "#{path}: #{e.message}")
rescue Errno::ENOENT
  raise LaneError.new(code, "#{path}: no such file")
end

def check_catalog(doc, label, allow_file_refs = false)
  checks = []
  unless doc.is_a?(Hash) && doc["schema_version"] == 1
    raise LaneError.new("CatalogSchema",
                        "#{label}: not a schema_version: 1 catalog")
  end
  packages = doc["packages"]
  unless packages.is_a?(Array)
    raise LaneError.new("CatalogSchema", "#{label}: packages: is not a list")
  end

  seen = {}
  packages.each_with_index do |row, i|
    where = "#{label} packages[#{i}]"
    raise LaneError.new("CatalogSchema", "#{where}: not a map") unless row.is_a?(Hash)

    name = row["name"]
    unless name.is_a?(String) && name.match?(NAME_GRAMMAR)
      raise LaneError.new("CatalogSchema",
                          "#{where}: name #{name.inspect} breaks the cache-key grammar")
    end
    if seen[name]
      raise LaneError.new("CatalogSchema", "#{where}: duplicate name #{name}")
    end
    seen[name] = true

    unless KINDS.include?(row["kind"])
      raise LaneError.new("CatalogSchema",
                          "#{where}: kind #{row['kind'].inspect} not one of #{KINDS.join(', ')}")
    end
    registry = row["registry"]
    registry_ok = registry.is_a?(String) &&
                  (registry.match?(GITHUB_REGISTRY) ||
                   (allow_file_refs && registry.start_with?("file://")))
    unless registry_ok
      raise LaneError.new("CatalogSchema",
                          "#{where}: registry #{registry.inspect} is not tfs:github:org/repo")
    end
    key_url = row["key_url"]
    key_ok = key_url.nil? ||
             (key_url.is_a?(String) &&
              (key_url.start_with?("https://") || (allow_file_refs && key_url.start_with?("file://"))))
    unless key_ok
      raise LaneError.new("CatalogSchema",
                          "#{where}: key_url #{key_url.inspect} is not an https:// URL")
    end
    checks << Check.new(true, nil, "#{where}: row grammar")
  end
  [packages, checks]
end

# The spec 04 §2 grammar (schemas/tpkg-registry.yaml in tamatebako/tebako)
# as this lane speaks it. Unknown fields pass — the schema's evolution law
# (readers ignore them; `status: withdrawn` rides that rule).
def validate_registry!(doc, source, allow_file_refs = false)
  unless doc.is_a?(Hash) && doc["schema_version"] == 1
    raise LaneError.new("RegistrySchema",
                        "#{source}: not a schema_version: 1 payload registry")
  end
  payloads = doc["payloads"]
  unless payloads.is_a?(Array)
    raise LaneError.new("RegistrySchema", "#{source}: payloads: is not a list")
  end

  payloads.each do |p|
    where = "#{source} payload #{p.is_a?(Hash) ? p['name'].inspect : '?'}"
    raise LaneError.new("RegistrySchema", "#{where}: not a map") unless p.is_a?(Hash)
    unless p["name"].is_a?(String) && p["name"].match?(NAME_GRAMMAR)
      raise LaneError.new("RegistrySchema", "#{where}: bad name #{p['name'].inspect}")
    end
    unless KINDS.include?(p["kind"])
      raise LaneError.new("RegistrySchema", "#{where}: bad kind #{p['kind'].inspect}")
    end
    versions = p["versions"]
    unless versions.is_a?(Array) && !versions.empty?
      raise LaneError.new("RegistrySchema", "#{where}: versions: is not a non-empty list")
    end
    seen = {}
    versions.each do |v|
      vwhere = "#{where}@#{v.is_a?(Hash) ? v['version'] : '?'}"
      raise LaneError.new("RegistrySchema", "#{vwhere}: not a map") unless v.is_a?(Hash)
      version = v["version"]
      unless version.is_a?(String) && !version.empty?
        raise LaneError.new("RegistrySchema",
                            "#{vwhere}: version must be a (quoted) string, got #{version.inspect}")
      end
      raise LaneError.new("RegistrySchema", "#{vwhere}: duplicate version") if seen[version]

      seen[version] = true

      platforms = v["platforms"]
      if platforms == "universal"
        # the single-.tfs rule (spec 04 §1): the artifact is the release's
        # one .tfs asset; signature.asc names the exact asc.
      elsif platforms.is_a?(Hash) && !platforms.empty?
        platforms.each do |triplet, entry|
          pwhere = "#{vwhere} #{triplet}"
          unless entry.is_a?(Hash) && entry["artifact"].is_a?(String) &&
                 !entry["artifact"].empty? && !entry["artifact"].include?("/") &&
                 entry["sha256"].is_a?(String) && entry["sha256"].match?(SHA256_GRAMMAR)
            raise LaneError.new("RegistrySchema",
                                "#{pwhere}: needs {artifact: <basename>, sha256: <64 lowercase hex>}")
          end
        end
      else
        raise LaneError.new("RegistrySchema",
                            "#{vwhere}: platforms: is neither \"universal\" nor a triplet map")
      end

      ref = v.dig("release", "ref")
      ref_ok = ref.is_a?(String) &&
               (ref.match?(GITHUB_RELEASE) || (allow_file_refs && ref.start_with?("file://")))
      unless ref_ok
        raise LaneError.new("UnsupportedRef",
                            "#{vwhere}: release.ref #{ref.inspect} is not tfs:github:org/repo:tag")
      end

      sig = v["signature"]
      if sig.nil?
        raise LaneError.new("UnsignedSubmission",
                            "#{vwhere}: no signature: block — the curated commons indexes signed payloads only")
      end
      unless sig.is_a?(Hash) && sig["keyid"].is_a?(String) &&
             sig["keyid"].match?(KEYID_GRAMMAR) && sig["asc"].is_a?(String) &&
             !sig["asc"].empty? && !sig["asc"].include?("/")
        raise LaneError.new("RegistrySchema",
                            "#{vwhere}: signature: needs {keyid: <16 lowercase hex>, asc: <asset basename>}")
      end

      rr = v["runtime_requirement"]
      if !rr.nil? && !(rr.is_a?(Hash) && rr["engine"].is_a?(String) && rr["constraint"].is_a?(String))
        raise LaneError.new("RegistrySchema",
                            "#{vwhere}: runtime_requirement: needs {engine, constraint}")
      end

      entrypoints = v["entrypoints"]
      if !entrypoints.nil? && !(entrypoints.is_a?(Array) && entrypoints.all? { |e| e.is_a?(String) })
        raise LaneError.new("RegistrySchema", "#{vwhere}: entrypoints: is not a string list")
      end
    end
    if !p["default"].nil? && !(p["default"].is_a?(String) && seen[p["default"]])
      raise LaneError.new("RegistrySchema",
                          "#{where}: default #{p['default'].inspect} is not one of its versions")
    end
  end
  payloads
end

# Segment-wise version compare: numeric segments compare numerically,
# others lexically; no exceptions, total order. Returns -1/0/1.
def compare_versions(a, b)
  as = a.to_s.split(/[.\-+]/)
  bs = b.to_s.split(/[.\-+]/)
  as.zip(bs) do |x, y|
    return 1 if y.nil?
    return -1 if x.nil?

    xn = x.match?(/\A\d+\z/)
    yn = y.match?(/\A\d+\z/)
    c = if xn && yn
          x.to_i <=> y.to_i
        elsif xn
          1 # numeric outranks a prerelease-ish segment
        elsif yn
          -1
        else
          x <=> y
        end
    return c unless c.zero?
  end
  0
end

# ------------------------------------------------------------- openpgp ---

# Verify `asc` against `artifact` under an ephemeral keyring holding only
# `key_asc`; assert the signing key's PRIMARY carries the pinned keyid.
def verify_signature!(artifact_path, asc_path, key_asc, pinned_keyid, root:)
  Dir.mktmpdir do |gnupg|
    File.chmod(0o700, gnupg)
    key_file = File.join(gnupg, "key.asc")
    File.write(key_file, key_asc)

    out, err, st = Open3.capture3({ "GNUPGHOME" => gnupg },
                                  "gpg", "--batch", "--no-tty", "--import", key_file)
    unless st.success?
      raise LaneError.new("KeyFetch", "gpg cannot import the public key: #{err.strip}")
    end

    list, = Open3.capture2({ "GNUPGHOME" => gnupg },
                           "gpg", "--batch", "--no-tty", "--with-colons", "--list-keys")
    primary = list.lines.find { |l| l.start_with?("fpr:") }&.split(":")&.fetch(9)
    if primary.nil?
      raise LaneError.new("KeyFetch", "no primary fingerprint in the imported key")
    end
    if root && primary != ROOT_FINGERPRINT
      raise LaneError.new("KeyIdentity",
                          "the key served at #{ROOT_KEY_URL} is not the tamatebako root " \
                          "(#{primary}, expected #{ROOT_FINGERPRINT})")
    end
    unless primary[-16, 16].downcase == pinned_keyid
      raise LaneError.new("KeyIdentity",
                          "the served key's primary #{primary[-16, 16].downcase} is not " \
                          "the pinned keyid #{pinned_keyid}")
    end

    status, err, st = Open3.capture3({ "GNUPGHOME" => gnupg },
                                     "gpg", "--batch", "--no-tty", "--status-fd=1",
                                     "--verify", asc_path, artifact_path)
    unless st.success? && status.include?("[GNUPG:] GOODSIG")
      raise LaneError.new("SignatureInvalid",
                          "gpg: #{err.lines.grep(/gpg:/).first&.strip || 'signature does not verify'}")
    end
    validsig = status.lines.find { |l| l.include?("[GNUPG:] VALIDSIG") }
    signing_primary = validsig&.split&.last
    unless signing_primary && signing_primary[-16, 16].downcase == pinned_keyid
      raise LaneError.new("SignatureKeyMismatch",
                          "signed by primary #{signing_primary || 'unknown'}, the row pins #{pinned_keyid}")
    end
    signing_primary
  end
end

# -------------------------------------------------------------- probing ---

def release_base(ref, allow_file_refs)
  if (m = ref.match(GITHUB_RELEASE))
    repo, tag = m[1], m[2]
    return [repo, tag, "https://github.com/#{repo}/releases/download/#{tag}"]
  end
  if allow_file_refs && ref.start_with?("file://")
    return [nil, nil, ref]
  end

  raise LaneError.new("UnsupportedRef",
                      "release.ref #{ref.inspect} is not tfs:github:org/repo:tag")
end

# universal payloads: the single-.tfs rule resolves against the release's
# asset list (spec 04 §1 — exactly one .tfs asset).
def universal_artifact(ref, allow_file_refs)
  repo, tag, = release_base(ref, allow_file_refs)
  if repo.nil? # file:// fixture release: the directory's one .tfs entry
    dir = URI.parse(ref).path
    tfs = Dir.children(dir).select { |n| n.end_with?(".tfs") }
    unless tfs.length == 1
      raise LaneError.new("RegistrySchema",
                          "#{ref}: the single-.tfs rule needs exactly one .tfs entry, found #{tfs.length}")
    end
    return tfs.first
  end

  api = "https://api.github.com/repos/#{repo}/releases/tags/#{tag}"
  assets = JSON.parse(http_get(api))["assets"]
  raise LaneError.new("RegistryFetch", "#{api}: no asset list") unless assets.is_a?(Array)

  tfs = assets.select { |a| a["name"].end_with?(".tfs") }.map { |a| a["name"] }
  unless tfs.length == 1
    raise LaneError.new("RegistrySchema",
                        "#{repo}@#{tag}: the single-.tfs rule needs exactly one .tfs asset, found #{tfs.length}")
  end
  tfs.first
rescue JSON::ParserError
  raise LaneError.new("RegistryFetch", "#{api}: unparseable release payload")
end

# Probe one (version × artifact): reachability, sha256 pin, signature.
def probe_artifact!(checks, base_url, artifact, pinned_sha, sig, key_asc, root_key)
  url = "#{base_url}/#{artifact}"
  Dir.mktmpdir do |work|
    artifact_path = File.join(work, artifact)
    if base_url.start_with?("file://")
      source = File.join(URI.parse(base_url).path, artifact)
      unless File.file?(source)
        raise LaneError.new("ArtifactUnreachable", "#{url}: no such file")
      end
      checks << Check.new(true, nil, "reachable: #{artifact}")
      FileUtils.cp(source, artifact_path)
    else
      head_reachable!(url, "ArtifactUnreachable")
      checks << Check.new(true, nil, "reachable: #{artifact}")
      http_get(url, to: artifact_path)
    end

    actual = Digest::SHA256.file(artifact_path).hexdigest
    unless actual == pinned_sha
      raise LaneError.new("Sha256Mismatch",
                          "#{artifact}: row pins #{pinned_sha}, the artifact hashes #{actual}")
    end
    checks << Check.new(true, nil, "sha256: #{artifact} matches the pin")

    asc_name = artifact.end_with?(".tfs") ? "#{artifact}.asc" : sig["asc"]
    # Per-triplet convention: <artifact>.asc per artifact (registry.rs:
    # the installer verifies the SELECTED artifact against its own asc);
    # the row's signature.asc names the exact asset for universal.
    asc_path = File.join(work, asc_name)
    if base_url.start_with?("file://")
      source = File.join(URI.parse(base_url).path, asc_name)
      raise LaneError.new("SignatureFetch", "#{url}: no #{asc_name}") unless File.file?(source)

      FileUtils.cp(source, asc_path)
    else
      asc_url = "#{base_url}/#{asc_name}"
      begin
        http_get(asc_url, to: asc_path)
      rescue LaneError => e
        raise LaneError.new("SignatureFetch", "#{asc_url}: #{e.message}")
      end
    end

    primary = verify_signature!(artifact_path, asc_path, key_asc,
                                sig["keyid"], root: root_key)
    checks << Check.new(true, nil,
                        "signature: #{asc_name} verifies (primary …#{primary[-16, 16].downcase})")
  end
end

# --------------------------------------------------------- review proper ---

def registry_url_for(ref, allow_file_refs)
  if (m = ref.match(GITHUB_REGISTRY))
    "https://raw.githubusercontent.com/#{m[1]}/HEAD/tpkg-registry.yaml"
  elsif allow_file_refs && ref.start_with?("file://")
    ref
  else
    raise LaneError.new("UnsupportedRef",
                        "registry ref #{ref.inspect} is not tfs:github:org/repo")
  end
end

def fetch_registry(ref, allow_file_refs)
  url = registry_url_for(ref, allow_file_refs)
  if url.start_with?("file://")
    load_yaml_file(URI.parse(url).path, "RegistryFetch")
  else
    begin
      YAML.safe_load(http_get(url))
    rescue Psych::Exception => e
      raise LaneError.new("RegistryFetch", "#{url}: #{e.message}")
    end
  end
end

def review_submission(checks, name, head_row, base_row, allow_file_refs)
  where = base_row.nil? ? "new feedstock" : "updated feedstock"
  checks << Check.new(true, nil, "submission: #{name} (#{where}) → #{head_row['registry']}")

  key_url = head_row["key_url"]
  root_key = key_url.nil?
  if root_key
    checks << Check.new(true, nil, "key: the tamatebako root (#{ROOT_KEY_URL})")
  else
    checks << Check.new(true, nil, "key: declared community key (#{key_url})")
  end

  registry = fetch_registry(head_row["registry"], allow_file_refs)
  checks << Check.new(true, nil, "registry fetch: #{head_row['registry']}")
  payloads = validate_registry!(registry, head_row["registry"], allow_file_refs)
  checks << Check.new(true, nil, "registry schema: #{payloads.length} payload row(s)")

  payload = payloads.find { |p| p["name"] == name }
  unless payload
    raise LaneError.new("PayloadMissing",
                        "the registry carries no payload named #{name} " \
                        "(one feedstock, one payload, one name)")
  end
  checks << Check.new(true, nil, "payload row: #{name} (#{payload['kind']})")

  # Monotonicity against the base catalog's row for this name: versions
  # only grow, and the newest never sorts older. Withdrawal rides
  # governance (`status: withdrawn`), never deletion through intake.
  prior_versions = []
  if base_row
    base_registry = fetch_registry(base_row["registry"], allow_file_refs)
    base_payloads = validate_registry!(base_registry, base_row["registry"], allow_file_refs)
    base_payload = base_payloads.find { |p| p["name"] == name }
    prior_versions = base_payload ? base_payload["versions"].map { |v| v["version"] } : []
    current = payload["versions"].map { |v| v["version"] }
    dropped = prior_versions - current
    unless dropped.empty?
      raise LaneError.new("VersionRemoved",
                          "the update drops #{dropped.join(', ')} — yanking is " \
                          "`status: withdrawn` via docs/governance.md, never a deletion")
    end
    if !prior_versions.empty? &&
       compare_versions(current.max { |a, b| compare_versions(a, b) },
                        prior_versions.max { |a, b| compare_versions(a, b) }).negative?
      raise LaneError.new("VersionRegression",
                          "the submitted registry's newest version sorts older than the published one")
    end
    checks << Check.new(true, nil,
                        "monotonicity: #{current.length} version(s), none dropped, none older")
  end

  key_asc =
    if root_key
      http_get(ROOT_KEY_URL)
    elsif allow_file_refs && key_url.start_with?("file://")
      File.read(URI.parse(key_url).path)
    else
      http_get(key_url)
    end

  payload["versions"].each do |v|
    version = v["version"]
    if v["status"] == "withdrawn"
      checks << Check.new(true, nil, "#{version}: withdrawn — reported, not probed (governance row)")
      next
    end
    if prior_versions.include?(version)
      checks << Check.new(true, nil, "#{version}: already published — not re-probed")
      next
    end
    repo, _tag, base_url = release_base(v.dig("release", "ref"), allow_file_refs)
    if v["platforms"] == "universal"
      artifact = universal_artifact(v.dig("release", "ref"), allow_file_refs)
      # universal pins no sha256 in the row — the signature over the
      # single artifact is the integrity gate, and the asc names it.
      Dir.mktmpdir do |work|
        url = "#{base_url}/#{artifact}"
        artifact_path = File.join(work, artifact)
        asc_path = File.join(work, v["signature"]["asc"])
        if base_url.start_with?("file://")
          dir = URI.parse(base_url).path
          raise LaneError.new("ArtifactUnreachable", "#{url}: no such file") unless File.file?(File.join(dir, artifact))

          checks << Check.new(true, nil, "reachable: #{artifact} (universal)")
          FileUtils.cp(File.join(dir, artifact), artifact_path)
          FileUtils.cp(File.join(dir, v["signature"]["asc"]), asc_path)
        else
          head_reachable!(url, "ArtifactUnreachable")
          checks << Check.new(true, nil, "reachable: #{artifact} (#{repo}, universal)")
          http_get(url, to: artifact_path)
          http_get("#{base_url}/#{v['signature']['asc']}", to: asc_path)
        end
        primary = verify_signature!(artifact_path, asc_path,
                                    key_asc, v["signature"]["keyid"], root: root_key)
        checks << Check.new(true, nil,
                            "signature: #{v['signature']['asc']} verifies (primary …#{primary[-16, 16].downcase})")
      end
    else
      v["platforms"].each do |triplet, entry|
        checks << Check.new(true, nil, "#{version} #{triplet}:")
        probe_artifact!(checks, base_url, entry["artifact"], entry["sha256"],
                        v["signature"], key_asc, root_key)
      end
    end
  end
end

# ----------------------------------------------------------------- main ---

def main
  options = { report: nil, allow_file_refs: false }
  OptionParser.new do |o|
    o.banner = "usage: ruby tools/intake_review.rb --base CATALOG --head CATALOG [--report FILE] [--allow-file-refs]"
    o.on("--base PATH") { |v| options[:base] = v }
    o.on("--head PATH") { |v| options[:head] = v }
    o.on("--report PATH") { |v| options[:report] = v }
    o.on("--allow-file-refs") { options[:allow_file_refs] = true }
  end.parse!
  unless options[:base] && options[:head]
    warn "intake_review: --base and --head are required"
    return 2
  end

  base_doc = load_yaml_file(options[:base], "CatalogParse")
  head_doc = load_yaml_file(options[:head], "CatalogParse")
  base_rows, = check_catalog(base_doc, "base", options[:allow_file_refs])
  head_rows, = check_catalog(head_doc, "head", options[:allow_file_refs])

  base_by_name = base_rows.to_h { |r| [r["name"], r] }
  head_by_name = head_rows.to_h { |r| [r["name"], r] }

  sections = []
  failures = 0

  removed = base_by_name.keys - head_by_name.keys
  unless removed.empty?
    failures += removed.length
    sections << ["removed rows", removed.map do |name|
      Check.new(false, "RowRemoval",
                "#{name}: catalog rows leave only through governance " \
                "(docs/governance.md), never through this lane")
    end]
  end

  submissions = head_by_name.reject do |name, row|
    base_by_name.key?(name) && base_by_name[name] == row
  end
  new_names = submissions.keys - base_by_name.keys
  dup = new_names.select { |n| base_by_name.key?(n) } # unreachable, kept for clarity
  dup.each do |name|
    failures += 1
    sections << [name, [Check.new(false, "DuplicateName", "#{name} is already catalogued")]]
  end

  if submissions.empty? && removed.empty?
    failures += 1
    sections << ["submission", [Check.new(false, "NoSubmission",
                                          "the catalog changed but no packages: row was added or changed")]]
  end

  submissions.each do |name, row|
    checks = []
    begin
      review_submission(checks, name, row, base_by_name[name], options[:allow_file_refs])
    rescue LaneError => e
      failures += 1
      checks << Check.new(false, e.code, e.message)
    rescue StandardError => e
      failures += 1
      checks << Check.new(false, "LaneInternal", "#{e.class}: #{e.message}")
    end
    sections << [name, checks]
  end

  verdict = failures.zero? ? "GREEN" : "RED"
  report = +"# Intake review — verdict: #{verdict}\n\n"
  report << if failures.zero?
              "Every gate passed. **Report-only** — a human maintainer merges " \
              "(or declines); this lane never auto-merges a community submission.\n"
            else
              "#{failures} named failure(s). Fail closed: the submission needs " \
              "a fix and a fresh review; nothing merges on red.\n"
            end
  sections.each do |title, checks|
    report << "\n## #{title}\n\n"
    checks.each { |c| report << "- #{c.line}\n" }
  end

  puts report
  File.write(options[:report], report) if options[:report]
  failures.zero? ? 0 : 1
rescue LaneError => e
  warn "intake_review: #{e.code}: #{e.message}"
  1
end

exit(main) if __FILE__ == $PROGRAM_NAME
