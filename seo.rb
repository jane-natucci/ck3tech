# The crawlable side of the site, generated at deploy time from the data files: a real page for every lifestyle's
# perk trees, every dynasty legacy track and every culture (its own title, description, canonical address,
# structured data and a plain-text summary), plus a sitemap. The page itself is one app; these pages are the same app
# opened on that perk tree, legacy or culture, so a search for "Mashriqi culture CK3" can land on it.
#
#   ruby seo.rb <ck3/data.json> <ck3/legacies.json> <ck3/culture.json> <index.html as deployed> <output dir>
#
# Writes <output dir>/index.html, <output dir>/{perks,legacies,culture}/<slug> (no extension: the deploy uploads them
# as text/html) and <output dir>/sitemap.xml. Standard library only.
require "json"
require "cgi"
require "fileutils"
require "time"

Encoding.default_external = Encoding::UTF_8 # a CI runner may not have a UTF-8 locale
Encoding.default_internal = nil

SITE = "https://ck3tech.jane.berlin"
GAME = "Crusader Kings III"
SHORT = "CK3"

perks_data = JSON.parse(File.read(ARGV[0], encoding: "UTF-8"))
legacies = JSON.parse(File.read(ARGV[1], encoding: "UTF-8"))["tracks"]
culture_data = JSON.parse(File.read(ARGV[2], encoding: "UTF-8"))
template = File.read(ARGV[3], encoding: "UTF-8")
out = ARGV[4]

def h(text) = CGI.escapeHTML(text.to_s)
def n0(x) = x.to_f.round.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
def slugify(name) = name.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
def humanize(key) = key.to_s.tr("_", " ").sub(/\A(?:tradition|ethos|heritage|language|martial custom|innovation) /, "").capitalize
def ld(obj) = %(<script type="application/ld+json">#{JSON.generate(obj).gsub("</", "<\\/")}</script>)

# "Close family opinion +15", "Chance of reinforcing congenital traits +30%".
def modifier(m)
  v = m["value"].to_f
  shown = m["kind"] == "percent" ? "#{(v * 100).round(1).to_s.sub(/\.0\z/, "")}%" : v.round(2).to_s.sub(/\.0\z/, "")
  "#{m["label"]} #{v.positive? ? "+" : ""}#{shown}"
end

# Effect texts carry the game's own markup (icons, placeholders, scripted values); what is left once that is gone, if
# it still reads as a sentence, is kept.
def clean(text)
  t = text.to_s.gsub(/@\w+!/, "").gsub(/\[[^\]]*\]|\$[^$]*\$|#\w+|#!/, "").gsub(/\b\w+_\w+\b/, "").gsub(/\(\s*[^)\w]*\)/, "").gsub(/\s+/, " ").strip
  t.match?(/\+%|\bfp\d|\bcb\b|…|[+%:]\s*(\.|\z)|\(\s*[^)]*of\s*\)|\bto the maximum of\b/i) || t.empty? ? nil : t
end

def perk_line(p)
  mods = (p["modifiers"] || []).reject { |m| m["label"].to_s.match?(/[%$\[]/) }.map { |m| modifier(m) }
  bits = mods + (p["effects"] || []).filter_map { |e| clean(e) }
  bits.any? ? "#{p["name"]}: #{bits.join("; ")}" : p["name"]
end

# --- Rewrites of the page's own tags ---------------------------------------------------------------------------------
def retag(html, title:, description:, url:)
  html = html.sub(%r{<title>.*?</title>}m, "<title>#{h(title)}</title>")
  html = html.sub(/(<meta name="description" content=")[^"]*(")/, "\\1#{h(description)}\\2")
  html = html.sub(/(<link rel="canonical" href=")[^"]*(")/, "\\1#{url}\\2")
  html = html.sub(/(<meta property="og:url" content=")[^"]*(")/, "\\1#{url}\\2")
  html = html.gsub(/(<meta (?:property="og:title"|name="twitter:title") content=")[^"]*(")/, "\\1#{h(title)}\\2")
  html.gsub(/(<meta (?:property="og:description"|name="twitter:description") content=")[^"]*(")/, "\\1#{h(description)}\\2")
end

pages = [] # { path:, title:, description:, facts:, hash:, rank: }

# Lifestyles ---------------------------------------------------------------------------------------------------------------
perks_data["lifestyles"].each do |l|
  total = l["trees"].sum { |t| t["perks"].size }
  facts = [ "#{l["name"]} is one of the six lifestyles in #{GAME}: #{l["trees"].size} perk trees with #{total} perks in all." ]
  l["trees"].each { |t| facts << "#{t["name"]} tree: #{t["perks"].map { |p| perk_line(p) }.join(". ")}." }
  pages << { path: "perks/#{slugify(l["name"])}", hash: "perks/#{l["key"]}", rank: 1,
             title: "#{l["name"]} lifestyle perks in #{SHORT}: every tree and perk effect – #{SHORT} Tech",
             description: "All #{total} #{l["name"]} lifestyle perks in #{GAME}, tree by tree (#{l["trees"].map { |t| t["name"] }.join(", ")}) with what each perk does.",
             heading: "#{l["name"]} lifestyle perks", facts: facts, about: "#{l["name"]} lifestyle in #{GAME}" }
end

# Legacy tracks ------------------------------------------------------------------------------------------------------------
legacies.each do |t|
  facts = [ "#{t["name"]} is one of the dynasty legacy tracks in #{GAME}: #{t["description"].to_s.sub(/\.\z/, "")}.#{t["dlc"] ? " It comes with the #{t["dlc"]} DLC." : ""}" ]
  t["perks"].each_with_index { |p, i| facts << "Level #{i + 1}, #{perk_line(p)}." }
  pages << { path: "legacies/#{slugify(t["name"])}", hash: "legacies/#{t["key"]}", rank: 2,
             title: "#{t["name"]} dynasty legacy in #{SHORT}: all #{t["perks"].size} perks – #{SHORT} Tech",
             description: "The #{t["name"]} dynasty legacy track in #{GAME}, perk by perk: #{t["perks"].map { |p| p["name"] }.join(", ")}.",
             heading: "#{t["name"]} dynasty legacy", facts: facts, about: "#{t["name"]} dynasty legacy in #{GAME}" }
end

# Cultures -----------------------------------------------------------------------------------------------------------------
traditions = culture_data["traditions"]
pillars = culture_data["pillars"]
innovations = culture_data["innovations"].to_h { |i| [ i["key"], i ] }
cultures = culture_data["cultures"].to_h { |c| [ c["key"], c ] }
bookmarks = culture_data["bookmarks"]
eras = culture_data["eras"].to_h { |e| [ e["key"], e["name"] ] }
bookmarks = bookmarks.to_a if bookmarks.is_a?(Hash)

culture_data["cultures"].each do |c|
  first = bookmarks.find { |date, _| c["at"][date] }
  ethos = pillars.dig(c["ethos"], "name") || humanize(c["ethos"])
  trad = c["traditions"].map { |k| traditions.dig(k, "name") || humanize(k) }
  facts = []
  facts << "#{c["name"]} is a culture in #{GAME}, of the #{humanize(c["heritage"])} heritage, speaking #{humanize(c["language"])}, with the #{ethos} ethos#{c["martial_custom"] ? " and the martial custom \"#{humanize(c["martial_custom"]).downcase}\"" : ""}."
  facts << "Its traditions are #{trad.join(", ")}." if trad.any?
  parents = c["parents"].map { |k| cultures.dig(k, "name") || humanize(k) }
  facts << "It was created in #{c["created"].to_s.split(".").first} from #{parents.join(" and ")}." if c["created"] && parents.any?
  bookmarks.each do |date, label|
    at = c["at"][date] or next
    names = at["innovations"].filter_map { |k| innovations.dig(k, "name") }
    facts << "At the #{label} start it is in the #{eras[at["era"]] || humanize(at["era"])} era with #{names.size} innovations#{names.any? ? ", such as #{names.first(8).join(", ")}" : ""}."
  end
  pages << { path: "culture/#{slugify(c["name"])}", hash: "cultures/#{first ? first.first : bookmarks.first.first}/#{c["key"]}", rank: 3,
             title: "#{c["name"]} culture in #{SHORT}: traditions, ethos and innovations by era – #{SHORT} Tech",
             description: "The #{c["name"]} culture in #{GAME}: #{ethos} ethos, #{trad.first(4).join(", ")}#{trad.size > 4 ? " and more" : ""}, plus the innovations it has at each start.",
             heading: "#{c["name"]} culture", facts: facts, about: "#{c["name"]} culture in #{GAME}" }
end

# Slugs must be unique within their folder.
pages.group_by { |p| p[:path] }.each_value { |same| same.drop(1).each_with_index { |p, i| p[:path] = "#{p[:path]}-#{i + 2}" } }

# The script a generated page carries so that its address and its "About" text stay honest: while the app shows the
# page's own item the address keeps the page's path; once the app moves on to another country (or culture, perk
# tree ...) the address becomes the app's normal /#... one and the About text, which was about the first, goes.
def entry_script(path:, key:, key_js:)
  <<~JS
    <script>
      (() => {
        const ENTRY = #{JSON.generate(key)}, PATH = #{JSON.generate(path)}, keyOf = #{key_js};
        const settle = (url) => {
          if (typeof url !== "string" || !url.includes("#")) return url;
          const hash = url.slice(url.indexOf("#"));
          if (hash.length < 2 || keyOf(hash) === ENTRY) return PATH + hash;
          document.querySelector(".seo-about")?.remove();
          return "/" + hash;
        };
        for (const m of ["replaceState", "pushState"]) {
          const original = history[m].bind(history);
          history[m] = (state, title, url) => original(state, title, settle(url));
        }
        const tidy = () => { if (location.hash.length > 1) history.replaceState(history.state, "", location.hash); };
        document.addEventListener("DOMContentLoaded", tidy);
        window.addEventListener("hashchange", tidy); // a link or an edited address, which don't go through the history calls above
      })();
    </script>
  JS
end

# --- The pages -------------------------------------------------------------------------------------------------------------
%w[perks legacies culture].each { |d| FileUtils.mkdir_p(File.join(out, d)) }
pages.each do |pg|
  url = "#{SITE}/#{pg[:path]}"
  block = <<~HTML
    <details class="seo-about">
      <summary>About #{h(pg[:heading])}</summary>
      #{pg[:facts].map { |f| "<p>#{h(f)}</p>" }.join("\n      ")}
      <p><a href="/">All of #{SHORT} Tech</a>.</p>
    </details>
  HTML
  html = retag(template, title: pg[:title], description: pg[:description][0, 300], url: url)
  html = html.sub("<!--seo:about-->", block)
  html = html.sub("<head>", %(<head>\n  <base href="/">)) # the app loads its data and pictures by relative address, which must not resolve under /country/ or /culture/
  parts = pg[:hash].split("/")
  entry_key = parts[0] == "cultures" ? "cultures/#{parts[2]}" : "#{parts[0]}/#{parts[1]}"
  key_js = '(h) => { const p = decodeURIComponent(h.slice(1)).split("/"); return p[0] === "cultures" ? "cultures/" + (p[2] || "") : p[0] + "/" + (p[1] || ""); }'
  html = html.sub("<!--seo:head-->", %(<meta name="initial-hash" content="#{h(pg[:hash])}">\n  ) + entry_script(path: "/#{pg[:path]}", key: entry_key, key_js: key_js) + ld({
    "@context" => "https://schema.org", "@type" => "WebPage", "name" => pg[:title], "url" => url,
    "description" => pg[:description][0, 300], "inLanguage" => "en",
    "isPartOf" => { "@type" => "WebSite", "name" => "#{SHORT} Tech", "url" => "#{SITE}/" },
    "about" => { "@type" => "Thing", "name" => pg[:about] },
    "breadcrumb" => { "@type" => "BreadcrumbList", "itemListElement" => [
      { "@type" => "ListItem", "position" => 1, "name" => "#{SHORT} Tech", "item" => "#{SITE}/" },
      { "@type" => "ListItem", "position" => 2, "name" => pg[:heading], "item" => url }
    ] }
  }))
  File.write(File.join(out, pg[:path]), html, encoding: "UTF-8")
end

# --- The front page: unchanged to look at, just without the markers ---
File.write(File.join(out, "index.html"), template.sub("<!--seo:about-->", "").sub("<!--seo:head-->", ""), encoding: "UTF-8")

# --- Sitemap -------------------------------------------------------------------------------------------------------------
stamp = Time.parse(perks_data["generated"].to_s).utc.strftime("%Y-%m-%d") rescue Time.now.utc.strftime("%Y-%m-%d")
urls = [ [ "#{SITE}/", "1.0" ] ] + pages.map { |p| [ "#{SITE}/#{p[:path]}", p[:rank] <= 2 ? "0.8" : "0.6" ] }
File.write(File.join(out, "sitemap.xml"), <<~XML, encoding: "UTF-8")
  <?xml version="1.0" encoding="UTF-8"?>
  <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  #{urls.map { |u, p| "  <url><loc>#{u}</loc><lastmod>#{stamp}</lastmod><priority>#{p}</priority></url>" }.join("\n")}
  </urlset>
XML
puts "SEO: #{pages.size} pages (#{pages.count { |p| p[:rank] == 1 }} lifestyles, #{pages.count { |p| p[:rank] == 2 }} legacies, #{pages.count { |p| p[:rank] == 3 }} cultures), sitemap with #{urls.size} addresses"
