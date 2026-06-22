# amnezia-openwrt — agent guide

AmneziaWG multi-tunnel failover VPN router for **OpenWrt 24.10.3** on a Xiaomi **AX3000T** (mediatek/filogic, aarch64). All runtime code is **POSIX sh / BusyBox ash**. Top constraint: **never break client internet** — every router action must be reversible and verified (WAN + DNS + tunnel handshake) before moving on.

## What it does

Routes LAN traffic selectively through AmneziaWG (`awg`) tunnels using **fwmark policy routing**, with automatic failover across multiple tunnels.

- **Classifier** (`/etc/nftables.d/30-amnezia-classify.nft`, prerouting/mangle) marks LAN traffic: sticky → `0x0a0000` (table `100`), pool → `0x0b0000` (table `101`); `MARK_MASK=0x0ff0000`. ip rules at pref `31000`/`31001` send marked traffic to those tables. The active classifier is **mode-generated** from a `@@LAN_IFNAME@@` template.
- **nft sets** decide routing: `amnezia_ru4` / `amnezia_ru_tld4` (Russia + `.ru` → direct), `amnezia_sticky4` (pin to sticky tunnel), `amnezia_force4` (the allowlist).
- **`routing_mode`** (`amnezia.config.routing_mode`): `tunnel-default` (foreign→tunnel, RU→direct — the normal mode) vs `direct-default` (everything direct, only `amnezia_force4`→tunnel). Switch via `amnezia-failover-ctl set-routing-mode`. In `tunnel-default` the force allowlist is **dormant** (classifier doesn't consult `force4`).
- **Failover daemon** `/usr/sbin/amnezia-failover` monitors tunnels, (re)installs ip rules + routing tables, and writes state JSON to `/var/run/amnezia-failover.json` (`routing_mode` + `sources{}` for the UI).
- **Allowlist engine**: `amnezia-force-update` fetches enabled `force_source` UCI sections → `/etc/amnezia/force.d/<name>.list`; `amnezia-force-load` splits IP/CIDR → `amnezia_force4` nft set and domains → dnsmasq nftset directives. Two-trigger repopulation (volatile nft set): boot init (`START=96`) + firewall hotplug. Daily cron 03:15.
- **RU routing**: `amnezia-ru-cidr` / `amnezia-ru-load` (weekly cron Sun 04:30).
- **Tunnel management**: `amnezia-tunnel-ctl add|remove|list-free` (paste `.conf` or Amnezia `vpn://`; the LuCI UI decodes `vpn://` client-side and passes only `.conf`).

## Layout

**Device:** daemon `/usr/sbin/amnezia-failover`; CLIs `/usr/bin/amnezia-{tunnel-ctl,force-load,force-update,failover-ctl,status,ru-cidr}`; libs `/usr/lib/amnezia/{amnezia-common,amnezia-routing,amnezia-tunnel-lib}.sh`; inits `/etc/init.d/amnezia-{failover,ru-load,force-load}`; hotplugs `/etc/hotplug.d/firewall/99-amnezia-{ru-load,force-load}`; classifier active `/etc/nftables.d/30-amnezia-classify.nft`, templates `/usr/share/amnezia/nftables.d/`; config `/etc/config/amnezia` (`awgN` tunnels, `globals`, `config`, `force_source` sections); data `/etc/amnezia/` (`force.d/`, `force-tunnel.list`, `*.conf` — **private keys, never print/commit**, stamps) + `/etc/amnezia/dnsmasq.d/` (chunked nftset conf-dir).

**Repo:** `openwrt/` is the source of truth; `dev/sync-to-packages.sh` mirrors it into `packages/` (the `.ipk` tree) — **keep `openwrt/ ↔ packages/` in sync** (CI checks it). Delivery is two paths: imperative `openwrt/install-amnezia-pbr.sh` (`--first-install` / `--migrate`, postinst-style) and the `.ipk`. Tests: `test/unit/*.bats` + `test/stubs/`. VM harness: `dev/vm/` (QEMU OpenWrt; `test-all.sh` = migrate / first-install / tunnel-mgmt scenarios). Router ops: `dev/{openwrt-backup,openwrt-restore,openwrt-emergency-internet,deploy-cutover,rollback-multitunnel}.sh`. SSH alias **`openWRT`** → `192.168.1.1:2323` (dev scripts default `SSH_HOST=router`, so pass `SSH_HOST=openWRT`).

## Hard-won rules

These come from bugs that passed the VM + unit tests and only surfaced on the live router. Root theme: **simulation must match real OpenWrt, or real bugs hide.**

### UCI: read option values with `uci -q get`, never `uci show | grep | sed`
Real `uci show` **quotes** option values (`amnezia.x.enabled='1'`) and renders lists on **one line** (`firewall.vpn.network='a' 'b'`). grep|sed on a value yields quoted junk (`'1' != 1`); counting list members by lines always returns 1. Both shipped real bugs: force-update read every source as disabled (fetched nothing); tunnel-ctl `_fwnet_count` always returned 1 → `remove` was a silent no-op. Use `uci -q get <path>` for values; for list membership iterate `uci -q get` words or use `uci del_list`/`add_list`. Only the unquoted **type** line (`x=force_source`) is safe to grep.

### Test stubs MUST mirror real tool output — a green stubbed/VM run is not proof
The bats `uci` stub emitted unquoted values + multi-line lists, so 240 tests **and** the VM passed while two bugs reached the live router. Stub `uci`/`dnsmasq`/`nft` in the exact real format. When a VM gate can't truly measure something (the VM's dnsmasq never served queries, so DNS-down was left "advisory"), that blind spot is exactly where a live-only bug hides — verify on real hardware before declaring done.

### dnsmasq config lines cap ~1024 bytes — chunk large domain sets into a conf-dir
A UCI `config ipset` section renders **all** its domains into one `nftset=/d1/d2/.../inet#fw4#set` line. >~1000 domains overflows dnsmasq's config-line buffer → `bad option` → dnsmasq won't start → **DNS outage** (hit live: 1185 itdoginfo domains = 16KB line). For large sets, write byte-chunked `nftset=` lines (≤~900B each) into a dnsmasq conf-dir wired via `uci dhcp.@dnsmasq[0].confdir`, not a UCI config-ipset section. Validate with `dnsmasq --test -C <file>`.

### nftables.d fragments: validate with `fw4 check`, not `nft -c -f`
`/etc/nftables.d/*.nft` are fw4 **includes** (valid only inside `table inet fw4 {...}`); standalone `nft -c -f` reports false syntax errors. Use `fw4 check` (assembled ruleset) before `fw4 reload`. The classifier active file is the `@@LAN_IFNAME@@` template substituted (templates in `/usr/share/amnezia/nftables.d/`, active in `/etc/nftables.d/`) — never drop a second classifier fragment into `/etc/nftables.d/` (duplicate `chain amnezia_classify` breaks reload). `fw4 reload` can drop SSH → run it backgrounded: `( sleep 1 && fw4 reload ) &`.

### Live-router updates: apply the delta surgically, don't re-run the postinst installer
`install-amnezia-pbr.sh` is postinst-style — it assumes the `.ipk` already placed libs (`/usr/lib/amnezia/*.sh`) and the classifier. A manually-cutover router matches no install scenario; re-running the installer skips/half-applies. Update such a router by placing the specific changed files + wiring, verifying WAN/DNS/handshake after each step, snapshotting each replaced file first. SSH is LAN-side (`192.168.1.1:2323`) so it survives routing/tunnel breakage — it's the recovery channel; keep `dev/openwrt-emergency-internet.sh` ready and take a full backup (`dev/openwrt-backup.sh`) first.
