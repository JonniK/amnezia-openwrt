#!/bin/sh
# Emits the monitor state JSON. With --emit-empty, prints a valid empty doc (for tests/boot).
if [ -f /usr/lib/amnezia/amnezia-common.sh ]; then
  . /usr/lib/amnezia/amnezia-common.sh
else
  . "$(dirname "$0")/lib/amnezia-common.sh"
fi
emit_empty() {
  cat <<'JSON'
{"mode":"failover","active_pool":null,"active_sticky":null,"all_down":true,"tunnels":[]}
JSON
}
case "$1" in
  --emit-empty) emit_empty ;;
  *) [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || emit_empty ;;
esac
