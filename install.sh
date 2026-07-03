#!/bin/sh
# install.sh -- bootstrap amnezia-pbr-openwrt on an OpenWrt router.
#
# Run this ON THE ROUTER (not from a workstation):
#
#   wget -O - https://raw.githubusercontent.com/JonniK/amnezia-openwrt/main/install.sh | sh
#
# Or, if you've already cloned/copied the repo to /tmp/, just:
#
#   sh install.sh
#
# Required: place your Amnezia-exported .conf at /etc/amnezia/awg.conf
# (or point AWG_CONF at it) BEFORE running. The installer needs the
# AmneziaWG keys and obfuscation params; it has no other way to get them.
#
# Env overrides:
#   STEPS=1|2|3       install depth: 1=AWG only, 2=+PBR, 3=full (default)
#   AWG_CONF=<path>   where to read AWG keys/params from (default
#                     /etc/amnezia/awg.conf; falls back to /tmp/awg.conf
#                     and ./awg.conf if neither exists yet)
#   REPO_REF=<ref>    branch/tag to install from (default: main)
#   AWG_VER=<ver>     pin a specific Slava-Shchipunov AWG package release
#
# Idempotent: re-run safely after fixing config or upgrading.
set -eu

REPO_OWNER=JonniK
REPO_NAME=amnezia-openwrt
REPO_REF="${REPO_REF:-main}"
STEPS="${STEPS:-3}"

WORK=/tmp/amnezia-install
LOG=/tmp/openwrt-deploy.log
ARCHIVE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/${REPO_REF}.tar.gz"

err()  { echo "install: $*" >&2; }
fail() { err "$*"; exit 1; }

# --- Preflight ---
[ "$(id -u)" -eq 0 ] || fail "must run as root"
[ -r /etc/openwrt_release ] || fail "not OpenWrt? (no /etc/openwrt_release)"
. /etc/openwrt_release
case "$DISTRIB_RELEASE" in
	24.*|SNAPSHOT) ;;
	*) err "WARN: tested only on OpenWrt 24.10+; you have $DISTRIB_RELEASE -- continuing anyway" ;;
esac

# Resolve AWG config: env > /etc/amnezia/ > /tmp/ > cwd. The installer
# itself (install-amnezia-pbr.sh) wants /tmp/awg-setup.conf, so we copy
# whichever source we found there.
AWG_CONF="${AWG_CONF:-}"
if [ -z "$AWG_CONF" ]; then
	for _c in /etc/amnezia/awg.conf /tmp/awg.conf ./awg.conf; do
		[ -f "$_c" ] && { AWG_CONF=$_c; break; }
	done
fi
if [ -z "$AWG_CONF" ] || [ ! -f "$AWG_CONF" ]; then
	cat <<EOF >&2
install: AmneziaWG config not found.

This installer needs your Amnezia-exported .conf file (the one with the
extra Jc/Jmin/Jmax/S*/H*/I* lines under [Interface]). Get it from the
Amnezia desktop client: Settings -> Connection -> Export config.

Then either:
  1. Save it to /etc/amnezia/awg.conf and re-run, or
  2. AWG_CONF=/path/to/your.conf sh install.sh

Without this, the installer cannot configure the tunnel.
EOF
	exit 2
fi

# --- Download payload ---
mkdir -p "$WORK"
cd "$WORK"
echo "install: downloading $ARCHIVE_URL"
rm -rf payload payload.tar.gz
wget -q -O payload.tar.gz "$ARCHIVE_URL" || fail "download failed"
mkdir payload
tar xzf payload.tar.gz -C payload --strip-components=1 || fail "extract failed"
[ -d payload/openwrt ] || fail "extracted tree missing openwrt/ subdir (wrong ref?)"

# --- Stage files where install-amnezia-pbr.sh expects them ---
echo "install: staging payload to /tmp/"
SRC=payload/openwrt

# Flat scripts, inits, and hotplugs: stage all via globs so newly-added helpers
# are included automatically without updating this list.  The guard
# `[ -f "$_f" ] || continue` silently skips an unmatched glob pattern.
for _f in "$SRC"/*.sh "$SRC"/*.init "$SRC"/*.hotplug; do
	[ -f "$_f" ] || continue
	_bn=$(basename "$_f")
	cp "$_f" "/tmp/$_bn" || err "WARN: $_bn staging failed; some functionality may degrade"
done
chmod +x /tmp/install-amnezia-pbr.sh

# Extensionless daemon binary (not caught by *.sh glob — stage explicitly).
if [ -f "$SRC/amnezia-failover" ]; then
	cp "$SRC/amnezia-failover" /tmp/amnezia-failover
	chmod +x /tmp/amnezia-failover
else
	err "WARN: amnezia-failover missing from payload; failover daemon will not run"
fi

# iproute2 routing tables config (no extension — stage explicitly).
if [ -f "$SRC/iproute2-amnezia-rt_tables.conf" ]; then
	cp "$SRC/iproute2-amnezia-rt_tables.conf" /tmp/iproute2-amnezia-rt_tables.conf
else
	err "WARN: iproute2-amnezia-rt_tables.conf missing from payload"
fi

# Seed lists and force-tunnel.list.
for _f in "$SRC"/*.list; do
	[ -f "$_f" ] || continue
	_bn=$(basename "$_f")
	cp "$_f" "/tmp/$_bn" || err "WARN: $_bn staging failed"
done

# Shared libs: installer sources $SCRIPT_DIR/lib/amnezia-*.sh (SCRIPT_DIR=/tmp).
mkdir -p /tmp/lib
for _f in "$SRC"/lib/*.sh; do
	[ -f "$_f" ] || continue
	_bn=$(basename "$_f")
	cp "$_f" "/tmp/lib/$_bn" || err "WARN: lib/$_bn staging failed; some functionality may degrade"
done

# nftables classifier fragments: installer reads $SCRIPT_DIR/nftables.d/ (= /tmp/nftables.d/).
mkdir -p /tmp/nftables.d
for _f in "$SRC"/nftables.d/*.nft; do
	[ -f "$_f" ] || continue
	_bn=$(basename "$_f")
	cp "$_f" "/tmp/nftables.d/$_bn" || err "WARN: nftables.d/$_bn staging failed; classifier install may degrade"
done

# UCI scaffold (different naming because installer copies to /etc/config/amnezia)
[ -f "$SRC/config/amnezia" ] && cp "$SRC/config/amnezia" /tmp/amnezia.config

# LuCI app tree (nested subdirs).
mkdir -p /tmp/luci-app-amnezia/menu /tmp/luci-app-amnezia/acl /tmp/luci-app-amnezia/view
mkdir -p /tmp/luci-app-amnezia/amnezia
cp "$SRC/luci-app-amnezia/menu/luci-app-amnezia.json" /tmp/luci-app-amnezia/menu/
cp "$SRC/luci-app-amnezia/acl/luci-app-amnezia.json"  /tmp/luci-app-amnezia/acl/
cp "$SRC/luci-app-amnezia/view/main.js"               /tmp/luci-app-amnezia/view/
cp -r "$SRC/luci-app-amnezia/amnezia/." /tmp/luci-app-amnezia/amnezia/

# AWG config -> what install-amnezia-pbr.sh reads.
cp "$AWG_CONF" /tmp/awg-setup.conf

# --- Run installer ---
echo "install: running install-amnezia-pbr.sh (STEPS=$STEPS, log: $LOG)"
: > "$LOG"
if STEPS="$STEPS" LOG="$LOG" INSTALLED_VERSION="$REPO_REF" sh /tmp/install-amnezia-pbr.sh; then
	echo ""
	echo "install: DONE. Log: $LOG"
	echo ""
	echo "Next:"
	echo "  - Open LuCI: Network -> Amnezia (refresh if you had it open)"
	echo "  - Toggle the tunnel from the State row"
	echo "  - Optional: Run Blockcheck against a few sites you care about"
	echo "    and Apply the recommended zapret strategy. See README for"
	echo "    when zapret helps (DPI bypass) vs when only the tunnel does"
	echo "    (SYN-blocked or anti-VPN services)."
else
	rc=$?
	echo ""
	err "install: FAILED (exit $rc). Last log lines:"
	tail -20 "$LOG" >&2 || true
	exit "$rc"
fi
