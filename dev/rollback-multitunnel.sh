#!/bin/sh
# Emergency rollback for the multi-tunnel failover deploy/spike.
#
# Restores the EXACT pre-deploy state (pbr + awg1 + RU routing + wifi + the
# amnezia_block_quic rule) from a full sysupgrade backup, AND tears down the
# new multi-tunnel failover stack (classifier nft, ip rules, tables 100/101,
# amnezia-failover / amnezia-ru-load services, hotplug hook). Safe to run at
# any point during the guided spike — handles a partially-applied state.
#
# Usage:
#   SSH_HOST=openWRT ./dev/rollback-multitunnel.sh [backup-label] [--dry-run] [--no-reboot]
#   ROLLBACK_YES=1 SSH_HOST=openWRT ./dev/rollback-multitunnel.sh        # skip confirm
#
# Defaults to the backup taken before this deploy. Reboots by default (cleanest
# way to bring the restored pbr stack fully back); --no-reboot just restarts
# network/firewall/pbr instead.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SSH_HOST="${SSH_HOST:-router}"
BACKUP_ROOT="${BACKUP_ROOT:-$REPO_ROOT/openwrt-backups}"
DEFAULT_LABEL="before-multitunnel-deploy-20260615-1746"

DRYRUN=0
REBOOT=1
LABEL=""
for a in "$@"; do
  case "$a" in
    --dry-run)   DRYRUN=1 ;;
    --no-reboot) REBOOT=0 ;;
    --*)         echo "unknown option: $a" >&2; exit 2 ;;
    *)           LABEL="$a" ;;
  esac
done
LABEL="${LABEL:-$DEFAULT_LABEL}"
SRC="$BACKUP_ROOT/$LABEL"
TAR="$SRC/openwrt-sysupgrade-backup.tar.gz"

[ -f "$TAR" ] || { echo "FATAL: backup archive not found: $TAR" >&2; exit 1; }
tar tzf "$TAR" >/dev/null 2>&1 || { echo "FATAL: backup archive is corrupt: $TAR" >&2; exit 1; }

SSH_OPTS="-o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3"

echo "=== Rollback plan ==="
echo "  router:  $SSH_HOST"
echo "  backup:  $TAR"
echo "  reboot:  $([ "$REBOOT" = 1 ] && echo yes || echo 'no (restart services)')"
echo "  mode:    $([ "$DRYRUN" = 1 ] && echo DRY-RUN || echo LIVE)"

# Remote teardown + restore. Quoted heredoc: nothing expands locally; REBOOT is
# passed as $1 to the remote shell.
remote_script() {
cat <<'REMOTE_EOF'
set -u
REBOOT="${1:-1}"
log() { echo "[rollback] $*"; }

# 1) Stop + disable + remove the new failover-stack services.
for svc in amnezia-failover amnezia-ru-load; do
  if [ -x "/etc/init.d/$svc" ]; then
    "/etc/init.d/$svc" stop 2>/dev/null || true
    "/etc/init.d/$svc" disable 2>/dev/null || true
  fi
  rm -f "/etc/init.d/$svc" 2>/dev/null || true
  rm -f /etc/rc.d/*"$svc" 2>/dev/null || true
  log "service $svc stopped/disabled/removed"
done

# 2) Remove new-stack files that are NOT in the backup (sysupgrade -r only
#    adds/overwrites; it never deletes, so these must go explicitly).
rm -f /etc/nftables.d/30-amnezia-classify.nft \
      /etc/hotplug.d/firewall/99-amnezia-ru-load \
      /etc/iproute2/rt_tables.d/amnezia.conf \
      /var/run/amnezia-failover.json 2>/dev/null || true
log "new-stack files removed"

# 3) Tear down the new ip rules + routing tables (marks 0x0a0000 / 0x0b0000,
#    tables 100 / 101). Loop a few times in case of duplicates.
for _ in 1 2 3 4; do ip rule del fwmark 0x0a0000/0x0ff0000 2>/dev/null || true; done
for _ in 1 2 3 4; do ip rule del fwmark 0x0b0000/0x0ff0000 2>/dev/null || true; done
ip route flush table 100 2>/dev/null || true
ip route flush table 101 2>/dev/null || true
log "new ip rules + tables 100/101 flushed"

# 4) Restore the exact pre-deploy /etc from the full sysupgrade backup.
if sysupgrade -r /tmp/rollback-backup.tar.gz; then
  log "config restored from backup"
else
  log "WARN: sysupgrade -r returned nonzero"
fi

# 5) Ensure pbr is enabled again (it was, in the restored config).
/etc/init.d/pbr enable 2>/dev/null || true

# 6) Bring the restored stack back.
if [ "$REBOOT" = 1 ]; then
  log "rebooting in 2s to apply restored state"
  ( sleep 2 && reboot ) &
else
  log "restarting network/firewall/dnsmasq/pbr (no reboot)"
  ( sleep 1 && /etc/init.d/network restart && /etc/init.d/firewall restart \
    && { /etc/init.d/dnsmasq restart 2>/dev/null || true; } \
    && { /etc/init.d/pbr restart 2>/dev/null || true; } ) &
fi
log "rollback dispatched"
REMOTE_EOF
}

if [ "$DRYRUN" = 1 ]; then
  echo ""
  echo "=== DRY-RUN: remote script that WOULD run (REBOOT=$REBOOT) ==="
  remote_script
  echo "=== end (no upload, no execution) ==="
  exit 0
fi

if [ "${ROLLBACK_YES:-}" != 1 ]; then
  echo ""
  printf 'Restore router to pre-deploy state and %s? [y/N] ' \
    "$([ "$REBOOT" = 1 ] && echo reboot || echo 'restart services')"
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "aborted"; exit 0 ;; esac
fi

echo "Uploading backup archive to router..."
ssh $SSH_OPTS "$SSH_HOST" "cat > /tmp/rollback-backup.tar.gz" < "$TAR"
echo "Uploading rollback script to router..."
remote_script | ssh $SSH_OPTS "$SSH_HOST" "cat > /tmp/rollback-remote.sh"

echo "Executing rollback (detached so a reboot/SSH-drop can't half-finish it)..."
ssh $SSH_OPTS "$SSH_HOST" "( sh /tmp/rollback-remote.sh $REBOOT >/tmp/rollback.log 2>&1 ) & echo \"rollback started pid \$!\""

echo "Waiting for router to come back..."
sleep 12
n=0
while [ "$n" -lt 72 ]; do
  if ssh $SSH_OPTS "$SSH_HOST" true 2>/dev/null; then break; fi
  n=$((n + 1)); printf '  waiting for %s (%s/72)...\n' "$SSH_HOST" "$n"; sleep 5
done
if ! ssh $SSH_OPTS "$SSH_HOST" true 2>/dev/null; then
  echo "WARN: router not reachable yet. It may still be rebooting — re-check in a minute:"
  echo "  ssh $SSH_HOST 'cat /tmp/rollback.log; /etc/init.d/pbr enabled && echo pbr-on; ping -c1 1.1.1.1'"
  exit 1
fi

# On boot after the restore, pbr (enabled) starts before awg1 has completed a
# handshake, so it can't install its tunnel routes and sits idle until kicked.
# Wait for awg1 to be up with a recent handshake, then restart pbr so it
# (re)applies its policy routing -- otherwise LAN has no route until a manual
# `/etc/init.d/pbr restart`.
echo "Ensuring pbr is routing (it starts before awg1 is up on boot)..."
ssh $SSH_OPTS "$SSH_HOST" 'sh -s' <<'PBRFIX'
i=0
while [ "$i" -lt 24 ]; do
  hs=$(awg show awg1 latest-handshakes 2>/dev/null | awk '{print $2}')
  now=$(date +%s)
  [ "${hs:-0}" -gt 0 ] && [ $((now - hs)) -lt 180 ] && break
  i=$((i + 1)); sleep 5
done
/etc/init.d/pbr enabled 2>/dev/null || /etc/init.d/pbr enable 2>/dev/null
/etc/init.d/pbr restart 2>/dev/null || /etc/init.d/pbr start 2>/dev/null
sleep 3
echo "  pbr restarted (awg1 handshake age: $((now - ${hs:-0}))s)"
PBRFIX

echo "=== Post-rollback verification ==="
ssh $SSH_OPTS "$SSH_HOST" 'sh -s' <<'VERIFY'
echo -n "  pbr enabled:          "; /etc/init.d/pbr enabled 2>/dev/null && echo yes || echo "NO (!)"
echo -n "  pbr routing applied:  "; ip rule show 2>/dev/null | grep -q 'lookup pbr_' && echo yes || echo "NO -- run /etc/init.d/pbr restart (!)"
echo -n "  awg1 up:              "; ifstatus awg1 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null || echo "n/a"
echo -n "  wan ping:             "; ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 && echo OK || echo "FAIL (!)"
echo -n "  classifier removed:   "; [ -f /etc/nftables.d/30-amnezia-classify.nft ] && echo "STILL PRESENT (!)" || echo yes
echo -n "  failover svc removed: "; [ -x /etc/init.d/amnezia-failover ] && echo "STILL PRESENT (!)" || echo yes
echo -n "  new ip rules gone:    "; ip rule show 2>/dev/null | grep -q '0x0a0000\|0x0b0000' && echo "STILL PRESENT (!)" || echo yes
echo -n "  QUIC rule restored:   "; uci -q get firewall.amnezia_block_quic >/dev/null 2>&1 && echo present || echo "absent (!)"
VERIFY
echo ""
echo "Rollback complete. If LAN clients still lack net: renew DHCP / reconnect Wi-Fi."
