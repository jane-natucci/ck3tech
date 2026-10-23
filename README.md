# CK3 tech (prototype)

Three views of Crusader Kings III, all read from the game files:

- **Perk trees:** 6 lifestyles, 18 trees, 162 perks, laid out the way the game draws them, with what each perk requires, what it leads to, its modifiers and effect text.
- **Innovations:** all 106 cultural innovations by era, filterable by type and skill, with what each unlocks and how many cultures know it at each start.
- **Cultures:** 237 cultures with their heritage, language, ethos, traditions and the innovations they know at the 867, 1066 and 1178 starts; add up to three to compare them side by side.

Everything is read from the game's own files, not transcribed by hand.

- `index.html` — the whole page: plain HTML/CSS/JS, no build step.
- `extract.rb` — reads a local CK3 install and writes `ck3/data.json` (perks), `ck3/culture.json` (innovations, cultures, traditions) and the icons and backdrops (PNG/JPG; needs ImageMagick for the DDS files). Plain Ruby, standard library only.

```bash
ruby extract.rb                       # default Steam path on macOS, or pass the install folder
ruby -run -e httpd . -p 8000          # then open http://localhost:8000/
```

The generated files are Paradox's data, so they're gitignored.

## Known gaps

- About a third of the perks have no readable effect text: the game's English files build it in code (`[Get…]` calls), so those show only their name, place and links.
- Only `character_modifier` is shown; the extra modifiers some perks get for a government, culture or faith aren't yet.
- Next: cultural innovations by era, a culture comparison (traditions, innovations), dynasty legacies.
