#!/bin/sh
# Puts FILE... (the names of the files are the names of the assets) in
# the prerelease edge of GITHUB_REPOSITORY, for the commit GITHUB_SHA,
# with gh and GH_TOKEN:
#
#   sh scripts/publish_edge.sh beam.com beam.com.sha256
#
# With no release edge, the script makes one. Else it keeps the release
# and its old files until the new files are in it:
#
# 1. Each new file goes in as NAME.new. A failed upload keeps the old
#    files, so edge always has a beam.com.
# 2. For each file, the script deletes the old asset NAME and gives the
#    name NAME to NAME.new.
# 3. The tag edge moves to GITHUB_SHA, and the notes name it.
#
# Before, the job deleted the release and then made a new one. When the
# upload then failed, edge had no file at all.
set -eu
[ $# -gt 0 ] || { echo "usage: publish_edge.sh FILE..." >&2; exit 2; }
repo=$GITHUB_REPOSITORY
notes="beam.com of main at $GITHUB_SHA. The next merge replaces it. To check where it comes from: \`gh attestation verify beam.com --repo $repo\`."

# The id of the asset NAME of edge, or nothing.
asset() {
    gh api "repos/$repo/releases/tags/edge" --jq ".assets[] | select(.name == \"$1\") | .id"
}

if ! gh release view edge --repo "$repo" > /dev/null 2>&1; then
    gh release create edge "$@" --repo "$repo" --prerelease --target "$GITHUB_SHA" \
        --title edge --notes "$notes"
    exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/publish_edge.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
for f in "$@"; do
    name=$(basename "$f")
    # A NAME.new of a run that failed before.
    old=$(asset "$name.new")
    [ -z "$old" ] || gh api -X DELETE "repos/$repo/releases/assets/$old"
    cp "$f" "$tmp/$name.new"
done
(cd "$tmp" && gh release upload edge ./*.new --repo "$repo")
for f in "$@"; do
    name=$(basename "$f")
    new=$(asset "$name.new")
    [ -n "$new" ] || { echo "publish_edge: no asset $name.new after the upload" >&2; exit 1; }
    old=$(asset "$name")
    [ -z "$old" ] || gh api -X DELETE "repos/$repo/releases/assets/$old"
    gh api -X PATCH "repos/$repo/releases/assets/$new" -f name="$name" > /dev/null
done
gh api -X PATCH "repos/$repo/git/refs/tags/edge" -f sha="$GITHUB_SHA" -F force=true > /dev/null
gh release edit edge --repo "$repo" --prerelease --title edge --notes "$notes"
