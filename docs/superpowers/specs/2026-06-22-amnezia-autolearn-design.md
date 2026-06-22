# Self-learning auto-bypass for AmneziaWG — Design

**Date:** 2026-06-22
**Branch:** `feat/autolearn-bypass` (stacked on `feat/multi-tunnel-failover`)
**Component name:** `amnezia-autolearn`

## Goal

A router-side loop that observes the domains LAN clients visit, classifies which are
**blocked on the direct path** (geoblocked *or* DPI-reset) using the existing
`zapret-probe`, and — after confirmation — auto-adds them to a **separate
auto-learned tunnel list** that feeds the existing `amnezia_force4` engine. The loop
runs **only in `direct-default` routing mode**, is **opt-in via a UI toggle**
(default OFF), and uses **no Claude/LLM** on or off the router in v1.

Top constraint, inherited project-wide: **never break client internet.** Every action
is reversible, bounded, and gated on tunnel health.

## Why this is mostly assembly, not invention

Two pieces already exist and are reused with minimal, backward-compatible change:

- **Detection primitive** — `openwrt/zapret-probe.sh` takes a domain and returns a
  verdict JSON: `direct_ok` / `direct_geoblocked` / `direct_dpi_blocked` /
  `direct_blocked` / `direct_unreachable` / `error`. It is a WAN curl classifier
  (`curl --interface wan`) and works regardless of whether the zapret DPI-desync stack
  is running (it currently is not). **One backward-compatible extension** is added: an
  optional pinned-IP argument so the caller can fix resolution (see §3.3).
- **Routing engine** — `amnezia-force-load` merges `force.d/*.list` + the manual
  `force-tunnel.list`, classifies IP/CIDR → `amnezia_force4` nft set and domains →
  chunked dnsmasq `nftset=` directives. A new `force.d/auto.list` is picked up by its
  existing `*.list` glob. **One small change** is added (a guarded deny filter, §6).

The new code is the autonomous **loop + bookkeeping + UI control + safety filters** on
top.

> **Router-origin caveat (accepted, documented).** `zapret-probe` egresses from the
> router itself, not from a forwarded LAN client. The two paths share the WAN IP, so a
> **geoblock** verdict (server refuses by country) transfers reliably to clients. A
> **DPI-timing** verdict is less transferable and noisier (the probe's sub-2 s heuristic
> misfires under load). v1 therefore trusts `direct_geoblocked` strongly and treats
> `direct_dpi_blocked` as a weaker signal (higher confirmation bar — §5). This caveat is
> the reason the confirmation thresholds differ by verdict.

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| What the loop learns | A separate **auto-tunnel list** only (no zapret driving; zapret is not working). |
| Trigger verdicts | `direct_geoblocked` **and** `direct_dpi_blocked`, each **tagged with its reason**. DPI carries a higher confirmation bar (§5) and is held for hand-off to zapret if it is ever fixed. |
| Candidate source | dnsmasq query-log harvest is the candidate pool. Probe **ordering** is by a weak recency/frequency hint (honest "popularity", NOT a trusted failure signal — see §3 and Out-of-scope). |
| Mode coupling | **Gate the loop to `direct-default`**; fully dormant in `tunnel-default`. Ship independently of any live mode switch. |
| Confidence & aging | **2 matching geoblock verdicts** (or **3** DPI verdicts) before adding; **14-day revalidation** — re-probe each entry, drop it if it now passes direct. |
| Control & Claude | LuCI **view + veto + purge** (remove → denylist; promote → manual list). **No Claude in v1**. |
| Master switch | A LuCI **toggle** to enable/disable auto-learning, **default OFF** (opt-in). |

## Architecture

A periodic **cron-driven pass** (matching the existing `ru-load` / `force` cron
pattern), not a persistent daemon — lighter on a 256 MB router and more testable.

### New components

- **`/usr/sbin/amnezia-autolearn`** — one pass: gate-check → harvest → safety-filter →
  throttled pinned-probe → confirm/age → write `auto.list` → (on net change only)
  `amnezia-force-load`.
- **`/usr/bin/amnezia-autolearn-ctl`** — CLI backing the UI:
  - `status` — JSON (enabled, counts, last-run ts).
  - `list` — current auto-list with reason tags and added-when.
  - `veto <domain>` — remove from `auto.list` and add to deny list.
  - `promote <domain>` — move from `auto.list` into the manual `force-tunnel.list`.
  - `purge` — take the autolearn flock, empty `auto.list` + `candidates.json`, single
    `force-load`. Does NOT auto-deny purged domains (intended for use with the toggle
    OFF; with it ON they may re-learn — documented in the UI).
  - `set-enabled <0|1>` — flip the master toggle (enabling sets up query logging,
    disabling reverses it — §3.1).
- **`/etc/init.d/amnezia-autolearn`** — installs the cron entry, sets up/tears down
  query logging, honors the enable flag.

### Data flow — one pass

1. **Gate (fast exit unless ALL hold):**
   - `amnezia.config.routing_mode = direct-default`, and
   - `amnezia.config.autolearn_enabled = 1`, and
   - **tunnel health, freshly verified:** read `/var/run/amnezia-failover.json`, require
     its mtime to be within `AUTOLEARN_STATE_MAX_AGE` (hardcoded **120 s** ≈ 12× the
     daemon's in-process ~10 s `POLL_INTERVAL`; a stale file from a dead daemon is
     treated as unhealthy), and require `all_down` to be `false`. `all_down` is parsed
     with `grep -o '"all_down":[a-z]*'` — **no jq on the router**.
     *Limitation, documented:* `all_down` reflects **pool**-tunnel health only; it is a
     conservative-enough gate because the failure direction (not adding) is safe.
   **Hard safety rule:** never auto-route through a dead/stale tunnel.
2. **Harvest:** read new lines from the tmpfs query log over `[offset, size)` (offset
   handling per §3.2, never truncating mid-window); parse **only** `query[` lines —
   canonical dnsmasq form `query[A] <domain> from <client-ip>` — extracting the FQDN and
   the client IP; drop RU / `.ru` domains, and drop anything already in `auto.list`,
   `force-tunnel.list`, or `deny.list`.
3. **Safety filter (§3.3):** reject any candidate that is not a public, routable FQDN
   before it is ever probed, and pin the validated IP for the probe.
4. **Abuse resistance (§3.4):** a domain is probe-eligible only after **≥2 distinct
   client IPs** have resolved it; per-pass per-client candidate cap; the recency hint
   only orders the queue, never substitutes for a probe verdict.
5. **Probe (throttled, sequential, pinned):** call `zapret-probe <domain> <pinned-ip>`
   on up to `autolearn_max_probes` candidates per pass (default 20), sequentially.
   Record the verdict in `candidates.json`.
6. **Confirm:** add a domain to `auto.list` (with reason tag in `candidates.json`) on
   the **2nd** matching `direct_geoblocked`, or the **3rd** matching
   `direct_dpi_blocked`. `direct_ok` / `direct_blocked` / `direct_unreachable` / `error`
   are **no-ops** (neither add nor drop).
7. **Apply (only if `auto.list` net-changed this pass):** `auto.list` is in
   `/etc/amnezia/force.d/`, globbed by `amnezia-force-load`. Call it once; domains flow
   to the dnsmasq nftset and resolve into `force4`. Skipping the call when nothing
   changed avoids needless dnsmasq restarts (§6, H1).
8. **Age / revalidate:** entries whose `last_probe` is older than
   `autolearn_revalidate_days` (default 14) are re-probed (pinned); a now-`direct_ok`
   entry is dropped. The revalidation probe MUST egress direct (tested invariant — §7).
   This is **structurally guaranteed**: the classifier hooks `prerouting` and marks only
   *forwarded* LAN traffic, so router-origin packets (the probe's curl) get no fwmark,
   never hit the pref-31000/31001 ip rules, and always egress the WAN — independent of
   `force4` membership. `zapret-probe`'s `curl --interface wan` bind is a secondary
   anchor. If direct egress ever cannot be guaranteed, revalidation-drop is disabled
   rather than silently never-dropping.

### 3.1 Query-log source (resolves C1/C2/C3)

OpenWrt dnsmasq does not log queries by default. The component enables it **reversibly
and to tmpfs, never flash**:

- `uci set dhcp.@dnsmasq[0].logqueries='1'`
- `uci set dhcp.@dnsmasq[0].logfacility='/tmp/dnsmasq-queries.log'` (tmpfs, RAM-backed,
  no flash wear)
- `uci set dhcp.@dnsmasq[0].log-async='5'` (keep logging off the resolve hot-path)
- restart dnsmasq once at enable time (SSH-safe).

**Rotation via SIGUSR2, using the `mv`-then-signal idiom (not truncate-under-a-live-fd).**
dnsmasq holds the log fd open and only reopens it on `SIGUSR2` (its documented logrotate
hook). Truncating in place (`: >`) under the retained fd recreates a sparse NUL hole and
loses lines written in the truncate→reopen window — so the pass uses the **logrotate
idiom** instead. Each pass reads `[offset, size)` and advances the stored offset to
`size`. **Only when the file exceeds `AUTOLEARN_LOG_MAX_BYTES` (default 2 MB)** does it
rotate:
1. `mv /tmp/dnsmasq-queries.log /tmp/dnsmasq-queries.log.1` (dnsmasq keeps writing to the
   now-renamed inode via its held fd — no loss);
2. signal dnsmasq to reopen at a fresh inode/offset 0 (pid resolution below);
3. drain any remaining lines from `.1`, then `unlink` it and reset the stored offset to 0.

**dnsmasq pid resolution (BusyBox-safe).** BusyBox `pgrep -x`/`pkill` mis-match
absolute-path daemons (documented project trap — see `zapret-status.sh`). Resolve the pid
from the **procd pidfile** `/var/run/dnsmasq/dnsmasq.*.pid` (read the single match);
fall back to `pgrep -f dnsmasq` (the `-f` form, as `zapret-status.sh` uses), never `-x`.
**If no pid resolves, skip rotation entirely** (do NOT `mv`/truncate without a working
reopen) — the file keeps growing until a later pass finds the pid, which is safe (tmpfs,
bounded by available RAM) and fail-safe.

The kernel reopen itself is **live-only-verify** (the bats `dnsmasq` stub cannot model a
retained fd — per the project's stub rule); the `mv`+drain+offset-reset logic *is*
unit-testable with a file stub. `log-async='5'` requires a dnsmasq built with async-log
support — a live-hardware check; if unsupported, dnsmasq rejects the option, so the init
must verify it applied. On `set-enabled 0` / init `stop`, the UCI options are removed and
dnsmasq restarted, fully reversing the change.

### 3.2 Offset handling

Defensive: **if stored offset > current file size** (post-rotation, reboot, or a torn
state), reset to 0 before reading. A power-loss mid-rotate leaves at worst a re-read of
already-seen lines, absorbed by the dedup in step 2.

### 3.3 Probe-target safety filter + pinned resolution (resolves C-SSRF)

`zapret-probe` resolves the domain itself inside `curl`. To close the
resolve-for-check / resolve-for-use **TOCTOU** (DNS rebinding), autolearn resolves the
candidate **once**, validates the address, and **passes that pinned IP to the probe**:

- Resolve the candidate's A record via the router resolver. **Reject** (never probe,
  never add) if it is private/loopback/link-local/CGNAT/multicast/router-LAN:
  `10/8`, `172.16/12`, `192.168/16`, `127/8`, `169.254/16`, `100.64/10`, `0/8`,
  `224/4`, and the router's own LAN subnets — enumerated from UCI (`uci -q get
  network.<iface>.ipaddr`/`netmask` across interface sections, not just `lan`, so a
  non-`lan`-named bridge is still covered). When the resolver returns **multiple** A
  records, validate every one and pin the **first public** address; a per-edge GeoDNS
  verdict can still diverge from a client's edge (safety-neutral — a wrong verdict only
  mis-routes one domain to the tunnel = latency), which is the documented reason DPI
  verdicts carry a higher confirmation bar.
- **Reject non-public names:** bare hostnames (no dot), `.lan` / `.local` / `.internal`
  / `.localdomain` / `.home.arpa`, and IP-literals.
- Probe with the pinned IP: `zapret-probe` gains an optional 2nd arg; when present it
  uses `curl --resolve <domain>:443:<ip> --resolve <domain>:80:<ip>` and
  **`--max-redirs 0`** (no redirect-following — a block manifests at the handshake /
  first response, before any redirect, so following 30x into a possibly-internal host
  is both unnecessary and unsafe). The existing UI `verify`/`probe` flow keeps calling
  `zapret-probe` with one arg (redirect-following preserved) — the extension is
  backward-compatible.
- IPv4-only (matches the v4-only stack); AAAA is out of scope and not probed.

### 3.4 Abuse resistance (resolves C-poison — honest framing)

These **raise the cost** of LAN-side poisoning; they are not a hard stop, because LAN
client IPs are unauthenticated and spoofable. The real backstop is that a poisoned
domain still must return a blocked verdict from a *pinned* probe (§3.3) to be added, and
a poisoned add only routes that one domain via the tunnel (latency, not breakage).

- **Distinct-client gate:** probe-eligible only after **≥2 distinct client IPs**
  resolved it (cost-raising, not a stop — documented as such).
- **Per-client fairness:** at most `autolearn_max_per_client` (default 5) candidates
  attributable to one client IP per pass, so one host cannot exhaust the probe budget.
- **Size cap with LRU eviction (resolves the starvation DoS):** at
  `autolearn_max_entries`, admitting a newly-confirmed domain **evicts the
  least-recently-confirmed auto entry** (LRU by `last_probe`), so an attacker squatting
  genuinely-geoblocked junk cannot permanently starve legitimate learning. Manual /
  promoted entries live in `force-tunnel.list` and are never evicted. The cap still
  bounds total `force4` size (and thus the all-down blast radius — §6 H2).

### Files & config

| Path | Purpose |
|---|---|
| `/tmp/dnsmasq-queries.log` | tmpfs query log (RAM, SIGUSR2-rotated at 2 MB). Plaintext full-DNS history while the toggle is ON — see Privacy note. |
| `/etc/amnezia/force.d/auto.list` | Auto-learned entries. Separate from manual `force-tunnel.list`; never merged into it. |
| `/etc/amnezia/autolearn/candidates.json` | Per-domain history: `{verdict, count, distinct_clients[], first_seen, last_probe, reason}`. Pruned by retention. Parse-fail → reinitialize empty (never abort). |
| `/etc/amnezia/autolearn/deny.list` | Vetoed domains; applied as a guarded, suffix-aware **global** exclusion by `force-load` (§6). |
| `/etc/amnezia/autolearn.json` | UI state: enabled, counts, last-run ts. |
| `/etc/amnezia/autolearn/.dnsmasq-log.offset` | Byte offset into the tmpfs log. |

UCI options under `amnezia.config`:

| Option | Default | Meaning |
|---|---|---|
| `autolearn_enabled` | `0` | Master toggle (opt-in). |
| `autolearn_interval_min` | `30` | Cron cadence in minutes (bounds restart cadence — §6 H1). |
| `autolearn_max_probes` | `20` | Max probes per pass. |
| `autolearn_max_per_client` | `5` | Max candidates attributable to one client IP per pass. |
| `autolearn_revalidate_days` | `14` | Re-probe age threshold. |
| `autolearn_max_entries` | `500` | Cap on `auto.list` (v1 default lowered from 5000 to bound the all-down blast radius — §6 H2; LRU-evicts at cap). |
| `autolearn_candidate_retention_days` | `30` | Drop `candidates.json` entries unseen for this long. |

**Privacy note:** while the toggle is ON, `/tmp/dnsmasq-queries.log` holds the LAN's full
DNS history in cleartext RAM (gone on reboot, rotated at 2 MB) — the default-OFF toggle is
the consent gate. **Distinctly, `candidates.json` is flash-resident** (`/etc/amnezia/`),
so the per-candidate client-IP attribution it stores **survives reboot** and persists for
`autolearn_candidate_retention_days` (30) — a longer-lived, on-disk privacy artifact than
the ephemeral log. `purge` and toggle-OFF should be the documented way to clear it.

### UI (LuCI Amnezia view)

- **Master toggle** (the tumbler): enable/disable auto-learning. Default OFF. Disabling
  stops *learning* and reverses query logging, but leaves existing `auto.list` entries
  active — a learning switch, not a routing switch. **Purge** fully backs out.
- **Auto-list table:** domain · reason tag · added-when, with per-row **Remove**
  (→ deny list) and **Promote to manual**, plus a **Purge all** action. The Remove
  tooltip states veto is exact-FQDN + subdomains (suffix-aware, §6) and authoritative
  across subscribed sources.

## Error handling & safety (never break internet)

- **Tunnel-health gate** (step 1) with **staleness check** prevents adds when no tunnel
  works or the daemon is dead.
- **All-down blast radius (H2):** in `direct-default` an all-tunnels-down state
  blackholes *every* `force4` source (manual, fetched, auto alike). Autolearn does not
  introduce this failure mode but **does enlarge it** (more entries than a human list) —
  so the v1 cap is lowered to **500** to bound it, and a failover-daemon
  `force4`→direct drain on all-down is filed as a recommended follow-up (benefits all
  sources).
- **deny.list — guarded, suffix-aware, global (resolves H4 + new force-update risk):**
  `force-load` applies the deny filter over the merged domain set **only when the file
  is non-empty and readable** (`[ -s deny.list ]`), so a missing/empty file or a read
  error can NEVER blank the merged set (which would empty `force4`). Matching is
  **suffix-aware** to mirror dnsmasq nftset semantics: a vetoed `example.com` drops
  `example.com` and `*.example.com`. Because `force-update`'s daily cron also calls
  `force-load`, this filter runs on that path too — i.e. a veto suppresses a domain even
  if it is in a subscribed `force_source`. Insertion point: after the domain dedup,
  **before** the domain hash is computed, so a veto invalidates the hash and triggers a
  rebuild. This cross-effect on subscriptions is intended and documented.
- **Never touches `force-tunnel.list`** except via explicit `promote`; all writes atomic
  (temp + `mv`).
- **Restart cadence bounded (H1):** `force-load` runs only on a net `auto.list` change,
  at a 30-min default cadence; the existing domain-hash skip suppresses no-op restarts.
  `force-load`'s own `FORCE_LOCK` serializes against the daily `force-update` cron;
  autolearn's flock guards `auto.list`/`candidates.json` writes and is taken by `purge`
  so a pass cannot resurrect just-purged entries.
- **Size cap + LRU** bound growth and dnsmasq load; tmpfs log + 2 MB rotation bound RAM.
- Probe failures (`error`/`direct_unreachable`/`direct_blocked`) never add and never
  drop — no-ops leaving prior state intact.

## Testing

- **bats units** — stubbed `zapret-probe` (canned verdicts), `uci`, `nft`, `dnsmasq`,
  mirroring real OpenWrt output incl. the **exact** `query[A] <domain> from <ip>` log
  line (per the project's hard-won stub rule): geoblock-confirm-after-2,
  dpi-confirm-after-3, revalidate-drop, **deny global + suffix** (vetoing `example.com`
  suppresses `www.example.com` from a fetched source), **deny empty/missing file →
  pass-through, never blanks force4**, mode-gate no-op, toggle-off no-op +
  logging-reversed, **stale/missing failover.json → no add**, all-down → no add,
  RU-skip, safety-filter rejects RFC1918/`.lan`/bare-host/IP-literal, **distinct-client
  gate (1 client → not eligible; cached second-client query still counts)**,
  per-client fairness cap, **size-cap LRU eviction** (new confirmed evicts oldest, never
  evicts a promoted/manual entry), candidate retention prune, offset-reset-on-shrink,
  atomic-write, `auto.list` never pollutes `force-tunnel.list`, **pinned-probe passes
  `--resolve`/`--max-redirs 0`** (assert the curl invocation).
- **Revalidation-drop invariant (H3):** a test asserts the probe binds `--interface wan`
  (the structural anchor that egress is WAN, not the tunnel); drop disabled if not.
- **VM scenario** (`dev/vm/`) — direct-default + autolearn on, inject candidate domains
  (≥2 client IPs) with canned verdicts, assert `auto.list` populated and `force4`
  reflects it; toggle-off halts learning and reverses query logging; stale failover.json
  blocks adds.
- **Live-router carry-over (cannot be simulated):** (a) the **SIGUSR2 log-rotation**
  actually reopens dnsmasq's fd and the harvest keeps reading after rotation; (b) LAN DNS
  stays up during an `auto.list`-driven `force-load`; (c) the tmpfs query log does not
  grow unbounded.

## Out of scope (v1)

- Claude/LLM curation of the auto-list (documented future option, off-router via API).
- IPv6 — matches the existing v4-only `force4`.
- Kernel-side RST/conntrack failure detection — deferred. The honest v1 candidate
  *ordering* is recency/frequency popularity, **not** a true connection-failure signal
  (the DNS-log retry heuristic is defeated by dnsmasq caching). True failure-driven
  prioritization needs the deferred conntrack work.
- Failover-daemon `force4`→direct drain on all-tunnels-down (benefits all force4 sources,
  not just autolearn).
