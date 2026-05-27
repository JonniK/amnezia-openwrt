#!/bin/sh
# Safe OpenWrt deploy: runs ON the router in background (survives SSH drop).
# Local side: backup, upload config, start remote job, poll until DONE/FAILED.
#
# Usage:
#   SSH_HOST=openWRT ./deploy-openwrt-safe.sh
#   SSH_HOST=openWRT STEPS=1 ./deploy-openwrt-safe.sh   # AWG+PBR only, no RU bypass
#   SSH_HOST=openWRT STEPS=3 ./deploy-openwrt-safe.sh   # full (default)
#
# Never uses "network restart". WAN ping checked before/after every step.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SSH_HOST="${SSH_HOST:-router}"
CONF_LOCAL="${CONF_LOCAL:-$SCRIPT_DIR/local/awg.conf}"
STEPS="${STEPS:-3}"
LOG_REMOTE="/tmp/openwrt-deploy.log"
PID_REMOTE="/tmp/openwrt-deploy.pid"
BACKUP_LABEL="before-safe-deploy-$(date +%Y%m%d-%H%M)"

SSH_OPTS="-o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3"

ssh_wait() {
  _n=0
  while [ "$_n" -lt 72 ]; do
    if ssh $SSH_OPTS "$SSH_HOST" true 2>/dev/null; then
      return 0
    fi
    _n=$((_n + 1))
    printf '  waiting for %s (%s/72)...\n' "$SSH_HOST" "$_n"
    sleep 5
  done
  return 1
}

ssh_run() {
  ssh $SSH_OPTS "$SSH_HOST" "$@"
}

need_local_conf() {
  [ -f "$CONF_LOCAL" ] || {
    echo "Missing $CONF_LOCAL"
    exit 1
  }
}

preflight_local() {
  echo "=== Preflight (local -> router) ==="
  ssh_wait || { echo "Router unreachable"; exit 1; }
  ssh_run 'sh -s' <<'CHK'
set -eu
echo -n "wan: "; ifstatus wan | jsonfilter -e '@.up' 2>/dev/null || echo FAIL
ping -c 2 -W 3 1.1.1.1 >/dev/null || { echo "FAIL: no ping 1.1.1.1"; exit 1; }
ping -c 2 -W 3 8.8.8.8 >/dev/null || { echo "FAIL: no ping 8.8.8.8"; exit 1; }
command -v nslookup >/dev/null && nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1 || true
echo "preflight OK"
CHK
}

start_remote_deploy() {
  echo "=== Upload deploy script + AWG config + PBR helpers ==="
  for _f in openwrt/pbr.d/ru-direct.sh openwrt/pbr.d/99-lan-vpn-full.sh openwrt/pbr.d/99-lan-vpn-vpn-only.sh openwrt/install-dnsmasq-full.sh openwrt/configure-dnsmasq-ru-nftset.sh openwrt/awg-toggle.sh openwrt/install-luci-toggle.sh openwrt/zapret-toggle.sh openwrt/zapret-status.sh openwrt/zapret-blockcheck.sh openwrt/zapret-apply.sh openwrt/install-zapret.sh; do
    cat "$SCRIPT_DIR/$_f" | ssh_run "cat > /tmp/$(basename "$_f")"
  done
  ssh_run "cat > /tmp/openwrt-deploy-body.sh && chmod +x /tmp/openwrt-deploy-body.sh" <<'REMOTE_BODY'
#!/bin/sh
# shellcheck disable=SC2039
set -eu

STEPS="${1:-3}"
LOG="${LOG:-/tmp/openwrt-deploy.log}"
IFACE=awg1
CFG=amneziawg_awg1
ZONE=awg1
CONF=/tmp/awg-setup.conf

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

pbr_running() {
  [ -f /var/run/pbr.nft ] && ! logread 2>/dev/null | tail -30 | grep -q "pbr.*FAILED TO START"
}

get() {
  _sec="$1"; _key="$2"
  awk -v s="$_sec" -v k="$_key" '
    $0 ~ "^\\[" s "\\]" { in_s=1; next }
    /^\[/ { in_s=0 }
    in_s && $1==k { sub(/^[^=]+= */, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }
  ' "$CONF"
}

log "DEPLOY_START steps=$STEPS"
need_wan
need_dns
ok "0 preflight"

# --- Step 1: AWG UCI + ifup (no network restart) ---
log "Step 1: AWG interface"
if ! opkg list-installed | grep -q '^kmod-amneziawg '; then
  VER=24.10.3; ARCH=aarch64_cortex-a53; TS=mediatek_filogic
  BASE="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${VER}"
  DIR=/tmp/awg-pkgs; mkdir -p "$DIR"
  opkg update >/dev/null || opkg update || fail "opkg update"
  for pkg in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
    f="${pkg}_v${VER}_${ARCH}_${TS}.ipk"
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
[ -n "$IF_PRIV" ] && [ -n "$PEER_PUB" ] || fail "awg.conf parse"

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

_ipdeny=$(nft list set inet fw4 pbr_wan_4_dst_ip_user 2>/dev/null | grep -c '/' || echo 0)
log "ipdeny entries: $_ipdeny"
[ "$_ipdeny" -gt 100 ] || fail "ipdeny set too small ($_ipdeny)"

ok "3 ru_bypass"
log "DEPLOY_DONE steps=$STEPS"
REMOTE_BODY
  ssh_run "cat > /tmp/awg-setup.conf" <"$CONF_LOCAL"
  ssh_run "STEPS=$STEPS LOG=$LOG_REMOTE sh -s" <<'REMOTE_WRAPPER'
set -eu
LOG="${LOG:-/tmp/openwrt-deploy.log}"
STEPS="${STEPS:-3}"
: > "$LOG"
(
  exec sh /tmp/openwrt-deploy-body.sh "$STEPS"
) >>"$LOG" 2>&1 &
echo $! > /tmp/openwrt-deploy.pid
sleep 1
kill -0 "$(cat /tmp/openwrt-deploy.pid)" 2>/dev/null || { echo "deploy process died immediately"; tail -5 "$LOG"; exit 1; }
echo "started pid $(cat /tmp/openwrt-deploy.pid)"
REMOTE_WRAPPER
}

poll_remote() {
  echo "=== Waiting for deploy on router (SSH may drop — will retry) ==="
  _last=""
  _stall=0
  while true; do
  if ! ssh_wait; then
    continue
  fi
  _tail=$(ssh_run "tail -3 '$LOG_REMOTE' 2>/dev/null" || true)
  if [ "$_tail" != "$_last" ]; then
    printf '%s\n' "$_tail"
    _last="$_tail"
    _stall=0
  else
    _stall=$((_stall + 1))
  fi
  echo "$_tail" | grep -q "DEPLOY_DONE" && return 0
  echo "$_tail" | grep -q "DEPLOY_FAILED" && return 1
  if [ "$_stall" -gt 90 ]; then
    echo "Deploy stalled (no log progress 15min). Check: ssh $SSH_HOST tail -f $LOG_REMOTE"
    return 1
  fi
  sleep 10
  done
}

print_final_status() {
  echo "=== Final status ==="
  ssh_run "sh -s" <<'STAT'
set -eu
echo -n "wan: "; ifstatus wan | jsonfilter -e '@.up' 2>/dev/null; ping -c1 -W3 1.1.1.1 >/dev/null && echo "ping OK" || echo "ping FAIL"
echo -n "awg1: "; ifstatus awg1 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null || echo "n/a"
ping -c1 -W3 -I awg1 1.1.1.1 >/dev/null 2>&1 && echo "awg ping OK" || echo "awg ping skip/fail"
test -f /var/run/pbr.nft && nft -c -f /var/run/pbr.nft 2>/dev/null && echo "pbr.nft: OK" || echo "pbr.nft: missing/bad"
_ru=$(grep -c ru_tld_dns_skip /var/run/pbr.nft 2>/dev/null || true); _ru=${_ru:-0}
_rd=$(grep -c ru_direct_skip /var/run/pbr.nft 2>/dev/null || true); _rd=${_rd:-0}
_lv=$(grep -c lan_via_vpn /var/run/pbr.nft 2>/dev/null || true); _lv=${_lv:-0}
echo "pbr.nft rules: ru_tld=$_ru ru_direct=$_rd lan_vpn=$_lv (expect 1 each)"
nft list set inet fw4 pbr_wan_4_dst_ip_user 2>/dev/null | grep -c '/' || echo "0 ipdeny"
STAT
}

# --- main ---
need_local_conf
preflight_local
echo "=== Backup $BACKUP_LABEL ==="
SSH_HOST="$SSH_HOST" "$SCRIPT_DIR/openwrt-backup.sh" "$BACKUP_LABEL"
preflight_local
start_remote_deploy
if poll_remote; then
  print_final_status
  echo ""
  echo "OK. Backup: openwrt-backups/$BACKUP_LABEL"
  echo "Log on router: $LOG_REMOTE"
  exit 0
fi
echo "FAILED. Restore: OPENWRT_RESTORE_YES=1 SSH_HOST=$SSH_HOST $SCRIPT_DIR/openwrt-restore.sh $BACKUP_LABEL"
print_final_status
exit 1
