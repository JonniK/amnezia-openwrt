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
# shellcheck disable=SC2039,SC2154
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

# Preserve any caller-supplied CONF_DIR before sourcing amnezia-common.sh.
# amnezia-common.sh hard-sets `export CONF_DIR=/etc/amnezia`, which would
# otherwise overwrite an env var injected by the test harness or a sysadmin.
_saved_conf_dir="${CONF_DIR:-}"

# Source the shared lib if present (POSIX-safe guard: no failed-`.` exit).
if [ -f /usr/lib/amnezia/amnezia-common.sh ]; then
  . /usr/lib/amnezia/amnezia-common.sh
elif [ -f "$SCRIPT_DIR/lib/amnezia-common.sh" ]; then
  . "$SCRIPT_DIR/lib/amnezia-common.sh"
fi

# Restore caller-supplied CONF_DIR if it was set before the source.
[ -n "$_saved_conf_dir" ] && CONF_DIR="$_saved_conf_dir"

# Source the routing lib if present.
if [ -f /usr/lib/amnezia/amnezia-routing.sh ]; then
  . /usr/lib/amnezia/amnezia-routing.sh
elif [ -f "$SCRIPT_DIR/lib/amnezia-routing.sh" ]; then
  . "$SCRIPT_DIR/lib/amnezia-routing.sh"
fi

# Source the tunnel lib (gen_tunnel_uci) if present.
if [ -f /usr/lib/amnezia/amnezia-tunnel-lib.sh ]; then
  . /usr/lib/amnezia/amnezia-tunnel-lib.sh
elif [ -f "$SCRIPT_DIR/lib/amnezia-tunnel-lib.sh" ]; then
  . "$SCRIPT_DIR/lib/amnezia-tunnel-lib.sh"
fi

# ---------------------------------------------------------------------------
# resolve_dep <installed_path> <tmp_name> <script_dir_rel>
#   Returns (via stdout) the first path that exists among:
#     1. <installed_path>        -- .ipk-installed location (no .sh extension)
#     2. /tmp/<tmp_name>         -- install.sh staging (with .sh extension)
#     3. $SCRIPT_DIR/<script_dir_rel> -- dev/deploy staging (relative to script)
#   Returns empty string (and exit 1) when none is found so callers can guard.
# ---------------------------------------------------------------------------
resolve_dep() {
  _rd_installed="$1"
  _rd_tmp="/tmp/$2"
  _rd_src="$SCRIPT_DIR/$3"
  if [ -f "$_rd_installed" ]; then
    echo "$_rd_installed"; return 0
  fi
  if [ -f "$_rd_tmp" ]; then
    echo "$_rd_tmp"; return 0
  fi
  if [ -f "$_rd_src" ]; then
    echo "$_rd_src"; return 0
  fi
  return 1
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
    | awk -F'[.=]' '/\.enabled='"'"'?1/ && $2 ~ /^awg[0-9]/{print $2}' | tr '\n' ' ' | sed 's/ $//')
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
  exit 0
fi

# ---------------------------------------------------------------------------
# _amz_wire_force_engine <dry>
#   Shared helper: installs the full force-list engine (helpers, hotplug,
#   boot-init, seed, cron, initial populate). Called from BOTH first_install
#   and migrate_from_pbr after the ru4 gate passes.
#   $1 = "1" means dry-run (skip all real file operations).
#   Note: .nft fragment install is NOT here — first_install places it before
#   classifier generation (step 2b) which must remain before classifier gen.
# ---------------------------------------------------------------------------
_amz_wire_force_engine() {
  _afe_dry="${1:-0}"

  if [ "$_afe_dry" = 1 ]; then
    return 0
  fi

  # Install the three allowlist helpers to /usr/bin.
  for _afe_helper in amnezia-tunnel-ctl amnezia-force-load amnezia-force-update amnezia-force-warm amnezia-app-ctl amnezia-autotunnel; do
    if [ -f "/usr/bin/${_afe_helper}" ]; then
      amz_log "${_afe_helper} already present (/usr/bin)"
    else
      _afe_src=$(resolve_dep \
        "/usr/bin/${_afe_helper}" \
        "${_afe_helper}.sh" \
        "${_afe_helper}.sh") || true
      if [ -n "$_afe_src" ] && [ "$_afe_src" != "/usr/bin/${_afe_helper}" ]; then
        cp "$_afe_src" "/usr/bin/${_afe_helper}" 2>/dev/null || true
        chmod +x "/usr/bin/${_afe_helper}" 2>/dev/null || true
        amz_log "${_afe_helper} installed to /usr/bin"
      elif [ -z "$_afe_src" ]; then
        amz_log "WARN: ${_afe_helper} not found; allowlist helper will be missing"
      fi
    fi
  done

  # Install the force-load firewall hotplug (repopulates amnezia_force4 on fw reload).
  if [ -f /etc/hotplug.d/firewall/99-amnezia-force-load ]; then
    amz_log "99-amnezia-force-load hotplug already present (.ipk path)"
  else
    _afe_hplug=$(resolve_dep \
      /etc/hotplug.d/firewall/99-amnezia-force-load \
      99-amnezia-force-load.hotplug \
      99-amnezia-force-load.hotplug) || true
    if [ -n "$_afe_hplug" ] && [ "$_afe_hplug" != /etc/hotplug.d/firewall/99-amnezia-force-load ]; then
      mkdir -p /etc/hotplug.d/firewall 2>/dev/null || true
      cp "$_afe_hplug" /etc/hotplug.d/firewall/99-amnezia-force-load 2>/dev/null || true
      chmod +x /etc/hotplug.d/firewall/99-amnezia-force-load 2>/dev/null || true
    elif [ -z "$_afe_hplug" ]; then
      amz_log "WARN: 99-amnezia-force-load.hotplug not found; force-load hotplug disabled"
    fi
  fi

  # Install the force-load boot init (mirrors amnezia-ru-load.init pattern).
  if [ -f /etc/init.d/amnezia-force-load ]; then
    amz_log "amnezia-force-load init already present (.ipk path)"
  else
    _afe_init=$(resolve_dep \
      /etc/init.d/amnezia-force-load \
      amnezia-force-load.init \
      amnezia-force-load.init) || true
    if [ -n "$_afe_init" ] && [ "$_afe_init" != /etc/init.d/amnezia-force-load ]; then
      cp "$_afe_init" /etc/init.d/amnezia-force-load 2>/dev/null || true
      chmod +x /etc/init.d/amnezia-force-load 2>/dev/null || true
    elif [ -z "$_afe_init" ]; then
      amz_log "WARN: amnezia-force-load.init not found; force-load on boot disabled"
    fi
  fi
  # Enable the init service (runs procd enable — idempotent).
  # Explicit echo to STUB_LOG allows tests to verify enable was called.
  echo "/etc/init.d/amnezia-force-load enable" >> "${STUB_LOG:-/dev/null}"
  /etc/init.d/amnezia-force-load enable 2>/dev/null || true

  # --- Encrypted-DNS packages + files (after the dry-run guard above) ---
  for pkg in stubby https-dns-proxy; do
    opkg list-installed 2>/dev/null | grep -q "^$pkg " || opkg install "$pkg" 2>/dev/null \
      || amz_log "dns: opkg install $pkg failed (DoT falls back to plaintext until installed)"
  done
  # CLI + lib + init + hotplug via resolve_dep (on-router paths, not repo openwrt/ paths)
  _dns_ctl=$(resolve_dep /usr/bin/amnezia-dns-ctl amnezia-dns-ctl.sh amnezia-dns-ctl.sh) || true
  if [ -n "$_dns_ctl" ] && [ "$_dns_ctl" != /usr/bin/amnezia-dns-ctl ]; then
    cp "$_dns_ctl" /usr/bin/amnezia-dns-ctl 2>/dev/null || true
    chmod 0755 /usr/bin/amnezia-dns-ctl 2>/dev/null || true
  fi
  _dns_lib=$(resolve_dep /usr/lib/amnezia/amnezia-dns-lib.sh amnezia-dns-lib.sh lib/amnezia-dns-lib.sh) || true
  if [ -n "$_dns_lib" ] && [ "$_dns_lib" != /usr/lib/amnezia/amnezia-dns-lib.sh ]; then
    cp "$_dns_lib" /usr/lib/amnezia/amnezia-dns-lib.sh 2>/dev/null || true
  fi
  if [ ! -f /etc/init.d/amnezia-dns ]; then
    _dns_init=$(resolve_dep /etc/init.d/amnezia-dns amnezia-dns.init amnezia-dns.init) || true
    if [ -n "$_dns_init" ]; then
      cp "$_dns_init" /etc/init.d/amnezia-dns 2>/dev/null || true
      chmod 0755 /etc/init.d/amnezia-dns 2>/dev/null || true
    fi
  fi
  if [ ! -f /etc/hotplug.d/firewall/99-amnezia-dns ]; then
    _dns_hp=$(resolve_dep /etc/hotplug.d/firewall/99-amnezia-dns 99-amnezia-dns.hotplug 99-amnezia-dns.hotplug) || true
    if [ -n "$_dns_hp" ]; then
      cp "$_dns_hp" /etc/hotplug.d/firewall/99-amnezia-dns 2>/dev/null || true
      chmod 0755 /etc/hotplug.d/firewall/99-amnezia-dns 2>/dev/null || true
    fi
  fi
  /etc/init.d/amnezia-dns enable 2>/dev/null || true

  # DNS-leak prevention CLI + init + hotplug (default-OFF; wired but not started).
  _dnsleak_ctl=$(resolve_dep /usr/bin/amnezia-dnsleak-ctl amnezia-dnsleak-ctl.sh amnezia-dnsleak-ctl.sh) || true
  if [ -n "$_dnsleak_ctl" ] && [ "$_dnsleak_ctl" != /usr/bin/amnezia-dnsleak-ctl ]; then
    cp "$_dnsleak_ctl" /usr/bin/amnezia-dnsleak-ctl 2>/dev/null || true
    chmod 0755 /usr/bin/amnezia-dnsleak-ctl 2>/dev/null || true
  fi
  if [ ! -f /etc/init.d/amnezia-dnsleak ]; then
    _dnsleak_init=$(resolve_dep /etc/init.d/amnezia-dnsleak amnezia-dnsleak.init amnezia-dnsleak.init) || true
    if [ -n "$_dnsleak_init" ]; then
      cp "$_dnsleak_init" /etc/init.d/amnezia-dnsleak 2>/dev/null || true
      chmod 0755 /etc/init.d/amnezia-dnsleak 2>/dev/null || true
    fi
  fi
  if [ ! -f /etc/hotplug.d/firewall/99-amnezia-dnsleak ]; then
    _dnsleak_hp=$(resolve_dep /etc/hotplug.d/firewall/99-amnezia-dnsleak 99-amnezia-dnsleak.hotplug 99-amnezia-dnsleak.hotplug) || true
    if [ -n "$_dnsleak_hp" ]; then
      cp "$_dnsleak_hp" /etc/hotplug.d/firewall/99-amnezia-dnsleak 2>/dev/null || true
      chmod 0755 /etc/hotplug.d/firewall/99-amnezia-dnsleak 2>/dev/null || true
    fi
  fi
  /etc/init.d/amnezia-dnsleak enable 2>/dev/null || true

  # Kernel resilience: auto-reboot on a hung/oopsed kernel instead of dead-hanging
  # (procd keeps the hw watchdog fed during a subsystem lockup, so a hung kernel
  # can otherwise sit dead for hours). Place + apply the sysctl drop-in.
  _amz_sysctl=$(resolve_dep /etc/sysctl.d/99-amnezia-resilience.conf \
    sysctl.d/99-amnezia-resilience.conf 99-amnezia-resilience.conf) || true
  if [ -n "$_amz_sysctl" ]; then
    mkdir -p /etc/sysctl.d
    cp "$_amz_sysctl" /etc/sysctl.d/99-amnezia-resilience.conf 2>/dev/null || true
    sysctl -p /etc/sysctl.d/99-amnezia-resilience.conf >/dev/null 2>&1 || true
  fi

  # Wire dnsmasq conf-dir so fresh installs pick up chunked nftset directives
  # even before the first amnezia-force-load run.  Idempotent: only set+commit
  # when the value is not already the expected path.
  _afe_confdir=/etc/amnezia/dnsmasq.d
  _afe_cur_confdir=$(uci -q get dhcp.@dnsmasq[0].confdir 2>/dev/null || true)
  if [ "$_afe_cur_confdir" != "$_afe_confdir" ]; then
    uci set "dhcp.@dnsmasq[0].confdir=$_afe_confdir"
    uci commit dhcp
    amz_log "dnsmasq confdir wired to $_afe_confdir"
  else
    amz_log "dnsmasq confdir already set to $_afe_confdir"
  fi
  mkdir -p "$_afe_confdir" 2>/dev/null || true

  # Seed /etc/amnezia/force-tunnel.list and force.d/ (idempotent).
  mkdir -p "${CONF_DIR:-/etc/amnezia}/force.d" 2>/dev/null || true
  if [ ! -f "${CONF_DIR:-/etc/amnezia}/force-tunnel.list" ]; then
    _afe_ftl=$(resolve_dep \
      "${CONF_DIR:-/etc/amnezia}/force-tunnel.list" \
      force-tunnel.list \
      force-tunnel.list) || true
    if [ -n "$_afe_ftl" ] && \
       [ "$_afe_ftl" != "${CONF_DIR:-/etc/amnezia}/force-tunnel.list" ]; then
      cp "$_afe_ftl" "${CONF_DIR:-/etc/amnezia}/force-tunnel.list" 2>/dev/null || true
      chmod 0644 "${CONF_DIR:-/etc/amnezia}/force-tunnel.list" 2>/dev/null || true
    else
      touch "${CONF_DIR:-/etc/amnezia}/force-tunnel.list" 2>/dev/null || true
      chmod 0644 "${CONF_DIR:-/etc/amnezia}/force-tunnel.list" 2>/dev/null || true
    fi
    amz_log "force-tunnel.list seeded"
  else
    amz_log "force-tunnel.list already present"
  fi

  # Seed /etc/amnezia/direct-tunnel.list (direct-override set; idempotent —
  # never clobbers user edits on upgrade). See
  # docs/superpowers/specs/2026-07-22-direct-override-set-design.md.
  if [ ! -f "${CONF_DIR:-/etc/amnezia}/direct-tunnel.list" ]; then
    _afe_dtl=$(resolve_dep \
      "${CONF_DIR:-/etc/amnezia}/direct-tunnel.list" \
      direct-tunnel.list \
      direct-tunnel.list) || true
    if [ -n "$_afe_dtl" ] && \
       [ "$_afe_dtl" != "${CONF_DIR:-/etc/amnezia}/direct-tunnel.list" ]; then
      cp "$_afe_dtl" "${CONF_DIR:-/etc/amnezia}/direct-tunnel.list" 2>/dev/null || true
      chmod 0644 "${CONF_DIR:-/etc/amnezia}/direct-tunnel.list" 2>/dev/null || true
    else
      touch "${CONF_DIR:-/etc/amnezia}/direct-tunnel.list" 2>/dev/null || true
      chmod 0644 "${CONF_DIR:-/etc/amnezia}/direct-tunnel.list" 2>/dev/null || true
    fi
    amz_log "direct-tunnel.list seeded"
  else
    amz_log "direct-tunnel.list already present"
  fi

  # Seed /etc/amnezia/ru-dns-bypass.list (idempotent — never clobbers user edits on upgrade).
  if [ ! -f "${CONF_DIR:-/etc/amnezia}/ru-dns-bypass.list" ]; then
    _rdbl=$(resolve_dep \
      "${CONF_DIR:-/etc/amnezia}/ru-dns-bypass.list" \
      ru-dns-bypass.list \
      ru-dns-bypass.list) || true
    if [ -n "$_rdbl" ] && \
       [ "$_rdbl" != "${CONF_DIR:-/etc/amnezia}/ru-dns-bypass.list" ]; then
      cp "$_rdbl" "${CONF_DIR:-/etc/amnezia}/ru-dns-bypass.list" 2>/dev/null || true
      chmod 0644 "${CONF_DIR:-/etc/amnezia}/ru-dns-bypass.list" 2>/dev/null || true
    else
      touch "${CONF_DIR:-/etc/amnezia}/ru-dns-bypass.list" 2>/dev/null || true
      chmod 0644 "${CONF_DIR:-/etc/amnezia}/ru-dns-bypass.list" 2>/dev/null || true
    fi
    amz_log "ru-dns-bypass.list seeded"
  else
    amz_log "ru-dns-bypass.list already present"
  fi

  # Seed /etc/amnezia/autotunnel-exclude.list (idempotent — never clobbers user edits on upgrade).
  if [ ! -f "${CONF_DIR:-/etc/amnezia}/autotunnel-exclude.list" ]; then
    _atel=$(resolve_dep \
      "${CONF_DIR:-/etc/amnezia}/autotunnel-exclude.list" \
      autotunnel-exclude.list \
      autotunnel-exclude.list) || true
    if [ -n "$_atel" ] && \
       [ "$_atel" != "${CONF_DIR:-/etc/amnezia}/autotunnel-exclude.list" ]; then
      cp "$_atel" "${CONF_DIR:-/etc/amnezia}/autotunnel-exclude.list" 2>/dev/null || true
      chmod 0644 "${CONF_DIR:-/etc/amnezia}/autotunnel-exclude.list" 2>/dev/null || true
    else
      touch "${CONF_DIR:-/etc/amnezia}/autotunnel-exclude.list" 2>/dev/null || true
      chmod 0644 "${CONF_DIR:-/etc/amnezia}/autotunnel-exclude.list" 2>/dev/null || true
    fi
    amz_log "autotunnel-exclude.list seeded"
  else
    amz_log "autotunnel-exclude.list already present"
  fi

  # Install the daily amnezia-force-update cron entry (dedup, idempotent).
  _afe_cron=/etc/crontabs/root
  mkdir -p /etc/crontabs 2>/dev/null || true
  touch "$_afe_cron" 2>/dev/null || true
  sed -i '/# amnezia-force-update/d' "$_afe_cron" 2>/dev/null || true
  echo '15 3 * * * /usr/bin/amnezia-force-update >/dev/null 2>&1 # amnezia-force-update' \
    >> "$_afe_cron" 2>/dev/null || true
  amz_log "amnezia-force-update cron installed (daily 03:15)"

  # Install the every-2-min force-warm cron entry (dedup, idempotent).
  sed -i '/# amnezia-force-warm/d' "$_afe_cron" 2>/dev/null || true
  echo '*/2 * * * * /usr/bin/amnezia-force-warm >/dev/null 2>&1 # amnezia-force-warm' \
    >> "$_afe_cron" 2>/dev/null || true
  amz_log "amnezia-force-warm cron installed (every 2 min)"

  # Install the vitals logger to /usr/sbin/amnezia-blackbox.
  if [ ! -f /usr/sbin/amnezia-blackbox ]; then
    _bb_src=$(resolve_dep \
      /usr/sbin/amnezia-blackbox \
      amnezia-blackbox.sh \
      amnezia-blackbox.sh) || true
    if [ -n "$_bb_src" ] && [ "$_bb_src" != /usr/sbin/amnezia-blackbox ]; then
      cp "$_bb_src" /usr/sbin/amnezia-blackbox 2>/dev/null || true
      chmod 0755 /usr/sbin/amnezia-blackbox 2>/dev/null || true
      amz_log "amnezia-blackbox installed to /usr/sbin"
    else
      amz_log "WARN: amnezia-blackbox.sh not found; vitals logger will be missing"
    fi
  else
    amz_log "amnezia-blackbox already present (/usr/sbin)"
  fi

  # Install the per-minute blackbox cron entry (dedup, idempotent).
  sed -i '/# amnezia-blackbox/d' "$_afe_cron" 2>/dev/null || true
  echo '* * * * * /usr/sbin/amnezia-blackbox >/dev/null 2>&1 # amnezia-blackbox' \
    >> "$_afe_cron" 2>/dev/null || true
  amz_log "amnezia-blackbox cron installed (every minute)"

  /etc/init.d/cron enable 2>/dev/null || true
  /etc/init.d/cron reload 2>/dev/null || true

  # Run amnezia-force-update once on install (best-effort, backgrounded).
  if [ -x /usr/bin/amnezia-force-update ]; then
    ( /usr/bin/amnezia-force-update >/dev/null 2>&1 ) &
    amz_log "amnezia-force-update: initial run triggered (background)"
  else
    amz_log "WARN: amnezia-force-update not installed; skipping initial run"
  fi

  # Run amnezia-force-warm once on install (best-effort, backgrounded).
  if [ -x /usr/bin/amnezia-force-warm ]; then
    ( /usr/bin/amnezia-force-warm >/dev/null 2>&1 ) &
  fi
}

# ---------------------------------------------------------------------------
# --migrate [--dry-run]: ordered pbr-removal migration.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--migrate" ]; then
  _migrate_dry=0
  shift
  [ "${1:-}" = "--dry-run" ] && { _migrate_dry=1; shift; }

  MUST_TUNNEL_LIST="${MUST_TUNNEL_LIST:-/etc/amnezia/seed-must-tunnel.list}"

  migrate_from_pbr() {
    # -----------------------------------------------------------------------
    # GATE PHASE: classifier file is installed and ru4 set populated, but the
    # marking rules are NOT yet active and pbr stays intact — clean abort is
    # possible up to and including the gate check.
    # -----------------------------------------------------------------------

    # Step 1: install classifier file (no fw4 reload — not activated yet).
    if [ "$_migrate_dry" = 1 ]; then
      echo "install:classifier"
    else
      # Ensure both .nft fragments are in the stable read location before generating.
      mkdir -p /usr/share/amnezia/nftables.d 2>/dev/null || true
      export AMNEZIA_NFT_DIR=/usr/share/amnezia/nftables.d
      for _frag in 30-amnezia-classify.nft 30-amnezia-classify-direct.nft; do
        if [ ! -f "/usr/share/amnezia/nftables.d/${_frag}" ]; then
          _mig_frag_src=$(resolve_dep \
            "/usr/share/amnezia/nftables.d/${_frag}" \
            "$_frag" \
            "nftables.d/${_frag}") || true
          if [ -n "$_mig_frag_src" ] && \
             [ "$_mig_frag_src" != "/usr/share/amnezia/nftables.d/${_frag}" ]; then
            cp "$_mig_frag_src" "/usr/share/amnezia/nftables.d/${_frag}" 2>/dev/null || true
            chmod 0644 "/usr/share/amnezia/nftables.d/${_frag}" 2>/dev/null || true
          fi
        fi
      done
      LAN_DEV=$(uci -q get network.lan.device 2>/dev/null || echo br-lan)
      mkdir -p /etc/nftables.d 2>/dev/null || true
      _routing_mode=$(uci -q get amnezia.config.routing_mode 2>/dev/null || echo tunnel-default)
      if command -v routing_emit_classifier >/dev/null 2>&1; then
        _cls_tmp=$(mktemp /tmp/amnezia-cls-mig-XXXXXX 2>/dev/null || echo "/tmp/amnezia-cls-mig-$$")
        _cls_ok=0
        if routing_emit_classifier "$_routing_mode" "$LAN_DEV" > "$_cls_tmp" 2>/dev/null; then
          # Validate: non-empty and contains the expected chain declaration.
          if [ -s "$_cls_tmp" ] && grep -q "chain amnezia_classify" "$_cls_tmp" 2>/dev/null; then
            mv "$_cls_tmp" /etc/nftables.d/30-amnezia-classify.nft 2>/dev/null \
              || { rm -f "$_cls_tmp"; amz_log "ERROR: classifier mv failed; keeping existing file"; }
            amz_log "install:classifier (mode=${_routing_mode}, lan=${LAN_DEV})"
          else
            rm -f "$_cls_tmp"
            amz_log "ERROR: classifier gen produced empty/invalid output; keeping existing file"
          fi
        else
          rm -f "$_cls_tmp"
          amz_log "ERROR: routing_emit_classifier failed; keeping existing file"
        fi
        unset _cls_tmp
      else
        # Fallback for legacy staged installs without routing lib.
        _nft_src=$(resolve_dep \
          /etc/nftables.d/30-amnezia-classify.nft \
          30-amnezia-classify.nft \
          nftables.d/30-amnezia-classify.nft) || true
        if [ -n "$_nft_src" ] && [ "$_nft_src" != /etc/nftables.d/30-amnezia-classify.nft ]; then
          _cls_tmp=$(mktemp /tmp/amnezia-cls-mig-XXXXXX 2>/dev/null || echo "/tmp/amnezia-cls-mig-$$")
          if sed "s/@@LAN_IFNAME@@/$LAN_DEV/" "$_nft_src" > "$_cls_tmp" 2>/dev/null \
             && [ -s "$_cls_tmp" ] && grep -q "chain amnezia_classify" "$_cls_tmp" 2>/dev/null; then
            mv "$_cls_tmp" /etc/nftables.d/30-amnezia-classify.nft 2>/dev/null \
              || { rm -f "$_cls_tmp"; amz_log "ERROR: classifier mv failed; keeping existing file"; }
          else
            rm -f "$_cls_tmp"
            amz_log "ERROR: classifier fallback gen failed; keeping existing file"
          fi
          unset _cls_tmp
        elif [ -z "$_nft_src" ]; then
          amz_log "WARN: classifier fragment not found; skipping classifier install"
        fi
        amz_log "install:classifier (fallback sed)"
      fi
    fi

    # Step 2: declare @amnezia_ru4 in the live ruleset so that amnezia-ru-cidr
    # can populate it via `nft add element`.  Without this declaration the set
    # does not exist and every element add is silently discarded, leaving the
    # set empty and the gate below always aborting on real hardware.
    if [ "$_migrate_dry" != 1 ]; then
      nft add table inet fw4 2>/dev/null || true
      nft add set inet fw4 amnezia_ru4 \
        '{ type ipv4_addr; flags interval; auto-merge; }' 2>/dev/null || true
    fi

    # Step 3: install the amnezia-ru-cidr binary to /usr/bin/amnezia-ru-cidr,
    # then run it to populate @amnezia_ru4.
    #
    # FIX 2: The installer previously only *ran* the loader (via resolve_dep
    # which may find it in /tmp or $SCRIPT_DIR) but never INSTALLED it to
    # /usr/bin/amnezia-ru-cidr.  At boot the amnezia-ru-load init and the
    # firewall hotplug call /usr/bin/amnezia-ru-cidr directly; if it is absent
    # the RU set stays empty on every reboot.  Mirror the monitor self-install
    # pattern: copy to the installed path first, then run from there.
    if [ "$_migrate_dry" != 1 ]; then
      _rucidr_run=""
      if [ -f /usr/bin/amnezia-ru-cidr ]; then
        amz_log "amnezia-ru-cidr binary already present (/usr/bin)"
        _rucidr_run=/usr/bin/amnezia-ru-cidr
      else
        _rucidr_src=$(resolve_dep \
          /usr/bin/amnezia-ru-cidr \
          amnezia-ru-cidr.sh \
          amnezia-ru-cidr.sh) || true
        if [ -n "$_rucidr_src" ] && [ "$_rucidr_src" != /usr/bin/amnezia-ru-cidr ]; then
          cp "$_rucidr_src" /usr/bin/amnezia-ru-cidr 2>/dev/null || true
          chmod +x /usr/bin/amnezia-ru-cidr 2>/dev/null || true
          # Verify copy succeeded; fall back to source path if not (e.g. read-only /usr/bin).
          if [ -f /usr/bin/amnezia-ru-cidr ]; then
            amz_log "amnezia-ru-cidr installed to /usr/bin"
            _rucidr_run=/usr/bin/amnezia-ru-cidr
          else
            amz_log "WARN: could not install amnezia-ru-cidr to /usr/bin; using source path"
            _rucidr_run="$_rucidr_src"
          fi
        elif [ -z "$_rucidr_src" ]; then
          amz_log "WARN: amnezia-ru-cidr source not found; RU CIDR loader will be missing"
        fi
      fi
      # Populate @amnezia_ru4 with the binary we just installed (or the source fallback).
      if [ -n "$_rucidr_run" ]; then
        sh "$_rucidr_run" 2>/dev/null || true
      else
        amz_log "WARN: amnezia-ru-cidr not available; skipping RU CIDR populate"
      fi
    fi

    # Step 3b: install/refresh the weekly RU CIDR update cron entry.
    # FIX 3: The old pbr-era installer wrote a cron line pointing at the
    # defunct /usr/bin/awg-ru-update.  Replace any legacy or duplicate entry
    # with a single, deduplicated line that calls /usr/bin/amnezia-ru-cidr.
    if [ "$_migrate_dry" != 1 ]; then
      _cron_file=/etc/crontabs/root
      mkdir -p /etc/crontabs 2>/dev/null || true
      touch "$_cron_file" 2>/dev/null || true
      # Remove any pre-existing lines matching the old or new tag so re-running
      # the installer is always idempotent (no duplicates).
      sed -i '/awg-ru-update/d; /# amnezia-ru-update/d; /# amnezia-pbr/d' \
        "$_cron_file" 2>/dev/null || true
      # Add a single weekly entry (Sunday 04:30) using the native updater.
      echo '30 4 * * 0 /usr/bin/amnezia-ru-cidr >/dev/null 2>&1 # amnezia-ru-update' \
        >> "$_cron_file" 2>/dev/null || true
      /etc/init.d/cron enable 2>/dev/null || true
      /etc/init.d/cron reload 2>/dev/null || true
      amz_log "amnezia-ru-update cron installed (weekly Sun 04:30)"
    fi

    # Step 4: gate on @amnezia_ru4 being non-empty before touching dnsmasq or pbr.
    # If this gate fails we roll back only the classifier; dnsmasq is untouched.
    _ru4_count=0
    _ru4_out=$(nft list set inet fw4 amnezia_ru4 2>/dev/null || true)
    if echo "$_ru4_out" | grep -q 'elements'; then
      _ru4_count=$(echo "$_ru4_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | wc -l | tr -d ' ')
    fi
    # NFT_FAKE_RU4_COUNT is a test-only override for the nft stub response.
    _ru4_abort=0
    if [ -z "${NFT_FAKE_RU4_COUNT:-}" ] && [ "$_ru4_count" -le 0 ]; then
      _ru4_abort=1
    fi
    if [ -n "${NFT_FAKE_RU4_COUNT:-}" ] && [ "${NFT_FAKE_RU4_COUNT}" -le 0 ]; then
      _ru4_abort=1
    fi
    if [ "$_ru4_abort" = 1 ]; then
      echo "ABORT:ru4-empty"
      # Roll back: remove classifier and the set declaration so pbr does not
      # run alongside the new classifier.  dnsmasq has NOT been repointed yet.
      if [ "$_migrate_dry" != 1 ]; then
        nft delete set inet fw4 amnezia_ru4 2>/dev/null || true
        rm -f /etc/nftables.d/30-amnezia-classify.nft 2>/dev/null || true
      fi
      return 1
    fi

    # -----------------------------------------------------------------------
    # CUTOVER PHASE: gate passed — wire the full failover stack, then cut over.
    # -----------------------------------------------------------------------

    # Step 5: install rt_tables (mirror first_install_wiring step 1).
    if [ "$_migrate_dry" = 1 ]; then
      amz_log "install:rt_tables"
    else
      mkdir -p /etc/iproute2/rt_tables.d 2>/dev/null || true
      _rtt_src=$(resolve_dep \
        /etc/iproute2/rt_tables.d/amnezia.conf \
        iproute2-amnezia-rt_tables.conf \
        iproute2-amnezia-rt_tables.conf) || true
      if [ -n "$_rtt_src" ] && [ "$_rtt_src" != /etc/iproute2/rt_tables.d/amnezia.conf ]; then
        cp "$_rtt_src" /etc/iproute2/rt_tables.d/amnezia.conf 2>/dev/null || true
      elif [ -z "$_rtt_src" ]; then
        amz_log "WARN: iproute2-amnezia-rt_tables.conf not found; skipping rt_tables install"
      fi
      amz_log "install:rt_tables"
    fi

    # Step 6: install ip rules (fwmark→table mapping).
    if [ "$_migrate_dry" != 1 ]; then
      routing_install_rules
    fi

    # Step 7: fail-closed blackhole default routes BEFORE any traffic can be marked.
    if [ "$_migrate_dry" != 1 ]; then
      routing_set_sticky_default ""
      routing_set_pool_default ""
    fi

    # Step 8: enumerate enabled tunnels (needed for bring-up + firewall steps).
    # Compute early so the list is available for all remaining steps.
    _mig_tunnels=""
    if [ "$_migrate_dry" != 1 ]; then
      _mig_tunnels=$(uci show amnezia 2>/dev/null \
        | awk -F'[.=]' '/\.enabled='"'"'?1/ && $2 ~ /^awg[0-9]/{print $2}' | tr '\n' ' ' | sed 's/ $//')
      if [ -z "$_mig_tunnels" ] && [ -n "${UCI_FAKE_TUNNELS:-}" ]; then
        _mig_tunnels="$UCI_FAKE_TUNNELS"
      fi
      # Apply each enabled tunnel's network UCI and bring it up.
      for _tunnel in $_mig_tunnels; do
        _tcf="${CONF_DIR:-/etc/amnezia}/${_tunnel}.conf"
        if [ -f "$_tcf" ]; then
          # Use _gen_rc=0; ...|| _gen_rc=$? to capture failure under set -eu
          # without triggering the shell's -e exit on the gen_tunnel_uci line.
          _gen_rc=0
          gen_tunnel_uci "$_tunnel" "$_tcf" > /tmp/amnezia-tunnel-uci.$$ 2>/dev/null \
            || _gen_rc=$?
          if [ "$_gen_rc" -ne 0 ]; then
            amz_log "WARN: conf parse failed for $_tunnel (rc=$_gen_rc), skipping UCI apply"
            rm -f /tmp/amnezia-tunnel-uci.$$
          else
            uci batch < /tmp/amnezia-tunnel-uci.$$ 2>/dev/null || true
            rm -f /tmp/amnezia-tunnel-uci.$$
            uci commit network 2>/dev/null || true
            ifup "$_tunnel" 2>/dev/null || true
          fi
        fi
      done
    fi

    # Step 9: install ru-load init + hotplug (mirror first_install_wiring step 6).
    if [ "$_migrate_dry" != 1 ]; then
      if [ -f /etc/init.d/amnezia-ru-load ]; then
        amz_log "amnezia-ru-load init already present (.ipk path)"
        /etc/init.d/amnezia-ru-load enable 2>/dev/null || true
      else
        _ruload_src=$(resolve_dep \
          /etc/init.d/amnezia-ru-load \
          amnezia-ru-load.init \
          amnezia-ru-load.init) || true
        if [ -n "$_ruload_src" ] && [ "$_ruload_src" != /etc/init.d/amnezia-ru-load ]; then
          cp "$_ruload_src" /etc/init.d/amnezia-ru-load 2>/dev/null || true
          chmod +x /etc/init.d/amnezia-ru-load 2>/dev/null || true
          /etc/init.d/amnezia-ru-load enable 2>/dev/null || true
        elif [ -z "$_ruload_src" ]; then
          amz_log "WARN: amnezia-ru-load.init not found; RU CIDR load on boot disabled"
        fi
      fi
      if [ -f /etc/hotplug.d/firewall/99-amnezia-ru-load ]; then
        amz_log "99-amnezia-ru-load hotplug already present (.ipk path)"
      else
        _hotplug_src=$(resolve_dep \
          /etc/hotplug.d/firewall/99-amnezia-ru-load \
          99-amnezia-ru-load.hotplug \
          99-amnezia-ru-load.hotplug) || true
        if [ -n "$_hotplug_src" ] && [ "$_hotplug_src" != /etc/hotplug.d/firewall/99-amnezia-ru-load ]; then
          mkdir -p /etc/hotplug.d/firewall 2>/dev/null || true
          cp "$_hotplug_src" /etc/hotplug.d/firewall/99-amnezia-ru-load 2>/dev/null || true
          chmod +x /etc/hotplug.d/firewall/99-amnezia-ru-load 2>/dev/null || true
        elif [ -z "$_hotplug_src" ]; then
          amz_log "WARN: 99-amnezia-ru-load.hotplug not found; firewall reload trigger disabled"
        fi
      fi
    fi

    # Step 10: self-install the failover monitor daemon + init, then enable + start.
    # The .ipk path pre-installs these; the install.sh/staged-tree path does not.
    # Mirror the ru-load pattern: resolve binary + init from staged tree and copy
    # to their installed paths before calling enable/start.
    if [ "$_migrate_dry" != 1 ]; then
      # Install the monitor binary to /usr/sbin/amnezia-failover.
      if [ -f /usr/sbin/amnezia-failover ]; then
        amz_log "amnezia-failover binary already present (.ipk path)"
      else
        _failover_bin=$(resolve_dep \
          /usr/sbin/amnezia-failover \
          amnezia-failover \
          amnezia-failover) || true
        if [ -n "$_failover_bin" ] && [ "$_failover_bin" != /usr/sbin/amnezia-failover ]; then
          cp "$_failover_bin" /usr/sbin/amnezia-failover 2>/dev/null || true
          chmod +x /usr/sbin/amnezia-failover 2>/dev/null || true
        elif [ -z "$_failover_bin" ]; then
          amz_log "WARN: amnezia-failover binary not found; monitor will not run"
        fi
      fi
      # Install the init script to /etc/init.d/amnezia-failover.
      if [ -f /etc/init.d/amnezia-failover ]; then
        amz_log "amnezia-failover init already present (.ipk path)"
      else
        _failover_init=$(resolve_dep \
          /etc/init.d/amnezia-failover \
          amnezia-failover.init \
          amnezia-failover.init) || true
        if [ -n "$_failover_init" ] && [ "$_failover_init" != /etc/init.d/amnezia-failover ]; then
          cp "$_failover_init" /etc/init.d/amnezia-failover 2>/dev/null || true
          chmod +x /etc/init.d/amnezia-failover 2>/dev/null || true
        elif [ -z "$_failover_init" ]; then
          amz_log "WARN: amnezia-failover.init not found; monitor cannot be enabled"
        fi
      fi
      echo "amnezia-failover:enable" >> "${STUB_LOG:-/dev/null}"
      /etc/init.d/amnezia-failover enable 2>/dev/null || true
      ( sleep 1 && /etc/init.d/amnezia-failover start ) &
    fi

    # Step 10b: wire the full force-list engine (helpers, hotplug, boot-init,
    # seed, cron, initial populate).  Dry-run-guarded via _amz_wire_force_engine.
    # H3/H2: migrate_from_pbr was previously missing this wiring entirely.
    _amz_wire_force_engine "$_migrate_dry"

    # Step 11: repoint dnsmasq to amnezia nftsets (only reached when ru4 gate passes).
    if [ "$_migrate_dry" = 1 ]; then
      echo "repoint:dnsmasq"
    else
      _dns_helper=$(resolve_dep \
        /usr/sbin/configure-dnsmasq-amnezia \
        configure-dnsmasq-amnezia.sh \
        configure-dnsmasq-amnezia.sh) || true
      if [ -n "$_dns_helper" ]; then
        sh "$_dns_helper"
      else
        amz_log "WARN: configure-dnsmasq-amnezia not found; skipping dnsmasq repoint"
      fi
    fi

    # Step 12: must-tunnel→sticky migration.
    # In dry-run: delete amnezia_sticky explicitly so idempotency holds (the real path
    # relies on configure-dnsmasq-amnezia.sh having already done the delete+recreate).
    if [ "$_migrate_dry" = 1 ]; then
      uci -q delete dhcp.amnezia_sticky 2>/dev/null || true
    fi
    if [ -f "$MUST_TUNNEL_LIST" ]; then
      while IFS= read -r _dom; do
        case "$_dom" in ''|\#*) continue ;; esac
        uci add_list dhcp.amnezia_sticky.domain="$_dom"
      done < "$MUST_TUNNEL_LIST"
    fi

    # Step 13: activate the classifier via fw4 reload BEFORE removing pbr so
    # there is a brief both-active overlap (both route to VPN) rather than a
    # neither-active gap (which would leak LAN traffic to WAN cleartext).
    #
    # FIX 1: Disable flow offloading BEFORE fw4 reload.
    # Hardware/software flow offloading bypasses the kernel's fwmark policy
    # routing: offloaded flows are steered in the fast path and never consult
    # ip rules, so fwmark-tagged packets intended for the VPN tunnel are
    # silently forwarded via WAN instead.  pbr-based routing requires that all
    # forwarded LAN traffic goes through the slow path where nftables can set
    # fwmarks.  Disable both offload knobs here, idempotently, before the
    # reload that activates the classifier.
    if [ "$_migrate_dry" != 1 ]; then
      uci set firewall.@defaults[0].flow_offloading='0'
      uci set firewall.@defaults[0].flow_offloading_hw='0'
      uci commit firewall
      fw4 reload >/dev/null 2>&1 || /etc/init.d/firewall reload >/dev/null 2>&1 || true
    fi

    # Step 14: remove pbr (AFTER classifier activated at step 13).
    if [ "$_migrate_dry" = 1 ]; then
      echo "remove:pbr"
    else
      /etc/init.d/pbr stop 2>/dev/null || true
      /etc/init.d/pbr disable 2>/dev/null || true
      # --force-depends: an older amnezia-pbr .ipk recorded a spurious
      # "Depends: pbr" in opkg metadata, so a plain `opkg remove pbr` no-ops
      # ("No packages removed"). Force past it. Do NOT discard opkg's output —
      # surface it so a real removal failure is visible in the cutover log.
      opkg remove pbr luci-app-pbr --force-depends 2>&1 || true
    fi

    # Step 14b: clean pbr remnants left after package removal.
    # FIX 4: Remove config/data files that opkg does not clean up and that
    # would otherwise linger and confuse diagnostics or trigger pbr restarts
    # if the package is ever re-installed.
    if [ "$_migrate_dry" != 1 ]; then
      # /etc/config/pbr — UCI config file; opkg marks it as a conffile and
      # intentionally leaves it behind on removal so user edits survive.
      rm -f /etc/config/pbr 2>/dev/null || true
      # /etc/pbr.d/ — pbr globs this dir for user rules; remnants here would
      # break a fresh pbr install.
      rm -rf /etc/pbr.d/ 2>/dev/null || true
      # Stale dnsmasq ipset section that pbr wrote via UCI.
      uci -q delete dhcp.pbr_ru_tld 2>/dev/null || true
      uci commit dhcp 2>/dev/null || true
      /etc/init.d/dnsmasq reload 2>/dev/null || true
      # nftables fragment left by the old pbr RU-TLD ipset approach.
      rm -f /etc/nftables.d/15-pbr-ru-tld4.nft 2>/dev/null || true
    fi

    # Step 15: apply firewall zones + disable LAN IPv6 (real path only).
    # FIX 1 (first-install path): flow offloading is also disabled here so that
    # a fresh install that never had pbr also gets the offload knobs cleared
    # before routing_firewall_apply fires its fw4 reload.
    if [ "$_migrate_dry" != 1 ]; then
      [ -n "$_mig_tunnels" ] && routing_firewall_apply "$_mig_tunnels"
      routing_disable_lan_v6
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
      mkdir -p /etc/iproute2/rt_tables.d 2>/dev/null || true
      _rtt_src=$(resolve_dep \
        /etc/iproute2/rt_tables.d/amnezia.conf \
        iproute2-amnezia-rt_tables.conf \
        iproute2-amnezia-rt_tables.conf) || true
      if [ -n "$_rtt_src" ] && [ "$_rtt_src" != /etc/iproute2/rt_tables.d/amnezia.conf ]; then
        cp "$_rtt_src" /etc/iproute2/rt_tables.d/amnezia.conf 2>/dev/null || true
      elif [ -z "$_rtt_src" ]; then
        amz_log "WARN: iproute2-amnezia-rt_tables.conf not found; skipping rt_tables install"
      fi
      amz_log "install:rt_tables"
    fi
    # 2. ip rules
    routing_install_rules
    # 2b. Install force-list helpers, hotplug, and nft fragments to stable locations.
    # Must run before step 3 (classifier generation reads from /usr/share/amnezia/nftables.d/).
    if [ "$_fi_dry" != 1 ]; then
      # Install both .nft fragments to stable read location for routing_emit_classifier.
      # NOTE: helpers+hotplug+boot-init+seed+cron are wired via _amz_wire_force_engine
      # below (step 8), after the failover monitor is started.  The .nft fragments must
      # come here — before classifier generation in step 3 — so the generator can read them.
      mkdir -p /usr/share/amnezia/nftables.d 2>/dev/null || true
      export AMNEZIA_NFT_DIR=/usr/share/amnezia/nftables.d
      for _frag in 30-amnezia-classify.nft 30-amnezia-classify-direct.nft; do
        if [ ! -f "/usr/share/amnezia/nftables.d/${_frag}" ]; then
          _frag_src=$(resolve_dep \
            "/usr/share/amnezia/nftables.d/${_frag}" \
            "$_frag" \
            "nftables.d/${_frag}") || true
          if [ -n "$_frag_src" ] && \
             [ "$_frag_src" != "/usr/share/amnezia/nftables.d/${_frag}" ]; then
            cp "$_frag_src" "/usr/share/amnezia/nftables.d/${_frag}" 2>/dev/null || true
            chmod 0644 "/usr/share/amnezia/nftables.d/${_frag}" 2>/dev/null || true
          elif [ -z "$_frag_src" ]; then
            amz_log "WARN: classifier fragment ${_frag} not found"
          fi
        fi
      done
      amz_log "install:classifier-fragments"
    fi
    # 3. classifier generation (replaces static .nft copy — uses routing_emit_classifier).
    if [ "$_fi_dry" = 1 ]; then
      amz_log "install:classifier"
      echo "install:classifier" >> "${STUB_LOG:-/dev/null}"
    else
      LAN_DEV=$(uci -q get network.lan.device 2>/dev/null || echo br-lan)
      mkdir -p /etc/nftables.d 2>/dev/null || true
      _routing_mode=$(uci -q get amnezia.config.routing_mode 2>/dev/null || echo tunnel-default)
      if command -v routing_emit_classifier >/dev/null 2>&1; then
        _cls_tmp=$(mktemp /tmp/amnezia-cls-fi-XXXXXX 2>/dev/null || echo "/tmp/amnezia-cls-fi-$$")
        if routing_emit_classifier "$_routing_mode" "$LAN_DEV" > "$_cls_tmp" 2>/dev/null; then
          # Validate: non-empty and contains the expected chain declaration.
          if [ -s "$_cls_tmp" ] && grep -q "chain amnezia_classify" "$_cls_tmp" 2>/dev/null; then
            mv "$_cls_tmp" /etc/nftables.d/30-amnezia-classify.nft 2>/dev/null \
              || { rm -f "$_cls_tmp"; amz_log "ERROR: classifier mv failed; keeping existing file"; }
            amz_log "install:classifier (mode=${_routing_mode}, lan=${LAN_DEV})"
          else
            rm -f "$_cls_tmp"
            amz_log "ERROR: classifier gen produced empty/invalid output; keeping existing file"
          fi
        else
          rm -f "$_cls_tmp"
          amz_log "ERROR: routing_emit_classifier failed; keeping existing file"
        fi
        unset _cls_tmp
      else
        amz_log "WARN: routing_emit_classifier not available; skipping classifier install"
      fi
    fi
    # 4. dnsmasq UCI ipset
    _dns_helper=$(resolve_dep \
      /usr/sbin/configure-dnsmasq-amnezia \
      configure-dnsmasq-amnezia.sh \
      configure-dnsmasq-amnezia.sh) || true
    if [ -n "$_dns_helper" ]; then
      sh "$_dns_helper"
    else
      amz_log "WARN: configure-dnsmasq-amnezia not found; skipping dnsmasq ipset config"
    fi
    # 5. tunnel UCI apply + bring-up + firewall zones + disable LAN IPv6 (real path only).
    if [ "$_fi_dry" != 1 ]; then
      _fi_tunnels=$(uci show amnezia 2>/dev/null \
        | awk -F'[.=]' '/\.enabled='"'"'?1/ && $2 ~ /^awg[0-9]/{print $2}' | tr '\n' ' ' | sed 's/ $//')
      if [ -z "$_fi_tunnels" ] && [ -n "${UCI_FAKE_TUNNELS:-}" ]; then
        _fi_tunnels="$UCI_FAKE_TUNNELS"
      fi
      # Apply each enabled tunnel's network UCI and bring it up.
      # Guard: validate parse_awg_conf succeeded (gen_tunnel_uci returns non-zero
      # on incomplete conf) BEFORE piping to uci batch; on parse failure log and
      # skip the tunnel so a malformed/truncated .conf never applies a partial UCI
      # batch that leaves the config in an inconsistent state.
      for _tunnel in $_fi_tunnels; do
        _tcf="${CONF_DIR:-/etc/amnezia}/${_tunnel}.conf"
        if [ -f "$_tcf" ]; then
          # Use _gen_rc=0; ...|| _gen_rc=$? to capture failure under set -eu
          # without triggering the shell's -e exit on the gen_tunnel_uci line.
          _gen_rc=0
          gen_tunnel_uci "$_tunnel" "$_tcf" > /tmp/amnezia-tunnel-uci.$$ 2>/dev/null \
            || _gen_rc=$?
          if [ "$_gen_rc" -ne 0 ]; then
            amz_log "WARN: conf parse failed for $_tunnel (rc=$_gen_rc), skipping UCI apply"
            rm -f /tmp/amnezia-tunnel-uci.$$
          else
            uci batch < /tmp/amnezia-tunnel-uci.$$ 2>/dev/null || true
            rm -f /tmp/amnezia-tunnel-uci.$$
            uci commit network 2>/dev/null || true
            ifup "$_tunnel" 2>/dev/null || true
          fi
        fi
      done
      # FIX 1: Disable flow offloading before routing_firewall_apply fires fw4 reload.
      # HW/SW flow offloading bypasses fwmark policy routing; forwarded LAN traffic
      # through the tunnel silently follows WAN instead of the VPN table.  Both knobs
      # must be off for pbr-based fwmark routing to work correctly.
      uci set firewall.@defaults[0].flow_offloading='0'
      uci set firewall.@defaults[0].flow_offloading_hw='0'
      uci commit firewall
      [ -n "$_fi_tunnels" ] && routing_firewall_apply "$_fi_tunnels"
      routing_disable_lan_v6
    fi
    # 6. RU boot loader: install init + firewall hotplug hook (real path only).
    if [ "$_fi_dry" != 1 ]; then
      # If .ipk already installed the init script, it's already enabled by procd; skip copy.
      if [ -f /etc/init.d/amnezia-ru-load ]; then
        amz_log "amnezia-ru-load init already present (.ipk path)"
        /etc/init.d/amnezia-ru-load enable 2>/dev/null || true
      else
        _ruload_src=$(resolve_dep \
          /etc/init.d/amnezia-ru-load \
          amnezia-ru-load.init \
          amnezia-ru-load.init) || true
        if [ -n "$_ruload_src" ] && [ "$_ruload_src" != /etc/init.d/amnezia-ru-load ]; then
          cp "$_ruload_src" /etc/init.d/amnezia-ru-load 2>/dev/null || true
          chmod +x /etc/init.d/amnezia-ru-load 2>/dev/null || true
          /etc/init.d/amnezia-ru-load enable 2>/dev/null || true
        elif [ -z "$_ruload_src" ]; then
          amz_log "WARN: amnezia-ru-load.init not found; RU CIDR load on boot disabled"
        fi
      fi
      # Hotplug: skip if .ipk already installed it.
      if [ -f /etc/hotplug.d/firewall/99-amnezia-ru-load ]; then
        amz_log "99-amnezia-ru-load hotplug already present (.ipk path)"
      else
        _hotplug_src=$(resolve_dep \
          /etc/hotplug.d/firewall/99-amnezia-ru-load \
          99-amnezia-ru-load.hotplug \
          99-amnezia-ru-load.hotplug) || true
        if [ -n "$_hotplug_src" ] && [ "$_hotplug_src" != /etc/hotplug.d/firewall/99-amnezia-ru-load ]; then
          mkdir -p /etc/hotplug.d/firewall 2>/dev/null || true
          cp "$_hotplug_src" /etc/hotplug.d/firewall/99-amnezia-ru-load 2>/dev/null || true
          chmod +x /etc/hotplug.d/firewall/99-amnezia-ru-load 2>/dev/null || true
        elif [ -z "$_hotplug_src" ]; then
          amz_log "WARN: 99-amnezia-ru-load.hotplug not found; firewall reload trigger disabled"
        fi
      fi
    fi
    # 6b. Install /usr/bin/amnezia-ru-cidr binary + populate @amnezia_ru4 + set cron.
    # FIX 2: The loader binary must be installed to /usr/bin/amnezia-ru-cidr so
    # the amnezia-ru-load init and firewall hotplug can find it at boot.
    # FIX 3: Install/refresh the weekly RU CIDR update cron entry.
    if [ "$_fi_dry" != 1 ]; then
      _rucidr_run_fi=""
      if [ -f /usr/bin/amnezia-ru-cidr ]; then
        amz_log "amnezia-ru-cidr binary already present (/usr/bin)"
        _rucidr_run_fi=/usr/bin/amnezia-ru-cidr
      else
        _rucidr_src=$(resolve_dep \
          /usr/bin/amnezia-ru-cidr \
          amnezia-ru-cidr.sh \
          amnezia-ru-cidr.sh) || true
        if [ -n "$_rucidr_src" ] && [ "$_rucidr_src" != /usr/bin/amnezia-ru-cidr ]; then
          cp "$_rucidr_src" /usr/bin/amnezia-ru-cidr 2>/dev/null || true
          chmod +x /usr/bin/amnezia-ru-cidr 2>/dev/null || true
          # Verify copy succeeded; fall back to source path if not (e.g. read-only /usr/bin).
          if [ -f /usr/bin/amnezia-ru-cidr ]; then
            amz_log "amnezia-ru-cidr installed to /usr/bin"
            _rucidr_run_fi=/usr/bin/amnezia-ru-cidr
          else
            amz_log "WARN: could not install amnezia-ru-cidr to /usr/bin; using source path"
            _rucidr_run_fi="$_rucidr_src"
          fi
        elif [ -z "$_rucidr_src" ]; then
          amz_log "WARN: amnezia-ru-cidr source not found; RU CIDR loader will be missing"
        fi
      fi
      # Populate @amnezia_ru4 for the initial live set.
      if [ -n "$_rucidr_run_fi" ]; then
        # Declare the set first so element adds don't fail if fw4 hasn't loaded yet.
        nft add table inet fw4 2>/dev/null || true
        nft add set inet fw4 amnezia_ru4 \
          '{ type ipv4_addr; flags interval; auto-merge; }' 2>/dev/null || true
        sh "$_rucidr_run_fi" 2>/dev/null || true
      else
        amz_log "WARN: amnezia-ru-cidr not available; RU CIDR set will be empty"
      fi
      # Cron: remove old/duplicate entries, install a single weekly entry.
      _cron_file=/etc/crontabs/root
      mkdir -p /etc/crontabs 2>/dev/null || true
      touch "$_cron_file" 2>/dev/null || true
      sed -i '/awg-ru-update/d; /# amnezia-ru-update/d; /# amnezia-pbr/d' \
        "$_cron_file" 2>/dev/null || true
      echo '30 4 * * 0 /usr/bin/amnezia-ru-cidr >/dev/null 2>&1 # amnezia-ru-update' \
        >> "$_cron_file" 2>/dev/null || true
      /etc/init.d/cron enable 2>/dev/null || true
      /etc/init.d/cron reload 2>/dev/null || true
      amz_log "amnezia-ru-update cron installed (weekly Sun 04:30)"
    fi
    # 7. self-install the failover monitor daemon + init, then enable + start.
    # Mirror the ru-load pattern: resolve binary + init from staged tree and copy
    # to their installed paths before calling enable/start.
    if [ "$_fi_dry" = 1 ]; then
      echo "/etc/init.d/amnezia-failover enable" >> "${STUB_LOG:-/dev/null}"
    else
      # Install the monitor binary to /usr/sbin/amnezia-failover.
      if [ -f /usr/sbin/amnezia-failover ]; then
        amz_log "amnezia-failover binary already present (.ipk path)"
      else
        _failover_bin=$(resolve_dep \
          /usr/sbin/amnezia-failover \
          amnezia-failover \
          amnezia-failover) || true
        if [ -n "$_failover_bin" ] && [ "$_failover_bin" != /usr/sbin/amnezia-failover ]; then
          cp "$_failover_bin" /usr/sbin/amnezia-failover 2>/dev/null || true
          chmod +x /usr/sbin/amnezia-failover 2>/dev/null || true
        elif [ -z "$_failover_bin" ]; then
          amz_log "WARN: amnezia-failover binary not found; monitor will not run"
        fi
      fi
      # Install the init script to /etc/init.d/amnezia-failover.
      if [ -f /etc/init.d/amnezia-failover ]; then
        amz_log "amnezia-failover init already present (.ipk path)"
      else
        _failover_init=$(resolve_dep \
          /etc/init.d/amnezia-failover \
          amnezia-failover.init \
          amnezia-failover.init) || true
        if [ -n "$_failover_init" ] && [ "$_failover_init" != /etc/init.d/amnezia-failover ]; then
          cp "$_failover_init" /etc/init.d/amnezia-failover 2>/dev/null || true
          chmod +x /etc/init.d/amnezia-failover 2>/dev/null || true
        elif [ -z "$_failover_init" ]; then
          amz_log "WARN: amnezia-failover.init not found; monitor cannot be enabled"
        fi
      fi
      /etc/init.d/amnezia-failover enable 2>/dev/null || true
      ( sleep 1 && /etc/init.d/amnezia-failover start ) &
    fi
    # 8. Wire the full force-list engine: helpers, hotplug, boot-init, seed,
    # daily cron, and initial populate run (shared with migrate_from_pbr).
    # H3/H2: _amz_wire_force_engine is defined at the top of the --migrate
    # dispatch section and is always available when this code runs.
    _amz_wire_force_engine "$_fi_dry"
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
opkg install conntrack-tools 2>/dev/null || true

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

# --- Steps 2+3: failover stack (classifier + ip rules + monitor + RU bypass) ---
# Replaces the old pbr/pbr.d-based Steps 2+3.  Detects whether this is a
# fresh install (pbr absent) or a pbr-to-failover upgrade, and dispatches to
# the appropriate wiring function.  Both functions live at the top of this
# script (under --first-install / --migrate sections).
log "Step 2: dnsmasq-full"
if _dnsmasq=$(find_helper install-dnsmasq-full); then
  $_dnsmasq 2>/dev/null || fail "dnsmasq-full install"
else
  command -v dnsmasq >/dev/null 2>&1 || fail "dnsmasq missing and no installer helper"
fi
need_dns || fail "DNS broken after dnsmasq-full"
ok "2 dnsmasq_full"

if [ "$STEPS" -lt 3 ]; then
  log "DEPLOY_DONE steps=$STEPS"
  exit 0
fi

log "Step 3: failover stack wiring"
if /etc/init.d/pbr status >/dev/null 2>&1 || opkg list-installed 2>/dev/null | grep -q '^pbr '; then
  # pbr is still present: run ordered migration so RU sets are live before pbr is removed.
  log "Step 3: pbr detected — running migrate_from_pbr"
  # Inline the migrate_from_pbr logic using the flags the top-of-script block accepts.
  # Re-exec ourselves with --migrate so the already-defined function runs cleanly,
  # inheriting SCRIPT_DIR, CONF_DIR, and all sourced libs.
  CONF_DIR="${CONF_DIR:-/etc/amnezia}" sh "$0" --migrate || fail "migrate_from_pbr failed"
else
  # Fresh install: wire classifier, ip rules, monitor, firewall zones.
  log "Step 3: no pbr found — running first_install_wiring"
  CONF_DIR="${CONF_DIR:-/etc/amnezia}" sh "$0" --first-install || fail "first_install_wiring failed"
fi

/etc/init.d/firewall reload 2>/dev/null || true

ok "3 failover_wiring"
log "DEPLOY_DONE steps=$STEPS"
