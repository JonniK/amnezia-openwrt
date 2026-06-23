# Changelog

## [unreleased]

### Modular LuCI UI + accordion (no behavior change)

`openwrt/luci-app-amnezia/view/main.js` (was ~2300 lines) is now a
~129-line orchestration shell. Feature logic extracted into six modules
under `openwrt/luci-app-amnezia/amnezia/`:

- `util.js` — `fmtDur`, `fmtAge`, `verdictColor`, `uiConfirm`
- `section/failover.js`, `section/routing.js`, `section/zapret.js`,
  `section/dns.js`, `section/autolearn.js` — per-feature handlers +
  `render()` + `refresh()`

`main.js` `'require's each module, `Object.assign`s their handler maps
onto the view, and delegates `refresh()` via `Promise.all`. Presentation:
native `<details>` accordion — four status families open by default
(Tunnels & Failover, Routing & Allowlist, Encrypted DNS, Auto-learning);
the DPI bypass (zapret) family and all action sub-sections collapsed.

On device modules land at `/www/luci-static/resources/amnezia/`. All four
delivery surfaces updated: `dev/sync-to-packages.sh`,
`openwrt/install-luci-app-amnezia.sh`, `install.sh`,
`dev/deploy-openwrt-safe.sh`.

**New test gate:** `test/lib/luci-harness.js` — stubs LuCI globals,
walks the full require graph, executes every `render()` + `main.render()`,
asserts no action panel carries `open`, and verifies all `refresh()`
calls resolve under a failing-fs stub. Run by `test/unit/luci-js.bats`.

ACL, UCI, and all backend sh scripts are unchanged.

---

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
