# `.ru` domain zone bypass (DNS → nftables)

Deploy scripts install **two** mechanisms for “Russian traffic direct on WAN”:

1. **`ru.zone` (ipdeny)** — `ru-direct.sh` fills `pbr_wan_4_dst_ip_user` with Russian **IPv4 CIDRs**.
2. **`*.ru` via dnsmasq** — **`dnsmasq-full`** is installed when possible; dhcp UCI gets a **`config ipset`** stanza (`pbr_ru_tld`: `domain=.ru`, `name=pbr_ru_tld4`, `table=fw4`, `table_family=inet`). On OpenWrt 24+, the legacy `dhcp.@dnsmasq[0].nftset` list is **ignored** by the dnsmasq init script.  
   Every **A record** for names under `.ru` is added to **`pbr_ru_tld4`**.  
   `99-lan-vpn.sh` returns (no VPN mark) for `ip daddr @pbr_ru_tld4` the same way as for the ipdeny set.

The nft set is defined in **`/etc/nftables.d/15-pbr-ru-tld4.nft`** so it survives normal **firewall4** reloads.

## Why this helps

- **CDN / anycast**: an edge may sit outside `ru.zone` while the name still ends in `.ru`; the dnsmasq path still steers resolved IPs to WAN.
- **First hit**: until a name is resolved, the set has no IP — the first connection may still follow the VPN path until DNS has run through the router’s **dnsmasq**.

## DNS feels slow sometimes

Typical causes:

1. **Cold cache** — first query for a `.ru` name must complete before nft has addresses; later queries are faster (`cachesize` is raised to **8192** when `dnsmasq-full` is present).
2. **Upstream path** — if the router (or client) uses resolvers that are far away or only reachable via the tunnel, fix **WAN / DHCP DNS** so the router’s own upstreams are fast; clients should use the router as DNS when you rely on nftset population.
3. **IPv6** — this setup only adds **IPv4** (`4#…`) to the set; pure-AAAA flows are not matched by `pbr_ru_tld4`.

Optional: add **`list server '/.ru/<resolver-ip>'`** in dhcp dnsmasq (or Luci) to force a specific resolver for `.ru` only — choose one you trust and that is reachable **without** the VPN if you use split DNS.

## Packages

- Replacing **`dnsmasq`** with **`dnsmasq-full`** can briefly disturb DNS during `opkg`; scripts try **`opkg install dnsmasq-full`** first, then remove+install with **fallback to `dnsmasq`** if full fails.
- If **`dnsmasq-full`** is missing, `openwrt/configure-dnsmasq-ru-nftset.sh` is skipped (note in log); **ipdeny** bypass still works.

## Emergency cleanup

`openwrt-emergency-internet.sh` removes **`/etc/nftables.d/15-pbr-ru-tld4.nft`**, drops the **`pbr_ru_tld`** ipset stanza (and legacy nftset list) from dhcp, and clears **`/etc/pbr.d`**.

## See also

- [amnezia_sites_ru_geoip.md](amnezia_sites_ru_geoip.md) — ipdeny `ru.zone` source.
