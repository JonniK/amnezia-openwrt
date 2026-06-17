#!/bin/sh
# Emits the monitor state JSON. With --emit-empty, prints a valid empty doc (for tests/boot).
if [ -f /usr/lib/amnezia/amnezia-common.sh ]; then
  # shellcheck disable=SC1091
  . /usr/lib/amnezia/amnezia-common.sh
else
  # shellcheck disable=SC1091
  . "$(dirname "$0")/lib/amnezia-common.sh"
fi
emit_empty() {
  cat <<'JSON'
{"mode":"failover","routing_mode":"tunnel-default","active_pool":null,"active_sticky":null,"all_down":true,"sources":{"itdoginfo_inside":true,"itdoginfo_services":true,"refilter_domains":false,"refilter_ip":false,"antifilter":false},"tunnels":[]}
JSON
}
case "$1" in
  --emit-empty) emit_empty ;;
  *)
    if [ -f "$STATE_FILE" ]; then
      cat "$STATE_FILE"
    else
      emit_empty
    fi ;;
esac
