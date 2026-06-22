# Shared tunnel UCI generator. Sourced by install-amnezia-pbr.sh and amnezia-tunnel-ctl.sh.
# Depends on amnezia-common.sh being sourced first (for parse_awg_conf / amz_log).
# shellcheck disable=SC2154  # AWG_* vars are set by parse_awg_conf called within gen_tunnel_uci.

# gen_tunnel_uci <tunnel_name> <conf_file>
# Prints the UCI lines that describe one AmneziaWG tunnel (interface + peer).
# Emits allowed_ips=0.0.0.0/0 ONLY — never ::/0 (IPv4-only policy).
gen_tunnel_uci() {
  _tname=$1
  _cfile=$2
  _CFG="amneziawg_${_tname}"

  # Parse the conf so AWG_* vars are available.
  parse_awg_conf "$_cfile" || return 1

  echo "set network.${_tname}=interface"
  echo "set network.${_tname}.proto=amneziawg"
  echo "set network.${_tname}.private_key=${AWG_PrivateKey}"
  echo "set network.${_tname}.addresses=${AWG_Address}"
  echo "set network.${_tname}.mtu=1376"
  [ -n "${AWG_Jc:-}"   ] && echo "set network.${_tname}.awg_jc=${AWG_Jc}"
  [ -n "${AWG_Jmin:-}" ] && echo "set network.${_tname}.awg_jmin=${AWG_Jmin}"
  [ -n "${AWG_Jmax:-}" ] && echo "set network.${_tname}.awg_jmax=${AWG_Jmax}"
  [ -n "${AWG_S1:-}"   ] && echo "set network.${_tname}.awg_s1=${AWG_S1}"
  [ -n "${AWG_S2:-}"   ] && echo "set network.${_tname}.awg_s2=${AWG_S2}"
  [ -n "${AWG_S3:-}"   ] && echo "set network.${_tname}.awg_s3=${AWG_S3}"
  [ -n "${AWG_S4:-}"   ] && echo "set network.${_tname}.awg_s4=${AWG_S4}"
  [ -n "${AWG_H1:-}"   ] && echo "set network.${_tname}.awg_h1=${AWG_H1}"
  [ -n "${AWG_H2:-}"   ] && echo "set network.${_tname}.awg_h2=${AWG_H2}"
  [ -n "${AWG_H3:-}"   ] && echo "set network.${_tname}.awg_h3=${AWG_H3}"
  [ -n "${AWG_H4:-}"   ] && echo "set network.${_tname}.awg_h4=${AWG_H4}"
  [ -n "${AWG_I1:-}"   ] && echo "set network.${_tname}.awg_i1='${AWG_I1}'"
  [ -n "${AWG_I2:-}"   ] && echo "set network.${_tname}.awg_i2='${AWG_I2}'"
  [ -n "${AWG_I3:-}"   ] && echo "set network.${_tname}.awg_i3='${AWG_I3}'"
  [ -n "${AWG_I4:-}"   ] && echo "set network.${_tname}.awg_i4='${AWG_I4}'"
  [ -n "${AWG_I5:-}"   ] && echo "set network.${_tname}.awg_i5='${AWG_I5}'"
  echo "add network ${_CFG}"
  echo "set network.@${_CFG}[-1]=${_CFG}"
  echo "set network.@${_CFG}[-1].name=${_tname}_client"
  echo "set network.@${_CFG}[-1].public_key=${AWG_PublicKey}"
  [ -n "${AWG_PresharedKey:-}" ] && echo "set network.@${_CFG}[-1].preshared_key=${AWG_PresharedKey}"
  echo "set network.@${_CFG}[-1].endpoint_host=${AWG_Endpoint_host}"
  echo "set network.@${_CFG}[-1].endpoint_port=${AWG_Endpoint_port}"
  echo "set network.@${_CFG}[-1].persistent_keepalive=${AWG_PersistentKeepalive:-25}"
  echo "set network.@${_CFG}[-1].allowed_ips=0.0.0.0/0"
  echo "set network.@${_CFG}[-1].route_allowed_ips=0"
}
