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

# ---------------------------------------------------------------------------
# Covert routing (P2): routing_emit_covert_classifier derives an output-hook
# route chain for the covert uid from the SAME mode template as the LAN
# classifier — identical mark logic, only the gate + hook differ.
_emit_covert() {
  sh -c '. "'"$HARNESS_DIR"'/../openwrt/lib/amnezia-common.sh"; \
    . "'"$HARNESS_DIR"'/../openwrt/lib/amnezia-routing.sh"; \
    AMNEZIA_NFT_DIR="'"$ND"'" routing_emit_covert_classifier "'"$1"'" "'"$2"'" "'"$3"'"'
}

@test "covert classifier: correct chain, hook, uid gate, no set redecls (direct-default)" {
  run _emit_covert direct-default br-lan 391
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'chain amnezia_covert_classify {'
  echo "$output" | grep -q 'type route hook output priority mangle;'
  echo "$output" | grep -q 'meta skuid != 391 return'
  # marking mirrors the LAN classifier
  echo "$output" | grep -q 'ip daddr @amnezia_sticky4 meta mark set 0x0a0000 return'
  echo "$output" | grep -q 'ip daddr @amnezia_force4  meta mark set 0x0b0000 return'
  # never redeclare the sets (the LAN classifier owns them; a redecl errors)
  run grep -c '^set amnezia_' <<<"$output"
  [ "$output" = "0" ]
  # never carry the prerouting hook or the LAN iifname gate
  ! _emit_covert direct-default br-lan 391 | grep -q 'hook prerouting'
  ! _emit_covert direct-default br-lan 391 | grep -q 'iifname'
}

@test "covert classifier: tunnel-default mirrors ru-direct + blanket pool mark" {
  run _emit_covert tunnel-default br-lan 391
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '@amnezia_ru_tld4 return'
  echo "$output" | grep -q '@amnezia_ru4 return'
  echo "$output" | grep -q '@amnezia_sticky4 meta mark set 0x0a0000 return'
  echo "$output" | grep -qE '^[[:space:]]*meta mark set 0x0b0000$'
}

@test "covert classifier: uid substitution is applied, not left as a placeholder" {
  run _emit_covert direct-default br-lan 6553
  echo "$output" | grep -q 'meta skuid != 6553 return'
  ! echo "$output" | grep -q '@@COVERT_UID@@'
  ! echo "$output" | grep -q '@@LAN_IFNAME@@'
}

@test "covert classifier: mark lines are byte-identical to the LAN classifier (anti-drift)" {
  for mode in direct-default tunnel-default; do
    lan="$(_emit_lan "$mode" br-lan | grep -E 'meta mark set|@amnezia_(ru4|ru_tld4|sticky4|force4)' | sed 's/^[[:space:]]*//')"
    cov="$(_emit_covert "$mode" br-lan 391 | grep -E 'meta mark set|@amnezia_(ru4|ru_tld4|sticky4|force4)' | sed 's/^[[:space:]]*//')"
    [ -n "$lan" ]
    [ "$lan" = "$cov" ] || { echo "DRIFT ($mode):"; diff <(echo "$lan") <(echo "$cov"); false; }
  done
}
_emit_lan() {
  sh -c '. "'"$HARNESS_DIR"'/../openwrt/lib/amnezia-common.sh"; \
    . "'"$HARNESS_DIR"'/../openwrt/lib/amnezia-routing.sh"; \
    AMNEZIA_NFT_DIR="'"$ND"'" routing_emit_classifier "'"$1"'" "'"$2"'"'
}
