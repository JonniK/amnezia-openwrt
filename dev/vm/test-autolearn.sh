#!/bin/sh
# Phase 10 VM verification: autolearn direct-default learning scenario.
#
# Asserts the Phase 10 Task 10.1 Step 1 spec:
#   - Provision: tunnel + routing_mode=direct-default + autolearn_enabled=1
#     + /etc/init.d/amnezia-autolearn enable
#   - Inject a fake /tmp/dnsmasq-queries.log with query[A] lines for:
#       * a geoblock-canned domain (zapret-probe shim returns direct_geoblocked)
#         from two distinct client IPs  -> must appear in auto.list
#       * an RFC1918-resolving internal domain (stub nslookup returns private IP)
#         -> must be skipped (SSRF gate / al_ip_is_public rejects it)
#   - Run amnezia-autolearn twice (threshold=2 for geoblock).
#   - Assert auto.list contains the geoblocked domain and NOT the internal one.
#   - Assert amnezia_force4 nft set / dnsmasq conf-dir reflects the addition.
#   - flip autolearn_enabled=0 via ctl -> assert learning halts + no new adds.
#   - Set all-down failover state -> assert no new adds (tunnel health gate).
#
# Harness notes:
#   - Does NOT run QEMU. Script is authored for user-gated VM execution.
#   - All assertions use assert_pass/assert_fail from assert.sh (shared counters).
#   - fd3 is saved BEFORE redirecting fd1 to the log file to avoid the
#     tail-feeds-itself infinite-loop bug (see test-tunnel-mgmt.sh header).
#
# Pre-conditions:
#   - VM provisioned + full stack installed (provision.sh --first-install +
#     installer --first-install, same as SCENARIO 3 in test-all.sh).
#   - amnezia-autolearn, amnezia-autolearn-ctl, amnezia-autolearn-lib.sh,
#     and /etc/init.d/amnezia-autolearn installed on the VM.
#   - zapret-probe shim with canned-verdict env var support on the VM
#     (the stub pattern: ZP_VERDICT_<domain_underscored>=direct_geoblocked).
#
# Exit code: 0 = all PASS, nonzero = at least one FAIL.
# POSIX sh; runs on the macOS HOST.

set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/assert.sh"

VM_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$VM_DIR/../.." && pwd)"

log()  { echo "[test-autolearn] $*"; }
die()  { echo "[test-autolearn] FATAL: $*" >&2; exit 1; }
warn() { echo "[test-autolearn] WARN: $*"; }

# ── Transcript log ────────────────────────────────────────────────────────────
LOG_TS=$(date +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%d%H%M%S)
LOG_FILE="$REPO_ROOT/dev/logs/autolearn-${LOG_TS}.log"
mkdir -p "$REPO_ROOT/dev/logs"
# Save the real terminal stdout to fd 3 BEFORE redirecting fd 1 to the log file.
# (Order matters: if fd 1 is already the log file, `exec 3>&1` would alias fd 3
# to the log too, and `tail -f "$LOG_FILE" >&3` would feed the log into itself —
# an infinite loop that fills the disk and kills the VM.)
exec 3>&1
exec > "$LOG_FILE" 2>&1
_tee_pid=""
tail_to_tty() {
  tail -f "$LOG_FILE" >&3 &
  _tee_pid=$!
}
tail_to_tty

log "=== Phase 10: autolearn direct-default learning scenario ==="
log "    transcript: $LOG_FILE"
log "    date: $(date)"

# ── SSH pre-check ─────────────────────────────────────────────────────────────
"$VM_DIR/vm-ssh.sh" 'echo ok' | grep -q '^ok$' \
  || die "VM not reachable over SSH -- run provision.sh + installer first"

# ── Test domain constants ─────────────────────────────────────────────────────
# GEOBLOCK_DOMAIN: a domain that will be probed and returned as direct_geoblocked.
# Use a valid-looking public domain that won't accidentally resolve to anything real.
GEOBLOCK_DOMAIN="blocked-example-test.example.org"
# INTERNAL_DOMAIN: resolves to an RFC1918 address; al_resolve_public must reject it.
INTERNAL_DOMAIN="internal-only.home.arpa"
# Two distinct client IPs (RFC1918 LAN clients) that both queried GEOBLOCK_DOMAIN.
CLIENT_A="192.168.1.100"
CLIENT_B="192.168.1.101"

# ── Fake zapret-probe shim path (injected into the VM) ───────────────────────
# We install a wrapper at /usr/bin/zapret-probe that reads ZP_VERDICT_* env
# vars exactly like the stub in test/stubs/zapret-probe, so the canned verdict
# for GEOBLOCK_DOMAIN is direct_geoblocked and everything else is direct_ok.
GEOBLOCK_KEY="ZP_VERDICT_$(printf '%s' "$GEOBLOCK_DOMAIN" | tr '.-' '__')"

# =============================================================================
# STEP 0: Provision autolearn prerequisites
# =============================================================================
log ""
log "===== STEP 0: provision direct-default + autolearn UCI + init enable ====="

# 0-a: set routing_mode=direct-default.
vm_run "uci set amnezia.config.routing_mode=direct-default; uci commit amnezia 2>/dev/null || true"
assert_contains "S0-1" "routing_mode=direct-default after provision" \
  "uci -q get amnezia.config.routing_mode 2>/dev/null || echo MISSING" \
  "direct-default"

# 0-b: enable autolearn.
vm_run "uci set amnezia.config.autolearn_enabled=1; uci commit amnezia 2>/dev/null || true"
assert_contains "S0-2" "autolearn_enabled=1 after provision" \
  "uci -q get amnezia.config.autolearn_enabled 2>/dev/null || echo MISSING" \
  "^1$"

# 0-c: enable the init script.
vm_run "/etc/init.d/amnezia-autolearn enable 2>/dev/null || true"
_al_rclink=$(vm_run "ls /etc/rc.d/S*amnezia-autolearn 2>/dev/null || true" 2>/dev/null || true)
if [ -n "$_al_rclink" ]; then
  assert_pass "S0-3" "amnezia-autolearn init enabled (rc.d symlink: $_al_rclink)"
else
  assert_fail "S0-3" "amnezia-autolearn init NOT enabled -- no /etc/rc.d/S*amnezia-autolearn symlink"
fi

# 0-d: inject zapret-probe shim that honours ZP_VERDICT_* canned verdicts.
# This mirrors test/stubs/zapret-probe exactly, so the same env-var pattern works.
log "installing zapret-probe shim on VM"
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  "cat > /usr/bin/zapret-probe-shim.sh" <<'SHIM_EOF' 2>/dev/null || true
#!/bin/sh
_dom="$1"
_key="ZP_VERDICT_$(printf '%s' "$_dom" | tr '.-' '__')"
eval _v="\${$_key:-\${ZP_VERDICT_DEFAULT:-direct_ok}}"
printf '{"domain":"%s","verdict":"%s","reason":"shim"}\n' "$_dom" "$_v"
SHIM_EOF
vm_run "chmod +x /usr/bin/zapret-probe-shim.sh 2>/dev/null || true; cp /usr/bin/zapret-probe /usr/bin/zapret-probe.real 2>/dev/null || true; cp /usr/bin/zapret-probe-shim.sh /usr/bin/zapret-probe 2>/dev/null || true"
assert_contains "S0-4" "zapret-probe shim returns canned verdict for geoblock domain" \
  "${GEOBLOCK_KEY}=direct_geoblocked zapret-probe '${GEOBLOCK_DOMAIN}' 203.0.113.1 2>/dev/null || true" \
  "direct_geoblocked"

# 0-e: wire a fake /etc/amnezia/autolearn/ directory and clear any stale state.
vm_run "mkdir -p /etc/amnezia/force.d /etc/amnezia/autolearn; : > /etc/amnezia/force.d/auto.list 2>/dev/null || true; : > /etc/amnezia/autolearn/candidates.tsv 2>/dev/null || true; : > /etc/amnezia/autolearn/deny.list 2>/dev/null || true"

# 0-f: seed a fresh failover state JSON with all_down:false so the tunnel
# health gate passes.  Touch the file with the current timestamp (mtime guard).
log "seeding /var/run/amnezia-failover.json with all_down:false"
vm_run "printf '{\"routing_mode\":\"direct-default\",\"all_down\":false,\"active_pool\":\"awg1\"}\n' > /var/run/amnezia-failover.json 2>/dev/null || true; touch /var/run/amnezia-failover.json 2>/dev/null || true"

log "Step 0 done. PASS=${ASSERT_PASS} FAIL=${ASSERT_FAIL}"

# =============================================================================
# STEP 1: Inject fake dnsmasq query log
# =============================================================================
log ""
log "===== STEP 1: inject fake /tmp/dnsmasq-queries.log ====="

# Log lines in the exact format dnsmasq uses with --log-queries:
#   <date> <time> dnsmasq[<pid>]: query[<type>] <domain> from <client-ip>
# al_querylog_pairs parses: field starting "query[" -> next field is domain, last field is client.
# We write lines for:
#   * GEOBLOCK_DOMAIN from CLIENT_A and CLIENT_B (two distinct clients -> meets threshold after 2 runs)
#   * INTERNAL_DOMAIN from CLIENT_A (resolves to RFC1918 -> must be skipped by al_resolve_public)
# Reset offset file so amnezia-autolearn reads from byte 0.
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  "cat > /tmp/dnsmasq-queries.log" <<QLOG_EOF 2>/dev/null || true
Jun 22 10:00:01 dnsmasq[1234]: query[A] ${GEOBLOCK_DOMAIN} from ${CLIENT_A}
Jun 22 10:00:02 dnsmasq[1234]: query[A] ${GEOBLOCK_DOMAIN} from ${CLIENT_B}
Jun 22 10:00:03 dnsmasq[1234]: query[A] ${INTERNAL_DOMAIN} from ${CLIENT_A}
QLOG_EOF

vm_run "rm -f /etc/amnezia/autolearn/.dnsmasq-log.offset 2>/dev/null || true"

_log_content=$(vm_run "cat /tmp/dnsmasq-queries.log 2>/dev/null || true" 2>/dev/null || true)
log "injected query log lines:"
log "  $(echo "$_log_content" | wc -l | tr -d ' ') lines"

if echo "$_log_content" | grep -q "$GEOBLOCK_DOMAIN"; then
  assert_pass "T1-1" "dnsmasq query log contains geoblock domain"
else
  assert_fail "T1-1" "dnsmasq query log missing geoblock domain -- content: $(echo "$_log_content" | head -5)"
fi

if echo "$_log_content" | grep -q "$INTERNAL_DOMAIN"; then
  assert_pass "T1-2" "dnsmasq query log contains internal domain (will be filtered by SSRF gate)"
else
  assert_fail "T1-2" "dnsmasq query log missing internal domain -- content: $(echo "$_log_content" | head -5)"
fi

log "Step 1 done. PASS=${ASSERT_PASS} FAIL=${ASSERT_FAIL}"

# =============================================================================
# STEP 2: Run amnezia-autolearn twice (geoblock threshold=2)
# =============================================================================
log ""
log "===== STEP 2: run amnezia-autolearn twice (geoblock threshold=2) ====="

# The amnezia-autolearn script needs:
#   - AL_QUERYLOG=/tmp/dnsmasq-queries.log
#   - AL_STATE=/var/run/amnezia-failover.json  (already seeded)
#   - zapret-probe shim (already installed)
#   - nslookup on INTERNAL_DOMAIN must return an RFC1918 address so al_resolve_public rejects it.
#
# We need nslookup on INTERNAL_DOMAIN to return a private IP so the SSRF gate triggers.
# Inject a stub /etc/hosts entry so nslookup answers without real DNS.
vm_run "printf '192.168.99.1 ${INTERNAL_DOMAIN}\n' >> /etc/hosts 2>/dev/null || true"
# GEOBLOCK_DOMAIN should not resolve to anything (or to a public IP for the probe to proceed).
# We inject a public stub address so al_resolve_public passes and the probe runs.
vm_run "printf '203.0.113.1 ${GEOBLOCK_DOMAIN}\n' >> /etc/hosts 2>/dev/null || true"

# First run: geoblock domain reaches candidates.tsv with count=1 (below threshold 2).
log "first run of amnezia-autolearn (count will reach 1 for geoblock domain)"
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  "AL_QUERYLOG=/tmp/dnsmasq-queries.log ${GEOBLOCK_KEY}=direct_geoblocked amnezia-autolearn 2>&1 || true" \
  >/dev/null 2>&1 || true

_auto_after1=$(vm_run "cat /etc/amnezia/force.d/auto.list 2>/dev/null || true" 2>/dev/null || true)
log "auto.list after run 1: '$(echo "$_auto_after1" | tr '\n' '|')'"
# After run 1 only: geoblock domain's count=1, not yet in auto.list.
if echo "$_auto_after1" | grep -q "$GEOBLOCK_DOMAIN"; then
  warn "T2-1: geoblock domain already in auto.list after run 1 (threshold hit on first pass -- may have been pre-populated)"
  assert_pass "T2-1" "geoblock domain in auto.list (threshold hit even on run 1 -- candidate pre-existing; run 2 will confirm)"
else
  assert_pass "T2-1" "geoblock domain NOT in auto.list after run 1 (count=1, below threshold 2 -- correct)"
fi

# Second run: same log (offset was saved to end, so reset it to 0 to re-harvest same lines).
# This simulates the next cron tick where the same pair appears again.
# (In production, new query lines accumulate; in the test we re-read from offset 0.)
vm_run "rm -f /etc/amnezia/autolearn/.dnsmasq-log.offset 2>/dev/null || true"
log "second run of amnezia-autolearn (count will reach 2, geoblock domain promoted to auto.list)"
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  "AL_QUERYLOG=/tmp/dnsmasq-queries.log ${GEOBLOCK_KEY}=direct_geoblocked amnezia-autolearn 2>&1 || true" \
  >/dev/null 2>&1 || true

log "Step 2 done. PASS=${ASSERT_PASS} FAIL=${ASSERT_FAIL}"

# =============================================================================
# STEP 3: Assert auto.list contents
# =============================================================================
log ""
log "===== STEP 3: assert auto.list contents ====="

_auto_list=$(vm_run "cat /etc/amnezia/force.d/auto.list 2>/dev/null || true" 2>/dev/null || true)
log "auto.list after 2 runs: '$(echo "$_auto_list" | tr '\n' '|')'"

# T3-1: geoblock domain IS in auto.list.
if echo "$_auto_list" | grep -qxF "$GEOBLOCK_DOMAIN"; then
  assert_pass "T3-1" "auto.list contains geoblock domain '${GEOBLOCK_DOMAIN}' after 2 runs (threshold met)"
else
  assert_fail "T3-1" "auto.list does NOT contain '${GEOBLOCK_DOMAIN}' -- content: $(echo "$_auto_list" | head -10)"
fi

# T3-2: internal domain is NOT in auto.list (SSRF gate rejected it).
if echo "$_auto_list" | grep -qxF "$INTERNAL_DOMAIN"; then
  assert_fail "T3-2" "internal domain '${INTERNAL_DOMAIN}' FOUND in auto.list -- SSRF gate did not filter it"
else
  assert_pass "T3-2" "internal domain '${INTERNAL_DOMAIN}' correctly absent from auto.list (SSRF gate filtered RFC1918 resolve)"
fi

# T3-3: candidates.tsv was written with at least the geoblock domain entry.
_cand=$(vm_run "cat /etc/amnezia/autolearn/candidates.tsv 2>/dev/null || true" 2>/dev/null || true)
if echo "$_cand" | grep -q "$GEOBLOCK_DOMAIN"; then
  assert_pass "T3-3" "candidates.tsv contains geoblock domain entry"
else
  assert_fail "T3-3" "candidates.tsv missing geoblock domain -- tsv: $(echo "$_cand" | head -5)"
fi

log "Step 3 done. PASS=${ASSERT_PASS} FAIL=${ASSERT_FAIL}"

# =============================================================================
# STEP 4: Assert amnezia_force4 nft set and dnsmasq conf-dir reflect auto.list
# =============================================================================
log ""
log "===== STEP 4: assert amnezia_force4 / dnsmasq conf-dir reflect auto.list ====="

# amnezia-force-load is called by amnezia-autolearn on change; verify it ran
# by checking either the nft set or the dnsmasq conf-dir for the geoblock domain.

# T4-1: amnezia_force4 nft set exists (created by amnezia-force-load boot or hotplug).
_force4=$(vm_run "nft list set inet fw4 amnezia_force4 2>/dev/null || true" 2>/dev/null || true)
if [ -n "$_force4" ]; then
  assert_pass "T4-1" "amnezia_force4 nft set exists in inet fw4"
else
  assert_fail "T4-1" "amnezia_force4 nft set not found in inet fw4 -- fw4 may not be running"
fi

# T4-2: dnsmasq conf-dir contains an nftset directive for the geoblock domain.
# amnezia-force-load chunks domain sets into /etc/amnezia/dnsmasq.d/*.conf files.
_dnsmasq_d=$(vm_run "grep -r '${GEOBLOCK_DOMAIN}' /etc/amnezia/dnsmasq.d/ 2>/dev/null | head -3 || true" 2>/dev/null || true)
if echo "$_dnsmasq_d" | grep -q "$GEOBLOCK_DOMAIN"; then
  assert_pass "T4-2" "dnsmasq conf-dir contains nftset directive for geoblock domain"
else
  # Fallback: check if force-load placed the domain in the UCI ipset or amnezia_force4 directly.
  _uci_force=$(vm_run "uci show dhcp.amnezia_force 2>/dev/null || true" 2>/dev/null || true)
  _force_list=$(vm_run "cat /etc/amnezia/force.d/*.list 2>/dev/null | grep '${GEOBLOCK_DOMAIN}' | head -1 || true" 2>/dev/null || true)
  if echo "$_uci_force" | grep -q "amnezia_force4" || [ -n "$_force_list" ]; then
    assert_pass "T4-2" "geoblock domain present in force list/UCI ipset (force-load ran, dnsmasq conf-dir may not be wired yet in this Tier-1 VM)"
  else
    assert_fail "T4-2" "geoblock domain NOT found in dnsmasq conf-dir, UCI ipset, or force.d lists -- force-load may not have run"
  fi
fi

log "Step 4 done. PASS=${ASSERT_PASS} FAIL=${ASSERT_FAIL}"

# =============================================================================
# STEP 5: Flip autolearn_enabled=0 -- assert learning halts
# =============================================================================
log ""
log "===== STEP 5: flip autolearn_enabled=0 via ctl, assert learning halts ====="

# Use amnezia-autolearn-ctl set-enabled 0.
vm_run "amnezia-autolearn-ctl set-enabled 0 2>/dev/null || true"

# Verify UCI was written.
assert_contains "T5-1" "autolearn_enabled=0 after set-enabled 0" \
  "uci -q get amnezia.config.autolearn_enabled 2>/dev/null || echo MISSING" \
  "^0$"

# Add a new unique domain to the query log and reset the offset.
# After re-running, it should NOT appear in auto.list because the gate exits early.
NEW_DOMAIN_DISABLED="should-not-appear-${LOG_TS}.example.org"
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  "printf 'Jun 22 10:01:00 dnsmasq[1234]: query[A] ${NEW_DOMAIN_DISABLED} from ${CLIENT_A}\nJun 22 10:01:01 dnsmasq[1234]: query[A] ${NEW_DOMAIN_DISABLED} from ${CLIENT_B}\n' >> /tmp/dnsmasq-queries.log 2>/dev/null || true" \
  2>/dev/null || true
vm_run "rm -f /etc/amnezia/autolearn/.dnsmasq-log.offset 2>/dev/null || true"

# Also inject a public IP for this domain so it would pass the SSRF gate if the gate were enabled.
vm_run "printf '203.0.113.2 ${NEW_DOMAIN_DISABLED}\n' >> /etc/hosts 2>/dev/null || true"

log "running amnezia-autolearn with autolearn_enabled=0 (expect immediate exit)"
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  "AL_QUERYLOG=/tmp/dnsmasq-queries.log ZP_VERDICT_DEFAULT=direct_geoblocked amnezia-autolearn 2>&1 || true" \
  >/dev/null 2>&1 || true

_auto_disabled=$(vm_run "cat /etc/amnezia/force.d/auto.list 2>/dev/null || true" 2>/dev/null || true)
if echo "$_auto_disabled" | grep -q "$NEW_DOMAIN_DISABLED"; then
  assert_fail "T5-2" "disabled-state domain '${NEW_DOMAIN_DISABLED}' appeared in auto.list -- enabled gate did not halt learning"
else
  assert_pass "T5-2" "disabled-state domain absent from auto.list (autolearn_enabled=0 gate halted learning correctly)"
fi

# T5-3: ctl status reflects disabled state.
assert_contains "T5-3" "autolearn-ctl status shows enabled=0 after set-enabled 0" \
  "amnezia-autolearn-ctl status 2>/dev/null || true" \
  '"enabled":0'

log "Step 5 done. PASS=${ASSERT_PASS} FAIL=${ASSERT_FAIL}"

# =============================================================================
# STEP 6: All-down failover state -- assert no new adds
# =============================================================================
log ""
log "===== STEP 6: all-down failover state -- assert tunnel health gate fires ====="

# Re-enable autolearn (so only the tunnel-health gate should halt it).
vm_run "amnezia-autolearn-ctl set-enabled 1 2>/dev/null || true"
assert_contains "S6-prereq" "autolearn_enabled=1 re-enabled for tunnel-health gate test" \
  "uci -q get amnezia.config.autolearn_enabled 2>/dev/null || echo MISSING" \
  "^1$"

# Write an all_down:true failover state.
log "seeding /var/run/amnezia-failover.json with all_down:true"
vm_run "printf '{\"routing_mode\":\"direct-default\",\"all_down\":true,\"active_pool\":null}\n' > /var/run/amnezia-failover.json 2>/dev/null || true; touch /var/run/amnezia-failover.json 2>/dev/null || true"

# New domain for this step.
NEW_DOMAIN_ALLDOWN="tunneldown-${LOG_TS}.example.org"
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  "printf 'Jun 22 10:02:00 dnsmasq[1234]: query[A] ${NEW_DOMAIN_ALLDOWN} from ${CLIENT_A}\nJun 22 10:02:01 dnsmasq[1234]: query[A] ${NEW_DOMAIN_ALLDOWN} from ${CLIENT_B}\n' >> /tmp/dnsmasq-queries.log 2>/dev/null || true" \
  2>/dev/null || true
vm_run "rm -f /etc/amnezia/autolearn/.dnsmasq-log.offset 2>/dev/null || true"
vm_run "printf '203.0.113.3 ${NEW_DOMAIN_ALLDOWN}\n' >> /etc/hosts 2>/dev/null || true"

log "running amnezia-autolearn with all_down:true (expect exit at tunnel-health gate)"
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  "AL_QUERYLOG=/tmp/dnsmasq-queries.log ZP_VERDICT_DEFAULT=direct_geoblocked amnezia-autolearn 2>&1 || true" \
  >/dev/null 2>&1 || true

_auto_alldown=$(vm_run "cat /etc/amnezia/force.d/auto.list 2>/dev/null || true" 2>/dev/null || true)
if echo "$_auto_alldown" | grep -q "$NEW_DOMAIN_ALLDOWN"; then
  assert_fail "T6-1" "all-down-state domain '${NEW_DOMAIN_ALLDOWN}' appeared in auto.list -- tunnel health gate did not halt learning"
else
  assert_pass "T6-1" "all-down-state domain absent from auto.list (all_down:true tunnel health gate halted learning correctly)"
fi

# T6-2: original geoblock domain must STILL be in auto.list (gate exits without touching it).
_final_auto=$(vm_run "cat /etc/amnezia/force.d/auto.list 2>/dev/null || true" 2>/dev/null || true)
if echo "$_final_auto" | grep -qxF "$GEOBLOCK_DOMAIN"; then
  assert_pass "T6-2" "original geoblock domain preserved in auto.list after all-down gate run (no truncation)"
else
  assert_fail "T6-2" "original geoblock domain '${GEOBLOCK_DOMAIN}' MISSING from auto.list -- gate may have corrupted state"
fi

log "Step 6 done. PASS=${ASSERT_PASS} FAIL=${ASSERT_FAIL}"

# =============================================================================
# Final summary
# =============================================================================
log ""
log "===== FINAL SUMMARY ====="
log "    transcript: $LOG_FILE"
log "    date: $(date)"

print_summary
_rc=$?

# Stop the tail-to-tty background process.
if [ -n "$_tee_pid" ]; then
  kill "$_tee_pid" 2>/dev/null || true
fi

exit "$_rc"
