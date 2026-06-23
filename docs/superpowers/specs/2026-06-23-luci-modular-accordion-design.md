# LuCI Modular Accordion UI — Design

**Date:** 2026-06-23
**Branch:** `feat/luci-modular-accordion`
**Status:** approved (inline brainstorming), entering review

## Goal

Refactor the monolithic 2302-line `luci-app-amnezia` view (`main.js`) into focused
per-feature JavaScript modules, and present its 13 sections as a two-level
**native-`<details>` accordion**: status views open by default, every *action*
collapsed-until-requested. No behavior change — same RPC calls, same handlers,
same polling. Pure structural refactor + a presentational accordion wrapper.

## Motivation

`main.js` is one 2302-line file: module-level vars + ~40 free helper functions
(parsers / painters / formatters) + a `view.extend({...})` carrying ~25 handlers
and a `render()` that builds 13 inline `cbi-section`s. It is hard to navigate and
hard to reason about. The user wants it split into modules ("I don't like that
everything is in one file") and the panel reorganized as an accordion where only
the most important blocks are expanded by default.

## Non-goals

- No change to any backend CLI, RPC call, ACL grant, UCI schema, or daemon.
- No new feature. Probe/verify/blockcheck/failover/DoT/autolearn behavior is
  byte-for-byte preserved; only their **location in source** and **DOM nesting**
  change.
- No restyle of individual controls beyond the accordion chrome (chevron + spacing).

---

## Architecture

### LuCI module mechanics (the constraint that shapes everything)

A LuCI view is one resource file ending in `return view.extend({...})`, loaded by
the menu entry `amnezia/main` from
`/www/luci-static/resources/view/amnezia/main.js`.

A `'require a.b.c'` declaration at the top of any module resolves to
`/www/luci-static/resources/a/b/c.js`, loads it once (cached), and binds the
returned class to a variable named after the **last** path component (`c`). Each
required module is itself `'use strict'; 'require baseclass'; … return
baseclass.extend({...})`.

**Implication:** if any required module has a syntax error or a bad require, the
**entire view fails to load** (blank panel). So every module must `node --check`
clean, and the real gate is the live "panel renders" check at deploy.

### Source ↔ package layout

Source of truth lives under `openwrt/luci-app-amnezia/`. New modules go in a new
`amnezia/` sibling of `view/`, mirroring the on-device resource path exactly so
the `require` path matches the dest path:

```
openwrt/luci-app-amnezia/
  view/main.js                     (view entry — slimmed shell)
  view/decode-vpn.mjs              (unchanged)
  amnezia/util.js                  → resources/amnezia/util.js
  amnezia/section/failover.js      → resources/amnezia/section/failover.js
  amnezia/section/routing.js       → resources/amnezia/section/routing.js
  amnezia/section/zapret.js        → resources/amnezia/section/zapret.js
  amnezia/section/dns.js           → resources/amnezia/section/dns.js
  amnezia/section/autolearn.js     → resources/amnezia/section/autolearn.js
  acl/luci-app-amnezia.json        (unchanged)
  menu/luci-app-amnezia.json       (unchanged)
```

On device:
```
/www/luci-static/resources/
  view/amnezia/main.js
  view/amnezia/decode-vpn.mjs
  amnezia/util.js
  amnezia/section/{failover,routing,zapret,dns,autolearn}.js
```

`main.js` requires them as: `'require amnezia.util'`,
`'require amnezia.section.failover'`, … → variables `util`, `failover`, `routing`,
`zapret`, `dns`, `autolearn`.

### Module interface contract

Every **section module** returns:

```js
'use strict';
'require baseclass';
'require fs';   // only the LuCI cores it actually uses
'require ui';
'require amnezia.util';

// file-scope: this module's in-flight guards + parsers + painters
var addTunnelInFlight = false;
function paintFailoverSummary(state) { … }   // private, closed over by handlers/render

return baseclass.extend({
  // handler map — spread onto the view by main.js so `this` === view instance.
  handlers: {
    handleAddTunnel: function(ev) { … },      // `this` is the view
    handleTunnelRemove: function(ev, name, ip) { … },
    …
  },
  // build this family's accordion panel; `view` is passed for ui.createHandlerFn.
  // Does the FIRST paint inline using `data` (preserves today's load→render paint).
  render: function(view, data) { return E('details', {…}, [ … ]); },
  // poll step: fetch this family's live state + paint by element id. Returns Promise.
  refresh: function(view) { return Promise.all([ … ]); }
});
```

**`util.js`** holds only genuinely cross-feature primitives (no feature owns them):
`fmtDur`, `fmtUptime`, `fmtAge`, `verdictColor`, `uiConfirm`. Everything
feature-specific (e.g. `parseFailoverState`, `paintZapret`, `parseAutolearnList`)
moves into the owning section module. `util.js` requires only `baseclass` + `ui`
(for `uiConfirm`'s modal).

**`main.js` shell** keeps only orchestration:
```js
'use strict';
'require view'; 'require fs'; 'require ui'; 'require poll';
'require amnezia.util';
'require amnezia.section.failover';
'require amnezia.section.routing';
'require amnezia.section.zapret';
'require amnezia.section.dns';
'require amnezia.section.autolearn';

var pollFn = null, domSeen = false, applyInFlight = false;   // shell-global state

return view.extend(Object.assign({},
  failover.handlers, routing.handlers, zapret.handlers, dns.handlers, autolearn.handlers,
  {
    load:   function() { /* unchanged: batch reads → data bundle */ },
    render: function(data) {
      var acc = E('div', { 'class': 'amnezia-accordion' }, [
        failover.render(this, data),
        routing.render(this, data),
        zapret.render(this, data),     // family collapsed by default
        dns.render(this, data),
        autolearn.render(this, data),
      ]);
      var footer = /* Refresh-status button — OUTSIDE the accordion */;
      var style  = /* one injected <style> for accordion chrome */;
      … poll.add(L.bind(this.refresh,this), 5) …
      // preserve the existing h2 + cbi-map-descr intro paragraph (main.js:1674-1676)
      return E('div', { 'class': 'cbi-map' }, [
        E('h2', {}, _('AmneziaWG')),
        E('div', { 'class': 'cbi-map-descr' }, _( /* existing intro text */ )),
        style, acc, footer
      ]);
    },
    refresh: function() {
      // unchanged anchor guard: #failover-tunnel-table sentinel + domSeen self-unregister
      if (!document.getElementById('failover-tunnel-table')) {
        if (domSeen && pollFn) { poll.remove(pollFn); pollFn = null; }
        return Promise.resolve();
      }
      domSeen = true;
      return Promise.all([
        failover.refresh(this), routing.refresh(this),
        zapret.refresh(this), dns.refresh(this), autolearn.refresh(this)
      ]);
    },
    handleRefresh: function(ev) { … },   // footer's force-poll (stays in shell)
    handleSaveApply: null, handleSave: null, handleReset: null
  }
));
```

The `#failover-tunnel-table` sentinel **must** remain in `failover.render`'s output
(it gates poll self-unregister). `applyInFlight` guards zapret's blockcheck-apply, so
it moves into `zapret.js` file scope along with `handleApply`/`handleRevert`/`paintApply`.
The shell keeps only `pollFn` + `domSeen`. **Module-file-scope mutable state** (NOT
instance state) that must move with its module: `addTunnelInFlight`/`removeTunnelInFlight`
→ failover; `routingModeInFlight`/`forceUpdateInFlight`/`saveManualInFlight` → routing;
`probeInFlight`/`verifyInFlight`/`applyInFlight`/`candidatesSig` → zapret
(`candidatesSig`, main.js:51, is seeded by `zapret.render` and read/written by
`zapret.refresh`→`paintApply` — both live in the same module file so the closure works).

**Cross-module refresh contract (the one real coupling).** Today `refresh()` p5
(main.js:1575) reads `/var/run/amnezia-failover.json` **once** and from that single
parsed state paints THREE owners' fields: the failover summary + `#failover-tunnel-table`
(failover), the `#routing-mode-select` value (routing, guarded by `activeElement`,
main.js:1585), and the 5 `#force-src-*` checkboxes (routing, guarded, main.js:1591).
The split must NOT double-read the file or drop the guarded reconcile. Contract:
`failover.refresh(view)` reads + parses the file once, paints its own fields, then calls
`routing.applyFailoverState(state)` — an exported routing function that does **only** the
`activeElement`-guarded routing-mode-select + source-checkbox reconcile. `routing.refresh`
handles routing's *other* reads (RU stamp, force stamp); it does not re-read the failover
JSON. This keeps one read per tick and preserves both guards verbatim.

**Inline closures travel with `render`, not the handler map.** The failover Mode-select
(`set-mode`, main.js:1709) and Sticky input+button (`set-sticky`, main.js:1739) are wired
with `ui.createHandlerFn(this, function(ev){…})` — anonymous closures, not named view
methods. They move into `failover.js` *inside* `failover.render`, so `failover.js` MUST
declare `'require fs'; 'require ui';` (the closures call `fs.exec`/`ui.addNotification`).
Their initial `selected`/`value` derive from the `data` bundle's `failoverState` — pass it
through `render(view, data)`.

### Module → section assignment

| Module | Sections it owns | Handlers it owns |
|---|---|---|
| `failover.js` | Failover tunnels (status: mode-select, sticky, table) · Add tunnel (action) | `handleTunnelToggle`, `handleTunnelRemove`, `handleAddTunnel`, `_doAddTunnel`, **+ inline `set-mode`/`set-sticky` closures** |
| `routing.js` | Routing mode · Allowlist sources · Manual entries (action) · RU IP list | `handleRoutingMode`, `handleSourceToggle`, `handleForceUpdate`, `handleSaveManual`, `handleRuUpdate` |
| `zapret.js` | DPI desync (status) · Domain probe (action) · Verify list (action) · Blockcheck (action) | `handleProbe`, `handleVerify`, `handleBlockcheckRun`, `handleBlockcheckCancel`, `handleSelectRecommended`, `handleApply`, `handleRevert`, `handleZapretToggle` |
| `dns.js` | Encrypted DNS (DoT) | (inline `setDot`/`setDnsProvider`; no view-method handlers) |
| `autolearn.js` | Auto-learning | `handleAutolearnToggle`, `handleAutolearnVeto`, `handleAutolearnPromote`, `handleAutolearnPurge` |
| `main.js` shell | Refresh footer | `handleRefresh` |

Parsers/painters move with their module: `parseFailoverState`/`renderTunnelTable`/
`paintFailoverSummary`/`decodeVpnLink` → `failover.js`;
`parseRuStamp`/`paintRuStamp`/`paintForceStamp` → `routing.js` (force-update belongs to the Routing & Allowlist family); `parseZapret`/`paintZapret`/
`parseProbe`/`parseVerify`/`parseSeedList`/`parseBlockcheck`/`paintBlockcheck`/
`paintBlockcheckLog`/`parseApplyState`/`parseCandidates`/`paintApply`/`candidateKey`/
`candidatesSignature`/`composeNfqwsOpt` → `zapret.js`; `parseAutolearnStatus`/
`parseAutolearnList`/`paintAutolearnStatus`/`paintAutolearnTable` → `autolearn.js`;
`dnsExec`/`renderDnsRow`/`refreshDnsStatus`/`DNS_PROVIDERS` → `dns.js`.
`fmtDur`/`fmtUptime`/`fmtAge`/`verdictColor`/`uiConfirm` → `util.js`.

---

## Accordion behavior

Native `<details>`/`<summary>`. No JS toggle state — open/closed is browser-owned,
so the 5s poll (which repaints inner nodes by id, never rebuilding the `<details>`)
**cannot clobber** it. This is the same reason the existing DoT focus-guard
(`box.contains(document.activeElement)`) is preserved as-is.

### Two levels

1. **Family panel** = top-level `<details class="amnezia-panel">` with
   `<summary>` heading. `open` attribute present ⇒ expanded.
2. **Action sub-section** = nested `<details class="amnezia-action">`, **never**
   carries `open` (always starts collapsed).
3. **Status content** = rendered as a direct child of the family `<details>`, so
   it's visible the moment the family is open.

`E('details', { 'open': '' }, …)` renders expanded; omit the `open` key entirely
(do **not** pass `'open': null` unless verified that LuCI's `E()` skips null-valued
attributes — the plan must confirm this and use whichever form actually omits the
attribute) for collapsed.

### Default-open map (per user)

| Family panel | Default | Status (visible when open) | Collapsed action sub-panels |
|---|---|---|---|
| **Tunnels & Failover** | **open** | failover tunnel table (`#failover-tunnel-table`) + summary | ▸ Add tunnel |
| **Routing & Allowlist** | **open** | routing-mode select + allowlist-source toggle list | ▸ Manual force-tunnel entries · ▸ Update sources / RU now |
| **DPI bypass (zapret)** | collapsed | (DPI desync status shown when family expanded) | ▸ Domain probe · ▸ Verify list · ▸ Blockcheck |
| **Encrypted DNS** | **open** | DoT toggle + provider + active-tier status | (none) |
| **Auto-learning** | **open** | autolearn toggle + learned-domain table | (inline row actions: veto/promote/purge) |

The global **Refresh status** button stays **outside** the accordion (always
visible). `handleSaveApply/handleSave/handleReset` remain nulled (LuCI's default
save bar stays suppressed).

### Accordion chrome

One `<style>` node injected once at the top of `render()`: hide the default marker,
draw a `▸`/`▾` chevron via `summary::before`, give `summary` cursor:pointer +
padding, indent nested `.amnezia-action`. Self-contained — no external CSS file to
ship (keeps the wiring surface minimal).

---

## Wiring & deployment impact

**CRITICAL — there are FOUR cherry-pick delivery surfaces, not two.** Each hardcodes
`view/main.js` by name; the new modules live at the **sibling** root
`/www/luci-static/resources/amnezia/` (NOT under `view/`), so none of these surfaces
ships them until patched. Converting inlined functions into 6 *runtime-required* modules
means a half-updated surface → `require amnezia.*` 404 → **blank panel**. All four MUST be
updated in the same plan; the require-graph + sync-parity tests are the offline guards.

| Surface | Role | Current state | Required change |
|---|---|---|---|
| `packages/luci-app-amnezia/Makefile` | `.ipk` build | `$(CP) ./files/. $(1)/` (wholesale) | **none** for file list — ships whole tree once sync populates `files/`. `[autofix]` bump `PKG_RELEASE`; drop stale "PBR health/Reload button" line from description. |
| `dev/sync-to-packages.sh` | openwrt→packages mirror | cherry-picks `main.js`+`decode-vpn.mjs` (lines 164-167); `mkdir -p` list omits the new dir (line 38) | add `…/resources/amnezia/section` to the `mkdir -p` block; `cp -r openwrt/luci-app-amnezia/amnezia/* → …/resources/amnezia/`; chmod **files only** (`find … -type f -exec chmod 0644`) so dir modes don't break byte+mode parity. |
| `openwrt/install-luci-app-amnezia.sh` | on-device copy (`/tmp`→`/www`) | copies only `$SRC/view/main.js` → `VIEW_DIR=resources/view/amnezia` (line 13,37); preflight checks 3 files (line 19-21) | `mkdir -p /www/luci-static/resources/amnezia/section`; copy each module to `resources/amnezia/…` (**not** under `VIEW_DIR`); add per-file preflight existence checks for all 6 modules. Also fixes the pre-existing `decode-vpn.mjs` omission while here. |
| `install.sh` | stages repo→`/tmp/luci-app-amnezia` for the above | stages only `menu/acl/view/main.js` (lines 123-126) | stage the whole `openwrt/luci-app-amnezia/amnezia/` tree into `/tmp/luci-app-amnezia/amnezia/`. |
| `dev/deploy-openwrt-safe.sh` | **live-router push** (`cat`-over-ssh) | `for _f in … view/main.js` stages 3 files to `/tmp` (lines 77-82) | add every `amnezia/**` module to the staging loop; preserve relative path so it lands at `/tmp/luci-app-amnezia/amnezia/…`. |
| ACL (`acl/luci-app-amnezia.json`) | rpcd perms | — | **none** — new files are static JS; same `exec` grants. |

`decode-vpn.mjs` is **not** in the require graph (the live `decodeVpnLink` is inlined at
main.js:585 and moves to `failover.js`); the `.mjs` is a standalone fixture — the
require-graph test must NOT expect a require for it.

**Live-router deploy (user-gated) — atomicity & ordering.** Multi-file `cat`-over-ssh is
non-atomic. Invariant: **snapshot every target to `*.pre-modular` BEFORE the first byte is
overwritten; copy ALL `amnezia/**` modules FIRST; write `view/main.js` LAST** — so at no
instant does the entry reference a not-yet-present module. After copy: clear LuCI caches,
**`rpcd restart` not `reload`** (known gotcha), verify the panel renders + every section
paints + `fs.exec` succeeds + WAN/DNS/handshake. Rollback = restore `*.pre-modular`
(main.js first to re-pin the old, module-free entry) + `rpcd restart`. Full backup first.

---

## Testing

Define one bats helper `ALLJS` = the union glob `view/*.js` + `amnezia/**/*.js` (the
full shipped JS surface). **Positive** assertions target the specific new owner file;
**negative** assertions run over `ALLJS` (concatenated), never a single file.

| Gate | What |
|---|---|
| `node --check` | every new module + the slimmed `main.js` (CI + bats). |
| positive symbol assertions | each moved symbol asserted present **in its new owner file** (e.g. `decodeVpnLink`/`renderTunnelTable` in `failover.js`, `DNS_PROVIDERS`/focus-guard in `dns.js`, `handleAutolearn*` in `autolearn.js`). |
| **negative guards — must not pass vacuously** | the load-bearing `! grep` guards run over `ALLJS` (union of ALL shipped JS), AND are paired with a positive anchor so a vacuous pass is impossible: `! grep pbr-status\|pbr-reload\|handlePbrReload` (Issue #9, across union); `! grep -E 'fs\.write\s*\('` (argv-only security guard — **across all 6 modules + shell**, an `fs.write` could be introduced in any); `! grep Date.now().*handshake_age` paired with asserting `failover.js` contains the direct age path; `! grep DNS_PROVIDERS…'custom'` paired with asserting `dns.js` contains `DNS_PROVIDERS`. |
| new bats: accordion structure | 5 family `<details>` w/ `<summary>`; the 4 default-open families render `<details … open` and DPI/zapret renders `<details` WITHOUT `open` (structural check on the family node, not a bare `grep open` which is order-sensitive); action sub-panels (`Add tunnel`, `Domain probe`, `Verify list`, `Blockcheck`, `Manual force-tunnel`) are nested `<details>` without `open`. |
| new bats: require graph | assert `main.js` declares the 6 `'require amnezia.*'` lines and each resolves to an existing file **in both `openwrt/luci-app-amnezia/amnezia/…` AND the synced `packages/.../resources/amnezia/…`** (catches a sync that drops a module). Must NOT expect a require for `decode-vpn.mjs`. |
| sync parity | `dev/sync-to-packages.sh` run twice → idempotent; `git diff --quiet` after; `openwrt/ ↔ packages/` byte+mode identical (CI check). |
| `#failover-tunnel-table` sentinel | bats asserts it still appears in `failover.js` (poll self-unregister depends on it). |

LuCI's `E()` **omits null-valued attributes** — proven by the live `'selected': … ? '' :
null` / `'disabled': … ? null : ''` idioms (main.js:1721, 2006) — so collapsed =
`'open': isOpen ? '' : null` is safe; the accordion test asserts the rendered structure,
not a fragile `grep`. No `.po`/`.pot` catalog exists in the repo (Makefile has empty
`Build/Prepare`/`Compile`); `_()` is resolved at runtime by luci-base, so splitting `_()`
strings across modules breaks no translation wiring — strings may live in any module.

Offline tests cannot prove LuCI actually resolves every `require` at runtime — only
the live "panel renders, every section paints, fs.exec calls succeed" check can.
That is the deploy-time gate and stays user-gated.

---

## Risks & mitigations

1. **A bad require / syntax error blanks the whole panel.** → `node --check` all
   modules; require-graph bats test; live render check before declaring done; keep
   `*.pre-modular` on-device snapshots for one-command rollback.
2. **Handler `this`-binding regressions** (handlers moved into modules then spread).
   → Object.assign onto `view.extend` keeps them prototype methods; `ui.createHandlerFn(view,'handleX')`
   resolves unchanged. bats asserts each handler name is present in its module.
3. **Poll clobbering accordion open/closed state.** → native `<details>` is
   browser-owned; refresh repaints inner nodes by id, never the `<details>` element.
4. **First-paint blank for ~5s** if initial paint is dropped. → each `module.render`
   does the first paint inline from the `load()` data bundle (preserves today's
   behavior); the immediate poll only updates.
5. **Sync / installer drift** (new files missing on one of FOUR delivery surfaces →
   blank panel). → all four (`sync-to-packages.sh`, `install-luci-app-amnezia.sh`,
   `install.sh`, `deploy-openwrt-safe.sh`) + the Makefile updated in the same plan;
   sync-parity CI catches openwrt↔packages mismatch; require-graph bats (run against both
   `openwrt/` and `packages/`) catches a `require` with no backing file; live deploy
   orders modules-first/main.js-last so a partial push never references a missing module.

## Done criteria

- 5 section modules + `util.js` exist; `main.js` ≤ ~200 lines of pure orchestration.
- `node --check` clean across all; full bats suite green (retargeted + new tests);
  sync parity green.
- Accordion: 5 family `<details>`, correct default-open set, all actions nested &
  collapsed, Refresh footer outside.
- No backend/ACL/UCI change; deploy steps documented; deploy itself user-gated.
