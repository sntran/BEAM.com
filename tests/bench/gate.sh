#!/bin/sh
# The performance gate: compare the benchmarks of a new beam.com with
# those of a base beam.com (in CI, the edge build of main), on the same
# machine at the same time.
#
#   tests/bench/gate.sh NEW BASE [CASE...]
#
# The script builds tests/bench/bench.erl with each file. Then it runs the
# two programs in turns, ROUNDS times (default 5), and keeps the best time
# of each case for each file. The start time of a program is also a case.
# Without CASE, all the cases run.
#
# The gate fails when:
#
# - a case of NEW is more than LIMIT percent (default 20) slower than
#   BASE, and also more than SLACK ms (default 5) slower;
# - the geometric mean of the ratios NEW / BASE is more than MEAN percent
#   (default 10) above 1;
# - the file NEW is more than SIZE percent (default 10) larger than BASE.
#
# The result is a Markdown table on standard output. RUNNER is the command
# that starts an APE file, as for tests/run.sh.
set -u
[ $# -ge 2 ] || { echo "usage: $0 NEW BASE [CASE...]" >&2; exit 2; }
new=$1 base=$2
shift 2
rounds=${ROUNDS:-5} limit=${LIMIT:-20} slack=${SLACK:-5} mean=${MEAN:-10} size=${SIZE:-10}
runner=${RUNNER:-sh}
[ "$runner" = sh ] || chmod +x "$runner"
runner_path=$(command -v "$runner")
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

for v in new base; do
    eval "file=\$$v"
    chmod +x "$file"
    $runner "$file" tests/bench/bench.erl -o "$out/$v.com" > /dev/null || exit 2
    chmod +x "$out/$v.com"
    wc -c < "$file" | tr -d ' ' > "$out/$v.size"
done

# The two programs run in turns, and the first one changes each round, so
# that a slow period of the machine falls on both.
measure() {
    v=$1
    shift
    $runner "$out/$v.com" "$@" > "$out/run.log" 2>&1 || {
        cat "$out/run.log" >&2
        exit 2
    }
    sed -n 's/^bench //p' "$out/run.log" >> "$out/$v.times"
    $runner "$out/$v.com" start "$runner_path" "$out/$v.com" none |
        sed -n 's/^start /start_program /p' >> "$out/$v.times"
}
r=1
while [ "$r" -le "$rounds" ]; do
    if [ $((r % 2)) = 1 ]; then measure new "$@"; measure base "$@"; else measure base "$@"; measure new "$@"; fi
    r=$((r + 1))
done

awk -v limit="$limit" -v slack="$slack" -v mean="$mean" -v size="$size" \
    -v new_size="$(cat "$out/new.size")" -v base_size="$(cat "$out/base.size")" '
    FILENAME ~ /new.times$/ { if (!($1 in n) || $2 < n[$1]) n[$1] = $2; if (!($1 in seen)) { seen[$1] = 1; order[++count] = $1 } }
    FILENAME ~ /base.times$/ { if (!($1 in b) || $2 < b[$1]) b[$1] = $2 }
    END {
        fails = 0
        print "| case | base (ms) | new (ms) | new / base | |"
        print "|---|---:|---:|---:|---|"
        for (i = 1; i <= count; i++) {
            k = order[i]
            if (!(k in b)) { print "| " k " | | " n[k] " | | not in base |"; continue }
            ratio = (n[k] < 1 ? 1 : n[k]) / (b[k] < 1 ? 1 : b[k])
            logsum += log(ratio); cases++
            mark = ""
            if (ratio > 1 + limit / 100 && n[k] - b[k] > slack) { mark = "SLOWER"; fails++ }
            printf "| %s | %d | %d | %.2f | %s |\n", k, b[k], n[k], ratio, mark
        }
        g = cases ? exp(logsum / cases) : 1
        gmark = g > 1 + mean / 100 ? "SLOWER" : ""
        if (gmark != "") fails++
        printf "| geometric mean | | | %.2f | %s |\n", g, gmark
        sratio = new_size / base_size
        smark = sratio > 1 + size / 100 ? "LARGER" : ""
        if (smark != "") fails++
        printf "| file size (MB) | %.1f | %.1f | %.2f | %s |\n", base_size / 1048576, new_size / 1048576, sratio, smark
        print ""
        if (fails) {
            printf "The gate fails: %d results are over the limits (a case: %d%% and %d ms, the mean: %d%%, the size: %d%%).\n", fails, limit, slack, mean, size
            exit 1
        }
        printf "The gate passes (limits: a case %d%% and %d ms, the mean %d%%, the size %d%%).\n", limit, slack, mean, size
    }' "$out/new.times" "$out/base.times"
