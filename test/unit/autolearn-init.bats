#!/usr/bin/env bats
load '../lib/harness.bash'
INIT="$HARNESS_DIR/../openwrt/amnezia-autolearn.init"
setup() {
  export AL_CRON="$BATS_TEST_TMPDIR/cron"; : > "$AL_CRON"
  export AMNEZIA_DNSMASQ_INIT="dnsmasq"
}
@test "enable sets logqueries + tmpfs logfacility + cron line" {
  run sh "$INIT" enable
  grep -q "set dhcp.@dnsmasq\[0\].logqueries=1" "$STUB_LOG"
  grep -q "set dhcp.@dnsmasq\[0\].logfacility=/tmp/dnsmasq-queries.log" "$STUB_LOG"
  grep -q "amnezia-autolearn" "$AL_CRON"
}
@test "disable removes the uci options and the cron line" {
  sh "$INIT" enable
  run sh "$INIT" disable
  grep -q "delete dhcp.@dnsmasq\[0\].logqueries" "$STUB_LOG"
  # Robust negative: amnezia-autolearn should be removed from cron
  run grep -q "amnezia-autolearn" "$AL_CRON"; [ "$status" -ne 0 ]
}
