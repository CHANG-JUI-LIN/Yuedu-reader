#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"

root = ARGV[0] || "Resources"
pattern = File.join(root, "*.lproj", "Localizable.strings")
files = Dir.glob(pattern).sort

if files.size < 2
  warn "#{pattern} matched #{files.size} file(s); need at least two languages to compare keys"
  exit 1
end

parsed = {}
failed = false

files.each do |path|
  json, stderr, status = Open3.capture3("plutil", "-convert", "json", "-o", "-", path)
  unless status.success?
    warn "#{path}: plist parse failed"
    warn stderr
    failed = true
    next
  end

  begin
    parsed[path] = JSON.parse(json)
  rescue JSON::ParserError => e
    warn "#{path}: JSON conversion failed: #{e.message}"
    failed = true
  end
end

exit 1 if failed

base_path, base_strings = parsed.first
base_keys = base_strings.keys.sort
has_mismatches = false

parsed.each do |path, strings|
  keys = strings.keys.sort
  missing = base_keys - keys
  extra = keys - base_keys
  next if missing.empty? && extra.empty?

  has_mismatches = true
  warn "#{path}: localization key mismatch against #{base_path}"
  warn "  missing keys:"
  missing.each { |key| warn "    #{key}" }
  warn "  extra keys:"
  extra.each { |key| warn "    #{key}" }
end

if has_mismatches
  exit 1
end

puts "Localization OK: #{parsed.size} files, #{base_keys.size} keys"
