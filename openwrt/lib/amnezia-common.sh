# Shared constants + helpers for amnezia multi-tunnel. POSIX sh (BusyBox ash).
STICKY_MARK=0x0A0000
POOL_MARK=0x0B0000
MARK_MASK=0x0FF0000
TBL_STICKY=100
TBL_POOL=101
SET_RU4=amnezia_ru4
SET_RU_TLD4=amnezia_ru_tld4
SET_STICKY4=amnezia_sticky4
STATE_FILE=/var/run/amnezia-failover.json
CONF_DIR=/etc/amnezia
RU_CIDR_PERSIST=/etc/amnezia/ru.cidr
MAX_TUNNELS=5

# Per-member conntrack mark (balance mode): low byte only, never the selector nibble.
member_ctmark() { printf '0x%06x\n' "$1"; }

amz_log() { logger -t amnezia-failover "$*" 2>/dev/null; [ -n "$AMNEZIA_DEBUG" ] && echo "amnezia: $*" >&2; }

# Parse an AmneziaWG client .conf into AWG_<Key> vars. Endpoint split into host/port.
parse_awg_conf() {
  _f=$1; [ -f "$_f" ] || { amz_log "conf missing: $_f"; return 1; }
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
    if [ "$_k" = Endpoint ]; then
      AWG_Endpoint_host=${_v%:*}; AWG_Endpoint_port=${_v##*:}
    fi
    eval "AWG_${_k}=\$_v"
  done < "$_f"
  [ -n "$AWG_PrivateKey" ] && [ -n "$AWG_PublicKey" ] || { amz_log "conf incomplete: $_f"; return 1; }
  return 0
}
