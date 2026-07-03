#!/usr/bin/env bats
# Tests for the RU DNS bypass feature (dns_ru_bypass_* helpers + amnezia-dns-ctl verbs).
load '../lib/harness.bash'
LIB="$HARNESS_DIR/../openwrt/lib/amnezia-dns-lib.sh"
CTL="$HARNESS_DIR/../openwrt/amnezia-dns-ctl.sh"
COMMON="$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"

setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export UCI_GET_amnezia_config_dns_provider=quad9
  export UCI_GET_amnezia_config_dot_enabled=1
  export AMZ_DNSMASQ_CONFDIR="$BATS_TEST_TMPDIR/dnsmasq.d"
  export AMNEZIA_RU_BYPASS_LIST="$BATS_TEST_TMPDIR/ru-dns-bypass.list"
  printf 'avito.st\nvk.com\n' > "$AMNEZIA_RU_BYPASS_LIST"
  mkdir -p "$AMZ_DNSMASQ_CONFDIR"
  printf 'nameserver 109.195.112.1\n' > "$BATS_TEST_TMPDIR/resolv.auto"
  export AMNEZIA_RESOLV_AUTO="$BATS_TEST_TMPDIR/resolv.auto"
}

# ── dns_ru_bypass_domains() ──────────────────────────────────────────────────

@test "dns_ru_bypass_domains: includes built-in TLD ru" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_domains"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "ru"
}

@test "dns_ru_bypass_domains: includes built-in TLD su" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_domains"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "su"
}

@test "dns_ru_bypass_domains: includes built-in TLD xn--p1ai" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_domains"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "xn--p1ai"
}

@test "dns_ru_bypass_domains: includes list-file domains" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_domains"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "avito.st"
  echo "$output" | grep -qx "vk.com"
}

@test "dns_ru_bypass_domains: strips leading dot from entries" {
  printf '.example.ru\n' >> "$AMNEZIA_RU_BYPASS_LIST"
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_domains"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "example.ru"
  # dot form must NOT appear
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_domains | grep -Fx '.example.ru'"
  [ "$status" -ne 0 ]
}

@test "dns_ru_bypass_domains: strips comment lines" {
  printf '# this is a comment\n' >> "$AMNEZIA_RU_BYPASS_LIST"
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_domains"
  [ "$status" -eq 0 ]
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_domains | grep -F '#'"
  [ "$status" -ne 0 ]
}

@test "dns_ru_bypass_domains: works without list file (built-ins only)" {
  run sh -c ". '$COMMON'; . '$LIB'; AMNEZIA_RU_BYPASS_LIST=/nonexistent/path.list dns_ru_bypass_domains"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "ru"
  echo "$output" | grep -qx "su"
  echo "$output" | grep -qx "xn--p1ai"
}

# ── dns_ru_bypass_render() ───────────────────────────────────────────────────

@test "dns_ru_bypass_render: creates conf file with server=/ lines" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_render"
  [ "$status" -eq 0 ]
  [ -f "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf" ]
  grep -q "^server=/" "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
}

@test "dns_ru_bypass_render: conf contains built-in TLD ru" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_render"
  [ "$status" -eq 0 ]
  grep -q "/ru/" "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf" || \
    grep -qE "/ru/[0-9]" "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
}

@test "dns_ru_bypass_render: conf contains built-in TLD xn--p1ai" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_render"
  [ "$status" -eq 0 ]
  grep -q "xn--p1ai" "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
}

@test "dns_ru_bypass_render: conf contains list-file domains" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_render"
  [ "$status" -eq 0 ]
  grep -q "avito.st" "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
  grep -q "vk.com" "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
}

@test "dns_ru_bypass_render: uses default resolver 77.88.8.8 when UCI unset" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_render"
  [ "$status" -eq 0 ]
  grep -q "77.88.8.8" "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
}

@test "dns_ru_bypass_render: also emits second default resolver 77.88.8.1" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_render"
  [ "$status" -eq 0 ]
  grep -q "77.88.8.1" "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
}

@test "dns_ru_bypass_render: emits one server= line per resolver IP per chunk (two IPs)" {
  export UCI_GET_amnezia_config_dns_ru_resolver="10.0.0.1 10.0.0.2"
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_render"
  [ "$status" -eq 0 ]
  grep -q "10.0.0.1" "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
  grep -q "10.0.0.2" "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
}

@test "dns_ru_bypass_render: custom single resolver from UCI overrides default" {
  export UCI_GET_amnezia_config_dns_ru_resolver="1.2.3.4"
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_render"
  [ "$status" -eq 0 ]
  grep -q "1.2.3.4" "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
  run grep -q "77.88.8.8" "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
  [ "$status" -ne 0 ]
}

@test "dns_ru_bypass_render: every server= line ≤950 bytes (chunking test with 200 domains)" {
  # Generate 200 long domains to force chunking beyond a single server= line.
  _biglist="$BATS_TEST_TMPDIR/big-list.list"
  : > "$_biglist"
  _i=0
  while [ "$_i" -lt 200 ]; do
    printf 'sub%03d.longdomainname.example.com\n' "$_i" >> "$_biglist"
    _i=$((_i + 1))
  done
  run sh -c ". '$COMMON'; . '$LIB'; AMNEZIA_RU_BYPASS_LIST='$_biglist' dns_ru_bypass_render"
  [ "$status" -eq 0 ]
  [ -f "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf" ]
  # Verify: no line exceeds 950 bytes (domain part ≤900 + server= prefix + / + ip suffix)
  run awk 'length>950{print NR": "length" bytes"; found=1} END{exit found+0}' \
    "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
  [ "$status" -eq 0 ]
  # Verify: chunking actually happened (more than 2 lines for 2 default IPs)
  _nlines=$(wc -l < "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf" | tr -d ' ')
  [ "$_nlines" -gt 2 ]
}

# ── dns_ru_bypass_clear() ────────────────────────────────────────────────────

@test "dns_ru_bypass_clear: removes conf file" {
  sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_render"
  [ -f "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf" ]
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_clear"
  [ "$status" -eq 0 ]
  [ ! -f "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf" ]
}

@test "dns_ru_bypass_clear: is a no-op when conf file absent" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_ru_bypass_clear"
  [ "$status" -eq 0 ]
}

# ── cmd_apply integration ────────────────────────────────────────────────────

@test "apply (encrypted, bypass unset): conf file rendered (default ON)" {
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy \
    AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' apply"
  [ "$status" -eq 0 ]
  [ -f "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf" ]
  grep -q "server=/" "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
}

@test "apply (encrypted, bypass=0): conf file absent" {
  export UCI_GET_amnezia_config_dns_ru_bypass=0
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy \
    AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' apply"
  [ "$status" -eq 0 ]
  [ ! -f "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf" ]
}

@test "apply (no-bin / plaintext): conf file cleared" {
  # Pre-create a conf file; it must be removed on plaintext (no-bin) apply.
  touch "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
  run sh -c "AMNEZIA_HAS_BIN=0 AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' apply"
  [ "$status" -eq 0 ]
  [ ! -f "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf" ]
}

# ── cmd_disable integration ──────────────────────────────────────────────────

@test "disable: conf file removed when dot was enabled" {
  touch "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
  export UCI_GET_amnezia_config_dot_enabled=1
  run sh -c "AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_STUBBY_INIT=stubby \
    AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNS_INIT=amnezia-dns sh '$CTL' disable"
  [ "$status" -eq 0 ]
  [ ! -f "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf" ]
}

# ── ru-bypass verb ───────────────────────────────────────────────────────────

@test "ru-bypass off: sets dns_ru_bypass=0 in UCI and clears conf when dot enabled" {
  touch "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf"
  export UCI_GET_amnezia_config_dot_enabled=1
  export UCI_GET_amnezia_config_dns_ru_bypass=0
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy \
    AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' ru-bypass off"
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dns_ru_bypass=0" "$STUB_LOG"
  [ ! -f "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf" ]
}

@test "ru-bypass on: sets dns_ru_bypass=1 in UCI and renders conf when dot enabled" {
  export UCI_GET_amnezia_config_dot_enabled=1
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy \
    AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' ru-bypass on"
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dns_ru_bypass=1" "$STUB_LOG"
  [ -f "$AMZ_DNSMASQ_CONFDIR/amnezia-ru-dns.conf" ]
}

@test "ru-bypass: invalid verb returns exit 2" {
  run sh -c "sh '$CTL' ru-bypass badverb"
  [ "$status" -eq 2 ]
}

@test "ru-bypass: no extra call to cmd_apply when dot disabled" {
  export UCI_GET_amnezia_config_dot_enabled=0
  run sh -c "sh '$CTL' ru-bypass on"
  [ "$status" -eq 0 ]
  # dnsmasq restart must NOT be logged (no apply ran)
  run grep -q "dnsmasq restart" "$STUB_LOG"
  [ "$status" -ne 0 ]
}

# ── cmd_status JSON ──────────────────────────────────────────────────────────

@test "status: includes ru_bypass:true when dns_ru_bypass unset (default ON)" {
  run sh -c "sh '$CTL' status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ru_bypass":true'
}

@test "status: includes ru_bypass:false when dns_ru_bypass=0" {
  export UCI_GET_amnezia_config_dns_ru_bypass=0
  run sh -c "sh '$CTL' status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ru_bypass":false'
}

@test "status: disabled path also includes ru_bypass field" {
  export UCI_GET_amnezia_config_dot_enabled=0
  run sh -c "sh '$CTL' status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ru_bypass":'
}

@test "status: disabled path ru_bypass:true when bypass unset" {
  export UCI_GET_amnezia_config_dot_enabled=0
  run sh -c "sh '$CTL' status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ru_bypass":true'
}
