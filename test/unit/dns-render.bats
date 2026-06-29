#!/usr/bin/env bats
load '../lib/harness.bash'
LIB="$HARNESS_DIR/../openwrt/lib/amnezia-dns-lib.sh"

@test "quad9 profile resolves; DoT-IP distinct from DoH-bootstrap-IP" {
  run sh -c ". '$LIB'; dns_profile quad9 && printf '%s|%s|%s|%s' \
    \"\$DNS_DOT_IP\" \"\$DNS_DOT_HOST\" \"\$DNS_DOH_HOST\" \"\$DNS_DOH_BOOTSTRAP\""
  [ "$status" -eq 0 ]
  [ "$output" = "9.9.9.9|dns.quad9.net|dns.quad9.net|149.112.112.112" ]
}

@test "every shipped profile yields DoT-IP != DoH-bootstrap-IP" {
  for p in quad9 adguard dns0 mullvad google; do
    run sh -c ". '$LIB'; dns_profile $p && [ \"\$DNS_DOT_IP\" != \"\$DNS_DOH_BOOTSTRAP\" ] && echo ok"
    [ "$status" -eq 0 ] || { echo "profile $p failed invariant"; false; }
    [ "$output" = "ok" ]
  done
}

@test "custom profile accepts a hostname DoH URL + bootstrap IP" {
  export UCI_GET_amnezia_config_dot_resolver='1.2.3.4@853#dot.example'
  export UCI_GET_amnezia_config_doh_resolver='https://doh.example/dns-query'
  export UCI_GET_amnezia_config_doh_bootstrap='5.6.7.8'
  run sh -c ". '$LIB'; dns_profile custom && printf '%s|%s|%s' \"\$DNS_DOT_IP\" \"\$DNS_DOH_HOST\" \"\$DNS_DOH_BOOTSTRAP\""
  [ "$status" -eq 0 ]
  [ "$output" = "1.2.3.4|doh.example|5.6.7.8" ]
}

@test "custom rejects an IP-literal DoH host" {
  export UCI_GET_amnezia_config_dot_resolver='1.2.3.4@853#dot.example'
  export UCI_GET_amnezia_config_doh_resolver='https://9.9.9.9/dns-query'
  export UCI_GET_amnezia_config_doh_bootstrap='5.6.7.8'
  run sh -c ". '$LIB'; dns_profile custom"
  [ "$status" -ne 0 ]
}

@test "custom rejects a missing bootstrap IP" {
  export UCI_GET_amnezia_config_dot_resolver='1.2.3.4@853#dot.example'
  export UCI_GET_amnezia_config_doh_resolver='https://doh.example/dns-query'
  run sh -c ". '$LIB'; dns_profile custom"
  [ "$status" -ne 0 ]
}

@test "unknown profile returns non-zero" {
  run sh -c ". '$LIB'; dns_profile bogus"
  [ "$status" -ne 0 ]
}

@test "_uci_drop_all deletes one delete per stock section (count via type lines)" {
  export UCI_SHOW_stubby=$'stubby.@resolver[0]=resolver\nstubby.@resolver[1]=resolver'
  run sh -c ". '$LIB'; _uci_drop_all stubby resolver"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'delete stubby.@resolver\[0\]' "$STUB_LOG")" = "2" ]
}

@test "stubby render: drop stock then one DoT resolver + short timeout" {
  export UCI_SHOW_stubby=$'stubby.@resolver[0]=resolver'
  export AMNEZIA_STUBBY_INIT=stubby
  run sh -c ". '$LIB'; dns_profile quad9; dns_render_stubby"
  [ "$status" -eq 0 ]
  grep -q "delete stubby.@resolver\[0\]" "$STUB_LOG"
  grep -q "address=9.9.9.9" "$STUB_LOG"
  grep -q "tls_auth_name=dns.quad9.net" "$STUB_LOG"
  grep -q "tls_connection_timeout=2" "$STUB_LOG"
  # Regression: the init's start_service no-ops unless ENABLED, so a bare restart
  # launches nothing (no listener → verify fails → enable auto-reverts). Must enable first.
  grep -q "stubby enable" "$STUB_LOG"
  grep -q "stubby restart" "$STUB_LOG"
}

@test "doh render: hostname URL + bootstrap IP + port 5454 (no IP-literal)" {
  export UCI_SHOW_https_dns_proxy=$'https-dns-proxy.@https-dns-proxy[0]=https-dns-proxy'
  export AMNEZIA_DOH_INIT=https-dns-proxy
  run sh -c ". '$LIB'; dns_profile adguard; dns_render_doh"
  [ "$status" -eq 0 ]
  grep -q "resolver_url=https://dns.adguard-dns.com/dns-query" "$STUB_LOG"
  grep -q "bootstrap_dns=94.140.15.15" "$STUB_LOG"
  grep -q "listen_port=5454" "$STUB_LOG"
  grep -q "https-dns-proxy enable" "$STUB_LOG"
  grep -q "https-dns-proxy restart" "$STUB_LOG"
}

@test "no Cloudflare endpoint appears in any rendered argv" {
  export UCI_SHOW_stubby=$'stubby.@resolver[0]=resolver'
  export UCI_SHOW_https_dns_proxy=$'https-dns-proxy.@https-dns-proxy[0]=https-dns-proxy'
  export AMNEZIA_STUBBY_INIT=stubby
  export AMNEZIA_DOH_INIT=https-dns-proxy
  run sh -c ". '$LIB'; dns_profile quad9; dns_render_stubby; dns_render_doh"
  [ "$status" -eq 0 ]
  run grep -Ei "1\.1\.1\.1|1\.0\.0\.1|cloudflare" "$STUB_LOG"
  [ "$status" -ne 0 ]
}
