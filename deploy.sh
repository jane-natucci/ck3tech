#!/usr/bin/env bash
# Uploads the site to S3, where CloudFront serves it as ck3tech.jane.berlin.
#
#   ./deploy.sh              full deploy: page, our own files and the game
#                            data in ck3/ (run extract.rb first; needs a
#                            machine with Crusader Kings III installed)
#   ./deploy.sh --code-only  page and our own files only, reusing the game
#                            data already on S3 -- what CI runs on every push
#                            to main. The very first deploy has to be a full
#                            one, since CI can't generate the data.
#
# Every ck3/ URL carries ?v=<version>, which CloudFront caches ck3/* on for a
# year. The version hashes data.json, culture.json and legacies.json plus our own tracked
# files in ck3/, so a new extraction or a change to any of those files busts
# the cache. index.html is sent with no-cache, so a deploy shows up
# immediately.
set -euo pipefail
cd "$(dirname "$0")"

bucket="${CK3_BUCKET:-ck3tech.jane.berlin}"
# Locally, use the named profile; in CI, credentials come from the OIDC role.
[ -n "${CI:-}" ] || export AWS_PROFILE="${AWS_PROFILE:-personal}"

md5() { if command -v md5sum >/dev/null; then md5sum | cut -d' ' -f1; else command md5 -q; fi; }
tracked=$(git ls-files ck3)   # our own files in ck3/ (the rest is generated)
tmp="$(mktemp -d)"

if [ "${1:-}" = "--code-only" ]; then
  for f in data.json culture.json legacies.json; do
    aws s3 cp "s3://${bucket}/ck3/${f}" "$tmp/${f}" --only-show-errors || {
      echo "No ck3/${f} on S3 yet. The first deploy must be a full one:" >&2
      echo "run 'ruby extract.rb && ./deploy.sh' on a machine with Crusader Kings III installed." >&2
      exit 1
    }
  done
  data="$tmp/data.json"; culture="$tmp/culture.json"; legacies="$tmp/legacies.json"
else
  for f in data.json culture.json legacies.json; do
    [ -f "ck3/${f}" ] || { echo "No ck3/${f} -- run: ruby extract.rb" >&2; exit 1; }
  done
  data="ck3/data.json"; culture="ck3/culture.json"; legacies="ck3/legacies.json"
fi

version="$(cat "$data" "$culture" "$legacies" $tracked | md5)"
version="${version:0:10}"
# The footer's build link points at the deployed commit on GitHub. A local
# deploy with uncommitted changes to the page or our files says so.
sha="$(git rev-parse HEAD)"
label="${sha:0:7}"
[ -z "$(git status --porcelain -- index.html $tracked)" ] || label="${label}-dirty"
sed -e "s/__DATA_VERSION__/${version}/g" -e "s/__BUILD_SHA__/${sha}/g" -e "s/__BUILD_LABEL__/${label}/g" \
  index.html > "$tmp/index.html"

# The crawlable side: a page per perk tree, legacy track and culture, and the sitemap (seo.rb).
ruby seo.rb "$data" "$legacies" "$culture" "$tmp/index.html" "$tmp/seo"

# Assets first, page last, so a new page never points at files not yet there.
if [ "${1:-}" = "--code-only" ]; then
  for f in $tracked; do
    aws s3 cp "$f" "s3://${bucket}/${f}" --only-show-errors --cache-control "public, max-age=31536000"
  done
else
  aws s3 sync ck3/ "s3://${bucket}/ck3/" --delete --exclude ".DS_Store" \
    --cache-control "public, max-age=31536000"
fi
# The pages have no file extension, so they say they are HTML themselves; --delete drops pages that no longer exist.
for d in perks legacies culture; do
  aws s3 sync "$tmp/seo/$d" "s3://${bucket}/$d" --delete --only-show-errors \
    --content-type "text/html; charset=utf-8" --cache-control "public, max-age=3600"
done
aws s3 cp "$tmp/seo/sitemap.xml" "s3://${bucket}/sitemap.xml" --only-show-errors \
  --cache-control "public, max-age=3600" --content-type "application/xml"
aws s3 cp robots.txt "s3://${bucket}/robots.txt" --only-show-errors \
  --cache-control "public, max-age=3600" --content-type "text/plain; charset=utf-8"
aws s3 cp "$tmp/seo/index.html" "s3://${bucket}/index.html" --only-show-errors \
  --cache-control "no-cache" --content-type "text/html; charset=utf-8"

echo "Deployed version ${version} to s3://${bucket}${1:+ ($1)}"
