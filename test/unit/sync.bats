#!/usr/bin/env bats
load '../lib/harness.bash'

@test "sync covers monitor/lib/nft/init and drops pbr.d template references" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-failover" "$F"
  grep -q "lib/amnezia-common.sh" "$F"
  grep -q "nftables.d/30-amnezia-classify.nft" "$F"
  grep -q "configure-dnsmasq-amnezia.sh" "$F"
  # These pbr.d references must be gone -- strings that actually appear in the old script:
  ! grep -q "pbr.d/ru-direct.sh" "$F"
  ! grep -q "/etc/pbr.d" "$F"
  ! grep -q "99-lan-vpn" "$F"
}
@test "sync includes all new runtime paths" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-failover" "$F"
  grep -q "amnezia-failover.init" "$F"
  grep -q "amnezia-routing.sh" "$F"
  grep -q "iproute2-amnezia-rt_tables.conf" "$F"
}

# F2: new runtime paths added by Phase F
@test "sync maps amnezia-tunnel-ctl to /usr/bin" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-tunnel-ctl" "$F"
}
@test "sync maps amnezia-force-load to /usr/bin" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-force-load" "$F"
}
@test "sync maps amnezia-force-update to /usr/bin" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-force-update" "$F"
}
@test "sync maps amnezia-tunnel-lib.sh to /usr/lib/amnezia" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-tunnel-lib.sh" "$F"
}
@test "sync maps 99-amnezia-force-load.hotplug to /etc/hotplug.d/firewall" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "99-amnezia-force-load.hotplug" "$F"
}
@test "sync maps 30-amnezia-classify-direct.nft to /etc/nftables.d" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "30-amnezia-classify-direct.nft" "$F"
}
@test "sync ships both .nft fragments to /usr/share/amnezia/nftables.d" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "usr/share/amnezia/nftables.d" "$F"
}
@test "sync seeds force-tunnel.list to /etc/amnezia" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "force-tunnel.list" "$F"
}
@test "sync seeds force.d dir to /etc/amnezia" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "force.d" "$F"
}
@test "sync maps decode-vpn.mjs into luci package files" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "decode-vpn.mjs" "$F"
}
@test "packages contain amnezia-tunnel-ctl in /usr/bin after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/usr/bin/amnezia-tunnel-ctl" ]
}
@test "packages contain amnezia-force-load in /usr/bin after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/usr/bin/amnezia-force-load" ]
}
@test "packages contain amnezia-force-update in /usr/bin after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/usr/bin/amnezia-force-update" ]
}
@test "packages contain amnezia-tunnel-lib.sh in /usr/lib/amnezia after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/usr/lib/amnezia/amnezia-tunnel-lib.sh" ]
}
@test "packages contain 99-amnezia-force-load in /etc/hotplug.d/firewall after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/etc/hotplug.d/firewall/99-amnezia-force-load" ]
}
@test "packages contain 30-amnezia-classify-direct.nft in /etc/nftables.d after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/etc/nftables.d/30-amnezia-classify-direct.nft" ]
}
@test "packages contain both .nft fragments in /usr/share/amnezia/nftables.d after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/usr/share/amnezia/nftables.d/30-amnezia-classify.nft" ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/usr/share/amnezia/nftables.d/30-amnezia-classify-direct.nft" ]
}
@test "packages contain seeded force-tunnel.list in /etc/amnezia after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/etc/amnezia/force-tunnel.list" ]
}
@test "packages contain force.d dir in /etc/amnezia after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -d "$HARNESS_DIR/../packages/amnezia-pbr/files/etc/amnezia/force.d" ]
}
@test "packages contain decode-vpn.mjs in luci package after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/luci-app-amnezia/files/www/luci-static/resources/view/amnezia/decode-vpn.mjs" ]
}
@test "sync script copies the new DNS files into the packages tree" {
  S="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-dns-ctl" "$S"
  grep -q "amnezia-dns-lib.sh" "$S"
  grep -q "amnezia-dns" "$S"            # init
  grep -q "99-amnezia-dns" "$S"         # hotplug
}

# Phase 9 (covert-creator-router plan): explicit per-file cp-line greps --
# a never-added cp line yields a *clean* diff (file absent from both trees),
# so only an explicit name-grep catches the omission.
@test "sync maps amnezia-covert-ctl.sh to /usr/bin" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-covert-ctl" "$F"
}
@test "sync maps amnezia-covert-run.sh to /usr/lib/amnezia" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-covert-run.sh" "$F"
}
@test "sync maps amnezia-covert-logwrap.sh to /usr/lib/amnezia" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-covert-logwrap.sh" "$F"
}
@test "sync maps amnezia-covert.init to /etc/init.d/amnezia-covert" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-covert.init" "$F"
}
@test "sync maps 40-amnezia-covert-egress.nft into the sync script" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "40-amnezia-covert-egress.nft" "$F"
}
@test "packages contain amnezia-covert-ctl in /usr/bin after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/usr/bin/amnezia-covert-ctl" ]
}
@test "packages contain amnezia-covert-run.sh and amnezia-covert-logwrap.sh in /usr/lib/amnezia after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/usr/lib/amnezia/amnezia-covert-run.sh" ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/usr/lib/amnezia/amnezia-covert-logwrap.sh" ]
  # Both are EXECUTED (procd command / exec'd by the launcher) -- must ship executable.
  [ -x "$HARNESS_DIR/../packages/amnezia-pbr/files/usr/lib/amnezia/amnezia-covert-run.sh" ]
  [ -x "$HARNESS_DIR/../packages/amnezia-pbr/files/usr/lib/amnezia/amnezia-covert-logwrap.sh" ]
}
@test "packages contain amnezia-covert init at /etc/init.d/amnezia-covert after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/etc/init.d/amnezia-covert" ]
}
@test "template_not_in_etc_nftables: covert egress template ships ONLY to /usr/share, never /etc/nftables.d" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/usr/share/amnezia/nftables.d/40-amnezia-covert-egress.nft" ]
  [ ! -f "$HARNESS_DIR/../packages/amnezia-pbr/files/etc/nftables.d/40-amnezia-covert-egress.nft" ]
}
