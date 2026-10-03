#!/bin/sh
# The npm package beam.com (npm/README.md): the files of npm/, the runtime
# of a --target wasm32 directory of beam.com, and the SHA-256 of that
# beam.com for npx beam.com (npm/lib/download.js).
#
#   scripts/npm.sh BEAM_COM DIR OUT
#
# BEAM_COM: the beam.com of the release. DIR: the output of "BEAM_COM
# INPUT -o DIR --target wasm32" (any INPUT: the runtime does not depend on
# it). OUT: a new directory for the package ("npm pack OUT" or "npm
# publish OUT"). The version is the version of beam.com.
set -eu
[ $# -eq 3 ] || { echo "usage: $0 BEAM_COM DIR OUT" >&2; exit 2; }
beam_com=$1 dir=$2 out=$3
root=$(cd "$(dirname "$0")/.." && pwd)

vsn=$(sed -n 's/.*{vsn, *"\([^"]*\)".*/\1/p' "$root/src/beam_com/beam_com.app.src")
[ -n "$vsn" ] || { echo "$0: no version in src/beam_com/beam_com.app.src" >&2; exit 1; }
for f in worker.js app-com.js runtime-id.js beam.mjs beam.wasm; do
    [ -f "$dir/$f" ] || { echo "$0: $dir/$f: no such file (DIR of --target wasm32)" >&2; exit 1; }
done
if command -v sha256sum > /dev/null; then
    sha=$(sha256sum "$beam_com" | cut -d' ' -f1)
else
    sha=$(shasum -a 256 "$beam_com" | cut -d' ' -f1)
fi

[ ! -e "$out" ] || { echo "$0: $out exists" >&2; exit 1; }
mkdir -p "$out/runtime"
cp -R "$root/npm/." "$out/"
for f in worker.js app-com.js runtime-id.js beam.mjs beam.wasm; do
    cp "$dir/$f" "$out/runtime/$f"
done
# The license texts: of BEAM.com, and of the parts of the runtime.
cp "$root/LICENSE" "$root/NOTICE" "$out/"
[ ! -d "$dir/licenses" ] || cp -R "$dir/licenses" "$out/licenses"
sed "s/\"version\": \"0.0.0\"/\"version\": \"$vsn\"/" "$root/npm/package.json" > "$out/package.json"
printf '{"version": "%s", "sha256": "%s"}\n' "$vsn" "$sha" > "$out/bin/release.json"
chmod +x "$out/bin/beam.com.js"
echo "$0: wrote $out (beam.com $vsn, runtime $(sed -n "s/^export default '\(.*\)';$/\1/p" "$out/runtime/runtime-id.js"))"
