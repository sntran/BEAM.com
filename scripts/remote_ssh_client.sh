#!/bin/sh
# The client of .github/workflows/remote-ssh.yml. It reads the URL and the
# fingerprint of the server from the branch BRANCH, and starts
# scripts/remote_ssh.erl with beam.com ($BEAM_COM, else beam.com on the
# PATH):
#
#   remote_ssh_client.sh BRANCH KEY exec 'CMD'
#   remote_ssh_client.sh BRANCH KEY put LOCAL REMOTE
#   remote_ssh_client.sh BRANCH KEY get REMOTE LOCAL
#   remote_ssh_client.sh BRANCH - bridge PORT    # then: ssh -p PORT runner@127.0.0.1
#
# KEY is a file of "remote_ssh.erl keygen". The bridge needs no KEY,
# because OpenSSH uses its own key.
set -eu
[ $# -ge 4 ] || { sed -n '2,12p' "$0" >&2; exit 2; }
BRANCH=$1 KEY=$2 MODE=$3
shift 3
dir=$(cd "$(dirname "$0")" && pwd)
git fetch -q origin "+refs/heads/$BRANCH:refs/remote-ssh/info"
url=$(git show refs/remote-ssh/info:url)
fp=$(git show refs/remote-ssh/info:fingerprint)
case $MODE in
    bridge) exec "${BEAM_COM:-beam.com}" -a ssh "$dir/remote_ssh.erl" -- bridge "$url" "$@" ;;
    *) exec "${BEAM_COM:-beam.com}" -a ssh "$dir/remote_ssh.erl" -- "$MODE" "$url" "$KEY" "$fp" "$@" ;;
esac
