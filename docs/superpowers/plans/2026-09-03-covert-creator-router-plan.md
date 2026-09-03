# Covert-Transport Creator on Router (Phase 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the whitelist-bypass WebRTC "creator" as an opt-in, default-OFF OpenWrt procd service (`amnezia-covert`) with a LuCI toggle, a uid-scoped egress firewall restriction, and a manual join-link workflow — so the phone/Mac joiner works whenever the router is up.

**Architecture:** A cross-compiled static `linux/arm64` Go binary (`headless/vk` creator) runs under procd as a dedicated unprivileged user, launched by a POSIX-sh launcher (FIFO-piped into a log wrapper) that owns readiness, call-creation backoff, and teardown. A POSIX-sh CLI (`amnezia-covert-ctl`) reconciles UCI state, installs/removes a uid-scoped fw4 egress fragment (dnsleak precedent), and reports status JSON to LuCI. A new LuCI section module renders the toggle, cookie input (`fs.write`), and live status.

**Tech stack:** POSIX sh / BusyBox ash (all router wrappers), Go 1.26 (`GOOS=linux GOARCH=arm64 CGO_ENABLED=0`, the ONE compiled artifact), fw4/nftables, procd, LuCI (JS), bats + the offline `luci-harness.js`.

> **Code-in-plan convention (project rule, overrides writing-plans' "complete code in every step").** This repo's CLAUDE.md forbids hand-written runnable code in a plan/spec — it never executes, so mechanics the language would catch survive review. So each task below gives the **CONTRACT** (file paths, signatures, semantics), the **ASSERTION TABLE** (exact test names + what each asserts + the mutation that must turn it red), the **known traps**, and the **verification command**. The executor writes the sh/JS/nft bodies **test-first in a real shell** and runs every gate for real. The nft rule text, function signatures, and JSON schema below are contract (copy exactly); everything else is written and executed by the implementer. The authoritative source of truth for every semantic is the design doc: `docs/superpowers/specs/2026-09-03-covert-creator-router-design.md` — read it before starting.

---

## Global Constraints

Copied verbatim from the design; every task's requirements implicitly include these.

- **Never break client internet.** No touch to the nft classifier, ip rules, or dnsmasq for existing routing/DNS. The one new firewall object is the uid-scoped egress fragment, installed by `enable`, removed by `disable`, gated by `fw4 check` with rollback, reloaded backgrounded (`( sleep 1 && fw4 reload ) &`).
- **All router wrappers are POSIX sh / BusyBox ash** (v1.36.1 on the target). No bashisms. `pkill`/`pgrep -u`/`ps -o` are ABSENT — reap via the `/proc`-scan helper only.
- **Secrets never cross a command line, log, UCI dump, or commit.** The VK cookie and the join link (tunnel key material) are secrets. Cookie written only via LuCI `fs.write`. Redaction masks every `, response:` tail in the log wrapper.
- **Default OFF.** `amnezia.config.covert_enabled='0'`. A default-OFF feature never starts at boot and installs inert on `.ipk`/`install.sh`.
- **Fixed uid** for `amnezia-covert`, `id`-precheck idempotent + collision-loud. Process-written files `0640 amnezia-covert:amnezia-covert`; cookie file `0640 root:amnezia-covert`; flash dir `0750 root:amnezia-covert`.
- **UCI reads** with `uci -q get`, never `uci show | grep | sed`. No `uci set` before a preflight completes (shared `/tmp/.uci` staging).
- **Binary delivery is dev-deploy-only in P1** (`dev/deploy-openwrt-safe.sh` staging + installer placement). `.ipk`/`install.sh` install inert.
- **`openwrt/ ↔ packages/` stay in sync** (CI checks it); every new file ships through the four delivery surfaces per its kind.
- **Pinned upstream SHA** `89d7a474b7aca6cce664280e6feeaeca2706733b`. Line citations below are at this SHA.
- **Fixed paths** (constants): binary `/usr/bin/amnezia-covert-creator`; cookie `/etc/amnezia/covert/vk-cookies.json`; flash log `/etc/amnezia/covert/covert.log`; manifest `/etc/amnezia/covert/BUILD_MANIFEST`; runtime dir `/var/run/amnezia-covert/` holding `state.json`, `last-call.ts`, the `-write-file` link target, and `covert.fifo`.

---

## File Structure

Source of truth is `openwrt/`; `dev/sync-to-packages.sh` mirrors into `packages/`. Repo conventions confirmed against siblings: CLI `openwrt/amnezia-<n>-ctl.sh`, init `openwrt/amnezia-<n>.init`, lib `openwrt/lib/amnezia-common.sh`, nft templates `openwrt/nftables.d/`, LuCI sections `openwrt/luci-app-amnezia/amnezia/section/`.

**Create:**
- `dev/build-covert-creator.sh` — cross-compile → `build/covert/dist/{amnezia-covert-creator,BUILD_MANIFEST}` (gitignored).
- `openwrt/nftables.d/40-amnezia-covert-egress.nft` — the egress template (with `@@COVERT_UID@@` / `@@LAN_IFNAME@@`). Installs to `/usr/share/amnezia/nftables.d/`.
- `openwrt/amnezia-covert-ctl.sh` → `/usr/bin/amnezia-covert-ctl` — CLI (`enable|disable|apply|status`).
- `openwrt/amnezia-covert-run.sh` → `/usr/lib/amnezia/amnezia-covert-run.sh` — launcher.
- `openwrt/amnezia-covert-logwrap.sh` → `/usr/lib/amnezia/amnezia-covert-logwrap.sh` — log wrapper.
- `openwrt/amnezia-covert.init` → `/etc/init.d/amnezia-covert` — procd init (START=99).
- `openwrt/luci-app-amnezia/amnezia/section/covert.js` — LuCI section module.
- bats: `test/unit/covert-ctl.bats`, `test/unit/covert-launcher.bats`, `test/unit/covert-logwrap.bats`, `test/unit/covert-egress-nft.bats`, `test/unit/covert-reap.bats`.
- stubs: `test/stubs/amnezia-covert-init` (CLI→init, Phase 6), `test/stubs/adduser` + `test/stubs/addgroup` (installer, CI-portable, Phase 9). Phase 5 uses an inline PATH-shadowed logwrap stub.

**Modify:**
- `.gitignore` — add `build/`.
- `openwrt/lib/amnezia-common.sh` — add `amz_covert_enabled`, `amz_covert_reap`, `amz_covert_uid` (+ path constants).
- `openwrt/config/amnezia` — add `option covert_enabled '0'` to `config amnezia 'config'`.
- `openwrt/luci-app-amnezia/amnezia/util.js` — add `covertStateColor()`.
- `openwrt/luci-app-amnezia/view/main.js` — require + `Object.assign` + `refresh()` + `main.load()` index 14 + master-strip untouched.
- `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json` — add `exec` + `write` grants.
- `openwrt/install-amnezia-pbr.sh` — create user/group (fixed uid, BusyBox `adduser`/`addgroup`), dir, pre-create `covert.log`, place binary+manifest, verify sha256, remove staged copy; add the reverse-order `uninstall` path.
- `dev/deploy-openwrt-safe.sh` — stage binary + manifest to `/tmp` (explicit entries).
- `dev/sync-to-packages.sh` — add **explicit `cp` entries** (this script uses hand-maintained lists, not globs): CLI, launcher+wrapper (into `/usr/lib/amnezia/`), init, and the nft template into `/usr/share/amnezia/nftables.d/` **only** (never `/etc/nftables.d/`). LuCI `covert.js` ships automatically.
- `test/lib/luci-harness.js` — wire the `covert` module: module-load sites + the two handler-coverage sites (`WIRING` map + `buildView` `Object.assign`), see Phase 8.
- `test/unit/shellcheck-phaseF.bats` — register `amnezia-covert-{ctl,run,logwrap}.sh` + `amnezia-covert.init` (explicit file list, `-s sh`).

---

## Waves

- **Wave A** (no shared input): Phase 1 (build), Phase 2 (common helpers + UCI), Phase 3 (nft template).
- **Wave B** (consume Wave A contracts): Phase 4 (logwrap), Phase 5 (launcher), Phase 6 (CLI).
- **Wave C** (consume Wave B): Phase 7 (init), Phase 8 (LuCI + harness), Phase 9 (installer + delivery).

**Same-wave dependencies are stub-satisfied in unit tests** (real integration is the live gate) — the parallelism is real only because each phase's bats shadow its same/later-wave collaborators on `PATH`, mirroring the repo's existing `test/stubs/amnezia-{dnsleak,failover}-init` convention:
- **Phase 5 (launcher) stubs Phase 4's logwrap:** the launcher's readiness test execs a sibling that writes `state.json`. Phase 5's bats provide a **minimal PATH-shadowed `amnezia-covert-logwrap.sh` stub** (writes a scripted `state.json` sequence) — it never requires Phase 4's real artifact. (H2, sonnet-lens.)
- **Phase 6 (CLI) stubs Phase 7's init:** `enable`/`disable`/`apply` drive `/etc/init.d/amnezia-covert`. Phase 6's bats add a new **`test/stubs/amnezia-covert-init`** (mirroring `test/stubs/amnezia-dnsleak-init`) so the CLI tests never need the real init. (L8, sonnet-lens.)
- **Phase 9 is the one Wave-C step that is NOT independently completable and MUST run after Phase 7:** its `dev/sync-to-packages.sh` gate issues an unconditional `cp` for `openwrt/amnezia-covert.init` (Phase 7's artifact) under `set -eu` — a missing source aborts the whole script. Sequence Phase 9 last in Wave C. (H3, sonnet-lens.)

Commit between waves; git is the handoff. Each phase ends with its bats green — run a single new file with `bats test/unit/<file>.bats` (the hardware-free entrypoint used by `dev/test-integration.sh`; CI runs `sudo bats test/integration test/unit`). There is no `test/run.sh`. (M7, sonnet-lens.)

---

## Phase 1 — Build script + gitignore

**Files:** Create `dev/build-covert-creator.sh`; Modify `.gitignore`.

**Interfaces — Produces:** `build/covert/dist/amnezia-covert-creator` (static ARM aarch64 ELF, ~11 MB) and `build/covert/dist/BUILD_MANIFEST` (`upstream_sha=…`, `go_version=…`, `artifact_sha256=…`).

**Contract:**
- Clones/updates the upstream sparse checkout including **both** `relay/` and `headless/vk` (go.mod:11 `replace whitelist-bypass/relay => ../../relay`), asserts `git rev-parse HEAD` == the pinned SHA.
- Builds `headless/vk` with **`GOOS=linux GOARCH=arm64 CGO_ENABLED=0`** (absence → a darwin Mach-O; the ELF assertion must fail loudly). Read upstream `build-headless.sh` for the invocation rather than reconstructing it.
- Asserts `file` reports **static ARM aarch64 ELF**.
- Checksums with **`shasum -a 256`** (macOS has no `sha256sum`; `set -eu` would abort).
- Emits `BUILD_MANIFEST` next to the binary.

**Known traps:** runs on the dev **Mac** (shasum, not sha256sum); the local upstream clone is already full so a missing `relay/` in the sparse spec won't surface here — assert the checkout explicitly.

**Assertion table** (`test/unit/` not applicable — this is a dev-host script; gate is a real run):

| check | asserts | how it fails |
|---|---|---|
| build produces an ELF | `file …/amnezia-covert-creator` matches `ELF.*aarch64` | omit `GOOS/GOARCH` → Mach-O → assertion red |
| manifest present | all three fields (`upstream_sha`/`go_version`/`artifact_sha256`) non-empty | blank any manifest field before the non-empty check → red |
| pinned SHA | `git rev-parse HEAD` == pin | check out a different upstream ref → SHA mismatch → red (script aborts before build) |

**Steps:**
- [ ] **1.** Add `build/` to `.gitignore`; `git status` shows `build/` untracked-ignored.
- [ ] **2.** Write `dev/build-covert-creator.sh` to the contract; `set -eu`.
- [ ] **3.** Run it for real on the Mac; confirm the ELF + manifest via `file` and `shasum -a 256`.
- [ ] **4.** Commit `feat(covert): cross-compile build script for the headless VK creator`.

---

## Phase 2 — common.sh helpers + UCI option

**Files:** Modify `openwrt/lib/amnezia-common.sh`; Modify `openwrt/config/amnezia`; Create `test/unit/covert-reap.bats`.

**Interfaces — Produces** (sourced by launcher, CLI, init):
- `amz_covert_uid` → prints the numeric uid of `amnezia-covert` (`id -u amnezia-covert`), or empty + rc≠0 if the user is missing.
- `amz_covert_enabled` → rc 0 iff `uci -q get amnezia.config.covert_enabled` == `1`.
- `amz_covert_reap <signal>` → `/proc`-scan: for each `/proc/<pid>/status`, if the `Uid:` line's **real-uid column** (`$2` under awk default split — `$1` is the `Uid:` label) equals `amz_covert_uid`, `kill -<signal>` it (default TERM); `2>/dev/null` absorbs pid-vanish races. Reads `/proc` as root (callers are root).

**Contract:** UCI option `option covert_enabled '0'` added to `config amnezia 'config'`, placed next to the `dot_enabled '0'` sibling (~line 31) and matching its formatting. (The `config amnezia 'config'` section opens at line 10; the option goes beside `dot_enabled`, not at the section head. L4, opus-lens.)

**Known traps:** `pkill`/`pgrep -u`/`ps -o` are ABSENT on the target — the reap MUST be the `/proc`-scan (a stub providing `pkill` would pass green while the router can't reap: mirror the real absence in the test). `awk` at `/usr/bin/awk`.

**Assertion table** (`covert-reap.bats`):

| test | asserts | mutation → red |
|---|---|---|
| `reap_kills_matching_uid` | spawn a `sleep` under a stub uid, `amz_covert_reap TERM` (uid stubbed via a fake `/proc` fixture or a real subprocess whose uid matches a stubbed `amz_covert_uid`), process gone | reap keyed on `$1` (the label) instead of `$2` → no match → still alive → red |
| `reap_uses_proc_not_pkill` | with `pkill` absent from `PATH`, reap still works | implement via `pkill -u` → red on a pkill-less PATH |
| `reap_ignores_other_uids` | a process under a different uid survives the reap | reap ignores uid and kills all → red |
| `enabled_reads_uci_get` | `amz_covert_enabled` true only when the (quoted-format) uci stub returns `1` | parse via `uci show \| grep` → quoted `'1'` ≠ `1` → red |

**Steps:**
- [ ] **1.** Write `covert-reap.bats` (the 4 assertions above) against the real helper; run → fails (helper absent).
- [ ] **2.** Add the three helpers to `amnezia-common.sh` to the contract; add the UCI option.
- [ ] **3.** Run bats → green; run each mutation → confirm red; revert.
- [ ] **4.** Commit `feat(covert): common helpers (uid, enabled, /proc-scan reap) + UCI covert_enabled`.

---

## Phase 3 — nft egress template

**Files:** Create `openwrt/nftables.d/40-amnezia-covert-egress.nft`; Create `test/unit/covert-egress-nft.bats`.

**Contract — the template body is fixed (copy exactly), `@@…@@` substituted at `enable` time:**
```
chain amnezia_covert_egress {
    type filter hook output priority filter; policy accept;
    meta skuid @@COVERT_UID@@ oifname "lo" ip  daddr 127.0.0.1 udp dport 53 accept
    meta skuid @@COVERT_UID@@ oifname "lo" ip  daddr 127.0.0.1 tcp dport 53 accept
    meta skuid @@COVERT_UID@@ oifname "lo" ip6 daddr ::1       udp dport 53 accept
    meta skuid @@COVERT_UID@@ oifname "lo" ip6 daddr ::1       tcp dport 53 accept
    meta skuid @@COVERT_UID@@ ip  daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 } reject
    meta skuid @@COVERT_UID@@ ip6 daddr { fc00::/7, fe80::/10 } reject
    meta skuid @@COVERT_UID@@ oifname "lo" reject
    meta skuid @@COVERT_UID@@ oifname "@@LAN_IFNAME@@" reject
}
```
Loopback-DNS accepts precede all rejects; destination rejects (private/CGNAT/link-local/multicast) + `oifname` rejects together; `policy accept` permits public WAN egress on both stacks.

**Known traps:** it's an fw4 include (valid only inside `table inet fw4`); validate with **`fw4 check`**, never bare `nft -c -f`. A `@@…@@` left unsubstituted, or a `meta skuid <name>` (vs numeric), is a **parse error that takes down the whole ruleset** — the CLI substitutes a numeric uid + real ifname before load. The template is NEVER shipped into `/etc/nftables.d/` (only `enable` copies it there).

**Assertion table** (`covert-egress-nft.bats` — pure-substitution + shape checks; the real `fw4 check` is a live gate):

| test | asserts | mutation → red |
|---|---|---|
| `substitution_leaves_no_placeholder` | after uid+ifname substitution, no `@@` remains | leave `@@LAN_IFNAME@@` → red |
| `dns_accepts_precede_rejects` | the four `dport 53 … accept` lines appear before any `reject` | reorder a reject above the accepts → red |
| `both_reject_families_present` | the address-set rejects AND the two `oifname` rejects are all present | drop the `ip daddr {…} reject` → red (belt-and-braces regression guard) |
| `numeric_uid_only` | the substituted `meta skuid` operand is all-digits | substitute a name → red |

**Steps:**
- [ ] **1.** Write `covert-egress-nft.bats`; run → fails (template absent).
- [ ] **2.** Create the template exactly as the contract.
- [ ] **3.** bats green; mutations red; revert. (Live `fw4 check` deferred to the Phase-6/live gate.)
- [ ] **4.** Commit `feat(covert): uid-scoped fw4 egress template (belt-and-braces oif+dest rejects)`.

---

## Phase 4 — Log wrapper

**Files:** Create `openwrt/amnezia-covert-logwrap.sh`; Create `test/unit/covert-logwrap.bats`.

**Interfaces — Consumes:** creator stdout+stderr on stdin (via the launcher's FIFO). **Produces:** appends to `/etc/amnezia/covert/covert.log` (pre-created 0640 by the installer — append only, never create); atomically rewrites `/var/run/amnezia-covert/state.json` (tmp + `mv`, same dir).

**Contract — state markers (source at pinned SHA):**

| marker | main.go | → state |
|---|---|---|
| `  CALL CREATED` | :553 | `starting`→has-call |
| `  join_link: ` | :554 | parse link (key material) |
| `[vk-ws] Connected` | :583 | `connected` |
| `Failed to create call:` / `Failed to join existing call:` / `[rejoin] Failed:` | :704 / :699 / :606 | `auth-failed` |
| `Cannot read cookies:` / `Cannot parse cookies:` | http.go:17 / :24 | `auth-failed` |

**Contract — redaction (generic, hard requirement):** classify state off the surfacing prefix FIRST, then on any line containing `, response:` keep everything up to and including `response:` and replace the tail with `***`. This covers all NINE body-dump sites (`main.go:264/286/289` + `authAndJoin` `:133/145/156/159/180/197`), incl. the rejoin path. Never drop the whole line (loses the state signal).

**Contract — cap (file-write only):** `tail -n 2000 covert.log > /var/run/amnezia-covert/logcap && cat /var/run/amnezia-covert/logcap > covert.log` (the `>` truncates the owned file; preserves inode/owner/mode). The blackbox `>$LOG.tmp && mv` pattern is **forbidden** (needs dir-write the unprivileged wrapper lacks in the 0750 dir). Cap runs periodically, not per-line. State rewrite ≤ once/sec. Logwrap **refuses to downgrade** a terminal `not-started`/`crashed` state.

**Assertion table** (`covert-logwrap.bats`):

| test | asserts | mutation → red |
|---|---|---|
| `states_from_markers` | fed a captured marker stream, state.json transitions idle→starting→connected | swap a marker mapping → red |
| `redacts_generic_response_tail` | fed a `Failed to create call: … empty VK token, response: <token>` AND a `[rejoin] Failed: … empty session_key, response: <sk>` line, neither token nor session_key appears in covert.log | remove the redaction → red; narrow to 3 fixed shapes → the session_key rejoin line leaks → red |
| `redaction_keeps_state_prefix` | after masking, `auth-failed` is still classified from the kept prefix | drop the whole line → red |
| `cap_is_truncate_in_place` | capping a large covert.log inside a `0750 root:amnezia-covert` dir, running as `amnezia-covert`, succeeds and trims | use blackbox `>$LOG.tmp && mv` → EACCES on the dir → red |
| `no_terminal_downgrade` | after `not-started`, a buffered `CALL CREATED` does not flip state back to `starting` | remove the terminal-state guard → red |

**Known traps:** the wrapper runs as `amnezia-covert`; it can only APPEND to covert.log (installer pre-creates it) and WRITE within `/var/run/amnezia-covert/`. `-debug` off does NOT suppress the unconditional `[vk-ws]` dumps (peer-IP metadata; accepted trusted-LAN residual) — do not rely on it for cap sizing.

**Steps:**
- [ ] **1.** Write `covert-logwrap.bats` (5 assertions); run → fails.
- [ ] **2.** Write the wrapper to contract.
- [ ] **3.** bats green; each mutation red; revert.
- [ ] **4.** Register the wrapper in `test/unit/shellcheck-phaseF.bats` (`-s sh`). (M2, opus-lens.)
- [ ] **5.** Commit `feat(covert): log wrapper — generic redaction, truncate-in-place cap, state.json`.

---

## Phase 5 — Launcher

**Files:** Create `openwrt/amnezia-covert-run.sh`; Create `test/unit/covert-launcher.bats`.

**Interfaces — Consumes:** `amnezia-common.sh` helpers; the logwrap path; the creator binary path. **Produces:** the running creator (PID captured), a live readiness monitor writing `state.json`.

**Testing note (H2, sonnet-lens):** the launcher's bats provide a **minimal PATH-shadowed `amnezia-covert-logwrap.sh` stub** that writes a scripted `state.json` sequence — Phase 5 never requires Phase 4's real artifact, keeping Wave B truly parallel (mirrors the `test/stubs/amnezia-*-init` convention).

**Contract — ordered steps (design "Run wrapper" section):**
0. `amz_covert_enabled || exit 0` — first act (procd re-execs the instance on respawn, bypassing `start_service`'s guard; a disable-race respawn must not mint a call).
0.5. **uid-match fail-closed (design §New CLI "the boot start path ... fail-closed", lines 400/1035; C1, sonnet-lens).** Re-resolve `amz_covert_uid`; read the numeric `meta skuid` operand from the active fragment `/etc/nftables.d/40-amnezia-covert-egress.nft`. On mismatch OR unresolvable uid OR missing fragment, write `state.json`=`not-started` (reason `uid-mismatch`) and `exit 1` — **never launch the creator**. This is the respawn-safe checkpoint: procd re-execs the launcher (not `start_service`), so after a `--migrate` reallocates the uid, only a check *here* prevents the creator running under a new uid while the persisted fragment still restricts the old one — which would silently void the entire egress control. (`start_service` also reconciles via `apply` at cold boot — Phase 7 — but respawn bypasses it; the fragment is world-readable, the launcher runs as `amnezia-covert` and can read it.)
1. Truncate `state.json` + link file. Do **not** truncate `last-call.ts`.
2. Call-creation gap: read `last-call.ts`; sleep the remainder of 120 s; stamp `last-call.ts` just before launch.
3. Launch via FIFO (both PIDs captured), `$PIPE=/var/run/amnezia-covert/covert.fifo`:
   `mkfifo "$PIPE" 2>/dev/null || :` ; `logwrap < "$PIPE" & LW=$!` ; `creator -resources moderate -cookies … -write-file … > "$PIPE" 2>&1 & CR=$!` ; `trap 'kill "$CR" "$LW" 2>/dev/null' TERM INT EXIT`. `-resources moderate` is **mandatory** (default is 128 MB; moderate = 64 MB, main.go:642).
4. Readiness monitor concurrent: poll `state.json` for `starting`→`connected`. On success `wait "$CR"`. On timeout: kill `$CR`, then `$LW`, confirm both dead, THEN write `not-started`; exit → procd respawns.

**Known traps:** a plain `creator | logwrap &` is unusable (`$!` = logwrap; BusyBox ash has no job control → no pipeline group to kill; SIGTERM orphans the creator → unrestricted relay). The FIFO must live in the writable `/var/run` dir, not the 0750 flash dir. `procd_set_param respawn 300 120 5` (field 2 = 120 s delay).

**Assertion table** (`covert-launcher.bats`, using a fake creator script):

| test | asserts | mutation → red |
|---|---|---|
| `disabled_respawn_exits` | with `covert_enabled=0`, running the launcher exits 0 without launching | remove the `amz_covert_enabled \|\| exit 0` → red |
| `launcher_uid_mismatch_fail_closed` | active fragment's `skuid` ≠ current `amz_covert_uid` → launcher writes `not-started`/`uid-mismatch` and exits non-zero, fake creator NEVER exec'd | drop the step-0.5 check → creator launches under mismatched uid → red |
| `fifo_lives_in_var_run` | the `mkfifo` target is under `/var/run/amnezia-covert/`, not the 0750 flash dir | point `$PIPE` at `/etc/amnezia/covert/` → mkfifo EACCES as `amnezia-covert` → red |
| `readiness_connected` | fake creator emits `CALL CREATED`+`[vk-ws] Connected`, status reaches `connected` | order the readiness wait before the launch → times out → red |
| `readiness_timeout_not_started` | fake creator never emits → `not-started`, and NO fake-creator process survives | use `creator \| logwrap &` (so `$!`=logwrap) → surviving process → red |
| `sigterm_no_orphan` | SIGTERM the launcher → the `trap` kills the fake creator, none survives | remove the `trap` → red |
| `resources_flag_present` | the exec'd command line carries `-resources moderate` | drop the flag → red |
| `call_gap_uses_dedicated_ts` | a simulated respawn still waits the 120 s gap | point the timestamp at `state.json` (truncated in step 1) → gap defeated → red |

**Steps:**
- [ ] **1.** Write `covert-launcher.bats` (8 assertions) with a fake creator + a PATH-shadowed stub logwrap; run → fails.
- [ ] **2.** Write the launcher to contract (incl. the step-0.5 uid-match fail-closed guard).
- [ ] **3.** bats green; mutations red; revert.
- [ ] **4.** Register the launcher in `test/unit/shellcheck-phaseF.bats` (`-s sh`). (M2, opus-lens.)
- [ ] **5.** Commit `feat(covert): procd launcher — FIFO PID capture, trap teardown, readiness monitor, call-gap, uid fail-closed`.

---

## Phase 6 — CLI `amnezia-covert-ctl`

**Files:** Create `openwrt/amnezia-covert-ctl.sh`; Create `test/unit/covert-ctl.bats`.

**Interfaces — Consumes:** common helpers, the nft template, the init. **Produces:** verbs `enable|disable|apply|status`; the `status` JSON schema consumed by LuCI.

**Contract — `status` JSON (exact schema):**
```json
{"enabled":true,"running":true,"state":"connected","link":"https://vk.com/call/join/XXXX","link_age_s":42,"reason":"","build_sha":"89d7a474","build_hash":"ab12cd34"}
```
`state` ∈ `idle|starting|connected|auth-failed|crashed|not-started|unknown`. `link`/`link_age_s` are JSON `null` (not `""`) when absent. `build_sha`/`build_hash` read from the installed `BUILD_MANIFEST` (never recomputed). Exit 0 whenever a JSON object is produced; non-zero only on a genuine CLI-internal failure. Full truth table in the design (§status).

**Contract — verbs (design §New CLI, exact ordering):**
- `enable`: preflight (binary present; user exists; cookie structural check; `MemAvailable` ≥ threshold) with **no `uci set` before it completes** → install fragment with numeric-uid + LAN-ifname substitution → `fw4 check` → on fail remove + abort non-zero, firewall untouched → `uci set covert_enabled='1'; uci commit` → init `enable` **then** `restart` → `( sleep 1 && fw4 reload ) &`.
- `disable`: stop + init-disable → `amz_covert_reap TERM`; wait; if scan non-empty `amz_covert_reap KILL`; re-verify empty → **then** remove fragment, backgrounded `fw4 reload`, remove state/link, `covert_enabled='0'`, commit. Idempotent. Cookie kept.
- `apply`: **idempotent reconcile — this is the verb `start_service` (Phase 7 boot init) calls.** Re-resolve the uid and **re-substitute + revalidate the fragment** (numeric uid + LAN ifname → `fw4 check`), fail-closed on mismatch/unresolvable (design §New CLI lines 400/651/1035) — this is what heals a `--migrate`-reallocated uid at cold boot. Reap only on the (re)start path (procd reports not-running), never a healthy running creator; on preflight fail leave `covert_enabled` untouched + `status` reports the reason. Missing binary → loud dev-deploy-only error.
- `status`: per the schema; reads state.json + `/etc/init.d/amnezia-covert running` bit.

Also: cookie structural validator (file exists, non-empty, JSON array, each element non-empty `name`+`value` — structural only, never dials VK); `apply` re-asserts `chown root:amnezia-covert` + `chmod 0640` on the cookie after any rpcd write (rpcd `fs.write` sets mode but leaves group `root` — without the re-chown the unprivileged process can't read the cookie → `LoadCookies` fatal → silent auth-failed respawn loop); uid-match **fail-closed** (abort/stop on running-uid ≠ fragment-uid).

**Assertion table** (`covert-ctl.bats` — uci stub in EXACT real quoted format, modelling `set` staged vs `commit`):

| test | asserts | mutation → red |
|---|---|---|
| `enable_no_cookie_refuses_no_set` | invalid/missing cookie → refuses, **no `uci set` at all** | stage a set before preflight → red |
| `enable_happy_order` | fragment written w/ numeric uid, `fw4 check` **before** any reload, init `enable` **then** `restart` | swap enable/restart → red |
| `enable_fw4check_fail_rolls_back` | `fw4 check` fails → fragment removed, no UCI mutation, non-zero, firewall untouched | skip the check → red |
| `disable_reaps_before_fragment` | reap (real `/proc`-scan, not stubbed pkill) confirms empty BEFORE fragment removal | remove fragment before reap → red; implement reap via `pkill -u` on a pkill-less PATH → red |
| `disable_idempotent` | disabling an already-disabled feature → exit 0, cookie kept | — |
| `cookie_validator` | rejects non-JSON/non-array/missing name·value; accepts real shape | accept-anything → red |
| `enable_low_mem_refuses` | `/proc/meminfo` stubbed below the `MemAvailable` threshold → `enable` refuses, no `uci set`, `status` reports the reason | remove the MemAvailable check → starts anyway → red (M3, opus-lens) |
| `apply_rechowns_cookie` | after a simulated rpcd `fs.write` leaves the cookie group `root`, `apply` runs `chown root:amnezia-covert`+`chmod 0640` on it | drop the re-chown → cookie stays group-root → red (M4, opus-lens) |
| `apply_resubstitutes_fragment_fail_closed` | with the active fragment carrying a stale uid, `apply` re-substitutes it to the current uid (or fail-closes if unresolvable) | make `apply` skip fragment re-substitution → stale-uid fragment survives → red (C1 boot-reconcile) |
| `status_truth_table` | per-state fixtures for all seven states incl. the three `(enabled=true,running=false)` states (`auth-failed`/`crashed`/`not-started`) discriminated by state-file+reason; `link` `null` not `""` | `running=false,enabled=true`→`idle` → red; AND collapse `crashed`→`not-started` (drop the reason discriminator) → red (M5, opus-lens) |
| `status_reads_manifest` | build_sha/hash from BUILD_MANIFEST, not recomputed | recompute (sha the binary) → red (assert no hashing of the 11 MB file) |
| `uid_mismatch_fail_closed` | running-uid ≠ fragment-uid → abort/stop, non-zero | downgrade to status-only warning → red |

**Known traps:** UCI values are quoted in `uci show` — use `uci -q get`. The **enable/disable UCI lifecycle** (staged set → preflight → commit) mirrors `amnezia-dnsleak-ctl.sh` (read it first). But the **template→active nft substitution** (read template, `sed` the `@@…@@`, write the active `.nft`, `fw4 check`) has NO dnsleak precedent — dnsleak installs UCI firewall *sections*, not substituted fragment files; the substitution/copy precedent is the **classifier** (`lib/amnezia-routing.sh` `sed s/@@LAN_IFNAME@@/…`, `amnezia-failover-ctl.sh` `mv … /etc/nftables.d/`). **`fw4 check` is new-to-repo** (`grep -rln "fw4 check" openwrt/` is empty) — no sibling to mirror; validate the assembled ruleset per the design's known-trap. `status` must never hash the binary. CLI tests stub the init via a new `test/stubs/amnezia-covert-init`. (L1/L8.)

**Steps:**
- [ ] **1.** Add `test/stubs/amnezia-covert-init` (mirror `test/stubs/amnezia-dnsleak-init`); write `covert-ctl.bats` (12 assertions), uci stub real-format; run → fails.
- [ ] **2.** Write the CLI to contract (dnsleak for the UCI lifecycle; classifier for the substitution/copy; `fw4 check` new).
- [ ] **3.** bats green; mutations red; revert.
- [ ] **4.** Register the CLI in `test/unit/shellcheck-phaseF.bats` (`-s sh`). (M2, opus-lens.)
- [ ] **5.** Commit `feat(covert): amnezia-covert-ctl (enable/disable/apply/status) with fail-closed reap+uid`.

---

## Phase 7 — procd init

**Files:** Create `openwrt/amnezia-covert.init`.

**Interfaces — Consumes:** launcher path, common helpers. **Produces:** the procd service `amnezia-covert`.

**Contract (design §procd init):** `USE_PROCD=1`, `START=99`, sources `amnezia-common.sh`. `start_service`: `amz_covert_enabled` guard (return if `0`); create `/var/run/amnezia-covert/` **owned by `amnezia-covert`** (`mkdir -p` + `chown amnezia-covert:amnezia-covert` — else `status` reads `unknown` forever, design §procd); **call `amnezia-covert-ctl apply`** (the idempotent reconcile: re-resolve uid, re-substitute+revalidate the fragment fail-closed — design line 651 "apply → used by boot init") and **on non-zero apply, do NOT open the instance** (fail-closed cold-boot half of C1); then open the instance with `command /usr/lib/amnezia/amnezia-covert-run.sh`, `user amnezia-covert`, `respawn 300 120 5`; **do NOT set `stdout`/`stderr`** (output must go to the wrapper, not logd). Respawn exhaustion leaves `covert_enabled='1'` and `status` reports `crashed`. (The launcher's own step-0.5 uid check is the respawn-path backstop, since procd re-execs the instance, not `start_service`.)

**Known traps:** init `enable` must precede `restart` (a bare `restart` on a not-yet-enabled procd service is a silent no-op — the stubby/https-dns-proxy bug). Setting `stdout`/`stderr` defeats the whole log-starvation mitigation. `apply` invoked from `start_service` must reconcile the fragment only — it must not itself `restart` the service from within `start_service` (procd opens the instance), avoiding a start recursion.

**Assertion table:** bats coverage of an init is thin; gate is a real `/etc/init.d/amnezia-covert running` bit on the live gate + static checks:

| test | asserts | mutation → red |
|---|---|---|
| `init_no_stdout_stderr` (grep the init file) | the init does NOT `procd_set_param stdout`/`stderr` | add `stdout 1` → red |
| `init_start_guarded` (grep) | `start_service` calls `amz_covert_enabled` and returns on false | remove the guard → red |
| `init_creates_runtime_dir_owned` (grep) | `start_service` `mkdir`s `/var/run/amnezia-covert/` and `chown`s it to `amnezia-covert` | drop the chown → red (M6, opus-lens) |
| `init_calls_apply_reconcile` (grep) | `start_service` calls `amnezia-covert-ctl apply` before opening the instance and bails on non-zero | remove the apply call → red (C1 boot-reconcile) |

**Steps:**
- [ ] **1.** Write the four static-grep assertions; run → fails.
- [ ] **2.** Write the init to contract (mirror `amnezia-dnsleak.init` / `amnezia-dns.init` structure).
- [ ] **3.** bats green; mutations red; revert.
- [ ] **4.** Register the init in `test/unit/shellcheck-phaseF.bats` (`-s sh`). (M2, opus-lens.)
- [ ] **5.** Commit `feat(covert): procd init (START=99, enabled-guard, apply-reconcile, no logd routing)`.

---

## Phase 8 — LuCI section + harness + ACL

**Files:** Create `openwrt/luci-app-amnezia/amnezia/section/covert.js`; Modify `openwrt/luci-app-amnezia/amnezia/util.js`, `openwrt/luci-app-amnezia/view/main.js`, `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json`, `test/lib/luci-harness.js`.

**Interfaces — Produces:** the covert section module (handler map + `render()` + `refresh()`), rendered **outside** `#amz-accordion` (master-off `pointer-events:none` must not disable it).

**Contract (design §LuCI):**
- `covert.js`: enable/disable toggle → `handleCovertToggle` (`ctlThenRefresh` shape); cookie `<textarea>` (write-only, never pre-filled) + "Save cookies" → `fs.write('/etc/amnezia/covert/vk-cookies.json', value, 0o640)` then a separate `handleCovertApply` → `amnezia-covert-ctl apply`; join-link row (copy affordance + `link_age_s`) shown only when `state==="connected"`; status color via a **new** `covertStateColor()` in util.js (NOT a new arm on shared `verdictColor`). Extra-arg handlers declared `function(extraArg, ev)` (createHandlerFn passes the event LAST).
- `main.js`: add `covert` to the require list + `Object.assign` handler map; fold `refresh()` into `Promise.all`; `main.load()` entry at **index 14**; all exec calls `L.resolveDefault`-wrapped. Render the covert block outside `#amz-accordion`.
- `util.js`: `covertStateColor(state)` → colour per state.
- ACL (`write.file` block): add `"/usr/bin/amnezia-covert-ctl":["exec"]` AND `"/etc/amnezia/covert/vk-cookies.json":["write"]`.
- **Harness (`luci-harness.js`) — module-load wiring (the "9 edits"), atomic `names`↔`fn(...)` pairing:** add `covert` to the `names` DI array (~L77); add `deps.covert` at the matching position in the positional `fn(baseclass, …, deps.dns, uciStub)` call (~L80 — grep-invisible); add `d.covert = load('amnezia/section/covert.js', d)` in the module-load block; add index 14 to the `DATA` fixture (~L72); plus the remaining grep-matched wiring sites. Re-derive line numbers at execute time.
- **Harness (`luci-harness.js`) — handler-coverage wiring (H1, opus-lens — TWO grep-invisible sites the module-load edits DON'T touch; without them the `handler-argorder`/`handlers_resolve` teeth never execute for covert and pass vacuously):**
  1. Merge `(dv.covert && dv.covert.handlers) || {}` into the `buildView` `Object.assign` (L221-225, alongside failover/routing/zapret/dns) — and into every parallel assembled/repaint env the harness builds (the `av` env at ~L271 and any `dr`/`dv2` sub-env that reuses `WIRING`).
  2. Add every covert handler to the `WIRING` map (L187-208) with its exact extra-arg signature: `handleCovertToggle: ['1']` (extra-arg toggle, `function(state, ev)`, like `handleMasterToggle`), `handleCovertApply: []` (no extra arg, reads `ev.target`). This is what drives `createHandlerFn` event-last through the covert handlers under both succeeding and rejecting fs stubs.

**Known traps:** `createHandlerFn` passes the event LAST — an extra-arg handler is `function(extraArg, ev)`. Render-time `getElementById` is `null` on the device — paint synchronously in the returned tree; use `getElementById` only in `refresh()`/handlers. Missing the `names`↔`fn(...)` pairing shifts every binding and blanks panels silently. LuCI static JS is browser-cached — the live smoke-test is in a private window.

**Assertion table** (`test/unit/luci-js.bats` via the harness):

| test | asserts | mutation → red |
|---|---|---|
| `harness_wires_covert` | full require graph loads, every module `render()` + `main.render()` runs, no module binds `undefined` | add `covert` to `names` but not the `fn(...)` call → a different module binds `undefined` → harness self-test red |
| `no_action_panel_open` (existing self-test) | no covert action panel carries `open` | — |
| `handlers_resolve` (existing self-test) | every named handler resolves (never rejects) under succeeding AND rejecting fs stubs; no event object leaks as a backend arg | wire a handler `function(ev, extraArg)` → event leaks to `fs.exec` → red |
| `covert_handlers_exercised` | `handleCovertToggle`/`handleCovertApply` are present in `WIRING` AND merged into the assembled view, so the arg-order/resolve teeth actually run for covert | add `covert` to module-load but NOT to `WIRING`+`Object.assign` → `handleCovertToggle` never invoked → the `function(ev, extraArg)` mutation stays green → red (H1, opus-lens) |
| `acl_has_exec_and_write` | ACL contains both grants | drop either → red |

**Steps:**
- [ ] **1.** Extend the harness — module-load sites AND the two handler-coverage sites (`WIRING` + `Object.assign`) — plus `luci-js.bats` assertions incl. `covert_handlers_exercised`; run → fails (module absent).
- [ ] **2.** Write `covert.js`, `covertStateColor()`, wire `main.js` (index 14), add ACL grants.
- [ ] **3.** bats + `luci-js.bats` green; mutations red (incl. the "WIRING-omitted → arg-order mutation stays green" check); revert.
- [ ] **4.** Commit `feat(covert): LuCI section (toggle, cookie fs.write, live status) + harness + ACL`.

---

## Phase 9 — Installer + delivery + sync

**Files:** Modify `openwrt/install-amnezia-pbr.sh`, `dev/deploy-openwrt-safe.sh`, `dev/sync-to-packages.sh`.

**Runs after Phase 7** (its `sync-to-packages.sh` gate `cp`s Phase 7's init under `set -eu`). 

**Contract (design §Installer):**
- **User/group creation — first user-creation code in this repo (`grep -rn "adduser\|useradd" openwrt/ packages/` is empty; genuinely new ground, H5 sonnet-lens).** Create `amnezia-covert` group+user with a **fixed uid/gid** (choose a value OpenWrt leaves free; document it) using **BusyBox applets** (NOT Debian `adduser` — the target is BusyBox ash): `addgroup -g <GID> amnezia-covert` then `adduser -D -H -s /bin/false -u <UID> -G amnezia-covert amnezia-covert` (`-D` no-password, `-H` no home, `-s /bin/false` no shell). Guard idempotent + collision-loud via an `id`-precheck FIRST: `id -u amnezia-covert` == fixed uid → skip; exists-with-different-uid, or the uid is held by another name (`awk -F: -v u=<UID> '$3==u{print $1}' /etc/passwd` returns a different name) → **fail loudly, create nothing**. CI runs on Ubuntu (Debian `adduser` — different flags), so the unit test MUST use a stub, not the host's real applet (see below); real BusyBox creation is proven only on the VM/live gate.
- Creates `/etc/amnezia/covert/` `0750 root:amnezia-covert`; **pre-creates `covert.log` `0640 amnezia-covert:amnezia-covert`** (the wrapper cannot create it in the 0750 dir). Places binary + `BUILD_MANIFEST`, verifies sha256 against the manifest, `chmod +x`, removes the staged `/tmp` copy. All user/dir/log creation **before** anything can load the nft fragment. On `.ipk`/`install.sh` the user + empty log are still created (harmless, inert); the binary is absent → `apply` fails loud.
- **Uninstall/rollback (design §Uninstall/rollback — a resolved requirement, H2 opus-lens).** Add an `uninstall` path (a function in the installer, or a dedicated `amnezia-covert-ctl uninstall` verb — pick the installer function, matching sibling teardown style) that reverses the install **in reverse order**: `amnezia-covert-ctl disable` (stop + reap + remove fragment + backgrounded `fw4 reload` + state/link + `covert_enabled='0'`) → remove `/etc/init.d/amnezia-covert` (after `disable`) → remove binary + manifest → remove `/etc/amnezia/covert/` (cookie included) → remove the ACL grants → `deluser amnezia-covert` + `delgroup amnezia-covert` (BusyBox applets) LAST. Each step idempotent (absent → skip, never error).
- `deploy-openwrt-safe.sh`: add **explicit** entries staging `build/covert/dist/amnezia-covert-creator` and `BUILD_MANIFEST` to `/tmp/`.
- `sync-to-packages.sh` (**hand-maintained explicit `cp` lists, NOT globs — L2 opus-lens; verified L44-52/L76-79/L109-113**): these four non-LuCI entries are ALWAYS required — the CLI `amnezia-covert-ctl`, the launcher `amnezia-covert-run.sh` + wrapper `amnezia-covert-logwrap.sh` (bespoke `cp` into `/usr/lib/amnezia/`, since their source is `openwrt/` root not `openwrt/lib/`), and the init `amnezia-covert.init`. **The nft template `40-amnezia-covert-egress.nft` is copied ONLY to `packages/.../usr/share/amnezia/nftables.d/`, NEVER to `/etc/nftables.d/` (H4 sonnet-lens).** The classifier block at `sync-to-packages.sh:89-101` dual-copies its `.nft` to BOTH dirs — do **not** mirror that pattern here: a copy into `/etc/nftables.d/` ships an active fragment with unsubstituted `@@COVERT_UID@@`/`@@LAN_IFNAME@@` → parse error that takes the whole firewall down on reload, and `sync_parity` (checks every source has *a* mirror) will NOT catch an *extra* wrong copy. The LuCI `covert.js` ships automatically (all four surfaces `cp -r` `amnezia/section/` — no edit needed). CI checks `openwrt/ ↔ packages/` parity.

**Known traps:** `install-amnezia-pbr.sh` is postinst-style (reads from `/tmp/<staged>`) — for the manually-cutover live router, apply the delta **surgically** (not a full installer re-run), snapshotting each replaced file, verifying WAN+DNS+handshake after each step. BusyBox `adduser`/`deluser` flags differ from Debian's — the invocation above is BusyBox-specific.

**Assertion table:**

| test | asserts | mutation → red |
|---|---|---|
| `first-install.bats` (extend, `adduser`/`addgroup`/`id` stubbed for CI portability) | install invokes `addgroup -g <GID>`+`adduser … -u <UID> …`, the `id`-precheck skips on correct-uid and fails loud on a uid collision; `/etc/amnezia/covert/covert.log` exists `0640 amnezia-covert:amnezia-covert` | drop the pre-create → red (first-start wrapper create would EACCES); drop the collision check → a taken uid silently reused → red |
| `uninstall_reverses` (new) | `uninstall` calls `disable` before removing the init, and `deluser` LAST (after files/dir/ACL gone) | reorder `deluser` before `disable` → red |
| `template_not_in_etc_nftables` (new, greps the synced `packages/` tree) | `40-amnezia-covert-egress.nft` exists under `packages/.../usr/share/amnezia/nftables.d/` and is ABSENT from `packages/.../etc/nftables.d/` | add an `/etc/nftables.d/` sync line for it → red |
| `sync_parity` (existing CI check) | every new `openwrt/` file has its `packages/` mirror | omit a file from sync → parity check red |

**Steps:**
- [ ] **1.** Add `test/stubs/adduser`, `test/stubs/addgroup` (mirror real BusyBox arg-echo behaviour); extend `first-install.bats` for the stubbed user creation + collision check + pre-created log; add `uninstall_reverses` + `template_not_in_etc_nftables`; run → fails.
- [ ] **2.** Implement the installer delta (BusyBox `adduser`/`addgroup`, id-precheck), the `uninstall` reverse path, deploy staging, and the explicit sync entries (template → `/usr/share` only).
- [ ] **3.** bats green; run `dev/sync-to-packages.sh` + the parity check green; mutations red; revert.
- [ ] **4.** **Real BusyBox gate:** run `dev/vm/test-all.sh` (QEMU OpenWrt) — the CI stubs prove wiring, not that BusyBox `adduser`/`deluser` accept these flags; user creation + uninstall must be proven on real OpenWrt (CLAUDE.md: "a green stubbed/VM run is not proof" — this is the class of installer risk the VM harness exists for).
- [ ] **5.** Commit `feat(covert): installer (fixed-uid user, pre-created log, binary placement, uninstall) + deploy staging + sync`.

---

## Live-router gates (after unit waves, user-gated, per CLAUDE.md live-router rules)

Not plan tasks — a checklist for the supervised first deploy (design §Testing "Live-only gates"). Take a full backup first (`dev/openwrt-backup.sh`); keep `dev/openwrt-emergency-internet.sh` ready; verify WAN+DNS after each step.

- [ ] `fw4 check` passes with the fragment on the real assembled ruleset; WAN+DNS+handshake survive `enable` and `disable`.
- [ ] `oif=lo` semantics confirmed: covert-uid can resolve DNS but the admin plane is **refused** on every router-own address (127.0.0.1, ::1, LAN IP, **WAN IP**, any GUA) on `:2323`/`:80`; a LAN host and a private/CGNAT target are refused; the SFU/public-WAN path is reachable (control-plane, both stacks).
- [ ] uid-match fail-closed under a deliberately mismatched uid.
- [ ] procd SIGTERM leaves no orphan; a SIGKILL orphan is reaped by `amz_covert_reap`.
- [ ] Joiner attaches to the router-created call and loads a page.
- [ ] `MemAvailable` under sustained joiner traffic (foreground-supervised); pin the preflight threshold.
- [ ] Multi-day watch: process-exit cadence + calls-created-per-day (slow-drip residual detector).
- [ ] Reboot with the feature enabled → comes back up unattended.
- [ ] LuCI smoke-test in a **private window** (static JS is browser-cached): toggle, cookie save, live status, join-link copy, all extra-arg buttons fire.

---

## Self-Review

- **Spec coverage:** every design section maps to a phase — build (1), UCI/helpers (2), egress rule (3), logwrap+redaction+cap (4), launcher+FIFO+gap+uid-fail-closed (5), CLI+status+reap+apply-reconcile (6), init+apply-boot-reconcile (7), LuCI+harness+ACL (8), installer+uninstall+delivery (9), live gates (checklist). The design's three-checkpoint uid promise (enable/apply/**boot+respawn**, fail-closed) is now covered at all three: `enable`+`apply` (Phase 6), `start_service`→`apply` cold boot (Phase 7), launcher step-0.5 respawn backstop (Phase 5). ✓
- **Type/name consistency:** `amz_covert_reap`/`amz_covert_enabled`/`amz_covert_uid` (Phase 2) are consumed by Phases 5/6/7; the `status` JSON schema (Phase 6) is consumed by the LuCI module (Phase 8); the state.json contract (Phase 4) is consumed by the launcher monitor (Phase 5) and CLI status (Phase 6). Paths are the fixed constants in Global Constraints. ✓
- **No unexecutable code bodies** beyond the fixed nft rule, the JSON schema, and helper signatures — per the project rule; the executor writes and runs the sh/JS test-first. ✓
- **Phase independence:** Wave A phases share no input; Wave B consume only Wave-A contracts; Wave C consume Wave-B artifacts. Same-wave collaborators (Phase 5→4 logwrap, Phase 6→7 init) are **stub-satisfied** in units per the Waves section; the one genuine ordering constraint (Phase 9 after Phase 7 for `sync-to-packages.sh`) is called out. ✓
- **Grep-invisible harness sites** (`WIRING` + `Object.assign`) are named explicitly so the arg-order teeth actually cover covert (H1). Uninstall/rollback is a real task with an assertion (H2). The nft template's `/usr/share`-only delivery is pinned against the classifier's dual-copy sibling (H4). ✓
