#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; }

@test "parse_awg_conf extracts interface+peer fields" {
  parse_awg_conf "$HARNESS_DIR/../test/fixtures/awg-sample.conf"
  [ "$AWG_PrivateKey" = "AAA_priv" ]
  [ "$AWG_Address" = "10.8.0.2/24" ]
  [ "$AWG_Jc" = "4" ]
  [ "$AWG_PublicKey" = "BBB_pub" ]
  [ "$AWG_Endpoint_host" = "vpn.example.com" ]
  [ "$AWG_Endpoint_port" = "51820" ]
  [ "$AWG_PersistentKeepalive" = "25" ]
}
@test "parse_awg_conf strips CR from CRLF files (no trailing CR in port)" {
  parse_awg_conf "$HARNESS_DIR/../test/fixtures/awg-crlf.conf"
  # AWG_Endpoint_port must equal exactly "51820" with no trailing \r
  [ "$AWG_Endpoint_port" = "51820" ]
}
@test "parse_awg_conf fails cleanly on missing file" {
  run parse_awg_conf /no/such/file
  [ "$status" -ne 0 ]
}
@test "parse_awg_conf does not leak PSK from first conf into second PSK-less conf" {
  # Parse a conf that HAS a PresharedKey first.
  parse_awg_conf "$HARNESS_DIR/../test/fixtures/awg-sample.conf"
  [ "$AWG_PresharedKey" = "CCC_psk" ]
  # Now parse a conf that has NO PresharedKey -- AWG_PresharedKey must be empty.
  parse_awg_conf "$HARNESS_DIR/../test/fixtures/awg-nopsk.conf"
  [ -z "${AWG_PresharedKey:-}" ]
}
