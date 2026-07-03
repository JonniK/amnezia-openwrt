#!/usr/bin/env bats
# test/unit/install-staging.bats
#
# Verifies that install.sh's glob-based staging covers every dependency
# basename that install-amnezia-pbr.sh requests via resolve_dep (second
# argument = /tmp/<name>, or third argument = $SCRIPT_DIR/<rel>).
#
# "Covered" means a file with that basename exists under openwrt/ in a
# location staged by one of install.sh's globs:
#   openwrt/*.sh / *.init / *.hotplug → /tmp/<basename>
#   openwrt/lib/*.sh                  → /tmp/lib/<basename>  (SCRIPT_DIR/lib/<rel>)
#   openwrt/nftables.d/*.nft          → /tmp/nftables.d/<basename> (SCRIPT_DIR/nftables.d/<rel>)
#   openwrt/amnezia-failover          → /tmp/amnezia-failover (explicit)
#   openwrt/iproute2-amnezia-rt_tables.conf → /tmp/... (explicit)
#   openwrt/*.list                    → /tmp/<basename>
load '../lib/harness.bash'

SRC="$HARNESS_DIR/../openwrt"

# Returns 0 if <basename> is reachable via any of install.sh's globs.
_covered() {
  local base="$1"
  [ -f "$SRC/$base" ] || [ -f "$SRC/lib/$base" ] || [ -f "$SRC/nftables.d/$base" ]
}

# ── resolve_dep second-arg deps (looked up as /tmp/<name>) ──────────────────

@test "staging covers configure-dnsmasq-amnezia.sh" {
  _covered configure-dnsmasq-amnezia.sh
}

@test "staging covers iproute2-amnezia-rt_tables.conf" {
  [ -f "$SRC/iproute2-amnezia-rt_tables.conf" ]
}

@test "staging covers amnezia-ru-cidr.sh" {
  _covered amnezia-ru-cidr.sh
}

@test "staging covers amnezia-ru-load.init" {
  _covered amnezia-ru-load.init
}

@test "staging covers 99-amnezia-ru-load.hotplug" {
  _covered 99-amnezia-ru-load.hotplug
}

@test "staging covers amnezia-failover (extensionless daemon)" {
  [ -f "$SRC/amnezia-failover" ]
}

@test "staging covers amnezia-failover.init" {
  _covered amnezia-failover.init
}

@test "staging covers amnezia-tunnel-ctl.sh" {
  _covered amnezia-tunnel-ctl.sh
}

@test "staging covers amnezia-force-load.sh" {
  _covered amnezia-force-load.sh
}

@test "staging covers amnezia-force-update.sh" {
  _covered amnezia-force-update.sh
}

@test "staging covers amnezia-force-warm.sh" {
  _covered amnezia-force-warm.sh
}

@test "staging covers amnezia-app-ctl.sh" {
  _covered amnezia-app-ctl.sh
}

@test "staging covers amnezia-autotunnel.sh" {
  _covered amnezia-autotunnel.sh
}

@test "staging covers amnezia-blackbox.sh" {
  _covered amnezia-blackbox.sh
}

@test "staging covers 99-amnezia-force-load.hotplug" {
  _covered 99-amnezia-force-load.hotplug
}

@test "staging covers amnezia-force-load.init" {
  _covered amnezia-force-load.init
}

@test "staging covers amnezia-dns-ctl.sh" {
  _covered amnezia-dns-ctl.sh
}

@test "staging covers amnezia-dns-lib.sh (via lib/)" {
  # resolve_dep looks in /tmp/amnezia-dns-lib.sh (2nd arg) then
  # $SCRIPT_DIR/lib/amnezia-dns-lib.sh (3rd arg = lib/amnezia-dns-lib.sh).
  _covered amnezia-dns-lib.sh
}

@test "staging covers amnezia-dns.init" {
  _covered amnezia-dns.init
}

@test "staging covers 99-amnezia-dns.hotplug" {
  _covered 99-amnezia-dns.hotplug
}

@test "staging covers amnezia-dnsleak-ctl.sh" {
  _covered amnezia-dnsleak-ctl.sh
}

@test "staging covers amnezia-dnsleak.init" {
  _covered amnezia-dnsleak.init
}

@test "staging covers 99-amnezia-dnsleak.hotplug" {
  _covered 99-amnezia-dnsleak.hotplug
}

@test "staging covers force-tunnel.list" {
  _covered force-tunnel.list
}

@test "staging covers 30-amnezia-classify.nft (via nftables.d/)" {
  _covered 30-amnezia-classify.nft
}

@test "staging covers 30-amnezia-classify-direct.nft (via nftables.d/)" {
  _covered 30-amnezia-classify-direct.nft
}

# ── Sourced libs (not via resolve_dep but via $SCRIPT_DIR/lib/) ─────────────

@test "staging covers amnezia-common.sh (sourced via lib/)" {
  _covered amnezia-common.sh
}

@test "staging covers amnezia-routing.sh (sourced via lib/)" {
  _covered amnezia-routing.sh
}

@test "staging covers amnezia-tunnel-lib.sh (sourced via lib/)" {
  _covered amnezia-tunnel-lib.sh
}
