# Tunnel Management + Allowlist Mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add UI add/remove of AmneziaWG tunnels (`.conf` + `vpn://`) and a `direct-default` "allowlist" routing mode fed by auto-updating curated lists (itdoginfo default-on, Re-filter + antifilter toggleable) plus never-clobbered manual entries.

**Architecture:** New POSIX-sh helpers (`amnezia-tunnel-ctl`, `amnezia-force-load`, `amnezia-force-update`) + a firewall hotplug; the classifier becomes a mode generator in `amnezia-routing.sh` with two `.nft` fragments; `amnezia-failover-ctl` gains `set-routing-mode`/`set-source`; LuCI `main.js` gains the UI + a browser-side `vpn://` decoder. All `openwrt/` source mirrors into `packages/` via `dev/sync-to-packages.sh`. Design: `docs/superpowers/specs/2026-06-17-tunnel-mgmt-allowlist-design.md` (read it — full rationale + the resolved review findings live there).

**Tech Stack:** BusyBox ash, nftables/fw4, UCI, dnsmasq `config ipset`, LuCI client JS (`fs.exec`/`fs.read`, `DecompressionStream`), bats, the `dev/vm/` QEMU harness.

**Conventions (match existing code):**
- Source helpers load libs via the `AMNEZIA_LIB` + `$(dirname "$0")/lib/` fallback pattern (`amnezia-failover-ctl.sh:6-11` sources **only** `amnezia-common.sh`; any helper needing routing functions must source `amnezia-routing.sh` too — see C2/H-fix).
- `fw4 reload` AND the dnsmasq `restart` both run in a backgrounded subshell (`( sleep 1 && … ) &`) per the SSH-drop rule (mirror `configure-dnsmasq-amnezia.sh:36`).
- Every new `openwrt/` runtime file gets a `dev/sync-to-packages.sh` entry (drop `.sh`, map to its install path) — CI `sync.bats` enforces parity.
- Never print private keys; `.conf` files are mode 600.

**Test harness contract (REAL convention — `test/lib/harness.bash`):** there is ONE shared log `$STUB_LOG` (every stub in `test/stubs/` appends to it); `PATH` is prefixed with `test/stubs`; `AMNEZIA_DRYRUN=1` is exported. Tests invoke a helper as `run sh "$HARNESS_DIR/../openwrt/<script>.sh" <args>` and assert with `grep -q "<recorded cmd>" "$STUB_LOG"` (see `test/unit/ctl.bats`). ACL tests use `node -e` JSON-structural assertions against `read.file`/`write.file` (see `test/unit/acl.bats`). **Do NOT invent per-tool log variables or bare-command invocation** — those do not exist. `test/unit/classify-nft.bats` already tests the tunnel-default fragment.

### Phase 0 — Harness stubs (Wave-1 prelude; do FIRST)

**Files:** Create `test/stubs/ifdown`, `test/stubs/wget` (+ symlinks/copies `uclient-fetch`, `curl`), `test/stubs/amnezia-failover-init`; Modify `test/stubs/uci`.

- [ ] **P0-1:** Add stubs that log to `$STUB_LOG` like the existing ones: `ifdown` (echo `ifdown $*`); a fetch stub (`wget`/`uclient-fetch`/`curl`) that, unless `FETCH_FAIL=1`, writes a small fixture list to the `-O`/redirect target and logs the URL — honor `AMZ_FETCH` override. Helpers invoke the monitor init and sibling helpers via overridable names so tests can intercept: `${AMNEZIA_FAILOVER_INIT:-/etc/init.d/amnezia-failover}`, `${AMNEZIA_FORCE_LOAD:-amnezia-force-load}`, etc. Provide a `test/stubs/amnezia-failover-init` stub (logs `amnezia-failover <verb>`) and PATH shims `amnezia-force-load`/`amnezia-tunnel-ctl` for cross-helper-call tests; point the env overrides at them in the relevant `setup()`.
- [ ] **P0-2:** Extend `test/stubs/uci` to enumerate, driven by env like the existing `UCI_FAKE_TUNNELS`: `firewall.vpn.network` members (`UCI_FAKE_FWNET`) and `force_source` sections + their `enabled` (`UCI_FAKE_SOURCES`), and to answer `get amnezia.globals.sticky_target`. Keep existing behavior intact (run the full suite after, expect green).
- [ ] **P0-3:** Commit `test(harness): stubs for ifdown/fetch/monitor-init + uci firewall/force_source enumeration`.

---

## File Structure

| File | Responsibility | Phase |
|---|---|---|
| `openwrt/nftables.d/30-amnezia-classify.nft` | tunnel-default fragment; **add `amnezia_force4` set decl** | A |
| `openwrt/nftables.d/30-amnezia-classify-direct.nft` | NEW — direct-default chain (allowlist) + all 4 set decls | A |
| `openwrt/lib/amnezia-routing.sh` | `+routing_emit_classifier <mode> <lan>` | A |
| `openwrt/lib/amnezia-tunnel-lib.sh` | NEW — extracted `gen_tunnel_uci` (shared installer + tunnel-ctl) | D |
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

**Waves (for parallel execution):** Phase 0 (harness stubs) first. Wave 1 = A, B, D. **Caveat (H4):** D2 extracts `gen_tunnel_uci` out of `install-amnezia-pbr.sh` into a shared lib and edits the installer — so D is NOT fully file-disjoint from Wave-3 F (also edits the installer). Serialize: D's installer edit lands before F, and D re-runs `installer-loop.bats`/`installer-dispatch.bats` after the extraction. Wave 2 = C (needs A+B), E (builds against A–D CLI contracts). Wave 3 = F (integrates all), then G (VM verify). If executed by parallel worktree agents, D and F must not run concurrently (shared `install-amnezia-pbr.sh`).

---

## Phase A — Classifier generator + `amnezia_force4` set

**Files:**
- Modify: `openwrt/nftables.d/30-amnezia-classify.nft`
- Create: `openwrt/nftables.d/30-amnezia-classify-direct.nft`
- Modify: `openwrt/lib/amnezia-routing.sh`
- Test: `test/unit/classifier-generator.bats`

- [ ] **A1: Write failing test for the two fragments + generator (real harness convention).**

```bash
# test/unit/classifier-generator.bats
load '../lib/harness.bash'
ND="$HARNESS_DIR/../openwrt/nftables.d"

@test "both fragments declare amnezia_force4 as an interval set" {
  for f in 30-amnezia-classify.nft 30-amnezia-classify-direct.nft; do
    grep -Eq 'set amnezia_force4 +\{ type ipv4_addr; flags interval; auto-merge; \}' "$ND/$f" \
      || { echo "missing force4 decl in $f"; false; }
  done
}

@test "direct fragment: default direct, force->pool, sticky->sticky, no blanket mark" {
  f="$ND/30-amnezia-classify-direct.nft"
  grep -q 'ip daddr @amnezia_sticky4 meta mark set 0x0a0000 return' "$f"
  grep -q 'ip daddr @amnezia_force4  meta mark set 0x0b0000 return' "$f"
  run grep -E '^[[:space:]]*meta mark set 0x0b0000$' "$f"   # blanket pool-mark = tunnel-default only
  [ "$status" -ne 0 ] || { echo "direct fragment must not blanket-mark to pool"; false; }
}

@test "routing_emit_classifier picks the right fragment and substitutes LAN" {
  run sh -c '. "'"$HARNESS_DIR"'/../openwrt/lib/amnezia-common.sh"; \
    . "'"$HARNESS_DIR"'/../openwrt/lib/amnezia-routing.sh"; \
    AMNEZIA_NFT_DIR="'"$ND"'" routing_emit_classifier direct-default br-lan'
  echo "$output" | grep -q 'iifname != "br-lan" return'
  echo "$output" | grep -q 'ip daddr @amnezia_force4  meta mark set 0x0b0000 return'
  run sh -c '. "'"$HARNESS_DIR"'/../openwrt/lib/amnezia-common.sh"; \
    . "'"$HARNESS_DIR"'/../openwrt/lib/amnezia-routing.sh"; \
    AMNEZIA_NFT_DIR="'"$ND"'" routing_emit_classifier tunnel-default br-lan'
  echo "$output" | grep -qE '^[[:space:]]*meta mark set 0x0b0000$'
}

@test "tunnel-default fragment behaviour is preserved (regression)" {
  # The pre-existing golden test must still pass after A2 adds the force4 decl.
  run bats "$HARNESS_DIR/unit/classify-nft.bats"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  f="$ND/30-amnezia-classify.nft"
  grep -q '@amnezia_ru_tld4 return' "$f"
  grep -q '@amnezia_ru4 return' "$f"
  grep -q '@amnezia_sticky4 meta mark set 0x0a0000 return' "$f"
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
# test/unit/force-load.bats
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-force-load.sh"
setup() {
  export FORCE_DIR="$BATS_TEST_TMPDIR/amnezia"; mkdir -p "$FORCE_DIR/force.d"
  export AMNEZIA_FAILOVER_INIT="amnezia-failover-init"   # P0 stub
}

@test "force-load classifies IP/CIDR into the set and domains into config ipset" {
  printf '8.8.8.8\n1.2.3.0/24\nexample.com\n# comment\n\n' > "$FORCE_DIR/force.d/itdoginfo_inside.list"
  printf 'manual.example\n9.9.9.9\n' > "$FORCE_DIR/force-tunnel.list"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # all stubs (nft/uci/dnsmasq) record to the single $STUB_LOG
  grep -q 'amnezia_force4.*8.8.8.8' "$STUB_LOG"
  grep -q 'amnezia_force4.*1.2.3.0/24' "$STUB_LOG"
  grep -q 'amnezia_force4.*9.9.9.9' "$STUB_LOG"
  grep -q 'add_list dhcp.amnezia_force.domain=example.com' "$STUB_LOG"
  grep -q 'add_list dhcp.amnezia_force.domain=manual.example' "$STUB_LOG"
}

@test "force-load restarts dnsmasq only when the domain set changed" {
  printf 'a.example\n' > "$FORCE_DIR/force-tunnel.list"
  sh "$SCRIPT"; : > "$STUB_LOG"
  sh "$SCRIPT"                                   # no change
  run grep -q 'dnsmasq.*restart' "$STUB_LOG"; [ "$status" -ne 0 ] || { echo "restarted w/o change"; false; }
  printf 'a.example\nb.example\n' > "$FORCE_DIR/force-tunnel.list"
  : > "$STUB_LOG"; sh "$SCRIPT"                   # domain added
  grep -q 'dnsmasq.*restart' "$STUB_LOG"
}

@test "save-manual writes the manual file without touching auto caches, then loads" {
  printf 'AUTO\n' > "$FORCE_DIR/force.d/x.list"
  run sh "$SCRIPT" save-manual "$(printf 'one.example\ntwo.example')"
  [ "$status" -eq 0 ]
  grep -q one.example "$FORCE_DIR/force-tunnel.list"
  grep -q AUTO "$FORCE_DIR/force.d/x.list"        # auto cache untouched
}
```

Run: FAIL (script missing). (The `nft`/`uci`/`dnsmasq` stubs already log to `$STUB_LOG`; the dnsmasq stub records its `restart` arg.)

- [ ] **B2: Write `openwrt/amnezia-force-load.sh`.** Reads `FORCE_DIR` (default `/etc/amnezia`), merges `force.d/*.list` + `force-tunnel.list`, dedups, classifies each line (IP/CIDR regex → set; else domain), flushes+batch-adds IP/CIDR into `amnezia_force4` (batch like `amnezia-ru-cidr`), rebuilds `dhcp.amnezia_force` `add_list domain=` entries, computes a hash of the sorted domain list, and only restarts dnsmasq **in a backgrounded subshell** (`( sleep 1 && /etc/init.d/dnsmasq restart ) &`, per the SSH-drop rule) when the hash differs from `$FORCE_DIR/.force-domains.hash`. `save-manual <content>` writes `$content` to `force-tunnel.list` (mode 644) then falls through to the load. Take a `flock` on `/var/lock/amnezia-force.lock` around the load. POSIX sh, shellcheck-clean, `amz_log` for diagnostics.

- [ ] **B3: Run `bats test/unit/force-load.bats`** → PASS.

- [ ] **B4: Failing tests for `amnezia-force-update` (enabled iteration + fetch-fail keeps cache).**
```bash
# test/unit/force-update.bats
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-force-update.sh"
setup() {
  export FORCE_DIR="$BATS_TEST_TMPDIR/amnezia"; mkdir -p "$FORCE_DIR/force.d"
  export UCI_FAKE_SOURCES="itdoginfo_inside:1 itdoginfo_services:1 antifilter:0"
  export AMNEZIA_FORCE_LOAD="amnezia-force-load"   # PATH shim from P0 logs to $STUB_LOG
}
@test "update fetches only enabled sources" {
  run sh "$SCRIPT"
  grep -q 'itdoginfo_inside' "$STUB_LOG"            # fetch stub logs the source/url
  run grep -q 'antifilter' "$STUB_LOG"; [ "$status" -ne 0 ]
}
@test "a failed fetch keeps the previous cache and marks status failed" {
  printf 'OLD\n' > "$FORCE_DIR/force.d/itdoginfo_inside.list"
  FETCH_FAIL=1 run sh "$SCRIPT"
  grep -q OLD "$FORCE_DIR/force.d/itdoginfo_inside.list"     # not clobbered
  grep -q '"status":"failed"' "$FORCE_DIR/force-update.json"
}
@test "update writes a stamp and calls force-load" {
  run sh "$SCRIPT"
  grep -q '"ts"' "$FORCE_DIR/force-update.json"
  grep -q 'amnezia-force-load' "$STUB_LOG"
}
```

- [ ] **B5: Write `openwrt/amnezia-force-update.sh`.** Iterate `force_source` sections (`uci show amnezia | grep force_source`); for each `enabled=1`, fetch its `url` with a timeout (`uclient-fetch`/`wget`, `|| curl`), validate non-empty + line-shape per `kind` (domains vs cidr), write atomically to `force.d/<name>.list` (temp+mv); on fetch failure keep the existing cache. Write `force-update.json` stamp (ts, per-source count/status). Take the `force-update.lock` flock. End by exec/calling `amnezia-force-load`. Make the fetch command overridable for tests (`AMZ_FETCH`), and honor `FETCH_FAIL` only via the stub.

- [ ] **B6: Run `bats test/unit/force-update.bats`** → PASS.

- [ ] **B7: Create `openwrt/99-amnezia-force-load.hotplug`** — mirror `99-amnezia-ru-load.hotplug` EXACTLY (same quoting + `|| true` tail; read the real file first):
```sh
[ "$ACTION" = "reload" ] || exit 0
[ -x /usr/bin/amnezia-force-load ] && /usr/bin/amnezia-force-load || true
```

- [ ] **B8: Add the `dhcp.amnezia_force` ipset section to `openwrt/configure-dnsmasq-amnezia.sh`** (mirror the `amnezia_sticky` block at lines 26-33), pointing `name='amnezia_force4'`, `table='fw4'`, `table_family='inet'`. Do NOT add domains here (the loader manages them); just ensure the section exists.

- [ ] **B9: Add the FIVE `force_source` sections to `openwrt/config/amnezia`** (H2 — design lines 123-143 define five: `itdoginfo_inside`, `itdoginfo_services`, `refilter_domains`, `refilter_ip`, `antifilter`). `itdoginfo_inside` + `itdoginfo_services` → `enabled '1'`; the other three → `enabled '0'`. Each has `kind` (`domains`/`cidr`) and `url`. Leave `url` as the design placeholders with a comment to resolve at F1.

- [ ] **B10: `shellcheck` all new scripts; commit** `feat(force): allowlist load/update engine + hotplug + dnsmasq section`.

---

## Phase C — `amnezia-failover-ctl`: `set-routing-mode` + `set-source`

**Files:** Modify `openwrt/amnezia-failover-ctl.sh`; Test `test/unit/failover-ctl-mode.bats`.

- [ ] **C1: Failing tests (harness convention).**
```bash
# test/unit/failover-ctl-mode.bats
load '../lib/harness.bash'
CTL="$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh"
setup() {
  export AMNEZIA_NFT_DIR="$HARNESS_DIR/../openwrt/nftables.d"
  export AMNEZIA_CLASSIFIER_OUT="$BATS_TEST_TMPDIR/active.nft"   # redirect the write target in tests
  export UCI_FAKE_SOURCES="itdoginfo_inside:1 antifilter:0"
  export AMNEZIA_FORCE_LOAD="amnezia-force-load"
}
@test "set-routing-mode validates, regenerates classifier, force-loads, flushes both marks" {
  run sh "$CTL" set-routing-mode direct-default
  [ "$status" -eq 0 ]
  grep -q 'uci set amnezia.config.routing_mode=direct-default' "$STUB_LOG"
  grep -q '@amnezia_force4' "$AMNEZIA_CLASSIFIER_OUT"        # direct fragment written
  grep -q 'amnezia-force-load' "$STUB_LOG"
  # conntrack stub logs its args; match case-insensitively (constants are 0x0B.. but tolerate 0xb..)
  grep -qiE -- '-D -m 0x0?b0000/0x0?ff0000' "$STUB_LOG"      # pool mark flushed
  grep -qiE -- '-D -m 0x0?a0000/0x0?ff0000' "$STUB_LOG"      # sticky mark flushed
}
@test "set-routing-mode rejects an unknown mode" {
  run sh "$CTL" set-routing-mode bogus; [ "$status" -ne 0 ]
}
@test "set-source toggles a known source and rejects unknown" {
  run sh "$CTL" set-source antifilter 1
  [ "$status" -eq 0 ]; grep -q 'uci set amnezia.antifilter.enabled=1' "$STUB_LOG"
  run sh "$CTL" set-source not_a_source 1; [ "$status" -ne 0 ]
}
```

- [ ] **C2: Implement the two verbs** in `amnezia-failover-ctl.sh`. **First add an `amnezia-routing.sh` source block** (mirror the existing `amnezia-common.sh` block at lines 6-11 with the `$AMNEZIA_LIB` + `$(dirname "$0")/lib/` fallback — H1: the file currently sources only common.sh, but `set-routing-mode` needs `routing_emit_classifier`). `set-routing-mode`: validate ∈ {tunnel-default,direct-default}; `uci set amnezia.config.routing_mode`; `uci commit amnezia`; resolve LAN exactly as the installer does — `LAN_DEV=$(uci -q get network.lan.device || echo br-lan)` (M4, single source of truth); `routing_emit_classifier "$2" "$LAN_DEV"` → `${AMNEZIA_CLASSIFIER_OUT:-/etc/nftables.d/30-amnezia-classify.nft}`; `${AMNEZIA_FORCE_LOAD:-amnezia-force-load}`; backgrounded `fw4 reload`; then `conntrack -D -m "$POOL_MARK/$MARK_MASK"` and `conntrack -D -m "$STICKY_MARK/$MARK_MASK"` (constants from `amnezia-common.sh`, passed verbatim). `set-source`: validate `$2` ∈ the **five** hardcoded known names (H2: itdoginfo_inside, itdoginfo_services, refilter_domains, refilter_ip, antifilter), `$3` ∈ {0,1}; `uci set amnezia.$2.enabled=$3`; commit.

- [ ] **C3: Run tests → PASS; `shellcheck`; commit** `feat(failover-ctl): set-routing-mode + set-source`.

---

## Phase D — `amnezia-tunnel-ctl` (add / remove / list-free)

**Files:** Create `openwrt/amnezia-tunnel-ctl.sh`, `openwrt/lib/amnezia-tunnel-lib.sh` (extracted `gen_tunnel_uci`); **Modify `openwrt/install-amnezia-pbr.sh`** (source the extracted lib — H4: this is a shared-with-F file, serialize before F); Test `test/unit/tunnel-ctl.bats`, `test/fixtures/awg-sample.conf`.

- [ ] **D0: Extract `gen_tunnel_uci` FIRST into `openwrt/lib/amnezia-tunnel-lib.sh`** (DRY — one copy for installer + tunnel-ctl). Update `install-amnezia-pbr.sh` to source it (replacing the inline def at line 113) and **re-run `bats test/unit/installer-loop.bats test/unit/installer-dispatch.bats`** (they exercise `--dry-run-tunnel`/`--dry-run-all` via `gen_tunnel_uci`) → must stay green before proceeding. Commit `refactor(install): extract gen_tunnel_uci to shared lib`.

- [ ] **D1: Failing tests (harness convention).**
```bash
# test/unit/tunnel-ctl.bats
load '../lib/harness.bash'
TC="$HARNESS_DIR/../openwrt/amnezia-tunnel-ctl.sh"
FIX="$HARNESS_DIR/fixtures/awg-sample.conf"
setup() {
  export AMNEZIA_FAILOVER_INIT="amnezia-failover-init"
  export CONF_DIR="$BATS_TEST_TMPDIR/amnezia"; mkdir -p "$CONF_DIR"
}
@test "list-free returns the lowest free slot, accounting for gaps" {
  UCI_FAKE_TUNNELS="awg1 awg3" run sh "$TC" list-free; [ "$output" = awg2 ]
}
@test "list-free exits 3 when full" {
  UCI_FAKE_TUNNELS="awg1 awg2 awg3 awg4 awg5" run sh "$TC" list-free; [ "$status" -eq 3 ]
}
@test "add refuses a conf missing Endpoint (no UCI mutation)" {
  run sh "$TC" add awg2 "$(printf '[Interface]\nPrivateKey=x\n[Peer]\nPublicKey=y\n')"
  [ "$status" -ne 0 ]
  run grep -q 'set network.awg2' "$STUB_LOG"; [ "$status" -ne 0 ]
}
@test "add emits typed tunnel section with all fields + fw membership + ifup + monitor restart" {
  run sh "$TC" add awg2 "$(cat "$FIX")" --label Backup
  [ "$status" -eq 0 ]
  grep -q 'set amnezia.awg2=tunnel' "$STUB_LOG"
  grep -q 'set amnezia.awg2.enabled=1' "$STUB_LOG"
  grep -q 'set amnezia.awg2.label=Backup' "$STUB_LOG"
  grep -q 'set amnezia.awg2.weight=1' "$STUB_LOG"
  grep -q 'set amnezia.awg2.track_ip=' "$STUB_LOG"
  grep -q 'add_list firewall.vpn.network=awg2' "$STUB_LOG"
  grep -q 'ifup awg2' "$STUB_LOG"
  grep -q 'amnezia-failover restart' "$STUB_LOG"
}
@test "remove refuses the sticky target" {
  UCI_FAKE_TUNNELS="awg1 awg2" run sh "$TC" remove awg1   # sticky_target=awg1 (uci stub)
  [ "$status" -ne 0 ]
}
@test "remove refuses leaving zero firewall.vpn.network members" {
  UCI_FAKE_FWNET="awg2" run sh "$TC" remove awg2; [ "$status" -ne 0 ]
}
@test "remove stops the monitor BEFORE teardown, restarts after" {
  UCI_FAKE_TUNNELS="awg1 awg2" UCI_FAKE_FWNET="awg1 awg2" run sh "$TC" remove awg2
  [ "$status" -eq 0 ]
  awk '/amnezia-failover stop/{s=NR} /ifdown awg2/{i=NR} /amnezia-failover start/{e=NR} \
    END{exit !(s&&i&&e&&s<i&&i<e)}' "$STUB_LOG"
}
```
Add `test/fixtures/awg-sample.conf` (complete dummy conf: `[Interface]` PrivateKey/Address/Jc.. + `[Peer]` PublicKey/Endpoint — no real keys).

- [ ] **D2: Implement `amnezia-tunnel-ctl.sh`** (source `amnezia-common.sh` + `amnezia-tunnel-lib.sh`): `list-free` (scan awg1..MAX_TUNNELS, exit 3 if full); `add <name> <conf-body> [--label L]` — write argv body → `mktemp` (600) → `parse_awg_conf` → **require non-empty `AWG_PrivateKey`, `AWG_PublicKey`, `AWG_Endpoint_host`, `AWG_Endpoint_port`** (exit 1 + rm temp if any missing) → `gen_tunnel_uci` → move temp → `$CONF_DIR/<name>.conf` (600) → emit the typed section with the **exact** design fields: `uci set amnezia.<name>=tunnel`, `.enabled=1`, `.label=<L or name>`, `.metric=<next>`, `.weight=1`, `.track_ip=1.1.1.1` → `firewall.vpn.network` delete-then-`add_list` → `uci commit network firewall amnezia` → `ifup` → backgrounded `fw4 reload` → `${AMNEZIA_FAILOVER_INIT:-/etc/init.d/amnezia-failover} restart`. `remove <name>` — guards (sticky_target; would leave zero `firewall.vpn.network` members) → `${AMNEZIA_FAILOVER_INIT} stop` → `ifdown` + delete `network.<name>`/peer + remove firewall member + delete `amnezia.<name>` + rm conf → commit → backgrounded `fw4 reload` → `${AMNEZIA_FAILOVER_INIT} start`.

- [ ] **D3: Run tests → PASS; `shellcheck`; commit** `feat(tunnel-ctl): add/remove/list-free`.

---

## Phase E — LuCI UI + ACL

**Files:** Modify `openwrt/luci-app-amnezia/view/main.js`, `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json`; Test `test/js/decode-vpn.test.mjs`, `test/unit/acl-grants.bats`.

- [ ] **E1: Failing JS test for `decodeVpnLink`.** Capture a real Amnezia AmneziaWG `vpn://` link into `test/js/fixtures/sample.vpn` and the expected `.conf` into `sample.conf`. Export `decodeVpnLink` from a small ESM shim (or factor it into a tiny module `main.js` imports) so Node can test it; run under `node --test` with a `DecompressionStream` polyfill if needed (Node 18+ has it). Assert decode → expected conf, and that garbage / non-`vpn://` input rejects (returns null/throws caught).

- [ ] **E2: Implement `decodeVpnLink(text)`** per design (strip `vpn://`, base64url→bytes, drop 4-byte BE prefix, `DecompressionStream('deflate')`, `JSON.parse`, walk `containers[]`→AmneziaWG→`JSON.parse(last_config)`→`.config`). Return the conf string; throw/return null on any failure.

- [ ] **E3: Run JS test → PASS.**

- [ ] **E4: Failing ACL test (node JSON-structural, matching `test/unit/acl.bats`).**
```bash
# test/unit/acl-grants.bats
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/luci-app-amnezia/acl/luci-app-amnezia.json"
@test "acl grants exec of every new helper (write/file)" {
  node -e "
    const a=JSON.parse(require('fs').readFileSync('$F','utf8'));
    const wf=a['luci-app-amnezia'].write.file;
    for (const p of ['/usr/bin/amnezia-tunnel-ctl','/usr/bin/amnezia-force-load','/usr/bin/amnezia-force-update'])
      if(!wf[p]) throw new Error('missing exec grant '+p);
  "
}
@test "acl grants read of force list + stamp (read/file)" {
  node -e "
    const a=JSON.parse(require('fs').readFileSync('$F','utf8'));
    const rf=a['luci-app-amnezia'].read.file;
    for (const p of ['/etc/amnezia/force-tunnel.list','/etc/amnezia/force-update.json'])
      if(!rf[p]) throw new Error('missing read grant '+p);
  "
}
@test "acl does NOT grant write of force-tunnel.list (save goes via save-manual exec)" {
  node -e "
    const a=JSON.parse(require('fs').readFileSync('$F','utf8'));
    const wf=a['luci-app-amnezia'].write.file['/etc/amnezia/force-tunnel.list'];
    if (wf && wf.indexOf('write')!==-1) throw new Error('unexpected write grant on force-tunnel.list');
  "
}
```

- [ ] **E5: Update the ACL** with the design's grants (exec: tunnel-ctl, force-load, force-update; read: force-tunnel.list, force-update.json; NO force-tunnel.list write grant). Run ACL test → PASS.

- [ ] **E6: Build the UI in `main.js`** (no `fs.write` anywhere): Add-tunnel box (textarea + label + button; `vpn://` → `decodeVpnLink` → confirm preview → `fs.exec(amnezia-tunnel-ctl, ['add', name, confBody, '--label', L])`; `list-free` to label/disable when full); per-row Remove button (uiConfirm → `amnezia-tunnel-ctl remove`); Mode radio (uiConfirm → `amnezia-failover-ctl set-routing-mode`); Sources checkboxes (`set-source`) + "Update now" (`amnezia-force-update`) + `force-update.json` stamp via `paintRuStamp`-style; Manual editor (`fs.read` prefill → `amnezia-force-load save-manual <content>`). Reuse existing in-flight guards/`uiConfirm`/poll patterns. Keep the `failover-tunnel-table` anchor for the poll self-unregister.

- [ ] **E7: Smoke-check `main.js`** parses (`node --check` won't work for AMD `'use strict'; 'require …'` — instead run the repo's existing JS lint/format check if present, else a careful read). Commit `feat(luci): add/remove tunnels, allowlist mode UI, vpn:// decode`.

---

## Phase F — Installer integration + sync-to-packages

**Files:** Modify `openwrt/install-amnezia-pbr.sh`, `dev/sync-to-packages.sh`; Test `test/unit/sync.bats` (extend), `test/unit/installer-*.bats`.

- [x] **F1: Resolve the real source URLs** (WebFetch confirmed 2026-06-17):
  - `itdoginfo_inside` (intent a, RKN-blocked): `https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst` — HTTP 200
  - `itdoginfo_services` (intent b, geoblock-RU services — OpenAI/ChatGPT/Claude/Spotify etc.): `https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Categories/geoblock.lst` — HTTP 200 (NOTE: `Russia/services-raw.lst` returned 404; the correct path is `Categories/geoblock.lst`)
  - `refilter_domains`: `https://raw.githubusercontent.com/1andrevich/Re-filter-lists/main/domains_all.lst` — HTTP 200
  - `refilter_ip`: `https://raw.githubusercontent.com/1andrevich/Re-filter-lists/main/ipsum.lst` — HTTP 200
  - `antifilter`: `https://antifilter.download/list/domains.lst` — HTTP 200
  - CONFIRMED: `itdoginfo_services` (geoblock-RU, `Categories/geoblock.lst`) is among the two default-on itdoginfo sources. Both intents (a) and (b) covered by default.

- [ ] **F2: Failing sync test.** Extend `test/unit/sync.bats` to assert `dev/sync-to-packages.sh` maps each new path into `packages/amnezia-pbr/files/...`: `amnezia-tunnel-ctl`/`amnezia-force-load`/`amnezia-force-update`→`/usr/bin/`, `lib/amnezia-tunnel-lib.sh`→`/usr/lib/amnezia/` (alongside the existing libs), `99-amnezia-force-load.hotplug`→`/etc/hotplug.d/firewall/`, `30-amnezia-classify-direct.nft`→`/etc/nftables.d/` AND both fragments→`/usr/share/amnezia/nftables.d/`, seeded `force-tunnel.list` + `force.d/`→`/etc/amnezia/`.

- [ ] **F3: Update `dev/sync-to-packages.sh`** to add those entries (follow the existing drop-`.sh` loop at line ~50). Run sync; run `sync.bats` → PASS.

- [ ] **F4: Integrate into `install-amnezia-pbr.sh`** (idempotent, dry-run-guarded like existing steps): install the three helpers to `/usr/bin` (resolve_dep pattern), the hotplug to `/etc/hotplug.d/firewall/`, BOTH `.nft` fragments to `/usr/share/amnezia/nftables.d/`; replace the static classifier-install step with `routing_emit_classifier "$(uci get amnezia.config.routing_mode)" "$LAN_DEV"` → `/etc/nftables.d/30-amnezia-classify.nft`; ensure `dhcp.amnezia_force` section via `configure-dnsmasq-amnezia.sh`; seed an empty `/etc/amnezia/force-tunnel.list` + `force.d/` dir; add the **daily** `amnezia-force-update` cron line (dedup like the RU cron sed); run `amnezia-force-update` once on install. Keep existing flow-offloading-off + RU steps intact.

- [ ] **F5: Run installer bats (`installer-hardening`, `migration`) → PASS** (fix any fallout). `shellcheck` the installer. Commit `feat(install): ship allowlist engine + classifier generator + sources cron`.

---

## Phase G — VM integration + final verification

**Files:** `dev/vm/` scenario script; run the full bats + JS suite + shellcheck.

- [ ] **G1: Write a `dev/vm/` scenario** (extend `test-all.sh` style) that, from a provisioned image: installs; `amnezia-tunnel-ctl add awg2 <fixture conf>` and asserts the interface + firewall member + monitor membership; `set-routing-mode direct-default` with a one-IP + one-domain manual list; asserts the IP is in `amnezia_force4` and marks to pool while a non-listed IP returns/direct; **measures `uci commit dhcp` + dnsmasq restart time with the real default itdoginfo list** (the C1 scale gate — record the number); asserts a force domain resolves into `amnezia_force4`; runs `fw4 reload` then asserts `amnezia_force4` IP half is still populated (hotplug); asserts mode-switch flushed pool/sticky conntrack; `set-routing-mode tunnel-default` back; `amnezia-tunnel-ctl remove awg2` and asserts no stale probe route/rule and no WAN-cleartext leak for forwarded clients.

- [ ] **G2: Run the scenario on the VM.** Capture results to `dev/logs/`. **Concrete scale-gate threshold (M5):** if the `uci commit dhcp` + backgrounded `dnsmasq restart` for the real default itdoginfo list takes **> 10 s wall-clock** OR the resulting DNS-unavailable window for LAN clients exceeds **3 s**, the `config ipset` path fails the gate → trigger the documented conf-dir fallback (name the exact OpenWrt 24.10 conf-dir UCI option, prove dnsmasq reads it, then implement). At/under both thresholds, proceed with `config ipset`. Record the measured numbers in the VM log regardless.

- [ ] **G3: Full local gate:** `bats test/` (all), `node --test test/js/`, `shellcheck` all new `.sh`, `dev/sync-to-packages.sh` + `git diff --exit-code packages/` (parity). All green.

- [ ] **G4: Commit** any VM-driven fixes; the branch is now ready for the per-phase/deep review stages and (after the user confirms VM green) the live-router apply with rollback per the design's Rollback section.

---

## Self-review notes (done)

- **Spec coverage:** add/remove (D,E), `.conf`+`vpn://` (D,E2), allowlist mode (A,C), RKN + geoblock sources (B,F1), auto-update (B,F4), manual + never-clobbered (B2 save-manual + separate file), defaults (B9). ✓
- **No placeholders:** every task names files, gives the test, and the implementation approach with the tricky code inlined; routine sh bodies follow cited existing patterns. The only deferred concretes are the source URLs (F1, gated) and the conf-dir fallback (G2, only if the scale gate fails) — both explicitly gated, not hand-waved.
- **Type/contract consistency:** CLI verbs/args match across D/E (`add <name> <conf-body> --label`), C (`set-routing-mode`, `set-source`), B (`save-manual <content>`); mark constants (`POOL_MARK`/`STICKY_MARK`/`MARK_MASK`) match `amnezia-common.sh`; `gen_tunnel_uci` is unified (D2) so the installer and tunnel-ctl can't drift.
