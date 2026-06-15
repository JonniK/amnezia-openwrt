#!/bin/sh
# Bring a freshly-booted OpenWrt armsr VM to the pbr pre-state (Tier 1 regression
# testing: dummy tunnels, no real crypto, no secrets).
#
# Run AFTER run-vm.sh has booted the VM. Drives:
#   a) Serial console setup (WAN DHCP + SSH key injection) until SSH works.
#   b) opkg installs over SSH (pbr, dnsmasq-full, ip-full, etc.).
#   c) Dummy tunnel interfaces (awg1, awg2) + /etc/config/amnezia pbr pre-state.
#   d) Push the repo's openwrt/ tree into the VM at /root/cutover.
#
# Idempotent where possible: re-running is safe.
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

# ── a) Serial console: WAN + SSH key ─────────────────────────────────────────
# The armsr OpenWrt image boots to a root shell with no password and no WAN.
# We drive the console to:
#   1. Detect the WAN NIC name (should be eth0 on virtio; verify via ip link).
#   2. Configure DHCP WAN + restart network.
#   3. Inject our SSH public key so password-less SSH works.
#
# FIRST_BOOT_TWEAK: if eth0 is not the NIC name, adjust WAN_DEV here.
# On armsr/armv8 with a single virtio-net-pci, it is almost always eth0.
# Check: console.sh read | grep -E '^[0-9]+: '  (ip link output after boot).

log "=== Phase A: serial console provisioning ==="

# Generate SSH keypair on the host if absent.
if [ ! -f "$SSH_KEY" ]; then
  log "generating test SSH keypair at $SSH_KEY"
  mkdir -p "$(dirname "$SSH_KEY")"
  ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" >/dev/null
fi
PUBKEY=$(cat "${SSH_KEY}.pub")

# Wait briefly for the VM to reach the boot shell prompt.
log "waiting 20s for VM to reach login prompt..."
sleep 20

# Probe WAN device name. The armsr kernel names the first virtio-net as eth0.
# If the VM names it something else (e.g. ens3) this step will need adjustment.
# FIRST_BOOT_TWEAK: verify WAN_DEV matches actual 'ip link' output in the VM.
WAN_DEV="eth0"

log "configuring WAN as DHCP on $WAN_DEV via console"

# UCI: configure a wan interface for DHCP on the detected NIC.
"$VM_DIR/console.sh" send "uci set network.wan=interface"
sleep 0.5
"$VM_DIR/console.sh" send "uci set network.wan.proto=dhcp"
sleep 0.5
"$VM_DIR/console.sh" send "uci set network.wan.device=$WAN_DEV"
sleep 0.5
"$VM_DIR/console.sh" send "uci commit network"
sleep 0.5
"$VM_DIR/console.sh" send "/etc/init.d/network restart"
sleep 8

# Inject SSH pubkey into dropbear's authorized_keys.
# FIRST_BOOT_TWEAK: dropbear on OpenWrt 24.10 uses /etc/dropbear/authorized_keys.
# Older builds used /root/.ssh/authorized_keys. Confirm on first boot.
log "injecting SSH pubkey into VM"
"$VM_DIR/console.sh" send "mkdir -p /etc/dropbear"
sleep 0.3
# Write the pubkey via echo — the quote escaping is safe for ed25519 keys
# (no shell-special characters in base64 + algo string).
"$VM_DIR/console.sh" send "echo '$PUBKEY' > /etc/dropbear/authorized_keys"
sleep 0.3
"$VM_DIR/console.sh" send "chmod 600 /etc/dropbear/authorized_keys"
sleep 0.3

log "waiting for dropbear to be reachable on $SSH_HOST:$SSH_PORT..."
_deadline=60
_elapsed=0
while [ "$_elapsed" -lt "$_deadline" ]; do
  if "$VM_DIR/vm-ssh.sh" 'echo ok' 2>/dev/null | grep -q '^ok$'; then
    log "SSH is up!"
    break
  fi
  sleep 3
  _elapsed=$((_elapsed + 3))
done
"$VM_DIR/vm-ssh.sh" 'echo ok' | grep -q '^ok$' || die "SSH did not come up within ${_deadline}s"

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

# Enable pbr so the installer's detection logic (/etc/init.d/pbr status) sees it.
log "enabling pbr service"
ssh_run "/etc/init.d/pbr enable 2>/dev/null || true"
# Start pbr so 'status' returns active (installer checks 'pbr status').
ssh_run "/etc/init.d/pbr start 2>/dev/null || true"

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
# The actual pbr rule content is not critical; we just need pbr to be running.
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

# ── d) Push repo's openwrt/ tree to VM ───────────────────────────────────────
log "=== Phase D: push openwrt/ tree to VM at /root/cutover ==="

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
ssh_run "ip link show awg1 awg2"
ssh_run "uci -q get amnezia.globals.mode"
ssh_run "/etc/init.d/pbr status 2>/dev/null && echo 'pbr: running' || echo 'pbr: not running (check FIRST_BOOT_TWEAK)'"
