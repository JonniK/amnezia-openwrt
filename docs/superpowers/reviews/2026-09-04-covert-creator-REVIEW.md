# Covert-creator-router — Deep Review (Stage 8)

**Branch:** `feat/covert-creator-router`  **Base:** `fe1721d` → **Head:** `6463e6c`
**Date:** 2026-09-04

## Run note

The `deep-review-workflow.js` fan-out was **degraded by the `[cyber]` real-time
safeguard**: 9 of 10 dimension reviewers (security, correctness, spec-compliance,
interface-contract, concurrency, regression-parity, error-resources,
tests-quality, egress-enforcement) died mid-run with `[cyber]`. Their zero-counts
in the workflow's `byDimension` are **not** clean results — those reviewers never
executed. Only `secret-lifecycle` genuinely ran; both its findings below were
adversarially verified (independent verifier confirmed every link) and
re-verified by hand against the source.

Per user instruction, the flaky workflow is not re-run; the surviving finding is
fixed and coverage is completed with a **regular** `superpowers-reviewer` cycle.

---

## Confirmed findings

### H1 — `logcap` staging file leaks the join link into a world-readable file
**dimension:** secret-lifecycle · **severity:** HIGH · **file:** `openwrt/amnezia-covert-logwrap.sh:41`

`_cap_log()` writes the last 2000 lines of `covert.log` to `$RUN_DIR/logcap`
with a plain `>` redirect, no chmod, and never removes it. `covert.log` holds the
VK join link verbatim (the creator emits `  join_link: <link>`; `_redact` masks
only a `, response:` tail, so the join-link line is appended unredacted at
logwrap:226). The run dir `/var/run/amnezia-covert` is created **0755** (init:53-54
`mkdir -p`+`chown` with no `chmod`; run.sh:92 / logwrap:187 bare `mkdir -p`), so
`logcap` lands 0644 under the default umask inside a world-traversable dir → a
persistent world-readable file containing the secret join link. Violates the
"join link must never reach a world-readable file" invariant. The asymmetry is
the tell: `state.json` / `covert-link` (same secret, same dir) are deliberately
`chmod 0640`, `logcap` gets nothing.

Mirror: `packages/amnezia-pbr/files/usr/lib/amnezia/amnezia-covert-logwrap.sh:41`.

### M1 — world-traversable run dir + 0644 FIFO exposes the pre-redaction creator stream
**dimension:** secret-lifecycle · **severity:** MEDIUM · **file:** `openwrt/amnezia-covert-run.sh:160`

`mkfifo "$PIPE"` (covert.fifo) is created with no explicit mode → 0644 inside the
0755 run dir. The FIFO carries the creator's raw stdout+stderr **before** logwrap
redaction — the unmasked VK auth-response bodies (access_token/session_key) and
the join link. A local reader can siphon them ahead of/interleaved with logwrap.
Same root cause as H1: the run dir is never restricted to 0750.

Mirror: `packages/amnezia-pbr/files/usr/lib/amnezia/amnezia-covert-run.sh:160`.

## Fix (shared root cause) — DONE `6d7c6e6`

Restricted the run dir to **0750** at every creation site (init start_service, run.sh,
logwrap.sh) so "other" cannot traverse into it — this alone closes both findings.
Defense-in-depth: `chmod 0640 "$RUN_DIR/logcap"` in `_cap_log`, and `chmod 0600`
on the FIFO after `mkfifo`. Mirrored into `packages/`. 5 mutation-checked bats
assertions added; full suite 772 green.

---

## Regular final review cycle (replaces the degraded workflow) — 3 parallel opus reviewers over `fe1721d..6d7c6e6`

**Result: 0 CRITICAL, 0 HIGH across all three lenses.** The C/H gate is satisfied on
cycle 1. Positive verifications: egress model has no bypass (every locally-delivered
address → reject, only public-WAN → accept; uid always numeric-or-`fw4 check`-abort;
fail-closed at all 3 checkpoints; disable reaps before removing the fragment);
secrets never land world-readable or in logd; redaction covers all 9 upstream
`, response: %s` token-dump sites (verified against `headless/vk/main.go`); template
ships to `/usr/share` only; reap reads the right uid; openwrt↔packages byte-identical;
FIFO/PID/trap composition race-free; LuCI status-JSON contract + handler arg-order +
ACL grants all correct; default-OFF survives reboot; uninstall reverse-order with a
real JSON-validity test.

### Non-gating findings — disposition

**Fixed in the follow-up pass (this cycle):**
- **M `[autofix]`** `_cap_log` truncation regression (reviewer 2, reproduced: staging
  failure → live log truncated to 0) + **L `[autofix]`** logcap momentary-0644 window
  (reviewer 1). Combined: `( umask 0027; tail > logcap ) && chmod && cat` (cat only on
  tail success).
- **M `[defer]→fixed`** check-failed rollback leaves a `fw4`-rejected fragment when the
  snapshot restore is unavailable → bricks the next `fw4 reload` (whole firewall).
  Upgraded from defer because the blast radius is the project's #1 constraint; fix is
  mechanical (rm the rejected fragment on the check-failed path). (reviewer 1)
- **M `[defer]→fixed`** `connected→unknown` heartbeat-staleness downgrade untested — a
  mutation stayed green (reviewer 3). Added a truth-table case.

**Deferred (need design judgment / negligible; logged in scratchpad backlog):**
- **M `[defer]`** launcher overwrites a runtime `auth-failed` with `not-started` on the
  creator-died-before-connect path → cookie read/parse failures misreport in `status`
  as `not-started`/`readiness-timeout`. A mechanical fix reintroduces the drain window
  the design deliberately closed → real design decision. (reviewer 2; already in backlog)
- **M `[defer]`** `cmd_enable` never positively asserts the (backgrounded) `fw4 reload`
  actually loaded the covert chain — fail-open shape, but no exploitable window found
  (fresh enable has no joiner; re-enable covered by 120s gap; boot/respawn/any later
  reload heals via apply's synchronous reload). Suggested hardening: assert
  `nft list chain inet fw4 amnezia_covert_egress` present post-reload. (reviewer 1)
- **L `[defer]`** sub-ms orphan window between backgrounding the children and installing
  the traps; egress fragment still restricts the orphan → bounded. (reviewer 2)
- **L `[defer]`** harness arg-order teeth are blind to *toggle-style* handlers (extra arg
  compared, not forwarded); `handleCovertToggle` covered only by the static-signature
  grep. (reviewer 3)
- **L `[defer]`** failed `status` poll renders the panel `off/Enable` while enabled
  (pre-existing pattern across all sections; transient rpcd only). (reviewer 3)
- **L `[defer]`** `_is_fresh_log_line` theoretical under-suppression on a VK body line
  starting with a Go-log timestamp — VK-server-controlled, not attacker in the threat
  model. (reviewer 1)

**Informational (stated-and-accepted design caveats, not defects):** cookie textarea
POSTs over plain `:80` unless `luci-ssl` is installed; `covert.log` retains prior-session
join links in clear (0640, flash, for diagnosis; removed on `--uninstall`). Both accepted
for the single-admin trusted-LAN target.
