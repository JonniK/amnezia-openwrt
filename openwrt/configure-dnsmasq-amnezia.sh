#!/bin/sh
# Configure dnsmasq to populate amnezia nftsets via UCI ipset sections.
# Requires dnsmasq-full with nftset support. Safe to re-run.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STICKY_LIST="${STICKY_LIST:-$SCRIPT_DIR/seed-sticky-domains.list}"

if command -v opkg >/dev/null 2>&1; then
  if ! opkg list-installed 2>/dev/null | grep -q '^dnsmasq-full '; then
    echo "NOTE: dnsmasq-full missing — amnezia nftset domain bypass disabled." >&2
    exit 0
  fi
fi

# RU TLD -> amnezia_ru_tld4
uci -q delete dhcp.amnezia_ru_tld 2>/dev/null || true
uci set dhcp.amnezia_ru_tld='ipset'
uci add_list dhcp.amnezia_ru_tld.name='amnezia_ru_tld4'
uci add_list dhcp.amnezia_ru_tld.domain='.ru'
uci set dhcp.amnezia_ru_tld.table='fw4'
uci set dhcp.amnezia_ru_tld.table_family='inet'

# Sticky domains -> amnezia_sticky4
uci -q delete dhcp.amnezia_sticky 2>/dev/null || true
uci set dhcp.amnezia_sticky='ipset'
uci add_list dhcp.amnezia_sticky.name='amnezia_sticky4'
uci set dhcp.amnezia_sticky.table='fw4'
uci set dhcp.amnezia_sticky.table_family='inet'
while IFS= read -r _dom; do
  case "$_dom" in ''|\#*) continue ;; esac
  uci add_list dhcp.amnezia_sticky.domain="$_dom"
done < "$STICKY_LIST"

# Force-list domains -> amnezia_force4
# The nft set itself is declared in the .nft fragment; this section only adds
# domain entries (managed by amnezia-force-load, not here).
uci -q delete dhcp.amnezia_force 2>/dev/null || true
uci set dhcp.amnezia_force='ipset'
uci add_list dhcp.amnezia_force.name='amnezia_force4'
uci set dhcp.amnezia_force.table='fw4'
uci set dhcp.amnezia_force.table_family='inet'

uci commit dhcp
( sleep 1 && /etc/init.d/dnsmasq restart ) &
