#!/bin/sh
# Restore OpenWrt from openwrt-backup.sh snapshot.
# Usage: ./openwrt-restore.sh <label> [--uci-only]
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Script lives under dev/; backups land at repo root in openwrt-backups/.
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SSH_HOST="${SSH_HOST:-router}"
BACKUP_ROOT="${BACKUP_ROOT:-$REPO_ROOT/openwrt-backups}"
LABEL="${1:?Usage: $0 <backup-label> [--uci-only]}"
UCI_ONLY=0
[ "${2:-}" = "--uci-only" ] && UCI_ONLY=1

SRC="$BACKUP_ROOT/$LABEL"
[ -d "$SRC/config" ] || { echo "Missing backup: $SRC"; exit 1; }

echo "Restoring $SSH_HOST from $SRC (uci_only=$UCI_ONLY)"
echo "Current backup meta:"
cat "$SRC/meta/release.txt" 2>/dev/null || true
if [ "${OPENWRT_RESTORE_YES:-}" != "1" ]; then
  echo ""
  read -r -p "Continue? [y/N] " ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac
fi

# Upload bundle
tar czf - -C "$SRC" . | ssh "$SSH_HOST" "cat > /tmp/openwrt-restore.tar.gz"

ssh "$SSH_HOST" "sh -s" "$UCI_ONLY" <<'REMOTE'
set -eu
UCI_ONLY="$1"
cd /tmp
rm -rf openwrt-restore
mkdir openwrt-restore
tar xzf openwrt-restore.tar.gz -C openwrt-restore

# Safety snapshot before restore
sysupgrade -b /tmp/pre-restore-sysupgrade.tar.gz 2>/dev/null || true

for f in network firewall dhcp wireless system uhttpd dropbear pbr podkop; do
  if [ -f "openwrt-restore/config/$f" ]; then
    cp "openwrt-restore/config/$f" "/etc/config/$f"
  else
    # Remove broken VPN configs if not in backup
    case "$f" in pbr|podkop) uci -q delete "$f" 2>/dev/null && uci commit "$f" 2>/dev/null || rm -f "/etc/config/$f" ;; esac
  fi
done

uci commit network
uci commit firewall
uci commit dhcp
uci commit wireless 2>/dev/null || true

# Stop VPN/PBR services if present
/etc/init.d/pbr stop 2>/dev/null || true
/etc/init.d/pbr disable 2>/dev/null || true
/etc/init.d/podkop stop 2>/dev/null || true
ifdown awg1 2>/dev/null || true
ifdown awg 2>/dev/null || true
uci -q delete network.awg1 2>/dev/null || true
uci -q delete network.awg 2>/dev/null || true
while uci -q delete network.@amneziawg_awg1[0]; do :; done
while uci -q delete network.@amneziawg_awg[0]; do :; done
uci commit network 2>/dev/null || true

rm -rf /etc/pbr.d 2>/dev/null || true
nft delete table inet pbr 2>/dev/null || true

if [ "$UCI_ONLY" = "0" ] && [ -f openwrt-restore/meta/opkg-installed.txt ]; then
  echo "Package restore hint: diff opkg lists manually if needed."
fi

/etc/init.d/network restart
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart 2>/dev/null || true

sleep 3
echo "=== after restore ==="
ip route
ping -c 2 -W 3 1.1.1.1 || true
ifstatus wan | jsonfilter -e '@.up' 2>/dev/null || ifstatus wan | head -5
REMOTE

echo "Restore finished. If LAN clients still have no net: renew DHCP on devices or reboot router."
