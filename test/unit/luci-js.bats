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
  ! grep -qE "Date\.now\(\).*handshake_age|handshake_age.*Date\.now\(\)" "$F"
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

@test "acl does NOT grant exec on amnezia-autolearn-ctl (feature removed)" {
  ACL="$HARNESS_DIR/../openwrt/luci-app-amnezia/acl/luci-app-amnezia.json"
  ! grep -q 'amnezia-autolearn-ctl' "$ACL"
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

# ── Phase 6: failover.js ──────────────────────────────────────────────────────

@test "failover.js owns tunnel table, add-tunnel, set-mode/set-sticky, sentinel; direct handshake_age" {
  FV="$AMZ/amnezia/section/failover.js"; node --check "$FV"
  for s in renderTunnelTable decodeVpnLink handleAddTunnel handleTunnelRemove failover-tunnel-table set-mode set-sticky; do grep -q "$s" "$FV"; done
  grep -qE "age < 0.*never|age < 60.*ago" "$FV"                 # positive: direct age path present
  ! grep -qE "Date\.now\(\).*handshake_age|handshake_age.*Date\.Now\(\)" "$FV"
}

# ── Phase 7: accordion chrome + structural tests ──────────────────────────────

@test "accordion: 4 family panels with correct default-open set (harness)" {
  run node -e '
    const h=require("./test/lib/luci-harness.js");
    const fams={}; h.panels.forEach(([k,n])=>h.walk(n,x=>{ if(x.tag==="details" && (x.attrs.class||"").includes("amnezia-panel")){
      fams[k]=Object.prototype.hasOwnProperty.call(x.attrs,"open") && x.attrs.open!=null; }}));
    const want={failover:true,routing:true,dns:true,zapret:false};
    for(const k of Object.keys(want)){ if(fams[k]!==want[k]){ console.error("open mismatch "+k+": "+fams[k]); process.exit(1);} }
    process.exit(0);'
  [ "$status" -eq 0 ]
}
@test "accordion: action sub-panels nested and never open (harness self-test)" {
  run node "$HARNESS_DIR/../test/lib/luci-harness.js"
  [ "$status" -eq 0 ]
  grep -q "amnezia-accordion" "$AMZ/view/main.js"
}
@test "main.js require-graph resolves to existing files" {
  for m in util section/failover section/routing section/zapret section/dns; do
    grep -q "require amnezia.${m//\//.}" "$AMZ/view/main.js"
    [ -f "$AMZ/amnezia/$m.js" ]
  done
  ! grep -q "require.*decode-vpn" "$AMZ/view/main.js"
  ! grep -q "require.*autolearn" "$AMZ/view/main.js"
}

# ── Phase 8: delivery wiring — packages mirror carries the amnezia module tree ──

@test "packages mirror carries the amnezia module tree (5 files, no autolearn)" {
  PKG="$HARNESS_DIR/../packages/luci-app-amnezia/files/www/luci-static/resources/amnezia"
  [ -f "$PKG/util.js" ]
  [ -f "$PKG/section/failover.js" ]
  [ -f "$PKG/section/routing.js" ]
  [ -f "$PKG/section/zapret.js" ]
  [ -f "$PKG/section/dns.js" ]
  [ ! -f "$PKG/section/autolearn.js" ]
}

@test "no dotted require without 'as' alias (LuCI binding footgun)" {
  # LuCI does NOT auto-bind a namespaced require; `'require a.b.c'` needs ` as <alias>`
  # or the variable is undefined at runtime → ReferenceError → blank panel.
  run node -e 'const h=require("./test/lib/luci-harness.js"); const b=h.lintRequires(); if(b.length){console.error(b.join("\n"));process.exit(1)}'
  [ "$status" -eq 0 ]
}

# ── Phase 4: handler harness (Item 3 regression guard) ───────────────────────

@test "harness executes all named change handlers without reject (handler-exec-safe)" {
  # Every named handler in CHANGE_HANDLERS must resolve under both succeeding
  # and rejecting fs stubs. This is the regression guard the original Item-3
  # inline-closure bug (Mode/Sticky didn't repaint AND weren't harness-reachable) would trip.
  run node "$HARNESS_DIR/../test/lib/luci-harness.js"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "handler-exec-safe ok"
}

@test "main.js load() reads DoT status (index 10) and master_enabled (index 11)" {
  grep -q "amnezia-dns-ctl.*status\|status.*amnezia-dns-ctl" "$F"
  grep -q "amnezia.config.master_enabled" "$F"
}

@test "main.js has master strip and handleMasterToggle" {
  grep -q "amz-master-strip" "$F"
  grep -q "handleMasterToggle" "$F"
  grep -q "amnezia-failover-ctl.*master\|master.*amnezia-failover-ctl" "$F"
}

@test "failover.js has named handleSetMode and handleSetSticky handlers" {
  FV="$AMZ/amnezia/section/failover.js"
  grep -q "handleSetMode" "$FV"
  grep -q "handleSetSticky" "$FV"
}

@test "failover.js has handleMakeDefault, handleTunnelRestart, handleForcePin, handleForceUnpin" {
  FV="$AMZ/amnezia/section/failover.js"
  grep -q "handleMakeDefault" "$FV"
  grep -q "handleTunnelRestart" "$FV"
  grep -q "handleForcePin" "$FV"
  grep -q "handleForceUnpin" "$FV"
}

@test "failover.js shows exit_ip with age in tunnel table" {
  FV="$AMZ/amnezia/section/failover.js"
  grep -q "exit_ip_age" "$FV"
  grep -q "exit_ip" "$FV"
}

@test "dns.js has handlers map with labeled enable/disable, provider, and test" {
  D="$AMZ/amnezia/section/dns.js"
  grep -q "handleDotSetEnabled" "$D"
  grep -q "handleDotProvider" "$D"
  grep -q "handleDotTest" "$D"
  grep -q "Enable DoT" "$D"
  grep -q "handlers:" "$D"
}

@test "dns.js has dnsRowMarkup helper used by both render and refresh paths" {
  D="$AMZ/amnezia/section/dns.js"
  grep -q "dnsRowMarkup" "$D"
}

@test "failover.js has force-pool banner and force-pool select" {
  FV="$AMZ/amnezia/section/failover.js"
  grep -q "failover-force-pool-banner" "$FV"
  grep -q "failover-force-pool-select" "$FV"
  grep -q "force-pin" "$FV"
  grep -q "force-unpin" "$FV"
}

# ── Tunnel apps (feat/tunnel-apps-ui) ────────────────────────────────────────

@test "routing.js has tunnel-apps handlers (handleAppToggle/Remove/Preset/Add)" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "handleAppToggle"  "$R"
  grep -q "handleAppRemove"  "$R"
  grep -q "handleAppPreset"  "$R"
  grep -q "handleAppAdd"     "$R"
}

@test "routing.js calls amnezia-app-ctl for remove/preset/add" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "amnezia-app-ctl" "$R"
}

@test "routing.js render builds tunnel-apps-tbody synchronously in tree" {
  # The apps table must be present in the render tree and the harness tooth confirms
  # it is painted synchronously (not via getElementById at render time).
  # getElementById IS used in paintAppsTable (refresh-path only) — that is correct.
  # The tooth in luci-harness.js asserts the tbody exists in the render tree.
  R="$AMZ/amnezia/section/routing.js"
  grep -q "tunnel-apps-tbody" "$R"
  # The id must appear in an E() call (build path), not ONLY in getElementById.
  grep -qE "'id'.*tunnel-apps-tbody|\"id\".*tunnel-apps-tbody" "$R" \
    || { echo "tunnel-apps-tbody not built via E() in render tree"; false; }
}

@test "harness asserts tunnel-apps-tbody in render tree (synchronous paint tooth)" {
  run node "$HARNESS_DIR/../test/lib/luci-harness.js"
  [ "$status" -eq 0 ]
}

@test "routing.js refresh calls amnezia-app-ctl list (keeps table live)" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "amnezia-app-ctl.*list\|list.*amnezia-app-ctl" "$R"
}

@test "main.js load() has index 12 = amnezia-app-ctl list" {
  grep -q "amnezia-app-ctl.*list\|list.*amnezia-app-ctl" "$F"
}

@test "routing.js has AS number help text with bgp.he.net / ipinfo.io" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "bgp.he.net" "$R"
  grep -q "ipinfo.io" "$R"
}

@test "routing.js has preset buttons for Telegram and Meta" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "telegram" "$R"
  grep -q "meta" "$R"
  grep -q "handleAppPreset" "$R"
}

@test "acl grants exec on amnezia-app-ctl" {
  ACL="$HARNESS_DIR/../openwrt/luci-app-amnezia/acl/luci-app-amnezia.json"
  grep -q "amnezia-app-ctl" "$ACL"
}

@test "handler arg-order: tunnel-app handlers pass no event as backend arg (harness)" {
  run node "$HARNESS_DIR/../test/lib/luci-harness.js"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "handler-argorder ok"
}

@test "routing.js has app-add-name and app-add-btn form elements" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "app-add-name" "$R"
  grep -q "app-add-btn"  "$R"
  grep -q "app-add-asn"  "$R"
  grep -q "app-add-cidrs" "$R"
  grep -q "app-add-url"  "$R"
}

# ── Auto-tunnel worker (feat/autotunnel) ────────────────────────────────────

@test "routing.js has handleAutotunnelToggle and handleAutotunnelRemove handlers" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "handleAutotunnelToggle" "$R"
  grep -q "handleAutotunnelRemove" "$R"
}

@test "routing.js handleAutotunnelRemove is declared function(domain, ev) — extra arg first" {
  R="$AMZ/amnezia/section/routing.js"
  # The handler MUST be declared with the domain arg first (LuCI convention: extra args first,
  # event last).  Getting it backwards sends the event object to the backend.
  grep -qE "handleAutotunnelRemove\s*:\s*function\s*\(\s*domain" "$R"
}

@test "routing.js autotunnel panel is collapsed (amnezia-action, no open attribute)" {
  # The autotunnel worker panel must NOT have open by default.
  run node "$HARNESS_DIR/../test/lib/luci-harness.js"
  [ "$status" -eq 0 ]
}

@test "routing.js has amz-at-domains-tbody built in render tree (synchronous paint)" {
  R="$AMZ/amnezia/section/routing.js"
  grep -qE "'id'.*amz-at-domains-tbody|\"id\".*amz-at-domains-tbody" "$R"
}

@test "routing.js handleAutotunnelRemove calls amnezia-autotunnel remove" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "amnezia-autotunnel" "$R"
  grep -q "remove" "$R"
}

@test "routing.js has handleAutotunnelToggle calling amnezia-autotunnel enable/disable" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "handleAutotunnelToggle" "$R"
  grep -qE "'enable'|\"enable\"|'disable'|\"disable\"" "$R"
}

@test "main.js load() has index 13 = amnezia-autotunnel status" {
  grep -q "amnezia-autotunnel.*status\|status.*amnezia-autotunnel" "$F"
}

@test "harness DATA has 14 elements (index 13 = autotunnel status)" {
  run node -e '
    const h=require("./test/lib/luci-harness.js");
    if(h.DATA.length !== 14){ console.error("DATA.length="+h.DATA.length+", want 14"); process.exit(1); }
    process.exit(0);'
  [ "$status" -eq 0 ]
}

@test "handler arg-order: handleAutotunnelRemove passes no event as backend arg (harness)" {
  run node "$HARNESS_DIR/../test/lib/luci-harness.js"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "handler-argorder ok"
}

@test "routing.js refresh calls amnezia-autotunnel status (keeps panel live)" {
  R="$AMZ/amnezia/section/routing.js"
  grep -q "amnezia-autotunnel.*status\|status.*amnezia-autotunnel" "$R"
}
