#!/bin/sh
# install-amnezia-pbr: end-to-end installer that runs ON the router.
#
# Drives three steps:
#   STEPS=1   AmneziaWG interface + firewall zone (kmod + tools + UCI + ifup)
#   STEPS=2   + Policy-based routing base (LAN forwarded via awg1)
#   STEPS=3   + RU bypass (.ru TLD via dnsmasq nftset + ipdeny RU CIDR list)
#
# Inputs:
#   /tmp/awg-setup.conf       AmneziaWG client config exported from Amnezia
#                              client (or the desktop wireguard-style conf
#                              with the extra Jc/Jmin/Jmax/S*/H*/I* lines).
#                              Override via CONF env var.
#   /tmp/<helper>.sh          The wrappers + LuCI app + install-* scripts,
#                              pre-uploaded by the bootstrap (install.sh)
#                              or deploy (dev/deploy-openwrt-safe.sh).
#
# Outputs:
#   /tmp/openwrt-deploy.log   step-by-step log; ends with DEPLOY_DONE or
#                              DEPLOY_FAILED so callers can poll it.
#
# Never restarts the network as a whole -- only `firewall reload` and
# targeted `ifup awg1`. Pings WAN before/after each destructive step so a
# remote run can fail fast instead of leaving you locked out.
#
# This script intentionally has no SSH knowledge -- the maintainer wrapper
# (dev/deploy-openwrt-safe.sh) handles SSH, the public bootstrap
# (install.sh) handles tarball download. Both end up here.
# shellcheck disable=SC2039
set -eu

usage() {
  cat <<USAGE
amnezia-pbr-setup -- first-run setup for amnezia-pbr-openwrt.

Usage:
  amnezia-pbr-setup [STEPS]
  STEPS=N amnezia-pbr-setup

Where STEPS is 1, 2, or 3 (default 3):
  1   AmneziaWG interface + firewall zone only
  2   + Policy-based routing base (LAN forwarded via awg1)
  3   + RU bypass (.ru direct via dnsmasq nftset + ipdeny RU CIDR)

Reads AmneziaWG config from \$CONF (default /etc/amnezia/awg.conf,
falling back to /tmp/awg-setup.conf for install.sh-staged runs).
Writes step-by-step log to /tmp/openwrt-deploy.log; tail it to track
progress on a long run.

Other env overrides:
  AWG_VER     Slava-Shchipunov ipk release (default 24.10.3)
  AWG_ARCH    auto from /etc/openwrt_release
  AWG_TS      auto from /etc/openwrt_release
USAGE
}

# ---------------------------------------------------------------------------
# Multi-tunnel entry points (Phase D): must appear BEFORE the legacy arg
# parser so they intercept --dry-run-tunnel / --dry-run-all / --migrate /
# --first-install before the old "expected 1, 2, 3" guard fires.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source the shared lib if present (POSIX-safe guard: no failed-`.` exit).
if [ -f /usr/lib/amnezia/amnezia-common.sh ]; then
  . /usr/lib/amnezia/amnezia-common.sh
elif [ -f "$SCRIPT_DIR/lib/amnezia-common.sh" ]; then
  . "$SCRIPT_DIR/lib/amnezia-common.sh"
fi

# Source the routing lib if present.
if [ -f /usr/lib/amnezia/amnezia-routing.sh ]; then
  . /usr/lib/amnezia/amnezia-routing.sh
elif [ -f "$SCRIPT_DIR/lib/amnezia-routing.sh" ]; then
  . "$SCRIPT_DIR/lib/amnezia-routing.sh"
fi

# gen_tunnel_uci <tunnel_name> <conf_file>
# Prints the UCI lines that describe one AmneziaWG tunnel (interface + peer).
# Emits allowed_ips=0.0.0.0/0 ONLY — never ::/0 (IPv4-only policy).
gen_tunnel_uci() {
  _tname=$1
  _cfile=$2
  _CFG="amneziawg_${_tname}"

  # Parse the conf so AWG_* vars are available.
  parse_awg_conf "$_cfile" || return 1

  echo "set network.${_tname}=interface"
  echo "set network.${_tname}.proto=amneziawg"
  echo "set network.${_tname}.private_key=${AWG_PrivateKey}"
  echo "set network.${_tname}.addresses=${AWG_Address}"
  echo "set network.${_tname}.mtu=1376"
  [ -n "${AWG_Jc:-}"   ] && echo "set network.${_tname}.awg_jc=${AWG_Jc}"
  [ -n "${AWG_Jmin:-}" ] && echo "set network.${_tname}.awg_jmin=${AWG_Jmin}"
  [ -n "${AWG_Jmax:-}" ] && echo "set network.${_tname}.awg_jmax=${AWG_Jmax}"
  echo "add network ${_CFG}"
  echo "set network.@${_CFG}[-1]=${_CFG}"
  echo "set network.@${_CFG}[-1].name=${_tname}_client"
  echo "set network.@${_CFG}[-1].public_key=${AWG_PublicKey}"
  [ -n "${AWG_PresharedKey:-}" ] && echo "set network.@${_CFG}[-1].preshared_key=${AWG_PresharedKey}"
  echo "set network.@${_CFG}[-1].endpoint_host=${AWG_Endpoint_host}"
  echo "set network.@${_CFG}[-1].endpoint_port=${AWG_Endpoint_port}"
  echo "set network.@${_CFG}[-1].persistent_keepalive=${AWG_PersistentKeepalive:-25}"
  echo "set network.@${_CFG}[-1].allowed_ips=0.0.0.0/0"
  echo "set network.@${_CFG}[-1].route_allowed_ips=0"
}

# ---------------------------------------------------------------------------
# --dry-run-tunnel <name> --conf <file>: emit UCI for a single tunnel, no
# side effects.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--dry-run-tunnel" ]; then
  _dt_name="${2:-}"
  _dt_conf=""
  shift 2 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --conf) _dt_conf="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$_dt_name" ] || { echo "usage: --dry-run-tunnel <name> --conf <file>" >&2; exit 2; }
  [ -n "$_dt_conf" ] || { echo "usage: --dry-run-tunnel <name> --conf <file>" >&2; exit 2; }
  gen_tunnel_uci "$_dt_name" "$_dt_conf"
  exit 0
fi

# ---------------------------------------------------------------------------
# --dry-run-all: enumerate enabled tunnels from UCI and emit all tunnel UCI
# + firewall dry-run. Uses stubs in tests; applies to real UCI on-router.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--dry-run-all" ]; then
  _tunnel_list=""
  _tunnel_list=$(uci show amnezia 2>/dev/null \
    | awk -F'[.=]' '/\.enabled=1/{print $2}' | tr '\n' ' ' | sed 's/ $//')
  # Fallback: UCI_FAKE_TUNNELS is set by the test harness stub.
  if [ -z "$_tunnel_list" ] && [ -n "${UCI_FAKE_TUNNELS:-}" ]; then
    _tunnel_list="$UCI_FAKE_TUNNELS"
  fi
  for _t in $_tunnel_list; do
    _cfile="${CONF_DIR:-/etc/amnezia}/${_t}.conf"
    if [ -f "$_cfile" ]; then
      gen_tunnel_uci "$_t" "$_cfile"
    else
      # In dry-run/test mode emit placeholder lines so the test can grep them.
      echo "set network.${_t}=interface"
    fi
  done
  # Emit firewall dry-run if routing lib is loaded.
  if command -v routing_firewall_dryrun >/dev/null 2>&1; then
    routing_firewall_dryrun "$_tunnel_list"
  fi
  echo "firewall.vpn.network=$_tunnel_list"
  exit 0
fi

# ---------------------------------------------------------------------------
# --migrate [--dry-run]: ordered pbr-removal migration.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--migrate" ]; then
  _migrate_dry=0
  shift
  [ "${1:-}" = "--dry-run" ] && { _migrate_dry=1; shift; }

  MUST_TUNNEL_LIST="${MUST_TUNNEL_LIST:-/etc/amnezia/seed-must-tunnel.list}"

  migrate_from_pbr() {
    # Step 1: declare/install classifier.
    if [ "$_migrate_dry" = 1 ]; then
      echo "install:classifier"
    else
      LAN_DEV=$(uci get network.lan.device 2>/dev/null || echo br-lan)
      sed "s/@@LAN_IFNAME@@/$LAN_DEV/" \
        "$SCRIPT_DIR/nftables.d/30-amnezia-classify.nft" \
        > /etc/nftables.d/30-amnezia-classify.nft
      amz_log "install:classifier"
    fi

    # Step 2: repoint dnsmasq to amnezia nftsets.
    if [ "$_migrate_dry" = 1 ]; then
      echo "repoint:dnsmasq"
    else
      sh "$SCRIPT_DIR/configure-dnsmasq-amnezia.sh"
    fi

    # must-tunnel→sticky migration: feed existing seed-must-tunnel.list entries
    # into the sticky dnsmasq ipset binding.
    if [ -f "$MUST_TUNNEL_LIST" ]; then
      while IFS= read -r _dom; do
        case "$_dom" in ''|\#*) continue ;; esac
        uci add_list dhcp.amnezia_sticky.domain="$_dom"
      done < "$MUST_TUNNEL_LIST"
    fi

    # Step 3: gate on @amnezia_ru4 being non-empty before removing pbr.
    _ru4_count=0
    _ru4_out=$(nft list set inet fw4 amnezia_ru4 2>/dev/null || true)
    if echo "$_ru4_out" | grep -q 'elements'; then
      _ru4_count=$(echo "$_ru4_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | wc -l | tr -d ' ')
    else
      # Use NFT_FAKE_RU4_COUNT in test mode.
      _ru4_count="${NFT_FAKE_RU4_COUNT:-0}"
    fi

    if [ "$_ru4_count" -le 0 ]; then
      echo "ABORT:ru4-empty"
      return 1
    fi

    # Step 4: remove pbr (AFTER classifier is installed and ru4 is populated).
    if [ "$_migrate_dry" = 1 ]; then
      echo "remove:pbr"
    else
      /etc/init.d/pbr stop 2>/dev/null || true
      /etc/init.d/pbr disable 2>/dev/null || true
      opkg remove pbr luci-app-pbr 2>/dev/null || true
    fi
  }

  migrate_from_pbr
  exit $?
fi

# ---------------------------------------------------------------------------
# --first-install [--dry-run]: wire up all new components on a clean install.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--first-install" ]; then
  _fi_dry=0
  shift
  [ "${1:-}" = "--dry-run" ] && { _fi_dry=1; shift; }

  first_install_wiring() {
    # 1. rt_tables
    if [ "$_fi_dry" = 1 ]; then
      echo "install:rt_tables" >> "${STUB_LOG:-/dev/null}"
      amz_log "install:rt_tables"
    else
      cp "$SCRIPT_DIR/iproute2-amnezia-rt_tables.conf" /etc/iproute2/rt_tables.d/amnezia.conf
      amz_log "install:rt_tables"
    fi
    # 2. ip rules
    routing_install_rules
    # 3. classifier (with LAN ifname substitution)
    if [ "$_fi_dry" = 1 ]; then
      amz_log "install:classifier"
      echo "install:classifier" >> "${STUB_LOG:-/dev/null}"
    else
      LAN_DEV=$(uci get network.lan.device 2>/dev/null || echo br-lan)
      sed "s/@@LAN_IFNAME@@/$LAN_DEV/" "$SCRIPT_DIR/nftables.d/30-amnezia-classify.nft" \
        > /etc/nftables.d/30-amnezia-classify.nft
      amz_log "install:classifier"
    fi
    # 4. dnsmasq UCI ipset
    if [ "$_fi_dry" = 1 ]; then
      sh "$SCRIPT_DIR/configure-dnsmasq-amnezia.sh"
    else
      sh "$SCRIPT_DIR/configure-dnsmasq-amnezia.sh"
    fi
    # 5. monitor enable + start
    if [ "$_fi_dry" = 1 ]; then
      echo "/etc/init.d/amnezia-failover enable" >> "${STUB_LOG:-/dev/null}"
    else
      /etc/init.d/amnezia-failover enable
      ( sleep 1 && /etc/init.d/amnezia-failover start ) &
    fi
  }

  first_install_wiring
  exit 0
fi

# ---------------------------------------------------------------------------
# Legacy argument parsing (original single-tunnel installer).
# ---------------------------------------------------------------------------
# Argument parsing: support --help and reject unknown args. Without this,
# `amnezia-pbr-setup --help` would set STEPS=--help and silently start
# the install pipeline with junk as the steps value.
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  ""|1|2|3) ;;
  *) echo "amnezia-pbr-setup: unknown argument '$1' (expected 1, 2, 3, or --help)" >&2
     usage >&2
     exit 2 ;;
esac

STEPS="${STEPS:-${1:-3}}"
LOG="${LOG:-/tmp/openwrt-deploy.log}"
# CONF default cascades: explicit env -> /tmp/ (install.sh staging) ->
# /etc/amnezia/ (.ipk installed). The .ipk path is what `opkg install`
# users hit; the /tmp/ path is what install.sh + dev/deploy hit.
if [ -z "${CONF:-}" ]; then
  if [ -f /tmp/awg-setup.conf ]; then
    CONF=/tmp/awg-setup.conf
  else
    CONF=/etc/amnezia/awg.conf
  fi
fi
IFACE=awg1
CFG=amneziawg_awg1
ZONE=awg1

# Locate helper scripts (install-zapret, install-dnsmasq-full, etc.) -- they
# may live under /tmp/ (install.sh staging, with .sh extension) or in PATH
# without extension (amnezia-pbr.ipk installs them to /usr/sbin/). Return
# empty + nonzero if not found anywhere; caller decides whether to skip.
find_helper() {
  _name=$1
  if [ -f "/tmp/${_name}.sh" ]; then
    echo "sh /tmp/${_name}.sh"
    return 0
  fi
  if command -v "$_name" >/dev/null 2>&1; then
    command -v "$_name"
    return 0
  fi
  return 1
}

# Locate PBR templates (99-lan-vpn-*.sh). install.sh stages them under /tmp/
# unmodified; the .ipk ships them under /usr/share/amnezia-pbr/pbr.d/.
#
# Templates MUST NOT live in /etc/pbr.d/ -- the pbr service globs that
# directory and would execute them with the literal __LAN__ placeholder,
# triggering "Could not resolve hostname" in the generated nft file. The
# resolved file is written to /etc/pbr.d/99-lan-vpn.sh by the install steps
# below.
find_template() {
  _name=$1
  if [ -f "/tmp/${_name}" ]; then
    echo "/tmp/${_name}"
    return 0
  fi
  if [ -f "/usr/share/amnezia-pbr/pbr.d/${_name}" ]; then
    echo "/usr/share/amnezia-pbr/pbr.d/${_name}"
    return 0
  fi
  return 1
}

# Legacy cleanup: 0.2.0 shipped templates with a .template suffix in
# /etc/pbr.d/, which pbr globbed and tried to execute. Remove them on any
# re-run so a routine `amnezia-pbr-setup` heals the bad install state.
rm -f /etc/pbr.d/*.template 2>/dev/null || true

# AmneziaWG kmod + tools come from Slava-Shchipunov's release feed -- they
# aren't in the official OpenWrt repos. Auto-detect arch and target from
# /etc/openwrt_release; env override lets the maintainer pin a build that
# doesn't match the running kernel (rare but useful when testing a kmod ABI).
. /etc/openwrt_release 2>/dev/null || true
AWG_VER="${AWG_VER:-24.10.3}"
AWG_ARCH="${AWG_ARCH:-${DISTRIB_ARCH:-aarch64_cortex-a53}}"
AWG_TS="${AWG_TS:-${DISTRIB_TARGET:-mediatek/filogic}}"
# /etc/openwrt_release stores TARGET as `mediatek/filogic`; Slava's release
# filenames use the underscore form `mediatek_filogic.ipk`.
AWG_TS_FLAT=$(printf '%s' "$AWG_TS" | tr '/' '_')

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

# Read a key from a section of a wireguard-style ini config. Tolerates blank
# lines, "Key = Value" or "Key=Value", whitespace around the value.
get() {
  _sec="$1"; _key="$2"
  awk -v s="$_sec" -v k="$_key" '
    $0 ~ "^\\[" s "\\]" { in_s=1; next }
    /^\[/ { in_s=0 }
    in_s && $1==k { sub(/^[^=]+= */, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }
  ' "$CONF"
}

log "DEPLOY_START steps=$STEPS arch=$AWG_ARCH target=$AWG_TS"
[ -f "$CONF" ] || fail "missing AWG config at $CONF (provide Amnezia-exported .conf)"
need_wan
need_dns
ok "0 preflight"

# --- Step 1: AWG UCI + ifup (no network restart) ---
log "Step 1: AWG interface"
if ! opkg list-installed | grep -q '^kmod-amneziawg '; then
  BASE="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${AWG_VER}"
  DIR=/tmp/awg-pkgs; mkdir -p "$DIR"
  opkg update >/dev/null || opkg update || fail "opkg update"
  for pkg in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
    f="${pkg}_v${AWG_VER}_${AWG_ARCH}_${AWG_TS_FLAT}.ipk"
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
[ -n "$IF_PRIV" ] && [ -n "$PEER_PUB" ] || fail "awg.conf parse (missing PrivateKey or PublicKey)"

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

# Lay down /etc/config/amnezia if absent. Existing file is preserved (user
# may have overridden routing_mode); only the version + timestamp stamps
# get refreshed each run so `uci show amnezia` always reports the latest
# install. Non-fatal: bad UCI here must not block AWG/PBR.
if [ -f /tmp/amnezia.config ] && [ ! -f /etc/config/amnezia ]; then
  # BusyBox has no `install` command; cp + chmod is the portable form.
  cp /tmp/amnezia.config /etc/config/amnezia
  chmod 0644 /etc/config/amnezia
  log "UCI: /etc/config/amnezia created from staged template"
fi
if [ -f /etc/config/amnezia ]; then
  uci -q set amnezia.config.installed_version="${INSTALLED_VERSION:-main}" 2>/dev/null || true
  uci -q set amnezia.config.installed_ts="$(date +%s)" 2>/dev/null || true
  uci -q commit amnezia 2>/dev/null || true
fi

# LuCI toggle buttons (System -> Custom Commands). Optional; skip silently
# when the helper isn't available (.ipk path doesn't ship it as it's a
# niche luci-app-commands integration the user likely doesn't want).
if [ -f /tmp/install-luci-toggle.sh ]; then
  if SRC=/tmp/awg-toggle.sh sh /tmp/install-luci-toggle.sh >>"$LOG" 2>&1; then
    log "luci toggle installed"
  else
    log "WARN: luci toggle install failed (non-fatal)"
  fi
fi

# zapret (DPI desync) install. Service stays DISABLED after install -- user
# enables via the LuCI button. Non-fatal: failure here must not break AWG.
# In .ipk mode the helper is at /usr/sbin/install-zapret; in install.sh mode
# it's at /tmp/install-zapret.sh.
if _zapret=$(find_helper install-zapret); then
  if $_zapret >>"$LOG" 2>&1; then
    log "zapret installed (service left disabled)"
  else
    log "WARN: zapret install failed (non-fatal)"
  fi
else
  log "WARN: install-zapret helper not found; skipping zapret install"
fi

# Refresh LuCI app: menu entry, ACL, view JS. The .ipk path installs these
# via the luci-app-amnezia package, so the helper script is absent and we
# skip. install.sh path stages the helper to /tmp/.
if [ -d /tmp/luci-app-amnezia ] && [ -f /tmp/install-luci-app-amnezia.sh ]; then
  if SRC=/tmp/luci-app-amnezia sh /tmp/install-luci-app-amnezia.sh >>"$LOG" 2>&1; then
    log "luci-app-amnezia refreshed (menu/acl/view)"
  else
    log "WARN: luci-app-amnezia refresh failed (non-fatal)"
  fi
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
# Step 2's PBR config is "LAN -> VPN, nothing direct yet". The .ru
# direct rule lands in Step 3 if STEPS=3, so we drop it here so a
# re-run isn't reading a stale file.
rm -f /etc/pbr.d/ru-direct.sh
_tpl=$(find_template 99-lan-vpn-vpn-only.sh) || fail "missing 99-lan-vpn-vpn-only.sh template"
sed "s|__LAN__|$LAN|g" "$_tpl" > /etc/pbr.d/99-lan-vpn.sh
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

if _dnsmasq=$(find_helper install-dnsmasq-full); then
  $_dnsmasq 2>/dev/null || fail "dnsmasq-full install"
else
  # .ipk path declares dnsmasq-full as a hard DEPENDS, so opkg already has
  # it installed. No-op.
  command -v dnsmasq >/dev/null 2>&1 || fail "dnsmasq missing and no installer helper"
fi
need_dns || fail "DNS broken after dnsmasq-full"

if _nftset=$(find_helper configure-dnsmasq-ru-nftset); then
  $_nftset 2>/dev/null || fail "dnsmasq .ru nftset config"
else
  log "WARN: configure-dnsmasq-ru-nftset helper missing; .ru nftset not wired"
fi

# ru-direct + full LAN rules (idempotent — no duplicate nft rules on pbr restart).
# ru-direct.sh ships at /etc/pbr.d/ in .ipk; copy from /tmp/ only when present.
if [ -f /tmp/ru-direct.sh ]; then
  cp /tmp/ru-direct.sh /etc/pbr.d/ru-direct.sh
fi
chmod 755 /etc/pbr.d/ru-direct.sh
_tpl=$(find_template 99-lan-vpn-full.sh) || fail "missing 99-lan-vpn-full.sh template"
sed "s|__LAN__|$LAN|g" "$_tpl" > /etc/pbr.d/99-lan-vpn.sh
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

_ipdeny=$(nft list set inet fw4 pbr_wan_4_dst_ip_user 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | wc -l)
_ipdeny=$(printf '%s' "$_ipdeny" | tr -d ' ')
log "ipdeny entries: $_ipdeny"
[ "$_ipdeny" -gt 100 ] || fail "ipdeny set too small ($_ipdeny)"

ok "3 ru_bypass"
log "DEPLOY_DONE steps=$STEPS"
