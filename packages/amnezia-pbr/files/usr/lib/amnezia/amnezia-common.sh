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

amz_log() { logger -t amnezia-failover "$*" 2>/dev/null; if [ -n "${AMNEZIA_DEBUG:-}" ]; then echo "amnezia: $*" >&2; fi; }

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
  [ -n "$AWG_PrivateKey" ] && [ -n "$AWG_PublicKey" ] || { amz_log "conf incomplete: $_f"; return 1; }
  return 0
}
