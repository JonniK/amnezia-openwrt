#!/bin/sh
# Remove .ru dnsmasq nftset configuration (legacy list + OpenWrt 24 ipset stanza).
set -eu

uci -q del_list dhcp.@dnsmasq[0].nftset='/.ru/4#inet#fw4#pbr_ru_tld4' 2>/dev/null || true
uci -q delete dhcp.pbr_ru_tld 2>/dev/null || true
uci commit dhcp 2>/dev/null || true
