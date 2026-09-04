#!/bin/sh
# Test the covert-creator --uninstall reverse teardown, and confirm the
# MAIN routing stack (ip rules, classifier, WAN/DNS) survives it untouched.
#
# Runs against a VM that has ALREADY had the installer run with
# --first-install (test-all.sh Scenario 4 provisions this: fresh disk ->
# provision.sh --first-install -> installer --first-install over SSH, so
# amnezia-covert user/dir/log exist per test-first-install.sh's H block --
# see assert_covert_installed() in assert.sh for what --first-install
# actually creates).
#
# Verified against install-amnezia-pbr.sh's covert_uninstall() (2026-09-04),
# in its actual reverse order:
#   1. amnezia-covert-ctl disable (best-effort; resolves from
#      /root/cutover/amnezia-covert-ctl.sh via resolve_dep since it was
#      never self-installed to /usr/bin by this harness's --first-install)
#   2. rm -f /etc/init.d/amnezia-covert
#   3. rm -f the creator binary + BUILD_MANIFEST
#   4. rm -rf /etc/amnezia/covert (the dir + log H2/H3 created)
#   5. strip the two covert grants from the rpcd ACL file + repair any
#      dangling trailing comma so json-c still parses it
#   6. deluser/delgroup amnezia-covert LAST, after every file reference is gone
#
# NOTE: /usr/bin/amnezia-covert-ctl, /etc/init.d/amnezia-covert,
# /usr/lib/amnezia/amnezia-covert-{run,logwrap}.sh and the egress template
# are NOT self-installed by --first-install in this raw-script VM harness
# (they are .ipk-only -- see dev/sync-to-packages.sh). So checks I2 below
# confirm they are absent post-uninstall, which is true both because
# covert_uninstall removes them AND because they were never present to
# begin with in this harness -- the meaningful regression guards here are
# I1 (user/group actually deleted) and I3 (the dir --first-install DID
# create is actually removed). The rpcd ACL file (I4) is similarly never
# staged in this harness (luci-app-amnezia refresh is dev-deploy-only), so
# I4 degrades to a documented skip when the file is absent.
#
# Exit code: 0 = all PASS, 1 = one or more FAIL.
# POSIX sh; runs on the macOS HOST.

set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/assert.sh"

VM_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

log() { echo "[test-uninstall] $*"; }
die() { echo "[test-uninstall] FATAL: $*" >&2; exit 1; }

# Verify SSH connectivity.
"$VM_DIR/vm-ssh.sh" 'echo ok' | grep -q '^ok$' || \
  die "VM not reachable over SSH -- is the VM booted and provisioned with --first-install?"

# ── Pre-condition: covert IS present (installer --first-install already ran) ──
log "=== Pre-condition: amnezia-covert must be present at uid=391 ==="
_pre_uid=$(vm_run "id -u amnezia-covert 2>/dev/null" 2>/dev/null || true)
if [ "$_pre_uid" != "391" ]; then
  die "amnezia-covert user absent/wrong uid ('$_pre_uid') -- wrong VM state; run the installer --first-install before this test (test-all.sh Scenario 4 does this automatically)."
fi
log "OK: amnezia-covert present at uid=391 -- proceeding to uninstall"

# ── Baseline: capture main-routing health BEFORE uninstall (not asserted --
# just logged, so a post-uninstall regression is attributable to the
# uninstall itself rather than a pre-existing gap). ────────────────────────
log "=== Baseline (before --uninstall) ==="
_base_rules=$(vm_run "ip rule show" 2>/dev/null || true)
_base_classify=$(vm_run "nft list chain inet fw4 amnezia_classify 2>/dev/null | head -1" 2>/dev/null || true)
_base_default=$(vm_run "ip route show default" 2>/dev/null || true)
log "baseline ip rule show:"
echo "$_base_rules"
log "baseline amnezia_classify chain present: $([ -n "$_base_classify" ] && echo yes || echo no)"
log "baseline default route: $_base_default"

# ── Run the uninstall ───────────────────────────────────────────────────────
log "=== Running installer --uninstall inside VM ==="
# shellcheck disable=SC2086
ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  'sh /root/cutover/install-amnezia-pbr.sh --uninstall 2>&1' \
  && log "installer --uninstall returned 0" \
  || log "WARN: installer --uninstall returned non-zero (assertions may clarify)"

log "=== Assertions I: covert teardown ==="

# ── I1: amnezia-covert user + group GONE ────────────────────────────────────
_post_uid=$(vm_run "id -u amnezia-covert 2>/dev/null" 2>/dev/null || true)
_post_gid=$(vm_run "id -g amnezia-covert 2>/dev/null" 2>/dev/null || true)
if [ -z "$_post_uid" ] && [ -z "$_post_gid" ]; then
  assert_pass "I1" "amnezia-covert user+group removed by --uninstall"
else
  assert_fail "I1" "amnezia-covert user/group SURVIVED --uninstall -- id -u: '$_post_uid' id -g: '$_post_gid'"
fi

# ── I2: covert-ctl/init/lib/template files GONE ─────────────────────────────
# (never self-installed by --first-install in this harness; still asserted
# absent so a future installer version that DOES self-install them is caught
# if --uninstall regresses.)
_i2_leftover=""
for _f in /usr/bin/amnezia-covert-ctl \
          /etc/init.d/amnezia-covert \
          /usr/lib/amnezia/amnezia-covert-run.sh \
          /usr/lib/amnezia/amnezia-covert-logwrap.sh \
          /usr/share/amnezia/nftables.d/40-amnezia-covert-egress.nft \
          /etc/amnezia/covert/BUILD_MANIFEST; do
  if vm_run_rc "test -e $_f"; then
    _i2_leftover="$_i2_leftover $_f"
  fi
done
if [ -z "$_i2_leftover" ]; then
  assert_pass "I2" "covert-ctl/init/lib/template files absent after --uninstall"
else
  assert_fail "I2" "covert files SURVIVED --uninstall:$_i2_leftover"
fi

# ── I3: /etc/amnezia/covert dir GONE (the dir H2/H3 confirmed --first-install created) ──
if vm_run_rc "test -e /etc/amnezia/covert"; then
  assert_fail "I3" "/etc/amnezia/covert dir SURVIVED --uninstall"
else
  assert_pass "I3" "/etc/amnezia/covert dir removed by --uninstall"
fi

# ── I4: rpcd ACL still parses, covert grants gone (skip gracefully if the
# ACL was never staged in this harness -- luci-app-amnezia refresh is
# dev-deploy-only, see install-amnezia-pbr.sh:1579). ────────────────────────
_acl_path="/usr/share/rpcd/acl.d/luci-app-amnezia.json"
if vm_run_rc "test -f $_acl_path"; then
  if vm_run_rc "jsonfilter -i $_acl_path -e '@' >/dev/null"; then
    assert_pass "I4a" "rpcd ACL file still parses as valid JSON after covert-grant removal"
  else
    assert_fail "I4a" "rpcd ACL file FAILED to parse after covert-grant removal (dangling comma repair broken?)"
  fi
  assert_not_contains "I4b" "rpcd ACL no longer grants amnezia-covert-ctl exec" "cat $_acl_path" "amnezia-covert-ctl"
else
  assert_pass "I4a" "rpcd ACL file not staged in this harness (luci-app-amnezia is dev-deploy-only) -- N/A, skipping"
  assert_pass "I4b" "rpcd ACL file not staged in this harness -- N/A, skipping"
fi

log "=== Assertions J: main routing survives --uninstall (the whole point) ==="

# ── J: ip rules, classifier, no-WAN-leak still hold ─────────────────────────
log "J-ip-rules: fwmark ip rules survive --uninstall"
assert_ip_rules_present

log "J-classifier: nft classifier chain survives --uninstall"
assert_classifier_live

log "J-no-wan-leak: marked traffic still never leaks to WAN"
assert_no_wan_leak

# ── J-default-route: default route + DNS still functional ──────────────────
_post_default=$(vm_run "ip route show default" 2>/dev/null || true)
if [ -n "$_post_default" ]; then
  assert_pass "J-default-route" "default route present after --uninstall: $_post_default"
else
  assert_fail "J-default-route" "default route MISSING after --uninstall -- WAN may be broken"
fi

# ── J-dns: DNS resolution, ADVISORY only ────────────────────────────────────
# test-tunnel-mgmt.sh documents this same VM blind spot: dnsmasq is not
# reachable by the in-VM nslookup probe in this WAN-only harness (no LAN
# bridge client netns wired to it here), so a failure here is not evidence
# of a real regression. Logged for visibility, never asserted pass/fail.
_dns_out=$(vm_run "nslookup openwrt.org 127.0.0.1 2>&1" 2>/dev/null || true)
if echo "$_dns_out" | grep -qE "Address|Name"; then
  log "J-dns (advisory): DNS resolves via local dnsmasq after --uninstall"
else
  log "J-dns (advisory): DNS probe did not resolve after --uninstall -- known WAN-only-harness blind spot (see test-tunnel-mgmt.sh), not asserted: $(echo "$_dns_out" | head -3)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
