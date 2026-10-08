#!/bin/sh
# The version of beam.com is in more than one file. This script checks
# that each one has the vsn of src/beam_com/beam_com.app.src:
#
# - "version" of package.json (the npm package),
# - the beam.com dependency of each examples/*/package.json,
# - the URL of the npm package of the release in README.md.
#
#   scripts/version.sh [TAG]
#
# With TAG (the tag of a release, for example v0.1.0), TAG must also be
# "v" and the version, and CHANGELOG.md must have a section "## VERSION"
# with text: the release job puts it at the start of the notes. CI runs
# this script for each run, and the release job with the tag.
set -eu
[ $# -le 1 ] || { echo "usage: $0 [TAG]" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)

vsn=$(sed -n 's/.*{vsn, *"\([^"]*\)".*/\1/p' "$root/src/beam_com/beam_com.app.src")
if [ -z "$vsn" ]; then
    echo "$0: src/beam_com/beam_com.app.src has no vsn" >&2
    exit 1
fi
bad=0
fail() {
    echo "$0: $1" >&2
    bad=1
}

if [ $# -eq 1 ]; then
    [ "$1" = "v$vsn" ] || fail "the tag $1 is not the version of beam.com (v$vsn)"
    # The same awk as the step "Publish the release".
    notes=$(awk -v v="## $vsn" '$0 == v {on = 1; next} /^## / {on = 0} on' "$root/CHANGELOG.md")
    printf '%s' "$notes" | grep -q '[^[:space:]]' ||
        fail "CHANGELOG.md has no section \"## $vsn\" with text"
fi
pkg=$(sed -n 's/^  "version": "\([^"]*\)",$/\1/p' "$root/package.json")
[ "$pkg" = "$vsn" ] || fail "package.json has the version \"$pkg\", not \"$vsn\""
for f in "$root"/examples/*/package.json; do
    # The examples that use the npm package: a line "beam.com": "VERSION".
    pin=$(sed -n 's/^ *"beam\.com": "\([^"]*\)",\{0,1\}$/\1/p' "$f")
    [ -n "$pin" ] || continue
    [ "$pin" = "$vsn" ] || fail "${f#"$root"/} has beam.com \"$pin\", not \"$vsn\""
done
url="releases/download/v$vsn/beam.com-$vsn.tgz"
grep -qF "$url" "$root/README.md" || fail "README.md does not have the URL .../$url"
[ "$bad" -eq 0 ] || exit 1
echo "the version $vsn is in each place"
