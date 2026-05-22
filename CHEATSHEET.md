# Command cheat sheet (Amnezia + OpenWrt)

**Languages:** English (this file) · [Русский](CHEATSHEET.ru.md)

Short command list — full context in [README.md](README.md) · [RU](README.ru.md).

Run from the **repository root** (or set `BACKUP_ROOT` / `CONF_LOCAL` explicitly).

| Step | Command |
|------|---------|
| Test SSH to the router | `ssh router uptime` |
| Different SSH host | `SSH_HOST=myrouter ./openwrt-backup.sh my-label` |
| Backup with timestamp label | `./openwrt-backup.sh` |
| Backup before changes | `./openwrt-backup.sh before-amnezia` |
| Backup after successful setup | `./openwrt-backup.sh after-amnezia` |
| Full AWG + PBR deploy (from host) | `./setup-amnezia-full.sh` |
| Deploy with another import file | `CONF_LOCAL=/path/to/import.conf ./setup-amnezia-full.sh` |
| Alternate script (parse `.conf` locally) | `./setup-openwrt-awg-pbr.sh` |
| Deploy on router only | Upload import to **`/tmp/awg-setup.conf`**, then on router: `sh setup-router-remote.sh` |
| Restore snapshot (prompts) | `./openwrt-restore.sh before-amnezia` |
| Restore without prompt (CI/scripts) | `OPENWRT_RESTORE_YES=1 ./openwrt-restore.sh before-amnezia` |
| UCI configs only from snapshot | `./openwrt-restore.sh before-amnezia --uci-only` |
| Emergency: strip VPN/PBR | `./openwrt-emergency-internet.sh` |
| “Outside RU” check from a client | `curl -4 ifconfig.me` or another non‑RU service |
| Check on router (over SSH) | `ifstatus awg1; /etc/init.d/pbr status` |
