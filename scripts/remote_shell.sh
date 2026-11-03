#!/bin/sh
# A shell on a runner of CI, for tests and debugging on a system that a
# person does not have (.github/workflows/remote-shell.yml). The commands
# come through two branches of this repository, and each one always holds
# one commit with no parent, so no history grows:
#
# - $BRANCH: a person force-pushes a commit with the file cmd.sh
#   (scripts/remote_shell_send.sh does it).
# - $BRANCH-out: this script force-pushes a commit with out.txt, the
#   output of the last command, with its exit status and the SHA-256 of
#   the command.
#
# It runs each new cmd.sh with bash in $WORK, which stays for the next
# command, with a limit of $COMMAND_SECONDS seconds. It stops after
# $MINUTES minutes, or for a cmd.sh that is only the word "stop". At the
# end it deletes the two branches. It checks $BRANCH each 5 seconds.
set -u
: "${BRANCH:?}" "${MINUTES:=60}" "${COMMAND_SECONDS:=900}"
# The job has a limit of 125 minutes.
[ "$MINUTES" -gt 120 ] && MINUTES=120
WORK=${WORK:-${RUNNER_TEMP:-/tmp}/work}
mkdir -p "$WORK"
repo=$(pwd)
export GIT_AUTHOR_NAME="remote shell" GIT_AUTHOR_EMAIL="remote-shell@users.noreply.github.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

sha() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1; }

# A commit with no parent that holds the file $1 as $2.
orphan() {
    blob=$(git hash-object -w "$1")
    tree=$(printf '100644 blob %s\t%s\n' "$blob" "$2" | git mktree)
    echo "$3" | git commit-tree "$tree"
}

cleanup() {
    git push -q origin --delete "$BRANCH" "$BRANCH-out" 2>/dev/null
    echo "remote shell: the branches $BRANCH and $BRANCH-out are deleted"
}
trap cleanup EXIT

printf 'The remote shell waits for commands.\n' > "$WORK/.out.txt"
git push -q -f origin "$(orphan "$WORK/.out.txt" out.txt "Remote shell: ready"):refs/heads/$BRANCH-out"

last=
end=$(( $(date +%s) + MINUTES * 60 ))
echo "remote shell: $(uname -a), for $MINUTES minutes"
while [ "$(date +%s)" -lt "$end" ]; do
    if git fetch -q origin "+refs/heads/$BRANCH:refs/remote-shell/cmd" 2>/dev/null &&
       git show refs/remote-shell/cmd:cmd.sh > "$WORK/.cmd.sh" 2>/dev/null &&
       [ "$(sha "$WORK/.cmd.sh")" != "$last" ]; then
        last=$(sha "$WORK/.cmd.sh")
        if [ "$(tr -d ' \r\n' < "$WORK/.cmd.sh")" = stop ]; then
            echo "remote shell: stop"
            break
        fi
        echo "remote shell: running $last"
        start=$(date +%s)
        # perl gives the limit of time: macOS has no timeout(1).
        (cd "$WORK" && REPO=$repo perl -e 'alarm shift; exec @ARGV' \
            "$COMMAND_SECONDS" bash .cmd.sh) > "$WORK/.out.txt" 2>&1 < /dev/null
        status=$?
        printf '\n--- command %s: exit %s after %s s\n' "$last" "$status" \
            "$(( $(date +%s) - start ))" >> "$WORK/.out.txt"
        git push -q -f origin \
            "$(orphan "$WORK/.out.txt" out.txt "Remote shell: output of $last"):refs/heads/$BRANCH-out" ||
            echo "remote shell: the output of $last did not reach $BRANCH-out" >&2
    fi
    sleep 5
done
