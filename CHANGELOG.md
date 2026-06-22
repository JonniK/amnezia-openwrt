# Changelog

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
