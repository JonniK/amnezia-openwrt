#!/usr/bin/env bats
load '../lib/harness.bash'
CTL="$HARNESS_DIR/../openwrt/amnezia-dnsleak-ctl.sh"

setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export UCI_GET_amnezia_config_dnsleak_enabled=0
  # Wire the init/dnsmasq overrides to stubs already on PATH.
  export AMNEZIA_DNSLEAK_INIT=amnezia-dnsleak-init
  export AMNEZIA_DNSMASQ_RESTART="dnsmasq restart"
}

# ---------------------------------------------------------------------------
# enable
# ---------------------------------------------------------------------------

@test "enable: sets dnsleak_enabled=1 in UCI" {
  run sh "$CTL" enable
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dnsleak_enabled=1" "$STUB_LOG"
}

@test "enable: creates all 3 firewall sections" {
  run sh "$CTL" enable
  [ "$status" -eq 0 ]
  grep -q "set firewall.amz_dns_intercept=redirect" "$STUB_LOG"
  grep -q "set firewall.amz_block_dot=rule"         "$STUB_LOG"
  grep -q "set firewall.amz_block_doh=rule"         "$STUB_LOG"
}

@test "enable: intercept section has correct attributes" {
  run sh "$CTL" enable
  [ "$status" -eq 0 ]
  grep -q "firewall.amz_dns_intercept.name=amnezia-dns-intercept" "$STUB_LOG"
  grep -q "firewall.amz_dns_intercept.src=lan"                    "$STUB_LOG"
  grep -q "firewall.amz_dns_intercept.dest_ip=192.168.1.1"        "$STUB_LOG"
  grep -q "firewall.amz_dns_intercept.dest_port=53"               "$STUB_LOG"
  grep -q "firewall.amz_dns_intercept.target=DNAT"                "$STUB_LOG"
}

@test "enable: DoH block section includes all 6 IP addresses via add_list" {
  run sh "$CTL" enable
  [ "$status" -eq 0 ]
  grep -q "add_list firewall.amz_block_doh.dest_ip=1.1.1.1"           "$STUB_LOG"
  grep -q "add_list firewall.amz_block_doh.dest_ip=1.0.0.1"           "$STUB_LOG"
  grep -q "add_list firewall.amz_block_doh.dest_ip=8.8.8.8"           "$STUB_LOG"
  grep -q "add_list firewall.amz_block_doh.dest_ip=8.8.4.4"           "$STUB_LOG"
  grep -q "add_list firewall.amz_block_doh.dest_ip=9.9.9.9"           "$STUB_LOG"
  grep -q "add_list firewall.amz_block_doh.dest_ip=149.112.112.112"   "$STUB_LOG"
}

@test "enable: commits both firewall and amnezia UCI" {
  run sh "$CTL" enable
  [ "$status" -eq 0 ]
  grep -q "commit firewall" "$STUB_LOG"
  grep -q "commit amnezia"  "$STUB_LOG"
}

@test "enable: schedules backgrounded fw4 reload (sleep 1 pattern)" {
  run sh "$CTL" enable
  [ "$status" -eq 0 ]
  grep -q "fw4 reload" "$STUB_LOG"
}

@test "enable: starts the watchdog init" {
  run sh "$CTL" enable
  [ "$status" -eq 0 ]
  grep -q "amnezia-dnsleak-init enable" "$STUB_LOG"
  grep -q "amnezia-dnsleak-init start"  "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# disable
# ---------------------------------------------------------------------------

@test "disable: sets dnsleak_enabled=0" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  run sh "$CTL" disable
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dnsleak_enabled=0" "$STUB_LOG"
}

@test "disable: deletes all 3 firewall sections" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  run sh "$CTL" disable
  [ "$status" -eq 0 ]
  grep -q "delete firewall.amz_dns_intercept" "$STUB_LOG"
  grep -q "delete firewall.amz_block_dot"     "$STUB_LOG"
  grep -q "delete firewall.amz_block_doh"     "$STUB_LOG"
}

@test "disable: commits firewall and amnezia after deletion" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  run sh "$CTL" disable
  [ "$status" -eq 0 ]
  grep -q "commit firewall" "$STUB_LOG"
  grep -q "commit amnezia"  "$STUB_LOG"
}

@test "disable: schedules backgrounded fw4 reload" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  run sh "$CTL" disable
  [ "$status" -eq 0 ]
  grep -q "fw4 reload" "$STUB_LOG"
}

@test "disable: stops the watchdog init" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  run sh "$CTL" disable
  [ "$status" -eq 0 ]
  grep -q "amnezia-dnsleak-init stop" "$STUB_LOG"
}

@test "disable: sentinel prevents recursion (AMNEZIA_DNSLEAK_STOPPING skips stop)" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  run sh -c "AMNEZIA_DNSLEAK_STOPPING=1 AMNEZIA_DNSLEAK_INIT=amnezia-dnsleak-init AMNEZIA_LIB='$AMNEZIA_LIB' sh '$CTL' disable"
  [ "$status" -eq 0 ]
  # With sentinel set, init stop must NOT be logged.
  run grep -q "amnezia-dnsleak-init stop" "$STUB_LOG"; [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------

@test "apply: no-op when dnsleak_enabled=0" {
  export UCI_GET_amnezia_config_dnsleak_enabled=0
  run sh "$CTL" apply
  [ "$status" -eq 0 ]
  # No firewall sections should be set
  run grep -q "set firewall.amz_dns_intercept" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "apply: re-asserts all 3 sections when dnsleak_enabled=1" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  run sh "$CTL" apply
  [ "$status" -eq 0 ]
  grep -q "set firewall.amz_dns_intercept=redirect" "$STUB_LOG"
  grep -q "set firewall.amz_block_dot=rule"         "$STUB_LOG"
  grep -q "set firewall.amz_block_doh=rule"         "$STUB_LOG"
}

@test "apply: commits firewall when enabled" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  run sh "$CTL" apply
  [ "$status" -eq 0 ]
  grep -q "commit firewall" "$STUB_LOG"
}

@test "apply: does NOT trigger fw4 reload (hotplug path)" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  run sh "$CTL" apply
  [ "$status" -eq 0 ]
  # apply is called from within a hotplug/reload — it must NOT trigger another reload
  run grep -q "fw4 reload" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "apply: idempotent — safe to call twice, second call still succeeds" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  run sh "$CTL" apply
  [ "$status" -eq 0 ]
  run sh "$CTL" apply
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# failopen
# ---------------------------------------------------------------------------

@test "failopen: deletes DNAT rule for amnezia-dns-intercept by handle" {
  # Provide a fake nft ruleset via NFT_FAKE_FW4 env used by the enhanced stub.
  export NFT_FAKE_FW4=dnsleak
  run sh "$CTL" failopen
  [ "$status" -eq 0 ]
  # The stub logs nft delete rule ... handle <N> calls.
  grep -q "nft delete rule inet fw4 dstnat_lan handle 42" "$STUB_LOG"
}

@test "failopen: deletes REJECT rules for amnezia-block-DoT and amnezia-block-DoH-ips by handle" {
  export NFT_FAKE_FW4=dnsleak
  run sh "$CTL" failopen
  [ "$status" -eq 0 ]
  grep -q "nft delete rule inet fw4 forward handle 43" "$STUB_LOG"
  grep -q "nft delete rule inet fw4 forward handle 44" "$STUB_LOG"
}

@test "failopen: also removes https-dns-proxy redirect by handle (best-effort)" {
  export NFT_FAKE_FW4=dnsleak
  run sh "$CTL" failopen
  [ "$status" -eq 0 ]
  grep -q "nft delete rule inet fw4 dstnat_lan handle 41" "$STUB_LOG"
}

@test "failopen: sets dnsleak_failopen=1 in UCI" {
  export NFT_FAKE_FW4=dnsleak
  run sh "$CTL" failopen
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dnsleak_failopen=1" "$STUB_LOG"
}

@test "failopen: commits amnezia UCI" {
  export NFT_FAKE_FW4=dnsleak
  run sh "$CTL" failopen
  [ "$status" -eq 0 ]
  grep -q "commit amnezia" "$STUB_LOG"
}

@test "failopen: idempotent when rules are already absent (no handles found)" {
  # No NFT_FAKE_FW4 set → stub returns empty ruleset → no handles → no deletes → still OK.
  run sh "$CTL" failopen
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dnsleak_failopen=1" "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# failclosed
# ---------------------------------------------------------------------------

@test "failclosed: deletes dnsleak_failopen UCI key" {
  export UCI_GET_amnezia_config_dnsleak_failopen=1
  run sh "$CTL" failclosed
  [ "$status" -eq 0 ]
  grep -q "delete amnezia.config.dnsleak_failopen" "$STUB_LOG"
}

@test "failclosed: commits amnezia UCI" {
  run sh "$CTL" failclosed
  [ "$status" -eq 0 ]
  grep -q "commit amnezia" "$STUB_LOG"
}

@test "failclosed: schedules backgrounded fw4 reload" {
  run sh "$CTL" failclosed
  [ "$status" -eq 0 ]
  grep -q "fw4 reload" "$STUB_LOG"
}

@test "failclosed: idempotent when already not failopen" {
  run sh "$CTL" failclosed
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

@test "status: reports enabled= and failopen= fields" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  export UCI_GET_amnezia_config_dnsleak_failopen=0
  export AMNEZIA_DNSLEAK_PROBE_CMD="true"
  run sh "$CTL" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^enabled=1"
  echo "$output" | grep -q "^failopen=0"
}

@test "status: reports resolver_ok=true when probe succeeds" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  export AMNEZIA_DNSLEAK_PROBE_CMD="true"
  run sh "$CTL" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^resolver_ok=true"
}

@test "status: reports resolver_ok=false when probe fails" {
  export UCI_GET_amnezia_config_dnsleak_enabled=0
  export AMNEZIA_DNSLEAK_PROBE_CMD="false"
  run sh "$CTL" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^resolver_ok=false"
}

# ---------------------------------------------------------------------------
# watchdog: safety invariant — healthy probe → ZERO destructive actions
# ---------------------------------------------------------------------------

@test "watchdog: healthy probe — no fw4 reload, no dnsmasq restart, no failopen (safety invariant)" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  export AMNEZIA_DNSLEAK_PROBE_CMD="true"
  run sh -c "AMNEZIA_DNSLEAK_WD_ONCE=1 AMNEZIA_DNSLEAK_INIT=amnezia-dnsleak-init AMNEZIA_LIB='$AMNEZIA_LIB' sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  run grep -q "fw4 reload"         "$STUB_LOG"; [ "$status" -ne 0 ]
  run grep -q "dnsmasq restart"    "$STUB_LOG"; [ "$status" -ne 0 ]
  run grep -q "dnsleak_failopen=1" "$STUB_LOG"; [ "$status" -ne 0 ]
  run grep -q "nft delete"         "$STUB_LOG"; [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# watchdog: dnsmasq restart threshold
# ---------------------------------------------------------------------------

@test "watchdog: fail count reaching RESTART_N triggers dnsmasq restart" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  export AMNEZIA_DNSLEAK_PROBE_CMD="false"
  run sh -c "AMNEZIA_DNSLEAK_WD_TICKS=2 AMNEZIA_DNSLEAK_WD_RESTART_N=2 AMNEZIA_DNSLEAK_WD_OPEN_N=99 AMNEZIA_DNSLEAK_INIT=amnezia-dnsleak-init AMNEZIA_LIB='$AMNEZIA_LIB' sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  grep -q "dnsmasq restart" "$STUB_LOG"
}

@test "watchdog: fail count below RESTART_N does NOT trigger restart" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  export AMNEZIA_DNSLEAK_PROBE_CMD="false"
  run sh -c "AMNEZIA_DNSLEAK_WD_TICKS=1 AMNEZIA_DNSLEAK_WD_RESTART_N=2 AMNEZIA_DNSLEAK_WD_OPEN_N=99 AMNEZIA_DNSLEAK_INIT=amnezia-dnsleak-init AMNEZIA_LIB='$AMNEZIA_LIB' sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  run grep -q "dnsmasq restart" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "watchdog: dnsmasq restart happens exactly once when fail=RESTART_N (not on every subsequent tick)" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  export AMNEZIA_DNSLEAK_PROBE_CMD="false"
  # TICKS=3, RESTART_N=2, OPEN_N=99 → restart fires at tick 2, not tick 3.
  run sh -c "AMNEZIA_DNSLEAK_WD_TICKS=3 AMNEZIA_DNSLEAK_WD_RESTART_N=2 AMNEZIA_DNSLEAK_WD_OPEN_N=99 AMNEZIA_DNSLEAK_INIT=amnezia-dnsleak-init AMNEZIA_LIB='$AMNEZIA_LIB' sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  _count=$(grep -c "dnsmasq restart" "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# watchdog: failopen threshold
# ---------------------------------------------------------------------------

@test "watchdog: persistent fail reaching OPEN_N triggers failopen (deletes nft rules)" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  export AMNEZIA_DNSLEAK_PROBE_CMD="false"
  export NFT_FAKE_FW4=dnsleak
  run sh -c "AMNEZIA_DNSLEAK_WD_TICKS=4 AMNEZIA_DNSLEAK_WD_RESTART_N=99 AMNEZIA_DNSLEAK_WD_OPEN_N=4 AMNEZIA_DNSLEAK_INIT=amnezia-dnsleak-init AMNEZIA_LIB='$AMNEZIA_LIB' sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dnsleak_failopen=1" "$STUB_LOG"
  # DNAT rule deleted by failopen
  grep -q "nft delete rule inet fw4 dstnat_lan handle 42" "$STUB_LOG"
}

@test "watchdog: failopen fires only once (not re-triggered on subsequent fails)" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  export AMNEZIA_DNSLEAK_PROBE_CMD="false"
  export NFT_FAKE_FW4=dnsleak
  # TICKS=6, OPEN_N=4 → failopen fires at tick 4, should not fire again at 5 or 6.
  run sh -c "AMNEZIA_DNSLEAK_WD_TICKS=6 AMNEZIA_DNSLEAK_WD_RESTART_N=99 AMNEZIA_DNSLEAK_WD_OPEN_N=4 AMNEZIA_DNSLEAK_INIT=amnezia-dnsleak-init AMNEZIA_LIB='$AMNEZIA_LIB' sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  _count=$(grep -c "set amnezia.config.dnsleak_failopen=1" "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$_count" -eq 1 ]
}

@test "watchdog: below OPEN_N threshold — no failopen" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  export AMNEZIA_DNSLEAK_PROBE_CMD="false"
  run sh -c "AMNEZIA_DNSLEAK_WD_TICKS=3 AMNEZIA_DNSLEAK_WD_RESTART_N=99 AMNEZIA_DNSLEAK_WD_OPEN_N=4 AMNEZIA_DNSLEAK_INIT=amnezia-dnsleak-init AMNEZIA_LIB='$AMNEZIA_LIB' sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  run grep -q "dnsleak_failopen=1" "$STUB_LOG"; [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# watchdog: recovery (failclosed after M consecutive oks)
# ---------------------------------------------------------------------------

@test "watchdog: M consecutive oks after failopen triggers failclosed" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  export UCI_GET_amnezia_config_dnsleak_failopen=1
  export AMNEZIA_DNSLEAK_PROBE_CMD="true"
  # M=2: need 2 consecutive OK ticks to close.
  run sh -c "AMNEZIA_DNSLEAK_WD_TICKS=2 AMNEZIA_DNSLEAK_WD_M=2 AMNEZIA_DNSLEAK_INIT=amnezia-dnsleak-init AMNEZIA_LIB='$AMNEZIA_LIB' sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  grep -q "delete amnezia.config.dnsleak_failopen" "$STUB_LOG"
  grep -q "fw4 reload" "$STUB_LOG"
}

@test "watchdog: M-1 oks not enough to close failopen (hysteresis)" {
  export UCI_GET_amnezia_config_dnsleak_enabled=1
  export UCI_GET_amnezia_config_dnsleak_failopen=1
  export AMNEZIA_DNSLEAK_PROBE_CMD="true"
  # M=3: need 3 oks, but only run 2 ticks → must not close.
  run sh -c "AMNEZIA_DNSLEAK_WD_TICKS=2 AMNEZIA_DNSLEAK_WD_M=3 AMNEZIA_DNSLEAK_INIT=amnezia-dnsleak-init AMNEZIA_LIB='$AMNEZIA_LIB' sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  run grep -q "delete amnezia.config.dnsleak_failopen" "$STUB_LOG"; [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# watchdog: exits cleanly when disabled
# ---------------------------------------------------------------------------

@test "watchdog: exits immediately when dnsleak_enabled=0" {
  export UCI_GET_amnezia_config_dnsleak_enabled=0
  export AMNEZIA_DNSLEAK_PROBE_CMD="false"
  run sh -c "AMNEZIA_DNSLEAK_WD_TICKS=5 AMNEZIA_DNSLEAK_WD_OPEN_N=2 AMNEZIA_DNSLEAK_INIT=amnezia-dnsleak-init AMNEZIA_LIB='$AMNEZIA_LIB' sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  # Must NOT have triggered failopen
  run grep -q "dnsleak_failopen=1" "$STUB_LOG"; [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# init + hotplug structural
# ---------------------------------------------------------------------------

@test "init: only starts watchdog when dnsleak_enabled=1" {
  INIT="$HARNESS_DIR/../openwrt/amnezia-dnsleak.init"
  grep -q "dnsleak_enabled" "$INIT"
  grep -q "procd_set_param command /usr/bin/amnezia-dnsleak-ctl watchdog" "$INIT"
}

@test "init: stop_service sets AMNEZIA_DNSLEAK_STOPPING sentinel (recursion guard)" {
  INIT="$HARNESS_DIR/../openwrt/amnezia-dnsleak.init"
  grep -q "AMNEZIA_DNSLEAK_STOPPING=1" "$INIT"
}

@test "init: START >= 20 (runs after dnsmasq)" {
  INIT="$HARNESS_DIR/../openwrt/amnezia-dnsleak.init"
  _start=$(grep "^START=" "$INIT" | head -1 | cut -d= -f2)
  [ "$_start" -ge 20 ]
}

@test "hotplug: fires on ACTION=reload and calls apply" {
  HP="$HARNESS_DIR/../openwrt/99-amnezia-dnsleak.hotplug"
  grep -q 'ACTION.*=.*reload' "$HP" || grep -q '"$ACTION" = reload' "$HP"
  grep -q "amnezia-dnsleak-ctl apply" "$HP"
}

@test "hotplug: checks dnsleak_enabled before calling apply" {
  HP="$HARNESS_DIR/../openwrt/99-amnezia-dnsleak.hotplug"
  grep -q "dnsleak_enabled" "$HP"
}

# ---------------------------------------------------------------------------
# sync parity
# ---------------------------------------------------------------------------

@test "sync: amnezia-dnsleak-ctl is wired into sync-to-packages.sh" {
  S="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-dnsleak-ctl" "$S"
}

@test "sync: amnezia-dnsleak.init is wired into sync-to-packages.sh" {
  S="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-dnsleak" "$S"
}

@test "sync: 99-amnezia-dnsleak.hotplug is wired into sync-to-packages.sh" {
  S="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "99-amnezia-dnsleak" "$S"
}

@test "sync: amnezia-dnsleak-ctl appears in packages tree after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/usr/bin/amnezia-dnsleak-ctl" ]
}

@test "sync: amnezia-dnsleak init appears in packages tree after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/etc/init.d/amnezia-dnsleak" ]
}

@test "sync: 99-amnezia-dnsleak hotplug appears in packages tree after sync" {
  run sh "$HARNESS_DIR/../dev/sync-to-packages.sh"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_DIR/../packages/amnezia-pbr/files/etc/hotplug.d/firewall/99-amnezia-dnsleak" ]
}
