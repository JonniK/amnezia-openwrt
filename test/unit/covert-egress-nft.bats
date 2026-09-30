#!/usr/bin/env bats
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/nftables.d/40-amnezia-covert-egress.nft"

# Substitutes the template placeholders exactly as the CLI's `enable` verb
# does at runtime (numeric uid + real LAN ifname) and writes the result to
# a scratch file for the assertions below.
_substitute() {
  sed -e 's/@@COVERT_UID@@/1234/g' -e 's/@@LAN_IFNAME@@/br-lan/g' "$F" > "$BATS_TEST_TMPDIR/substituted.nft"
}

@test "template file exists" {
  [ -f "$F" ]
}

@test "substitution_leaves_no_placeholder" {
  _substitute
  ! grep -q '@@' "$BATS_TEST_TMPDIR/substituted.nft"
}

@test "dns_accepts_precede_rejects" {
  _substitute
  first_reject_line="$(grep -n 'reject' "$BATS_TEST_TMPDIR/substituted.nft" | head -1 | cut -d: -f1)"
  last_dns_accept_line="$(grep -n 'dport 53' "$BATS_TEST_TMPDIR/substituted.nft" | grep 'accept' | tail -1 | cut -d: -f1)"
  [ -n "$first_reject_line" ]
  [ -n "$last_dns_accept_line" ]
  [ "$last_dns_accept_line" -lt "$first_reject_line" ]
}

@test "both_reject_families_present" {
  _substitute
  grep -Eq 'ip +daddr \{.*\} reject' "$BATS_TEST_TMPDIR/substituted.nft"
  grep -Eq 'ip6 +daddr \{.*\} reject' "$BATS_TEST_TMPDIR/substituted.nft"
  grep -q 'oifname "lo" reject' "$BATS_TEST_TMPDIR/substituted.nft"
  grep -q 'oifname "br-lan" reject' "$BATS_TEST_TMPDIR/substituted.nft"
}

@test "numeric_uid_only" {
  _substitute
  # Every "meta skuid" operand must be the fully-numeric substituted uid
  # with a clean word boundary after it (no leftover name/placeholder, and
  # no trailing garbage merely because the operand STARTS with a digit --
  # e.g. "meta skuid 1234x" must fail this, which a bare
  # 'meta skuid [^0-9]' negative-class check on the first char would miss).
  run grep -E 'meta skuid [0-9][0-9]*[^0-9 ]' "$BATS_TEST_TMPDIR/substituted.nft"
  [ "$status" -ne 0 ]
  grep -q 'meta skuid 1234' "$BATS_TEST_TMPDIR/substituted.nft"
}
