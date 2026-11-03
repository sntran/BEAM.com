#!/bin/sh
# Send a command to the remote shell (scripts/remote_shell.sh) and print
# its output: scripts/remote_shell_send.sh BRANCH FILE. FILE holds the
# commands for bash; the word "stop" ends the shell. The branch BRANCH
# then holds one commit with no parent, with FILE as cmd.sh.
set -eu
branch=$1 file=$2
want=$( (sha256sum "$file" 2>/dev/null || shasum -a 256 "$file") | cut -d' ' -f1)
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-remote shell}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-remote-shell@users.noreply.github.com}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
blob=$(git hash-object -w "$file")
tree=$(printf '100644 blob %s\tcmd.sh\n' "$blob" | git mktree)
commit=$(echo "Remote shell: command $want" | git commit-tree "$tree")
git push -q -f origin "$commit:refs/heads/$branch"
[ "$(tr -d ' \r\n' < "$file")" = stop ] && exit 0
# The output names the SHA-256 of its command. Wait at most 20 minutes.
i=0
while [ "$i" -lt 240 ]; do
    if git fetch -q origin "+refs/heads/$branch-out:refs/remote-shell/out" 2>/dev/null &&
       git show refs/remote-shell/out:out.txt 2>/dev/null | grep -q "^--- command $want:"; then
        git show refs/remote-shell/out:out.txt
        exit 0
    fi
    sleep 5
    i=$((i + 1))
done
echo "remote_shell_send: no output for $want on $branch-out" >&2
exit 1
