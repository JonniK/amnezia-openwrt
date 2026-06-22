#!/usr/bin/env bats
load '../lib/harness.bash'
@test "Phase E scripts pass shellcheck" {
  cd "$HARNESS_DIR/.."
  run shellcheck --severity=warning -s sh \
    openwrt/amnezia-failover \
    openwrt/amnezia-failover.init \
    openwrt/amnezia-status.sh \
    openwrt/amnezia-failover-ctl.sh \
    openwrt/amnezia-dns.init \
    openwrt/99-amnezia-dns.hotplug
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
