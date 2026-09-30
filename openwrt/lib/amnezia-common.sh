# Shared constants + helpers for amnezia multi-tunnel. POSIX sh (BusyBox ash).
# shellcheck disable=SC2034  # These are library exports; consumers source this file.
export STICKY_MARK=0x0A0000
export POOL_MARK=0x0B0000
export MARK_MASK=0x0FF0000
export TBL_STICKY=100
export TBL_POOL=101
# ip rule priorities — deliberately ABOVE pbr's cleanup range (pbr deletes priorities
# <= uplink_ip_rules_priority, default 30000) and BELOW the main-table fallback (32766),
# so a pbr teardown during migrate never removes our rules.
export RULE_PREF_STICKY=31000
export RULE_PREF_POOL=31001
export SET_RU4=amnezia_ru4
export SET_RU_TLD4=amnezia_ru_tld4
export SET_STICKY4=amnezia_sticky4
export STATE_FILE="${STATE_FILE:-/var/run/amnezia-failover.json}"
export CONF_DIR=/etc/amnezia
export RU_CIDR_PERSIST=/etc/amnezia/ru.cidr
export MAX_TUNNELS=5
export RULE_PREF_DOT=30900            # DoT-IP ip rule; above pbr cleanup (30000), below sticky (31000)
export DNSMASQ_LOCK=/var/lock/amnezia-dnsmasq.lock

# Exit-IP probe: endpoints tried in order, first valid IPv4 wins.
export AMNEZIA_IPECHO_URLS="${AMNEZIA_IPECHO_URLS:-https://api.ipify.org https://ifconfig.co/ip}"
# Cache TTL in seconds; re-probe after expiry.
export AMNEZIA_EXITIP_TTL="${AMNEZIA_EXITIP_TTL:-300}"

# Shared state directory (single source of truth so ctl and daemon agree).
export ST_DIR="${ST_DIR:-/tmp/amnezia-fo}"

# Covert-creator (whitelist-bypass) fixed paths.
export AMZ_COVERT_BIN=/usr/bin/amnezia-covert-creator
export AMZ_COVERT_DIR=/etc/amnezia/covert
export AMZ_COVERT_COOKIES="$AMZ_COVERT_DIR/vk-cookies.json"
export AMZ_COVERT_LOG="$AMZ_COVERT_DIR/covert.log"
export AMZ_COVERT_MANIFEST="$AMZ_COVERT_DIR/BUILD_MANIFEST"
export AMZ_COVERT_RUN_DIR=/var/run/amnezia-covert
# /proc mount point; overridable so bats can point at a fabricated fixture
# (there is no /proc on the macOS dev host running the offline test suite).
export AMZ_PROC_DIR="${AMZ_PROC_DIR:-/proc}"

amz_log() { logger -t amnezia-failover "$*" 2>/dev/null; if [ -n "${AMNEZIA_DEBUG:-}" ]; then echo "amnezia: $*" >&2; fi; }

# True (exit 0) unless master_enabled is explicitly set to 0. Default = enabled.
amz_master_enabled() { [ "$(uci -q get amnezia.config.master_enabled 2>/dev/null || echo 1)" != 0 ]; }

# Numeric uid of the amnezia-covert service user. Empty + rc<>0 if the user
# does not exist. AMZ_COVERT_UID, when set, short-circuits the `id -u` lookup
# — a test seam (that system user does not exist off-router / in bats).
amz_covert_uid() {
  if [ -n "${AMZ_COVERT_UID:-}" ]; then
    printf '%s' "$AMZ_COVERT_UID"
    return 0
  fi
  id -u amnezia-covert 2>/dev/null
}

# True (exit 0) iff amnezia.config.covert_enabled == '1'. MUST read via
# `uci -q get` (unquoted) — never `uci show | grep | sed` (quoted '1' != 1).
amz_covert_enabled() {
  [ "$(uci -q get amnezia.config.covert_enabled 2>/dev/null)" = 1 ]
}

# Reap every process owned by amz_covert_uid via a /proc scan: pkill/pgrep -u/
# ps -o are ABSENT on the BusyBox target. Signal defaults to TERM. Reads the
# Uid: line's real-uid column ($2 under awk default split; $1 is the "Uid:"
# label). 2>/dev/null on kill absorbs pid-vanish races. Always returns 0 (a
# best-effort sweep; callers re-check emptiness themselves).
amz_covert_reap() {
  _sig="${1:-TERM}"
  _cuid=$(amz_covert_uid) || return 0
  [ -n "$_cuid" ] || return 0
  for _statf in "$AMZ_PROC_DIR"/[0-9]*/status; do
    [ -f "$_statf" ] || continue
    _uline=$(awk '/^Uid:/{print; exit}' "$_statf" 2>/dev/null)
    [ -n "$_uline" ] || continue
    _ruid=$(printf '%s' "$_uline" | awk '{print $2}')
    [ "$_ruid" = "$_cuid" ] || continue
    _pid=${_statf#"$AMZ_PROC_DIR"/}
    _pid=${_pid%/status}
    kill -"$_sig" "$_pid" 2>/dev/null
  done
  return 0
}

# Active tunnel egress device for router-origin traffic that MUST be tunneled.
# Router-origin packets are not seen by the prerouting/mangle classifier, so they
# carry no fwmark and fall through to the main table -> WAN (direct). Callers that
# need their own traffic tunneled (force-update fetches; the self-learning probe)
# bind to this device (SO_BINDTODEVICE via `curl --interface`), which egresses the
# tunnel regardless of destination IP. Derived from the sticky table's default
# route, then the pool table, then the first awg* link. Empty = no tunnel up.
# A blackhole default ("blackhole default ...") has no `dev` and is skipped.
amz_tunnel_dev() {
  _td=$(ip route show table "$TBL_STICKY" 2>/dev/null | awk '/^default /{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$_td" ] || _td=$(ip route show table "$TBL_POOL" 2>/dev/null | awk '/^default /{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$_td" ] || _td=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -m1 '^awg')
  printf '%s' "$_td"
}

# Parse an AmneziaWG client .conf into AWG_<Key> vars. Endpoint split into host/port.
parse_awg_conf() {
  _f=$1; [ -f "$_f" ] || { amz_log "conf missing: $_f"; return 1; }
  # Clear all optional fields so a PSK-bearing conf never leaks into a PSK-less one.
  AWG_PrivateKey=""; AWG_Address=""; AWG_Jc=""; AWG_Jmin=""; AWG_Jmax=""
  AWG_S1=""; AWG_S2=""; AWG_S3=""; AWG_S4=""
  AWG_H1=""; AWG_H2=""; AWG_H3=""; AWG_H4=""
  AWG_I1=""; AWG_I2=""; AWG_I3=""; AWG_I4=""; AWG_I5=""
  AWG_PublicKey=""; AWG_PresharedKey=""; AWG_Endpoint_host=""; AWG_Endpoint_port=""
  AWG_PersistentKeepalive=""
  _sec=""
  while IFS= read -r _line; do
    _line=$(printf '%s' "$_line" | tr -d '\r')
    case "$_line" in
      \[Interface\]*) _sec=Interface; continue ;;
      \[Peer\]*) _sec=Peer; continue ;;
      ""|\#*|\;*) continue ;;
    esac
    case "$_line" in *=*) ;; *) continue ;; esac
    _k=$(printf '%s' "${_line%%=*}" | tr -d ' \t')
    _v=$(printf '%s' "${_line#*=}" | sed 's/^[ \t]*//; s/[ \t]*$//')
    [ -n "$_sec" ] || continue
    # Allowlist: only known AmneziaWG/WireGuard keys are accepted.
    # Any key not on this list is silently skipped to prevent command
    # injection via eval with attacker-controlled key names.
    case "$_k" in
      PrivateKey|PublicKey|PresharedKey|Address|Endpoint|\
PersistentKeepalive|Jc|Jmin|Jmax|S1|S2|S3|S4|\
H1|H2|H3|H4|I1|I2|I3|I4|I5) ;;
      *) continue ;;
    esac
    if [ "$_k" = Endpoint ]; then
      # shellcheck disable=SC2034  # Set for caller inspection after parse_awg_conf.
      AWG_Endpoint_host=${_v%:*}; AWG_Endpoint_port=${_v##*:}
    fi
    eval "AWG_${_k}=\$_v"
  done < "$_f"
  if [ -z "$AWG_PrivateKey" ] || [ -z "$AWG_PublicKey" ]; then
    amz_log "conf incomplete: $_f"
    return 1
  fi
  return 0
}
