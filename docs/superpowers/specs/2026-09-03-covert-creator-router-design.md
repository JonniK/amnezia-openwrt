# Covert-Transport Creator on Router (Phase 1) — Design

**Date:** 2026-09-03
**Branch:** `feat/covert-creator-router`
**Status:** design-review cycles 1–6 complete. Cycle 1: 8 C / 15 H.
Cycle 2: ~15 C / ~28 H. Cycle 3: 1 C / 2 H / 6 M / 6 L. Cycle 4:
2 C / 3 H / 5 M / 6 L. Cycle 5: 0 C / 2 H / 2 M / 4 L. **Cycle 6: 1 C**
(one opus lens; the second lens and the external codex both hit a
content-safeguard filter on this material — a tooling limit, not a
finding). The cycle-6 CRITICAL was **live-verified on the router**: the
cycle-5 `pkill -u` reap is unrunnable — `pkill` is absent on this BusyBox
(only `pgrep`, no `-u`; `ps -o` unsupported), so the orphan-reap silently
no-op'd. Now a `/proc`-scan helper (`amz_covert_reap`, mechanism verified
present on the router), with `apply` reaping only on the (re)start path so
it never kills a healthy creator, and Test 4 exercising the real helper
rather than a stubbed `pkill` (the "stubs must mirror real tools" trap).
The lens also confirmed the other cycle-5 fixes hold on the router
(combined egress rule, truncate-in-place cap, readiness-timeout ordering).
Criticals across cycles: 8→15→1→2→0→1, each a smaller, more localized
defect in the prior cycle's fix. **A cycle 7 is required** to confirm the
`/proc`-scan swap introduced nothing. Every claim is read from upstream
source or measured on the router, not asserted from memory. **Prerequisite spike PASSED
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
> that carries `access_token`; `main.go:286`/`:289` do the same for the
> `calls.start` body (and `authAndJoin` dumps six more bodies at
> `:133`/`:145`/`:156`/`:159`/`:180`/`:197`, `:133` and `:180` carrying an
> access_token and a session_key — see the Redaction section for the full
> nine and the generic fix). These reach stdout via `log.Fatalf`
> (`main.go:704`/`:699`) or `log.Printf("[rejoin] Failed…")` (`:606`) and
> none is wrapped in `common.MaskError`, which the code *does* use
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
- **Cycle-3/4 correction — reject by OUTPUT INTERFACE, not by address
  set.** Two review cycles found the destination-set approach leaks the
  admin plane once per cycle: cycle 3 caught IPv6 **Global Unicast
  (`2000::/3`)** left open (the router's own GUA + LAN GUAs reachable on a
  v6-prefix-delegated router); cycle 4 caught that even the v4 set omits
  **the router's own public WAN IP** — and that IP is *the joiner's own
  egress IP*, so `CONNECT <egress-ip>:2323` → SSH / `:80` → LuCI is
  trivial, because a packet destined to any of the router's **own**
  addresses is routed out `lo` and delivered locally (the WAN-input reject
  never sees it). Cycle 4 also found that a *blanket* `meta nfproto ipv6
  reject` (cycle 3's fix) would **brick the SFU dial**: `connectVKWs`
  (`main.go:479-483`) resolves the signalling host and pins `ips[0]` with
  **no v4 fallback**, dialling it as QUIC/UDP via `wtsignal.Dial`
  (`wtsignal.go:75`) — not a Happy-Eyeballs TCP dial — so if the resolver
  returns a v6 address first the QUIC dial hits the reject and retries
  that same v6 address forever.
  Both holes and the SFU-brick dissolve together by matching on the
  **egress interface** the kernel actually chose, which is stack-agnostic
  and renumber-proof: everything the kernel delivers locally (any of the
  router's own addresses — loopback, LAN IP, WAN IP, every GUA) routes out
  `lo`; other-LAN-host traffic routes out the LAN bridge; genuine internet
  egress (the SFU dial included, on **either** stack) routes out a WAN
  interface and is left to `policy accept`.
- `enable` resolves **both** the numeric uid **and** the LAN interface
  name at activation time and substitutes them into the template
  (`@@COVERT_UID@@` → e.g. `1001`, `@@LAN_IFNAME@@` → the real LAN bridge,
  read exactly as the classifier reads it). A numeric uid and a real
  ifname cannot fail to resolve at parse time, keeping the
  whole-firewall failure mode closed.
- **uid must be pinned + enforced fail-CLOSED (cycle-3/4).** A uid that
  drifts (user recreated at a different next-free uid on
  reinstall/`--migrate`) makes the active fragment match the *old* uid
  while the process runs as the *new* one → matches **none** of the
  rejects → `policy accept` → the whole restriction silently voids. So the
  installer creates `amnezia-covert` with an **explicit fixed uid/gid**
  (see Installer for the `id`-precheck/collision handling), and
  `enable`/`apply` **and the boot start path** re-resolve the uid,
  re-substitute the template, and **on any mismatch abort/stop the service
  fail-closed** — never merely flag `status` unhealthy while the
  unrestricted relay keeps running (cycle-4 M: the mitigation for a
  security control must fail closed).
- The rule itself, loopback DNS permitted first, then the two egress
  interfaces that reach the router/LAN denied on both stacks:
  ```
  chain amnezia_covert_egress {
      type filter hook output priority filter; policy accept;
      # loopback DNS to the router's own resolver — must precede every reject
      meta skuid @@COVERT_UID@@ oifname "lo" ip  daddr 127.0.0.1 udp dport 53 accept
      meta skuid @@COVERT_UID@@ oifname "lo" ip  daddr 127.0.0.1 tcp dport 53 accept
      meta skuid @@COVERT_UID@@ oifname "lo" ip6 daddr ::1       udp dport 53 accept
      meta skuid @@COVERT_UID@@ oifname "lo" ip6 daddr ::1       tcp dport 53 accept
      # (1) destination-based rejects — private/CGNAT/link-local/multicast,
      #     both stacks: catches the upstream ISP CPE/modem (100.64/10, a
      #     192.168 modem panel), any OTHER internal bridge, and private
      #     tunnel-peer subnets, none of which egress `lo` or the LAN bridge:
      meta skuid @@COVERT_UID@@ ip  daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 } reject
      meta skuid @@COVERT_UID@@ ip6 daddr { fc00::/7, fe80::/10 } reject
      # (2) interface-based rejects — everything the kernel delivers locally
      #     (the router's OWN addresses incl. the public WAN IP and any GUA,
      #     any stack) routes out `lo`; other LAN hosts route out the bridge:
      meta skuid @@COVERT_UID@@ oifname "lo" reject
      meta skuid @@COVERT_UID@@ oifname "@@LAN_IFNAME@@" reject
  }
  ```
  **Cycle-5 correction — belt AND braces, not either/or.** Cycle 4
  *replaced* the destination-set rejects with the `oifname` rejects; cycle
  5 caught that this dropped the RFC1918/CGNAT/link-local coverage cycle 2
  had deliberately added, re-exposing the upstream ISP CPE / double-NAT
  modem and any second internal bridge to a joiner (they egress a WAN
  interface, so neither `oifname` reject catches them). The corrected rule
  keeps **both**: destination rejects (1) close private/CGNAT/other-bridge
  targets stack-agnostically; interface rejects (2) close the router's own
  addresses that a destination list cannot enumerate (the dynamic WAN IP,
  every GUA). `policy accept` then permits only genuine **public** internet
  egress out the WAN interface on **both** v4 and v6 — so the SFU dial
  works whichever stack the resolver picks. Verified by `fw4 check` plus a
  live gate that proves all directions (see Testing): DNS resolves,
  `<router-any-IP>:2323`/`:80` and a private/CGNAT target are refused on
  both stacks, and the SFU/public-WAN path is reachable. **Caveats named:**
  `oif=lo` for locally-destined traffic and the single-`@@LAN_IFNAME@@`
  assumption are the two facts the live gate must confirm on the real
  kernel; if a deployment has additional internal bridges (guest/IoT VLANs)
  each needs its own `oifname … reject` line, though the destination
  rejects (1) already cover their private ranges as a backstop.
- Coverage rationale: every flow the joiner asks for is dialled **by the
  creator process itself** (`relay/tunnel/relay_bridge.go` uses
  `net.DialTimeout`/`net.DialUDP` in-process), so those sockets carry the
  creator's uid and the `hook output` uid match covers joiner-forwarded
  traffic as well as the creator's own.
- **Known accepted limitation:** this also rejects WebRTC ICE
  host-candidate checks toward LAN peers. Irrelevant here — the joiner
  is remote and reaches the router via the SFU, never as a LAN peer.
- Threat model, stated plainly: anyone with the link gets **router-IP
  internet egress**. Link secrecy is the only admission control in P1, and
  because the LuCI `status` JSON returns the link, **LuCI/rpcd access ==
  relay-join capability** — acceptable for the single-admin home-router
  target, stated not assumed. The link is additionally **key material** —
  `main.go:718` derives the tunnel obfuscation secret from it via
  `tunnel.DeriveSecretFromJoinLink` — so it is handled as a secret
  everywhere it is stored (see Secrets). A dedicated/disposable VK
  account is recommended over the user's primary one.
- **Peer-IP metadata in the flash log (cycle-5, accepted):** the
  unconditional `[vk-ws]` SFU-message dumps put unmasked ICE-candidate /
  joiner peer-IP data into `covert.log`. No VK credential leaks this way,
  and the log is `0640` in a `0750` dir — for the trusted-LAN / single-admin
  target this metadata exposure is accepted; a later phase may extend
  `MaskAddr` to the `[vk-ws]` path or drop those lines via marker-only
  filtering.

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
  restriction), and — **cycle-3 correction** — it is written to the log
  file **in the clear** at `main.go:554` (`  join_link:`, deliberately
  kept as the state marker the wrapper parses) and again at `main.go:722`
  (`[obf] key-source=…`). It is **not** redacted there and cannot be:
  `:554` is the marker `status` needs. So the link in `covert.log`, the
  `-write-file` target, and `state.json` is protected by **file mode, not
  redaction** — the earlier risk-table wording "not logged unredacted"
  was false and is corrected.
- **Ownership + WHERE each process-written file lives (cycle-3/4
  corrections to a contradiction).** All process-written files are created
  by the launcher/log-wrapper, which run **as `amnezia-covert`** (procd
  `user amnezia-covert`); they are all `0640 amnezia-covert:amnezia-covert`
  (not `root:…` — an unprivileged process cannot create a root-owned file,
  and a `0640 root:amnezia-covert` file gives the group only `r--`, so the
  wrapper could not even write its own state; the cycle-2/3 `root:…` claim
  was unmet). But **creating** a file needs **write on the directory**, and
  cycle 4 caught that the flash dir `/etc/amnezia/covert/` is
  `0750 root:amnezia-covert` (group `r-x`, **no write**) — so the
  unprivileged wrapper gets EACCES creating a file there. Resolution splits
  by directory:
  - **`/var/run/amnezia-covert/`** is created by `start_service`
    **owned by `amnezia-covert`** (see procd init), so the process creates
    freely there. `state.json`, `last-call.ts`, and the **`-write-file`
    link target** live here — all ephemeral, all regenerated each start.
    The launcher pre-creates the link target `0640` and truncates it on
    start (the binary's `-write-file` opens `O_APPEND|O_CREATE, 0644`,
    `main.go:709`, so left alone it would append across restarts and be
    world-readable — the launcher owns the mode, not the binary).
  - **`/etc/amnezia/covert/covert.log`** is the one process-written file
    that must survive reboot (flash, for diagnosis), so it stays in the
    `0750` flash dir the process cannot create into. The **installer (root)
    pre-creates it** `0640 amnezia-covert:amnezia-covert`; the wrapper then
    only **appends** (file-write, which it has as owner — not dir-write).
    A first-start test on an empty dir guards this.
  - Only the **cookie** file is `root:amnezia-covert` (rpcd writes it as
    root; the process only *reads* it, via group membership).

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
  **Reap helper — `/proc`-scan, NOT `pkill` (cycle-6 CRITICAL).** Verified
  on the target (BusyBox v1.36.1): **`pkill` does not exist** on this router
  (only `pgrep`, which has **no `-u`**; `ps -o` is unsupported), so a
  `pkill -u <uid>` reap is a silent "command not found" no-op — the exact
  "stubs must mirror real tools" trap, since a bats stub providing `pkill`
  would pass green while the router cannot reap at all. Reaping is therefore
  a shared `amz_covert_reap` helper in `amnezia-common.sh` that scans
  `/proc/<pid>/status` for the covert uid (the `Uid:` line's first field;
  `awk` is present at `/usr/bin/awk`) and `kill`s matches with the given
  signal. Only the launcher and creator run as the fixed covert uid, so a
  uid scan is precise.
- **`disable`** → stop + init-disable the service, then **confirm no
  creator survives before removing the fragment** (cycle-5: the egress
  fragment must outlive the relay, never the reverse): `amz_covert_reap TERM`;
  wait briefly; if the scan still finds a covert-uid process,
  `amz_covert_reap KILL` and re-verify the scan is empty. **Only then**
  remove the nft fragment, backgrounded `fw4 reload`, remove state/link
  files, `covert_enabled='0'`, commit. Idempotent: disabling an
  already-disabled feature is exit 0. Cookie file is **not** deleted.
  Residual, stated: if procd SIGKILLs the launcher on `term_timeout`
  (default 5 s) the launcher's `trap` never runs — so the `/proc`-scan reap
  here (and in `apply`, below) is what actually guarantees no orphan, not
  the `trap` alone.
- **`apply`** → idempotent reconcile used by boot init and `enable`.
  `covert_enabled=0` ⇒ ensure stopped, `amz_covert_reap TERM` (then KILL if
  needed), exit 0. `covert_enabled=1` ⇒ same preflight; **reap only on the
  path that (re)starts** — i.e. when procd reports the service **not**
  running (clearing a SIGKILL-left orphan *before* the fresh start); when
  the service is already running healthy, `apply` is a no-op and **must not
  reap** (a blanket uid reap would kill the healthy creator during a benign
  boot/enable reconcile). On preflight failure, log the specific reason,
  leave `covert_enabled` untouched, do not start, and make `status` report
  it (never a silent no-op). Missing binary ⇒ loud,
  distinct failure whose text names the dev-deploy-only caveat.
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
  | false | true | `idle` | `null` | racing/failed `disable`; `status` forces `idle` and the reconcile stops the instance (cycle-3 L4) |
  | true | true | `starting` | `null` or url | started; `null` before the `join_link:` marker, may be **non-null** once the link is parsed (`main.go:554`) but before `[vk-ws] Connected` (cycle-3 L3) |
  | true | true | `connected` | url | call created + ws connected, heartbeat fresh |
  | true | true | `unknown` | last known | running but heartbeat stale past the window |
  | true | false | `auth-failed` | `null` | preflight/auth failure, `reason` set |
  | true | false | `crashed` | `null` | procd respawn budget exhausted |
  | true | false | `not-started` | `null` | readiness gate never satisfied |

  `link` is JSON `null` (not `""`) when absent, and `link_age_s` is
  `null` alongside it. The UI shows the link only in `connected`, so a
  non-null link during `starting` has no user-visible effect; the table
  row documents it so the state machine is not over-specified. When
  `enabled=0` but procd still reports the instance running (a raced
  `disable`), `status` reports `idle` and the boot/reconcile `apply`
  stops the instance — never an undefined state. Exit code is 0 whenever a JSON object was
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

`/usr/lib/amnezia/amnezia-covert-run.sh` is what procd execs. **Cycle-3
correction (HIGH):** the previous revision listed the readiness wait
*before* the exec that launches the creator, which is unbuildable — a
wait that must observe the creator's own markers (`CALL CREATED`,
`[vk-ws] Connected`) cannot run before the creator exists; it would
always hit its timeout, write `not-started`, and the service would be
dead on arrival. And because the creator is launched via
`exec … | logwrap` (the launcher shell *becomes* the pipeline and
blocks), no post-exec step can exist either. The readiness monitor must
therefore run **concurrently with a backgrounded creator pipeline**.
Corrected order:

0. **Recheck `covert_enabled` first (cycle-4 M).** procd re-execs the
   *instance command* on a respawn, not `start_service`, so
   `start_service`'s enabled-guard is bypassed on every respawn. During a
   `disable` race (UCI `covert_enabled=0` already set, init-disable not yet
   applied, respawn timer fires) the launcher would otherwise start the
   creator and mint a fresh VK call. So the launcher's first act is
   `amz_covert_enabled || exit 0`.
1. **Truncate `state.json` and the link file here, in the launcher** —
   not in `start_service`. procd does not re-run `start_service` on a
   respawn, it re-execs the instance command, so truncation in
   `start_service` would leave the previous generation's `connected`
   state and link visible after a crash. (The previous revision claimed
   staleness was "structurally impossible"; it was not.) The dedicated
   **`/var/run/amnezia-covert/last-call.ts`** is deliberately **not**
   truncated here — see step 2.
2. **Enforce the call-creation gap.** The launcher reads the last
   call-creation timestamp from `last-call.ts` (a dedicated file, *not*
   `state.json`, so step 1's truncation cannot wipe it and defeat the gap
   — cycle-3 MEDIUM), sleeps out the remainder of a 120 s gap, then
   stamps `last-call.ts` immediately before launch. Belt and braces:
   `procd_set_param respawn 300 120 5` puts the same 120 s in procd's own
   **respawn delay** field (the second field is the delay, not a window —
   `respawn 300 5 5` would have allowed ~5 real VK calls in ~25 s).
3. **Launch the creator via a FIFO so both PIDs are captured (cycle-4
   CRITICAL).** A plain `creator … | logwrap &` is unusable on this
   platform: `$!` is the *last* pipeline element (`logwrap`), so the
   launcher never holds the creator's PID; non-interactive BusyBox ash has
   job control **off**, so the pipeline is not its own process group and
   there is no group to kill; and with no signal handler procd's SIGTERM
   reaches only the launcher, leaving the 11 MB creator **orphaned to
   init and still running** — while `disable` has just removed the egress
   fragment, so the orphan becomes an *unrestricted* relay. Instead
   (`$PIPE` lives in the writable service dir — `/var/run/amnezia-covert/covert.fifo`
   — never the `0750` flash dir, where `mkfifo` would EACCES exactly like
   `covert.log`; a leftover FIFO from a prior generation is harmless and
   reused):
   ```sh
   PIPE=/var/run/amnezia-covert/covert.fifo
   mkfifo "$PIPE" 2>/dev/null || :
   amnezia-covert-logwrap.sh < "$PIPE" &  LW=$!
   /usr/bin/amnezia-covert-creator -resources moderate -cookies ... -write-file ... > "$PIPE" 2>&1 &  CR=$!
   trap 'kill "$CR" "$LW" 2>/dev/null' TERM INT EXIT
   ```
   Now both PIDs are held; the `trap` makes procd's SIGTERM (and the
   timeout path below) actually reach the creator, so stop/`disable`/respawn
   leave **no** surviving relay. (`-resources moderate` — cycle-3 HIGH:
   without it the binary defaults to `-resources default` =
   `debug.SetMemoryLimit(128 MB)` per `main.go:623,646`, double the 64 MB
   soft target the Memory section is sized against; `moderate` = 64 MB at
   `main.go:642`.)
4. **Run the readiness monitor concurrently**, polling `state.json` (which
   the log wrapper updates from the FIFO) for the `starting`→`connected`
   transition. A blocking wait here — after the creator is already
   backgrounded and procd already considers the service running — is free:
   it does not stall the serial rc boot sequence or the LuCI `enable` click
   under rpcd's RPC timeout. On success it `wait "$CR"` (so procd sees the
   service alive for the creator's whole life, and the `trap` still fires
   on eventual stop). On timeout it **kills `$CR`, then `$LW` (or `wait`s
   it out) so no draining writer remains, confirms both are dead, then**
   writes `state: "not-started"` last — otherwise a `logwrap` still
   draining buffered lines could emit a `starting` (from a buffered
   `CALL CREATED`) *after* the monitor's write and flap the terminal state
   (cycle-5 LOW). Belt-and-braces: `logwrap` also refuses to downgrade a
   terminal `not-started`/`crashed` state. Then the monitor exits so procd
   respawns.

`amnezia-covert-logwrap.sh` appends to a capped, dedicated
`/etc/amnezia/covert/covert.log` (flash — not tmpfs, so it survives reboot
for diagnosis) and rewrites `state.json` atomically (tmp + `mv`, in the
service-owned `/var/run/amnezia-covert/`).

**Capping must use FILE-write only, never DIR-write (cycle-5 HIGH).** The
blackbox logger caps with `tail -n N "$LOG" > "$LOG.tmp" && mv "$LOG.tmp"
"$LOG"` (`amnezia-blackbox.sh:18`) — but that creates a temp file **and
renames over the original**, both of which need **write on the
directory**. Blackbox gets away with it because it runs as **root**; the
covert wrapper runs as `amnezia-covert` and the flash dir is
`0750 root:amnezia-covert` (group `r-x`, **no write**), so the blackbox
pattern EACCESes and — if the exit status is swallowed — `covert.log`
grows unbounded on ~48.9 MB of flash until UCI commits / DNS break (the
top "never break client internet" constraint). The wrapper therefore caps
by **truncating the file it owns in place**, staging the trimmed copy in
the writable service dir:
```sh
tail -n 2000 covert.log > /var/run/amnezia-covert/logcap && cat /var/run/amnezia-covert/logcap > covert.log
```
The final `>` truncates the existing owned file (needs file-write, which
the wrapper has as owner) — no temp-in-dir, no rename, no unlink. The
blackbox `>$LOG.tmp && mv` pattern is explicitly **forbidden** for this
file; a bats test caps a large `covert.log` in a `0750 root`-owned dir and
asserts success (blackbox-style cap → EACCES → red).

**Bounded cost** (cycle-2 finding — the wrapper must not become the new
autolearn): the state file is rewritten **at most once per second**
regardless of marker rate, and the cap check runs periodically rather than
per line. **Correction (cycle-5):** an earlier draft claimed "`-debug` off
suppresses the `[vk-ws]` chatter" — false. `common.Debug` gates only the
`tunnel_relay.go` lines; the `[vk-ws] <- notification` / `<- response
seq=` / `unhandled` dumps (`main.go:371,449,440`) are logged
**unconditionally** (the Prerequisite's 0.8 lines/s idle rate already
includes them). The CPU conclusion survives because that rate was
*measured*, not assumed. But those `[vk-ws]` lines emit raw SFU/SDP JSON
that can carry **ICE-candidate / joiner peer-IP** metadata **unmasked**
(the `[p2p]`/`[dc]` paths use `MaskAddr`; the raw `[vk-ws]` JSON does not)
into the flash log. No VK credential leaks this way (tokens come from the
HTTP auth bodies, which the `, response:` filter covers) — but see the
threat-model note on peer-IP metadata. If the measured rate ever warrants
it, the wrapper filters to marker lines only and drops the rest, which
also drops these dumps.

**Markers are read from source, not deferred** (they were an
unnecessary deferral — cycle 2):

| marker | source | meaning |
|---|---|---|
| `  CALL CREATED` | `main.go:553` | call created |
| `  join_link: ` | `main.go:554` | the link (also the obfuscation secret) |
| `[vk-ws] Connected` | `main.go:583` | SFU websocket up ⇒ `connected` |
| `Failed to create call:` | `main.go:704` | fatal ⇒ `auth-failed` |
| `Cannot read cookies:` / `Cannot parse cookies:` | `relay/common/http.go:17,24` | credential problem ⇒ `auth-failed` |

**Redaction is a hard requirement of the wrapper**, not an afterthought.
**Cycle-4 correction — redact GENERICALLY, not by an enumerated shape
list.** The cycle-3 revision enumerated three leak lines and asserted
"only `:264` carries the token"; cycle 4 found that wrong and dangerous.
The binary dumps a **raw auth-response body** at **nine** `fmt.Errorf("…
response: %s", string(r))` sites — three in `createAndJoinCall`
(`main.go:264` `empty VK token` = **access_token**, `:286` `empty call_id`
= join_link, `:289` `empty ok_join_link` = join_link) **and six in
`authAndJoin`** (`main.go:133` `empty VK token` = **access_token**, `:145`
`empty public_key`, `:156` `empty call token`, `:159` `empty api_base_url`,
`:180` `empty session_key` = **a credential**, `:197` `empty WS endpoint`).
`authAndJoin` runs on the initial create (`:294`) **and on every
self-healing rejoin** (`:604`, whose failure is logged
`[rejoin] Failed: %v` at `:606`) — and the Prerequisite proved the creator
self-heals in production, so these bodies reach the persistent flash
`covert.log` in the field, not just on a cold auth failure. Enumerating
three shapes leaves `session_key` and the rejoin-path token **unmasked**.

The wrapper therefore redacts on the **generic substring `, response:`**:
on any line containing it, keep everything up to and including
`response:` and replace the remainder with `***`. This is prefix-agnostic
(it does not matter which `empty X` produced it, nor which wrapper
surfaced it — `Failed to create call:` `:704`, `Failed to join existing
call:` `:699`, or `[rejoin] Failed:` `:606`), so it covers all nine sites
and any future one. **Order:** classify state off the wrapper prefix
**first** (the `auth-failed`/rejoin signal lives in the kept head), then
mask the tail — never drop the whole line, which would lose the state
signal.

This is the same defect class as the Prerequisite correction at the top
of this document.

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
- GOMEMLIMIT at 64 MB via `-resources moderate` (soft, real; case at
  `main.go:639`, `debug.SetMemoryLimit(64MB)` at `:642`). **This flag must
  be in the launcher exec line** (cycle-3 HIGH) — the binary defaults to
  `-resources default` = 128 MB (`:643`/`:646`), so an omitted flag doubles
  the target the `MemAvailable` preflight is sized against. A `status`/bats
  assertion checks the running command line carries it.
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

**Harness extension — enumerated mechanically, and corrected in cycle 3.**
The `grep -n "'dns'\|section/dns" test/lib/luci-harness.js` pattern
matches **8** sites (lines ~77, 90, 116, 126, 160, 164, 217, 297), but
that grep is **not sufficient** — it misses the load-bearing wiring site
where the value is passed **positionally**. In `loadWith`, the module is
constructed as `fn(baseclass, ui, fsStub, …, deps.dns, uciStub)` (the
`deps.dns` argument, ~line 80): the `names` DI array (~line 77) and this
positional `fn(...)` call must move **in lockstep**. Adding `covert` to
`names` **without** inserting `deps.covert` at the matching position in
the `fn(...)` call shifts every later argument by one — `uci` binds to
`undefined` and `uciStub` lands on `covert` — silently breaking the
harness across **all** modules while the grep-derived list still looks
complete. So the required edits are **9**: the 8 grep-matched sites **plus
the positional `fn(...)` argument** (which no `'dns'` grep can find),
**plus** the `d.covert = load('amnezia/section/covert.js', d)` line in the
module-load block, **plus** the `DATA` fixture (~line 72) gaining index 14.
Line numbers drift as the harness evolves — the executor re-derives them
at execute time, but must treat the `names`↔`fn(...)` pairing as a single
atomic edit, not two grep hits.

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
4. The installer also **creates the `amnezia-covert` user/group with an
   explicit fixed uid/gid** — a next-free uid would let a reinstall or
   `--migrate` reallocate it and silently void the egress fragment
   (cycle-3/4). It is **idempotent and collision-checked** (cycle-4 M):
   `id -u amnezia-covert` → if the user already exists **with the chosen
   uid**, skip; if it exists with a *different* uid, or the chosen uid is
   held by another name, **fail loudly** rather than proceed against a
   fragment pinned to a stale number. A concrete uid/gid is chosen in a
   range OpenWrt leaves free and documented. It also creates
   `/etc/amnezia/covert/` at `0750 root:amnezia-covert` and
   **pre-creates `/etc/amnezia/covert/covert.log` as
   `0640 amnezia-covert:amnezia-covert`** (cycle-4 HIGH: the wrapper runs
   unprivileged and cannot create a file in a `0750 root`-owned dir — the
   process appends as owner, but the file must exist first), all **before**
   anything can load the nft fragment. `enable`/`apply` **and the boot
   start path** re-resolve the uid at activation, substitute it (and the
   LAN ifname) into the template, and on any mismatch **fail closed**
   (abort/stop), never merely flag `status`.
5. CLI, libs, init, template fragment and ACL ship through the normal
   four-surface convention. On `install.sh`/`.ipk` the feature installs
   **inert**: no binary ⇒ `apply` fails loudly with text naming the
   dev-deploy-only caveat, and the nft fragment is a template that
   `enable` never gets far enough to activate. **Inert-path user/log
   creation (cycle-5):** the `.ipk` postinst and `install.sh` **also**
   create the fixed-uid `amnezia-covert` user + the pre-created
   `covert.log` (harmless — an unused system user and an empty owned log),
   so a later binary-only dev-deploy onto a `.ipk` base finds them already
   present; `enable`'s "user exists" preflight then passes rather than
   failing on a base that shipped without them.

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
4. `disable` idempotent; removes fragment + state + link; leaves cookies;
   **confirms no covert-uid process survives BEFORE removing the fragment**
   (fragment outlives the relay). The reap is exercised via the real
   `amz_covert_reap` `/proc`-scan against an actual spawned process, **not**
   a stubbed `pkill` (which doesn't exist on the router — a stub would hide
   the live failure). *Mutations: (a) remove the fragment before the reap →
   a test asserting the fragment is still present while a fake creator
   lives must go red; (b) implement the reap with `pkill -u` → on a host
   without `pkill`, or with `pkill` removed from PATH in the test, the
   surviving-process assertion must go red.*
5. Cookie structural validator: rejects non-JSON, non-array, and
   elements missing `name`/`value`; accepts the real shape. *Mutation:
   accept-anything → red.*
6. `status` truth table — every row, including `not-started` and
   `unknown`; `link` is `null` not `""` when absent. *Mutation: make
   `running=false,enabled=true` return `idle` → red.*
7. Log wrapper: fed captured spike output, produces the right states;
   **masks the tail generically** at `, response:` while **keeping** the
   surfacing prefix so state is still classified. The fixture must include
   a **rejoin-path** line (`[rejoin] Failed: … empty session_key,
   response: <session_key>`) as well as a create-path token line.
   *Mutations: (a) remove the redaction filter → a test asserting no
   token/session_key/link-shaped string reaches the log must go red;
   (b) drop the whole line instead of masking the tail → a test asserting
   the `auth-failed`/rejoin state is still detected must go red;
   (c) narrow the match to a fixed three-shape list → the `session_key`
   rejoin line leaks and the test must go red.*
8. Log wrapper truncates state+link on **launcher** start, so a
   simulated respawn cannot surface the previous generation's link.
   *Mutation: move truncation back to `start_service` → red.*
8b. **Log cap uses file-write only:** capping a large `covert.log` inside a
   `0750 root:amnezia-covert` dir, running as `amnezia-covert`, **succeeds**
   and leaves the file trimmed. *Mutation: use the blackbox
   `>$LOG.tmp && mv` pattern → EACCES on the dir → red.*
9. Call-creation gap enforced in the launcher, reading a **dedicated
   `last-call.ts`** that launcher-start truncation does **not** touch.
   *Mutations: (a) remove the sleep → red; (b) point the timestamp at
   `state.json` (which step 2 truncates) → a test that a simulated
   respawn still waits the gap must go red.*
10. Launcher exec line carries `-resources moderate`. *Mutation: drop
    the flag → a test asserting the flag is present in the exec'd
    command must go red.*
11. Readiness monitor runs **concurrently** with a backgrounded creator
    (via the FIFO, both PIDs captured): fed a fake creator that emits
    `CALL CREATED` + `[vk-ws] Connected` after a delay, `status` reaches
    `connected`; fed one that never emits, it reaches `not-started` on
    timeout **and no fake-creator process survives**. *Mutations:
    (a) order the readiness wait before the launch (the cycle-2 bug) →
    the `connected` case must go red (times out); (b) use `cmd|logwrap &`
    so `$!` is logwrap → the "no creator survives timeout" assertion must
    go red.*
12. **Launcher teardown:** send SIGTERM to the launcher; the `trap` kills
    the fake creator so none survives. *Mutation: remove the `trap` →
    a surviving-process assertion must go red.*
13. **Enabled-guard on respawn:** with `covert_enabled=0`, re-exec the
    launcher directly (simulating a respawn) → it exits 0 without launching
    the creator. *Mutation: remove the `amz_covert_enabled || exit 0` →
    red.*
14. `enable`/`apply` **fail closed** on uid mismatch (abort/stop, non-zero),
    not a status color. *Mutation: downgrade to a status-only warning →
    a test asserting the service is stopped on mismatch must go red.*
15. **First-start on an empty flash dir:** with `covert.log`
    pre-created by the installer step, the wrapper appends; without it
    (dir `0750 root`), the wrapper's create must fail — the test asserts
    the installer pre-creates it. *Mutation: drop the pre-create → red.*
16. ACL contains both the `exec` and the `write` grants.
17. `test/unit/luci-js.bats` passes with the covert module wired into
    all **9** harness sites (incl. the positional `fn(...)` argument) +
    the `d.covert` load line + the `DATA` fixture index 14. *Mutation:
    add `covert` to `names` but not to the `fn(...)` call → the harness
    self-test (a different module binds `undefined`) must go red.*

**Live-only gates:**
- The Prerequisite spike (the actual go/no-go).
- `fw4 check` passes with the fragment on the real assembled ruleset,
  and WAN + DNS + tunnel handshake all survive `enable` and `disable`.
- **`oif=lo` semantics confirmed on the real kernel** — the whole egress
  design rests on locally-destined traffic routing out `lo` in the output
  hook. The gate below proves it empirically; if it does not hold, fall
  back to explicit-address rejects incl. the resolved router GUAs.
- The creator, running as `amnezia-covert`, **can resolve DNS** (port-53
  loopback accept works) but **cannot** reach the admin plane on **any of
  the router's own addresses, either stack**: `127.0.0.1`, `::1`, the LAN
  IP `192.168.1.1`, **the router's own public WAN IP** (cycle-4: this is
  the joiner's egress IP — the most important probe), and any router GUA,
  on `:2323` and `:80`, must all be **refused**; a **LAN host** must be
  unreachable; and a **private/CGNAT target** off-box — the upstream
  gateway / `100.64.0.0/10` / a `192.168.100.1`-style modem panel
  (cycle-5) — must be **refused** on both stacks.
- **Control-plane IPv4/IPv6 (cycle-4):** the creator's own SFU/TURN dial
  (not just relayed joiner traffic) completes and the tunnel comes up —
  confirming WAN egress is permitted on whichever stack the resolver picks
  and the `oifname` rejects do not catch it. The Mac gate proved *relayed*
  traffic over IPv4 with **no** fw4 rule applied, so it does **not** cover
  this; it is a pending router gate.
- **uid-match, fail-closed:** the running creator's uid equals the uid in
  the active fragment; a deliberately mismatched uid makes `enable` abort /
  the service stop (not just a status color).
- Joiner attaches to the router-created call and loads a page (proven
  on the Mac 2026-09-03; re-confirm once the creator runs on the router).
- **procd SIGTERM leaves no orphan:** send SIGTERM to the launcher (as
  procd stop/`disable` does) and confirm **no** `amnezia-covert-creator`
  process survives (cycle-4 CRITICAL guard).
- **SIGKILL orphan is reaped (cycle-6):** SIGKILL the launcher (bypassing
  its `trap`), then run `amz_covert_reap` via `disable`/`apply` and confirm
  the `/proc`-scan leaves no covert-uid process — proving the reap works
  on the real BusyBox where `pkill` is absent.
- **Multi-day supervised watch (cycle-4):** observe process-exit cadence
  and calls-created-per-day over the first sustained run — the slow-drip
  unbounded-call residual has no other detector, and sustained call
  creation is exactly what the captcha go/no-go catches.
- `MemAvailable` under sustained joiner traffic, foreground-supervised.
- Reboot with the feature enabled → comes back up unattended.

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| **Headless creator has zero captcha handling — a VK challenge is terminal** (verified: no captcha code in `headless/vk/`; it exists only in the joiner package) | Blocking Prerequisite spike; if challenges appear, P1 does not proceed in this shape |
| Spike/service log can contain an `access_token` or `session_key` on auth-failure and self-healing rejoin paths (nine `response: %s` dumps: `main.go:264/286/289` + `authAndJoin` `:133/145/156/159/180/197`) | Prerequisite reports only derived counts, never raw logs; log wrapper **redacts generically** on the substring `, response:` (masks the tail), covering all nine + any future site, on all surfacing lines (`:704`/`:699`/`[rejoin] :606`) |
| Join link is the tunnel obfuscation secret, not just an admission token (`main.go:718`) | Treated as a secret everywhere: `0640 amnezia-covert:amnezia-covert` files, no world-readable `-write-file` default; the link **is** logged in clear at `:554`/`:722` (marker lines) so it is protected by **file mode + `0750` parent dir**, not redaction |
| **Admin plane / private targets reachable** — v6-GUA (cycle-3), the v4 WAN IP = joiner's egress IP (cycle-4), and the upstream ISP CPE / other bridges (cycle-5, after the oif rewrite dropped the address rejects) | Egress rule uses **both**: destination rejects (RFC1918/CGNAT/link-local/multicast, both stacks) close private/CGNAT/other-bridge targets that egress WAN; `oifname "lo"`/`"<LAN>"` rejects close the router's own addresses (WAN IP + GUA, any stack) + LAN hosts. `policy accept` permits only public WAN egress. Live gate probes the WAN IP, a GUA, and a private/CGNAT target on both stacks |
| Flash `covert.log` grows unbounded — the blackbox `>$LOG.tmp && mv` cap needs dir-write the unprivileged wrapper lacks in the `0750 root` dir → EACCES → flash exhaustion breaks UCI/DNS | Wrapper caps by **truncate-in-place** (`tail > /var/run/…/logcap && cat logcap > covert.log`) — file-write only, no temp-in-dir/rename; bats test caps in a `0750 root` dir and asserts success |
| Orphan window during `disable` (fragment removed before creator dies) + SIGKILL bypasses the launcher `trap` | `disable` reaps via `amz_covert_reap` (a **`/proc`-scan** on the covert uid — `pkill`/`ps -o` are ABSENT on this BusyBox, cycle-6) and confirms the scan empty **before** removing the fragment; `apply` reaps a SIGKILL-left orphan only on the (re)start path (never a healthy running creator); SIGKILL residual stated, not assumed away |
| A blanket `meta nfproto ipv6 reject` would brick the SFU dial (pinned `ips[0]`, no v4 fallback — `main.go:479`/`wtsignal.go:75`) | Not used — the rule **allows** public WAN egress on both stacks (only the router's own addresses, LAN, and private/CGNAT destinations are denied), so the SFU dial works whichever stack the resolver picks |
| Unresolvable `meta skuid <name>` / ifname would break the **entire** fw4 ruleset | Numeric uid **and** real LAN ifname substituted at `enable` time (both parse-safe); template never shipped into `/etc/nftables.d/`; `fw4 check` gate with fragment rollback; backgrounded reload |
| Egress rule blocking loopback would kill the creator's own DNS | Explicit `oifname "lo"` port-53 accepts (v4 `127.0.0.1` **and** v6 `::1`) ahead of the `lo` reject; live gate proves DNS resolves and admin plane is refused |
| uid drift silently voids the whole egress restriction | Installer pins a **fixed uid** with an `id` precheck (idempotent, collision-loud); `enable`/`apply`/boot re-resolve, re-substitute, and **fail closed** (abort/stop) on running-uid ≠ fragment-uid — not a status color |
| Unauthenticated exit relay reachable by anyone with the link | Output-interface reject of the router's own addresses + the LAN bridge (both stacks); link treated as a secret; dedicated VK account recommended |
| **Orphaned unrestricted relay after stop/`disable`** — a `cmd|logwrap &` pipeline in BusyBox ash (no job control) leaves the creator running when the launcher dies, while `disable` removes the egress fragment | Launcher captures the creator PID via a **FIFO** (not a pipeline) + `trap … TERM INT EXIT` that kills it; live gate asserts no creator survives a launcher SIGTERM |
| Unprivileged wrapper cannot **create** its flash `covert.log` in the `0750 root` dir | Installer (root) pre-creates `covert.log` `0640 amnezia-covert:amnezia-covert`; wrapper only appends. Ephemeral `state.json`/link/`last-call.ts` live in the service-owned `/var/run/amnezia-covert/` |
| Unprivileged user cannot **read** its own credential | Cookie dir 0750 / file 0640, both `root:amnezia-covert`; process reads via group; `apply` re-asserts `chown root:amnezia-covert` after every rpcd write |
| Unprivileged user cannot write its state file (`/tmp/run` is 0755 root) | `start_service` pre-creates `/var/run/amnezia-covert/` owned by the service user |
| Respawn during a `disable` race mints a fresh VK call (procd re-execs the instance, bypassing `start_service`'s enabled-guard) | Launcher's first act is `amz_covert_enabled \|\| exit 0` |
| Join link exposed to any LuCI session via the status JSON | Stated admission model: **LuCI/rpcd access == relay-join capability** (the link is the sole admission control); same trusted-LAN + plain-`:80` caveat as the cookie field. Acceptable for the single-admin home-router target; noted, not silently assumed |
| Crash-loop burst = call-creation storm on a personal VK account | 120 s gap enforced in the launcher (via a dedicated `last-call.ts` that survives the state-file truncation) **and** in procd's respawn-delay field |
| **Slow-drip** respawn (one death per >300 s) resets procd's retry counter → unbounded calls over days | Named residual: the binary self-heals *without* process exit (Prerequisite), so a process-exit cadence is the unbounded case; if live runs show it, add a persistent daily call counter that trips `crashed` past a ceiling — specified then, not pre-built |
| Binary runs at 128 MB GOMEMLIMIT instead of the 64 MB the Memory section is sized for | `-resources moderate` is an explicit part of the launcher exec contract + a `status` assertion that the running command line carries it |
| `limits as=` is virtual address space, not RSS, and can block Go startup | Dropped; GOMEMLIMIT + `MemAvailable` preflight + supervised first run, with the residual stated plainly |
| Log wrapper becoming the new autolearn-style CPU sink | ≤1 state rewrite/sec, periodic (not per-line) cap check, measured-low line rate (0.8/s idle); marker-only filtering if a live rate warrants it. (`-debug` off matters for the `[relay]` chatter but does **not** gate the unconditional `[vk-ws]` dumps — those are already in the measured rate) |
| Stale `connected` + dead link surviving a respawn | Truncation in the launcher (which procd *does* re-exec), not `start_service` |
| Harness green while not covering the new module | **9** wiring edits (the 8 grep-matched sites **plus** the positional `fn(...)` argument the grep cannot find, treated as one atomic `names`↔`fn(...)` edit) + the `d.covert = load(...)` line + `DATA` index 14 |
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
- **The concrete fixed uid/gid** for `amnezia-covert` (a documented value
  in a range OpenWrt leaves free) — chosen at execute time against the
  target's `/etc/passwd`.
- **`oif=lo` semantics + the SFU control-plane over the router's real v6**
  — the two facts the egress live gate must confirm on the actual kernel
  (see Testing); if `oif=lo` for locally-destined traffic does not hold,
  the fallback is explicit-address rejects incl. the resolved router GUAs.
