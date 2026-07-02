# Command cheat sheet (Amnezia + OpenWrt)

**Languages:** English (this file) · [Русский](CHEATSHEET.ru.md)

Short command list — full context in [README.md](README.md) · [RU](README.ru.md).

---

## Install

```sh
# One-liner installer (runs on the router)
wget -O - https://raw.githubusercontent.com/JonniK/amnezia-openwrt/main/install.sh | sh

# Or via .ipk packages
opkg install ./amnezia-pbr.ipk ./luci-app-amnezia.ipk
amnezia-pbr-setup        # download AmneziaWG kmod + zapret, configure UCI
```

## Tunnel management

```sh
amnezia-tunnel-ctl list-free                          # next free slot (awg2..awg5)
amnezia-tunnel-ctl add awg2 "$(cat /tmp/awg2.conf)" --label 'Backup'
amnezia-tunnel-ctl remove awg2
```

## Failover control

```sh
amnezia-failover-ctl set-mode balance                 # load-balance across tunnels
amnezia-failover-ctl set-mode failover                # strict-priority (default)
amnezia-failover-ctl set-sticky awg2                  # pin sticky traffic to awg2
amnezia-failover-ctl set-weight awg2 3                # raise awg2 weight (balance mode)
amnezia-failover-ctl toggle awg2                      # enable / disable awg2 in pool
amnezia-failover-ctl make-default awg2                # renumber metrics: awg2 wins next election
amnezia-failover-ctl force-pin awg2                   # route all pool traffic via awg2 (fail-closed if down)
amnezia-failover-ctl force-unpin                      # restore metric-based pool selection
amnezia-failover-ctl restart awg2                     # bounce awg2 only (ifdown/ifup)
amnezia-failover-ctl set-routing-mode tunnel-default  # foreign traffic -> tunnel, .ru -> direct
amnezia-failover-ctl set-routing-mode direct-default  # all -> WAN direct, allowlist -> tunnel
amnezia-failover-ctl master off                       # fail-open: disable VPN routing + DoT
amnezia-failover-ctl master on                        # restore stack from saved settings
amnezia-failover-ctl set-source refilter_domains 1    # enable a force-tunnel source
amnezia-failover-ctl set-source refilter_domains 0    # disable it
```

## Status

```sh
amnezia-status                          # summary: tunnels, failover state, DoT tier
cat /var/run/amnezia-failover.json      # live JSON: routing_mode, pool, per-tunnel exit_ip
```

## Force allowlist

```sh
amnezia-force-update                    # fetch all enabled sources + load
amnezia-force-load                      # merge cached lists + apply (no fetch)
# Edit manual entries (domains or IPs, one per line):
vi /etc/amnezia/force-tunnel.list
nft list set inet fw4 amnezia_force4 | head   # inspect loaded IPs/CIDRs
```

## Encrypted DNS (DoT)

```sh
amnezia-dns-ctl enable
amnezia-dns-ctl disable
amnezia-dns-ctl set-provider quad9      # quad9 adguard dns0 mullvad google
amnezia-dns-ctl status
```

## DNS-leak prevention

```sh
amnezia-dnsleak-ctl enable    # intercept port 53, block DoT/DoH bypass from LAN
amnezia-dnsleak-ctl disable
amnezia-dnsleak-ctl status
```

## Auto-tunnel (opt-in domain auto-learning)

```sh
amnezia-autotunnel enable     # install cron + dnsmasq query log snippet
amnezia-autotunnel disable    # remove cron + snippet (keeps added domains)
amnezia-autotunnel status
amnezia-autotunnel add example.com
amnezia-autotunnel remove example.com
```

## Backup / restore (run from dev/ on your machine)

```sh
SSH_HOST=openWRT ./dev/openwrt-backup.sh before-changes
SSH_HOST=openWRT ./dev/openwrt-restore.sh before-changes
OPENWRT_RESTORE_YES=1 ./dev/openwrt-restore.sh before-changes   # no prompt
SSH_HOST=openWRT ./dev/openwrt-emergency-internet.sh             # strip VPN, restore plain WAN
```

## Inspect nft sets (on router)

```sh
nft list set inet fw4 amnezia_force4 | head    # current allowlist IPs
nft list set inet fw4 amnezia_ru4 | head       # RU CIDR bypass list
```

## Check connectivity

```sh
ping -c 2 1.1.1.1                  # WAN ping from router
nslookup openwrt.org 127.0.0.1    # DNS on router
curl -4 https://ifconfig.co/ip    # egress IP (should be VPN exit)
ifstatus awg1 | jsonfilter -e '@.up'   # tunnel up/down
