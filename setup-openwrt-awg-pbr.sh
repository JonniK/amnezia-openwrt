#!/bin/sh
# Deploy AmneziaWG + Russia bypass (PBR + ipdeny) on OpenWrt via SSH.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SSH_HOST="${SSH_HOST:-router}"
CONF_LOCAL="${CONF_LOCAL:-$SCRIPT_DIR/local/awg.conf}"

if [ ! -f "$CONF_LOCAL" ]; then
  echo "Missing $CONF_LOCAL — see local/README.md or set CONF_LOCAL" >&2
  exit 1
fi

# Parse WireGuard/AWG .conf locally (POSIX sh)
IF_PRIV=""
IF_ADDR=""
IF_DNS=""
JC="" JMIN="" JMAX="" S1="" S2="" S3="" S4=""
H1="" H2="" H3="" H4="" I1="" I2="" I3="" I4="" I5=""
PEER_PUB="" PEER_PSK="" PEER_EP="" PEER_KEEPALIVE="25"

section=""
while IFS= read -r line || [ -n "$line" ]; do
  line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$line" ] && continue
  case "$line" in
    "[Interface]") section=interface ;;
    "[Peer]") section=peer ;;
    *=*)
      key="${line%%=*}"
      val="${line#*=}"
      val="$(echo "$val" | sed 's/^[[:space:]]*//')"
      case "$section:$key" in
        interface:PrivateKey) IF_PRIV="$val" ;;
        interface:Address) IF_ADDR="$val" ;;
        interface:DNS) IF_DNS="$val" ;;
        interface:Jc) JC="$val" ;;
        interface:Jmin) JMIN="$val" ;;
        interface:Jmax) JMAX="$val" ;;
        interface:S1) S1="$val" ;;
        interface:S2) S2="$val" ;;
        interface:S3) S3="$val" ;;
        interface:S4) S4="$val" ;;
        interface:H1) H1="$val" ;;
        interface:H2) H2="$val" ;;
        interface:H3) H3="$val" ;;
        interface:H4) H4="$val" ;;
        interface:I1) I1="$val" ;;
        interface:I2) I2="$val" ;;
        interface:I3) I3="$val" ;;
        interface:I4) I4="$val" ;;
        interface:I5) I5="$val" ;;
        peer:PublicKey) PEER_PUB="$val" ;;
        peer:PresharedKey) PEER_PSK="$val" ;;
        peer:Endpoint) PEER_EP="$val" ;;
        peer:PersistentKeepalive) PEER_KEEPALIVE="$val" ;;
      esac
      ;;
  esac
done < "$CONF_LOCAL"

PEER_HOST="${PEER_EP%:*}"
PEER_PORT="${PEER_EP##*:}"

echo "Upload PBR helpers..."
for _f in openwrt/pbr.d/ru-direct.sh openwrt/pbr.d/99-lan-vpn-full.sh openwrt/pbr.d/99-lan-vpn-vpn-only.sh openwrt/install-dnsmasq-full.sh openwrt/configure-dnsmasq-ru-nftset.sh; do
  cat "$SCRIPT_DIR/$_f" | ssh "$SSH_HOST" "cat > /tmp/$(basename "$_f")"
done

ssh "$SSH_HOST" "sh -s" <<REMOTE
set -eu
IF_PRIV='$IF_PRIV'
IF_ADDR='$IF_ADDR'
JC='$JC' JMIN='$JMIN' JMAX='$JMAX' S1='$S1' S2='$S2' S3='$S3' S4='$S4'
H1='$H1' H2='$H2' H3='$H3' H4='$H4'
I1='$I1' I2='$I2' I3='$I3' I4='$I4' I5='$I5'
PEER_PUB='$PEER_PUB'
PEER_PSK='$PEER_PSK'
PEER_HOST='$PEER_HOST'
PEER_PORT='$PEER_PORT'
PEER_KEEPALIVE='$PEER_KEEPALIVE'

# dnsmasq-full (see openwrt/install-dnsmasq-full.sh)
sh /tmp/install-dnsmasq-full.sh 2>/dev/null || true

IFACE=awg1
CFG=amneziawg_awg1
ZONE=awg1

# --- AmneziaWG interface (no full-tunnel routes; PBR decides paths) ---
uci -q delete network.\${IFACE} 2>/dev/null || true
while uci -q delete network.@\${CFG}[0]; do :; done

uci set network.\${IFACE}=interface
uci set network.\${IFACE}.proto='amneziawg'
uci set network.\${IFACE}.private_key="\$IF_PRIV"
uci set network.\${IFACE}.addresses="\$IF_ADDR"
uci set network.\${IFACE}.listen_port='51821'
uci set network.\${IFACE}.mtu='1376'
uci set network.\${IFACE}.awg_jc="\$JC"
uci set network.\${IFACE}.awg_jmin="\$JMIN"
uci set network.\${IFACE}.awg_jmax="\$JMAX"
uci set network.\${IFACE}.awg_s1="\$S1"
uci set network.\${IFACE}.awg_s2="\$S2"
uci set network.\${IFACE}.awg_s3="\$S3"
uci set network.\${IFACE}.awg_s4="\$S4"
uci set network.\${IFACE}.awg_h1="\$H1"
uci set network.\${IFACE}.awg_h2="\$H2"
uci set network.\${IFACE}.awg_h3="\$H3"
uci set network.\${IFACE}.awg_h4="\$H4"
[ -n "\$I1" ] && uci set network.\${IFACE}.awg_i1="\$I1"
[ -n "\$I2" ] && uci set network.\${IFACE}.awg_i2="\$I2"
[ -n "\$I3" ] && uci set network.\${IFACE}.awg_i3="\$I3"
[ -n "\$I4" ] && uci set network.\${IFACE}.awg_i4="\$I4"
[ -n "\$I5" ] && uci set network.\${IFACE}.awg_i5="\$I5"

uci add network \${CFG}
uci set network.@\${CFG}[-1]=\${CFG}
uci set network.@\${CFG}[-1].name="\${IFACE}_client"
uci set network.@\${CFG}[-1].public_key="\$PEER_PUB"
uci set network.@\${CFG}[-1].preshared_key="\$PEER_PSK"
uci set network.@\${CFG}[-1].endpoint_host="\$PEER_HOST"
uci set network.@\${CFG}[-1].endpoint_port="\$PEER_PORT"
uci set network.@\${CFG}[-1].persistent_keepalive="\$PEER_KEEPALIVE"
uci set network.@\${CFG}[-1].allowed_ips='0.0.0.0/0'
uci add_list network.@\${CFG}[-1].allowed_ips='::/0'
uci set network.@\${CFG}[-1].route_allowed_ips='0'

uci commit network

# --- Firewall ---
if ! uci show firewall | grep -q "name='\${ZONE}'"; then
  uci add firewall zone
  uci set firewall.@zone[-1].name="\$ZONE"
  uci set firewall.@zone[-1].network="\$IFACE"
  uci set firewall.@zone[-1].input='REJECT'
  uci set firewall.@zone[-1].output='ACCEPT'
  uci set firewall.@zone[-1].forward='REJECT'
  uci set firewall.@zone[-1].masq='1'
  uci set firewall.@zone[-1].mtu_fix='1'
fi
if ! uci show firewall | grep -q "\${ZONE}-lan"; then
  uci add firewall forwarding
  uci set firewall.@forwarding[-1].name="\${ZONE}-lan"
  uci set firewall.@forwarding[-1].src='lan'
  uci set firewall.@forwarding[-1].dest="\$ZONE"
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

sh /tmp/configure-dnsmasq-ru-nftset.sh 2>/dev/null || true

# --- PBR: Russia -> WAN (ipdeny + *.ru via dnsmasq nftset), LAN -> VPN ---
mkdir -p /etc/pbr.d
cp /tmp/ru-direct.sh /etc/pbr.d/ru-direct.sh
chmod 755 /etc/pbr.d/ru-direct.sh
LAN="\$(ip -4 route show table main | awk '/dev br-lan proto kernel/{print \$1; exit}')"
[ -n "\$LAN" ] || LAN="192.168.1.0/24"
sed "s|__LAN__|\$LAN|g" /tmp/99-lan-vpn-full.sh > /etc/pbr.d/99-lan-vpn.sh
chmod 755 /etc/pbr.d/99-lan-vpn.sh

# /etc/pbr.d/* auto-loaded — remove stale uci includes only
while uci -q delete pbr.@policy[0]; do :; done
idx=0
while uci -q get pbr.@include[\$idx] >/dev/null 2>&1; do
  path="\$(uci -q get pbr.@include[\$idx].path || true)"
  case "\$path" in
    /etc/pbr.d/ru-direct.sh|/etc/pbr.d/99-lan-vpn.sh) uci delete pbr.@include[\$idx] ;;
    *) idx=\$((idx + 1)) ;;
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
ifdown "\$IFACE" 2>/dev/null || true
ifup "\$IFACE"
/etc/init.d/pbr enable
/etc/init.d/pbr restart

/etc/init.d/dnsmasq restart 2>/dev/null || true
sleep 2

sleep 3
echo "=== status ==="
. /etc/openwrt_release
echo "OpenWrt \$DISTRIB_RELEASE"
ifstatus "\$IFACE" | jsonfilter -e '@.up' 2>/dev/null || ifstatus "\$IFACE" | head -5
/etc/init.d/pbr status 2>&1 | head -25
echo "ru ipdeny elements:"; nft list set inet fw4 pbr_wan_4_dst_ip_user 2>/dev/null | grep -c '/' || true
echo "ru .ru nftset elements:"; nft list set inet fw4 pbr_ru_tld4 2>/dev/null | grep -c '/' || true
REMOTE

echo "Done."
