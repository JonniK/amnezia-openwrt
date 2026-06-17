#!/bin/sh
# amnezia-force-update: fetch enabled force_source lists, cache atomically,
# write force-update.json stamp, then call amnezia-force-load.
# Usage: amnezia-force-update
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
FORCE_UPDATE_LOCK="${FORCE_UPDATE_LOCK:-/var/lock/amnezia-force-update.lock}"

# Fall back to FORCE_DIR for the lock if /var/lock is not writable.
_upd_lock_dir="$(dirname "$FORCE_UPDATE_LOCK")"
if ! mkdir -p "$_upd_lock_dir" 2>/dev/null && [ ! -d "$_upd_lock_dir" ]; then
  FORCE_UPDATE_LOCK="$FORCE_DIR/amnezia-force-update.lock"
fi

mkdir -p "$FORCE_DIR/force.d"

(
  # Acquire exclusive lock.
  # shellcheck disable=SC2094
  exec 9>"$FORCE_UPDATE_LOCK"
  flock -x 9 2>/dev/null || true

  # Build JSON stamp incrementally.
  _ts=$(date +%s 2>/dev/null || echo 0)
  _stamp_entries=""
  _any_failed=0

  # Parse enabled force_source sections from UCI.
  # uci show amnezia emits lines like:
  #   amnezia.<name>=force_source
  #   amnezia.<name>.enabled=1
  #   amnezia.<name>.url=https://...
  #   amnezia.<name>.kind=domains
  _sources=$(uci show amnezia 2>/dev/null | grep '=force_source$' | \
    sed 's/amnezia\.\([^=]*\)=force_source/\1/')

  for _name in $_sources; do
    _enabled=$(uci show amnezia 2>/dev/null | \
      grep "^amnezia\.${_name}\.enabled=" | \
      sed "s/amnezia\.${_name}\.enabled=//")
    [ "$_enabled" = "1" ] || continue

    _url=$(uci show amnezia 2>/dev/null | \
      grep "^amnezia\.${_name}\.url=" | \
      sed "s/amnezia\.${_name}\.url=//")
    [ -n "$_url" ] || continue

    _cache="$FORCE_DIR/force.d/${_name}.list"
    _tmp=$(mktemp 2>/dev/null || echo "/tmp/amz-upd-${_name}.$$")

    # Fetch into temp file. Use AMZ_FETCH if set (for test override).
    _fetch_ok=0
    if [ -n "${AMZ_FETCH:-}" ] && [ -f "$AMZ_FETCH" ]; then
      cp "$AMZ_FETCH" "$_tmp" && _fetch_ok=1
    else
      uclient-fetch -qO "$_tmp" "$_url" 2>/dev/null \
        || wget -qO "$_tmp" "$_url" 2>/dev/null \
        || curl -sLo "$_tmp" "$_url" 2>/dev/null \
        && _fetch_ok=1
    fi

    if [ "$_fetch_ok" = 1 ] && [ -s "$_tmp" ]; then
      # Atomic write: move temp into place.
      mv "$_tmp" "$_cache"
      _count=$(wc -l < "$_cache" 2>/dev/null | tr -d ' ' || echo 0)
      _status="ok"
    else
      rm -f "$_tmp"
      # Keep prior cache; mark failed in stamp.
      _count=$(wc -l < "$_cache" 2>/dev/null | tr -d ' ' || echo 0)
      _status="failed"
      _any_failed=1
      amz_log "force-update: fetch failed for $_name ($_url), keeping cache"
    fi

    # Accumulate JSON entry for this source.
    if [ -n "$_stamp_entries" ]; then
      _stamp_entries="${_stamp_entries},"
    fi
    _stamp_entries="${_stamp_entries}\"${_name}\":{\"status\":\"${_status}\",\"count\":${_count}}"
  done

  # Write force-update.json stamp.
  printf '{"ts":%s,"sources":{%s}}\n' "$_ts" "$_stamp_entries" \
    > "$FORCE_DIR/force-update.json"

  # Call force-load to merge+apply everything.
  ${AMNEZIA_FORCE_LOAD:-amnezia-force-load}
)
