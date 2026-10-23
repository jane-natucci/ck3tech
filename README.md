# CK3 Tech

**https://ck3tech.jane.berlin** — Crusader Kings III from the game's own files, in three views:

- **Perk trees:** the 6 lifestyles, 18 trees and 162 perks, laid out the way the game draws them, with what each perk requires, what it leads to, its modifiers and its effect text.
- **Innovations:** all 106 cultural innovations by era, filterable by type and skill, with what each unlocks and how many cultures know it at each start.
- **Cultures:** 237 cultures with their heritage, language, ethos and traditions, and the innovations they know at the 867, 1066 and 1178 starts. Add up to three to compare them side by side.

Everything is read straight from the game's files, not transcribed by hand.

## How it works

- `index.html` — the whole site: one static page, plain HTML/CSS/JS, no build step or framework.
- `extract.rb` — reads a local Crusader Kings III install and writes `ck3/data.json` (perks), `ck3/culture.json` (innovations, cultures, traditions) and the icons, lifestyle emblems and tree backdrops it uses. Plain Ruby, standard library only; needs [ImageMagick](https://imagemagick.org) (`magick`) to convert the game's DDS images.
- `deploy.sh` — uploads the page and the generated files to S3, served through CloudFront. See [Deploying](#deploying).

The generated files come from Paradox's game data, so they're **not in this repo**. Run the extractor against your own install to get them.

## Running it locally

```bash
ruby extract.rb                                    # default Steam path on macOS
ruby extract.rb "/path/to/Crusader Kings III"      # elsewhere
bundle install && bundle exec ruby -run -e httpd . -p 8000   # then open http://localhost:8000
```

Re-run `extract.rb` after a game patch. The page shows which game version its data came from in the footer.

## Deploying

Two kinds of deploy, because the game data can only be generated where the game is installed:

- **Code** (`index.html`): deployed automatically by GitHub Actions on every push to `main` (`./deploy.sh --code-only`). It reuses the game data already on S3.
- **Game data** (after a game patch, or anything `extract.rb` produces): run locally:

  ```bash
  ruby extract.rb && ./deploy.sh
  ```

> [!IMPORTANT]
> **The very first deploy must be a full local one** (`ruby extract.rb && ./deploy.sh`). CI has no game data to upload, so until S3 has a `ck3/data.json` and `ck3/culture.json`, the GitHub Action stops with an error saying so.

Local deploys use the `personal` AWS profile by default (`AWS_PROFILE` overrides it). CI logs into AWS through GitHub's OIDC, into a role that can only write to this site's bucket (defined in the site's separate infrastructure config), so no AWS keys are stored in this repo.

## Known approximations

- Innovations have no prerequisites in the game (a culture discovers them by era), so they're shown as a catalogue, not a graph.
- What a culture knows at a start comes from the game's culture history files (the culture's own, else its heritage's); innovations added by game-start events, some of them DLC-gated, aren't included.
- Some perks have no readable effect text: the game builds it in code.
- Some tradition descriptions keep a stray `!` where the game inserts a link.

## Credits

Unofficial fan project. Crusader Kings III and all its data, art and text are © Paradox Interactive; this project isn't affiliated with or endorsed by Paradox. The code in this repository is MIT-licensed.
