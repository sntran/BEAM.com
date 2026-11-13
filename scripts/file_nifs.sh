#!/bin/sh
# The NIF files of beam.com that come from a release of another project
# (docs/NIFS.md, "The NIF files of beam.com"): prebuilt native NIF
# objects, with no build and no link. They go into the zip as
# lib/beam_com/priv/nifs/DIR, with a file SOURCE that names the package
# of the files, so only a dep of that source gets them.
#
#   sh scripts/file_nifs.sh names         the names, on one line
#   sh scripts/file_nifs.sh dir NAME      the directory DIR of NAME (APP-VSN)
#   sh scripts/file_nifs.sh fetch NAME OUT
#
# fetch downloads the files of NAME, checks the SHA-256 of each one, and
# writes them to OUT/nifs/DIR, with SOURCE. It writes the line of NAME
# for parts.txt (build.yml) and for scripts/assemble.erl:
# "NAME lib/beam_com/priv/nifs/DIR/=nifs/DIR".
#
# The pins are in this file, a source of the build (scripts/): a new pin
# changes the KEY of a custom build (scripts/custom_build.py).
set -eu

# tailwind.com (https://github.com/sntran/tailwind.com): the NIF of the
# module tailwind_nif, for the git dep tailwind.com of the tag or of the
# commit. FILE_NIFS_TAILWIND_URL gives another place of the same files
# (for the tests).
TAILWIND_TAG=v0.3.0
TAILWIND_COMMIT=0d6061e69ecbb9c5cb7103d58fbebe46d3f7c3df
TAILWIND_X86_64_SHA256=bf406360908a9522d3feaa680cd4dd884ecaf6b1ee5b9a6b72692e007ceaffc4
TAILWIND_AARCH64_SHA256=da381e6e9c9bc529a83697e325d9cb87c6bc20fca8e16026ddd63b86858fc5a9
TAILWIND_URL=${FILE_NIFS_TAILWIND_URL:-https://github.com/sntran/tailwind.com/releases/download/$TAILWIND_TAG}

usage() {
    echo "usage: file_nifs.sh names | dir NAME | fetch NAME OUT" >&2
    exit 2
}

dir_of() {
    case $1 in
        tailwind) echo "tailwind-${TAILWIND_TAG#v}" ;;
        *) echo "file_nifs.sh: no NIF files of $1" >&2
           exit 1 ;;
    esac
}

sha256() {
    if command -v sha256sum > /dev/null; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# get URL FILE SHA256: download URL to FILE, and check its SHA-256.
get() {
    curl -fsSL --retry 3 -o "$2" "$1"
    sum=$(sha256 "$2")
    if [ "$sum" != "$3" ]; then
        echo "file_nifs.sh: $1 has the SHA-256 $sum, not $3" >&2
        rm -f "$2"
        exit 1
    fi
}

fetch_tailwind() {
    d=$1/nifs/$(dir_of tailwind)
    rm -rf "$d"
    mkdir -p "$d/native"
    get "$TAILWIND_URL/libtailwind_nif.x86_64.o" "$d/native/libtailwind_nif.x86_64.o" \
        "$TAILWIND_X86_64_SHA256"
    get "$TAILWIND_URL/libtailwind_nif.aarch64.o" "$d/native/libtailwind_nif.aarch64.o" \
        "$TAILWIND_AARCH64_SHA256"
    printf 'git https://github.com/sntran/tailwind.com commit=%s tag=%s\n' \
        "$TAILWIND_COMMIT" "$TAILWIND_TAG" > "$d/SOURCE"
}

[ $# -ge 1 ] || usage
case $1 in
    names)
        [ $# -eq 1 ] || usage
        echo tailwind ;;
    dir)
        [ $# -eq 2 ] || usage
        dir_of "$2" ;;
    fetch)
        [ $# -eq 3 ] || usage
        dir=$(dir_of "$2")
        case $2 in
            tailwind) fetch_tailwind "$3" ;;
        esac
        echo "$2 lib/beam_com/priv/nifs/$dir/=nifs/$dir" ;;
    *)
        usage ;;
esac
