#!/usr/bin/env bats
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/luci-app-amnezia/view/main.js"
AMZ="$HARNESS_DIR/../openwrt/luci-app-amnezia"
# ALLJS: every shipped JS file (view + modules). Negative guards run over this union.
alljs() { find "$AMZ/view" "$AMZ/amnezia" -name '*.js' 2>/dev/null; }
@test "failover state file + per-tunnel table present across shipped JS" {
  node --check "$F"
  # amnezia-failover.json is read in main.js load() and failover.js refresh()
  grep -q "amnezia-failover.json" "$F"
  # renderTunnelTable + parseFailoverState now live in failover.js
  FV="$AMZ/amnezia/section/failover.js"
  grep -q "renderTunnelTable" "$FV"
  grep -q "parseFailoverState" "$FV"
}
@test "main.js still reads seed-must-tunnel.list at the existing runtime path (~line 962)" {
  grep -q "seed-must-tunnel.list" "$F"
}
@test "panel calls amnezia-failover-ctl matching the helper installed name" {
  # The ctl helper is installed as amnezia-failover-ctl (see F3/ACL).
  # Now lives in failover.js.
  FV="$AMZ/amnezia/section/failover.js"
  grep -q "amnezia-failover-ctl" "$FV"
}
@test "no pbr panel anywhere (Issue #9)" {
  for f in $(alljs); do ! grep -qE "pbr-status|pbr-reload|handlePbrReload" "$f"; done
}
@test "failover tunnel panel is present: renderTunnelTable and failover-tunnel-table id" {
  # These now live in failover.js; main.js has the anchor guard in refresh().
  FV="$AMZ/amnezia/section/failover.js"
  grep -q "renderTunnelTable" "$FV"
  grep -q "failover-tunnel-table" "$FV"
  grep -q "Failover tunnels" "$FV"
}
@test "handshake_age is rendered directly as age-in-seconds (no Date.now subtract)" {
  # Issue MED: producer emits age-in-seconds; consumer must not double-convert via Date.now().
  # direct age path now lives in failover.js; main.js must not have the stale pattern.
  ! grep -qE "Date\.Now\(\).*handshake_age|handshake_age.*Date\.Now\(\)" "$F"
  FV="$AMZ/amnezia/section/failover.js"
  grep -qE "age < 0.*never|age < 60.*ago" "$FV"
}

# ── Phase E additions ────────────────────────────────────────────────────────

@test "failover.js contains decodeVpnLink function" {
  FV="$AMZ/amnezia/section/failover.js"
  grep -q "function decodeVpnLink" "$FV"
}

@test "failover.js decodeVpnLink returns null for non-vpn:// prefix" {
  FV="$AMZ/amnezia/section/failover.js"
  grep -q "indexOf('vpn://') !== 0" "$FV"
}

@test "failover.js has handleAddTunnel handler" {
  FV="$AMZ/amnezia/section/failover.js"
  grep -q "handleAddTunnel" "$FV"
}

@test "failover.js has handleTunnelRemove handler calling amnezia-tunnel-ctl remove" {
  FV="$AMZ/amnezia/section/failover.js"
  grep -q "handleTunnelRemove" "$FV"
  grep -q "amnezia-tunnel-ctl.*remove\|remove.*amnezia-tunnel-ctl" "$FV"
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

@test "failover.js has Remove button in renderTunnelTable (per-row remove column)" {
  FV="$AMZ/amnezia/section/failover.js"
  grep -q "awg-remove-" "$FV"
  grep -q "handleTunnelRemove" "$FV"
}

@test "no fs.write() in any module (argv-only channel)" {
  for f in $(alljs); do ! grep -qE "fs\.write\s*\(" "$f"; done
}

@test "failover.js add-tunnel section has textarea and Add tunnel button" {
  FV="$AMZ/amnezia/section/failover.js"
  grep -q "add-tunnel-conf" "$FV"
  grep -q "add-tunnel-btn" "$FV"
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

# ── Phase 6: failover.js ──────────────────────────────────────────────────────

@test "failover.js owns tunnel table, add-tunnel, set-mode/set-sticky, sentinel; direct handshake_age" {
  FV="$AMZ/amnezia/section/failover.js"; node --check "$FV"
  for s in renderTunnelTable decodeVpnLink handleAddTunnel handleTunnelRemove failover-tunnel-table set-mode set-sticky; do grep -q "$s" "$FV"; done
  grep -qE "age < 0.*never|age < 60.*ago" "$FV"                 # positive: direct age path present
  ! grep -qE "Date\.now\(\).*handshake_age|handshake_age.*Date\.Now\(\)" "$FV"
}
