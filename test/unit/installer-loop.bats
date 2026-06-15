#!/usr/bin/env bats
load '../lib/harness.bash'

@test "installer iterates enabled tunnels and folds all into vpn zone" {
  UCI_FAKE_TUNNELS="awg1 awg2" run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --dry-run-all
  echo "$output" | grep -q "firewall.vpn.network=awg1 awg2"
  echo "$output" | grep -q "network.awg1=interface"
  echo "$output" | grep -q "network.awg2=interface"
}
