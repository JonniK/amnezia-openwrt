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
	"$PBR_PKG/etc/amnezia" \
	"$PBR_PKG/etc/config" \
	"$PBR_PKG/etc/pbr.d" \
	"$PBR_PKG/etc/uci-defaults" \
	"$LUCI_PKG/usr/share/luci/menu.d" \
	"$LUCI_PKG/usr/share/rpcd/acl.d" \
	"$LUCI_PKG/www/luci-static/resources/view/amnezia"

# -- amnezia-pbr -------------------------------------------------------------
# Runtime CLI wrappers go to /usr/bin/ (no .sh -- OpenWrt convention).
for src in \
	awg-toggle.sh awg-ru-update.sh \
	pbr-status.sh pbr-reload.sh \
	zapret-toggle.sh zapret-status.sh zapret-blockcheck.sh \
	zapret-apply.sh zapret-probe.sh zapret-verify.sh
do
	cp "$SRC/$src" "$PBR_PKG/usr/bin/${src%.sh}"
	chmod 0755 "$PBR_PKG/usr/bin/${src%.sh}"
done

# /usr/sbin/ holds admin tools the first-run setup uses internally. These
# are PATH-resolvable so install-amnezia-pbr.sh's find_helper() picks them
# up automatically when /tmp/install-*.sh isn't there (the .ipk path).
cp "$SRC/install-amnezia-pbr.sh"           "$PBR_PKG/usr/sbin/amnezia-pbr-setup"
cp "$SRC/install-zapret.sh"                "$PBR_PKG/usr/sbin/install-zapret"
cp "$SRC/install-dnsmasq-full.sh"          "$PBR_PKG/usr/sbin/install-dnsmasq-full"
cp "$SRC/configure-dnsmasq-ru-nftset.sh"   "$PBR_PKG/usr/sbin/configure-dnsmasq-ru-nftset"
chmod 0755 \
	"$PBR_PKG/usr/sbin/amnezia-pbr-setup" \
	"$PBR_PKG/usr/sbin/install-zapret" \
	"$PBR_PKG/usr/sbin/install-dnsmasq-full" \
	"$PBR_PKG/usr/sbin/configure-dnsmasq-ru-nftset"

# Reference data and PBR includes.
cp "$SRC/seed-must-tunnel.list"   "$PBR_PKG/etc/amnezia/seed-must-tunnel.list"
cp "$SRC/config/amnezia"          "$PBR_PKG/etc/config/amnezia"
cp "$SRC/pbr.d/ru-direct.sh"      "$PBR_PKG/etc/pbr.d/ru-direct.sh"
cp "$SRC/pbr.d/99-lan-vpn-full.sh"     "$PBR_PKG/etc/pbr.d/99-lan-vpn-full.sh.template"
cp "$SRC/pbr.d/99-lan-vpn-vpn-only.sh" "$PBR_PKG/etc/pbr.d/99-lan-vpn-vpn-only.sh.template"
chmod 0755 "$PBR_PKG/etc/pbr.d/ru-direct.sh"

# uci-defaults: runs once after package install to populate UCI from the
# shipped /etc/config/amnezia template + record the install timestamp.
# Convention: numeric prefix sets ordering relative to other packages.
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
