#!/usr/bin/env ruby
# frozen_string_literal: true

# reanchor.rb — re-anchor a feedstock Tebakofile's toolchain pins against a
# tebako release, without touching anything else in the file.
#
#   ruby reanchor.rb --tebakofile Tebakofile --release v2.8.57 [--check]
#
# What it anchors (every value is READ FROM THE RELEASE, never assumed):
#
#   tools.release                     -> "v<ver>"
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

def fetch(url, redirects: 5)
  uri = URI(url)
  die "too many redirects for #{url}" if redirects.zero?
  res = Net::HTTP.get_response(uri)
  case res
  when Net::HTTPSuccess then res.body
  when Net::HTTPRedirection then fetch(res["location"], redirects: redirects - 1)
  else die "#{url} answered #{res.code}"
  end
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

def reanchor(text, version, sums)
  anchors = []
  scan(text).each do |index, path, value, _line|
    next if path.nil?

    leaf = path.last
    current = quoted(value)

    if path == %w[tools release]
      anchors << Anchor.new(index, path, :release, nil, current, "v#{version}")
    elsif leaf == "wrapper_tebako"
      anchors << Anchor.new(index, path, :wrapper, nil, current, version)
    elsif current&.match?(/\A[0-9a-f]{64}\z/)
      kind =
        if path.include?("wrapper_sha256") then :launcher
        elsif path.include?("sha256") && path.include?("tfs") then :tfs
        elsif path.include?("sha256") && path.include?("link-unit") then :link_unit
        elsif path.include?("sha256") && path.include?("tebako-shim") then :shim
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
  opts.banner = "usage: reanchor.rb --tebakofile <path> --release <vX.Y.Z> [--check]"
  opts.on("--tebakofile PATH") { |v| options[:tebakofile] = v }
  opts.on("--release TAG") { |v| options[:release] = v.delete_prefix("v") }
  opts.on("--check") { options[:check] = true }
  opts.on("--keep PREFIX[,PREFIX]") { |v| options[:keep] = v.split(",").map(&:strip) }
end.parse!

die "--tebakofile is required" if options[:tebakofile].nil?
die "--release is required" if options[:release].nil?
die "#{options[:tebakofile]} does not exist" unless File.file?(options[:tebakofile])

version = options[:release]
text = File.read(options[:tebakofile])
sums = sha256sums(version)
anchors = reanchor(text, version, sums)
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
  puts "reanchor: #{options[:tebakofile]} is in sync with v#{version} (#{anchors.length} pins)"
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
File.write(options[:tebakofile], out)

# Verify what we wrote: re-resolve the written file and prove zero drift.
verify = reanchor(File.read(options[:tebakofile]), version, sums)
# The verification pass must apply the SAME --keep filter as the write, or
# a deliberately-kept arm reads as drift the tool itself created.
verify, = verify.partition do |anchor|
  options[:keep].any? { |prefix| anchor.path.join(".").start_with?(prefix) }
end
remaining = verify.reject { |a| a.old == a.new }
die "the write did not converge: #{remaining.map { |a| a.path.join('.') }.join(', ')}" if remaining.any?

puts "reanchor: #{drift.length} of #{anchors.length} pins re-anchored to v#{version}; verified 0 drift"
