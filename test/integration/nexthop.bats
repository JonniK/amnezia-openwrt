#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { _require_linux_nft || skip "needs Linux nft/ip"; }
@test "resilient nexthop replace with buckets succeeds in a netns" {
  run sudo ip netns add amznhtest
  sudo ip netns exec amznhtest ip link add dummy0 type dummy
  sudo ip netns exec amznhtest ip link set dummy0 up
  sudo ip netns exec amznhtest ip nexthop add id 10 dev dummy0
  run sudo ip netns exec amznhtest ip nexthop replace id 101 group 10,1 type resilient buckets 128 idle_timer 120
  [ "$status" -eq 0 ]
  sudo ip netns del amznhtest
}
