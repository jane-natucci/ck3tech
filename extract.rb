#!/usr/bin/env ruby
# frozen_string_literal: true

# Reads a local Crusader Kings III install and writes ck3/data.json (and the icons the
# page uses, as PNGs in ck3/icons/): the lifestyle perk trees -- 6 lifestyles, 3 trees
# each, every perk with its place in the tree, what it requires, its modifiers and its
# effect text -- straight from the game's own files, not transcribed by hand.
#
#   ruby extract.rb                                    # default Steam install on macOS
#   ruby extract.rb "/path/to/Crusader Kings III"
#
# The output is Paradox's game data, so it's gitignored and never committed.
# Needs ImageMagick (`magick`) only for the icons. Plain Ruby otherwise.

Encoding.default_external = Encoding::UTF_8

require "json"
require "fileutils"
require "open3"

DEFAULT_ROOT = File.expand_path("~/Library/Application Support/Steam/steamapps/common/Crusader Kings III")
ROOT = ARGV[0] || DEFAULT_ROOT
GAME = File.join(ROOT, "game")
abort "No Crusader Kings III install at #{ROOT}" unless File.directory?(GAME)

OUT_DIR = File.join(__dir__, "ck3")
ICON_DIR = File.join(OUT_DIR, "icons")
FileUtils.mkdir_p(ICON_DIR)

# --- Paradox script: a small parser -------------------------------------------------
# A block is an array of [key, value] pairs (keys can repeat: several `parent =`), a value
# is a String, a Float/Integer or another block. Bare values inside braces get a nil key.
module Script
  TOKEN = /\s*(?:#[^\n]*|"(?:[^"\\]|\\.)*"|[{}]|[<>!?]?=|[<>]|[^\s{}=<>"#]+)/

  def self.parse(text)
    tokens = text.sub(/\A﻿/, "").scan(TOKEN).map(&:strip).reject { |t| t.empty? || t.start_with?("#") }
    pos = 0
    value = nil
    block = lambda do
      pairs = []
      while pos < tokens.size
        tok = tokens[pos]
        if tok == "}"
          pos += 1
          return pairs
        end
        pos += 1
        if tokens[pos]&.match?(/\A[<>!?]?=\z|\A[<>]\z/)
          pos += 1
          pairs << [tok, value.call]
        else
          pairs << [nil, scalar(tok)]
        end
      end
      pairs
    end
    value = lambda do
      tok = tokens[pos]
      pos += 1
      tok == "{" ? block.call : scalar(tok)
    end
    block.call
  end

  def self.scalar(token)
    return token[1..-2] if token.start_with?('"')
    return token.to_i if token.match?(/\A-?\d+\z/)
    return token.to_f if token.match?(/\A-?\d*\.\d+\z/)

    token
  end

  def self.get(block, key) = block.find { |k, _| k == key }&.last
  def self.all(block, key) = block.select { |k, _| k == key }.map(&:last)
end

# --- Localization ---------------------------------------------------------------------
LOC = {}
Dir.glob(File.join(GAME, "localization/english/**/*.yml")).sort.each do |file|
  File.foreach(file, encoding: "bom|utf-8") do |line|
    next unless (m = line.match(/\A\s*([A-Za-z0-9_.\-']+):\d*\s+"(.*)"\s*(?:#.*)?\z/))

    LOC[m[1]] = m[2]
  end
end

def humanize(key) = key.to_s.sub(/_perk\z/, "").tr("_", " ").split.map(&:capitalize).join(" ")

# Game text with its formatting codes taken out: #V ... #! colours, $other$ references,
# [concept|E] links and the like. Good enough to read, not a faithful render.
def clean(text, depth = 0)
  return nil if text.nil?

  text = text.gsub(/\$([A-Za-z0-9_.\-']+)(?:\|[^$]*)?\$/) { depth < 4 && LOC[$1] ? clean(LOC[$1], depth + 1) : "" }
  text = text.gsub(/\[([A-Za-z0-9_]+)\|[A-Za-z]*\]/) { $1.tr("_", " ") }
  text = text.gsub(/\s*\[[^\]]*\]\s*\z/, " …").gsub(/\[[^\]]*\]/, "")
  text = text.gsub(/#[A-Za-z_]*\s?/, "").gsub(/£[^£]*£/, "").gsub('\n', " ").gsub(/\\"/, '"')
  text.gsub(/\s+/, " ").strip
end

def loc(key) = clean(LOC[key])

# --- Effect texts: common/effect_localization says which localization key a perk's
# "<perk>_effect" text key stands for (its `global` line is the plain wording). ----------
EFFECT_TEXT = {}
Dir.glob(File.join(GAME, "common/effect_localization/*.txt")).sort.each do |file|
  Script.parse(File.read(file, encoding: "bom|utf-8")).each do |key, body|
    next unless key.is_a?(String) && body.is_a?(Array)

    global = Script.get(body, "global")
    EFFECT_TEXT[key] = global if global.is_a?(String)
  end
end

def effect_text(key)
  loc(key) || (EFFECT_TEXT[key] && loc(EFFECT_TEXT[key]))
end

# --- Named numbers: script values (common/script_values) and a file's own @constants -------
SCRIPT_VALUES = {}
Dir.glob(File.join(GAME, "common/script_values/*.txt")).sort.each do |file|
  Script.parse(File.read(file, encoding: "bom|utf-8")).each do |key, value|
    next unless key.is_a?(String)

    SCRIPT_VALUES[key] = value if value.is_a?(Numeric)
  end
end

def resolve(value, constants)
  return value if value.is_a?(Numeric)
  return constants[value] if value.is_a?(String) && value.start_with?("@") && constants[value].is_a?(Numeric)

  SCRIPT_VALUES[value] if value.is_a?(String)
end

# --- The perks ---------------------------------------------------------------------------
perks = []
Dir.glob(File.join(GAME, "common/lifestyle_perks/*.txt")).sort.each do |file|
  parsed = Script.parse(File.read(file, encoding: "bom|utf-8"))
  constants = parsed.select { |k, v| k.is_a?(String) && k.start_with?("@") && v.is_a?(Numeric) }.to_h
  parsed.each do |key, body|
    next unless key.is_a?(String) && body.is_a?(Array) && Script.get(body, "lifestyle")

    mods = (Script.get(body, "character_modifier") || []).filter_map do |mkey, mval|
      number = mkey && resolve(mval, constants)
      next unless number

      raw = LOC[mkey] || LOC["MOD_#{mkey.upcase}"]
      label = raw && !raw.include?("[Get") ? clean(raw) : humanize(mkey.sub(/_(add|mult)\z/, ""))
      { key: mkey, label: label, value: number, kind: mkey.end_with?("_mult") ? "percent" : "number" }
    end

    effect_texts = []
    walk = lambda do |block|
      block.each do |k, v|
        next unless v.is_a?(Array)

        if %w[custom_description_no_bullet custom_description custom_tooltip].include?(k)
          text_key = Script.get(v, "text")
          text = text_key.is_a?(String) ? effect_text(text_key) : nil
          effect_texts << text if text && !text.empty?
        end
        walk.call(v)
      end
    end
    walk.call(Script.get(body, "effect") || [])

    position = Script.get(body, "position") || []
    perks << {
      key: key,
      name: loc("#{key}_name") || humanize(key),
      lifestyle: Script.get(body, "lifestyle"),
      tree: Script.get(body, "tree"),
      x: position[0]&.last || 0,
      y: position[1]&.last || 0,
      icon: Script.get(body, "icon") || key,
      parents: Script.all(body, "parent"),
      trait: Script.get(body, "trait"),
      modifiers: mods,
      description: loc("#{key}_modifier_desc"),
      effects: effect_texts.uniq
    }
  end
end

# --- Art: modifier icons, lifestyle icons and the painted backdrop of each tree ---------------
ICONS = File.join(GAME, "gfx/interface/icons")
FileUtils.mkdir_p(File.join(OUT_DIR, "trees"))
FileUtils.mkdir_p(File.join(OUT_DIR, "lifestyles"))

def convert(src, dest, *args)
  return false unless File.exist?(src)

  _out, err, status = Open3.capture3("magick", src, *args, dest)
  warn "#{File.basename(src)}: #{err.strip}" unless status.success?
  status.success?
end

# The game names a modifier's icon after the modifier: <key>_positive.dds / _negative.dds,
# or the same without a _mult/_add ending.
def modifier_icon(key, value)
  tone = value.negative? ? "negative" : "positive"
  [ key, key.sub(/_(mult|add)\z/, "") ].uniq.each do |base|
    src = File.join(ICONS, "modifiers/#{base}_#{tone}.dds")
    name = "mod_#{base}_#{tone}"
    dest = File.join(ICON_DIR, "#{name}.png")
    return name if File.exist?(dest) || convert(src, dest, "-resize", "40x40")
  end
  nil
end
perks.each { |perk| perk[:modifiers].each { |m| m[:icon] = modifier_icon(m[:key], m[:value]) } }
perks.each { |perk| perk[:trait_name] = perk[:trait] && (loc("trait_#{perk[:trait]}") || loc(perk[:trait]) || humanize(perk[:trait].sub(/\Alifestyle_/, ""))) }

# --- Lifestyles and trees ---------------------------------------------------------------
lifestyles = perks.group_by { |p| p[:lifestyle] }.map do |lifestyle_key, lifestyle_perks|
  short = lifestyle_key.sub(/_lifestyle\z/, "")
  trees = lifestyle_perks.group_by { |p| p[:tree] }.map do |tree_key, tree_perks|
    name = loc("#{short}_#{tree_key}_focus_short") || humanize(tree_key)
    { key: tree_key, name: name, perks: tree_perks.sort_by { |p| [p[:y], p[:x]] } }
  end
  { key: lifestyle_key, name: loc("#{lifestyle_key}_name") || humanize(short), trees: trees.sort_by { |t| t[:key] } }
end
lifestyles.each do |ls|
  # Each lifestyle strip holds three 160x160 frames; the first is the plain emblem.
  ls[:icon] = convert(File.join(ICONS, "lifestyles/#{ls[:key]}.dds"), File.join(OUT_DIR, "lifestyles/#{ls[:key]}.png"), "-crop", "160x160+0+0", "+repage", "-resize", "96x96") ? ls[:key] : nil
  ls[:trees].each do |tree|
    tree[:backdrop] = convert(File.join(ICONS, "lifestyle_tree_backgrounds/#{tree[:key]}.dds"), File.join(OUT_DIR, "trees/#{tree[:key]}.jpg"), "-resize", "360x", "-quality", "72") ? tree[:key] : nil
  end
end
order = %w[diplomacy_lifestyle martial_lifestyle stewardship_lifestyle intrigue_lifestyle learning_lifestyle wanderer_lifestyle]
lifestyles.sort_by! { |l| order.index(l[:key]) || 99 }

# --- Icons ---------------------------------------------------------------------------------
icon_names = perks.map { |p| p[:icon] }.uniq
icon_names.each do |name|
  src = File.join(GAME, "gfx/interface/icons/lifestyles_perks/#{name}.dds")
  next unless File.exist?(src)

  # The node_* files are strips of three 60x60 states (dark, lit, dark): the lit gem, in each
  # lifestyle's colour, is the one worth drawing. Trait icons are single images.
  args = name.start_with?("node_") ? [ "-crop", "60x60+60+0", "+repage" ] : []
  _out, err, status = Open3.capture3("magick", src, *args, "-resize", "96x96", File.join(ICON_DIR, "#{name}.png"))
  warn "icon #{name}: #{err.strip}" unless status.success?
end

version = begin
  JSON.parse(File.read(File.join(ROOT, "launcher/launcher-settings.json")))["rawVersion"]
rescue StandardError
  nil
end

data = { game_version: version, generated: Time.now.utc.strftime("%Y-%m-%d"), lifestyles: lifestyles }
File.write(File.join(OUT_DIR, "data.json"), JSON.pretty_generate(data))

total = perks.size
puts "Wrote ck3/data.json: #{lifestyles.size} lifestyles, #{lifestyles.sum { |l| l[:trees].size }} trees, #{total} perks (game #{version || "version unknown"})"
puts "Perks with a description: #{perks.count { |p| p[:description] }}, with modifiers: #{perks.count { |p| p[:modifiers].any? }}, with effect text: #{perks.count { |p| p[:effects].any? }}, with none of them: #{perks.count { |p| p[:description].nil? && p[:modifiers].empty? && p[:effects].empty? }}"
puts "Perks without a localized name: #{perks.count { |p| !LOC.key?("#{p[:key]}_name") }}; without any modifier: #{perks.count { |p| p[:modifiers].empty? }}; icons: #{Dir.glob(File.join(ICON_DIR, '*.png')).size}"
missing_parent = perks.flat_map { |p| p[:parents] }.uniq - perks.map { |p| p[:key] }
puts "Parents that aren't perks (should be none): #{missing_parent.inspect}"
