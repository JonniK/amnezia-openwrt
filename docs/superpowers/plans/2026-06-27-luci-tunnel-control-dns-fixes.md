# LuCI Tunnel Control, DoT Fixes, Exit-IP & Master Switch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add make-default + force-pin tunnel selection, per-tunnel restart, a background cached exit-IP probe, a fail-open master on/off switch, and fix the DoT toggle visibility + the change-handler XHR/no-repaint bug in the LuCI panel.

**Architecture:** Backend changes are POSIX-sh additions to the failover daemon (`openwrt/amnezia-failover`), the control helper (`openwrt/amnezia-failover-ctl.sh`), and the failover init; the UI is the LuCI section modules + the offline JS handler harness. Backend and UI communicate through two fixed contracts: the failover-state JSON (new fields `force_pool`, `exit_ip`, `exit_ip_age`) and the new ctl verbs. UI handlers all adopt one standard shape (exec → repaint → notify, no unhandled rejection).

**Tech Stack:** BusyBox ash / POSIX sh, iproute2, uci, dnsmasq, netifd (`ifup`/`ifdown`), LuCI client JS (`'require'` modules), bats + a Node render/handler harness.

## Global Constraints

- **Never break client internet.** Every router action reversible; verify WAN + DNS + handshake. Master-OFF only ever *removes* policy routing (fail-open → WAN direct); it must never fail-closed.
- **POSIX sh / BusyBox ash only** — no bashisms.
- **`uci -q get <path>` for values; never `uci show | grep | sed`** — real `uci show` quotes values and renders lists on one line.
- **Test stubs MUST mirror real tool output** — `uci -q get` returns the **unquoted** scalar; a bare-section get (`uci -q get amnezia.awg2`) returns the **type** (`tunnel`); lists one-per-`get`; `ifup`/`ifdown` realistic exit codes; `ip`/`nft` real form. A green stub run is not proof — the live router is the final gate.
- **`openwrt/` is the source of truth; mirror to `packages/` via `dev/sync-to-packages.sh`** — CI `sync-check` enforces parity. Bump `packages/luci-app-amnezia/Makefile` `PKG_RELEASE`.
- **LuCI dotted `require` MUST carry `as <alias>`** (binding footgun). Single-segment requires bind without `as`.
- **Poll interval is `POLL_INTERVAL=10` s** (daemon line 193) — reason about probe cadence / exit-IP age in 10s units, not 5s.
- **`*.conf` files contain private keys — never print/commit.**
- **Existing abstractions:** `routing_install_rules` / `routing_remove_rules` (prefs `RULE_PREF_STICKY=31000`, `RULE_PREF_POOL=31001`, tables 100/101) in `lib/amnezia-routing.sh`; `dns_iprule_flush` (pref `RULE_PREF_DOT=30900`) in `lib/amnezia-dns-lib.sh`; daemon source guard `--source-only` (line 298); immediate re-reconcile trigger file `$ST_DIR/immediate` (touch → poll loop breaks its sleep and re-runs `reconcile()` *without* a restart, daemon lines 228/293).
- **`ST_DIR` MUST be a shared single source of truth.** Today `ST_DIR=/tmp/amnezia-fo` is defined **only in the daemon** and is NOT exported by `amnezia-common.sh` — so `amnezia-failover-ctl` (which sources common.sh, not the daemon) sees `ST_DIR` *empty*. The ctl's `touch "$ST_DIR/immediate"` would therefore write to `/immediate` and the daemon would never see the trigger. **Phase 1 moves the canonical `export ST_DIR="${ST_DIR:-/tmp/amnezia-fo}"` into `amnezia-common.sh`**; the daemon keeps its own `ST_DIR=${ST_DIR:-/tmp/amnezia-fo}` as a harmless default (common.sh wins when sourced). Tests must NOT blindly pre-export a different `ST_DIR` and assume it reaches both processes — let common.sh resolve it (or assert the resolved default).

---

## File Structure

| File | Responsibility | Phase |
|---|---|---|
| `openwrt/amnezia-failover` | daemon: honor `globals.force_pool` (read per-cycle in `reconcile()`); detached cached exit-IP probe; emit new JSON fields | 1 |
| `openwrt/lib/amnezia-common.sh` | `amz_master_enabled` helper; exit-IP echo endpoints + TTL (all common.sh edits live in **Phase 1** to keep Wave-1 file-disjoint) | 1 |
| `openwrt/amnezia-failover-ctl.sh` | verbs: `make-default`, `force-pin`, `force-unpin`, `restart`, `master on\|off` | 2 |
| `openwrt/amnezia-failover.init` | gate `start_service()` on `master_enabled` (the only daemon with no own enable-flag) | 3 |
| `openwrt/luci-app-amnezia/amnezia/section/failover.js` | make-default/restart buttons; force-pin select+banner; exit-IP+age cell; **named** `handleSetMode`/`handleSetSticky`; standard handler shape | 4 |
| `openwrt/luci-app-amnezia/amnezia/section/dns.js` | synchronous DoT toggle from `load()`; `dnsRowMarkup(view,st)`; new `handlers:` map | 4 |
| `openwrt/luci-app-amnezia/view/main.js` | master toggle above accordion; `load()` reads DoT status + `master_enabled`; grow harness contract | 4 |
| `test/lib/luci-harness.js`, `test/unit/luci-js.bats` | execute every named change handler under succeeding + rejecting fs; grow `DATA` | 4 |
| `test/unit/*.bats` | ctl verbs, daemon force_pool/exit_ip, `amz_master_enabled` helper, init-guard grep | 1,2,3 |
| `dev/sync-to-packages.sh` (run), `packages/luci-app-amnezia/Makefile`, `CHANGELOG.md` | mirror, bump PKG_RELEASE, changelog | 5 |

**Waves:**
- **Wave 1 (parallel — file-disjoint):** Phase 1 (daemon + common.sh), Phase 2 (ctl), Phase 3 (failover.init). No two phases touch the same file.
- **Wave 2:** Phase 4 (LuCI UI + harness) — codes against the Wave-1 contracts.
- **Wave 3:** Phase 5 (sync + packaging).

### Contracts (frozen — every phase relies on these exact names)

**Failover JSON (per-tunnel object) gains:** `"exit_ip":"<ip>"|null`, `"exit_ip_age":<int seconds>|null`. **Top-level gains:** `"force_pool":"awgN"|null`.

**UCI keys:** `amnezia.globals.force_pool` (`awgN` or unset); `amnezia.config.master_enabled` (`0|1`, default `1`); `amnezia.config.dot_master_saved` / `amnezia.config.autolearn_master_saved` (transient snapshots, only present while master is OFF); `amnezia.<awgN>.metric` (existing).

**Master-switch model (resolves the DoT-preference-loss + init-gating CRITICALs):**
- The **only** persistent gate is `master_enabled`, checked by **`failover.init` only** (failover is the one subsystem with no own enable-flag; DoT and autolearn already gate on `dot_enabled` / `autolearn_enabled`).
- `master off` **snapshots** the user's real intent (`dot_enabled`, `autolearn_enabled`) into `*_master_saved`, then operationally disables each via its own ctl (which turns its intent flag off — that's why we snapshot). `master on` **restores** from the snapshot and re-enables, then deletes the snapshot keys. This makes OFF→ON transparent and reboot-persistent without ever losing the user's preference.
- **Fail-open contract (documented + tested):** master-off stops the failover daemon (its `stop_service` runs `routing_remove_rules`) and flushes tables 100/101. The nft **classifier stays loaded** (it's a fw4 include) and keeps marking packets — this is safe *because the fwmark→table ip rules are gone*, so marked LAN traffic falls through to the main table → WAN direct. A subsequent `fw4 reload` cannot resurrect routing: the pref-31000/31001 rules are **kernel ip rules installed only by the failover daemon/init**, and the init is now master-gated → it won't reinstall them while OFF. (pref-30900 DoT rule is removed by `amnezia-dns-ctl disable` and not re-added while `dot_enabled=0`.)

**ctl verbs (exit 0 on success, nonzero + `amz_log` on bad args):**
- `make-default <awgN>` — require the tunnel **enabled**; set its `metric=1`, renumber other enabled tunnels `2,3,…` (ascending `awg1..awg5` order); commit; `_restart_monitor` (rebuilds MEMBERS — same class as existing `set-weight`/`toggle`).
- `force-pin <awgN>` — `uci set amnezia.globals.force_pool=<awgN>`; commit; **touch `$ST_DIR/immediate`** (no restart → no rules-gone window; the daemon reads `force_pool` per-cycle in `reconcile()`).
- `force-unpin` — `uci -q delete amnezia.globals.force_pool`; commit; touch `$ST_DIR/immediate`.
- `restart <awgN>` — require enabled; `ifdown <awgN>; sleep 1; ifup <awgN>`.
- `master off` / `master on` — see Phase 2 Step 11.

**Common-lib helper:** `amz_master_enabled` → exit 0 (true) when `amnezia.config.master_enabled` != `0` (default enabled), else exit 1.

Reused validator (in ctl):
```sh
_ctl_tun_exists()  { [ -n "$1" ] && [ "$(uci -q get amnezia.$1 2>/dev/null)" = tunnel ]; }
_ctl_tun_enabled() { [ "$(uci -q get amnezia.$1.enabled 2>/dev/null)" = 1 ]; }
```

---

## Phase 1 — Daemon: force-pin honor + detached cached exit-IP probe (+ common.sh helpers)

**Files:**
- Modify: `openwrt/amnezia-failover` (`_best_pool` ~101, `reconcile()` ~116, `run_loop` member build ~197, `write_state` per-tunnel object ~150/160 & top-level printf ~182)
- Modify: `openwrt/lib/amnezia-common.sh` (exit-IP endpoints/TTL; `amz_master_enabled`; **`export ST_DIR`** — placed here in Phase 1 so Wave-1 stays file-disjoint; Phase 3 only consumes the helper)
- Test: `test/unit/failover-daemon.bats` (extend; sources daemon with `--source-only` like the existing `debounce.bats`/`health.bats`)

**Interfaces:**
- Consumes: `_is_healthy`, `$MEMBERS` (`name:metric:weight`), `$STICKY_TARGET`, `reconcile()`, `write_state`, `$ST_DIR`.
- Produces: per-cycle `FORCE_POOL` (read in `reconcile()`); `_probe_exit_ip <awgN>`; cache files `$ST_DIR/exitip.<awgN>.ip` / `.ts`; JSON fields; `amz_master_enabled` (consumed in Phase 3).

### Part A — force_pool honor (read per-cycle)

- [ ] **Step 1: Failing tests — direct `_best_pool` AND the real uci-read path**

In `test/unit/failover-daemon.bats`, source the daemon `--source-only`. Add a tiny setup helper `_best_pool_run` that exports the env then calls `_best_pool`. Cover both the in-memory var and the **uci-read wiring** (the project's most-burned bug class):

```bash
@test "force_pool pins healthy tunnel regardless of metric" {
  FORCE_POOL=awg2 MEMBERS="awg1:1:1 awg2:2:1 awg3:3:1" HEALTHY="awg1 awg2 awg3" run _best_pool
  [ "$output" = awg2 ]
}
@test "force_pool fail-closed when pinned tunnel down" {
  FORCE_POOL=awg2 MEMBERS="awg1:1:1 awg2:2:1 awg3:3:1" HEALTHY="awg1 awg3" run _best_pool
  [ -z "$output" ]
}
@test "no force_pool: lowest-metric healthy" {
  FORCE_POOL="" MEMBERS="awg1:1:1 awg2:2:1 awg3:3:1" HEALTHY="awg2 awg3" run _best_pool
  [ "$output" = awg2 ]
}
@test "reconcile reads force_pool from uci (-q get globals.force_pool)" {
  # Stub uci so `uci -q get amnezia.globals.force_pool` echoes awg3 (unquoted).
  export UCI_GET_amnezia_globals_force_pool=awg3
  MEMBERS="awg1:1:1 awg2:2:1 awg3:3:1" HEALTHY="awg1 awg2 awg3" run _reconcile_pool_probe
  [ "$output" = awg3 ]   # honored via the real read, not a pre-set env var
}
```
`_reconcile_pool_probe` is a 2-line bats helper that runs the exact `FORCE_POOL=$(uci -q get amnezia.globals.force_pool ...)` line from `reconcile()` then echoes `_best_pool`. The `uci` stub's `get` arm returns `$UCI_GET_<dotted_path_underscored>` (existing stub convention).

- [ ] **Step 2: Run — expect FAIL** (`_best_pool` ignores `FORCE_POOL`; `reconcile` doesn't read it).

- [ ] **Step 3: Implement.** Prepend a force-pool early-return to `_best_pool` (leave the existing loop untouched — do NOT re-paste it):
```sh
_best_pool() {
  if [ -n "$FORCE_POOL" ]; then
    _is_healthy "$FORCE_POOL" && echo "$FORCE_POOL"   # pinned: honor only if healthy
    return                                            # else fail-closed (no silent switch)
  fi
  # … existing lowest-metric loop unchanged …
}
```
In `reconcile()` (line ~116, runs every cycle), add as the first line:
```sh
  FORCE_POOL=$(uci -q get amnezia.globals.force_pool 2>/dev/null || echo "")
```
`_sticky_pick` is unchanged (sticky stays independent of force-pin).

- [ ] **Step 4: Run — PASS.**

- [ ] **Step 5: Emit `force_pool` top-level in `write_state`.** Add `"force_pool":%s` to the printf (line ~182):
```sh
_fp=null; [ -n "$FORCE_POOL" ] && _fp="\"$FORCE_POOL\""
```
Add a bats case driving `write_state` (stub members) asserting the JSON contains `"force_pool":"awg2"` when set, `"force_pool":null` when empty.

- [ ] **Step 6: Run all daemon bats — PASS. Commit** `feat(failover): honor globals.force_pool per-cycle (pin pool, fail-closed when down)`.

### Part B — detached cached exit-IP probe (off the serial poll loop)

- [ ] **Step 7: Failing test — `_probe_exit_ip` binds to tunnel, caches, honors TTL, never blocks the loop**

Stub `curl` to (a) require `--interface if!awg1` in its args, (b) echo `$CURL_STUB_OUT`, (c) increment a counter file `$CURL_CALLCOUNT`. Export `ST_DIR=$BATS_TEST_TMPDIR`:
```bash
@test "_probe_exit_ip binds to tunnel, caches, honors TTL" {
  export ST_DIR="$BATS_TEST_TMPDIR" CURL_STUB_OUT=185.10.20.30 CURL_CALLCOUNT="$BATS_TEST_TMPDIR/n"; echo 0 > "$CURL_CALLCOUNT"
  run _probe_exit_ip awg1
  [ "$output" = 185.10.20.30 ]
  [ "$(cat $ST_DIR/exitip.awg1.ip)" = 185.10.20.30 ]
  run _probe_exit_ip awg1                 # within TTL → cached
  [ "$(cat $CURL_CALLCOUNT)" = 1 ]        # curl invoked exactly once
}
@test "refresh pass is detached (loop body issues no blocking curl)" {
  # _refresh_exit_ips backgrounds the probe; assert it returns immediately and
  # the cache is written by the child (poll loop only cats).
  export ST_DIR="$BATS_TEST_TMPDIR" CURL_STUB_OUT=9.9.9.9
  MEMBERS="awg1:1:1" HEALTHY="awg1" run _refresh_exit_ips     # must not block
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 8: Run — expect FAIL** (fns undefined).

- [ ] **Step 9: Implement endpoints + probe + detached refresher.** In `lib/amnezia-common.sh`:
```sh
export AMNEZIA_IPECHO_URLS="${AMNEZIA_IPECHO_URLS:-https://api.ipify.org https://ifconfig.co/ip}"
export AMNEZIA_EXITIP_TTL="${AMNEZIA_EXITIP_TTL:-300}"
```
In the daemon:
```sh
# Refresh one tunnel's public egress IP, bound to its device, cached with TTL.
# Safe to call from a detached subshell; never invoked synchronously in the poll body.
_probe_exit_ip() {  # $1 = awgN ; echoes ip or "" (keeps last-known on failure)
  _ifn=$1; _cf="$ST_DIR/exitip.${_ifn}.ip"; _tf="$ST_DIR/exitip.${_ifn}.ts"
  _now=$(date +%s); _ts=$(cat "$_tf" 2>/dev/null || echo 0)
  if [ -f "$_cf" ] && [ $((_now - _ts)) -lt "${AMNEZIA_EXITIP_TTL:-300}" ]; then cat "$_cf"; return; fi
  _ip=""
  for _u in $AMNEZIA_IPECHO_URLS; do
    _ip=$(curl --interface "if!$_ifn" -fsSL --connect-timeout 5 --max-time 8 "$_u" 2>/dev/null \
          | tr -d ' \t\r\n' | grep -Eo '^[0-9]{1,3}(\.[0-9]{1,3}){3}$') && [ -n "$_ip" ] && break
  done
  if [ -n "$_ip" ]; then printf '%s' "$_ip" > "$_cf"; printf '%s' "$_now" > "$_tf"; echo "$_ip"
  else cat "$_cf" 2>/dev/null; fi
}
# Detached per-cycle refresher: spawns ONE background pass, guarded so passes
# never stack. The poll loop returns immediately; only the child runs curl.
_refresh_exit_ips() {
  _lk="$ST_DIR/exitip.lock"
  ( flock -n 9 || exit 0
    for _m in $MEMBERS; do _n=${_m%%:*}; _is_healthy "$_n" && _probe_exit_ip "$_n" >/dev/null; done
  ) 9>"$_lk" &
}
```
(BusyBox provides `flock`; if absent on target, fall back to a pid/age-guarded lockfile — verify on device. The lock makes overlapping cycles a no-op rather than stacking curls.)

- [ ] **Step 10: Run — PASS.**

- [ ] **Step 11: Wire into the loop + JSON (cache-only read in write_state).** In `run_loop`'s `while true` body (after `reconcile`, before/around `write_state`), call `_refresh_exit_ips` (detached — does not block). In `write_state`'s per-tunnel builder (line ~150/160), read the cache only (no curl):
```sh
_eip=$(cat "$ST_DIR/exitip.${_n}.ip" 2>/dev/null); _ets=$(cat "$ST_DIR/exitip.${_n}.ts" 2>/dev/null || echo 0)
if [ -n "$_eip" ] && [ "$_up" = true ]; then _eipj="\"$_eip\""; _eage=$(( $(date +%s) - _ets )); else _eipj=null; _eage=null; fi
```
Replace the per-tunnel `"exit_ip":null` with `"exit_ip":$_eipj,"exit_ip_age":$_eage`. (down→up immediacy: on a tunnel's up-transition in the debounce/health path, `rm -f "$ST_DIR/exitip.${_n}.ts"` so the next refresh re-probes; if no clean transition hook exists, TTL alone governs — note it.)

- [ ] **Step 12: bats — UP tunnel with cached IP → `"exit_ip":"185.10.20.30"` + integer age; DOWN tunnel → `null,null`. Run all — PASS. Commit** `feat(failover): detached cached exit-IP probe (bound, TTL, off poll hot-path)`.

### Part C — master helper (consumed in Phase 3)

- [ ] **Step 13: Export shared `ST_DIR` from common.sh** (single source of truth so the ctl sees the same path as the daemon). Add near the other exports in `lib/amnezia-common.sh`:
```sh
export ST_DIR="${ST_DIR:-/tmp/amnezia-fo}"
```
Leave the daemon's own `ST_DIR=${ST_DIR:-/tmp/amnezia-fo}` as a default (common.sh wins when sourced). bats: source `amnezia-common.sh` with `ST_DIR` unset → assert `ST_DIR` resolves to `/tmp/amnezia-fo`.

- [ ] **Step 14: Failing test + implement `amz_master_enabled`** in `lib/amnezia-common.sh`:
```sh
# True (0) unless master_enabled is explicitly 0. Default = enabled.
amz_master_enabled() { [ "$(uci -q get amnezia.config.master_enabled 2>/dev/null || echo 1)" != 0 ]; }
```
bats (stub `uci`): unset→true(0), `1`→true(0), `0`→false(1). Run — PASS. **Commit** `feat(common): export ST_DIR, amz_master_enabled helper + exit-IP endpoint config`.

---

## Phase 2 — failover-ctl: tunnel-control + master verbs

**Files:**
- Modify: `openwrt/amnezia-failover-ctl.sh` (add `case` arms before `*)`; add `_ctl_tun_exists`/`_ctl_tun_enabled`; extend usage + header)
- Test: `test/unit/failover-ctl.bats` (extend)

**Interfaces:**
- Consumes: `_restart_monitor`, sourced `amnezia-common.sh` (`amz_log`, `$ST_DIR`) + `amnezia-routing.sh`.
- Produces: verbs `make-default`, `force-pin`, `force-unpin`, `restart`, `master`.

- [ ] **Step 1: Failing tests — `make-default`** (stub `uci`: bare-section get→`tunnel`, `enabled`→`1`, log `set`/`commit`; the `uci` stub must return `tunnel` for `uci -q get amnezia.awgN` — confirm/extend the shared stub):
```bash
@test "make-default sets chosen=1, renumbers others ascending" {
  run amnezia-failover-ctl make-default awg3
  [ "$status" -eq 0 ]
  grep -q 'set amnezia.awg3.metric=1' "$UCI_LOG"
  grep -q 'set amnezia.awg1.metric=2' "$UCI_LOG"
  grep -q 'set amnezia.awg2.metric=3' "$UCI_LOG"
}
@test "make-default rejects unknown tunnel" { run amnezia-failover-ctl make-default awg9; [ "$status" -ne 0 ]; }
@test "make-default rejects disabled tunnel" {
  UCI_GET_amnezia_awg3_enabled=0 run amnezia-failover-ctl make-default awg3
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement validators + `make-default`:**
```sh
  make-default)
    _ctl_tun_exists "$2"  || { amz_log "ctl: make-default unknown tunnel '$2'"; exit 1; }
    _ctl_tun_enabled "$2" || { amz_log "ctl: make-default tunnel '$2' is disabled"; exit 1; }
    uci set "amnezia.$2.metric=1"; _next=2
    for _i in 1 2 3 4 5; do _t="awg$_i"
      [ "$_t" = "$2" ] && continue
      [ "$(uci -q get amnezia.$_t 2>/dev/null)" = tunnel ] || continue
      [ "$(uci -q get amnezia.$_t.enabled 2>/dev/null)" = 1 ] || continue
      uci set "amnezia.$_t.metric=$_next"; _next=$((_next+1))
    done
    uci commit amnezia; _restart_monitor
    ;;
```

- [ ] **Step 4: Run — PASS.**

- [ ] **Step 5: Failing tests — `force-pin`/`force-unpin`/`restart`** (stub `ifup`/`ifdown`→log+exit 0; `$ST_DIR`=tmpdir):
```bash
@test "force-pin sets globals.force_pool and touches trigger (no restart)" {
  run amnezia-failover-ctl force-pin awg2
  [ "$status" -eq 0 ]; grep -q 'set amnezia.globals.force_pool=awg2' "$UCI_LOG"
  [ -f "$ST_DIR/immediate" ]; ! grep -q 'amnezia-failover restart' "$INIT_LOG"
}
@test "force-unpin deletes force_pool and touches trigger" {
  run amnezia-failover-ctl force-unpin
  [ "$status" -eq 0 ]; grep -q 'delete amnezia.globals.force_pool' "$UCI_LOG"; [ -f "$ST_DIR/immediate" ]
}
@test "restart bounces only the named iface" {
  run amnezia-failover-ctl restart awg2
  [ "$status" -eq 0 ]; grep -q 'ifdown awg2' "$IF_LOG"; grep -q 'ifup awg2' "$IF_LOG"; ! grep -q awg1 "$IF_LOG"
}
@test "restart rejects unknown tunnel" { run amnezia-failover-ctl restart awg9; [ "$status" -ne 0 ]; }
```

- [ ] **Step 6: Run — FAIL.**

- [ ] **Step 7: Implement:**
```sh
  force-pin)
    _ctl_tun_exists "$2" || { amz_log "ctl: force-pin unknown tunnel '$2'"; exit 1; }
    uci set "amnezia.globals.force_pool=$2"; uci commit amnezia; touch "$ST_DIR/immediate"
    ;;
  force-unpin)
    uci -q delete amnezia.globals.force_pool; uci commit amnezia; touch "$ST_DIR/immediate"
    ;;
  restart)
    _ctl_tun_exists "$2" || { amz_log "ctl: restart unknown tunnel '$2'"; exit 1; }
    ifdown "$2"; sleep 1; ifup "$2"
    ;;
```

- [ ] **Step 8: Run — PASS.**

- [ ] **Step 9: Failing tests — `master off`/`master on`** (stub `/etc/init.d/amnezia-failover`, `amnezia-dns-ctl`, `amnezia-autolearn-ctl` → log; stub `ip` → log; a tiny WAN/DNS verify hook overridable via env, e.g. `AMNEZIA_VERIFY_CMD=true`):
```bash
@test "master off: flag=0, snapshots intent, stops daemon, fail-open (no blackhole)" {
  UCI_GET_amnezia_config_dot_enabled=1 UCI_GET_amnezia_config_autolearn_enabled=0 \
    AMNEZIA_VERIFY_CMD=true run amnezia-failover-ctl master off
  [ "$status" -eq 0 ]
  grep -q 'set amnezia.config.master_enabled=0' "$UCI_LOG"
  grep -q 'set amnezia.config.dot_master_saved=1' "$UCI_LOG"
  grep -q 'amnezia-failover stop' "$INIT_LOG"
  grep -q 'disable' "$DNSCTL_LOG"            # dot was enabled → operational revert
  ! grep -q blackhole "$IP_LOG"
}
@test "master off: does NOT disable DoT when it was already off" {
  UCI_GET_amnezia_config_dot_enabled=0 AMNEZIA_VERIFY_CMD=true run amnezia-failover-ctl master off
  [ "$status" -eq 0 ]; ! grep -q disable "$DNSCTL_LOG"
}
@test "master on: restores snapshot, starts daemon, re-enables saved DoT" {
  UCI_GET_amnezia_config_dot_master_saved=1 UCI_GET_amnezia_config_autolearn_master_saved=0 \
    AMNEZIA_VERIFY_CMD=true run amnezia-failover-ctl master on
  [ "$status" -eq 0 ]
  grep -q 'set amnezia.config.master_enabled=1' "$UCI_LOG"
  grep -q 'amnezia-failover start' "$INIT_LOG"
  grep -q 'enable' "$DNSCTL_LOG"
  grep -q 'delete amnezia.config.dot_master_saved' "$UCI_LOG"
}
@test "master rejects bad arg" { run amnezia-failover-ctl master sideways; [ "$status" -ne 0 ]; }
```

- [ ] **Step 10: Run — FAIL.**

- [ ] **Step 11: Implement `master`** (snapshot model + WAN/DNS verify; verify cmd overridable for tests):
```sh
  master)
    # Real bounded WAN+DNS probe (amnezia-status only cats JSON → would never fail).
    # Overridable for tests via AMNEZIA_VERIFY_CMD=true.
    _amz_verify_conn() { ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && nslookup -timeout=2 openwrt.org >/dev/null 2>&1; }
    _verify="${AMNEZIA_VERIFY_CMD:-_amz_verify_conn}"
    case "$2" in
      off)
        _ds=$(uci -q get amnezia.config.dot_enabled 2>/dev/null || echo 0)
        _as=$(uci -q get amnezia.config.autolearn_enabled 2>/dev/null || echo 0)
        uci set amnezia.config.master_enabled=0
        uci set amnezia.config.dot_master_saved="$_ds"
        uci set amnezia.config.autolearn_master_saved="$_as"
        uci commit amnezia
        /etc/init.d/amnezia-failover stop 2>/dev/null || true     # stop_service → routing_remove_rules
        [ "$_ds" = 1 ] && { ${AMNEZIA_DNS_CTL:-amnezia-dns-ctl} disable 2>/dev/null || true; }
        [ "$_as" = 1 ] && { ${AMNEZIA_AL_CTL:-amnezia-autolearn-ctl} set-enabled 0 2>/dev/null || true; }
        ip route flush table 100 2>/dev/null || true              # belt-and-suspenders; rules already gone
        ip route flush table 101 2>/dev/null || true
        if $_verify >/dev/null 2>&1; then amz_log "ctl: master OFF — policy routing bypassed (WAN direct)"
        else amz_log "ctl: master OFF applied but WAN/DNS verify FAILED — check connectivity"; fi
        ;;
      on)
        uci set amnezia.config.master_enabled=1; uci commit amnezia
        /etc/init.d/amnezia-failover start 2>/dev/null || true    # gate now passes → reinstalls rules
        _ds=$(uci -q get amnezia.config.dot_master_saved 2>/dev/null || echo 0)
        _as=$(uci -q get amnezia.config.autolearn_master_saved 2>/dev/null || echo 0)
        if [ "$_ds" = 1 ]; then ${AMNEZIA_DNS_CTL:-amnezia-dns-ctl} enable 2>/dev/null || true; fi
        if [ "$_as" = 1 ]; then ${AMNEZIA_AL_CTL:-amnezia-autolearn-ctl} set-enabled 1 2>/dev/null || true; fi
        uci -q delete amnezia.config.dot_master_saved
        uci -q delete amnezia.config.autolearn_master_saved
        uci commit amnezia
        $_verify >/dev/null 2>&1 && amz_log "ctl: master ON — stack restored" \
          || amz_log "ctl: master ON applied but verify FAILED — check handshake/DNS"
        ;;
      *) amz_log "ctl: master requires on|off"; exit 1 ;;
    esac
    ;;
```

- [ ] **Step 12: Update usage string + header comment** to list all new verbs. Run all ctl bats — PASS. **Commit** `feat(failover-ctl): make-default, force-pin/unpin, restart, master on|off (snapshot model)`.

---

## Phase 3 — failover.init master-gate

**Files:**
- Modify: `openwrt/amnezia-failover.init` (guard `start_service` after `_amnezia_load_routing`, before `routing_install_rules`)
- Test: `test/unit/init-master-gate.bats` (create — repo convention: grep the init text + unit-test the helper)

**Interfaces:** consumes `amz_master_enabled` (Phase 1, sourced via `_amnezia_load_routing`).

**Why only this init:** failover is the sole subsystem with no own enable-flag, so it needs the master gate for reboot-persistence. DoT (`dot_enabled`) and autolearn (`autolearn_enabled`) already gate on their own flags, which `master off` turns off via the snapshot model — so editing their inits is unnecessary (and `amnezia-autolearn.init` has no `start_service`, so a generic gate there would be a no-op bug — avoided).

- [ ] **Step 1: Failing test** (the repo tests inits by grepping their text — `init.bats` never executes `start_service`; follow that convention, and separately unit-test the helper which carries the real logic):
```bash
@test "failover.init guards start_service on amz_master_enabled" {
  grep -q 'amz_master_enabled || return 0' openwrt/amnezia-failover.init
}
@test "guard sits before routing_install_rules (no rule install when disabled)" {
  # the guard line number must precede the routing_install_rules line
  g=$(grep -n 'amz_master_enabled || return 0' openwrt/amnezia-failover.init | cut -d: -f1)
  r=$(grep -n 'routing_install_rules' openwrt/amnezia-failover.init | head -1 | cut -d: -f1)
  [ -n "$g" ] && [ -n "$r" ] && [ "$g" -lt "$r" ]
}
```
(The behavioral truth — does the daemon launch? — is covered by the `amz_master_enabled` helper unit test in Phase 1 Step 13 + the Phase 2 `master` verb tests asserting init start/stop. We do not invent a procd-execution harness.)

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Add the guard** to `start_service()` in `openwrt/amnezia-failover.init`, immediately after `_amnezia_load_routing` and before `routing_install_rules`:
```sh
start_service() {
  _amnezia_load_routing
  amz_master_enabled || { logger -t amnezia "master disabled — failover start skipped"; return 0; }
  command -v routing_install_rules >/dev/null 2>&1 && routing_install_rules
  …
}
```

- [ ] **Step 4: Run — PASS. Commit** `feat(init): gate amnezia-failover start on master_enabled (boot-persistent OFF, fail-open)`.

---

## Phase 4 — LuCI UI: handlers, DoT toggle, exit-IP, controls, master switch

**Files:**
- Modify: `openwrt/luci-app-amnezia/amnezia/section/failover.js`, `dns.js`, `view/main.js`
- Modify: `test/lib/luci-harness.js`, `test/unit/luci-js.bats`

**Interfaces:**
- Consumes: JSON `force_pool`/`exit_ip`/`exit_ip_age` (Phase 1); ctl verbs (Phase 2); DoT `status` JSON; `master_enabled` UCI.
- Produces: view handlers `handleSetMode`, `handleSetSticky`, `handleMakeDefault`, `handleTunnelRestart`, `handleForcePin`, `handleForceUnpin`, `handleDotToggle`, `handleDotProvider`, `handleMasterToggle`; shared `dnsRowMarkup(view, st)`.

### Part A — standard handler shape; NAME the Mode/Sticky closures (Item 3 + harness teeth)

- [ ] **Step 1: Standard shape helper** in `failover.js`:
```js
function ctlThenRefresh(view, argv, sectionRefresh) {
    return fs.exec(argv[0], argv.slice(1)).then(function(res) {
        ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
            (res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
            res.code === 0 ? 'info' : 'warning');
        return sectionRefresh(view);
    }).catch(function(err) {
        ui.addNotification(null, E('p', {}, _('Action failed: ') + err), 'danger');
    });
}
```
- [ ] **Step 2: Convert the inline Mode `change` and Sticky `click` closures into NAMED handlers** `handleSetMode`/`handleSetSticky` on `failover.handlers` (so the harness can invoke the exact Item-3 defect site). Each reads its DOM input then `ctlThenRefresh(this, ['/usr/bin/amnezia-failover-ctl', <verb>, <val>], failover.refresh)`. Wire the controls via `ui.createHandlerFn(view,'handleSetMode')` / `'handleSetSticky'`. (This is the fix that makes Mode/Sticky repaint AND become harness-reachable.)

### Part B — DoT toggle synchronous + `handlers:` map (Items 2 & 3)

- [ ] **Step 3: `main.load()` reads DoT status** — append a new bundle leg (document its index):
```js
L.resolveDefault(fs.exec('/usr/bin/amnezia-dns-ctl', ['status']), { stdout: '' })   // index 10
```
- [ ] **Step 4: `dnsRowMarkup(view, st)` shared helper.** Factor the toggle/select/tier markup out of `renderDnsRow` into `dnsRowMarkup(view, st)` (now threading `view` so handlers wire to named view methods). `render(view,data)` parses `data[10].stdout` → builds `#amz-dns-row` already populated; `renderDnsRow` (poll path, keeps the activeElement guard) reuses the same helper. dns.js gains a `handlers:` map with `handleDotToggle`/`handleDotProvider`, each `ctlThenRefresh`-style (exec `amnezia-dns-ctl enable|disable|set-provider` → `dns.refresh(view)` → catch-notify). `main.js` already `Object.assign`s `dns.handlers` (was `undefined`; now real).

### Part C — failover controls + exit-IP (Items 1, 4, 5)

- [ ] **Step 5: Exit-IP cell** in `renderTunnelTable`: `t.exit_ip ? (t.exit_ip + ' (' + util.fmtAge(t.exit_ip_age) + ')') : '—'`.
- [ ] **Step 6: Per-row Make default + Restart buttons.** Add to each row's action cell:
  - **Make default** — hidden when `t.name === state.active_pool` (the actual lowest-metric pool exit; do NOT use `t.carrying`, which is also true for the sticky tunnel). Also hidden when `state.force_pool` is set (metric is moot while pinned). `click` → `handleMakeDefault(ev, t.name)`.
  - **Restart** — `click` → `handleTunnelRestart(ev, t.name)`; `util.uiConfirm` first, busy state, `failover.refresh(view)` after.
- [ ] **Step 7: Force-pin control + banner.** Below Sticky: a "Force pool through" `<select>` of tunnel names + an **Unpin** button. When `state.force_pool` set, show banner: `Failover suspended — pool pinned to <force_pool>. If it drops, pool traffic stops until you unpin.` Handlers `handleForcePin`/`handleForceUnpin`.
- [ ] **Step 8: Implement** `handleMakeDefault`, `handleTunnelRestart`, `handleForcePin`, `handleForceUnpin` in `failover.handlers` via `ctlThenRefresh(this, ['/usr/bin/amnezia-failover-ctl', <verb>, <arg>], failover.refresh)` (Restart wraps in `util.uiConfirm`).

### Part D — master switch (Item 6)

- [ ] **Step 9: `main.load()` reads master flag** — append:
```js
L.resolveDefault(fs.exec('/sbin/uci', ['-q','get','amnezia.config.master_enabled']), { stdout: '1' })  // index 11
```
- [ ] **Step 10: Master strip above the accordion** in `main.render`: a header strip showing state + a toggle button (`master_enabled` parsed from `data[11]`, default `1`). `click` → `handleMasterToggle(ev, currentState)`.
- [ ] **Step 11: `handleMasterToggle`** — `util.uiConfirm` (OFF message from the design), exec `amnezia-failover-ctl master off|on`, then `this.refresh()` + repaint the strip; when OFF add a dimmed class to the accordion (CSS in the existing `<style>`). Standard shape, no unhandled rejection.

### Part E — harness executes every named change handler (the bug-class teeth)

- [ ] **Step 12: Grow `DATA` + execute handlers.** In `test/lib/luci-harness.js`: extend the `DATA` fixture to ≥12 elements (indices 10 DoT-status, 11 master flag) so `data[10]/[11]` aren't `undefined`. After the render pass, add a handler pass: build the assembled view (Object.assign of all section `handlers` + main), then for each name in a `CHANGE_HANDLERS` list (`handleSetMode`, `handleSetSticky`, `handleMakeDefault`, `handleTunnelRestart`, `handleForcePin`, `handleForceUnpin`, `handleDotToggle`, `handleDotProvider`, `handleMasterToggle`) invoke `Promise.resolve().then(()=>view[name](fakeEv,'awg1'))` under BOTH the succeeding-fs and the rejecting-fs module loads, asserting each (a) does not synchronously throw and (b) **resolves** (never rejects). `process.exit(1)` + message on any reject/throw. This is the regression guard that the original Item-3 bug would have tripped.
- [ ] **Step 13: bats `luci-js.bats`** — add a case asserting the harness prints `handler-exec-safe ok`; keep `lintRequires()` + the accordion `open` invariants.
- [ ] **Step 14: Run `node test/lib/luci-harness.js` + `bats test/unit/luci-js.bats` — PASS. Commit** `feat(luci): tunnel controls, exit-IP, DoT toggle fix, master switch + handler harness`.

---

## Phase 5 — Sync to packages + changelog

**Files:** run `dev/sync-to-packages.sh`; modify `packages/luci-app-amnezia/Makefile`, `CHANGELOG.md`.

- [ ] **Step 1:** Run `dev/sync-to-packages.sh`; `git status` shows `packages/` mirrors every changed `openwrt/` file.
- [ ] **Step 2:** Read the current `PKG_RELEASE` in `packages/luci-app-amnezia/Makefile` (don't assume) and bump by one; bump any sh-package Makefile that ships the daemon/ctl too.
- [ ] **Step 3:** Add a `CHANGELOG.md` entry under `[unreleased]` summarizing the six items.
- [ ] **Step 4:** Verify openwrt↔packages parity as CI does (diff mirrored trees / run the repo sync-check). Commit `chore(pkg): sync openwrt→packages, bump PKG_RELEASE, changelog`.

---

## Self-Review

**Spec coverage:** Item 1 → P1A (daemon honor) + P2 (make-default, force-pin/unpin) + P4C. Item 2 → P4B. Item 3 → P4A (named Mode/Sticky) + P4E (harness reaches them). Item 4 → P2 (restart) + P4C. Item 5 → P1B + P4C. Item 6 → P2 (master snapshot model) + P3 (failover.init gate) + P4D. Tests/parity → P4E + P5. ✔

**Review findings folded in:** R2-C1 DoT-preference-loss → snapshot model (P2 S11). R1-C1/R2-C2 autolearn-init-gate → only failover.init gated; DoT/autolearn via own flags (P3). R1-C2 invented procd harness → grep-init + helper unit test (P3 S1). R1-C3 fail-open/fw4 → documented contract + guard-before-install test (Contracts + P3 S1). R1-H1/R2-H1 hot-path probe → detached `_refresh_exit_ips` + flock (P1B). R1-H2 uci-read path untested → P1A S1 case 4. R1-H3 dns.js shape → `dnsRowMarkup(view,st)` + `handlers:` map (P4B). R1-H4 harness can't reach inline closures → named `handleSetMode`/`handleSetSticky` (P4A). R2-H2 disabled make-default → `_ctl_tun_enabled` reject (P2 S1/3). MEDIUMs: no `_restart_monitor` rules-gone window for force-pin (trigger touch, Contracts); `--source-only` convention (P1); 10s interval; make-default hide via `active_pool` not `carrying` (P4C S6); grow `DATA` (P4E S12); read real PKG_RELEASE (P5 S2).

**Cycle-2 review findings folded in:** (C) `$ST_DIR` undefined in the ctl process → `export ST_DIR` from `amnezia-common.sh` as the single source of truth (P1 S13), so `force-pin`'s `touch "$ST_DIR/immediate"` reaches the daemon on the live router, not `/`. (H) master verify was a no-op (`amnezia-status` only cats JSON) → real bounded `_amz_verify_conn` (`ping` + `nslookup`), `AMNEZIA_VERIFY_CMD=true` overridable in tests (P2 S11).

**Placeholder scan:** all code/test steps carry real content; the one conditional (down→up re-probe hook) has an explicit TTL fallback. ✔

**Name consistency:** JSON fields, UCI keys (incl. `*_master_saved`), ctl verbs, handler names used identically across P1↔P2↔P4. `amz_master_enabled` defined P1, consumed P3. ✔
