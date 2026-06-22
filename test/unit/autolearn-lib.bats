#!/usr/bin/env bats
load '../lib/harness.bash'
LIB="$HARNESS_DIR/../openwrt/lib/amnezia-autolearn-lib.sh"
setup() { . "$LIB"; }

@test "uci stub: UCI_GET_* override resolves, unset key exits non-zero" {
  export UCI_GET_amnezia_config_autolearn_enabled="1"
  run uci -q get amnezia.config.autolearn_enabled
  [ "$status" -eq 0 ]; [ "$output" = "1" ]
  run uci -q get amnezia.config.does_not_exist
  [ "$status" -ne 0 ]; [ -z "$output" ]
}
@test "uci stub: existing hardcoded routing_mode default preserved when unset" {
  run uci -q get amnezia.config.routing_mode
  [ "$output" = "tunnel-default" ]    # unchanged for state-write.bats
}

@test "al_ip_is_public accepts a global address" {
  run al_ip_is_public 8.8.8.8
  [ "$status" -eq 0 ]
}
@test "al_ip_is_public rejects RFC1918 / loopback / CGNAT / link-local / multicast" {
  for ip in 10.0.0.1 192.168.1.1 172.16.5.5 127.0.0.1 169.254.1.1 100.64.0.1 224.0.0.1 0.0.0.0 240.0.0.1; do
    run al_ip_is_public "$ip"; [ "$status" -eq 1 ] || { echo "leaked $ip"; return 1; }
  done
}
@test "al_ip_is_public rejects non-dotted-quad garbage" {
  run al_ip_is_public "not.an.ip"; [ "$status" -eq 1 ]
  run al_ip_is_public "8.8.8";     [ "$status" -eq 1 ]
  run al_ip_is_public "8.8.8.999"; [ "$status" -eq 1 ]
}

@test "al_name_is_probeable accepts a public FQDN" {
  run al_name_is_probeable example.com; [ "$status" -eq 0 ]
}
@test "al_name_is_probeable rejects bare host, reserved TLDs, IP-literals, bad charset" {
  for n in localhost router box.lan x.local svc.internal a.localdomain h.home.arpa 8.8.8.8 "bad space" ".."; do
    run al_name_is_probeable "$n"; [ "$status" -eq 1 ] || { echo "accepted $n"; return 1; }
  done
}

@test "al_resolve_public returns the first public A and skips private ones" {
  export NSLOOKUP_ADDR="10.0.0.5 93.184.216.34"
  run al_resolve_public example.com
  [ "$status" -eq 0 ]; [ "$output" = "93.184.216.34" ]
}
@test "al_resolve_public is empty when all answers are private" {
  export NSLOOKUP_ADDR="10.0.0.5 192.168.1.9"
  run al_resolve_public example.com
  [ -z "$output" ]
}
@test "al_router_lan_cidrs reads configured LAN address" {
  export UCI_SHOW_network="network.lan=interface"   # stub: drives uci -q show network
  export UCI_GET_network_lan_ipaddr="192.168.1.1"
  export UCI_GET_network_lan_netmask="255.255.255.0"
  run al_router_lan_cidrs
  echo "$output" | grep -q "192.168.1."
}
@test "al_resolve_public rejects a PUBLIC address that is inside the router LAN" {
  export UCI_SHOW_network="network.lan=interface"
  export UCI_GET_network_lan_ipaddr="93.184.216.1"   # public-looking LAN (test)
  export NSLOOKUP_ADDR="93.184.216.34"               # same /24 as router LAN
  run al_resolve_public example.com
  [ -z "$output" ]                                    # rejected as same-LAN
}

@test "al_querylog_pairs extracts domain+client only from query[ lines past offset" {
  log="$BATS_TEST_TMPDIR/q.log"
  printf 'Jun 22 query[A] skip.example from 192.168.1.9\n' > "$log"   # pre-offset
  off=$(wc -c < "$log")
  {
    printf 'Jun 22 query[A] foo.com from 192.168.1.10\n'
    printf 'Jun 22 reply foo.com is 1.2.3.4\n'
    printf 'Jun 22 cached bar.com is 5.6.7.8\n'
    printf 'Jun 22 query[AAAA] baz.com from 192.168.1.11\n'
  } >> "$log"
  run al_querylog_pairs "$log" "$off"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^foo.com 192.168.1.10$'
  echo "$output" | grep -q '^baz.com 192.168.1.11$'
  ! echo "$output" | grep -q 'skip.example'   # before offset
  ! echo "$output" | grep -q 'bar.com'         # not a query[ line
}

@test "al_deny_match matches domain and subdomains, not look-alikes" {
  deny="$BATS_TEST_TMPDIR/deny.list"; printf 'example.com\nfoo.org\n' > "$deny"
  run al_deny_match example.com "$deny";      [ "$status" -eq 0 ]
  run al_deny_match www.example.com "$deny";  [ "$status" -eq 0 ]
  run al_deny_match a.b.foo.org "$deny";       [ "$status" -eq 0 ]
  run al_deny_match notexample.com "$deny";    [ "$status" -eq 1 ]
  run al_deny_match example.com.evil.net "$deny"; [ "$status" -eq 1 ]
  run al_deny_match other.net "$deny";          [ "$status" -eq 1 ]
}
@test "al_deny_match returns no-match on missing/empty denyfile" {
  run al_deny_match x.com /nonexistent;        [ "$status" -eq 1 ]
}
