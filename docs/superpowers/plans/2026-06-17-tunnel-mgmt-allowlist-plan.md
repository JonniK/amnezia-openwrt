# Tunnel Management + Allowlist Mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add UI add/remove of AmneziaWG tunnels (`.conf` + `vpn://`) and a `direct-default` "allowlist" routing mode fed by auto-updating curated lists (itdoginfo default-on, Re-filter + antifilter toggleable) plus never-clobbered manual entries.

**Architecture:** New POSIX-sh helpers (`amnezia-tunnel-ctl`, `amnezia-force-load`, `amnezia-force-update`) + a firewall hotplug; the classifier becomes a mode generator in `amnezia-routing.sh` with two `.nft` fragments; `amnezia-failover-ctl` gains `set-routing-mode`/`set-source`; LuCI `main.js` gains the UI + a browser-side `vpn://` decoder. All `openwrt/` source mirrors into `packages/` via `dev/sync-to-packages.sh`. Design: `docs/superpowers/specs/2026-06-17-tunnel-mgmt-allowlist-design.md` (read it — full rationale + the resolved review findings live there).

**Tech Stack:** BusyBox ash, nftables/fw4, UCI, dnsmasq `config ipset`, LuCI client JS (`fs.exec`/`fs.read`, `DecompressionStream`), bats, the `dev/vm/` QEMU harness.

**Conventions (match existing code):**
- Source helpers load `amnezia-common.sh` + `amnezia-routing.sh` via the `AMNEZIA_LIB` pattern (see `amnezia-failover-ctl.sh:6-11`).
- `fw4 reload` runs in a backgrounded subshell (`( sleep 1 && … ) &`) per the SSH-drop rule.
- Every new `openwrt/` runtime file gets a `dev/sync-to-packages.sh` entry (drop `.sh`, map to its install path) — CI `sync.bats` enforces parity.
- Tests live in `test/unit/` (bats) and `test/integration/`; JS fixture under `test/js/`.
- Never print private keys; `.conf` files are mode 600.

---

## File Structure

| File | Responsibility | Phase |
|---|---|---|
| `openwrt/nftables.d/30-amnezia-classify.nft` | tunnel-default fragment; **add `amnezia_force4` set decl** | A |
| `openwrt/nftables.d/30-amnezia-classify-direct.nft` | NEW — direct-default chain (allowlist) + all 4 set decls | A |
| `openwrt/lib/amnezia-routing.sh` | `+routing_emit_classifier <mode> <lan>` | A |
| `openwrt/amnezia-force-load.sh` | NEW — merge/classify/load force list; `save-manual` | B |
| `openwrt/amnezia-force-update.sh` | NEW — fetch enabled sources, cache, stamp, flock, →load | B |
| `openwrt/99-amnezia-force-load.hotplug` | NEW — repopulate `amnezia_force4` IP half on fw reload | B |
| `openwrt/configure-dnsmasq-amnezia.sh` | `+dhcp.amnezia_force` `config ipset` → `amnezia_force4` | B |
| `openwrt/config/amnezia` | `+force_source` sections (itdoginfo inside+services ON) | B |
| `openwrt/amnezia-failover-ctl.sh` | `+set-routing-mode` (conntrack flush), `+set-source` | C |
| `openwrt/amnezia-tunnel-ctl.sh` | NEW — `add`/`remove`/`list-free` | D |
| `openwrt/luci-app-amnezia/view/main.js` | `+decodeVpnLink`, add/remove UI, mode radio, sources, manual editor | E |
| `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json` | `+`exec/read grants | E |
| `openwrt/install-amnezia-pbr.sh` | install helpers/hotplug; use generator; seed list+cron | F |
| `dev/sync-to-packages.sh` | mirror all new runtime paths | F |
| `test/unit/*.bats`, `test/js/decode-vpn.test.*`, `dev/vm/` scenario | tests | each phase + G |

**Waves (for parallel execution):** Wave 1 = A, B, D (disjoint files). Wave 2 = C (needs A+B), E (builds against A–D CLI contracts). Wave 3 = F (integrates all), then G (VM verify).

---

## Phase A — Classifier generator + `amnezia_force4` set

**Files:**
- Modify: `openwrt/nftables.d/30-amnezia-classify.nft`
- Create: `openwrt/nftables.d/30-amnezia-classify-direct.nft`
- Modify: `openwrt/lib/amnezia-routing.sh`
- Test: `test/unit/classifier-generator.bats`

- [ ] **A1: Write failing test for the two golden fragments + generator.**

```bash
# test/unit/classifier-generator.bats
setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  . "$REPO/openwrt/lib/amnezia-common.sh"
  . "$REPO/openwrt/lib/amnezia-routing.sh"
}

@test "both fragments declare amnezia_force4 as an interval set" {
  for f in 30-amnezia-classify.nft 30-amnezia-classify-direct.nft; do
    run grep -E 'set amnezia_force4 \{ type ipv4_addr; flags interval; auto-merge; \}' \
      "$REPO/openwrt/nftables.d/$f"
    [ "$status" -eq 0 ] || { echo "missing force4 decl in $f"; false; }
  done
}

@test "direct fragment: default returns (direct), force-listed marks pool, sticky marks sticky" {
  f="$REPO/openwrt/nftables.d/30-amnezia-classify-direct.nft"
  grep -q 'ip daddr @amnezia_sticky4 meta mark set 0x0a0000 return' "$f"
  grep -q 'ip daddr @amnezia_force4 meta mark set 0x0b0000 return' "$f"
  # No unconditional "meta mark set 0x0b0000" tail (that would be tunnel-default).
  run grep -E '^\tmeta mark set 0x0b0000$' "$f"
  [ "$status" -ne 0 ] || { echo "direct fragment must not blanket-mark to pool"; false; }
}

@test "routing_emit_classifier substitutes LAN_IFNAME and picks the right fragment" {
  out=$(routing_emit_classifier direct-default br-lan)
  echo "$out" | grep -q 'iifname != "br-lan" return'
  echo "$out" | grep -q 'ip daddr @amnezia_force4 meta mark set 0x0b0000 return'
  out2=$(routing_emit_classifier tunnel-default br-lan)
  echo "$out2" | grep -qE '^\tmeta mark set 0x0b0000$'   # tunnel-default blanket mark present
}
```

Run: `bats test/unit/classifier-generator.bats` → FAIL (direct fragment + function missing).

- [ ] **A2: Add the `amnezia_force4` set decl to the existing tunnel-default fragment.** In `openwrt/nftables.d/30-amnezia-classify.nft`, after the `amnezia_sticky4` set line add:
```
set amnezia_force4   { type ipv4_addr; flags interval; auto-merge; }
```
(Behaviour of the tunnel-default chain is otherwise unchanged — `amnezia_force4` is declared-but-unused in this mode, which is correct: the set must exist in both modes so a switch never references an undefined set.)

- [ ] **A3: Create the direct-default fragment** `openwrt/nftables.d/30-amnezia-classify-direct.nft`:
```
# amnezia direct-default (allowlist) classifier — included into inet fw4 by fw4.
set amnezia_ru4      { type ipv4_addr; flags interval; auto-merge; }
set amnezia_ru_tld4  { type ipv4_addr; flags interval; auto-merge; }
set amnezia_sticky4  { type ipv4_addr; flags interval; auto-merge; }
set amnezia_force4   { type ipv4_addr; flags interval; auto-merge; }

chain amnezia_classify {
	type filter hook prerouting priority mangle; policy accept;
	iifname != "@@LAN_IFNAME@@" return
	# Allowlist mode: tunnel ONLY the force list (and sticky); everything else direct.
	ip daddr @amnezia_sticky4 meta mark set 0x0a0000 return
	ip daddr @amnezia_force4  meta mark set 0x0b0000 return
	# default: return -> main table -> WAN direct (zapret operates here).
}
```

- [ ] **A4: Add `routing_emit_classifier` to `openwrt/lib/amnezia-routing.sh`.** It reads the fragment for the mode from the source/install location and substitutes `@@LAN_IFNAME@@`. Resolve the fragment path with the same fallback style the installer uses (source tree in tests, `/etc/nftables.d` … in install). Minimal form:
```sh
# routing_emit_classifier <tunnel-default|direct-default> <lan_ifname>
# Prints the classifier .nft for the given mode with @@LAN_IFNAME@@ substituted.
routing_emit_classifier() {
  _mode=$1; _lan=$2
  case "$_mode" in
    direct-default) _frag=30-amnezia-classify-direct.nft ;;
    *)              _frag=30-amnezia-classify.nft ;;
  esac
  _src=$(_amz_find_fragment "$_frag") || { amz_log "classifier fragment $_frag not found"; return 1; }
  sed "s/@@LAN_IFNAME@@/$_lan/" "$_src"
}
# Locate a packaged .nft fragment across source-tree and installed locations.
_amz_find_fragment() {
  for _p in "${AMNEZIA_NFT_DIR:-}/$1" \
            "$(dirname "$0")/nftables.d/$1" \
            "$(dirname "$0")/../nftables.d/$1" \
            "/usr/share/amnezia/nftables.d/$1" \
            "/etc/nftables.d/$1"; do
    [ -n "${_p#/}" ] && [ -f "$_p" ] && { echo "$_p"; return 0; }
  done
  return 1
}
```
Note for F: the installer must ship BOTH fragments to a stable read location (e.g. `/usr/share/amnezia/nftables.d/`) so `set-routing-mode` can regenerate either mode at runtime, then write the active one to `/etc/nftables.d/30-amnezia-classify.nft`.

- [ ] **A5: Run `bats test/unit/classifier-generator.bats`** → PASS. Then `shellcheck openwrt/lib/amnezia-routing.sh`.

- [ ] **A6: Commit** `feat(routing): classifier mode generator + amnezia_force4 set`.

---

## Phase B — Force-list engine (load / update / hotplug / dnsmasq / sources)

**Files:**
- Create: `openwrt/amnezia-force-load.sh`, `openwrt/amnezia-force-update.sh`, `openwrt/99-amnezia-force-load.hotplug`
- Modify: `openwrt/configure-dnsmasq-amnezia.sh`, `openwrt/config/amnezia`
- Test: `test/unit/force-load.bats`, `test/unit/force-update.bats`

- [ ] **B1: Failing tests for `amnezia-force-load` (classify + merge + idempotent restart).**

```bash
# test/unit/force-load.bats  (uses uci/nft/dnsmasq stubs on PATH like other unit tests)
@test "force-load classifies IP/CIDR into the set and domains into config ipset" {
  printf '8.8.8.8\n1.2.3.0/24\nexample.com\n# comment\n\n' > "$FORCE_DIR/force.d/itdoginfo_inside.list"
  printf 'manual.example\n9.9.9.9\n' > "$FORCE_DIR/force-tunnel.list"
  run amnezia-force-load
  [ "$status" -eq 0 ]
  grep -q 'add element inet fw4 amnezia_force4 { 8.8.8.8 }' "$NFT_LOG"
  grep -q 'add element inet fw4 amnezia_force4 { 1.2.3.0/24 }' "$NFT_LOG"
  grep -q 'add element inet fw4 amnezia_force4 { 9.9.9.9 }' "$NFT_LOG"
  grep -q "add_list dhcp.amnezia_force.domain=example.com" "$UCI_LOG"
  grep -q "add_list dhcp.amnezia_force.domain=manual.example" "$UCI_LOG"
}

@test "force-load restarts dnsmasq only when the domain set changed" {
  printf 'a.example\n' > "$FORCE_DIR/force-tunnel.list"
  amnezia-force-load; : > "$DNSMASQ_LOG"
  amnezia-force-load                      # no change
  run cat "$DNSMASQ_LOG"; [ -z "$output" ] || { echo "restarted with no change"; false; }
  printf 'a.example\nb.example\n' > "$FORCE_DIR/force-tunnel.list"
  amnezia-force-load                      # domain added
  grep -q restart "$DNSMASQ_LOG"
}

@test "save-manual writes the manual file without touching auto caches, then loads" {
  printf 'AUTO\n' > "$FORCE_DIR/force.d/x.list"
  run amnezia-force-load save-manual "$(printf 'one.example\ntwo.example')"
  [ "$status" -eq 0 ]
  grep -q one.example "$FORCE_DIR/force-tunnel.list"
  grep -q AUTO "$FORCE_DIR/force.d/x.list"     # auto cache untouched
}
```
(Set up stubs/env in `setup()`: `FORCE_DIR`, `NFT_LOG`, `UCI_LOG`, `DNSMASQ_LOG`, and `PATH`-shim `nft`/`uci`/`/etc/init.d/dnsmasq` recording to those logs — mirror the stub style already in `test/unit/`.)

Run: FAIL (script missing).

- [ ] **B2: Write `openwrt/amnezia-force-load.sh`.** Reads `FORCE_DIR` (default `/etc/amnezia`), merges `force.d/*.list` + `force-tunnel.list`, dedups, classifies each line (IP/CIDR regex → set; else domain), flushes+batch-adds IP/CIDR into `amnezia_force4` (batch like `amnezia-ru-cidr`), rebuilds `dhcp.amnezia_force` `add_list domain=` entries, computes a hash of the sorted domain list, and only `/etc/init.d/dnsmasq restart` when the hash differs from `$FORCE_DIR/.force-domains.hash`. `save-manual <content>` writes `$content` to `force-tunnel.list` (mode 644) then falls through to the load. Take a `flock` on `/var/lock/amnezia-force.lock` around the load. POSIX sh, shellcheck-clean, `amz_log` for diagnostics.

- [ ] **B3: Run `bats test/unit/force-load.bats`** → PASS.

- [ ] **B4: Failing tests for `amnezia-force-update` (enabled iteration + fetch-fail keeps cache).**
```bash
# test/unit/force-update.bats
@test "update fetches only enabled sources" {
  # uci stub returns itdoginfo_inside enabled=1, antifilter enabled=0
  run amnezia-force-update
  grep -q itdoginfo_inside "$FETCH_LOG"
  run grep -q antifilter "$FETCH_LOG"; [ "$status" -ne 0 ]
}
@test "a failed fetch keeps the previous cache and marks status failed" {
  printf 'OLD\n' > "$FORCE_DIR/force.d/itdoginfo_inside.list"
  FETCH_FAIL=1 run amnezia-force-update
  grep -q OLD "$FORCE_DIR/force.d/itdoginfo_inside.list"     # not clobbered
  grep -q '"status":"failed"' "$FORCE_DIR/force-update.json"
}
@test "update writes a stamp and calls force-load" {
  run amnezia-force-update
  grep -q '"ts"' "$FORCE_DIR/force-update.json"
  grep -q force-load "$LOAD_LOG"
}
```

- [ ] **B5: Write `openwrt/amnezia-force-update.sh`.** Iterate `force_source` sections (`uci show amnezia | grep force_source`); for each `enabled=1`, fetch its `url` with a timeout (`uclient-fetch`/`wget`, `|| curl`), validate non-empty + line-shape per `kind` (domains vs cidr), write atomically to `force.d/<name>.list` (temp+mv); on fetch failure keep the existing cache. Write `force-update.json` stamp (ts, per-source count/status). Take the `force-update.lock` flock. End by exec/calling `amnezia-force-load`. Make the fetch command overridable for tests (`AMZ_FETCH`), and honor `FETCH_FAIL` only via the stub.

- [ ] **B6: Run `bats test/unit/force-update.bats`** → PASS.

- [ ] **B7: Create `openwrt/99-amnezia-force-load.hotplug`** (mirror `99-amnezia-ru-load.hotplug`):
```sh
[ "$ACTION" = reload ] || exit 0
[ -x /usr/bin/amnezia-force-load ] && /usr/bin/amnezia-force-load
```

- [ ] **B8: Add the `dhcp.amnezia_force` ipset section to `openwrt/configure-dnsmasq-amnezia.sh`** (mirror the `amnezia_sticky` block at lines 26-33), pointing `name='amnezia_force4'`, `table='fw4'`, `table_family='inet'`. Do NOT add domains here (the loader manages them); just ensure the section exists.

- [ ] **B9: Add `force_source` sections to `openwrt/config/amnezia`** (the four sections from the design; itdoginfo_inside + itdoginfo_services `enabled '1'`, the rest `'0'`). Leave the `url` values as the design's placeholders with a comment to resolve at F1.

- [ ] **B10: `shellcheck` all new scripts; commit** `feat(force): allowlist load/update engine + hotplug + dnsmasq section`.

---

## Phase C — `amnezia-failover-ctl`: `set-routing-mode` + `set-source`

**Files:** Modify `openwrt/amnezia-failover-ctl.sh`; Test `test/unit/failover-ctl-mode.bats`.

- [ ] **C1: Failing tests.**
```bash
@test "set-routing-mode validates, regenerates classifier, force-loads, flushes conntrack" {
  run amnezia-failover-ctl set-routing-mode direct-default
  [ "$status" -eq 0 ]
  grep -q 'amnezia.config.routing_mode=direct-default' "$UCI_LOG"
  grep -q '30-amnezia-classify-direct' "$EMIT_LOG"        # generator invoked for direct
  grep -q 'force-load' "$LOAD_LOG"
  grep -q -- '-D -m 0x0B0000/0x0FF0000' "$CONNTRACK_LOG"   # pool mark flushed
  grep -q -- '-D -m 0x0A0000/0x0FF0000' "$CONNTRACK_LOG"   # sticky mark flushed
}
@test "set-routing-mode rejects an unknown mode" {
  run amnezia-failover-ctl set-routing-mode bogus; [ "$status" -ne 0 ]
}
@test "set-source toggles a known source and rejects unknown" {
  run amnezia-failover-ctl set-source antifilter 1
  grep -q 'amnezia.antifilter.enabled=1' "$UCI_LOG"
  run amnezia-failover-ctl set-source not_a_source 1; [ "$status" -ne 0 ]
}
```

- [ ] **C2: Implement the two verbs** in `amnezia-failover-ctl.sh` (extend the `case`). `set-routing-mode`: validate ∈ {tunnel-default,direct-default}; `uci set amnezia.config.routing_mode`; `uci commit amnezia`; write `routing_emit_classifier "$2" "$LAN_DEV"` → `/etc/nftables.d/30-amnezia-classify.nft` (resolve `LAN_DEV` from the live network config / preserve current substitution); `amnezia-force-load`; backgrounded `fw4 reload`; then `conntrack -D -m "$POOL_MARK/$MARK_MASK"` and `conntrack -D -m "$STICKY_MARK/$MARK_MASK"`. `set-source`: validate `$2` ∈ the hardcoded known names, `$3` ∈ {0,1}; `uci set amnezia.$2.enabled=$3`; commit. Make `conntrack`/`fw4`/classifier-target overridable via env for tests.

- [ ] **C3: Run tests → PASS; `shellcheck`; commit** `feat(failover-ctl): set-routing-mode + set-source`.

---

## Phase D — `amnezia-tunnel-ctl` (add / remove / list-free)

**Files:** Create `openwrt/amnezia-tunnel-ctl.sh`; Test `test/unit/tunnel-ctl.bats`.

- [ ] **D1: Failing tests.**
```bash
@test "list-free returns the lowest free slot, accounting for gaps" {
  # uci stub: awg1, awg3 present -> awg2 free
  run amnezia-tunnel-ctl list-free; [ "$output" = awg2 ]
}
@test "list-free exits 3 when full (awg1..awg5 all present)" {
  run amnezia-tunnel-ctl list-free; [ "$status" -eq 3 ]
}
@test "add refuses a conf missing Endpoint (no UCI mutation)" {
  run amnezia-tunnel-ctl add awg2 "$(printf '[Interface]\nPrivateKey=x\n[Peer]\nPublicKey=y\n')"
  [ "$status" -ne 0 ]
  run grep -q 'set network.awg2' "$UCI_LOG"; [ "$status" -ne 0 ]
}
@test "add emits typed tunnel section + firewall membership + ifup + monitor restart" {
  run amnezia-tunnel-ctl add awg2 "$(cat test/fixtures/awg-sample.conf)" --label Backup
  [ "$status" -eq 0 ]
  grep -q 'set amnezia.awg2=tunnel' "$UCI_LOG"
  grep -q 'add_list firewall.vpn.network=awg2' "$UCI_LOG"
  grep -q 'ifup awg2' "$CMD_LOG"
  grep -q 'amnezia-failover restart' "$CMD_LOG"
}
@test "remove refuses the sticky target and the last firewall member" {
  run amnezia-tunnel-ctl remove awg1   # sticky_target=awg1 in stub
  [ "$status" -ne 0 ]
}
@test "remove stops the monitor BEFORE teardown, restarts after" {
  run amnezia-tunnel-ctl remove awg2
  # assert ordering in CMD_LOG: stop ... before ifdown/delete ... before start
  grep -n 'amnezia-failover stop' "$CMD_LOG" | head -1
  awk '/amnezia-failover stop/{s=NR} /ifdown awg2/{i=NR} /amnezia-failover start/{e=NR} END{exit !(s<i && i<e)}' "$CMD_LOG"
}
```
Add `test/fixtures/awg-sample.conf` (a complete dummy conf with `[Interface]` PrivateKey/Address/Jc.. and `[Peer]` PublicKey/Endpoint — no real keys).

- [ ] **D2: Implement `amnezia-tunnel-ctl.sh`** per design Feature 1: source libs; `list-free` (scan awg1..MAX_TUNNELS); `add <name> <conf-body> [--label L]` (write argv body → `mktemp` 600 → `parse_awg_conf` → require PrivateKey/PublicKey/Endpoint_host/Endpoint_port → `gen_tunnel_uci` (factor it out of the installer or source it) → `uci set amnezia.<name>=tunnel` + fields → `add_list firewall.vpn.network` (delete-then-add) → `uci commit network firewall amnezia` → `ifup` → backgrounded `fw4 reload` → `amnezia-failover restart`); `remove <name>` (guards: sticky_target, would-empty `firewall.vpn.network` → `/etc/init.d/amnezia-failover stop` → ifdown + delete network/peer + remove firewall member + delete `amnezia.<name>` + rm conf → commit → backgrounded reload → `/etc/init.d/amnezia-failover start`). `gen_tunnel_uci` is currently defined inside `install-amnezia-pbr.sh`; extract it into a sourced lib (e.g. `amnezia-routing.sh` or a new `amnezia-tunnel-lib.sh`) so both the installer and `amnezia-tunnel-ctl` use ONE copy (DRY) — update the installer to source it.

- [ ] **D3: Run tests → PASS; `shellcheck`; commit** `feat(tunnel-ctl): add/remove/list-free + shared gen_tunnel_uci`.

---

## Phase E — LuCI UI + ACL

**Files:** Modify `openwrt/luci-app-amnezia/view/main.js`, `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json`; Test `test/js/decode-vpn.test.mjs`, `test/unit/acl-grants.bats`.

- [ ] **E1: Failing JS test for `decodeVpnLink`.** Capture a real Amnezia AmneziaWG `vpn://` link into `test/js/fixtures/sample.vpn` and the expected `.conf` into `sample.conf`. Export `decodeVpnLink` from a small ESM shim (or factor it into a tiny module `main.js` imports) so Node can test it; run under `node --test` with a `DecompressionStream` polyfill if needed (Node 18+ has it). Assert decode → expected conf, and that garbage / non-`vpn://` input rejects (returns null/throws caught).

- [ ] **E2: Implement `decodeVpnLink(text)`** per design (strip `vpn://`, base64url→bytes, drop 4-byte BE prefix, `DecompressionStream('deflate')`, `JSON.parse`, walk `containers[]`→AmneziaWG→`JSON.parse(last_config)`→`.config`). Return the conf string; throw/return null on any failure.

- [ ] **E3: Run JS test → PASS.**

- [ ] **E4: Failing ACL test.**
```bash
# test/unit/acl-grants.bats — assert every exec/read path the UI calls is granted
@test "acl grants every new helper + read path" {
  acl="$REPO/openwrt/luci-app-amnezia/acl/luci-app-amnezia.json"
  for p in /usr/bin/amnezia-tunnel-ctl /usr/bin/amnezia-force-load /usr/bin/amnezia-force-update; do
    grep -q "\"$p\"" "$acl" || { echo "missing exec grant $p"; false; }
  done
  grep -q '/etc/amnezia/force-tunnel.list' "$acl"
  grep -q '/etc/amnezia/force-update.json' "$acl"
}
```

- [ ] **E5: Update the ACL** with the design's grants (exec: tunnel-ctl, force-load, force-update; read: force-tunnel.list, force-update.json; NO force-tunnel.list write grant). Run ACL test → PASS.

- [ ] **E6: Build the UI in `main.js`** (no `fs.write` anywhere): Add-tunnel box (textarea + label + button; `vpn://` → `decodeVpnLink` → confirm preview → `fs.exec(amnezia-tunnel-ctl, ['add', name, confBody, '--label', L])`; `list-free` to label/disable when full); per-row Remove button (uiConfirm → `amnezia-tunnel-ctl remove`); Mode radio (uiConfirm → `amnezia-failover-ctl set-routing-mode`); Sources checkboxes (`set-source`) + "Update now" (`amnezia-force-update`) + `force-update.json` stamp via `paintRuStamp`-style; Manual editor (`fs.read` prefill → `amnezia-force-load save-manual <content>`). Reuse existing in-flight guards/`uiConfirm`/poll patterns. Keep the `failover-tunnel-table` anchor for the poll self-unregister.

- [ ] **E7: Smoke-check `main.js`** parses (`node --check` won't work for AMD `'use strict'; 'require …'` — instead run the repo's existing JS lint/format check if present, else a careful read). Commit `feat(luci): add/remove tunnels, allowlist mode UI, vpn:// decode`.

---

## Phase F — Installer integration + sync-to-packages

**Files:** Modify `openwrt/install-amnezia-pbr.sh`, `dev/sync-to-packages.sh`; Test `test/unit/sync.bats` (extend), `test/unit/installer-*.bats`.

- [ ] **F1: Resolve the real source URLs** (WebSearch/WebFetch): itdoginfo inside (a) + a services/geoblock list (b), Re-filter `domains_all` + `ipsum`, antifilter domains. Update the `url` values in `openwrt/config/amnezia` and record the resolved paths in this plan + the design. CONFIRM a geoblock-RU/services list is among the default-on two.

- [ ] **F2: Failing sync test.** Extend `test/unit/sync.bats` to assert `dev/sync-to-packages.sh` maps each new path into `packages/amnezia-pbr/files/...`: `amnezia-tunnel-ctl`/`amnezia-force-load`/`amnezia-force-update`→`/usr/bin/`, `99-amnezia-force-load.hotplug`→`/etc/hotplug.d/firewall/`, `30-amnezia-classify-direct.nft`→`/etc/nftables.d/` AND both fragments→`/usr/share/amnezia/nftables.d/`, seeded `force-tunnel.list` + `force.d/`→`/etc/amnezia/`.

- [ ] **F3: Update `dev/sync-to-packages.sh`** to add those entries (follow the existing drop-`.sh` loop at line ~50). Run sync; run `sync.bats` → PASS.

- [ ] **F4: Integrate into `install-amnezia-pbr.sh`** (idempotent, dry-run-guarded like existing steps): install the three helpers to `/usr/bin` (resolve_dep pattern), the hotplug to `/etc/hotplug.d/firewall/`, BOTH `.nft` fragments to `/usr/share/amnezia/nftables.d/`; replace the static classifier-install step with `routing_emit_classifier "$(uci get amnezia.config.routing_mode)" "$LAN_DEV"` → `/etc/nftables.d/30-amnezia-classify.nft`; ensure `dhcp.amnezia_force` section via `configure-dnsmasq-amnezia.sh`; seed an empty `/etc/amnezia/force-tunnel.list` + `force.d/` dir; add the **daily** `amnezia-force-update` cron line (dedup like the RU cron sed); run `amnezia-force-update` once on install. Keep existing flow-offloading-off + RU steps intact.

- [ ] **F5: Run installer bats (`installer-hardening`, `migration`) → PASS** (fix any fallout). `shellcheck` the installer. Commit `feat(install): ship allowlist engine + classifier generator + sources cron`.

---

## Phase G — VM integration + final verification

**Files:** `dev/vm/` scenario script; run the full bats + JS suite + shellcheck.

- [ ] **G1: Write a `dev/vm/` scenario** (extend `test-all.sh` style) that, from a provisioned image: installs; `amnezia-tunnel-ctl add awg2 <fixture conf>` and asserts the interface + firewall member + monitor membership; `set-routing-mode direct-default` with a one-IP + one-domain manual list; asserts the IP is in `amnezia_force4` and marks to pool while a non-listed IP returns/direct; **measures `uci commit dhcp` + dnsmasq restart time with the real default itdoginfo list** (the C1 scale gate — record the number); asserts a force domain resolves into `amnezia_force4`; runs `fw4 reload` then asserts `amnezia_force4` IP half is still populated (hotplug); asserts mode-switch flushed pool/sticky conntrack; `set-routing-mode tunnel-default` back; `amnezia-tunnel-ctl remove awg2` and asserts no stale probe route/rule and no WAN-cleartext leak for forwarded clients.

- [ ] **G2: Run the scenario on the VM.** Capture results to `dev/logs/`. If the scale gate fails (UCI restart too slow), trigger the documented conf-dir fallback path (name the exact OpenWrt 24.10 option, prove it, then implement) — otherwise proceed.

- [ ] **G3: Full local gate:** `bats test/` (all), `node --test test/js/`, `shellcheck` all new `.sh`, `dev/sync-to-packages.sh` + `git diff --exit-code packages/` (parity). All green.

- [ ] **G4: Commit** any VM-driven fixes; the branch is now ready for the per-phase/deep review stages and (after the user confirms VM green) the live-router apply with rollback per the design's Rollback section.

---

## Self-review notes (done)

- **Spec coverage:** add/remove (D,E), `.conf`+`vpn://` (D,E2), allowlist mode (A,C), RKN + geoblock sources (B,F1), auto-update (B,F4), manual + never-clobbered (B2 save-manual + separate file), defaults (B9). ✓
- **No placeholders:** every task names files, gives the test, and the implementation approach with the tricky code inlined; routine sh bodies follow cited existing patterns. The only deferred concretes are the source URLs (F1, gated) and the conf-dir fallback (G2, only if the scale gate fails) — both explicitly gated, not hand-waved.
- **Type/contract consistency:** CLI verbs/args match across D/E (`add <name> <conf-body> --label`), C (`set-routing-mode`, `set-source`), B (`save-manual <content>`); mark constants (`POOL_MARK`/`STICKY_MARK`/`MARK_MASK`) match `amnezia-common.sh`; `gen_tunnel_uci` is unified (D2) so the installer and tunnel-ctl can't drift.
