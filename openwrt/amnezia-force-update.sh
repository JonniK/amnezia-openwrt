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
  # The TYPE line (amnezia.<name>=force_source) is unquoted in uci show output
  # and safe to grep.  Option values are single-quoted by real OpenWrt uci show
  # (amnezia.<name>.enabled='1'), so use uci -q get for per-option reads to get
  # the raw unquoted value regardless of uci version.
  _sources=$(uci show amnezia 2>/dev/null | grep '=force_source$' | \
    sed 's/amnezia\.\([^=]*\)=force_source/\1/')

  for _name in $_sources; do
    _enabled=$(uci -q get "amnezia.${_name}.enabled")
    [ "$_enabled" = "1" ] || continue

    _kind=$(uci -q get "amnezia.${_name}.kind")
    # Default to 'domains' if kind is unset.
    _kind="${_kind:-domains}"

    _cache="$FORCE_DIR/force.d/${_name}.list"
    # M1: mktemp on same filesystem as cache so mv is an atomic rename.
    _tmp=$(mktemp "$FORCE_DIR/force.d/.amz-upd-${_name}.XXXXXX" 2>/dev/null \
      || echo "$FORCE_DIR/force.d/amz-upd-${_name}.$$")

    # M3: wrap the fetch chain in an explicit if/then for clarity.
    _fetch_ok=0

    case "$_kind" in
      # ----------------------------------------------------------------
      # static: materialize from inline UCI list option (no URL fetch).
      # ----------------------------------------------------------------
      static)
        # uci -q get for a list returns all values space-separated on one line.
        _cidrs=$(uci -q get "amnezia.${_name}.cidr" 2>/dev/null || echo "")
        if [ -n "$_cidrs" ]; then
          # Write each CIDR on its own line into the temp file.
          for _c in $_cidrs; do
            printf '%s\n' "$_c"
          done > "$_tmp"
          _fetch_ok=1
        else
          amz_log "force-update: static source $_name has no cidr entries"
        fi
        ;;
      # ----------------------------------------------------------------
      # as: fetch IPv4 prefixes from RIPEstat announced-prefixes API.
      # ----------------------------------------------------------------
      as)
        _asn=$(uci -q get "amnezia.${_name}.asn" 2>/dev/null || echo "")
        if [ -z "$_asn" ]; then
          amz_log "force-update: as source $_name has no asn option"
        else
          _ripe_url="https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${_asn}"
          _tdev=$(amz_tunnel_dev)
          _ripe_tmp=$(mktemp "$FORCE_DIR/force.d/.amz-ripe-${_name}.XXXXXX" 2>/dev/null \
            || echo "$FORCE_DIR/force.d/amz-ripe-${_name}.$$")
          _ripe_ok=0
          if [ -n "${AMZ_FETCH:-}" ] && [ -f "$AMZ_FETCH" ]; then
            if cp "$AMZ_FETCH" "$_ripe_tmp"; then _ripe_ok=1; fi
          elif [ -n "$_tdev" ] && command -v curl >/dev/null 2>&1 \
              && curl --interface "if!$_tdev" -fsSL --connect-timeout 10 --max-time 60 \
                      -o "$_ripe_tmp" "$_ripe_url" 2>/dev/null; then
            _ripe_ok=1
          elif curl -fsSL --connect-timeout 10 --max-time 60 \
                    -o "$_ripe_tmp" "$_ripe_url" 2>/dev/null; then
            _ripe_ok=1
          fi
          if [ "$_ripe_ok" = 1 ] && [ -s "$_ripe_tmp" ]; then
            # Extract IPv4 prefixes from the JSON (field by field, no jq required).
            tr '{},"' '\n' < "$_ripe_tmp" \
              | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
              | sort -u > "$_tmp"
            _fetch_ok=1
          fi
          rm -f "$_ripe_tmp"
        fi
        ;;
      # ----------------------------------------------------------------
      # url-based kinds (domains / cidr): original fetch logic.
      # ----------------------------------------------------------------
      *)
        _url=$(uci -q get "amnezia.${_name}.url" 2>/dev/null || echo "")
        if [ -z "$_url" ]; then
          amz_log "force-update: source $_name (kind=$_kind) has no url, skipping"
        else
          if [ -n "${AMZ_FETCH:-}" ] && [ -f "$AMZ_FETCH" ]; then
            if cp "$AMZ_FETCH" "$_tmp"; then
              _fetch_ok=1
            fi
          else
            # Router-origin fetches are NOT marked by the prerouting classifier, so by
            # default they egress WAN *directly* — exactly where RKN throttling stalls
            # GitHub-raw / antifilter, the fetch hangs, and the synchronous rpcd call
            # outlives the LuCI XHR timeout ("XHR request timed out"). Bind the fetch to
            # the active tunnel device (SO_BINDTODEVICE) so it egresses the tunnel
            # regardless of destination IP — immune to GitHub/Fastly CDN IP-rotation,
            # with no routing/firewall state to install or tear down. Bounded timeouts
            # turn a dead path into a fast, clean failure (cache kept) instead of a hang.
            _tdev=$(amz_tunnel_dev)
            if [ -n "$_tdev" ] && command -v curl >/dev/null 2>&1 \
                && curl --interface "if!$_tdev" -fsSL --connect-timeout 10 --max-time 120 \
                        -o "$_tmp" "$_url" 2>/dev/null; then
              _fetch_ok=1
            # Direct-egress fallbacks (bounded). Reached only when no tunnel is up or the
            # tunneled fetch failed; for RKN-blocked sources these usually fail too, but
            # they fail fast and the prior cache is preserved.
            elif uclient-fetch -T 20 -qO "$_tmp" "$_url" 2>/dev/null \
                || wget -T 20 -qO "$_tmp" "$_url" 2>/dev/null \
                || curl -fsSL --connect-timeout 10 --max-time 120 -o "$_tmp" "$_url" 2>/dev/null; then
              _fetch_ok=1
            fi
          fi
        fi
        ;;
    esac

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
        cidr|static|as)
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
      amz_log "force-update: fetch/materialize failed for $_name (kind=$_kind), keeping cache"
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

  # Call force-load to merge+apply everything.  Pass --flush so that entries
  # removed from upstream lists are actually evicted from the nft set (user
  # or cron triggered a full list refresh, so a one-shot resync blip is
  # acceptable; runtime dnsmasq-resolved IPs will be re-warmed on next query).
  ${AMNEZIA_FORCE_LOAD:-amnezia-force-load} --flush
)
