#!/usr/bin/env bats
load '../lib/harness.bash'
@test "loads CIDRs from a local source into amnezia_ru4 via nft add element" {
  printf '5.0.0.0/8\n31.0.0.0/16\n' > "$BATS_TEST_TMPDIR/ru.zone"
  RU_SRC="file://$BATS_TEST_TMPDIR/ru.zone" RU_CIDR_PERSIST="$BATS_TEST_TMPDIR/ru.cidr" \
    sh "$HARNESS_DIR/../openwrt/amnezia-ru-cidr.sh"
  grep -q "nft add element inet fw4 amnezia_ru4" "$STUB_LOG"
  grep -q "5.0.0.0/8" "$BATS_TEST_TMPDIR/ru.cidr"
}
@test "exits non-zero and keeps persist file if source unreachable" {
  printf '9.9.9.0/24\n' > "$BATS_TEST_TMPDIR/ru.cidr"
  run env RU_SRC="file:///no/such" RU_CIDR_PERSIST="$BATS_TEST_TMPDIR/ru.cidr" \
    sh "$HARNESS_DIR/../openwrt/amnezia-ru-cidr.sh"
  [ "$status" -ne 0 ]
  grep -q "9.9.9.0/24" "$BATS_TEST_TMPDIR/ru.cidr"
}
