#!/usr/bin/env bats
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/nftables.d/30-amnezia-classify.nft"
@test "declares all three sets as interval ipv4 sets" {
  grep -q "set amnezia_ru4" "$F"
  grep -q "set amnezia_ru_tld4" "$F"
  grep -q "set amnezia_sticky4" "$F"
  grep -q "flags interval" "$F"
}
@test "classifier chain hooks prerouting at mangle priority" {
  grep -Eq "type filter hook prerouting priority (mangle|-150)" "$F"
}
@test "marks pool and sticky and returns RU direct" {
  grep -q "meta mark set 0x0b0000" "$F"
  grep -q "meta mark set 0x0a0000" "$F"
  grep -Eq "@amnezia_ru(4|_tld4).*(return|accept)" "$F"
}
