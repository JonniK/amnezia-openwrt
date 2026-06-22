# Changelog

## 0.3.0 — 2026-06-22

### Auto-learning self-learning bypass

**New feature** — opt-in, `direct-default` mode only, default OFF.

A cron pass (`/usr/sbin/amnezia-autolearn`) harvests visited domains from
the dnsmasq query log, probes blocked ones via `zapret-probe` with a
pinned IP (SSRF-safe `--resolve`, no redirects, public-IP gate), and
auto-adds confirmed-blocked domains to `/etc/amnezia/force.d/auto.list`
which feeds `amnezia_force4` via the normal `amnezia-force-load` path.

Classification thresholds: geoblock (`direct_geoblocked`) confirmed at
**2 verdicts**, DPI (`direct_dpi_blocked`) at **3**. A domain is eligible
only if **≥2 distinct client IPs** resolved it in the harvest window. LRU
eviction bounds flash use at `autolearn_max_entries` (default 500).
Revalidation every `autolearn_revalidate_days` (default 14) days drops
domains that now return `direct_ok` on a direct router-origin probe.

Hard gates: `routing_mode=direct-default`, `autolearn_enabled=1`,
failover state file fresh + `all_down:false`. All failure directions are
fail-safe (no list change on probe error or unreachable).

**New files:**

- `/usr/sbin/amnezia-autolearn` — cron pass
- `/usr/bin/amnezia-autolearn-ctl` — CLI: `status|list|veto|promote|purge|set-enabled`
- `/etc/init.d/amnezia-autolearn` — reversible dnsmasq query logging + cron wiring (START=97)
- `/usr/lib/amnezia/amnezia-autolearn-lib.sh` — pure helpers (querylog parsing, IP/name validation, deny matching)

**New data paths:**

- `/etc/amnezia/force.d/auto.list` — auto-learned domains
- `/etc/amnezia/autolearn/candidates.tsv` — 7-col TSV: domain, verdict, count, clients, first_seen, last_probe, reason
- `/etc/amnezia/autolearn/deny.list` — vetoed domains (suffix-aware; never re-added)
- `/tmp/dnsmasq-queries.log` — DNS query log (tmpfs; present only while enabled)

**Changed files:**

- `zapret-probe.sh`: optional 2nd arg (pinned IPv4) for SSRF-safe probing;
  existing single-arg LuCI path is byte-equivalent to before.
- `amnezia-force-load.sh`: guarded suffix-aware `deny.list` global exclusion;
  a missing/empty deny.list is a strict no-op (can never blank force4).

**New UCI options** (all under `amnezia.config`):

```
option autolearn_enabled              '0'
option autolearn_interval_min         '30'
option autolearn_max_probes           '20'
option autolearn_max_per_client       '5'
option autolearn_revalidate_days      '14'
option autolearn_max_entries          '500'
option autolearn_candidate_retention_days '30'
```

**Enable:**

```sh
amnezia-autolearn-ctl set-enabled 1
```

**LuCI panel:** master toggle + auto-list table with Remove (veto), Promote,
and Purge all.

---

## 0.2.0-r3 — 2026-06-15

### Multi-tunnel AmneziaWG failover (replaces pbr)

**New features**

- `amnezia-failover` procd daemon: health-checks up to 5 `awgN` tunnels
  (fresh WireGuard handshake OR bound ping), debounces state transitions
  (3 consecutive samples), and switches the default route via
  `ip route replace` — no pbr involved.
- **Strict-priority failover** is the default (`globals.mode = failover`).
  The lowest-metric healthy tunnel carries all pool traffic. A dedicated
  sticky table (`vpn_sticky` / table 100) keeps claude.ai and
  anthropic.com on a single stable exit IP regardless of failover events.
- **Load-balance mode** (`globals.mode = balance`) is opt-in: distributes
  traffic across healthy tunnels using iproute2 resilient nexthop groups
  (falls back to single-tunnel if `ip nexthop` is unavailable).
- Fail-closed: when all tunnels are down a blackhole default is installed
  in both routing tables. LAN traffic cannot reach WAN unencrypted.
- `amnezia-failover-ctl` helper: `set-mode`, `set-sticky`, `set-weight`,
  `toggle` — each commits UCI and restarts the monitor.
- `/var/run/amnezia-failover.json` written atomically on every poll cycle
  (temp-file + rename); consumed by the LuCI panel.

**Native classifier replaces pbr**

- `/etc/nftables.d/30-amnezia-classify.nft`: fw4 prerouting chain marks
  LAN-sourced forwarded traffic into three buckets:
  - RU TLD / RU CIDR addresses: left unmarked → main table → WAN (zapret).
  - Sticky addresses (`@amnezia_sticky4`, populated by dnsmasq nftset):
    mark `0x0a0000` → `vpn_sticky` table.
  - Everything else: mark `0x0b0000` → `vpn_pool` table.
- `/etc/iproute2/rt_tables.d/amnezia.conf`: adds named tables `vpn_sticky`
  (100) and `vpn_pool` (101).
- `pbr` and `luci-app-pbr` are no longer dependencies and are removed on
  migration.

**IPv6 fail-closed**

- Firewall rule `amnezia_v6_drop` drops LAN→WAN IPv6 forwarding.
- LAN RA / DHCPv6 / NDP disabled via UCI (`dhcp.lan`).

**Migration from pbr-based installs** (`amnezia-pbr-setup --migrate`)

Ordered steps: install classifier → populate `@amnezia_ru4` (gate: abort
if empty) → repoint dnsmasq → migrate must-tunnel domains to sticky list
→ remove pbr + luci-app-pbr → apply firewall zones → disable LAN IPv6.
The `amnezia_block_quic` firewall rule is never touched.

**LuCI panel updates**

- New "Failover tunnels" section: per-tunnel health, handshake age,
  carrying-flag, and failover mode indicator.
- Reads `/var/run/amnezia-failover.json`; polls every 10 s.

**Config**

UCI source of truth: `/etc/config/amnezia`. New fields in this release:

```
config globals 'globals'
    option mode        'failover'   # or 'balance'
    option sticky_target 'awg1'

config tunnel 'awg1'
    option enabled  '1'
    option label    'Primary'
    option metric   '1'
    option weight   '1'
    # option track_ip '1.1.1.1'   # default when absent
```

Per-tunnel conf files: `/etc/amnezia/awgN.conf` (N = 1…5).

**Package release**: `amnezia-pbr_0.2.0-3_all.ipk`,
`luci-app-amnezia_0.2.0-3_all.ipk` (`PKG_RELEASE = 3`).

---

## 0.2.0-r2 — 2026-05-31

- Fix: move LAN PBR templates out of `/etc/pbr.d/` to stop pbr globbing
  them (LAN placeholder broke generated nft rules).
- Bump `PKG_RELEASE` to `r2`.

## 0.2.0-r1 — initial public release

- AmneziaWG single-tunnel setup (`awg1`) + pbr policy routing.
- RU bypass via dnsmasq nftset (`.ru` TLD) + ipdeny CIDR list.
- zapret DPI desync integration with LuCI blockcheck/apply/verify.
- LuCI panel: tunnel + PBR status, domain probe, verify list, blockcheck.
