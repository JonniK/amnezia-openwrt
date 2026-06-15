#!/usr/bin/env bats
load '../lib/harness.bash'

@test "stubs are on PATH and log their args" {
  run uci show network
  [ "$status" -eq 0 ]
  run cat "$STUB_LOG"
  [[ "$output" == *"uci show network"* ]]
}

@test "nft stub records ruleset adds" {
  nft add element inet fw4 amnezia_ru4 '{ 1.2.3.0/24 }'
  run cat "$STUB_LOG"
  [[ "$output" == *"nft add element inet fw4 amnezia_ru4"* ]]
}
