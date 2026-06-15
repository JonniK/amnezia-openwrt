#!/usr/bin/env bats
load '../lib/harness.bash'
@test "ctl sets uci mode and restarts monitor" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh" set-mode balance
  grep -q "uci set amnezia.globals.mode=balance" "$STUB_LOG"
  grep -q "uci commit amnezia" "$STUB_LOG"
}
@test "ctl rejects invalid mode" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh" set-mode bogus
  [ "$status" -ne 0 ]
}
@test "ctl set-sticky writes uci and commits" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh" set-sticky awg2
  [ "$status" -eq 0 ]
  grep -q "uci set amnezia.globals.sticky_target=awg2" "$STUB_LOG"
  grep -q "uci commit amnezia" "$STUB_LOG"
}
@test "ctl set-sticky rejects empty arg" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh" set-sticky
  [ "$status" -ne 0 ]
}
@test "ctl set-weight writes uci weight for named tunnel" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh" set-weight awg1 3
  [ "$status" -eq 0 ]
  grep -q "uci set amnezia.awg1.weight=3" "$STUB_LOG"
  grep -q "uci commit amnezia" "$STUB_LOG"
}
@test "ctl set-weight rejects missing args" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh" set-weight awg1
  [ "$status" -ne 0 ]
}
@test "ctl set-weight rejects invalid tunnel name" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh" set-weight "../../etc/passwd" 3
  [ "$status" -ne 0 ]
}
@test "ctl set-weight rejects non-integer weight" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh" set-weight awg1 "3;rm -rf /"
  [ "$status" -ne 0 ]
}
@test "ctl toggle enables a tunnel" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh" toggle awg2
  [ "$status" -eq 0 ]
  grep -q "uci commit amnezia" "$STUB_LOG"
}
@test "ctl toggle rejects invalid tunnel name" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh" toggle "../../etc/passwd"
  [ "$status" -ne 0 ]
}
@test "ctl rejects unknown command" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh" frobnicate
  [ "$status" -ne 0 ]
}
