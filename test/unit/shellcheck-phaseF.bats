#!/usr/bin/env bats
# Phase F: shellcheck coverage for runtime scripts not already covered by
# shellcheck-phaseB.bats (lib/amnezia-common.sh, lib/amnezia-dns-lib.sh,
# amnezia-dns-ctl.sh, amnezia-ru-cidr.sh, amnezia-status.sh,
# configure-dnsmasq-amnezia.sh) or shellcheck-phaseE.bats (amnezia-failover,
# amnezia-failover.init, amnezia-failover-ctl.sh, amnezia-dns.init,
# 99-amnezia-dns.hotplug).
load '../lib/harness.bash'
@test "Phase F scripts pass shellcheck" {
  cd "$HARNESS_DIR/.."
  run shellcheck --severity=warning -s sh \
    openwrt/amnezia-blackbox.sh \
    openwrt/amnezia-autotunnel.sh \
    openwrt/amnezia-force-load.sh \
    openwrt/amnezia-force-update.sh \
    openwrt/amnezia-tunnel-ctl.sh \
    openwrt/amnezia-app-ctl.sh \
    openwrt/amnezia-dnsleak-ctl.sh \
    openwrt/lib/amnezia-routing.sh \
    openwrt/lib/amnezia-tunnel-lib.sh \
    openwrt/install-amnezia-pbr.sh \
    openwrt/amnezia-force-load.init \
    openwrt/amnezia-ru-load.init \
    openwrt/amnezia-dnsleak.init \
    openwrt/99-amnezia-dnsleak.hotplug \
    openwrt/99-amnezia-force-load.hotplug \
    openwrt/99-amnezia-ru-load.hotplug \
    openwrt/amnezia-covert-ctl.sh \
    openwrt/amnezia-covert-run.sh \
    openwrt/amnezia-covert-logwrap.sh \
    openwrt/amnezia-covert.init
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
