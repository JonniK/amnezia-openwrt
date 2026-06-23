# Changelog

## 0.2.0-r4 — 2026-06-23

### Encrypted DNS (DoT/DoH) toggle

**New features**

- Optional encrypted-DNS stack, default OFF. When enabled, dnsmasq
  forwards queries through two loopback resolvers:
  - **stubby** (DoT, `127.0.0.1:5453`) — TLS-authenticated DNS that
    routes its own traffic through the sticky tunnel (ip rule pref
    `30900` → table `100`).
  - **https-dns-proxy** (DoH, `127.0.0.1:5454`) — HTTPS DNS that
    egresses direct.
  dnsmasq is configured with `noresolv` and `strict-order` so it uses
  these listeners exclusively and tries them in the declared order.
- **Procd watchdog** (`amnezia-dns-ctl watchdog`, run as a respawned
  procd service under `amnezia-dns`): probes both listeners every 20s.
  Enters a plaintext last-resort tier after 3 consecutive failures (N=3),
  inserts the WAN-provided IPs *after* the encrypted listeners so
  `strict-order` still tries encrypted first. Exits plaintext after 2
  consecutive ok probes (M=2) and 120s dwell. Plaintext-entry timestamp
  is persisted in UCI (`dns_plain_ts`) so dwell survives procd respawn.
- **`amnezia-dns-ctl`** CLI: `enable`, `disable`, `apply`, `set-provider`,
  `status`, `watchdog`. `enable` verifies encrypted DNS is answering
  before returning; auto-reverts via `disable` if the post-enable
  verification fails. `set-provider` hot-swaps the provider on a live
  stack with rollback on verify failure.
- **LuCI panel** (`Network → Amnezia → Encrypted DNS (DoT)`): checkbox
  to enable/disable, provider dropdown, active-tier label, and a
  plaintext-fallback warning banner.
- **Five built-in providers**: `quad9` (default), `adguard`, `dns0`,
  `mullvad`, `google`. Custom resolver via direct UCI only
  (`dot_resolver`, `doh_resolver`, `doh_bootstrap`).
- Installer (`amnezia-pbr-setup --first-install`) installs `stubby` and
  `https-dns-proxy` via opkg and wires the init/hotplug files. Degrades
  gracefully: if packages are absent, `apply` sets `dns_active_tier=plaintext`
  and continues rather than breaking DNS.
- Firewall hotplug (`99-amnezia-dns`) re-asserts the DoT ip rule after
  every `fw4 reload` — the rule lives in the `ip rule` table, not
  nftables, so it survives fw4 without a hotplug but is re-applied for
  correctness on provider-IP change.

**New UCI options** (under `amnezia.config`):

```
option dot_enabled      '0'       # 1 = encrypted DNS active (default OFF)
option dns_provider     'quad9'   # quad9 | adguard | dns0 | mullvad | google
option dot_resolver     ''        # custom only: <IP>#<hostname> for stubby
option doh_resolver     ''        # custom only: DoH URL
option doh_bootstrap    ''        # custom only: DoH bootstrap IP
option dns_active_tier  'off'     # runtime: off | dot | doh | plaintext
```

**New package dependencies**: `stubby`, `https-dns-proxy`.

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
