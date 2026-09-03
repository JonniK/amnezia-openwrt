# Covert-Transport Creator on Router (Phase 1) — Design

**Date:** 2026-09-03
**Branch:** `feat/covert-creator-router`
**Status:** design-review cycles 1 and 2 complete (2 internal opus + 1
external codex each). Cycle 1: 8 C / 15 H. Cycle 2: **~15 C / ~28 H —
most of them defects introduced by cycle 1's own fixes**, which is the
documented "fix rounds introduce defects at a high rate" pattern. This
revision addresses cycle 2 and, crucially, replaces every claim that
was previously asserted from memory with one read out of the upstream
source or measured on the router. **Prerequisite spike PASSED
2026-09-03** (see below) — the headless creator does create calls
unattended and draws no VK challenge over 3 consecutive runs. **Second
gate also PASSED** — the iPhone joiner attached to a headless-created
call and relayed real traffic (22 497 bytes over 4 completed
connections), in both DC and video modes. Both feasibility gates are
closed; the design is ready for the implementation plan.

> **Correction — a credential-handling mistake in the previous
> revision of this document.** The earlier Prerequisite told the user
> to paste the spike's raw log output, asserting "the binary's own log
> never echoes the cookie value." That assertion was made from memory
> and is **wrong on exactly the failure path the spike is designed to
> trigger**: `headless/vk/main.go:264` logs
> `fmt.Errorf("empty VK token, response: %s", string(r))` where `r` is
> the raw body of `https://login.vk.ru/?act=web_token` — the response
> that carries `access_token`; `main.go:287` does the same for
> `calls.start`. Both reach stdout via `log.Fatalf` (`main.go:704`) and
> neither is wrapped in `common.MaskError`, which the code *does* use
> elsewhere (`main.go:579,592`). Separately, the join link is not just
> an admission token — it is the **tunnel obfuscation secret**
> (`main.go:718`: `tunnel.NewTunnelObfuscator(tunnel.DeriveSecretFromJoinLink(callInfo.JoinLink))`)
> and is logged in the clear at `main.go:722`. The Prerequisite below
> is rewritten to report **only redacted, derived facts**. No raw log
> is to be pasted anywhere.

## Prerequisite — **PASSED 2026-09-03**

**Result.** Ran the host build 3 times, ~45 s each, ~50 s apart, cookies
read at runtime from their path (never on a command line). Every run:

| signal | run 1 | run 2 | run 3 |
|---|---|---|---|
| `CALL CREATED` | 1 | 1 | 1 |
| `[vk-ws] Connected` | 1 | 1 | 1 |
| fatal errors (`Failed to create call` / `Cannot read/parse cookies` / `empty VK token\|call_id\|ok_join_link`) | 0 | 0 | 0 |
| captcha / challenge / too-many / flood | 0 | 0 | 0 |

**The probe's own false positive, resolved:** the alarm pattern also
contained the bare substring `rate`, which matched 4×/run — all of them
`maintain-framerate` inside a VK SFU video-config message
(`[vk-ws] unhandled: {"camera":{...}}`). Not a rate-limit signal.

**Control for the negative** (per the project's "a negative probe is
worthless until a control proves the probe can say yes" rule): because
`headless/vk` has **no captcha handling at all**, a challenge cannot
present as a prompt — it would surface as `empty call_id, response: …`
→ `log.Fatalf`. That path is exactly what the fatal-error row counts,
and it read 0 while a call was demonstrably created and the SFU
websocket came up. Two independent signals agree, so the negative is
meaningful rather than merely "nothing printed".

**Measured, and it closes one deferred item:** steady-state log volume
is **37 lines / 45 s ≈ 0.8 lines/s at idle with no joiner attached**
(tags: `[p2p]` 13, `[vk-ws]` 9, `[auth]` 4, `[config]` 3, `[relay]` 1,
`[obf]` 1). At that rate the log wrapper is not a CPU concern and does
not need marker-only filtering. **Caveat:** this is the *idle* rate;
the rate under an attached joiner passing real traffic is still
unmeasured and is the number that actually sizes the wrapper — measure
it during the first supervised live run.

### Second gate — joiner against a headless-created call: **PASSED 2026-09-03**

Ran the creator on the Mac, handed the join link to the iPhone app (via
clipboard — the link is key material and was never printed), and browsed.

Hard evidence from the creator's own log, i.e. completed round trips
rather than "it connected":
```
TUNNEL CONNECTED
[relay] tunnel DC open (readyState=open)
[dc] CONNECT 15 -> 8.8.x.x:443
[dc] CONNECTED 15 -> 8.8.x.x:443
[dc] conn 15 closed, sent 4018 bytes
[dc] conn 18 closed, sent 10460 bytes
```
**4 completed connections, 22 497 bytes relayed** (10 CONNECTs issued,
4 reached CONNECTED; the rest were genuine upstream refusals, e.g. an
IMAP attempt answered `connection refused`). This is the exact signal
that was *absent* in Phase 0's broken Telemost run, where 884 CONNECT
attempts produced **zero** completion lines — so it discriminates a
working tunnel from a connected-but-dead one.

**Both tunnel modes work.** The log shows `mode=dc` and `mode=video`
state transitions, and the user confirmed functional browsing in both.
Precision on the evidence: byte-level accounting (`closed, sent N
bytes`) is emitted only on the `[dc]` path, so DC mode is attested by
measured bytes while video mode is attested by connection-state
transitions plus the user's functional observation — not by a byte
count.

**Self-healing confirmed, and it validates a design decision.** The
tunnel dropped once (`Participant … hung up`) and the creator
re-established it unattended (`connection state: connecting → connected`,
3 connect transitions over the session, 257 log lines total). This is
the empirical basis for P1 shipping **no watchdog verb** — procd
respawn plus the binary's own reconnect is sufficient.

**Incidental finding relevant to P2:** the phone resolved DNS via
**DoH to 8.8.x.x:443 through the tunnel**. When P2 routes creator
egress into the amnezia policy plane, client-side DoH will bypass that
policy — the same failure mode already recorded in project memory as
"Browser Secure DNS breaks direct-default". P2 must account for it.

**Still NOT proven** (do not let the PASS overstate itself):
- Long-run stability — the spike runs were 45 s and the joiner session
  a few minutes; the production service runs for days.
- Anything about arm64/the router. This was a host (darwin/arm64) build.
- Whether sustained call creation over days draws challenges; 3 calls
  in ~2.5 minutes did not. Note those 3 calls are now abandoned on the
  account.

Logs were shredded after extraction (they contain join links, which are
key material) and the test binary removed.

---

### Original gate rationale (kept for the record)

**Phase 0 never ran `headless/vk` in creator mode.** It ran
`relay/main.go --mode vk-video-creator` (browser-bridged) on the Mac
and the native iOS app (the *joiner* path). The native headless
*creator* — what this whole design packages — has never been executed
by anyone in this project.

**Newly established by reading the source (was previously an open
risk):** `headless/vk/` contains **no captcha handling whatsoever** —
`grep -rn captcha headless/vk/` returns nothing. The captcha flow
(`StartCaptchaProxy`, the `CAPTCHA:http://127.0.0.1:<port>/` prompt)
exists only in `relay/pion/headless-joiner-common/{vk_auth,captcha_proxy}.go`,
i.e. the **joiner** package. So if VK challenges the creator's
`calls.start`/`web_token` request, `CallID` comes back empty →
`log.Fatalf` → process exit, with no interactive recovery path in this
binary at this SHA. The consequence is therefore **terminal, not
merely reshaping**: procd would respawn, fail identically, and give up.

The spike is what decides whether VK actually challenges this account,
which is a per-account/per-behaviour fact no amount of source reading
can settle.

### How to run it safely

```sh
cd /Users/jonnik/amnezia-external/whitelist-bypass/headless/vk
go build -o /tmp/hvk .
/tmp/hvk -cookies /path/to/your/vk-cookies.json > /tmp/hvk.log 2>&1
# let it run ~60s, then Ctrl-C
```

**Report back only these derived facts — never the log itself:**

```sh
# 1. did it create a call?
grep -c "CALL CREATED" /tmp/hvk.log
# 2. did it reach the SFU websocket?
grep -c "vk-ws\] Connected" /tmp/hvk.log
# 3. any challenge/captcha/rate-limit signal?
grep -ic "captcha\|challenge\|too many\|flood\|rate" /tmp/hvk.log
# 4. did it die, and on what class of error? (error TEXT only, no response bodies)
grep -oE "Failed to create call|Cannot read cookies|Cannot parse cookies|empty (VK token|call_id|ok_join_link)" /tmp/hvk.log | sort | uniq -c
```

Those four counts are all I need. **Do not paste the log**, and note
that `/tmp/hvk.log` itself now contains an access token if run #4
matched `empty VK token` — delete it (`rm -f /tmp/hvk.log`) when done.

Run the whole thing **3 times** (a crash loop would do this in
production) to see whether repeated call creation from the same
account starts drawing challenges.

**One more step, which closes a second unknown for free:** Phase 0
proved the iOS/Mac joiner works against a **GUI-created** call. Whether
it attaches to a **headless-created** call is independent and currently
scheduled as a post-build live gate. Since you have both halves on hand:
take the `join_link` the spike printed, paste it into the existing
joiner app, and load a page. If that works, the end-to-end question is
settled before any packaging work starts rather than after.

If the spike shows challenges, Phase 1 does not proceed in this shape
— the headless creator cannot run unattended, full stop.

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

## Egress restriction

The creator is, by construction, an unauthenticated exit relay: anyone
holding the VK call link can join and route traffic through it. Left
unrestricted that traffic reaches not just the internet but the
router's own admin plane and the whole LAN — SSH on `:2323`, LuCI,
dnsmasq, every LAN host.

**Cycle-2 correction.** The previous revision's rule was wrong in four
independent ways, all verified: it rejected `127.0.0.0/8`, which is
where this router's own resolver lives (`/etc/resolv.conf` on the
device reads `nameserver 127.0.0.1` + `nameserver ::1`, confirmed by
inspection), so the creator could never resolve `login.vk.ru` and the
feature could not start at all; it was IPv4-only while LuCI, dropbear
and dnsmasq all bind dual-stack; it omitted CGNAT (`100.64.0.0/10`,
common on RU ISPs) and link-local; and it used `meta skuid` with a
**name** that nothing in this repo creates — an unresolvable name is a
ruleset **parse error**, and `/etc/nftables.d/*.nft` fragments load
atomically inside `table inet fw4`, so it would have taken the
classifier and the whole firewall down with it. That is a direct
"never break client internet" violation, on a feature that is supposed
to be inert when disabled.

Corrected design, following the **`amnezia-dnsleak-ctl` precedent**
already in this repo (fw4 rules installed by `enable`, removed by
`disable`, never shipped statically):

- The creator runs as a dedicated system user `amnezia-covert`, created
  explicitly at install time (see Installer — this repo has **no**
  existing user-creation infrastructure; `grep -rn "adduser\|useradd" openwrt/ packages/`
  returns nothing, so it is a new, named install step, not an
  assumption).
- The fragment lives as a **template** at
  `/usr/share/amnezia/nftables.d/40-amnezia-covert-egress.nft`,
  mirroring the classifier's existing template/active split. It is
  copied into `/etc/nftables.d/` **only by `amnezia-covert-ctl enable`**,
  and removed by `disable`. It is never shipped into `/etc/nftables.d/`
  by any installer or by `dev/sync-to-packages.sh`, so the `.ipk` and
  `install.sh` paths (where the feature is deliberately inert) cannot
  load it.
- `enable` resolves the **numeric uid** at activation time and
  substitutes it into the template (`@@COVERT_UID@@` → e.g. `1001`),
  exactly like the classifier's `@@LAN_IFNAME@@` substitution. A numeric
  uid cannot fail to resolve at parse time, which removes the
  whole-firewall failure mode rather than merely making it less likely.
- Activation sequence is gated and reversible: write the active
  fragment → **`fw4 check`** (the assembled-ruleset validator; a bare
  `nft -c -f` on a fragment reports false errors, per project rule) →
  on failure, remove the fragment and abort `enable` with a specific
  error, changing nothing; on success, `( sleep 1 && fw4 reload ) &`
  backgrounded, because a foreground `fw4 reload` can drop the SSH
  session that is the recovery channel.
- The rule itself, with DNS explicitly permitted first:
  ```
  chain amnezia_covert_egress {
      type filter hook output priority filter; policy accept;
      meta skuid @@COVERT_UID@@ udp dport 53 ip daddr 127.0.0.1 accept
      meta skuid @@COVERT_UID@@ tcp dport 53 ip daddr 127.0.0.1 accept
      meta skuid @@COVERT_UID@@ ip  daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, 127.0.0.0/8 } reject
      meta skuid @@COVERT_UID@@ ip6 daddr { ::1/128, fc00::/7, fe80::/10 } reject
  }
  ```
- Coverage rationale, restated correctly (the previous wording — "a
  kernel-level userspace socket relay" — was incoherent): every flow
  the joiner asks for is dialled **by the creator process itself**
  (`relay/tunnel/relay_bridge.go` uses `net.DialTimeout`/`net.DialUDP`
  in-process), so those sockets carry the creator's uid and the
  `hook output` uid match covers joiner-forwarded traffic as well as
  the creator's own.
- **Known accepted limitation:** this also rejects WebRTC ICE
  host-candidate checks toward LAN peers. Irrelevant here — the joiner
  is remote and reaches the router via the SFU, never as a LAN peer.
- Threat model, stated plainly: anyone with the link gets **router-IP
  internet egress**. Link secrecy is the only admission control in P1.
  The link is additionally **key material** — `main.go:718` derives the
  tunnel obfuscation secret from it via
  `tunnel.DeriveSecretFromJoinLink` — so it is handled as a secret
  everywhere it is stored (see Secrets). A dedicated/disposable VK
  account is recommended over the user's primary one.

---

## Components

### Upstream source pinning & build

Source: `github.com/kulikov0/whitelist-bypass`, pinned to commit
`89d7a474b7aca6cce664280e6feeaeca2706733b` — the tree Phase 0 built
from, **not** proof the creator-mode binary works (that is the
Prerequisite's job). Bumping means: re-clone, re-run the Prerequisite
spike, update the pin.

**Why not commit the binary or vendor the Go source:** this repo is
POSIX-sh-only by convention, and upstream's git history carries large
committed Android binaries (the reason Phase 0 used a sparse+partial
clone). A new `dev/build-covert-creator.sh` builds it into a gitignored
`build/` (which must be **added to `.gitignore` as part of this phase** —
it is not there today).

Per the project rule that a spec must not carry code it cannot run,
what follows is the **contract**, not a script body to copy verbatim —
the executor writes it and runs it for real:

- **Must set `GOOS=linux GOARCH=arm64 CGO_ENABLED=0`.** Cycle 2 caught
  their absence: without them the build silently produces a darwin/arm64
  Mach-O on the dev Mac and then fails its own ELF assertion. (The
  earlier "11 MB, static, stripped, ARM aarch64" measurement in
  Background §1 came from a manual build with these variables set, not
  from the script as it was written.)
- **Sparse checkout must include `relay/` as well as `headless/vk`.**
  Verified: `headless/vk/go.mod:11` is
  `replace whitelist-bypass/relay => ../../relay`, so a checkout of
  `headless/vk` alone cannot build. The Prerequisite spike does not
  catch this, because the local clone is already full.
- Assert the checkout landed on the pin (`git rev-parse HEAD` == pin)
  rather than assuming a blobless clone fetched an arbitrary SHA.
- Assert the artifact: `file` reports a **static ARM aarch64** ELF.
- Checksum with a command that exists on macOS — `shasum -a 256`, not
  `sha256sum` (cycle 2: the script runs on the dev Mac, where
  `sha256sum` does not exist and `set -eu` would abort).
- Emit `BUILD_MANIFEST` (upstream SHA, Go version, artifact sha256)
  **and install it to the router** alongside the binary — the previous
  revision produced it only on the Mac, leaving `status.build_sha` with
  no data source on the device.
- Upstream's own `build-headless.sh` at the repo root is the sibling
  reference for the build invocation; read it rather than reconstructing
  the command.

### UCI state (`/etc/config/amnezia`, `config amnezia 'config'`)

```
option covert_enabled  '0'   # opt-in, default off
```

`covert_resources` was dropped in the previous revision (dead knob).
`covert_cookies_path` is **also dropped now**: cycle 2 showed it was
only half-wired and could not be fully wired — the rpcd ACL `write`
grant is path-exact, so a relocated path makes LuCI's Save button fail
with a permission error while the init happily reads the new location.
The cookie path is a fixed constant
(`/etc/amnezia/covert/vk-cookies.json`), documented, matching how
`dot_resolver` and friends are handled (backend-only where they can't
be exposed coherently).

### Secrets

**Verified live against the router**, not assumed: `ubus -v list file`
returns `"exec":{"command":"String","params":"Array","env":"Table",...}`
— **no stdin channel**, so the original stdin-based design was
unbuildable. But `"write":{"path":"String","data":"String","mode":"Integer",...}`
exists, and the device's own `/www/luci-static/resources/fs.js` exposes
it as `write: function(path, data, mode)`. That is the mechanism.

- LuCI's "Save cookies" button calls
  `fs.write('/etc/amnezia/covert/vk-cookies.json', value, 0o640)`
  directly — the cookie is written by rpcd in one ubus call, never
  passed as a CLI argument, so it never appears in `ps`.
- **Ownership model (cycle-2 CRITICAL fix).** The previous revision
  specified `0700 root:root` dir + `0600 root:root` file *and* ran the
  process as unprivileged `amnezia-covert` — mutually exclusive; the
  process would get EACCES and `common.LoadCookies` (`relay/common/http.go:14`)
  would `log.Fatalf("Cannot read cookies: %v")` into a respawn loop.
  Corrected: directory `/etc/amnezia/covert/` is **0750 root:amnezia-covert**,
  the cookie file **0640 root:amnezia-covert**. rpcd writes as root;
  `amnezia-covert-ctl apply` re-asserts `chown root:amnezia-covert` +
  `chmod 0640` after any write, since the rpcd `mode` param sets
  permissions but not group ownership.
- **Cookie file format (was deferred, is readable — `relay/common/http.go:14-30`):**
  a JSON array of `{"name": "...", "value": "..."}` objects. The
  preflight validator therefore checks: file exists, non-empty, parses
  as JSON, is an array, and every element has non-empty `name` and
  `value`. That is a structural check only — it never dials VK, so it
  cannot itself leak or lock anything.
- **Transport caveat, stated rather than glossed:** the textarea POSTs
  the cookie over the LuCI HTTP session, and stock OpenWrt serves LuCI
  on plain `:80` unless `luci-ssl` is installed. On a trusted LAN this
  is the same exposure as every other LuCI credential field; if that is
  not acceptable, the alternative is `scp` to the router over the
  existing `:2323` SSH channel and skipping the UI for this one field.
  Decide at execute time; do not leave it unstated.
- **The join link is key material too** (`main.go:718`, see Egress
  restriction). Every place it lands gets a secret's treatment:
  `-write-file` target and the state JSON are **0640 root:amnezia-covert**,
  and the capped log file likewise. Note `-write-file` opens
  `O_APPEND|O_CREATE, 0644` (`main.go:709`) — it **appends** across
  restarts and creates world-readable — so `amnezia-covert-ctl` must
  pre-create the file with the intended mode and truncate it on each
  service start; the mode is not something the binary will set for us.

### New CLI `/usr/bin/amnezia-covert-ctl`

POSIX sh, sources `amnezia-common.sh`, `uci -q get` throughout.

- **`enable`** → preflight in this order, with **no `uci set` before it
  completes** (cycle 1: `uci` staging is process-shared in `/tmp/.uci/`,
  so even an uncommitted `set` can be flushed by another amnezia CLI's
  commit): binary present; `amnezia-covert` user exists; cookie file
  passes the structural check above; `MemAvailable` above threshold.
  Then: install the nft fragment with uid substitution → `fw4 check` →
  on failure remove it and abort → `uci set covert_enabled='1'; uci commit amnezia`
  → `/etc/init.d/amnezia-covert enable && /etc/init.d/amnezia-covert restart`
  (init `enable` **before** `restart`: a bare `restart` on a
  not-yet-enabled procd service is a silent no-op, a bug this project
  has already shipped once with stubby/https-dns-proxy) →
  `( sleep 1 && fw4 reload ) &`.
- **`disable`** → stop + init-disable the service, remove the nft
  fragment, backgrounded `fw4 reload`, remove state/link files,
  `covert_enabled='0'`, commit. Idempotent: disabling an
  already-disabled feature is exit 0. Cookie file is **not** deleted.
- **`apply`** → idempotent reconcile used by boot init and `enable`.
  `covert_enabled=0` ⇒ ensure stopped, exit 0. `covert_enabled=1` ⇒
  same preflight; on failure, log the specific reason, leave
  `covert_enabled` untouched, do not start, and make `status` report it
  (never a silent no-op). Missing binary ⇒ loud, distinct failure whose
  text names the dev-deploy-only caveat.
- **`status`** → reads `/var/run/amnezia-covert/state.json` plus procd's
  running bit; emits exactly one JSON object on stdout:
  ```json
  {"enabled":true,"running":true,"state":"connected",
   "link":"https://vk.com/call/join/XXXX","link_age_s":42,
   "reason":"","build_sha":"89d7a474","build_hash":"ab12cd34"}
  ```
  `state` ∈ `idle | starting | connected | auth-failed | crashed | not-started | unknown`.
  **`build_sha`/`build_hash` are read from the installed
  `/etc/amnezia/covert/BUILD_MANIFEST`** — never recomputed. Cycle 2
  caught that the previous spec would `sha256sum` an 11 MB file on every
  5-second LuCI poll.

  **Truth table** (every combination defined — cycle 2 found the
  previous one incomplete):

  | enabled | running | state | link | when |
  |---|---|---|---|---|
  | false | false | `idle` | `null` | feature off |
  | true | true | `starting` | `null` | started, no `CALL CREATED` marker yet |
  | true | true | `connected` | url | call created + ws connected, heartbeat fresh |
  | true | true | `unknown` | last known | running but heartbeat stale past the window |
  | true | false | `auth-failed` | `null` | preflight/auth failure, `reason` set |
  | true | false | `crashed` | `null` | procd respawn budget exhausted |
  | true | false | `not-started` | `null` | readiness gate never satisfied |

  `link` is JSON `null` (not `""`) when absent, and `link_age_s` is
  `null` alongside it. Exit code is 0 whenever a JSON object was
  produced — errors are represented *in* the JSON via `state`/`reason`;
  non-zero only on a genuine CLI-internal failure, which LuCI treats as
  a distinct "CLI broken" case.

No `set-cookies` verb (the write is LuCI-direct via `fs.write`). No
watchdog verb in P1.

### Run wrapper, state file, and why not `logread`

Cycle 1 established the problem: `amnezia-autotunnel.sh` reads the
**entire** logd ring every minute, and this router has already been
hard-reset once by autolearn load. Sending a chatty WebRTC process's
output into the shared ring risks evicting the lines autotunnel needs,
silently. Cycle 2 then found the previous revision's fix contradicted
itself — the init snippet still set `procd_set_param stdout 1 / stderr 1`
(which *is* "send to syslog"), and `procd_append_param command 2>&1`
appends nothing at all (the shell eats `2>&1` as a redirection of the
`procd_append_param` call itself). `procd_set_param command` is exec'd
without a shell, so a pipe cannot be expressed there.

**Resolved by making the instance a launcher script**, which is also
where three other cycle-2 findings land:

`/usr/lib/amnezia/amnezia-covert-run.sh` is what procd execs. It:
1. Truncates `state.json` and the link file **here**, in the launcher —
   not in `start_service`. procd does not re-run `start_service` on a
   respawn, it re-execs the instance command, so truncation in
   `start_service` would leave the previous generation's `connected`
   state and link visible after a crash. (The previous revision claimed
   staleness was "structurally impossible"; it was not.)
2. Runs the **readiness wait here**, not in `start_service`. A blocking
   wait inside `start_service` stalls the serial rc boot sequence and
   stalls the LuCI `enable` click under rpcd's RPC timeout. In the
   launcher, procd already considers the service running, so waiting is
   free. On timeout it writes `state: "not-started"` with a reason and
   exits.
3. Enforces the **call-creation gap here**. Cycle 2 correctly found the
   log-wrapper could never do this — it is a downstream pipe consumer,
   not the parent of the next exec. The launcher records the last
   call-creation timestamp and sleeps out the remainder of a 120 s gap
   before exec'ing. Belt and braces: `procd_set_param respawn 300 120 5`
   puts the same 120 s in procd's own **respawn delay** field (the
   second field is the delay, not a window — the previous revision's
   comment misread it; `respawn 300 5 5` would have allowed ~5 real VK
   calls in ~25 s).
4. Finally `exec`s the creator with stdout+stderr piped into the log
   wrapper:
   `exec /usr/bin/amnezia-covert-creator -cookies ... -write-file ... 2>&1 | amnezia-covert-logwrap.sh`

`amnezia-covert-logwrap.sh` appends to a capped, dedicated
`/etc/amnezia/covert/covert.log` (flash, like the blackbox logger — not
tmpfs, so it survives reboot for diagnosis; capped in the same
size-capped way) and rewrites `state.json` atomically (tmp + `mv`).
**Bounded cost** (cycle-2 finding — the wrapper must not become the new
autolearn): the state file is rewritten **at most once per second**
regardless of marker rate, the cap check runs periodically rather than
per line, and `-debug` stays **off** so the per-SFU-message chatter
(`[vk-ws] <- notification`, `<- response seq=`) is not emitted at all.
The Prerequisite spike's run gives the real steady-state line rate;
if it is high enough to matter, the wrapper filters to marker lines
only and drops the rest.

**Markers are read from source, not deferred** (they were an
unnecessary deferral — cycle 2):

| marker | source | meaning |
|---|---|---|
| `  CALL CREATED` | `main.go:553` | call created |
| `  join_link: ` | `main.go:554` | the link (also the obfuscation secret) |
| `[vk-ws] Connected` | `main.go:583` | SFU websocket up ⇒ `connected` |
| `Failed to create call:` | `main.go:704` | fatal ⇒ `auth-failed` |
| `Cannot read cookies:` / `Cannot parse cookies:` | `relay/common/http.go:17,23` | credential problem ⇒ `auth-failed` |

**Redaction is a hard requirement of the wrapper**, not an afterthought:
`main.go:264` and `:287` emit raw auth-response bodies containing an
`access_token` on the empty-token/empty-call_id paths. The wrapper must
drop or mask any line matching those error shapes before it reaches the
log file. This is the same defect class as the Prerequisite correction
at the top of this document.

### procd init `/etc/init.d/amnezia-covert`

`USE_PROCD=1`, `START=99` (98 is `amnezia-dnsleak`; 97 `amnezia-dns`;
96 force-load/ru-load; 95 failover — verified). Sources
`amnezia-common.sh` like the other inits. `start_service`:

- reads `covert_enabled` via `config_get`; returns immediately if `0`,
  so a default-OFF feature never starts at boot;
- creates `/var/run/amnezia-covert/` **owned by `amnezia-covert`** —
  necessary because `/var` → `/tmp` and `/tmp/run` is `0755 root:root`
  on this device (verified), so an unprivileged wrapper could not
  otherwise create its own state file, and `status` would report
  `unknown` forever;
- opens the instance with `command /usr/lib/amnezia/amnezia-covert-run.sh`,
  `user amnezia-covert`, `respawn 300 120 5`;
- **does not set `stdout`/`stderr`** — explicitly, because the whole
  log-starvation mitigation depends on the output going to the wrapper
  and not to logd.

**Respawn exhaustion** (5 deaths) leaves `covert_enabled='1'` — "on but
visibly broken" is preferred over silently self-disabling a user's
explicit opt-in — and `status` reports `crashed` with a reason naming
respawn exhaustion, never `idle`.

### Memory handling

`-resources moderate` maps to `debug.SetMemoryLimit(64MB)`
(`main.go:638-668`) — a **soft** GOMEMLIMIT target, not an RSS cap.

**Cycle-2 correction:** the previous revision claimed
`procd_set_param limits as=128000000` was "a hard RSS ceiling". It is
not. `RLIMIT_AS` caps *virtual address space*; `RLIMIT_RSS` is a no-op
on Linux. A Go runtime plus pion/DTLS/SRTP/QUIC/KCP reserves far more
address space than it resides, so a 128 MB `as` limit is a realistic
hard startup failure on the router while working fine on the Mac — the
named mitigation would have broken the feature. It is **dropped**.

What remains, stated honestly rather than overclaimed:
- GOMEMLIMIT at 64 MB via `-resources moderate` (soft, real, verified in
  source).
- A `MemAvailable`-based preflight in `apply`/`enable` (from
  `/proc/meminfo`, not `free -h`), refusing to start below a threshold
  pinned against a live measurement.
- **First live enable is foreground-supervised** under real joiner
  traffic, not idle — RSS for a DTLS/SRTP stack differs substantially
  between the two.
- Honest residual: the OOM killer is not obliged to pick the creator,
  and if it takes dnsmasq this project has a documented
  non-self-healing path (`amnezia_force4` corruption). `disable` cleanly
  rolls back *this feature's* state; it is not a guaranteed recovery
  for whatever else an OOM event already hit. If live supervision shows
  real pressure, the answer is a cgroup `memory.max`, specified and
  measured then — not a wrong rlimit asserted now.

### LuCI UI

Rendered **outside** `#amz-accordion`, as its own block next to the
master-state strip — the accordion carries
`.amnezia-master-off { pointer-events:none }` when master is OFF, which
would otherwise make a supposedly master-independent toggle
unclickable. Because it sits outside the
`.amnezia-accordion details.amnezia-panel` CSS scope, it needs its own
matching styles or it will look unlike every other panel.

New module `amnezia.section.covert`, added to `main.js`'s require list +
`Object.assign` handler map, its `refresh()` folded into the existing
`Promise.all`, and a `main.load()` entry at **index 14** (verified: the
`DATA` array currently holds indices 0–13, 12 = tunnel apps,
13 = autotunnel — so first paint shows real state instead of a blank
default, per the DoT precedent). All exec calls `L.resolveDefault`-wrapped
so a rejection cannot blank the whole page.

- Enable/disable toggle → `handleCovertToggle` (`ctlThenRefresh` shape).
- Cookie `<textarea>` (write-only, never pre-filled) + "Save cookies" →
  `fs.write()` directly, then a separate `handleCovertApply` →
  `amnezia-covert-ctl apply` so the CLI's structural validation runs
  against what was just saved.
- Status via a **new `covertStateColor()`** in `util.js` — not a new arm
  on the shared `verdictColor`, whose only two callers are in
  `zapret.js` and whose arm set must not move (the "adding a caller to
  a shared classifier makes a dead default arm live" trap).
- Join-link row with copy affordance and `link_age_s`, shown only when
  `state === "connected"`.
- Handlers wired with an extra arg are declared `function(extraArg, ev)`
  — `createHandlerFn` passes the event **last**.

**ACL** (`openwrt/luci-app-amnezia/acl/luci-app-amnezia.json`,
`write.file` block) needs **both**:
```json
"/usr/bin/amnezia-covert-ctl":                [ "exec" ],
"/etc/amnezia/covert/vk-cookies.json":        [ "write" ]
```

**Harness extension — enumerated mechanically** (`grep -n "'dns'\|section/dns" test/lib/luci-harness.js`),
because the previous revision's "six places" list was a recollection
that missed the two sites that make the module resolve at all. The real
sites are **8**: lines **77** (`names` DI array), **90**, **116**, **126**,
**160**, **164**, **217**, **297** — plus the `DATA` fixture (line 72)
which must gain index 14. Missing line 77 binds `covert` to `undefined`
inside every module and produces exactly the blank-panel failure the
harness exists to catch, while still printing green.

### Installer / packaging

**Binary delivery is dev-controlled only in P1.** Verified constraints:
`install-amnezia-pbr.sh` runs **on the router** and only reads from
`/tmp/<staged>`; `install.sh` fetches a GitHub **source tarball**, which
can never contain a gitignored build artifact; the `.ipk` declares
`PKGARCH:=all`, which cannot legitimately carry an aarch64 ELF.

Delivery, following the repo's actual staging convention (cycle 2:
`dev/deploy-openwrt-safe.sh` does not place files itself — it stages to
`/tmp` and lets the installer place them):
1. `dev/build-covert-creator.sh` produces the binary + `BUILD_MANIFEST`
   locally into gitignored `build/covert/dist/`.
2. `dev/deploy-openwrt-safe.sh` gains explicit entries in its
   hand-maintained upload list to stage both to `/tmp/`.
3. `install-amnezia-pbr.sh` places them (`/usr/bin/amnezia-covert-creator`,
   `/etc/amnezia/covert/BUILD_MANIFEST`), verifies the sha256 against
   the manifest, `chmod +x`, and **removes the staged copy** — `/tmp` is
   tmpfs, i.e. 11 MB of the same RAM budget this design worries about.
4. The installer also **creates the `amnezia-covert` user/group** (new
   infrastructure for this repo) and `/etc/amnezia/covert/` at
   `0750 root:amnezia-covert`, both **before** anything can load the nft
   fragment.
5. CLI, libs, init, template fragment and ACL ship through the normal
   four-surface convention. On `install.sh`/`.ipk` the feature installs
   **inert**: no binary ⇒ `apply` fails loudly with text naming the
   dev-deploy-only caveat, and the nft fragment is a template that
   `enable` never gets far enough to activate.

**Live-router caveat.** `dev/deploy-openwrt-safe.sh` runs
`install-amnezia-pbr.sh` on the router, and CLAUDE.md's live-router rule
says a manually-cutover router must be updated by placing specific
changed files rather than re-running the postinst installer. For this
router the deploy is therefore **surgical**: stage the files, place them
by hand with a snapshot of anything replaced, and verify WAN + DNS +
handshake after each step. The installer path is what the `.ipk`/fresh
installs use.

**Uninstall/rollback** (was missing entirely): `disable` stops the
service and removes the fragment, state and link. Full removal
additionally drops the binary, `/etc/amnezia/covert/`, the UCI key, the
init, the ACL entries and the system user — specified as an explicit
documented sequence so a future `--migrate` or rollback run has one.

---

## Testing

bats unit tests, with the `uci` stub in the **exact real quoted format**
and modelling `set` (staged) separately from `commit` — without that,
test 1's assertion is unobservable:

1. `enable` with no/invalid cookie file → refuses; **no `uci set` at
   all** (not merely no commit).
2. `enable` happy path → fragment written with the numeric uid
   substituted, `fw4 check` invoked **before** any reload, then
   init `enable` **then** `restart`, in that order. *Mutation: swap
   enable/restart → must go red.*
3. `enable` when `fw4 check` fails → fragment removed, no UCI mutation,
   non-zero exit, firewall untouched. *Mutation: skip the check → red.*
4. `disable` idempotent; removes fragment + state + link; leaves cookies.
5. Cookie structural validator: rejects non-JSON, non-array, and
   elements missing `name`/`value`; accepts the real shape. *Mutation:
   accept-anything → red.*
6. `status` truth table — every row, including `not-started` and
   `unknown`; `link` is `null` not `""` when absent. *Mutation: make
   `running=false,enabled=true` return `idle` → red.*
7. Log wrapper: fed captured spike output, produces the right states;
   **redacts** the `empty VK token, response:` / `empty call_id,
   response:` lines. *Mutation: remove the redaction filter → a test
   asserting no token-shaped string reaches the log must go red.*
8. Log wrapper truncates state+link on **launcher** start, so a
   simulated respawn cannot surface the previous generation's link.
   *Mutation: move truncation back to `start_service` → red.*
9. Call-creation gap enforced in the launcher. *Mutation: remove the
   sleep → red.*
10. ACL contains both the `exec` and the `write` grants.
11. `test/unit/luci-js.bats` passes with the covert module wired into
    all 8 harness sites + the `DATA` fixture.

**Live-only gates:**
- The Prerequisite spike (the actual go/no-go).
- `fw4 check` passes with the fragment on the real assembled ruleset,
  and WAN + DNS + tunnel handshake all survive `enable` and `disable`.
- The creator, running as `amnezia-covert`, can resolve DNS (proving the
  port-53 accept works) but **cannot** reach `192.168.1.1:80` or
  `:2323` (proving the reject works).
- Joiner attaches to the router-created call and loads a page (proven
  on the Mac 2026-09-03; re-confirm once the creator runs on the router).
- `MemAvailable` under sustained joiner traffic, foreground-supervised.
- Reboot with the feature enabled → comes back up unattended.

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| **Headless creator has zero captcha handling — a VK challenge is terminal** (verified: no captcha code in `headless/vk/`; it exists only in the joiner package) | Blocking Prerequisite spike; if challenges appear, P1 does not proceed in this shape |
| Spike log itself can contain an `access_token` on the auth-failure path (`main.go:264,287`) | Prerequisite reports only derived counts, never raw logs; log wrapper redacts these lines on the router |
| Join link is the tunnel obfuscation secret, not just an admission token (`main.go:718`) | Treated as a secret everywhere: 0640 files, no world-readable `-write-file` default, not logged unredacted |
| Unresolvable `meta skuid <name>` would break the **entire** fw4 ruleset | Numeric uid substituted at `enable` time; template never shipped into `/etc/nftables.d/`; `fw4 check` gate with fragment rollback; backgrounded reload |
| Egress rule blocking `127.0.0.0/8` would kill the creator's own DNS | Explicit port-53-to-127.0.0.1 accepts ahead of the rejects; live gate proves both directions |
| Unauthenticated exit relay reachable by anyone with the link | uid-scoped reject of RFC1918 + CGNAT + link-local + v6 ULA/loopback; link treated as a secret; dedicated VK account recommended |
| Unprivileged user cannot read its own credential | Dir 0750 / file 0640, both `root:amnezia-covert`; `apply` re-asserts ownership after every rpcd write |
| Unprivileged user cannot write its state file (`/tmp/run` is 0755 root) | `start_service` pre-creates `/var/run/amnezia-covert/` owned by the service user |
| Crash loop = call-creation storm on a personal VK account | 120 s gap enforced in the launcher **and** in procd's respawn-delay field |
| `limits as=` is virtual address space, not RSS, and can block Go startup | Dropped; GOMEMLIMIT + `MemAvailable` preflight + supervised first run, with the residual stated plainly |
| Log wrapper becoming the new autolearn-style CPU sink | `-debug` off, ≤1 state rewrite/sec, periodic (not per-line) cap check, marker-only filtering if the spike shows high line rates |
| Stale `connected` + dead link surviving a respawn | Truncation in the launcher (which procd *does* re-exec), not `start_service` |
| Harness green while not covering the new module | All 8 enumerated sites + `DATA` index 14, derived by grep, not memory |
| `status` hashing an 11 MB binary every 5 s | Manifest installed to the router; `status` reads it, never recomputes |
| Cookie crosses the LAN over plain HTTP LuCI | Stated explicitly; `scp`-over-SSH alternative named if unacceptable |
| Shared `/etc/config/amnezia` has no cross-CLI commit lock | Accepted, scoped: covert-ctl's writes are click-initiated; no timer-driven writer competes (verified: autotunnel's per-minute worker performs no `uci set`; the DNS watchdog commits only on tier transitions). Residual named: covert-ctl's `commit` can flush another CLI's staged sets — notably `amnezia-failover-ctl make-default`'s multi-`set` loop. Preflight strictly before any `set`, single uninterrupted set+commit |
| Binary can't reach the router on `install.sh`/`.ipk` paths | P1 scope is dev-deploy-only; other paths install inert with a loud, specific error |

---

## Open items for the plan

Only genuinely unresolvable-before-execution items remain (the previous
revision deferred several things that were readable in source; those are
now inline above):

- ~~The Prerequisite spike's counts~~ — **done, PASSED**, see above.
- ~~Steady-state log line rate~~ — **measured**: 0.8 lines/s idle;
  ~257 lines over a few-minute joiner session (≈1–2 lines/s under
  traffic). Well below any level that would need marker-only filtering.
- ~~Joiner attachment to a headless-created call~~ — **done, PASSED**,
  both DC and video modes; see above.
- `MemAvailable` threshold and the readiness-gate timeout — pinned
  against live measurement on the router.
- The state-file staleness window for `unknown`.
- Whether the LuCI-over-HTTP cookie transport is acceptable, or the
  `scp` path is used instead.
