# amnezia-pbr-openwrt

**Languages:** English (this file) · [Русский](README.ru.md)

OpenWrt router config for **AmneziaWG** with **multi-tunnel automatic
failover**, **RU bypass**, and an optional **zapret DPI desync** layer,
plus a LuCI panel that wraps it all.

What you get on the router:

- Up to 5 `awgN` AmneziaWG interfaces (kmod + tools from
  [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt)).
- **Multi-tunnel failover** managed by the `amnezia-failover` procd
  daemon: health-checks each tunnel (fresh handshake OR bound ping),
  debounces state changes, and switches the default route via
  `ip route replace` — no pbr involved.
  - Default mode: **strict-priority failover** (`mode failover` in
    `config globals`). The lowest-metric healthy tunnel carries all
    traffic; a configurable sticky tunnel keeps claude.ai and
    anthropic.com on one stable exit IP at all times.
  - Optional: **load-balance** (`mode balance`) spreads traffic across
    healthy tunnels using iproute2 resilient nexthop groups. Opt-in per
    the `globals.mode` UCI field.
  - Fail-closed: when all tunnels are down a blackhole default is
    installed so LAN traffic cannot leak through WAN unencrypted.
- **Two routing modes** switchable at runtime (UCI `config.routing_mode`):
  - `tunnel-default` (default): all foreign traffic routes through the
    tunnel; `.ru` TLDs and RU CIDRs go direct.
  - `direct-default` (allowlist mode): WAN direct is the default;
    only addresses in the force-tunnel list (and sticky addresses) use
    the tunnel. Useful when most traffic is fine on direct + zapret and
    only a short list of sites needs a non-RU exit. If the list is
    empty, all traffic goes direct (fail-open for tunnel, not
    fail-closed — choose accordingly).
- **Native fw4 nft classifier** (`/etc/nftables.d/30-amnezia-classify.nft`)
  replaces pbr/luci-app-pbr. Traffic is marked at prerouting and
  dispatched to two iproute2 tables (`vpn_sticky` 100, `vpn_pool` 101).
  In `direct-default` mode a separate fragment
  (`30-amnezia-classify-direct.nft`) is activated instead.
- `.ru` TLDs and ipdeny RU IPv4 CIDRs are left unmarked → routed direct
  via WAN (banks, госуслуги, mail.ru etc. don't tunnel). Only relevant
  in `tunnel-default` mode.
- **Allowlist (force-tunnel list)** for `direct-default` mode:
  - Curated sources fetched daily at 03:15 and cached in
    `/etc/amnezia/force.d/`. Default-on: `itdoginfo_inside` (RKN-blocked
    domains) and `itdoginfo_services` (geoblock-RU: OpenAI, Anthropic,
    Spotify equivalents). Toggleable: `refilter_domains`, `refilter_ip`,
    `antifilter`.
  - Manual entries in `/etc/amnezia/force-tunnel.list` are merged with
    source lists and are never overwritten by auto-update.
  - Domains resolve via dnsmasq into the `amnezia_force4` nft set; IP/
    CIDR entries are loaded directly into that set.
- **Add/remove tunnels at runtime** from the LuCI panel (paste a `.conf`
  or an Amnezia `vpn://` share link — decoded in the browser before
  submission) or via `amnezia-tunnel-ctl add/remove`.
- `zapret` (DPI desync, from
  [remittor/zapret-openwrt](https://github.com/remittor/zapret-openwrt))
  installed but disabled by default — you turn it on from LuCI after
  finding a strategy that works on your ISP.
- **IPv6 fail-closed**: LAN→WAN IPv6 forwarding is dropped and LAN
  RA/DHCPv6/NDP are disabled. Tunnels carry IPv4 traffic only.
- A LuCI page at **Network → Amnezia** with:
  - tunnel + failover status, per-tunnel health and handshake age
  - one-click tunnel toggle and mode switch
  - **Add tunnel** form (paste `.conf` or `vpn://` link) and per-row
    **Remove** button
  - **Routing mode** selector (tunnel-default / direct-default)
  - **Allowlist sources** with per-source enable/disable checkboxes,
    "Update now" button, and a manual entry textarea
  - daily RU CIDR refresh (RU bypass list) and weekly RU CIDR refresh
  - **Domain probe** to classify how a site fails on direct WAN
  - **Verify list** to check a set of domains in one go after applying
    a strategy
  - **Blockcheck** runner with live log + apply/revert of recommended
    nfqws strategies

## Screenshots

| | |
|---|---|
| ![Panel overview](docs/screenshots/luci-amnezia-overview.png) | ![Domain probe](docs/screenshots/luci-amnezia-probe.png) |
| Tunnel + failover + RU list + zapret status, one place. | Probe a domain, get a verdict + recommendation. |
| ![Verify list](docs/screenshots/luci-amnezia-verify.png) | ![Blockcheck](docs/screenshots/luci-amnezia-blockcheck.png) |
| Re-probe N domains after Apply with summary chips and an action hint. | Run upstream blockcheck.sh with a live log; one-click Apply of the recommended nfqws strategy. |

## Install

Two paths — pick one. Both end at the same configured router; the
difference is how updates work afterwards.

**Before either path, place your Amnezia-exported .conf** at
`/etc/amnezia/awg1.conf` (the file with `Jc / Jmin / S* / H* / I*` lines
under `[Interface]` — export it from the Amnezia desktop client:
*Settings → Connection → Export config*). For multiple tunnels add
`/etc/amnezia/awg2.conf`, `/etc/amnezia/awg3.conf`, … up to `awg5.conf`.

```sh
mkdir -p /etc/amnezia
vi /etc/amnezia/awg1.conf      # paste the exported config, save, quit
# optional second tunnel:
vi /etc/amnezia/awg2.conf
```

### Path A: one-line installer (simplest)

```sh
wget -O - https://raw.githubusercontent.com/JonniK/amnezia-openwrt/main/install.sh | sh
```

Pulls a tarball of this repo, stages the wrappers to `/usr/bin/`, runs
the install pipeline. Updates require re-running the same command.
Good for first install or one-off setups.

### Path B: opkg .ipk packages (native, updateable)

```sh
ARCH=$(. /etc/openwrt_release && echo "$DISTRIB_ARCH")
REL=v0.2.0-r3   # or whatever the latest release tag is
VER=0.2.0-r3

cd /tmp
for pkg in amnezia-pbr luci-app-amnezia; do
  wget -O "${pkg}.ipk" \
    "https://github.com/JonniK/amnezia-openwrt/releases/download/${REL}/${pkg}_${VER}_all.ipk"
done

opkg install ./amnezia-pbr.ipk ./luci-app-amnezia.ipk
amnezia-pbr-setup     # downloads AmneziaWG kmod + zapret, configures UCI
```

Native opkg integration — `opkg upgrade amnezia-pbr` picks up wrapper
updates without re-running the bootstrap. `opkg remove` cleanly
uninstalls. UCI config (`/etc/config/amnezia`) and `/etc/amnezia/awg*.conf`
are package conffiles, so user edits survive upgrades.

Either path: WAN is pinged before and after every destructive step, the
network is never fully restarted, and `/tmp/openwrt-deploy.log` ends
with `DEPLOY_DONE` or `DEPLOY_FAILED`. Re-run safely after fixing
anything — idempotent.

### Install options

| Env var | Default | Effect |
|---|---|---|
| `STEPS` | `3` | `1` = AWG + firewall only, `2` = +routing, `3` = +RU bypass |
| `AWG_CONF` | `/etc/amnezia/awg1.conf` | Where to read AWG keys/params from |
| `REPO_REF` | `main` | Branch/tag to install from |
| `AWG_VER` | `24.10.3` | Slava-Shchipunov ipk release pin |

### Where things live

| Path | Purpose |
|---|---|
| `/etc/amnezia/awg1.conf` … `awg5.conf` | Your AmneziaWG client configs (you provide them; also written by `amnezia-tunnel-ctl add`) |
| `/etc/config/amnezia` | UCI config: failover globals, per-tunnel settings, routing mode, force_source sections |
| `/etc/nftables.d/30-amnezia-classify.nft` | Active fw4 prerouting classifier (regenerated on mode switch via `routing_emit_classifier`) |
| `/etc/iproute2/rt_tables.d/amnezia.conf` | Named routing tables: `vpn_sticky` (100), `vpn_pool` (101) |
| `/etc/amnezia/ru.cidr` | Current ipdeny RU IPv4 list (refreshed weekly) |
| `/etc/amnezia/ru-update.json` | Stamp of last RU CIDR refresh |
| `/etc/amnezia/blockcheck.json` | Stamp of last blockcheck run |
| `/etc/amnezia/seed-sticky-domains.list` | Domains pinned to the sticky tunnel (default: claude.ai, anthropic.com) |
| `/etc/amnezia/zapret-backups/` | Per-Apply backups of `NFQWS_OPT` |
| `/opt/zapret/config` | Active zapret config (`NFQWS_OPT` lives here) |
| `/var/run/amnezia-failover.json` | Live failover state (read by LuCI panel) |
| `/etc/amnezia/force-tunnel.list` | Manual allowlist entries (domains/IPs); never overwritten by auto-update |
| `/etc/amnezia/force.d/` | Auto-update cache: one `.list` file per enabled source, written by `amnezia-force-update` |
| `/etc/amnezia/force-update.json` | Stamp of last force-list update (per-source counts + status) |

### Configuring multiple tunnels

All failover settings live in `/etc/config/amnezia` (UCI). Edit via
`uci` commands or LuCI → Network → Amnezia.

**`config globals 'globals'`** — failover-wide settings:

| UCI field | Default | Description |
|---|---|---|
| `globals.mode` | `failover` | `failover` = strict-priority (single exit IP); `balance` = load-balance across healthy tunnels |
| `globals.sticky_target` | `awg1` | Tunnel name that carries sticky-marked traffic (claude.ai, anthropic.com) |

**`config tunnel 'awgN'`** — one section per tunnel (awg1 … awg5):

| UCI field | Default | Description |
|---|---|---|
| `awgN.enabled` | `1` | `1` = include in failover pool, `0` = exclude |
| `awgN.label` | — | Human-readable name shown in the LuCI panel |
| `awgN.metric` | N | Lower value = higher priority in failover mode (ties keep the first-defined) |
| `awgN.weight` | `1` | Relative weight used in balance mode |
| `awgN.track_ip` | `1.1.1.1` | IP used for the bound ping health-check when the handshake is stale |

**Example — two tunnels, awg1 primary, awg2 backup:**

```sh
uci set amnezia.globals.mode=failover
uci set amnezia.globals.sticky_target=awg1

uci set amnezia.awg1=tunnel
uci set amnezia.awg1.enabled=1
uci set amnezia.awg1.label='Primary'
uci set amnezia.awg1.metric=1
uci set amnezia.awg1.weight=1

uci set amnezia.awg2=tunnel
uci set amnezia.awg2.enabled=1
uci set amnezia.awg2.label='Backup'
uci set amnezia.awg2.metric=2
uci set amnezia.awg2.weight=1

uci commit amnezia
/etc/init.d/amnezia-failover restart
```

The `amnezia-failover` daemon re-reads UCI on each start, so
`restart` is the only step needed after changing config.

**Runtime control helper** — `amnezia-failover-ctl`:

```sh
amnezia-failover-ctl set-mode balance        # switch to load-balance
amnezia-failover-ctl set-mode failover       # switch back to strict-priority
amnezia-failover-ctl set-sticky awg2         # pin sticky traffic to awg2
amnezia-failover-ctl set-weight awg2 3       # raise awg2 weight in balance mode
amnezia-failover-ctl toggle awg2             # enable/disable awg2 in pool
amnezia-failover-ctl set-routing-mode direct-default   # switch to allowlist mode
amnezia-failover-ctl set-routing-mode tunnel-default   # switch back to tunnel-by-default
amnezia-failover-ctl set-source refilter_domains 1     # enable a source for the force-tunnel list
amnezia-failover-ctl set-source refilter_domains 0     # disable it
```

`set-mode`, `set-sticky`, `set-weight`, and `toggle` commit UCI and restart the
monitor. `set-routing-mode` regenerates the active classifier, runs
`amnezia-force-load`, reloads fw4 (in a backgrounded subshell so SSH stays
open), and flushes conntrack pool/sticky marks so existing flows re-evaluate
immediately. `set-source` commits UCI only; the change takes effect on the
next `amnezia-force-update` run.

### Managing tunnels at runtime

Add or remove tunnels from the LuCI panel (Network → Amnezia → Add tunnel
form and per-row Remove button) or from the CLI:

```sh
# Add a tunnel — paste the .conf body as an argument.
# The next free slot (awg2..awg5) is picked automatically by the UI;
# from the CLI, pass the slot name explicitly.
amnezia-tunnel-ctl list-free                        # print next free slot, or exit 3 if full
amnezia-tunnel-ctl add awg2 "$(cat /tmp/awg2.conf)" --label 'Backup'
amnezia-tunnel-ctl remove awg2                      # tear down and remove from UCI
```

The `add` subcommand validates the `.conf` body (requires PrivateKey,
PublicKey, Endpoint host, and Endpoint port), writes the config to
`/etc/amnezia/<name>.conf` (mode 600), creates the network/firewall/amnezia
UCI sections, brings the interface up, and restarts the failover monitor.

The `remove` subcommand stops the monitor first (so no mid-teardown poll
happens), brings the interface down, removes all UCI sections and the conf
file, then starts the monitor against the remaining tunnel set. Refused (exit
2) if the tunnel is the current sticky target or if removal would leave no
members in the firewall VPN zone — reassign sticky (`set-sticky`) or keep at
least one tunnel.

Maximum 5 tunnels (`awg1` … `awg5`).

**From the LuCI panel:** paste a `.conf` file directly OR paste an Amnezia
`vpn://` share link — the link is decoded in the browser (base64url + zlib
inflation + JSON extraction) and the resulting `.conf` is shown for review
before submission. The backend never receives the raw `vpn://` link.

### Allowlist sources

`amnezia-force-update` fetches each enabled `force_source` UCI section and
writes the result to `/etc/amnezia/force.d/<source>.list`. On fetch failure,
the prior cached file is kept. After fetching, it calls `amnezia-force-load`
to merge and apply the result.

`amnezia-force-load` merges all `force.d/*.list` files with the manual
`/etc/amnezia/force-tunnel.list`, deduplicates, classifies each line:

- **IP/CIDR lines** are loaded directly into the `amnezia_force4` nft set.
- **Domain lines** are written to the `dhcp.amnezia_force` UCI ipset section;
  dnsmasq is restarted only when the domain list actually changed.

The `amnezia_force4` set is volatile (cleared on every `fw4 reload`). A
hotplug script (`/etc/hotplug.d/firewall/99-amnezia-force-load`) and a boot
init (`/etc/init.d/amnezia-force-load`, start order 96) repopulate the set
automatically after each reload.

Sources and their defaults:

| UCI section | Default | Coverage |
|---|---|---|
| `itdoginfo_inside` | **on** | RKN-blocked domains (Russia/inside-raw.lst) |
| `itdoginfo_services` | **on** | Geoblock-RU services — OpenAI, Anthropic, Spotify equiv. (Categories/geoblock.lst) |
| `refilter_domains` | off | Re-filter broader domain list (1andrevich/Re-filter-lists) |
| `refilter_ip` | off | Re-filter IP/CIDR list (same repo) |
| `antifilter` | off | antifilter.download domain list |

Toggle via `amnezia-failover-ctl set-source <name> 0|1` or the LuCI
checkboxes. Auto-update runs daily at **03:15** via cron
(`/etc/crontabs/root`). To trigger an immediate fetch:

```sh
amnezia-force-update          # fetch + load (runs as cron does)
amnezia-force-load            # merge + apply already-cached lists only
```

Manual entries in `/etc/amnezia/force-tunnel.list` are always merged in and
are never overwritten by `amnezia-force-update`.

### Supported hardware

Tested on **aarch64 mediatek/filogic** (Xiaomi AX3000T, Banana Pi BPI-R4,
etc.) on OpenWrt 24.10.3.

The installer auto-detects `DISTRIB_ARCH` and `DISTRIB_TARGET` to pick
the right AmneziaWG kmod ipk from Slava-Shchipunov's releases, so other
targets *should* work as long as a matching ipk exists for your kernel.
mips_24kc is intended but untested.

## Upgrading from a pbr-based install

Existing installs that used `pbr` + `luci-app-pbr` are migrated
automatically when you run `amnezia-pbr-setup --migrate`:

1. The native nft classifier (`30-amnezia-classify.nft`) is installed.
2. The `@amnezia_ru4` nftset is populated from the persisted CIDR file.
   Migration aborts and rolls back if the set is empty (safe gate).
3. dnsmasq is repointed from old pbr nftsets to the new amnezia nftsets.
4. Old must-tunnel domains are migrated to the sticky domain list.
5. `pbr` and `luci-app-pbr` are stopped, disabled, and removed via opkg.
6. Firewall zones are updated to cover all enabled `awgN` interfaces;
   the `amnezia_block_quic` firewall rule is never touched.
7. LAN IPv6 RA/DHCPv6/NDP are disabled (IPv6 fail-closed).

The `amnezia_block_quic` nft rule (QUIC/UDP-443 block that forces
claude.ai over TCP for reliable tunnel traversal) is preserved
through the migration.

For the manual hardware validation sequence see
[`dev/spike-multitunnel-runbook.md`](dev/spike-multitunnel-runbook.md).

## When zapret helps and when it doesn't

zapret performs DPI desync on egress packets after they've left the
router but before they hit the ISP's TSPU. It can help when:

- A site is **DPI-blocked**: TSPU lets the SYN through, parses the
  ClientHello's SNI, then RSTs the connection. zapret rewrites the
  ClientHello (split, fakedsplit, multidisorder, etc.) so the SNI
  isn't parseable. This is the classic case it's designed for.

It **cannot help** when:

- A site is **SYN-blocked**: TSPU drops the first packet of the
  handshake by destination IP. zapret operates on packets that reach
  it; if the SYN dies upstream, there's nothing to desync. In 2026
  Russia this is the dominant block mode for many western services
  (Instagram, Facebook, X, LinkedIn, often YouTube).
- A site does **server-side anti-VPN** (Cloudflare's `cf-mitigated`,
  OpenAI's region check, Netflix). The block is based on your IP, and
  no packet-level desync changes the IP. Only the tunnel (with a
  non-flagged exit) helps.

The LuCI panel makes the distinction with three tools:

- **Domain probe** classifies one domain into `direct_ok`,
  `direct_dpi_blocked`, `direct_geoblocked`, or `direct_unreachable`.
- **Blockcheck** runs the upstream `/opt/zapret/blockcheck.sh` and
  surfaces a recommended `--dpi-desync=...` strategy when one works.
- **Verify list** then re-probes a list of domains with the applied
  strategy live, so you can see whether the recommendation actually
  helps on your real targets (blockcheck often gets a false positive
  by testing against `iana.org` IPs rather than the real destination).

If most of your blocked sites are SYN-blocked, leaving zapret off and
sending those domains through the tunnel is the right answer. zapret
is most valuable when it lets you keep high-bandwidth, DPI-only sites
on direct WAN to free the tunnel from carrying the load.

## Repo layout

```
install.sh                          Public bootstrap (this is what users run)
openwrt/
  install-amnezia-pbr.sh            Main installer + migration pipeline (runs on the router)
  amnezia-failover                  procd failover monitor daemon
  amnezia-failover-ctl.sh           Control helper (set-mode, set-sticky, set-weight, toggle,
                                      set-routing-mode, set-source)
  amnezia-failover.init             procd init script for amnezia-failover (installs fwmark rules)
  amnezia-tunnel-ctl.sh             Add / remove tunnels (add, remove, list-free)
  amnezia-force-load.sh             Merge force.d/ + manual list -> amnezia_force4 set + dnsmasq
  amnezia-force-update.sh           Fetch enabled force_source lists, cache, call force-load
  amnezia-force-load.init           Boot init (START=96) to repopulate amnezia_force4
  99-amnezia-force-load.hotplug     Firewall hotplug: repopulate amnezia_force4 after fw4 reload
  amnezia-ru-cidr.sh                Populate @amnezia_ru4 nftset from persist / fetch
  amnezia-ru-load.init              Boot + hotplug loader for amnezia_ru4
  amnezia-status.sh                 Status summary script
  configure-dnsmasq-amnezia.sh      Wire dnsmasq nftset sections (RU TLD + sticky + force-list)
  nftables.d/30-amnezia-classify.nft        fw4 classifier for tunnel-default mode
  nftables.d/30-amnezia-classify-direct.nft fw4 classifier for direct-default (allowlist) mode
  iproute2-amnezia-rt_tables.conf   Named routing tables (vpn_sticky 100, vpn_pool 101)
  seed-sticky-domains.list          Domains pinned to sticky tunnel (claude.ai, anthropic.com)
  force-tunnel.list                 Seed file for manual allowlist entries (shipped empty)
  lib/amnezia-common.sh             Shared constants + helpers (MAX_TUNNELS=5)
  lib/amnezia-routing.sh            iproute2 / nft / firewall helpers (routing_emit_classifier)
  lib/amnezia-tunnel-lib.sh         .conf parser + UCI generator used by amnezia-tunnel-ctl
  install-zapret.sh                 zapret package + wrappers + ncat-full
  install-luci-app-amnezia.sh       LuCI menu/acl/view + cron
  configure-dnsmasq-ru-nftset.sh    .ru TLD -> nftset directive (legacy, superseded by configure-dnsmasq-amnezia.sh)
  awg-{toggle,status,ru-update}.sh  AWG wrappers
  zapret-{toggle,status,blockcheck,apply,probe,verify}.sh   zapret wrappers
  luci-app-amnezia/                 LuCI app (menu, acl, view/main.js, decode-vpn.mjs)
config/amnezia                      UCI config example (shipped in package)
docs/                               Design notes
dev/                                Maintainer-side SSH tooling + spike runbooks + VM test harness
local/                              Your private AWG config (gitignored)
```

## License

GPLv2. See LICENSE.

## See also

- [`dev/spike-multitunnel-runbook.md`](dev/spike-multitunnel-runbook.md) — manual
  hardware validation sequence for the multi-tunnel failover feature.
- [docs/plan-b-inverted-pbr.md](docs/plan-b-inverted-pbr.md) — original design
  notes for the "direct default + zapret + selective must-tunnel" architecture,
  now implemented as the `direct-default` routing mode.
- [docs/ru-tld-bypass.md](docs/ru-tld-bypass.md) — how the `.ru` TLD
  bypass works via dnsmasq nftset.
- [README.ru.md](README.ru.md) — русская версия.
