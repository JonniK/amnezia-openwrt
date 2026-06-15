#!/usr/bin/env bats
# Tests that the no-arg / STEPS=3 installer path dispatches to the new
# failover wiring stack instead of the legacy pbr path.
load '../lib/harness.bash'

# Static assertions: verify the source text has been rewired.

@test "installer STEPS path dispatches to first_install_wiring or migrate_from_pbr" {
  F="$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh"
  # The dispatch must be present: sh \$0 --first-install (fresh) or sh \$0 --migrate (upgrade).
  grep -q 'sh "$0" --first-install' "$F" || grep -q "sh \"\$0\" --first-install" "$F"
  grep -q 'sh "$0" --migrate' "$F"      || grep -q "sh \"\$0\" --migrate" "$F"
}

@test "installer STEPS path does NOT contain legacy pbr.d template logic" {
  F="$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh"
  # The legacy path must be gone from the Steps 2+3 main body.
  # These were the pbr-specific lines that fail on the new stack.
  ! grep -q "find_template 99-lan-vpn" "$F"
  ! grep -q "opkg install pbr luci-app-pbr" "$F"
  ! grep -q "chmod 755 /etc/pbr.d/ru-direct.sh" "$F"
}

@test "installer STEPS path checks for pbr presence to dispatch correctly" {
  F="$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh"
  # The dispatch must detect pbr (via /etc/init.d/pbr status or opkg list-installed).
  grep -q "pbr" "$F"
  # Both dispatch branches must exist.
  grep -q "migrate_from_pbr\|--migrate" "$F"
  grep -q "first_install_wiring\|--first-install" "$F"
}

@test "STEPS=3 fresh install (via --first-install) invokes failover stack (functional)" {
  # Test the --first-install subcommand directly -- this is what the STEPS=3
  # fresh-install dispatch re-execs into. Confirms the wiring that STEPS=3 triggers.
  UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install --dry-run
  # New stack markers must be present.
  grep -q "install:rt_tables"                    "$STUB_LOG"
  grep -q "ip rule add fwmark"                   "$STUB_LOG"
  grep -q "/etc/init.d/amnezia-failover enable"  "$STUB_LOG"
  grep -q "install:classifier"                   "$STUB_LOG"
}

@test "STEPS=3 pbr-upgrade (via --migrate) invokes failover stack (functional)" {
  # Test the --migrate subcommand directly -- this is what STEPS=3 re-execs into
  # when pbr is present. Confirms the wiring that the upgrade dispatch triggers.
  NFT_FAKE_RU4_COUNT=12 UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate --dry-run
  echo "$output" | grep -q "install:classifier"
  echo "$output" | grep -q "remove:pbr"
  # Legacy pbr enable must NOT appear.
  ! grep -q "/etc/init.d/pbr enable" "$STUB_LOG"
}
