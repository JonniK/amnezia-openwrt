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
BLOCKCHECK_SRC="${BLOCKCHECK_SRC:-/tmp/zapret-blockcheck.sh}"
APPLY_SRC="${APPLY_SRC:-/tmp/zapret-apply.sh}"
PROBE_SRC="${PROBE_SRC:-/tmp/zapret-probe.sh}"
VERIFY_SRC="${VERIFY_SRC:-/tmp/zapret-verify.sh}"
SEED_SRC="${SEED_SRC:-/tmp/seed-must-tunnel.list}"
TOGGLE_DST=/usr/bin/zapret-toggle
STATUS_DST=/usr/bin/zapret-status
BLOCKCHECK_DST=/usr/bin/zapret-blockcheck
APPLY_DST=/usr/bin/zapret-apply
PROBE_DST=/usr/bin/zapret-probe
VERIFY_DST=/usr/bin/zapret-verify
SEED_DST=/etc/amnezia/seed-must-tunnel.list

# One-shot migration: pre-rename installs kept state under /etc/awg/ (private
# repo era). The package now namespaces everything under /etc/amnezia/ so it
# doesn't collide with vanilla awg-tools on a shared system. Move stamps and
# backups across once; subsequent runs find /etc/amnezia/ already populated
# and the conditional is a no-op. Old dir is removed only if empty so any
# hand-placed file the user kept there survives.
if [ -d /etc/awg ] && [ ! -d /etc/amnezia ]; then
	echo "install-zapret: migrating /etc/awg -> /etc/amnezia"
	mkdir -p /etc/amnezia
	# `cp -a + rm` is safer than `mv` across overlay fs boundaries on OpenWrt.
	cp -a /etc/awg/. /etc/amnezia/ 2>/dev/null || true
	rm -rf /etc/awg 2>/dev/null || rmdir /etc/awg 2>/dev/null || true
fi

# When this script is invoked via the install.sh / dev/deploy path, the
# wrapper sources are pre-staged at /tmp/. When invoked via the .ipk path
# (find_helper -> /usr/sbin/install-zapret), the wrappers are already
# placed in /usr/bin/ by the amnezia-pbr.ipk install. Detect which case
# we're in by checking for any one staged source; if none are present we
# skip the cp section entirely and only handle the upstream-zapret install
# + best-effort dep installs.
STAGED=0
if [ -f "$TOGGLE_SRC" ] && [ -f "$STATUS_SRC" ] && [ -f "$BLOCKCHECK_SRC" ] && \
   [ -f "$APPLY_SRC" ] && [ -f "$PROBE_SRC" ] && [ -f "$VERIFY_SRC" ] && \
   [ -f "$SEED_SRC" ]; then
	STAGED=1
elif [ -f "$TOGGLE_SRC" ] || [ -f "$STATUS_SRC" ] || [ -f "$BLOCKCHECK_SRC" ] || \
     [ -f "$APPLY_SRC" ] || [ -f "$PROBE_SRC" ] || [ -f "$VERIFY_SRC" ] || \
     [ -f "$SEED_SRC" ]; then
	# Partial staging is almost certainly a deploy bug, not the .ipk case.
	# Fail loudly so we don't silently leave an inconsistent install.
	echo "install-zapret: partial source staging at /tmp/ -- aborting"
	exit 1
fi

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
	# stdbuf is used by zapret-blockcheck to line-buffer curl output so the
	# LuCI log tail updates live instead of in 4 KiB bursts. Non-fatal.
	if ! command -v stdbuf >/dev/null 2>&1; then
		echo "install-zapret: opkg install coreutils-stdbuf (best-effort)"
		opkg install coreutils-stdbuf >/dev/null 2>&1 || \
			echo "install-zapret: coreutils-stdbuf install failed; blockcheck log will buffer"
	fi
	# blockcheck.sh needs a "real" nc (busybox nc doesn't support its flags) to
	# run port-block tests (raw TCP SYN to :443 without HTTP). Without it the
	# port-block phase prints "suitable netcat not found" and silently skips,
	# so we lose the L4-vs-L7 distinction in the results. Best-effort.
	if ! opkg list-installed 2>/dev/null | grep -qE '^(nmap-ncat|ncat-full|netcat-openbsd) '; then
		echo "install-zapret: opkg install nmap-ncat (best-effort)"
		opkg install nmap-ncat >/dev/null 2>&1 || \
			echo "install-zapret: nmap-ncat install failed; blockcheck port-block tests will be skipped"
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

# (Re)place wrappers only when we have staged sources -- the .ipk path
# (STAGED=0) gets these files directly from the amnezia-pbr package, so
# this loop would clobber freshly-installed binaries with files that don't
# even exist.
if [ "$STAGED" -eq 1 ]; then
	cp "$TOGGLE_SRC"     "$TOGGLE_DST"
	cp "$STATUS_SRC"     "$STATUS_DST"
	cp "$BLOCKCHECK_SRC" "$BLOCKCHECK_DST"
	cp "$APPLY_SRC"      "$APPLY_DST"
	cp "$PROBE_SRC"      "$PROBE_DST"
	cp "$VERIFY_SRC"     "$VERIFY_DST"
	chmod 0755 "$TOGGLE_DST" "$STATUS_DST" "$BLOCKCHECK_DST" "$APPLY_DST" "$PROBE_DST" "$VERIFY_DST"
	# Reference seed list -- read-only data, lives under /etc/amnezia next to ru.cidr.
	mkdir -p "$(dirname "$SEED_DST")"
	cp "$SEED_SRC"       "$SEED_DST"
	chmod 0644 "$SEED_DST"

	echo "install-zapret: wrappers placed:"
	echo "  $TOGGLE_DST"
	echo "  $STATUS_DST"
	echo "  $BLOCKCHECK_DST"
	echo "  $APPLY_DST"
	echo "  $PROBE_DST"
	echo "  $VERIFY_DST"
	echo "  $SEED_DST"
else
	echo "install-zapret: wrappers already in place (running under .ipk install)"
fi

if /etc/init.d/zapret enabled 2>/dev/null; then
	echo "install-zapret: zapret service is ENABLED"
else
	echo "install-zapret: zapret service is DISABLED (use LuCI toggle to start)"
fi
