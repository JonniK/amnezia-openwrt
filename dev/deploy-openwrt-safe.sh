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
# Script lives under dev/; repo content (openwrt/, local/) is one level up.
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SSH_HOST="${SSH_HOST:-router}"
CONF_LOCAL="${CONF_LOCAL:-$REPO_ROOT/local/awg.conf}"
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
  echo "=== Upload installer + AWG config + payload ==="
  # Flat scripts and configs land directly in /tmp/ via basename. The
  # installer (install-amnezia-pbr.sh) reads them from there.
  for _f in openwrt/pbr.d/ru-direct.sh openwrt/pbr.d/99-lan-vpn-full.sh openwrt/pbr.d/99-lan-vpn-vpn-only.sh openwrt/install-dnsmasq-full.sh openwrt/configure-dnsmasq-ru-nftset.sh openwrt/awg-toggle.sh openwrt/pbr-status.sh openwrt/pbr-reload.sh openwrt/install-luci-toggle.sh openwrt/zapret-toggle.sh openwrt/zapret-status.sh openwrt/zapret-blockcheck.sh openwrt/zapret-apply.sh openwrt/zapret-probe.sh openwrt/zapret-verify.sh openwrt/seed-must-tunnel.list openwrt/install-zapret.sh openwrt/install-luci-app-amnezia.sh openwrt/install-amnezia-pbr.sh openwrt/amnezia-app-ctl.sh; do
    cat "$REPO_ROOT/$_f" | ssh_run "cat > /tmp/$(basename "$_f")"
  done
  # UCI scaffold has a slash-free filename (`amnezia`), so basename loop
  # would clobber any unrelated /tmp/amnezia file the user might have.
  # Upload as /tmp/amnezia.config to be explicit; installer copies from there.
  cat "$REPO_ROOT/openwrt/config/amnezia" | ssh_run "cat > /tmp/amnezia.config"
  # LuCI app is a directory tree (menu/acl/view subdirs). Flat /tmp/ basename
  # upload above won't preserve that, so push each file into the explicit
  # nested path the installer reads from. Kept separate to keep the main
  # loop terse.
  ssh_run "mkdir -p /tmp/luci-app-amnezia/menu /tmp/luci-app-amnezia/acl /tmp/luci-app-amnezia/view /tmp/luci-app-amnezia/amnezia/section"
  # Push menu, acl, and amnezia resource modules first; main.js LAST so
  # on-device require() resolves modules before the entry point is loaded.
  for _f in openwrt/luci-app-amnezia/menu/luci-app-amnezia.json \
            openwrt/luci-app-amnezia/acl/luci-app-amnezia.json \
            openwrt/luci-app-amnezia/amnezia/util.js \
            openwrt/luci-app-amnezia/amnezia/section/failover.js \
            openwrt/luci-app-amnezia/amnezia/section/routing.js \
            openwrt/luci-app-amnezia/amnezia/section/zapret.js \
            openwrt/luci-app-amnezia/amnezia/section/dns.js \
            openwrt/luci-app-amnezia/view/main.js; do
    _rel=${_f#openwrt/luci-app-amnezia/}
    cat "$REPO_ROOT/$_f" | ssh_run "cat > /tmp/luci-app-amnezia/$_rel"
  done
  ssh_run "chmod +x /tmp/install-amnezia-pbr.sh"
  ssh_run "cat > /tmp/awg-setup.conf" <"$CONF_LOCAL"
  # Detach the installer from this SSH session so a dropped connection
  # doesn't kill the run mid-step. The log file is the source of truth;
  # poll_remote tails it from a fresh SSH each iteration.
  ssh_run "STEPS=$STEPS LOG=$LOG_REMOTE sh -s" <<'REMOTE_WRAPPER'
set -eu
LOG="${LOG:-/tmp/openwrt-deploy.log}"
STEPS="${STEPS:-3}"
: > "$LOG"
(
  exec env STEPS="$STEPS" LOG="$LOG" sh /tmp/install-amnezia-pbr.sh
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
