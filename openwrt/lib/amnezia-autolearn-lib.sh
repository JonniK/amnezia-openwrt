#!/bin/sh
# amnezia-autolearn-lib: pure helpers for the auto-learning pass. POSIX sh.
# No side effects on source; every function is independently testable.

# al_ip_is_public <ipv4>: exit 0 iff a global-unicast routable IPv4.
al_ip_is_public() {
  _ip="$1"
  case "$_ip" in *.*.*.*) ;; *) return 1 ;; esac
  _o1="${_ip%%.*}"; _r="${_ip#*.}"; _o2="${_r%%.*}"; _r="${_r#*.}"
  _o3="${_r%%.*}"; _o4="${_r#*.}"
  for _o in "$_o1" "$_o2" "$_o3" "$_o4"; do
    case "$_o" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_o" -le 255 ] 2>/dev/null || return 1
  done
  # Reserved / non-routable ranges.
  case "$_o1" in 0|10|127) return 1 ;; esac
  [ "$_o1" -ge 224 ] && return 1                      # 224/4 multicast + 240/4 reserved
  [ "$_o1" = 169 ] && [ "$_o2" = 254 ] && return 1    # link-local
  [ "$_o1" = 192 ] && [ "$_o2" = 168 ] && return 1    # 192.168/16
  [ "$_o1" = 172 ] && [ "$_o2" -ge 16 ] && [ "$_o2" -le 31 ] && return 1   # 172.16/12
  [ "$_o1" = 100 ] && [ "$_o2" -ge 64 ] && [ "$_o2" -le 127 ] && return 1  # 100.64/10 CGNAT
  return 0
}

# al_name_is_probeable <domain>: exit 0 iff a public, probeable FQDN.
al_name_is_probeable() {
  _d="$1"
  [ ${#_d} -ge 2 ] && [ ${#_d} -le 253 ] || return 1
  case "$_d" in *[!A-Za-z0-9._-]*) return 1 ;; esac   # charset (mirror zapret-probe)
  case "$_d" in *.*) ;; *) return 1 ;; esac           # must have a dot (no bare host)
  case "$_d" in *[A-Za-z]*) ;; *) return 1 ;; esac     # an IP-literal has no letter -> reject
  case "$_d" in
    *.lan|*.local|*.internal|*.localdomain|*.home.arpa|*.arpa) return 1 ;;
  esac
  return 0
}

# al_router_lan_cidrs: echo each router LAN network as "ipaddr/prefixlen".
# Enumerates every network.<section> that has a static ipaddr (covers a
# non-"lan"-named bridge), not just network.lan.
al_router_lan_cidrs() {
  for _sec in $(uci -q show network 2>/dev/null \
                  | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p'); do
    _ip=$(uci -q get "network.${_sec}.ipaddr" 2>/dev/null) || continue
    [ -n "$_ip" ] || continue
    _nm=$(uci -q get "network.${_sec}.netmask" 2>/dev/null)
    # Emit the address; prefix derivation is best-effort (membership test in
    # al_resolve_public uses octet compare, not exact CIDR math).
    printf '%s/%s\n' "$_ip" "${_nm:-255.255.255.0}"
  done
}

# _al_same_lan <ip>: return 0 iff <ip> shares the /24 of any router LAN address.
# No pipeline-subshell (avoids any ambiguity about exit propagation): capture
# the CIDR list into a var, iterate with a plain for-loop.
_al_same_lan() {
  _q="$1"; _q3="${_q%.*}"
  _cidrs=$(al_router_lan_cidrs)
  for _line in $_cidrs; do
    _la="${_line%%/*}"
    [ "${_la%.*}" = "$_q3" ] && return 0
  done
  return 1
}

# al_resolve_public <domain>: echo first public, non-LAN A record (or empty).
# Anchor to the ANSWER section: skip the leading Server:/Address: block (the
# resolver's own address) so an upstream like 8.8.8.8#53 is not mistaken for an
# A record of the domain.
al_resolve_public() {
  _d="$1"
  _addrs=$(nslookup "$_d" 2>/dev/null | awk '
    /^Name:/ {ans=1; next}                 # answer section starts at first Name:
    ans && /^Address: ?[0-9]/ {sub(/#.*/,"",$2); print $2}')
  for _a in $_addrs; do
    al_ip_is_public "$_a" || continue
    _al_same_lan "$_a" && continue
    printf '%s\n' "$_a"; break
  done
}

# al_querylog_pairs <file> <offset>: emit "<domain> <client-ip>" for each
# dnsmasq `query[<type>] <domain> from <ip>` line at/after byte <offset>.
al_querylog_pairs() {
  _f="$1"; _off="${2:-0}"
  [ -f "$_f" ] || return 0
  _off=$(printf '%s' "$_off" | tr -d ' \t\n')
  case "$_off" in *[!0-9]*|'') _off=0 ;; esac
  _size=$(wc -c < "$_f" 2>/dev/null | tr -d ' \t\n'); _size=${_size:-0}
  case "$_size" in *[!0-9]*|'') _size=0 ;; esac
  [ "$_off" -gt "$_size" ] 2>/dev/null && _off=0   # shrink/rotation guard
  # BusyBox tail has no `-c +N`; seek with dd block-skip instead (skip exactly
  # _off bytes = one block of size _off, then read the remainder).
  # When _off=0 use cat (dd bs=0 is invalid on BusyBox).
  # The awk scans fields for one starting `query[` so it is robust to a
  # `dnsmasq[pid]:` daemon-tag prefix; the client IP is the last field.
  if [ "$_off" -gt 0 ]; then
    dd if="$_f" bs="$_off" skip=1 2>/dev/null
  else
    cat "$_f" 2>/dev/null
  fi | awk '
      /query\[[A-Za-z]+\] [^ ]+ from [0-9]/ {
        for (i=1;i<=NF;i++) if ($i ~ /^query\[/) { print $(i+1), $NF }
      }'
}

# al_deny_match <domain> <denyfile>: exit 0 iff <domain> == an entry or a
# subdomain of one. Suffix-aware to mirror dnsmasq nftset matching.
al_deny_match() {
  _d="$1"; _df="$2"
  [ -s "$_df" ] || return 1
  awk -v dom="$_d" '
    { gsub(/[ \t\r]/,""); if($0!="") deny[$0]=1 }
    END {
      if (dom in deny) exit 0
      s=dom
      while ((i=index(s,"."))>0) { s=substr(s,i+1); if (s in deny) exit 0 }
      exit 1
    }' "$_df"
}
