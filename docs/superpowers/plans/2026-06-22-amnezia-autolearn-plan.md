# amnezia-autolearn Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A cron-driven, direct-default-only loop that harvests visited domains from the dnsmasq query log, classifies blocked ones with a pinned `zapret-probe`, and after confirmation auto-adds them to a separate `auto.list` feeding `amnezia_force4` — opt-in via a UI toggle, tunnel-health gated, never breaking client internet.

**Architecture:** Most testable logic lives in a new pure-shell library (`amnezia-autolearn-lib.sh`); a thin `amnezia-autolearn` pass orchestrates it; `amnezia-autolearn-ctl` backs the UI; an init script wires cron + reversible dnsmasq query logging. Two existing files gain minimal, backward-compatible changes (`zapret-probe.sh` pinned-IP arg; `amnezia-force-load.sh` guarded suffix-aware deny filter). POSIX sh / BusyBox ash only.

**Tech Stack:** OpenWrt 24.10.3, BusyBox ash, nftables/fw4, dnsmasq, UCI, bats + test stubs, LuCI (JS).

---

## Design refinements locked here (vs the committed spec)

- **Candidate store is TSV, not JSON.** `/etc/amnezia/autolearn/candidates.tsv`, tab-separated columns:
  `domain⇥last_verdict⇥block_count⇥clients_csv⇥first_seen⇥last_probe⇥reason`
  (`reason` ∈ `geoblock`|`dpi`|empty). Pure-shell JSON parsing is the project's documented footgun; TSV + awk is the shell-correct choice. The UI never reads this file — it reads `amnezia-autolearn-ctl list/status`, which hand-emit JSON (same pattern as `zapret-status.sh`).
- **The autolearn pass skips denied candidates** via `al_deny_match` (lib); `force-load` independently applies its own inline suffix-deny as the authoritative global filter (decoupled — `force-load` does not source the autolearn lib).

## Locked contracts (all tasks must match exactly)

**Library `/usr/lib/amnezia/amnezia-autolearn-lib.sh` (source path `openwrt/lib/amnezia-autolearn-lib.sh`):**

| Function | Behavior | Exit / output |
|---|---|---|
| `al_ip_is_public <ip>` | IPv4 dotted-quad; reject `0/8 10/8 127/8 169.254/16 172.16/12 192.168/16 100.64/10 224/4` and ≥240/4 | exit 0 public, 1 otherwise |
| `al_router_lan_cidrs` | echo router LAN `ip/prefix` lines from `uci network` (all bridge/static interfaces, not just `lan`) | stdout |
| `al_name_is_probeable <domain>` | must contain a dot, valid hostname charset (`zapret-probe` rules), not an IP-literal, not a reserved TLD (`lan local internal localdomain arpa`) | exit 0 probeable, 1 otherwise |
| `al_resolve_public <domain>` | resolve A records via `nslookup`; echo the FIRST address that passes `al_ip_is_public` and is not in `al_router_lan_cidrs`; empty if none | stdout (may be empty) |
| `al_querylog_pairs <file> <offset>` | for each line at/after byte `<offset>` matching `query[<type>] <domain> from <ip>`, echo `<domain> <ip>` | stdout |
| `al_deny_match <domain> <denyfile>` | exit 0 if `<domain>` equals a deny entry or is a subdomain of one | exit 0 match, 1 no-match |

**New runtime files:**
- `/usr/sbin/amnezia-autolearn` (source `openwrt/amnezia-autolearn.sh`)
- `/usr/bin/amnezia-autolearn-ctl` (source `openwrt/amnezia-autolearn-ctl.sh`)
- `/etc/init.d/amnezia-autolearn` (source `openwrt/amnezia-autolearn.init`)

**Data paths:** `/etc/amnezia/force.d/auto.list`, `/etc/amnezia/autolearn/candidates.tsv`, `/etc/amnezia/autolearn/deny.list`, `/etc/amnezia/autolearn/.dnsmasq-log.offset`, `/etc/amnezia/autolearn.json`, `/tmp/dnsmasq-queries.log`.

**UCI options under `amnezia.config`:** `autolearn_enabled`=0, `autolearn_interval_min`=30, `autolearn_max_probes`=20, `autolearn_max_per_client`=5, `autolearn_revalidate_days`=14, `autolearn_max_entries`=500, `autolearn_candidate_retention_days`=30.

**Pass constants:** `AUTOLEARN_STATE_MAX_AGE=120` (s), `AUTOLEARN_LOG_MAX_BYTES=2097152` (2 MiB).

**Confirm thresholds:** geoblock → add on `block_count>=2`; dpi → add on `block_count>=3`.

## Wave / phase map (a wave = phases sharing no unbuilt input)

- **Wave 1 (parallel):** P1 lib · P2 zapret-probe pinned arg · P3 force-load deny filter · P4 UCI config defaults
- **Wave 2 (parallel; need W1):** P5 autolearn pass (needs P1,P2) · P6 ctl (needs P1) · P7 init+cron+logging (needs P4)
- **Wave 3 (parallel; need W2):** P8 LuCI UI (needs P6 JSON contract) · P9 sync-to-packages + install wiring (needs P1–P7)
- **Wave 4:** P10 VM scenario (needs all)

Commit after every task. Run `bats test/unit/<file>.bats` for unit gates; the full suite is `bats test/unit/`.

> **Commit hygiene (MANDATORY):** the working tree may carry **unrelated uncommitted changes** belonging to the `feat/multi-tunnel-failover` branch (a parallel force-update fix touched `openwrt/amnezia-force-update.sh`, `openwrt/lib/amnezia-common.sh`, `test/stubs/*`, `test/unit/force-update.bats`, and their `packages/` copies). **Never `git add -A` / `git add .` / `git commit -am`** — always stage the explicit paths each task names, and run `git status` before every commit to confirm no foreign file is staged. Before starting execution, reconcile the tree (commit those changes to their own branch, or stash them) so they don't intermix — see the pre-execution note at the end of this plan.

---

## Phase 1 — Library `amnezia-autolearn-lib.sh`

**Files:**
- Create: `openwrt/lib/amnezia-autolearn-lib.sh`
- Test: `test/unit/autolearn-lib.bats`
- Stub (extend): `test/stubs/nslookup`, `test/stubs/uci`

### Task 1.0: extend the `uci` stub with `UCI_GET_*` resolution (PREREQUISITE)

The repo `uci` stub has only hardcoded `case` arms and **no** `UCI_GET_*` mechanism — every Phase-1/5/6 gate, cidr, and status test depends on one. Add it WITHOUT breaking existing tests (`state-write.bats` asserts `routing_mode` defaults to `tunnel-default`).

- [ ] **Step 1: Failing test** — `test/unit/autolearn-lib.bats` (created here; reused by later tasks):

```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
LIB="$HARNESS_DIR/../openwrt/lib/amnezia-autolearn-lib.sh"
setup() { . "$LIB"; }

@test "uci stub: UCI_GET_* override resolves, unset key exits non-zero" {
  export UCI_GET_amnezia_config_autolearn_enabled="1"
  run uci -q get amnezia.config.autolearn_enabled
  [ "$status" -eq 0 ]; [ "$output" = "1" ]
  run uci -q get amnezia.config.does_not_exist
  [ "$status" -ne 0 ]; [ -z "$output" ]
}
@test "uci stub: existing hardcoded routing_mode default preserved when unset" {
  run uci -q get amnezia.config.routing_mode
  [ "$output" = "tunnel-default" ]    # unchanged for state-write.bats
}
```

- [ ] **Step 2: Run → FAIL** (`UCI_GET_*` not honored).

- [ ] **Step 3: Implement** — in `test/stubs/uci`: the stub `shift`s past `-q`, so the verb is `$1` and the dotted key is `$2`. ONLY under the `get` verb, BEFORE the existing hardcoded `case`, add an env lookup mapping the key to `UCI_GET_<a>_<b>_<c>` (dots/hyphens → underscores); if that var is set, echo it and exit 0; otherwise fall through to the existing hardcoded arms (keeping `routing_mode=tunnel-default`), and a truly-unknown key still exits non-zero like real `uci -q get`:

```sh
# (inside the `get` verb branch, with the dotted key in $2)
if [ "$1" = get ]; then
  _envk="UCI_GET_$(printf '%s' "$2" | tr '.-' '__')"
  eval _envv="\${$_envk+set}"
  if [ "${_envv:-}" = set ]; then eval printf '%s\\n' "\"\$$_envk\""; exit 0; fi
fi
# ...existing hardcoded `get` case arms follow unchanged...
```

Also, in the `show` verb branch, add the `$UCI_SHOW_network` arm **BEFORE** the existing hardcoded `"show network")` arm (else the hardcoded `@interface[0]` line wins and `al_router_lan_cidrs` finds no static section):

```sh
# (inside the `show` verb branch, FIRST — short-circuits only when the var is set)
if [ "$1" = show ] && [ "$2" = network ] && [ -n "${UCI_SHOW_network:-}" ]; then
  printf '%s\n' "$UCI_SHOW_network"; exit 0
fi
# ...existing hardcoded `show network` arm follows unchanged...
```

- [ ] **Step 4: Run → PASS**; also `bats test/unit/state-write.bats` → still PASS (no regression).
- [ ] **Step 5: Commit** — `git add test/stubs/uci test/unit/autolearn-lib.bats && git commit -m "test(autolearn): uci stub honors UCI_GET_* with hardcoded fallback"`

### Task 1.1: `al_ip_is_public`

- [ ] **Step 1: Write the failing test** — append to `test/unit/autolearn-lib.bats` (created in Task 1.0):

```bash
@test "al_ip_is_public accepts a global address" {
  run al_ip_is_public 8.8.8.8
  [ "$status" -eq 0 ]
}
@test "al_ip_is_public rejects RFC1918 / loopback / CGNAT / link-local / multicast" {
  for ip in 10.0.0.1 192.168.1.1 172.16.5.5 127.0.0.1 169.254.1.1 100.64.0.1 224.0.0.1 0.0.0.0 240.0.0.1; do
    run al_ip_is_public "$ip"; [ "$status" -eq 1 ] || { echo "leaked $ip"; return 1; }
  done
}
@test "al_ip_is_public rejects non-dotted-quad garbage" {
  run al_ip_is_public "not.an.ip"; [ "$status" -eq 1 ]
  run al_ip_is_public "8.8.8";     [ "$status" -eq 1 ]
  run al_ip_is_public "8.8.8.999"; [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run to verify it fails** — `bats test/unit/autolearn-lib.bats` → FAIL (`al_ip_is_public: not found`).

- [ ] **Step 3: Implement** — create `openwrt/lib/amnezia-autolearn-lib.sh`:

```sh
#!/bin/sh
# amnezia-autolearn-lib: pure helpers for the auto-learning pass. POSIX sh.
# No side effects on source; every function is independently testable.

# al_ip_is_public <ipv4>: exit 0 iff a global-unicast routable IPv4.
al_ip_is_public() {
  _ip="$1"
  case "$_ip" in *.*.*.*) ;; *) return 1 ;; esac
  _o1="${_ip%%.*}"; _r="${_ip#*.}"; _o2="${_r%%.*}"; _r="${_r#*.}"
  _o3="${_r%%.*}"; _o4="${_r#*.}"
  for _o in "$_o1" "$_o2" "$_o3" "$_o4"; do
    case "$_o" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_o" -le 255 ] 2>/dev/null || return 1
  done
  # Reserved / non-routable ranges.
  case "$_o1" in 0|10|127) return 1 ;; esac
  [ "$_o1" -ge 224 ] && return 1                      # 224/4 multicast + 240/4 reserved
  [ "$_o1" = 169 ] && [ "$_o2" = 254 ] && return 1    # link-local
  [ "$_o1" = 192 ] && [ "$_o2" = 168 ] && return 1    # 192.168/16
  [ "$_o1" = 172 ] && [ "$_o2" -ge 16 ] && [ "$_o2" -le 31 ] && return 1   # 172.16/12
  [ "$_o1" = 100 ] && [ "$_o2" -ge 64 ] && [ "$_o2" -le 127 ] && return 1  # 100.64/10 CGNAT
  return 0
}
```

- [ ] **Step 4: Run to verify it passes** — `bats test/unit/autolearn-lib.bats` → the three `al_ip_is_public` tests PASS.

- [ ] **Step 5: Commit**

```bash
git add openwrt/lib/amnezia-autolearn-lib.sh test/unit/autolearn-lib.bats
git commit -m "feat(autolearn): al_ip_is_public IPv4 reserved-range guard"
```

### Task 1.2: `al_name_is_probeable`

- [ ] **Step 1: Add the failing tests** to `autolearn-lib.bats`:

```bash
@test "al_name_is_probeable accepts a public FQDN" {
  run al_name_is_probeable example.com; [ "$status" -eq 0 ]
}
@test "al_name_is_probeable rejects bare host, reserved TLDs, IP-literals, bad charset" {
  for n in localhost router box.lan x.local svc.internal a.localdomain h.home.arpa 8.8.8.8 "bad space" ".."; do
    run al_name_is_probeable "$n"; [ "$status" -eq 1 ] || { echo "accepted $n"; return 1; }
  done
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — append to the lib:

```sh
# al_name_is_probeable <domain>: exit 0 iff a public, probeable FQDN.
al_name_is_probeable() {
  _d="$1"
  [ ${#_d} -ge 2 ] && [ ${#_d} -le 253 ] || return 1
  case "$_d" in *[!A-Za-z0-9._-]*) return 1 ;; esac   # charset (mirror zapret-probe)
  case "$_d" in *.*) ;; *) return 1 ;; esac           # must have a dot (no bare host)
  case "$_d" in *[A-Za-z]*) ;; *) return 1 ;; esac     # an IP-literal has no letter -> reject
  case "$_d" in
    *.lan|*.local|*.internal|*.localdomain|*.home.arpa|*.arpa) return 1 ;;
  esac
  return 0
}
```

- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — `git add openwrt/lib/amnezia-autolearn-lib.sh test/unit/autolearn-lib.bats && git commit -m "feat(autolearn): al_name_is_probeable public-FQDN gate"` (explicit paths — never `-am`; the tree may carry unrelated `feat/multi-tunnel-failover` changes)

### Task 1.3: `al_router_lan_cidrs` + `al_resolve_public`

- [ ] **Step 1: Extend the `nslookup` stub** so it can return canned addresses. Replace `test/stubs/nslookup` with:

```sh
#!/bin/sh
echo "nslookup $*" >> "${STUB_LOG:-/dev/null}"
# Test-controlled answer: NSLOOKUP_ADDR="1.2.3.4 5.6.7.8" (space-separated),
# echoed in the real `Name:/Address:` block shape so the parser is exercised.
_dom="${*##* }"
echo "Server:    127.0.0.1"
echo "Address:   127.0.0.1#53"
echo ""
for _a in ${NSLOOKUP_ADDR:-}; do
  echo "Name:      $_dom"
  echo "Address: $_a"
done
exit 0
```

- [ ] **Step 2: Add failing tests** to `autolearn-lib.bats`:

```bash
@test "al_resolve_public returns the first public A and skips private ones" {
  export NSLOOKUP_ADDR="10.0.0.5 93.184.216.34"
  run al_resolve_public example.com
  [ "$status" -eq 0 ]; [ "$output" = "93.184.216.34" ]
}
@test "al_resolve_public is empty when all answers are private" {
  export NSLOOKUP_ADDR="10.0.0.5 192.168.1.9"
  run al_resolve_public example.com
  [ -z "$output" ]
}
@test "al_router_lan_cidrs reads configured LAN address" {
  export UCI_SHOW_network="network.lan=interface"   # stub: drives uci -q show network
  export UCI_GET_network_lan_ipaddr="192.168.1.1"
  export UCI_GET_network_lan_netmask="255.255.255.0"
  run al_router_lan_cidrs
  echo "$output" | grep -q "192.168.1."
}
@test "al_resolve_public rejects a PUBLIC address that is inside the router LAN" {
  export UCI_SHOW_network="network.lan=interface"
  export UCI_GET_network_lan_ipaddr="93.184.216.1"   # public-looking LAN (test)
  export NSLOOKUP_ADDR="93.184.216.34"               # same /24 as router LAN
  run al_resolve_public example.com
  [ -z "$output" ]                                    # rejected as same-LAN
}
```

> Test note: Task 1.0 extended the `uci` stub to resolve `uci -q get a.b.c` from `UCI_GET_a_b_c` (and to exit non-zero when unset). `al_router_lan_cidrs` also calls `uci -q show network`; extend the stub's `show` arm in Task 1.0 to emit `$UCI_SHOW_network` when set (one `network.<sec>=interface` line per section), else nothing. Add this to the Task 1.0 implement step and its commit.

- [ ] **Step 3: Implement** — append to the lib:

```sh
# al_router_lan_cidrs: echo each router LAN network as "ipaddr/prefixlen".
# Enumerates every network.<section> that has a static ipaddr (covers a
# non-"lan"-named bridge), not just network.lan.
al_router_lan_cidrs() {
  for _sec in $(uci -q show network 2>/dev/null \
                  | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p'); do
    _ip=$(uci -q get "network.${_sec}.ipaddr" 2>/dev/null) || continue
    [ -n "$_ip" ] || continue
    _nm=$(uci -q get "network.${_sec}.netmask" 2>/dev/null)
    # Emit the address; prefix derivation is best-effort (membership test in
    # al_resolve_public uses octet compare, not exact CIDR math).
    printf '%s/%s\n' "$_ip" "${_nm:-255.255.255.0}"
  done
}

# _al_same_lan <ip>: return 0 iff <ip> shares the /24 of any router LAN address.
# No pipeline-subshell (avoids any ambiguity about exit propagation): capture
# the CIDR list into a var, iterate with a plain for-loop.
_al_same_lan() {
  _q="$1"; _q3="${_q%.*}"
  _cidrs=$(al_router_lan_cidrs)
  for _line in $_cidrs; do
    _la="${_line%%/*}"
    [ "${_la%.*}" = "$_q3" ] && return 0
  done
  return 1
}

# al_resolve_public <domain>: echo first public, non-LAN A record (or empty).
# Anchor to the ANSWER section: skip the leading Server:/Address: block (the
# resolver's own address) so an upstream like 8.8.8.8#53 is not mistaken for an
# A record of the domain.
al_resolve_public() {
  _d="$1"
  _addrs=$(nslookup "$_d" 2>/dev/null | awk '
    /^Name:/ {ans=1; next}                 # answer section starts at first Name:
    ans && /^Address: ?[0-9]/ {sub(/#.*/,"",$2); print $2}')
  for _a in $_addrs; do
    al_ip_is_public "$_a" || continue
    _al_same_lan "$_a" && continue
    printf '%s\n' "$_a"; break
  done
}
```

- [ ] **Step 4: Run → PASS** (`bats test/unit/autolearn-lib.bats`).
- [ ] **Step 5: Commit** — `git add -u openwrt/lib/amnezia-autolearn-lib.sh test/stubs/nslookup test/unit/autolearn-lib.bats && git commit -m "feat(autolearn): al_router_lan_cidrs + al_resolve_public (SSRF-safe pinning source)"`

### Task 1.4: `al_querylog_pairs`

- [ ] **Step 1: Add failing test:**

```bash
@test "al_querylog_pairs extracts domain+client only from query[ lines past offset" {
  log="$BATS_TEST_TMPDIR/q.log"
  printf 'Jun 22 query[A] skip.example from 192.168.1.9\n' > "$log"   # pre-offset
  off=$(wc -c < "$log")
  {
    printf 'Jun 22 query[A] foo.com from 192.168.1.10\n'
    printf 'Jun 22 reply foo.com is 1.2.3.4\n'
    printf 'Jun 22 cached bar.com is 5.6.7.8\n'
    printf 'Jun 22 query[AAAA] baz.com from 192.168.1.11\n'
  } >> "$log"
  run al_querylog_pairs "$log" "$off"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^foo.com 192.168.1.10$'
  echo "$output" | grep -q '^baz.com 192.168.1.11$'
  ! echo "$output" | grep -q 'skip.example'   # before offset
  ! echo "$output" | grep -q 'bar.com'         # not a query[ line
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — append:

```sh
# al_querylog_pairs <file> <offset>: emit "<domain> <client-ip>" for each
# dnsmasq `query[<type>] <domain> from <ip>` line at/after byte <offset>.
al_querylog_pairs() {
  _f="$1"; _off="${2:-0}"
  [ -f "$_f" ] || return 0
  case "$_off" in *[!0-9]*|'') _off=0 ;; esac
  _size=$(wc -c < "$_f" 2>/dev/null || echo 0)
  [ "$_off" -gt "$_size" ] 2>/dev/null && _off=0   # shrink/rotation guard
  # tail -c +N is 1-based; read bytes after the offset. Far cheaper than
  # `dd bs=1` (one syscall per byte) on a near-2MiB tmpfs log. The awk scans
  # fields for one starting `query[` so it is robust to a `dnsmasq[pid]:`
  # daemon-tag prefix; the client IP is the last field (`... from <ip>`).
  tail -c "+$((_off + 1))" "$_f" 2>/dev/null \
    | awk '
        /query\[[A-Za-z]+\] [^ ]+ from [0-9]/ {
          for (i=1;i<=NF;i++) if ($i ~ /^query\[/) { print $(i+1), $NF }
        }'
}
```

- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — `git add openwrt/lib/amnezia-autolearn-lib.sh test/unit/autolearn-lib.bats && git commit -m "feat(autolearn): al_querylog_pairs query-log harvester"`

### Task 1.5: `al_deny_match`

- [ ] **Step 1: Add failing test:**

```bash
@test "al_deny_match matches domain and subdomains, not look-alikes" {
  deny="$BATS_TEST_TMPDIR/deny.list"; printf 'example.com\nfoo.org\n' > "$deny"
  run al_deny_match example.com "$deny";      [ "$status" -eq 0 ]
  run al_deny_match www.example.com "$deny";  [ "$status" -eq 0 ]
  run al_deny_match a.b.foo.org "$deny";       [ "$status" -eq 0 ]
  run al_deny_match notexample.com "$deny";    [ "$status" -eq 1 ]
  run al_deny_match example.com.evil.net "$deny"; [ "$status" -eq 1 ]
  run al_deny_match other.net "$deny";          [ "$status" -eq 1 ]
}
@test "al_deny_match returns no-match on missing/empty denyfile" {
  run al_deny_match x.com /nonexistent;        [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — append:

```sh
# al_deny_match <domain> <denyfile>: exit 0 iff <domain> == an entry or a
# subdomain of one. Suffix-aware to mirror dnsmasq nftset matching.
al_deny_match() {
  _d="$1"; _df="$2"
  [ -s "$_df" ] || return 1
  awk -v dom="$_d" '
    { gsub(/[ \t\r]/,""); if($0!="") deny[$0]=1 }
    END {
      if (dom in deny) exit 0
      s=dom
      while ((i=index(s,"."))>0) { s=substr(s,i+1); if (s in deny) exit 0 }
      exit 1
    }' "$_df"
}
```

- [ ] **Step 4: Run → PASS** (whole file: `bats test/unit/autolearn-lib.bats`).
- [ ] **Step 5: Commit** — `git add openwrt/lib/amnezia-autolearn-lib.sh test/unit/autolearn-lib.bats && git commit -m "feat(autolearn): al_deny_match suffix-aware deny test"`

---

## Phase 2 — `zapret-probe.sh` pinned-IP extension

**Files:** Modify `openwrt/zapret-probe.sh`; Test: `test/unit/zapret-probe-pin.bats`; extend `test/stubs/curl` if needed.

### Task 2.1: optional pinned-IP arg → `--resolve` + `--max-redirs 0`

- [ ] **Step 1: Failing test** — `test/unit/zapret-probe-pin.bats`:

```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/zapret-probe.sh"

@test "pinned-IP invocation passes --resolve and --max-redirs 0 to curl" {
  run sh "$SCRIPT" example.com 93.184.216.34
  grep -q -- '--resolve example.com:443:93.184.216.34' "$STUB_LOG"
  grep -q -- '--resolve example.com:80:93.184.216.34' "$STUB_LOG"
  grep -q -- '--max-redirs 0' "$STUB_LOG"
}
@test "unpinned invocation is byte-equivalent: -sL preserved, no --resolve/--max-redirs" {
  run sh "$SCRIPT" example.com
  ! grep -q -- '--resolve' "$STUB_LOG"
  ! grep -q -- '--max-redirs' "$STUB_LOG"
  grep -q -- '-sL' "$STUB_LOG"        # silent + follow-redirects retained
  grep -q -- '-D ' "$STUB_LOG"        # header dump still requested
  grep -q -- "%{http_code}" "$STUB_LOG"
}
@test "pinned-IP arg is validated (rejects non-IP)" {
  run sh "$SCRIPT" example.com not-an-ip
  echo "$output" | grep -q '"verdict": *"error"'
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run → FAIL** (current script ignores `$2`; no `--resolve`).

- [ ] **Step 3: Implement** — in `openwrt/zapret-probe.sh`, after the domain-validation block (after line 42) insert:

```sh
# Optional 2nd arg: a pinned IPv4 to fix resolution (autolearn SSRF guard).
# When present, curl resolves <domain> to exactly this IP and follows NO
# redirects (a block manifests at the handshake / first response).
pinned_ip=${2:-}
RESOLVE_OPTS=""
# REDIR_OPTS carries the redirect policy. The unpinned (existing UI) path MUST
# stay byte-equivalent to the original `-sL` — keep BOTH -s and -L. The pinned
# path keeps -s but forbids redirects.
REDIR_OPTS="-sL"
if [ -n "$pinned_ip" ]; then
  case "$pinned_ip" in
    *.*.*.*) : ;;
    *) echo '{"verdict":"error","reason":"invalid pinned ip"}'; exit 2 ;;
  esac
  case "$pinned_ip" in *[!0-9.]*) echo '{"verdict":"error","reason":"invalid pinned ip"}'; exit 2 ;; esac
  RESOLVE_OPTS="--resolve $domain:443:$pinned_ip --resolve $domain:80:$pinned_ip"
  REDIR_OPTS="-s --max-redirs 0"
fi
```

Then change the two `curl` invocations. Replace lines 56–60 (note `-sL` becomes `$REDIR_OPTS`, which is `-sL` when unpinned → byte-equivalent):

```sh
out=$(curl --interface wan $RESOLVE_OPTS \
	--connect-timeout "$CT" --max-time "$MAX" \
	$REDIR_OPTS -D "$HDR_FILE" -o /dev/null \
	-w '%{http_code}\t%{time_total}\t%{num_redirects}\n' \
	"$URL" 2>&1)
```

and the body-peek `curl` (lines 104–106):

```sh
		body=$(curl --interface wan $RESOLVE_OPTS \
			--connect-timeout "$CT" --max-time "$MAX" \
			$REDIR_OPTS "$URL" 2>/dev/null | head -c 16384 | tr '[:upper:]' '[:lower:]')
```

(Note: `$RESOLVE_OPTS`/`$REDIR_OPTS` are intentionally unquoted for word-splitting; they hold only validated tokens.)

- [ ] **Step 4: Run → PASS.** Confirm the unpinned path is byte-equivalent and the full suite is green: `bats test/unit/` (no regressions).
- [ ] **Step 5: Commit** — `git add openwrt/zapret-probe.sh test/unit/zapret-probe-pin.bats && git commit -m "feat(zapret-probe): optional pinned-IP arg (--resolve + no-redirect) for SSRF-safe probing"`

---

## Phase 3 — `amnezia-force-load.sh` guarded suffix-aware deny filter

**Files:** Modify `openwrt/amnezia-force-load.sh`; Test: extend `test/unit/force-load.bats`.

### Task 3.1: apply `deny.list` after domain dedup, before the hash

- [ ] **Step 1: Failing test** — append to `test/unit/force-load.bats`:

```bash
@test "force-load deny.list suppresses a domain (and subdomains) from any source" {
  printf 'example.com\nkeep.com\n' > "$FORCE_DIR/force.d/itdoginfo_inside.list"
  printf 'www.example.com\n' >> "$FORCE_DIR/force.d/itdoginfo_inside.list"
  mkdir -p "$FORCE_DIR/autolearn"; printf 'example.com\n' > "$FORCE_DIR/autolearn/deny.list"
  export AMZ_DENY_LIST="$FORCE_DIR/autolearn/deny.list"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'example\.com' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"
  ! grep -q 'www\.example\.com' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"
  grep -q 'keep\.com' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"
}
@test "force-load never blanks the set when deny.list is missing/empty" {
  printf 'a.com\nb.com\n' > "$FORCE_DIR/force.d/itdoginfo_inside.list"
  export AMZ_DENY_LIST="$FORCE_DIR/autolearn/deny.list"   # file absent
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'a\.com' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"
  grep -q 'b\.com' "$AMZ_DNSMASQ_CONFDIR/amnezia-force.conf"
}
```

- [ ] **Step 2: Run → FAIL** (deny not applied yet).

- [ ] **Step 3: Implement** — in `openwrt/amnezia-force-load.sh`, add near the top config block (after `SET_FORCE4=amnezia_force4`, line 27):

```sh
# Vetoed domains (autolearn). Applied as a guarded, suffix-aware GLOBAL
# exclusion over the merged domain set so a veto is authoritative across all
# sources. Overridable for tests.
AMZ_DENY_LIST="${AMZ_DENY_LIST:-/etc/amnezia/autolearn/deny.list}"
```

Then, immediately after the domain dedup (after line 134, where `_tmp_domains` is sorted/deduped) and **before** `_new_hash` is computed (line 141), insert:

```sh
  # Guarded suffix-aware deny filter. Only runs when the file is non-empty and
  # readable, so a missing/empty/unreadable deny.list can NEVER blank force4.
  if [ -s "$AMZ_DENY_LIST" ]; then
    _tmp_dom_kept=$(mktemp "$FORCE_DIR/force.d/.amz-dom-kept.XXXXXX" 2>/dev/null \
      || echo "$FORCE_DIR/force.d/amz-dom-kept.$$")
    awk -v denyfile="$AMZ_DENY_LIST" '
      BEGIN { while ((getline d < denyfile) > 0) { gsub(/[ \t\r]/,"",d); if (d!="") deny[d]=1 } }
      { dom=$0; gsub(/[ \t\r]/,"",dom); if (dom=="") next
        if (dom in deny) next
        drop=0; s=dom
        while ((i=index(s,"."))>0) { s=substr(s,i+1); if (s in deny) { drop=1; break } }
        if (!drop) print $0 }
    ' "$_tmp_domains" > "$_tmp_dom_kept" && mv "$_tmp_dom_kept" "$_tmp_domains"
  fi
```

- [ ] **Step 4: Run → PASS** — `bats test/unit/force-load.bats` AND the full suite `bats test/unit/` (force-load runs on the existing force-update cron path — assert zero regressions, esp. `force-update.bats`).
- [ ] **Step 5: Commit** — `git add openwrt/amnezia-force-load.sh test/unit/force-load.bats && git commit -m "feat(force-load): guarded suffix-aware deny.list global exclusion"`

---

## Phase 4 — UCI config defaults

**Files:** Modify `openwrt/config/amnezia`; Test: extend `test/unit/uci-schema.bats`.

### Task 4.1: add the seven `autolearn_*` options (default OFF)

- [ ] **Step 1: Failing test** — append to `test/unit/uci-schema.bats` (follow that file's existing assertion style; if it greps the config file directly, mirror it):

```bash
@test "config ships autolearn_* defaults with learning OFF" {
  CFG="$HARNESS_DIR/../openwrt/config/amnezia"
  grep -q "option autolearn_enabled '0'" "$CFG"
  grep -q "option autolearn_interval_min '30'" "$CFG"
  grep -q "option autolearn_max_probes '20'" "$CFG"
  grep -q "option autolearn_max_per_client '5'" "$CFG"
  grep -q "option autolearn_revalidate_days '14'" "$CFG"
  grep -q "option autolearn_max_entries '500'" "$CFG"
  grep -q "option autolearn_candidate_retention_days '30'" "$CFG"
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — in `openwrt/config/amnezia`, inside `config amnezia 'config'` (after line 26, the `installed_ts` option), add:

```
	# --- Auto-learning (amnezia-autolearn) ---------------------------------
	# Opt-in self-learning of blocked domains in direct-default mode. OFF by
	# default; enabling also turns on reversible dnsmasq query logging to tmpfs.
	option autolearn_enabled '0'
	option autolearn_interval_min '30'
	option autolearn_max_probes '20'
	option autolearn_max_per_client '5'
	option autolearn_revalidate_days '14'
	option autolearn_max_entries '500'
	option autolearn_candidate_retention_days '30'
```

- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — `git add openwrt/config/amnezia test/unit/uci-schema.bats && git commit -m "feat(autolearn): UCI defaults under amnezia.config (learning OFF)"`

---

## Phase 5 — `amnezia-autolearn` pass

**Files:** Create `openwrt/amnezia-autolearn.sh`; Test: `test/unit/autolearn-pass.bats`; add `test/stubs/zapret-probe`, `test/stubs/kill`.

The pass composes Phase-1 lib functions. It is the orchestrator; each behavior below gets a test.

### Task 5.1: stubs for the pass

- [ ] **Step 1:** create `test/stubs/zapret-probe`:

```sh
#!/bin/sh
echo "zapret-probe $*" >> "${STUB_LOG:-/dev/null}"
# Canned verdict per-domain via ZP_VERDICT_<domain-with-dots-as-underscores>,
# default ZP_VERDICT_DEFAULT, fallback direct_ok.
_dom="$1"; _key="ZP_VERDICT_$(printf '%s' "$_dom" | tr '.-' '__')"
eval _v="\${$_key:-\${ZP_VERDICT_DEFAULT:-direct_ok}}"
printf '{"domain":"%s","verdict":"%s","reason":"stub"}\n' "$_dom" "$_v"
```

- [ ] **Step 2:** create `test/stubs/al-kill` — a logging shim the pass calls via the `AL_KILL` indirection (a PATH stub named `kill` would be shadowed by the shell builtin, so the pass uses `"$AL_KILL"` and the test sets `AL_KILL=al-kill`):

```sh
#!/bin/sh
echo "kill $*" >> "${STUB_LOG:-/dev/null}"   # observable; never signals a real pid
exit 0
```

- [ ] **Step 3: Commit** — `git add test/stubs/zapret-probe test/stubs/al-kill && git commit -m "test(autolearn): stubs for zapret-probe + al-kill signal shim"`

### Task 5.2: gate — exit unless direct-default + enabled + fresh-healthy

- [ ] **Step 1: Failing test** — `test/unit/autolearn-pass.bats`:

```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-autolearn.sh"
setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export AL_DIR="$BATS_TEST_TMPDIR/amnezia"; mkdir -p "$AL_DIR/force.d" "$AL_DIR/autolearn"
  export AL_STATE="$BATS_TEST_TMPDIR/failover.json"
  export AL_QUERYLOG="$BATS_TEST_TMPDIR/q.log"; : > "$AL_QUERYLOG"
  export AMNEZIA_FORCE_LOAD="amnezia-force-load"   # stub on PATH
  # Healthy, fresh state by default.
  printf '{"all_down":false}\n' > "$AL_STATE"
  export UCI_GET_amnezia_config_routing_mode="direct-default"
  export UCI_GET_amnezia_config_autolearn_enabled="1"
}

@test "gate: tunnel-default mode -> no-op (no probe, no force-load)" {
  export UCI_GET_amnezia_config_routing_mode="tunnel-default"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  ! grep -q 'zapret-probe' "$STUB_LOG"
}
@test "gate: disabled -> no-op" {
  export UCI_GET_amnezia_config_autolearn_enabled="0"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  ! grep -q 'zapret-probe' "$STUB_LOG"
}
@test "gate: all_down true -> no add" {
  printf '{"all_down":true}\n' > "$AL_STATE"
  printf 'q.com 192.168.1.2\nq.com 192.168.1.3\n' >/dev/null
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  ! grep -q 'zapret-probe' "$STUB_LOG"
}
@test "gate: stale state file (old mtime) -> no add" {
  touch -t 197001010000 "$AL_STATE"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  ! grep -q 'zapret-probe' "$STUB_LOG"
}
```

- [ ] **Step 2: Run → FAIL** (script absent).
- [ ] **Step 3: Implement** — create `openwrt/amnezia-autolearn.sh` (gate section first; later tasks append the body). Begin the file:

```sh
#!/bin/sh
# amnezia-autolearn: one cron pass. Harvest visited domains, probe blocked
# ones (pinned), confirm/age, write auto.list, force-load on net change.
# Direct-default-only, opt-in, tunnel-health gated. POSIX sh.
set -u
AMNEZIA_LIB="${AMNEZIA_LIB:-/usr/lib/amnezia}"
# shellcheck disable=SC1091
. "$AMNEZIA_LIB/amnezia-autolearn-lib.sh"

AL_DIR="${AL_DIR:-/etc/amnezia}"
AL_STATE="${AL_STATE:-/var/run/amnezia-failover.json}"
AL_QUERYLOG="${AL_QUERYLOG:-/tmp/dnsmasq-queries.log}"
AL_LOCK="${AL_LOCK:-/var/lock/amnezia-autolearn.lock}"
AUTO_LIST="$AL_DIR/force.d/auto.list"
CAND="$AL_DIR/autolearn/candidates.tsv"
DENY="$AL_DIR/autolearn/deny.list"
OFFSET_F="$AL_DIR/autolearn/.dnsmasq-log.offset"
AUTOLEARN_STATE_MAX_AGE=120
AUTOLEARN_LOG_MAX_BYTES=2097152
AMNEZIA_FORCE_LOAD="${AMNEZIA_FORCE_LOAD:-amnezia-force-load}"
# `kill` is a shell builtin — a PATH stub is never reached. Route the signal
# through this indirection so tests can inject a logging shim via AL_KILL.
AL_KILL="${AL_KILL:-kill}"

_uci() { uci -q get "$1" 2>/dev/null; }
_now() { date +%s 2>/dev/null || echo 0; }

# --- Gate -------------------------------------------------------------------
[ "$(_uci amnezia.config.routing_mode)" = "direct-default" ] || exit 0
[ "$(_uci amnezia.config.autolearn_enabled)" = "1" ] || exit 0
# Tunnel health: state file must exist, be fresh, and report all_down:false.
[ -f "$AL_STATE" ] || exit 0
_mtime=$(date -r "$AL_STATE" +%s 2>/dev/null || stat -c %Y "$AL_STATE" 2>/dev/null || echo 0)
_age=$(( $(_now) - _mtime ))
[ "$_age" -le "$AUTOLEARN_STATE_MAX_AGE" ] 2>/dev/null || exit 0
_alldown=$(grep -o '"all_down":[a-z]*' "$AL_STATE" 2>/dev/null | head -n1 | sed 's/.*://')
[ "$_alldown" = "false" ] || exit 0

mkdir -p "$AL_DIR/force.d" "$AL_DIR/autolearn"
```

> Note: the bats `uci` stub must resolve `uci -q get amnezia.config.routing_mode` from `UCI_GET_amnezia_config_routing_mode`. Confirm the stub maps dots→underscores; if not, extend it (mirroring real `uci -q get`) as a 1-line stub change and note it in the commit.

- [ ] **Step 4: Run → the four gate tests PASS.**
- [ ] **Step 5: Commit** — `git add openwrt/amnezia-autolearn.sh test/unit/autolearn-pass.bats && git commit -m "feat(autolearn): pass gate (mode+enabled+fresh-healthy)"`

### Task 5.3: harvest → eligibility → pinned probe → confirm

- [ ] **Step 1: Failing tests** — append to `autolearn-pass.bats`:

```bash
@test "confirm: geoblocked added after 2 distinct-client probes; force-load called" {
  export ZP_VERDICT_block_com="direct_geoblocked"
  export NSLOOKUP_ADDR="93.184.216.34"
  # two distinct clients resolve block.com twice
  printf 'query[A] block.com from 192.168.1.2\nquery[A] block.com from 192.168.1.3\n' > "$AL_QUERYLOG"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]        # 1st probe -> count 1, not added
  ! grep -q '^block.com$' "$AL_DIR/force.d/auto.list" 2>/dev/null
  printf 'query[A] block.com from 192.168.1.2\nquery[A] block.com from 192.168.1.3\n' >> "$AL_QUERYLOG"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]        # 2nd probe -> count 2 -> added
  grep -q '^block.com$' "$AL_DIR/force.d/auto.list"
  grep -q 'amnezia-force-load' "$STUB_LOG"
}
@test "eligibility: single client -> never probed" {
  export ZP_VERDICT_DEFAULT="direct_geoblocked"
  printf 'query[A] solo.com from 192.168.1.2\n' > "$AL_QUERYLOG"
  run sh "$SCRIPT"
  ! grep -q 'zapret-probe solo.com' "$STUB_LOG"
}
@test "safety filter: RFC1918-resolving domain is never probed" {
  export NSLOOKUP_ADDR="10.0.0.9"
  printf 'query[A] internal.example from 192.168.1.2\nquery[A] internal.example from 192.168.1.3\n' > "$AL_QUERYLOG"
  run sh "$SCRIPT"
  ! grep -q 'zapret-probe internal.example' "$STUB_LOG"
}
@test "dpi needs 3 confirmations" {
  export ZP_VERDICT_dpi_com="direct_dpi_blocked"; export NSLOOKUP_ADDR="93.184.216.34"
  # APPEND fresh bytes each pass so the offset advances and dpi.com is
  # re-harvested (a same-size rewrite would leave offset==size -> no harvest).
  for i in 1 2; do
    printf 'query[A] dpi.com from 192.168.1.2\nquery[A] dpi.com from 192.168.1.3\n' >> "$AL_QUERYLOG"
    run sh "$SCRIPT"
  done
  ! grep -qx 'dpi.com' "$AL_DIR/force.d/auto.list" 2>/dev/null    # only 2 -> not yet
  printf 'query[A] dpi.com from 192.168.1.2\nquery[A] dpi.com from 192.168.1.3\n' >> "$AL_QUERYLOG"
  run sh "$SCRIPT"
  grep -qx 'dpi.com' "$AL_DIR/force.d/auto.list"                  # 3rd -> added
}
@test "RU domains and denied domains are skipped" {
  export ZP_VERDICT_DEFAULT="direct_geoblocked"; export NSLOOKUP_ADDR="93.184.216.34"
  printf 'denied.com\n' > "$DENY"
  printf 'query[A] site.ru from 192.168.1.2\nquery[A] site.ru from 192.168.1.3\n' > "$AL_QUERYLOG"
  printf 'query[A] denied.com from 192.168.1.2\nquery[A] denied.com from 192.168.1.3\n' >> "$AL_QUERYLOG"
  run sh "$SCRIPT"
  ! grep -q 'zapret-probe site.ru' "$STUB_LOG"
  ! grep -q 'zapret-probe denied.com' "$STUB_LOG"
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — append the harvest/probe/confirm body to `openwrt/amnezia-autolearn.sh`:

```sh
# Placeholders implemented in Tasks 5.4/5.5 — defined here as no-ops so this
# task's script runs standalone; later tasks REPLACE these definitions.
_al_revalidate() { return 1; }
_al_rotate_log() { return 0; }
_al_prune_candidates() { return 0; }

# --- Lock (advisory; flock may be absent in dev/test) -----------------------
exec 9>"$AL_LOCK" 2>/dev/null || true
flock -n 9 2>/dev/null || true     # NEVER `|| exit` — matches force-load idiom

_changed=0                          # declared BEFORE revalidation so a drop counts
_al_revalidate && _changed=1        # (defined in Task 5.4) drop stale recovered entries

# --- Harvest pairs since offset --------------------------------------------
_off=0; [ -f "$OFFSET_F" ] && _off=$(cat "$OFFSET_F" 2>/dev/null || echo 0)
case "$_off" in *[!0-9]*) _off=0 ;; esac
_size=$(wc -c < "$AL_QUERYLOG" 2>/dev/null || echo 0)
_pairs=$(al_querylog_pairs "$AL_QUERYLOG" "$_off")
printf '%s\n' "$_size" > "$OFFSET_F"

# Tally (domain, client) pairs this pass. Skip RU/.ru and denied up front.
# NOTE: write to the tmp file inside the loop's OWN process (here-string, not a
# pipe) so it is not lost to a pipeline subshell.
_cand_tmp=$(mktemp 2>/dev/null || echo "/tmp/al-cand.$$"); : > "$_cand_tmp"
printf '%s\n' "$_pairs" > "${_cand_tmp}.raw"
while read -r _dom _ip; do
  [ -n "$_dom" ] || continue
  case "$_dom" in *.ru) continue ;; esac
  al_name_is_probeable "$_dom" || continue
  al_deny_match "$_dom" "$DENY" && continue
  grep -qx "$_dom" "$AUTO_LIST" 2>/dev/null && continue
  printf '%s\t%s\n' "$_dom" "$_ip" >> "$_cand_tmp"
done < "${_cand_tmp}.raw"
rm -f "${_cand_tmp}.raw"

# Per-client fairness cap + distinct-client (>=2) eligibility, in one awk.
# - drop pairs beyond autolearn_max_per_client for any single client IP
# - a domain is eligible iff >=2 DISTINCT client IPs resolved it
# Also emit, for each eligible domain, its distinct-client CSV for candidates.tsv.
_maxpc=$(_uci amnezia.config.autolearn_max_per_client); _maxpc=${_maxpc:-5}
_eligible=$(awk -F'\t' -v maxpc="$_maxpc" '
  { dom=$1; ip=$2
    if (++perclient[ip] > maxpc) next            # fairness cap per client IP
    if (!(dom SUBSEP ip in seenpair)) { seenpair[dom SUBSEP ip]=1; dcnt[dom]++ } }
  END { for (d in dcnt) if (dcnt[d] >= 2) print d }' "$_cand_tmp")
# clients CSV per domain (for the TSV record).
_clients_for() {
  awk -F'\t' -v d="$1" '$1==d{ if(!(d $2 in s)){s[d $2]=1; c=c (c?",":"") $2} } END{print c}' "$_cand_tmp"
}

_max_probes=$(_uci amnezia.config.autolearn_max_probes); _max_probes=${_max_probes:-20}
_n=0
for _dom in $_eligible; do
  [ "$_n" -lt "$_max_probes" ] || break
  _n=$((_n+1))
  _pin=$(al_resolve_public "$_dom"); [ -n "$_pin" ] || continue   # SSRF gate
  _verdict=$(zapret-probe "$_dom" "$_pin" | grep -o '"verdict":"[^"]*"' | sed 's/.*:"//;s/"//')
  if _al_record "$_dom" "$_verdict" "$(_clients_for "$_dom")"; then _changed=1; fi
done
rm -f "$_cand_tmp"

_al_rotate_log                                   # (Task 5.5) bound the tmpfs log
_al_prune_candidates                             # (Task 5.4) retention
[ "$_changed" = 1 ] && "$AMNEZIA_FORCE_LOAD" >/dev/null 2>&1
exit 0
```

And insert the `_al_record` helper **above** the harvest block (after the gate/mkdir). It returns **0 ONLY when it appends to auto.list**, 1 otherwise (so a `direct_ok`/non-trigger verdict never triggers `force-load`):

```sh
# _al_record <domain> <verdict> <clients_csv>: update candidates.tsv; on
# threshold, append to auto.list (with LRU eviction at the cap). Returns 0 iff
# a domain was newly appended to auto.list; 1 otherwise.
_al_record() {
  _d="$1"; _v="$2"; _clients="$3"; _ts=$(_now)
  case "$_v" in
    direct_geoblocked) _reason=geoblock; _thresh=2 ;;
    direct_dpi_blocked) _reason=dpi; _thresh=3 ;;
    *) return 1 ;;                      # ok/blocked/unreachable/error -> no add
  esac
  _prev=$(awk -F'\t' -v d="$_d" '$1==d{print; exit}' "$CAND" 2>/dev/null)
  if [ -n "$_prev" ]; then
    _cnt=$(printf '%s' "$_prev" | cut -f3); _first=$(printf '%s' "$_prev" | cut -f5)
  else
    _cnt=0; _first=$_ts
  fi
  case "$_cnt" in *[!0-9]*|'') _cnt=0 ;; esac
  _cnt=$((_cnt+1))
  _tmp=$(mktemp 2>/dev/null || echo "$CAND.$$")
  awk -F'\t' -v d="$_d" '$1!=d' "$CAND" 2>/dev/null > "$_tmp"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_d" "$_v" "$_cnt" "$_clients" "$_first" "$_ts" "$_reason" >> "$_tmp"
  mv "$_tmp" "$CAND"
  [ "$_cnt" -ge "$_thresh" ] || return 1
  grep -qx "$_d" "$AUTO_LIST" 2>/dev/null && return 1   # already present
  # Size cap with LRU eviction (never evicts force-tunnel.list/manual entries).
  _cap=$(_uci amnezia.config.autolearn_max_entries); _cap=${_cap:-500}
  _count=$(awk 'END{print NR}' "$AUTO_LIST" 2>/dev/null); _count=${_count:-0}
  if [ "$_count" -ge "$_cap" ] 2>/dev/null; then
    _victim=$(awk -F'\t' 'NR==FNR{auto[$0]=1; next} ($1 in auto){print $6"\t"$1}' \
                "$AUTO_LIST" "$CAND" 2>/dev/null | sort -n | head -n1 | cut -f2)
    [ -n "$_victim" ] && { _t=$(mktemp 2>/dev/null || echo "$AUTO_LIST.$$"); grep -vx "$_victim" "$AUTO_LIST" > "$_t"; mv "$_t" "$AUTO_LIST"; }
  fi
  printf '%s\n' "$_d" >> "$AUTO_LIST"
  return 0
}
```

- [ ] **Step 4: Run → PASS** (`bats test/unit/autolearn-pass.bats`). Fix any `uci` stub dot-mapping gap surfaced here.
- [ ] **Step 5: Commit** — `git add openwrt/amnezia-autolearn.sh test/unit/autolearn-pass.bats && git commit -m "feat(autolearn): harvest+eligibility+pinned-probe+confirm core"`

### Task 5.4: revalidation-drop, LRU size cap, candidate retention

- [ ] **Step 1: Failing tests** — append:

```bash
@test "revalidate: entry now direct_ok is dropped" {
  export NSLOOKUP_ADDR="93.184.216.34"; export ZP_VERDICT_old_com="direct_ok"
  printf 'old.com\n' > "$AUTO_LIST"
  # candidate row with last_probe 15 days ago (older than revalidate_days=14)
  old=$(( $(date +%s) - 15*86400 ))
  printf 'old.com\tdirect_geoblocked\t2\t\t%s\t%s\tgeoblock\n' "$old" "$old" > "$CAND"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  ! grep -qx 'old.com' "$AUTO_LIST"
}
@test "size cap: at cap, a new confirmed entry evicts the LRU (never a promoted one in force-tunnel.list)" {
  export UCI_GET_amnezia_config_autolearn_max_entries="1"
  export ZP_VERDICT_new_com="direct_geoblocked"; export NSLOOKUP_ADDR="93.184.216.34"
  printf 'lru.com\n' > "$AUTO_LIST"
  old=$(( $(date +%s) - 100 ))
  printf 'lru.com\tdirect_geoblocked\t2\t\t%s\t%s\tgeoblock\n' "$old" "$old" > "$CAND"
  # APPEND fresh bytes before each pass so new.com is harvested both times.
  printf 'query[A] new.com from 192.168.1.2\nquery[A] new.com from 192.168.1.3\n' >> "$AL_QUERYLOG"
  run sh "$SCRIPT"   # count 1
  printf 'query[A] new.com from 192.168.1.2\nquery[A] new.com from 192.168.1.3\n' >> "$AL_QUERYLOG"
  run sh "$SCRIPT"   # count 2 -> confirmed -> evicts the LRU (lru.com)
  grep -qx 'new.com' "$AUTO_LIST"
  ! grep -qx 'lru.com' "$AUTO_LIST"     # evicted
}
@test "retention: stale candidate not in auto.list is pruned; an in-list one is kept" {
  export UCI_GET_amnezia_config_autolearn_candidate_retention_days="30"
  old=$(( $(date +%s) - 40*86400 ))            # older than 30 days
  printf 'gone.com\tdirect_ok\t1\t\t%s\t%s\t\n' "$old" "$old"  > "$CAND"
  printf 'kept.com\tdirect_geoblocked\t2\t\t%s\t%s\tgeoblock\n' "$old" "$old" >> "$CAND"
  printf 'kept.com\n' > "$AUTO_LIST"           # kept.com is live in auto.list
  : > "$AL_QUERYLOG"                            # nothing to harvest this pass
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  ! grep -q '^gone.com' "$CAND"                 # pruned (stale + not in auto.list)
  grep -q '^kept.com' "$CAND"                   # retained (in auto.list)
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — add a revalidation block (re-probe entries with `last_probe` older than `revalidate_days*86400`, drop on `direct_ok`) and an LRU-evict step in `_al_record` when `auto.list` line-count ≥ `autolearn_max_entries` (evict the `auto.list` domain whose `candidates.tsv` `last_probe` is smallest). Full code:

```sh
# Revalidation: re-probe stale auto entries; drop those that now pass direct.
_al_revalidate() {
  _days=$(_uci amnezia.config.autolearn_revalidate_days); _days=${_days:-14}
  _cut=$(( $(_now) - _days*86400 ))
  [ -s "$AUTO_LIST" ] || return 0
  _changed_local=0
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    _lp=$(awk -F'\t' -v d="$_d" '$1==d{print $6; exit}' "$CAND" 2>/dev/null); _lp=${_lp:-0}
    [ "$_lp" -lt "$_cut" ] 2>/dev/null || continue
    _pin=$(al_resolve_public "$_d") || true
    [ -n "$_pin" ] || continue
    _v=$(zapret-probe "$_d" "$_pin" | grep -o '"verdict":"[^"]*"' | sed 's/.*:"//;s/"//')
    if [ "$_v" = direct_ok ]; then
      _t=$(mktemp 2>/dev/null || echo "$AUTO_LIST.$$"); grep -vx "$_d" "$AUTO_LIST" > "$_t"; mv "$_t" "$AUTO_LIST"
      _changed_local=1
    else
      # refresh last_probe so we don't re-probe every pass
      _t=$(mktemp 2>/dev/null || echo "$CAND.$$")
      awk -F'\t' -v d="$_d" -v ts="$(_now)" 'BEGIN{OFS="\t"} $1==d{$6=ts} {print}' "$CAND" > "$_t" && mv "$_t" "$CAND"
    fi
  done < "$AUTO_LIST"
  [ "$_changed_local" = 1 ] && return 0 || return 1
}
```

`_al_revalidate` is already wired into the pass body (Task 5.3: `_changed=0` then `_al_revalidate && _changed=1`, before harvest). The LRU size cap already lives inside `_al_record` (Task 5.3). This task adds `_al_revalidate` (above) plus candidate-retention pruning (`_al_prune_candidates`, called near the end of the pass body in Task 5.3). Add:

```sh
# _al_prune_candidates: drop candidates.tsv rows whose last_probe is older than
# autolearn_candidate_retention_days AND that are not currently in auto.list.
# Bounds the flash-resident, client-IP-bearing privacy artifact.
_al_prune_candidates() {
  [ -s "$CAND" ] || return 0
  _days=$(_uci amnezia.config.autolearn_candidate_retention_days); _days=${_days:-30}
  _cut=$(( $(_now) - _days*86400 ))
  _t=$(mktemp 2>/dev/null || echo "$CAND.$$")
  awk -F'\t' -v cut="$_cut" 'NR==FNR{auto[$0]=1; next}
    ($1 in auto) || ($6+0 >= cut) {print}' "$AUTO_LIST" "$CAND" > "$_t" && mv "$_t" "$CAND"
}
```

- [ ] **Step 4: Run → PASS** (`bats test/unit/autolearn-pass.bats`).
- [ ] **Step 5: Commit** — `git add openwrt/amnezia-autolearn.sh test/unit/autolearn-pass.bats && git commit -m "feat(autolearn): revalidation-drop + candidate retention prune"`

### Task 5.5: tmpfs log rotation via `mv`-then-SIGUSR2 (design §3.1)

- [ ] **Step 1: Failing test** — append to `autolearn-pass.bats`:

```bash
@test "log rotation: oversize log is mv'd, dnsmasq sent USR2, offset reset" {
  export AUTOLEARN_LOG_MAX_BYTES=64        # tiny so the test log is "oversize"
  export AL_KILL=al-kill                   # logging shim (kill is a builtin)
  export DNSMASQ_PID_FILE="$BATS_TEST_TMPDIR/dnsmasq.pid"; echo 4242 > "$DNSMASQ_PID_FILE"
  # fill the log past the cap with non-query noise so nothing is added
  head -c 200 /dev/zero | tr '\0' 'x' > "$AL_QUERYLOG"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  grep -q 'kill -USR2 4242' "$STUB_LOG"            # reopen signalled (via AL_KILL)
  [ "$(cat "$AL_DIR/autolearn/.dnsmasq-log.offset")" = "0" ]   # offset reset
  [ ! -f "$AL_QUERYLOG.1" ]                          # rotated file unlinked
}
@test "log rotation: skipped (no truncate) when dnsmasq pid cannot be resolved" {
  export AUTOLEARN_LOG_MAX_BYTES=64; export AL_KILL=al-kill
  export DNSMASQ_PID_FILE="$BATS_TEST_TMPDIR/none.pid"   # absent
  head -c 200 /dev/zero | tr '\0' 'x' > "$AL_QUERYLOG"
  run sh "$SCRIPT"; [ "$status" -eq 0 ]
  ! grep -q 'kill -USR2' "$STUB_LOG"
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — add to `openwrt/amnezia-autolearn.sh` a rotation step run at the END of the pass (after harvest/probe), using the design's `mv`-then-signal idiom and BusyBox-safe pid resolution:

```sh
# Resolve dnsmasq pid: procd pidfile first, then pgrep -f (NOT -x). Empty -> "".
_al_dnsmasq_pid() {
  _pf="${DNSMASQ_PID_FILE:-}"
  if [ -z "$_pf" ]; then for _p in /var/run/dnsmasq/dnsmasq.*.pid; do [ -f "$_p" ] && { _pf="$_p"; break; }; done; fi
  if [ -n "$_pf" ] && [ -f "$_pf" ]; then cat "$_pf" 2>/dev/null; return; fi
  pgrep -f dnsmasq 2>/dev/null | head -n1
}

# Rotate the tmpfs log iff oversize. mv-then-USR2 so dnsmasq reopens at a fresh
# inode/offset 0 with no NUL-hole data loss. Skip entirely (do NOT truncate) if
# no pid resolves — safe: the file keeps growing until a later pass succeeds.
_al_rotate_log() {
  _sz=$(wc -c < "$AL_QUERYLOG" 2>/dev/null || echo 0)
  [ "$_sz" -gt "$AUTOLEARN_LOG_MAX_BYTES" ] 2>/dev/null || return 0
  _pid=$(_al_dnsmasq_pid); [ -n "$_pid" ] || return 0
  mv "$AL_QUERYLOG" "$AL_QUERYLOG.1" 2>/dev/null || return 0
  "$AL_KILL" -USR2 "$_pid" 2>/dev/null || true   # dnsmasq reopens AL_QUERYLOG at 0
  rm -f "$AL_QUERYLOG.1"
  printf '0\n' > "$OFFSET_F"
  # Accepted minor loss: query lines dnsmasq wrote to .1 between this pass's
  # harvest and the mv (a few KB, only when the log crossed 2 MiB) are dropped.
  # Harmless — the candidate pool is recurring popularity, not a one-shot signal;
  # any dropped domain reappears in a later pass's harvest.
}
```

Call `_al_rotate_log` just before `exit 0`. The kernel reopen itself is live-only-verify (the `dnsmasq` stub can't model a retained fd); the test asserts the `mv`+signal+offset-reset path.

- [ ] **Step 4: Run → PASS** (`bats test/unit/autolearn-pass.bats`).
- [ ] **Step 5: Commit** — `git add openwrt/amnezia-autolearn.sh test/unit/autolearn-pass.bats && git commit -m "feat(autolearn): tmpfs log rotation via mv-then-SIGUSR2 (pid-safe, skip-on-empty)"`

---

## Phase 6 — `amnezia-autolearn-ctl` CLI

**Files:** Create `openwrt/amnezia-autolearn-ctl.sh`; Test: `test/unit/autolearn-ctl.bats`.

### Task 6.1: status / list (JSON) + veto / promote / purge / set-enabled

- [ ] **Step 1: Failing test** — `test/unit/autolearn-ctl.bats`:

```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-autolearn-ctl.sh"
setup() {
  export AL_DIR="$BATS_TEST_TMPDIR/amnezia"; mkdir -p "$AL_DIR/force.d" "$AL_DIR/autolearn"
  export AUTO_LIST="$AL_DIR/force.d/auto.list"
  export AMNEZIA_FORCE_LOAD="amnezia-force-load"
  export UCI_GET_amnezia_config_autolearn_enabled="1"
  printf 'a.com\nb.com\n' > "$AUTO_LIST"
  printf 'a.com\tdirect_geoblocked\t2\t\t100\t200\tgeoblock\n' > "$AL_DIR/autolearn/candidates.tsv"
  printf 'b.com\tdirect_dpi_blocked\t3\t\t100\t200\tdpi\n' >> "$AL_DIR/autolearn/candidates.tsv"
}
@test "list emits valid JSON array with reason tags" {
  run sh "$SCRIPT" list
  echo "$output" | grep -q '"domain":"a.com"'
  echo "$output" | grep -q '"reason":"geoblock"'
  echo "$output" | grep -q '"reason":"dpi"'
}
@test "status emits enabled + count" {
  run sh "$SCRIPT" status
  echo "$output" | grep -q '"enabled":1'
  echo "$output" | grep -q '"count":2'
}
@test "status on an EMPTY auto.list is valid single-line JSON with count 0" {
  : > "$AUTO_LIST"
  run sh "$SCRIPT" status
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | wc -l | tr -d ' ')" -le 1 ]   # no embedded newline
  echo "$output" | grep -qx '{"enabled":1,"count":0}'
}
@test "veto removes from auto.list, adds to deny.list, runs force-load" {
  run sh "$SCRIPT" veto a.com; [ "$status" -eq 0 ]
  ! grep -qx 'a.com' "$AUTO_LIST"
  grep -qx 'a.com' "$AL_DIR/autolearn/deny.list"
  grep -q 'amnezia-force-load' "$STUB_LOG"
}
@test "promote moves to force-tunnel.list (manual, sacrosanct)" {
  run sh "$SCRIPT" promote b.com; [ "$status" -eq 0 ]
  ! grep -qx 'b.com' "$AUTO_LIST"
  grep -qx 'b.com' "$AL_DIR/force-tunnel.list"
}
@test "purge empties auto.list + candidates, runs force-load" {
  run sh "$SCRIPT" purge; [ "$status" -eq 0 ]
  [ ! -s "$AUTO_LIST" ]
  [ ! -s "$AL_DIR/autolearn/candidates.tsv" ]
}
@test "set-enabled writes uci" {
  run sh "$SCRIPT" set-enabled 0; [ "$status" -eq 0 ]
  grep -q "set amnezia.config.autolearn_enabled=0" "$STUB_LOG"
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — create `openwrt/amnezia-autolearn-ctl.sh`:

```sh
#!/bin/sh
# amnezia-autolearn-ctl: UI/CLI control for the auto-learning list.
set -u
AL_DIR="${AL_DIR:-/etc/amnezia}"
AUTO_LIST="${AUTO_LIST:-$AL_DIR/force.d/auto.list}"
CAND="$AL_DIR/autolearn/candidates.tsv"
DENY="$AL_DIR/autolearn/deny.list"
MANUAL="$AL_DIR/force-tunnel.list"
AL_LOCK="${AL_LOCK:-/var/lock/amnezia-autolearn.lock}"
AMNEZIA_FORCE_LOAD="${AMNEZIA_FORCE_LOAD:-amnezia-force-load}"
mkdir -p "$AL_DIR/force.d" "$AL_DIR/autolearn"

_je() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r\t'; }
_reload() { "$AMNEZIA_FORCE_LOAD" >/dev/null 2>&1 || true; }
_lock() { exec 9>"$AL_LOCK" 2>/dev/null || true; flock -n 9 2>/dev/null || true; }

cmd="${1:-status}"
case "$cmd" in
  list)
    printf '['; _first=1
    [ -s "$AUTO_LIST" ] && while IFS= read -r _d; do
      [ -n "$_d" ] || continue
      _row=$(awk -F'\t' -v d="$_d" '$1==d{print; exit}' "$CAND" 2>/dev/null)
      _reason=$(printf '%s' "$_row" | cut -f7); _added=$(printf '%s' "$_row" | cut -f5)
      [ "$_first" = 1 ] || printf ','; _first=0
      printf '{"domain":"%s","reason":"%s","added":"%s"}' "$(_je "$_d")" "$(_je "$_reason")" "$(_je "$_added")"
    done < "$AUTO_LIST"
    printf ']\n'
    ;;
  status)
    _en=$(uci -q get amnezia.config.autolearn_enabled 2>/dev/null); _en=${_en:-0}
    # NOT `grep -c . || echo 0`: BusyBox grep -c on an empty file prints 0 AND
    # exits 1, so `|| echo 0` would append a second 0 -> invalid JSON. Use the
    # repo's awk NR idiom (cf. amnezia-force-update.sh).
    _cnt=$(awk 'END{print NR}' "$AUTO_LIST" 2>/dev/null); _cnt=${_cnt:-0}
    printf '{"enabled":%s,"count":%s}\n' "$_en" "$_cnt"
    ;;
  veto)
    _d="${2:?domain}"; _lock
    _t=$(mktemp 2>/dev/null || echo "$AUTO_LIST.$$"); grep -vx "$_d" "$AUTO_LIST" 2>/dev/null > "$_t"; mv "$_t" "$AUTO_LIST"
    grep -qx "$_d" "$DENY" 2>/dev/null || printf '%s\n' "$_d" >> "$DENY"
    _reload
    ;;
  promote)
    _d="${2:?domain}"; _lock
    grep -qx "$_d" "$MANUAL" 2>/dev/null || printf '%s\n' "$_d" >> "$MANUAL"
    _t=$(mktemp 2>/dev/null || echo "$AUTO_LIST.$$"); grep -vx "$_d" "$AUTO_LIST" 2>/dev/null > "$_t"; mv "$_t" "$AUTO_LIST"
    _reload
    ;;
  purge)
    _lock; : > "$AUTO_LIST"; : > "$CAND"; _reload
    ;;
  set-enabled)
    _v="${2:?0|1}"; uci set "amnezia.config.autolearn_enabled=$_v"; uci commit amnezia
    ;;
  *) echo '{"error":"unknown command"}'; exit 2 ;;
esac
```

- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — `git add openwrt/amnezia-autolearn-ctl.sh test/unit/autolearn-ctl.bats && git commit -m "feat(autolearn): ctl CLI (status/list/veto/promote/purge/set-enabled)"`

---

## Phase 7 — init script + cron + reversible query logging

**Files:** Create `openwrt/amnezia-autolearn.init`; Test: `test/unit/autolearn-init.bats`.

### Task 7.1: enable sets up logging+cron; disable reverses both

- [ ] **Step 1: Failing test** — `test/unit/autolearn-init.bats`:

```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
INIT="$HARNESS_DIR/../openwrt/amnezia-autolearn.init"
setup() {
  export AL_CRON="$BATS_TEST_TMPDIR/cron"; : > "$AL_CRON"
  export AMNEZIA_DNSMASQ_INIT="dnsmasq"
}
@test "enable sets logqueries + tmpfs logfacility + cron line" {
  run sh "$INIT" enable
  grep -q "set dhcp.@dnsmasq\[0\].logqueries=1" "$STUB_LOG"
  grep -q "set dhcp.@dnsmasq\[0\].logfacility=/tmp/dnsmasq-queries.log" "$STUB_LOG"
  grep -q "amnezia-autolearn" "$AL_CRON"
}
@test "disable removes the uci options and the cron line" {
  sh "$INIT" enable
  run sh "$INIT" disable
  grep -q "delete dhcp.@dnsmasq\[0\].logqueries" "$STUB_LOG"
  ! grep -q "amnezia-autolearn" "$AL_CRON"
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — create `openwrt/amnezia-autolearn.init`. Use a procd init skeleton like the repo's other inits (`amnezia-force-load.init`); for the test the `enable`/`disable` actions are plain functions. Core:

```sh
#!/bin/sh /etc/rc.common
# amnezia-autolearn: enable/disable reversible dnsmasq query logging + cron.
START=97
USE_PROCD=0
AMNEZIA_DNSMASQ_INIT="${AMNEZIA_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
AL_CRON="${AL_CRON:-/etc/crontabs/root}"
AL_LOG="/tmp/dnsmasq-queries.log"

_interval() { uci -q get amnezia.config.autolearn_interval_min 2>/dev/null || echo 30; }

# Set a dhcp option only if it differs; echo "changed" when it did. Lets the
# caller restart dnsmasq ONLY on a real change (avoids a boot restart storm).
_set_if_diff() {  # <uci-path> <value>
  _cur=$(uci -q get "$1" 2>/dev/null)
  [ "$_cur" = "$2" ] && return 1
  uci set "$1=$2"; return 0
}

enable() {
  _ch=0
  _set_if_diff dhcp.@dnsmasq[0].logqueries 1 && _ch=1
  _set_if_diff "dhcp.@dnsmasq[0].logfacility" "$AL_LOG" && _ch=1
  _set_if_diff dhcp.@dnsmasq[0].log-async 5 && _ch=1
  if [ "$_ch" = 1 ]; then
    uci commit dhcp
    "$AMNEZIA_DNSMASQ_INIT" restart >/dev/null 2>&1 || true
    # Fail-closed visibility: if the build rejected log-async/logqueries, the
    # option won't read back — warn (no harvest is internet-safe, just inert).
    [ "$(uci -q get dhcp.@dnsmasq[0].logqueries)" = 1 ] || \
      logger -t amnezia-autolearn "WARNING: dnsmasq did not accept logqueries; harvesting inert"
  fi
  touch "$AL_CRON"
  grep -q 'amnezia-autolearn' "$AL_CRON" || \
    printf '*/%s * * * * /usr/sbin/amnezia-autolearn\n' "$(_interval)" >> "$AL_CRON"
  /etc/init.d/cron reload >/dev/null 2>&1 || true
}

disable() {
  # Unconditional + idempotent (uci -q delete is a no-op if absent). disable is
  # a deliberate, infrequent action, so an unconditional dnsmasq restart here is
  # fine (the boot-storm concern is the enable/start path, guarded above).
  uci -q delete dhcp.@dnsmasq[0].logqueries 2>/dev/null
  uci -q delete dhcp.@dnsmasq[0].logfacility 2>/dev/null
  uci -q delete dhcp.@dnsmasq[0].log-async 2>/dev/null
  uci commit dhcp
  "$AMNEZIA_DNSMASQ_INIT" restart >/dev/null 2>&1 || true
  if [ -f "$AL_CRON" ] && grep -q 'amnezia-autolearn' "$AL_CRON"; then
    _t=$(mktemp 2>/dev/null || echo "$AL_CRON.$$"); grep -v 'amnezia-autolearn' "$AL_CRON" > "$_t"; mv "$_t" "$AL_CRON"
    /etc/init.d/cron reload >/dev/null 2>&1 || true
  fi
  rm -f "$AL_LOG"
}

start() { [ "$(uci -q get amnezia.config.autolearn_enabled)" = 1 ] && enable || true; }
stop() { disable; }

# Test-env dispatch: when /etc/rc.common is ABSENT (bats), it never sourced us
# and never dispatched $1, so do it here. On-device rc.common IS present and
# handles $1 itself, so this block is skipped (no double-dispatch).
if [ ! -f /etc/rc.common ]; then
  case "${1:-}" in enable) enable ;; disable) disable ;; start) start ;; stop) stop ;; esac
fi
```

> Note: the `#!/bin/sh /etc/rc.common` shebang only takes effect when the file is executed directly on-device; the bats tests run it as `sh "$INIT" enable`, where the shebang is inert and the bottom `if [ ! -f /etc/rc.common ]` block dispatches. On-device, rc.common is present → it dispatches `$1` and the bottom block is skipped. `_set_if_diff` makes both enable and disable restart dnsmasq only on a real change, so a boot `start` with options already set causes no restart.

- [ ] **Step 4: Run → PASS** (`bats test/unit/autolearn-init.bats`). Ensure the `uci` stub records `set/delete/commit` to `STUB_LOG`.
- [ ] **Step 5: Commit** — `git add openwrt/amnezia-autolearn.init test/unit/autolearn-init.bats && git commit -m "feat(autolearn): init — reversible query logging + cron wiring"`

---

## Phase 8 — LuCI UI (toggle + auto-list table)

**Files:** Modify `openwrt/luci-app-amnezia/view/main.js`, `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json`; Test: extend `test/unit/luci-js.bats`.

### Task 8.1: master toggle + table calling ctl over rpc

- [ ] **Step 1: Failing test** — extend `test/unit/luci-js.bats` (mirror its existing static-assertion style — it greps `main.js` for required wiring):

```bash
@test "main.js wires the autolearn toggle and list" {
  JS="$HARNESS_DIR/../openwrt/luci-app-amnezia/view/main.js"
  grep -q 'autolearn' "$JS"
  grep -q 'amnezia-autolearn-ctl' "$JS"            # rpc target
  grep -q 'set-enabled' "$JS"
}
@test "acl grants exec on amnezia-autolearn-ctl" {
  ACL="$HARNESS_DIR/../openwrt/luci-app-amnezia/acl/luci-app-amnezia.json"
  grep -q 'amnezia-autolearn-ctl' "$ACL"
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — add to `main.js` an "Auto-learning" section: a toggle bound to `amnezia-autolearn-ctl set-enabled <0|1>` and a table rendered from `amnezia-autolearn-ctl list`, with per-row Remove (`veto`) / Promote (`promote`) and a Purge-all button (`purge`), reusing the view's existing focus-guarded poll + the same `fs.exec`/rpc pattern already used for tunnel-ctl and zapret. Add the `amnezia-autolearn-ctl` path to the ACL `read`/`exec` grants (mirror how `amnezia-tunnel-ctl`/`zapret-*` are granted in the existing ACL JSON). Follow the existing call conventions in `main.js` exactly (the repo decodes/execs server-side wrappers; never inline shell in JS).

> Implementer: read `main.js` + the ACL JSON first and copy the established `fs.exec('/usr/bin/<wrapper>', [args])` + `poll.add` + focus-guard pattern. Keep the toggle optimistic-but-reconciled against the next `status` poll (per the project's "never-observed sentinel" rule — use an explicit `hasObserved` flag, not `=== null`).

- [ ] **Step 4: Run → PASS** (`bats test/unit/luci-js.bats`). If the repo has a JS lint/build gate, run it.
- [ ] **Step 5: Commit** — `git add openwrt/luci-app-amnezia/view/main.js openwrt/luci-app-amnezia/acl/luci-app-amnezia.json test/unit/luci-js.bats && git commit -m "feat(autolearn): LuCI toggle + auto-list table"`

---

## Phase 9 — sync-to-packages + install wiring

**Files:** Modify `openwrt/install-amnezia-pbr.sh` (add `_amz_wire_autolearn`); **modify `dev/sync-to-packages.sh`** (it stages via hardcoded `cp` lists — globs won't pick up the new files); run it; Test: extend `test/unit/sync.bats` / `test/unit/packaging.bats`.

### Task 9.1: install wiring + package parity

- [ ] **Step 1: Failing test** — extend `test/unit/packaging.bats` (mirror its existing "file is staged in the ipk tree" assertions):

```bash
@test "autolearn files are staged into the package tree" {
  ROOT="$HARNESS_DIR/.."
  for f in usr/sbin/amnezia-autolearn usr/bin/amnezia-autolearn-ctl \
           etc/init.d/amnezia-autolearn usr/lib/amnezia/amnezia-autolearn-lib.sh; do
    find "$ROOT/packages" -path "*/$f" | grep -q . || { echo "missing $f"; return 1; }
  done
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** —
  1. **`dev/sync-to-packages.sh`** — add the four new files to the existing hardcoded `cp` lists (no globs exist):
     - in the `/usr/bin` wrapper `for src in … ` loop, append `amnezia-autolearn-ctl.sh` (→ `/usr/bin/amnezia-autolearn-ctl`);
     - add a dedicated `/usr/sbin` line (the pass is sbin, like `amnezia-failover`): `cp "$SRC/amnezia-autolearn.sh" "$PBR_PKG/usr/sbin/amnezia-autolearn"` + add it to that block's `chmod 0755`;
     - add the lib: `cp "$SRC/lib/amnezia-autolearn-lib.sh" "$PBR_PKG/usr/lib/amnezia/amnezia-autolearn-lib.sh"` + add to the `chmod 0644` lib group;
     - add the init: `cp "$SRC/amnezia-autolearn.init" "$PBR_PKG/etc/init.d/amnezia-autolearn"` + add to the init `chmod 0755` group.
  2. In `install-amnezia-pbr.sh`, add `_amz_wire_autolearn` (called from both fresh-install and migrate paths, like `_amz_wire_force_engine`): place the four files, `chmod +x` the executables, and — only if `autolearn_enabled=1` — call `/etc/init.d/amnezia-autolearn enable`. Default-OFF means a normal install does nothing visible.
  3. Run `dev/sync-to-packages.sh` to regenerate `packages/`.

- [ ] **Step 4: Run → PASS** — `bats test/unit/packaging.bats test/unit/sync.bats`; confirm `openwrt ↔ packages` parity is clean (run `dev/sync-to-packages.sh` then `git status` shows no further `packages/` drift — the CI gate).
- [ ] **Step 5: Commit** — review `git status` first, then stage EXPLICIT paths (never `git add -A` / `git add .` from root, and exclude the unrelated `feat/multi-tunnel-failover` working-tree changes if present):

```bash
git add openwrt/amnezia-autolearn.sh openwrt/amnezia-autolearn-ctl.sh \
        openwrt/amnezia-autolearn.init openwrt/lib/amnezia-autolearn-lib.sh \
        openwrt/install-amnezia-pbr.sh dev/sync-to-packages.sh \
        openwrt/config/amnezia openwrt/zapret-probe.sh openwrt/amnezia-force-load.sh \
        openwrt/luci-app-amnezia \
        packages/amnezia-pbr packages/luci-app-amnezia \
        test/stubs test/unit/autolearn-lib.bats test/unit/autolearn-pass.bats \
        test/unit/autolearn-ctl.bats test/unit/autolearn-init.bats \
        test/unit/zapret-probe-pin.bats test/unit/force-load.bats \
        test/unit/uci-schema.bats test/unit/luci-js.bats test/unit/packaging.bats test/unit/sync.bats
git commit -m "feat(autolearn): install wiring + sync-to-packages + parity"
```

---

## Phase 10 — VM end-to-end scenario

**Files:** Create `dev/vm/test-autolearn.sh`; wire into `dev/vm/test-all.sh`.

### Task 10.1: direct-default learning scenario

- [ ] **Step 1:** create `dev/vm/test-autolearn.sh` modeled on `dev/vm/test-tunnel-mgmt.sh` (same provision + assert harness, same `exec 3>&1` ordering — save fd3 BEFORE redirecting to the log file, the documented fd-loop bug). Scenario steps:
  1. provision a tunnel + set `routing_mode=direct-default`, `autolearn_enabled=1`, run `/etc/init.d/amnezia-autolearn enable`;
  2. write a fake `/tmp/dnsmasq-queries.log` with `query[A] <domain> from <ip>` lines for two distinct client IPs against a domain whose probe is canned (inject a `zapret-probe` shim returning `direct_geoblocked`), plus an RFC1918-resolving domain that must be skipped;
  3. run `amnezia-autolearn` twice; assert `auto.list` contains the geoblocked domain and NOT the internal one, and that `nft list set inet fw4 amnezia_force4` / the dnsmasq conf-dir reflects it;
  4. flip `autolearn_enabled=0` via ctl; assert learning halts and query-logging UCI is reversed;
  5. set `all_down`-style failover state and assert no new adds.

- [ ] **Step 2:** add an `autolearn` case to `dev/vm/test-all.sh` alongside `migrate` / `first-install` / `tunnel-mgmt`.
- [ ] **Step 3: Run** — `SSH_HOST=… dev/vm/test-all.sh autolearn` (or the harness's invocation) → expect OVERALL PASS.
- [ ] **Step 4: Commit** — `git add dev/vm/test-autolearn.sh dev/vm/test-all.sh && git commit -m "test(autolearn): VM end-to-end direct-default learning scenario"`

> Live-router carry-over (cannot be simulated — verify by hand after deploy): (a) `SIGUSR2` log rotation actually reopens dnsmasq's fd and harvest continues; (b) LAN DNS stays up during an `auto.list`-driven `force-load`; (c) the tmpfs query log does not grow unbounded; (d) `log-async=5` is accepted by the on-device dnsmasq build (the init's fail-closed check logs a warning if not); (e) **capture one real line from `/tmp/dnsmasq-queries.log` and confirm it matches the harvester regex** — the `al_querylog_pairs` awk scans fields for one starting `query[`, so a `dnsmasq[pid]: query[A] <domain> from <ip>` daemon-tag prefix is already handled, but if the on-device build emits a materially different shape, pin the regex to the captured line and update the bats `dnsmasq`-format fixture to mirror it exactly (hard-won stub rule).

---

## Self-review

**Spec coverage:** gate/harvest/safety-filter/abuse/probe/confirm/apply/age (P5) · pinned probe (P2) · deny global+suffix+guard (P3) · UCI defaults incl. toggle (P4) · CLI view/veto/promote/purge/toggle (P6) · init reversible logging + SIGUSR2 rotation + cron (P7) · LuCI toggle+table (P8) · install+sync (P9) · VM + live carry-over (P10). All spec sections map to a phase.

**Placeholder scan:** no TBD/“handle errors”/uncoded steps; every code step shows code. The two prose-only implementation tasks (P8 LuCI, P9 install) point the implementer at the exact existing patterns to copy rather than inventing — acceptable because faithfully duplicating an established in-repo pattern is the correct move there.

**Type/name consistency:** lib functions (`al_*`), file paths, UCI keys, TSV columns, and thresholds are defined once in "Locked contracts" and referenced verbatim throughout.

**Note for the SIGUSR2 rotation:** the detailed `mv`-then-signal + procd-pidfile logic from the design §3.1 is implemented in P5 Task 5.5; it is unit-testable except the kernel reopen (live-only), per the design.

## Pre-execution: reconcile the working tree FIRST

Before Phase 1, the shared working tree may hold uncommitted `feat/multi-tunnel-failover` changes from a parallel force-update fix (`openwrt/amnezia-force-update.sh`, `openwrt/lib/amnezia-common.sh`, `test/stubs/wget`+`ip`, `test/unit/force-update.bats`, and their `packages/` copies). Resolve this before executing so they never intermix with autolearn commits:

1. `git status` — confirm what's modified.
2. Decide with the user (or per their standing instruction): either **(a)** commit those changes on `feat/multi-tunnel-failover` (their home branch) and rebase/merge this branch onto the result, or **(b)** `git stash` them for the duration. Do NOT commit them as part of any autolearn task.
3. Re-run `bats test/unit/` to establish a green baseline (the parallel fix added tests — they should pass) before starting Phase 1.

This is a hard prerequisite: skipping it risks the recurring "changes landed on the wrong branch / got swept into an unrelated commit" failure.
