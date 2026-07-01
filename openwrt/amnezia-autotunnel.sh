#!/bin/sh
# amnezia-autotunnel: probe a domain and optionally add it to the manual
# force-tunnel list when it appears throttled on the direct path.
# Usage: amnezia-autotunnel probe <domain>
#        amnezia-autotunnel add   <domain> [--force]
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
PROBE_MAXTIME="${PROBE_MAXTIME:-8}"
DNSMASQ_HUP="${DNSMASQ_HUP:-1}"

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
# _probe_curl <domain> <ip> [<ifname>]
# Sets _probe_code and _probe_ms. Uses $CURL.
# With ifname, adds --interface <ifname>.
# ---------------------------------------------------------------------------
_probe_curl() {
  _pc_domain="$1"
  _pc_ip="$2"
  _pc_if="${3:-}"

  if [ -n "$_pc_if" ]; then
    _pc_out=$("$CURL" -s -o /dev/null -w '%{http_code} %{time_total}' \
      --max-time "$PROBE_MAXTIME" \
      --interface "$_pc_if" \
      --resolve "${_pc_domain}:443:${_pc_ip}" \
      "https://${_pc_domain}/" 2>/dev/null)
  else
    _pc_out=$("$CURL" -s -o /dev/null -w '%{http_code} %{time_total}' \
      --max-time "$PROBE_MAXTIME" \
      --resolve "${_pc_domain}:443:${_pc_ip}" \
      "https://${_pc_domain}/" 2>/dev/null)
  fi

  _probe_code=$(printf '%s' "$_pc_out" | awk '{print $1}')
  _probe_sec=$(printf '%s' "$_pc_out" | awk '{print $2}')
  # Convert seconds (possibly decimal) to integer milliseconds via awk.
  _probe_ms=$(printf '%s' "$_probe_sec" | awk '{printf "%d", $1 * 1000 + 0.5}')
  # Normalize empty/000 code.
  [ -z "$_probe_code" ] && _probe_code="000"
  [ -z "$_probe_ms" ] && _probe_ms="0"
}

# ---------------------------------------------------------------------------
# _do_probe <domain>
# Runs the full probe sequence.
# Sets: _verdict, _ip, _d_code, _d_ms, _t_if, _t_code, _t_ms
# ---------------------------------------------------------------------------
_do_probe() {
  _dp_domain="$1"

  # 1. Resolve IP.
  _resolve_domain "$_dp_domain"
  _ip="$_resolved_ip"
  if [ -z "$_ip" ]; then
    _verdict="unresolved"
    _d_code="000"; _d_ms="0"; _t_if=""; _t_code="000"; _t_ms="0"
    return 0
  fi

  # 2. Direct probe.
  _probe_curl "$_dp_domain" "$_ip" ""
  _d_code="$_probe_code"
  _d_ms="$_probe_ms"
  _d_sec="$_probe_sec"

  # 3. Pick tunnel.
  _pick_tunnel
  _t_if="$_tunnel_if"

  # 4. Tunnel probe — try active_pool first; if not set or returns 000, try awg1/awg2/awg3.
  _t_code="000"; _t_ms="0"; _t_sec="0"
  _try_tunnel() {
    _tt_if="$1"
    _probe_curl "$_dp_domain" "$_ip" "$_tt_if"
    if [ "$_probe_code" != "000" ]; then
      _t_code="$_probe_code"
      _t_ms="$_probe_ms"
      _t_sec="$_probe_sec"
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

  # 5. Verdict.
  if [ "$_t_code" = "000" ]; then
    _verdict="tunnel-down"
  elif [ "$_d_code" = "000" ]; then
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
}

# ---------------------------------------------------------------------------
# cmd_probe <domain>
# ---------------------------------------------------------------------------
cmd_probe() {
  _domain="$1"
  _validate_domain "$_domain"
  _do_probe "$_domain"

  if [ "$_verdict" = "unresolved" ]; then
    printf '{"domain":"%s","verdict":"unresolved"}\n' "$_domain"
    exit 0
  fi

  printf '{"domain":"%s","ip":"%s","direct_code":%s,"direct_ms":%s,"tunnel":"%s","tunnel_code":%s,"tunnel_ms":%s,"verdict":"%s"}\n' \
    "$_domain" "$_ip" "$_d_code" "$_d_ms" \
    "${_t_if:-}" "$_t_code" "$_t_ms" "$_verdict"
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
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  probe)
    [ $# -ge 2 ] || { printf 'Usage: %s probe <domain>\n' "$0" >&2; exit 1; }
    cmd_probe "$2"
    ;;
  add)
    [ $# -ge 2 ] || { printf 'Usage: %s add <domain> [--force]\n' "$0" >&2; exit 1; }
    cmd_add "$2" "${3:-}"
    ;;
  *)
    printf 'Usage: %s {probe <domain>|add <domain> [--force]}\n' "$0" >&2
    exit 1
    ;;
esac
