# Plan B — Inverted PBR with zapret as the default obfuscation layer

Status: **B0 partially in place** (probe utility, seed list, blockcheck/apply
tooling all shipped). **B1–B3 pending user go-ahead**, deliberately paused so
real-world data about which domains genuinely fail direct gets collected
before any routing flip.

## What changes

Today (current state — call it Plan A):
- Default route for foreign traffic = **AmneziaWG tunnel** (`awg1`).
- RU IPv4 CIDRs and `.ru` TLD lookups bypass the tunnel via PBR sets
  `pbr_wan_4_dst_ip_user`, `pbr_ru_tld4`.
- zapret is **independent** and only meaningful for traffic already going
  direct. With the current PBR layout that's only the RU direct path, so
  zapret is mostly idle.

Plan B inverts the routing decision:
- Default route for foreign traffic = **WAN direct + zapret DPI desync.**
- AWG tunnel is used **only** for an explicit allow-list of "must-tunnel"
  domains — sites where direct fails for one of two reasons:
  1. **Geo / anti-VPN block:** the site refuses connections from our IP
     by country (probe verdict `direct_geoblocked`). zapret can't help —
     only a non-RU exit can.
  2. **DPI block that zapret can't fix:** TSPU drops the traffic and the
     blockcheck-tuned NFQWS_OPT doesn't recover it (probe verdict
     `direct_dpi_blocked` even with zapret ON).
- RU bypass logic (`.ru` direct, RU CIDR direct) stays as-is, but becomes
  a no-op for most flows since direct is the new default.

Expected upside vs current:
- Foreign traffic on direct = 0–5% speed loss instead of 20–50% via tunnel.
- AWG server bandwidth / latency budget freed for the small must-tunnel set.
- One less hop in the most-trafficked path.

Expected downside:
- Operational: a curated must-tunnel domain list to maintain.
- zapret now sits on the hot path for ALL foreign traffic — nfqws CPU
  load goes up proportionally; misconfiguration is now user-visible
  instead of harmless background noise.
- Single point of failure: if zapret breaks, foreign sites that worked
  behind the tunnel may stop working until the toggle is flipped back.

## What's already in place (the B0 foundation)

These shipped during the diagnostic build-out and don't need to be rebuilt:

- `/usr/bin/zapret-probe <domain>` — classifies a domain into
  `direct_ok / direct_geoblocked / direct_dpi_blocked / direct_blocked /
  direct_unreachable`. Verified against real targets:
  `example.com → direct_ok`, `chatgpt.com → direct_geoblocked (HTTP 403)`,
  `rutracker.org → direct_dpi_blocked (0.8s RST)`,
  `instagram.com → direct_unreachable (5s SYN timeout)`.
- `/etc/amnezia/seed-must-tunnel.list` — short reference of well-known
  RU-blocking sites (chatgpt, claude, gemini, netflix, nytimes, etc.).
  Read-only data; does **not** route anything by itself.
- LuCI "Domain probe" section — input + Probe button + seed-list rows
  that are clickable to probe.
- `/usr/bin/zapret-blockcheck` + apply/revert — tune NFQWS_OPT once,
  blockcheck-recommended.
- `/usr/bin/zapret-toggle` + `/usr/bin/pbr-reload` + Reload PBR button
  in LuCI — operational safety net.

## Surprising finding worth flagging

`chatgpt.com` probe via the current PBR (which sends it through AWG)
**also returns HTTP 403** — i.e. OpenAI knows the current AWG exit IP
and blocks it as a VPN. This means:

- A must-tunnel entry isn't enough for some services if the exit IP is
  already on their blocklist. Mitigation is exit-side, not router-side
  (rotate the AmneziaWG server, use a less-known provider, etc.).
- The probe tells us "direct doesn't work" but it can't tell us "AWG
  works either" — the user has to verify each must-tunnel candidate
  actually loads through the tunnel before adding it.

## Decision gate before starting B1

Run for at least one full week with the current Plan A and the probe
utility. Catalogue what *actually* fails for you in normal usage:

1. **Stability** — any unexpected disconnects, RAM pressure, kernel
   tracebacks (`logread | grep -iE 'nfqws|oom|stall'`)?
2. **Effectiveness** — do the YouTube / Discord / Twitch / GitHub /
   Cloudflare targets actually work with **AWG turned OFF** and zapret
   ON? Use `zapret-probe` to verify direct verdicts on each.
3. **Strategy adequacy** — does the blockcheck-tuned NFQWS_OPT cover
   the bulk of needed sites, or is it specific to one or two domains
   only? (Re-running blockcheck against a comma list of 5–10 domains
   is the cheapest way to find out.)
4. **Concrete must-tunnel list** — which domains *still* fail with
   zapret ON? That list seeds the new `pbr_unblock4` nftset.
5. **AWG exit health** — for each must-tunnel candidate, manually
   open it in a browser with AWG up and verify it actually loads.
   A geo-blocked site whose AWG exit is also on the service's blocklist
   needs an upstream fix, not a routing one.

If 1+2 hold and the catalogue at step 4 produces a list of <30 domains
that all pass step 5, proceed.
If zapret causes regressions, the strategy is too domain-specific, or
the catalogue explodes past ~100 domains, stay on Plan A — at that
scale the operational cost of maintaining the list outweighs the
bandwidth savings.

## Architecture sketch

```
┌──────────────────────────────────────────────────────────────────────┐
│ Client (LAN)                                                         │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                   ┌────────────────────┐
                   │ dnsmasq + nftsets  │
                   │  - pbr_ru_tld4     │ ◀── .ru TLDs (DIRECT)
                   │  - pbr_unblock4    │ ◀── must-tunnel hostlist (AWG)
                   └────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
   ┌──────────────────────┐         ┌────────────────────┐
   │ AWG tunnel (awg1)    │         │ WAN direct + zapret│
   │ - dst ∈ pbr_unblock4 │         │ - everything else  │
   └──────────────────────┘         │ - nfqws hook on    │
              │                     │   tcp 80/443/QUIC  │
              ▼                     └────────────────────┘
       remote VPN server                       │
                                               ▼
                                          internet
```

Routing rules in priority order (first match wins):

| Priority | Match                              | Route   |
|----------|------------------------------------|---------|
| 1        | dst ∈ `pbr_unblock4` (allow-list)  | `awg1`  |
| 2        | dst ∈ `pbr_ru_tld4` (RU TLDs)      | WAN     |
| 3        | dst ∈ `pbr_wan_4_dst_ip_user` (RU) | WAN     |
| 4        | default                            | WAN     |

zapret nfqws hook is on egress WAN, so steps 2/3/4 get DPI desync;
step 1 goes through the tunnel and is independent of zapret.

## Implementation plan

### Phase B0 — diagnostic foundation (✅ done in this session)

- ✅ `zapret-probe <domain>` returning a verdict.
- ✅ `seed-must-tunnel.list` reference list.
- ✅ LuCI Domain probe section with input + seed list.
- ✅ blockcheck + apply pipeline so NFQWS_OPT is actually tuned.
- ⬜ **User homework** (the gate before B1): run normally for a week
  with the probe at hand, build a personal `must-tunnel.list`.

### Phase B1 — must-tunnel list as a real PBR set (pending)

1. New persistent file `/etc/amnezia/must-tunnel.list` (one domain per line).
2. `awg-must-tunnel-update.sh`:
   - Reads the list.
   - Writes a dnsmasq config snippet that nftset-tags each domain
     into `pbr_unblock4` on lookup.
   - Cron weekly: re-probes each entry; alerts the UI (via a stamp
     file like `/etc/amnezia/must-tunnel-probe.json`) if any entry's
     direct verdict flipped to `direct_ok` (candidate for removal).
3. Persistent nftables set `pbr_unblock4` (mirror of `pbr_ru_tld4`).
4. New PBR include `/etc/pbr.d/unblock-via-vpn.sh` emitting the
   "dst ∈ pbr_unblock4 → mark for awg1" rule with priority above the
   RU exception rules.

### Phase B2 — routing-mode switch (pending)

5. Keep both PBR-default files under version control:
   - `/etc/pbr.d/99-lan-vpn-tunnel-default.sh` (today's behaviour)
   - `/etc/pbr.d/99-lan-vpn-direct-default.sh` (the inverted version)
6. New `/usr/bin/awg-routing-mode <tunnel|direct>`:
   - Atomically swaps which include is active.
   - Calls `pbr-reload`.
   - Writes `/etc/amnezia/routing-mode` so status is observable.
7. LuCI Tunnel section gets a "Routing mode" dropdown surfacing the
   switch. Choosing it shows a preview ("traffic to N must-tunnel
   domains goes via AWG; everything else direct via WAN+zapret") and
   asks for confirmation.

### Phase B3 — LuCI must-tunnel UI (pending)

8. New panel: list of must-tunnel domains, each row shows the last
   probe verdict + timestamp.
9. "Add" — text input + Probe-first button (so user sees the verdict
   before committing).
10. "Probe all" button that re-verifies the whole list.
11. "Suggest removals" — domains whose last probe is `direct_ok` for
    ≥3 consecutive checks (probably safe to drop back to direct).
12. Integration with `handleProbe` → after a `direct_geoblocked` or
    `direct_dpi_blocked` verdict, offer "Add to must-tunnel".

### Phase B4 — rollback safety net (pending)

13. The current Plan A code paths stay in the repo as
    `/etc/pbr.d/99-lan-vpn-tunnel-default.sh` and remain referenceable.
14. `awg-routing-mode tunnel` flips back to Plan A in one command.
15. The LuCI dropdown lets the user revert with one click.
16. Document the rollback path in `docs/openwrt-pbr-modes.md`.

## Open questions to resolve before B1 starts

- **AWG exit reputation.** Some services (OpenAI, banks) block the
  current AWG exit IP regardless. Must-tunnel becomes useless for those
  until the exit rotates. Worth tracking which entries actually work
  through AWG before committing them.
- **zapret CPU load on hot path.** Current setup has zapret idle. After
  B1+B2, nfqws sees every TLS handshake leaving the WAN. Need to
  measure CPU on this Filogic box at peak (YouTube 1080p multi-client)
  and confirm it stays under ~30% across a busy evening.
- **DNS-over-TLS / DoH.** External DoH bypasses dnsmasq so the
  `pbr_unblock4` set never sees lookups for must-tunnel domains.
  Either block external 853/known-DoH IPs at the firewall and force
  fallback to the router resolver, or accept that DoH users bypass the
  list and document it.
- **IPv6.** Current setup only has IPv4 PBR sets. zapret's UCI config
  has `DISABLE_IPV6 '1'`. Plan B inherits this — IPv6 stays
  default-direct, no must-tunnel coverage. Acceptable for v1.
- **Per-device exemption.** Some clients (a work laptop, an Apple TV)
  may want different rules. Add a LAN-IP-based override set later if
  requested.

## Why this is in a doc and not yet code

B1 onward is a routing-default flip. Without a real list of domains
that actually fail direct in this user's day-to-day, the inverted
architecture would either be:

- **Over-tunneled** (must-tunnel grows past 100 entries — defeats the
  purpose of inversion).
- **Under-tunneled** (whatever was working through AWG breaks because
  the corresponding domain isn't on the list yet).

The probe utility is the cheap measurement device. The discipline is to
*use* it for a week or two before committing to the rewrite. When the
list stabilises and stays small, B1+ becomes a focused 3–5 commit
change.
