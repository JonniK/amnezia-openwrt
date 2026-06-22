# OpenWrt QEMU test harness — multi-tunnel failover migrate

A faithful OpenWrt VM for testing the AmneziaWG multi-tunnel failover stack
(`openwrt/install-amnezia-pbr.sh`, the `amnezia-failover` monitor, the fw4
classifier, ip-rule policy routing) **off the physical daily-driver router**.

## Why this exists

The live pbr→failover cutover on the real AX3000T broke. Two root causes:

1. **Deploy mechanism:** the migrate was backgrounded over SSH without
   `setsid`/`nohup`, so step 13's `fw4 reload` dropped SSH and SIGHUP killed
   the process *mid-`opkg remove pbr`* — leaving a half-migrated router.
2. **Integration bug bats never saw:** after pbr stop + interface churn, the
   `fwmark→table` ip rules were gone, so classifier-marked LAN traffic fell
   through to the main table and **leaked out WAN cleartext**; the vpn
   firewall zone (masquerade/SNAT) was also never applied.

`test/unit/*.bats` stubs `nft`/`ip`/`uci`/init.d, so it can verify shell
*logic* but never the real kernel/procd/fw4/pbr/hotplug interaction — exactly
the layer that failed. This VM closes that gap: real OpenWrt kernel, `fw4`,
`procd`, `ubus`, `hotplug`, `pbr`, `dnsmasq`. Run inside the VM there is no
droppable SSH session, so cause (1) is removed and we test the installer logic
in isolation; cause (2) is directly asserted as a regression.

## Host / image

- macOS arm64, `qemu-system-aarch64 -machine virt -accel hvf -cpu host`
  (native-speed via Hypervisor.framework).
- OpenWrt **24.10.3 `armsr/armv8`** ext4 combined-efi (matches the router's
  release; ext4 = persistent writable rootfs). Fetched to `images/`.
- edk2 aarch64 UEFI firmware ships with brew qemu
  (`/opt/homebrew/share/qemu/edk2-aarch64-code.fd` + a writable vars copy).

## Topology

```
        host:2222 ──hostfwd──> VM:22 (dropbear)
   ┌────────────────────────────────────────────┐
   │ OpenWrt VM (router under test)              │
   │   eth0  = WAN  (virtio-net, user-mode NAT)  │  → host internet
   │   br-lan       (LAN bridge, 192.168.1.1)    │
   │   netns "lanclient" ──veth──> br-lan        │  simulated LAN host
   │   awg1 / awg2  = tunnels                     │
   └────────────────────────────────────────────┘
```

The simulated LAN client lives in a network namespace attached to `br-lan`, so
its forwarded traffic traverses the **exact** prerouting classifier +
policy-routing path a real LAN device would. Asserting on its egress (tunnel
device vs WAN, exit IP) is how we prove "tunneled, not leaked".

## Test tiers

**Tier 1 — routing/leak regression (priority, no crypto, no secrets).**
Tunnels are **dummy interfaces** (`ip link add awg1 type dummy` … assigned an
addr + a default route in their table) so we exercise classifier + ip-rule +
pbr-removal + SNAT + monitor failover **without** amneziawg keys or endpoints.
This reproduces the bug that broke the router. Assertions after running the
corrected `--migrate`:
  1. classifier `amnezia_classify` chain is live and marks LAN traffic.
  2. `fwmark 0x0a0000→100` / `0x0b0000→101` ip rules are **present after pbr is
     removed** (the regression).
  3. LAN-client marked traffic resolves to a **tunnel device, not `wan`**
     (`ip route get … mark …` from the client's perspective + an actual
     egress check) — no WAN leak.
  4. firewall **vpn zone with masquerade** exists (SNAT for LAN→tunnel).
  5. failover: down the active dummy tunnel → monitor switches to the backup,
     traffic stays tunneled; all-down → **blackhole (fail-closed), not WAN**.

**Tier 2 — full fidelity (later).** Real `amneziawg-go` userspace tunnels to
the real endpoints (`amneziawg-go` is arch-portable, sidesteps the
filogic-only kmod). Configs are staged from `../../local/*.conf` at runtime and
**must never be committed or printed** (they hold private keys).

## pbr pre-state (for the migrate path)

To test `migrate_from_pbr`, the VM is first provisioned into a pbr-based
single-tunnel state mimicking the old stack: `pbr` + `dnsmasq-full` installed,
a pbr.d rule steering LAN→awg1, and `/etc/config/amnezia` with
`globals.mode=failover`, `awg1` (metric 1) + `awg2` (metric 2) enabled. Then
`STEPS=3 … install-amnezia-pbr.sh` detects pbr and runs `--migrate`.
The clean `first_install` path is also tested (no pbr present).

## Scripts (built by the harness task)

| script | purpose |
|---|---|
| `lib.sh` | shared paths, ports, ssh opts |
| `fetch-image.sh` | download/decompress image + prepare EFI vars + writable disk |
| `run-vm.sh` | boot the VM headless (serial+monitor on unix sockets) |
| `console.sh` | talk to the serial socket (first-boot provisioning) |
| `vm-ssh.sh` | ssh/scp into the VM over `localhost:2222` |
| `provision.sh` | bring VM to pbr pre-state (Tier 1: dummy tunnels) |
| `test-migrate.sh` | run `--migrate`, assert the 5 regression checks, print PASS/FAIL |
| `test-first-install.sh` | run clean `first_install`, assert end state |
| `test-tunnel-mgmt.sh` | Phase G: tunnel-ctl add/remove + allowlist mode + scale gate |

## Phase G — Tunnel management + allowlist scenario (`test-tunnel-mgmt.sh`)

Tests the Phase G spec (plan: `docs/superpowers/plans/2026-06-17-tunnel-mgmt-allowlist-plan.md`,
design: `docs/superpowers/specs/2026-06-17-tunnel-mgmt-allowlist-design.md`).

**Pre-condition:** the VM is provisioned (`provision.sh --first-install`) and the stack
is installed (`--first-install`). `test-all.sh` runs this automatically as SCENARIO 3.

**Assertions (7 steps, 16 checks):**

| ID | Description |
|---|---|
| T1-1 | `network.awg2` UCI section created after `tunnel-ctl add awg2` |
| T1-2 | `awg2` in `firewall.vpn.network` after add |
| T1-3 | `amnezia.awg2.enabled=1` in UCI after add |
| T1-4 | monitor enumerates `awg2` (state file or running process) |
| T1-5 | **C1 regression guard:** `awg1` still in `firewall.vpn.network` after adding `awg2` |
| T2-1/T2-2 | manual force list written via `save-manual` (IP + domain) |
| T2-3 | `FORCE_IP` in `nft set amnezia_force4` after `set-routing-mode direct-default` |
| T2-4 | `ip route get FORCE_IP mark 0x0b0000` → tunnel (not WAN) |
| T2-5 | non-listed IP is unmarked/direct (no blanket pool-mark in direct-default chain) |
| T3-3 | **C1 scale gate:** `uci commit dhcp` + dnsmasq restart <= 10 s, DNS-down <= 3 s |
| T3-4 | force domain materializes into `amnezia_force4` via dnsmasq conf-dir `nftset=` |
| T4-1 | `amnezia_force4` IP half repopulated after `fw4 reload` (hotplug) |
| T5-1 | `amnezia_force4` repopulated by boot-init run (cold-boot simulation) |
| T6-1 | pool+sticky conntrack entries flushed after `set-routing-mode` |
| T7-1 – T7-6 | `awg2` fully removed; `awg1` still a member; no stale routes/rules |
| T7-7/T7-8 | no LAN→WAN cleartext leak after remove (fail-closed blackhole) |

**Transcript** captured to `dev/logs/tunnel-mgmt-<ts>.log`.

**Harness limitation noted:** Step 5 (cold-boot repop) is simulated via
`/etc/init.d/amnezia-force-load start` rather than a true VM reboot. A full cold-boot
test would require the `wait_for_vm_reboot` helper from `test-cutover.sh` integrated
into this scenario — noted for a later Tier-2 extension.

### Running stand-alone

```sh
# From a provisioned, installer-run VM:
dev/vm/test-tunnel-mgmt.sh
```

### Running via test-all.sh (recommended)

`test-all.sh` boots a fresh disk, runs `provision.sh --first-install`, runs the installer,
and then invokes `test-tunnel-mgmt.sh` as SCENARIO 3 automatically.

```sh
dev/vm/fetch-image.sh          # one-time
dev/vm/test-all.sh             # runs all 3 scenarios
```

## Usage

```sh
dev/vm/fetch-image.sh          # one-time: image + firmware + disk
dev/vm/run-vm.sh &             # boot (headless)
dev/vm/provision.sh            # pbr pre-state with dummy tunnels
dev/vm/test-migrate.sh         # the regression suite → PASS/FAIL
```
