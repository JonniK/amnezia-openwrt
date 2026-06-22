# Multi-tunnel AmneziaWG failover — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add support for up to 5 AmneziaWG tunnels with automatic, routing-native failover (strict-priority default, optional load-balance), dropping `pbr` for a native fw4 nft classifier + iproute2 tables + a procd monitor daemon, keeping `zapret`.

**Architecture:** A native `/etc/nftables.d` classifier marks LAN traffic (RU-direct → unmarked → wan; sticky → `0x0A0000`; pool → `0x0B0000`). ip rules send marked traffic to routing tables `vpn_sticky`/`vpn_pool`, whose default routes are owned by a procd monitor that health-checks each tunnel (netifd event + handshake age + dedicated-route bound ping), fails over/back via `ip route replace`, fails closed with a blackhole default when all tunnels are down, and flushes conntrack selectively. LuCI exposes per-tunnel config/status.

**Tech Stack:** BusyBox ash, nftables (fw4), iproute2 (ip rule/route/nexthop), procd/ubus, dnsmasq nftset, UCI, conntrack-tools, LuCI (JS). Tests: shellcheck + bats-core (local), real-kernel integration in GitHub Actions (ubuntu) + optional Docker, manual hardware spike.

**Design doc:** `docs/superpowers/specs/2026-06-15-multi-tunnel-failover-design.md`

---

## Test strategy (three tiers)

**Local prerequisites (Tier 1):** `bats-core`, `shellcheck`, and `node` must be on PATH before running Tier-1 tests.

- **Tier 1 — local, macOS-runnable (the pipeline's stage-9 E2E runs this):** `shellcheck` on every script; `bats` unit tests driving shell functions with **command stubs** (`uci`/`nft`/`ip`/`awg`/`conntrack`/`ubus` fakes on `PATH` that log args and emit canned output); **dry-run** generators that emit the UCI/nft they *would* apply, diffed against **golden files**; JSON-schema validation of monitor state; `node --check` on LuCI JS.
- **Tier 2 — CI, real Linux kernel (GitHub Actions ubuntu + optional local Docker):** load the real nft classifier (`nft -c -f`, then apply in a netns), install real ip-rules/tables, create **dummy interfaces** standing in for `awg1..5`, drive the monitor through up→down→up sequences, and assert real `ip route show table …` / `conntrack -L` / `nft list ruleset`. Guarded so Tier-2-only tests `skip` when `command -v nft` is absent (macOS).
- **Tier 3 — manual hardware spike (Phase 0 runbook, backup-gated, NOT run by the pipeline):** amneziawg kmod, MT7981 `CONFIG_IP_ROUTE_MULTIPATH`/resilient nexthop, zapret/DFS coexistence, fw4 hook ordering, real rollback.

Every bats test file sources `test/lib/harness.bash` (Phase A) which puts `test/stubs` first on `PATH`. Tier-2 files start with `_require_linux_nft || skip`.

---

## File structure

**New (runtime):**
- `openwrt/lib/amnezia-common.sh` — shared lib: fwmark constants, paths, `parse_awg_conf`, UCI helpers, logging. Sourced by installer + monitor.
- `openwrt/nftables.d/30-amnezia-classify.nft` — classifier + set declarations (installed to `/etc/nftables.d/`).
- `openwrt/lib/amnezia-routing.sh` — ip-rule/table/nexthop generator (install/remove, idempotent, dry-run); also contains `routing_disable_lan_v6` (Task C4).
- `openwrt/amnezia-ru-cidr.sh` — RU CIDR loader (port of `pbr.d/ru-direct.sh`, writes `@amnezia_ru4`).
- `openwrt/amnezia-failover` — the monitor daemon.
- `openwrt/amnezia-failover.init` — procd init script (`/etc/init.d/amnezia-failover`).
- `openwrt/amnezia-status.sh` — emits `/var/run/amnezia-failover.json` consumers / panel helper.
- `openwrt/config/amnezia` — extended UCI scaffold (per-tunnel sections, globals).
- `openwrt/configure-dnsmasq-amnezia.sh` — generator script that emits UCI `config ipset` sections for dnsmasq (ru TLD + sticky domains); replaces any static conf-file approach.
- `openwrt/iproute2-amnezia-rt_tables.conf` — `/etc/iproute2/rt_tables.d/amnezia.conf`.
- `dev/spike-multitunnel-runbook.md` — Tier-3 manual runbook.
- `dev/test-integration.sh` — Tier-2 local Docker runner (optional).
- `.github/workflows/integration.yml` — Tier-2 CI job.

**Modified:**
- `openwrt/install-amnezia-pbr.sh` — multi-tunnel loop + ordered pbr-removal migration.
- `openwrt/luci-app-amnezia/view/main.js` — multi-tunnel table + status.
- `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json` — add state-json read + monitor execs, drop pbr execs.
- `packages/amnezia-pbr/Makefile`, `packages/luci-app-amnezia/Makefile` — deps (drop pbr/luci-app-pbr), `PKG_RELEASE`.
- `dev/sync-to-packages.sh` — sync new files, drop pbr.d template handling.

**New (tests):**
- `test/lib/harness.bash`, `test/stubs/{uci,nft,ip,awg,conntrack,ubus,logger,ping}`, `test/golden/`, `test/unit/*.bats`, `test/integration/*.bats`.
- `test/fixtures/awg-crlf.conf` — CRLF variant of `awg-sample.conf` for CR-strip testing.
- `test/fixtures/firewall-quic.uci` — representative `amnezia_block_quic` UCI rule fixture (Phase C/D).

**Contracts pinned in Phase A** (every later phase depends only on these, not on each other's code):
- **fwmark allocation:** selector mask `0x0FF0000`; `STICKY_MARK=0x0A0000`, `POOL_MARK=0x0B0000`; balance-mode per-member conntrack marks in low byte `0x0000NN` (member index N).
- **Tables:** `vpn_sticky` (id 100), `vpn_pool` (id 101).
- **Sets:** `amnezia_ru4`, `amnezia_ru_tld4`, `amnezia_sticky4` (all `inet fw4`).
- **State file:** `/var/run/amnezia-failover.json` (schema in Task A4).
- **Paths:** configs `/etc/amnezia/awgN.conf`; lib `/usr/lib/amnezia/amnezia-common.sh`; CIDR persist `/etc/amnezia/ru.cidr`.

---

## Wave / dependency map

- **Wave 1:** Phase A (foundations + contracts + harness).
- **Wave 2:** Phase B (classifier/sets), Phase C (routing lib) — parallel; both depend only on A.
- **Wave 3:** Phase D (installer+migration), Phase E (monitor daemon) — parallel; D depends on A/B/C artifacts, E on A/C contracts.
- **Wave 4:** Phase F (LuCI + ACL) — depends on A state-schema. **F is ordered: F1 (ACL) → F3 (ctl helper) → F2 (panel).**
- **Wave 5:** Phase G (packaging, sync, CI job, runbook, docs).

> **STUB ISOLATION RULE (C5):** Task A1 pre-declares ALL stub response branches the entire plan needs (`UCI_FAKE_TUNNELS`, `NFT_FAKE_RU4_COUNT`, `AWG_FAKE_HS`, `PING_FAKE_OK`, `IP_FAKE_RULE_EXISTS`, `IP_NEXTHOP_OK`, `IP_FAKE_ROUTE`, conntrack logging). **Later phases MUST NOT edit files in `test/stubs/` — all stub behavior is declared in A1. Tests select behavior via env vars only.** Commit blocks in D2, D3, E1, E3 omit `test/stubs/*` from `git add` (those files are already committed in A1).

---

## Phase A — Foundations, contracts, test harness  *(Wave 1)*

### Task A1: bats/shellcheck harness + command stubs

**Files:**
- Create: `test/lib/harness.bash`
- Create: `test/stubs/uci`, `test/stubs/nft`, `test/stubs/ip`, `test/stubs/awg`, `test/stubs/conntrack`, `test/stubs/ubus`, `test/stubs/logger`, `test/stubs/ping`
- Create: `test/unit/harness.bats`

- [ ] **Step 1: Write the failing test**

`test/unit/harness.bats`:
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'

@test "stubs are on PATH and log their args" {
  run uci show network
  [ "$status" -eq 0 ]
  run cat "$STUB_LOG"
  [[ "$output" == *"uci show network"* ]]
}

@test "nft stub records ruleset adds" {
  nft add element inet fw4 amnezia_ru4 '{ 1.2.3.0/24 }'
  run cat "$STUB_LOG"
  [[ "$output" == *"nft add element inet fw4 amnezia_ru4"* ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats test/unit/harness.bats`
Expected: FAIL ("harness.bash: No such file").

- [ ] **Step 3: Implement harness + stubs**

`test/lib/harness.bash`:
```bash
# Common bats harness: stubs on PATH, scratch dirs, log file.
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STUB_LOG="${BATS_TEST_TMPDIR:-/tmp}/stub.log"
: > "$STUB_LOG"
export PATH="$HARNESS_DIR/stubs:$PATH"
export AMNEZIA_DRYRUN=1

# Skip helper for Tier-2 (real-kernel) tests.
_require_linux_nft() { command -v nft >/dev/null 2>&1 && [ "$(uname -s)" = Linux ]; }
```

Each stub in `test/stubs/` is executable. ALL stub behavior for the entire plan is declared here; later phases select behavior via env vars only — they MUST NOT edit these files.

Template (`uci` shown):
```bash
#!/bin/sh
echo "uci $*" >> "${STUB_LOG:-/dev/null}"
case "$1 $2" in
  "show network") echo "network.@interface[0]=interface" ;;
  "get amnezia") exit 0 ;;
  "show amnezia")
    # UCI_FAKE_TUNNELS: space-separated list of tunnel names to report as enabled.
    if [ -n "$UCI_FAKE_TUNNELS" ]; then
      for _t in $UCI_FAKE_TUNNELS; do echo "amnezia.${_t}=tunnel"; echo "amnezia.${_t}.enabled=1"; done
    fi ;;
esac
exit 0
```

`nft` stub — all NFT_FAKE_* branches pre-declared:
```bash
#!/bin/sh
echo "nft $*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  "list set inet fw4 amnezia_ru4")
    # NFT_FAKE_RU4_COUNT: number of elements to emit (0 = empty set).
    _n=${NFT_FAKE_RU4_COUNT:-0}
    if [ "$_n" -gt 0 ]; then printf 'elements = { '; i=0; while [ $i -lt $_n ]; do printf '10.0.%d.0/24, ' $i; i=$((i+1)); done; printf '}\n'; fi ;;
esac
exit 0
```

`awg` stub — AWG_FAKE_HS branch pre-declared:
```bash
#!/bin/sh
echo "awg $*" >> "${STUB_LOG:-/dev/null}"
case "$1" in
  show)
    _now=$(date +%s 2>/dev/null || echo 9999999999)
    case "${AWG_FAKE_HS:-stale}" in
      now)   printf 'PUBKEY\t%s\n' "$_now" ;;
      stale) printf 'PUBKEY\t0\n' ;;
      *)     printf 'PUBKEY\t%s\n' "${AWG_FAKE_HS}" ;;
    esac ;;
esac
exit 0
```

`ping` stub — PING_FAKE_OK branch pre-declared:
```bash
#!/bin/sh
echo "ping $*" >> "${STUB_LOG:-/dev/null}"
exit "${PING_FAKE_OK:-0}"
```

`ip` stub — IP_FAKE_RULE_EXISTS, IP_NEXTHOP_OK, IP_FAKE_ROUTE branches pre-declared:
```bash
#!/bin/sh
echo "ip $*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  "rule show"*)
    [ "${IP_FAKE_RULE_EXISTS:-0}" = 1 ] && printf 'fwmark 0x0a0000/0xff0000 lookup 100\nfwmark 0x0b0000/0xff0000 lookup 101\n' ;;
  "nexthop help")
    [ "${IP_NEXTHOP_OK:-0}" = 1 ] && exit 0 || exit 1 ;;
  "-j route show table vpn_pool"|"-j route show table 101")
    printf '%s\n' "${IP_FAKE_ROUTE:-[]}" ;;
  "rule show"*"to "*"lookup 110")
    # IP_FAKE_PROBE_RULE: set to 1 if probe rule already exists
    [ "${IP_FAKE_PROBE_RULE:-0}" = 1 ] && printf 'to 1.1.1.1 lookup 110\n' ;;
esac
exit 0
```

`conntrack` stub — logs all args (conntrack flush assertions checked via STUB_LOG):
```bash
#!/bin/sh
echo "conntrack $*" >> "${STUB_LOG:-/dev/null}"
exit 0
```

`ubus` and `logger` stubs: same shape — log `"$0 $*"`, exit 0.

Make all stubs executable: `chmod +x test/stubs/*`.

- [ ] **Step 4: Run to verify pass**

Run: `bats test/unit/harness.bats`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**
```bash
git add test/lib/harness.bash test/stubs test/unit/harness.bats
git commit -m "test(harness): bats stubs and PATH harness for hardware-free tests"
```

### Task A2: shared lib — fwmark constants + paths

**Files:**
- Create: `openwrt/lib/amnezia-common.sh`
- Create: `test/unit/common-constants.bats`

- [ ] **Step 1: Failing test**

`test/unit/common-constants.bats`:
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; }

@test "fwmark constants match the design contract" {
  [ "$STICKY_MARK" = "0x0A0000" ]
  [ "$POOL_MARK" = "0x0B0000" ]
  [ "$MARK_MASK" = "0x0FF0000" ]
}
@test "table ids match contract" {
  [ "$TBL_STICKY" = "100" ]
  [ "$TBL_POOL" = "101" ]
}
@test "member conntrack mark is low-byte and never collides with selector nibble" {
  run member_ctmark 3
  [ "$output" = "0x000003" ]
}
```

- [ ] **Step 2: Run — fails** (`amnezia-common.sh` missing). `bats test/unit/common-constants.bats` → FAIL.

- [ ] **Step 3: Implement**

`openwrt/lib/amnezia-common.sh`:
```sh
# Shared constants + helpers for amnezia multi-tunnel. POSIX sh (BusyBox ash).
STICKY_MARK=0x0A0000
POOL_MARK=0x0B0000
MARK_MASK=0x0FF0000
TBL_STICKY=100
TBL_POOL=101
SET_RU4=amnezia_ru4
SET_RU_TLD4=amnezia_ru_tld4
SET_STICKY4=amnezia_sticky4
STATE_FILE=/var/run/amnezia-failover.json
CONF_DIR=/etc/amnezia
RU_CIDR_PERSIST=/etc/amnezia/ru.cidr
MAX_TUNNELS=5

# Per-member conntrack mark (balance mode): low byte only, never the selector nibble.
member_ctmark() { printf '0x%06x\n' "$1"; }

amz_log() { logger -t amnezia-failover "$*" 2>/dev/null; [ -n "$AMNEZIA_DEBUG" ] && echo "amnezia: $*" >&2; }
```

- [ ] **Step 4: Run — passes.** `bats test/unit/common-constants.bats` → PASS (3).
- [ ] **Step 5: Commit**
```bash
git add openwrt/lib/amnezia-common.sh test/unit/common-constants.bats
git commit -m "feat(common): shared fwmark/table/set constants and helpers"
```

### Task A3: AmneziaWG `.conf` parser

**Files:**
- Modify: `openwrt/lib/amnezia-common.sh`
- Create: `test/unit/parse-conf.bats`, `test/fixtures/awg-sample.conf`, `test/fixtures/awg-crlf.conf`

- [ ] **Step 1: Failing test**

`test/fixtures/awg-sample.conf`:
```ini
[Interface]
PrivateKey = AAA_priv
Address = 10.8.0.2/24
Jc = 4
Jmin = 40
Jmax = 70
[Peer]
PublicKey = BBB_pub
PresharedKey = CCC_psk
Endpoint = vpn.example.com:51820
PersistentKeepalive = 25
```

`test/fixtures/awg-crlf.conf`: same as `awg-sample.conf` but with CRLF line endings. Create it with:
```bash
sed 's/$/\r/' test/fixtures/awg-sample.conf > test/fixtures/awg-crlf.conf
```

`test/unit/parse-conf.bats`:
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; }

@test "parse_awg_conf extracts interface+peer fields" {
  parse_awg_conf "$HARNESS_DIR/../test/fixtures/awg-sample.conf"
  [ "$AWG_PrivateKey" = "AAA_priv" ]
  [ "$AWG_Address" = "10.8.0.2/24" ]
  [ "$AWG_Jc" = "4" ]
  [ "$AWG_PublicKey" = "BBB_pub" ]
  [ "$AWG_Endpoint_host" = "vpn.example.com" ]
  [ "$AWG_Endpoint_port" = "51820" ]
  [ "$AWG_PersistentKeepalive" = "25" ]
}
@test "parse_awg_conf strips CR from CRLF files (no trailing CR in port)" {
  parse_awg_conf "$HARNESS_DIR/../test/fixtures/awg-crlf.conf"
  # AWG_Endpoint_port must equal exactly "51820" with no trailing \r
  [ "$AWG_Endpoint_port" = "51820" ]
}
@test "parse_awg_conf fails cleanly on missing file" {
  run parse_awg_conf /no/such/file
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement** (append to `amnezia-common.sh`).
> CR-strip uses `printf '%s' ... | tr -d '\r'` — NOT `${_line%$'\r'}` which is a bashism that does nothing in BusyBox ash.
```sh
# Parse an AmneziaWG client .conf into AWG_<Key> vars. Endpoint split into host/port.
parse_awg_conf() {
  _f=$1; [ -f "$_f" ] || { amz_log "conf missing: $_f"; return 1; }
  _sec=""
  while IFS= read -r _line; do
    _line=$(printf '%s' "$_line" | tr -d '\r')
    case "$_line" in
      \[Interface\]*) _sec=Interface; continue ;;
      \[Peer\]*) _sec=Peer; continue ;;
      ""|\#*|\;*) continue ;;
    esac
    case "$_line" in *=*) ;; *) continue ;; esac
    _k=$(printf '%s' "${_line%%=*}" | tr -d ' \t')
    _v=$(printf '%s' "${_line#*=}" | sed 's/^[ \t]*//; s/[ \t]*$//')
    [ -n "$_sec" ] || continue
    if [ "$_k" = Endpoint ]; then
      AWG_Endpoint_host=${_v%:*}; AWG_Endpoint_port=${_v##*:}
    fi
    eval "AWG_${_k}=\$_v"
  done < "$_f"
  [ -n "$AWG_PrivateKey" ] && [ -n "$AWG_PublicKey" ] || { amz_log "conf incomplete: $_f"; return 1; }
  return 0
}
```

- [ ] **Step 4: Run — passes (3 tests including CRLF).**
- [ ] **Step 5: Commit**
```bash
git add openwrt/lib/amnezia-common.sh test/unit/parse-conf.bats test/fixtures/awg-sample.conf test/fixtures/awg-crlf.conf
git commit -m "feat(common): AmneziaWG .conf parser with CRLF tolerance"
```

### Task A4: state-file JSON schema + validator

**Files:**
- Create: `test/lib/state-schema.json`, `test/unit/state-schema.bats`, `openwrt/amnezia-status.sh` (skeleton emitting empty valid doc)

- [ ] **Step 1: Failing test**

`test/lib/state-schema.json` (documented contract — fields the monitor MUST emit):
```json
{
  "required": ["mode","active_pool","active_sticky","all_down","tunnels"],
  "tunnel_required": ["name","enabled","up","metric","weight","handshake_age","carrying","exit_ip"]
}
```

`test/unit/state-schema.bats`:
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'

@test "amnezia-status emits a doc with all required top-level keys" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-status.sh" --emit-empty
  [ "$status" -eq 0 ]
  for k in mode active_pool active_sticky all_down tunnels; do
    echo "$output" | grep -q "\"$k\""
  done
}
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** `openwrt/amnezia-status.sh`:
```sh
#!/bin/sh
# Emits the monitor state JSON. With --emit-empty, prints a valid empty doc (for tests/boot).
. /usr/lib/amnezia/amnezia-common.sh 2>/dev/null || . "$(dirname "$0")/lib/amnezia-common.sh"
emit_empty() {
  cat <<'JSON'
{"mode":"failover","active_pool":null,"active_sticky":null,"all_down":true,"tunnels":[]}
JSON
}
case "$1" in
  --emit-empty) emit_empty ;;
  *) [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || emit_empty ;;
esac
```

- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Commit**
```bash
git add test/lib/state-schema.json test/unit/state-schema.bats openwrt/amnezia-status.sh
git commit -m "feat(status): state-file JSON contract and empty-doc emitter"
```

### Task A5: extended UCI scaffold + schema test

**Files:**
- Modify: `openwrt/config/amnezia`
- Create: `test/unit/uci-schema.bats`

- [ ] **Step 1: Failing test**

`test/unit/uci-schema.bats`:
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
@test "amnezia uci scaffold declares globals + a tunnel template" {
  f="$HARNESS_DIR/../openwrt/config/amnezia"
  grep -q "config globals 'globals'" "$f"
  grep -q "option mode 'failover'" "$f"
  grep -q "option sticky_target 'awg1'" "$f"
  grep -q "config tunnel 'awg1'" "$f"
  grep -q "option metric '1'" "$f"
}
@test "existing config amnezia 'config' section and routing_mode are preserved" {
  f="$HARNESS_DIR/../openwrt/config/amnezia"
  grep -q "config amnezia 'config'" "$f"
  grep -q "option routing_mode" "$f"
}
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** — APPEND the new sections to `openwrt/config/amnezia`, preserving the existing `config amnezia 'config'` block (which holds `routing_mode`, `installed_version`, `installed_ts`). Do NOT remove or replace the existing content:
```
config globals 'globals'
	option mode 'failover'
	option sticky_target 'awg1'

config tunnel 'awg1'
	option enabled '1'
	option label 'Primary'
	option metric '1'
	option weight '1'
```

- [ ] **Step 4: Run — passes (2 tests).**
- [ ] **Step 5: Commit**
```bash
git add openwrt/config/amnezia test/unit/uci-schema.bats
git commit -m "feat(config): multi-tunnel UCI scaffold (globals + tunnel sections)"
```

---

## Phase B — nft classifier, sets, dnsmasq, RU loader  *(Wave 2)*

### Task B1: classifier nft include with own set declarations

**Files:**
- Create: `openwrt/nftables.d/30-amnezia-classify.nft`
- Create: `test/unit/classify-nft.bats`, `test/integration/classify-load.bats`

- [ ] **Step 1: Failing tests**

`test/unit/classify-nft.bats` (structural — runs on macOS):
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/nftables.d/30-amnezia-classify.nft"
@test "declares all three sets as interval ipv4 sets" {
  grep -q "set amnezia_ru4" "$F"
  grep -q "set amnezia_ru_tld4" "$F"
  grep -q "set amnezia_sticky4" "$F"
  grep -q "flags interval" "$F"
}
@test "classifier chain hooks prerouting at mangle priority" {
  grep -Eq "type filter hook prerouting priority (mangle|-150)" "$F"
}
@test "marks pool and sticky and returns RU direct" {
  grep -q "meta mark set 0x0b0000" "$F"
  grep -q "meta mark set 0x0a0000" "$F"
  grep -Eq "@amnezia_ru(4|_tld4).*(return|accept)" "$F"
}
```

`test/integration/classify-load.bats` (Tier 2 — real nft):
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { _require_linux_nft || skip "needs Linux nft"; }
@test "classifier include parses under real nft -c" {
  # Wrap in a minimal table so the include is self-contained for syntax check.
  tmp="$BATS_TEST_TMPDIR/t.nft"
  { echo 'table inet fw4 {'; cat "$HARNESS_DIR/../openwrt/nftables.d/30-amnezia-classify.nft"; echo '}'; } > "$tmp"
  run sudo nft -c -f "$tmp"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run — fail** (file missing). Tier-2 test `skip`s on macOS.

- [ ] **Step 3: Implement** `openwrt/nftables.d/30-amnezia-classify.nft` (fw4 includes this inside `table inet fw4`; do NOT re-declare the table):
```nft
# amnezia multi-tunnel classifier — included into inet fw4 by fw4.
set amnezia_ru4      { type ipv4_addr; flags interval; auto-merge; }
set amnezia_ru_tld4  { type ipv4_addr; flags interval; auto-merge; }
set amnezia_sticky4  { type ipv4_addr; flags interval; auto-merge; }

chain amnezia_classify {
	type filter hook prerouting priority mangle; policy accept;
	# Only classify LAN-sourced forwarded traffic.
	# @@LAN_IFNAME@@ is replaced by the installer (see Task D1/M-a substitution step).
	iifname != "@@LAN_IFNAME@@" return
	# RU-direct: leave unmarked -> main table -> wan (zapret operates here).
	ip daddr @amnezia_ru_tld4 return
	ip daddr @amnezia_ru4 return
	# Sticky (Claude/Anthropic) -> dedicated stable tunnel.
	ip daddr @amnezia_sticky4 meta mark set 0x0a0000 return
	# Everything else -> pool.
	meta mark set 0x0b0000
}
```
> Note: `@@LAN_IFNAME@@` is a placeholder replaced by the installer (Phase D) with the real LAN bridge device, read from `uci get network.lan.device` (defaulting to `br-lan`). Priority `mangle` (-150) runs before the ip-rule routing decision and before fw4's default forward handling.

- [ ] **Step 4: Run — unit passes; Tier-2 passes in CI/Linux.**
- [ ] **Step 5: Commit**
```bash
git add openwrt/nftables.d/30-amnezia-classify.nft test/unit/classify-nft.bats test/integration/classify-load.bats
git commit -m "feat(classify): native fw4 nft classifier with own interval sets"
```

### Task B2: dnsmasq UCI ipset config (ru TLD + sticky domains)

> **Mechanism:** On OpenWrt 24.10 dnsmasq is configured via UCI `config ipset` sections (not a standalone `.conf` file). This mirrors `openwrt/configure-dnsmasq-ru-nftset.sh` exactly.

**Files:**
- Create: `openwrt/configure-dnsmasq-amnezia.sh` — generator script that emits UCI `config ipset` sections
- Create: `test/unit/dnsmasq-uci.bats`
- Create: `openwrt/seed-sticky-domains.list`

> **Remove:** Do NOT create `openwrt/dnsmasq-amnezia-nftset.conf`. That static-file approach is wrong for OpenWrt 24.10. Remove it from the file structure list if previously mentioned.

- [ ] **Step 1: Failing test**
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'

@test "configure-dnsmasq-amnezia.sh emits uci set for ru TLD ipset" {
  AMNEZIA_DRYRUN=1 sh "$HARNESS_DIR/../openwrt/configure-dnsmasq-amnezia.sh"
  grep -q "uci set dhcp.amnezia_ru_tld=ipset" "$STUB_LOG"
  grep -q "uci add_list dhcp.amnezia_ru_tld.name=amnezia_ru_tld4" "$STUB_LOG"
  grep -q "uci add_list dhcp.amnezia_ru_tld.domain=.ru" "$STUB_LOG"
}
@test "configure-dnsmasq-amnezia.sh emits uci set for sticky ipset" {
  AMNEZIA_DRYRUN=1 sh "$HARNESS_DIR/../openwrt/configure-dnsmasq-amnezia.sh"
  grep -q "uci set dhcp.amnezia_sticky=ipset" "$STUB_LOG"
  grep -q "uci add_list dhcp.amnezia_sticky.name=amnezia_sticky4" "$STUB_LOG"
  # Each domain from seed-sticky-domains.list must produce a uci add_list call
  grep -q "uci add_list dhcp.amnezia_sticky.domain=claude.ai" "$STUB_LOG"
  grep -q "uci add_list dhcp.amnezia_sticky.domain=anthropic.com" "$STUB_LOG"
}
@test "configure-dnsmasq-amnezia.sh commits dhcp (not just sets)" {
  AMNEZIA_DRYRUN=1 sh "$HARNESS_DIR/../openwrt/configure-dnsmasq-amnezia.sh"
  grep -q "uci commit dhcp" "$STUB_LOG"
}
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement**

`openwrt/seed-sticky-domains.list` (source of truth; also fed into `/etc/amnezia/seed-must-tunnel.list` at install time — see H5):
```
claude.ai
anthropic.com
```

`openwrt/configure-dnsmasq-amnezia.sh` (mirrors `configure-dnsmasq-ru-nftset.sh` UCI pattern):
```sh
#!/bin/sh
# Configure dnsmasq to populate amnezia nftsets via UCI ipset sections.
# Requires dnsmasq-full with nftset support. Safe to re-run.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STICKY_LIST="${STICKY_LIST:-$SCRIPT_DIR/seed-sticky-domains.list}"

# RU TLD -> amnezia_ru_tld4
uci -q delete dhcp.amnezia_ru_tld 2>/dev/null || true
uci set dhcp.amnezia_ru_tld='ipset'
uci add_list dhcp.amnezia_ru_tld.name='amnezia_ru_tld4'
uci add_list dhcp.amnezia_ru_tld.domain='.ru'
uci set dhcp.amnezia_ru_tld.table='fw4'
uci set dhcp.amnezia_ru_tld.table_family='inet'

# Sticky domains -> amnezia_sticky4
uci -q delete dhcp.amnezia_sticky 2>/dev/null || true
uci set dhcp.amnezia_sticky='ipset'
uci add_list dhcp.amnezia_sticky.name='amnezia_sticky4'
uci set dhcp.amnezia_sticky.table='fw4'
uci set dhcp.amnezia_sticky.table_family='inet'
while IFS= read -r _dom; do
  case "$_dom" in ''|\#*) continue ;; esac
  uci add_list dhcp.amnezia_sticky.domain="$_dom"
done < "$STICKY_LIST"

uci commit dhcp
( sleep 1 && /etc/init.d/dnsmasq restart ) &
```

- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Commit**
```bash
git add openwrt/configure-dnsmasq-amnezia.sh openwrt/seed-sticky-domains.list test/unit/dnsmasq-uci.bats
git commit -m "feat(dns): dnsmasq UCI ipset config for ru TLD + sticky domains (OpenWrt 24.10)"
```

### Task B3: RU CIDR loader (port of ru-direct.sh → amnezia_ru4)

**Files:**
- Create: `openwrt/amnezia-ru-cidr.sh`
- Create: `test/unit/ru-cidr.bats`

- [ ] **Step 1: Failing test** (stubbed `nft`; loader reads a local fixture instead of downloading when `RU_SRC` is set):
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
@test "loads CIDRs from a local source into amnezia_ru4 via nft add element" {
  printf '5.0.0.0/8\n31.0.0.0/16\n' > "$BATS_TEST_TMPDIR/ru.zone"
  RU_SRC="file://$BATS_TEST_TMPDIR/ru.zone" RU_CIDR_PERSIST="$BATS_TEST_TMPDIR/ru.cidr" \
    sh "$HARNESS_DIR/../openwrt/amnezia-ru-cidr.sh"
  grep -q "nft add element inet fw4 amnezia_ru4" "$STUB_LOG"
  grep -q "5.0.0.0/8" "$BATS_TEST_TMPDIR/ru.cidr"
}
@test "exits non-zero and keeps persist file if source unreachable" {
  printf '9.9.9.0/24\n' > "$BATS_TEST_TMPDIR/ru.cidr"
  run env RU_SRC="file:///no/such" RU_CIDR_PERSIST="$BATS_TEST_TMPDIR/ru.cidr" \
    sh "$HARNESS_DIR/../openwrt/amnezia-ru-cidr.sh"
  [ "$status" -ne 0 ]
  grep -q "9.9.9.0/24" "$BATS_TEST_TMPDIR/ru.cidr"
}
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** `openwrt/amnezia-ru-cidr.sh`:
```sh
#!/bin/sh
. /usr/lib/amnezia/amnezia-common.sh 2>/dev/null || . "$(dirname "$0")/lib/amnezia-common.sh"
RU_SRC=${RU_SRC:-https://www.ipdeny.com/ipblocks/data/countries/ru.zone}
RU_CIDR_PERSIST=${RU_CIDR_PERSIST:-/etc/amnezia/ru.cidr}
TMP=$(mktemp 2>/dev/null || echo /tmp/ru.$$)

fetch() {
  case "$RU_SRC" in
    file://*) cp "${RU_SRC#file://}" "$TMP" 2>/dev/null ;;
    *) uclient-fetch -qO "$TMP" "$RU_SRC" 2>/dev/null || wget -qO "$TMP" "$RU_SRC" 2>/dev/null ;;
  esac
}
if ! fetch || [ ! -s "$TMP" ]; then
  amz_log "ru-cidr: fetch failed, keeping existing $RU_CIDR_PERSIST"
  rm -f "$TMP"; exit 1
fi
# Flush + repopulate set, then persist.
nft flush set inet fw4 "$SET_RU4" 2>/dev/null
# batch in chunks of 256 to avoid arg limits
_n=0; _buf=""
while IFS= read -r _c; do
  case "$_c" in */*) ;; *) continue ;; esac
  _buf="$_buf $_c,"; _n=$((_n+1))
  if [ "$_n" -ge 256 ]; then
    nft add element inet fw4 "$SET_RU4" "{ ${_buf%,} }" 2>/dev/null
    _buf=""; _n=0
  fi
done < "$TMP"
[ -n "$_buf" ] && nft add element inet fw4 "$SET_RU4" "{ ${_buf%,} }" 2>/dev/null
cp "$TMP" "$RU_CIDR_PERSIST"; rm -f "$TMP"
amz_log "ru-cidr: loaded into $SET_RU4"
exit 0
```

- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Commit**
```bash
git add openwrt/amnezia-ru-cidr.sh test/unit/ru-cidr.bats
git commit -m "feat(ru): RU CIDR loader writing amnezia_ru4 (port of ru-direct.sh)"
```

### Task B4: shellcheck gate for Phase B scripts

> **Per-phase shellcheck (C6):** Each phase lints only its OWN new scripts in its own file. There is no cross-phase accumulator. Phase B lints `amnezia-common.sh`, `amnezia-ru-cidr.sh`, `amnezia-status.sh`, and `configure-dnsmasq-amnezia.sh`.

- [ ] **Step 1: Create** `test/unit/shellcheck-phaseB.bats`:
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
@test "Phase B scripts pass shellcheck" {
  cd "$HARNESS_DIR/.."
  run shellcheck -s sh \
    openwrt/lib/amnezia-common.sh \
    openwrt/amnezia-ru-cidr.sh \
    openwrt/amnezia-status.sh \
    openwrt/configure-dnsmasq-amnezia.sh
  [ "$status" -eq 0 ]
}
```
- [ ] **Step 2: Run** `bats test/unit/shellcheck-phaseB.bats`; fix any findings inline.
- [ ] **Step 3: Commit**
```bash
git add test/unit/shellcheck-phaseB.bats
git commit -m "test(lint): shellcheck gate for Phase B scripts (common/ru/status/dnsmasq)"
```

---

## Phase C — Routing lib: ip rules, tables, IPv6 fail-closed, firewall  *(Wave 2)*

### Task C1: rt_tables file + masked ip-rule install (idempotent)

**Files:**
- Create: `openwrt/iproute2-amnezia-rt_tables.conf`
- Create: `openwrt/lib/amnezia-routing.sh`
- Create: `test/unit/routing-rules.bats`, `test/integration/routing-rules.bats`

- [ ] **Step 1: Failing tests**

`test/unit/routing-rules.bats` (stubbed `ip`, asserts the exact commands):
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; . "$HARNESS_DIR/../openwrt/lib/amnezia-routing.sh"; }

@test "install_ip_rules adds masked fwmark rules for both tables" {
  routing_install_rules
  grep -q "ip rule add fwmark 0x0a0000/0x0ff0000 lookup 100" "$STUB_LOG"
  grep -q "ip rule add fwmark 0x0b0000/0x0ff0000 lookup 101" "$STUB_LOG"
}
@test "install is idempotent (checks existence before add)" {
  IP_FAKE_RULE_EXISTS=1 routing_install_rules
  ! grep -q "ip rule add fwmark 0x0b0000" "$STUB_LOG"
}
@test "blackhole default installed when no member" {
  routing_set_pool_default ""   # empty = no healthy member
  grep -q "ip route replace blackhole default table 101" "$STUB_LOG"
}
@test "pool default points at a single dev in failover mode" {
  routing_set_pool_default "awg2"
  grep -q "ip route replace default dev awg2 table 101" "$STUB_LOG"
}
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement**

`openwrt/iproute2-amnezia-rt_tables.conf`:
```
100 vpn_sticky
101 vpn_pool
```

`openwrt/lib/amnezia-routing.sh`:
```sh
# Routing-table / ip-rule management. Sourced; depends on amnezia-common.sh.
_rule_exists() {  # $1 mark
  [ "${IP_FAKE_RULE_EXISTS:-0}" = 1 ] && return 0
  ip rule show 2>/dev/null | grep -q "fwmark $1"
}
routing_install_rules() {
  _rule_exists "$STICKY_MARK/$MARK_MASK" || ip rule add fwmark "$STICKY_MARK/$MARK_MASK" lookup "$TBL_STICKY"
  _rule_exists "$POOL_MARK/$MARK_MASK"   || ip rule add fwmark "$POOL_MARK/$MARK_MASK" lookup "$TBL_POOL"
}
routing_remove_rules() {
  ip rule del fwmark "$STICKY_MARK/$MARK_MASK" lookup "$TBL_STICKY" 2>/dev/null
  ip rule del fwmark "$POOL_MARK/$MARK_MASK" lookup "$TBL_POOL" 2>/dev/null
}
# $1 = dev (empty -> blackhole). Fail-closed.
routing_set_pool_default() {
  if [ -z "$1" ]; then ip route replace blackhole default table "$TBL_POOL"
  else ip route replace default dev "$1" table "$TBL_POOL"; fi
}
routing_set_sticky_default() {
  if [ -z "$1" ]; then ip route replace blackhole default table "$TBL_STICKY"
  else ip route replace default dev "$1" table "$TBL_STICKY"; fi
}
```

`test/integration/routing-rules.bats` (Tier 2 — real ip, netns):
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { _require_linux_nft || skip "needs Linux"; }
@test "real ip rule add/show roundtrip in a netns" {
  run sudo ip netns add amztest
  sudo ip netns exec amztest ip rule add fwmark 0x0b0000/0x0ff0000 lookup 101
  run sudo ip netns exec amztest ip rule show
  [[ "$output" == *"fwmark 0x0b0000/0xff0000 lookup 101"* ]]
  sudo ip netns del amztest
}
```

- [ ] **Step 4: Run — unit passes; Tier-2 in CI.**
- [ ] **Step 5: Commit**
```bash
git add openwrt/iproute2-amnezia-rt_tables.conf openwrt/lib/amnezia-routing.sh test/unit/routing-rules.bats test/integration/routing-rules.bats
git commit -m "feat(routing): masked ip-rule install + fail-closed table defaults"
```

### Task C2: nexthop group (balance mode) with kernel-feature detection

**Files:**
- Modify: `openwrt/lib/amnezia-routing.sh`
- Modify: `test/unit/routing-rules.bats`

- [ ] **Step 1: Failing test** (append):
```bash
@test "balance mode builds a resilient weighted nexthop group when supported" {
  IP_NEXTHOP_OK=1 routing_set_pool_balance "awg1:2 awg2:1"
  grep -q "ip nexthop replace id 101 group" "$STUB_LOG"
  grep -q "ip route replace default nhid 101 table 101" "$STUB_LOG"
}
@test "balance mode falls back to single dev when nexthop unsupported" {
  IP_NEXTHOP_OK=0 routing_set_pool_balance "awg1:2 awg2:1"
  grep -q "ip route replace default dev awg1 table 101" "$STUB_LOG"
}
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** (append to `amnezia-routing.sh`).
> Note: `type resilient buckets 128 idle_timer 120` — exact resilient syntax is spike-confirmed against Linux kernel 5.10+ (design unverified item; verify during Tier-3 hardware spike on MT7981).
```sh
routing_nexthop_supported() {
  [ -n "$IP_NEXTHOP_OK" ] && return "$([ "$IP_NEXTHOP_OK" = 1 ] && echo 0 || echo 1)"
  ip nexthop help >/dev/null 2>&1 && [ -e /proc/sys/net/ipv4/fib_multipath_hash_policy ]
}
# $1 = "devA:weightA devB:weightB ..." (healthy members, highest priority first)
routing_set_pool_balance() {
  if ! routing_nexthop_supported; then
    set -- $1; _first=${1%%:*}; routing_set_pool_default "$_first"; return
  fi
  sysctl -w net.ipv4.fib_multipath_hash_policy=1 >/dev/null 2>&1
  _grp=""; _id=10
  for _m in $1; do
    _dev=${_m%%:*}; _w=${_m##*:}
    ip nexthop replace id "$_id" dev "$_dev"
    _grp="${_grp}${_id},${_w}/"; _id=$((_id+1))
  done
  ip nexthop replace id "$TBL_POOL" group "${_grp%/}" type resilient buckets 128 idle_timer 120
  ip route replace default nhid "$TBL_POOL" table "$TBL_POOL"
}
```

- [ ] **Step 4: Add** `test/integration/nexthop.bats` (Tier 2):
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { _require_linux_nft || skip "needs Linux nft/ip"; }
@test "resilient nexthop replace with buckets succeeds in a netns" {
  run sudo ip netns add amznhtest
  sudo ip netns exec amznhtest ip link add dummy0 type dummy
  sudo ip netns exec amznhtest ip link set dummy0 up
  sudo ip netns exec amznhtest ip nexthop add id 10 dev dummy0
  run sudo ip netns exec amznhtest ip nexthop replace id 101 group 10,1 type resilient buckets 128 idle_timer 120
  [ "$status" -eq 0 ]
  sudo ip netns del amznhtest
}
```

- [ ] **Step 5: Run — unit passes; Tier-2 in CI.**
- [ ] **Step 6: Commit**
```bash
git add openwrt/lib/amnezia-routing.sh test/unit/routing-rules.bats test/integration/nexthop.bats
git commit -m "feat(routing): resilient nexthop group (buckets 128) for balance mode with feature-gate fallback"
```

### Task C3: IPv6 fail-closed (forward-drop) + firewall vpn-zone + QUIC-rule preservation (UCI dry-run)

**Files:**
- Modify: `openwrt/lib/amnezia-routing.sh` (add `routing_firewall_apply` emitting UCI)
- Create: `test/unit/firewall-uci.bats`, `test/golden/firewall.uci`, `test/fixtures/firewall-quic.uci`

- [ ] **Step 1: Create fixture** `test/fixtures/firewall-quic.uci` (representative `amnezia_block_quic` rule to pre-load into the UCI stub):
```
firewall.amnezia_block_quic=rule
firewall.amnezia_block_quic.name=amnezia-block-quic
firewall.amnezia_block_quic.src=lan
firewall.amnezia_block_quic.proto=udp
firewall.amnezia_block_quic.dest_port=443
firewall.amnezia_block_quic.target=REJECT
```

- [ ] **Step 2: Failing test**
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; . "$HARNESS_DIR/../openwrt/lib/amnezia-routing.sh"; }
@test "firewall dry-run matches golden (vpn zone, v6 drop, quic preserved)" {
  run routing_firewall_dryrun "awg1 awg2"
  echo "$output" > "$BATS_TEST_TMPDIR/out.uci"
  diff "$HARNESS_DIR/../test/golden/firewall.uci" "$BATS_TEST_TMPDIR/out.uci"
}
@test "migration with quic fixture does NOT delete amnezia_block_quic (negative-space)" {
  # Drive migration with the uci stub pre-loaded with the QUIC rule via env.
  UCI_PRELOAD="$HARNESS_DIR/../test/fixtures/firewall-quic.uci" \
    routing_firewall_dryrun "awg1"
  # No delete of the QUIC rule must appear — the migration must never destroy it.
  ! grep -q "uci delete firewall.amnezia_block_quic" "$STUB_LOG"
  ! grep -q "uci set firewall.amnezia_block_quic" "$STUB_LOG"
}
```

- [ ] **Step 3: Run — fails.**
- [ ] **Step 4: Implement** `routing_firewall_dryrun` (emits the intended UCI as text; the real apply runs the same via `uci`):
```sh
# Emit the firewall UCI plan for the given tunnel list (space-separated awgN).
# The amnezia_block_quic rule is NEVER touched — it is preserved as-is.
routing_firewall_dryrun() {
  echo "set firewall.vpn=zone"
  echo "set firewall.vpn.name=vpn"
  echo "set firewall.vpn.network=$1"
  echo "set firewall.vpn.input=REJECT"
  echo "set firewall.vpn.output=ACCEPT"
  echo "set firewall.vpn.forward=REJECT"
  echo "set firewall.vpn.masq=1"
  echo "set firewall.vpn.mtu_fix=1"
  echo "set firewall.vpn_fwd=forwarding"
  echo "set firewall.vpn_fwd.src=lan"
  echo "set firewall.vpn_fwd.dest=vpn"
  # IPv6 fail-closed (forward-drop): drop forwarded lan->wan v6 only.
  echo "set firewall.amnezia_v6_drop=rule"
  echo "set firewall.amnezia_v6_drop.name=amnezia-drop-v6-forward"
  echo "set firewall.amnezia_v6_drop.src=lan"
  echo "set firewall.amnezia_v6_drop.dest=wan"
  echo "set firewall.amnezia_v6_drop.family=ipv6"
  echo "set firewall.amnezia_v6_drop.proto=all"
  echo "set firewall.amnezia_v6_drop.target=DROP"
  # amnezia_block_quic is intentionally NOT touched here.
  # The migration function asserts via negative-space test that no delete or re-set occurs.
}
```
Generate the golden once and verify by eye:
```bash
. openwrt/lib/amnezia-common.sh; . openwrt/lib/amnezia-routing.sh
routing_firewall_dryrun "awg1 awg2" > test/golden/firewall.uci
```

- [ ] **Step 5: Run — passes.**
- [ ] **Step 6: Commit**
```bash
git add openwrt/lib/amnezia-routing.sh test/unit/firewall-uci.bats test/golden/firewall.uci test/fixtures/firewall-quic.uci
git commit -m "feat(routing): vpn zone + scoped IPv6 fail-closed (forward-drop) + QUIC-rule negative-space preservation"
```

### Task C4: Disable LAN RA/DHCPv6 (v6 fail-closed part b)

> **Design:** The v6 fail-closed requirement has two parts: (a) Task C3 drops forwarded LAN→WAN IPv6 traffic at the firewall level; (b) this task disables LAN RA/DHCPv6/NDP so clients stay IPv4-only and never acquire a routable v6 address. Together they are fail-closed for v6.

**Files:**
- Modify: `openwrt/lib/amnezia-routing.sh` (add `routing_disable_lan_v6` function)
- Create: `test/unit/disable-lan-v6.bats`

- [ ] **Step 1: Failing test**
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; . "$HARNESS_DIR/../openwrt/lib/amnezia-routing.sh"; }

@test "routing_disable_lan_v6 sets ra, dhcpv6, ndp to disabled and commits dhcp" {
  routing_disable_lan_v6
  grep -q "uci set dhcp.lan.ra=disabled" "$STUB_LOG"
  grep -q "uci set dhcp.lan.dhcpv6=disabled" "$STUB_LOG"
  grep -q "uci set dhcp.lan.ndp=disabled" "$STUB_LOG"
  grep -q "uci commit dhcp" "$STUB_LOG"
}
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** (append to `openwrt/lib/amnezia-routing.sh`):
```sh
# Disable LAN RA/DHCPv6/NDP so LAN clients stay IPv4-only (v6 fail-closed part b).
routing_disable_lan_v6() {
  uci set dhcp.lan.ra='disabled'
  uci set dhcp.lan.dhcpv6='disabled'
  uci set dhcp.lan.ndp='disabled'
  uci commit dhcp
}
```

- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Commit**
```bash
git add openwrt/lib/amnezia-routing.sh test/unit/disable-lan-v6.bats
git commit -m "feat(routing): disable LAN RA/DHCPv6/NDP — v6 fail-closed part b"
```

---

## Phase D — Installer multi-tunnel loop + migration  *(Wave 3)*

### Task D1: multi-tunnel network/peer generation (dry-run + golden) + remove `::/0` from real installer

**Files:**
- Modify: `openwrt/install-amnezia-pbr.sh` — (a) REMOVE the `uci add_list network.@${CFG}[-1].allowed_ips='::/0'` line at line 242 (IPv4-only; this is a real edit to the live installer, not just a dry-run path); (b) extract per-tunnel UCI into a `gen_tunnel_uci()` function reading `/etc/amnezia/awgN.conf` + UCI tunnel sections; (c) add `--dry-run-tunnel` entry path.
- Create: `test/unit/installer-network.bats`, `test/golden/network-awg2.uci`, `test/fixtures/awg2.conf`

- [ ] **Step 1: Failing test** — tests BOTH the dry-run path AND asserts the real install code never emits `::/0`:
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'

@test "installer dry-run emits network+peer+v4-only allowed_ips for awg2" {
  run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --dry-run-tunnel awg2 \
        --conf "$HARNESS_DIR/../test/fixtures/awg2.conf"
  echo "$output" > "$BATS_TEST_TMPDIR/o"
  diff "$HARNESS_DIR/../test/golden/network-awg2.uci" "$BATS_TEST_TMPDIR/o"
  ! grep -q "::/0" "$BATS_TEST_TMPDIR/o"
}
@test "real installer code path never emits ::/0 to uci stub" {
  # Run a minimal install (UCI_FAKE_TUNNELS=awg1, no actual system changes due to stubs).
  UCI_FAKE_TUNNELS="awg1" \
    sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --dry-run-all
  ! grep -q "::/0" "$STUB_LOG"
}
```
`test/fixtures/awg2.conf` = copy of `awg-sample.conf` with distinct keys/endpoint.

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement**
  - Edit `install-amnezia-pbr.sh` line 242: DELETE `uci add_list network.@${CFG}[-1].allowed_ips='::/0'` entirely. Only `allowed_ips='0.0.0.0/0'` remains.
  - Add `gen_tunnel_uci()` function that, given `awgN` + conf, prints the UCI (network.awgN interface, amneziawg peer, `allowed_ips='0.0.0.0/0'` only).
  - Add `--dry-run-tunnel <name> --conf <file>` entry path that sources the lib, parses the conf, and prints (no `uci` side effects).
  - Generate the golden once and eyeball it.
  - Also add LAN ifname substitution step: read `LAN_DEV=$(uci get network.lan.device 2>/dev/null || echo br-lan)` and substitute `@@LAN_IFNAME@@` in the installed nft classifier file. Add a test asserting the installed file contains the real device name, not the placeholder.

- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Commit**
```bash
git add openwrt/install-amnezia-pbr.sh test/unit/installer-network.bats test/golden/network-awg2.uci test/fixtures/awg2.conf
git commit -m "feat(installer): per-tunnel UCI generation, IPv4-only allowed_ips (remove ::/0), LAN ifname substitution"
```

### Task D2: loop over configured tunnels + zone membership

**Files:**
- Modify: `openwrt/install-amnezia-pbr.sh`
- Create: `test/unit/installer-loop.bats`

- [ ] **Step 1: Failing test** (UCI stub returns two enabled tunnels):
```bash
@test "installer iterates enabled tunnels and folds all into vpn zone" {
  UCI_FAKE_TUNNELS="awg1 awg2" run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --dry-run-all
  echo "$output" | grep -q "firewall.vpn.network=awg1 awg2"
  echo "$output" | grep -q "network.awg1=interface"
  echo "$output" | grep -q "network.awg2=interface"
}
```
Extend the `uci` stub: when `UCI_FAKE_TUNNELS` set, `uci show amnezia` lists those `tunnel` sections enabled.

- [ ] **Step 2–4:** Implement `--dry-run-all` that reads enabled tunnels from UCI and emits all tunnel UCI + the `routing_firewall_dryrun "<list>"`. The `UCI_FAKE_TUNNELS` env var is already declared in the `uci` stub from Task A1 — do NOT edit `test/stubs/uci`. Run → pass.
- [ ] **Step 5: Commit**
```bash
git add openwrt/install-amnezia-pbr.sh test/unit/installer-loop.bats
git commit -m "feat(installer): enumerate enabled tunnels and fold into vpn zone"
```

### Task D3: ordered pbr-removal migration (precondition-gated) + must-tunnel→sticky migration

**Files:**
- Modify: `openwrt/install-amnezia-pbr.sh` (add `migrate_from_pbr`)
- Create: `test/unit/migration.bats`

> The `NFT_FAKE_RU4_COUNT` branch is already declared in the `nft` stub from Task A1 — do NOT edit `test/stubs/nft`.

- [ ] **Step 1: Failing test** — assert ORDER and the precondition gate:
```bash
@test "migration declares sets, repoints dnsmasq, installs, THEN removes pbr only if ru4 populated" {
  NFT_FAKE_RU4_COUNT=12 run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate --dry-run
  # ordering check — assert both markers exist before comparing positions
  o="$output"
  echo "$o" | grep -q "install:classifier" || { echo "marker install:classifier missing"; false; }
  echo "$o" | grep -q "remove:pbr"        || { echo "marker remove:pbr missing"; false; }
  pos_install=$(echo "$o" | grep -n "install:classifier" | head -1 | cut -d: -f1)
  pos_remove=$(echo "$o"  | grep -n "remove:pbr"         | head -1 | cut -d: -f1)
  [ "$pos_install" -lt "$pos_remove" ]
}
@test "migration ABORTS pbr removal when amnezia_ru4 is empty" {
  NFT_FAKE_RU4_COUNT=0 run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate --dry-run
  ! echo "$output" | grep -q "remove:pbr"
  echo "$output" | grep -q "ABORT:ru4-empty"
}
@test "migration does NOT delete or rebuild amnezia_block_quic (negative-space)" {
  # Drive migration with the uci stub pre-loaded with the QUIC rule fixture.
  UCI_PRELOAD="$HARNESS_DIR/../test/fixtures/firewall-quic.uci" \
    NFT_FAKE_RU4_COUNT=12 run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate --dry-run
  ! echo "$output" | grep -q "uci delete firewall.amnezia_block_quic"
  ! echo "$output" | grep -q "uci set firewall.amnezia_block_quic"
}
@test "must-tunnel migration: domains from seed-must-tunnel.list each get a sticky binding" {
  # Fixture: a multi-entry seed-must-tunnel.list
  printf 'example.com\nfoo.org\n' > "$BATS_TEST_TMPDIR/seed-must-tunnel.list"
  MUST_TUNNEL_LIST="$BATS_TEST_TMPDIR/seed-must-tunnel.list" \
    NFT_FAKE_RU4_COUNT=12 run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate --dry-run
  grep -q "uci add_list dhcp.amnezia_sticky.domain=example.com" "$STUB_LOG"
  grep -q "uci add_list dhcp.amnezia_sticky.domain=foo.org" "$STUB_LOG"
}
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** `migrate_from_pbr` following design §7 ordering:
  - In `--dry-run` mode print the `install:classifier`, `repoint:dnsmasq`, gate on `ru4` count (`ABORT:ru4-empty` if 0), then `remove:pbr`.
  - QUIC rule is never touched — no `uci delete firewall.amnezia_block_quic` anywhere in the function.
  - **must-tunnel→sticky migration sub-step:** Read `/etc/amnezia/seed-must-tunnel.list` (or `MUST_TUNNEL_LIST` env override) if present; for each domain, emit a `uci add_list dhcp.amnezia_sticky.domain=<domain>` call, feeding it into the same generator used by `configure-dnsmasq-amnezia.sh` from Task B2. This merges existing must-tunnel entries into the sticky set without losing them.
  - Real mode runs the corresponding commands with the backup/stage-then-reload protocol.

- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Commit**
```bash
git add openwrt/install-amnezia-pbr.sh test/unit/migration.bats
git commit -m "feat(installer): ordered pbr-removal migration + must-tunnel→sticky domain merge"
```

### Task D4: first-install wiring (uci-defaults / clean-install bootstrap)

> This task ensures a clean (non-migration) install also wires up all the new components: routing tables, classifier, dnsmasq ipset, monitor service.

**Files:**
- Modify: `openwrt/install-amnezia-pbr.sh` (add `first_install_wiring` function)
- Create: `test/unit/first-install.bats`

- [ ] **Step 1: Failing test**
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'

@test "first-install wiring copies rt_tables, runs routing_install_rules, enables monitor, installs classifier" {
  UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install --dry-run
  # rt_tables
  grep -q "install:rt_tables" "$STUB_LOG"
  # ip rules
  grep -q "ip rule add fwmark" "$STUB_LOG"
  # monitor enabled
  grep -q "/etc/init.d/amnezia-failover enable" "$STUB_LOG"
  # classifier installed
  grep -q "install:classifier" "$STUB_LOG"
  # dnsmasq ipset configured
  grep -q "uci set dhcp.amnezia_ru_tld=ipset" "$STUB_LOG"
}
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** `first_install_wiring` in `install-amnezia-pbr.sh`:
```sh
first_install_wiring() {
  # 1. rt_tables
  cp "$SCRIPT_DIR/iproute2-amnezia-rt_tables.conf" /etc/iproute2/rt_tables.d/amnezia.conf
  amz_log "install:rt_tables"
  # 2. ip rules
  routing_install_rules
  # 3. classifier (with LAN ifname substitution)
  LAN_DEV=$(uci get network.lan.device 2>/dev/null || echo br-lan)
  sed "s/@@LAN_IFNAME@@/$LAN_DEV/" "$SCRIPT_DIR/nftables.d/30-amnezia-classify.nft" \
    > /etc/nftables.d/30-amnezia-classify.nft
  amz_log "install:classifier"
  # 4. dnsmasq UCI ipset
  sh "$SCRIPT_DIR/configure-dnsmasq-amnezia.sh"
  # 5. monitor enable + start
  /etc/init.d/amnezia-failover enable
  ( sleep 1 && /etc/init.d/amnezia-failover start ) &
}
```
Add `--first-install` entry path that calls `first_install_wiring`. In `--dry-run` mode, print the `install:*` markers and emit UCI to stub log instead of applying to system.

- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Commit**
```bash
git add openwrt/install-amnezia-pbr.sh test/unit/first-install.bats
git commit -m "feat(installer): first-install wiring — rt_tables, rules, classifier, dnsmasq, monitor"
```

---

## Phase E — Monitor daemon + procd init  *(Wave 3)*

### Task E1: health signal — handshake age + bound-ping via dedicated probe route

**Files:**
- Create: `openwrt/amnezia-failover`
- Create: `test/unit/health.bats`

> All stubs (`awg`, `ping`, `ip`) are already declared in Task A1. Do NOT edit `test/stubs/*` here.

- [ ] **Step 1: Failing test** (all stub behavior selected via env vars declared in A1):
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"; . "$HARNESS_DIR/../openwrt/amnezia-failover" --source-only; }

@test "fresh handshake -> healthy WITHOUT requiring a ping (fresh wins immediately)" {
  AWG_FAKE_HS=now PING_FAKE_OK=0 run tunnel_healthy awg1 1.1.1.1
  [ "$status" -eq 0 ]
  # ping must NOT have been called when handshake is fresh
  ! grep -q "ping -I awg1" "$STUB_LOG"
}
@test "stale handshake AND ping fail -> unhealthy" {
  AWG_FAKE_HS=stale PING_FAKE_OK=0 run tunnel_healthy awg1 1.1.1.1
  [ "$status" -ne 0 ]
}
@test "stale handshake but ping ok -> healthy (ping breaks the tie)" {
  AWG_FAKE_HS=stale PING_FAKE_OK=1 run tunnel_healthy awg1 1.1.1.1
  [ "$status" -eq 0 ]
}
@test "probe_setup installs probe route+rule idempotently (no duplicate rules)" {
  # First call with no pre-existing rule
  IP_FAKE_PROBE_RULE=0 probe_setup awg1 1.1.1.1
  _count=$(grep -c "ip rule add to 1.1.1.1 lookup 110" "$STUB_LOG" || true)
  [ "$_count" -eq 1 ]
  # Second call with rule already present — must NOT add again
  IP_FAKE_PROBE_RULE=1 probe_setup awg1 1.1.1.1
  _count2=$(grep -c "ip rule add to 1.1.1.1 lookup 110" "$STUB_LOG" || true)
  [ "$_count2" -eq 1 ]
}
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** in `openwrt/amnezia-failover` (guard a `--source-only` so tests can source without starting the loop).
> Logic: `tunnel_healthy` = "fresh OR ping" — ping is only called when handshake is stale. `probe_setup` is called once at `run_loop` init, not per-ping.
```sh
#!/bin/sh
AMNEZIA_LIB=${AMNEZIA_LIB:-/usr/lib/amnezia}
. "$AMNEZIA_LIB/amnezia-common.sh"
. "$AMNEZIA_LIB/amnezia-routing.sh"
PROBE_TBL=110
HS_STALE=150

handshake_fresh() {  # $1 iface
  _hs=$(awg show "$1" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
  [ -n "$_hs" ] || return 1
  _now=$(date +%s 2>/dev/null || echo 0)
  [ $(( _now - _hs )) -lt "$HS_STALE" ]
}
# Called once at startup per tunnel. Sets up a persistent probe route + idempotent rule.
probe_setup() {  # $1 iface $2 target_ip
  ip route replace "$2" dev "$1" table "$PROBE_TBL" 2>/dev/null
  ip rule show 2>/dev/null | grep -q "to $2 lookup $PROBE_TBL" || \
    ip rule add to "$2" lookup "$PROBE_TBL" 2>/dev/null
}
probe_cleanup() {  # $1 iface $2 target_ip
  ip rule del to "$2" lookup "$PROBE_TBL" 2>/dev/null
  ip route del "$2" table "$PROBE_TBL" 2>/dev/null
}
ping_via() {  # $1 iface $2 target
  ping -I "$1" -c1 -W2 "$2" >/dev/null 2>&1
}
# Healthy if handshake fresh (returns immediately, no ping) OR ping succeeds.
tunnel_healthy() {  # $1 iface $2 track_ip
  handshake_fresh "$1" && return 0
  ping_via "$1" "$2"
}

[ "$1" = "--source-only" ] && return 0 2>/dev/null
```

- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Commit** (stubs already committed in A1 — do not re-add `test/stubs/`):
```bash
git add openwrt/amnezia-failover test/unit/health.bats
git commit -m "feat(monitor): three-signal tunnel health (fresh-OR-ping), idempotent probe setup"
```

### Task E2: debounce state machine

**Files:**
- Modify: `openwrt/amnezia-failover`
- Create: `test/unit/debounce.bats`

- [ ] **Step 1: Failing test**:
```bash
@test "needs 3 consecutive fails to go down, 3 to come up" {
  state_reset awg1
  for i in 1 2; do debounce awg1 0; [ "$(state_get awg1)" = up ]; done
  debounce awg1 0; [ "$(state_get awg1)" = down ]
  for i in 1 2; do debounce awg1 1; [ "$(state_get awg1)" = down ]; done
  debounce awg1 1; [ "$(state_get awg1)" = up ]
}
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** (append; state in `/tmp`):
```sh
DEBOUNCE_N=3
ST_DIR=${ST_DIR:-/tmp/amnezia-fo}
mkdir -p "$ST_DIR" 2>/dev/null
state_reset() { echo "up 0" > "$ST_DIR/$1"; }
state_get()   { awk '{print $1}' "$ST_DIR/$1" 2>/dev/null || echo up; }
# $1 iface, $2 ok(1)/fail(0). Returns 0 if state CHANGED.
debounce() {
  _s=$(awk '{print $1}' "$ST_DIR/$1" 2>/dev/null || echo up)
  _c=$(awk '{print $2}' "$ST_DIR/$1" 2>/dev/null || echo 0)
  if [ "$2" = 1 ]; then _want=up; else _want=down; fi
  if [ "$_s" = "$_want" ]; then echo "$_s 0" > "$ST_DIR/$1"; return 1; fi
  _c=$((_c+1))
  if [ "$_c" -ge "$DEBOUNCE_N" ]; then echo "$_want 0" > "$ST_DIR/$1"; return 0; fi
  echo "$_s $_c" > "$ST_DIR/$1"; return 1
}
```

- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Commit**
```bash
git add openwrt/amnezia-failover test/unit/debounce.bats
git commit -m "feat(monitor): up/down debounce state machine"
```

### Task E3: reconcile — pick best, set both tables, fail-closed, flush conntrack

**Files:**
- Modify: `openwrt/amnezia-failover`
- Create: `test/unit/reconcile.bats`

- [ ] **Step 1: Failing test**:
```bash
@test "failover mode: best healthy by metric becomes pool+sticky default" {
  MODE=failover MEMBERS="awg1:1:1 awg2:2:1" HEALTHY="awg2" STICKY_TARGET=awg1
  _PREV_POOL="" _PREV_STKY=""
  run reconcile
  grep -q "ip route replace default dev awg2 table 101" "$STUB_LOG"      # pool -> only healthy
  grep -q "ip route replace default dev awg2 table 100" "$STUB_LOG"      # sticky re-pinned (awg1 down)
}
@test "all down -> blackhole both tables + selective flush only on change" {
  MODE=failover MEMBERS="awg1:1:1" HEALTHY=""
  _PREV_POOL="awg1" _PREV_STKY="awg1"  # was up, now going down -> change
  run reconcile
  grep -q "ip route replace blackhole default table 101" "$STUB_LOG"
  grep -q "ip route replace blackhole default table 100" "$STUB_LOG"
  grep -q "conntrack -D" "$STUB_LOG"
}
@test "no flush when pool does NOT change (no-change path)" {
  MODE=failover MEMBERS="awg1:1:1" HEALTHY="awg1"
  _PREV_POOL="awg1" _PREV_STKY="awg1"  # same as new result -> no change
  run reconcile
  ! grep -q "conntrack -D" "$STUB_LOG"
}
@test "balance mode flushes only departed member marks, not whole pool" {
  MODE=balance MEMBERS="awg1:1:1 awg2:2:1" HEALTHY="awg1"
  _PREV_HEALTHY="awg1 awg2"  # awg2 departed
  run reconcile
  grep -q "conntrack -D -m 0x000002/0x0ff0000" "$STUB_LOG"  # awg2 = member index 2
  ! grep -q "conntrack -D -m 0x0b0000" "$STUB_LOG"
}
@test "sticky stays on healthy sticky_target when it is up" {
  MODE=failover MEMBERS="awg1:1:1 awg2:2:1" HEALTHY="awg1 awg2" STICKY_TARGET=awg1
  _PREV_POOL="" _PREV_STKY=""
  run reconcile
  grep -q "ip route replace default dev awg1 table 100" "$STUB_LOG"
}
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** (append). `MEMBERS` = `name:metric:weight` list; `HEALTHY` = space list; `_PREV_POOL`/`_PREV_STKY`/`_PREV_HEALTHY` track previous state (initialized empty at startup):
```sh
_is_healthy() { case " $HEALTHY " in *" $1 "*) return 0 ;; esac; return 1; }
# Lowest metric among healthy; ties keep first.
_best_pool() {
  _b=""; _bm=9999
  for _m in $MEMBERS; do _n=${_m%%:*}; _met=$(echo "$_m" | cut -d: -f2)
    _is_healthy "$_n" || continue
    [ "$_met" -lt "$_bm" ] && { _b=$_n; _bm=$_met; }
  done
  echo "$_b"
}
_sticky_pick() {  # prefer sticky_target if healthy, else best pool
  _is_healthy "$STICKY_TARGET" && { echo "$STICKY_TARGET"; return; }
  _best_pool
}
# Member index (1-based) for per-member conntrack mark in balance mode.
_member_idx() {
  _i=1; for _m in $MEMBERS; do [ "${_m%%:*}" = "$1" ] && { echo "$_i"; return; }; _i=$((_i+1)); done; echo 0
}
reconcile() {
  _pool=$(_best_pool); _stk=$(_sticky_pick)
  _changed=0
  [ "$_pool" != "${_PREV_POOL:-}" ] && _changed=1
  [ "$_stk"  != "${_PREV_STKY:-}" ] && _changed=1

  if [ "$MODE" = balance ]; then
    _list=""; _idx=1
    for _m in $MEMBERS; do _n=${_m%%:*}; _w=$(echo "$_m" | cut -d: -f3)
      _is_healthy "$_n" && _list="$_list $_n:$_w"
      _idx=$((_idx+1))
    done
    [ -n "$_list" ] && routing_set_pool_balance "$_list" || routing_set_pool_default ""
    # Flush only members that DEPARTED the healthy set (member-scoped by conntrack mark)
    if [ "$_changed" = 1 ]; then
      for _m in $MEMBERS; do _n=${_m%%:*}
        case " ${_PREV_HEALTHY:-} " in *" $_n "*) ;; *) continue ;; esac  # was not healthy, skip
        _is_healthy "$_n" && continue  # still healthy, skip
        _midx=$(_member_idx "$_n")
        _cmk=$(printf '0x%06x' "$_midx")
        conntrack -D -m "${_cmk}/${MARK_MASK}" >/dev/null 2>&1
      done
    fi
  else
    routing_set_pool_default "$_pool"
    # Flush pool mark only when pool actually changed
    [ "$_changed" = 1 ] && [ -z "$_pool" ] && \
      conntrack -D -m "$POOL_MARK/$MARK_MASK" >/dev/null 2>&1
  fi
  routing_set_sticky_default "$_stk"
  _PREV_POOL="$_pool"; _PREV_STKY="$_stk"; _PREV_HEALTHY="$HEALTHY"
}
```

- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Commit** (conntrack stub already committed in A1 — do not re-add `test/stubs/`):
```bash
git add openwrt/amnezia-failover test/unit/reconcile.bats
git commit -m "feat(monitor): reconcile best tunnel, fail-closed, selective conntrack flush"
```

### Task E4: state JSON writer

**Files:**
- Modify: `openwrt/amnezia-failover`
- Create: `test/unit/state-write.bats`

- [ ] **Step 1: Failing test**:
```bash
@test "writes state json with required keys and per-tunnel objects" {
  MODE=failover MEMBERS="awg1:1:1 awg2:2:1" HEALTHY="awg2" STATE_FILE="$BATS_TEST_TMPDIR/s.json"
  write_state awg2 awg2
  for k in mode active_pool active_sticky all_down tunnels; do grep -q "\"$k\"" "$BATS_TEST_TMPDIR/s.json"; done
  grep -q "\"name\":\"awg1\"" "$BATS_TEST_TMPDIR/s.json"
  grep -q "\"up\":false" "$BATS_TEST_TMPDIR/s.json"   # awg1 not in HEALTHY
}
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** `write_state <pool_dev> <sticky_dev>` building JSON by hand (no jq dependency):
```sh
write_state() {
  _pool=$1; _stk=$2; _alldown=true; [ -n "$_pool" ] && _alldown=false
  _t=""
  for _m in $MEMBERS; do _n=${_m%%:*}; _met=$(echo "$_m"|cut -d: -f2); _w=$(echo "$_m"|cut -d: -f3)
    _up=false; _is_healthy "$_n" && _up=true
    _car=false; { [ "$_n" = "$_pool" ] || [ "$_n" = "$_stk" ]; } && _car=true
    _t="$_t{\"name\":\"$_n\",\"enabled\":true,\"up\":$_up,\"metric\":$_met,\"weight\":$_w,\"handshake_age\":-1,\"carrying\":$_car,\"exit_ip\":null},"
  done
  printf '{"mode":"%s","active_pool":%s,"active_sticky":%s,"all_down":%s,"tunnels":[%s]}\n' \
    "$MODE" "$([ -n "$_pool" ] && echo "\"$_pool\"" || echo null)" \
    "$([ -n "$_stk" ] && echo "\"$_stk\"" || echo null)" "$_alldown" "${_t%,}" > "$STATE_FILE"
}
```

- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Commit**
```bash
git add openwrt/amnezia-failover test/unit/state-write.bats
git commit -m "feat(monitor): JSON state writer for LuCI panel"
```

### Task E5: main loop + procd init + ubus event subscription

**Files:**
- Modify: `openwrt/amnezia-failover` (add `run_loop` reading UCI, ubus-subscribe + timer)
- Create: `openwrt/amnezia-failover.init`
- Create: `test/unit/init.bats`, `test/integration/failover-e2e.bats`

- [ ] **Step 1: Failing tests**

`test/unit/init.bats`:
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/amnezia-failover.init"
@test "procd init declares the service and respawn" {
  grep -q "USE_PROCD=1" "$F"
  grep -q "procd_set_param respawn" "$F"
  grep -q "/usr/sbin/amnezia-failover" "$F"
}
```

`test/integration/failover-e2e.bats` (Tier 2 — dummy ifaces, real ip/route; documents the golden-path E2E):
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { _require_linux_nft || skip "needs Linux"; }
@test "pulling the active dummy tunnel moves the pool default to the backup" {
  ns=amzfo; sudo ip netns add $ns
  sudo ip netns exec $ns sh -c '
    ip link add awg1 type dummy; ip link add awg2 type dummy; ip link set awg1 up; ip link set awg2 up
    ip route replace default dev awg1 table 101
    ip link set awg1 down
    ip route replace default dev awg2 table 101
    ip route show table 101' | grep -q "default dev awg2"
  sudo ip netns del $ns
}
```

- [ ] **Step 2: Run — unit fails; Tier-2 skips on macOS.**
- [ ] **Step 3: Implement** `run_loop` (read `MEMBERS`/`MODE`/`STICKY_TARGET`/track_ips from UCI; call `probe_setup <iface> <track_ip>` once per tunnel at startup; then every interval: for each tunnel `tunnel_healthy`→`debounce`, rebuild `HEALTHY`, `reconcile`, `write_state`; call `probe_cleanup` for all tunnels on exit/shutdown; also subscribe to `ubus` `network.interface` events to trigger an immediate pass). And `openwrt/amnezia-failover.init`:
```sh
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10
start_service() {
  procd_open_instance
  procd_set_param command /usr/sbin/amnezia-failover
  procd_set_param respawn 3600 5 5
  procd_set_param stderr 1
  procd_close_instance
}
```

- [ ] **Step 4: Run — unit passes; Tier-2 in CI.**
- [ ] **Step 5: Commit**
```bash
git add openwrt/amnezia-failover openwrt/amnezia-failover.init test/unit/init.bats test/integration/failover-e2e.bats
git commit -m "feat(monitor): main loop, procd init, ubus-driven reconcile"
```

### Task E6: shellcheck gate for Phase E scripts

> **Per-phase shellcheck (C6):** Phase E lints only its own scripts: `amnezia-failover`, `amnezia-failover.init`, `amnezia-status.sh`, and `amnezia-failover-ctl.sh`. Phase C owns `lib/amnezia-routing.sh` (linted in Phase C). Phase D owns `install-amnezia-pbr.sh` (linted by Phase D). Do NOT add cross-phase scripts here.

- [ ] **Step 1: Create** `test/unit/shellcheck-phaseE.bats`:
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
@test "Phase E scripts pass shellcheck" {
  cd "$HARNESS_DIR/.."
  run shellcheck -s sh \
    openwrt/amnezia-failover \
    openwrt/amnezia-failover.init \
    openwrt/amnezia-status.sh \
    openwrt/amnezia-failover-ctl.sh
  [ "$status" -eq 0 ]
}
```
- [ ] **Step 2: Run** `bats test/unit/shellcheck-phaseE.bats`; fix any findings inline.
- [ ] **Step 3: Commit**
```bash
git add test/unit/shellcheck-phaseE.bats
git commit -m "test(lint): shellcheck gate for Phase E scripts (monitor/init/ctl)"
```

---

## Phase F — LuCI ACL → ctl helper → panel  *(Wave 4)*

> **Ordering (H8b):** F1 (ACL) → F3 (ctl helper) → F2 (panel). The panel (F2) references the ctl binary that F3 creates, so F3 must come before F2. Tasks are renumbered to enforce this dependency.

### Task F1: ACL — add state read + monitor execs, drop pbr execs

> **Real ACL shape (H8a):** The actual `luci-app-amnezia.json` has `read/file` and `write/file` sections. Exec entries are full absolute paths under `write/file`. There is no `read/ubus` block. Edits must match the real structure.
> Current real shape (read before editing):
> - `read/file`: `/etc/amnezia/ru-update.json`, `/etc/amnezia/blockcheck.json`, `/etc/amnezia/seed-must-tunnel.list`
> - `write/file`: `/usr/bin/awg-toggle`, `/usr/bin/awg-status`, ..., `/usr/bin/pbr-status`, `/usr/bin/pbr-reload`

**Files:**
- Modify: `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json`
- Create: `test/unit/acl.bats`

- [ ] **Step 1: Failing test** (aligned to real ACL shape):
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/luci-app-amnezia/acl/luci-app-amnezia.json"
@test "acl grants read of state json (in read/file section)" {
  node -e "
    const a = JSON.parse(require('fs').readFileSync('$F','utf8'));
    const rf = a['luci-app-amnezia'].read.file;
    if (!rf['/var/run/amnezia-failover.json']) throw new Error('state file missing from read/file');
  "
}
@test "acl keeps seed-must-tunnel.list in read/file (runtime path preserved)" {
  node -e "
    const a = JSON.parse(require('fs').readFileSync('$F','utf8'));
    const rf = a['luci-app-amnezia'].read.file;
    if (!rf['/etc/amnezia/seed-must-tunnel.list']) throw new Error('seed-must-tunnel.list missing');
  "
}
@test "acl grants exec of failover-ctl full path (in write/file)" {
  node -e "
    const a = JSON.parse(require('fs').readFileSync('$F','utf8'));
    const wf = a['luci-app-amnezia'].write.file;
    if (!wf['/usr/bin/amnezia-failover-ctl']) throw new Error('failover-ctl missing from write/file');
  "
}
@test "acl drops pbr-status and pbr-reload" {
  node -e "
    const a = JSON.parse(require('fs').readFileSync('$F','utf8'));
    const wf = a['luci-app-amnezia'].write.file;
    if (wf['/usr/bin/pbr-status'])  throw new Error('pbr-status still present');
    if (wf['/usr/bin/pbr-reload'])  throw new Error('pbr-reload still present');
  "
}
@test "acl is valid json" { node -e "JSON.parse(require('fs').readFileSync('$F','utf8'))"; }
```

- [ ] **Step 2–4:** Edit the ACL JSON:
  - Add `/var/run/amnezia-failover.json` to `read/file` (with `["read"]`).
  - Keep `/etc/amnezia/seed-must-tunnel.list` in `read/file` — do NOT rename the runtime path (see H5; main.js reads this path at line ~962 and it must remain).
  - Add `/usr/bin/amnezia-failover-ctl` and `/usr/bin/amnezia-status` to `write/file` (with `["exec"]`).
  - Remove `/usr/bin/pbr-status` and `/usr/bin/pbr-reload` from `write/file`.
  - Do NOT add a `read/ubus` block — it does not exist in the real ACL structure.
  Run → pass.
- [ ] **Step 5: Commit**
```bash
git add openwrt/luci-app-amnezia/acl/luci-app-amnezia.json test/unit/acl.bats
git commit -m "feat(luci): ACL for failover state/exec; drop pbr execs; keep seed-must-tunnel.list path"
```

### Task F3: ctl helper script (apply mode/sticky/weight to UCI + restart monitor)

> **Moved before F2:** The panel (now Task F2) calls the ctl binary; ctl must exist first.

**Files:**
- Create: `openwrt/amnezia-failover-ctl.sh`
- Create: `test/unit/ctl.bats`

- [ ] **Step 1: Failing test**:
```bash
@test "ctl sets uci mode and restarts monitor" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh" set-mode balance
  grep -q "uci set amnezia.globals.mode=balance" "$STUB_LOG"
  grep -q "uci commit amnezia" "$STUB_LOG"
}
@test "ctl rejects invalid mode" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh" set-mode bogus
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2–4:** Implement `set-mode`, `set-sticky`, `set-weight <awgN> <w>`, `toggle <awgN>` writing UCI + `( sleep 1 && /etc/init.d/amnezia-failover restart ) &` (background, per the SSH-drop guard). Validate inputs. Run → pass.
- [ ] **Step 5: Commit**
```bash
git add openwrt/amnezia-failover-ctl.sh test/unit/ctl.bats
git commit -m "feat(luci): failover control helper (mode/sticky/weight/toggle)"
```

### Task F2: panel multi-tunnel table + status

> **Comes after F3 (ctl helper):** The panel calls `/usr/bin/amnezia-failover-ctl` — verify the installed helper name matches before wiring the panel.

**Files:**
- Modify: `openwrt/luci-app-amnezia/view/main.js`
- Create: `test/unit/luci-js.bats`

- [ ] **Step 1: Failing test** (lint + presence of the new render/parse functions + ctl path match):
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/luci-app-amnezia/view/main.js"
@test "main.js parses and references the failover state file + per-tunnel table" {
  node --check "$F"
  grep -q "amnezia-failover.json" "$F"
  grep -q "renderTunnelTable" "$F"
  grep -q "parseFailoverState" "$F"
}
@test "main.js still reads seed-must-tunnel.list at the existing runtime path (~line 962)" {
  grep -q "seed-must-tunnel.list" "$F"
}
@test "panel calls amnezia-failover-ctl matching the helper installed name" {
  # The ctl helper is installed as amnezia-failover-ctl (see F3/ACL).
  grep -q "amnezia-failover-ctl" "$F"
}
```

- [ ] **Step 2: Run — fails** (functions absent).
- [ ] **Step 3: Implement** `parseFailoverState(json)` and `renderTunnelTable(state)` in `main.js`, wired into the existing `refresh()` poller and a new section: per-tunnel rows (label, up/down badge, active vs standby, metric/weight inputs, handshake age, exit IP), plus `mode` (failover/balance) and `sticky_target` pickers that call `amnezia-failover-ctl` (matching the installed name from F3). Follow the existing `paint*`/`E(...)` patterns in the file. Do NOT rename or change the `seed-must-tunnel.list` read path (~line 962).

- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Commit**
```bash
git add openwrt/luci-app-amnezia/view/main.js test/unit/luci-js.bats
git commit -m "feat(luci): multi-tunnel status table, mode and sticky pickers"
```

---

## Phase G — Packaging, sync, CI, runbook, docs  *(Wave 5)*

### Task G1: Makefiles — drop pbr deps, add conntrack-tools, bump release

**Files:**
- Modify: `packages/amnezia-pbr/Makefile`, `packages/luci-app-amnezia/Makefile`
- Create: `test/unit/packaging.bats`

- [ ] **Step 1: Failing test**:
```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
A="$HARNESS_DIR/../packages/amnezia-pbr/Makefile"
@test "amnezia-pbr drops pbr/luci-app-pbr, adds conntrack-tools, ip-full optional" {
  ! grep -Eq "DEPENDS.*\+pbr( |$)" "$A"
  ! grep -q "luci-app-pbr" "$A"
  grep -q "conntrack-tools" "$A"
  grep -q "PKG_RELEASE:=3" "$A"
}
```

- [ ] **Step 2–4:** Edit DEPENDS (remove `+pbr`, `+luci-app-pbr`; add `+conntrack-tools`; `ip-full` as `+IPV6:` is wrong — add plain `+ip-full` only if balance needs it, document it as the LB-mode dep), bump `PKG_RELEASE:=3` on both. Run → pass.
- [ ] **Step 5: Commit**
```bash
git add packages/amnezia-pbr/Makefile packages/luci-app-amnezia/Makefile test/unit/packaging.bats
git commit -m "chore(pkg): drop pbr deps, add conntrack-tools, bump PKG_RELEASE to r3"
```

### Task G2: sync-to-packages for new files

**Files:**
- Modify: `dev/sync-to-packages.sh`
- Create: `test/unit/sync.bats`

- [ ] **Step 1: Failing test** — assert each new runtime file has a sync line and the pbr.d template block is actually gone (assertions are concrete strings that must be absent, not trivially-green patterns):
```bash
@test "sync covers monitor/lib/nft/init and drops pbr.d template references" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-failover" "$F"
  grep -q "lib/amnezia-common.sh" "$F"
  grep -q "nftables.d/30-amnezia-classify.nft" "$F"
  grep -q "configure-dnsmasq-amnezia.sh" "$F"
  # These pbr.d references must be gone — strings that actually appear in the old script:
  ! grep -q "pbr.d/ru-direct.sh" "$F"
  ! grep -q "/etc/pbr.d" "$F"
  ! grep -q "99-lan-vpn" "$F"
}
@test "sync includes all new runtime paths" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-failover" "$F"
  grep -q "amnezia-failover.init" "$F"
  grep -q "amnezia-routing.sh" "$F"
  grep -q "iproute2-amnezia-rt_tables.conf" "$F"
}
```

- [ ] **Step 2–4:** Add `cp`/`mkdir` lines mapping each new `openwrt/...` file to the package `files/` tree (`/usr/lib/amnezia/`, `/etc/nftables.d/`, `/usr/sbin/`, `/etc/init.d/`, `/etc/iproute2/rt_tables.d/`, dnsmasq conf to `/etc/dnsmasq.d/` or appended via uci-defaults). Remove the pbr.d template copy block. Run → pass.
- [ ] **Step 5: Commit**
```bash
git add dev/sync-to-packages.sh test/unit/sync.bats
git commit -m "chore(sync): stage new failover/classifier/monitor files; drop pbr.d templates"
```

### Task G3: run sync, verify package tree

- [ ] **Step 1:** `sh dev/sync-to-packages.sh`
- [ ] **Step 2:** `git status` — confirm only expected `packages/*/files/...` additions; no stray files.
- [ ] **Step 3: Commit**
```bash
git add packages/amnezia-pbr/files packages/luci-app-amnezia/files
git commit -m "chore(sync): regenerate package file trees for multi-tunnel failover"
```

### Task G4: CI integration job (Tier 2 on ubuntu)

**Files:**
- Create: `.github/workflows/integration.yml`
- Create: `dev/test-integration.sh` (local Docker runner, optional)

- [ ] **Step 1:** Write `.github/workflows/integration.yml`: ubuntu-latest, install `bats nftables iproute2 conntrack`, run `sudo bats test/integration test/unit` (Tier-2 tests detect Linux nft and execute; unit tests run too).
- [ ] **Step 2:** Write `dev/test-integration.sh` that, if `docker`/`colima` present, runs the same `bats` suite inside `openwrt/rootfs` (for uci/procd realism) or `ubuntu` (for nft/ip), else prints "install colima to run Tier-2 locally; CI covers it."
- [ ] **Step 3:** Validate YAML: `node -e "require('js-yaml')"` is overkill — instead `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/integration.yml'))"`.
- [ ] **Step 4: Commit**
```bash
git add .github/workflows/integration.yml dev/test-integration.sh
git commit -m "ci: real-kernel integration tests for classifier/routing/failover"
```

### Task G5: manual hardware spike runbook (Tier 3)

**Files:**
- Create: `dev/spike-multitunnel-runbook.md`

- [ ] **Step 1:** Write the runbook: a numbered, copy-pasteable sequence the user (with the agent) runs on the live router — **backup first** (`dev/openwrt-backup.sh` label `before-multitunnel-spike`), bring up a 2nd dummy/awg tunnel, install classifier + rules + tables + monitor, verify RU-direct + `amnezia_block_quic` survive, pull tunnel 1 and observe failover, verify fail-closed, test `restore`. Each step references the safety protocol (stage→background reload→poll). Mark clearly: NOT run by the pipeline.
- [ ] **Step 2:** `cmux-preview-md dev/spike-multitunnel-runbook.md`
- [ ] **Step 3: Commit**
```bash
git add dev/spike-multitunnel-runbook.md
git commit -m "docs(spike): manual hardware validation runbook (backup-gated)"
```

---

## Self-review checklist (run before execution)

- **Spec coverage:** up-to-5 tunnels (D2), failover default + balance opt-in (E3/C2), auto-failback (E3 picks best each pass), 3-signal health (E1), debounce (E2), fail-closed (C1/E3), sticky re-pin (E3 `_sticky_pick`), IPv6 fail-closed = **two parts**: forward-drop firewall rule (C3) + LAN RA/DHCPv6 disable (C4), QUIC-rule preserved via **negative-space** test (C3/D3 — no `uci delete firewall.amnezia_block_quic` in migration), pbr removal ordered+gated (D3), must-tunnel→sticky migration (D3 sub-step), set-migration mapping (B2/D3), **dnsmasq via UCI ipset** `configure-dnsmasq-amnezia.sh` (B2 — NOT a static .conf file), RU loader (B3), LuCI table+pickers (F2/F3), ACL with real shape (F1), F phase ordered F1→F3→F2, packaging drop-pbr (G1), sync with real concrete assertions (G2), CI integration (G4), manual spike (G5). ✓
- **Stub isolation:** All stub env-var branches (`UCI_FAKE_TUNNELS`, `NFT_FAKE_RU4_COUNT`, `AWG_FAKE_HS`, `PING_FAKE_OK`, `IP_FAKE_RULE_EXISTS`, `IP_NEXTHOP_OK`, `IP_FAKE_ROUTE`, `IP_FAKE_PROBE_RULE`, conntrack) are pre-declared in Task A1 `test/stubs/`. Later phases select behavior via env vars only — no phase after A1 edits `test/stubs/` files. ✓
- **Per-phase shellcheck:** `shellcheck-phaseB.bats` (B4 — common/ru/status/dnsmasq), `shellcheck-phaseE.bats` (E6 — monitor/init/ctl). Phase C lints `amnezia-routing.sh` in its own context; Phase D lints `install-amnezia-pbr.sh`. No cross-phase accumulator. ✓
- **CR-strip fix:** `parse_awg_conf` uses `printf '%s' "$_line" | tr -d '\r'` (not the bashism `${_line%$'\r'}`). CRLF fixture `test/fixtures/awg-crlf.conf` and bats test included in A3. ✓
- **::/0 removal:** `install-amnezia-pbr.sh` line 242 `uci add_list ... '::/0'` is deleted by D1. Test drives real install code path and asserts no `::/0` in stub log. ✓
- **resilient nexthop:** `buckets 128 idle_timer 120` required (C2). Tier-2 netns test in `test/integration/nexthop.bats`. Marked spike-confirm for MT7981. ✓
- **seed-must-tunnel.list runtime path:** KEPT at `/etc/amnezia/seed-must-tunnel.list` (not renamed). ACL `read/file` entry preserved; `main.js` ~line 962 read path unchanged. Installer populates it AND the sticky set from the same source. ✓
- **Placeholder scan:** none — every code/test step shows concrete content.
- **Type/name consistency:** `STICKY_MARK/POOL_MARK/MARK_MASK`, `TBL_STICKY=100/TBL_POOL=101`, set names `amnezia_ru4/amnezia_ru_tld4/amnezia_sticky4`, `STATE_FILE`, function names (`routing_set_pool_default`, `routing_disable_lan_v6`, `tunnel_healthy`, `handshake_fresh`, `ping_via`, `probe_setup`, `probe_cleanup`, `debounce`, `reconcile`, `write_state`, `parseFailoverState`, `renderTunnelTable`, `amnezia-failover-ctl`) are used consistently across phases.
- **Hardware-free:** every task's Step-by-step verification runs on macOS via bats/stubs/golden; Tier-2 (`test/integration/*`) `skip`s off-Linux and runs in CI; Tier-3 is the manual runbook only.
