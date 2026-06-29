#!/bin/sh
# amnezia-dnsleak-ctl: DNS-leak prevention block + fail-open watchdog. POSIX sh.
#
# Installs three firewall rules that:
#   1. DNAT all LAN port-53 UDP/TCP → router dnsmasq (intercept)
#   2. REJECT LAN→WAN TCP port 853  (block DoT)
#   3. REJECT LAN→WAN TCP port 443  to known DoH IPs (block DoH)
#
# A watchdog monitors dnsmasq health and performs fail-open (remove the
# interception rules from the live nft table) if dnsmasq is unrecoverable,
# preserving client DNS resolution over the VPN leak risk.
#
# UCI keys (all under amnezia.config):
#   dnsleak_enabled  — 0/1 feature flag (default 0)
#   dnsleak_failopen — 0/1 runtime state: 1 = rules removed from live nft
#
# Env test hooks:
#   AMNEZIA_DNSLEAK_PROBE_HOST   — nslookup target (default openwrt.org)
#   AMNEZIA_DNSLEAK_PROBE_CMD    — override probe command for tests
#   AMNEZIA_DNSLEAK_WD_RESTART_N — consecutive fail count before dnsmasq restart (default 2)
#   AMNEZIA_DNSLEAK_WD_OPEN_N    — consecutive fail count before failopen (default 4)
#   AMNEZIA_DNSLEAK_WD_M         — consecutive ok count to close failopen (default 3)
#   AMNEZIA_DNSLEAK_WD_INTERVAL  — sleep seconds between ticks (default 10)
#   AMNEZIA_DNSLEAK_WD_ONCE      — run one tick and exit (for tests)
#   AMNEZIA_DNSLEAK_WD_TICKS     — run exactly N ticks and exit (for tests, no sleep)
#   AMNEZIA_DNSMASQ_RESTART      — dnsmasq restart command (default /etc/init.d/dnsmasq restart)
#   AMNEZIA_DNSLEAK_INIT         — watchdog init path (default /etc/init.d/amnezia-dnsleak)

# shellcheck source=lib/amnezia-common.sh
AMNEZIA_LIB=${AMNEZIA_LIB:-/usr/lib/amnezia}
# shellcheck disable=SC1091
if [ -f "$AMNEZIA_LIB/amnezia-common.sh" ]; then
  . "$AMNEZIA_LIB/amnezia-common.sh"
else
  . "$(dirname "$0")/lib/amnezia-common.sh"
fi

AMNEZIA_DNSMASQ_RESTART="${AMNEZIA_DNSMASQ_RESTART:-/etc/init.d/dnsmasq restart}"
AMNEZIA_DNSLEAK_INIT="${AMNEZIA_DNSLEAK_INIT:-/etc/init.d/amnezia-dnsleak}"

# ---------------------------------------------------------------------------
# UCI section names (must match the spec exactly)
# ---------------------------------------------------------------------------
_SEC_INTERCEPT=amz_dns_intercept
_SEC_BLOCK_DOT=amz_block_dot
_SEC_BLOCK_DOH=amz_block_doh

# DoH IP block list (must match spec)
_DOH_IPS="1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Idempotently ensure the three firewall UCI sections exist.
_assert_sections() {
  # DNS intercept: DNAT LAN port-53 TCP/UDP → router
  uci -q get "firewall.${_SEC_INTERCEPT}" >/dev/null 2>&1 || uci set "firewall.${_SEC_INTERCEPT}=redirect"
  uci set "firewall.${_SEC_INTERCEPT}.name=amnezia-dns-intercept"
  uci set "firewall.${_SEC_INTERCEPT}.src=lan"
  uci set "firewall.${_SEC_INTERCEPT}.proto=tcp udp"
  uci set "firewall.${_SEC_INTERCEPT}.src_dport=53"
  uci set "firewall.${_SEC_INTERCEPT}.dest_ip=192.168.1.1"
  uci set "firewall.${_SEC_INTERCEPT}.dest_port=53"
  uci set "firewall.${_SEC_INTERCEPT}.target=DNAT"

  # Block DoT: REJECT LAN→WAN TCP port 853
  uci -q get "firewall.${_SEC_BLOCK_DOT}" >/dev/null 2>&1 || uci set "firewall.${_SEC_BLOCK_DOT}=rule"
  uci set "firewall.${_SEC_BLOCK_DOT}.name=amnezia-block-DoT"
  uci set "firewall.${_SEC_BLOCK_DOT}.src=lan"
  uci set "firewall.${_SEC_BLOCK_DOT}.dest=wan"
  uci set "firewall.${_SEC_BLOCK_DOT}.proto=tcp"
  uci set "firewall.${_SEC_BLOCK_DOT}.dest_port=853"
  uci set "firewall.${_SEC_BLOCK_DOT}.target=REJECT"

  # Block DoH: REJECT LAN→WAN TCP port 443 to known DoH IPs
  uci -q get "firewall.${_SEC_BLOCK_DOH}" >/dev/null 2>&1 || uci set "firewall.${_SEC_BLOCK_DOH}=rule"
  uci set "firewall.${_SEC_BLOCK_DOH}.name=amnezia-block-DoH-ips"
  uci set "firewall.${_SEC_BLOCK_DOH}.src=lan"
  uci set "firewall.${_SEC_BLOCK_DOH}.dest=wan"
  uci set "firewall.${_SEC_BLOCK_DOH}.proto=tcp"
  uci set "firewall.${_SEC_BLOCK_DOH}.dest_port=443"
  uci set "firewall.${_SEC_BLOCK_DOH}.target=REJECT"
  # Build the dest_ip list idempotently: delete any existing list then re-add.
  uci -q delete "firewall.${_SEC_BLOCK_DOH}.dest_ip" 2>/dev/null || true
  for _ip in $_DOH_IPS; do
    uci add_list "firewall.${_SEC_BLOCK_DOH}.dest_ip=$_ip"
  done
}

# Delete the three UCI sections (disable path).
_delete_sections() {
  uci -q delete "firewall.${_SEC_INTERCEPT}" 2>/dev/null || true
  uci -q delete "firewall.${_SEC_BLOCK_DOT}" 2>/dev/null || true
  uci -q delete "firewall.${_SEC_BLOCK_DOH}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# cmd_enable
# ---------------------------------------------------------------------------
cmd_enable() {
  uci set amnezia.config.dnsleak_enabled=1
  _assert_sections
  uci commit firewall
  uci commit amnezia
  ( sleep 1 && fw4 reload ) &
  "$AMNEZIA_DNSLEAK_INIT" enable 2>/dev/null || true
  "$AMNEZIA_DNSLEAK_INIT" start  2>/dev/null || true
}

# ---------------------------------------------------------------------------
# cmd_disable
# ---------------------------------------------------------------------------
cmd_disable() {
  # Stop the watchdog procd service first (stop_service is a no-op there, so no
  # recursion risk; procd simply kills the watchdog process).
  "$AMNEZIA_DNSLEAK_INIT" stop 2>/dev/null || true
  uci set amnezia.config.dnsleak_enabled=0
  uci -q delete amnezia.config.dnsleak_failopen 2>/dev/null || true
  _delete_sections
  uci commit firewall
  uci commit amnezia
  ( sleep 1 && fw4 reload ) &
}

# ---------------------------------------------------------------------------
# cmd_apply  (idempotent; called from hotplug and init)
# ---------------------------------------------------------------------------
cmd_apply() {
  [ "$(uci -q get amnezia.config.dnsleak_enabled 2>/dev/null || echo 0)" = 1 ] || return 0
  _assert_sections
  uci commit firewall
  # No fw4 reload here — hotplug is called BY a reload, and init relies on
  # the fact that the rules are already present in UCI and fw4 loads them.
}

# ---------------------------------------------------------------------------
# cmd_failopen  — remove live nft rules by handle (leave UCI as-is)
# ---------------------------------------------------------------------------
cmd_failopen() {
  # Parse the live nft ruleset for the rules we own, identified by comment.
  # For each matching line, extract the handle number and delete that rule.
  # Patterns:
  #   amnezia-dns-intercept      → chain dstnat_lan (DNAT rules)
  #   amnezia-block-DoT          → chain forward
  #   amnezia-block-DoH-ips      → chain forward
  #   ubus:https-dns-proxy       → chain dstnat_lan (best-effort)
  _nft_list=$(nft -a list table inet fw4 2>/dev/null || true)

  # Helper: delete a rule by chain + handle
  _nft_del_handle() {
    _chain=$1; _handle=$2
    [ -n "$_handle" ] || return 0
    nft delete rule inet fw4 "$_chain" handle "$_handle" 2>/dev/null || true
  }

  # Find and delete all rules matching each comment, in each candidate chain.
  # We check both dstnat_lan (DNAT/redirect) and forward (reject) chains.
  for _chain in dstnat_lan forward; do
    # Extract the handle for each named rule in this chain.
    # Real nft output (abridged):
    #   meta nfproto ipv4 ... dnat ip to 192.168.1.1:53 comment "!fw4: amnezia-dns-intercept" # handle 42
    # We walk the list output looking for lines in the current chain context.
    _in_chain=0
    while IFS= read -r _line; do
      case "$_line" in
        *"chain ${_chain}"*) _in_chain=1 ;;
        *"chain "*)           _in_chain=0 ;;
      esac
      [ "$_in_chain" = 1 ] || continue
      case "$_line" in
        *"amnezia-dns-intercept"*|*"amnezia-block-DoT"*|*"amnezia-block-DoH-ips"*|*"ubus:https-dns-proxy"*)
          _h=$(printf '%s' "$_line" | grep -o '# handle [0-9]*' | awk '{print $3}')
          _nft_del_handle "$_chain" "$_h"
          ;;
      esac
    done <<EOF
$_nft_list
EOF
  done

  uci set amnezia.config.dnsleak_failopen=1
  uci commit amnezia
  amz_log "dnsleak: DNS interception/block rules removed from live nft table (fail-open)"
}

# ---------------------------------------------------------------------------
# cmd_failclosed  — regenerate all rules from UCI via fw4 reload
# ---------------------------------------------------------------------------
cmd_failclosed() {
  uci -q delete amnezia.config.dnsleak_failopen 2>/dev/null || true
  uci commit amnezia
  ( sleep 1 && fw4 reload ) &
}

# ---------------------------------------------------------------------------
# cmd_status
# ---------------------------------------------------------------------------
cmd_status() {
  _en=$(uci -q get amnezia.config.dnsleak_enabled 2>/dev/null || echo 0)
  _fo=$(uci -q get amnezia.config.dnsleak_failopen 2>/dev/null || echo 0)

  # Probe the local resolver at port 53 (BusyBox nslookup is fine here —
  # standard port, no host#port needed).
  _probe_host="${AMNEZIA_DNSLEAK_PROBE_HOST:-openwrt.org}"
  _probe_ok=false
  if [ -n "${AMNEZIA_DNSLEAK_PROBE_CMD:-}" ]; then
    $AMNEZIA_DNSLEAK_PROBE_CMD >/dev/null 2>&1 && _probe_ok=true
  else
    nslookup -type=A "$_probe_host" 127.0.0.1 >/dev/null 2>&1 && _probe_ok=true
  fi

  printf 'enabled=%s\nfailopen=%s\nresolver_ok=%s\n' "$_en" "$_fo" "$_probe_ok"
}

# ---------------------------------------------------------------------------
# cmd_watchdog
# ---------------------------------------------------------------------------
cmd_watchdog() {
  _restart_n=${AMNEZIA_DNSLEAK_WD_RESTART_N:-2}
  _open_n=${AMNEZIA_DNSLEAK_WD_OPEN_N:-4}
  _m=${AMNEZIA_DNSLEAK_WD_M:-3}
  _fail=0; _ok=0; _ticks_done=0
  _failopen=$(uci -q get amnezia.config.dnsleak_failopen 2>/dev/null || echo 0)

  _probe() {
    _probe_host="${AMNEZIA_DNSLEAK_PROBE_HOST:-openwrt.org}"
    if [ -n "${AMNEZIA_DNSLEAK_PROBE_CMD:-}" ]; then
      $AMNEZIA_DNSLEAK_PROBE_CMD >/dev/null 2>&1
    else
      nslookup -type=A "$_probe_host" 127.0.0.1 >/dev/null 2>&1
    fi
  }

  while true; do
    # Exit immediately if feature was disabled while we were running.
    [ "$(uci -q get amnezia.config.dnsleak_enabled 2>/dev/null || echo 0)" = 1 ] || break

    if _probe; then
      _fail=0; _ok=$((_ok + 1))
      if [ "$_failopen" = 1 ] && [ "$_ok" -ge "$_m" ]; then
        cmd_failclosed
        _failopen=0
        amz_log "dnsleak: resolver healthy for ${_m} consecutive ticks — fail-closed restored"
      fi
    else
      _ok=0; _fail=$((_fail + 1))

      # Primary recovery: restart dnsmasq after RESTART_N consecutive failures.
      if [ "$_fail" = "$_restart_n" ]; then
        amz_log "dnsleak: dnsmasq probe failed ${_restart_n} times — attempting restart"
        $AMNEZIA_DNSMASQ_RESTART 2>/dev/null || true
      fi

      # Last resort: fail-open after OPEN_N consecutive failures (and not already open).
      if [ "$_fail" -ge "$_open_n" ] && [ "$_failopen" != 1 ]; then
        amz_log "dnsleak: dnsmasq unrecoverable after ${_fail} probes — FAIL-OPEN, DNS interception/block removed to preserve client resolution"
        cmd_failopen
        _failopen=1
      fi
    fi

    # Test tick control (mirrors DoT watchdog pattern).
    [ -n "${AMNEZIA_DNSLEAK_WD_ONCE:-}" ] && break
    if [ -n "${AMNEZIA_DNSLEAK_WD_TICKS:-}" ]; then
      _ticks_done=$((_ticks_done + 1))
      [ "$_ticks_done" -ge "${AMNEZIA_DNSLEAK_WD_TICKS}" ] && break
    else
      sleep "${AMNEZIA_DNSLEAK_WD_INTERVAL:-10}"
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  enable)     cmd_enable ;;
  disable)    cmd_disable ;;
  apply)      cmd_apply ;;
  status)     cmd_status ;;
  failopen)   cmd_failopen ;;
  failclosed) cmd_failclosed ;;
  watchdog)   cmd_watchdog ;;
  *) echo "usage: amnezia-dnsleak-ctl {enable|disable|apply|status|failopen|failclosed|watchdog}" >&2; exit 2 ;;
esac
