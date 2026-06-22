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
@test "disable removes the uci options and the cron line when logfacility is AL_LOG" {
  # Wire logfacility to the same path the init set (AL_LOG = /tmp/dnsmasq-queries.log).
  # Uses UCI_DNSMASQ_logfacility (special stub key for dhcp.@dnsmasq[0].logfacility).
  export UCI_DNSMASQ_logfacility="/tmp/dnsmasq-queries.log"
  sh "$INIT" enable
  run sh "$INIT" disable
  grep -q "delete dhcp.@dnsmasq\[0\].logqueries" "$STUB_LOG"
  # Robust negative: amnezia-autolearn should be removed from cron
  run grep -q "amnezia-autolearn" "$AL_CRON"; [ "$status" -ne 0 ]
}
@test "disable does NOT delete dnsmasq logging when logfacility is a foreign path" {
  # Simulate a user-owned logfacility pointing elsewhere.
  export UCI_DNSMASQ_logfacility="/var/log/dnsmasq-user.log"
  sh "$INIT" enable
  : > "$STUB_LOG"   # clear the log so only disable's actions are visible
  run sh "$INIT" disable
  # Must NOT have issued a uci delete for our logging options
  run grep -q "delete dhcp.@dnsmasq\[0\].logqueries" "$STUB_LOG"; [ "$status" -ne 0 ]
  run grep -q "delete dhcp.@dnsmasq\[0\].logfacility" "$STUB_LOG"; [ "$status" -ne 0 ]
}
