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
  _any_ok=0

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

    _kind=$(uci show amnezia 2>/dev/null | \
      grep "^amnezia\.${_name}\.kind=" | \
      sed "s/amnezia\.${_name}\.kind=//")
    # Default to 'domains' if kind is unset.
    _kind="${_kind:-domains}"

    _cache="$FORCE_DIR/force.d/${_name}.list"
    # M1: mktemp on same filesystem as cache so mv is an atomic rename.
    _tmp=$(mktemp "$FORCE_DIR/force.d/.amz-upd-${_name}.XXXXXX" 2>/dev/null \
      || echo "$FORCE_DIR/force.d/amz-upd-${_name}.$$")

    # M3: wrap the fetch chain in an explicit if/then for clarity.
    _fetch_ok=0
    if [ -n "${AMZ_FETCH:-}" ] && [ -f "$AMZ_FETCH" ]; then
      if cp "$AMZ_FETCH" "$_tmp"; then
        _fetch_ok=1
      fi
    else
      if uclient-fetch -qO "$_tmp" "$_url" 2>/dev/null \
          || wget -qO "$_tmp" "$_url" 2>/dev/null \
          || curl -sLo "$_tmp" "$_url" 2>/dev/null; then
        _fetch_ok=1
      fi
    fi

    # H1: per-kind content validation.
    # After a successful fetch we validate the payload shape.
    # A 404 page ("<!DOCTYPE html>") or error body must not overwrite the cache.
    if [ "$_fetch_ok" = 1 ] && [ -s "$_tmp" ]; then
      _valid=1
      case "$_kind" in
        domains)
          # Count non-comment/non-blank lines and those that look like domains.
          _total=$(grep -v '^[[:space:]]*$' "$_tmp" | grep -v '^[[:space:]]*#' \
            | awk 'END{print NR}')
          if [ "${_total:-0}" -gt 0 ]; then
            _domain_lines=$(grep -v '^[[:space:]]*$' "$_tmp" \
              | grep -v '^[[:space:]]*#' \
              | grep -c '^[A-Za-z0-9_.-][A-Za-z0-9_.-]*\.[A-Za-z0-9-][A-Za-z0-9-]*$' \
              2>/dev/null || echo 0)
            # Majority (>50%) of content lines must match domain shape.
            # Use awk to avoid needing bc/expr for the comparison.
            _majority=$(awk -v t="$_total" -v d="$_domain_lines" \
              'BEGIN{ print (d * 2 > t) ? "ok" : "fail" }')
            [ "$_majority" = "ok" ] || _valid=0
          fi
          ;;
        cidr)
          # All non-comment/non-blank lines must be dotted-quad[/len].
          _total=$(grep -v '^[[:space:]]*$' "$_tmp" | grep -v '^[[:space:]]*#' \
            | awk 'END{print NR}')
          if [ "${_total:-0}" -gt 0 ]; then
            _cidr_lines=$(grep -v '^[[:space:]]*$' "$_tmp" \
              | grep -v '^[[:space:]]*#' \
              | grep -c '^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\(/[0-9][0-9]*\)\{0,1\}$' \
              2>/dev/null || echo 0)
            [ "$_cidr_lines" = "$_total" ] || _valid=0
          fi
          ;;
      esac
      _fetch_ok="$_valid"
      [ "$_valid" = 1 ] || \
        amz_log "force-update: content validation failed for $_name (kind=$_kind), keeping cache"
    fi

    if [ "$_fetch_ok" = 1 ] && [ -s "$_tmp" ]; then
      # Atomic write: move temp into place.
      mv "$_tmp" "$_cache"
      # L1: count lines with awk to avoid wc -l portability quirk (no trailing newline).
      _count=$(awk 'END{print NR}' "$_cache" 2>/dev/null || echo 0)
      _status="ok"
      _any_ok=$(( _any_ok + 1 ))
    else
      rm -f "$_tmp"
      # Keep prior cache; mark failed in stamp.
      _count=$(awk 'END{print NR}' "$_cache" 2>/dev/null || echo 0)
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

  # Warn when every enabled source failed: the cron "success" would otherwise
  # silently mask a dead upstream.  No behavior change — we still write the
  # stamp and call force-load (prior cached lists remain active, which is safe).
  if [ "$_any_ok" = "0" ] && [ "$_any_failed" != "0" ]; then
    amz_log "force-update: WARNING — all sources failed, no list materialized; allowlist unchanged (using prior cache if any)"
  fi

  # Write force-update.json stamp.
  printf '{"ts":%s,"sources":{%s}}\n' "$_ts" "$_stamp_entries" \
    > "$FORCE_DIR/force-update.json"

  # Call force-load to merge+apply everything.
  ${AMNEZIA_FORCE_LOAD:-amnezia-force-load}
)
