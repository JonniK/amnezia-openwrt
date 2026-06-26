# LuCI tunnel control, DoT fixes, exit-IP, and master switch — design

**Date:** 2026-06-27
**Status:** approved (brainstorming)
**Scope:** six items reported against the deployed modular LuCI panel. Spans the
failover daemon, `amnezia-failover-ctl`, `amnezia-dns-ctl`, the LuCI section
modules (`failover.js`, `dns.js`, `main.js`), the JS render/handler harness, and
bats. ACL is unchanged — every exec target is already whitelisted.

Top constraint (unchanged): **never break client internet.** Every router action
must be reversible and verified (WAN + DNS + tunnel handshake) before moving on.

---

## Background — grounded current behavior

- Failover daemon (`/usr/sbin/amnezia-failover`) writes `/var/run/amnezia-failover.json`
  each poll. Pool exit = lowest-metric healthy tunnel (`_best_pool`). `exit_ip` is
  **hardcoded `null`** (daemon line ~153: deferred, "requires a bound external
  probe, throttled").
- `amnezia-failover-ctl` verbs today: `set-mode`, `set-sticky`, `set-weight`,
  `toggle`, `set-routing-mode`, `set-source`. **No** `set-metric`, `make-default`,
  `force-pin`, `restart`, or master switch.
- ip-rule / table abstraction lives in `lib/amnezia-routing.sh`:
  `routing_install_rules` / `routing_remove_rules` (fwmark prefs
  `RULE_PREF_STICKY=31000`, `RULE_PREF_POOL=31001`, tables 100/101). DoT rule
  pref `RULE_PREF_DOT=30900` with `dns_iprule_flush` in `lib/amnezia-dns-lib.sh`.
- Tunnels are netifd interfaces — `ifup awgN` / `ifdown awgN` (see
  `amnezia-tunnel-ctl.sh`).
- `amnezia-dns-ctl status` emits `{"enabled":…,"provider":…,"active_tier":…,…}`;
  `enable`/`disable` are bounded (nslookup probe, 3s timeout).
- LuCI modules: `dns.render()` emits an **empty** `#amz-dns-row` (toggle only
  paints on the first 5s poll). Change handlers are inconsistent: Mode/Sticky use
  `ui.createHandlerFn` **but never call `this.refresh()`**; DoT toggle/provider are
  **bare** handlers with no `.catch` and no repaint.

---

## Item 3 — XHR error on change + UI only updates after manual refresh *(do first)*

**Root cause:** two distinct defects in the change handlers.
1. Mode/Sticky handlers exec successfully but never repaint → the UI looks stale
   until the next poll / manual refresh ("меняется только после обновления").
2. DoT toggle/provider are bare event handlers returning an un-`catch`ed promise
   (`setDot`/`setDnsProvider` → `dnsExec` with no `.catch`). Any exec hiccup
   becomes an unhandled rejection that LuCI surfaces as an XHR error alert.

**Fix — one standard handler shape** for every "change" control (Mode, Sticky,
DoT toggle, DoT provider, and the new controls below):

```
disable the control (busy state)
→ fs.exec(...)                      // resolves even on nonzero exit
→ on resolve: notify (info if code 0, warning otherwise) AND repaint the section
→ on reject:  notify 'danger', never leak an unhandled rejection
→ finally: re-enable the control
```

DoT toggle/provider are routed through `ui.createHandlerFn(view, …)` like the
rest, and call `dns.refresh(view)` after the exec settles. Mode/Sticky gain the
missing `failover.refresh(view)` call. No backend change.

**Acceptance:** clicking any control (a) never raises an XHR/RPC error alert on a
normal exec, and (b) repaints the affected section within the same click, without
waiting for the 5s poll or a manual Refresh.

---

## Item 2 — DoT enable/disable button not visible / unusable

**Root cause:** `dns.render()` renders only `E('div',{'id':'amz-dns-row'})`; the
toggle is injected by `renderDnsRow()` which runs only from `refresh()`/poll. On a
slow or failed first status read the row stays empty → "no DoT button".

**Fix:** render the DoT control **synchronously from `load()` data**.
- `main.load()` gains a DoT status read:
  `L.resolveDefault(fs.exec('/usr/bin/amnezia-dns-ctl',['status']), {stdout:''})`
  appended to the data bundle (new index).
- `dns.render(view,data)` parses that status and paints the enable/disable
  checkbox + provider dropdown + tier label on first paint. The poll path
  (`renderDnsRow`) keeps it live and remains the single source of repaint markup
  (extract the row-building into a shared helper used by both render and refresh).
- Combined with Item 3, the toggle now actually toggles and repaints.

**Acceptance:** the Encrypted DNS panel shows a working enable/disable control and
provider dropdown on first paint (no 5s blank window), reflecting real state.

---

## Item 1 — Default tunnel: BOTH make-default and force-pin

### Backend — new `amnezia-failover-ctl` verbs
- **`make-default <awgN>`** — renumber tunnel metrics so the chosen tunnel = metric
  `1` and the remaining **enabled** tunnels keep their relative order as `2,3,…`
  (deterministic, no metric drift on repeat clicks). Commits UCI
  (`amnezia.<tun>.metric`) and restarts the monitor. Failover stays active.
- **`force-pin <awgN>`** — set `amnezia.globals.force_pool=<awgN>`, commit, restart
  monitor.
- **`force-unpin`** — delete `amnezia.globals.force_pool`, commit, restart monitor.

Validation: each verb requires an existing tunnel name; reject unknown/disabled
targets with a clear message and nonzero exit.

### Daemon — honor `force_pool`
`_best_pool` (and `_sticky_pick` only insofar as the pool selection feeds it)
gains a leading check: if `globals.force_pool` is set:
- and that tunnel is **UP** → return it regardless of metric; auto-failover to
  other tunnels is **suspended**.
- and that tunnel is **DOWN** → return empty so the pool goes **fail-closed**
  (blackhole), i.e. no silent switch to another tunnel. (This is the explicit
  pin semantic — the user chose to pin, so we honor it even when it costs
  connectivity for the *pool*; sticky/RU/direct are unaffected.)

`force_pool` is surfaced in the failover JSON (`"force_pool":"awgN"|null`) so the
UI can render the suspended-failover banner.

**Scope boundary (confirmed):** force-pin governs the **pool exit only**. The
sticky table (claude/anthropic, `sticky_target`) stays independent — the user can
set sticky to the same tunnel if they want everything on one exit.

### UI (`failover.js`)
- Per-row **"Make default"** button (in the actions cell), hidden on the row that
  is already the lowest-metric / current default. Calls `make-default`.
- A **"Force pool through"** control in the failover section: a select of tunnel
  names + an **Unpin** button. When `force_pool` is set, show a clear banner:
  "Failover suspended — pool pinned to awgN. If it drops, pool traffic stops
  until you unpin or pin another."
- All via the standard handler shape (Item 3): exec → repaint → notify.

**Acceptance:** "Make default" makes the chosen tunnel the active pool exit while
leaving the others as failover backups; force-pin pins the pool to one tunnel and
visibly suspends failover; unpin restores normal lowest-metric selection.

---

## Item 4 — Per-tunnel restart button

### Backend
- **`amnezia-failover-ctl restart <awgN>`** — `ifdown <awgN>; sleep 1; ifup <awgN>`,
  then return. The running daemon re-evaluates health on its next poll and
  reinstalls routes/rules as needed. Validates the tunnel name; never touches any
  other interface.

### UI (`failover.js`)
- Per-row **"Restart"** button next to Toggle/Remove, with a confirm dialog
  ("Restart awgN? The interface drops and re-establishes; brief reconnection."),
  busy state, and post-action `failover.refresh(view)`.

**Acceptance:** clicking Restart on a row bounces only that interface; the row
returns to UP with a fresh handshake; other tunnels are untouched.

---

## Item 5 — Exit IP via background cached probe

### Daemon — throttled bound probe
For each **UP** tunnel, resolve the real public egress IP bound to the tunnel
device using the established pattern:
`curl --interface "if!<awgN>" -fsSL --connect-timeout 5 --max-time 8 <ip-echo>`
with one primary + one fallback IP-echo endpoint (small, plaintext-IP responses).

- **Caching:** per-tunnel cache of `{exit_ip, ts}` (in-memory across the daemon
  loop, persisted to a small state file so it survives a daemon restart). Re-probe
  a tunnel only when: cache is empty, cache age > TTL (~300s), **or** the tunnel
  transitioned down→up. No probe for DOWN tunnels.
- Probe runs **off the hot path** (does not block the JSON write / failover
  decision) — stale-but-cached value is emitted immediately; the refresh updates
  it next cycle. Failure leaves the previous cached value (or null) — never blocks.
- Emit into the JSON: `"exit_ip":"185.x.x.x"` (or null) and `"exit_ip_age":<sec>`.

### UI (`failover.js`)
- The existing **Exit IP** column shows the IP plus its age (e.g. `185.x.x.x
  (2m ago)`), and `—` while the tunnel is down or unprobed. No per-poll cost added
  on the client.

**Acceptance:** each UP tunnel shows its true external egress IP within one TTL
window; the value is cached (no probe storm); DOWN tunnels show `—`.

---

## Item 6 — Master enable/disable for the whole app *(fail-open)*

A top-level kill switch that makes the router behave like a plain OpenWrt box
(direct WAN internet, no tunnel) when OFF, and fully restores the stack when ON.

### Persistent state
`amnezia.config.master_enabled` (default `1`). The inits `amnezia-failover`,
`amnezia-dns`, `amnezia-autolearn` check it in `start()`/boot and **no-op when
`0`**, so OFF survives a reboot.

### Backend — new verb `amnezia-failover-ctl master <on|off>`
- **off (fail-open bypass):**
  1. `uci set amnezia.config.master_enabled=0; commit`
  2. stop the failover daemon (`/etc/init.d/amnezia-failover stop`)
  3. `routing_remove_rules` (drops fwmark prefs 31000/31001) + `dns_iprule_flush`
     (drops pref 30900) + flush tables 100/101 (remove any blackhole/default
     there). With the ip rules gone, any still-marked LAN traffic falls through to
     the **main table → WAN direct**.
  4. revert encrypted DNS to plaintext (`amnezia-dns-ctl disable`) and stop the
     autolearn cron.
  5. **verify WAN + DNS reachable**, then return success.
- **on:**
  1. `uci set amnezia.config.master_enabled=1; commit`
  2. start the failover daemon (reinstalls rules/tables via `routing_install_rules`)
  3. re-apply encrypted DNS per UCI (`dot_enabled`) and re-enable autolearn per UCI
     (`autolearn_enabled`).
  4. **verify** handshake + DNS, then return.

Both directions are fail-safe: any verify failure is reported; OFF must never
leave the router without internet (it only ever *removes* policy routing, so the
default is WAN-direct).

**Scope boundary (confirmed):** master-off lifts **policy routing + daemon +
encrypted DNS + autolearn**. It **leaves** the firewall scaffolding (the QUIC
block, the IPv6 LAN→WAN drop) in place — IPv4 internet works directly; full
firewall teardown is the uninstaller's job, not this switch.

### UI (`main.js`)
A prominent master toggle **above the accordion** (its own header strip), showing
current state, with a confirm dialog:
- turning OFF: "Disable all AmneziaWG routing? LAN traffic will go directly to WAN
  (no VPN, no DPI bypass). Encrypted DNS reverts to plaintext. This persists across
  reboot until you re-enable."
- The accordion sections render dimmed/disabled-looking when master is OFF (status
  still readable), so the user understands the stack is bypassed.
- Standard handler shape: exec → repaint full view → notify. Reads
  `master_enabled` from a `load()` read (`uci -q get` via
  `fs.exec('/sbin/uci',['-q','get','amnezia.config.master_enabled'])`, default 1).

**Acceptance:** OFF → clients keep working internet directly with the VPN fully
bypassed, state survives reboot; ON → full stack restored and verified. The toggle
repaints immediately (Item 3 shape).

---

## Cross-cutting: tests & delivery

- **JS harness (`test/lib/luci-harness.js`)** currently executes `render()` +
  `refresh()` but **not handler bodies** — which is exactly why the Item 3 bugs
  escaped. Extend it to **invoke each change handler** (Mode, Sticky, DoT toggle,
  DoT provider, make-default, force-pin/unpin, restart, master on/off) against the
  succeeding-fs and rejecting-fs stubs, asserting (a) no synchronous throw, (b) the
  returned promise resolves (never rejects → no unhandled rejection), and (c) a
  repaint path is exercised. Keep `lintRequires()` and the accordion/`open`
  invariants.
- **bats (`test/unit/*.bats`)** — new cases for the new ctl verbs (`make-default`
  renumber math, `force-pin`/`force-unpin` UCI effects, `restart` arg validation,
  `master on|off` flag + teardown/restore calls) using the existing real-format
  `uci`/`ifup`/`ifdown`/init stubs. New daemon cases: `force_pool` honored
  (up→pin, down→fail-closed), `exit_ip` cache TTL / down→up re-probe, JSON shape
  (`force_pool`, `exit_ip`, `exit_ip_age`).
- **Stubs must mirror real tool output** (the project's hard-won rule): `uci -q get`
  values unquoted, lists one-per-`get`, `ifup`/`ifdown` exit codes realistic.
- **openwrt/ ↔ packages/ parity** — `dev/sync-to-packages.sh` mirrors all changed
  files; CI `sync-check` enforces it. Bump `packages/luci-app-amnezia/Makefile`
  `PKG_RELEASE`.
- **Delivery:** one autonomous pipeline pass (design→plan→execute→deep-review→
  e2e→docs→ship) → a single PR off `main`. Then **surgical** live deploy (place
  changed files + wiring, never re-run the postinst installer), backup first,
  verify WAN + DNS + handshake after each step; SSH (`openWRT`, LAN-side) is the
  recovery channel.

## Out of scope (YAGNI)

- Custom DoT resolver UI (still backend-only via direct UCI).
- Full firewall/uninstall teardown from the master switch.
- Per-tunnel exit-IP geolocation / latency display.
- Moving sticky onto the force-pinned tunnel automatically.
