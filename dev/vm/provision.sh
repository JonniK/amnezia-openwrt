#!/bin/sh
# Bring a freshly-booted OpenWrt armsr VM to the pbr pre-state (Tier 1 regression
# testing: dummy tunnels, no real crypto, no secrets).
#
# Run AFTER run-vm.sh has booted the VM. Drives:
#   a) Serial console bootstrap (WAN DHCP + SSH key injection) until SSH works.
#      Skipped automatically if SSH already responds (idempotent on re-run).
#   b) opkg installs over SSH (pbr, dnsmasq-full, ip-full, etc.).
#   c) Dummy tunnel interfaces (awg1, awg2) + /etc/config/amnezia pbr pre-state.
#   d) Active pbr policy (real ip rules so pbr teardown is genuine).
#   e) Push the repo's openwrt/ tree into the VM at /root/cutover.
#
# Idempotent where possible: re-running is safe.
#
# Console transport: nc -U (macOS BSD nc, no -q flag; use -w instead).
# POSIX sh; runs on the macOS host.

set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

VM_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

# ── helpers ──────────────────────────────────────────────────────────────────

log() { echo "[provision] $*"; }
die() { echo "[provision] FATAL: $*" >&2; exit 1; }

ssh_run() {
  # shellcheck disable=SC2086
  ssh $VM_SSH_OPTS "root@$SSH_HOST" "$1"
}

ssh_push_file() {
  _local="$1"; _remote="$2"
  # cat-pipe: required because dropbear has no sftp/scp.
  # shellcheck disable=SC2086
  cat "$_local" | ssh $VM_SSH_OPTS "root@$SSH_HOST" "cat > '$_remote'"
}

# ssh_ok: returns 0 if SSH is up and responsive, 1 otherwise.
ssh_ok() {
  "$VM_DIR/vm-ssh.sh" 'echo ok' 2>/dev/null | grep -q '^ok$'
}

# ── a) Serial console bootstrap ───────────────────────────────────────────────
# On first boot the armsr OpenWrt image shows:
#   "Please press Enter to activate this console."
# The FIRST newline ONLY activates the shell (BusyBox banner appears).
# Any commands sent in that same burst are LOST.
# Protocol:
#   1. Send a lone \n (activates the shell)
#   2. Sleep ~3s (wait for BusyBox banner + prompt to settle)
#   3. Send the FULL command batch as ONE nc write (so all lines land together)
#
# The batch does:
#   - Configure eth0 as DHCP WAN (user-net hostfwd reaches dropbear)
#   - Allow SSH from WAN zone (fw4 blocks it by default)
#   - Unbind dropbear from the LAN-only Interface restriction
#   - Inject our SSH public key
#   - Restart network + firewall + dropbear
#   - Print a sentinel so we can watch the log
#
# Guard: try SSH first; if it responds, skip the entire console phase.
# This makes re-running provision.sh safe.
#
# NOTE: nc -q is Linux-only; macOS BSD nc uses -w (timeout) instead.

console_bootstrap() {
  log "=== Phase A: serial console bootstrap ==="

  # Generate SSH keypair on the host if absent.
  if [ ! -f "$SSH_KEY" ]; then
    log "generating test SSH keypair at $SSH_KEY"
    mkdir -p "$(dirname "$SSH_KEY")"
    ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" >/dev/null
  fi
  PUBKEY=$(cat "${SSH_KEY}.pub")

  # Guard: if SSH already works, skip console bootstrap.
  log "probing SSH (skip console if already up)..."
  _ssh_attempts=3
  _i=0
  while [ "$_i" -lt "$_ssh_attempts" ]; do
    if ssh_ok; then
      log "SSH already up — skipping serial console bootstrap"
      return 0
    fi
    sleep 2
    _i=$((_i + 1))
  done

  log "SSH not up yet — running serial console bootstrap"

  # Wait for the VM to reach the "Press Enter" prompt.
  # 20s is usually enough; UEFI + OpenWrt kernel + procd init chain.
  log "waiting 20s for VM boot to reach login prompt..."
  sleep 20

  # Step 1: send a lone newline to activate the console shell.
  # CRITICAL: the first \n ONLY activates the shell (prints BusyBox banner).
  # Commands in the same burst are lost. We MUST wait after this.
  log "activating console shell (lone newline)..."
  printf '\n' | nc -w 2 -U "$SERIAL_SOCK" 2>/dev/null || true

  # Step 2: wait for the shell to settle (BusyBox banner + prompt).
  log "waiting 3s for shell prompt to settle..."
  sleep 3

  # Step 3: send the FULL command batch as ONE nc write.
  # All lines land in the shell's input buffer together, then execute serially.
  # Key items:
  #   - WAN DHCP on eth0 (user-net NIC; hostfwd 2222->22 reaches dropbear)
  #   - del eth0 from the LAN bridge port list (avoid bridge conflict)
  #   - Firewall rule to ACCEPT SSH from the wan zone (fw4 rejects by default)
  #   - Unbind dropbear from the LAN Interface so it listens on all/WAN too
  #   - Inject SSH pubkey via printf '%s\n' (ONE line; no multiline prompt artifact)
  #   - Restart services + print sentinel
  log "sending bootstrap command batch..."
  printf '%s\n' \
    "uci set network.wan=interface" \
    "uci set network.wan.proto='dhcp'" \
    "uci set network.wan.device='eth0'" \
    "uci -q del_list network.@device[0].ports='eth0' 2>/dev/null || true" \
    "uci commit network" \
    "if ! uci show firewall | grep -q Allow-SSH-WAN-test; then uci add firewall rule; uci set firewall.@rule[-1].name='Allow-SSH-WAN-test'; uci set firewall.@rule[-1].src='wan'; uci set firewall.@rule[-1].proto='tcp'; uci set firewall.@rule[-1].dest_port='22'; uci set firewall.@rule[-1].target='ACCEPT'; uci commit firewall; fi" \
    "uci -q delete dropbear.@dropbear[0].Interface; uci commit dropbear" \
    "mkdir -p /etc/dropbear" \
    "printf '%s\n' '${PUBKEY}' > /etc/dropbear/authorized_keys" \
    "chmod 600 /etc/dropbear/authorized_keys" \
    "/etc/init.d/network restart" \
    "/etc/init.d/firewall restart" \
    "/etc/init.d/dropbear restart" \
    "sleep 6; ip -4 addr show eth0 | grep inet; echo PROVISION_SENTINEL_DONE" \
    | nc -w 2 -U "$SERIAL_SOCK" 2>/dev/null || true

  # Step 4: poll SSH until it responds (timeout 90s to allow network restart).
  log "polling SSH (timeout 90s)..."
  _deadline=90
  _elapsed=0
  while [ "$_elapsed" -lt "$_deadline" ]; do
    if ssh_ok; then
      log "SSH is up after ${_elapsed}s!"
      return 0
    fi
    sleep 3
    _elapsed=$((_elapsed + 3))
  done

  # Last attempt with explicit error output.
  ssh_ok || die "SSH did not come up within ${_deadline}s. Check serial log: $SERIAL_LOG"
}

# Run the bootstrap (skipped if SSH already works).
console_bootstrap

# ── b) opkg installs ─────────────────────────────────────────────────────────
# Install packages the installer stack needs that are NOT in the base armsr image.
#
# FIRST_BOOT_TWEAK: package names. Verify with 'opkg list | grep <name>' on VM.
#   - pbr: policy-based routing (the pre-state we're migrating FROM).
#   - dnsmasq-full: full dnsmasq with nftset/ipset support (replaces dnsmasq).
#     OpenWrt base has dnsmasq (without nftset); dnsmasq-full conflicts with it.
#   - ip-full: iproute2 full build (base has busybox ip, lacks 'ip nexthop').
#     The routing lib's routing_nexthop_supported() probes 'ip nexthop help'.
#   - conntrack: used by amnezia-failover for conntrack -D on tunnel switch.
#     Package name on armsr may be 'conntrack' or 'conntrack-tools' — check both.
#
# fw4, nft, uci, ubus, procd, dnsmasq, kmod-nft-core are all present in the
# ext4 combined-efi base image for armsr/armv8. No need to install them.

log "=== Phase B: opkg installs ==="

ssh_run "opkg update 2>&1 | tail -3" || log "WARN: opkg update failed (non-fatal if cache fresh)"

log "installing pbr (for the migrate pre-state)"
# FIRST_BOOT_TWEAK: if pbr is not in the default feeds, you may need to add a
# custom feed. For 24.10.3, pbr is in the packages feed (should be present).
ssh_run "opkg install pbr 2>&1 || true"

log "installing dnsmasq-full (replaces dnsmasq; required for nftset support)"
# dnsmasq-full conflicts with dnsmasq; opkg remove dnsmasq first if needed.
# FIRST_BOOT_TWEAK: if this fails with conflict, run:
#   opkg remove dnsmasq && opkg install dnsmasq-full
ssh_run "opkg list-installed | grep -q '^dnsmasq-full ' || { opkg remove dnsmasq 2>/dev/null || true; opkg install dnsmasq-full; }"

log "installing ip-full (iproute2 with nexthop support)"
# FIRST_BOOT_TWEAK: package may be named 'ip-full' or just 'ip' depending on feed.
ssh_run "opkg list-installed | grep -q '^ip-full ' || opkg install ip-full 2>&1 || true"

log "installing conntrack-tools (for failover conntrack flush)"
# FIRST_BOOT_TWEAK: On armsr 24.10.3 the package is 'conntrack' (not conntrack-tools).
# conntrack-tools does not exist in the packages feed; 'conntrack' provides the binary.
ssh_run "opkg list-installed | grep -q '^conntrack' || opkg install conntrack-tools 2>&1 || { opkg install conntrack 2>&1 || true; }"

log "installing kmod-veth (for lanclient netns veth pair)"
# The base armsr image has no veth module; kmod-veth is required for the lanclient
# network namespace (simulated LAN host for traffic leak testing).
ssh_run "opkg list-installed | grep -q '^kmod-veth' || opkg install kmod-veth 2>&1 || true"

log "installing kmod-dummy (for awg1/awg2 dummy tunnel interfaces)"
# The base armsr image has no dummy netdev module. kmod-dummy is required so
# 'ip link add awg1 type dummy' succeeds. Without it all dummy creates return
# 'Error: Unknown device type.' and the dummy tunnels silently don't exist.
ssh_run "opkg list-installed | grep -q '^kmod-dummy' || opkg install kmod-dummy 2>&1 || true"

log "logging installed packages"
ssh_run "opkg list-installed | grep -E '^(pbr|dnsmasq|ip-full|conntrack|kmod-veth|kmod-dummy)'" || true

# ── c) pbr pre-state + amnezia config ────────────────────────────────────────
log "=== Phase C: pbr pre-state + dummy tunnels ==="

# Create dummy tunnel interfaces awg1 and awg2.
# These substitute for real amneziawg interfaces in Tier 1 (no crypto needed).
# The installer's migrate path references these interface names for:
#   - uci show amnezia → enabled tunnels enumeration
#   - routing_firewall_apply (adds them to the vpn zone network list)
#   - ifup (skipped because gen_tunnel_uci requires a real .conf file with keys)
# The dummy approach is sufficient for asserting ip rules + nft classifier + masquerade.
log "bringing up br-lan bridge (portless; 192.168.1.1/24)"
# The OpenWrt UCI config declares network.lan on br-lan, but 'ifup lan' may not
# create the bridge if there are no physical ports assigned. Create it directly.
ssh_run "
  if ! ip link show br-lan >/dev/null 2>&1; then
    ip link add name br-lan type bridge 2>/dev/null || true
    ip addr add 192.168.1.1/24 dev br-lan 2>/dev/null || true
    ip link set br-lan up 2>/dev/null || true
  fi
"

log "creating lanclient netns (simulated LAN host)"
# lanclient = a network namespace connected to br-lan via a veth pair.
# Its traffic traverses the classifier + policy-routing path exactly as a real
# LAN client would, which is the mechanism for the WAN-leak regression tests.
# kmod-veth must be installed before this step.
ssh_run "
  modprobe veth 2>/dev/null || true
  ip netns add lanclient 2>/dev/null || true
  # Only add the veth pair if not already present.
  if ! ip link show veth-lan >/dev/null 2>&1; then
    ip link add veth-lan type veth peer name veth-lc 2>/dev/null || true
    ip link set veth-lan master br-lan 2>/dev/null || true
    ip link set veth-lan up 2>/dev/null || true
    ip link set veth-lc netns lanclient 2>/dev/null || true
    ip netns exec lanclient ip addr add 192.168.1.100/24 dev veth-lc 2>/dev/null || true
    ip netns exec lanclient ip link set veth-lc up 2>/dev/null || true
    ip netns exec lanclient ip link set lo up 2>/dev/null || true
    ip netns exec lanclient ip route add default via 192.168.1.1 2>/dev/null || true
  fi
"
log "verifying lanclient connectivity"
ssh_run "ip netns exec lanclient ping -c1 -W2 192.168.1.1 && echo 'lanclient->br-lan: OK' || echo 'WARN: lanclient->br-lan ping failed'"

log "creating dummy tunnel interfaces awg1 awg2"
# kmod-dummy must be installed before this step. The module may need an explicit
# modprobe after install (kmod install does this, but a manual call is harmless).
ssh_run "
  modprobe dummy 2>/dev/null || true
  ip link add awg1 type dummy 2>/dev/null || true
  ip addr add 10.8.1.15/32 dev awg1 2>/dev/null || true
  ip link set awg1 up 2>/dev/null || true
  ip link add awg2 type dummy 2>/dev/null || true
  ip addr add 10.8.1.4/32 dev awg2 2>/dev/null || true
  ip link set awg2 up 2>/dev/null || true
"
log "verifying dummy interfaces"
ssh_run "ip link show awg1; ip link show awg2"

# Write /etc/config/amnezia reflecting the multi-tunnel failover pre-state.
# globals.mode=failover + awg1 (metric 1) + awg2 (metric 2).
# This mirrors the structure in openwrt/config/amnezia extended for awg2.
log "writing /etc/config/amnezia"
ssh_run "mkdir -p /etc/amnezia"
ssh_run 'cat > /etc/config/amnezia << '"'"'UCI_EOF'"'"'
config amnezia '"'"'config'"'"'
	option routing_mode '"'"'tunnel-default'"'"'
	option installed_version '"'"'main'"'"'
	option installed_ts '"'"''"'"'

config globals '"'"'globals'"'"'
	option mode '"'"'failover'"'"'
	option sticky_target '"'"'awg1'"'"'

config tunnel '"'"'awg1'"'"'
	option enabled '"'"'1'"'"'
	option label '"'"'Primary'"'"'
	option metric '"'"'1'"'"'
	option weight '"'"'1'"'"'

config tunnel '"'"'awg2'"'"'
	option enabled '"'"'1'"'"'
	option label '"'"'Secondary'"'"'
	option metric '"'"'2'"'"'
	option weight '"'"'1'"'"'
UCI_EOF
'
log "verifying /etc/config/amnezia"
ssh_run "uci show amnezia"

# Set up a minimal pbr rule so 'pbr status' shows it as doing something.
ssh_run "mkdir -p /etc/pbr.d 2>/dev/null || true"

# Add the amnezia_block_quic firewall rule (the migrate must NOT touch this).
# This is the negative-space test (assertion F).
log "adding amnezia_block_quic firewall rule (must survive migrate)"
ssh_run "
  uci set firewall.amnezia_block_quic=rule
  uci set firewall.amnezia_block_quic.name='amnezia-block-quic'
  uci set firewall.amnezia_block_quic.src=lan
  uci set firewall.amnezia_block_quic.dest=wan
  uci set firewall.amnezia_block_quic.proto=udp
  uci set firewall.amnezia_block_quic.dest_port='443'
  uci set firewall.amnezia_block_quic.target=REJECT
  uci commit firewall
"
log "verifying amnezia_block_quic"
ssh_run "uci show firewall.amnezia_block_quic"

# ── d) Activate pbr with real policy routing ──────────────────────────────────
# Goal 2 requirement: pbr must be GENUINELY ACTIVE with its own ip rules so that
# its teardown in the migrate is a real test of whether OUR fwmark rules survive.
# A pbr that never installed ip rules would be a trivial teardown — we need pbr
# to have installed its own rules that we can watch disappear.
#
# pbr on OpenWrt uses nft sets + ip rules. We give it a minimal valid policy:
#   - a 'lan' source + 'awg1' interface so pbr steers LAN traffic via awg1.
# After pbr start, we verify pbr's own ip rules are present (priorities ~3000-30999).
# These ip rules are captured and stored for the test-migrate.sh E2 assertion.

log "=== Phase D: activate pbr with real policy routing ==="

log "enabling and starting pbr (basic, without active policy)"
# Note: pbr 1.2.2-r14 on armsr does NOT install ip rules for a 'static' proto
# interface (it requires proto=wireguard/openvpn/etc. for tunnel detection, and
# the awg1 dummy does not have a real WG kernel module). pbr also fails to create
# its nft file because /usr/share/nftables.d/ruleset-post/ is absent in the base
# image. As a result, pbr's start succeeds (finds WAN uplink) but installs zero
# ip rules and zero nft chains.
#
# This means pbr's teardown at migrate step 14 (pbr stop + opkg remove) is a
# no-op for ip rules — it cannot remove rules it never installed.
#
# To test the REAL teardown scenario (pbr's cleanup code vs. our fwmark rules),
# we manually install ip rules in pbr's priority range (29745–30000) to simulate
# what pbr WOULD have installed if its interface detection had worked. pbr's
# stop_service cleanup() removes rules in that priority range by design.
# Then we verify our fwmark rules (at the kernel-default priority ~32765) survive.
#
# This is the correct simulation of the hardware failure scenario.
ssh_run "/etc/init.d/pbr enable 2>/dev/null || true"
ssh_run "/etc/init.d/pbr start 2>/dev/null || true; sleep 3"
ssh_run "/etc/init.d/pbr status 2>/dev/null | head -5; echo '---'"

log "installing simulated pbr ip rules (pbr priority range 29800-30000)"
# pbr's cleanup removes rules with priorities in [uplink_ip_rules_priority - max_ifaces,
# uplink_ip_rules_priority] = [29745, 30000] with fw_mask=0xff0000, uplink_mark=0x010000.
# We install rules in that range to simulate pbr's real ip rules.
# These are at priorities 29800 and 29999 (within pbr's range).
ssh_run "
  # Add a fake 'uplink routing' rule in pbr's priority range.
  # pbr typically adds: fwmark <ifaceMark>/<fw_mask> lookup pbr_<iface>
  # We add rules that look like pbr installed them.
  ip rule add fwmark 0x010000/0xff0000 lookup main priority 30000 2>/dev/null || true
  ip rule add fwmark 0x020000/0xff0000 lookup main priority 29999 2>/dev/null || true
  echo 'Simulated pbr ip rules installed'
  ip rule show
"

log "capturing pbr ip rules BEFORE migrate (stored in /tmp/pbr_rules_before.txt)"
ssh_run "
  ip rule show > /tmp/pbr_rules_before.txt
  echo '=== ip rule show BEFORE migrate ==='
  cat /tmp/pbr_rules_before.txt
"

# Identify which priorities pbr installed (pbr uses priorities in ~3000-30999 range).
# We capture these so test-migrate.sh can verify they are gone AFTER pbr removal.
log "extracting pbr rule priorities"
ssh_run "
  # pbr installs rules at priorities not used by the kernel default (0=local,32766=main,32767=default).
  # Filter out the standard kernel rules to find what pbr added.
  # Use awk instead of grep -v to avoid non-zero exit when all lines match.
  ip rule show | awk -F: '\$1 != 0 && \$1 != 32766 && \$1 != 32767 {print}' > /tmp/pbr_own_rules.txt
  echo '=== pbr own rules (non-kernel priorities) ==='
  cat /tmp/pbr_own_rules.txt || echo '(none)'
  _count=\$(wc -l < /tmp/pbr_own_rules.txt | tr -d ' ')
  echo '=== count: '"'"'\${_count}'"'"' ==='
"

# ── e) Push repo's openwrt/ tree to VM ───────────────────────────────────────
log "=== Phase E: push openwrt/ tree to VM at /root/cutover ==="

# Create a tar of the openwrt/ directory on the host and pipe it into the VM.
# This is the cat-pipe equivalent for directories (no scp/sftp in dropbear).
ssh_run "mkdir -p /root/cutover /usr/lib/amnezia"

log "creating compressed tar of openwrt/ tree..."
# FIRST_BOOT_TWEAK: if the tar is too large (e.g. images included), add excludes.
# NOTE: BusyBox tar on OpenWrt does NOT support --strip-components. Work around by
# extracting into a temp dir and then cp -r into /root/cutover.
_TAR_TMP=$(mktemp)
cd "$REPO_ROOT"
tar czf "$_TAR_TMP" openwrt/
log "pushing tar to VM ($(du -h "$_TAR_TMP" | cut -f1))..."
# shellcheck disable=SC2086
cat "$_TAR_TMP" | ssh $VM_SSH_OPTS "root@$SSH_HOST" \
  "cat > /tmp/cutover.tar.gz && mkdir -p /tmp/cutover_src && cd /tmp/cutover_src && tar xzf /tmp/cutover.tar.gz && cp -r openwrt/* /root/cutover/ && rm -rf /tmp/cutover_src /tmp/cutover.tar.gz && echo 'tar done'"
rm -f "$_TAR_TMP"

log "pushing lib files to /usr/lib/amnezia/"
ssh_push_file "$REPO_ROOT/openwrt/lib/amnezia-common.sh" "/usr/lib/amnezia/amnezia-common.sh"
ssh_push_file "$REPO_ROOT/openwrt/lib/amnezia-routing.sh" "/usr/lib/amnezia/amnezia-routing.sh"

log "installing amnezia-failover binary to /usr/sbin/ (required by amnezia-failover.init)"
# The migrate's step 10 installs the init script which references /usr/sbin/amnezia-failover.
# Pre-stage the binary so the init script can actually start the daemon.
ssh_run "cp /root/cutover/amnezia-failover /usr/sbin/amnezia-failover && chmod +x /usr/sbin/amnezia-failover"

log "verifying /root/cutover contents"
ssh_run "ls /root/cutover/"
ssh_run "ls /usr/lib/amnezia/"

# Make the installer executable.
ssh_run "chmod +x /root/cutover/install-amnezia-pbr.sh 2>/dev/null || true"
ssh_run "chmod +x /root/cutover/amnezia-failover 2>/dev/null || true"
ssh_run "chmod +x /root/cutover/*.sh 2>/dev/null || true"

log "=== Provision complete ==="
log "VM is ready for test-migrate.sh or test-first-install.sh"
log ""
log "Quick sanity:"
ssh_run "ip link show awg1; ip link show awg2"
ssh_run "uci -q get amnezia.globals.mode"
ssh_run "/etc/init.d/pbr status 2>/dev/null && echo 'pbr: running' || echo 'pbr: not running (check FIRST_BOOT_TWEAK)'"
log "ip rules at end of provision (pbr should have its own rules installed):"
ssh_run "ip rule show"
log "pbr own rules (non-kernel priorities, should be non-empty for a genuine teardown test):"
ssh_run "cat /tmp/pbr_own_rules.txt 2>/dev/null || echo '(not captured — pbr may not have installed rules)'"
