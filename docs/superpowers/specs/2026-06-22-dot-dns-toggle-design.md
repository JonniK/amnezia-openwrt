# Encrypted DNS (DoT) Toggle with Tunnel-Pinned Fallback Chain — Design

**Date:** 2026-06-22
**Branch:** `feat/autolearn-bypass` (DNS work may move to its own `feat/dot-dns` branch at plan time)
**Status:** approved (brainstorm) → design-review converged over 2 cycles. Cycle 1: 3 C + 9 H (two reviewers) — resolved (leak-free chain rework). Cycle 2: cycle-1 items confirmed closed; 2 new H (dnsmasq/force-load concurrency lock + flap hysteresis; DoH hostname-URL+bootstrap cert fix) — resolved here. Pending: writing-plans.

## Goal

Replace today's reliance on the **ISP resolver** (plaintext, on the direct path, poisonable for blocked domains) with a **user-toggleable encrypted DNS** stack driven from the LuCI page:

1. **DoT on/off** toggle. OFF ⇒ exactly today's behaviour (dnsmasq forwards to WAN-DHCP provider resolvers). ON ⇒ encrypted DNS with the layered chain below.
2. **Provider dropdown** — switch the resolver provider live (Quad9 default, plus AdGuard / dns0.eu / Mullvad / Google / Custom).

When ON, resolution is **two leak-free encrypted tiers** plus a **health-gated plaintext last resort**:

1. **DoT** (stubby) → chosen provider, **routed through the sticky tunnel** (encrypted *and* hidden from the ISP, unblockable).
2. If the tunnel is down → **DoH** (https-dns-proxy) → same provider, **direct over WAN** (still encrypted/tamper-proof; 443 blends with HTTPS).
3. Only if **both encrypted tiers are confirmed dead** by a health watchdog → **plaintext provider DNS** (today's behaviour), as an explicitly **surfaced warning state** — never a silent per-query peer.

**Non-goals.** No change to failover/health/sticky logic, the RU-direct CIDR loader, the force-allowlist engine, or `routing_mode`. This feature only owns the *resolver chain* and its UI.

## Constraints (carried from project history)

- **Never break client internet.** Every mutation reloads atomically and **fails toward a working resolver**: manual `enable` verifies resolution **through an encrypted tier** and **auto-reverts to plain provider DNS** if that fails; the health watchdog gates the plaintext tier in/out with a visible status.
- **No Cloudflare** anywhere in the shipped profiles (explicit user requirement). Because both daemons ship Cloudflare *default* upstreams, "no Cloudflare" is a **fail-closed gate**: `apply` deletes the stock sections and a test asserts no Cloudflare endpoint survives in the rendered config.
- **No silent DNS leak.** Plaintext (tier 3) is never a co-equal dnsmasq `server=` while an encrypted tier might work — see "Why not plain `strict-order` over three tiers" below. The force-allowlist confdir (`/etc/amnezia/dnsmasq.d/`) is never touched by this feature.
- POSIX sh / BusyBox ash for router scripts; LuCI client JS for browser work.
- Source lives in `openwrt/`; `dev/sync-to-packages.sh` mirrors into `packages/` (CI sync-check enforces parity). The sync script is a **hand-maintained allow-list**, not a glob — every new file is an explicit work item.
- Live-router application is a **separate, later step** after unit/VM verification, each router action preceded by its rollback and a WAN+DNS+handshake check (per CLAUDE.md live-router rules).

---

## Current DNS state (recap, measured on the live router 2026-06-22)

- dnsmasq is the LAN resolver (`192.168.1.1:53`). `resolvfile=/tmp/resolv.conf.d/resolv.conf.auto`, no `server=`, no `noresolv` ⇒ forwards to **WAN-DHCP provider resolvers** (`109.195.112.1`, `5.3.3.3`).
- `confdir=/etc/amnezia/dnsmasq.d` holds the force-allowlist `nftset=` chunks — **owned by force-load, out of scope here.**
- `awgN.conf` `DNS =` fields are **ignored** by the OpenWrt `amneziawg` proto. The awg server runs **no** internal resolver (`10.8.1.1` does not answer DoT through either tunnel — probed, timed out).
- Router-originated traffic (dnsmasq → upstream) is **not** marked by the prerouting classifier, so it egresses via the **main table → WAN** unless an explicit `ip rule`/route says otherwise.

---

## Resolver chain (the mechanism)

### Two encrypted tiers via dnsmasq `strict-order` (leak-free)

dnsmasq is configured `noresolv=1` + `strict-order` with **exactly two** loopback upstreams — both encrypted:

| # | Tier | Daemon / listen | Upstream | Egress |
|---|------|-----------------|----------|--------|
| 1 | DoT | stubby `127.0.0.1#5453` | provider **DoT primary IP** `@853` (strict TLS auth by `tls_auth_name`) | **sticky tunnel** via `ip rule to <DoT-IP> lookup 100 pref 30900` |
| 2 | DoH | https-dns-proxy `127.0.0.1#5454` | provider **DoH hostname URL** `https://<host>/dns-query` + `bootstrap_dns=<DoH-IP>` | **direct / WAN** (main table) |

**DoH uses a hostname URL, not an IP literal.** https-dns-proxy validates the upstream TLS cert against the URL host; most providers' DoH certs carry **hostname** SANs only (AdGuard, Mullvad, dns0.eu have no bare-IP SAN), so an IP-literal URL would fail cert validation and silently kill tier-2 for half the profiles. The bootstrap-loop concern (resolving the URL host through dnsmasq, which points at this very proxy) is instead solved by https-dns-proxy's **`bootstrap_dns=<DoH-IP>`** — it resolves the hostname directly against the pinned IP, never through dnsmasq. So each profile still pins a concrete **DoH-IP** (for `bootstrap_dns`), but the cert validates against the hostname.

Because **both** upstreams are encrypted local proxies, the strict-order fall-through can only ever land on another encrypted tier — **a per-query fall-through from DoT to DoH never leaks.** This is the key change from the first draft, which listed plaintext provider as a third strict-order peer; under dnsmasq `strict-order` a *lossy* tier-1 (stubby up but stalling) advances the *same* query to the next `server=`, so a plaintext peer would leak blocked-domain lookups to the ISP-reachable provider on exactly the flaky-tunnel conditions the feature targets. Plaintext must therefore be gated by health, not by strict-order (next section).

**`strict-order` semantics we rely on (verified against dnsmasq behavior):** without `all-servers`, dnsmasq sends a query to one upstream and advances to the next only on timeout/SERVFAIL; `strict-order` forces that probing to start from the first listed server every query (instead of fastest-RTT). So while tier-1 answers, tier-2 is never contacted (no leak between encrypted tiers either); when tier-1 fails the query advances to tier-2; and recovery is automatic (each query re-tries tier-1 first). The live leak-test below validates this empirically rather than trusting the manual.

**Tunnel egress + the failover blackhole.** Table 100 is the *sticky* table, owned by `amnezia-failover` (`routing_set_sticky_default`). The `to <DoT-IP> lookup 100` rule is **tunnel-agnostic by design**: it follows whatever tunnel the daemon currently points table 100 at (the configured `sticky_target`, default awg1, or the best pool member during failover) — so it self-heals across *all* tunnels, not just awg1 recovery. Two sub-cases when tunnels are unhealthy, both handled:
- **All tunnels down ⇒ table 100 holds `blackhole default`** (`amnezia-routing.sh`). The DoT packet is dropped with an immediate `EHOSTUNREACH` → stubby fails **fast** → dnsmasq advances to tier-2 (DoH/WAN) promptly. This is the desired outcome (tier-1 never falls through to cleartext WAN), and it is *fast*, not a timeout stall.
- **Transient stale route** (dead `dev awgN` still in table 100 for one poll before the daemon swings it to blackhole) ⇒ packets blackhole at the dead device; bounded by a **short, explicit stubby timeout** (value pinned in the plan, e.g. 2s) so tier-2 is still reached quickly. dnsmasq cache absorbs repeats.

**Rule priority — pinned and documented.** `pref 30900` sits **above pbr's 30000 cleanup line** (survives pbr teardown, per `amnezia-common.sh`) and **below the sticky fwmark rules at 31000/31001** (evaluated first, which is correct: router-origin DNS carries no fwmark, so only this `to`-selector should steer it). The plan asserts: exactly one such rule exists, it is keyed by the exact normalized `to <IP> pref 30900 lookup 100` triple for idempotent delete-then-add (mirroring `_rule_exists`'s kernel-normalization handling, e.g. `/32` and hex-mask reprinting), and pref 30900 is unused by zapret/pbr.

### Plaintext last resort — health-gated, never a strict-order peer

A lightweight watchdog (procd-respawned `amnezia-dns-ctl watchdog`, ~every 20s) probes the two **encrypted** listeners (`127.0.0.1#5453`, `127.0.0.1#5454`). State machine **with anti-flap hysteresis**:
- **Either encrypted tier healthy ⇒** dnsmasq has only the two encrypted `server=` entries. No plaintext anywhere. `active_tier` = `dot` or `doh`.
- **Both encrypted tiers failing for `N` consecutive probes (enter threshold) ⇒** add provider IPs — **re-read live from `/tmp/resolv.conf.d/resolv.conf.auto` at gate-time** (not a stale cached capture) — as `server=` (plaintext, direct), reload dnsmasq, set a **persisted `active_tier=plaintext` warning flag**. The only path to cleartext, and *visible*.
- **An encrypted tier healthy for `M` consecutive probes AND a minimum plaintext dwell elapsed (exit threshold) ⇒** remove the plaintext `server=`, clear the warning, reload. Asymmetric `N`/`M` + min-dwell prevents a borderline DoH endpoint from reloading dnsmasq every cycle.

**Single-writer lock (gates "never break client internet").** The watchdog, `apply`, `enable`, `set-provider`, the boot init, **and force-load** all mutate `dhcp.@dnsmasq[0]` + reload dnsmasq. Without serialization, two concurrent `uci commit dhcp` are last-writer-wins (one side's edit silently dropped) and a reload racing a restart can leave a half-applied config — a live DNS outage. **All dnsmasq/`dhcp` mutations in this feature take a shared `flock` on `/var/lock/amnezia-dnsmasq.lock`**, and force-load's existing dnsmasq commit+restart is wrapped in the **same** lock (a minimal, serialization-only touch to force-load — no logic change, despite force-load being a non-goal otherwise). A bats test interleaves a watchdog plaintext-add with a force-load domain-change and asserts both edits survive.

This honors "if DoH fails, then provider DNS" (the user's explicit ask) **without** the per-query leak, because plaintext enters the candidate set only after confirmed total encrypted failure, and leaves the moment encryption returns. Tier-2 DoH (direct/WAN) already covers the common "tunnel down but internet up" case, so the plaintext tier should fire only when the ISP additionally blocks the DoH endpoint — genuinely rare, and now alarmed when it happens.

> **Why a watchdog and not pure `strict-order`** (revisiting the v1 YAGNI call): the leak analysis above forces it. The cost is one tiny procd loop reusing the listener probes `status` already needs. The failover daemon is *not* extended — tunnel-health ≠ DNS-tier-health (DoH works when the tunnel is down), so DNS-tier liveness is its own loopback DNS probe.

### IPv6 — no leak, v4-only endpoints

- All shipped-profile DoT/DoH endpoints are **v4 IP literals** (asserted invariant). No `ip -6 rule` is needed because there is no v6 upstream.
- `noresolv` is what makes this safe end-to-end: dnsmasq forwards **every** query (A *and* AAAA) only to the loopback proxies — it has no other upstream, so there is no v6 (or v4) leak path out of dnsmasq regardless of the query type. stubby/https-dns-proxy make the actual provider connection over v4 (tunnel-pinned / direct respectively). stubby's `::1@5453` listen line is dropped (loopback v4 is sufficient and avoids implying a v6 upstream).
- **Boundary stated explicitly:** clients configured with their *own* resolver (RA-advertised v6 resolver, hardcoded `8.8.8.8`, DoH-in-browser) bypass the router resolver entirely; this feature cannot encrypt those and does not try to. It does not add or change the existing `amnezia_v6_drop` firewall behavior.

---

## Provider profiles

A profile is a record the `amnezia-dns-ctl` table owns: `name → { dot_ip@853, dot_tls_host, doh_url(IP-literal) }`. `amnezia.config.dns_provider` selects one. Shipped (all free, non-Cloudflare):

| Profile | Notes |
|---|---|
| `quad9` (default) | Swiss foundation, malware-filtering, privacy-first |
| `adguard` | DNS-level ad/tracker blocking |
| `dns0` | EU, GDPR, privacy-focused (IP-pin maintenance risk noted — see Risks) |
| `mullvad` | No-log, VPN-grade, block variants |
| `google` | Most robust uptime; **large US logging provider** — dropdown help-text states this so the choice is informed |
| `custom` | user-supplied `dot_resolver` (`<ip>@853#<tls-host>`) and `doh_resolver` (`https://<host>/dns-query`) **plus a required bootstrap IP**; a hostname DoH URL is allowed (it must be, for cert validation) but the bootstrap IP is mandatory |

> **Per-profile invariant, proven at plan time, not from memory:** for each shipped profile, record the concrete **DoT-IP** (stubby `address`), the **DoH hostname** (cert SAN), and the **DoH-IP** (`bootstrap_dns`), verified against the provider's published docs **and** a live resolution probe; assert (a) **DoT-IP ≠ DoH-IP** — the lookup-100 rule pins the DoT-IP into the tunnel, so the DoH bootstrap IP must be a *different* address or the DoH fallback gets dragged into the dead tunnel exactly when needed; (b) the DoH cert validates against its hostname via `bootstrap_dns` (no dnsmasq loop); (c) both IPs are stable published anycast literals; (d) no other `ip rule`/route references the DoH-IP. **Drop any profile that cannot satisfy this** rather than shipping a silently-broken fallback.

---

## Components

### UCI state (`/etc/config/amnezia`, `config amnezia 'config'`)

```
option dot_enabled  '0'        # master toggle; 0 = today's provider DNS
option dns_provider 'quad9'    # selected profile
option dot_resolver ''         # custom only: <ip>@853#<tls-host>
option doh_resolver ''         # custom only: https://<ip-literal>/dns-query
# runtime, written by the watchdog (not user-edited):
option dns_active_tier 'dot'   # dot | doh | plaintext  (drives UI warning)
```

### New CLI `/usr/bin/amnezia-dns-ctl`

POSIX sh, sources `amnezia-common.sh`. UCI reads use `uci -q get` (quoting/list discipline). Verbs:

- **`status`** → JSON `{ "enabled": bool, "provider": str, "active_tier": "dot|doh|plaintext", "encrypted": bool, "healthy": bool }`. `active_tier` is read from the watchdog flag; `encrypted` = active tier ∈ {dot,doh}. **Bounded** (each listener probe ≤1s) and **never triggers `apply`**, so the UI status call can't stall during an outage.
- **`enable`** → preflight: confirm `stubby` + `https-dns-proxy` **binaries present** (else fail with "install packages first", no mutation). Set `dot_enabled=1`, commit → `apply` → **verify through an encrypted tier**: probe `127.0.0.1#5453` and `127.0.0.1#5454` directly (not `#53`, which could be answered by a plaintext tier). Success **only** if an encrypted tier resolves a control domain. On failure: **auto-revert** to plain provider DNS, `dot_enabled=0`, non-zero exit, message to UI.
- **`set-provider <name>`** → validate (custom ⇒ DoH IP-literal). Persist `dns_provider_prev`, set new `dns_provider`. If `dot_enabled=1`: `apply` + encrypted-tier verify; on failure roll back to `dns_provider_prev` and re-verify; if that also fails, drop to `dot_enabled=0` plain. End-state matrix defined in the plan; UI reflects the actual landing state.
- **`apply`** (idempotent; used by `enable`, `set-provider`, init, hotplug, watchdog) → **under the `/var/lock/amnezia-dnsmasq.lock` flock**: render stubby + https-dns-proxy **via their UCI** (see below); set dnsmasq via **UCI `dhcp.@dnsmasq[0]` options** — `.noresolv='1'`, `.strictorder='1'`, and `.server` **list** entries (`add_list`/`del_list` keyed by exact value `127.0.0.1#5453` / `127.0.0.1#5454`, so the watchdog can add/remove the plaintext entry without disturbing the encrypted ones, and `disable` removes exactly ours); install the `ip rule` (delete-then-add by normalized triple); restart stubby + https-dns-proxy; **`dnsmasq --test` the assembled config, and only on pass** do a **backgrounded** dnsmasq reload. **If a binary is missing** (e.g. post-sysupgrade), do **not** wedge DNS: fall back to plain provider config and set `active_tier=plaintext` + warning. **No auto-revert** here (boot/watchdog own degradation), but also **no silent encrypted-claim** — the missing-binary fallback is surfaced.
- **`disable`** → restore dnsmasq to `resolvfile` (drop `noresolv`/`strict-order`/our `server=`), remove the `ip rule`, stop+disable stubby and https-dns-proxy and the watchdog, clear `active_tier`, `dot_enabled=0`, commit, backgrounded dnsmasq reload.
- **`watchdog`** → the procd-respawned loop described in "Plaintext last resort."

**Fail-closed ordering.** `apply` is re-runnable; every mutation is delete-then-add. dnsmasq reloads **only after** `dnsmasq --test` passes — a bad render never takes DNS down.

### Daemon configs — driven via the packages' own UCI (not hand-written)

Both `stubby` and `https-dns-proxy` ship `/etc/config/{stubby,https-dns-proxy}` whose init scripts **regenerate** runtime config on start; hand-writing `stubby.yml` would be clobbered and could fall back to the packages' **Cloudflare/Quad9 default upstreams** (a no-Cloudflare violation). Therefore `apply` drives **their UCI**:
- **stubby** — `uci -q delete` **all** stock `stubby.@resolver[*]` sections, add a single resolver = profile DoT (`address`, `tls_auth_name`, strict `tls_authentication`/spki), listen `127.0.0.1@5453` only, short timeout; `uci commit stubby; /etc/init.d/stubby restart`.
- **https-dns-proxy** — `uci -q delete` **all** stock `@https-dns-proxy[*]` sections (the Cloudflare defaults), add a single section = profile DoH IP-literal URL, listen `127.0.0.1:5454`, `bootstrap_dns` = the same pinned IP; commit + restart.
- A test asserts **no Cloudflare IP/host** remains in either rendered config.

### Persistence — triggers (mirrors force-load's robustness)

- **`/etc/init.d/amnezia-dns`** (`START` after network/failover) → if `dot_enabled=1`, `apply` (tolerant of "no tunnel yet": the chain degrades to DoH; the watchdog gates plaintext if even DoH can't start) and start the watchdog.
- **Hotplug — lead with the firewall-reload trigger** (the proven project precedent: `99-amnezia-force-load.hotplug` keys off `ACTION=reload` in `hotplug.d/firewall/`, sidestepping the documented awg boot race and the `ifup`-vs-`ifupdate` unreliability). A firewall `reload` re-asserts the `ip rule` and refreshes the live-read provider IPs — no new `hotplug.d/iface/` dir, no extra sync mkdir. Only if live `logread` shows the firewall trigger misses a needed sticky-tunnel-up event do we add a scoped iface hotplug; that decision is pinned at plan time against a captured awg1 flap.

### LuCI UI (`main.js` + ACL)

- New controls near the routing-mode block: a **DoT on/off** toggle and a **provider dropdown** (6 options; Custom reveals two text inputs). Both call `fs.exec('/usr/bin/amnezia-dns-ctl', [...])`, exactly like the `set-routing-mode` precedent. A **status line shows `active_tier`**, and renders a **visible warning when `active_tier=plaintext`** ("encrypted DNS unavailable — on plaintext fallback").
- **ACL** — edit the canonical source `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json` (sync mirrors it to `packages/.../rpcd/acl.d/`): add `"/usr/bin/amnezia-dns-ctl": ["exec"]` under the existing **`write.file`** block (mirroring `amnezia-failover-ctl`). No new `read.file` entry (status is exec-derived, no JSON state file).

### Installer / packaging

- `install-amnezia-pbr.sh`: `opkg update && opkg install stubby https-dns-proxy` **guarded** (skip if present) and **before any dnsmasq mutation**, on the working/plain resolver — never from inside `enable`/`apply`. Install the new CLI + init + hotplug + ACL.
- **Sysupgrade caveat (documented):** these packages are not in the firmware image, so a sysupgrade removes the binaries while `dot_enabled=1` persists. The boot `apply`'s **missing-binary fallback** (→ plain + `active_tier=plaintext` warning) prevents a silent degraded boot; the docs tell the user to re-install the two packages (or bake a custom image) after sysupgrade.
- Mirror every new file into `packages/` via `dev/sync-to-packages.sh` — **explicit edits required**: add `amnezia-dns-ctl` to its wrapper list, add the init + the new `hotplug.d/iface/` path (the script currently only `mkdir`s `hotplug.d/firewall`), and the ACL. CI sync-check must stay green.

---

## Testing

bats unit tests with stubs in the **exact real output format** (CLAUDE.md rule):

1. `enable` (binaries present) → encrypted-tier verify ok → dnsmasq has `noresolv`+`strict-order`+exactly the **two** encrypted `server=`; `ip rule` present; **no plaintext server=**.
2. `enable` → encrypted verify fails → **auto-revert**: `dot_enabled=0`, dnsmasq back on `resolvfile`, no stray `ip rule`, non-zero exit.
3. `enable` with a **missing binary** → preflight refuses (no mutation); and the `apply` missing-binary path → plain + `active_tier=plaintext` warning, never wedged.
4. `disable` fully restores today's provider config (no `noresolv`, no our `server=`, no `ip rule`, watchdog stopped).
5. `set-provider` for each shipped profile renders a **DoT-IP ≠ DoH-bootstrap-IP** (asserts the two-distinct-IP invariant), a **hostname** DoH `resolver_url` + `bootstrap_dns=<DoH-IP>`, and a stubby/https-dns-proxy UCI with **no Cloudflare** surviving; `custom` parses user endpoints, **accepts a hostname DoH URL**, and **requires a bootstrap IP** (rejects a missing one).
6. `apply` idempotent (run twice → identical state, single `ip rule`; uses the kernel-normalized selector so boot-init + hotplug double-apply can't duplicate).
7. **Watchdog state machine:** both-encrypted-down for `N` probes → adds plaintext (live-read provider IPs) + sets warning flag; recovery for `M` probes + min-dwell → removes plaintext + clears flag; a borderline tier toggling each probe does **not** flap (hysteresis holds).
8b. **Lock serialization:** interleave a watchdog plaintext-add with a force-load domain-change (both under `/var/lock/amnezia-dnsmasq.lock`) → both edits survive, dnsmasq never reloaded on a half-written `dhcp` section.
8. **`dnsmasq --test` gate is actually exercised** — the current stub (`exit 0` for everything) makes the headline safety test vacuous; **upgrade the dnsmasq stub** to reject the malformation classes the gate guards (oversized `server=`/line, malformed `server=`, bad `nftset`) — or run real `dnsmasq --test` in CI. A deliberately-bad render must be rejected **before** reload.

**Live-only gates (explicit — a green bats run is not proof; the VM's dnsmasq doesn't serve real queries):**
- **Leak test:** enable DoT, `tcpdump` WAN `:53` while resolving control domains with tier-1 artificially **stalled** (not just down) — assert **zero** cleartext `:53` to the provider until the watchdog deliberately gates plaintext.
- **nftset tagging:** enable DoT, resolve a force-listed domain, assert its IP lands in `amnezia_force4` and routes through the tunnel (confirms encrypted upstreams don't break the force-allowlist tagging path).
- **Failover interaction:** with DoT on, force a sticky failover and confirm DNS continues via the new sticky tunnel (lookup-100 follows it).
- **Enable auto-revert:** `enable` against a deliberately-broken DoT/DoH endpoint must fail the encrypted-tier verify and auto-revert to plain provider DNS (the verify is a real network dependency, fully stubbed in bats — so the revert path is only truly proven live).

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Plaintext tier leaks per-query under a lossy tunnel (the v1 strict-order flaw) | Plaintext is **health-gated**, never a strict-order peer; only two encrypted tiers in `strict-order`; live `tcpdump` leak-test |
| IPv6 upstream leak / unpinned v6 DoT | v4-literal endpoints only; `noresolv` forces all query types to loopback proxies → no v6 (or v4) leak out of dnsmasq; `::1` listener dropped; client-own-resolver boundary stated |
| Tunnel down ⇒ table 100 blackhole stalls tier-1 | Blackhole returns fast `EHOSTUNREACH` (not a timeout); short explicit stubby timeout bounds the stale-route transient; documented so nobody "fixes" it into a WAN fallthrough |
| DoT/DoH share an IP ⇒ fallback pinned into dead tunnel | Two-distinct-IP invariant **proven per profile at plan time**; drop profiles that can't satisfy it; assert no other rule touches the DoH-IP |
| Hand-written daemon config clobbered ⇒ Cloudflare default leak | Drive stubby + https-dns-proxy **via their UCI**, delete stock sections; test asserts no Cloudflare survives |
| IP-literal DoH URL fails TLS cert validation (no IP SAN) ⇒ tier-2 dead for half the profiles | DoH = **hostname URL + `bootstrap_dns=<pinned IP>`**; cert validates against host, bootstrap avoids the dnsmasq loop |
| Watchdog/operator-verbs/force-load race the shared dnsmasq ⇒ lost edits or half-applied reload (DNS outage) | Single `flock /var/lock/amnezia-dnsmasq.lock` over **all** dnsmasq/`dhcp` mutations incl. force-load's reload; UCI `.server` list keyed by exact value; interleave test |
| Plaintext tier flaps on a borderline DoH endpoint ⇒ dnsmasq reload every 20s | Asymmetric enter/exit thresholds (`N`/`M`) + minimum plaintext dwell |
| Packages vanish after sysupgrade ⇒ silent degraded boot | `apply` missing-binary fallback → plain + visible `active_tier=plaintext`; docs: reinstall after sysupgrade; never opkg from `enable`/`apply` |
| `enable` "success" via plaintext ⇒ green status on cleartext | Verify probes the **encrypted listeners** specifically; only encrypted success is green; plaintext is a warning state |
| `dnsmasq --test` gate unprovable with the `exit 0` stub | Upgrade stub to parse malformations (or real `--test` in CI); test #8 |
| force-allowlist nftset tagging silently breaks under encrypted upstreams | Live-only gate (resolve force domain → assert in `amnezia_force4`) |
| Hotplug fires `ifupdate` not `ifup` ⇒ rule not re-asserted | `$ACTION×$INTERFACE` matrix pinned against live `logread`; firewall-reload-hotplug fallback |
| Reload drops SSH | Backgrounded dnsmasq reload per the fw4/dnsmasq-reload-SSH rule |
| `dns0`/IP-pinned providers change IPs ⇒ silent breakage | Prefer stable published anycast; watchdog surfaces the resulting plaintext fallback; note maintenance burden |

---

## Open items deferred to plan

- Branch choice: fold into `feat/autolearn-bypass` or cut `feat/dot-dns`.
- Exact short stubby/dnsmasq timeout values; watchdog probe interval and enter/exit thresholds (`N`/`M`) + min plaintext dwell — pinned at plan time with live observation.
- Concrete per-profile DoT-IP + DoH-hostname + DoH-bootstrap-IP (proven against provider docs + live probe; profiles failing the distinct-IP / cert invariant are dropped).
- The minimal serialization-only patch to force-load (wrap its dnsmasq commit+restart in the shared `flock`) — scoped at plan time so it stays logic-neutral.
- v6 LAN posture: state at plan time whether this router runs with `routing_disable_lan_v6` active (which already kills LAN RA/DHCPv6) so the "client-own-v6-resolver" boundary is concrete, not hypothetical.
