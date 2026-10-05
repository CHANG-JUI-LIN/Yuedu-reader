#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks that every language has the same keys in each strings table.
#
# A root holds one <language>.lproj folder per language, and each *.strings
# name in them (Localizable.strings, InfoPlist.strings) is a table. Every
# language must have every table, with the same keys: a key one language lacks
# reaches its users untranslated. That is how ja and ko showed the
# photo-library permission prompt in English.
#
# Usage: scripts/check_localizations.rb [root ...]
# Tables are read with plutil, so this runs on macOS only.

require "json"
require "open3"

# Keep in step with the paths filters in .github/workflows/localization.yml,
# or edits to a root's tables never run this check.
DEFAULT_ROOTS = %w[Resources ShareExtension].freeze

def parse_table(path)
  json, stderr, status = Open3.capture3("plutil", "-convert", "json", "-o", "-", path)
  unless status.success?
    warn "#{path}: plist parse failed"
    warn stderr
    return nil
  end

  JSON.parse(json)
rescue JSON::ParserError => e
  warn "#{path}: JSON conversion failed: #{e.message}"
  nil
end

# Checks one table: every language has the file, and every file has the same
# keys as the first. Reports each problem and returns whether there were none.
def check_table(pattern, expected, files)
  absent = expected - files
  absent.each { |path| warn "#{path}: missing; the other languages have this table" }

  if files.size < 2
    warn "#{pattern} matched #{files.size} file(s); need at least two languages to compare keys"
    return false
  end

  parsed = {}
  files.each { |path| parsed[path] = parse_table(path) }
  return false if parsed.value?(nil)

  base_path, base_strings = parsed.first
  base_keys = base_strings.keys.sort
  consistent = absent.empty?

  parsed.each do |path, strings|
    keys = strings.keys.sort
    missing = base_keys - keys
    extra = keys - base_keys
    next if missing.empty? && extra.empty?

    consistent = false
    warn "#{path}: localization key mismatch against #{base_path}"
    warn "  missing keys:"
    missing.each { |key| warn "    #{key}" }
    warn "  extra keys:"
    extra.each { |key| warn "    #{key}" }
  end
  return false unless consistent

  count = base_keys.size
  puts "Localization OK: #{pattern} (#{files.size} files, #{count} #{count == 1 ? "key" : "keys"})"
  true
end

failed = false

(ARGV.empty? ? DEFAULT_ROOTS : ARGV).each do |root|
  languages = Dir.glob(File.join(root, "*.lproj")).sort
  tables = Dir.glob(File.join(root, "*.lproj", "*.strings")).sort.group_by { |path| File.basename(path) }

  if tables.empty?
    warn "#{File.join(root, "*.lproj", "*.strings")} matched 0 files; need at least two languages to compare keys"
    failed = true
  end

  tables.each do |table, files|
    expected = languages.map { |dir| File.join(dir, table) }
    failed = true unless check_table(File.join(root, "*.lproj", table), expected, files)
  end
end

exit 1 if failed
