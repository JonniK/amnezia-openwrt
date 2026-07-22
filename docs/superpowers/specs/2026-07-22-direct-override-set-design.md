# Direct-override routing set (`amnezia_direct4`) — Design

**Date:** 2026-07-22
**Branch:** `feat/direct-override-set`
**Lane:** superpowers-autonomous, express mode

## Problem

`chat.google.com` (Google Chat) loads poorly and unstably. Root cause is **not** a
throttle or a routing bug — it is an over-broad force rule:

- The `amnezia.google` force-source is an **AS-source (AS15169 = all of Google)**,
  titled "Google Meet / media". It exists because RU **hard-blocks YouTube media**
  (`i.ytimg.com` / `googlevideo.com` are dead on the direct path — verified
  `http=000` direct vs `200` via tunnel).
- But AS15169 covers **all** Google, so `chat.google.com` (142.251.x, in
  `142.250.0.0/15`) is dragged into the tunnel too.
- Plain Google is **not** throttled on the direct path (`apis.google.com/js/api.js`
  loads full on both paths). Real-time Google Chat (websockets / long-poll) over the
  foreign tunnel exit suffers jitter + datacenter-exit rate-limiting → "unstable".

We cannot separate Chat from YouTube by CIDR — both live in AS15169 with overlapping
ranges (Google mixes services across its address space via GFE/anycast). YouTube
**must** stay tunneled; Chat should go **direct**.

## Goal

Introduce a **routing-level direct-override**: a set of domains that always route
**direct** (WAN), taking precedence over the force/sticky tunnel rules — even when a
broad force-range (the Google AS) would otherwise tunnel them. Seed it with
`chat.google.com`; make it trivial to add other Workspace hosts (`mail.google.com`,
`drive.google.com`, `docs.google.com`, …).

Top constraint (project CLAUDE.md): **never break client internet.** The change is
purely additive — an extra `return` (direct) rule and a new empty set — so its
worst-case failure mode is "a listed domain still tunnels" (no breakage), and the only
real risk (a malformed nft fragment breaking `fw4 reload`) is gated by `fw4 check` +
a bats template test before any reload.

## Design

Mirror the existing `amnezia_force4` subsystem symmetrically with an
`amnezia_direct4` **override** set, checked **first** in the classifier.

### 1. New nft set + classifier rule (both mode templates)

`amnezia_direct4` is declared and consulted in **both** classifier templates
(`openwrt/nftables.d/30-amnezia-classify.nft` = tunnel-default, and
`…-classify-direct.nft` = direct-default). Declaration mirrors the others:

```
set amnezia_direct4  { type ipv4_addr; flags interval; auto-merge; }
```

The override rule is inserted **immediately after** the `iifname != LAN return`
guard, **before** every RU/sticky/force rule, in both chains:

```
iifname != "@@LAN_IFNAME@@" return
ip daddr @amnezia_direct4 return      # <-- direct-override: always WAN, wins over force/sticky
…existing rules unchanged…
```

`return` with no `meta mark` leaves the packet unmarked → main table → WAN (direct),
identical to how RU-direct already works. Because it precedes the `@amnezia_force4`
rule, a domain present in **both** sets routes **direct** — which is exactly the fix
(`chat.google.com` is in `force4` via the Google AS range).

- **tunnel-default mode:** override sends the domain direct even though "everything
  foreign → pool".
- **direct-default mode:** override beats the `force4` allowlist rule.

Placing it before `sticky4` too is intentional and harmless (no override domain is a
sticky/Anthropic host).

### 2. Population — extend the force subsystem (no parallel subsystem)

`amnezia-force-load.sh` already: takes the flock, merges source lists, classifies
each entry into IP/CIDR vs domain, batch-loads IPs into the nft set, writes
byte-chunked `nftset=` directives into a dnsmasq conf-dir file, hash-gates the
dnsmasq restart, and is add-only by default (never flushes runtime CDN IPs). We
**reuse all of it** for direct.

Refactor the per-set body (classify → load IPs into `<set>` → write chunked
`nftset=…#<set>` conf → domain-hash) into a shell function parameterised by
`(set_name, source_lists, conf_file, hash_file)`, and call it **twice** in one
flock: once for `amnezia_force4` (sources `force.d/*.list` + `force-tunnel.list`,
conf `amnezia-force.conf`, hash `.force-domains.hash`) and once for
`amnezia_direct4` (source `direct-tunnel.list`, conf `amnezia-direct.conf`, hash
`.direct-domains.hash`). **One** dnsmasq restart at the end, fired if **either**
domain-hash changed. This keeps the single lock, single restart, and all the
existing safety properties (add-only, chunking, atomic mv, validation).

- `--flush` continues to apply to force4; direct4 is likewise add-only and only
  flushed under `--flush` (user-initiated refresh). Same rationale: flushing strips
  the fwmark decision from ESTABLISHED flows.
- The `save-manual` path is force-only and unchanged.

### 3. Seed list + installer

- New `openwrt/direct-tunnel.list`, seeded with `chat.google.com` (one entry).
- `install-amnezia-pbr.sh` places it idempotently, mirroring the existing
  `force-tunnel.list` seed block (create if absent, else `touch`, `chmod 0644`).

### 4. Boot / hotplug / warm — reuse existing triggers

- Boot init (`amnezia-force-load.init`, `START=96`) and firewall hotplug
  (`99-amnezia-force-load.hotplug`) already call `amnezia-force-load`, which now
  loads direct too — **no new init/hotplug files**.
- `amnezia-force-warm.sh` re-resolves `force-tunnel.list` domains every 2 min to keep
  CDN IPs hot. Extend it to also re-resolve `direct-tunnel.list` domains (so
  `chat.google.com`'s rotating Google IPs stay in `amnezia_direct4`). Guard on file
  existence exactly like the force list.

### 5. CLI — `amnezia-failover-ctl` verbs

Add three verbs (case dispatch, mirroring `set-routing-mode` etc.):

- `direct-add <domain>` — validate domain, append to `direct-tunnel.list` (dedup),
  run `amnezia-force-load` (repopulates direct4 + wires dnsmasq), resolve once via
  `127.0.0.1` so IPs land immediately. Emits a one-line JSON result.
- `direct-remove <domain>` — remove from list, run `amnezia-force-load --flush` so
  the removal takes effect (mirrors the force removal semantics), evict is handled by
  the flush+repopulate.
- `direct-list` — print current entries.

Domain validation reuses the same guard style as elsewhere (reject IP-shaped or
garbage input for the domain path; a CIDR/IP is also accepted and loaded straight
into `amnezia_direct4`).

## Files

| File | Change |
|---|---|
| `openwrt/nftables.d/30-amnezia-classify.nft` | declare `amnezia_direct4` + override rule |
| `openwrt/nftables.d/30-amnezia-classify-direct.nft` | declare `amnezia_direct4` + override rule |
| `openwrt/amnezia-force-load.sh` | extract per-set fn; load `direct-tunnel.list` → `amnezia_direct4` |
| `openwrt/amnezia-force-warm.sh` | also re-resolve `direct-tunnel.list` |
| `openwrt/direct-tunnel.list` | **new**, seed `chat.google.com` |
| `openwrt/amnezia-failover-ctl.sh` | `direct-add` / `direct-remove` / `direct-list` verbs |
| `openwrt/install-amnezia-pbr.sh` | seed `direct-tunnel.list` idempotently |
| `test/unit/direct-override.bats` | **new** — see Testing |
| `packages/**` | mechanical sync via `dev/sync-to-packages.sh` |

## Testing

`test/unit/direct-override.bats` (stubs mirror real `nft`/`dnsmasq`/`uci` output per
CLAUDE.md):

1. Both classifier templates declare `amnezia_direct4` and the override rule appears
   **before** the `amnezia_force4` rule (grep ordering assertion).
2. `amnezia-force-load` populates `amnezia_direct4` from `direct-tunnel.list`
   (IP entry → set; domain entry → `nftset=…#amnezia_direct4` conf line).
3. **Precedence:** a domain present in **both** `force-tunnel.list` and
   `direct-tunnel.list` produces both an `amnezia_force4` and an `amnezia_direct4`
   nftset directive, and the classifier's direct rule precedes force (the routing win
   is structural — asserted via rule ordering in test 1).
4. force4 loading is **unchanged** (regression: existing force behaviour still
   populates `amnezia_force4` and writes `amnezia-force.conf`).
5. `direct-add` / `direct-remove` mutate `direct-tunnel.list` and invoke force-load.
6. Empty `direct-tunnel.list` writes an empty `amnezia-direct.conf` (no stale
   directives), same as force's empty-list path.

Plus the existing `fw4 check` discipline for the classifier (validated in the live
smoke, stage 9). Run the full bats suite (regression on force-load/autotunnel).

## Non-goals

- No LuCI UI for the direct list (backend + CLI only; add later if wanted).
- No per-tunnel selection — direct-override means WAN, full stop.
- Not narrowing the Google AS force-source (kept as-is; YouTube depends on it).

## Rollout

Live-router: surgical per CLAUDE.md — snapshot each replaced file, upload, `fw4 check`
before any reload, `( sleep 1 && fw4 reload ) &` backgrounded, then verify WAN + DNS +
handshake **and** the actual override (client flow to `chat.google.com` egresses WAN,
not the tunnel) before declaring done.
