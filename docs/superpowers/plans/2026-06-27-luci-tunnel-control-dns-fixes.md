# LuCI Tunnel Control, DoT Fixes, Exit-IP & Master Switch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add make-default + force-pin tunnel selection, per-tunnel restart, a background cached exit-IP probe, a fail-open master on/off switch, and fix the DoT toggle visibility + the change-handler XHR/no-repaint bug in the LuCI panel.

**Architecture:** Backend changes are POSIX-sh additions to the failover daemon (`openwrt/amnezia-failover`), the control helper (`openwrt/amnezia-failover-ctl.sh`), and the three procd inits; the UI is the LuCI section modules + the offline JS harness. Backend and UI communicate through two fixed contracts: the failover-state JSON (new fields `force_pool`, `exit_ip`, `exit_ip_age`) and the new ctl verbs. UI handlers all adopt one standard shape (exec → repaint → notify, no unhandled rejection).

**Tech Stack:** BusyBox ash / POSIX sh, iproute2, uci, dnsmasq, netifd (`ifup`/`ifdown`), LuCI client JS (`'require'` modules), bats + a Node render/handler harness.

## Global Constraints

- **Never break client internet.** Every router action reversible; verify WAN + DNS + handshake. Master-OFF only ever *removes* policy routing (fail-open → WAN direct); it must never fail-closed.
- **POSIX sh / BusyBox ash only** — no bashisms. The Bash tool runs zsh; in scripts force word-split with `${=var}` is N/A (these are sh scripts run by ash).
- **`uci -q get <path>` for values; never `uci show | grep | sed`.** Real `uci show` quotes values and renders lists on one line.
- **Test stubs MUST mirror real tool output** — `uci -q get` unquoted scalar, lists one-per-`get`; `ifup`/`ifdown` realistic exit codes; `nft`/`ip` real form. A green stub run is not proof — the live router is the final gate.
- **nftables.d fragments validate with `fw4 check`, not `nft -c -f`.** `fw4 reload` can drop SSH → background it: `( sleep 1 && fw4 reload ) &`.
- **`openwrt/` is the source of truth; mirror to `packages/` via `dev/sync-to-packages.sh`** — CI `sync-check` enforces parity. Bump `packages/luci-app-amnezia/Makefile` `PKG_RELEASE`.
- **LuCI dotted `require` MUST carry `as <alias>`** (binding footgun). Single-segment requires bind without `as`.
- **`*.conf` files contain private keys — never print/commit.**
- **Existing ip-rule/table abstraction:** `routing_install_rules` / `routing_remove_rules` (prefs `RULE_PREF_STICKY=31000`, `RULE_PREF_POOL=31001`, tables 100/101) in `lib/amnezia-routing.sh`; `dns_iprule_flush` (pref `RULE_PREF_DOT=30900`) in `lib/amnezia-dns-lib.sh`.

---

## File Structure

| File | Responsibility | Phase |
|---|---|---|
| `openwrt/amnezia-failover` | daemon: honor `globals.force_pool`; cached bound exit-IP probe; emit new JSON fields | 1 |
| `openwrt/amnezia-failover-ctl.sh` | new verbs: `make-default`, `force-pin`, `force-unpin`, `restart`, `master on\|off` | 2 |
| `openwrt/amnezia-failover.init`, `openwrt/amnezia-dns.init`, `openwrt/amnezia-autolearn.init` | gate `start_service()` on `master_enabled` | 3 |
| `openwrt/lib/amnezia-common.sh` | `amz_master_enabled` helper; exit-IP echo endpoints | 1,3 |
| `openwrt/luci-app-amnezia/amnezia/section/failover.js` | make-default/force-pin/restart buttons; exit-IP+age cell; force-pin banner; standard handler shape | 4 |
| `openwrt/luci-app-amnezia/amnezia/section/dns.js` | synchronous DoT toggle from `load()` data; standard handler shape | 4 |
| `openwrt/luci-app-amnezia/view/main.js` | master toggle above accordion; `load()` reads DoT status + `master_enabled` | 4 |
| `test/lib/luci-harness.js` | execute change handlers under succeeding + rejecting fs | 4 |
| `test/unit/*.bats` | ctl verbs, daemon force_pool/exit_ip, init gating | 1,2,3 |
| `dev/sync-to-packages.sh` (run), `packages/luci-app-amnezia/Makefile`, `CHANGELOG.md` | mirror openwrt→packages, bump PKG_RELEASE, changelog | 5 |

**Waves:**
- **Wave 1 (parallel — file-disjoint):** Phase 1 (daemon), Phase 2 (ctl), Phase 3 (inits + helper).
- **Wave 2:** Phase 4 (LuCI UI + harness) — codes against the Wave-1 contracts.
- **Wave 3:** Phase 5 (sync + packaging).

### Contracts (frozen — every phase relies on these exact names)

**Failover JSON (per-tunnel object) gains:** `"exit_ip":"<ip>"|null`, `"exit_ip_age":<int seconds>|null`. **Top-level gains:** `"force_pool":"awgN"|null`.

**UCI keys:** `amnezia.globals.force_pool` (`awgN` or unset), `amnezia.config.master_enabled` (`0|1`, default `1`), `amnezia.<awgN>.metric` (existing).

**ctl verbs (exit 0 on success, nonzero + `amz_log` on bad args):**
- `make-default <awgN>` — set `amnezia.<awgN>.metric=1`, renumber other **enabled** tunnels `2,3,…` preserving prior relative order; commit; restart monitor.
- `force-pin <awgN>` — `uci set amnezia.globals.force_pool=<awgN>`; commit; restart monitor.
- `force-unpin` — `uci -q delete amnezia.globals.force_pool`; commit; restart monitor.
- `restart <awgN>` — `ifdown <awgN>; sleep 1; ifup <awgN>`.
- `master off` / `master on` — see Phase 2.

**Common-lib helper:** `amz_master_enabled` → returns 0 (true) when `amnezia.config.master_enabled` != `0` (default enabled), else 1.

---

## Phase 1 — Daemon: force-pin honor + cached exit-IP probe

**Files:**
- Modify: `openwrt/amnezia-failover` (`_best_pool`, the MEMBERS/uci read block ~196–219, the JSON `printf` ~182, per-tunnel object build ~160)
- Modify: `openwrt/lib/amnezia-common.sh` (add exit-IP echo endpoint list)
- Test: `test/unit/failover-daemon.bats` (create if absent; else add cases)

**Interfaces:**
- Consumes: existing `_is_healthy`, `$MEMBERS` (`name:metric:weight` words), `$STICKY_TARGET`, the per-tunnel JSON builder.
- Produces: JSON fields `force_pool` (top-level), `exit_ip`/`exit_ip_age` (per tunnel); shell fn `_probe_exit_ip <awgN>` and cache file `/var/run/amnezia-exitip.<awgN>`.

### Part A — force_pool honor

- [ ] **Step 1: Failing test — force_pool pins pool when target healthy, fails closed when down**

Create `test/unit/failover-daemon.bats`. Stub `uci` (real format: `uci -q get amnezia.globals.force_pool` echoes `awg2` unquoted), and drive `_best_pool` with a sourced harness that sets `MEMBERS="awg1:1:1 awg2:2:1 awg3:3:1"` and `HEALTHY`:

```bash
@test "force_pool returns pinned tunnel when healthy regardless of metric" {
  FORCE_POOL=awg2 MEMBERS="awg1:1:1 awg2:2:1 awg3:3:1" HEALTHY="awg1 awg2 awg3" \
    run _best_pool_test
  [ "$output" = "awg2" ]
}
@test "force_pool returns empty (fail-closed) when pinned tunnel down" {
  FORCE_POOL=awg2 MEMBERS="awg1:1:1 awg2:2:1 awg3:3:1" HEALTHY="awg1 awg3" \
    run _best_pool_test
  [ -z "$output" ]
}
@test "no force_pool falls back to lowest-metric healthy" {
  FORCE_POOL="" MEMBERS="awg1:1:1 awg2:2:1 awg3:3:1" HEALTHY="awg2 awg3" \
    run _best_pool_test
  [ "$output" = "awg2" ]
}
```

(`_best_pool_test` is a tiny wrapper the bats setup defines that exports the env then calls the real `_best_pool`; source the daemon with a guard so it doesn't run its main loop — see existing daemon bats setup pattern if one exists, else `AMNEZIA_NO_MAIN=1`.)

- [ ] **Step 2: Run — expect FAIL** (`_best_pool` ignores FORCE_POOL).

- [ ] **Step 3: Implement force_pool in `_best_pool`**

Read `FORCE_POOL` once in the reconcile/uci block (near line 196):
```sh
FORCE_POOL=$(uci -q get amnezia.globals.force_pool 2>/dev/null || echo "")
```
Prepend to `_best_pool`:
```sh
_best_pool() {
  if [ -n "$FORCE_POOL" ]; then
    # Pinned: honor only if healthy, else fail-closed (no silent switch).
    _is_healthy "$FORCE_POOL" && echo "$FORCE_POOL"
    return
  fi
  _b=""; _bm=9999
  for _m in $MEMBERS; do _n=${_m%%:*}; _met=$(echo "$_m" | cut -d: -f2)
    _is_healthy "$_n" || continue
    [ "$_met" -lt "$_bm" ] && { _b=$_n; _bm=$_met; }
  done
  echo "$_b"
}
```
Note: `_sticky_pick` is unchanged (sticky stays independent of force-pin, per design).

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Emit `force_pool` in JSON.** Add `"force_pool":%s` to the top-level `printf` (line ~182), value = `\"$FORCE_POOL\"` when set else `null`:
```sh
_fp=null; [ -n "$FORCE_POOL" ] && _fp="\"$FORCE_POOL\""
```
Add a bats case asserting the rendered JSON contains `"force_pool":"awg2"` when set and `"force_pool":null` when unset (drive the state-writer fn with stubbed members).

- [ ] **Step 6: Run all daemon bats — PASS. Commit** `feat(failover): honor globals.force_pool (pin pool, fail-closed when down)`.

### Part B — cached bound exit-IP probe

- [ ] **Step 7: Failing test — `_probe_exit_ip` binds to the tunnel and caches**

Stub `curl` so that `curl --interface if!awg1 ...` echoes `185.10.20.30`; assert `_probe_exit_ip awg1` writes `185.10.20.30` to `/var/run/amnezia-exitip.awg1` and echoes it; a second call within TTL does **not** re-invoke curl (assert via a curl-call counter file):

```bash
@test "_probe_exit_ip binds to tunnel, caches result, honors TTL" {
  CURL_STUB_OUT=185.10.20.30 run _probe_exit_ip awg1
  [ "$output" = "185.10.20.30" ]
  [ "$(cat $RUNDIR/amnezia-exitip.awg1.ip)" = "185.10.20.30" ]
  run _probe_exit_ip awg1            # within TTL → cached, no new curl
  [ "$(cat $CURL_CALLCOUNT)" = "1" ]
}
```

- [ ] **Step 8: Run — expect FAIL** (fn undefined).

- [ ] **Step 9: Implement `_probe_exit_ip` + endpoints.** In `lib/amnezia-common.sh` add:
```sh
# Small plaintext IP-echo endpoints for exit-IP probing (primary + fallback).
export AMNEZIA_IPECHO_URLS="https://api.ipify.org https://ifconfig.co/ip"
export AMNEZIA_EXITIP_TTL=300
```
In the daemon:
```sh
# Probe a tunnel's public egress IP bound to its device, cached with TTL.
# Off the hot path: callers use the cached value; this only refreshes it.
_probe_exit_ip() {  # $1 = awgN ; echoes ip or "" ; never blocks the JSON write
  _ifn=$1
  _cf="${AMNEZIA_RUNDIR:-/var/run}/amnezia-exitip.${_ifn}.ip"
  _tf="${AMNEZIA_RUNDIR:-/var/run}/amnezia-exitip.${_ifn}.ts"
  _now=$(date +%s)
  _ts=$(cat "$_tf" 2>/dev/null || echo 0)
  if [ -f "$_cf" ] && [ $((_now - _ts)) -lt "${AMNEZIA_EXITIP_TTL:-300}" ]; then
    cat "$_cf"; return
  fi
  _ip=""
  for _u in $AMNEZIA_IPECHO_URLS; do
    _ip=$(curl --interface "if!$_ifn" -fsSL --connect-timeout 5 --max-time 8 "$_u" 2>/dev/null \
          | tr -d ' \t\r\n' | grep -Eo '^[0-9]{1,3}(\.[0-9]{1,3}){3}$') && [ -n "$_ip" ] && break
  done
  if [ -n "$_ip" ]; then printf '%s' "$_ip" > "$_cf"; printf '%s' "$_now" > "$_tf"; echo "$_ip"
  else cat "$_cf" 2>/dev/null; fi   # keep last-known on failure
}
```
Re-probe trigger: in the reconcile/health loop, when a tunnel transitions down→up, `rm -f` its `.ts` so the next `_probe_exit_ip` refreshes immediately (find the existing transition point; if none, TTL alone suffices — note it).

- [ ] **Step 10: Run — expect PASS.**

- [ ] **Step 11: Wire exit_ip into the per-tunnel JSON object.** In the per-tunnel builder (line ~160), for UP tunnels set `exit_ip`/`exit_ip_age` from the cache (do NOT call curl synchronously in the JSON loop — read the cache file only; a separate pass per cycle calls `_probe_exit_ip` for each healthy tunnel to refresh the cache):
```sh
# refresh pass (once per cycle, before building JSON):
for _m in $MEMBERS; do _n=${_m%%:*}; _is_healthy "$_n" && _probe_exit_ip "$_n" >/dev/null; done
```
Per-tunnel object: replace `"exit_ip":null` with cache-derived value:
```sh
_eip=$(cat "${AMNEZIA_RUNDIR:-/var/run}/amnezia-exitip.${_n}.ip" 2>/dev/null)
_ets=$(cat "${AMNEZIA_RUNDIR:-/var/run}/amnezia-exitip.${_n}.ts" 2>/dev/null || echo 0)
if [ -n "$_eip" ] && [ "$_up" = true ]; then
  _eipj="\"$_eip\""; _eage=$(( $(date +%s) - _ets ))
else _eipj=null; _eage=null; fi
```
and emit `"exit_ip":$_eipj,"exit_ip_age":$_eage`.

- [ ] **Step 12: bats — JSON for an UP tunnel with a cached IP shows `"exit_ip":"185.10.20.30"`, age integer; a DOWN tunnel shows `null,null`. Run all — PASS. Commit** `feat(failover): background cached exit-IP probe (bound to tunnel, TTL)`.

---

## Phase 2 — failover-ctl: tunnel-control + master verbs

**Files:**
- Modify: `openwrt/amnezia-failover-ctl.sh` (add `case` arms before the `*)` default; extend usage string + header comment)
- Test: `test/unit/failover-ctl.bats` (create/extend)

**Interfaces:**
- Consumes: existing `_restart_monitor`, sourced `amnezia-common.sh` + `amnezia-routing.sh` (`routing_remove_rules`), `amz_log`.
- Produces: verbs `make-default`, `force-pin`, `force-unpin`, `restart`, `master`.

A helper to validate a tunnel exists (reused by all per-tunnel verbs):
```sh
_ctl_tun_exists() {  # $1 = awgN ; 0 if a config tunnel section exists
  [ -n "$1" ] && [ "$(uci -q get amnezia.$1 2>/dev/null)" = "tunnel" ]
}
```

- [ ] **Step 1: Failing test — `make-default awg3` renumbers metrics**

Stub `uci`: `-q get amnezia.awgN` → `tunnel`; track `uci set amnezia.awgN.metric=…` calls to a log file; `amnezia.awgN.enabled` → `1`. Assert after `make-default awg3` (with awg1,awg2,awg3 enabled, prior metrics 1,2,3): awg3→1, awg1→2, awg2→3 (preserve relative order of the non-chosen), and `_restart_monitor` invoked:

```bash
@test "make-default sets chosen=1 and renumbers others preserving order" {
  run amnezia-failover-ctl make-default awg3
  [ "$status" -eq 0 ]
  grep -q 'amnezia.awg3.metric=1' "$UCI_SETLOG"
  grep -q 'amnezia.awg1.metric=2' "$UCI_SETLOG"
  grep -q 'amnezia.awg2.metric=3' "$UCI_SETLOG"
}
@test "make-default rejects unknown tunnel" {
  run amnezia-failover-ctl make-default awg9
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement `make-default`** (before `*)`):
```sh
  make-default)
    _ctl_tun_exists "$2" || { amz_log "ctl: make-default unknown tunnel '$2'"; exit 1; }
    uci set "amnezia.$2.metric=1"
    _next=2
    for _i in 1 2 3 4 5; do
      _t="awg$_i"
      [ "$_t" = "$2" ] && continue
      [ "$(uci -q get amnezia.$_t 2>/dev/null)" = tunnel ] || continue
      [ "$(uci -q get amnezia.$_t.enabled 2>/dev/null)" = 0 ] && continue
      uci set "amnezia.$_t.metric=$_next"; _next=$((_next+1))
    done
    uci commit amnezia
    _restart_monitor
    ;;
```
(Relative-order note: iterating `awg1..awg5` ascending preserves their natural order; the design says "preserving relative order" — natural index order is the deterministic, stable choice. Document this in the header comment.)

- [ ] **Step 4: Run — PASS.**

- [ ] **Step 5: Failing tests — force-pin / force-unpin / restart**
```bash
@test "force-pin sets globals.force_pool and restarts monitor" {
  run amnezia-failover-ctl force-pin awg2
  [ "$status" -eq 0 ]; grep -q 'amnezia.globals.force_pool=awg2' "$UCI_SETLOG"
}
@test "force-unpin deletes globals.force_pool" {
  run amnezia-failover-ctl force-unpin
  [ "$status" -eq 0 ]; grep -q 'delete amnezia.globals.force_pool' "$UCI_DELLOG"
}
@test "restart bounces only the named interface" {
  run amnezia-failover-ctl restart awg2
  [ "$status" -eq 0 ]
  grep -q 'ifdown awg2' "$IF_LOG"; grep -q 'ifup awg2' "$IF_LOG"
  ! grep -q 'awg1\|awg3' "$IF_LOG"
}
@test "restart rejects unknown tunnel" { run amnezia-failover-ctl restart awg9; [ "$status" -ne 0 ]; }
```
(Stub `ifup`/`ifdown` to append `$0 $1` to `$IF_LOG` and exit 0.)

- [ ] **Step 6: Run — expect FAIL.**

- [ ] **Step 7: Implement the three verbs:**
```sh
  force-pin)
    _ctl_tun_exists "$2" || { amz_log "ctl: force-pin unknown tunnel '$2'"; exit 1; }
    uci set "amnezia.globals.force_pool=$2"; uci commit amnezia; _restart_monitor
    ;;
  force-unpin)
    uci -q delete amnezia.globals.force_pool; uci commit amnezia; _restart_monitor
    ;;
  restart)
    _ctl_tun_exists "$2" || { amz_log "ctl: restart unknown tunnel '$2'"; exit 1; }
    ifdown "$2"; sleep 1; ifup "$2"
    ;;
```

- [ ] **Step 8: Run — PASS.**

- [ ] **Step 9: Failing tests — `master off` / `master on`**

`master off` must: set `amnezia.config.master_enabled=0`, commit, stop the failover init, call `routing_remove_rules`, call `dns_iprule_flush` (or `amnezia-dns-ctl disable`), and NOT install any blackhole. `master on` must set the flag to 1 and start the init. Stub the init (`/etc/init.d/amnezia-failover` → log `stop`/`start`), `routing_remove_rules`/`dns_iprule_flush` (log), `amnezia-dns-ctl` (log), `ip` (log; assert table-100/101 flush). Tests:
```bash
@test "master off sets flag, stops daemon, removes rules (fail-open)" {
  run amnezia-failover-ctl master off
  [ "$status" -eq 0 ]
  grep -q 'amnezia.config.master_enabled=0' "$UCI_SETLOG"
  grep -q 'amnezia-failover stop' "$INIT_LOG"
  grep -q 'routing_remove_rules' "$FNLOG"
  ! grep -q 'blackhole' "$IP_LOG"
}
@test "master on sets flag and starts daemon" {
  run amnezia-failover-ctl master on
  [ "$status" -eq 0 ]
  grep -q 'amnezia.config.master_enabled=1' "$UCI_SETLOG"
  grep -q 'amnezia-failover start' "$INIT_LOG"
}
@test "master rejects bad arg" { run amnezia-failover-ctl master sideways; [ "$status" -ne 0 ]; }
```

- [ ] **Step 10: Run — expect FAIL.**

- [ ] **Step 11: Implement `master`:**
```sh
  master)
    case "$2" in
      off)
        uci set amnezia.config.master_enabled=0; uci commit amnezia
        /etc/init.d/amnezia-failover stop 2>/dev/null || true
        routing_remove_rules 2>/dev/null || true
        # Drop DoT ip-rule + revert encrypted DNS to plaintext (fail-open).
        ${AMNEZIA_DNS_CTL:-amnezia-dns-ctl} disable 2>/dev/null || true
        # Flush policy tables so no stale blackhole/default remains; with the
        # fwmark rules gone, marked LAN traffic falls through to main → WAN.
        ip route flush table 100 2>/dev/null || true
        ip route flush table 101 2>/dev/null || true
        # Stop autolearn cron (best-effort; init disable path).
        /etc/init.d/amnezia-autolearn stop 2>/dev/null || true
        amz_log "ctl: master OFF — policy routing bypassed (WAN direct)"
        ;;
      on)
        uci set amnezia.config.master_enabled=1; uci commit amnezia
        /etc/init.d/amnezia-failover start 2>/dev/null || true
        # DNS + autolearn re-apply per their own UCI flags via their inits.
        [ "$(uci -q get amnezia.config.dot_enabled 2>/dev/null)" = 1 ] && \
          ${AMNEZIA_DNS_CTL:-amnezia-dns-ctl} enable 2>/dev/null || true
        /etc/init.d/amnezia-autolearn start 2>/dev/null || true
        amz_log "ctl: master ON — stack restored"
        ;;
      *) amz_log "ctl: master requires on|off"; exit 1 ;;
    esac
    ;;
```

- [ ] **Step 12: Update usage string + header comment** to list all new verbs. Run all ctl bats — PASS. **Commit** `feat(failover-ctl): make-default, force-pin/unpin, restart, master on|off`.

---

## Phase 3 — Init master-gating

**Files:**
- Modify: `openwrt/lib/amnezia-common.sh` (add `amz_master_enabled`)
- Modify: `openwrt/amnezia-failover.init`, `openwrt/amnezia-dns.init`, `openwrt/amnezia-autolearn.init` (guard `start_service`)
- Test: `test/unit/init-master-gate.bats` (create)

**Interfaces:**
- Produces: `amz_master_enabled` (exit 0 when enabled / flag != 0; exit 1 when `0`).

- [ ] **Step 1: Failing test — helper semantics**
```bash
@test "amz_master_enabled true by default (unset)" { UCI_GET_master_enabled="" run amz_master_enabled; [ "$status" -eq 0 ]; }
@test "amz_master_enabled true when 1"            { UCI_GET_master_enabled=1  run amz_master_enabled; [ "$status" -eq 0 ]; }
@test "amz_master_enabled false when 0"           { UCI_GET_master_enabled=0  run amz_master_enabled; [ "$status" -eq 1 ]; }
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement helper** in `lib/amnezia-common.sh`:
```sh
# True (0) unless master_enabled is explicitly 0. Default = enabled.
amz_master_enabled() {
  [ "$(uci -q get amnezia.config.master_enabled 2>/dev/null || echo 1)" != 0 ]
}
```

- [ ] **Step 4: Run — PASS.**

- [ ] **Step 5: Failing test — failover init no-ops when disabled**

Stub the init's procd calls; assert that with `master_enabled=0`, `start_service` does NOT call `procd_set_param command` (i.e. the daemon isn't launched). Use the init's testability hook — source it with procd functions stubbed to log:
```bash
@test "amnezia-failover start_service skips daemon when master disabled" {
  UCI_GET_master_enabled=0 run start_service_test amnezia-failover.init
  ! grep -q 'command /usr/sbin/amnezia-failover' "$PROCD_LOG"
}
@test "amnezia-failover start_service launches daemon when enabled" {
  UCI_GET_master_enabled=1 run start_service_test amnezia-failover.init
  grep -q 'command /usr/sbin/amnezia-failover' "$PROCD_LOG"
}
```

- [ ] **Step 6: Run — FAIL.**

- [ ] **Step 7: Guard each init.** At the top of `start_service()` in all three inits (after sourcing the common lib), add:
```sh
  . /usr/lib/amnezia/amnezia-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/amnezia/amnezia-common.sh" 2>/dev/null
  amz_master_enabled || { logger -t amnezia "master disabled — $(basename "$0") start skipped"; return 0; }
```
(Match each init's existing lib-sourcing convention; only add the guard line if the lib is already sourced there. For `amnezia-dns`/`amnezia-autolearn`, place the guard before they wire dnsmasq/cron so a disabled master leaves DNS plain and no cron.)

- [ ] **Step 8: Run — PASS for all three inits (add the dns + autolearn variants of the test). Commit** `feat(init): gate failover/dns/autolearn on master_enabled (boot-persistent OFF)`.

---

## Phase 4 — LuCI UI: handlers, DoT toggle, exit-IP, controls, master switch

**Files:**
- Modify: `openwrt/luci-app-amnezia/amnezia/section/failover.js`
- Modify: `openwrt/luci-app-amnezia/amnezia/section/dns.js`
- Modify: `openwrt/luci-app-amnezia/view/main.js`
- Modify: `test/lib/luci-harness.js`, `test/unit/luci-js.bats`

**Interfaces:**
- Consumes: failover JSON fields `force_pool`/`exit_ip`/`exit_ip_age` (Phase 1), ctl verbs (Phase 2), DoT `status` JSON, `master_enabled` UCI.
- Produces: view handlers `handleMakeDefault`, `handleForcePin`, `handleForceUnpin`, `handleTunnelRestart`, `handleDotToggle`, `handleDotProvider`, `handleMasterToggle`; shared `dnsRowMarkup(st)`.

### Part A — standard handler shape + Mode/Sticky/DoT repaint (Item 3)

- [ ] **Step 1: Define the standard shape once.** In `failover.js` add a small helper exported on the module (or inline pattern reused). The shape:
```js
// exec a ctl command, then repaint the owning section; never leak a rejection.
function ctlThenRefresh(view, sectionRefresh, argv, okMsg) {
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
Convert the inline Mode `change` and Sticky `click` handlers to call `failover.refresh(view)` after exec (they currently don't repaint). Keep `ui.createHandlerFn` wrapping.

- [ ] **Step 2: dns.js — route DoT toggle/provider through the standard shape with repaint.** Replace the bare `change`/`click` handlers (`setDot`/`setDnsProvider` with no `.catch`) so each: execs `amnezia-dns-ctl enable|disable|set-provider`, then calls the dns module's `refresh(view)`, with a `.catch` that notifies. Wrap via `ui.createHandlerFn(view, 'handleDotToggle')` / `'handleDotProvider'` (add these to a `handlers:` map on the dns module so `main.js` `Object.assign`s them).

### Part B — DoT toggle visible on first paint (Item 2)

- [ ] **Step 3: Add DoT status to `main.load()`.** Append:
```js
L.resolveDefault(fs.exec('/usr/bin/amnezia-dns-ctl', ['status']), { stdout: '' })
```
as a new bundle index (document the index in a comment; it follows the existing `force-update.json` read).

- [ ] **Step 4: Extract shared row markup + render synchronously.** In `dns.js`, factor the toggle/select/tier markup into `dnsRowMarkup(st)` used by BOTH `render(view,data)` (parse `data[<dot-index>].stdout` → paint immediately) and `renderDnsRow` (poll path). `render` builds `#amz-dns-row` already populated; the poll keeps it live (with the existing activeElement guard).

### Part C — failover controls + exit-IP (Items 1, 4, 5)

- [ ] **Step 5: Exit-IP cell.** In `renderTunnelTable`, render `t.exit_ip` + age: `t.exit_ip ? (t.exit_ip + ' (' + fmtAge-style + ')') : '—'`. Reuse `util.fmtAge(t.exit_ip_age)` for the age suffix; `—` when down/null.

- [ ] **Step 6: Per-row Make default + Restart buttons.** Add two buttons to each row's action area:
  - **Make default** — hidden when the row is already the current default (lowest metric / `t.carrying` in failover mode with no force_pool). `click` → `ui.createHandlerFn(view,'handleMakeDefault', t.name)`.
  - **Restart** — `click` → `ui.createHandlerFn(view,'handleTunnelRestart', t.name)`; confirm dialog via `util.uiConfirm`, busy state, post-action `failover.refresh(view)`.

- [ ] **Step 7: Force-pin control + banner.** Below the Sticky row, add a "Force pool through" select (tunnel names from state) + an **Unpin** button. When `state.force_pool` is set, render a banner: `Failover suspended — pool pinned to <force_pool>. If it drops, pool traffic stops until you unpin.` Handlers `handleForcePin`/`handleForceUnpin` use the standard shape.

- [ ] **Step 8: Implement the handlers** (`handleMakeDefault`, `handleTunnelRestart`, `handleForcePin`, `handleForceUnpin`) in `failover.js` `handlers:`, each `ctlThenRefresh(this, failover.refresh, ['/usr/bin/amnezia-failover-ctl', <verb>, <arg>], …)`. Restart wraps in a `util.uiConfirm` first.

### Part D — master switch (Item 6)

- [ ] **Step 9: `main.load()` reads master flag.** Append:
```js
L.resolveDefault(fs.exec('/sbin/uci', ['-q', 'get', 'amnezia.config.master_enabled']), { stdout: '1' })
```
- [ ] **Step 10: Master toggle above the accordion.** In `main.render`, before the `amnezia-accordion` div, add a header strip with current state + a toggle button. Parse `master_enabled` from the load bundle (default `1`). `click` → `ui.createHandlerFn(this,'handleMasterToggle', currentState)`.
- [ ] **Step 11: `handleMasterToggle`.** Confirm via `util.uiConfirm` (OFF message from the design), exec `amnezia-failover-ctl master off|on`, then `this.refresh()` + repaint the master strip. When OFF, add a dimmed class to the accordion (CSS in the existing `<style>` block). Standard shape, no unhandled rejection.

### Part E — harness + bats (the bug-class that escaped before)

- [ ] **Step 12: Harness executes handlers.** In `test/lib/luci-harness.js`, after the render pass, add a handler-execution pass: build the view (Object.assign of handler maps), then for each new/changed change-handler name, invoke it with a synthetic event under BOTH the succeeding-fs and rejecting-fs module loads, asserting: (a) no synchronous throw, (b) the returned value is a Promise that **resolves** (never rejects). Add to the self-test (`process.exit(1)` on any reject). This is the regression guard for Item 3.
```js
// pseudo: for (name of CHANGE_HANDLERS) { const p = Promise.resolve().then(()=>view[name](fakeEv, 'awg1'));
//   await assertResolves(p); }   // under fsApi AND fsRej
```
- [ ] **Step 13: bats `luci-js.bats`** — add a case calling the harness handler-pass and asserting `handler-reject-safe ok`. Keep `lintRequires()` + accordion-`open` invariants.

- [ ] **Step 14: Run `node test/lib/luci-harness.js` + `bats test/unit/luci-js.bats` — all PASS. Commit** `feat(luci): tunnel controls, exit-IP, DoT toggle fix, master switch + handler harness`.

---

## Phase 5 — Sync to packages + changelog

**Files:**
- Run: `dev/sync-to-packages.sh`
- Modify: `packages/luci-app-amnezia/Makefile` (`PKG_RELEASE`), `CHANGELOG.md`

- [ ] **Step 1:** Run `dev/sync-to-packages.sh`; `git status` shows `packages/` mirrors the changed `openwrt/` files (daemon, ctl, inits, lib, JS modules).
- [ ] **Step 2:** Bump `packages/luci-app-amnezia/Makefile` `PKG_RELEASE` (4→5). If a sh-package Makefile also carries the daemon/ctl, bump its release too.
- [ ] **Step 3:** Add a `CHANGELOG.md` entry under `[unreleased]` summarizing the six items.
- [ ] **Step 4:** Verify openwrt↔packages parity the way CI does (diff the mirrored trees / run the repo's sync-check if present). Commit `chore(pkg): sync openwrt→packages, bump PKG_RELEASE, changelog`.

---

## Self-Review

**Spec coverage:** Item 1 → Phase 1A (daemon honor) + Phase 2 (make-default, force-pin/unpin) + Phase 4C (UI). Item 2 → Phase 4B. Item 3 → Phase 4A + Phase 4E (harness teeth). Item 4 → Phase 2 (restart) + Phase 4C. Item 5 → Phase 1B + Phase 4C. Item 6 → Phase 2 (master verb) + Phase 3 (init gate) + Phase 4D. Cross-cutting tests/parity → Phase 4E + Phase 5. ✔ no gaps.

**Placeholder scan:** all code steps carry real code; test steps carry real assertions; the one "find the existing down→up transition point" in Phase 1B has an explicit TTL-only fallback. ✔

**Type/name consistency:** JSON fields (`force_pool`, `exit_ip`, `exit_ip_age`), UCI keys (`globals.force_pool`, `config.master_enabled`), ctl verbs, and handler names are used identically across Phases 1↔2↔4. `amz_master_enabled` defined Phase 3, consumed Phase 3 inits (Phase 2 `master` verb sets the flag directly, doesn't call the helper — intentional). ✔
