#!/bin/sh
# The runner part of .github/workflows/remote-ssh.yml: an SSH server of
# Erlang :ssh (scripts/remote_ssh.erl), a quick tunnel of Cloudflare to
# its WebSocket, and the branch $BRANCH with the files url and
# fingerprint, so that scripts/remote_ssh_client.sh can find the server.
# The branch holds one commit with no parent, and this script deletes it
# at its end.
#
# Environment: BRANCH, KEYS (a file in the format of authorized_keys),
# MINUTES, WORK, PROBE_TRIES (60), and ERL_MODE: beam.com (with BEAM_COM, the path of
# beam.com) or erl (an OTP on the PATH, for Windows).
set -u
: "${BRANCH:?}" "${KEYS:?}" "${MINUTES:=60}" "${ERL_MODE:=beam.com}" "${PROBE_TRIES:=60}"
[ "$MINUTES" -gt 120 ] && MINUTES=120
TMP=${RUNNER_TEMP:-/tmp}
WORK=${WORK:-$TMP/work}
PORT=${REMOTE_SSH_PORT:-8022}
mkdir -p "$TMP" "$WORK"
repo=$(pwd)
log=$TMP/remote_ssh.log
tunnel_log=$TMP/cloudflared.log

# cloudflared 2026.10.7, with the SHA-256 of each file.
CF_VERSION=2026.10.7
cloudflared() {
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) f=cloudflared-linux-amd64
            s=1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872 ;;
        Linux-aarch64|Linux-arm64) f=cloudflared-linux-arm64
            s=3df43aedc9ff291d1735b5cb576cb97e0b157488796db2e32b28aecabb445775 ;;
        Darwin-x86_64) f=cloudflared-darwin-amd64.tgz
            s=02f3edfd87684dd5b705607688e4eb4b323f6e777b81e7b3a85af556aa356848 ;;
        Darwin-arm64) f=cloudflared-darwin-arm64.tgz
            s=3586ccf397e98e5f437e60e7c307ca6ac463e110580503af8bb8e6f9ebf831bd ;;
        MINGW*-x86_64|MSYS*-x86_64) f=cloudflared-windows-amd64.exe
            s=2493dbc168923bb3e59e5e7716f71deced92992eea9acd6e9d74f84ac7751343 ;;
        *) echo "remote ssh: no cloudflared for $(uname -s) $(uname -m)" >&2; return 1 ;;
    esac
    curl -fsSL -o "$TMP/$f" \
        "https://github.com/cloudflare/cloudflared/releases/download/$CF_VERSION/$f" || return 1
    # From standard input: with a file name that has a backslash (Windows),
    # sha256sum puts a backslash before the hash.
    got=$( (sha256sum < "$TMP/$f" 2>/dev/null || shasum -a 256 < "$TMP/$f") | cut -d' ' -f1)
    if [ "$got" != "$s" ]; then
        echo "remote ssh: the SHA-256 of $f is $got, not $s" >&2
        return 1
    fi
    case $f in
        *.tgz) tar -xzf "$TMP/$f" -C "$TMP" cloudflared && CLOUDFLARED=$TMP/cloudflared ;;
        *.exe) CLOUDFLARED=$TMP/$f ;;
        *) chmod +x "$TMP/$f" && CLOUDFLARED=$TMP/$f ;;
    esac
}

export GIT_AUTHOR_NAME="remote ssh" GIT_AUTHOR_EMAIL="remote-ssh@users.noreply.github.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

server_pid= tunnel_pid=
cleanup() {
    [ -n "$tunnel_pid" ] && kill "$tunnel_pid" 2>/dev/null
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null
    git push -q origin --delete "$BRANCH" 2>/dev/null
    echo "remote ssh: the branch $BRANCH is deleted"
}
trap cleanup EXIT

# Wait at most $2 seconds for the pattern $1 in the file $3, while the
# process $4 runs.
wait_for() {
    n=0
    while [ $n -lt $(( $2 * 5 )) ]; do
        m=$(grep -E -o "$1" "$3" 2>/dev/null | head -n 1)
        if [ -n "$m" ]; then echo "$m"; return 0; fi
        kill -0 "$4" 2>/dev/null || return 1
        sleep 0.2
        n=$((n + 1))
    done
    return 1
}

export REMOTE_SSH_MINUTES=$MINUTES REMOTE_SSH_PORT=$PORT
case $ERL_MODE in
    beam.com)
        sh "${BEAM_COM:?}" -a ssh "$repo/scripts/remote_ssh.erl" -- \
            serve "$KEYS" "$WORK" > "$log" 2>&1 &
        server_pid=$! ;;
    erl)
        erlc -o "$TMP" "$repo/scripts/remote_ssh.erl" || exit 1
        erl -noshell -pa "$TMP" -run remote_ssh main serve "$KEYS" "$WORK" > "$log" 2>&1 &
        server_pid=$! ;;
esac
if ! fp=$(wait_for 'SHA256:[A-Za-z0-9+/=]+' 300 "$log" "$server_pid"); then
    cat "$log"
    echo "remote ssh: the server did not start" >&2
    exit 1
fi
cat "$log"

# CLOUDFLARED: a cloudflared that is there already, for a test.
[ -n "${CLOUDFLARED:-}" ] || cloudflared || exit 1
"$CLOUDFLARED" tunnel --no-autoupdate --url "http://127.0.0.1:$PORT" > "$tunnel_log" 2>&1 &
tunnel_pid=$!
if ! host=$(wait_for '[a-z0-9-]+\.trycloudflare\.com' 120 "$tunnel_log" "$tunnel_pid"); then
    cat "$tunnel_log"
    echo "remote ssh: the tunnel did not start" >&2
    exit 1
fi
# The name of the tunnel needs some seconds in DNS. The server answers
# 400 to a request that is not a WebSocket.
n=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' "https://$host/")" = 400 ]; do
    n=$((n + 1))
    if [ $n -ge "$PROBE_TRIES" ]; then
        echo "remote ssh: https://$host/ does not answer" >&2
        break
    fi
    sleep 2
done

printf 'wss://%s/\n' "$host" > "$TMP/url"
printf '%s\n' "$fp" > "$TMP/fingerprint"
tree=$(printf '100644 blob %s\turl\n100644 blob %s\tfingerprint\n' \
    "$(git hash-object -w "$TMP/url")" "$(git hash-object -w "$TMP/fingerprint")" | git mktree)
commit=$(echo "Remote SSH: wss://$host/" | git commit-tree "$tree")
git push -q -f origin "$commit:refs/heads/$BRANCH" || exit 1
echo "remote ssh: wss://$host/ $fp, for $MINUTES minutes"
echo "remote ssh: scripts/remote_ssh_client.sh $BRANCH KEY exec 'uname -a'"

wait "$server_pid"
server_pid=
tail -n 1 "$log"
