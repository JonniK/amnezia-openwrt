#!/bin/sh
# Configure dnsmasq to populate inet fw4 pbr_ru_tld4 for *.ru (OpenWrt 24+ ipset stanza).
# Requires dnsmasq-full with nftset support. Safe to re-run.
set -eu

if ! opkg list-installed | grep -q '^dnsmasq-full '; then
	echo "NOTE: dnsmasq-full missing — .ru domain nftset bypass disabled." >&2
	exit 0
fi

# OpenWrt <=23: dhcp.@dnsmasq[0].nftset='/.ru/4#inet#fw4#pbr_ru_tld4'
# OpenWrt 24+: config ipset { list name; list domain; option table; option table_family }
uci -q del_list dhcp.@dnsmasq[0].nftset='/.ru/4#inet#fw4#pbr_ru_tld4' 2>/dev/null || true

uci -q delete dhcp.pbr_ru_tld 2>/dev/null || true
uci set dhcp.pbr_ru_tld='ipset'
uci add_list dhcp.pbr_ru_tld.name='pbr_ru_tld4'
uci add_list dhcp.pbr_ru_tld.domain='.ru'
uci set dhcp.pbr_ru_tld.table='fw4'
uci set dhcp.pbr_ru_tld.table_family='inet'

uci set dhcp.@dnsmasq[0].cachesize='8192'
uci commit dhcp

/etc/init.d/dnsmasq restart
