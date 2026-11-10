#!/usr/bin/env ruby
# frozen_string_literal: true

# reanchor.rb — re-anchor a feedstock Tebakofile's toolchain pins against a
# tebako release, without touching anything else in the file.
#
#   ruby reanchor.rb --tebakofile Tebakofile --release v2.8.57 [--check]
#   ruby reanchor.rb --contract contract.yml --release v2.8.57 [--check]
#
# What it anchors (every value is READ FROM THE RELEASE, never assumed):
#
#   tools.release                     -> "v<ver>"
#   tools.sha256.tebako.<platform>    -> SHA256SUMS' `tebako-<ver>-<platform>`
#                                        row (the CLI)
#   tools.sha256.tfs.<platform>       -> SHA256SUMS' `tfs-<ver>-<platform>` row
#   tools.sha256.link-unit.<platform> -> the `link-unit-<ver>-<platform>.tar.gz`
#                                        asset, hashed from the asset itself
#                                        (the monolith does not carry these)
#   tools.sha256.tebako-shim.<platform> -> SHA256SUMS' `tebako-shim-<ver>-<platform>`
#                                        row (the dispatcher the order/slice arms
#                                        consume; absent on windows-ucrt-arm64,
#                                        which the recipe declares)
#   <arm>.wrapper_tebako              -> "<ver>" (every arm, nested flavors included)
#   <arm>.wrapper_sha256.<platform>   -> SHA256SUMS' `tebako-runtime-launcher-<ver>-<platform>` row
#
# Contract mode (--contract) covers the OTHER pin shape — the runtime
# factories' contract.yml (tebako-runtime-ruby, tebako-runtime-python),
# which carries no Tebakofile. Exactly one key is anchored:
#
#   link_unit_release                 -> "v<ver>", and only when the release
#                                        provably serves at least one
#                                        link-unit asset (a pinned release
#                                        whose units never published would
#                                        silently flip every leg to a
#                                        source build — a miss is never an
#                                        error THERE, so it must be one HERE)
#
# The file is edited LINE-WISE: only the quoted values on the lines whose
# path resolves to one of those keys change. Comments, ordering, spacing
# and every other key stay byte-identical — a feedstock recipe is
# hand-authored prose as much as data, and a serializer round-trip would
# destroy it.
#
# `--check` reports the drift without writing (the same resolution, no
# writes). Exit 0 = in sync / written; 1 = `--check` found drift; 2 = a
# named failure (an unresolvable platform, a missing asset, a digest that
# disagrees with the release).
#
# Ruby stdlib only; the factories run this from CI or a workstation.

require "digest"
require "fileutils"
require "net/http"
require "optparse"
require "tmpdir"
require "uri"

REPO = "tamatebako/tebako"
BASE = "https://github.com/#{REPO}/releases/download"

# A resolved anchor: the line to rewrite, and the value the release says
# it must carry.
Anchor = Struct.new(:line_index, :path, :kind, :platform, :old, :new)

def die(message)
  warn "reanchor: #{message}"
  exit 2
end

def fetch(url, redirects: 5, retries: 8)
  uri = URI(url)
  die "too many redirects for #{url}" if redirects.zero?
  res = Net::HTTP.get_response(uri)
  case res
  when Net::HTTPSuccess then res.body
  when Net::HTTPRedirection then fetch(res["location"], redirects: redirects - 1, retries: retries)
  else
    # A 5xx is the host's transient class (the 2026-11-09 incident 504'd
    # every release-asset GET for ~an hour): back off and retry. A 4xx is
    # the request's fault — named immediately, never retried.
    if res.code.to_i >= 500 && retries.positive?
      warn "reanchor: #{url} answered #{res.code} — retrying (#{retries} left)"
      sleep(2**(8 - retries))
      return fetch(url, redirects: redirects, retries: retries - 1)
    end
    die "#{url} answered #{res.code}"
  end
end

# A 1-byte probe: does the release actually SERVE this asset? The link-unit
# guard runs this instead of trusting the release object, because a factory
# pinned to a unit-less release does not fail — it silently source-builds.
# 200/206 = served; 404 = absent; redirects followed (the download host is
# a redirect chain); 5xx retried like fetch's.
def asset_served?(url, redirects: 5, retries: 3)
  uri = URI(url)
  die "too many redirects probing #{url}" if redirects.zero?
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
    http.get(uri.request_uri.empty? ? "/" : uri.request_uri, { "range" => "bytes=0-0" })
  end
  case res
  when Net::HTTPSuccess, Net::HTTPPartialContent then true
  when Net::HTTPRedirection then asset_served?(res["location"], redirects: redirects - 1, retries: retries)
  when Net::HTTPNotFound then false
  else
    if res.code.to_i >= 500 && retries.positive?
      warn "reanchor: probe #{url} answered #{res.code} — retrying (#{retries} left)"
      sleep(2**(3 - retries))
      return asset_served?(url, redirects: redirects, retries: retries - 1)
    end
    die "probe #{url} answered #{res.code}"
  end
end

# The contract-mode guard: the release must serve at least one link-unit
# asset on the canonical platform set. The full set is probed because no
# single platform is guaranteed ("a platform with no published unit misses
# the pin" is the factories' documented tolerance); zero across the set is
# the failure — the pin would buy nothing and hide a dead link-unit leg.
def link_unit_served!(version)
  platforms = %w[
    linux-gnu-x86_64 linux-gnu-arm64 linux-musl-x86_64 linux-musl-arm64
    macos-x86_64 macos-arm64 windows-x86_64
  ]
  served = platforms.any? do |platform|
    asset_served?("#{BASE}/v#{version}/#{asset_name(:link_unit, version, platform)}")
  end
  die "v#{version} serves no link-unit asset on any canonical platform — refusing to pin a unit-less release" unless served
end

# The release monolith: one `digest  name` line per asset it covers.
def sha256sums(version)
  body = fetch("#{BASE}/v#{version}/SHA256SUMS")
  body.each_line.with_object({}) do |line, out|
    digest, name = line.split(/\s+/, 2)
    next if name.nil?
    out[name.strip] = digest
  end
end

def asset_name(kind, version, platform)
  exe = platform.start_with?("windows") && kind != :link_unit ? ".exe" : ""
  case kind
  when :cli then "tebako-#{version}-#{platform}#{exe}"
  when :tfs then "tfs-#{version}-#{platform}#{exe}"
  when :launcher then "tebako-runtime-launcher-#{version}-#{platform}#{exe}"
  when :link_unit then "link-unit-#{version}-#{platform}.tar.gz"
  when :shim then "tebako-shim-#{version}-#{platform}#{exe}"
  end
end

def asset_sha(sums, version, kind, platform)
  name = asset_name(kind, version, platform)
  if kind == :link_unit
    # Not in the monolith: hash the asset the release serves. These run to
    # ~110 MB and the verification pass re-resolves every anchor, so the
    # digest is cached on disk by asset name (which carries the version):
    # one download per asset per machine, not per pass.
    return cached_asset_sha("#{BASE}/v#{version}/#{name}", name)
  end
  sums[name] || die("the release has no #{name} row in SHA256SUMS")
end

def cached_asset_sha(url, name)
  dir = ENV.fetch("TEBAKO_REANCHOR_CACHE", File.join(Dir.tmpdir, "tebako-reanchor-cache"))
  FileUtils.mkdir_p(dir)
  path = File.join(dir, "#{name}.sha256")
  return File.read(path).strip if File.file?(path)

  digest = Digest::SHA256.hexdigest(fetch(url))
  tmp = "#{path}.#{Process.pid}.tmp"
  File.write(tmp, "#{digest}\n")
  File.rename(tmp, path)
  digest
end

# A trailing `# comment` is stripped only when it is outside quotes and
# starts a word. `each_line` keeps the newline, so the pattern has to stop
# at end-of-LINE: the old `#.*\z` could never match a line that ends in
# "\n", which left the comment in the value. A family header written with a
# trailing comment (`link-unit:  # POSIX legs only`) then read as
# "key: value" instead of a parent, and every pin beneath it fell out of
# the path — silently, because the write and the verification pass shared
# the same blind spot.
def strip_comment(line)
  quoted = false
  line.each_char.with_index do |char, index|
    if char == '"'
      quoted = !quoted
    elsif char == "#" && !quoted && (index.zero? || line[index - 1].match?(/\s/))
      return line[0...index]
    end
  end
  line
end

# Split a Tebakofile into lines, tracking each line's YAML path. The
# grammar is deliberately small: `key:` scalars, `key: value` pairs, and
# comments. That is all a Tebakofile uses, and a full YAML parse would lose
# the comments we must preserve.
def scan(text)
  stack = []
  text.each_line.with_index.map do |line, index|
    stripped = strip_comment(line).rstrip
    if stripped.strip.empty?
      stack = stack
      next [index, nil, nil, line]
    end
    indent = stripped[/\A */].length
    key, value = stripped.strip.split(/:(?!\/\/)\s*/, 2)
    next [index, nil, nil, line] if key.nil?

    stack.pop while stack.any? && stack.last[0] >= indent
    path = stack.map { |(_, k)| k } + [key.sub(/\A-\s*/, "")]
    entry = [index, path, value&.strip, line]
    stack << [indent, key.sub(/\A-\s*/, "")] if value.nil? || value.strip.empty?
    entry
  end
end

def quoted(value)
  return nil if value.nil?
  return value[1..-2] if value.start_with?('"') && value.end_with?('"')
  value
end

def reanchor(text, version, sums, contract: false)
  anchors = []
  scan(text).each do |index, path, value, _line|
    next if path.nil?

    leaf = path.last
    current = quoted(value)

    if contract
      # Contract mode anchors exactly one key. The value must already be a
      # quoted release tag — anything else means the file is not the shape
      # this mode owns (named, never guessed).
      next unless path == ["link_unit_release"]

      die "link_unit_release is not a quoted v<ver> tag: #{value.inspect}" unless current&.match?(/\Av\d+\.\d+\.\d+\z/)
      anchors << Anchor.new(index, path, :release, nil, current, "v#{version}")
      next
    end

    if path == %w[tools release]
      anchors << Anchor.new(index, path, :release, nil, current, "v#{version}")
    elsif leaf == "wrapper_tebako"
      anchors << Anchor.new(index, path, :wrapper, nil, current, version)
    elsif current&.match?(/\A[0-9a-f]{64}\z/)
      kind =
        if path.include?("wrapper_sha256") then :launcher
        # The kind-bearing nested shapes win FIRST: `tools.sha256.tebako.*`
        # is the tebako CLI, not the tfs one — the flat arm is only the
        # fallback for a tools block with no kind segment (the v2.8.74
        # roll wrote tfs digests into xml2rfc's tebako pins when the flat
        # arm ran first — the fetch then correctly failed verification).
        elsif path.include?("sha256") && path.include?("tfs") then :tfs
        elsif path.include?("sha256") && path.include?("link-unit") then :link_unit
        elsif path.include?("sha256") && path.include?("tebako-shim") then :shim
        elsif path.include?("sha256") && path.include?("tebako") then :cli
        # The flat tools block (tools.sha256.<platform>) pins the tfs CLI
        # asset — the documented convention (tools/lib/common.sh's
        # download_tfs fetches tfs-<version>-<platform>). The completeness
        # guard owns this family, so an unclassified row is a hard
        # failure, not a skip (the pin-roll debut died here on
        # tebako-packages/hello — "no pin kind resolved it").
        elsif path[0, 2] == %w[tools sha256] then :tfs
        end
      next if kind.nil?

      platform = leaf
      anchors << Anchor.new(index, path, kind, platform, current, :resolve)
    end
  end

  # Resolve every digest against the release; a mismatch is named, never
  # written.
  anchors.each do |anchor|
    next unless anchor.new == :resolve
    anchor.new = asset_sha(sums, version, anchor.kind, anchor.platform)
  end

  # Completeness guard. The tool owns two families — `tools.sha256.*` and
  # `<arm>.wrapper_sha256.*` — and every digest inside them must have been
  # classified; one it cannot classify is a blind spot, not a key it declines
  # to own. Digests elsewhere in the file (an upstream tarball's, say) belong
  # to their own owner and are none of this tool's business. This is the check
  # that would have caught the commented family header: the write pass and the
  # verification pass both skipped those pins, so "verified 0 drift" was true
  # and worthless.
  owned = ->(path) { path[0, 2] == %w[tools sha256] || path.include?("wrapper_sha256") }
  anchored = anchors.map(&:line_index)
  scan(text).each do |index, path, _value, line|
    next if path.nil? || !owned.call(path)
    next unless line.match?(/\b[0-9a-f]{64}\b/)
    next if anchored.include?(index)

    die "line #{index + 1} (#{path.join('.')}) carries a digest but no pin kind resolved it"
  end

  anchors
end

# Contract mode's existence requirement: the file must actually carry the
# key this mode owns, or the roll would report "in sync (0 pins)" on a file
# it never touched.
def require_contract_anchor!(anchors, path)
  return unless anchors.empty?

  die "#{path} carries no link_unit_release key — not the contract shape this mode owns"
end

def rewrite(text, anchors)
  lines = text.lines
  anchors.each do |anchor|
    next if anchor.kind == :wrapper || anchor.kind == :release
    lines[anchor.line_index] = lines[anchor.line_index].sub(anchor.old, anchor.new)
  end
  lines.join
end

def rewrite_scalars(text, anchors)
  lines = text.lines
  anchors.each do |anchor|
    next unless anchor.kind == :wrapper || anchor.kind == :release
    lines[anchor.line_index] = lines[anchor.line_index].sub(%("#{anchor.old}"), %("#{anchor.new}"))
  end
  lines.join
end

options = { check: false, keep: [] }
OptionParser.new do |opts|
  opts.banner = "usage: reanchor.rb --tebakofile <path> | --contract <path> --release <vX.Y.Z> [--check]"
  opts.on("--tebakofile PATH") { |v| options[:tebakofile] = v }
  opts.on("--contract PATH") { |v| options[:contract] = v }
  opts.on("--release TAG") { |v| options[:release] = v.delete_prefix("v") }
  opts.on("--check") { options[:check] = true }
  opts.on("--keep PREFIX[,PREFIX]") { |v| options[:keep] = v.split(",").map(&:strip) }
end.parse!

die "exactly one of --tebakofile / --contract is required" if [options[:tebakofile], options[:contract]].compact.length != 1
die "--release is required" if options[:release].nil?

contract_mode = !options[:contract].nil?
target = contract_mode ? options[:contract] : options[:tebakofile]
die "#{target} does not exist" unless File.file?(target)

version = options[:release]
text = File.read(target)
# Contract mode anchors a scalar, not digests: no monolith fetch — but the
# release must provably serve link-unit assets before the pin moves.
if contract_mode
  link_unit_served!(version)
  sums = nil
else
  sums = sha256sums(version)
end
anchors = reanchor(text, version, sums, contract: contract_mode)
require_contract_anchor!(anchors, target) if contract_mode
# A nested arm may deliberately sit on an older line (truffleruby's jvm
# arm is the live example): --keep <path-prefix> leaves it untouched, and
# the report names what was kept so the PR says so out loud.
kept, anchors = anchors.partition do |anchor|
  options[:keep].any? { |prefix| anchor.path.join(".").start_with?(prefix) }
end

drift = anchors.reject { |a| a.old == a.new }
skipped = anchors.select { |a| a.old.nil? }

kept.each { |anchor| puts "  kept (--keep): #{anchor.path.join('.')} stays #{anchor.old}" }

if drift.empty?
  puts "reanchor: #{target} is in sync with v#{version} (#{anchors.length} pins)"
  exit 0
end

drift.each do |anchor|
  puts "  #{anchor.path.join('.')}: #{anchor.old} -> #{anchor.new}"
end
skipped.each { |anchor| puts "  skipped (no value): #{anchor.path.join('.')}" }

if options[:check]
  puts "reanchor: #{drift.length} of #{anchors.length} pins DRIFT from v#{version} (--check: nothing written)"
  exit 1
end

# Two passes so a scalar rewrite never invalidates a digest edit's offsets
# (line indexes are stable; each sub touches one line).
out = rewrite(text, anchors)
out = rewrite_scalars(out, anchors)
File.write(target, out)

# Verify what we wrote: re-resolve the written file and prove zero drift.
verify = reanchor(File.read(target), version, sums, contract: contract_mode)
# The verification pass must apply the SAME --keep filter as the write, or
# a deliberately-kept arm reads as drift the tool itself created.
verify, = verify.partition do |anchor|
  options[:keep].any? { |prefix| anchor.path.join(".").start_with?(prefix) }
end
remaining = verify.reject { |a| a.old == a.new }
die "the write did not converge: #{remaining.map { |a| a.path.join('.') }.join(', ')}" if remaining.any?

puts "reanchor: #{drift.length} of #{anchors.length} pins re-anchored to v#{version}; verified 0 drift"
