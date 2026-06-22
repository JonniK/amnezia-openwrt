#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { _require_linux_nft || skip "needs Linux nft"; }
@test "classifier include parses under real nft -c" {
  # Wrap in a minimal table so the include is self-contained for syntax check.
  tmp="$BATS_TEST_TMPDIR/t.nft"
  { echo 'table inet fw4 {'; cat "$HARNESS_DIR/../openwrt/nftables.d/30-amnezia-classify.nft"; echo '}'; } > "$tmp"
  run sudo nft -c -f "$tmp"
  [ "$status" -eq 0 ]
}
