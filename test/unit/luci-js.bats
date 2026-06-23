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

@test "routing module has handleRoutingMode calling set-routing-mode" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "handleRoutingMode" "$R"
  grep -q "set-routing-mode" "$R"
}

@test "routing module has handleSourceToggle calling set-source" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "handleSourceToggle" "$R"
  grep -q "set-source" "$R"
}

@test "routing module has handleForceUpdate calling amnezia-force-update" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "handleForceUpdate" "$R"
  grep -q "amnezia-force-update" "$R"
}

@test "routing module has handleSaveManual calling amnezia-force-load save-manual" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "handleSaveManual" "$R"
  grep -q "save-manual" "$R"
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

@test "routing module has routing-mode select with tunnel-default and direct-default options" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "routing-mode-select" "$R"
  grep -q "tunnel-default" "$R"
  grep -q "direct-default" "$R"
}

@test "routing module has manual-list textarea prefilled with forceTunnelList" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "manual-list-ta" "$R"
  grep -q "forceTunnelList" "$R"
}

@test "routing module has paintForceStamp that reads force-update.json stamp" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "paintForceStamp" "$R"
  grep -q "force-when" "$R"
}

@test "main.js failover-tunnel-table anchor is preserved (poll self-unregister)" {
  grep -q "failover-tunnel-table" "$F"
}

# ── Phase 8 additions (autolearn) ───────────────────────────────────────────

@test "autolearn.js wires the autolearn toggle and list" {
  A="$AMZ/amnezia/section/autolearn.js"
  grep -q 'autolearn' "$A"
  grep -q 'amnezia-autolearn-ctl' "$A"
  grep -q 'set-enabled' "$A"
}
@test "acl grants exec on amnezia-autolearn-ctl" {
  ACL="$HARNESS_DIR/../openwrt/luci-app-amnezia/acl/luci-app-amnezia.json"
  grep -q 'amnezia-autolearn-ctl' "$ACL"
}

# ── Phase 4: dns.js ──────────────────────────────────────────────────────────

@test "dns.js owns DoT toggle/provider + focus-guard, no 'custom' provider" {
  D="$AMZ/amnezia/section/dns.js"; node --check "$D"
  grep -q "DNS_PROVIDERS" "$D"                        # positive anchor
  grep -q "box.contains(document.activeElement)" "$D" # focus-guard
  grep -q "amnezia-dns-ctl" "$D"
  ! grep -qE "DNS_PROVIDERS\s*=\s*\[.*'custom'" "$D"  # negative, anchored
}

@test "dns.js wires the DoT toggle + provider dropdown + plaintext warning" {
  D="$AMZ/amnezia/section/dns.js"
  grep -q "amnezia-dns-ctl" "$D"
  grep -Eq "'enable'|\"enable\"" "$D"
  grep -q "set-provider" "$D"
  grep -q "active_tier" "$D"
  grep -q "plaintext" "$D"
}

@test "renderDnsRow has a focus guard (M8: no poll-clobber on active DoT controls)" {
  # Guard must be present: box.contains(document.activeElement) inside renderDnsRow.
  D="$AMZ/amnezia/section/dns.js"
  grep -q "box.contains(document.activeElement)" "$D"
}

@test "DNS_PROVIDERS does not include 'custom' (M7: dead-end provider removed)" {
  # 'custom' made dns_profile fail with no recovery path; removed from the dropdown.
  D="$AMZ/amnezia/section/dns.js"
  ! grep -qE "DNS_PROVIDERS\s*=\s*\[.*'custom'" "$D"
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

# ── Phase 2: routing.js ──────────────────────────────────────────────────────

@test "routing.js owns routing/allowlist handlers + applyFailoverState" {
  R="$AMZ/amnezia/section/routing.js"; node --check "$R"
  for s in handleRoutingMode handleSourceToggle handleForceUpdate handleSaveManual handleRuUpdate applyFailoverState routing-mode-select; do grep -q "$s" "$R"; done
}

# ── Phase 3: zapret.js ──────────────────────────────────────────────────────

@test "zapret.js owns probe/verify/blockcheck/apply + zapret in-flight state" {
  Z="$AMZ/amnezia/section/zapret.js"; node --check "$Z"
  for s in handleProbe handleVerify handleBlockcheckRun handleApply handleRevert applyInFlight candidatesSig paintApply; do grep -q "$s" "$Z"; done
}

# ── Phase 5: autolearn.js ─────────────────────────────────────────────────────

@test "autolearn.js wires toggle/list + row handlers" {
  A="$AMZ/amnezia/section/autolearn.js"; node --check "$A"
  for s in amnezia-autolearn-ctl set-enabled handleAutolearnVeto handleAutolearnPromote handleAutolearnPurge; do grep -q "$s" "$A"; done
}
