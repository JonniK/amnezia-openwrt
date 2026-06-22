#!/usr/bin/env bats
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/luci-app-amnezia/view/main.js"
@test "main.js parses and references the failover state file + per-tunnel table" {
  node --check "$F"
  grep -q "amnezia-failover.json" "$F"
  grep -q "renderTunnelTable" "$F"
  grep -q "parseFailoverState" "$F"
}
@test "main.js still reads seed-must-tunnel.list at the existing runtime path (~line 962)" {
  grep -q "seed-must-tunnel.list" "$F"
}
@test "panel calls amnezia-failover-ctl matching the helper installed name" {
  # The ctl helper is installed as amnezia-failover-ctl (see F3/ACL).
  grep -q "amnezia-failover-ctl" "$F"
}
@test "pbr panel is gone: no pbr-status or pbr-reload exec calls" {
  # Issue #9: pbr binaries no longer exist; the panel must be fully removed.
  ! grep -q "pbr-status" "$F"
  ! grep -q "pbr-reload" "$F"
  ! grep -q "pbr-reload-btn" "$F"
  ! grep -q "handlePbrReload" "$F"
}
@test "failover tunnel panel is present: renderTunnelTable and failover-tunnel-table id" {
  grep -q "renderTunnelTable" "$F"
  grep -q "failover-tunnel-table" "$F"
  grep -q "Failover tunnels" "$F"
}
@test "handshake_age is rendered directly as age-in-seconds (no Date.now subtract)" {
  # Issue MED: producer emits age-in-seconds; consumer must not double-convert via Date.now().
  # Ensure the stale pattern is gone and the direct path is present.
  ! grep -q "Date.now().*handshake_age\|handshake_age.*Date.now()" "$F"
  grep -q "age < 0.*never\|age < 60.*ago" "$F"
}

# ── Phase E additions ────────────────────────────────────────────────────────

@test "main.js contains decodeVpnLink function" {
  grep -q "function decodeVpnLink" "$F"
}

@test "main.js decodeVpnLink returns null for non-vpn:// prefix" {
  grep -q "indexOf('vpn://') !== 0" "$F"
}

@test "main.js has handleAddTunnel handler" {
  grep -q "handleAddTunnel" "$F"
}

@test "main.js has handleTunnelRemove handler calling amnezia-tunnel-ctl remove" {
  grep -q "handleTunnelRemove" "$F"
  grep -q "amnezia-tunnel-ctl.*remove\|remove.*amnezia-tunnel-ctl" "$F"
}

@test "main.js has handleRoutingMode calling set-routing-mode" {
  grep -q "handleRoutingMode" "$F"
  grep -q "set-routing-mode" "$F"
}

@test "main.js has handleSourceToggle calling set-source" {
  grep -q "handleSourceToggle" "$F"
  grep -q "set-source" "$F"
}

@test "main.js has handleForceUpdate calling amnezia-force-update" {
  grep -q "handleForceUpdate" "$F"
  grep -q "amnezia-force-update" "$F"
}

@test "main.js has handleSaveManual calling amnezia-force-load save-manual" {
  grep -q "handleSaveManual" "$F"
  grep -q "save-manual" "$F"
}

@test "main.js reads force-tunnel.list and force-update.json in load()" {
  grep -q "force-tunnel.list" "$F"
  grep -q "force-update.json" "$F"
}

@test "main.js has Remove button in renderTunnelTable (per-row remove column)" {
  grep -q "awg-remove-" "$F"
  grep -q "handleTunnelRemove" "$F"
}

@test "main.js uses no fs.write() calls anywhere (argv-only channel)" {
  # Match actual call sites (fs.write followed by opening paren), not comments.
  ! grep -qE "fs\.write\s*\(" "$F"
}

@test "main.js add-tunnel section has textarea and Add tunnel button" {
  grep -q "add-tunnel-conf" "$F"
  grep -q "add-tunnel-btn" "$F"
}

@test "main.js routing-mode select has tunnel-default and direct-default options" {
  grep -q "routing-mode-select" "$F"
  grep -q "tunnel-default" "$F"
  grep -q "direct-default" "$F"
}

@test "main.js manual-list section has textarea prefilled with forceTunnelList" {
  grep -q "manual-list-ta" "$F"
  grep -q "forceTunnelList" "$F"
}

@test "main.js paintForceStamp reads force-update.json stamp" {
  grep -q "paintForceStamp" "$F"
  grep -q "force-when" "$F"
}

@test "main.js failover-tunnel-table anchor is preserved (poll self-unregister)" {
  grep -q "failover-tunnel-table" "$F"
}

@test "main.js wires the DoT toggle + provider dropdown + plaintext warning" {
  JS="$HARNESS_DIR/../openwrt/luci-app-amnezia/view/main.js"
  grep -q "amnezia-dns-ctl" "$JS"
  grep -Eq "'enable'|\"enable\"" "$JS"
  grep -q "set-provider" "$JS"
  grep -q "active_tier" "$JS"
  grep -q "plaintext" "$JS"
}
