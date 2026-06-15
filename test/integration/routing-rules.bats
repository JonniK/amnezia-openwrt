#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { _require_linux_nft || skip "needs Linux"; }
@test "real ip rule add/show roundtrip in a netns" {
  run sudo ip netns add amztest
  sudo ip netns exec amztest ip rule add fwmark 0x0b0000/0x0ff0000 lookup 101
  run sudo ip netns exec amztest ip rule show
  [[ "$output" == *"fwmark 0x0b0000/0xff0000 lookup 101"* ]]
  sudo ip netns del amztest
}
