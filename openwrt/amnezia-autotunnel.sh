#!/bin/sh
# amnezia-autotunnel: probe a domain and optionally add it to the manual
# force-tunnel list when it appears throttled on the direct path.
# Usage: amnezia-autotunnel probe  <domain>
#        amnezia-autotunnel add    <domain> [--force]
#        amnezia-autotunnel remove <domain>
#        amnezia-autotunnel auto          (one worker tick, run by cron)
#        amnezia-autotunnel enable        (install cron + dnsmasq snippet)
#        amnezia-autotunnel disable       (remove cron + snippet, keep added domains)
#        amnezia-autotunnel status        (JSON status one-liner)
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
RESOLVER="${RESOLVER:-127.0.0.1}"
CURL="${CURL:-curl}"
NSLOOKUP="${NSLOOKUP:-nslookup}"
NFT="${NFT:-nft}"
PROBE_MAXTIME="${PROBE_MAXTIME:-8}"
DNSMASQ_HUP="${DNSMASQ_HUP:-1}"

# ---------------------------------------------------------------------------
# Auto-worker configuration — all paths/commands are overridable for tests.
# ---------------------------------------------------------------------------
STATE_DIR="${STATE_DIR:-/tmp/amnezia-autotunnel}"
ADDED_FILE="${ADDED_FILE:-/etc/amnezia/autotunnel.d/added}"
LOADAVG_FILE="${LOADAVG_FILE:-/proc/loadavg}"
CRON_FILE="${CRON_FILE:-/etc/crontabs/root}"
DNSMASQ_CONFDIR="${DNSMASQ_CONFDIR:-/etc/amnezia/dnsmasq.d}"
AMNEZIA_DNSMASQ_INIT="${AMNEZIA_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
# logread is injectable so tests can stub it.
LOGREAD="${LOGREAD:-logread}"
# nslookup / pgrep are injectable for the health-check in cmd_enable.
PGREP="${PGREP:-pgrep}"
# Health-check retry count (injectable).
AUTOTUNNEL_HEALTHCHECK_TRIES="${AUTOTUNNEL_HEALTHCHECK_TRIES:-3}"
# Set to any non-empty value to skip the live dnsmasq health check in tests.
AUTOTUNNEL_SKIP_HEALTHCHECK="${AUTOTUNNEL_SKIP_HEALTHCHECK:-}"
# Marker comment used to dedup the cron line.
_CRON_MARKER="amnezia-autotunnel"
# dnsmasq confdir snippet filename.
_AUTOTUNNEL_LOG_CONF="${DNSMASQ_CONFDIR}/amnezia-autotunnel-log.conf"
# ---------------------------------------------------------------------------
# probe-page and watch: injectable paths and commands.
# ---------------------------------------------------------------------------
PROBE_PAGE_LOCK="${PROBE_PAGE_LOCK:-/var/lock/amnezia-probe-page.lock}"
PROBE_PAGE_STATE="${PROBE_PAGE_STATE:-/tmp/amnezia-fo/probe-page.json}"
WATCH_LOCK="${WATCH_LOCK:-/var/lock/amnezia-watch.lock}"
WATCH_STATE="${WATCH_STATE:-/tmp/amnezia-fo/watch.json}"
TIMEOUT="${TIMEOUT:-timeout}"

# ---------------------------------------------------------------------------
# _validate_domain <domain>
# Exit 2 on invalid; returns 0 on valid.
# Allowed chars: [A-Za-z0-9.-], must contain a dot, must not start/end with . or -.
# ---------------------------------------------------------------------------
_validate_domain() {
  _vd="$1"
  # Must not be empty.
  [ -n "$_vd" ] || { printf '{"error":"invalid domain"}\n'; exit 2; }
  # Reject characters outside [A-Za-z0-9.-].
  # Use case with a glob that matches any disallowed char.
  case "$_vd" in
    *[!A-Za-z0-9.-]*) printf '{"error":"invalid domain"}\n'; exit 2 ;;
  esac
  # Must contain a dot.
  case "$_vd" in
    *.*) ;;
    *) printf '{"error":"invalid domain"}\n'; exit 2 ;;
  esac
  # Must not start with . or -.
  case "$_vd" in
    [.-]*) printf '{"error":"invalid domain"}\n'; exit 2 ;;
  esac
  # Must not end with . or -.
  _last=$(printf '%s' "$_vd" | tail -c 1)
  case "$_last" in
    [.-]) printf '{"error":"invalid domain"}\n'; exit 2 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# _resolve_domain <domain> -> sets _resolved_ip (first IPv4) or empty string.
# Parses `nslookup <domain> <resolver>` output: Address: lines, strips port/127.
# ---------------------------------------------------------------------------
_resolve_domain() {
  _rd_domain="$1"
  _resolved_ip=""
  # BusyBox nslookup does NOT accept host#port; just domain + resolver.
  _ns_out=$("$NSLOOKUP" "$_rd_domain" "$RESOLVER" 2>/dev/null)
  # Parse Address: lines; skip 127.x (loopback/resolver address echo-backs).
  # Real nslookup output has "Address: 1.2.3.4" or "Address:1.2.3.4" (no space sometimes).
  while IFS= read -r _ns_line; do
    case "$_ns_line" in
      Address:*)
        # Strip the "Address:" prefix and any whitespace/port ("#53").
        _ip=$(printf '%s' "$_ns_line" | sed 's/Address:[ ]*//' | sed 's/#.*//' | tr -d ' \t\r')
        case "$_ip" in
          127.*) continue ;;
          [0-9]*.[0-9]*.[0-9]*.[0-9]*)
            _resolved_ip="$_ip"
            break
            ;;
        esac
        ;;
    esac
  done <<EOF
$_ns_out
EOF
}

# ---------------------------------------------------------------------------
# _inject_ips <domain>
# Resolve ALL IPv4 A-records and add them immediately to the amnezia_force4
# nft set for instant tunneling (no dnsmasq restart needed).
# Non-fatal: errors are silently suppressed.
# ---------------------------------------------------------------------------
_inject_ips() {
  _ii_domain="$1"
  _ii_ips=""
  _ii_ns_out=$("$NSLOOKUP" "$_ii_domain" "$RESOLVER" 2>/dev/null)
  while IFS= read -r _ii_line; do
    case "$_ii_line" in
      Address:*)
        _ii_ip=$(printf '%s' "$_ii_line" | sed 's/Address:[ ]*//' | sed 's/#.*//' | tr -d ' \t\r')
        case "$_ii_ip" in
          127.*) continue ;;
          [0-9]*.[0-9]*.[0-9]*.[0-9]*)
            if [ -z "$_ii_ips" ]; then
              _ii_ips="$_ii_ip"
            else
              _ii_ips="${_ii_ips}, ${_ii_ip}"
            fi
            ;;
        esac
        ;;
    esac
  done <<IEOF
$_ii_ns_out
IEOF
  [ -n "$_ii_ips" ] || return 0
  "$NFT" add element inet fw4 amnezia_force4 "{ ${_ii_ips} }" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _pick_tunnel -> sets _tunnel_if to the active pool tunnel device.
# Reads /var/run/amnezia-failover.json, falls back to awg1/awg2/awg3 probe.
# ---------------------------------------------------------------------------
_pick_tunnel() {
  _tunnel_if=""
  _STATE_FILE="${STATE_FILE:-/var/run/amnezia-failover.json}"
  if [ -f "$_STATE_FILE" ]; then
    # Extract active_pool field from JSON using sed (no jq on BusyBox).
    _ap=$(sed -n 's/.*"active_pool"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_STATE_FILE" | head -1)
    [ -n "$_ap" ] && _tunnel_if="$_ap"
  fi
}

# ---------------------------------------------------------------------------
# _probe_curl <domain> <ip> [<ifname>] [<url>]
# Sets _probe_code, _probe_ms, _probe_sec, _probe_exit, _probe_speed,
# _probe_size. Uses $CURL.
# With ifname, adds --interface <ifname>.
# With url (4th arg), fetches that URL instead of https://<domain>/ — the
# --resolve pin still uses domain:443 so IP pinning works regardless.
# ---------------------------------------------------------------------------
_probe_curl() {
  _pc_domain="$1"
  _pc_ip="$2"
  _pc_if="${3:-}"
  _pc_url="${4:-}"
  _pc_target="${_pc_url:-https://${_pc_domain}/}"

  if [ -n "$_pc_if" ]; then
    _pc_out=$("$CURL" -s -o /dev/null \
      -w '%{http_code} %{time_total} %{speed_download} %{size_download}' \
      --max-time "$PROBE_MAXTIME" \
      --interface "$_pc_if" \
      --resolve "${_pc_domain}:443:${_pc_ip}" \
      "$_pc_target" 2>/dev/null)
    _probe_exit=$?
  else
    _pc_out=$("$CURL" -s -o /dev/null \
      -w '%{http_code} %{time_total} %{speed_download} %{size_download}' \
      --max-time "$PROBE_MAXTIME" \
      --resolve "${_pc_domain}:443:${_pc_ip}" \
      "$_pc_target" 2>/dev/null)
    _probe_exit=$?
  fi

  _probe_code=$(printf '%s' "$_pc_out" | awk '{print $1}')
  _probe_sec=$(printf '%s' "$_pc_out" | awk '{print $2}')
  # Convert seconds (possibly decimal) to integer milliseconds via awk.
  _probe_ms=$(printf '%s' "$_probe_sec" | awk '{printf "%d", $1 * 1000 + 0.5}')
  # Speed (bytes/sec) and body size (bytes) — rounded to nearest integer.
  _probe_speed=$(printf '%s' "$_pc_out" | awk '{printf "%d", $3 + 0.5}')
  _probe_size=$(printf '%s' "$_pc_out" | awk '{printf "%d", $4 + 0.5}')
  # Normalize empty/000 code and missing numeric fields.
  [ -z "$_probe_code" ]  && _probe_code="000"
  [ -z "$_probe_ms" ]    && _probe_ms="0"
  [ -z "$_probe_speed" ] && _probe_speed="0"
  [ -z "$_probe_size" ]  && _probe_size="0"
}

# ---------------------------------------------------------------------------
# _do_probe <domain> [<sample_url>]
# Runs the full probe sequence.
# Sets: _verdict, _ip, _d_code, _d_ms, _d_exit, _d_speed, _d_size,
#       _t_if, _t_code, _t_ms, _t_exit, _t_speed, _t_size
# ---------------------------------------------------------------------------
_do_probe() {
  _dp_domain="$1"
  _dp_url="${2:-}"

  # 1. Resolve IP.
  _resolve_domain "$_dp_domain"
  _ip="$_resolved_ip"
  if [ -z "$_ip" ]; then
    _verdict="unresolved"
    _d_code="000"; _d_ms="0"; _d_exit="0"; _d_speed="0"; _d_size="0"
    _t_if=""; _t_code="000"; _t_ms="0"; _t_exit="0"; _t_speed="0"; _t_size="0"
    return 0
  fi

  # 2. Direct probe.
  _probe_curl "$_dp_domain" "$_ip" "" "$_dp_url"
  _d_code="$_probe_code"
  _d_ms="$_probe_ms"
  _d_sec="$_probe_sec"
  _d_exit="$_probe_exit"
  _d_speed="$_probe_speed"
  _d_size="$_probe_size"

  # 3. Pick tunnel.
  _pick_tunnel
  _t_if="$_tunnel_if"

  # 4. Tunnel probe — try active_pool first; if not set or returns 000, try awg1/awg2/awg3.
  _t_code="000"; _t_ms="0"; _t_sec="0"; _t_exit="0"; _t_speed="0"; _t_size="0"
  _try_tunnel() {
    _tt_if="$1"
    _probe_curl "$_dp_domain" "$_ip" "$_tt_if" "$_dp_url"
    if [ "$_probe_code" != "000" ]; then
      _t_code="$_probe_code"
      _t_ms="$_probe_ms"
      _t_sec="$_probe_sec"
      _t_exit="$_probe_exit"
      _t_speed="$_probe_speed"
      _t_size="$_probe_size"
      _t_if="$_tt_if"
      return 0
    fi
    return 1
  }

  if [ -n "$_t_if" ]; then
    _try_tunnel "$_t_if" || true
  fi
  if [ "$_t_code" = "000" ]; then
    for _fb_if in awg1 awg2 awg3; do
      [ "$_fb_if" != "$_t_if" ] || continue
      _try_tunnel "$_fb_if" && break || true
    done
    # If still 000 but we had a _t_if from active_pool and hadn't tried it, it's already done.
  fi

  # 5. Verdict (checked in priority order).
  if [ "$_t_code" = "000" ]; then
    _verdict="tunnel-down"
  elif [ "$_d_code" = "000" ]; then
    _verdict="throttled"
  elif [ "$_d_exit" = "28" ] && [ "$_d_size" -gt 0 ] && [ "$_t_exit" = "0" ]; then
    # TSPU stall: direct hit max-time mid-body, tunnel completed cleanly.
    _verdict="throttled"
  else
    # Throughput check: only when both completed and body was large enough to measure.
    _tp_throttled="0"
    if [ "$_d_exit" = "0" ] && [ "$_t_exit" = "0" ] && \
       [ "$_d_size" -ge 65536 ] && [ "$_t_speed" -gt 0 ]; then
      _tp_throttled=$(awk -v ds="${_d_speed:-0}" -v ts="${_t_speed:-0}" \
        'BEGIN{if(ds < ts/3) print "1"; else print "0"}')
    fi
    if [ "$_tp_throttled" = "1" ]; then
      _verdict="throttled"
    else
      # Both OK: throttled if direct > max(1.5, 3.0 * tunnel).
      # Use awk for float compare (BusyBox has no bc).
      _is_throttled=$(awk -v d="${_d_sec:-0}" -v t="${_t_sec:-0}" \
        'BEGIN{th=3.0*t; if(th<1.5)th=1.5; if(d>th) print "1"; else print "0"}')
      if [ "$_is_throttled" = "1" ]; then
        _verdict="throttled"
      else
        _verdict="ok"
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# cmd_probe <domain> [<sample_url>]
# ---------------------------------------------------------------------------
cmd_probe() {
  _domain="$1"
  _sample_url="${2:-}"
  _validate_domain "$_domain"
  _do_probe "$_domain" "$_sample_url"

  if [ "$_verdict" = "unresolved" ]; then
    printf '{"domain":"%s","verdict":"unresolved"}\n' "$_domain"
    exit 0
  fi

  printf '{"domain":"%s","ip":"%s","direct_code":%s,"direct_ms":%s,"tunnel":"%s","tunnel_code":%s,"tunnel_ms":%s,"verdict":"%s","d_speed":%s,"d_size":%s,"t_speed":%s,"t_size":%s}\n' \
    "$_domain" "$_ip" "$_d_code" "$_d_ms" \
    "${_t_if:-}" "$_t_code" "$_t_ms" "$_verdict" \
    "${_d_speed:-0}" "${_d_size:-0}" "${_t_speed:-0}" "${_t_size:-0}"
  exit 0
}

# ---------------------------------------------------------------------------
# cmd_add <domain> [--force]
# ---------------------------------------------------------------------------
cmd_add() {
  _domain="$1"
  _force="${2:-}"
  _validate_domain "$_domain"

  # Master gate.
  if command -v amz_master_enabled >/dev/null 2>&1; then
    if ! amz_master_enabled; then
      printf '{"error":"master-disabled"}\n'
      exit 3
    fi
  fi

  # Routing mode note.
  _rm_note=""
  _rmode=$(uci -q get amnezia.config.routing_mode 2>/dev/null || true)
  if [ "$_rmode" = "tunnel-default" ]; then
    _rm_note='"note":"routing_mode=tunnel-default (force list dormant)",'
  fi

  # Already-present check.
  _list_file="$FORCE_DIR/force-tunnel.list"
  if [ -f "$_list_file" ]; then
    while IFS= read -r _line; do
      # Strip inline comments and whitespace.
      _entry="${_line%%#*}"
      _entry=$(printf '%s' "$_entry" | tr -d ' \t\r')
      if [ "$_entry" = "$_domain" ]; then
        # Domain already present: ensure it's live via HUP.
        if [ "${DNSMASQ_HUP:-1}" = "1" ]; then
          _dmpid=$(pgrep dnsmasq 2>/dev/null | head -1 || true)
          [ -n "$_dmpid" ] && kill -HUP "$_dmpid" 2>/dev/null || true
        fi
        printf '{"domain":"%s","result":"already-present"}\n' "$_domain"
        exit 0
      fi
    done < "$_list_file"
  fi

  # Gate: unless --force, run probe and decide.
  _verdict="throttled"
  if [ "$_force" != "--force" ]; then
    _do_probe "$_domain"
    # _verdict is now set by _do_probe.
    if [ "$_verdict" = "ok" ]; then
      printf '{"domain":"%s",%s"verdict":"ok","result":"not-added"}\n' "$_domain" "$_rm_note"
      exit 0
    fi
    if [ "$_verdict" = "tunnel-down" ]; then
      printf '{"domain":"%s",%s"verdict":"tunnel-down","result":"not-added"}\n' "$_domain" "$_rm_note"
      exit 4
    fi
    if [ "$_verdict" = "unresolved" ]; then
      printf '{"domain":"%s",%s"result":"not-added","verdict":"unresolved"}\n' "$_domain" "$_rm_note"
      exit 0
    fi
    # verdict == throttled: fall through to add.
  fi

  # Add: read current list, dedup, append.
  _new_content=""
  if [ -f "$_list_file" ]; then
    while IFS= read -r _line; do
      # Check if it's a duplicate of the domain (stripping comments/whitespace).
      _entry="${_line%%#*}"
      _entry=$(printf '%s' "$_entry" | tr -d ' \t\r')
      if [ "$_entry" = "$_domain" ]; then
        # Skip duplicate.
        continue
      fi
      _new_content="${_new_content}${_line}
"
    done < "$_list_file"
  fi
  # Append the new domain.
  _new_content="${_new_content}${_domain}"

  # Write via amnezia-force-load save-manual (overwrite with full content).
  ${AMNEZIA_FORCE_LOAD:-amnezia-force-load} save-manual "$_new_content"

  # Flush dnsmasq cache and trigger fresh resolution.
  if [ "${DNSMASQ_HUP:-1}" = "1" ]; then
    _dmpid=$(pgrep dnsmasq 2>/dev/null | head -1 || true)
    [ -n "$_dmpid" ] && kill -HUP "$_dmpid" 2>/dev/null || true
  fi
  "$NSLOOKUP" "$_domain" "$RESOLVER" >/dev/null 2>&1 || true

  amz_log "autotunnel: added $_domain (verdict=$_verdict)"
  printf '{"domain":"%s",%s"verdict":"%s","result":"added"}\n' "$_domain" "$_rm_note" "$_verdict"
  exit 0
}

# ---------------------------------------------------------------------------
# cmd_remove <domain>
# Strip a domain from force-tunnel.list and from the autotunnel added marker.
# ---------------------------------------------------------------------------
cmd_remove() {
  _domain="$1"
  _validate_domain "$_domain"

  _list_file="$FORCE_DIR/force-tunnel.list"
  _new_content=""
  _found=0
  if [ -f "$_list_file" ]; then
    while IFS= read -r _line; do
      _entry="${_line%%#*}"
      _entry=$(printf '%s' "$_entry" | tr -d ' \t\r')
      if [ "$_entry" = "$_domain" ]; then
        _found=1
        continue
      fi
      _new_content="${_new_content}${_line}
"
    done < "$_list_file"
  fi
  if [ "$_found" = "1" ]; then
    ${AMNEZIA_FORCE_LOAD:-amnezia-force-load} save-manual "$_new_content"
    if [ "${DNSMASQ_HUP:-1}" = "1" ]; then
      _dmpid=$("$PGREP" dnsmasq 2>/dev/null | head -1 || true)
      [ -n "$_dmpid" ] && kill -HUP "$_dmpid" 2>/dev/null || true
    fi
  fi

  # Strip from added marker.
  if [ -f "$ADDED_FILE" ]; then
    _new_added=""
    while IFS= read -r _aline; do
      _ad="${_aline%% *}"
      [ "$_ad" = "$_domain" ] && continue
      _new_added="${_new_added}${_aline}
"
    done < "$ADDED_FILE"
    printf '%s' "$_new_added" > "$ADDED_FILE"
  fi

  amz_log "autotunnel: removed $_domain"
  printf '{"domain":"%s","result":"removed","was-in-list":%s}\n' \
    "$_domain" "$([ "$_found" = "1" ] && printf 'true' || printf 'false')"
  exit 0
}

# ---------------------------------------------------------------------------
# _dnsmasq_healthcheck
# Returns 0 (healthy) or 1 (unhealthy).
# Retries up to $AUTOTUNNEL_HEALTHCHECK_TRIES times with 1s sleep between.
# Skipped entirely when $AUTOTUNNEL_SKIP_HEALTHCHECK is non-empty.
# ---------------------------------------------------------------------------
_dnsmasq_healthcheck() {
  if [ -n "$AUTOTUNNEL_SKIP_HEALTHCHECK" ]; then
    return 0
  fi
  _hc_try=0
  while [ "$_hc_try" -lt "$AUTOTUNNEL_HEALTHCHECK_TRIES" ]; do
    _hc_try=$((_hc_try + 1))
    if "$PGREP" dnsmasq >/dev/null 2>&1 && \
       "$NSLOOKUP" openwrt.org "$RESOLVER" >/dev/null 2>&1; then
      return 0
    fi
    [ "$_hc_try" -lt "$AUTOTUNNEL_HEALTHCHECK_TRIES" ] && sleep 1
  done
  return 1
}

# ---------------------------------------------------------------------------
# cmd_enable
# Write dnsmasq confdir snippet (log-queries only — syslog, works in ujail),
# restart dnsmasq, verify it's healthy, install cron.  Auto-rollback on
# dnsmasq failure: remove snippet + re-restart, set enabled=0, exit 5.
# ---------------------------------------------------------------------------
cmd_enable() {
  # 1. Ensure state dir exists (used for verdicts, hourcount — NOT for log).
  mkdir -p "$STATE_DIR" 2>/dev/null || true

  # 2. Write the snippet.  log-queries only: dnsmasq sends query logs to
  # syslog, which works inside its ujail sandbox.  A log-facility=file path
  # would point outside the jail and cause dnsmasq to exit on reload.
  mkdir -p "$DNSMASQ_CONFDIR" 2>/dev/null || true
  printf 'log-queries\n' > "$_AUTOTUNNEL_LOG_CONF"

  # 3. Restart dnsmasq to pick up the snippet.
  if [ -x "$AMNEZIA_DNSMASQ_INIT" ]; then
    "$AMNEZIA_DNSMASQ_INIT" restart 2>/dev/null || true
  fi

  # 4. Health check — verify dnsmasq came back up.
  if ! _dnsmasq_healthcheck; then
    # ROLLBACK: remove snippet, re-restart, leave enabled=0.
    rm -f "$_AUTOTUNNEL_LOG_CONF" 2>/dev/null || true
    if [ -x "$AMNEZIA_DNSMASQ_INIT" ]; then
      "$AMNEZIA_DNSMASQ_INIT" restart 2>/dev/null || true
    fi
    "$PGREP" dnsmasq >/dev/null 2>&1 || true  # best-effort re-verify
    uci set amnezia.config.autotunnel_enabled=0
    uci commit amnezia
    amz_log "autotunnel: enable ROLLED BACK (dnsmasq unhealthy)"
    printf '{"result":"rollback","error":"dnsmasq-unhealthy"}\n'
    exit 5
  fi

  # 5. HEALTHY: persist enabled=1 and install cron.
  uci set amnezia.config.autotunnel_enabled=1
  uci commit amnezia

  # Initialize last_apply so the initial learning burst is also coalesced
  # (IPs are injected immediately; only the directive load is deferred).
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  date +%s 2>/dev/null > "$STATE_DIR/last_apply" || printf '0\n' > "$STATE_DIR/last_apply"
  rm -f "$STATE_DIR/pending" 2>/dev/null || true

  mkdir -p "$(dirname "$CRON_FILE")" 2>/dev/null || true
  touch "$CRON_FILE" 2>/dev/null || true
  sed -i "/${_CRON_MARKER}/d" "$CRON_FILE" 2>/dev/null || true
  printf '* * * * * /usr/bin/amnezia-autotunnel auto >/dev/null 2>&1 # %s\n' \
    "$_CRON_MARKER" >> "$CRON_FILE"
  /etc/init.d/cron enable 2>/dev/null || true
  /etc/init.d/cron reload 2>/dev/null || true

  amz_log "autotunnel: enabled"
  printf '{"result":"enabled"}\n'
  exit 0
}

# ---------------------------------------------------------------------------
# cmd_disable
# Remove cron line and dnsmasq snippet; restart dnsmasq; set UCI off.
# Already-added domains are kept (they are legit tunnel entries).
# Disable always succeeds — never fails the disable path.
# ---------------------------------------------------------------------------
cmd_disable() {
  # Remove dnsmasq snippet and reload to restore default logging.
  rm -f "$_AUTOTUNNEL_LOG_CONF" 2>/dev/null || true
  if [ -x "$AMNEZIA_DNSMASQ_INIT" ]; then
    "$AMNEZIA_DNSMASQ_INIT" restart 2>/dev/null || true
  fi

  # Best-effort verify dnsmasq is back.
  if "$PGREP" dnsmasq >/dev/null 2>&1; then
    amz_log "autotunnel: dnsmasq healthy after disable"
  else
    amz_log "autotunnel: dnsmasq not running after disable (non-fatal)"
  fi

  # Remove the cron entry.
  sed -i "/${_CRON_MARKER}/d" "$CRON_FILE" 2>/dev/null || true
  /etc/init.d/cron reload 2>/dev/null || true

  uci set amnezia.config.autotunnel_enabled=0
  uci commit amnezia

  amz_log "autotunnel: disabled"
  printf '{"result":"disabled"}\n'
  exit 0
}

# ---------------------------------------------------------------------------
# cmd_status
# JSON one-liner: enabled, routing_mode, loadavg, added_count, added[],
# verdict_count, hour_count.
# ---------------------------------------------------------------------------
cmd_status() {
  _enabled=$(uci -q get amnezia.config.autotunnel_enabled 2>/dev/null || printf '0')
  _rmode=$(uci -q get amnezia.config.routing_mode 2>/dev/null || printf '')
  _loadavg=$(awk '{print $1}' "$LOADAVG_FILE" 2>/dev/null || printf '0')

  # Count and list auto-added domains from the persistent marker.
  _added_list=""
  _added_count=0
  if [ -f "$ADDED_FILE" ]; then
    while IFS= read -r _aline; do
      # Marker line is "<domain> <epoch>"; take the first field as the domain.
      # (Do NOT tr -d spaces first — that would glue the epoch onto the domain.)
      _ad=$(printf '%s' "$_aline" | awk '{print $1}')
      [ -n "$_ad" ] || continue
      _added_count=$((_added_count + 1))
      if [ -n "$_added_list" ]; then
        _added_list="${_added_list},\"${_ad}\""
      else
        _added_list="\"${_ad}\""
      fi
    done < "$ADDED_FILE"
  fi

  # Count cached verdicts.
  _verdict_count=0
  if [ -f "$STATE_DIR/verdicts" ]; then
    _verdict_count=$(grep -c . "$STATE_DIR/verdicts" 2>/dev/null || printf '0')
  fi

  # Hour count.
  _hour_count=0
  if [ -f "$STATE_DIR/hourcount" ]; then
    _cur_hour=$(date +%s 2>/dev/null | awk '{printf "%d", $1/3600}')
    _hc_line=$(cat "$STATE_DIR/hourcount" 2>/dev/null || true)
    _hc_window=$(printf '%s' "$_hc_line" | awk '{print $1}')
    _hc_count=$(printf '%s' "$_hc_line" | awk '{print $2}')
    if [ "$_hc_window" = "$_cur_hour" ] && [ -n "$_hc_count" ]; then
      _hour_count="$_hc_count"
    fi
  fi

  # Coalesce apply state.
  _apply_interval=$(uci -q get amnezia.config.autotunnel_apply_interval 2>/dev/null || printf '1800')
  _pending=0
  [ -f "$STATE_DIR/pending" ] && _pending=1

  printf '{"enabled":%s,"routing_mode":"%s","loadavg":%s,"added_count":%d,"added":[%s],"verdict_count":%d,"hour_count":%d,"apply_interval":%s,"pending":%d}\n' \
    "$_enabled" "$_rmode" "$_loadavg" \
    "$_added_count" "$_added_list" \
    "$_verdict_count" "$_hour_count" \
    "$_apply_interval" "$_pending"
  exit 0
}

# ---------------------------------------------------------------------------
# cmd_auto — ONE background worker tick (cron-driven).
# Reads new DNS query candidates from syslog via logread (injectable: $LOGREAD).
# Safety order: guard gates first, then read candidates from logread, filter,
# probe at most max_per_tick, add throttled ones.
# ---------------------------------------------------------------------------
cmd_auto() {
  # 1. Kill-switch.
  _enabled=$(uci -q get amnezia.config.autotunnel_enabled 2>/dev/null || printf '0')
  [ "$_enabled" = "1" ] || exit 0

  # 2a. Master gate.
  if command -v amz_master_enabled >/dev/null 2>&1; then
    amz_master_enabled || exit 0
  fi

  # 2b. Routing mode must be direct-default for the force list to be active.
  _rmode=$(uci -q get amnezia.config.routing_mode 2>/dev/null || printf '')
  if [ "$_rmode" != "direct-default" ]; then
    amz_log "autotunnel auto: skip (routing_mode=${_rmode}, need direct-default)"
    exit 0
  fi

  # 3. Non-blocking flock: skip overlapping ticks.
  if command -v flock >/dev/null 2>&1; then
    exec 6>/var/lock/amnezia-autotunnel.lock
    flock -n 6 2>/dev/null || exit 0
  fi

  # 4. Read config options.
  _max_per_tick=$(uci -q get amnezia.config.autotunnel_max_per_tick 2>/dev/null || printf '1')
  _max_per_hour=$(uci -q get amnezia.config.autotunnel_max_per_hour 2>/dev/null || printf '10')
  _loadavg_max=$(uci -q get amnezia.config.autotunnel_loadavg_max 2>/dev/null || printf '2.0')
  _list_cap=$(uci -q get amnezia.config.autotunnel_list_cap 2>/dev/null || printf '200')

  # 5. Loadavg gate.
  _loadavg=$(awk '{print $1}' "$LOADAVG_FILE" 2>/dev/null || printf '0')
  _overload=$(awk -v la="$_loadavg" -v mx="$_loadavg_max" \
    'BEGIN{if(la+0 > mx+0) print "1"; else print "0"}')
  if [ "$_overload" = "1" ]; then
    amz_log "autotunnel auto: skip (loadavg=${_loadavg} > ${_loadavg_max})"
    exit 0
  fi

  # 6. Hourly cap check.
  _cur_hour=$(date +%s 2>/dev/null | awk '{printf "%d", $1/3600}')
  _hour_count=0
  if [ -f "$STATE_DIR/hourcount" ]; then
    _hc_line=$(cat "$STATE_DIR/hourcount" 2>/dev/null || true)
    _hc_window=$(printf '%s' "$_hc_line" | awk '{print $1}')
    _hc_count=$(printf '%s' "$_hc_line" | awk '{print $2}')
    if [ "$_hc_window" = "$_cur_hour" ] && [ -n "$_hc_count" ]; then
      _hour_count="$_hc_count"
    fi
  fi
  if [ "$_hour_count" -ge "$_max_per_hour" ] 2>/dev/null; then
    amz_log "autotunnel auto: hourly cap reached ($_hour_count/$_max_per_hour)"
    exit 0
  fi

  # 7. Read new candidates from syslog via logread.
  # dnsmasq logs queries to syslog when log-queries is set (no log-facility= file
  # needed — works inside its ujail sandbox).  Reprocessing all syslog lines on
  # every tick is harmless: verdict cache and already-in-list checks dedup.
  _candidates=$("$LOGREAD" 2>/dev/null \
    | grep -E 'dnsmasq.*query\[A' \
    | sed -n 's/.*query\[A[^]]*\] \([^ ]*\) .*/\1/p' \
    | grep '\.' \
    | grep -v -E '\.arpa$|\.lan$|\.local$|in-addr\.arpa|ip6\.arpa' \
    | sort -u)

  # 8. Count current list size.
  _list_file="$FORCE_DIR/force-tunnel.list"
  _list_size=0
  if [ -f "$_list_file" ]; then
    _list_size=$(grep -c . "$_list_file" 2>/dev/null || printf '0')
  fi

  # 9. Process candidates.
  _tick_count=0
  for _candidate in $_candidates; do
    # Per-tick cap.
    if [ "$_tick_count" -ge "$_max_per_tick" ] 2>/dev/null; then
      break
    fi

    # Hourly cap (re-check in loop since we may add during this tick).
    if [ "$((_hour_count + _tick_count))" -ge "$_max_per_hour" ] 2>/dev/null; then
      break
    fi

    # Skip .ru TLD.
    case "$_candidate" in
      *.ru) continue ;;
    esac

    # Skip if in ru4 nft set (RU IP range).
    _ru_skip=0
    _resolved_ip=""
    _resolve_domain "$_candidate"
    if [ -n "$_resolved_ip" ]; then
      _in_ru=$("$NFT" list set inet fw4 amnezia_ru4 2>/dev/null \
        | grep -F "$_resolved_ip" | head -1 || true)
      [ -n "$_in_ru" ] && _ru_skip=1
    fi
    [ "$_ru_skip" = "1" ] && continue

    # Skip if already in force-tunnel.list.
    _already=0
    if [ -f "$_list_file" ]; then
      while IFS= read -r _ll; do
        _le="${_ll%%#*}"
        _le=$(printf '%s' "$_le" | tr -d ' \t\r')
        if [ "$_le" = "$_candidate" ]; then _already=1; break; fi
      done < "$_list_file"
    fi
    [ "$_already" = "1" ] && continue

    # Skip if verdict is cached.
    _cached=""
    if [ -f "$STATE_DIR/verdicts" ]; then
      _cached=$(grep "^${_candidate} " "$STATE_DIR/verdicts" 2>/dev/null | head -1 || true)
    fi
    if [ -n "$_cached" ]; then
      _cached_verdict=$(printf '%s' "$_cached" | awk '{print $2}')
      [ "$_cached_verdict" = "throttled" ] || continue
      # cached throttled: still try to add if list not capped.
    fi

    if [ -z "$_cached" ]; then
      # Probe the domain.
      _do_probe "$_candidate"
      # Cache verdict.
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      # Remove old entry for this domain then append fresh one.
      _new_verts=""
      if [ -f "$STATE_DIR/verdicts" ]; then
        while IFS= read -r _vl; do
          _vd="${_vl%% *}"
          [ "$_vd" = "$_candidate" ] && continue
          _new_verts="${_new_verts}${_vl}
"
        done < "$STATE_DIR/verdicts"
      fi
      printf '%s%s %s\n' "$_new_verts" "$_candidate" "$_verdict" > "$STATE_DIR/verdicts"
      [ "$_verdict" = "throttled" ] || continue
    fi

    # List cap check.
    if [ "$_list_size" -ge "$_list_cap" ] 2>/dev/null; then
      amz_log "autotunnel auto: list cap reached ($_list_size/$_list_cap), not adding $_candidate"
      continue
    fi

    # Add to force-tunnel.list.
    _new_content=""
    if [ -f "$_list_file" ]; then
      while IFS= read -r _ll; do
        _le="${_ll%%#*}"
        _le=$(printf '%s' "$_le" | tr -d ' \t\r')
        [ "$_le" = "$_candidate" ] && continue
        _new_content="${_new_content}${_ll}
"
      done < "$_list_file"
    fi
    _new_content="${_new_content}${_candidate}"
    # Write the list directly (atomic temp+mv) — NO dnsmasq restart here.
    mkdir -p "$(dirname "$_list_file")" 2>/dev/null || true
    printf '%s\n' "$_new_content" > "${_list_file}.tmp" 2>/dev/null \
      && mv "${_list_file}.tmp" "$_list_file" 2>/dev/null || true
    # Immediate tunneling: inject the domain's current IPs into force4 (no restart).
    _inject_ips "$_candidate"
    # Mark a coalesced dnsmasq directive-refresh as pending.
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    : > "$STATE_DIR/pending"
    _list_size=$((_list_size + 1))

    # Record in added marker (domain + timestamp).
    mkdir -p "$(dirname "$ADDED_FILE")" 2>/dev/null || true
    _ts=$(date +%s 2>/dev/null || printf '0')
    printf '%s %s\n' "$_candidate" "$_ts" >> "$ADDED_FILE"

    amz_log "autotunnel auto: added $_candidate (throttled)"
    _tick_count=$((_tick_count + 1))
  done

  # Coalesced dnsmasq directive refresh — at most once per apply-interval.
  # Detected domains were written to the list + their IPs injected into force4
  # immediately (no per-detection restart).  Here we load the new nftset=
  # directives with a SINGLE dnsmasq restart, throttled so active browsing is
  # not disrupted by frequent restarts.  A bare amnezia-force-load hash-guards
  # its own restart, so this is a no-op restart-wise if nothing changed.
  if [ -f "$STATE_DIR/pending" ]; then
    _apply_interval=$(uci -q get amnezia.config.autotunnel_apply_interval 2>/dev/null || printf '1800')
    _now=$(date +%s 2>/dev/null || printf '0')
    _last_apply=0
    [ -f "$STATE_DIR/last_apply" ] && _last_apply=$(cat "$STATE_DIR/last_apply" 2>/dev/null || printf '0')
    _elapsed=$(( _now - _last_apply ))
    # Clock stepped backward (RTC-less router): treat as interval elapsed so
    # a skewed last_apply never permanently suppresses the coalesced apply.
    [ "$_elapsed" -ge 0 ] || _elapsed="$_apply_interval"
    if [ "$_elapsed" -ge "$_apply_interval" ] 2>/dev/null; then
      ${AMNEZIA_FORCE_LOAD:-amnezia-force-load} >/dev/null 2>&1 || true
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      printf '%s\n' "$_now" > "$STATE_DIR/last_apply"
      rm -f "$STATE_DIR/pending"
      amz_log "autotunnel auto: coalesced dnsmasq apply (interval=${_apply_interval}s)"
    fi
  fi

  # 10. Persist hourcount.
  if [ "$_tick_count" -gt "0" ]; then
    _new_total=$((_hour_count + _tick_count))
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf '%s %d\n' "$_cur_hour" "$_new_total" > "$STATE_DIR/hourcount"
  fi

  exit 0
}

# ---------------------------------------------------------------------------
# _is_force_covered <host>
# Returns 0 if <host> is suffix-covered by any force list entry, 1 otherwise.
# dnsmasq suffix semantics: "example.com" covers "cdn.example.com".
# ---------------------------------------------------------------------------
_is_force_covered() {
  _ifc_h="$1"
  for _ifc_f in \
      "$FORCE_DIR/force-tunnel.list" \
      "$FORCE_DIR"/force.d/*.list; do
    [ -f "$_ifc_f" ] || continue
    while IFS= read -r _ifc_line; do
      _ifc_e="${_ifc_line%%#*}"
      _ifc_e=$(printf '%s' "$_ifc_e" | tr -d ' \t\r')
      [ -n "$_ifc_e" ] || continue
      [ "$_ifc_h" = "$_ifc_e" ] && return 0
      case "$_ifc_h" in
        *."$_ifc_e") return 0 ;;
      esac
    done < "$_ifc_f"
  done
  return 1
}

# ---------------------------------------------------------------------------
# _is_ru_host <host>
# Returns 0 if host belongs to the RU-direct set (.ru TLD or IP in ru4 set).
# ---------------------------------------------------------------------------
_is_ru_host() {
  _irh="$1"
  case "$_irh" in *.ru) return 0 ;; esac
  _resolve_domain "$_irh"
  if [ -n "$_resolved_ip" ]; then
    _irh_in=$("$NFT" list set inet fw4 amnezia_ru4 2>/dev/null \
      | grep -F "$_resolved_ip" | head -1 || true)
    [ -n "$_irh_in" ] && return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _pp_add_host <domain>
# Add domain to force-tunnel.list without a dnsmasq flush (uses pending marker
# so the coalesced apply handles the directive reload).
# Sets _pp_add_result: "added", "already-present", "capped", or "error".
# ---------------------------------------------------------------------------
_pp_add_host() {
  _pah_d="$1"
  _pp_add_result="error"
  _pah_list="$FORCE_DIR/force-tunnel.list"
  _pah_cap=$(uci -q get amnezia.config.autotunnel_list_cap 2>/dev/null \
    || printf '200')
  # Already-present check.
  if [ -f "$_pah_list" ]; then
    while IFS= read -r _pah_l; do
      _pah_e="${_pah_l%%#*}"
      _pah_e=$(printf '%s' "$_pah_e" | tr -d ' \t\r')
      if [ "$_pah_e" = "$_pah_d" ]; then
        _pp_add_result="already-present"
        return 0
      fi
    done < "$_pah_list"
  fi
  # List cap check.
  _pah_sz=0
  [ -f "$_pah_list" ] && \
    _pah_sz=$(grep -c . "$_pah_list" 2>/dev/null || printf '0')
  if [ "$_pah_sz" -ge "$_pah_cap" ] 2>/dev/null; then
    _pp_add_result="capped"
    return 0
  fi
  # Build new list content.
  _pah_new=""
  if [ -f "$_pah_list" ]; then
    while IFS= read -r _pah_l; do
      _pah_e="${_pah_l%%#*}"
      _pah_e=$(printf '%s' "$_pah_e" | tr -d ' \t\r')
      [ "$_pah_e" = "$_pah_d" ] && continue
      _pah_new="${_pah_new}${_pah_l}
"
    done < "$_pah_list"
  fi
  _pah_new="${_pah_new}${_pah_d}"
  ${AMNEZIA_FORCE_LOAD:-amnezia-force-load} save-manual "$_pah_new"
  _inject_ips "$_pah_d"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  : > "$STATE_DIR/pending"
  amz_log "autotunnel probe-page: added $_pah_d"
  _pp_add_result="added"
}

# ---------------------------------------------------------------------------
# _pp_json_host <host> <status> <verdict> <d_ms> <t_ms> <d_speed> <t_speed> <added>
# Emit a single JSON host object (no newline).
# ---------------------------------------------------------------------------
_pp_json_host() {
  printf '{"host":"%s","status":"%s","verdict":"%s","d_ms":%s,"t_ms":%s,"d_speed":%s,"t_speed":%s,"added":%d}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

# ---------------------------------------------------------------------------
# _probe_page_run <url> <page_host> <add_throttled> [state_file]
# Core implementation for probe-page.  Synchronous (state_file empty): prints
# final JSON to stdout.  Async (state_file set): writes progress + final JSON
# to state_file atomically via tmp+mv.
# ---------------------------------------------------------------------------
_probe_page_run() {
  _prun_url="$1"
  _prun_ph="$2"
  _prun_add="$3"
  _prun_sf="${4:-}"
  _prun_tab=$(printf '\t')
  _prun_tmpd="/tmp/amnezia-fo"
  mkdir -p "$_prun_tmpd" 2>/dev/null || true
  _prun_hf="$_prun_tmpd/pp-html-$$.tmp"
  _prun_pf="$_prun_tmpd/pp-pairs-$$.tmp"
  _prun_cf="$_prun_tmpd/pp-cands-$$.tmp"

  # 1. Fetch HTML (capped at 512 KB via head; avoids --max-filesize portability).
  "$CURL" -s --max-time 15 -L --max-redirs 3 \
    "$_prun_url" 2>/dev/null | head -c 524288 > "$_prun_hf" || true

  # 2. Extract "host<TAB>sample_url" pairs from HTML.
  #    Prefers asset extensions (.js/.css/img/font) as the sample URL per host.
  grep -oE \
    'https?://[^[:space:]"<>)]+|//[A-Za-z0-9][A-Za-z0-9._-]*/[^[:space:]"<>)]*' \
    "$_prun_hf" 2>/dev/null | \
  awk -v tab="	" '
  {
    url=$0
    h=url
    sub(/^https?:\/\//, "", h)
    sub(/^\/\//, "", h)
    if (match(h, /:[0-9]+/)) {
      h = substr(h,1,RSTART-1) substr(h,RSTART+RLENGTH)
    }
    slash=index(h,"/")
    host=(slash>0) ? substr(h,1,slash-1) : h
    sub(/[?#].*/, "", host)
    if (host=="") next
    is_a=(url ~ /\.(js|css|png|jpg|jpeg|webp|svg|woff2?)([?#].*)?$/)
    if (!(host in fu)) { fu[host]=url; ord[++n]=host }
    if (is_a && !(host in au)) { au[host]=url }
  }
  END {
    for(i=1;i<=n;i++){
      h=ord[i]
      print h tab (h in au ? au[h] : fu[h])
    }
  }' > "$_prun_pf" 2>/dev/null || true
  rm -f "$_prun_hf" 2>/dev/null || true

  # 3. Candidate list: page_host first, then HTML-derived hosts (page_host excluded
  #    from the HTML-derived list — it was already added first).
  printf '%s\t%s\n' "$_prun_ph" "https://${_prun_ph}/" > "$_prun_cf"
  if [ -f "$_prun_pf" ]; then
    while IFS="$_prun_tab" read -r _pc_h _pc_u; do
      [ -n "$_pc_h" ] || continue
      [ "$_pc_h" = "$_prun_ph" ] && continue
      printf '%s\t%s\n' "$_pc_h" "$_pc_u"
    done < "$_prun_pf" >> "$_prun_cf"
  fi
  rm -f "$_prun_pf" 2>/dev/null || true

  # 4. Classify and probe each candidate.
  _prun_json=""
  _prun_total=0
  _prun_probed=0

  while IFS="$_prun_tab" read -r _ph _pu; do
    [ -n "$_ph" ] || continue
    # Skip IP-literal hosts (no DNS entry, not a domain name).
    case "$_ph" in [0-9]*.[0-9]*.[0-9]*.[0-9]*) continue ;; esac
    # Force-covered → report status, skip probe.
    if _is_force_covered "$_ph"; then
      _pe=$(_pp_json_host "$_ph" "forced" "" "0" "0" "0" "0" "0")
      [ -n "$_prun_json" ] && _prun_json="${_prun_json},"
      _prun_json="${_prun_json}${_pe}"
      _prun_total=$((_prun_total + 1))
      if [ -n "$_prun_sf" ]; then
        printf \
          '{"url":"%s","page_host":"%s","running":1,"done":%d,"total":%d,"hosts":[%s]}\n' \
          "$_prun_url" "$_prun_ph" \
          "$_prun_total" "$_prun_total" "$_prun_json" \
          > "${_prun_sf}.tmp" \
          && mv "${_prun_sf}.tmp" "$_prun_sf" 2>/dev/null || true
      fi
      continue
    fi
    # RU direct → report status, skip probe.
    if _is_ru_host "$_ph"; then
      _pe=$(_pp_json_host "$_ph" "ru" "" "0" "0" "0" "0" "0")
      [ -n "$_prun_json" ] && _prun_json="${_prun_json},"
      _prun_json="${_prun_json}${_pe}"
      _prun_total=$((_prun_total + 1))
      if [ -n "$_prun_sf" ]; then
        printf \
          '{"url":"%s","page_host":"%s","running":1,"done":%d,"total":%d,"hosts":[%s]}\n' \
          "$_prun_url" "$_prun_ph" \
          "$_prun_total" "$_prun_total" "$_prun_json" \
          > "${_prun_sf}.tmp" \
          && mv "${_prun_sf}.tmp" "$_prun_sf" 2>/dev/null || true
      fi
      continue
    fi
    # Cap at 20 probed hosts.
    if [ "$_prun_probed" -ge 20 ]; then
      amz_log "autotunnel probe-page: cap (20) reached, skipping $_ph"
      continue
    fi
    # Probe via _do_probe (verdict v2: stall + throughput rules).
    _do_probe "$_ph" "$_pu"
    _pv="$_verdict"
    _pdm="$_d_ms"; _ptm="$_t_ms"
    _pds="${_d_speed:-0}"; _pts="${_t_speed:-0}"
    _prun_probed=$((_prun_probed + 1))
    _pst="probed"
    [ "$_pv" = "unresolved" ] && _pst="unresolved"
    # Add to force list if throttled and --add-throttled was requested.
    _padded=0
    if [ "$_prun_add" = "1" ] && [ "$_pv" = "throttled" ]; then
      _pp_add_host "$_ph"
      [ "$_pp_add_result" = "added" ] && _padded=1
    fi
    _pe=$(_pp_json_host "$_ph" "$_pst" "$_pv" \
      "$_pdm" "$_ptm" "$_pds" "$_pts" "$_padded")
    [ -n "$_prun_json" ] && _prun_json="${_prun_json},"
    _prun_json="${_prun_json}${_pe}"
    _prun_total=$((_prun_total + 1))
    if [ -n "$_prun_sf" ]; then
      printf \
        '{"url":"%s","page_host":"%s","running":1,"done":%d,"total":%d,"hosts":[%s]}\n' \
        "$_prun_url" "$_prun_ph" \
        "$_prun_total" "$_prun_total" "$_prun_json" \
        > "${_prun_sf}.tmp" \
        && mv "${_prun_sf}.tmp" "$_prun_sf" 2>/dev/null || true
    fi
  done < "$_prun_cf"
  rm -f "$_prun_cf" 2>/dev/null || true

  # 5. Final JSON.
  if [ -n "$_prun_sf" ]; then
    printf \
      '{"url":"%s","page_host":"%s","running":0,"done":%d,"total":%d,"hosts":[%s]}\n' \
      "$_prun_url" "$_prun_ph" \
      "$_prun_total" "$_prun_total" "$_prun_json" \
      > "${_prun_sf}.tmp" \
      && mv "${_prun_sf}.tmp" "$_prun_sf" 2>/dev/null || true
  else
    printf '{"url":"%s","page_host":"%s","total":%d,"hosts":[%s]}\n' \
      "$_prun_url" "$_prun_ph" "$_prun_total" "$_prun_json"
  fi
}

# ---------------------------------------------------------------------------
# cmd_probe_page [<url>] [--add-throttled] [--async]
# ---------------------------------------------------------------------------
cmd_probe_page() {
  _ppg_url=""
  _ppg_add=0
  _ppg_async=0
  for _ppg_a in "$@"; do
    case "$_ppg_a" in
      --add-throttled) _ppg_add=1 ;;
      --async)         _ppg_async=1 ;;
      *)               _ppg_url="$_ppg_a" ;;
    esac
  done

  [ -n "$_ppg_url" ] || {
    printf 'Usage: %s probe-page <https://url|host> [--add-throttled] [--async]\n' \
      "$0" >&2
    exit 2
  }

  # Validate and normalise URL; extract page host.
  case "$_ppg_url" in
    https://*)
      _ppg_ph="${_ppg_url#https://}"
      _ppg_ph="${_ppg_ph%%/*}"
      _ppg_fetch="$_ppg_url"
      ;;
    http://*)
      _ppg_ph="${_ppg_url#http://}"
      _ppg_ph="${_ppg_ph%%/*}"
      _ppg_fetch="$_ppg_url"
      ;;
    *://*)
      printf 'Usage: %s probe-page <https://url|host> [--add-throttled] [--async]\n' \
        "$0" >&2
      exit 2
      ;;
    *)
      # Bare host → treat as https://host/
      _ppg_ph="${_ppg_url%%/*}"
      _ppg_fetch="https://${_ppg_url}"
      _ppg_url="$_ppg_fetch"
      ;;
  esac

  # Validate the extracted host (must be a valid domain name).
  case "$_ppg_ph" in
    '' | *[!A-Za-z0-9.-]*)
      printf 'Usage: %s probe-page <https://url|host> [--add-throttled] [--async]\n' \
        "$0" >&2; exit 2 ;;
    *.*) ;;
    *)
      printf 'Usage: %s probe-page <https://url|host> [--add-throttled] [--async]\n' \
        "$0" >&2; exit 2 ;;
  esac
  case "$_ppg_ph" in
    [.-]*)
      printf 'Usage: %s probe-page <https://url|host> [--add-throttled] [--async]\n' \
        "$0" >&2; exit 2 ;;
  esac
  _ppg_last=$(printf '%s' "$_ppg_ph" | tail -c 1)
  case "$_ppg_last" in
    [.-])
      printf 'Usage: %s probe-page <https://url|host> [--add-throttled] [--async]\n' \
        "$0" >&2; exit 2 ;;
  esac

  if [ "$_ppg_async" = "1" ]; then
    mkdir -p /tmp/amnezia-fo 2>/dev/null || true
    (
      exec 9>"$PROBE_PAGE_LOCK"
      if command -v flock >/dev/null 2>&1; then
        flock -n 9 2>/dev/null || exit 0
      fi
      _probe_page_run "$_ppg_fetch" "$_ppg_ph" "$_ppg_add" "$PROBE_PAGE_STATE"
    ) </dev/null >/dev/null 2>&1 &
    printf '{"started":1}\n'
    exit 0
  fi

  _probe_page_run "$_ppg_fetch" "$_ppg_ph" "$_ppg_add" ""
  exit 0
}

# ---------------------------------------------------------------------------
# _watch_run <seconds> <add_throttled> [state_file]
# Core implementation for watch.  Collects dnsmasq DNS queries for <seconds>
# via $LOGREAD -f, filters, probes, and emits JSON.
# ---------------------------------------------------------------------------
_watch_run() {
  _wr_secs="$1"
  _wr_add="$2"
  _wr_sf="${3:-}"

  # Collect DNS query domains: exclude router-self (127.0.0.1), .arpa, .local,
  # bare labels, and IP-literal "domains".
  _wr_domains=$("$TIMEOUT" "$_wr_secs" "$LOGREAD" -f 2>/dev/null | \
    grep -E 'dnsmasq.*query\[A' | \
    grep -v 'from 127\.' | \
    sed -n 's/.*query\[A[^]]*\] \([^ ]*\) .*/\1/p' | \
    grep '\.' | \
    grep -v -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | \
    grep -v -E '\.arpa$|\.lan$|\.local$|in-addr\.arpa|ip6\.arpa' | \
    sort -u | head -30)

  _wr_json=""
  _wr_total=0
  _wr_probed=0

  for _wh in $_wr_domains; do
    # Force-covered?
    if _is_force_covered "$_wh"; then
      _we=$(_pp_json_host "$_wh" "forced" "" "0" "0" "0" "0" "0")
      [ -n "$_wr_json" ] && _wr_json="${_wr_json},"
      _wr_json="${_wr_json}${_we}"
      _wr_total=$((_wr_total + 1))
      if [ -n "$_wr_sf" ]; then
        printf '{"window":%d,"running":1,"done":%d,"total":%d,"hosts":[%s]}\n' \
          "$_wr_secs" "$_wr_total" "$_wr_total" "$_wr_json" \
          > "${_wr_sf}.tmp" && mv "${_wr_sf}.tmp" "$_wr_sf" 2>/dev/null || true
      fi
      continue
    fi
    # RU direct?
    if _is_ru_host "$_wh"; then
      _we=$(_pp_json_host "$_wh" "ru" "" "0" "0" "0" "0" "0")
      [ -n "$_wr_json" ] && _wr_json="${_wr_json},"
      _wr_json="${_wr_json}${_we}"
      _wr_total=$((_wr_total + 1))
      if [ -n "$_wr_sf" ]; then
        printf '{"window":%d,"running":1,"done":%d,"total":%d,"hosts":[%s]}\n' \
          "$_wr_secs" "$_wr_total" "$_wr_total" "$_wr_json" \
          > "${_wr_sf}.tmp" && mv "${_wr_sf}.tmp" "$_wr_sf" 2>/dev/null || true
      fi
      continue
    fi
    # Cap at 30 probed hosts.
    if [ "$_wr_probed" -ge 30 ]; then
      amz_log "autotunnel watch: cap (30) reached, skipping $_wh"
      continue
    fi
    _do_probe "$_wh"
    _wv="$_verdict"
    _wdm="$_d_ms"; _wtm="$_t_ms"
    _wds="${_d_speed:-0}"; _wts="${_t_speed:-0}"
    _wr_probed=$((_wr_probed + 1))
    _wst="probed"
    [ "$_wv" = "unresolved" ] && _wst="unresolved"
    _wadded=0
    if [ "$_wr_add" = "1" ] && [ "$_wv" = "throttled" ]; then
      _pp_add_host "$_wh"
      [ "$_pp_add_result" = "added" ] && _wadded=1
    fi
    _we=$(_pp_json_host "$_wh" "$_wst" "$_wv" \
      "$_wdm" "$_wtm" "$_wds" "$_wts" "$_wadded")
    [ -n "$_wr_json" ] && _wr_json="${_wr_json},"
    _wr_json="${_wr_json}${_we}"
    _wr_total=$((_wr_total + 1))
    if [ -n "$_wr_sf" ]; then
      printf '{"window":%d,"running":1,"done":%d,"total":%d,"hosts":[%s]}\n' \
        "$_wr_secs" "$_wr_total" "$_wr_total" "$_wr_json" \
        > "${_wr_sf}.tmp" && mv "${_wr_sf}.tmp" "$_wr_sf" 2>/dev/null || true
    fi
  done

  if [ -n "$_wr_sf" ]; then
    printf '{"window":%d,"running":0,"done":%d,"total":%d,"hosts":[%s]}\n' \
      "$_wr_secs" "$_wr_total" "$_wr_total" "$_wr_json" \
      > "${_wr_sf}.tmp" && mv "${_wr_sf}.tmp" "$_wr_sf" 2>/dev/null || true
  else
    printf '{"window":%d,"total":%d,"hosts":[%s]}\n' \
      "$_wr_secs" "$_wr_total" "$_wr_json"
  fi
}

# ---------------------------------------------------------------------------
# cmd_watch [<seconds>] [--add-throttled] [--async]
# ---------------------------------------------------------------------------
cmd_watch() {
  _cw_secs=30
  _cw_add=0
  _cw_async=0
  for _cw_a in "$@"; do
    case "$_cw_a" in
      --add-throttled) _cw_add=1 ;;
      --async)         _cw_async=1 ;;
      [0-9]*)          _cw_secs="$_cw_a" ;;
    esac
  done
  # Clamp 10..120.
  _cw_secs=$(awk -v s="$_cw_secs" \
    'BEGIN{if(s+0<10)s=10;if(s+0>120)s=120;print s+0}')

  if [ "$_cw_async" = "1" ]; then
    mkdir -p /tmp/amnezia-fo 2>/dev/null || true
    (
      exec 9>"$WATCH_LOCK"
      if command -v flock >/dev/null 2>&1; then
        flock -n 9 2>/dev/null || exit 0
      fi
      _watch_run "$_cw_secs" "$_cw_add" "$WATCH_STATE"
    ) </dev/null >/dev/null 2>&1 &
    printf '{"started":1}\n'
    exit 0
  fi

  _watch_run "$_cw_secs" "$_cw_add" ""
  exit 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  probe)
    [ $# -ge 2 ] || { printf 'Usage: %s probe <domain> [url]\n' "$0" >&2; exit 1; }
    cmd_probe "$2" "${3:-}"
    ;;
  add)
    [ $# -ge 2 ] || { printf 'Usage: %s add <domain> [--force]\n' "$0" >&2; exit 1; }
    cmd_add "$2" "${3:-}"
    ;;
  remove)
    [ $# -ge 2 ] || { printf 'Usage: %s remove <domain>\n' "$0" >&2; exit 1; }
    cmd_remove "$2"
    ;;
  auto)
    cmd_auto
    ;;
  enable)
    cmd_enable
    ;;
  disable)
    cmd_disable
    ;;
  status)
    cmd_status
    ;;
  probe-page)
    shift
    cmd_probe_page "$@"
    ;;
  watch)
    shift
    cmd_watch "$@"
    ;;
  *)
    printf 'Usage: %s {probe <domain>|add <domain> [--force]|remove <domain>|auto|enable|disable|status|probe-page <url> [--add-throttled] [--async]|watch [seconds] [--add-throttled] [--async]}\n' "$0" >&2
    exit 1
    ;;
esac
