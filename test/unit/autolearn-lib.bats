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
