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
