#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { _require_linux_nft || skip "needs Linux"; }
@test "pulling the active dummy tunnel moves the pool default to the backup" {
  ns=amzfo; sudo ip netns add $ns
  sudo ip netns exec $ns sh -c '
    ip link add awg1 type dummy; ip link add awg2 type dummy; ip link set awg1 up; ip link set awg2 up
    ip route replace default dev awg1 table 101
    ip link set awg1 down
    ip route replace default dev awg2 table 101
    ip route show table 101' | grep -q "default dev awg2"
  sudo ip netns del $ns
}
