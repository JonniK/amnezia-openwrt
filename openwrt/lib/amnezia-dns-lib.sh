# Encrypted-DNS helpers (DoT/DoH). POSIX sh. Sourced by amnezia-dns-ctl, the
# watchdog, and force-load's lock wrap. No side effects on source.
# shellcheck disable=SC2034
: "${TBL_STICKY:=100}"            # fallback when sourced without amnezia-common.sh
: "${RULE_PREF_DOT:=30900}"
: "${DNSMASQ_LOCK:=/var/lock/amnezia-dnsmasq.lock}"
DOT_PORT=5453
DOH_PORT=5454

# dns_profile <name>: populate DNS_DOT_IP / DNS_DOT_HOST / DNS_DOH_HOST /
# DNS_DOH_BOOTSTRAP from the providers' DOCUMENTED RESOLVER anycast addresses
# (NOT the marketing-domain A record). Invariant: DoT-IP != DoH-bootstrap-IP.
dns_profile() {
  DNS_DOT_IP=""; DNS_DOT_HOST=""; DNS_DOH_HOST=""; DNS_DOH_BOOTSTRAP=""
  case "$1" in
    quad9)   DNS_DOT_IP=9.9.9.9;      DNS_DOT_HOST=dns.quad9.net
             DNS_DOH_HOST=dns.quad9.net;       DNS_DOH_BOOTSTRAP=149.112.112.112 ;;
    adguard) DNS_DOT_IP=94.140.14.14; DNS_DOT_HOST=dns.adguard-dns.com
             DNS_DOH_HOST=dns.adguard-dns.com; DNS_DOH_BOOTSTRAP=94.140.15.15 ;;
    dns0)    DNS_DOT_IP=193.110.81.0; DNS_DOT_HOST=dns0.eu
             DNS_DOH_HOST=dns0.eu;             DNS_DOH_BOOTSTRAP=185.253.5.0 ;;
    mullvad) DNS_DOT_IP=194.242.2.2;  DNS_DOT_HOST=dns.mullvad.net
             DNS_DOH_HOST=dns.mullvad.net;     DNS_DOH_BOOTSTRAP=194.242.2.3 ;;
    google)  DNS_DOT_IP=8.8.8.8;      DNS_DOT_HOST=dns.google
             DNS_DOH_HOST=dns.google;          DNS_DOH_BOOTSTRAP=8.8.4.4 ;;
    custom)
      _dot=$(uci -q get amnezia.config.dot_resolver)
      _doh=$(uci -q get amnezia.config.doh_resolver)
      DNS_DOH_BOOTSTRAP=$(uci -q get amnezia.config.doh_bootstrap)
      DNS_DOT_IP=${_dot%@*}
      DNS_DOT_HOST=${_dot##*#}
      DNS_DOH_HOST=$(printf '%s' "$_doh" | sed -e 's#^https://##' -e 's#/.*##')
      # M2: reject non-bare-IPv4 DoT IP (CIDR, garbage, or empty).
      printf '%s' "$DNS_DOT_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || return 1
      # reject IP-literal host: must contain at least one non-digit, non-dot label char
      printf '%s' "$DNS_DOH_HOST" | grep -q '[A-Za-z]' || return 1
      [ -n "$DNS_DOT_IP" ] && [ -n "$DNS_DOH_HOST" ] && [ -n "$DNS_DOH_BOOTSTRAP" ] || return 1
      ;;
    *) return 1 ;;
  esac
  [ -n "$DNS_DOT_IP" ] && [ "$DNS_DOT_IP" != "$DNS_DOH_BOOTSTRAP" ]
}

AMNEZIA_STUBBY_INIT="${AMNEZIA_STUBBY_INIT:-/etc/init.d/stubby}"
AMNEZIA_DOH_INIT="${AMNEZIA_DOH_INIT:-/etc/init.d/https-dns-proxy}"

# Delete every @<type> section of <cfg>. Count type lines (unquoted, grep-safe
# per CLAUDE.md), then delete that many @type[0]; bounded so it never depends on
# `uci delete`'s exit status (real UCI returns 0; the test stub returns 1).
_uci_drop_all() {
  _n=$(uci -q show "$1" 2>/dev/null | grep -c "=$2$")
  _i=0; while [ "$_i" -lt "$_n" ]; do uci -q delete "$1.@$2[0]" 2>/dev/null || true; _i=$((_i+1)); done
}

dns_render_stubby() {
  _uci_drop_all stubby resolver
  _s=$(uci add stubby resolver)
  uci set "stubby.$_s.address=$DNS_DOT_IP"
  uci set "stubby.$_s.tls_auth_name=$DNS_DOT_HOST"
  uci set "stubby.$_s.tls_authentication=1"
  uci -q delete stubby.global.listen_address 2>/dev/null || true
  uci add_list "stubby.global.listen_address=127.0.0.1@$DOT_PORT"
  uci set "stubby.global.tls_connection_timeout=2"   # short: bound the tunnel-down stall
  uci commit stubby
  "$AMNEZIA_STUBBY_INIT" restart 2>/dev/null || true
}

dns_render_doh() {
  _uci_drop_all https-dns-proxy https-dns-proxy
  _d=$(uci add https-dns-proxy https-dns-proxy)
  uci set "https-dns-proxy.$_d.resolver_url=https://$DNS_DOH_HOST/dns-query"
  uci set "https-dns-proxy.$_d.bootstrap_dns=$DNS_DOH_BOOTSTRAP"
  uci set "https-dns-proxy.$_d.listen_addr=127.0.0.1"
  uci set "https-dns-proxy.$_d.listen_port=$DOH_PORT"
  uci commit https-dns-proxy
  "$AMNEZIA_DOH_INIT" restart 2>/dev/null || true
}

AMNEZIA_DNSMASQ_INIT="${AMNEZIA_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
AMNEZIA_RESOLV_AUTO="${AMNEZIA_RESOLV_AUTO:-/tmp/resolv.conf.d/resolv.conf.auto}"

dnsmasq_lock() {                       # fd 8 — DISTINCT from force-load's fd 9
  exec 8>"$DNSMASQ_LOCK" 2>/dev/null || return 0
  flock -x 8 2>/dev/null || true
}
dnsmasq_unlock() { flock -u 8 2>/dev/null || true; exec 8>&- 2>/dev/null || true; }

dns_iprule_set() {
  ip rule del to "$1" lookup "$TBL_STICKY" pref "$RULE_PREF_DOT" 2>/dev/null || true
  ip rule add to "$1" lookup "$TBL_STICKY" pref "$RULE_PREF_DOT"
}
dns_iprule_clear() { ip rule del to "$1" lookup "$TBL_STICKY" pref "$RULE_PREF_DOT" 2>/dev/null || true; }
# Flush ALL pref-RULE_PREF_DOT rules unconditionally (no-IP needed). Safe as
# an idempotent teardown even when the current profile can't be parsed.
dns_iprule_flush() { while ip rule del pref "$RULE_PREF_DOT" 2>/dev/null; do :; done; }

dns_dnsmasq_encrypted() {
  uci set "dhcp.@dnsmasq[0].noresolv=1"
  uci set "dhcp.@dnsmasq[0].strictorder=1"
  uci -q del_list "dhcp.@dnsmasq[0].server=127.0.0.1#$DOT_PORT"
  uci -q del_list "dhcp.@dnsmasq[0].server=127.0.0.1#$DOH_PORT"
  uci add_list "dhcp.@dnsmasq[0].server=127.0.0.1#$DOT_PORT"
  uci add_list "dhcp.@dnsmasq[0].server=127.0.0.1#$DOH_PORT"
}

_resolv_provider_ips() { awk '/^nameserver /{print $2}' "$AMNEZIA_RESOLV_AUTO" 2>/dev/null; }
dns_dnsmasq_add_plain() {
  for _ip in $(_resolv_provider_ips); do
    uci -q del_list "dhcp.@dnsmasq[0].server=$_ip"; uci add_list "dhcp.@dnsmasq[0].server=$_ip"
  done
}
dns_dnsmasq_del_plain() {
  for _ip in $(_resolv_provider_ips); do uci -q del_list "dhcp.@dnsmasq[0].server=$_ip"; done
}
dns_dnsmasq_restore() {
  uci -q delete "dhcp.@dnsmasq[0].noresolv" 2>/dev/null || true
  uci -q delete "dhcp.@dnsmasq[0].strictorder" 2>/dev/null || true
  uci -q del_list "dhcp.@dnsmasq[0].server=127.0.0.1#$DOT_PORT"
  uci -q del_list "dhcp.@dnsmasq[0].server=127.0.0.1#$DOH_PORT"
  dns_dnsmasq_del_plain
}

# Render the candidate dnsmasq options we control to a temp file and --test THAT
# (deterministic; never a router-instance hash path). Restart only on pass.
# M5: commit dhcp ONLY after --test passes; revert on failure so a bad candidate
#     is never persisted (would take DNS down on the next dnsmasq restart/reboot).
dns_dnsmasq_reload() {
  _tf=$(mktemp 2>/dev/null || echo /tmp/amz-dnsmasq-test.$$)
  {
    [ "$(uci -q get dhcp.@dnsmasq[0].noresolv)" = 1 ] && echo "no-resolv"
    [ "$(uci -q get dhcp.@dnsmasq[0].strictorder)" = 1 ] && echo "strict-order"
    for _s in $(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null); do echo "server=$_s"; done
    _cd=$(uci -q get dhcp.@dnsmasq[0].confdir 2>/dev/null); [ -n "$_cd" ] && echo "conf-dir=$_cd"
  } > "$_tf"
  if dnsmasq --test -C "$_tf" >/dev/null 2>&1; then
    rm -f "$_tf"
    uci commit dhcp 2>/dev/null || true
    "$AMNEZIA_DNSMASQ_INIT" restart 2>/dev/null || true
    return 0
  fi
  rm -f "$_tf"
  uci revert dhcp 2>/dev/null || true
  return 1
}
