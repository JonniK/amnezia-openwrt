#!/bin/sh
# install-zapret: install the upstream bol-van zapret package from the
# remittor/zapret-openwrt release for aarch64_cortex-a53 (OpenWrt 24.10),
# then place /usr/bin/zapret-toggle and /usr/bin/zapret-status wrappers.
#
# On FIRST install the service is left DISABLED (user enables via the LuCI button).
# On re-runs the current enabled/disabled state is preserved -- re-deploying the
# router shouldn't silently flip zapret off if the user had turned it on.
# Existing /opt/zapret/config is preserved on re-install (opkg conffile rules).
#
# Expects:
#   /tmp/zapret-toggle.sh   uploaded by deploy script
#   /tmp/zapret-status.sh   uploaded by deploy script
set -eu

ZAPRET_VERSION="v72.20260307"
ZAPRET_IPK_NAME="zapret_72.20260307-r1_aarch64_cortex-a53.ipk"
# Release filename keeps the leading 'v' in the version (zapret_vXX...zip).
ZAPRET_ZIP_URL="https://github.com/remittor/zapret-openwrt/releases/download/${ZAPRET_VERSION}/zapret_${ZAPRET_VERSION}_aarch64_cortex-a53.zip"
ZAPRET_ZIP_SHA256="fda00483a87071555e4bf3ae40ee815ee6c7f6a386f2860b646ce7e9347572dd"

TOGGLE_SRC="${TOGGLE_SRC:-/tmp/zapret-toggle.sh}"
STATUS_SRC="${STATUS_SRC:-/tmp/zapret-status.sh}"
TOGGLE_DST=/usr/bin/zapret-toggle
STATUS_DST=/usr/bin/zapret-status

[ -f "$TOGGLE_SRC" ] || { echo "missing $TOGGLE_SRC"; exit 1; }
[ -f "$STATUS_SRC" ] || { echo "missing $STATUS_SRC"; exit 1; }

if opkg list-installed 2>/dev/null | grep -q '^zapret '; then
	echo "install-zapret: zapret already installed, skipping package install"
else
	echo "install-zapret: downloading zapret ${ZAPRET_VERSION}"
	WORK=/tmp/zapret-install.$$
	mkdir -p "$WORK"
	trap 'rm -rf "$WORK"' EXIT

	if ! wget -q -T 30 -O "$WORK/zapret.zip" "$ZAPRET_ZIP_URL"; then
		echo "install-zapret: download failed from $ZAPRET_ZIP_URL"
		exit 1
	fi

	got=$(sha256sum "$WORK/zapret.zip" | awk '{print $1}')
	if [ "$got" != "$ZAPRET_ZIP_SHA256" ]; then
		echo "install-zapret: SHA256 mismatch"
		echo "  expected: $ZAPRET_ZIP_SHA256"
		echo "  got:      $got"
		exit 1
	fi

	# Need unzip to extract the ipk; not always present on stock OpenWrt.
	if ! command -v unzip >/dev/null 2>&1; then
		echo "install-zapret: opkg install unzip"
		opkg update >/dev/null 2>&1 || true
		opkg install unzip >/dev/null 2>&1 || { echo "install-zapret: failed to install unzip"; exit 1; }
	fi

	# Extract only the cortex-a53 ipk we need; ignore the .apk and luci-app.
	( cd "$WORK" && unzip -q -o zapret.zip "$ZAPRET_IPK_NAME" )
	[ -f "$WORK/$ZAPRET_IPK_NAME" ] || { echo "install-zapret: ipk missing after unzip"; exit 1; }

	echo "install-zapret: opkg update + install zapret"
	opkg update >/dev/null 2>&1 || true
	if ! opkg install "$WORK/$ZAPRET_IPK_NAME"; then
		echo "install-zapret: opkg install failed"
		exit 1
	fi

	# Fresh install -> ensure service starts disabled (we control it via toggle).
	/etc/init.d/zapret stop    >/dev/null 2>&1 || true
	/etc/init.d/zapret disable >/dev/null 2>&1 || true
fi

# Always (re)place wrappers.
cp "$TOGGLE_SRC" "$TOGGLE_DST"
cp "$STATUS_SRC" "$STATUS_DST"
chmod 0755 "$TOGGLE_DST" "$STATUS_DST"

echo "install-zapret: wrappers placed:"
echo "  $TOGGLE_DST"
echo "  $STATUS_DST"

if /etc/init.d/zapret enabled 2>/dev/null; then
	echo "install-zapret: zapret service is ENABLED"
else
	echo "install-zapret: zapret service is DISABLED (use LuCI toggle to start)"
fi
