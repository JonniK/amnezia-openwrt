#!/usr/bin/env bats
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/luci-app-amnezia/view/main.js"
AMZ="$HARNESS_DIR/../openwrt/luci-app-amnezia"
# ALLJS: every shipped JS file (view + modules). Negative guards run over this union.
alljs() { find "$AMZ/view" "$AMZ/amnezia" -name '*.js' 2>/dev/null; }
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
@test "no pbr panel anywhere (Issue #9)" {
  for f in $(alljs); do ! grep -qE "pbr-status|pbr-reload|handlePbrReload" "$f"; done
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

@test "no fs.write() in any module (argv-only channel)" {
  for f in $(alljs); do ! grep -qE "fs\.write\s*\(" "$f"; done
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

# ── Phase 8 additions (autolearn) ───────────────────────────────────────────

@test "main.js wires the autolearn toggle and list" {
  grep -q 'autolearn' "$F"
  grep -q 'amnezia-autolearn-ctl' "$F"
  grep -q 'set-enabled' "$F"
}
@test "acl grants exec on amnezia-autolearn-ctl" {
  ACL="$HARNESS_DIR/../openwrt/luci-app-amnezia/acl/luci-app-amnezia.json"
  grep -q 'amnezia-autolearn-ctl' "$ACL"
}

# ── DoT additions ────────────────────────────────────────────────────────────
@test "main.js wires the DoT toggle + provider dropdown + plaintext warning" {
  JS="$HARNESS_DIR/../openwrt/luci-app-amnezia/view/main.js"
  grep -q "amnezia-dns-ctl" "$JS"
  grep -Eq "'enable'|\"enable\"" "$JS"
  grep -q "set-provider" "$JS"
  grep -q "active_tier" "$JS"
  grep -q "plaintext" "$JS"
}

@test "renderDnsRow has a focus guard (M8: no poll-clobber on active DoT controls)" {
  # Guard must be present: box.contains(document.activeElement) inside renderDnsRow.
  grep -q "box.contains(document.activeElement)" "$F"
}

@test "DNS_PROVIDERS does not include 'custom' (M7: dead-end provider removed)" {
  # 'custom' made dns_profile fail with no recovery path; removed from the dropdown.
  ! grep -qE "DNS_PROVIDERS\s*=\s*\[.*'custom'" "$F"
}

# ── Phase 1: util.js + harness ───────────────────────────────────────────────

@test "util.js exists and exports the cross-cutting helpers" {
  U="$AMZ/amnezia/util.js"
  node --check "$U"
  for fn in fmtDur fmtAge verdictColor uiConfirm; do grep -q "$fn" "$U"; done
}
@test "render harness loads every module + executes render with no ReferenceError" {
  run node "$HARNESS_DIR/../test/lib/luci-harness.js"
  [ "$status" -eq 0 ]
}
