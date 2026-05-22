#!/bin/sh
# Full AmneziaWG 2.0 + PBR (RU bypass via ipdeny) on OpenWrt.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SSH_HOST="${SSH_HOST:-router}"
CONF_LOCAL="${CONF_LOCAL:-$SCRIPT_DIR/local/awg.conf}"

[ -f "$CONF_LOCAL" ] || { echo "Missing $CONF_LOCAL (see local/README.md or set CONF_LOCAL)"; exit 1; }

echo "1) Upload config..."
cat "$CONF_LOCAL" | ssh "$SSH_HOST" 'cat > /tmp/awg-setup.conf'

echo "2) Install packages + configure on router..."
ssh "$SSH_HOST" 'sh -s' <<'REMOTE'
set -eu

VER=24.10.3
ARCH=aarch64_cortex-a53
TS=mediatek_filogic
BASE="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${VER}"
DIR=/tmp/awg-pkgs
IFACE=awg1
CFG=amneziawg_awg1
ZONE=awg1
CONF=/tmp/awg-setup.conf

# --- Install AWG 2.0 if missing ---
if ! opkg list-installed | grep -q '^kmod-amneziawg '; then
  mkdir -p "$DIR"
  opkg update >/dev/null
  for pkg in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
    f="${pkg}_v${VER}_${ARCH}_${TS}.ipk"
    wget -q -O "$DIR/$f" "$BASE/$f" || { echo "FAIL download $f"; exit 1; }
    opkg install "$DIR/$f"
  done
  rm -rf "$DIR"
fi

opkg install pbr luci-app-pbr 2>/dev/null || true
opkg install resolveip ip-full 2>/dev/null || true

# --- Parse .conf ---
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

[ -n "$IF_PRIV" ] && [ -n "$PEER_PUB" ] || { echo "config parse failed"; exit 1; }

# --- AWG interface (no default route via WG — PBR handles it) ---
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

# Firewall zone
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

# Bring up VPN BEFORE PBR
/etc/init.d/firewall restart
/etc/init.d/network restart
sleep 5
ifup "$IFACE" 2>/dev/null || true
sleep 3

# --- PBR: RU -> WAN (ipdeny), rest of LAN -> VPN ---
mkdir -p /etc/pbr.d
cat > /etc/pbr.d/ru-direct.sh <<'RUSCRIPT'
#!/bin/sh
TARGET_URL='https://www.ipdeny.com/ipblocks/data/countries/ru.zone'
TARGET_FILE='/var/pbr_ru.zone'
TARGET_TABLE='inet fw4'
TARGET_INTERFACE='wan'
NFTSET="pbr_${TARGET_INTERFACE}_4_dst_ip_user"
BATCH=300
_ret=0
mkdir -p "${TARGET_FILE%/*}"
[ -s "$TARGET_FILE" ] || wget -q -O "$TARGET_FILE" "$TARGET_URL" || return 1
nft "flush element $TARGET_TABLE $NFTSET" 2>/dev/null || true
batch=""; count=0
while IFS= read -r cidr; do
  [ -z "$cidr" ] && continue
  case "$cidr" in \#*) continue ;; esac
  if [ -z "$batch" ]; then batch="$cidr"; else batch="$batch, $cidr"; fi
  count=$((count + 1))
  if [ "$count" -ge "$BATCH" ]; then
    nft "add element $TARGET_TABLE $NFTSET { $batch }" 2>/dev/null || _ret=1
    batch=""; count=0
  fi
done < "$TARGET_FILE"
[ -n "$batch" ] && nft "add element $TARGET_TABLE $NFTSET { $batch }" 2>/dev/null || _ret=1
return $_ret
RUSCRIPT
chmod 755 /etc/pbr.d/ru-direct.sh

cat > /etc/pbr.d/99-lan-vpn.sh <<'LANSCRIPT'
#!/bin/sh
# LAN: RU -> WAN (skip mark), everything else -> VPN
nft add rule inet fw4 pbr_prerouting ip saddr { 192.168.1.0/24 } ip daddr @pbr_wan_4_dst_ip_user return comment "ru_direct_skip"
nft add rule inet fw4 pbr_prerouting ip saddr { 192.168.1.0/24 } goto pbr_mark_0x020000 comment "lan_via_vpn"
return 0
LANSCRIPT
chmod 755 /etc/pbr.d/99-lan-vpn.sh

while uci -q delete pbr.@policy[0]; do :; done
idx=0
while uci -q get pbr.@include[$idx] >/dev/null 2>&1; do
  path="$(uci -q get pbr.@include[$idx].path || true)"
  if [ "$path" = '/etc/pbr.d/ru-direct.sh' ]; then
    uci delete pbr.@include[$idx]
  else
    idx=$((idx + 1))
  fi
done

uci set pbr.config.enabled='1'
uci set pbr.config.strict_enforcement='0'
uci set pbr.config.resolver_set='none'
while uci -q del_list pbr.config.supported_interface 2>/dev/null; do :; done
uci add_list pbr.config.supported_interface='awg1'

uci add pbr include
uci set pbr.@include[-1].path='/etc/pbr.d/ru-direct.sh'
uci set pbr.@include[-1].enabled='1'

uci add pbr include
uci set pbr.@include[-1].path='/etc/pbr.d/99-lan-vpn.sh'
uci set pbr.@include[-1].enabled='1'

uci commit pbr

/etc/init.d/pbr enable
/etc/init.d/pbr restart
sleep 5

echo "========== STATUS =========="
echo -n "awg1 up: "
ifstatus "$IFACE" | jsonfilter -e '@.up' 2>/dev/null || echo "?"
ip -4 addr show dev "$IFACE" 2>/dev/null | grep inet || true
echo -n "wan ping: "
ping -c 1 -W 3 1.1.1.1 >/dev/null && echo OK || echo FAIL
echo -n "awg ping: "
ping -c 1 -W 3 -I "$IFACE" 1.1.1.1 >/dev/null && echo OK || echo FAIL
echo "pbr:"
/etc/init.d/pbr status 2>&1 | head -15
echo "ru set size:"
nft list set inet fw4 pbr_wan_4_dst_ip_user 2>/dev/null | grep -c '/' || true
REMOTE

echo "Done. From a LAN client: curl ifconfig.me (expect VPN IP for non-RU destinations)."
