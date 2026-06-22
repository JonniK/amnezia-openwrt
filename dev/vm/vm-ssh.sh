#!/bin/sh
# Run a command in the VM over SSH, or push a file using cat-pipe.
#
# Usage:
#   vm-ssh.sh '<remote sh command>'
#   vm-ssh.sh --push <localfile> <remotepath>
#
# NOTE: Dropbear (OpenWrt's SSH server) has NO sftp/scp subsystem.
#       File transfer MUST use the cat-pipe idiom:
#         cat localfile | ssh ... 'cat > remotepath'
#       This script implements exactly that for --push.
#
# POSIX sh; runs on the macOS host. Sources lib.sh for SSH opts.

set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

_usage() {
  echo "Usage: vm-ssh.sh '<remote command>'" >&2
  echo "       vm-ssh.sh --push <localfile> <remotepath>" >&2
  exit 2
}

[ $# -ge 1 ] || _usage

case "$1" in
  --push)
    [ $# -eq 3 ] || { echo "vm-ssh.sh --push: expected <localfile> <remotepath>" >&2; _usage; }
    _local="$2"
    _remote="$3"
    [ -f "$_local" ] || { echo "vm-ssh.sh --push: local file not found: $_local" >&2; exit 1; }
    # cat-pipe: the only reliable file transfer with dropbear (no sftp/scp).
    # shellcheck disable=SC2086
    cat "$_local" | ssh $VM_SSH_OPTS "root@$SSH_HOST" "cat > '$_remote'"
    ;;
  *)
    # Run a remote command.
    # shellcheck disable=SC2086
    ssh $VM_SSH_OPTS "root@$SSH_HOST" "$1"
    ;;
esac
