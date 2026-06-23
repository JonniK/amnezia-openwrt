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
      return E('div', { 'class': 'cbi-map' }, [ E('h2',{},_('AmneziaWG')), style, acc, footer ]);
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
(it gates poll self-unregister). `applyInFlight` is referenced by zapret's
apply/revert path; it stays a shell-global imported by zapret? No — `applyInFlight`
guards zapret's blockcheck-apply, so it moves into `zapret.js` file scope along with
`handleApply`/`handleRevert`/`paintApply`. The shell keeps only `pollFn` + `domSeen`.

### Module → section assignment

| Module | Sections it owns | Handlers it owns |
|---|---|---|
| `failover.js` | Failover tunnels (status) · Add tunnel (action) | `handleTunnelToggle`, `handleTunnelRemove`, `handleAddTunnel`, `_doAddTunnel` |
| `routing.js` | Routing mode · Allowlist sources · Manual entries (action) · RU IP list | `handleRoutingMode`, `handleSourceToggle`, `handleForceUpdate`, `handleSaveManual`, `handleRuUpdate` |
| `zapret.js` | DPI desync (status) · Domain probe (action) · Verify list (action) · Blockcheck (action) | `handleProbe`, `handleVerify`, `handleBlockcheckRun`, `handleBlockcheckCancel`, `handleSelectRecommended`, `handleApply`, `handleRevert`, `handleZapretToggle` |
| `dns.js` | Encrypted DNS (DoT) | (inline `setDot`/`setDnsProvider`; no view-method handlers) |
| `autolearn.js` | Auto-learning | `handleAutolearnToggle`, `handleAutolearnVeto`, `handleAutolearnPromote`, `handleAutolearnPurge` |
| `main.js` shell | Refresh footer | `handleRefresh` |

Parsers/painters move with their module: `parseFailoverState`/`renderTunnelTable`/
`paintFailoverSummary`/`decodeVpnLink`/`paintForceStamp` → `failover.js`;
`parseRuStamp`/`paintRuStamp` → `routing.js`; `parseZapret`/`paintZapret`/
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

| Artifact | Change |
|---|---|
| `.ipk` Makefile (`packages/luci-app-amnezia/Makefile`) | **none** — `$(CP) ./files/. $(1)/` ships the whole tree once sync populates `files/`. |
| `dev/sync-to-packages.sh` | **add** recursive copy of `openwrt/luci-app-amnezia/amnezia/` → `packages/.../files/www/luci-static/resources/amnezia/` (mkdir + cp -r + chmod 0644). |
| `openwrt/install-luci-app-amnezia.sh` | **add** `mkdir -p …/resources/amnezia/section` + copy the new module files; extend the pre-flight existence checks. |
| ACL (`acl/luci-app-amnezia.json`) | **none** — new files are static JS; same `exec` grants. |
| Live router deploy | now ~7 files (tar-over-ssh or batched `cat`) instead of 1; **user-gated**; backup-first; **`rpcd restart` not `reload`** (known gotcha); verify panel renders + WAN/DNS/handshake. |

---

## Testing

| Gate | What |
|---|---|
| `node --check` | every new module + the slimmed `main.js` (CI + bats). |
| `test/unit/luci-js.bats` | retarget greps: symbols that moved out of `main.js` must be asserted in their new module file (glob `openwrt/luci-app-amnezia/amnezia/**/*.js`). Keep all existing assertions (decodeVpnLink, handlers, no `fs.write`, DoT focus-guard, no `custom` provider, pbr panel gone, etc.) — just point them at the right file. |
| new bats: accordion structure | assert 5 family `<details>` with `<summary>`; assert the 4 default-open families carry `open` and DPI/zapret does not; assert action sub-panels (`Add tunnel`, `Domain probe`, `Verify list`, `Blockcheck`, `Manual force-tunnel`) are nested `<details>` without `open`. |
| new bats: require graph | assert `main.js` declares the 6 `'require amnezia.*'` lines and that each referenced file exists. |
| sync parity | `dev/sync-to-packages.sh` idempotent; `openwrt/ ↔ packages/` match (CI check). |
| `#failover-tunnel-table` sentinel | bats asserts it still appears in `failover.js` (poll self-unregister depends on it). |

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
5. **Sync / installer drift** (new files missing on one delivery path). → both
   `sync-to-packages.sh` and `install-luci-app-amnezia.sh` updated in the same plan;
   sync-parity CI catches openwrt↔packages mismatch; require-graph bats catches a
   `require` with no backing file.

## Done criteria

- 5 section modules + `util.js` exist; `main.js` ≤ ~200 lines of pure orchestration.
- `node --check` clean across all; full bats suite green (retargeted + new tests);
  sync parity green.
- Accordion: 5 family `<details>`, correct default-open set, all actions nested &
  collapsed, Refresh footer outside.
- No backend/ACL/UCI change; deploy steps documented; deploy itself user-gated.
