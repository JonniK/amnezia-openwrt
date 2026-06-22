#!/bin/sh
# Talk to the VM serial unix socket for first-boot provisioning (before SSH exists).
#
# Usage:
#   console.sh send '<line>'   -- write a command line + newline to the socket
#   console.sh read            -- dump current serial output (tail SERIAL_LOG)
#
# Transport: nc -U (macOS netcat supports unix sockets with -U).
# Fallback: socat (brew install socat).
# Fails with a clear message if neither tool is available.
#
# POSIX sh; runs on the macOS host. Sources lib.sh for paths.

set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

_usage() {
  echo "Usage: console.sh send '<command>'" >&2
  echo "       console.sh read" >&2
  exit 2
}

# Detect available transport.
# nc -U: macOS BSD netcat supports unix sockets via -U flag.
# socat: commonly available via brew (brew install socat).
_send_line() {
  _line="$1"
  # macOS BSD nc supports -U (unix socket) but NOT -q (Linux-only flag).
  # Use -w 1 (wait 1s for data then close) instead of -q 1.
  if command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q '\-U'; then
    printf '%s\n' "$_line" | nc -w 1 -U "$SERIAL_SOCK" 2>/dev/null && return 0
  fi
  if command -v socat >/dev/null 2>&1; then
    printf '%s\n' "$_line" | socat - "UNIX-CONNECT:${SERIAL_SOCK}" 2>/dev/null && return 0
  fi
  echo "ERROR: neither 'nc -U' nor 'socat' is available." >&2
  echo "       Install socat: brew install socat" >&2
  exit 1
}

# _send_raw: pipe stdin directly to the unix socket (no appended newline).
# Used by console_bootstrap to send a pre-built batch all in one nc invocation.
_send_raw() {
  if command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q '\-U'; then
    nc -w 2 -U "$SERIAL_SOCK" 2>/dev/null && return 0
  fi
  if command -v socat >/dev/null 2>&1; then
    socat - "UNIX-CONNECT:${SERIAL_SOCK}" 2>/dev/null && return 0
  fi
  echo "ERROR: neither 'nc -U' nor 'socat' is available." >&2
  exit 1
}

CMD="${1:-}"
[ -n "$CMD" ] || _usage

case "$CMD" in
  send)
    [ -n "${2:-}" ] || { echo "console.sh send: missing command line argument" >&2; _usage; }
    if [ ! -S "$SERIAL_SOCK" ]; then
      echo "ERROR: serial socket not found: $SERIAL_SOCK" >&2
      echo "       Is the VM running? (run-vm.sh &)" >&2
      exit 1
    fi
    _send_line "$2"
    ;;
  send-raw)
    # Read from stdin, pipe to socket as-is.
    if [ ! -S "$SERIAL_SOCK" ]; then
      echo "ERROR: serial socket not found: $SERIAL_SOCK" >&2
      exit 1
    fi
    _send_raw
    ;;
  read)
    # Dump current serial log if it exists; otherwise try to cat the socket once.
    if [ -f "$SERIAL_LOG" ]; then
      tail -n 80 "$SERIAL_LOG"
    elif [ -S "$SERIAL_SOCK" ]; then
      # FIRST_BOOT_TWEAK: socket cat may hang; Ctrl-C to interrupt.
      # On first boot before any data is written the log may be absent.
      if command -v socat >/dev/null 2>&1; then
        timeout 3 socat -u "UNIX-CONNECT:${SERIAL_SOCK}" - 2>/dev/null || true
      else
        echo "[console.sh] SERIAL_LOG not yet present and socat unavailable for raw read." >&2
        echo "             Try: brew install socat" >&2
      fi
    else
      echo "[console.sh] No serial log and no socket yet. VM may not be booted." >&2
      exit 1
    fi
    ;;
  *)
    echo "console.sh: unknown command '$CMD'" >&2
    _usage
    ;;
esac
