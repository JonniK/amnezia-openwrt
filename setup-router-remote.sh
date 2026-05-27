#!/bin/sh
# Run ON the router after uploading the AWG import to /tmp/awg-setup.conf
set -eu

CONF=/tmp/awg-setup.conf
[ -f "$CONF" ] || { echo "missing $CONF"; exit 1; }
for _f in ru-direct.sh 99-lan-vpn-full.sh install-dnsmasq-full.sh configure-dnsmasq-ru-nftset.sh; do
  [ -f "/tmp/$_f" ] || { echo "missing /tmp/$_f — upload from openwrt/"; exit 1; }
done

IFACE=awg1
CFG=amneziawg_awg1
ZONE=awg1

get() {
  _sec="$1"; _key="$2"
  awk -v s="$_sec" -v k="$_key" '
    $0 ~ "^\\[" s "\\]" { in_s=1; next }
    /^\[/ { in_s=0 }
    in_s && $1==k { sub(/^[^=]+= */, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }
  ' "$CONF"
}

IF_PRIV="$(get Interface PrivateKey)"
IF_ADDR="$(get Interface Address)"
JC="$(get Interface Jc)"; JMIN="$(get Interface Jmin)"; JMAX="$(get Interface Jmax)"
S1="$(get Interface S1)"; S2="$(get Interface S2)"; S3="$(get Interface S3)"; S4="$(get Interface S4)"
H1="$(get Interface H1)"; H2="$(get Interface H2)"; H3="$(get Interface H3)"; H4="$(get Interface H4)"
I1="$(get Interface I1)"; I2="$(get Interface I2)"; I3="$(get Interface I3)"; I4="$(get Interface I4)"; I5="$(get Interface I5)"
PEER_PUB="$(get Peer PublicKey)"
PEER_PSK="$(get Peer PresharedKey)"
PEER_EP="$(get Peer Endpoint)"
PEER_KEEP="$(get Peer PersistentKeepalive)"
PEER_KEEP="${PEER_KEEP:-25}"

PEER_HOST="${PEER_EP%:*}"
PEER_PORT="${PEER_EP##*:}"

[ -n "$IF_PRIV" ] && [ -n "$PEER_PUB" ] && [ -n "$PEER_EP" ] || {
  echo "parse failed"; exit 1
}

# dnsmasq-full: nftset /.ru/ -> pbr_ru_tld4
if ! opkg list-installed | grep -q '^dnsmasq-full '; then
  opkg update >/dev/null 2>&1 || opkg update || true
  if opkg list | grep -q '^dnsmasq-full '; then
    if ! opkg install dnsmasq-full 2>/dev/null; then
      if opkg list-installed | grep -q '^dnsmasq '; then
        opkg remove dnsmasq && { opkg install dnsmasq-full || opkg install dnsmasq; }
      else
        opkg install dnsmasq-full
      fi
    fi
  else
    echo "NOTE: dnsmasq-full not in opkg lists — .ru nftset skipped." >&2
  fi
fi

uci -q delete network.${IFACE} 2>/dev/null || true
while uci -q delete network.@${CFG}[0]; do :; done

uci set network.${IFACE}=interface
uci set network.${IFACE}.proto='amneziawg'
uci set network.${IFACE}.private_key="$IF_PRIV"
uci set network.${IFACE}.addresses="$IF_ADDR"
uci set network.${IFACE}.listen_port='51821'
uci set network.${IFACE}.mtu='1376'
uci set network.${IFACE}.awg_jc="$JC"
uci set network.${IFACE}.awg_jmin="$JMIN"
uci set network.${IFACE}.awg_jmax="$JMAX"
uci set network.${IFACE}.awg_s1="$S1"
uci set network.${IFACE}.awg_s2="$S2"
uci set network.${IFACE}.awg_s3="$S3"
uci set network.${IFACE}.awg_s4="$S4"
uci set network.${IFACE}.awg_h1="$H1"
uci set network.${IFACE}.awg_h2="$H2"
uci set network.${IFACE}.awg_h3="$H3"
uci set network.${IFACE}.awg_h4="$H4"
[ -n "$I1" ] && uci set network.${IFACE}.awg_i1="$I1"
[ -n "$I2" ] && uci set network.${IFACE}.awg_i2="$I2"
[ -n "$I3" ] && uci set network.${IFACE}.awg_i3="$I3"
[ -n "$I4" ] && uci set network.${IFACE}.awg_i4="$I4"
[ -n "$I5" ] && uci set network.${IFACE}.awg_i5="$I5"

uci add network ${CFG}
uci set network.@${CFG}[-1]=${CFG}
uci set network.@${CFG}[-1].name="${IFACE}_client"
uci set network.@${CFG}[-1].public_key="$PEER_PUB"
uci set network.@${CFG}[-1].preshared_key="$PEER_PSK"
uci set network.@${CFG}[-1].endpoint_host="$PEER_HOST"
uci set network.@${CFG}[-1].endpoint_port="$PEER_PORT"
uci set network.@${CFG}[-1].persistent_keepalive="$PEER_KEEP"
uci set network.@${CFG}[-1].allowed_ips='0.0.0.0/0'
uci add_list network.@${CFG}[-1].allowed_ips='::/0'
uci set network.@${CFG}[-1].route_allowed_ips='0'
uci commit network

# Firewall
if ! uci show firewall | grep -q "name='${ZONE}'"; then
  uci add firewall zone
  uci set firewall.@zone[-1].name="$ZONE"
  uci set firewall.@zone[-1].network="$IFACE"
  uci set firewall.@zone[-1].input='REJECT'
  uci set firewall.@zone[-1].output='ACCEPT'
  uci set firewall.@zone[-1].forward='REJECT'
  uci set firewall.@zone[-1].masq='1'
  uci set firewall.@zone[-1].mtu_fix='1'
fi
if ! uci show firewall | grep -q "${ZONE}-lan"; then
  uci add firewall forwarding
  uci set firewall.@forwarding[-1].name="${ZONE}-lan"
  uci set firewall.@forwarding[-1].src='lan'
  uci set firewall.@forwarding[-1].dest="$ZONE"
fi
uci commit firewall

mkdir -p /etc/nftables.d
cat > /etc/nftables.d/15-pbr-ru-tld4.nft <<'NFTFRAG'
	set pbr_ru_tld4 {
		type ipv4_addr
		flags interval
		auto-merge
	}
NFTFRAG

sh /tmp/install-dnsmasq-full.sh 2>/dev/null || true

sh /tmp/configure-dnsmasq-ru-nftset.sh 2>/dev/null || true

# PBR: RU subnets (ipdeny) + *.ru via dnsmasq nftset; LAN -> VPN via raw nft
mkdir -p /etc/pbr.d
cp /tmp/ru-direct.sh /etc/pbr.d/ru-direct.sh
chmod 755 /etc/pbr.d/ru-direct.sh
LAN="$(ip -4 route show table main | awk '/dev br-lan proto kernel/{print $1; exit}')"
[ -n "$LAN" ] || LAN="192.168.1.0/24"
sed "s|__LAN__|$LAN|g" /tmp/99-lan-vpn-full.sh > /etc/pbr.d/99-lan-vpn.sh
chmod 755 /etc/pbr.d/99-lan-vpn.sh

# /etc/pbr.d/* auto-loaded — remove stale uci includes only
while uci -q delete pbr.@policy[0]; do :; done
idx=0
while uci -q get pbr.@include[$idx] >/dev/null 2>&1; do
  path="$(uci -q get pbr.@include[$idx].path || true)"
  case "$path" in
    /etc/pbr.d/ru-direct.sh|/etc/pbr.d/99-lan-vpn.sh) uci delete pbr.@include[$idx] ;;
    *) idx=$((idx + 1)) ;;
  esac
done

uci set pbr.config.enabled='1'
uci set pbr.config.strict_enforcement='0'
uci set pbr.config.resolver_set='none'
uci -q delete pbr.config.supported_interface 2>/dev/null || true
uci add_list pbr.config.supported_interface='awg1'
uci commit pbr

/etc/init.d/firewall reload 2>/dev/null || /etc/init.d/firewall restart
sleep 2
ifdown "$IFACE" 2>/dev/null || true
ifup "$IFACE"
/etc/init.d/pbr enable
/etc/init.d/pbr restart

/etc/init.d/dnsmasq restart 2>/dev/null || true
sleep 2

sleep 4
echo "=== awg1 ==="
ifstatus "$IFACE" | jsonfilter -e '@.up' 2>/dev/null || ifstatus "$IFACE" | head -8
ip link show "$IFACE" 2>/dev/null || true
echo "=== pbr ==="
/etc/init.d/pbr status 2>&1 | head -20
echo "ru ipdeny:"; nft list set inet fw4 pbr_wan_4_dst_ip_user 2>/dev/null | grep -c '/' || true
echo "ru .ru nftset:"; nft list set inet fw4 pbr_ru_tld4 2>/dev/null | grep -c '/' || true
