# Covert-Transport Creator on Router (Phase 1) — Design

**Date:** 2026-09-03
**Branch:** `feat/covert-creator-router`
**Status:** brainstormed, ready for spec self-review → user review → plan.

## Goal

Move the "creator" role of the whitelist-bypass covert transport (see
`docs/proposals/whitelist-bypass-covert-transport.md`, Phase 0 PASSED
2026-09-03 via VK) from the user's Mac onto the AX3000T router, as an
opt-in procd service with a LuCI toggle. Today the phone/Mac joiner only
gets free internet while the Mac is on and a browser tab is open running
the creator; after this phase the joiner works whenever the router is up.

**In scope (P1):**
- Cross-compiled native headless VK creator running as a router procd
  service, default OFF.
- LuCI toggle + cookie input + live status + current join-link display.
- Manual join-link workflow: the router creates a fresh VK call on
  start, prints the link, the user copies it into the phone/Mac joiner
  app by hand.

**Out of scope (later phases, already recorded in the proposal):**
- P2: routing the creator's own egress through the amnezia fwmark/tunnel
  plane (`--upstream-socks` seam) so the phone inherits RU-direct/tunnel
  policy.
- P3: automated join-link delivery (QR/push) and multi-SFU failover
  (Telemost is broken on upstream `main` as of Phase 0 — VK only for now).
- Anything to do with `master_enabled` interaction — this service does
  not participate in the tunnel/DNS plane at all in P1, so master on/off
  does not touch it. Revisit in P2.

## Background — two findings from exploration that changed the plan

1. **`relay/main.go --mode vk-video-creator` (what Phase 0 actually ran
   on the Mac) needs a browser tab** — it only opens a `/signaling`
   websocket; the real WebRTC negotiation happens in JS in a browser.
   Not portable to a headless OpenWrt box. Instead this design targets
   `headless/vk` — a **separate, fully native Go module** (own
   `go.mod`, no CGO, no browser) that already backs the project's
   Android/iOS headless *joiner* paths. Cross-compiled locally for
   `linux/arm64` (`CGO_ENABLED=0`): **11MB, static, stripped** — verified
   by an actual build, not assumed. Fits the router's 48.9MB free flash
   with room to spare.
2. **Even `-vk-link` (joining an existing call) requires a VK session
   cookie** — `headless-vk-creator` always authenticates as a real VK
   account (`-cookies <path>` / `-cookie-string`), whether creating a
   new call or joining one. There is no cookie-free mode. This is a
   real personal-account credential and is treated exactly like the
   project's existing private `.conf` tunnel keys: **never printed,
   grepped, logged, or committed.**
   - Silver lining: without `-vk-link`, the binary **creates a new call
     itself** and prints the join link (`-write-file <path>`). So P1's
     workflow is simpler than originally assumed — no "create the call
     from your phone first" step. Router starts → creates a call → LuCI
     shows the link → paste it into the joiner app.

## Constraints (carried from project CLAUDE.md + this feature)

- **Never break client internet.** This service is fully additive: it
  touches no nft classifier, no ip rule, no dnsmasq config, no fw4
  table. Blast radius to existing routing/DNS is zero by construction;
  rollback is always `amnezia-covert-ctl disable`.
- POSIX sh / BusyBox ash for all router-side wrapper scripts (the
  creator binary itself is the one compiled artifact in this repo —
  see "Why not commit the binary" below).
- Never expose the VK cookie in a command, log, UCI dump, or git commit.
- LuCI JS ships through all four delivery surfaces
  (`dev/sync-to-packages.sh`, `openwrt/install-luci-app-amnezia.sh`,
  `install.sh`, `dev/deploy-openwrt-safe.sh`) per existing convention.
- Live-router application is a separate, later step after unit
  verification, each step preceded by a rollback plan and a WAN+DNS
  health check per CLAUDE.md live-router rules.

---

## Components

### Upstream source pinning & build (new: this repo's first compiled artifact)

Source: `github.com/kulikov0/whitelist-bypass`, pinned to commit
`89d7a474b7aca6cce664280e6feeaeca2706733b` (the exact commit validated
live in Phase 0 today). A documented bump procedure (re-clone, re-run
Phase-0-style smoke test, update the pinned SHA) replaces floating
`main` — upstream has broken things on `main` before (Telemost, per
Phase 0 results).

**Why not commit the binary or vendor the Go source:** this repo is
POSIX-sh-only by convention and explicitly avoided pulling upstream's
git history earlier this session specifically to dodge large committed
binaries. A new `dev/build-covert-creator.sh`:
1. Sparse+partial-clones the pinned SHA into a **gitignored** scratch
   dir (`build/covert/src/`, mirroring the Phase-0 clone recipe).
2. `GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath
   -ldflags="-s -w" -C headless/vk -o
   build/covert/dist/headless-vk-creator .`
3. Leaves the artifact at `build/covert/dist/headless-vk-creator`
   (also gitignored).

The installer/deploy scripts copy **from that local build output**,
exactly like the iOS app's `Mobile.xcframework` was built fresh rather
than committed. A missing build output fails the install step loudly
("run dev/build-covert-creator.sh first"), never silently skips.

### UCI state (`/etc/config/amnezia`, `config amnezia 'config'`)

```
option covert_enabled       '0'                                   # opt-in, default off
option covert_cookies_path  '/etc/amnezia/covert/vk-cookies.json'  # path only — the secret lives in the file, never in UCI
option covert_resources     'moderate'                             # fixed for P1; exposed for future tuning
```

### Secrets

- `/etc/amnezia/covert/vk-cookies.json` — root:root, **mode 600**.
  Written only by `amnezia-covert-ctl set-cookies`, which reads the
  cookie content from **stdin**, never a command-line argument (keeps
  it out of `ps` output too, not just shell history/logs).
- `/var/run/amnezia-covert-link.txt` — the binary's own `-write-file`
  target; volatile (tmpfs), holds the current call's join link. Cleared
  naturally on reboot/service restart — matches "the call ends when the
  service stops" semantics.

### New CLI `/usr/bin/amnezia-covert-ctl`

POSIX sh, sources `amnezia-common.sh`, `uci -q get` throughout (never
`uci show | grep`). Verbs:

- **`enable`** → preflight: `covert_cookies_path` exists and is
  non-empty (else fail with a clear message, no mutation, no service
  start). Set `covert_enabled='1'`, commit, start/restart the procd
  service.
- **`disable`** → stop the procd service, `covert_enabled='0'`, commit.
  The cookies file is **not** deleted (survives for the next `enable`).
- **`apply`** → idempotent; ensures the procd service matches current
  UCI state (used by init boot, and by `enable`/`set-cookies`). If the
  binary is missing (build step never run / install incomplete), fails
  loudly rather than silently no-op-ing.
- **`set-cookies`** → reads new cookie content from stdin, writes it to
  `covert_cookies_path` with `chmod 600`, then `apply` if enabled.
- **`status`** → JSON `{ "enabled": bool, "running": bool, "state":
  "idle|starting|connected|auth-failed|crashed", "link": "<url or
  empty>" }`. `running` comes from procd's own service query; `state`
  and `link` come from tailing the service's syslog output and reading
  `/var/run/amnezia-covert-link.txt`. **Bounded** (no network calls of
  its own) so a LuCI poll can never stall.

No separate watchdog verb in P1 — Phase 0 showed the binary already
self-heals VK's ghost-participant/reconnect churn internally; the only
outer safety net needed is procd's own `respawn` on hard process death.
Revisit if live use shows otherwise (YAGNI).

### procd init `/etc/init.d/amnezia-covert`

`USE_PROCD=1`, `START=98` (after `amnezia-dns`/`amnezia-force-load`,
consistent with existing ordering — this service has no dependency on
either, ordering just keeps boot-log grouping sane). Command:

```
/usr/bin/amnezia-covert-creator \
  -cookies /etc/amnezia/covert/vk-cookies.json \
  -resources moderate \
  -write-file /var/run/amnezia-covert-link.txt
```

`procd_set_param respawn` (standard threshold/timeout/retry triple,
values pinned at plan time), `procd_set_param stdout 1`,
`procd_set_param stderr 1` (captured to syslog/`logread`, same pattern
as the DNS watchdog). No `-debug` by default (keeps logread quiet);
exposed as a future UCI toggle if troubleshooting needs it, not built
now.

**Known P1 limitation, accepted:** since no `-vk-link` is passed, every
process (re)start — including a procd respawn after a crash — creates a
**new** VK call with a **new** link. A crash means the user has to
re-copy the link from LuCI into the joiner app. Proper persistence
(rejoin the same call via `-vk-link` after a restart) is real complexity
that Phase 0's demonstrated stability doesn't yet justify — deferred,
not silently dropped.

### LuCI UI

New 5th `require`d section module `amnezia.section.covert` (sibling of
`failover`/`routing`/`zapret`/`dns`), added to `main.js`'s module list +
`Object.assign` handler map, its own `refresh()` folded into the
existing `Promise.all` polling. New accordion entry **"Covert Access
(VK)"**, **collapsed by default** (advanced/opt-in, same treatment as
the zapret family):

- Enable/disable toggle → `handleCovertToggle` (`ctlThenRefresh` shape).
- Cookie `<textarea>` (write-only — never pre-filled with the existing
  value, like a password field) + "Save cookies" button →
  `handleCovertSaveCookies`, calling `fs.exec` with the textarea content
  as **stdin input** (confirm exact `fs.exec` stdin-passing mechanics
  against this router's live `fs.js` at plan/execute time — don't
  assume from memory).
- Status line: state badge via the existing `verdictColor` util
  (idle/starting/connected/auth-failed/crashed each get a distinct
  color, not just "on/off").
- Join-link row with a copy affordance, shown only when `state ===
  "connected"` and `link` is non-empty.

**ACL:** add `"/usr/bin/amnezia-covert-ctl": ["exec"]` to
`openwrt/luci-app-amnezia/acl/luci-app-amnezia.json`'s `write.file`
block (mirrors the `amnezia-dns-ctl` entry — the single most common
cause of an empty/dead LuCI panel in this project's history is a missed
ACL grant).

### Installer / packaging

- `install-amnezia-pbr.sh` (and its `packages/` mirror): copy the
  built binary from `build/covert/dist/headless-vk-creator` to
  `/usr/bin/amnezia-covert-creator` on the router, plus the new CLI +
  lib + init + ACL. Binary copy step fails loudly if the local build
  output is missing.
- `dev/sync-to-packages.sh`: explicit new entries for the CLI, lib,
  init (hand-maintained allow-list per existing convention — CI
  sync-check must stay green). The binary artifact itself is **not**
  part of the `openwrt/ ↔ packages/` parity check (it's a build output,
  not source).

---

## Testing

bats unit tests (uci stub in the **exact quoted/multi-line-list real
format**, per CLAUDE.md):
1. `enable` with no cookies file → refuses, no UCI mutation, no service
   start.
2. `enable` with a cookies file present → `covert_enabled='1'`,
   procd service (re)started.
3. `disable` → service stopped, `covert_enabled='0'`, cookies file
   untouched.
4. `set-cookies` → writes stdin to the configured path with mode 600;
   does not echo/log the content anywhere the test can observe (assert
   the test's own captured stdout/stderr never contains the fixture
   secret).
5. `status` JSON parsing against **captured real log output** — see
   below, exact log signatures pinned at plan/execute time by actually
   running the binary once with valid and once with deliberately
   invalid cookies (never fabricated strings).
6. ACL file contains the new exec grant.

**Live-only gates** (a green bats run proves the wrapper logic only —
VK auth/connectivity cannot be simulated in the VM harness, same class
of blind spot as DoT's real-activation bug):
- Start the service on the router with real cookies, confirm LuCI shows
  `state: connected` and a real join link.
- Paste that link into the already-working iOS/Mac joiner app (from
  Phase 0), confirm a page loads through the router-hosted creator.
- `free -h` before/after first live start — confirm the router doesn't
  come under memory pressure that affects other services (dnsmasq,
  hostapd, `amnezia-failover`). If it does, `disable` is the immediate
  rollback; no other subsystem is touched by this feature so this is a
  clean revert.

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| VK cookie is a real personal-account credential | 600 root-owned file, never in UCI/git/logs; set via stdin (not argv, keeps it out of `ps`); same handling as existing private tunnel `.conf` keys |
| Router has only 85MB free RAM; `moderate` profile asks up to 64MB | The one empirical unknown in this design — flagged explicitly, monitored on first live start, `disable` is a clean full rollback since nothing else is touched |
| Crash/respawn creates a new call ⇒ stale link in the joiner app | Accepted P1 limitation, documented; connectivity still recovers via procd respawn, just requires re-copying the link; real fix (persist + `-vk-link` rejoin) deferred |
| Committing a fast-moving foreign upstream's compiled binary into this repo | Not committed — built fresh from a pinned SHA via a gitignored script, same pattern as the Phase-0 iOS build |
| Upstream `main` has broken features before (Telemost) | Pinned to the exact SHA validated in Phase 0; documented, deliberate bump procedure |
| Status parsing conflates "no cookie yet" / "still connecting" / "auth rejected" | Four distinct states surfaced explicitly, each backed by a real observed log signature captured empirically, not guessed (per project's "parser that defaults on missing key" lesson) |
| Missing ACL grant ⇒ dead-looking LuCI panel (this project's #1 recurring cause) | Explicit ACL entry in this design + covered by the existing offline `luci-harness.js` gate extended to the new module |
| Service accidentally participates in fwmark/DNS plane | Explicitly does not in P1 — default routing table only; no nft/ip-rule/dnsmasq touch; verified in bats by asserting the install step adds no such file |

---

## Open items deferred to plan

- Exact `state` log-line signatures (connected / auth-failed) — captured
  empirically from one real run with good cookies and one with bad
  cookies during execute, not guessed from reading source.
- Exact procd `respawn` threshold/timeout/retry values.
- Exact `fs.exec` stdin-passing mechanics for the cookie-save handler —
  confirm against this router's live `fs.js`/`rpcd` before finalizing.
- `START` ordering number final check against current init.d numbering
  on the live router (currently assumed 98, after `amnezia-dns`=97).
