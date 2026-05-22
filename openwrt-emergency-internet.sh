#!/bin/sh
# Emergency: remove VPN/PBR leftovers and restore plain WAN->LAN routing.
# Usage: ./openwrt-emergency-internet.sh
set -eu

SSH_HOST="${SSH_HOST:-router}"

echo "Emergency cleanup on $SSH_HOST (no backup required, but run openwrt-backup.sh first if possible)"

ssh "$SSH_HOST" 'sh -s' <<'REMOTE'
set -eu
echo "=== before ==="
ip route | head -5
ip rule | head -10

/etc/init.d/pbr stop 2>/dev/null || true
/etc/init.d/pbr disable 2>/dev/null || true
/etc/init.d/podkop stop 2>/dev/null || true

for iface in awg1 awg awg0 wg0; do
  ifdown "$iface" 2>/dev/null || true
  uci -q delete "network.$iface" 2>/dev/null || true
done
while uci -q delete network.@amneziawg_awg1[0]; do :; done
while uci -q delete network.@amneziawg_awg[0]; do :; done
while uci -q delete network.@wireguard_awg1[0]; do :; done

uci -q delete network.awg1 2>/dev/null || true
rm -f /etc/config/pbr /etc/config/podkop
rm -rf /etc/pbr.d

# Remove orphan firewall zones for VPN
for z in awg1 awg awg0; do
  idx=0
  while uci -q get firewall.@zone[$idx] >/dev/null 2>&1; do
    name="$(uci -q get firewall.@zone[$idx].name || true)"
    if [ "$name" = "$z" ]; then
      uci delete firewall.@zone[$idx]
    else
      idx=$((idx + 1))
    fi
  done
done
idx=0
while uci -q get firewall.@forwarding[$idx] >/dev/null 2>&1; do
  name="$(uci -q get firewall.@forwarding[$idx].name || true)"
  case "$name" in *awg*|*wg*) uci delete firewall.@forwarding[$idx] ;; *) idx=$((idx + 1)) ;; esac
done

# Ensure WAN DHCP + LAN static defaults
uci set network.wan.proto='dhcp' 2>/dev/null || true
uci set network.lan.proto='static' 2>/dev/null || true
uci set network.lan.ipaddr='192.168.1.1' 2>/dev/null || true
uci set network.lan.netmask='255.255.255.0' 2>/dev/null || true

uci commit network
uci commit firewall

nft delete table inet pbr 2>/dev/null || true
ip rule del pref 30000 2>/dev/null || true
ip rule del pref 30001 2>/dev/null || true

/etc/init.d/network restart
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart 2>/dev/null || true

sleep 3
echo "=== after ==="
ip route
ip rule
ping -c 2 -W 3 1.1.1.1
REMOTE

echo "Done. Reconnect Wi‑Fi / renew DHCP on clients."
