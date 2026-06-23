# Autolearn — live-router apply plan

**Goal:** Apply the `amnezia-autolearn` self-learning bypass feature to the live AX3000T (`openWRT`, 192.168.1.1:2323) **without changing any runtime behavior** until the user explicitly opts in.

**Branch:** `feat/autolearn-bypass` @ `b823fd4` — VM run #6 green (SCENARIO 4 autolearn 20/0; migrate 14/0; first-install 11/0).

**Top constraint:** never break client internet. Every step is reversible; verify WAN + DNS + awg handshake after each. SSH is LAN-side (survives routing/tunnel breakage) = recovery channel.

---

## Why this apply is low-risk

The feature is **double-gated OFF** and ships default-disabled:

1. `autolearn_enabled=0` (default) — no cron, no dnsmasq query logging, init does **not** create its rc.d symlink until `set-enabled 1`.
2. `routing_mode=direct-default` required — the router is currently **tunnel-default**, so even if enabled the learning loop is gated off.

So placing the files changes nothing. The learning loop only runs after BOTH a UI toggle **and** a routing-mode switch — each a separate, explicit user action.

## Surface (autolearn-only delta vs the live multi-tunnel/allowlist stack)

**Inert (do nothing until opt-in):**
- New files: `amnezia-autolearn.sh` (pass) → `/usr/sbin/`, `amnezia-autolearn-ctl.sh` → `/usr/bin/amnezia-autolearn-ctl`, `lib/amnezia-autolearn-lib.sh` → `/usr/lib/amnezia/`, `amnezia-autolearn.init` → `/etc/init.d/amnezia-autolearn` (placed but **not** enabled).
- `config/amnezia`: 7 `autolearn_*` options, all default-OFF.
- LuCI `view/main.js` + `acl/luci-app-amnezia.json`: toggle + table + exec grant for `amnezia-autolearn-ctl`.

**Active-code files (4) — all backward-compatible:**
| File | Change | Why safe |
|---|---|---|
| `lib/amnezia-common.sh` | +`amz_tunnel_dev()` helper | pure addition; no existing fn touched |
| `amnezia-force-update.sh` | tunnel-bind fetch (fixes "XHR request timed out") | tries tunnel, **falls back to the exact current direct path** → never worse |
| `amnezia-force-load.sh` | deny.list global exclusion | guarded `[ -s deny.list ]`; `deny.list` absent on router → no-op |
| `zapret-probe.sh` | optional pinned-IP 2nd arg | single-arg LuCI path byte-identical |

**Skipped:** `install-amnezia-pbr.sh` (postinst installer — never re-run on the live surgically-cutover router, per CLAUDE.md hard-won rule).

---

## Pre-flight

- [ ] **Confirm router baseline healthy.** `ssh openWRT` then check WAN, DNS, awg handshakes; record `routing_mode` (expect `tunnel-default`).
  ```sh
  ssh openWRT 'uci -q get amnezia.config.routing_mode; \
    ping -c1 -W2 1.1.1.1 >/dev/null && echo WAN_OK; \
    nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1 && echo DNS_OK; \
    for i in 1 2; do awg show awg$i latest-handshakes 2>/dev/null; done'
  ```
- [ ] **Full backup.** `SSH_HOST=openWRT ./dev/openwrt-backup.sh pre-autolearn-20260622`
- [ ] **Emergency script staged & tested for invocation** (do not run): `dev/openwrt-emergency-internet.sh` (stops pbr + AWG → direct WAN).
- [ ] **Stage the delta tree to the router** under `/root/cutover-autolearn/` and create a rollback snapshot dir `/root/autolearn-rollback/`.

---

## Apply steps (each: place → verify WAN/DNS/awg unchanged → next)

### Step 1 — Inert new files (no wiring)
- [ ] Copy `amnezia-autolearn-lib.sh` → `/usr/lib/amnezia/`; `amnezia-autolearn` (pass) → `/usr/sbin/`; `amnezia-autolearn-ctl` → `/usr/bin/`; `amnezia-autolearn.init` → `/etc/init.d/amnezia-autolearn` (chmod +x). **Do NOT** `enable` the init (no rc.d symlink).
- [ ] Verify: `/etc/init.d/amnezia-autolearn` exists, **not** in `/etc/rc.d/`; `amnezia-autolearn-ctl status` runs and reports `enabled=0`.
- [ ] Verify WAN/DNS/awg unchanged.
- **Rollback:** `rm` the 4 files.

### Step 2 — Shared helper (`amnezia-common.sh`)
- [ ] Snapshot `/usr/lib/amnezia/amnezia-common.sh` → `/root/autolearn-rollback/`. Replace with the branch version (adds `amz_tunnel_dev()` only).
- [ ] Verify: `. /usr/lib/amnezia/amnezia-common.sh; amz_tunnel_dev` prints an `awg*` dev (or empty if no tunnel) without error. Failover daemon still healthy: `/etc/init.d/amnezia-failover status` or check `/var/run/amnezia-failover.json`.
- [ ] Verify WAN/DNS/awg unchanged.
- **Rollback:** restore snapshot.

### Step 3 — force-update tunnel-bind fix (`amnezia-force-update.sh`)
- [ ] Snapshot, replace. (Depends on Step 2's `amz_tunnel_dev`.)
- [ ] **Functional verify — this is the "XHR timed out" fix:** run `amnezia-force-update` on the router; confirm it completes (not a hang), `force-update.json` stamp updates, force.d lists repopulate, **DNS stays up throughout**.
- [ ] Verify WAN/DNS/awg unchanged.
- **Rollback:** restore snapshot.

### Step 4 — force-load deny.list exclusion (`amnezia-force-load.sh`)
- [ ] Snapshot, replace. Confirm `/etc/amnezia/autolearn/deny.list` is **absent** (→ exclusion is a no-op).
- [ ] Run `amnezia-force-load`; confirm `amnezia_force4` repopulates identically (count unchanged), chunked conf-dir intact, **DNS stays up**.
- [ ] Verify WAN/DNS/awg unchanged.
- **Rollback:** restore snapshot.

### Step 5 — zapret-probe pinned-IP arg (`zapret-probe.sh`)
- [ ] Snapshot, replace.
- [ ] Verify single-arg path unchanged: `zapret-probe <some-domain>` returns a verdict as before (LuCI diagnostic path).
- **Rollback:** restore snapshot.

### Step 6 — config defaults (`config/amnezia`)
- [ ] Merge the 7 `autolearn_*` options into `amnezia.config` via `uci set` (do **not** overwrite the file — preserve live tunnels/sources). All default OFF: `autolearn_enabled=0`, `autolearn_interval_min=30`, `autolearn_max_probes=20`, `autolearn_max_per_client=5`, `autolearn_revalidate_days=14`, `autolearn_max_entries=500`, `autolearn_candidate_retention_days=30`. `uci commit amnezia`.
- [ ] Verify `uci -q get amnezia.config.autolearn_enabled` = `0`; failover/force still healthy.
- **Rollback:** `uci delete` the 7 keys + commit (or restore from backup).

### Step 7 — LuCI UI + ACL
- [ ] Copy `view/main.js` + `acl/luci-app-amnezia.json` to their LuCI paths; `rm -rf /tmp/luci-*` (clear cache); reload uhttpd if needed.
- [ ] Verify: LuCI loads, autolearn section renders with toggle **OFF**, no JS errors; existing tunnel/allowlist UI intact.
- **Rollback:** restore snapshots.

### Step 8 — Final verification (feature OFF, nothing changed)
- [ ] WAN + DNS + awg1/awg2 handshakes all OK.
- [ ] `routing_mode` still `tunnel-default`; `autolearn_enabled=0`; no `/etc/rc.d/S*amnezia-autolearn`; no `/tmp/dnsmasq-queries.log`.
- [ ] `amnezia-autolearn-ctl status` → `enabled=0`.

**End state:** all autolearn code present and inert. Router behavior byte-for-byte unchanged except the force-update fetch is now tunnel-bound (the XHR-timeout fix) and the autolearn UI section is visible (toggled OFF).

---

## Optional later step (separate, explicit opt-in) — actually turn it on

Only when the user wants to exercise learning:
1. Switch to allowlist mode: `amnezia-failover-ctl set-routing-mode direct-default` (regenerates classifier → `fw4 check` → bg `fw4 reload` → conntrack flush). Verify WAN/DNS/awg.
2. Enable learning from the UI toggle (or `amnezia-autolearn-ctl set-enabled 1`) — wires dnsmasq query logging + cron + rc.d symlink.
3. Watch `/etc/amnezia/autolearn/autolearn.json`, `candidates.tsv`, and `auto.list` populate over a few cron cycles; confirm DNS stays up and learned domains route through the tunnel.

This is reversible: `set-enabled 0` unwires logging+cron; `set-routing-mode tunnel-default` returns to the current mode.

---

## Rollback (whole feature)

- Per-step: restore the snapshot in `/root/autolearn-rollback/` for that file; `rm` the inert new files; `uci delete` the autolearn keys.
- Full: `SSH_HOST=openWRT ./dev/openwrt-restore.sh pre-autolearn-20260622` (+ etc-amnezia supplement if needed).
- Internet emergency: `SSH_HOST=openWRT ./dev/openwrt-emergency-internet.sh`.
