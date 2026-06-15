#!/bin/sh
# sync-to-packages: regenerate packages/<pkg>/files/ from openwrt/.
#
# `openwrt/` is the canonical source of truth for editing -- it's what the
# install.sh and deploy paths consume. `packages/<pkg>/files/` is what the
# OpenWrt SDK reads when building the .ipk's, and OpenWrt convention places
# files at their target install paths (no .sh extension on /usr/bin/ binaries,
# nested dir structure under files/).
#
# This script does the (one-way) copy and naming translation so the two stay
# in sync. CI runs it and refuses to publish if the resulting diff is
# non-empty -- forcing any edit to openwrt/ to be accompanied by a regen of
# the package tree in the same commit.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/openwrt"
PBR_PKG="$ROOT/packages/amnezia-pbr/files"
LUCI_PKG="$ROOT/packages/luci-app-amnezia/files"

# Wipe and recreate so a removed source file disappears from the package tree
# too. Anything outside files/ (Makefile, etc.) is preserved.
rm -rf "$PBR_PKG" "$LUCI_PKG"
mkdir -p \
	"$PBR_PKG/usr/bin" \
	"$PBR_PKG/usr/sbin" \
	"$PBR_PKG/usr/lib/amnezia" \
	"$PBR_PKG/etc/amnezia" \
	"$PBR_PKG/etc/config" \
	"$PBR_PKG/etc/nftables.d" \
	"$PBR_PKG/etc/iproute2/rt_tables.d" \
	"$PBR_PKG/etc/init.d" \
	"$PBR_PKG/etc/uci-defaults" \
	"$LUCI_PKG/usr/share/luci/menu.d" \
	"$LUCI_PKG/usr/share/rpcd/acl.d" \
	"$LUCI_PKG/www/luci-static/resources/view/amnezia"

# -- amnezia-pbr -------------------------------------------------------------
# Runtime CLI wrappers go to /usr/bin/ (no .sh -- OpenWrt convention).
for src in \
	awg-toggle.sh awg-ru-update.sh \
	zapret-toggle.sh zapret-status.sh zapret-blockcheck.sh \
	zapret-apply.sh zapret-probe.sh zapret-verify.sh \
	amnezia-ru-cidr.sh amnezia-status.sh amnezia-failover-ctl.sh
do
	cp "$SRC/$src" "$PBR_PKG/usr/bin/${src%.sh}"
	chmod 0755 "$PBR_PKG/usr/bin/${src%.sh}"
done

# /usr/sbin/ holds admin tools the first-run setup uses internally.
cp "$SRC/install-amnezia-pbr.sh"           "$PBR_PKG/usr/sbin/amnezia-pbr-setup"
cp "$SRC/install-zapret.sh"                "$PBR_PKG/usr/sbin/install-zapret"
cp "$SRC/install-dnsmasq-full.sh"          "$PBR_PKG/usr/sbin/install-dnsmasq-full"
cp "$SRC/configure-dnsmasq-ru-nftset.sh"   "$PBR_PKG/usr/sbin/configure-dnsmasq-ru-nftset"
cp "$SRC/configure-dnsmasq-amnezia.sh"     "$PBR_PKG/usr/sbin/configure-dnsmasq-amnezia"
cp "$SRC/amnezia-failover"                 "$PBR_PKG/usr/sbin/amnezia-failover"
chmod 0755 \
	"$PBR_PKG/usr/sbin/amnezia-pbr-setup" \
	"$PBR_PKG/usr/sbin/install-zapret" \
	"$PBR_PKG/usr/sbin/install-dnsmasq-full" \
	"$PBR_PKG/usr/sbin/configure-dnsmasq-ru-nftset" \
	"$PBR_PKG/usr/sbin/configure-dnsmasq-amnezia" \
	"$PBR_PKG/usr/sbin/amnezia-failover"

# Shared library: amnezia-common.sh and amnezia-routing.sh
cp "$SRC/lib/amnezia-common.sh"   "$PBR_PKG/usr/lib/amnezia/amnezia-common.sh"
cp "$SRC/lib/amnezia-routing.sh"  "$PBR_PKG/usr/lib/amnezia/amnezia-routing.sh"
chmod 0644 \
	"$PBR_PKG/usr/lib/amnezia/amnezia-common.sh" \
	"$PBR_PKG/usr/lib/amnezia/amnezia-routing.sh"

# nftables classifier
cp "$SRC/nftables.d/30-amnezia-classify.nft" \
   "$PBR_PKG/etc/nftables.d/30-amnezia-classify.nft"
chmod 0644 "$PBR_PKG/etc/nftables.d/30-amnezia-classify.nft"

# iproute2 routing tables
cp "$SRC/iproute2-amnezia-rt_tables.conf" \
   "$PBR_PKG/etc/iproute2/rt_tables.d/amnezia.conf"
chmod 0644 "$PBR_PKG/etc/iproute2/rt_tables.d/amnezia.conf"

# procd init script
cp "$SRC/amnezia-failover.init" "$PBR_PKG/etc/init.d/amnezia-failover"
chmod 0755 "$PBR_PKG/etc/init.d/amnezia-failover"

# Reference data and config.
cp "$SRC/seed-must-tunnel.list"    "$PBR_PKG/etc/amnezia/seed-must-tunnel.list"
cp "$SRC/seed-sticky-domains.list" "$PBR_PKG/etc/amnezia/seed-sticky-domains.list"
cp "$SRC/config/amnezia"           "$PBR_PKG/etc/config/amnezia"
chmod 0644 \
	"$PBR_PKG/etc/amnezia/seed-must-tunnel.list" \
	"$PBR_PKG/etc/amnezia/seed-sticky-domains.list" \
	"$PBR_PKG/etc/config/amnezia"

# uci-defaults: runs once after package install to populate UCI from the
# shipped /etc/config/amnezia template + record the install timestamp.
cat > "$PBR_PKG/etc/uci-defaults/90-amnezia-pbr" <<'UCIDEF'
#!/bin/sh
# uci-defaults: stamp the install timestamp. /etc/config/amnezia ships as the
# package conffile so opkg preserves user edits across upgrades; we only
# touch the install metadata here.
uci -q set amnezia.config.installed_ts="$(date +%s)" || exit 0
uci -q commit amnezia
exit 0
UCIDEF
chmod 0755 "$PBR_PKG/etc/uci-defaults/90-amnezia-pbr"

# -- luci-app-amnezia --------------------------------------------------------
cp "$SRC/luci-app-amnezia/menu/luci-app-amnezia.json" \
   "$LUCI_PKG/usr/share/luci/menu.d/luci-app-amnezia.json"
cp "$SRC/luci-app-amnezia/acl/luci-app-amnezia.json" \
   "$LUCI_PKG/usr/share/rpcd/acl.d/luci-app-amnezia.json"
cp "$SRC/luci-app-amnezia/view/main.js" \
   "$LUCI_PKG/www/luci-static/resources/view/amnezia/main.js"
chmod 0644 \
	"$LUCI_PKG/usr/share/luci/menu.d/luci-app-amnezia.json" \
	"$LUCI_PKG/usr/share/rpcd/acl.d/luci-app-amnezia.json" \
	"$LUCI_PKG/www/luci-static/resources/view/amnezia/main.js"

# Sanity report.
PBR_COUNT=$(find "$PBR_PKG" -type f | wc -l | tr -d ' ')
LUCI_COUNT=$(find "$LUCI_PKG" -type f | wc -l | tr -d ' ')
echo "sync-to-packages: amnezia-pbr=$PBR_COUNT files, luci-app-amnezia=$LUCI_COUNT files"
