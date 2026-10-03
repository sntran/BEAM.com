#!/bin/sh
# The generated part of the npm package beam.com (package.json at the root
# of the repository), in runtime/: the files of a --target wasm32
# directory of beam.com that are the same for each app (the runtime and
# its hosts, for js/edge.mjs), and the SHA-256 of that beam.com for npx
# beam.com (js/download.mjs). Then "npm pack" or "npm publish" in the root
# makes the package.
#
#   scripts/npm.sh BEAM_COM DIR
#
# BEAM_COM: the beam.com of the release. DIR: the output of "BEAM_COM
# INPUT -o DIR --target wasm32" (any INPUT: the runtime does not depend on
# it). The version of package.json must be the version of beam.com.
set -eu
[ $# -eq 2 ] || { echo "usage: $0 BEAM_COM DIR" >&2; exit 2; }
beam_com=$1 dir=$2
root=$(cd "$(dirname "$0")/.." && pwd)

vsn=$(sed -n 's/.*{vsn, *"\([^"]*\)".*/\1/p' "$root/src/beam_com/beam_com.app.src")
pkg=$(sed -n 's/^  "version": "\([^"]*\)",$/\1/p' "$root/package.json")
if [ -z "$vsn" ] || [ "$vsn" != "$pkg" ]; then
    echo "$0: the version of package.json ($pkg) is not the version of beam.com ($vsn)" >&2
    exit 1
fi
for f in worker.js app-com.js runtime-id.js beam.mjs beam.wasm; do
    [ -f "$dir/$f" ] || { echo "$0: $dir/$f: no such file (DIR of --target wasm32)" >&2; exit 1; }
done
if command -v sha256sum > /dev/null; then
    sha=$(sha256sum "$beam_com" | cut -d' ' -f1)
else
    sha=$(shasum -a 256 "$beam_com" | cut -d' ' -f1)
fi

out=$root/runtime
rm -rf "$out"
mkdir -p "$out"
# Not the files that depend on the app (beam_com_wasm:host_files/2, in the
# edge part of app.com), the release, and the copy of beam.wasm in page/.
(cd "$dir" && find . -type f | sed 's|^\./||') | while IFS= read -r f; do
    case $f in
        wrangler*.jsonc|release/wrangler.jsonc|worker.capnp|release/release.bin) continue ;;
        page/env.json|page/app/*|page/release.bin|page/beam.wasm) continue ;;
    esac
    mkdir -p "$out/$(dirname "$f")"
    cp "$dir/$f" "$out/$f"
done
# The files of the runtime are ES modules; package.json at the root has no
# type, because a Mix project below it can have CommonJS files
# (examples/phoenix_demo/assets/vendor).
echo '{ "type": "module" }' > "$out/package.json"
printf '{"version": "%s", "sha256": "%s"}\n' "$vsn" "$sha" > "$out/release.json"
echo "$0: wrote $out (beam.com $vsn, runtime $(sed -n "s/^export default '\(.*\)';$/\1/p" "$out/runtime-id.js"))"
