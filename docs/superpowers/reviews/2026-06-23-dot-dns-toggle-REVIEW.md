# Encrypted DNS (DoT) Toggle — Deep-Review Record

**Feature branch:** `feat/dot-dns-toggle`
**Review surface (cycle 1):** `a198a37..b7ed56a` — 10 commits, 36 files
**Method:** Stage-8 deep-review workflow — one `superpowers-reviewer` (opus) per dimension over the whole integrated diff, then adversarial refutation of every finding (only verified findings retained). 8 generic dimensions + 4 feature-specific lenses (dns-leak-freedom, busybox-portability, stub-fidelity-vs-real, live-router-reversibility).

## Cycle 1 — 21 raw → 18 confirmed (2 HIGH)

All HIGH/MEDIUM/LOW were dispositioned and fixed (the gate only required the 2 HIGH; the safety-critical "never break client internet" mandate justified sweeping the MEDIUM/LOW in the same pass). Verified-and-refuted findings only.

| # | Sev | Dimension | Finding | Fix commit |
|---|-----|-----------|---------|-----------|
| H1 | HIGH | spec-compliance | `disable → /etc/init.d/amnezia-dns stop → stop_service → amnezia-dns-ctl disable → …` self-recursion (fork/restart storm) on the **UI** disable path | `413add3` — `AMNEZIA_DNS_STOPPING` sentinel + watchdog stopped first |
| H2 | HIGH | tests-quality | Watchdog hysteresis/dwell (N=3/M=2/dwell=120s) had **zero effective coverage** — every test single-iteration with thresholds=1; mutation removing either guard left all tests green | `c3a9517` — `AMNEZIA_DNS_WD_TICKS` multi-tick tests (N-accumulation + dwell hold/elapse) |
| M1 | MED | security | `set-provider` leaks the previous provider's DoT `ip rule` (stale tunnel pin; accumulates) | `6008500` — clear prev provider's rule before switch |
| M2 | MED | security | custom DoT IP not validated as a literal — CIDR (`0.0.0.0/0`) slips into `ip rule to <X>` | `6008500` — bare-IPv4 validation |
| M3 | MED | concurrency | `cmd_disable` tears down dnsmasq **before** stopping the watchdog → probe race re-injects plaintext after restore | `413add3` — watchdog stop moved to top of `cmd_disable` |
| M4/M6 | MED | error-resources / concurrency | Dwell defeated on watchdog respawn (`_entered=0` never-observed-sentinel) → 120s dwell skipped | `87fe7b3` — persist `dns_plain_ts` in UCI; seed legacy |
| M5 | MED | error-resources | `uci commit dhcp` ran **before** the `dnsmasq --test` gate → a rejected render is persisted → DNS outage on the next restart/reboot | `0a76227` — commit only after `--test` passes; `uci revert` on failure |
| M7 | MED | interface-contract | LuCI `custom` provider was a guaranteed-fail dead-end (no inputs rendered; backend rejects empty custom fields) | `f54c0f1` — `custom` removed from dropdown (backend still supports it via direct UCI; dedicated UI deferred) |
| M8 | MED | interface-contract | DoT controls lacked the `document.activeElement` focus-guard the rest of the panel uses → 5s poll clobbers in-progress selection | `f54c0f1` — focus guard added |
| L1/L4 | LOW | spec / interface | `status` probe not bounded to design's ≤1s (`nslookup -timeout=3`, up to 2 probes) | `3679f6d` — `_PROBE_TIMEOUT=1` for status |
| L2 | LOW | correctness | (= M4) dwell bypass on inherited plaintext | `87fe7b3` |
| L3 | LOW | security | `disable` skips ip-rule cleanup when the (custom) profile no longer validates | `413add3` — unconditional `dns_iprule_flush` |
| L5 | LOW | interface-contract | `status` reports `encrypted:true`/`active_tier:dot` while the feature is **disabled** | `3679f6d` — short-circuit when `dot_enabled!=1` |
| L6 | LOW | tests-quality | Test title "enable verifies the encrypted listeners" asserted apply-wiring, not the verify probe | `3679f6d` — retitled honestly |
| L7 | LOW | tests-quality | Missing-binary fallback test didn't assert the plaintext provider server is added | `3679f6d` — fixture + assertion |
| L8 | LOW | regression-parity | `dns_dnsmasq_restore` unconditionally strips `noresolv`/`strictorder` even when DoT was never enabled | `413add3` — gate restore on `_was_enabled` |

### Regression caught during the fix pass (self-review, not a reviewer finding)
The L3 fix added a broad `"rule del pref "*) exit 1` arm to the **shared** `test/stubs/ip`, which also matched routing's `rule del pref 31000/31001` and broke `routing_remove_rules` tests #225/#227 (suite was 0-failures throughout before that). Resolved in `17a5796` — `dns_iprule_flush` made self-bounded (capped loop) and the shared `ip` stub reverted to pristine (byte-identical to `b7ed56a`).

**Post-fix state:** `bats test/unit/` = 290 green; shellcheck phases B+E pass; `openwrt/ ↔ packages/` sync parity proven (fresh `dev/sync-to-packages.sh` leaves the tree clean).

## Cycle 2 — 13 raw → 10 confirmed (1 HIGH)

Surface `a198a37..cb98713`. The HIGH was a genuine gap (not a fix-regression):

| # | Sev | Finding | Fix commit |
|---|-----|---------|-----------|
| H | HIGH | `cmd_enable` never started the procd watchdog — after a UI/CLI enable the failover daemon stayed dead until reboot (feature ships OFF, so first activation is always a runtime enable, never a boot `start`). If both encrypted tiers then died, nothing gated in plaintext → outage. | `d92b568` — `enable` calls `$AMNEZIA_DNS_INIT start` after apply+verify (`start`, not `restart`, to avoid `stop_service` teardown) |
| M | MED | Failed provider-switch revert leaked the *failed* provider's DoT ip rule (M1 covered only the success path) | `c413923` — `cmd_apply` flushes pref-30900 before `dns_iprule_set` |
| L×8 | LOW | disabled-status `active_tier:dot`; `_enter_plain` marked plaintext even on reload-revert; H1 sentinel only half-covered; + 5 test-precision/coverage nits | `6b57e3e` (status→off, reload-gated `_enter_plain`, sentinel test); rest deferred/logged |

## Cycle 3 — 11 raw → 7 confirmed (2 HIGH)

Surface `a198a37..888fd6e`. Two HIGH (one a partial regression of the cycle-2 `_enter_plain` change):

| # | Sev | Finding | Fix commit |
|---|-----|---------|-----------|
| H | HIGH | **apply reorders plaintext ahead of encrypted** — `dns_dnsmasq_encrypted`'s `del_list`+`add_list` moves the loopback listeners to the UCI tail; if the watchdog had appended plaintext WAN servers, `strict-order` then sends every query cleartext-first. Fires via the firewall hotplug (`fw4 reload` co-occurs with awg flaps). | `c89df7b` — apply does `del_plain` then conditional `add_plain` so encrypted is always first, plaintext strictly behind as last-resort |
| H | HIGH | **watchdog latches `_tier=plaintext` ignoring `_enter_plain`'s failure return** (caller bug exposed by the cycle-2 `return 1`) → never retries → DNS hard-down with no in-process recovery | `cea2c41` — `if _enter_plain; then _tier=plaintext; _entered=$(_now); fi` |
| M | MED | M-side exit hysteresis (`_ok ≥ _m`) was untested (all exit tests used `WD_M=1`) — mutation-proven false-green | `fbb824d` — `WD_M=2` accumulation tests |
| M×3 / L | — | see **Deferred** below | logged |

### Deferred (logged here, not fixed in the unit suite — live-gate or out-of-scope)
These confirmed findings were dispositioned `[defer]` with rationale; none gate (all MEDIUM/LOW, narrow triggers):
- **force-load ⇄ watchdog interleave test** (design Testing #9): a true concurrency test needs a *stateful* `uci` stub that models list state; the current stateless stub can't persist edits. The fd-8 lock discipline itself was independently verified sound by the reviewers (every fd-8 holder commits-or-reverts its `dhcp` staging before releasing). → **live-only gate** during bring-up (two backgrounded writers under `flock`).
- **add_plain/del_plain matched-pair across a mid-window `resolv.conf.auto` change**: both derive IPs from a live re-read, so if the WAN provider's nameservers change *during* a ≥120s plaintext window, `del_plain` can strand the originally-added IP. A snapshot approach has its own reboot edge (tmpfs `/var/run` cleared while the committed dhcp server persists). Trigger is rare (the design itself calls the plaintext window "genuinely rare"). → tracked as a known limitation + live observation.
- **empty-candidate uci-stub fidelity**: in the integrated apply/enable/watchdog tests the stateless `uci` stub returns nothing on read-back, so `dnsmasq --test` validates an empty candidate. The gate's pass/block/revert logic and the rendered-line *format* are covered in isolation (`dns-lock.bats` + the `add_list` literal assertions); the residual gap needs a stateful stub. → defer (non-mechanical stub work).

## Cycle 4 — 5 raw → 5 confirmed (1 HIGH)

Surface `a198a37..5d08e95`. The HIGH + two MEDIUMs shared one root cause (tier flag committed outside the fd-8 lock):

| # | Sev | Finding | Fix commit |
|---|-----|---------|-----------|
| H | HIGH | **`_enter_plain` commits `dns_active_tier=plaintext` OUTSIDE the fd-8 lock**, but `cmd_apply`'s plaintext-gate reads it INSIDE its lock. The firewall hotplug backgrounds `apply &` (separate process from the watchdog), so a cross-process interleave can land UCI=plaintext while dnsmasq has no plaintext server, both encrypted tiers down → DNS hard-down + lying state. | `0e076a1` — tier/`dns_plain_ts` committed inside the lock on reload success |
| M | MED | Symmetric `_exit_plain` race → stale plaintext server left behind encrypted listeners (leak, not outage) | `0e076a1` — `_exit_plain <tier>` sets tier inside the lock |
| M | MED | No-binary `cmd_apply` branch latches `tier=plaintext` before the reload (`\|\| true` swallows a `--test` failure) → tier/config divergence | `0e076a1` — tier set only after reload success |
| M | MED | Cycle-3 encrypted-first ordering test was a **false-green** (passed under a plaintext-first mutation; production code was correct, the test just didn't pin it) | `42beb6d` — assert encrypted `add_list` line precedes plaintext `add_list`; mutation-verified |
| L | LOW | interface-contract nit (non-gating) | deferred/logged |

The atomicity fix (tier commits inside the fd-8 critical section, paired with the server-list mutation) addresses the root of the plaintext/tier/lock race class; structural source-grep guards added so a regression moving the commit back outside the lock is caught.

## Cycle 5 — 5 raw → 2 confirmed (2 HIGH)

Surface `a198a37..5b711f5`. Both HIGHs were *completions* of the cycle-4 atomicity fix, not new classes:

| # | Sev | Finding | Fix commit |
|---|-----|---------|-----------|
| H | HIGH | **`_exit_plain` was the asymmetric mirror** — it committed the encrypted tier *unconditionally* after `dns_dnsmasq_reload \|\| true`. On a reload `--test` failure (which `uci revert`s the `del_plain`, leaving plaintext live) the tier was still flipped to dot/doh → torn state in the *exit* direction (status says encrypted, dnsmasq still serves plaintext = leak + lying status). | `4f6b872` — gate `_set_tier` on reload success, mirror of `_enter_plain`; watchdog leaves `_tier=plaintext` on failure to retry |
| H | HIGH | **The cycle-4 structural regression guard was itself a false-green** — its `awk NR > set_line` matched the *failure-branch* `dnsmasq_unlock`, so moving the tier commit outside the lock still passed. | `3876fb1` — rewrote both guards to extract the function body and assert `_set_tier` precedes the FIRST `dnsmasq_unlock`; **mutation-verified** both go red under the regression |

The atomicity invariant (tier committed inside the fd-8 lock, on reload success, atomic with the server-list mutation) is now complete in **both** enter and exit directions, with regression guards that actually bite.

## Cycle 6 — 2 raw → 1 confirmed, **0 CRITICAL/HIGH** → CONVERGED ✅

Surface `a198a37..04703fe`. The C/H gate is satisfied. One MEDIUM remained (swept in final-clean):

| # | Sev | Finding | Disposition |
|---|-----|---------|-------------|
| M | MED | `cmd_disable` stops the watchdog via procd's *signal-only* `stop` (no join), and `cmd_watchdog` never re-reads `dot_enabled` in its loop → a late tick can resurrect `dns_active_tier=plaintext` + stray plaintext servers after disable (bounded: no outage, status stays honest, self-heals on next enable). | **Fixed** `9da94ab` (final-clean) — watchdog re-reads `dot_enabled` at the top of each tick and exits cleanly on disable |

## Convergence summary

| Cycle | Confirmed | C/H | Net |
|---|---|---|---|
| 1 | 18 | 2H | ↓ |
| 2 | 10 | 1H | ↓ |
| 3 | 7 | 2H | ↓ |
| 4 | 5 | 1H | ↓ |
| 5 | 2 | 2H | ↓ |
| 6 | 1 | **0 C/H** | **converged** |

Every confirmed HIGH was a genuine "never break client internet" or DNS-leak defect in the plaintext-fallback / tier / fd-8-lock concurrent state machine — none catchable by the unit suite (the stateless `uci`/`dnsmasq` stubs cannot model cross-process interleaving). The integrated adversarial deep-review was the mechanism that found them. Final state: **304 unit tests green**, shellcheck phases B+E clean, `openwrt ↔ packages` parity proven, 0 open C/H.

**Live-only gates remaining** (cannot be unit-tested; to run during user-gated bring-up): the three deferred items above, plus the design's leak test (`tcpdump` WAN :53 under a stalled tier-1), nftset tagging under DoT, failover interaction, and the per-profile resolver-IP pinning. See the design doc's "Out of scope for these phases" section.
