#!/bin/sh
# Backup OpenWrt UCI + packages for rollback (no factory reset needed).
# Usage: ./openwrt-backup.sh [label]
# Example: ./openwrt-backup.sh clean-after-reset
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Script lives under dev/; backups land at repo root in openwrt-backups/.
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SSH_HOST="${SSH_HOST:-router}"
LABEL="${1:-$(date +%Y%m%d-%H%M%S)}"
BACKUP_ROOT="${BACKUP_ROOT:-$REPO_ROOT/openwrt-backups}"
DEST="$BACKUP_ROOT/$LABEL"

mkdir -p "$DEST"

echo "Backing up $SSH_HOST -> $DEST"

TAR_PATH="$(ssh "$SSH_HOST" "sh -s" "$LABEL" <<'REMOTE'
set -eu
LABEL="$1"
STAMP="/tmp/openwrt-backup-bundle"
rm -rf "$STAMP"
mkdir -p "$STAMP/config" "$STAMP/meta"

. /etc/openwrt_release 2>/dev/null || true
{
  echo "DISTRIB_RELEASE=${DISTRIB_RELEASE:-unknown}"
  echo "DISTRIB_REVISION=${DISTRIB_REVISION:-unknown}"
  echo "DISTRIB_TARGET=${DISTRIB_TARGET:-unknown}"
  echo "DISTRIB_ARCH=${DISTRIB_ARCH:-unknown}"
  echo "BACKUP_LABEL=$LABEL"
  date -Iseconds 2>/dev/null || date
} > "$STAMP/meta/release.txt"

for f in network firewall dhcp wireless system uhttpd dropbear pbr podkop; do
  [ -f "/etc/config/$f" ] && cp "/etc/config/$f" "$STAMP/config/" || true
done

opkg list-installed > "$STAMP/meta/opkg-installed.txt" 2>/dev/null || true
ip route > "$STAMP/meta/ip-route.txt" 2>/dev/null || true
ip rule > "$STAMP/meta/ip-rule.txt" 2>/dev/null || true
uci export > "$STAMP/meta/uci-export.txt" 2>/dev/null || true
sysupgrade -b "$STAMP/openwrt-sysupgrade-backup.tar.gz" 2>/dev/null || true

OUT="/tmp/openwrt-backup-${LABEL}.tar.gz"
tar czf "$OUT" -C "$STAMP" .
echo "$OUT"
REMOTE
)"

TAR_PATH="$(echo "$TAR_PATH" | tail -1)"
ssh "$SSH_HOST" "cat '$TAR_PATH'" > "$DEST/openwrt-backup.tar.gz"
ssh "$SSH_HOST" "rm -f '$TAR_PATH'" 2>/dev/null || true

tar xzf "$DEST/openwrt-backup.tar.gz" -C "$DEST"
rm -f "$DEST/openwrt-backup.tar.gz"

cat > "$DEST/README.txt" <<EOF
OpenWrt backup: $LABEL
Created: $(date)
Host: $SSH_HOST

Restore without factory reset:
  $SCRIPT_DIR/openwrt-restore.sh $LABEL

UCI only (keep installed packages):
  $SCRIPT_DIR/openwrt-restore.sh $LABEL --uci-only

Emergency if internet dies:
  $SCRIPT_DIR/openwrt-emergency-internet.sh
EOF

echo "OK: $DEST"
ls -la "$DEST"
