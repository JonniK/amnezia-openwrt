#!/usr/bin/env bats
load '../lib/harness.bash'
@test "Phase B scripts pass shellcheck" {
  cd "$HARNESS_DIR/.."
  run shellcheck -s sh \
    openwrt/lib/amnezia-common.sh \
    openwrt/lib/amnezia-dns-lib.sh \
    openwrt/amnezia-ru-cidr.sh \
    openwrt/amnezia-status.sh \
    openwrt/configure-dnsmasq-amnezia.sh
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
