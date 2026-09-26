#!/bin/sh
# Benchmarks of BEAM.com: file sizes, start times, and the workloads of
# tests/bench/bench.erl, for each variant in DIR (beam.com, beam-jit.com).
# The result is a Markdown table on standard output.
#
# Usage: tests/bench/run.sh DIR   (from the top of the repository)
#
# RUNNER is the command that starts an APE file, as for tests/run.sh.
# The numbers are for comparing variants on the same machine; CI machines
# are shared, so expect some noise between runs.
set -u
dir=${1:-.}
runner=${RUNNER:-sh}
out=${TMPDIR:-/tmp}/beam_com_bench.$$
mkdir -p "$out"
[ "$runner" = sh ] || chmod +x "$runner"
runner_path=$(command -v "$runner")

variants=
for v in beam.com beam-jit.com; do
    [ -f "$dir/$v" ] && variants="$variants $v"
done

for v in $variants; do
    chmod +x "$dir/$v"
    prog="$dir/bench.${v%.com}.com"
    $runner "$dir/$v" build tests/bench/bench.erl -o "$prog" > /dev/null || exit 1
    chmod +x "$prog"
    {
        echo "size_mb $(wc -c < "$dir/$v" | awk '{printf "%.1f", $1 / 1048576}')"
        echo "program_mb $(wc -c < "$prog" | awk '{printf "%.1f", $1 / 1048576}')"
        $runner "$prog" start "$runner_path" "$dir/$v" version | sed 's/^start/start_version/'
        $runner "$prog" start "$runner_path" "$prog" none | sed 's/^start/start_program/'
        $runner "$prog" | sed 's/^bench //'
    } > "$out/$v" 2>&1
done

# The table: one row for each measure, one column for each variant.
label() {
    case $1 in
        size_mb) echo "file size (MB)" ;;
        program_mb) echo "size of a program (MB)" ;;
        start_version) echo "start: \`version\` (ms)" ;;
        start_program) echo "start: a program (ms)" ;;
        *) echo "$1 (ms)" ;;
    esac
}
printf '| |'
for v in $variants; do printf ' %s |' "$v"; done
printf '\n|---|'
for v in $variants; do printf -- '---:|'; done
printf '\n'
first=$(echo $variants | awk '{print $1}')
for key in $(awk '{print $1}' "$out/$first"); do
    printf '| %s |' "$(label "$key")"
    for v in $variants; do
        printf ' %s |' "$(awk -v k="$key" '$1 == k {print $2}' "$out/$v")"
    done
    printf '\n'
done
rm -rf "$out"
