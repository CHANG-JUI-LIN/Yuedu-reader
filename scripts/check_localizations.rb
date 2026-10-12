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
# It also checks that every key the Swift code asks for exists. Agreeing tables
# say nothing about a key no table has: the EPUB media overlay called
# localized("段落"), which no table contained, so every language showed the raw
# Chinese key while the tables agreed. Every localized("…") under the source
# folders whose argument is a string literal, or a ternary choosing between two
# literals, must be a key of the zh-Hant Localizable.strings (the tables above
# keep the other languages in step with it). A literal that interpolates fails
# outright: the key it builds ("5 分鐘") is in no table, so the reading-stats
# durations and the WebDAV conflict message showed Chinese everywhere; format
# a key instead (String(format: localized("%d 分鐘"), n)). Variables can't be
# checked here and are skipped.
#
# Usage: scripts/check_localizations.rb [root ...]
# Tables are read with plutil, so this runs on macOS only.

require "json"
require "open3"
require "set"

# Keep in step with the paths filters in .github/workflows/localization.yml,
# or edits to a root's tables never run this check.
DEFAULT_ROOTS = %w[Resources ShareExtension].freeze
# The same goes for these: the workflow runs on edits to their Swift files.
CODE_SOURCES = %w[Modules Targets].freeze
CODE_TABLE = "Resources/zh-Hant.lproj/Localizable.strings"

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

# A Swift string literal's body: no unescaped quote, no line break.
SWIFT_LITERAL = /"((?:[^"\\\n]|\\.)*)"/.source
CALL_PREFIX = /(?<![\w.])localized\(\s*/.source
# localized("key") and localized(condition ? "key" : "key"), spanning lines.
LITERAL_CALL = /#{CALL_PREFIX}#{SWIFT_LITERAL}\s*[,)]/m
TERNARY_CALL = /#{CALL_PREFIX}[^"()]*?\?\s*#{SWIFT_LITERAL}\s*:\s*#{SWIFT_LITERAL}\s*[,)]/m
SWIFT_ESCAPES = { "n" => "\n", "t" => "\t", "r" => "\r", "0" => "\0" }.freeze

# The key a literal's body spells; the caller rules out interpolation.
def swift_literal_value(body)
  body.gsub(/\\u\{(\h+)\}|\\(.)/) { $1 ? [$1.hex].pack("U") : SWIFT_ESCAPES.fetch($2, $2) }
end

# Every literal key the code passes to localized, mapped to "file:line" sites,
# and the "file:line" sites whose literal interpolates.
def code_keys(sources)
  sites = Hash.new { |hash, key| hash[key] = [] }
  interpolated = []
  Dir.glob(sources.map { |dir| File.join(dir, "**", "*.swift") }).sort.each do |path|
    text = File.read(path, encoding: "UTF-8")
    [LITERAL_CALL, TERNARY_CALL].each do |pattern|
      text.scan(pattern) do
        match = Regexp.last_match
        line_start = text.rindex("\n", match.begin(0)).to_i
        next if text[line_start..match.begin(0)].lstrip.start_with?("//")

        line = text[0...match.begin(0)].count("\n") + 1
        match.captures.compact.each do |body|
          if body.include?("\\(")
            interpolated << "#{path}:#{line}"
          else
            sites[swift_literal_value(body)] << "#{path}:#{line}"
          end
        end
      end
    end
  end
  [sites, interpolated.uniq]
end

# Reports each literal key the code uses that the table lacks; returns whether
# there were none.
def check_code_keys(sources, table)
  strings = parse_table(table)
  return false if strings.nil?

  sites, interpolated = code_keys(sources)
  known = strings.keys.to_set
  missing = sites.reject { |key, _| known.include?(key) }
  unless missing.empty?
    warn "#{table}: keys used in code but missing from the table"
    missing.sort.each do |key, places|
      warn "    #{key.gsub("\n", "\\n")}"
      places.uniq.each { |place| warn "      #{place}" }
    end
  end
  unless interpolated.empty?
    warn "localized() keys built by interpolation, which no table can hold; format a key instead:"
    interpolated.each { |place| warn "    #{place}" }
  end
  return false unless missing.empty? && interpolated.empty?

  count = sites.size
  puts "Localization OK: #{sources.join(", ")} use #{count} literal #{count == 1 ? "key" : "keys"}, all in #{table}"
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

failed = true unless check_code_keys(CODE_SOURCES, CODE_TABLE)

exit 1 if failed
