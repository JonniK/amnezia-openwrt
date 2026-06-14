# Multi-tunnel AmneziaWG failover — design

**Date:** 2026-06-15
**Status:** Approved for planning · design-review cycle 1 applied
**Repo:** `amnezia-pbr-openwrt` (OpenWrt 24.10 / mediatek-filogic, AX3000T)

## Goal

Let the user configure **up to 5 AmneziaWG tunnels** and automatically route traffic
through a healthy tunnel when the active one becomes unavailable. Default behavior is
**strict-priority failover** (one active tunnel at a time, automatic failback). Optional
per-tunnel **load-balancing** is available via metric/weight, but off by default.

A feature on top of the existing single-tunnel stack (`awg1` + `pbr` + `zapret` +
RU-bypass + LuCI panel). It must not regress current behavior, and **every router-side
change is gated behind a labeled backup and a verified rollback.**

## Decisions taken in design review (safe defaults; user may veto)

- **Sticky failure policy** — the sticky/Claude tunnel **re-pins to the next-best single
  healthy tunnel** if its own tunnel dies (one Cloudflare re-challenge, never a blackhole,
  never per-connection IP variance). Steady-state exit IP is stable; it moves only on a
  real failure of its tunnel. The monitor owns `vpn_sticky` too, not just `vpn_pool`.
- **IPv6 policy** — **fail-closed**: forwarded LAN→WAN IPv6 is dropped so nothing leaks in
  cleartext. Full IPv6 tunnel routing/failover is an explicit follow-up (see Out of scope).
  This changes today's behavior (today `::/0` is tunneled via awg1) in the safe direction.

## Two deliberate tooling decisions

### Reject `mwan3`
mwan3 4.x on OpenWrt 24.10 is still the **iptables-`nft` shim**, not native nftables.
Bolting it onto this nft-native stack means two marking systems fighting over fwmarks and
ip-rule priority — known-flaky coexistence, the project's biggest integration risk. Tunnel
selection is instead **routing-native**: the active tunnel is *which default route the
`vpn_pool` table holds*, owned by a small procd monitor daemon.

### Drop `pbr`, keep `zapret`
This design owns the routing (ip rules, tables, nexthop, monitor), so `pbr`'s
policy→interface engine is unused. **fw4 hosts the classifier natively**
(`/etc/nftables.d/`), **dnsmasq populates domain sets natively** (`nftset=`), and the
RU-CIDR loader is `nft add element`. Removing `pbr` deletes a dependency, removes the
"keep a dummy pbr policy alive" hack, and **permanently eliminates the `/etc/pbr.d/*` glob
footgun** (worst prior burn). `zapret` is **kept unchanged** — a DPI-desync tool on the
*direct* (non-tunneled) path, orthogonal to failover.

> **Migration hazard (design-review C1):** `pbr` auto-creates the set
> `pbr_wan_4_dst_ip_user` that the RU-CIDR loader writes into today. Dropping pbr deletes
> that set. **We must declare our own sets** (see §4) *before* removing pbr, or RU-direct
> silently empties and **all of Russia routes through the tunnel** with no error.

## Approach: native iproute2/nftables

Tunnel selection = which default route `table vpn_pool` holds, managed by a
**procd-supervised monitor daemon**. Classification (RU-direct, sticky-pin) = a native fw4
nft include that sets a fwmark; ip rules send marked traffic to our routing tables.

| Concern | Native approach |
|---|---|
| Failover | monitor health-checks each tunnel, `ip route replace` the `vpn_pool` default to the best |
| Strict failover (default) | single default route in `vpn_pool`, swapped on failure — busybox `ip`, no extra deps |
| Load-balance (opt-in) | nexthop object group, weighted, `type resilient`; `fib_multipath_hash_policy=1` (L4 hashing) |
| Sticky per-connection | kernel flow-hash, free, with the nexthop group |
| Failback | monitor promotes a recovered higher-priority tunnel after N consecutive good checks |
| Classification | native fw4 nft include + dnsmasq `nftset=` + CIDR loader (no pbr) |
| Fail-closed | when no healthy member: blackhole default in `vpn_pool`/`vpn_sticky` (no WAN leak) |
| New deps | `conntrack-tools`; `ip-full`/iproute2 only if LB mode is used |
| Removed deps | `pbr`, `luci-app-pbr` (and the `/etc/pbr.d` footgun) |

### Modern primitives (where there was a fork)
- **Nexthop objects + resilient groups** (`ip nexthop … type resilient`, kernel ≥5.10;
  24.10 = 6.6) over legacy inline `nexthop dev` multipath. LB mode only.
- **procd service** (respawn + ubus) over cron.
- **netifd `ubus` interface-event subscription** + active probing over blind polling.
- **fw4 native nft includes** + **dnsmasq `nftset=`** over the pbr framework.
- **Graceful degradation**: strict failover needs only busybox `ip route replace` (zero
  extra packages); LB mode auto-detects `ip-full` + `CONFIG_IP_ROUTE_MULTIPATH`, disabled
  with a clear status message if unavailable.

### Cloudflare / Claude invariant (drove the default, honestly stated)
Cloudflare flags the AWG exit IP; the Claude mobile app breaks when the exit IP **changes**
(re-triggers the challenge / invalidates `__cf_bm`). The true invariant is *exit-IP
stability over time*, and a failover **does** change the exit IP — so the feature cannot
make failover free of this. What it can do, and does:
- **Default = strict-priority failover**, so there is a single exit IP at a time and it
  changes only on a genuine failover (rare), never per-connection.
- **Sticky pin** keeps Claude/Anthropic (`@amnezia_sticky4`) on one tunnel that moves only
  when *that* tunnel fails (re-pin to next-best single tunnel — one re-challenge, not a
  blackhole). In load-balance mode this is what prevents per-connection IP variance.
- **The existing `amnezia_block_quic` rule is preserved verbatim** (see §2) — it is
  load-bearing for Claude mobile and independent of tunnel count (LAN-scoped).

### Failover hygiene
Failover strands existing connections unless a **selective** `conntrack -D` runs on the
route change. Built-in global conntrack flush is a nuke and is not used.
- *failover mode*: flush the whole pool mark on switch (`-m 0x0B0000/0x0FF0000`).
- *balance mode*: flush **only the removed member's** flows, so surviving flows don't
  re-hash to a new exit (would re-challenge Cloudflare). Per-member conntrack mark needed.

## Architecture

```
            ┌─────────────────────────── LAN traffic ───────────────────────────┐
            │                                                                    │
   nft classifier  (/etc/nftables.d include in inet fw4, prerouting prio mangle) │
            │   declares @amnezia_ru4, @amnezia_ru_tld4, @amnezia_sticky4 (own    │
            │   sets); dnsmasq nftset + CIDR loader feed them                     │
   ┌────────┼──────────────────────────────┬─────────────────────────┐          │
   │ @ru_tld / @ru4 → RETURN (no mark)      │ @sticky →               │ else →   │
   │   → main table → wan (direct, zapret)  │  mark 0x0A → vpn_sticky │ mark 0x0B│
   └────────────────────────────────────────┴─────────────────────────┘ → pool  │
   ip rule: fwmark 0x0A0000/0x0FF0000 → table vpn_sticky  (default = monitor-managed) │
   ip rule: fwmark 0x0B0000/0x0FF0000 → table vpn_pool    (default = monitor-managed) │
       (both hold a blackhole default when no healthy member; only forwarded marked  │
        LAN traffic reaches them — router input/output + mgmt return path never do)   │
                                                  │                               │
                          ┌──────┬──────┬─────────┴─┬──────┬──────┐               │
                          │ awg1 │ awg2 │   awg3    │ awg4 │ awg5 │  (vpn zone)    │
                          └──────┴──────┴───────────┴──────┴──────┘               │
                                                  ▲
                  procd monitor: per-tunnel health (netifd event + awg handshake
                  age + dedicated-route bound ping) → recompute best → ip route/
                  nexthop replace on vpn_pool AND vpn_sticky; blackhole if all down;
                  selective conntrack flush on change
   forwarded LAN→wan IPv6: DROP (fail-closed, no v6 leak)
```

## Components

### 1. Config storage
- Tunnel config files `/etc/amnezia/awgN.conf` (N = 1..5), same AmneziaWG export format.
- UCI `amnezia`: per-tunnel section (`enabled`, `label`, `metric`, `weight`); globals
  `sticky_target` (default `awg1`) and `mode` (`failover` default | `balance`). UCI is the
  source of truth; `.conf` files hold keys/endpoints only.

### 2. Network + firewall (installer becomes a loop)
- Per tunnel: `network.awgN` (`proto amneziawg` + peer) parsed from `awgN.conf`;
  `persistent_keepalive=25`. **IPv4 only in `allowed_ips`** (drop the `::/0` the single-
  tunnel installer adds) — see IPv6 fail-closed below.
- All tunnels in **one `vpn` firewall zone** (`masq=1`, `mtu_fix=1`); verify every awgN is
  in the zone's `network` list (else SNAT missing → replies blackhole). Migration: existing
  `awg1` zone folded into `vpn`.
- **Preserve `firewall.amnezia_block_quic` verbatim.** Migration must not rebuild firewall
  from a template; post-migration assert `uci show firewall.amnezia_block_quic` is intact.
- **IPv6 fail-closed (scoped):** a firewall rule drops **only `forward lan→wan` IPv6** —
  the router's own v6 (input/output: NTP, opkg, ISP DHCPv6-PD renewal) is untouched.
  Additionally **disable LAN RA/DHCPv6 announcements** (`dhcp.lan` ra/dhcpv6 → disabled) so
  LAN clients stay v4-only and don't hold a GUA that blackholes (avoids the happy-eyeballs
  v6-timeout-then-v4 UX stall). No tunneled v6, no v6 leak, no dead client GUAs.
- MTU per-interface (1376 today; tunable later). QUIC PMTU note: 1376 is where Cloudflare
  QUIC PMTU fails — the LAN-scoped block-QUIC rule covers all tunnels, so this stays fine.

### 3. Routing tables + rules (new)
- `/etc/iproute2/rt_tables.d/amnezia.conf` defines `vpn_pool` and `vpn_sticky` ids.
- ip rules: `fwmark 0x0A0000/0x0FF0000 → vpn_sticky`; `fwmark 0x0B0000/0x0FF0000 →
  vpn_pool`. Installed idempotently, masked so they match only the selector nibble.
- Both `vpn_pool` and `vpn_sticky` defaults are **monitor-managed**; each holds an
  `unreachable`/blackhole default whenever its target set has no healthy member
  (fail-closed, no fall-through to main→WAN).
- **Lockout safety (corrected):** these tables are reached **only by forwarded LAN traffic
  the classifier marked** (`ip saddr {LAN}` in prerouting). Router-originated egress is
  never marked → uses `main` → wan. Inbound/return management traffic (LAN↔router, remote
  SSH) is the router's input path + conntrack, which never traverses `vpn_pool`/
  `vpn_sticky`. So a blackhole default **cannot** sever the management plane — no separate
  "management-escape" ip-rule is needed (it would not be expressible as a routing selector
  anyway). Spike confirms: during an all-down event, an admin on LAN still reaches the
  router UI and the RU/direct path.
- **fwmark allocation (consistent across classifier / ip-rule / flush):** selector marks
  live in byte bits 16–23 under mask `0x0FF0000` — `0x0A0000` (sticky), `0x0B0000` (pool).
  Classifier `meta mark set` writes them; ip rules and the conntrack flush both use
  `…/0x0FF0000`. Balance-mode per-member conntrack marks (for member-scoped flush) use a
  **separate** low-byte range (`0x0000NN`) so they never collide with the selector nibble.
  Verified end-to-end in the spike.

### 4. nft classifier include (replaces pbr.d) — owns its own sets
- `/etc/nftables.d/30-amnezia-classify.nft`: **declares** `@amnezia_ru4` and
  `@amnezia_ru_tld4` (`type ipv4_addr; flags interval; auto-merge`) and `@amnezia_sticky4`,
  plus a chain `type filter hook prerouting priority mangle; policy accept;` (priority
  -150, before the ip-rule routing decision). LAN-scoped rules: RU/direct → `return`
  (unmarked → main → wan, where zapret operates); `@amnezia_sticky4 → meta mark set
  0x0A0000`; default LAN → `meta mark set 0x0B0000`.
- **Set migration mapping (explicit, design-review H4/C1):**
  `pbr_ru_tld4` → `@amnezia_ru_tld4` (dnsmasq-fed); `pbr_wan_4_dst_ip_user` →
  `@amnezia_ru4` (CIDR-loader-fed); `seed-must-tunnel.list` / `routing_mode` must-tunnel
  semantics → folded into `@amnezia_sticky4` (preserved, not dropped); LuCI probe that reads
  `seed-must-tunnel.list` updated accordingly.
- dnsmasq config: `nftset=/ru/4#inet#fw4#amnezia_ru_tld4` and the sticky domains →
  `@amnezia_sticky4`. Replaces pbr+dnsmasq wiring with native dnsmasq nftset.
- CIDR loader (port of `ru-direct.sh`): downloads ipdeny RU zone, `nft add element` into
  `@amnezia_ru4`; persists to `/etc/amnezia/ru.cidr`.
- **zapret coexistence:** classifier runs at `mangle` (-150); zapret's nfqueue rules are
  daddr-scoped to the direct (RU/`return`ed) path and must not see tunnel-marked traffic.
  This is load-bearing and **gates the spike *and* the classifier phase**, not deferred.

### 5. Monitor daemon (`/usr/sbin/amnezia-failover`, procd-supervised)
- **Health per tunnel** (cheap→authoritative): netifd `ifstatus` up + AmneziaWG
  last-handshake age (`awg show <if> latest-handshakes`, stale > ~150s = suspect, **tie
  broken by ping** so an idle tunnel isn't falsely downed) + active **bound ping via a
  dedicated probe route**: a per-tunnel route to `track_ip` `dev awgN` in a probe table (or
  `ip route get`+oif), because `ping -I awgN` alone does **not** guarantee egress via awgN
  under policy routing (design-review H3 — correctness precondition, not tuning). Debounce:
  down after 3 fails, up after 3 successes (~15s each at 5s interval).
- **Event-driven + periodic.** Subscribe to netifd `ubus` interface events; also probe on a
  timer.
- **Action.** Recompute best healthy member(s) by `metric`/`weight`, for **both** tables:
  - `vpn_pool`: *failover mode* → `ip route replace default dev <best> table vpn_pool`;
    *balance mode* → replace weighted resilient nexthop group, `ip route replace default
    nhid <group> table vpn_pool`.
  - `vpn_sticky`: keep pinned to `sticky_target` while healthy; if it dies, re-pin to the
    next-best single healthy tunnel (`ip route replace default dev <next> table vpn_sticky`).
  - If **no** healthy member for a table: install blackhole default (fail-closed).
  - On any change: selective conntrack flush (whole pool mark in failover mode;
    removed-member-only in balance mode); clear AmneziaWG peer state for a dropped member if
    the spike shows sticky routing.
- **State output.** `/var/run/amnezia-failover.json` (per-tunnel up/down, active, current
  pool/sticky route, handshake age, exit IP) for LuCI; optionally via ubus.
- **Exit-IP discovery** for the panel: low-frequency, cached, via a lightweight bound probe
  (e.g. one small HTTP/STUN lookup per tunnel, throttled) — or cut from v1 if it risks
  rate-limits. Decide in the monitor phase.

### 6. LuCI panel
- Per-tunnel table: add/paste config, enable/disable, label, `metric`/`weight` editor, live
  status (up/down, active vs standby, which tunnel carries pool/sticky traffic, handshake
  age, exit IP). Plus `mode` and `sticky_target` pickers. Status read from the JSON state
  file via the existing read-only-exec pattern.
- **ACL:** add `/var/run/amnezia-failover.json` to the `read/file` allowlist and the new
  monitor/mode/sticky exec helpers to `write/file/exec` in `acl.d/luci-app-amnezia.json`;
  keep the existing `seed-must-tunnel.list` read entry valid; **remove the stale
  `pbr-status`/`pbr-reload` exec entries** (those binaries go away with pbr).

### 7. Packaging
- New deps: `conntrack-tools`; `ip-full` (iproute2) **only** for balance mode (runtime
  detection). **Remove deps:** `pbr`, `luci-app-pbr` (drop from `amnezia-pbr/Makefile`
  `DEPENDS`); reassess `resolveip`/`ip-full` force-install.
- `dev/sync-to-packages.sh` extended for the monitor, init script, nft include, dnsmasq
  conf, rt_tables file, CIDR loader; remove pbr.d template handling.
- Bump `PKG_RELEASE` on both packages.
- **Migration on upgrade (ordered, idempotent):** (1) declare new nft sets; (2) repoint
  dnsmasq `nftset=` to the new set names + restart dnsmasq; (3) install classifier + ip
  rules + tables + monitor; (4) **precondition-gated** — assert `@amnezia_ru4` is non-empty
  (CIDR loader has run) *before* uninstalling/disabling pbr and removing `/etc/pbr.d/*`, so
  there is no window where RU-direct is empty; (5) post-assert `amnezia_block_quic` intact
  and RU-bypass still populated. Never remove pbr before the replacement is live and
  populated.

## Safety / backup / rollback protocol (mandatory)

Applies to **every** router-mutating step, in the spike **and** every later live phase —
not just the spike.

1. **Backup before any change** via the existing flow (`dev/openwrt-*.sh`,
   `openwrt-backups/`) with a descriptive label, *before* the first mutation of each step.
   Confirm the backup file exists and is non-empty.
2. **Stage, then apply once.** All `uci set`/`commit` first; schedule `fw4 reload` / service
   restarts in a backgrounded subshell `( sleep 1 && … ) &` so SSH exits cleanly. Never
   chain a reload mid-heredoc with following commands.
3. **Poll for recovery**, not blind `sleep`:
   `until ssh -o ConnectTimeout=5 …; do sleep 5; done`. Allow ≥60–90s if any 5GHz DFS/HE160
   reload is involved.
4. **Verified rollback** per live-mutating phase: capture pre-change config; confirm
   `restore → known-good state` works, **and** that `amnezia_block_quic` + RU-bypass survive,
   before moving on.
5. **Lockout safety:** the blackhole/`vpn_*` tables are reachable only by forwarded,
   classifier-marked LAN traffic — router input/output and the management return path use
   `main` and conntrack, never these tables — so a misconfigured tunnel/blackhole cannot
   sever the management plane (verified in the spike: all-down + admin-on-LAN still reaches
   the router UI). No `wifi reload` unless required.

(Memory: `feedback-fw4-reload-ssh-drop`, `feedback-wifi-cac`, `router-workflow`,
`claude-mobile-quic-workaround`; `feedback-pbr-template-glob` is *resolved by deletion*.)

## Risk-first phasing (re-ordered for independence)

1. **Manual hardware spike (throwaway, rollback-tested).** By hand on the live router: 2
   tunnels in a `vpn` zone, the routing tables + ip rules (masked selectors + blackhole),
   the native nft classifier + dnsmasq nftset, a minimal route-replace, IPv6 drop. Verify:
   classifier marks compose with fw4/zapret and RU-direct still works; bound-probe routing
   actually egresses the right tunnel; pulling tunnel 1 reroutes new + (via conntrack flush)
   existing flows; failback; fail-closed when all down; `amnezia_block_quic` + RU-bypass
   survive; LB nexthop group + `fib_multipath_hash_policy` *if* the kernel supports it;
   rollback restores known-good. **Gate: nothing below is built until this recipe is
   confirmed.** This phase is manual and not committed.
2. **Static config artifacts + installer.** Commit the rt_tables file, nft classifier
   include, dnsmasq conf, ip-rule/table generator, and parameterize
   `install-amnezia-pbr.sh` over N tunnels (network/peer/zone, IPv6 drop, QUIC-rule
   preserve, ordered pbr-removal migration). These are the substrate the monitor consumes —
   so they land before the monitor. Script-testable via dry-run UCI/nft generation.
3. **Monitor daemon.** procd service, three-signal health (with dedicated probe route) +
   debounce, route/nexthop replace for both tables, fail-closed blackhole, selective
   conntrack flush, JSON state output. Consumes Phase-2 artifacts.
4. **LuCI panel.** Multi-tunnel table, editors, live status, mode/sticky pickers, ACL
   updates.
5. **Packaging + docs.** Deps (drop pbr/luci-app-pbr), sync, `PKG_RELEASE` bump, README,
   release.

(Phases 2–5 are repo/code work, script-testable without the router. Hardware validation of
2–5 happens manually, backup-first, with the user — outside the autonomous pipeline.)

## Unverified items to resolve in the spike

- `CONFIG_IP_ROUTE_MULTIPATH` / `fib_multipath_hash_policy` / `ip nexthop` resilient groups
  in the stock 24.10 mediatek-filogic kernel (gates LB mode only; global sysctl side-effect
  noted).
- Exact fw4 include hook/priority so the classifier mark is set before the ip-rule routing
  decision and coexists with zapret's nfqueue rules (target: `mangle` -150).
- The dedicated per-tunnel probe-route form that makes bound pings truly egress that tunnel.
- Whether AmneziaWG needs a WG-state clear on member flap.
- Clean ordered pbr removal on an existing install without dropping RU-bypass mid-flight.

## Out of scope (YAGNI)

- **Full IPv6 tunnel routing/failover** — v1 is fail-closed (v6 dropped to wan); v6 policy
  routing is a follow-up.
- More than 5 tunnels.
- Latency/quality-based balancing — metric/weight only.
- Tunneling router-originated DNS — dnsmasq upstream stays router-sourced via main→wan,
  **unchanged from today** (stated so the omission is a decision, not an oversight).
- Auto-import of configs (QR / remote) — user pastes `.conf` as today.
- Replacing `zapret`.

## Sources

mwan3 docs + source (iptables-nft shim on 24.10 → rejected); OpenWrt issues #22474 (ipset
removed → dnsmasq nftset), #17402 (flush_conntrack), #12112 (MSS+PBR); Linux nexthop-object
+ resilient-group docs (kernel ≥5.10); `fib_multipath_hash_policy` sysctl docs; dnsmasq
`nftset=` docs; conntrack/failover write-up (sindro.me 2026-05-01). Kernel-feature claims
are deferred to the hardware spike, not treated as verified.
