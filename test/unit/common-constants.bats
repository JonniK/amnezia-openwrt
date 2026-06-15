#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; }

@test "fwmark constants match the design contract" {
  [ "$STICKY_MARK" = "0x0A0000" ]
  [ "$POOL_MARK" = "0x0B0000" ]
  [ "$MARK_MASK" = "0x0FF0000" ]
}
@test "table ids match contract" {
  [ "$TBL_STICKY" = "100" ]
  [ "$TBL_POOL" = "101" ]
}
@test "member conntrack mark is low-byte and never collides with selector nibble" {
  run member_ctmark 3
  [ "$output" = "0x000003" ]
}
