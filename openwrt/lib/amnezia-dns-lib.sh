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
      # reject IP-literal host: must contain at least one non-digit, non-dot label char
      printf '%s' "$DNS_DOH_HOST" | grep -q '[A-Za-z]' || return 1
      [ -n "$DNS_DOT_IP" ] && [ -n "$DNS_DOH_HOST" ] && [ -n "$DNS_DOH_BOOTSTRAP" ] || return 1
      ;;
    *) return 1 ;;
  esac
  [ -n "$DNS_DOT_IP" ] && [ "$DNS_DOT_IP" != "$DNS_DOH_BOOTSTRAP" ]
}
