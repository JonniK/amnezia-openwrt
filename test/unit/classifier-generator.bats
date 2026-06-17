#!/usr/bin/env bats
load '../lib/harness.bash'
ND="$HARNESS_DIR/../openwrt/nftables.d"

@test "both fragments declare amnezia_force4 as an interval set" {
  for f in 30-amnezia-classify.nft 30-amnezia-classify-direct.nft; do
    grep -Eq 'set amnezia_force4 +\{ type ipv4_addr; flags interval; auto-merge; \}' "$ND/$f" \
      || { echo "missing force4 decl in $f"; false; }
  done
}

@test "direct fragment: default direct, force->pool, sticky->sticky, no blanket mark" {
  f="$ND/30-amnezia-classify-direct.nft"
  grep -q 'ip daddr @amnezia_sticky4 meta mark set 0x0a0000 return' "$f"
  grep -q 'ip daddr @amnezia_force4  meta mark set 0x0b0000 return' "$f"
  run grep -E '^[[:space:]]*meta mark set 0x0b0000$' "$f"   # blanket pool-mark = tunnel-default only
  [ "$status" -ne 0 ] || { echo "direct fragment must not blanket-mark to pool"; false; }
}

@test "routing_emit_classifier picks the right fragment and substitutes LAN" {
  run sh -c '. "'"$HARNESS_DIR"'/../openwrt/lib/amnezia-common.sh"; \
    . "'"$HARNESS_DIR"'/../openwrt/lib/amnezia-routing.sh"; \
    AMNEZIA_NFT_DIR="'"$ND"'" routing_emit_classifier direct-default br-lan'
  echo "$output" | grep -q 'iifname != "br-lan" return'
  echo "$output" | grep -q 'ip daddr @amnezia_force4  meta mark set 0x0b0000 return'
  run sh -c '. "'"$HARNESS_DIR"'/../openwrt/lib/amnezia-common.sh"; \
    . "'"$HARNESS_DIR"'/../openwrt/lib/amnezia-routing.sh"; \
    AMNEZIA_NFT_DIR="'"$ND"'" routing_emit_classifier tunnel-default br-lan'
  echo "$output" | grep -qE '^[[:space:]]*meta mark set 0x0b0000$'
}

@test "tunnel-default fragment behaviour is preserved (regression)" {
  # The pre-existing golden test must still pass after A2 adds the force4 decl.
  run bats "$HARNESS_DIR/unit/classify-nft.bats"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  f="$ND/30-amnezia-classify.nft"
  grep -q '@amnezia_ru_tld4 return' "$f"
  grep -q '@amnezia_ru4 return' "$f"
  grep -q '@amnezia_sticky4 meta mark set 0x0a0000 return' "$f"
}
