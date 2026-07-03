#!/bin/sh
# amnezia-force-warm: keep the amnezia_force4 nft set "hot" by periodically
# re-resolving the curated manual force-tunnel domains through the router's
# own dnsmasq (127.0.0.1). dnsmasq re-applies its nftset= directive on each
# reply, so the domains' current IPs (incl. rotating CDN IPs) stay in force4
# before any client needs them -- fixing the cold-start (post-boot/reload)
# and IP-rotation windows in direct-default mode. No fw4 reload, no state
# mutation: it only triggers DNS resolutions.
# Usage: amnezia-force-warm
# shellcheck source=lib/amnezia-common.sh
AMNEZIA_LIB=${AMNEZIA_LIB:-/usr/lib/amnezia}
if [ -f "$AMNEZIA_LIB/amnezia-common.sh" ]; then
  # shellcheck disable=SC1091
  . "$AMNEZIA_LIB/amnezia-common.sh"
else
  # shellcheck disable=SC1091
  . "$(dirname "$0")/lib/amnezia-common.sh"
fi

FORCE_DIR="${FORCE_DIR:-/etc/amnezia}"
WARM_RESOLVER="${WARM_RESOLVER:-127.0.0.1}"
FORCE_WARM_LOCK="${FORCE_WARM_LOCK:-/var/lock/amnezia-force-warm.lock}"

# Fall back to FORCE_DIR for the lock if /var/lock is not writable.
_wrm_lock_dir="$(dirname "$FORCE_WARM_LOCK")"
if ! mkdir -p "$_wrm_lock_dir" 2>/dev/null && [ ! -d "$_wrm_lock_dir" ]; then
  FORCE_WARM_LOCK="$FORCE_DIR/amnezia-force-warm.lock"
fi

# Master gate: skip entirely when amnezia is globally disabled.
if command -v amz_master_enabled >/dev/null 2>&1; then
  amz_master_enabled || exit 0
fi

# Nothing to warm if the manual force list is absent.
[ -f "$FORCE_DIR/force-tunnel.list" ] || exit 0

# Non-blocking flock: if a previous cron tick is still running, skip this one.
# If flock is unavailable (e.g. macOS test environment), proceed without locking.
exec 7>"$FORCE_WARM_LOCK"
if command -v flock >/dev/null 2>&1; then
  flock -n 7 2>/dev/null || exit 0
fi

FORCE_WARM_WAVE="${FORCE_WARM_WAVE:-10}"   # max concurrent nslookup processes per wave

_n=0
_wave=0
while IFS= read -r _line; do
  # Strip inline comments (everything from # onward).
  _entry="${_line%%#*}"
  # Strip all whitespace.
  _entry=$(printf '%s' "$_entry" | tr -d ' \t\r')
  # Skip blank lines and lines that were pure comments.
  [ -n "$_entry" ] || continue
  # Skip pure IP/CIDR entries (only digits, dots, slashes).
  # An entry containing any character outside [0-9./] is a domain.
  case "$_entry" in
    *[!0-9./]*) ;;   # has non-numeric char -> domain, fall through
    *) continue ;;   # pure digits/dots/slashes -> IP or CIDR, skip
  esac
  # Trigger dnsmasq to re-resolve (and re-apply its nftset= directive).
  # BusyBox nslookup does NOT accept -timeout or host#port; use external timeout only.
  timeout 5 nslookup "$_entry" "$WARM_RESOLVER" >/dev/null 2>&1 &
  _n=$((_n + 1))
  _wave=$((_wave + 1))
  # Bound parallelism: flush each completed wave before starting the next.
  if [ "$_wave" -ge "$FORCE_WARM_WAVE" ]; then
    wait
    _wave=0
  fi
done < "$FORCE_DIR/force-tunnel.list"

# Wait for the last (partial) wave to finish.
wait

amz_log "force-warm: re-resolved $_n domain(s) via $WARM_RESOLVER"
