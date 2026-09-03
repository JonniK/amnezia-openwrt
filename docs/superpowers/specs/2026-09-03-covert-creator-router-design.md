# Covert-Transport Creator on Router (Phase 1) — Design

**Date:** 2026-09-03
**Branch:** `feat/covert-creator-router`
**Status:** design-review cycle 1 complete (2 internal opus + 1 external
codex). **8 CRITICAL / 15 HIGH found, all addressed in this revision**
except one that cannot be resolved by design alone — see Prerequisite
below. Ready for a second review pass once the prerequisite spike
result is in.

## Prerequisite — must pass before any Phase 1 build work starts

Three independent reviewers flagged the same critical gap: **Phase 0
never actually ran `headless/vk` in creator mode.** It ran
`relay/main.go --mode vk-video-creator` (browser-bridged) on the Mac
and the native iOS app (which uses the *joiner* path). The native
headless *creator* — what this whole design packages — has never been
executed by anyone in this project. The proposal's own July analysis
records a known blocker for exactly this binary: *"VK's known
headless-CLI limitation (interactive captcha)"* — a blocker Phase 0
sidestepped only because it used the GUI Creator app, which this
design removes.

This is a credential-gated fact I cannot verify myself (per this
project's hard credential rule, I never handle the VK session cookie).
**Before any packaging/procd/LuCI work starts, run this once, on your
own machine, with your own cookies:**

```sh
cd /Users/jonnik/amnezia-external/whitelist-bypass/headless/vk
go build -o /tmp/headless-vk-creator .
/tmp/headless-vk-creator -cookies /path/to/your/vk-cookies.json -write-file /tmp/vk-link.txt
```

Watch for: does it print `WAITING_FOR_COOKIES`-style prompts only (fine
— that's just the no-cookie-supplied path, not relevant here since
`-cookies` is given), does it create a call and print a link within a
reasonable time, or does it hang / print something indicating a
captcha/verification challenge? Run it **at least 3 times** (respawn
will do this routinely in production) to see if repeated call-creation
from the same account triggers anything. Paste back the **log output**
(not the cookies file) so I can read the actual behavior — the
binary's own log never echoes the cookie value.

If this hits a captcha wall, Phase 1's entire shape changes (the
headless creator can't run unattended, full stop — see Risks). If it
doesn't, the rest of this design is what to build.

## Goal

Move the "creator" role of the whitelist-bypass covert transport (see
`docs/proposals/whitelist-bypass-covert-transport.md`, Phase 0 PASSED
2026-09-03 via VK) from the user's Mac onto the AX3000T router, as an
opt-in procd service with a LuCI toggle. Today the phone/Mac joiner only
gets free internet while the Mac is on and a browser tab is open running
the creator; after this phase the joiner works whenever the router is up
**and the prerequisite spike above has passed.**

**In scope (P1):**
- Cross-compiled native headless VK creator running as a router procd
  service, default OFF, as a dedicated low-privilege user.
- A narrowly-scoped fw4 rule restricting (not expanding) that user's
  own egress — see "Egress restriction" below. This is the one
  deliberate addition to the firewall surface in P1; everything else
  about existing routing/DNS is untouched.
- LuCI toggle + cookie input (written directly via `fs.write`, see
  Secrets) + live status + current join-link display.
- Manual join-link workflow: the router creates a fresh VK call on
  start, prints the link, the user copies it into the phone/Mac joiner
  app by hand.
- Delivery via `dev/deploy-openwrt-safe.sh` only (manual dev-controlled
  deploy) — see "Installer / packaging" for why the public `install.sh`
  and `.ipk` paths are explicitly **not** in scope for P1.

**Out of scope (later phases, already recorded in the proposal):**
- P2: routing the creator's own egress through the amnezia fwmark/tunnel
  plane (`--upstream-socks` seam) so the phone inherits RU-direct/tunnel
  policy.
- P3: automated join-link delivery (QR/push) and multi-SFU failover
  (Telemost is broken on upstream `main` as of Phase 0 — VK only for now).
- Public `.ipk`/`install.sh` delivery of this feature (needs a real
  arch-specific package or release-asset flow — a separate, later
  design, not silently bolted onto this one).
- `master_enabled` interaction — this service does not participate in
  the tunnel/DNS plane at all in P1. Its LuCI panel is deliberately
  rendered **outside** the master-gated accordion (see LuCI section) so
  this claim is actually true in the UI, not just in the routing layer.

## Background — corrected against review findings

1. **`relay/main.go --mode vk-video-creator` (what Phase 0 actually ran
   on the Mac) needs a browser tab** — it only opens a `/signaling`
   websocket; the real WebRTC negotiation happens in JS in a browser.
   Not portable to a headless OpenWrt box. This design instead targets
   `headless/vk` — a **separate, fully native Go module** (own
   `go.mod`, no CGO, no browser) that already backs the project's
   Android/iOS headless *joiner* paths. Cross-compiled locally for
   `linux/arm64` (`CGO_ENABLED=0`): **11MB, static, stripped** — verified
   by an actual build. Fits the router's 48.9MB free flash with room to
   spare.
2. **Correction from review:** the pinned commit `89d7a474` is "the
   tree Phase 0 built `relay/main.go` and the iOS app from" — it is
   **not** evidence that `headless/vk`'s *creator* mode at that SHA
   works unattended. That's exactly what the Prerequisite spike above
   settles, independent of which commit is pinned.
3. **Even `-vk-link` (joining an existing call) requires a VK session
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
   - **Cost of that silver lining (new in this revision):** every
     restart — including a procd respawn after any crash — creates a
     **new call on a real personal VK account**. See "Call-creation
     backoff" below; an unthrottled crash loop is a call-creation storm
     against your own account, exactly the kind of automated-looking
     activity the captcha/anti-abuse system in the Prerequisite exists
     to catch.

## Constraints (carried from project CLAUDE.md + this feature)

- **Never break client internet.** This service does not touch the nft
  classifier, ip rules, or dnsmasq config for existing routing/DNS.
  It *does* add one new, narrowly-scoped fw4 output rule for its own
  dedicated user (see Egress restriction) — stated honestly here
  instead of claiming "zero blast radius," which review correctly
  called out as false for the security dimension (an unauthenticated
  relay into the LAN is a blast-radius increase even if routing/DNS
  are untouched).
- POSIX sh / BusyBox ash for all router-side wrapper scripts (the
  creator binary itself is the one compiled artifact in this repo —
  see "Why not commit the binary" below).
- Never expose the VK cookie in a command, log, UCI dump, or git commit.
- LuCI JS ships through all four delivery surfaces for the JS/ACL
  changes; the **binary** ships through `dev/deploy-openwrt-safe.sh`
  only in P1 (see Installer / packaging — this is a correction from
  review, not an oversight).
- Live-router application is a separate, later step after unit
  verification, each step preceded by a rollback plan and a WAN+DNS
  health check per CLAUDE.md live-router rules.

---

## Egress restriction (new section — resolves the LAN-exposure finding)

The creator is, by construction, an unauthenticated exit relay: anyone
holding the VK call link (displayed in LuCI, copy-pasted between
devices) can join and route traffic through it. Left unrestricted, that
traffic reaches not just the internet but the router's own admin plane
and the whole LAN — SSH on `:2323`, LuCI, dnsmasq, every LAN host.

P1 mitigation, kept minimal (full policy-routing integration is P2):
- The creator runs as a **dedicated system user** `amnezia-covert`
  (procd `procd_set_param user amnezia-covert`), not root. It does not
  need root — it binds ephemeral UDP ports for WebRTC/ICE, nothing
  privileged.
- One new fw4 rule, in its own file
  `/etc/nftables.d/40-amnezia-covert-egress.nft` (validated with
  `fw4 check`, per the project's nftables.d convention — never
  `nft -c -f` on a fragment):
  ```
  chain amnezia_covert_egress {
      type filter hook output priority -1; policy accept;
      meta skuid amnezia-covert ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8 } reject
  }
  ```
  This denies the creator process itself from reaching RFC1918 space,
  loopback, and (transitively) the router's own management surfaces,
  while leaving its route to the real internet (and to VK's own
  infrastructure) untouched. Traffic **forwarded through the tunnel**
  by the relay bridge on behalf of the joiner is a kernel-level
  userspace socket relay (the creator process itself makes the outbound
  connections), so this same uid-scoped rule covers joiner-forwarded
  traffic too — it's the creator process doing the dialing either way.
- Threat model stated explicitly: anyone with the link gets router-IP
  internet egress (not LAN access, after the rule above). Link secrecy
  is the only admission control in P1 — treat the link like a
  credential, don't publish it. A dedicated/disposable VK account is
  recommended over the user's primary one (see Risks — this also
  bounds the blast radius of the call-creation-storm/account-ban risk).

---

## Components

### Upstream source pinning & build (new: this repo's first compiled artifact)

Source: `github.com/kulikov0/whitelist-bypass`, pinned to commit
`89d7a474b7aca6cce664280e6feeaeca2706733b`. **Corrected framing per
Background item 2:** this SHA is the tree Phase 0 built from, not proof
the creator-mode binary works — that's the Prerequisite's job. The bump
procedure (re-clone, re-run the Prerequisite spike, update the SHA)
replaces floating `main` — upstream has broken things on `main` before
(Telemost, per Phase 0 results).

**Why not commit the binary or vendor the Go source:** this repo is
POSIX-sh-only by convention and explicitly avoided pulling upstream's
git history earlier this session specifically to dodge large committed
binaries. A new `dev/build-covert-creator.sh` (**corrected build
command from review — `-C` must be the first flag, and `-o` is
interpreted relative to the `-C` directory, so it must be absolute**):

```sh
#!/bin/sh
set -eu
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/build/covert/src"
DIST="$REPO_ROOT/build/covert/dist"
PIN="89d7a474b7aca6cce664280e6feeaeca2706733b"

command -v go >/dev/null || { echo "go toolchain required" >&2; exit 1; }
go version | grep -q go1.26 || { echo "expected go1.26.x (got: $(go version))" >&2; exit 1; }

rm -rf "$SRC"
mkdir -p "$SRC" "$DIST"
git clone --filter=blob:none --no-checkout --sparse \
  https://github.com/kulikov0/whitelist-bypass "$SRC"
git -C "$SRC" sparse-checkout set headless/vk
git -C "$SRC" checkout "$PIN"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$PIN" ] || { echo "checkout SHA mismatch" >&2; exit 1; }

go -C "$SRC/headless/vk" build -trimpath -ldflags="-s -w" \
  -o "$DIST/headless-vk-creator" .

file "$DIST/headless-vk-creator" | grep -q 'ARM aarch64' \
  || { echo "build did not produce an aarch64 binary" >&2; exit 1; }

sha256sum "$DIST/headless-vk-creator" > "$DIST/headless-vk-creator.sha256"
{
  echo "upstream_sha=$PIN"
  echo "go_version=$(go version)"
  echo "built_at=$(date -u +%FT%TZ)"
} > "$DIST/BUILD_MANIFEST.txt"
echo "Built: $DIST/headless-vk-creator"
cat "$DIST/headless-vk-creator.sha256"
```

`build/` is added to `.gitignore` (it currently is **not** — review
caught that this design would otherwise be one `git add -A` from
committing an 11MB binary, exactly what the sparse-checkout dance
earlier this session was avoiding). The manifest + sha256 let `status`
report which build is actually on the router (see CLI section) — matches
this project's own lesson that "deployed ≠ confirmed running" for
opaque artifacts.

### UCI state (`/etc/config/amnezia`, `config amnezia 'config'`)

```
option covert_enabled       '0'                                   # opt-in, default off
option covert_cookies_path  '/etc/amnezia/covert/vk-cookies.json'  # path only — the secret lives in the file, never in UCI
```

`covert_resources` is **dropped** from this revision — review correctly
flagged it as a dead knob (nothing read it; `moderate` was hardcoded).
If per-deployment tuning is ever needed, add it back paired with an
actual reader in the init script, not before. `covert_cookies_path`
**is** read by the init script now (see procd init) — the other dead-knob
finding, fixed by actually wiring it up rather than dropping it, since
letting the user relocate the cookie file is a reasonable knob to keep.

### Secrets — resolved: `fs.write`, not stdin (the C2 finding across all three reviews)

**Verified live against the router**, not assumed: `ubus -v list file`
shows `file.exec` takes exactly `{command, params, env}` — **no stdin
channel exists**, confirming review's finding that the original stdin
design was unbuildable. But `file.write` takes `{path, data, mode}`
(confirmed from the device's own `/www/luci-static/resources/fs.js`:
`write: function(path, data, mode)`, default mode 0644) — **this is
the real mechanism.**

- LuCI's "Save cookies" button calls `fs.write('/etc/amnezia/covert/vk-cookies.json', textareaValue, 0o600)`
  directly — the cookie is written by rpcd in a single ubus call, never
  passed as a CLI argument (so it never appears in `ps`), and never
  routed through `amnezia-covert-ctl` at all for the write itself.
- **ACL:** the `write.file` block needs a **`write`** grant on that
  exact path (a different primitive than the `exec` grant the original
  draft assumed sufficient):
  ```json
  "write": {
    "file": {
      "/usr/bin/amnezia-covert-ctl":              [ "exec" ],
      "/etc/amnezia/covert/vk-cookies.json":       [ "write" ]
    }
  }
  ```
- `/etc/amnezia/covert/` is created **0700 root:root** at install time
  (not just the file at 0600 — the directory mode was unspecified
  before, per review). The file itself is written by rpcd running as
  root, so it lands owned root:root; `amnezia-covert-ctl apply` sets
  0600 explicitly as a belt-and-suspenders step after any write, in
  case rpcd's mode param doesn't stick exactly as expected on this
  OpenWrt version — verify empirically at execute time.
- **Validation, not blind trust:** `amnezia-covert-ctl enable`/`apply`
  checks the file exists, is non-empty, and does a shallow sanity check
  (parses as the expected cookie format) before starting the service —
  catching a truncated/malformed paste as a distinct, surfaced error
  rather than a generic `auth-failed` after the process starts and
  fails.
- `/var/run/amnezia-covert-link.txt` from the earlier draft is
  **replaced** by a proper state file — see "Status via a dedicated
  state file," not raw log-grepping.

### New CLI `/usr/bin/amnezia-covert-ctl`

POSIX sh, sources `amnezia-common.sh`, `uci -q get` throughout. Full
verb contract (review flagged the original as too loose to implement
against without guessing):

- **`enable`** → preflight: `covert_cookies_path` (from UCI, falling
  back to the default if unset) exists, non-empty, passes the shallow
  format check. On failure: **no UCI mutation**, print a specific
  reason to stderr, exit 1. On success: `uci set amnezia.config.covert_enabled='1'; uci commit amnezia`
  as a single uninterrupted sequence (minimizes the shared-UCI-commit
  race window flagged in review — see "UCI commit race" in Risks), then
  `/etc/init.d/amnezia-covert enable && /etc/init.d/amnezia-covert restart`
  (matches the DoT precedent: `restart` on a not-yet-`enable`d procd
  service is a silent no-op — this project has shipped that exact bug
  before). Exit 0 on success.
- **`disable`** → `/etc/init.d/amnezia-covert stop && /etc/init.d/amnezia-covert disable`,
  removes the state file and the link, `covert_enabled='0'`, commit.
  Idempotent: disabling an already-disabled service is exit 0, not an
  error. Cookies file is **not** deleted.
- **`apply`** → idempotent; re-asserts the running state matches UCI
  (used by boot init and by `enable`). If `covert_enabled=0`: ensures
  the service is stopped, exit 0 regardless of prior state. If
  `covert_enabled=1`: runs the same preflight as `enable`; if it fails
  (e.g. cookies file went missing after a factory-reset-adjacent event),
  logs the reason, leaves `covert_enabled` untouched but does **not**
  start the process, and `status` reports `state: "auth-failed"` with a
  reason string rather than silently doing nothing. If the binary
  itself is missing, fails loudly (distinct exit code) — this is the
  expected state on any install path other than
  `dev/deploy-openwrt-safe.sh` in P1 (see Installer section) and must
  say so in its error text, not just "not found."
- **`status`** → reads `/var/run/amnezia-covert.json` (written by the
  log-wrapper, see below) plus `ubus call service list` for the procd
  running bit, and returns exactly one JSON object on stdout:
  ```json
  {
    "enabled": true,
    "running": true,
    "state": "connected",
    "link": "https://vk.com/call/join/XXXX",
    "link_age_s": 42,
    "reason": "",
    "build_sha": "89d7a474",
    "build_hash": "<sha256 prefix of the installed binary>"
  }
  ```
  `state` ∈ `idle | starting | connected | auth-failed | crashed | unknown`.
  **Truth table (resolves the "undefined field combinations" finding):**
  `enabled=false` ⇒ always `state: "idle"`, `running: false`, no link.
  `running=false` while `enabled=true` ⇒ `state` ∈
  `{auth-failed, crashed}` with `reason` set — never bare `idle`, so
  the UI can distinguish "off by choice" from "off because it died."
  `state: "unknown"` is returned when the state file is stale beyond a
  fixed staleness window (see log-wrapper) or missing while
  `running=true` — an explicit "we can't tell" state, never silently
  presented as `idle` (the exact failure mode review's H4/status
  findings warned about). `status` never touches the network and never
  triggers `apply`, so a LuCI poll can't stall. Exit code is always 0 if
  JSON was produced (errors are represented *in* the JSON, via
  `state`/`reason`), non-zero only on a genuine CLI-internal failure
  (missing `jq`/`uci`, etc.) — LuCI's handler treats a non-zero exit as
  a distinct "CLI broken" case, separate from any `state` value.

No `set-cookies` verb — the write is LuCI-direct via `fs.write` (see
Secrets). No separate `watchdog` verb in P1 — Phase 0 showed the binary
already self-heals VK's ghost-participant/reconnect churn internally;
procd's own `respawn` is the only outer safety net needed. Revisit if
live use shows otherwise.

### Status via a dedicated state file, not `logread` (resolves the log-ring-starvation + status-ambiguity findings)

Review found a serious, project-specific risk in the original "parse
`logread`" design: `amnezia-autotunnel.sh`'s per-minute worker reads
the **entire** logd ring looking for dnsmasq query lines, and this
router has **already been hard-crashed once by autolearn CPU/log
load** (project memory: `feedback-autolearn-crashed-router.md`). A
chatty WebRTC process writing straight to the shared syslog ring risks
evicting the lines autotunnel depends on — silently, with no error
anywhere — and status derived from raw `logread` output has no way to
scope itself to the *current* process incarnation, so a stale
`connected` signature from a previous run can outlive a respawn.

**Fix, following this project's own `/var/run/amnezia-failover.json`
convention:** the procd service does not send the binary's stdout/stderr
straight to syslog. Instead:

```
/usr/bin/amnezia-covert-creator ... 2>&1 | /usr/lib/amnezia/amnezia-covert-logwrap.sh
```

`amnezia-covert-logwrap.sh` (new, POSIX sh) does two things per line:
1. Appends to a **capped, dedicated** file `/var/log/amnezia-covert.log`
   (own size cap, e.g. 500 lines, mirroring the blackbox logger's
   own-file-own-cap convention) — never the shared logd ring, so
   autotunnel's full-ring scan is never at risk from this feature.
2. On recognizing a small set of markers, atomically rewrites
   `/var/run/amnezia-covert.json` (`write-to-tmp` + `mv`, matching the
   project's atomic-state-file convention) with the current `state`,
   `link`, and a timestamp. **Exact marker strings are pinned during
   execute** (per this project's "never fabricate a stub from memory"
   rule) by running the Prerequisite spike output through this wrapper
   and observing the real log lines for connected/auth-failed — this is
   explicitly still deferred, but the *architecture* (dedicated capped
   file + state JSON, never raw `logread` parsing) is decided now, not
   left open.

The wrapper is spawned fresh by procd on every service start, so the
state file always reflects the *current* process generation — the
truncation-on-restart bug review found in the original design (stale
link surviving a respawn) is structurally impossible here rather than
requiring a separate "remember to clear the file" step.

### procd init `/etc/init.d/amnezia-covert`

`USE_PROCD=1`, `START=99` (**corrected from 98** — `amnezia-dnsleak`
already owns 98; review caught the original's stated rationale as
incomplete). `start_service`:

```sh
start_service() {
    config_load amnezia
    local enabled cookies_path
    config_get enabled config covert_enabled '0'
    config_get cookies_path config covert_cookies_path '/etc/amnezia/covert/vk-cookies.json'
    [ "$enabled" = "1" ] || return 0

    # readiness gate: no RTC on this hardware, and WAN/DNS complete
    # asynchronously after boot — starting before both are sane means
    # VK auth fails and procd's respawn budget burns on nothing (the
    # exact "pbr boot race" class this project has hit before).
    amnezia_covert_wait_ready || { logger -t amnezia-covert "boot readiness timeout, not starting"; return 1; }

    rm -f /var/run/amnezia-covert.json /var/run/amnezia-covert-link.txt

    procd_open_instance
    procd_set_param command /usr/bin/amnezia-covert-creator \
        -cookies "$cookies_path" -resources moderate
    procd_set_param user amnezia-covert
    procd_set_param respawn 300 5 5   # 5 restarts within 5min, then give up — see Risks for what "gave up" means
    procd_set_param limits as="128000000"   # RSS ceiling; see Risks/OOM handling
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_append_param command 2>&1
    procd_close_instance
}
```

(The pipe-to-logwrap from the previous section is realized via procd's
own stdout/stderr redirection plumbing — exact procd syntax for piping
through a filter vs. a respawned sidecar process is a plan-time detail;
both are standard procd patterns, picked at execute time based on which
is more robust against the wrapper itself dying independently of the
creator.)

**Respawn-exhaustion state, defined (was undefined in the previous
draft):** if procd's respawn budget is exhausted (5 deaths in 5 minutes),
the service instance stops trying and `covert_enabled` stays `'1'` —
matching how the project would rather have "on but visibly broken" than
silently self-disabling a user's opt-in choice. `status` must detect
this (`running: false`, `enabled: true`, no fresh state-file write) and
report `state: "crashed"` with a reason mentioning respawn exhaustion,
not `idle`.

**Call-creation backoff (resolves the account-abuse risk from review):**
`amnezia-covert-logwrap.sh` also tracks the timestamp of the last
call-creation marker in a small file; if the creator process is about
to be respawned less than 2 minutes after the previous one created a
call, the wrapper holds a short additional delay before allowing the
next `exec`, so a genuine crash loop doesn't turn into a rapid-fire
call-creation storm against the user's VK account (this is on top of,
not instead of, procd's own 5-in-5min respawn cap).

### Memory handling (resolves the OOM-rollback-not-provable finding)

`moderate` is a Go **soft** memory target (`GOMEMLIMIT` semantics), not
an RSS cap — the previous draft's "asks up to 64MB" understated the
real ceiling against the router's 85MB free RAM. Concrete mitigations,
now specified rather than deferred:
- `procd_set_param limits as=128000000` — a hard RSS ceiling via
  procd/ulimit, so a leak or a burst gets killed by the limit rather
  than pressuring the whole system.
- `amnezia-covert-ctl apply` checks `MemAvailable` from `/proc/meminfo`
  (not the coarser `free -h`) before starting the service; refuses to
  start below a threshold (pinned at plan/execute time against a live
  measurement) and reports that as a distinct `reason` in `status`.
- **First live enable is a foreground-supervised run**, not
  enable-then-walk-away: start it, watch `free`/`top` on the router for
  several minutes under real joiner traffic (not just idle — review
  correctly noted idle-vs-loaded RSS differ a lot for a DTLS/SRTP
  stack) before trusting it to run unattended across a reboot.
- Given the OOM killer isn't guaranteed to pick the creator over
  dnsmasq/hostapd, and this project has a **documented non-self-healing
  path** if `amnezia_force4` gets corrupted by an unrelated dnsmasq
  restart, the honest position (stated in Risks, not glossed over) is:
  the RSS ceiling + preflight check bound the *likely* failure mode,
  they do not make an OOM event impossible. `disable` is a clean
  rollback for *this feature's own* state; it is not a guaranteed
  recovery for whatever else the OOM killer may have already hit.

### LuCI UI

**Placement correction from review:** the panel is rendered **outside**
`#amz-accordion`, as its own block next to the master-state strip — not
inside the accordion. The original draft claimed independence from
`master_enabled` while also nesting the panel inside the
`.amnezia-master-off { pointer-events:none }` container, which review
correctly identified as self-contradicting (master OFF would make a
supposedly-independent toggle physically unclickable). Placing it
outside makes the stated independence actually true in the UI.

New require'd module `amnezia.section.covert`, added to `main.js`'s
module list + `Object.assign` handler map, its own `refresh()` folded
into the existing `Promise.all` polling, **plus** a `main.load()`
data-bundle entry (`fs.exec('/usr/bin/amnezia-covert-ctl',['status'])`)
so first paint shows real state instead of a blank/invented default —
this project already has the DoT precedent for exactly this pattern.

- Enable/disable toggle → `handleCovertToggle` (`ctlThenRefresh` shape,
  `L.resolveDefault`-wrapped so a rejection can't blank the whole page).
- Cookie `<textarea>` (write-only — never pre-filled) + "Save cookies"
  button → calls `fs.write()` **directly** (not `fs.exec` — see
  Secrets), then a **separate** `handleCovertApply` call to
  `amnezia-covert-ctl apply` so the CLI's validation runs against what
  was just saved.
- Status line: a **new** `covertStateColor()` function added to
  `util.js` (review flagged extending the existing `verdictColor`
  switch as the "adding a caller to a shared classifier makes a dead
  default arm live" trap this project has been burned by — zapret's
  probe vocabulary depends on that switch's exact arm set; a new
  function avoids touching it).
- Join-link row with a copy affordance and its age (`link_age_s`),
  shown only when `state === "connected"`.

**ACL** — `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json`'s
`write.file` block gets both entries (exec on the CLI, write on the
cookie path — see Secrets for the exact JSON). Missing this grant is,
per this project's own history, the single most common cause of a
dead-looking LuCI panel — called out explicitly so it isn't missed here
either.

**Harness extension** — `test/lib/luci-harness.js` hardcodes the
section-module list in **six** places (verified: lines ~88-91, 126,
158-161, 215-218, 297) plus the `main.js` `DATA` fixture array that
`main.load()`'s indices mirror. All six, plus the new fixture index,
must be updated together — a plan-time checklist item, not "extend the
harness" as a single vague step.

### Installer / packaging — scope corrected

**Review finding (all three reviewers, independently):** the original
draft's claim that `install-amnezia-pbr.sh` or `install.sh` could
deliver the binary was wrong. `install-amnezia-pbr.sh` runs **on the
router** and only ever reads from `/tmp/<staged>` — it cannot reach a
developer Mac's local build output. `install.sh` fetches a GitHub
**source tarball** — a gitignored local build artifact can never be in
it. The `.ipk`'s `PKGARCH:=all` cannot legitimately carry an aarch64
ELF.

**Corrected P1 scope: binary delivery is via `dev/deploy-openwrt-safe.sh`
only**, extending its existing hand-maintained upload list:
1. `dev/build-covert-creator.sh` produces `build/covert/dist/headless-vk-creator`
   locally.
2. `dev/deploy-openwrt-safe.sh` stages it to the router (`cat "$f" | ssh_run "cat > /tmp/amnezia-covert-creator"`,
   matching the script's existing upload pattern), then `cp` +
   `chmod +x` + a `sha256sum` verification against
   `BUILD_MANIFEST.txt` into `/usr/bin/amnezia-covert-creator`.
3. The CLI/lib/init/ACL files ship through the normal four-surface
   convention (they're POSIX sh + JSON, no different from any other
   feature) — **only the compiled binary is dev-deploy-only in P1.**
4. `install.sh` and the `.ipk` install the CLI/init/ACL but the feature
   stays inert (binary missing) on those paths — `apply`'s
   missing-binary error text says so explicitly, so this reads as "not
   available on this install method yet," not a silent bug.

A proper public-package story (GitHub release asset, or a
`PKGARCH:=aarch64_cortex-a53` package) is a separate, later decision —
correctly out of scope for a P1 that's explicitly a manually-deployed,
opt-in, dev-supervised feature.

---

## Testing

bats unit tests (uci stub in the exact quoted/multi-line-list real
format, per CLAUDE.md):
1. `enable` with no cookies file → refuses, no `uci set` at all (not
   just no `commit` — review's UCI-race finding means even a staged,
   uncommitted `uci set` can be flushed by a *different* CLI's
   `uci commit amnezia`, so the bats stub must model `set` vs `commit`
   as distinct, observable steps to make this assertion meaningful).
2. `enable` with a cookies file present → single set+commit sequence,
   init `enable` then `restart` called in that order (mutation test:
   swap the order, confirm the test goes red — this is the exact bug
   class DoT shipped once).
3. `disable` on an already-disabled service → exit 0, no error.
4. `apply` with `covert_enabled=1` and a missing binary → distinct,
   loud failure mentioning the dev-deploy-only caveat.
5. `status` JSON — exactly one object on stdout; every field present;
   the enabled/running/state truth table honored (mutation test: force
   `running=false` while `enabled=true` and confirm `state` is never
   `idle`).
6. ACL file contains both the `exec` and the new `write` grant.
7. Log-wrapper: feed it captured real output from the Prerequisite spike
   (once available) for both the connected and auth-failed cases,
   assert the state file lands correctly; feed it a burst simulating a
   respawn and assert the state file reflects only the newest
   generation (mutation test: comment out the truncate-on-start step,
   confirm a stale-state test goes red).
8. Call-creation backoff: two respawns inside the 2-minute window →
   second exec is delayed; assert via a mutation that removing the
   delay logic turns the test red.

**Live-only gates** (a green bats run proves the wrapper logic only):
- **The Prerequisite spike itself** — the actual gate that decides if
  any of this is buildable.
- Enable on the router with real cookies, confirm LuCI shows
  `state: "connected"` and a real join link; confirm the egress-restriction
  nft rule actually blocks the creator's own attempt to reach
  `192.168.1.1` (a `curl --interface` test bound to the `amnezia-covert`
  uid, or simplest: temporarily run a probe as that user).
- Paste the link into the already-working iOS/Mac joiner app, confirm a
  page loads through the router-hosted creator.
- `MemAvailable` before/during a live joiner session under real traffic
  (not idle) — confirm the RSS ceiling and preflight check behave as
  designed, and that a deliberately-triggered OOM-adjacent condition
  (e.g. `stress-ng` alongside it, if available) doesn't take down
  dnsmasq/hostapd before the ceiling kills the creator first.
- Reboot the router with the feature enabled, confirm it comes back up
  and creates a fresh call unattended (validates the boot-readiness
  gate).

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| **`headless/vk` creator mode has never been run; VK captcha is a known limitation for exactly this binary** | Promoted to a blocking Prerequisite, not a deferred risk — nothing else in this design proceeds to build until it's answered |
| Unauthenticated exit relay into the LAN (link = sole admission control) | New uid-scoped fw4 egress-restriction rule (RFC1918/loopback denied for the creator's own user); explicit threat model stated; dedicated/disposable VK account recommended |
| VK cookie is a real personal-account credential | Written directly via `fs.write` (verified: no stdin channel exists in `fs.exec`), 0700 dir / 0600 file, never in UCI/argv/git/logs |
| Router has only 85MB free RAM; `moderate` is a soft target, not an RSS cap | Hard `procd limits as=` ceiling + `MemAvailable` preflight + first-run foreground supervision under real (not idle) load; explicitly **not** claimed to make OOM impossible |
| Respawn creates a new call per restart on a real account ⇒ crash loop = call-creation storm | 2-minute call-creation backoff in the log-wrapper, on top of procd's 5-in-5min respawn cap; account-ban risk stated, dedicated account recommended |
| Boot race: service starts before clock/WAN/DNS are sane | Readiness-gate wrapper in `start_service`; respawn-exhaustion is a defined, surfaced `crashed` state, not silent death with `enabled: true` |
| `restart` on a not-yet-`enable`d procd service is a silent no-op (shipped once before, DoT) | `enable` explicitly runs init `enable` then `restart`, in that order, with a mutation test asserting the order matters |
| Shared `/etc/config/amnezia` UCI file has no commit lock across the ~7 CLIs that write it | **Accepted, scoped risk, not newly introduced infrastructure:** covert-ctl's own writes are user-initiated (enable/disable clicks), not a tight loop like the 20s DNS watchdog or per-minute autotunnel cron — its collision probability is low and no worse than the status quo. Preflight strictly before any `uci set`, single uninterrupted set+commit, to keep its own exposure window minimal. A real fix (a shared UCI lock across all amnezia CLIs) is a legitimate but separate, pre-existing project-wide gap — out of scope for this feature to solve alone |
| `logread` parsing would risk starving `amnezia-autotunnel`'s full-ring scan (this router has already hard-crashed from autolearn load once) | Resolved architecturally: dedicated capped log file + atomic state-JSON via a log-wrapper, never raw `logread` parsing for `status` |
| Stale state (old link/state surviving a respawn) | State file is truncated on every service start, written fresh by that generation's own log-wrapper instance — structurally can't show a previous generation's state |
| Missing ACL grant ⇒ dead-looking LuCI panel (this project's #1 recurring cause) | Explicit `write.file` entries for both the exec and write grants; covered by the extended offline `luci-harness.js` gate |
| Extending the shared `verdictColor` switch makes a dead default arm live for zapret's vocabulary | New `covertStateColor()` function instead |
| Binary has no working delivery path on `install.sh`/`.ipk` | P1 scope explicitly limited to `dev/deploy-openwrt-safe.sh`; other paths install the feature inert with a loud, specific error, not silently |
| Committing a fast-moving foreign upstream's compiled binary into this repo | Not committed — `build/` added to `.gitignore`; built fresh from a pinned SHA with a recorded manifest + sha256 |

---

## Open items deferred to plan

- Exact log-wrapper marker strings for `connected`/`auth-failed`/call-creation —
  captured empirically from the Prerequisite spike's real output, not
  guessed.
- Exact `MemAvailable` threshold and `procd limits as=` value — pinned
  against a live measurement under real joiner traffic.
- Exact staleness window for `status`'s `unknown` state.
- Whether procd's stdout piping to the log-wrapper is a literal shell
  pipe in the `command` line or a respawned sidecar service — a
  procd-mechanics detail, picked at execute time based on which handles
  the wrapper dying independently of the creator more robustly.
- Shallow cookie-format validation — exact check (structural, not a
  full auth attempt) pinned once the Prerequisite spike shows what a
  real `vk-cookies.json` looks like.
