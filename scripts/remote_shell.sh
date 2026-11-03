#!/bin/sh
# A shell on a runner of CI, for tests and debugging on a system that a
# person does not have (.github/workflows/remote-shell.yml). The commands
# come through the branch $BRANCH of this repository:
#
# - A person pushes the file cmd.sh to $BRANCH.
# - This script runs each new cmd.sh with bash in $WORK, which stays for
#   the next command, with a limit of $COMMAND_SECONDS seconds.
# - It pushes the output to out.txt on $BRANCH, with the exit status and
#   the SHA-256 of the command.
# - It stops after $MINUTES minutes, or when $BRANCH has the file stop.
#
# The runner checks the branch each 10 seconds.
set -u
: "${BRANCH:?}" "${MINUTES:=60}" "${COMMAND_SECONDS:=900}"
# The job has a limit of 125 minutes.
[ "$MINUTES" -gt 120 ] && MINUTES=120
WORK=${WORK:-${RUNNER_TEMP:-/tmp}/work}
mkdir -p "$WORK"
repo=$(pwd)
git config user.name "remote shell"
git config user.email "remote-shell@users.noreply.github.com"

sha() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1; }

# The branch, with a README when it does not exist yet.
if ! git fetch -q origin "$BRANCH" 2>/dev/null; then
    git checkout -q --orphan shell
    git rm -q -rf . >/dev/null 2>&1
    printf 'Commands for the remote shell (scripts/remote_shell.sh).\n' > README
    git add README
    git commit -q -m "Remote shell: the branch of the commands"
    git push -q origin "HEAD:$BRANCH"
fi

# The output of a command: out.txt on the branch. A push that loses a race
# with a new command takes the branch again and tries again.
publish() {
    for try in 1 2 3 4 5; do
        git fetch -q origin "$BRANCH" && git checkout -q -B shell FETCH_HEAD
        cp "$WORK/.out.txt" out.txt
        git add out.txt
        git commit -q -m "Remote shell: output of $1" || return 0
        git push -q origin "HEAD:$BRANCH" && return 0
        sleep "$try"
    done
    echo "remote shell: the output of $1 did not reach $BRANCH" >&2
}

last=
end=$(( $(date +%s) + MINUTES * 60 ))
echo "remote shell: $(uname -a), until $(date -u -d "@$end" 2>/dev/null || date -u -r "$end")"
while [ "$(date +%s)" -lt "$end" ]; do
    if git fetch -q origin "$BRANCH" 2>/dev/null; then
        git checkout -q -B shell FETCH_HEAD
        [ -f stop ] && { echo "remote shell: stop"; break; }
        if [ -f cmd.sh ] && [ "$(sha cmd.sh)" != "$last" ]; then
            last=$(sha cmd.sh)
            cp cmd.sh "$WORK/.cmd.sh"
            echo "remote shell: running $last"
            start=$(date +%s)
            # perl gives the limit of time: macOS has no timeout(1).
            (cd "$WORK" && REPO=$repo perl -e 'alarm shift; exec @ARGV' \
                "$COMMAND_SECONDS" bash .cmd.sh) \
                > "$WORK/.out.txt" 2>&1 < /dev/null
            status=$?
            printf '\n--- command %s: exit %s after %s s\n' "$last" "$status" \
                "$(( $(date +%s) - start ))" >> "$WORK/.out.txt"
            publish "$last"
        fi
    fi
    sleep 10
done
