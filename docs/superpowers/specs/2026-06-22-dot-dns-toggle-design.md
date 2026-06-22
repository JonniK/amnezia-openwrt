# Encrypted DNS (DoT) Toggle with Tunnel-Pinned Fallback Chain — Design

**Date:** 2026-06-22
**Branch:** `feat/autolearn-bypass` (DNS work may move to its own `feat/dot-dns` branch at plan time)
**Status:** approved (brainstorm). Pending: written-spec review → writing-plans.

## Goal

Replace today's reliance on the **ISP resolver** (plaintext, on the direct path, poisonable for blocked domains) with a **user-toggleable encrypted DNS** stack driven from the LuCI page:

1. **DoT on/off** toggle. OFF ⇒ exactly today's behaviour (dnsmasq forwards to WAN-DHCP provider resolvers). ON ⇒ encrypted DNS with a three-tier fallback chain.
2. **Provider dropdown** — switch the resolver provider live (Quad9 default, plus AdGuard / dns0.eu / Mullvad / Google / Custom).

When ON, resolution degrades gracefully:

1. **DoT** (stubby) → chosen provider, **routed through awg1** (encrypted *and* hidden from the ISP, unblockable).
2. If the tunnel is down → **DoH** (https-dns-proxy) → same provider, **direct over WAN** (still encrypted/tamper-proof; 443 blends with HTTPS).
3. If DoH also fails → **provider DNS** (plaintext, WAN — today's behaviour) as last resort.

**Non-goals.** No change to failover/health/sticky logic, the RU-direct CIDR loader, the force-allowlist engine, or `routing_mode`. This feature only owns the *resolver chain* and its UI.

## Constraints (carried from project history)

- **Never break client internet.** Every mutation reloads atomically and **fails toward a working resolver**: manual `enable` verifies resolution and **auto-reverts to plain provider DNS** if nothing resolves; boot/`apply` relies on the chain's own degradation. The force-allowlist confdir (`/etc/amnezia/dnsmasq.d/`) is never touched by this feature.
- **No Cloudflare** anywhere in the shipped profiles (explicit user requirement — the reason we're leaving the ISP/CF defaults).
- **No DNS leak while a higher tier works.** dnsmasq `strict-order` guarantees tier N+1 is queried *only* on tier N failure, so the provider never sees a query while DoT or DoH works.
- POSIX sh / BusyBox ash for router scripts; LuCI client JS for browser work.
- Source lives in `openwrt/`; `dev/sync-to-packages.sh` mirrors into `packages/` (CI sync-check enforces parity).
- Live-router application is a **separate, later step** after unit/VM verification, each router action preceded by its rollback and a WAN+DNS+handshake check (per CLAUDE.md live-router rules).

---

## Current DNS state (recap, measured on the live router 2026-06-22)

- dnsmasq is the LAN resolver (`192.168.1.1:53`). `resolvfile=/tmp/resolv.conf.d/resolv.conf.auto`, no `server=`, no `noresolv` ⇒ forwards to **WAN-DHCP provider resolvers** (`109.195.112.1`, `5.3.3.3`).
- `confdir=/etc/amnezia/dnsmasq.d` holds the force-allowlist `nftset=` chunks — **owned by force-load, out of scope here.**
- `awgN.conf` `DNS =` fields (`1.1.1.1, 8.8.8.8` etc.) are **ignored** by the OpenWrt `amneziawg` proto — they never reach the resolver. The awg server runs **no** internal resolver (`10.8.1.1` does not answer DoT through either tunnel — probed, timed out).
- Router-originated traffic (dnsmasq → upstream) is **not** marked by the prerouting classifier, so it egresses via the **main table → WAN** unless an explicit `ip rule`/route says otherwise.

---

## Resolver chain (the mechanism)

dnsmasq with **`noresolv=1` + `strict-order`** and three explicit upstreams, in order:

| # | Tier | Daemon / listen | Upstream | Egress |
|---|------|-----------------|----------|--------|
| 1 | DoT | stubby `127.0.0.1#5453` | provider **DoT primary IP** `@853` (TLS auth by hostname) | **awg1** via `ip rule to <DoT-IP> lookup 100` |
| 2 | DoH | https-dns-proxy `127.0.0.1#5454` | provider **DoH secondary IP** (`https://<host>/dns-query`) | **direct / WAN** (main table) |
| 3 | Provider | — (dnsmasq → IP) | WAN-DHCP resolver IPs, captured at `apply` | **direct / WAN** |

**Distinct primary/secondary IPs are mandatory.** DoT (tier 1) and DoH (tier 2) use the **same provider but two different anycast IPs** on purpose. If both used the same IP, the `ip rule … lookup 100` would force the DoH fallback into the *dead* tunnel too, collapsing tier 2 exactly when it's needed. Tier 1 IP is pinned to the tunnel; tier 2 IP stays direct. Using a fixed IP endpoint for DoH (not a hostname) also avoids a bootstrap-DNS chicken-and-egg and a second routing collision.

**Self-healing.** `strict-order` always restarts from tier 1, so when awg1 recovers the chain returns to DoT automatically — no daemon, no state machine. **Cost:** during a full tunnel outage every cache-miss first eats stubby's connect timeout before falling to DoH; we set a **short stubby timeout** to bound it, and dnsmasq's cache absorbs repeats. Acceptable for rare outages.

**Provider tier and `noresolv`.** Because `noresolv=1` makes dnsmasq ignore `resolvfile`, the tier-3 provider IPs are captured from `/tmp/resolv.conf.d/resolv.conf.auto` **at `apply` time** and written as the last `server=` entries. A WAN `ifupdate` hotplug re-runs `apply` so a DHCP renew refreshes them.

---

## Provider profiles

A profile is a small record the `amnezia-dns-ctl` table owns: `name → { dot_ip@853, dot_tls_host, doh_url(IP-pinned) }`. `amnezia.config.dns_provider` selects one. Shipped (all free, non-Cloudflare):

| Profile | Notes |
|---|---|
| `quad9` (default) | Swiss foundation, malware-filtering, privacy-first |
| `adguard` | DNS-level ad/tracker blocking |
| `dns0` | EU, GDPR, privacy-focused |
| `mullvad` | No-log, VPN-grade, block variants |
| `google` | Most robust uptime; large US provider (acceptable as a fallback choice) |
| `custom` | user-supplied `dot_resolver` / `doh_resolver` UCI values |

> **Exact endpoint IPs/hosts are locked at implementation**, verified against each provider's published docs **and** a live resolution probe during `apply` — not asserted from memory here. Each shipped profile must supply two distinct IPs (DoT-primary, DoH-secondary); this is a per-profile invariant the unit tests assert.

---

## Components

### UCI state (`/etc/config/amnezia`, `config amnezia 'config'`)

```
option dot_enabled  '0'        # master toggle; 0 = today's provider DNS
option dns_provider 'quad9'    # selected profile
option dot_resolver ''         # custom only: <ip>@853#<tls-host>
option doh_resolver ''         # custom only: https://<ip>/dns-query
```

### New CLI `/usr/bin/amnezia-dns-ctl`

POSIX sh, sources `amnezia-common.sh`. Verbs:

- **`status`** → JSON `{ "enabled": bool, "provider": str, "active_tier": "dot|doh|provider", "healthy": bool }` for the UI. `active_tier` is derived by probing each local listener in order; `healthy` = any tier resolves a control domain.
- **`enable`** → set `dot_enabled=1`, commit → `apply` → **verify** (resolve a control domain via `127.0.0.1`). On total failure: **auto-revert** (`disable` internals), `dot_enabled=0`, non-zero exit, message surfaced to UI.
- **`set-provider <name>`** → validate, set `dns_provider` (+ custom fields if `custom`), commit → if `dot_enabled=1`, `apply` + verify (same auto-revert-to-*previous-provider*-then-plain on failure); if disabled, just persist.
- **`apply`** (idempotent; used by `enable`, `set-provider`, init, hotplug) → render stubby + https-dns-proxy configs for the selected profile; set dnsmasq (`noresolv`+`strict-order`+3 `server=` with captured provider IPs); install `ip rule to <DoT-IP> lookup 100 pref 30900` (delete-then-add, idempotent); restart stubby + https-dns-proxy, **backgrounded** dnsmasq reload (fw4/dnsmasq-reload-SSH rule). **No** auto-revert here (boot-time degradation is the chain's job).
- **`disable`** → restore dnsmasq to `resolvfile` (drop `noresolv`/`strict-order`/our `server=`), remove the `ip rule`, stop+disable stubby and https-dns-proxy, `dot_enabled=0`, commit, backgrounded dnsmasq reload.

**Idempotency & fail-closed ordering.** `apply` is re-runnable; every mutation is delete-then-add. dnsmasq is only reloaded after its config validates (`dnsmasq --test`), mirroring the existing >1024-byte chunking guard — a bad render never takes DNS down.

### Daemon configs (generated, never hand-edited)

- **stubby** → `/etc/stubby/stubby.yml` (or UCI `/etc/config/stubby`): listen `127.0.0.1@5453` + `::1@5453`, **single** upstream = profile DoT (strict TLS auth by hostname, `tls_authentication: GETDNS_AUTHENTICATION_REQUIRED`), short timeout. No Cloudflare/Quad9-default servers from the package template.
- **https-dns-proxy** → its UCI/config: listen `127.0.0.1#5454`, upstream = profile DoH **IP-pinned** URL, egress direct (no ip rule). `bootstrap_dns` set to the same pinned IP to avoid recursion.

### Persistence — two triggers (mirrors force-load)

- **`/etc/init.d/amnezia-dns`** (`START` after network/failover) → `amnezia-dns-ctl apply` when `dot_enabled=1`.
- **`/etc/hotplug.d/iface/99-amnezia-dns`** → on **awg1 ifup** re-assert (`apply`, mainly to re-add the `ip rule` after a reboot/flush and survive the known pbr/failover boot race), and on **WAN ifupdate** refresh the tier-3 provider IPs.

### LuCI UI (`main.js` + ACL)

- New controls near the routing-mode block: a **DoT on/off** toggle and a **provider dropdown** (6 options; Custom reveals two text inputs). Both call `fs.exec('/usr/bin/amnezia-dns-ctl', [...])`, exactly like the `set-routing-mode` precedent. Status line shows `active_tier` from `amnezia-dns-ctl status`.
- **ACL** (`acl.d/luci-app-amnezia.json`): add `/usr/bin/amnezia-dns-ctl` to the permitted `file.exec` list (read+exec).

### Installer / packaging

- `install-amnezia-pbr.sh`: `opkg install stubby https-dns-proxy` (guarded — skip if present); install the new init + hotplug + CLI.
- Mirror everything into `packages/` via `dev/sync-to-packages.sh`; CI sync-check must stay green.

---

## Testing

bats unit tests with stubs in the **exact real output format** (CLAUDE.md rule — `uci` quotes values & one-lines lists; `dnsmasq --test`; `ip rule`; `stubby`/`https-dns-proxy` init):

1. `enable` → verify-ok → dnsmasq has `noresolv`+`strict-order`+3 ordered `server=`; `ip rule` present.
2. `enable` → verify-fail → **auto-revert**: `dot_enabled=0`, dnsmasq back on `resolvfile`, no stray `ip rule`, non-zero exit.
3. `disable` fully restores today's provider config (no `noresolv`, no our `server=`, no `ip rule`).
4. `set-provider` for each shipped profile renders distinct DoT/DoH IPs (asserts the two-distinct-IP invariant) and a valid stubby/DoH config; `custom` parses user endpoints.
5. `apply` is idempotent (run twice → identical state, single `ip rule`).
6. dnsmasq render passes `dnsmasq --test`; a deliberately bad render is rejected **before** reload (no DNS-down).
7. tier-3 provider IPs are captured from a stubbed `resolv.conf.auto`.

VM smoke (`dev/vm/`) where it can observe; **live verification on real hardware** is the final gate (the VM's dnsmasq blind spot for real queries is exactly where a live-only bug hides).

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| DoT/DoH share an IP → fallback pinned into dead tunnel | Two-distinct-IP invariant per profile, asserted in tests |
| `noresolv` drops provider fallback | Capture WAN resolver IPs at `apply`; WAN hotplug refreshes on DHCP renew |
| Boot race: awg1 not up at boot ⇒ tier-1 fails | Chain degrades to DoH/provider automatically; awg1-ifup hotplug re-asserts the `ip rule` |
| Bad generated dnsmasq config ⇒ DNS outage | `dnsmasq --test` gate before any reload |
| Total degradation leaks plaintext to provider | Accepted by design (last resort); only when both tunnel **and** DoH are down |
| Package missing on a stripped image | Installer guards `opkg install`; `enable` verify auto-reverts if daemons absent |
| Reload drops SSH | Backgrounded dnsmasq reload per the fw4/dnsmasq-reload-SSH rule |

---

## Open items deferred to plan

- Branch choice: fold into `feat/autolearn-bypass` or cut `feat/dot-dns`.
- Whether the failover daemon should additionally *nudge* a faster tier switch on a known tunnel-down transition (optimization over `strict-order`'s per-query timeout). **YAGNI for v1** — `strict-order` self-heals; revisit only if outage latency is a real complaint.
