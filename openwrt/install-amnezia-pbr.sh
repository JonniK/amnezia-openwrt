#!/bin/sh
# install-amnezia-pbr: end-to-end installer that runs ON the router.
#
# Drives three steps:
#   STEPS=1   AmneziaWG interface + firewall zone (kmod + tools + UCI + ifup)
#   STEPS=2   + Policy-based routing base (LAN forwarded via awg1)
#   STEPS=3   + RU bypass (.ru TLD via dnsmasq nftset + ipdeny RU CIDR list)
#
# Inputs:
#   /tmp/awg-setup.conf       AmneziaWG client config exported from Amnezia
#                              client (or the desktop wireguard-style conf
#                              with the extra Jc/Jmin/Jmax/S*/H*/I* lines).
#                              Override via CONF env var.
#   /tmp/<helper>.sh          The wrappers + LuCI app + install-* scripts,
#                              pre-uploaded by the bootstrap (install.sh)
#                              or deploy (dev/deploy-openwrt-safe.sh).
#
# Outputs:
#   /tmp/openwrt-deploy.log   step-by-step log; ends with DEPLOY_DONE or
#                              DEPLOY_FAILED so callers can poll it.
#
# Never restarts the network as a whole -- only `firewall reload` and
# targeted `ifup awg1`. Pings WAN before/after each destructive step so a
# remote run can fail fast instead of leaving you locked out.
#
# This script intentionally has no SSH knowledge -- the maintainer wrapper
# (dev/deploy-openwrt-safe.sh) handles SSH, the public bootstrap
# (install.sh) handles tarball download. Both end up here.
# shellcheck disable=SC2039
set -eu

STEPS="${STEPS:-${1:-3}}"
LOG="${LOG:-/tmp/openwrt-deploy.log}"
CONF="${CONF:-/tmp/awg-setup.conf}"
IFACE=awg1
CFG=amneziawg_awg1
ZONE=awg1

# AmneziaWG kmod + tools come from Slava-Shchipunov's release feed -- they
# aren't in the official OpenWrt repos. Auto-detect arch and target from
# /etc/openwrt_release; env override lets the maintainer pin a build that
# doesn't match the running kernel (rare but useful when testing a kmod ABI).
. /etc/openwrt_release 2>/dev/null || true
AWG_VER="${AWG_VER:-24.10.3}"
AWG_ARCH="${AWG_ARCH:-${DISTRIB_ARCH:-aarch64_cortex-a53}}"
AWG_TS="${AWG_TS:-${DISTRIB_TARGET:-mediatek/filogic}}"
# /etc/openwrt_release stores TARGET as `mediatek/filogic`; Slava's release
# filenames use the underscore form `mediatek_filogic.ipk`.
AWG_TS_FLAT=$(printf '%s' "$AWG_TS" | tr '/' '_')

log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
fail() { log "DEPLOY_FAILED: $*"; exit 1; }
ok()   { log "STEP_OK: $*"; }

need_wan() {
  ping -c 2 -W 4 1.1.1.1 >/dev/null 2>&1 || fail "WAN down (1.1.1.1)"
  ping -c 2 -W 4 8.8.8.8 >/dev/null 2>&1 || fail "WAN down (8.8.8.8)"
}

need_dns() {
  nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1 || nslookup google.com 127.0.0.1 >/dev/null 2>&1 || \
    fail "DNS on router broken"
}

lan_cidr() {
  ip -4 route show table main 2>/dev/null | awk '/dev br-lan proto kernel/{print $1; exit}'
}

pbr_nft_ok() {
  [ -f /var/run/pbr.nft ] || return 1
  nft -c -f /var/run/pbr.nft 2>/dev/null
}

# Read a key from a section of a wireguard-style ini config. Tolerates blank
# lines, "Key = Value" or "Key=Value", whitespace around the value.
get() {
  _sec="$1"; _key="$2"
  awk -v s="$_sec" -v k="$_key" '
    $0 ~ "^\\[" s "\\]" { in_s=1; next }
    /^\[/ { in_s=0 }
    in_s && $1==k { sub(/^[^=]+= */, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }
  ' "$CONF"
}

log "DEPLOY_START steps=$STEPS arch=$AWG_ARCH target=$AWG_TS"
[ -f "$CONF" ] || fail "missing AWG config at $CONF (provide Amnezia-exported .conf)"
need_wan
need_dns
ok "0 preflight"

# --- Step 1: AWG UCI + ifup (no network restart) ---
log "Step 1: AWG interface"
if ! opkg list-installed | grep -q '^kmod-amneziawg '; then
  BASE="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${AWG_VER}"
  DIR=/tmp/awg-pkgs; mkdir -p "$DIR"
  opkg update >/dev/null || opkg update || fail "opkg update"
  for pkg in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
    f="${pkg}_v${AWG_VER}_${AWG_ARCH}_${AWG_TS_FLAT}.ipk"
    wget -q -O "$DIR/$f" "$BASE/$f" || fail "download $f"
    opkg install "$DIR/$f" || fail "install $pkg"
  done
  rm -rf "$DIR"
fi
opkg install pbr luci-app-pbr resolveip ip-full 2>/dev/null || true

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
[ -n "$IF_PRIV" ] && [ -n "$PEER_PUB" ] || fail "awg.conf parse (missing PrivateKey or PublicKey)"

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

# reload firewall only — NOT full network restart
/etc/init.d/firewall reload 2>/dev/null || /etc/init.d/firewall restart
sleep 2
need_wan
need_dns

ifup "$IFACE" 2>/dev/null || ifup "$IFACE" || fail "ifup $IFACE"
_i=0
while [ "$_i" -lt 12 ]; do
  if ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null | grep -q true; then
    break
  fi
  _i=$((_i + 1))
  sleep 2
done
ifstatus "$IFACE" | jsonfilter -e '@.up' 2>/dev/null | grep -q true || fail "awg1 not up"
ping -c 2 -W 5 -I "$IFACE" 1.1.1.1 >/dev/null || fail "awg1 ping fail"
need_wan
need_dns

# LuCI toggle buttons (System -> Custom Commands). Non-fatal.
if SRC=/tmp/awg-toggle.sh sh /tmp/install-luci-toggle.sh >>"$LOG" 2>&1; then
  log "luci toggle installed"
else
  log "WARN: luci toggle install failed (non-fatal)"
fi

# zapret (DPI desync) install. Service stays DISABLED after install -- user
# enables via the LuCI button. Non-fatal: failure here must not break AWG.
if sh /tmp/install-zapret.sh >>"$LOG" 2>&1; then
  log "zapret installed (service left disabled)"
else
  log "WARN: zapret install failed (non-fatal)"
fi

# Refresh LuCI app: menu entry, ACL (rpcd permissions for our exec/read
# endpoints), and the main.js view. Non-fatal -- a broken LuCI panel must
# not block AWG/PBR; user can still drive everything from CLI. The
# installer reloads rpcd + uhttpd so ACL changes take effect immediately.
if SRC=/tmp/luci-app-amnezia sh /tmp/install-luci-app-amnezia.sh >>"$LOG" 2>&1; then
  log "luci-app-amnezia refreshed (menu/acl/view)"
else
  log "WARN: luci-app-amnezia refresh failed (non-fatal)"
fi

ok "1 awg1"

if [ "$STEPS" -lt 2 ]; then
  log "DEPLOY_DONE steps=$STEPS (awg only)"
  exit 0
fi

# --- Step 2: PBR base (LAN -> VPN) ---
log "Step 2: PBR base"
LAN="$(lan_cidr)"
[ -n "$LAN" ] || LAN="192.168.1.0/24"
mkdir -p /etc/pbr.d
rm -f /etc/pbr.d/ru-direct.sh
sed "s|__LAN__|$LAN|g" /tmp/99-lan-vpn-vpn-only.sh > /etc/pbr.d/99-lan-vpn.sh
chmod 755 /etc/pbr.d/99-lan-vpn.sh

while uci -q delete pbr.@policy[0]; do :; done
idx=0
while uci -q get "pbr.@include[$idx]" >/dev/null 2>&1; do
  path="$(uci -q get pbr.@include[$idx].path || true)"
  case "$path" in
    /etc/pbr.d/ru-direct.sh|/etc/pbr.d/99-lan-vpn.sh) uci delete "pbr.@include[$idx]" ;;
    *) idx=$((idx + 1)) ;;
  esac
done
uci set pbr.config.enabled='1'
uci set pbr.config.strict_enforcement='0'
uci set pbr.config.resolver_set='none'
uci -q delete pbr.config.supported_interface 2>/dev/null || true
uci add_list pbr.config.supported_interface='awg1'
uci commit pbr

/etc/init.d/pbr enable
/etc/init.d/pbr restart
sleep 8
pbr_nft_ok || fail "pbr.nft syntax error (step2)"
need_wan
need_dns
ok "2 pbr_base"

if [ "$STEPS" -lt 3 ]; then
  log "DEPLOY_DONE steps=$STEPS"
  exit 0
fi

# --- Step 3: RU bypass (ipdeny + dnsmasq nftset) ---
log "Step 3: RU bypass"

mkdir -p /etc/nftables.d
cat > /etc/nftables.d/15-pbr-ru-tld4.nft <<'NFTFRAG'
	set pbr_ru_tld4 {
		type ipv4_addr
		flags interval
		auto-merge
	}
NFTFRAG
/etc/init.d/firewall reload 2>/dev/null || true
sleep 2

sh /tmp/install-dnsmasq-full.sh 2>/dev/null || fail "dnsmasq-full install"
need_dns || fail "DNS broken after dnsmasq-full"

sh /tmp/configure-dnsmasq-ru-nftset.sh 2>/dev/null || fail "dnsmasq .ru nftset config"

# ru-direct + full LAN rules (idempotent — no duplicate nft rules on pbr restart)
cp /tmp/ru-direct.sh /etc/pbr.d/ru-direct.sh
chmod 755 /etc/pbr.d/ru-direct.sh
sed "s|__LAN__|$LAN|g" /tmp/99-lan-vpn-full.sh > /etc/pbr.d/99-lan-vpn.sh
chmod 755 /etc/pbr.d/99-lan-vpn.sh

idx=0
while uci -q get "pbr.@include[$idx]" >/dev/null 2>&1; do
  path="$(uci -q get pbr.@include[$idx].path || true)"
  case "$path" in
    /etc/pbr.d/ru-direct.sh|/etc/pbr.d/99-lan-vpn.sh) uci delete "pbr.@include[$idx]" ;;
    *) idx=$((idx + 1)) ;;
  esac
done
uci commit pbr

/etc/init.d/pbr restart
sleep 10
pbr_nft_ok || fail "pbr.nft syntax error (step3 ru-direct)"
logread 2>/dev/null | tail -20 | grep -qi "FAILED TO START" && fail "PBR failed to start step3"

/etc/init.d/dnsmasq restart 2>/dev/null || true
sleep 3
need_wan
need_dns
nslookup -type=A mail.ru 127.0.0.1 >/dev/null 2>&1 || log "WARN: mail.ru lookup failed (may need time)"

_ipdeny=$(nft list set inet fw4 pbr_wan_4_dst_ip_user 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | wc -l)
_ipdeny=$(printf '%s' "$_ipdeny" | tr -d ' ')
log "ipdeny entries: $_ipdeny"
[ "$_ipdeny" -gt 100 ] || fail "ipdeny set too small ($_ipdeny)"

ok "3 ru_bypass"
log "DEPLOY_DONE steps=$STEPS"
