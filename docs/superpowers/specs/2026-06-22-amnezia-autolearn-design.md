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
is reversible and gated on tunnel health.

## Why this is mostly assembly, not invention

Two pieces already exist and are reused unchanged:

- **Detection primitive** — `openwrt/zapret-probe.sh` takes a domain and returns a
  verdict JSON: `direct_ok` / `direct_geoblocked` / `direct_dpi_blocked` /
  `direct_unreachable` / `error`. It is a plain direct-WAN curl classifier and works
  regardless of whether the zapret DPI-desync stack is running (which it currently is
  not). `direct_geoblocked` is already documented as the "must-tunnel candidate — no
  DPI tweak will help" verdict.
- **Routing engine** — `amnezia-force-load` merges `force.d/*.list` + the manual
  `force-tunnel.list`, classifies IP/CIDR → `amnezia_force4` nft set and domains →
  chunked dnsmasq `nftset=` directives. Because it already globs `force.d/*.list`, a
  new `force.d/auto.list` is picked up with **zero changes** to that engine.

The new code is the autonomous **loop + bookkeeping + UI control** on top.

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| What the loop learns | A separate **auto-tunnel list** only (no zapret driving; zapret is not working). |
| Trigger verdicts | `direct_geoblocked` **and** `direct_dpi_blocked`, each **tagged with its reason** so DPI-tagged entries can be handed back to zapret if it is ever fixed. |
| Candidate source | **Hybrid:** dnsmasq query-log harvest is the candidate pool; a connection-failure signal *prioritizes* probing. The failure signal is a **pure DNS-log retry heuristic** (no new datapath rules). |
| Mode coupling | **Gate the loop to `direct-default`**; fully dormant in `tunnel-default`. Ship independently of any live mode switch. |
| Confidence & aging | **2 matching blocked verdicts** before adding; **14-day revalidation** — re-probe each entry, drop it if it now passes direct. |
| Control & Claude | LuCI **view + veto** (remove → denylist; promote → manual list). **No Claude in v1** (off-router curation documented as future). |
| Master switch | A LuCI **toggle** to enable/disable auto-learning, **default OFF** (opt-in). |

## Architecture

A periodic **cron-driven pass** (matching the existing `ru-load` / `force` cron
pattern), not a persistent daemon — lighter on a 256 MB router and more testable.

### New components

- **`/usr/sbin/amnezia-autolearn`** — one pass: gate-check → harvest → throttled probe
  → confirm/age → write `auto.list` → trigger `amnezia-force-load`.
- **`/usr/bin/amnezia-autolearn-ctl`** — CLI backing the UI:
  - `status` — JSON (enabled, counts, last-run ts).
  - `list` — current auto-list with reason tags and added-when.
  - `veto <domain>` — remove from `auto.list` and add to deny list.
  - `promote <domain>` — move from `auto.list` into the manual `force-tunnel.list`.
  - `set-enabled <0|1>` — flip the master toggle.
- **`/etc/init.d/amnezia-autolearn`** — installs the cron entry; honors the enable flag.

### Data flow — one pass

1. **Gate (fast exit unless ALL hold):**
   - `amnezia.config.routing_mode = direct-default`, and
   - `amnezia.config.autolearn_enabled = 1`, and
   - at least one tunnel reports a healthy handshake in
     `/var/run/amnezia-failover.json`. **Hard safety rule:** never auto-route a domain
     through a dead tunnel.
2. **Harvest:** read new lines from the dnsmasq query log since the stored byte offset;
   drop RU / `.ru` domains (already direct), and drop anything already present in
   `auto.list`, `force-tunnel.list`, or `deny.list`.
3. **Failure priority (pure DNS-log heuristic, no datapath changes):** a domain
   re-resolved repeatedly within a short window (clients retry when connections fail)
   jumps the probe queue. No new nftables/conntrack rules — the datapath is untouched.
4. **Probe (throttled, sequential):** call `zapret-probe` on up to
   `autolearn_max_probes` candidates per pass (default 20), sequentially (mirrors
   `zapret-verify.sh`: parallel curls under DPI/QoS mask each other). Record the verdict
   in `candidates.json`.
5. **Confirm:** on the **2nd** matching blocked verdict (`direct_geoblocked` or
   `direct_dpi_blocked`) for a domain, append it to `auto.list` and store its reason tag
   (`geoblock` / `dpi`) in `candidates.json`.
6. **Apply:** `auto.list` lives in `/etc/amnezia/force.d/`, already globbed by
   `amnezia-force-load`. Call `amnezia-force-load`; domains flow to the dnsmasq nftset
   and resolve into `force4`.
7. **Age / revalidate:** entries whose `last_probe` is older than
   `autolearn_revalidate_days` (default 14) are re-probed; a now-`direct_ok` entry is
   dropped from `auto.list`.

### Files & config

| Path | Purpose |
|---|---|
| `/etc/amnezia/force.d/auto.list` | Auto-learned entries. Separate from manual `force-tunnel.list`; never merged into it. |
| `/etc/amnezia/autolearn/candidates.json` | Per-domain probe history: `{verdict, count, first_seen, last_probe, reason}`. |
| `/etc/amnezia/autolearn/deny.list` | Vetoed domains; filtered at `auto.list` write time so `force-load` needs no deny awareness. |
| `/etc/amnezia/autolearn.json` | UI state: enabled, counts, last-run ts. |
| `/etc/amnezia/autolearn/.dnsmasq-log.offset` | Stored byte offset into the dnsmasq query log. |

UCI options under `amnezia.config`:

| Option | Default | Meaning |
|---|---|---|
| `autolearn_enabled` | `0` | Master toggle (opt-in). |
| `autolearn_interval_min` | `10` | Cron cadence in minutes. |
| `autolearn_max_probes` | `20` | Max probes per pass. |
| `autolearn_revalidate_days` | `14` | Re-probe age threshold. |
| `autolearn_max_entries` | `5000` | Cap on `auto.list` size (bounds dnsmasq load). |

### UI (LuCI Amnezia view)

- **Master toggle** (the tumbler): enable/disable auto-learning. Default OFF. Disabling
  stops *learning* but leaves existing `auto.list` entries active — it is a learning
  switch, not a routing switch.
- **Auto-list table:** domain · reason tag · added-when, with per-row **Remove**
  (→ deny list) and **Promote to manual**.

State is surfaced via `amnezia-autolearn-ctl status`/`list`, consumed by the existing
focus-guarded LuCI poll pattern.

## Error handling & safety (never break internet)

- **Tunnel-health gate** (step 1) prevents adds when no tunnel works; a false-positive
  add costs latency, not breakage, in direct-default.
- **Never touches `force-tunnel.list`** — the manual list is sacrosanct.
- **Atomic writes** (temp + `mv`) for every file, matching the existing scripts.
- **Size cap** (`autolearn_max_entries`) bounds `auto.list` growth and dnsmasq load.
- `amnezia-force-load` already restarts dnsmasq SSH-safely (no `fw4 reload`) and chunks
  `nftset=` lines under the ~1 KB dnsmasq config-line limit.
- **flock** on the pass (like `force-update`) so cron + manual runs cannot race.
- Probe failures (`error`/`direct_unreachable`) never add and never drop — they are
  no-ops, leaving prior state intact.

## Testing

- **bats units** — stubbed `zapret-probe` (canned verdicts), `uci`, `nft`, `dnsmasq`,
  mirroring real OpenWrt output (per the project's hard-won stub rule):
  confirm-after-2, revalidate-drop, deny-filter, mode-gate no-op, toggle-off no-op,
  tunnel-down guard, RU-skip, size-cap, atomic-write, `auto.list` never pollutes
  `force-tunnel.list`.
- **VM scenario** (`dev/vm/`) — direct-default + autolearn on, inject candidate domains
  with canned probe verdicts, assert `auto.list` populated and `force4` reflects it;
  toggle-off halts learning; tunnel-down blocks adds.
- **Live-router carry-over** — verify LAN DNS stays up during an `auto.list`-driven
  `force-load` (the one thing the VM cannot measure, per the existing project note).

## Out of scope (v1)

- Claude/LLM curation of the auto-list (documented future option, off-router via API).
- IPv6 — matches the existing v4-only `force4`.
- Kernel-side RST/conntrack failure detection — deferred; the DNS-log retry heuristic
  covers the failure-priority need without datapath risk.
