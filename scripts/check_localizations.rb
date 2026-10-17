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
# The widget extension is its own bundle with its own tables (Widget/*.lproj),
# looked up through its own localized(); its literal keys are checked against
# Widget/zh-Hant.lproj/Localizable.strings the same way. Literals the system
# looks up itself are checked too, because a missing key there shows the raw
# Chinese just as silently: the App Intents title and @Parameter title (in the
# app and in the widget), and in the widget Text("…"), configurationDisplayName
# and description. Those literals may interpolate (SwiftUI builds the key from
# the interpolation, e.g. `%lld%% · %@前`), so an interpolating one can't be
# checked and is skipped.
#
# Usage: scripts/check_localizations.rb [root ...]
# Tables are read with plutil, so this runs on macOS only.

require "json"
require "open3"
require "set"

# Keep in step with the paths filters in .github/workflows/localization.yml,
# or edits to a root's tables never run this check.
DEFAULT_ROOTS = %w[Resources ShareExtension Widget].freeze
# The same goes for these: the workflow runs on edits to their Swift files.
CODE_CHECKS = [
  { sources: %w[Modules Targets], table: "Resources/zh-Hant.lproj/Localizable.strings", swiftui: false },
  { sources: %w[Widget], table: "Widget/zh-Hant.lproj/Localizable.strings", swiftui: true }
].freeze

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
# Literals the system looks up itself, in every checked folder: the App Intents
# title (`static var title: LocalizedStringResource = "…"`) and `@Parameter(title: "…")`.
SYSTEM_LITERAL = /(?:LocalizedStringResource\s*=|@Parameter\(\s*title:)\s*#{SWIFT_LITERAL}/m
# And the widget's SwiftUI ones: `Text("…")` (not `Text(verbatim:`),
# `.configurationDisplayName("…")` and `.description("…")`.
SWIFTUI_LITERAL = /(?:(?<![\w.])Text\(|\.configurationDisplayName\(|\.description\()\s*#{SWIFT_LITERAL}\s*[,)]/m
SWIFT_ESCAPES = { "n" => "\n", "t" => "\t", "r" => "\r", "0" => "\0" }.freeze

# The key a literal's body spells; the caller rules out interpolation.
def swift_literal_value(body)
  body.gsub(/\\u\{(\h+)\}|\\(.)/) { $1 ? [$1.hex].pack("U") : SWIFT_ESCAPES.fetch($2, $2) }
end

# Every literal key the code passes to localized, or that the system looks up
# itself (SYSTEM_LITERAL, and SWIFTUI_LITERAL when swiftui is set), mapped to
# "file:line" sites, and the "file:line" sites whose localized() literal
# interpolates. A system-looked-up literal that interpolates is skipped: the
# key SwiftUI builds from it can't be read off the source.
def code_keys(sources, swiftui)
  sites = Hash.new { |hash, key| hash[key] = [] }
  interpolated = []
  call_patterns = [LITERAL_CALL, TERNARY_CALL]
  system_patterns = swiftui ? [SYSTEM_LITERAL, SWIFTUI_LITERAL] : [SYSTEM_LITERAL]
  Dir.glob(sources.map { |dir| File.join(dir, "**", "*.swift") }).sort.each do |path|
    text = File.read(path, encoding: "UTF-8")
    (call_patterns + system_patterns).each do |pattern|
      text.scan(pattern) do
        match = Regexp.last_match
        line_start = text.rindex("\n", match.begin(0)).to_i
        next if text[line_start..match.begin(0)].lstrip.start_with?("//")

        line = text[0...match.begin(0)].count("\n") + 1
        match.captures.compact.each do |body|
          if body.include?("\\(")
            interpolated << "#{path}:#{line}" if call_patterns.include?(pattern)
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
def check_code_keys(sources, table, swiftui)
  strings = parse_table(table)
  return false if strings.nil?

  sites, interpolated = code_keys(sources, swiftui)
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

CODE_CHECKS.each do |check|
  failed = true unless check_code_keys(check[:sources], check[:table], check[:swiftui])
end

exit 1 if failed
