# Shared constants + helpers for amnezia multi-tunnel. POSIX sh (BusyBox ash).
# shellcheck disable=SC2034  # These are library exports; consumers source this file.
export STICKY_MARK=0x0A0000
export POOL_MARK=0x0B0000
export MARK_MASK=0x0FF0000
export TBL_STICKY=100
export TBL_POOL=101
export SET_RU4=amnezia_ru4
export SET_RU_TLD4=amnezia_ru_tld4
export SET_STICKY4=amnezia_sticky4
export STATE_FILE=/var/run/amnezia-failover.json
export CONF_DIR=/etc/amnezia
export RU_CIDR_PERSIST=/etc/amnezia/ru.cidr
export MAX_TUNNELS=5

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
      # shellcheck disable=SC2034  # Set for caller inspection after parse_awg_conf.
      AWG_Endpoint_host=${_v%:*}; AWG_Endpoint_port=${_v##*:}
    fi
    eval "AWG_${_k}=\$_v"
  done < "$_f"
  [ -n "$AWG_PrivateKey" ] && [ -n "$AWG_PublicKey" ] || { amz_log "conf incomplete: $_f"; return 1; }
  return 0
}
