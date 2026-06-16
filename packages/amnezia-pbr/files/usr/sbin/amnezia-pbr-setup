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
  [ -n "${AWG_S1:-}"   ] && echo "set network.${_tname}.awg_s1=${AWG_S1}"
  [ -n "${AWG_S2:-}"   ] && echo "set network.${_tname}.awg_s2=${AWG_S2}"
  [ -n "${AWG_S3:-}"   ] && echo "set network.${_tname}.awg_s3=${AWG_S3}"
  [ -n "${AWG_S4:-}"   ] && echo "set network.${_tname}.awg_s4=${AWG_S4}"
  [ -n "${AWG_H1:-}"   ] && echo "set network.${_tname}.awg_h1=${AWG_H1}"
  [ -n "${AWG_H2:-}"   ] && echo "set network.${_tname}.awg_h2=${AWG_H2}"
  [ -n "${AWG_H3:-}"   ] && echo "set network.${_tname}.awg_h3=${AWG_H3}"
  [ -n "${AWG_H4:-}"   ] && echo "set network.${_tname}.awg_h4=${AWG_H4}"
  [ -n "${AWG_I1:-}"   ] && echo "set network.${_tname}.awg_i1='${AWG_I1}'"
  [ -n "${AWG_I2:-}"   ] && echo "set network.${_tname}.awg_i2='${AWG_I2}'"
  [ -n "${AWG_I3:-}"   ] && echo "set network.${_tname}.awg_i3='${AWG_I3}'"
  [ -n "${AWG_I4:-}"   ] && echo "set network.${_tname}.awg_i4='${AWG_I4}'"
  [ -n "${AWG_I5:-}"   ] && echo "set network.${_tname}.awg_i5='${AWG_I5}'"
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
    | awk -F'[.=]' '/\.enabled='"'"'?1/{print $2}' | tr '\n' ' ' | sed 's/ $//')
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
      LAN_DEV=$(uci get network.lan.device 2>/dev/null || echo br-lan)
      mkdir -p /etc/nftables.d 2>/dev/null || true
      # If the .ipk already installed the classifier, skip copying (it's up-to-date).
      if [ -f /etc/nftables.d/30-amnezia-classify.nft ]; then
        amz_log "install:classifier (already present, skipping copy)"
      else
        _nft_src=$(resolve_dep \
          /etc/nftables.d/30-amnezia-classify.nft \
          30-amnezia-classify.nft \
          nftables.d/30-amnezia-classify.nft) || true
        if [ -n "$_nft_src" ] && [ "$_nft_src" != /etc/nftables.d/30-amnezia-classify.nft ]; then
          sed "s/@@LAN_IFNAME@@/$LAN_DEV/" "$_nft_src" \
            > /etc/nftables.d/30-amnezia-classify.nft 2>/dev/null || true
        elif [ -z "$_nft_src" ]; then
          amz_log "WARN: 30-amnezia-classify.nft not found; skipping classifier install"
        fi
      fi
      amz_log "install:classifier"
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

    # Step 3: populate @amnezia_ru4 from persist before the gate check.
    # Moved before dnsmasq repoint so that an abort here leaves dnsmasq
    # still pointing at the old pbr nftsets — no partial-migration state.
    if [ "$_migrate_dry" != 1 ]; then
      _rucidr=$(resolve_dep \
        /usr/bin/amnezia-ru-cidr \
        amnezia-ru-cidr.sh \
        amnezia-ru-cidr.sh) || true
      if [ -n "$_rucidr" ]; then
        sh "$_rucidr" 2>/dev/null || true
      else
        amz_log "WARN: amnezia-ru-cidr not found; skipping RU CIDR populate"
      fi
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
        | awk -F'[.=]' '/\.enabled='"'"'?1/{print $2}' | tr '\n' ' ' | sed 's/ $//')
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
    if [ "$_migrate_dry" != 1 ]; then
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

    # Step 15: apply firewall zones + disable LAN IPv6 (real path only).
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
    # 3. classifier (with LAN ifname substitution)
    if [ "$_fi_dry" = 1 ]; then
      amz_log "install:classifier"
      echo "install:classifier" >> "${STUB_LOG:-/dev/null}"
    else
      LAN_DEV=$(uci get network.lan.device 2>/dev/null || echo br-lan)
      mkdir -p /etc/nftables.d 2>/dev/null || true
      # If .ipk already installed the classifier, skip copying.
      if [ -f /etc/nftables.d/30-amnezia-classify.nft ]; then
        amz_log "install:classifier (already present, skipping copy)"
      else
        _nft_src=$(resolve_dep \
          /etc/nftables.d/30-amnezia-classify.nft \
          30-amnezia-classify.nft \
          nftables.d/30-amnezia-classify.nft) || true
        if [ -n "$_nft_src" ] && [ "$_nft_src" != /etc/nftables.d/30-amnezia-classify.nft ]; then
          sed "s/@@LAN_IFNAME@@/$LAN_DEV/" "$_nft_src" \
            > /etc/nftables.d/30-amnezia-classify.nft 2>/dev/null || true
        elif [ -z "$_nft_src" ]; then
          amz_log "WARN: 30-amnezia-classify.nft not found; skipping classifier install"
        fi
      fi
      amz_log "install:classifier"
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
        | awk -F'[.=]' '/\.enabled='"'"'?1/{print $2}' | tr '\n' ' ' | sed 's/ $//')
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
