# AmneziaWG + OpenWrt (split tunnel)

**Languages:** English (this file) · [Русский](README.ru.md)

Scripts and notes for deploying **AmneziaWG 2.0** on **OpenWrt** with **policy-based routing (PBR)**: traffic to Russian subnets goes out **WAN**; other LAN traffic uses the VPN (**`awg1`**). Includes **backup / restore** without a factory reset.

## What this does

1. **Split routing (“RU direct, rest via VPN”)**  
   Russian IPv4 ranges are loaded from [ipdeny `ru.zone`](https://www.ipdeny.com/ipblocks/data/countries/ru.zone) into the PBR nftables set `pbr_wan_4_dst_ip_user`. For clients in **`192.168.1.0/24`**, non‑RU destinations are steered through **`awg1`**.

2. **AmneziaWG in UCI**  
   Interface **`awg1`**, firewall zone **`awg1`**, LAN → VPN forwarding, peer with **`route_allowed_ips=0`** so the tunnel does **not** install a full default route—PBR chooses paths.

3. **AWG packages pinned to a build**  
   `setup-amnezia-full.sh` embeds OpenWrt package **`VER`**, **`ARCH`**, and **`TS`** for [awg-openwrt releases](https://github.com/Slava-Shchipunov/awg-openwrt/releases). Change those lines for your device.

4. **Router snapshots under `openwrt-backups/`** (local only, see `openwrt-backups/.gitignore`):  
   Examples: `clean-after-reset`, `before-amnezia`, `after-amnezia`—whatever labels you choose when running `openwrt-backup.sh`.

5. **`amnezia_sites_ru_geoip.json`** — large CIDR JSON (optional “RU direct” source). Current shell scripts use **ipdeny** instead.

6. **Amnezia client export** (`vpn://…`) — for the Amnezia desktop app only, not for router UCI.

## Files

| Path | Purpose |
|------|---------|
| `setup-amnezia-full.sh` | **Main SSH flow:** upload import, install kmod/tools/luci AmneziaWG + PBR, UCI + firewall + `ru-direct.sh` + `99-lan-vpn.sh`, restart services. |
| `setup-openwrt-awg-pbr.sh` | Alternate deploy: parse `.conf` **on your machine**, pass values over SSH (same idea as “full”, different parse path). |
| `setup-router-remote.sh` | Run **on the router** after placing **`/tmp/awg-setup.conf`**. |
| `openwrt-backup.sh` | Pull snapshot: selected `/etc/config/*`, `uci export`, `opkg list-installed`, routes/rules, optional `sysupgrade -b`. |
| `openwrt-restore.sh` | Restore by label; `--uci-only` for configs only. Prompts unless `OPENWRT_RESTORE_YES=1`. |
| `openwrt-emergency-internet.sh` | Strip VPN/PBR, reset typical WAN DHCP + LAN `192.168.1.1/24`. |
| `openwrt-backups/<label>/` | Extracted backup: `config/`, `meta/`, `README.txt` with restore hints. |
| `amnezia_sites_ru_geoip.json` | Optional CIDR list (not used by current sh scripts). |
| [CHEATSHEET.md](CHEATSHEET.md) | Command table · [Шпаргалка (RU)](CHEATSHEET.ru.md) |
| `local/README.md` | Default import location (`local/awg.conf`, not in git). [Русский](local/README.ru.md) |
| `.gitignore` | Ignores `local/*` except `local/README*.md`; see `openwrt-backups/.gitignore` for snapshots. |

## Requirements

- SSH host for the router (default **`router`** in scripts—override with **`SSH_HOST`**), e.g. in `~/.ssh/config`.
- Optional env:
  - **`SSH_HOST`** — SSH target;
  - **`CONF_LOCAL`** — path to decoded `.conf` with keys (default **`local/awg.conf`**, see `local/README.md` / `local/README.ru.md`);
  - **`BACKUP_ROOT`** — backup root (default **`openwrt-backups/`** next to the scripts).

## Typical workflow

1. Decode Amnezia config to a plain `.conf` and place it at **`CONF_LOCAL`** (default **`local/awg.conf`**, see `local/README.md` / `local/README.ru.md`).
2. Before changes: `./openwrt-backup.sh before-amnezia`
3. Full install from your host: `./setup-amnezia-full.sh` (adjust **`VER` / `ARCH` / `TS`** if needed).
4. After checks: `./openwrt-backup.sh after-amnezia`

From a LAN client, e.g. `curl ifconfig.me` — for non‑RU checks you should see the VPN egress IP.

## Rollback & emergency

- Restore: `./openwrt-restore.sh before-amnezia` (or your label).
- If the router is unreachable except LAN: `./openwrt-emergency-internet.sh`, then renew DHCP / reconnect Wi‑Fi on clients.

## Security

- **`local/awg.conf`** (or any **`CONF_LOCAL`**) and **`openwrt-backups/*`** hold **keys and sensitive UCI**. They are excluded by **`.gitignore`** and **`openwrt-backups/.gitignore`**. Rotate in Amnezia if leaked.
- If something was committed before these rules: `git rm --cached local/awg.conf`, `git rm -r --cached openwrt-backups/<label>/`, etc.

## LAN note

Scripts assume **`192.168.1.0/24`**. For another LAN, edit `99-lan-vpn.sh` / PBR policies in the `.sh` files (or UCI / `/etc/pbr.d` on the router).

## Command cheat sheet

See **[CHEATSHEET.md](CHEATSHEET.md)** · [RU](CHEATSHEET.ru.md).

## FAQ

**Difference between `setup-amnezia-full.sh` and `setup-openwrt-awg-pbr.sh`?**  
`full` downloads AmneziaWG `.ipk` from GitHub for pinned **`VER`/`ARCH`/`TS`**, uploads the import, parses on the router from **`/tmp/awg-setup.conf`**, adds `99-lan-vpn.sh`, restarts in a fixed order. `setup-openwrt-awg-pbr.sh` parses `.conf` **on your machine** and passes values in a heredoc; it does **not** install AWG packages—you must have them already.

**`Missing …` (no import file).**  
Fix **`CONF_LOCAL`** or create **`local/awg.conf`** (see `local/README.md` / `local/README.ru.md`). Example:  
`CONF_LOCAL=/absolute/path/to/import.conf ./setup-amnezia-full.sh`.

**`.ipk` download / `opkg install` fails.**  
Usually **`ARCH`** or **`TS`** mismatch vs [awg-openwrt releases](https://github.com/Slava-Shchipunov/awg-openwrt/releases). On the router: `cat /etc/openwrt_release` and update **`ARCH`**, **`TS`**, **`VER`** in `setup-amnezia-full.sh`.

**`curl ifconfig.me` shows ISP IP, not VPN.**  
Test a **non‑**Russian destination; some CDNs map oddly. Check `ifstatus awg1`, PBR status, client in **`192.168.1.0/24`**. On the router, read the script footer (`awg ping`, `pbr`).

**RU sites via VPN or odd routing.**  
ipdeny updates over time; CDN edge cases exist. On the router: `/etc/init.d/pbr restart` ( `ru-direct.sh` refreshes `ru.zone` when needed).

**Use `amnezia_sites_ru_geoip.json` instead of ipdeny?**  
Current sh scripts **do not** wire it in—you’d need a custom generator / nft rules.

**LAN is not `192.168.1.0/24` or I have a guest network.**  
Change the subnet in `99-lan-vpn.sh` and PBR `src_addr` / nft `ip saddr` in all involved scripts, then redeploy or edit UCI / `/etc/pbr.d` manually.

**`openwrt-restore.sh` waits at `Continue?`**  
Non‑interactive: `OPENWRT_RESTORE_YES=1 ./openwrt-restore.sh <label>`.

**No internet on clients after restore / emergency.**  
Renew DHCP, reconnect Wi‑Fi, or reboot the router.

**Do I need git?**  
No—only SSH + POSIX `sh`. Git is handy to version scripts and docs **without** secrets—see **`.gitignore`** and [CHEATSHEET.md](CHEATSHEET.md) · [RU](CHEATSHEET.ru.md).
