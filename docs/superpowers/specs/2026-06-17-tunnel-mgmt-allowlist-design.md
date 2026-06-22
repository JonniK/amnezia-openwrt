# Tunnel Management + Allowlist Mode — Design

**Date:** 2026-06-17
**Branch:** `feat/multi-tunnel-failover`
**Status:** approved + design-review converged (Stage 2, 2 cycles). Cycle 1: 4 CRITICAL + 6 HIGH resolved. Cycle 2: all closed; 1 new HIGH (proven-vs-unproven dnsmasq inversion) resolved by reverting to the repo's proven `config ipset` mechanism; M/L folded in. 0 C/H open → proceed to plan.

## Goal

Add two user-facing capabilities to the AmneziaWG multi-tunnel stack, driven entirely from the LuCI page:

1. **Add / remove tunnels** from the UI — paste a `.conf` *or* an Amnezia `vpn://` share link; remove an existing tunnel with one click.
2. **"Allowlist" routing mode** — switch the router from "tunnel everything foreign, RU direct" (today's `tunnel-default`) to "everything direct, only addresses/domains from a list go through the tunnel" (the already-scaffolded `direct-default` mode). The list is fed by **auto-updating curated sources** (RKN-blocked + geoblock-RU services; itdoginfo on by default, Re-filter and antifilter.download available to toggle on) **plus manual entries** that auto-update never clobbers.

Non-goal: changing the failover/health logic, the sticky mechanism, or the RU-direct CIDR loader. Those stay as-is.

## Constraints (carried from project history)

- **Never break client internet.** Every mutation reloads atomically and fails *closed* (no WAN cleartext leak; an empty allowlist in direct-default = everything direct, which is safe).
- **Flow offloading stays off** (already enforced) — unaffected here.
- Live-router application is a **separate, later step** after VM verification, and every router action is preceded by its **rollback command**.
- POSIX sh / BusyBox ash only for router scripts; LuCI client JS for browser-side work.
- Source lives in `openwrt/`; `dev/sync-to-packages.sh` mirrors into `packages/` (CI sync-check enforces parity).

---

## Current data model (recap)

A "tunnel" `awgN` is four coupled things:

| Piece | Where | Created by |
|---|---|---|
| Failover membership | `amnezia.awgN` UCI section (`enabled/label/metric/weight/track_ip`) | installer / this feature |
| Credentials file | `/etc/amnezia/awgN.conf` | installer / this feature |
| Network interface | `network.awgN` (proto `amneziawg`) + peer section | `gen_tunnel_uci` |
| Firewall membership | entry in `firewall.vpn.network` list | `routing_firewall_apply` |

The failover daemon enumerates `awg1..awg5` from UCI on every (re)start (`amnezia-failover` `run_loop`), so a newly-added, committed `awgN` + a monitor restart is automatically picked up. `MAX_TUNNELS=5`.

---

## Feature 1 — Add / remove tunnels

### Backend: new helper `amnezia-tunnel-ctl`

`/usr/bin/amnezia-tunnel-ctl <add|remove|list-free> [args]`, sourcing `amnezia-common.sh` + `amnezia-routing.sh`.

**Conf ingestion — argv element, no staging file (resolves R1-C2 / R1-H2).** `add` receives the `.conf` **body as an argv element** — the exact proven pattern the UI already uses for large payloads (`fs.exec('/usr/bin/zapret-apply', ['apply', composed])`, `zapret-verify <csv>`). There is **no `fs.write`** anywhere (the repo has zero `fs.write` precedent and rpcd may not permit it; argv is the proven channel — rpcd passes it as a JSON string over ubus, no shell, newlines are safe). A `.conf` is ~1 KB, far under the ubus message limit. The helper writes the body to a `mktemp` file (mode 600) it owns, parses that, and on success moves it to `/etc/amnezia/<name>.conf` (mode 600). No shared `staging.conf`, so no TOCTOU between concurrent adds.

- **`list-free`** → prints the next free `awgN` (lowest unused index ≤ `MAX_TUNNELS`), or empty + exit 3 if full. Used by the UI to label the slot and to refuse when full.
- **`add <name> <conf-body> [--label L]`**
  1. Validate `name` matches `awg[1-9]`, is ≤ `MAX_TUNNELS`, and is currently free.
  2. Write the `<conf-body>` argv → `mktemp` (mode 600). `parse_awg_conf` it; **then explicitly require `AWG_PrivateKey`, `AWG_PublicKey`, `AWG_Endpoint_host`, AND `AWG_Endpoint_port` to be non-empty** (resolves R1-H1 — `parse_awg_conf` itself only checks the two keys, so a peerless/endpointless conf would otherwise half-create). Refuse (exit 1, rm temp) on any missing field — never half-create.
  3. `gen_tunnel_uci name temp` → apply to `network.*` (parse to a temp, then replay with `uci batch`, mirroring the installer's existing pattern at lines 387/652).
  4. Move temp → `/etc/amnezia/<name>.conf` (mode 600).
  5. Create `amnezia.<name>` section **typed `tunnel`** (`uci set amnezia.<name>=tunnel`, matching the shipped `config tunnel 'awgN'`): `enabled=1`, `label`, `metric`=next, `weight=1`, `track_ip=1.1.1.1`.
  6. `add_list firewall.vpn.network=<name>` (idempotent — delete-then-add the member).
  7. `uci commit network firewall amnezia`; `ifup <name>`; firewall reload (backgrounded subshell per the fw4-reload-SSH rule); `amnezia-failover restart`.
  - All steps are idempotent and ordered so a failure before commit leaves nothing live.
- **`remove <name>`** — **monitor stops FIRST** (resolves R1-H3 / R2-H4: the running daemon must not poll/cleanup an interface mid-teardown, and the pool default must be re-pointed off the dead dev before clients notice).
  1. Refuse (exit 2) if removing it would leave **zero members in `firewall.vpn.network`** (not merely "last *enabled* amnezia section" — the firewall list and the enabled-set are different lists; R1-H4), or if `name == amnezia.globals.sticky_target` (force the user to reassign sticky first).
  2. `/etc/init.d/amnezia-failover stop` — the daemon's cleanup trap frees its probe routes/rules while its section still exists.
  3. `ifdown <name>`; delete `network.<name>` + its `amneziawg_<name>` peer section; remove `<name>` from `firewall.vpn.network`; delete `amnezia.<name>`; `rm -f /etc/amnezia/<name>.conf`.
  4. commit; firewall reload (backgrounded subshell); `/etc/init.d/amnezia-failover start` (re-enumerates the reduced member set and re-points the pool default at a surviving healthy dev on its first poll).
  - Worst case during remove: pool-routed clients see up to one poll (~10s) of blackhole if the removed tunnel was the live carrier — fail-closed, no WAN leak. Documented, not silent.

### vpn:// decoding — **client-side only**

The Amnezia `vpn://` link is `base64url( <4-byte BE length> + <zlib stream> )` of a JSON document that embeds the WireGuard config text. Qt's `qCompress` emits a 4-byte big-endian uncompressed-length prefix followed by a **zlib/RFC1950** stream (2-byte zlib header + Adler-32) — so after dropping the 4-byte prefix the correct WHATWG mode is **`DecompressionStream('deflate')`** (zlib-wrapped), **not** `'deflate-raw'`. Decoding this in BusyBox sh is impractical, so it is browser-only:

- `main.js` gets `decodeVpnLink(text)` (async): strip `vpn://`, base64url-decode to bytes, drop the 4-byte BE prefix, inflate via `DecompressionStream('deflate')`, `JSON.parse`. **Extraction path (pin it so the implementer doesn't guess):** the Amnezia JSON nests the WireGuard text — read `containers[]`, find the AmneziaWG container, its `last_config` field is **itself a JSON string** that must be `JSON.parse`d again, and the `.conf` text lives under that inner object's `config` key. The JS fixture test locks this path against a captured real link.
- On success it **populates the .conf textarea** with the extracted config for the user to review/edit before submitting.
- On any failure (not a vpn:// link, unknown schema, browser without `DecompressionStream`) it shows "couldn't decode this link — paste the .conf text instead" and leaves the textarea untouched.
- **The backend never sees vpn://** — only the resulting `.conf` text. This contains all format fragility in the browser with a manual fallback.

### UI (in `main.js`, new "Add tunnel" sub-section + per-row Remove)

- **Add**: a textarea (placeholder: "paste .conf or vpn:// link"), an optional label field, and an "Add tunnel" button. On submit: if the text starts with `vpn://`, run `decodeVpnLink` first and ask the user to confirm the decoded preview; then call `fs.exec('/usr/bin/amnezia-tunnel-ctl', ['add', name, confBody, '--label', L])` — the conf body is an argv element (same channel as `zapret-apply apply <composed>`), no file write. Disable the button + show the target slot when `list-free` reports full.
- **Remove**: a "Remove" button per row in the existing tunnel table (next to Toggle), guarded by the existing `uiConfirm` modal showing the tunnel name + endpoint. Calls `amnezia-tunnel-ctl remove <name>`.

### ACL additions

```
write.file: /usr/bin/amnezia-tunnel-ctl: [exec]
```
(No file-write grant — `add` ingests the conf via exec stdin; `remove` takes only the tunnel name.)

---

## Feature 2 — Allowlist mode (`direct-default`)

### Routing-mode model

`amnezia.config.routing_mode` ∈ { `tunnel-default` (today), `direct-default` (new) }. The mode selects which classifier chain is active:

| Mode | Classifier behaviour |
|---|---|
| `tunnel-default` | RU-TLD/CIDR → `return` (direct); sticky → `0x0a0000`; **everything else → `0x0b0000` (pool/tunnel)** |
| `direct-default` | sticky → `0x0a0000`; **force-listed → `0x0b0000` (pool/tunnel)**; everything else → `return` (direct) |

### The "list" — `amnezia_force4` set, fed by auto-update sources **+** a manual list

New nft set `amnezia_force4`. **It is declared in the classifier `.nft` fragments** (`set amnezia_force4 { type ipv4_addr; flags interval; auto-merge; }` in BOTH the tunnel-default and direct-default fragments, exactly like `amnezia_ru4`/`amnezia_sticky4` are declared in `30-amnezia-classify.nft:2-4`) — **not** in the dnsmasq script (resolves R1-C2: dnsmasq `config ipset` only *adds elements*, it does not create the set; a chain referencing an undeclared set fails the whole `fw4 reload`). The set must exist in both modes so a mode switch never references an undefined set.

Its contents come from two independent layers, **merged, never mixed in storage** so an auto-update never clobbers a hand-added entry:

| Layer | Storage | Maintained by |
|---|---|---|
| **Auto** (curated remote sources) | `/etc/amnezia/force.d/<source>.list` (one cache file per enabled source) | `amnezia-force-update` (cron + UI button) |
| **Manual** (user entries) | `/etc/amnezia/force-tunnel.list` | the UI editor; auto-update never touches it |

Each line in either layer is **domain or IPv4/CIDR**; the loader classifies per line:
- **IP/CIDR** → loaded directly into `amnezia_force4` (flush + batched add, like `amnezia-ru-cidr`). Because `amnezia_force4` is volatile (lives in `inet fw4`) and is flushed on **every** `fw4 reload`, the IP/CIDR half is **repopulated by a firewall hotplug** — a sibling `99-amnezia-force-load.hotplug` (mirroring the existing `99-amnezia-ru-load.hotplug` that repopulates `amnezia_ru4`) calls `amnezia-force-load` on every firewall reload (resolves R2-C1 — without this the IP half silently empties after the first reload and the allowlist breaks).
- **Domain** → loaded via a **UCI `config ipset` section** — the **proven mechanism this router already runs** for `amnezia_sticky4` and `amnezia_ru_tld4` (`configure-dnsmasq-amnezia.sh:17-33`) (resolves R1-C1 + R2-NEW-H1: do NOT invert proven-vs-unproven — the repo's documented lesson, `docs/ru-tld-bypass.md`/`configure-dnsmasq-ru-nftset.sh`, is "the legacy `dhcp.@dnsmasq[0].nftset` *list* is ignored on 24+, use `config ipset`," and the repo's own answer was `config ipset`, never a conf-dir). `amnezia-force-load` rebuilds the merged list each run regardless, so it regenerates the `dhcp.amnezia_force` ipset section's `add_list domain=` entries declaratively — exactly the `config ipset` model, with no UCI-vs-conf-file divergence. Because newly-added `config ipset` *domains* are read by dnsmasq at (re)start (a plain `reload` does not pick up a structurally-changed ipset section), the domain path uses **`/etc/init.d/dnsmasq restart`** (the existing pattern at `configure-dnsmasq-amnezia.sh:36`) and accepts a brief (~1-2s) DNS blip on a domain-list change; the IP/CIDR path needs no dnsmasq touch at all. Domains do not need the firewall hotplug — dnsmasq re-adds them to the set on the next resolution.
  - **VM-measured scale gate:** the default itdoginfo lists run to tens of thousands of domains. The VM stage MUST measure the `uci commit dhcp` + `dnsmasq restart` time with the *real* default list. If it is unacceptable on the target, the documented fallback is a dnsmasq conf-file of `nftset=` lines via a `conf-dir` whose **exact** OpenWrt-24.10 UCI option is named and proven in the plan first (not "e.g. … / a managed include"). Proven mechanism is primary; the conf-file is a measured, last-resort optimization.

#### Configurable sources (UCI)

**Source → requirement mapping (resolves R2-H1 — both user intents must be covered by the default-on set).** The user requires BOTH (a) RKN-blocked AND (b) geoblock-RU services. itdoginfo/allow-domains splits these into distinct lists: its `Russia/inside-*` set is RKN-censored-from-inside (a), while services that geoblock Russia (b) — OpenAI/ChatGPT, Spotify, etc. — live in a **separate category/list** in that repo. Therefore the default-on itdoginfo source ships as **two URLs, not one**, so requirement (b) is actually covered by default and not silently dropped. The exact list paths/category names are **verified via WebFetch at implementation time** (these repos reorganize files) — the verification MUST confirm a geoblock-RU/services list is among the default-on URLs, recording the resolved paths in the plan.

Per-source UCI sections; **itdoginfo (both intents) enabled by default, the other two present but disabled**:

```
config force_source 'itdoginfo_inside'    # default ON  — (a) RKN-blocked, domains
    option enabled '1'
    option kind 'domains'
    option url '<itdoginfo Russia "inside" raw domains list — resolve at impl>'
config force_source 'itdoginfo_services'  # default ON  — (b) geoblock-RU services, domains
    option enabled '1'
    option kind 'domains'
    option url '<itdoginfo "services/geoblock" raw domains list — resolve at impl>'
config force_source 'refilter_domains'    # default OFF — broader coverage, domains
    option enabled '0'
    option kind 'domains'
    option url '<1andrevich/Re-filter-lists domains_all — resolve at impl>'
config force_source 'refilter_ip'         # default OFF — IP/CIDR for bare-IP services
    option enabled '0'
    option kind 'cidr'
    option url '<1andrevich/Re-filter-lists ipsum — resolve at impl>'
config force_source 'antifilter'          # default OFF — supplementary RKN, domains
    option enabled '0'
    option kind 'domains'
    option url '<antifilter.download domains list — resolve at impl>'
```

#### Helpers

- **`amnezia-force-update`** — for each `enabled` source: fetch with a timeout, validate (non-empty, sane line shape for its `kind`), write atomically to `/etc/amnezia/force.d/<source>.list`; a fetch failure keeps the previous cache (fail-safe, like `amnezia-ru-cidr`'s persist fallback). Writes a `/etc/amnezia/force-update.json` stamp (ts/per-source counts/status) for the UI. Then calls `amnezia-force-load`.
- **`amnezia-force-load`** — merge all `force.d/*.list` + the manual `force-tunnel.list`, dedup, classify, load IP/CIDR into `amnezia_force4` directly, and rebuild the `dhcp.amnezia_force` `config ipset` `add_list domain=` entries. Only restart dnsmasq (`/etc/init.d/dnsmasq restart`) **when the domain set actually changed** (compare a hash of the rebuilt domain list against the last applied; resolves R1-M2 by skipping the restart entirely on IP-only / no-op edits — the unavoidable restart-not-reload for structural `config ipset` changes is bounded to genuine domain deltas). Idempotent; run on edit, after update, on firewall hotplug (IP/CIDR repopulation only — no dnsmasq touch), and at boot. Exposes **`save-manual <content>`** (content as an argv element) so the UI persists the manual list **without `fs.write`** (writes `force-tunnel.list`, then loads).
- **Cron + serialization**: a **daily** line (resolves R2-M3: RKN/geoblock lists churn far faster than RU country-IP blocks) on a slot that does **not** collide with the RU loader's 04:30 Sun slot. `amnezia-force-update`/`-load` take a **dedicated `force-update.lock` flock** (the *lock pattern*, not a shared file — `amnezia-ru-cidr` itself takes no lock; resolves R1-M1 + R2-NEW-M2). The real contention to serialize is the `dhcp` UCI write + `dnsmasq restart`, so the lock scope covers the load step specifically.

### Classifier as a generator

Replace the single static `30-amnezia-classify.nft` with a generator that emits the chain for the *active* mode (still substituting `@@LAN_IFNAME@@`). Implemented as `routing_emit_classifier <mode> <lan_ifname>` in `amnezia-routing.sh`, called by the installer and by the mode switch. Two `.nft` template fragments (tunnel-default = today's file; direct-default = the inverted chain) keep it reviewable.

### Backend: extend `amnezia-failover-ctl`

`set-routing-mode <tunnel-default|direct-default>`:
1. Validate arg.
2. `uci set amnezia.config.routing_mode=<mode>; uci commit amnezia`.
3. Regenerate `/etc/nftables.d/30-amnezia-classify.nft` for the new mode (preserving the live `LAN_IFNAME`).
4. `amnezia-force-load` (ensure the set is populated before the chain references it).
5. firewall reload (backgrounded subshell).
6. **`conntrack -D -m "$POOL_MARK/$MARK_MASK"` then `conntrack -D -m "$STICKY_MARK/$MARK_MASK"`** (resolves R1-H5; sticky form spelled explicitly per R2-NEW-L1, mirroring `amnezia-failover:138`): established flows keep their old ctmark across a mode switch, so without this flush a flow marked-to-pool under `tunnel-default` stays pinned to the tunnel after switching to `direct-default` (and vice-versa — a should-now-be-tunneled flow leaks via WAN until it re-establishes). Flushing forces re-evaluation by the new chain.
- **Monitor**: a restart is *not* required — the ip rules and routing tables are unchanged, and the running daemon's existing ~10s poll already reasserts/reconverges the pool default route (`routing_set_pool_default`) for the new traffic mix. (Clarifies R2-H3: the "no restart" claim is about *rules/tables being unchanged*, and the post-switch route convergence is the daemon's normal poll, not a no-op.)

`set-source <name> <0|1>`: validate `name` against the hardcoded set of known `force_source` section names, `uci set amnezia.<name>.enabled=<v>; uci commit amnezia`. No reload — takes effect on the next `amnezia-force-update`/`-load`.

### Interaction with zapret (resolves R2-H2)

direct-default does **not** conflict with the zapret DPI bypass, and the design depends on understanding why: zapret/nfqws hooks **WAN egress**. Traffic marked to the tunnel (`0x0a0000`/`0x0b0000`) leaves via `awgN` and never touches zapret; **unmarked/direct** traffic goes out the WAN and *is* processed by zapret. So in `direct-default` the *default* path for the whole LAN becomes "WAN + zapret DPI desync" — which is the intended behavior (reach RKN-blocked sites direct-but-desynced, tunnel only the allowlist for geoblock-RU). zapret therefore **stays enabled in both modes**; it is complementary, not exclusive. This is a materially larger zapret load in direct-default (most traffic is now direct) but no correctness conflict.

### UI

A new "Allowlist (force-tunnel)" section, plus a mode control in the Failover section:

- **Mode** radio/select: "Tunnel by default (foreign → tunnel)" vs "Direct by default (only the list → tunnel)". `change` → `amnezia-failover-ctl set-routing-mode <v>`, guarded by `uiConfirm` (it changes routing for the whole LAN).
- **Sources**: a checkbox per `force_source` (label + enabled state), an **"Update now"** button → `fs.exec amnezia-force-update`, and a last-update stamp (reuses the `paintRuStamp` style against `force-update.json`, which the UI reads for per-source counts/status). Toggling a source → `amnezia-failover-ctl set-source <name> <0|1>`.
- **Manual entries**: a textarea pre-filled from `/etc/amnezia/force-tunnel.list` (`fs.read`) with "Save & apply" → `fs.exec('/usr/bin/amnezia-force-load', ['save-manual', listContent])` (content as argv — **no `fs.write`**). Reuses the domain-validation style from `handleVerify`.

### ACL additions

```
read.file:  /etc/amnezia/force-tunnel.list: [read]   # pre-fill the manual editor
read.file:  /etc/amnezia/force-update.json:  [read]   # source counts/status + stamp
write.file: /usr/bin/amnezia-force-load:    [exec]    # incl. save-manual verb
write.file: /usr/bin/amnezia-force-update:  [exec]
# set-routing-mode and set-source reuse the existing amnezia-failover-ctl exec grant
# No write.file grant for force-tunnel.list — save goes through amnezia-force-load save-manual.
# The UI reads only force-update.json (not force.d/*) so no force.d read grant is needed.
```

---

## Fail-closed analysis (don't break the internet)

- **direct-default, empty list** → no dest marked → all LAN traffic uses the main table → WAN direct. Safe (no tunnel, but no outage).
- **direct-default, tunnel(s) down** → force-listed dests mark to pool; pool default is blackholed by the monitor when all members are down → those specific dests fail closed (no cleartext leak), everything else keeps working. Acceptable. (Depends on the set staying populated — the hotplug repopulation above is what makes this hold across firewall reloads.)
- **Mode switch** regenerates the chain + single firewall reload + conntrack flush of pool/sticky marks; no window where LAN→WAN forwarding is dropped (the `vpn_fwd` forwarding + masq zone is untouched; only the mangle/mark chain changes), and established flows are re-evaluated immediately rather than lingering on the old path.
- **Add** never deletes the forwarding zone; on partial failure before commit nothing is live.
- **Remove** stops the monitor *before* tearing the interface down (no mid-poll cleanup of a dead dev), then restarts it; worst case is ≤1 poll (~10s) of fail-closed blackhole for pool-routed clients if the removed tunnel was the live carrier — documented, no WAN leak.

## Testing strategy

1. **bats unit** (`test/unit/`): `amnezia-tunnel-ctl` add/remove/list-free (UCI stubs, golden UCI output); `routing_emit_classifier` both modes (golden `.nft`); `amnezia-force-load` IP-vs-domain classification + merge of auto cache + manual list; `amnezia-force-update` enabled-source iteration + fetch-failure keeps prior cache (stubbed fetch); `set-source`/`set-routing-mode` UCI mutations; refuse-last-tunnel / refuse-sticky-target guards.
2. **JS unit**: `decodeVpnLink` against a captured vpn:// fixture → expected `.conf` (and graceful failure on garbage).
3. **VM integration** (`dev/vm/`): add a 2nd tunnel from a fixture conf (via the argv channel); flip to direct-default with a one-IP + one-domain list, assert the IP marks to pool and a non-listed IP does not; **assert the dnsmasq conf-dir is actually read on the target version (a force domain resolves into `amnezia_force4`)** — the C1 gate before live apply; **`fw4 reload` then assert `amnezia_force4` is still populated** (hotplug repopulation, R2-C1); **mode-switch then assert pool/sticky conntrack was flushed** (R1-H5); flip back; remove the 2nd tunnel and assert the monitor stopped-before-teardown ordering leaves no stale probe route and no WAN leak.
4. **Live apply** (after user confirms VM green): rollback command shown first; apply via the existing deploy path; verify on the real router.

## Rollback (for the eventual live step)

- Pre-change: `tar czf /root/tunnelmgmt-rollback.tar.gz /etc/config/amnezia /etc/config/network /etc/config/firewall /etc/config/dhcp /etc/nftables.d/30-amnezia-classify.nft /etc/amnezia/` and snapshot `uci export`.
- Each router action in the live step is preceded by its specific revert command (the exact `uci`/`cp`/`fw4 reload` to undo it), per standing rule.

## Files touched (summary)

- **New:** `openwrt/amnezia-tunnel-ctl.sh`, `openwrt/amnezia-force-load.sh`, `openwrt/amnezia-force-update.sh`, `openwrt/99-amnezia-force-load.hotplug` (firewall hotplug repopulating `amnezia_force4`), `openwrt/nftables.d/30-amnezia-classify-direct.nft` (direct-default fragment; current file becomes the `tunnel-default` fragment, with the `amnezia_force4` set declared in BOTH).
- **Modified:** `openwrt/amnezia-failover-ctl.sh` (+set-routing-mode w/ conntrack flush, +set-source), `openwrt/lib/amnezia-routing.sh` (+`routing_emit_classifier`), `openwrt/config/amnezia` (+`force_source` sections, itdoginfo inside+services default-on), `openwrt/configure-dnsmasq-amnezia.sh` (+`dhcp.amnezia_force` `config ipset` section pointing at `amnezia_force4`, like the existing `amnezia_sticky` section — the nft *set* itself is declared in the `.nft`, NOT here), `openwrt/install-amnezia-pbr.sh` (install new helpers + hotplug + use the classifier generator + ship default `force-tunnel.list` + `force.d/` dir + daily `amnezia-force-update` cron with the shared flock), `openwrt/luci-app-amnezia/view/main.js` (add/remove UI, mode radio, sources + manual-list editor via `save-manual`, `decodeVpnLink`), `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json`.
- **Tests:** new bats files + JS fixture; VM scenario in `dev/vm/`.
- **Sync (R2-M1 — enumerate, don't hand-wave):** `dev/sync-to-packages.sh` must mirror every new runtime path into `packages/amnezia-pbr/files/`: `amnezia-tunnel-ctl`→`/usr/bin/`, `amnezia-force-load`→`/usr/bin/`, `amnezia-force-update`→`/usr/bin/` (drop `.sh` like the existing loop at `sync-to-packages.sh:50`), `99-amnezia-force-load.hotplug`→`/etc/hotplug.d/firewall/`, `30-amnezia-classify-direct.nft`→`/etc/nftables.d/`, the seeded empty `force-tunnel.list` + `force.d/` dir under `/etc/amnezia/`, and the `force_source` additions to `/etc/config/amnezia` (config file already synced). `sync.bats`/CI sync-check must list all of these.
