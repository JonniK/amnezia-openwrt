# Encrypted DNS (DoT) Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a LuCI-toggleable encrypted-DNS stack: DoT (stubby, via the sticky tunnel) → DoH (https-dns-proxy, direct) → health-gated plaintext provider, with a provider dropdown, leak-free by construction.

**Architecture:** A new POSIX-sh CLI `/usr/bin/amnezia-dns-ctl` owns all state transitions (`enable`/`disable`/`apply`/`set-provider`/`status`/`watchdog`). dnsmasq runs `noresolv`+`strict-order` over exactly two **encrypted** loopback upstreams (stubby `127.0.0.1#5453`, https-dns-proxy `127.0.0.1#5454`); plaintext is added/removed only by a procd watchdog under hysteresis. All dnsmasq/`dhcp` mutations serialize on a shared `flock` (fd 8). The LuCI page calls the CLI via `fs.exec`, like `amnezia-failover-ctl set-routing-mode`.

**Tech Stack:** BusyBox ash (POSIX sh), OpenWrt UCI, `stubby` + `https-dns-proxy` packages, dnsmasq, iproute2, LuCI client JS, bats + `test/stubs/`.

**Design doc:** `docs/superpowers/specs/2026-06-22-dot-dns-toggle-design.md` (design-review converged, cycle 4, 0C/0H). Read it before starting.

**Plan-review status:** converged over 3 cycles (C1 6C+9H → C2 1C+5H → C3 0C/0H). Ready for execution (NOT yet executed — pipeline stopped here per run owner).

## Global Constraints

- **Source of truth is `openwrt/`**; `dev/sync-to-packages.sh` mirrors into `packages/` (CI sync-check enforces parity). Every new file is an explicit edit to the sync script's copy lists.
- **POSIX sh / BusyBox ash only**; no bashisms. Every new shell file MUST be added to the hardcoded file list in `test/unit/shellcheck-phaseB.bats` (libs/CLIs) or `phaseE.bats` (init/hotplug) — that addition is an explicit step in the owning task, not optional.
- **Read UCI values with `uci -q get`**; list membership via `add_list`/`del_list`. Counting **section type** lines via `uci show <cfg> | grep -c '=<type>$'` is the one CLAUDE.md-sanctioned grep (type lines are unquoted).
- **Lib sourcing** mirrors the existing CLIs exactly: `AMNEZIA_LIB=${AMNEZIA_LIB:-/usr/lib/amnezia}` then `if [ -f "$AMNEZIA_LIB/x.sh" ]; then . "$AMNEZIA_LIB/x.sh"; else . "$(dirname "$0")/lib/x.sh"; fi`. Tests set `AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"`.
- **Test stubs MUST mirror real tool output.** Reuse the existing stub contract: argv is logged to `$STUB_LOG`; `uci -q get a.b.c` → env `UCI_GET_a_b_c` (`tr '.-' '__'`); `uci delete` exits 1 (teardown idiom); `uci show <cfg>` served from `UCI_SHOW_<cfg>`. New stubs (`stubby`, `https-dns-proxy`, `nslookup`) log argv and exit 0 unless a test needs a return code.
- **dnsmasq `--test` gates the candidate config we are about to apply** (rendered to a temp file from the live UCI server/option list), never a hardcoded `/var/etc/dnsmasq.conf.<hash>` path.
- **No Cloudflare** in any rendered daemon config — a fail-closed assertion.
- **dnsmasq lock fd = 8** (force-load owns **fd 9**); never reuse fd 9.
- **Never break client internet** — `dnsmasq --test` gates every reload; reloads are SSH-safe synchronous `dnsmasq` restarts (overridable via `AMNEZIA_DNSMASQ_INIT`), not `fw4 reload`.
- **Live router = surgical delta, NOT an installer re-run** (CLAUDE.md). Task 10 wires the installer for fresh `.ipk`/first-install/migrate paths; the running router gets stubby/https-dns-proxy + the new files placed by hand, verified WAN/DNS/handshake after each step.
- Branch: stay on `feat/autolearn-bypass` (run owner's instruction; the design left it open — this pins it).

---

## File structure

| File | Responsibility |
|---|---|
| `openwrt/lib/amnezia-dns-lib.sh` | Provider profile table; `dns_render_*`; `dnsmasq_lock`/`unlock` (fd 8); `dns_iprule_*`; `dns_dnsmasq_*`; `_uci_drop_all`. Sources nothing with side effects; defines `: "${TBL_STICKY:=100}"`/`: "${RULE_PREF_DOT:=30900}"` fallbacks so it works when sourced standalone. |
| `openwrt/amnezia-dns-ctl.sh` → `/usr/bin/amnezia-dns-ctl` | CLI verbs. Sources common + dns-lib via the `AMNEZIA_LIB` pattern. |
| `openwrt/amnezia-dns.init` → `/etc/init.d/amnezia-dns` | Boot `apply` if enabled; procd watchdog. |
| `openwrt/99-amnezia-dns.hotplug` → `/etc/hotplug.d/firewall/99-amnezia-dns` | On firewall `reload`: re-assert ip rule + refresh provider IPs. |
| `openwrt/lib/amnezia-common.sh` | Append `RULE_PREF_DOT`, `DNSMASQ_LOCK`. |
| `openwrt/config/amnezia` | UCI defaults. |
| `openwrt/amnezia-force-load.sh` | Minimal touch: wrap its hash-change dnsmasq block in the shared fd-8 lock. |
| `openwrt/luci-app-amnezia/view/main.js` | DoT toggle + provider dropdown + plaintext warning. |
| `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json` | `amnezia-dns-ctl` exec grant. |
| `openwrt/install-amnezia-pbr.sh` | opkg install + place files in the shared post-setup region. |
| `dev/sync-to-packages.sh` | Mirror new files. |
| `test/stubs/{stubby,https-dns-proxy,nslookup}` + upgraded `test/stubs/{dnsmasq,uci}` | Stubs. |
| `test/unit/{dns-render,dns-lock,dns-ctl,dns-watchdog}.bats` | Suites. |

### Execution order (HONEST — same-file tasks are SEQUENTIAL)

The shared-file reality forbids parallel edits. Run:
- **Sequential chain A (the lib):** Task 1 → Task 2 → Task 3 (all edit `amnezia-dns-lib.sh`).
- **Sequential chain B (the CLI):** Task 4 → Task 5 → Task 6 (all edit `amnezia-dns-ctl.sh` + its `case`).
- **Parallel-safe (disjoint files, after chains A+B):** Task 7 (`amnezia-force-load.sh`) ∥ Task 8 (`amnezia-dns.init` + hotplug) ∥ Task 9 (`main.js` + ACL).
- **Last:** Task 10 (installer + sync + packages mirror; consumes every prior file).

Do NOT dispatch Tasks 2&3 or 4&5&6 to parallel worktrees — they append to one file and to one `case` block; concurrent edits collide. Chains A and B may run concurrently with each other (different files), but each chain is internally sequential. Task 8 appends to chain-B's `dns-ctl.bats` and so runs **after** chain B (not parallel with it); Tasks 7/8/9 touch mutually-disjoint source AND test files, so those three may parallelize among themselves once A+B are done.

**On the `--test` gate vs orchestration tests:** the candidate-config `--test` gate is authoritatively exercised by the Task-3 reload tests (which seed the dnsmasq `server` env so the rendered candidate is non-empty). The Task-4/5/6 orchestration tests don't persist UCI writes through the stateless `uci` stub, so their `dns_dnsmasq_reload` tests a near-empty candidate (passes vacuously) — that's intentional: those tests assert orchestration/control-flow (which daemons restart, which tier is set, auto-revert), not the gate internals. Don't add gate assertions to the orchestration tests.

---

## Task 1: DNS lib — profiles, constants, UCI defaults

**Files:**
- Create: `openwrt/lib/amnezia-dns-lib.sh`
- Modify: `openwrt/lib/amnezia-common.sh` (append constants)
- Modify: `openwrt/config/amnezia`
- Modify: `test/unit/shellcheck-phaseB.bats` (add `amnezia-dns-lib.sh`)
- Test: `test/unit/dns-render.bats`

**Interfaces:**
- Produces `dns_profile <name>` → sets `DNS_DOT_IP`, `DNS_DOT_HOST`, `DNS_DOH_HOST`, `DNS_DOH_BOOTSTRAP`; returns 0 on a valid profile (DoT-IP present and ≠ DoH-bootstrap-IP), 1 otherwise. `custom` reads `amnezia.config.{dot_resolver,doh_resolver,doh_bootstrap}` and rejects an IP-literal DoH host.
- Produces fallbacks `: "${TBL_STICKY:=100}"`, `: "${RULE_PREF_DOT:=30900}"`, `: "${DNSMASQ_LOCK:=/var/lock/amnezia-dnsmasq.lock}"`, `DOT_PORT=5453`, `DOH_PORT=5454`.

- [ ] **Step 1: Write the failing test** — `test/unit/dns-render.bats`

```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
LIB="$HARNESS_DIR/../openwrt/lib/amnezia-dns-lib.sh"

@test "quad9 profile resolves; DoT-IP distinct from DoH-bootstrap-IP" {
  run sh -c ". '$LIB'; dns_profile quad9 && printf '%s|%s|%s|%s' \
    \"\$DNS_DOT_IP\" \"\$DNS_DOT_HOST\" \"\$DNS_DOH_HOST\" \"\$DNS_DOH_BOOTSTRAP\""
  [ "$status" -eq 0 ]
  [ "$output" = "9.9.9.9|dns.quad9.net|dns.quad9.net|149.112.112.112" ]
}

@test "every shipped profile yields DoT-IP != DoH-bootstrap-IP" {
  for p in quad9 adguard dns0 mullvad google; do
    run sh -c ". '$LIB'; dns_profile $p && [ \"\$DNS_DOT_IP\" != \"\$DNS_DOH_BOOTSTRAP\" ] && echo ok"
    [ "$status" -eq 0 ] || { echo "profile $p failed invariant"; false; }
    [ "$output" = "ok" ]
  done
}

@test "custom profile accepts a hostname DoH URL + bootstrap IP" {
  export UCI_GET_amnezia_config_dot_resolver='1.2.3.4@853#dot.example'
  export UCI_GET_amnezia_config_doh_resolver='https://doh.example/dns-query'
  export UCI_GET_amnezia_config_doh_bootstrap='5.6.7.8'
  run sh -c ". '$LIB'; dns_profile custom && printf '%s|%s|%s' \"\$DNS_DOT_IP\" \"\$DNS_DOH_HOST\" \"\$DNS_DOH_BOOTSTRAP\""
  [ "$status" -eq 0 ]
  [ "$output" = "1.2.3.4|doh.example|5.6.7.8" ]
}

@test "custom rejects an IP-literal DoH host" {
  export UCI_GET_amnezia_config_dot_resolver='1.2.3.4@853#dot.example'
  export UCI_GET_amnezia_config_doh_resolver='https://9.9.9.9/dns-query'
  export UCI_GET_amnezia_config_doh_bootstrap='5.6.7.8'
  run sh -c ". '$LIB'; dns_profile custom"
  [ "$status" -ne 0 ]
}

@test "custom rejects a missing bootstrap IP" {
  export UCI_GET_amnezia_config_dot_resolver='1.2.3.4@853#dot.example'
  export UCI_GET_amnezia_config_doh_resolver='https://doh.example/dns-query'
  run sh -c ". '$LIB'; dns_profile custom"
  [ "$status" -ne 0 ]
}

@test "unknown profile returns non-zero" {
  run sh -c ". '$LIB'; dns_profile bogus"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify failure** — `bats test/unit/dns-render.bats` → FAIL (no lib).

- [ ] **Step 3: Write the lib** — `openwrt/lib/amnezia-dns-lib.sh`

```sh
# Encrypted-DNS helpers (DoT/DoH). POSIX sh. Sourced by amnezia-dns-ctl, the
# watchdog, and force-load's lock wrap. No side effects on source.
# shellcheck disable=SC2034
: "${TBL_STICKY:=100}"            # fallback when sourced without amnezia-common.sh
: "${RULE_PREF_DOT:=30900}"
: "${DNSMASQ_LOCK:=/var/lock/amnezia-dnsmasq.lock}"
DOT_PORT=5453
DOH_PORT=5454

# dns_profile <name>: populate DNS_DOT_IP / DNS_DOT_HOST / DNS_DOH_HOST /
# DNS_DOH_BOOTSTRAP from the providers' DOCUMENTED RESOLVER anycast addresses
# (NOT the marketing-domain A record). Invariant: DoT-IP != DoH-bootstrap-IP.
dns_profile() {
  DNS_DOT_IP=""; DNS_DOT_HOST=""; DNS_DOH_HOST=""; DNS_DOH_BOOTSTRAP=""
  case "$1" in
    quad9)   DNS_DOT_IP=9.9.9.9;      DNS_DOT_HOST=dns.quad9.net
             DNS_DOH_HOST=dns.quad9.net;       DNS_DOH_BOOTSTRAP=149.112.112.112 ;;
    adguard) DNS_DOT_IP=94.140.14.14; DNS_DOT_HOST=dns.adguard-dns.com
             DNS_DOH_HOST=dns.adguard-dns.com; DNS_DOH_BOOTSTRAP=94.140.15.15 ;;
    dns0)    DNS_DOT_IP=193.110.81.0; DNS_DOT_HOST=dns0.eu
             DNS_DOH_HOST=dns0.eu;             DNS_DOH_BOOTSTRAP=185.253.5.0 ;;
    mullvad) DNS_DOT_IP=194.242.2.2;  DNS_DOT_HOST=dns.mullvad.net
             DNS_DOH_HOST=dns.mullvad.net;     DNS_DOH_BOOTSTRAP=194.242.2.3 ;;
    google)  DNS_DOT_IP=8.8.8.8;      DNS_DOT_HOST=dns.google
             DNS_DOH_HOST=dns.google;          DNS_DOH_BOOTSTRAP=8.8.4.4 ;;
    custom)
      _dot=$(uci -q get amnezia.config.dot_resolver)
      _doh=$(uci -q get amnezia.config.doh_resolver)
      DNS_DOH_BOOTSTRAP=$(uci -q get amnezia.config.doh_bootstrap)
      DNS_DOT_IP=${_dot%@*}
      DNS_DOT_HOST=${_dot##*#}
      DNS_DOH_HOST=$(printf '%s' "$_doh" | sed -e 's#^https://##' -e 's#/.*##')
      # reject IP-literal host: must contain at least one non-digit, non-dot label char
      printf '%s' "$DNS_DOH_HOST" | grep -q '[A-Za-z]' || return 1
      [ -n "$DNS_DOT_IP" ] && [ -n "$DNS_DOH_HOST" ] && [ -n "$DNS_DOH_BOOTSTRAP" ] || return 1
      ;;
    *) return 1 ;;
  esac
  [ -n "$DNS_DOT_IP" ] && [ "$DNS_DOT_IP" != "$DNS_DOH_BOOTSTRAP" ]
}
```

- [ ] **Step 4: Run to verify pass** — `bats test/unit/dns-render.bats` → PASS (6).

- [ ] **Step 5: Append constants** — `openwrt/lib/amnezia-common.sh` (after `MAX_TUNNELS`)

```sh
export RULE_PREF_DOT=30900            # DoT-IP ip rule; above pbr cleanup (30000), below sticky (31000)
export DNSMASQ_LOCK=/var/lock/amnezia-dnsmasq.lock
```

- [ ] **Step 6: UCI defaults** — `openwrt/config/amnezia`, inside `config amnezia 'config'`, appended **after `option installed_ts ''`** (before the `config globals` section), so the existing `routing_mode`/`autolearn_*` options are undisturbed

```
	option dot_enabled '0'
	option dns_provider 'quad9'
	option dot_resolver ''
	option doh_resolver ''
	option doh_bootstrap ''
	option dns_active_tier 'dot'
```

- [ ] **Step 7: Add lib to shellcheck list** — `test/unit/shellcheck-phaseB.bats`: append the **repo-relative** path `openwrt/lib/amnezia-dns-lib.sh` to the `shellcheck -s sh \` file list (the list uses `openwrt/...` paths, not bare names). Run `bats test/unit/shellcheck-phaseB.bats` → PASS.

- [ ] **Step 8: Commit**

```bash
git add openwrt/lib/amnezia-dns-lib.sh openwrt/lib/amnezia-common.sh openwrt/config/amnezia test/unit/dns-render.bats test/unit/shellcheck-phaseB.bats
git commit -m "feat(dns): provider profile table + DoT constants + UCI defaults"
```

---

## Task 2: Daemon-config render (stubby + https-dns-proxy via UCI, no Cloudflare)

**Files:**
- Modify: `openwrt/lib/amnezia-dns-lib.sh` (`_uci_drop_all`, `dns_render_stubby`, `dns_render_doh`)
- Create: `test/stubs/stubby`, `test/stubs/https-dns-proxy`
- Modify: `test/stubs/uci` (add generic `UCI_SHOW_<cfg>` so `_uci_drop_all`'s type-count is testable)
- Test: `test/unit/dns-render.bats` (append)

**Interfaces:**
- Consumes `dns_profile` outputs.
- Produces `dns_render_stubby`/`dns_render_doh` — delete all stock sections, add exactly one resolver from the profile (stubby: `address`/`tls_auth_name`/`tls_authentication=1`/listen `127.0.0.1@5453`/`tls_connection_timeout=2`; https-dns-proxy: `resolver_url=https://<host>/dns-query`/`bootstrap_dns=<ip>`/`listen_addr=127.0.0.1`/`listen_port=5454`), commit + restart via `$AMNEZIA_STUBBY_INIT`/`$AMNEZIA_DOH_INIT` (defaults `/etc/init.d/{stubby,https-dns-proxy}`).
- Produces `_uci_drop_all <cfg> <type>` — counts `=<type>$` lines via `uci show <cfg>` and deletes that many `@type[0]` (bounded; no reliance on `delete`'s exit code → safe against the stub's `delete) exit 1`).

- [ ] **Step 1: Add stubs** — `test/stubs/stubby`, `test/stubs/https-dns-proxy`, and a `test/stubs/nslookup` (used later):

```sh
#!/bin/sh
echo "stubby $*" >> "${STUB_LOG:-/dev/null}"; exit 0
```

(`https-dns-proxy` and `nslookup` identical with their own name. `chmod +x` all three.)

- [ ] **Step 2: Upgrade `uci` stub** — three changes to `test/stubs/uci`, all backward-compatible:

  **(a) Key normalization must cover `@`, `[`, `]`** (the recurring trap). The existing `UCI_GET_*` arm uses `tr '.-' '__'`, which cannot encode `dhcp.@dnsmasq[0].server`. Change **both** the `UCI_GET` and the new `UCI_SHOW` normalization to `tr -c '[:alnum:]' '_'`. This is a strict superset: for the existing keys (only `.`/`-`) it produces identical output, and for `dhcp.@dnsmasq[0].server` it yields exactly `dhcp__dnsmasq_0__server` — matching the env var the Task-3 reload tests export. Replace the existing get-key line:

```sh
  _envk="UCI_GET_$(printf '%s' "$2" | tr -c '[:alnum:]' '_')"
```

  **(b) Generic `UCI_SHOW_<cfg>`** (was network-only), placed before the legacy `show network` arm:

```sh
if [ "$1" = show ] && [ -n "$2" ]; then
  _showk="UCI_SHOW_$(printf '%s' "$2" | tr -c '[:alnum:]' '_')"
  eval _showv="\${$_showk+set}"
  if [ "${_showv:-}" = set ]; then eval printf '%s\\n' "\"\$$_showk\""; exit 0; fi
fi
```

  **(c) `uci add` must echo a section name** (real `uci add` echoes the new anonymous section's id; the current stub echoes nothing, so `_s=$(uci add ...)` captures empty → renderers emit malformed `stubby..address=`). Add an `add` arm to the top `case "$_verb"`:

```sh
  add) echo "amzsec"; exit 0 ;;
```

  so `_s=$(uci add stubby resolver)` → `amzsec` and `uci set stubby.amzsec.address=...` is well-formed and greppable, exactly as a real router behaves.

- [ ] **Step 3: Failing render tests** — append to `test/unit/dns-render.bats`

```bash
@test "_uci_drop_all deletes one delete per stock section (count via type lines)" {
  export UCI_SHOW_stubby=$'stubby.@resolver[0]=resolver\nstubby.@resolver[1]=resolver'
  run sh -c ". '$LIB'; _uci_drop_all stubby resolver"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'delete stubby.@resolver\[0\]' "$STUB_LOG")" = "2" ]
}

@test "stubby render: drop stock then one DoT resolver + short timeout" {
  export UCI_SHOW_stubby=$'stubby.@resolver[0]=resolver'
  run sh -c ". '$LIB'; dns_profile quad9; dns_render_stubby"
  [ "$status" -eq 0 ]
  grep -q "delete stubby.@resolver\[0\]" "$STUB_LOG"
  grep -q "address=9.9.9.9" "$STUB_LOG"
  grep -q "tls_auth_name=dns.quad9.net" "$STUB_LOG"
  grep -q "tls_connection_timeout=2" "$STUB_LOG"
  grep -q "stubby restart" "$STUB_LOG"
}

@test "doh render: hostname URL + bootstrap IP + port 5454 (no IP-literal)" {
  export UCI_SHOW_https_dns_proxy=$'https-dns-proxy.@https-dns-proxy[0]=https-dns-proxy'
  run sh -c ". '$LIB'; dns_profile adguard; dns_render_doh"
  [ "$status" -eq 0 ]
  grep -q "resolver_url=https://dns.adguard-dns.com/dns-query" "$STUB_LOG"
  grep -q "bootstrap_dns=94.140.15.15" "$STUB_LOG"
  grep -q "listen_port=5454" "$STUB_LOG"
  grep -q "https-dns-proxy restart" "$STUB_LOG"
}

@test "no Cloudflare endpoint appears in any rendered argv" {
  export UCI_SHOW_stubby=$'stubby.@resolver[0]=resolver'
  export UCI_SHOW_https_dns_proxy=$'https-dns-proxy.@https-dns-proxy[0]=https-dns-proxy'
  run sh -c ". '$LIB'; dns_profile quad9; dns_render_stubby; dns_render_doh"
  [ "$status" -eq 0 ]
  run grep -Ei "1\.1\.1\.1|1\.0\.0\.1|cloudflare" "$STUB_LOG"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 4: Run to verify failure** — FAIL.

- [ ] **Step 5: Implement renderers** — append to `openwrt/lib/amnezia-dns-lib.sh`

```sh
AMNEZIA_STUBBY_INIT="${AMNEZIA_STUBBY_INIT:-/etc/init.d/stubby}"
AMNEZIA_DOH_INIT="${AMNEZIA_DOH_INIT:-/etc/init.d/https-dns-proxy}"

# Delete every @<type> section of <cfg>. Count type lines (unquoted, grep-safe
# per CLAUDE.md), then delete that many @type[0]; bounded so it never depends on
# `uci delete`'s exit status (real UCI returns 0; the test stub returns 1).
_uci_drop_all() {
  _n=$(uci -q show "$1" 2>/dev/null | grep -c "=$2$")
  _i=0; while [ "$_i" -lt "$_n" ]; do uci -q delete "$1.@$2[0]" 2>/dev/null || true; _i=$((_i+1)); done
}

dns_render_stubby() {
  _uci_drop_all stubby resolver
  _s=$(uci add stubby resolver)
  uci set "stubby.$_s.address=$DNS_DOT_IP"
  uci set "stubby.$_s.tls_auth_name=$DNS_DOT_HOST"
  uci set "stubby.$_s.tls_authentication=1"
  uci -q delete stubby.global.listen_address 2>/dev/null || true
  uci add_list "stubby.global.listen_address=127.0.0.1@$DOT_PORT"
  uci set "stubby.global.tls_connection_timeout=2"   # short: bound the tunnel-down stall
  uci commit stubby
  "$AMNEZIA_STUBBY_INIT" restart 2>/dev/null || true
}

dns_render_doh() {
  _uci_drop_all https-dns-proxy https-dns-proxy
  _d=$(uci add https-dns-proxy https-dns-proxy)
  uci set "https-dns-proxy.$_d.resolver_url=https://$DNS_DOH_HOST/dns-query"
  uci set "https-dns-proxy.$_d.bootstrap_dns=$DNS_DOH_BOOTSTRAP"
  uci set "https-dns-proxy.$_d.listen_addr=127.0.0.1"
  uci set "https-dns-proxy.$_d.listen_port=$DOH_PORT"
  uci commit https-dns-proxy
  "$AMNEZIA_DOH_INIT" restart 2>/dev/null || true
}
```

- [ ] **Step 6: Run to verify pass** — `bats test/unit/dns-render.bats` → PASS (all). Re-run the full suite to confirm the `uci` stub change didn't regress: `bats test/unit/` → green.

- [ ] **Step 7: Commit**

```bash
git add openwrt/lib/amnezia-dns-lib.sh test/stubs/stubby test/stubs/https-dns-proxy test/stubs/nslookup test/stubs/uci test/unit/dns-render.bats
git commit -m "feat(dns): render stubby+https-dns-proxy via UCI (drop stock, no Cloudflare, hostname DoH)"
```

---

## Task 3: dnsmasq wiring + ip rule + shared lock + --test gate

**Files:**
- Modify: `openwrt/lib/amnezia-dns-lib.sh`
- Modify: `test/stubs/dnsmasq` (validate `--test -C <file>`)
- Test: `test/unit/dns-lock.bats`

**Interfaces:**
- `dnsmasq_lock`/`dnsmasq_unlock` — exclusive `flock` on `DNSMASQ_LOCK` via **fd 8** (no-op if `flock` absent).
- `dns_iprule_set <DoT-IP>`/`dns_iprule_clear <DoT-IP>` — idempotent `to <ip> lookup $TBL_STICKY pref $RULE_PREF_DOT` (delete-then-add).
- `dns_dnsmasq_encrypted` — set `dhcp.@dnsmasq[0]` `.noresolv=1`,`.strictorder=1`,`.server` list = the two loopback ports (exact-value `del_list`+`add_list`); no commit/reload.
- `dns_dnsmasq_add_plain`/`dns_dnsmasq_del_plain` — add/remove plaintext `server=` from `$AMNEZIA_RESOLV_AUTO` (default `/tmp/resolv.conf.d/resolv.conf.auto`).
- `dns_dnsmasq_restore` — drop `noresolv`/`strictorder`/our `server=`.
- `dns_dnsmasq_reload` — render the candidate config (current UCI options) to a temp file, `dnsmasq --test -C` it; only on pass, restart via `$AMNEZIA_DNSMASQ_INIT`. Returns non-zero (no restart) on failure.

- [ ] **Step 1: Upgrade dnsmasq stub** — `test/stubs/dnsmasq`

```sh
#!/bin/sh
echo "dnsmasq $*" >> "${STUB_LOG:-/dev/null}"
case " $* " in *" --test "*)
  _f=""; _p=0; for a in "$@"; do [ "$_p" = 1 ] && { _f=$a; _p=0; }; [ "$a" = "-C" ] && _p=1; done
  [ -n "$_f" ] && [ -f "$_f" ] || exit 1   # a --test with no readable -C file is a failure, not a pass
  while IFS= read -r l; do
    [ "${#l}" -gt 1024 ] && { echo "dnsmasq: bad option" >&2; exit 1; }
    case "$l" in
      server=*) printf '%s' "$l" | grep -Eq '^server=([0-9A-Fa-f:.]+)(#[0-9]+)?$' || { echo "dnsmasq: bad server" >&2; exit 1; } ;;
      nftset=*) printf '%s' "$l" | grep -q '#' || { echo "dnsmasq: bad nftset" >&2; exit 1; } ;;
    esac
  done < "$_f"
  exit 0 ;;
esac
exit 0
```

- [ ] **Step 2: Failing tests** — `test/unit/dns-lock.bats`

```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
LIB="$HARNESS_DIR/../openwrt/lib/amnezia-dns-lib.sh"
COMMON="$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"

@test "stub sanity: uci -q get round-trips a bracketed @dnsmasq[0] key" {
  # Guards the recurring trap: the @[]-bracket key must normalize to the env
  # var the reload tests set. If this fails, every candidate-render test is vacuous.
  export UCI_GET_dhcp__dnsmasq_0__server='127.0.0.1#5453'
  run sh -c 'uci -q get dhcp.@dnsmasq[0].server'
  [ "$status" -eq 0 ]
  [ "$output" = "127.0.0.1#5453" ]
}

@test "dnsmasq lock uses fd 8, never fd 9" {
  grep -Eq 'exec[[:space:]]+8>|flock[[:space:]]+-x[[:space:]]+8' "$LIB"
  run grep -Eq 'exec[[:space:]]+9>|flock[[:space:]]+-x[[:space:]]+9' "$LIB"
  [ "$status" -ne 0 ]
}

@test "ip rule set is idempotent: delete-then-add with table 100 pref 30900" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_iprule_set 9.9.9.9; dns_iprule_set 9.9.9.9"
  [ "$status" -eq 0 ]
  grep -q "rule del to 9.9.9.9 lookup 100 pref 30900" "$STUB_LOG"
  grep -q "rule add to 9.9.9.9 lookup 100 pref 30900" "$STUB_LOG"
}

@test "encrypted dnsmasq: noresolv+strictorder+two loopback servers, no plaintext" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_dnsmasq_encrypted"
  grep -q "set dhcp.@dnsmasq\[0\].noresolv=1" "$STUB_LOG"
  grep -q "set dhcp.@dnsmasq\[0\].strictorder=1" "$STUB_LOG"
  grep -q "add_list dhcp.@dnsmasq\[0\].server=127.0.0.1#5453" "$STUB_LOG"
  grep -q "add_list dhcp.@dnsmasq\[0\].server=127.0.0.1#5454" "$STUB_LOG"
}

@test "reload gate: a malformed server in the candidate config blocks restart" {
  export UCI_GET_dhcp__dnsmasq_0__server='not a valid server'
  export UCI_GET_dhcp__dnsmasq_0__noresolv='1'
  run sh -c ". '$COMMON'; . '$LIB'; dns_dnsmasq_reload"
  [ "$status" -ne 0 ]
  run grep -q "dnsmasq restart" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "reload gate: a valid candidate config restarts dnsmasq" {
  export UCI_GET_dhcp__dnsmasq_0__server='127.0.0.1#5453'
  export UCI_GET_dhcp__dnsmasq_0__noresolv='1'
  run sh -c ". '$COMMON'; . '$LIB'; dns_dnsmasq_reload"
  [ "$status" -eq 0 ]
  grep -q "dnsmasq restart" "$STUB_LOG"
}
```

- [ ] **Step 3: Run to verify failure** — FAIL.

- [ ] **Step 4: Implement** — append to `openwrt/lib/amnezia-dns-lib.sh`

```sh
AMNEZIA_DNSMASQ_INIT="${AMNEZIA_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
AMNEZIA_RESOLV_AUTO="${AMNEZIA_RESOLV_AUTO:-/tmp/resolv.conf.d/resolv.conf.auto}"

dnsmasq_lock() {                       # fd 8 — DISTINCT from force-load's fd 9
  exec 8>"$DNSMASQ_LOCK" 2>/dev/null || return 0
  flock -x 8 2>/dev/null || true
}
dnsmasq_unlock() { flock -u 8 2>/dev/null || true; exec 8>&- 2>/dev/null || true; }

dns_iprule_set() {
  ip rule del to "$1" lookup "$TBL_STICKY" pref "$RULE_PREF_DOT" 2>/dev/null || true
  ip rule add to "$1" lookup "$TBL_STICKY" pref "$RULE_PREF_DOT"
}
dns_iprule_clear() { ip rule del to "$1" lookup "$TBL_STICKY" pref "$RULE_PREF_DOT" 2>/dev/null || true; }

dns_dnsmasq_encrypted() {
  uci set "dhcp.@dnsmasq[0].noresolv=1"
  uci set "dhcp.@dnsmasq[0].strictorder=1"
  uci -q del_list "dhcp.@dnsmasq[0].server=127.0.0.1#$DOT_PORT"
  uci -q del_list "dhcp.@dnsmasq[0].server=127.0.0.1#$DOH_PORT"
  uci add_list "dhcp.@dnsmasq[0].server=127.0.0.1#$DOT_PORT"
  uci add_list "dhcp.@dnsmasq[0].server=127.0.0.1#$DOH_PORT"
}

_resolv_provider_ips() { awk '/^nameserver /{print $2}' "$AMNEZIA_RESOLV_AUTO" 2>/dev/null; }
dns_dnsmasq_add_plain() {
  for _ip in $(_resolv_provider_ips); do
    uci -q del_list "dhcp.@dnsmasq[0].server=$_ip"; uci add_list "dhcp.@dnsmasq[0].server=$_ip"
  done
}
dns_dnsmasq_del_plain() {
  for _ip in $(_resolv_provider_ips); do uci -q del_list "dhcp.@dnsmasq[0].server=$_ip"; done
}
dns_dnsmasq_restore() {
  uci -q delete "dhcp.@dnsmasq[0].noresolv" 2>/dev/null || true
  uci -q delete "dhcp.@dnsmasq[0].strictorder" 2>/dev/null || true
  uci -q del_list "dhcp.@dnsmasq[0].server=127.0.0.1#$DOT_PORT"
  uci -q del_list "dhcp.@dnsmasq[0].server=127.0.0.1#$DOH_PORT"
  dns_dnsmasq_del_plain
}

# Render the candidate dnsmasq options we control to a temp file and --test THAT
# (deterministic; never a router-instance hash path). Restart only on pass.
dns_dnsmasq_reload() {
  uci commit dhcp 2>/dev/null || true
  _tf=$(mktemp 2>/dev/null || echo /tmp/amz-dnsmasq-test.$$)
  {
    [ "$(uci -q get dhcp.@dnsmasq[0].noresolv)" = 1 ] && echo "no-resolv"
    [ "$(uci -q get dhcp.@dnsmasq[0].strictorder)" = 1 ] && echo "strict-order"
    for _s in $(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null); do echo "server=$_s"; done
    _cd=$(uci -q get dhcp.@dnsmasq[0].confdir 2>/dev/null); [ -n "$_cd" ] && echo "conf-dir=$_cd"
  } > "$_tf"
  if dnsmasq --test -C "$_tf" >/dev/null 2>&1; then
    rm -f "$_tf"; "$AMNEZIA_DNSMASQ_INIT" restart 2>/dev/null || true; return 0
  fi
  rm -f "$_tf"; return 1
}
```

- [ ] **Step 5: Run to verify pass** — `bats test/unit/dns-lock.bats` → PASS.

- [ ] **Step 6: Commit**

```bash
git add openwrt/lib/amnezia-dns-lib.sh test/stubs/dnsmasq test/unit/dns-lock.bats
git commit -m "feat(dns): dnsmasq encrypted/plain wiring, fd-8 lock, ip rule, candidate --test gate"
```

---

## Task 4: `amnezia-dns-ctl apply` + missing-binary fallback

**Files:**
- Create: `openwrt/amnezia-dns-ctl.sh`
- Modify: `test/unit/shellcheck-phaseB.bats` (add `amnezia-dns-ctl.sh`)
- Test: `test/unit/dns-ctl.bats`

**Interfaces:**
- `apply` — under `dnsmasq_lock`: render both daemons, encrypted dnsmasq, ip rule, `dns_dnsmasq_reload`. Missing binary ⇒ plain + `dns_active_tier=plaintext`, exit 0. `_has_bin` honors `AMNEZIA_HAS_BIN` (`1`/`0`).

- [ ] **Step 1: Failing tests** — `test/unit/dns-ctl.bats`

```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
CTL="$HARNESS_DIR/../openwrt/amnezia-dns-ctl.sh"

setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export UCI_GET_amnezia_config_dns_provider=quad9
  export UCI_GET_amnezia_config_dot_enabled=1
}

@test "apply (binaries present) renders both daemons, encrypted dnsmasq, ip rule, reload" {
  run sh -c "AMNEZIA_HAS_BIN=1 sh '$CTL' apply"
  [ "$status" -eq 0 ]
  grep -q "stubby restart" "$STUB_LOG"
  grep -q "https-dns-proxy restart" "$STUB_LOG"
  grep -q "rule add to 9.9.9.9 lookup 100 pref 30900" "$STUB_LOG"
  grep -q "dnsmasq restart" "$STUB_LOG"
}

@test "apply with missing binary -> plain + active_tier=plaintext, never wedges" {
  run sh -c "AMNEZIA_HAS_BIN=0 sh '$CTL' apply"
  [ "$status" -eq 0 ]
  run grep -q "stubby restart" "$STUB_LOG"; [ "$status" -ne 0 ]
  grep -q "set amnezia.config.dns_active_tier=plaintext" "$STUB_LOG"
}
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement** — `openwrt/amnezia-dns-ctl.sh`

```sh
#!/bin/sh
# amnezia-dns-ctl: encrypted-DNS state machine. POSIX sh.
# shellcheck source=lib/amnezia-common.sh
AMNEZIA_LIB=${AMNEZIA_LIB:-/usr/lib/amnezia}
for _l in amnezia-common.sh amnezia-dns-lib.sh; do
  if [ -f "$AMNEZIA_LIB/$_l" ]; then . "$AMNEZIA_LIB/$_l"; else . "$(dirname "$0")/lib/$_l"; fi
done

_has_bin() {
  [ -n "${AMNEZIA_HAS_BIN:-}" ] && { [ "$AMNEZIA_HAS_BIN" = 1 ]; return; }
  command -v stubby >/dev/null 2>&1 && command -v https-dns-proxy >/dev/null 2>&1
}

cmd_apply() {
  _prov=$(uci -q get amnezia.config.dns_provider || echo quad9)
  dnsmasq_lock
  if ! _has_bin; then
    amz_log "dns: stubby/https-dns-proxy missing -> plain provider DNS"
    dns_dnsmasq_restore; dns_dnsmasq_add_plain
    uci set amnezia.config.dns_active_tier=plaintext; uci commit amnezia
    dns_dnsmasq_reload || true; dnsmasq_unlock; return 0
  fi
  if ! dns_profile "$_prov"; then amz_log "dns: bad profile $_prov"; dnsmasq_unlock; return 1; fi
  dns_render_stubby; dns_render_doh
  dns_dnsmasq_encrypted
  dns_iprule_set "$DNS_DOT_IP"
  if dns_dnsmasq_reload; then dnsmasq_unlock; return 0; fi
  amz_log "dns: dnsmasq --test failed"; dnsmasq_unlock; return 1
}

case "${1:-}" in
  apply) cmd_apply ;;
  *) echo "usage: amnezia-dns-ctl {apply|enable|disable|set-provider|status|watchdog}" >&2; exit 2 ;;
esac
```

(Note: NO `set -eu` — the verbs use explicit return handling; `set -e` is incompatible with the watchdog's `[ ] && [ ]` idioms and the `_has_bin` return convention.)

- [ ] **Step 4: Run to verify pass** — `bats test/unit/dns-ctl.bats` → PASS. Append the repo-relative path `openwrt/amnezia-dns-ctl.sh` to the `shellcheck -s sh` list in `shellcheck-phaseB.bats`; run it → PASS.

- [ ] **Step 5: Commit**

```bash
git add openwrt/amnezia-dns-ctl.sh test/unit/dns-ctl.bats test/unit/shellcheck-phaseB.bats
git commit -m "feat(dns): amnezia-dns-ctl apply with missing-binary fallback"
```

---

## Task 5: `enable` / `disable` / `set-provider` (verify outside lock, auto-revert)

**Files:**
- Modify: `openwrt/amnezia-dns-ctl.sh`
- Test: `test/unit/dns-ctl.bats` (append)

**Interfaces:**
- `_probe_listener <addr>` — returns 0 iff that encrypted listener resolves a control domain; honors `AMNEZIA_VERIFY_DOT`/`AMNEZIA_VERIFY_DOH` (`pass`/`fail`) keyed by the `#5453`/`#5454` suffix. `_verify_encrypted` = DoT probe OR DoH probe.
- `enable` — `_has_bin` preflight (else exit 1, no mutation); `dot_enabled=1`; `apply`; **verify OUTSIDE the lock** (`apply` already released it); on fail ⇒ `cmd_disable` + exit 1.
- `disable` — restore + reload (under lock), clear ip rule, stop stubby/DoH/watchdog, `dot_enabled=0`, clear `dns_active_tier`.
- `set-provider <name>` — validate; persist `dns_provider_prev`; set new; if enabled ⇒ apply+verify, on fail roll back to prev (apply+verify), on second fail ⇒ disable (plain).

- [ ] **Step 1: Failing tests** — append to `test/unit/dns-ctl.bats`

```bash
@test "enable verifies the encrypted listeners (not #53) and persists enabled" {
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_VERIFY_DOT=pass AMNEZIA_VERIFY_DOH=pass sh '$CTL' enable"
  [ "$status" -eq 0 ]
  grep -q "127.0.0.1#5453" "$STUB_LOG"
  grep -q "set amnezia.config.dot_enabled=1" "$STUB_LOG"
}

@test "enable auto-reverts to plain when BOTH encrypted tiers fail verify" {
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=fail sh '$CTL' enable"
  [ "$status" -ne 0 ]
  grep -q "set amnezia.config.dot_enabled=0" "$STUB_LOG"
  grep -q "delete dhcp.@dnsmasq\[0\].noresolv" "$STUB_LOG"
}

@test "disable restores resolvfile, clears the ip rule, stops the watchdog" {
  run sh -c "sh '$CTL' disable"
  [ "$status" -eq 0 ]
  grep -q "delete dhcp.@dnsmasq\[0\].noresolv" "$STUB_LOG"
  grep -q "rule del to 9.9.9.9 lookup 100 pref 30900" "$STUB_LOG"
  grep -q "amnezia-dns stop" "$STUB_LOG"
}

@test "set-provider: new fails verify -> rolls back to previous provider (UCI), non-zero exit" {
  export UCI_GET_amnezia_config_dns_provider=quad9
  # adguard verify fails; quad9 (prev) passes
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=fail sh '$CTL' set-provider adguard"
  [ "$status" -ne 0 ]
  grep -q "set amnezia.config.dns_provider_prev=quad9" "$STUB_LOG"
  grep -q "set amnezia.config.dns_provider=quad9" "$STUB_LOG"   # rolled back
}
```

(`amnezia-dns stop` is logged because `cmd_disable` calls `${AMNEZIA_DNS_INIT:-/etc/init.d/amnezia-dns} stop`, and the harness has no such stub — add a `test/stubs/amnezia-dns` logging stub OR point `AMNEZIA_DNS_INIT` at the existing `amnezia-failover-init` stub pattern. Simplest: add `test/stubs/amnezia-dns` = `echo "amnezia-dns $*" >> "$STUB_LOG"; exit 0` and `chmod +x`.)

- [ ] **Step 2: Add `test/stubs/amnezia-dns`** (logging stub) and run the tests to verify failure — FAIL.

- [ ] **Step 3: Implement** — insert into `openwrt/amnezia-dns-ctl.sh` before the `case`

```sh
AMNEZIA_NSLOOKUP="${AMNEZIA_NSLOOKUP:-nslookup}"
AMNEZIA_DNS_INIT="${AMNEZIA_DNS_INIT:-/etc/init.d/amnezia-dns}"

_probe_listener() {                    # $1 = 127.0.0.1#<port>
  case "$1" in
    *"#$DOT_PORT") [ -n "${AMNEZIA_VERIFY_DOT:-}" ] && { [ "$AMNEZIA_VERIFY_DOT" = pass ]; return; } ;;
    *"#$DOH_PORT") [ -n "${AMNEZIA_VERIFY_DOH:-}" ] && { [ "$AMNEZIA_VERIFY_DOH" = pass ]; return; } ;;
  esac
  "$AMNEZIA_NSLOOKUP" -timeout=3 openwrt.org "$1" >/dev/null 2>&1
}
_verify_encrypted() { _probe_listener "127.0.0.1#$DOT_PORT" || _probe_listener "127.0.0.1#$DOH_PORT"; }

cmd_disable() {
  dnsmasq_lock; dns_dnsmasq_restore; dns_dnsmasq_reload || true; dnsmasq_unlock
  _prov=$(uci -q get amnezia.config.dns_provider || echo quad9)
  dns_profile "$_prov" 2>/dev/null && dns_iprule_clear "$DNS_DOT_IP"
  "$AMNEZIA_STUBBY_INIT" stop 2>/dev/null || true
  "$AMNEZIA_DOH_INIT" stop 2>/dev/null || true
  "$AMNEZIA_DNS_INIT" stop 2>/dev/null || true
  uci set amnezia.config.dot_enabled=0
  uci -q delete amnezia.config.dns_active_tier 2>/dev/null || true
  uci commit amnezia
}

cmd_enable() {
  _has_bin || { echo "install stubby + https-dns-proxy first" >&2; return 1; }
  uci set amnezia.config.dot_enabled=1; uci commit amnezia
  cmd_apply || { cmd_disable; return 1; }
  if _verify_encrypted; then return 0; fi    # verify runs OUTSIDE the lock (apply released it)
  amz_log "dns: encrypted verify failed -> auto-revert"; cmd_disable; return 1
}

cmd_set_provider() {
  _new=$1; dns_profile "$_new" || { echo "bad provider $_new" >&2; return 2; }
  _prev=$(uci -q get amnezia.config.dns_provider || echo quad9)
  uci set "amnezia.config.dns_provider_prev=$_prev"
  uci set "amnezia.config.dns_provider=$_new"; uci commit amnezia
  [ "$(uci -q get amnezia.config.dot_enabled)" = 1 ] || return 0
  if cmd_apply && _verify_encrypted; then return 0; fi
  uci set "amnezia.config.dns_provider=$_prev"; uci commit amnezia
  if cmd_apply && _verify_encrypted; then return 1; fi
  cmd_disable; return 1
}
```

Extend the `case`: `enable) cmd_enable ;; disable) cmd_disable ;; set-provider) cmd_set_provider "${2:?provider}" ;;`

- [ ] **Step 4: Run to verify pass** — `bats test/unit/dns-ctl.bats` → PASS.

- [ ] **Step 5: Commit**

```bash
git add openwrt/amnezia-dns-ctl.sh test/stubs/amnezia-dns test/unit/dns-ctl.bats
git commit -m "feat(dns): enable/disable/set-provider, per-listener verify outside lock, auto-revert"
```

---

## Task 6: Watchdog (per-listener tiers + hysteresis + dwell) + `status`

**Files:**
- Modify: `openwrt/amnezia-dns-ctl.sh`
- Test: `test/unit/dns-watchdog.bats`

**Interfaces:**
- `watchdog` — one tick per `AMNEZIA_DNS_WD_ONCE`, else loop every `${AMNEZIA_DNS_WD_INTERVAL:-20}`s. Per tick: probe DoT then DoH. **DoT up ⇒** `active_tier=dot`. **DoT down, DoH up ⇒** `active_tier=doh`. **Both down for `N=${AMNEZIA_DNS_WD_N:-3}` consecutive ⇒** add plaintext, `active_tier=plaintext`. **Recovery: an encrypted tier up for `M=${AMNEZIA_DNS_WD_M:-2}` consecutive AND `now-entered ≥ ${AMNEZIA_DNS_WD_DWELL:-120}`s ⇒** remove plaintext. Each mutation under `dnsmasq_lock`. Uses `date +%s` for dwell; honors `AMNEZIA_NOW` override in tests.
- `status` — JSON `{enabled,provider,active_tier,encrypted,healthy}`, bounded probes, never `apply`.

- [ ] **Step 1: Failing tests** — `test/unit/dns-watchdog.bats`

```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
CTL="$HARNESS_DIR/../openwrt/amnezia-dns-ctl.sh"
setup() { export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export UCI_GET_amnezia_config_dns_provider=quad9
  printf 'nameserver 109.195.112.1\n' > "$BATS_TEST_TMPDIR/resolv.auto"
  export AMNEZIA_RESOLV_AUTO="$BATS_TEST_TMPDIR/resolv.auto"
}

@test "DoT up -> active_tier=dot, no plaintext" {
  run sh -c "AMNEZIA_DNS_WD_ONCE=1 AMNEZIA_VERIFY_DOT=pass AMNEZIA_VERIFY_DOH=pass sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dns_active_tier=dot" "$STUB_LOG"
  run grep -q "dns_active_tier=plaintext" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "DoT down, DoH up -> active_tier=doh, still no plaintext" {
  run sh -c "AMNEZIA_DNS_WD_ONCE=1 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=pass sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dns_active_tier=doh" "$STUB_LOG"
  run grep -q "add_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "both down for N=1 -> enters plaintext with live-read provider IP" {
  run sh -c "AMNEZIA_DNS_WD_ONCE=1 AMNEZIA_DNS_WD_N=1 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=fail sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dns_active_tier=plaintext" "$STUB_LOG"
  grep -q "add_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG"
}

@test "recovery: in plaintext, an encrypted tier up for M with dwell elapsed exits plaintext" {
  export UCI_GET_amnezia_config_dns_active_tier=plaintext
  run sh -c "AMNEZIA_DNS_WD_ONCE=1 AMNEZIA_DNS_WD_M=1 AMNEZIA_NOW=99999 AMNEZIA_VERIFY_DOT=pass AMNEZIA_VERIFY_DOH=pass sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  grep -q "del_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG"
  grep -q "set amnezia.config.dns_active_tier=dot" "$STUB_LOG"
}

@test "status emits JSON and never calls apply" {
  run sh -c "AMNEZIA_VERIFY_DOT=pass sh '$CTL' status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"active_tier"'
  run grep -q "stubby restart" "$STUB_LOG"; [ "$status" -ne 0 ]
}
```

(With `_entered=0` at loop entry and `AMNEZIA_NOW=99999`, `now-entered ≥ dwell` holds, so the recovery arm fires on the single tick. The `del_list` of the live-read provider IP confirms plaintext was removed.)

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement** — append to `openwrt/amnezia-dns-ctl.sh`

```sh
_now() { [ -n "${AMNEZIA_NOW:-}" ] && { echo "$AMNEZIA_NOW"; return; }; date +%s 2>/dev/null || echo 0; }
_set_tier() { uci set "amnezia.config.dns_active_tier=$1"; uci commit amnezia; }

_enter_plain() {
  dnsmasq_lock; dns_dnsmasq_add_plain; dns_dnsmasq_reload || true; dnsmasq_unlock
  _set_tier plaintext
}
_exit_plain() {
  dnsmasq_lock; dns_dnsmasq_del_plain; dns_dnsmasq_reload || true; dnsmasq_unlock
}

cmd_watchdog() {
  _n=${AMNEZIA_DNS_WD_N:-3}; _m=${AMNEZIA_DNS_WD_M:-2}; _dwell=${AMNEZIA_DNS_WD_DWELL:-120}
  _fail=0; _ok=0; _entered=0
  _tier=$(uci -q get amnezia.config.dns_active_tier 2>/dev/null || echo dot)
  while true; do
    if _probe_listener "127.0.0.1#$DOT_PORT"; then
      _fail=0; _ok=$((_ok + 1))
      if [ "$_tier" = plaintext ]; then
        if [ "$_ok" -ge "$_m" ] && [ "$(( $(_now) - _entered ))" -ge "$_dwell" ]; then _exit_plain; _tier=dot; _set_tier dot; fi
      else
        [ "$_tier" = dot ] || { _tier=dot; _set_tier dot; }
      fi
    elif _probe_listener "127.0.0.1#$DOH_PORT"; then
      _fail=0; _ok=$((_ok + 1))
      if [ "$_tier" = plaintext ]; then
        if [ "$_ok" -ge "$_m" ] && [ "$(( $(_now) - _entered ))" -ge "$_dwell" ]; then _exit_plain; _tier=doh; _set_tier doh; fi
      else
        [ "$_tier" = doh ] || { _tier=doh; _set_tier doh; }
      fi
    else
      _ok=0; _fail=$((_fail + 1))
      if [ "$_tier" != plaintext ] && [ "$_fail" -ge "$_n" ]; then _enter_plain; _tier=plaintext; _entered=$(_now); fi
    fi
    [ -n "${AMNEZIA_DNS_WD_ONCE:-}" ] && break
    sleep "${AMNEZIA_DNS_WD_INTERVAL:-20}"
  done
  return 0
}

cmd_status() {
  _en=$(uci -q get amnezia.config.dot_enabled || echo 0)
  _pr=$(uci -q get amnezia.config.dns_provider || echo quad9)
  _tier=$(uci -q get amnezia.config.dns_active_tier || echo dot)
  _enc=false; case "$_tier" in dot|doh) _enc=true ;; esac
  _hl=false; _verify_encrypted && _hl=true
  printf '{"enabled":%s,"provider":"%s","active_tier":"%s","encrypted":%s,"healthy":%s}\n' \
    "$([ "$_en" = 1 ] && echo true || echo false)" "$_pr" "$_tier" "$_enc" "$_hl"
}
```

Extend the `case`: `watchdog) cmd_watchdog ;; status) cmd_status ;;`

- [ ] **Step 4: Run to verify pass** — `bats test/unit/dns-watchdog.bats` → PASS.

- [ ] **Step 5: Commit**

```bash
git add openwrt/amnezia-dns-ctl.sh test/unit/dns-watchdog.bats
git commit -m "feat(dns): watchdog per-listener tiers + hysteresis/dwell + status JSON"
```

---

## Task 7: force-load shared-lock wrap (minimal, correct span)

**Files:**
- Modify: `openwrt/amnezia-force-load.sh`
- Test: `test/unit/dns-lock.bats` (append) + re-run `test/unit/force-load.bats`

**Interfaces:** consumes `dnsmasq_lock`/`dnsmasq_unlock` (fd 8). force-load keeps its fd-9 force-lock as the **outer** lock.

- [ ] **Step 1: Failing test** — append to `test/unit/dns-lock.bats`

```bash
@test "force-load takes the fd-8 dnsmasq lock around its dnsmasq restart (not fd 9)" {
  FL="$HARNESS_DIR/../openwrt/amnezia-force-load.sh"
  grep -q "dnsmasq_lock" "$FL"
  grep -q "dnsmasq_unlock" "$FL"
  run grep -Eq 'exec[[:space:]]+9>.*dnsmasq|flock[[:space:]]+-x[[:space:]]+9.*dnsmasq' "$FL"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Source dns-lib + wrap the WHOLE hash-change block** — `openwrt/amnezia-force-load.sh`

After the existing common-lib source, add a guarded dns-lib source (so force-load gains the lock helpers; logic-neutral — only `:-`-guarded var defaults + function defs, no clobber of `FORCE_LOCK`/`AMNEZIA_DNSMASQ_INIT` which both libs default with `:-`):

```sh
if [ -f "$AMNEZIA_LIB/amnezia-dns-lib.sh" ]; then . "$AMNEZIA_LIB/amnezia-dns-lib.sh"
elif [ -f "$(dirname "$0")/lib/amnezia-dns-lib.sh" ]; then . "$(dirname "$0")/lib/amnezia-dns-lib.sh"; fi
```

Then wrap the **entire** `if [ "$_new_hash" != "$_old_hash" ]; then ... fi` body (currently lines ~185–232, which contains BOTH `uci commit dhcp` calls at lines ~195 and ~202, the nftset confdir `mv`, AND the `"$AMNEZIA_DNSMASQ_INIT" restart` at ~231) — acquire the lock just inside the `then`, release just before the closing `fi`:

```sh
  if [ "$_new_hash" != "$_old_hash" ]; then
    command -v dnsmasq_lock >/dev/null 2>&1 && dnsmasq_lock
    # ... ALL existing body unchanged: confdir wiring, both `uci commit dhcp`,
    #     nftset chunk write + mv, and the synchronous dnsmasq restart ...
    command -v dnsmasq_unlock >/dev/null 2>&1 && dnsmasq_unlock
  fi
```

**Do NOT** place the lock around only one of the two commits or inside an inner `if` — the whole block must be one lock span so neither commit nor the `mv` nor the restart races the DNS watchdog. No other logic changes (hash-gating, atomic `mv`, synchronous restart all untouched). force-load has no `set -e`, so the added `command -v` guards cannot early-exit-skip cleanup.

- [ ] **Step 4: Run to verify pass** — `bats test/unit/dns-lock.bats` → PASS; `bats test/unit/force-load.bats` → still green (no regression).

- [ ] **Step 5: Commit**

```bash
git add openwrt/amnezia-force-load.sh test/unit/dns-lock.bats
git commit -m "feat(dns): serialize force-load's whole dnsmasq block on the shared fd-8 lock"
```

---

## Task 8: Persistence — init + firewall hotplug

**Files:**
- Create: `openwrt/amnezia-dns.init`, `openwrt/99-amnezia-dns.hotplug`
- Modify: `test/unit/shellcheck-phaseE.bats` (add both files)
- Test: `test/unit/dns-ctl.bats` (append static assertions)

**Interfaces:** consumes `amnezia-dns-ctl apply`/`watchdog`.

- [ ] **Step 1: Failing test** — append to `test/unit/dns-ctl.bats`

```bash
@test "init: applies + launches watchdog only when enabled; hotplug keys on firewall reload" {
  INIT="$HARNESS_DIR/../openwrt/amnezia-dns.init"
  HP="$HARNESS_DIR/../openwrt/99-amnezia-dns.hotplug"
  grep -q "amnezia-dns-ctl apply" "$INIT"
  grep -q "procd_set_param command /usr/bin/amnezia-dns-ctl watchdog" "$INIT"
  grep -q 'dot_enabled' "$INIT"
  grep -q 'ACTION.*=.*reload' "$HP" || grep -q '"$ACTION" = reload' "$HP"
  grep -q "amnezia-dns-ctl apply" "$HP"
}
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Write the init** — `openwrt/amnezia-dns.init`

```sh
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=97
STOP=10

start_service() {
  [ "$(uci -q get amnezia.config.dot_enabled)" = 1 ] || return 0
  /usr/bin/amnezia-dns-ctl apply || true   # tolerant of no-tunnel-yet; chain degrades
  procd_open_instance
  procd_set_param command /usr/bin/amnezia-dns-ctl watchdog
  procd_set_param respawn
  procd_close_instance
}

stop_service() {
  /usr/bin/amnezia-dns-ctl disable >/dev/null 2>&1 || true
}
```

- [ ] **Step 4: Write the hotplug** — `openwrt/99-amnezia-dns.hotplug`

```sh
#!/bin/sh
# Re-assert the DoT ip rule + refresh provider IPs on firewall reload
# (proven trigger; sidesteps awg ifup/ifupdate boot race).
[ "$ACTION" = reload ] || exit 0
[ "$(uci -q get amnezia.config.dot_enabled)" = 1 ] || exit 0
/usr/bin/amnezia-dns-ctl apply >/dev/null 2>&1 &
```

- [ ] **Step 5: Run + shellcheck** — `bats test/unit/dns-ctl.bats` → PASS. Append the repo-relative paths `openwrt/amnezia-dns.init` and `openwrt/99-amnezia-dns.hotplug` to the `shellcheck` list in `shellcheck-phaseE.bats` (phaseE runs `--severity=warning`); run it → PASS.

- [ ] **Step 6: Commit**

```bash
git add openwrt/amnezia-dns.init openwrt/99-amnezia-dns.hotplug test/unit/dns-ctl.bats test/unit/shellcheck-phaseE.bats
git commit -m "feat(dns): boot init (apply+watchdog) + firewall-reload hotplug"
```

---

## Task 9: LuCI UI toggle + provider dropdown + warning, ACL

**Files:**
- Modify: `openwrt/luci-app-amnezia/view/main.js`
- Modify: `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json`
- Test: `test/unit/luci-js.bats`, `test/unit/acl.bats` (append)

- [ ] **Step 1: Failing ACL test (node-based, mirroring existing acl.bats)** — append to `test/unit/acl.bats`

```bash
@test "acl grants exec on amnezia-dns-ctl under write.file" {
  run node -e '
    const a = require("'"$HARNESS_DIR"'/../openwrt/luci-app-amnezia/acl/luci-app-amnezia.json");
    const wf = a["luci-app-amnezia"].write.file;
    if (!wf["/usr/bin/amnezia-dns-ctl"] || wf["/usr/bin/amnezia-dns-ctl"][0] !== "exec") throw new Error("missing");
    console.log("ok");'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
```

- [ ] **Step 2: Failing UI test** — append to `test/unit/luci-js.bats`

```bash
@test "main.js wires the DoT toggle + provider dropdown + plaintext warning" {
  JS="$HARNESS_DIR/../openwrt/luci-app-amnezia/view/main.js"
  grep -q "amnezia-dns-ctl" "$JS"
  grep -Eq "'enable'|\"enable\"" "$JS"
  grep -q "set-provider" "$JS"
  grep -q "active_tier" "$JS"
  grep -q "plaintext" "$JS"
}
```

- [ ] **Step 3: Run to verify failure** — FAIL.

- [ ] **Step 4: ACL entry** — `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json`, in the existing `write.file` object:

```json
"/usr/bin/amnezia-dns-ctl": [ "exec" ]
```

- [ ] **Step 5: UI controls** — `openwrt/luci-app-amnezia/view/main.js`, in the routing-mode area. Add a complete `renderDnsRow` (no placeholder), mirroring the file's existing `E(...)`/`L.bind`/`fs.exec` idiom (model on the `set-routing-mode` handler ~`main.js:866`):

```javascript
var DNS_PROVIDERS = ['quad9','adguard','dns0','mullvad','google','custom'];

function dnsExec(args) {
  return fs.exec('/usr/bin/amnezia-dns-ctl', args).then(function(res) {
    if (res.code !== 0)
      ui.addNotification(null, E('p', {}, _('DNS change failed: ') + (res.stderr || res.stdout || '')), 'danger');
    return refreshDnsStatus();
  });
}
function setDot(on)            { return dnsExec([ on ? 'enable' : 'disable' ]); }
function setDnsProvider(name)  { return dnsExec([ 'set-provider', name ]); }

function renderDnsRow(st) {
  var sel = E('select', { 'class': 'cbi-input-select', 'change': function(ev){ setDnsProvider(ev.target.value); } },
    DNS_PROVIDERS.map(function(p){
      return E('option', Object.assign({ 'value': p }, p === st.provider ? { 'selected': 'selected' } : {}),
        p === 'google' ? 'google (large US provider)' : p);
    }));
  var toggle = E('input', { 'type': 'checkbox', 'click': function(ev){ setDot(ev.target.checked); } });
  if (st.enabled) toggle.setAttribute('checked', 'checked');
  var warn = (st.active_tier === 'plaintext')
    ? E('div', { 'class': 'alert-message warning' }, _('Encrypted DNS unavailable — on plaintext fallback'))
    : E('span', { 'class': 'label' }, _('tier: ') + (st.active_tier || '—'));
  var box = document.getElementById('amz-dns-row');
  if (box) { box.innerHTML = ''; box.appendChild(E('div', {}, [ E('strong', {}, _('Encrypted DNS (DoT) ')), toggle, ' ', sel, ' ', warn ])); }
}
function refreshDnsStatus() {
  return fs.exec('/usr/bin/amnezia-dns-ctl', [ 'status' ]).then(function(res) {
    var st = {}; try { st = JSON.parse(res.stdout || '{}'); } catch (e) {}
    renderDnsRow(st);
  });
}
```

Add an `E('div', { 'id': 'amz-dns-row' })` container into the page's render tree (next to the routing-mode row) and call `refreshDnsStatus()` from the page's load/poll path (mirror how the routing-mode block triggers its initial render).

- [ ] **Step 6: Run to verify pass** — `bats test/unit/acl.bats test/unit/luci-js.bats` → PASS.

- [ ] **Step 7: Commit**

```bash
git add openwrt/luci-app-amnezia/view/main.js openwrt/luci-app-amnezia/acl/luci-app-amnezia.json test/unit/acl.bats test/unit/luci-js.bats
git commit -m "feat(dns): LuCI DoT toggle + provider dropdown + plaintext warning + ACL"
```

---

## Task 10: Installer + sync-to-packages + packages mirror

**Files:**
- Modify: `openwrt/install-amnezia-pbr.sh`
- Modify: `dev/sync-to-packages.sh`
- Generated: `packages/...` (via the sync script)
- Test: `test/unit/sync.bats`, `test/unit/packaging.bats` (append)

- [ ] **Step 1: Failing sync test (grep-on-SOURCE, never execute the destructive generator)** — append to `test/unit/sync.bats`

```bash
@test "sync script copies the new DNS files into the packages tree" {
  S="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-dns-ctl" "$S"
  grep -q "amnezia-dns-lib.sh" "$S"
  grep -q "amnezia-dns" "$S"            # init
  grep -q "99-amnezia-dns" "$S"         # hotplug
}
```

(Do **not** run `dev/sync-to-packages.sh` from a unit test — it `rm -rf`s the real `packages/` tree. The grep-on-source assertion matches the rest of `sync.bats`.)

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Extend the installer (shared region, after the dry-run guard, before dnsmasq wiring)** — `openwrt/install-amnezia-pbr.sh`

The shared region is the `_amz_wire_force_engine` function (reached by both `--migrate` and `--first-install`). It starts with a **dry-run early return** at line ~177 (`if [ "$_afe_dry" = 1 ]; then return 0; fi`) and does its dnsmasq confdir wiring at ~line 240. Insert the new block **after** the dry-run guard (so `--dry-run` never invokes opkg or enables a service) and **before** the confdir wiring. Use the repo's real `resolve_dep <installed_path> <tmp_name> <script_rel>` + `cp`+`chmod` idiom (NOT a fictional `install_file`), mirroring the force-load placement at lines 182–231, each with the `.ipk`-already-present guard:

```sh
# --- Encrypted-DNS packages + files (after the dry-run guard above) ---
for pkg in stubby https-dns-proxy; do
  opkg list-installed 2>/dev/null | grep -q "^$pkg " || opkg install "$pkg" 2>/dev/null \
    || amz_log "dns: opkg install $pkg failed (DoT falls back to plaintext until installed)"
done
# CLI + lib + init + hotplug via resolve_dep (on-router paths, not repo openwrt/ paths)
_dns_ctl=$(resolve_dep /usr/bin/amnezia-dns-ctl amnezia-dns-ctl.sh amnezia-dns-ctl.sh) || true
[ -n "$_dns_ctl" ] && [ "$_dns_ctl" != /usr/bin/amnezia-dns-ctl ] && { cp "$_dns_ctl" /usr/bin/amnezia-dns-ctl; chmod 0755 /usr/bin/amnezia-dns-ctl; }
_dns_lib=$(resolve_dep /usr/lib/amnezia/amnezia-dns-lib.sh amnezia-dns-lib.sh lib/amnezia-dns-lib.sh) || true
[ -n "$_dns_lib" ] && [ "$_dns_lib" != /usr/lib/amnezia/amnezia-dns-lib.sh ] && cp "$_dns_lib" /usr/lib/amnezia/amnezia-dns-lib.sh
if [ ! -f /etc/init.d/amnezia-dns ]; then
  _dns_init=$(resolve_dep /etc/init.d/amnezia-dns amnezia-dns.init amnezia-dns.init) || true
  [ -n "$_dns_init" ] && { cp "$_dns_init" /etc/init.d/amnezia-dns; chmod 0755 /etc/init.d/amnezia-dns; }
fi
if [ ! -f /etc/hotplug.d/firewall/99-amnezia-dns ]; then
  _dns_hp=$(resolve_dep /etc/hotplug.d/firewall/99-amnezia-dns 99-amnezia-dns.hotplug 99-amnezia-dns.hotplug) || true
  [ -n "$_dns_hp" ] && { cp "$_dns_hp" /etc/hotplug.d/firewall/99-amnezia-dns; chmod 0755 /etc/hotplug.d/firewall/99-amnezia-dns; }
fi
/etc/init.d/amnezia-dns enable 2>/dev/null || true
```

**Live-router note:** the running (manually-cutover) router does NOT re-run this installer — it gets `opkg install stubby https-dns-proxy` + the four files placed by hand during bring-up, WAN/DNS/handshake verified after each.

- [ ] **Step 4: Extend the sync script** — `dev/sync-to-packages.sh`

Append the new files to the existing explicit copy lists (read the script first):
- CLI wrapper `for src in \ ... do cp "$SRC/$src" "$PBR_PKG/usr/bin/${src%.sh}"` loop (~lines 42–52): add **`amnezia-dns-ctl.sh`** (with the `.sh` suffix — the loop strips it via `${src%.sh}`).
- lib `cp`+`chmod` block (~lines 69–75): add a `cp "$SRC/lib/amnezia-dns-lib.sh" "$PBR_PKG/usr/lib/amnezia/"` **and** the matching `chmod` line.
- init block (~lines 100–106): add the `cp` for `amnezia-dns.init` → `etc/init.d/amnezia-dns` + chmod.
- firewall hotplug block (~lines 108–115, dir already `mkdir`'d): add `99-amnezia-dns.hotplug` → `etc/hotplug.d/firewall/99-amnezia-dns` + chmod.
- ACL + `config/amnezia` are already mirrored by the existing luci/base copy steps — verify, add only if absent.
- **`.ipk` DEPENDS:** add `stubby` and `https-dns-proxy` to the `amnezia-pbr` package `Makefile`'s `DEPENDS:=` line so the `.ipk` install path pulls the daemons (the script-level `opkg install` only covers the imperative installer path; without this, an `.ipk`-only install is silently DoT-less until the missing-binary fallback kicks in).

- [ ] **Step 5: Run the generator manually (outside bats), verify parity** — `bash dev/sync-to-packages.sh` then `bats test/unit/sync.bats test/unit/packaging.bats` → PASS; confirm the four files exist under `packages/amnezia-pbr/files/...`.

- [ ] **Step 6: Full suite + shellcheck** — `bats test/unit/` → all green.

- [ ] **Step 7: Commit**

```bash
git add openwrt/install-amnezia-pbr.sh dev/sync-to-packages.sh packages/ test/unit/sync.bats test/unit/packaging.bats
git commit -m "feat(dns): installer opkg+place (shared region), sync openwrt<->packages parity"
```

---

## Out of scope for these phases (design doc → live-only gates)

Not unit-testable (the VM's dnsmasq doesn't serve real queries); executed during live bring-up, each preceded by its rollback + WAN/DNS/handshake check:
- **Leak test:** `tcpdump` WAN `:53`, tier-1 stalled → zero cleartext until the watchdog deliberately gates plaintext.
- **nftset tagging:** resolve a force-listed domain under DoT → IP in `amnezia_force4`, routed through the tunnel.
- **Failover interaction:** sticky failover → DNS continues via the new sticky tunnel.
- **Enable auto-revert (live):** `enable` against a deliberately-broken endpoint → auto-revert.
- **Per-profile IP pin:** confirm each profile's two resolver anycast IPs against provider docs + live probe; drop any that can't satisfy the invariant.
- **Plan-time pins now resolved here:** stubby timeout = `tls_connection_timeout=2` (Task 2); reload is **synchronous** (`$AMNEZIA_DNSMASQ_INIT restart`, both here and in force-load) so the lock-release-vs-reload overlap is closed by construction; v6 LAN posture = stated assumption (v4-only endpoints, `noresolv`→loopback-only). Watchdog `N=3`/`M=2`/`dwell=120s` are defaults, overridable via UCI/env, tunable live.

---

## Self-review notes

- **Spec coverage:** chain (T3/T4), two-distinct-IP invariant + custom validation (T1), no-Cloudflare with a real drop-then-assert test (T2), encrypted-tier verify-not-#53 + auto-revert (T5), watchdog per-listener tiers + hysteresis + **dwell implemented** (T6), shared fd-8 lock + whole-block force-load wrap (T3/T7), candidate `--test` gate + upgraded stub (T3), missing-binary fallback (T4), persistence (T8), UI+ACL via node-test (T9), installer-in-shared-region + grep-on-source sync (T10), live-only gates deferred. All design sections map.
- **Executability fixes vs review:** waves honestly serialized for same-file tasks; `AMNEZIA_LIB` sourcing with dev fallback; tests source `common`+`lib` and use `UCI_GET_*`/`UCI_SHOW_*`; `_uci_drop_all` bounded-count (no infinite loop, no reliance on `delete` exit); per-listener `AMNEZIA_VERIFY_DOT/DOH`; new `stubby`/`https-dns-proxy`/`nslookup`/`amnezia-dns` stubs; `AMNEZIA_RESOLV_AUTO` override; candidate-config `--test` (no hash path); ACL test via `node`; sync test grep-on-source; every new shell file added to a shellcheck list.
- **Name/type consistency:** `DNS_DOT_IP/DNS_DOT_HOST/DNS_DOH_HOST/DNS_DOH_BOOTSTRAP`, `RULE_PREF_DOT=30900`, `TBL_STICKY=100`, ports 5453/5454, fd 8, `dns_active_tier ∈ {dot,doh,plaintext}`, overrides (`AMNEZIA_HAS_BIN`, `AMNEZIA_VERIFY_DOT/DOH`, `AMNEZIA_*_INIT`, `AMNEZIA_DNS_WD_*`, `AMNEZIA_RESOLV_AUTO`, `AMNEZIA_NOW`) consistent across tasks.
