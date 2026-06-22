# Encrypted DNS (DoT) Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a LuCI-toggleable encrypted-DNS stack: DoT (stubby, via the sticky tunnel) → DoH (https-dns-proxy, direct) → health-gated plaintext provider, with a provider dropdown, leak-free by construction.

**Architecture:** A new POSIX-sh CLI `/usr/bin/amnezia-dns-ctl` owns all state transitions (`enable`/`disable`/`apply`/`set-provider`/`status`/`watchdog`). dnsmasq runs `noresolv`+`strict-order` over exactly two **encrypted** loopback upstreams (stubby `127.0.0.1#5453`, https-dns-proxy `127.0.0.1#5454`); plaintext is added/removed only by a procd watchdog under hysteresis. All dnsmasq/`dhcp` mutations serialize on a shared `flock`. The LuCI page calls the CLI via `fs.exec`, exactly like `amnezia-failover-ctl set-routing-mode`.

**Tech Stack:** BusyBox ash (POSIX sh), OpenWrt UCI, `stubby` + `https-dns-proxy` packages, dnsmasq, iproute2, LuCI client JS, bats + `test/stubs/`.

**Design doc:** `docs/superpowers/specs/2026-06-22-dot-dns-toggle-design.md` (design-review converged, cycle 4, 0C/0H). Read it before starting — every "why" lives there.

## Global Constraints

- **Source of truth is `openwrt/`**; `dev/sync-to-packages.sh` mirrors into `packages/` (CI sync-check enforces parity). Every new file is an explicit edit to the sync script.
- **POSIX sh / BusyBox ash only** for router scripts. No bashisms. `shellcheck` clean (the repo gates `shellcheck-phaseB/E.bats`).
- **Read UCI values with `uci -q get`** — never `uci show | grep | sed`. List membership via `add_list`/`del_list` or word-iteration.
- **Test stubs MUST mirror real tool output** (quoted UCI values, one-line lists; real `dnsmasq --test` exit semantics). A green stub run is not proof; the design's live-only gates are tracked but out of scope for unit phases.
- **No Cloudflare** in any rendered daemon config — a fail-closed assertion, not a preference.
- **dnsmasq lock fd = 8** (force-load already owns **fd 9**); never reuse fd 9.
- **Never break client internet** — `dnsmasq --test` gates every reload; reloads are SSH-safe `dnsmasq` restarts (synchronous, overridable via `AMNEZIA_DNSMASQ_INIT`), not `fw4 reload`.
- Branch: stay on `feat/autolearn-bypass` (per the run owner). Commit per task.

---

## File structure

| File | Responsibility |
|---|---|
| `openwrt/lib/amnezia-dns-lib.sh` | Provider profile table; pure parse/render helpers; the shared `dnsmasq_lock`/`dnsmasq_unlock` (fd 8); `dns_render_*` config builders. Sourced by the CLI, the watchdog, and force-load's lock wrap. |
| `openwrt/amnezia-dns-ctl.sh` → `/usr/bin/amnezia-dns-ctl` | The CLI: `status`/`enable`/`disable`/`apply`/`set-provider`/`watchdog`. Sources the lib. |
| `openwrt/amnezia-dns.init` → `/etc/init.d/amnezia-dns` | Boot: `apply` if `dot_enabled=1`; start the watchdog (procd respawn). |
| `openwrt/99-amnezia-dns.hotplug` → `/etc/hotplug.d/firewall/99-amnezia-dns` | On firewall `reload`: re-assert the `ip rule` + refresh live provider IPs (proven trigger; no iface-hotplug dir). |
| `openwrt/lib/amnezia-common.sh` | Add DoT constants (`RULE_PREF_DOT=30900`, `DNSMASQ_LOCK`, listener ports). |
| `openwrt/config/amnezia` | UCI defaults: `dot_enabled`, `dns_provider`, `dot_resolver`, `doh_resolver`, `doh_bootstrap`, `dns_active_tier`. |
| `openwrt/amnezia-force-load.sh` | Minimal touch: wrap its existing `uci commit dhcp`+dnsmasq restart in the shared fd-8 lock. |
| `openwrt/luci-app-amnezia/view/main.js` | DoT toggle + provider dropdown + `active_tier=plaintext` warning. |
| `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json` | `"/usr/bin/amnezia-dns-ctl": ["exec"]` under `write.file`. |
| `openwrt/install-amnezia-pbr.sh` | `opkg install stubby https-dns-proxy` (guarded, before any dnsmasq mutation); install new files. |
| `dev/sync-to-packages.sh` | Mirror the new CLI/lib/init/hotplug/ACL/config into `packages/`. |
| `test/stubs/{stubby,https-dns-proxy}` + upgraded `test/stubs/dnsmasq` | New/updated stubs in real output format. |
| `test/unit/dns-ctl.bats`, `dns-render.bats`, `dns-watchdog.bats`, `dns-lock.bats` | Unit suites. |

**Dependency waves** (a wave = phases sharing no input file/symbol):
- **Wave 1:** Phase 1 (lib: profiles + constants + UCI defaults).
- **Wave 2:** Phase 2 (daemon-config render) ∥ Phase 3 (dnsmasq/ip-rule/lock primitives) — different functions in the lib + different stubs.
- **Wave 3:** Phase 4 (`apply` orchestration; consumes 2+3).
- **Wave 4:** Phase 5 (`enable`/`disable`/`set-provider`) ∥ Phase 6 (`watchdog`) — both consume `apply`, different verbs/tests.
- **Wave 5:** Phase 7 (force-load lock wrap) ∥ Phase 8 (init+hotplug) ∥ Phase 9 (LuCI UI+ACL) — disjoint files.
- **Wave 6:** Phase 10 (installer + sync + packages mirror; consumes every new file).

---

## Task 1: DNS lib — profiles, constants, UCI defaults

**Files:**
- Create: `openwrt/lib/amnezia-dns-lib.sh`
- Modify: `openwrt/lib/amnezia-common.sh` (append DoT constants)
- Modify: `openwrt/config/amnezia` (add options under `config amnezia 'config'`)
- Test: `test/unit/dns-render.bats` (profile-resolution cases)

**Interfaces:**
- Produces: `dns_profile <name>` → sets `DNS_DOT_IP`, `DNS_DOT_HOST`, `DNS_DOH_HOST`, `DNS_DOH_BOOTSTRAP`; returns 0 on a known/valid profile, 1 otherwise. For `custom`, reads `amnezia.config.dot_resolver`/`doh_resolver`/`doh_bootstrap`.
- Produces constants: `RULE_PREF_DOT=30900`, `DNSMASQ_LOCK=/var/lock/amnezia-dnsmasq.lock`, `DOT_PORT=5453`, `DOH_PORT=5454`.

- [ ] **Step 1: Write the failing test** — `test/unit/dns-render.bats`

```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
LIB="$HARNESS_DIR/../openwrt/lib/amnezia-dns-lib.sh"

@test "quad9 profile resolves to two distinct resolver IPs" {
  run sh -c ". '$LIB'; dns_profile quad9 && printf '%s|%s|%s|%s' \
    \"\$DNS_DOT_IP\" \"\$DNS_DOT_HOST\" \"\$DNS_DOH_HOST\" \"\$DNS_DOH_BOOTSTRAP\""
  [ "$status" -eq 0 ]
  [ "$output" = "9.9.9.9|dns.quad9.net|dns.quad9.net|149.112.112.112" ]
  # invariant: DoT-IP != DoH-bootstrap-IP
  [ "9.9.9.9" != "149.112.112.112" ]
}

@test "every shipped profile yields DoT-IP distinct from DoH-bootstrap-IP" {
  for p in quad9 adguard dns0 mullvad google; do
    run sh -c ". '$LIB'; dns_profile $p && [ \"\$DNS_DOT_IP\" != \"\$DNS_DOH_BOOTSTRAP\" ] && echo ok"
    [ "$status" -eq 0 ] || { echo "profile $p failed invariant"; false; }
    [ "$output" = "ok" ]
  done
}

@test "unknown profile returns non-zero" {
  run sh -c ". '$LIB'; dns_profile bogus"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats test/unit/dns-render.bats -f "quad9 profile"`
Expected: FAIL (`amnezia-dns-lib.sh` does not exist).

- [ ] **Step 3: Write the lib (profile table)** — `openwrt/lib/amnezia-dns-lib.sh`

```sh
# Encrypted-DNS helpers (DoT/DoH). POSIX sh. Sourced by amnezia-dns-ctl,
# the watchdog, and force-load's lock wrap. No side effects on source.
# shellcheck disable=SC2034

DOT_PORT=5453
DOH_PORT=5454
RULE_PREF_DOT=30900
DNSMASQ_LOCK="${DNSMASQ_LOCK:-/var/lock/amnezia-dnsmasq.lock}"

# dns_profile <name>: populate DNS_DOT_IP / DNS_DOT_HOST / DNS_DOH_HOST /
# DNS_DOH_BOOTSTRAP. IPs are the providers' DOCUMENTED RESOLVER anycast
# addresses (not the marketing-domain A record). Invariant enforced by the
# table itself: DoT-IP and DoH-bootstrap-IP are two distinct resolver IPs.
dns_profile() {
  DNS_DOT_IP=""; DNS_DOT_HOST=""; DNS_DOH_HOST=""; DNS_DOH_BOOTSTRAP=""
  case "$1" in
    quad9)   DNS_DOT_IP=9.9.9.9;        DNS_DOT_HOST=dns.quad9.net
             DNS_DOH_HOST=dns.quad9.net;        DNS_DOH_BOOTSTRAP=149.112.112.112 ;;
    adguard) DNS_DOT_IP=94.140.14.14;   DNS_DOT_HOST=dns.adguard-dns.com
             DNS_DOH_HOST=dns.adguard-dns.com;  DNS_DOH_BOOTSTRAP=94.140.15.15 ;;
    dns0)    DNS_DOT_IP=193.110.81.0;   DNS_DOT_HOST=dns0.eu
             DNS_DOH_HOST=dns0.eu;              DNS_DOH_BOOTSTRAP=185.253.5.0 ;;
    mullvad) DNS_DOT_IP=194.242.2.2;    DNS_DOT_HOST=dns.mullvad.net
             DNS_DOH_HOST=dns.mullvad.net;      DNS_DOH_BOOTSTRAP=194.242.2.3 ;;
    google)  DNS_DOT_IP=8.8.8.8;        DNS_DOT_HOST=dns.google
             DNS_DOH_HOST=dns.google;           DNS_DOH_BOOTSTRAP=8.8.4.4 ;;
    custom)
      _dot=$(uci -q get amnezia.config.dot_resolver)     # <ip>@853#<host>
      _doh=$(uci -q get amnezia.config.doh_resolver)     # https://<host>/dns-query
      DNS_DOH_BOOTSTRAP=$(uci -q get amnezia.config.doh_bootstrap)
      DNS_DOT_IP=${_dot%@*}
      DNS_DOT_HOST=${_dot##*#}
      DNS_DOH_HOST=$(printf '%s' "$_doh" | sed -e 's#^https://##' -e 's#/.*##')
      case "$DNS_DOH_HOST" in *[0-9].[0-9]*[0-9]) return 1 ;; esac  # reject IP-literal host
      [ -n "$DNS_DOT_IP" ] && [ -n "$DNS_DOH_HOST" ] && [ -n "$DNS_DOH_BOOTSTRAP" ] || return 1
      [ "$DNS_DOT_IP" != "$DNS_DOH_BOOTSTRAP" ] || return 1
      return 0 ;;
    *) return 1 ;;
  esac
  [ -n "$DNS_DOT_IP" ] && [ "$DNS_DOT_IP" != "$DNS_DOH_BOOTSTRAP" ]
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats test/unit/dns-render.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Append constants to common lib** — `openwrt/lib/amnezia-common.sh` (after `MAX_TUNNELS`)

```sh
export RULE_PREF_DOT=30900            # DoT-IP ip rule; above pbr cleanup (30000), below sticky (31000)
export DNSMASQ_LOCK=/var/lock/amnezia-dnsmasq.lock
```

- [ ] **Step 6: Add UCI defaults** — `openwrt/config/amnezia`, inside `config amnezia 'config'`

```
	option dot_enabled '0'
	option dns_provider 'quad9'
	option dot_resolver ''
	option doh_resolver ''
	option doh_bootstrap ''
	option dns_active_tier 'dot'
```

- [ ] **Step 7: Commit**

```bash
git add openwrt/lib/amnezia-dns-lib.sh openwrt/lib/amnezia-common.sh openwrt/config/amnezia test/unit/dns-render.bats
git commit -m "feat(dns): provider profile table + DoT constants + UCI defaults"
```

---

## Task 2: Daemon-config render (stubby + https-dns-proxy via UCI, no Cloudflare)

**Files:**
- Modify: `openwrt/lib/amnezia-dns-lib.sh` (add `dns_render_stubby`, `dns_render_doh`)
- Create: `test/stubs/stubby`, `test/stubs/https-dns-proxy`
- Test: `test/unit/dns-render.bats` (append render cases)

**Interfaces:**
- Consumes: `dns_profile` outputs (Task 1).
- Produces: `dns_render_stubby` — replaces all `stubby.@resolver[*]` with one resolver = profile DoT (`address`, `tls_auth_name`, required TLS auth), listen `127.0.0.1@5453`; commits + restarts via `$AMNEZIA_STUBBY_INIT`. `dns_render_doh` — replaces all `@https-dns-proxy[*]` with one section (`resolver_url=https://<DoH_HOST>/dns-query`, `bootstrap_dns=<DoH_BOOTSTRAP>`, `listen_addr=127.0.0.1`, `listen_port=5454`); commits + restarts via `$AMNEZIA_DOH_INIT`. Both honor `AMNEZIA_STUBBY_INIT`/`AMNEZIA_DOH_INIT` overrides (default `/etc/init.d/stubby`, `/etc/init.d/https-dns-proxy`) for test interception.

- [ ] **Step 1: Add stubs mirroring real tool invocation** — `test/stubs/stubby` and `test/stubs/https-dns-proxy`

```sh
#!/bin/sh
# stub: log argv to $STUB_LOG (matches harness convention used by other stubs)
echo "stubby $*" >> "${STUB_LOG:-/dev/null}"; exit 0
```

(Identical body for `https-dns-proxy` with its own name; `chmod +x` both.)

- [ ] **Step 2: Write the failing render tests** — append to `test/unit/dns-render.bats`

```bash
@test "stubby render deletes all stock resolvers then adds exactly one DoT" {
  run sh -c ". '$LIB'; dns_profile quad9; dns_render_stubby"
  [ "$status" -eq 0 ]
  grep -q "delete stubby.@resolver" "$STUB_LOG"
  grep -q "set stubby.@resolver\[.*\].address=9.9.9.9" "$STUB_LOG"
  grep -q "tls_auth_name=dns.quad9.net" "$STUB_LOG"
}

@test "no Cloudflare survives in either rendered config" {
  run sh -c ". '$LIB'; dns_profile quad9; dns_render_stubby; dns_render_doh"
  [ "$status" -eq 0 ]
  run grep -Ei "1\.1\.1\.1|1\.0\.0\.1|cloudflare" "$STUB_LOG"
  [ "$status" -ne 0 ]
}

@test "doh render uses hostname URL + bootstrap IP (cert-valid, no IP-literal)" {
  run sh -c ". '$LIB'; dns_profile adguard; dns_render_doh"
  [ "$status" -eq 0 ]
  grep -q "resolver_url=https://dns.adguard-dns.com/dns-query" "$STUB_LOG"
  grep -q "bootstrap_dns=94.140.15.15" "$STUB_LOG"
  grep -q "listen_port=5454" "$STUB_LOG"
}
```

(The `uci` stub must log `delete`/`set`/`commit` argv — verify `test/stubs/uci` already does; if not, that is part of this step.)

- [ ] **Step 3: Run to verify failure** — `bats test/unit/dns-render.bats -f "stubby render"` → FAIL.

- [ ] **Step 4: Implement the renderers** — append to `openwrt/lib/amnezia-dns-lib.sh`

```sh
AMNEZIA_STUBBY_INIT="${AMNEZIA_STUBBY_INIT:-/etc/init.d/stubby}"
AMNEZIA_DOH_INIT="${AMNEZIA_DOH_INIT:-/etc/init.d/https-dns-proxy}"

_uci_drop_all() {  # _uci_drop_all <config> <type>: delete every @type[] section
  while uci -q get "$1.@$2[0]" >/dev/null 2>&1; do
    uci delete "$1.@$2[0]" || break
  done
}

dns_render_stubby() {
  _uci_drop_all stubby resolver
  _s=$(uci add stubby resolver)
  uci set "stubby.$_s.address=$DNS_DOT_IP"
  uci set "stubby.$_s.tls_auth_name=$DNS_DOT_HOST"
  uci set "stubby.$_s.tls_authentication=1"
  uci -q delete stubby.global.listen_address
  uci add_list "stubby.global.listen_address=127.0.0.1@$DOT_PORT"
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

- [ ] **Step 5: Run to verify pass** — `bats test/unit/dns-render.bats` → PASS (all).

- [ ] **Step 6: Commit**

```bash
git add openwrt/lib/amnezia-dns-lib.sh test/stubs/stubby test/stubs/https-dns-proxy test/unit/dns-render.bats
git commit -m "feat(dns): render stubby+https-dns-proxy via UCI (no Cloudflare, hostname DoH+bootstrap)"
```

---

## Task 3: dnsmasq wiring + ip rule + shared lock + --test gate

**Files:**
- Modify: `openwrt/lib/amnezia-dns-lib.sh` (`dnsmasq_lock`/`dnsmasq_unlock`, `dns_iprule_set/clear`, `dns_dnsmasq_encrypted/plain/restore`, `dns_dnsmasq_reload`)
- Modify: `test/stubs/dnsmasq` (make `--test` actually validate)
- Modify: `test/stubs/ip` (already mirrors rule-mask normalization — verify `to <ip>` rules log)
- Test: `test/unit/dns-lock.bats`, append to `test/unit/dns-render.bats`

**Interfaces:**
- Produces:
  - `dnsmasq_lock`/`dnsmasq_unlock` — exclusive `flock` on `DNSMASQ_LOCK` via **fd 8** (graceful no-op if `flock` absent).
  - `dns_iprule_set <DoT-IP>` / `dns_iprule_clear <DoT-IP>` — idempotent `to <ip> lookup 100 pref 30900` (delete-then-add).
  - `dns_dnsmasq_encrypted` — set `dhcp.@dnsmasq[0]` `.noresolv=1`, `.strictorder=1`, `.server` list = `127.0.0.1#5453`,`127.0.0.1#5454` (exact-value `del_list`/`add_list`); **does not** commit/reload.
  - `dns_dnsmasq_add_plain` / `dns_dnsmasq_del_plain` — add/remove plaintext `server=` entries (live-read from resolv.conf.auto).
  - `dns_dnsmasq_restore` — drop `noresolv`/`strictorder`/our `server=` (back to `resolvfile`).
  - `dns_dnsmasq_reload` — `dnsmasq --test` on the assembled config; only on pass, restart via `$AMNEZIA_DNSMASQ_INIT`. Returns non-zero (no reload) on test failure.

- [ ] **Step 1: Upgrade the dnsmasq stub to validate `--test`** — `test/stubs/dnsmasq`

```sh
#!/bin/sh
# Mirror real `dnsmasq --test`: parse a -C <file> for malformations the gate
# must catch (oversized line >1024B, malformed server=, bad nftset). exit 1 on
# any, like real dnsmasq. All other invocations log+exit 0.
echo "dnsmasq $*" >> "${STUB_LOG:-/dev/null}"
case " $* " in *" --test "*)
  _f=""; _p=0; for a in "$@"; do [ "$_p" = 1 ] && { _f=$a; _p=0; }; [ "$a" = "-C" ] && _p=1; done
  [ -n "$_f" ] && [ -f "$_f" ] || exit 0
  while IFS= read -r l; do
    [ "${#l}" -gt 1024 ] && { echo "dnsmasq: bad option at line" >&2; exit 1; }
    case "$l" in
      server=*) printf '%s' "$l" | grep -Eq '^server=([0-9a-fA-F:.]+)(#[0-9]+)?$' || { echo "dnsmasq: bad server" >&2; exit 1; } ;;
      nftset=*) printf '%s' "$l" | grep -q '#' || { echo "dnsmasq: bad nftset" >&2; exit 1; } ;;
    esac
  done < "$_f"
  exit 0 ;;
esac
exit 0
```

- [ ] **Step 2: Write the failing lock + rule + gate tests** — `test/unit/dns-lock.bats`

```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
LIB="$HARNESS_DIR/../openwrt/lib/amnezia-dns-lib.sh"

@test "dnsmasq lock uses fd 8 (never force-load's fd 9)" {
  run grep -nE 'exec[[:space:]]+8>|flock[[:space:]]+-x[[:space:]]+8' "$HARNESS_DIR/../openwrt/lib/amnezia-dns-lib.sh"
  [ "$status" -eq 0 ]
  run grep -nE 'exec[[:space:]]+9>|flock[[:space:]]+-x[[:space:]]+9' "$HARNESS_DIR/../openwrt/lib/amnezia-dns-lib.sh"
  [ "$status" -ne 0 ]
}

@test "ip rule set is idempotent: run twice, single rule add per invocation, delete-first" {
  run sh -c ". '$LIB'; dns_iprule_set 9.9.9.9; dns_iprule_set 9.9.9.9"
  [ "$status" -eq 0 ]
  grep -q "rule del to 9.9.9.9" "$STUB_LOG"
  grep -q "rule add to 9.9.9.9 lookup 100 pref 30900" "$STUB_LOG"
}

@test "encrypted dnsmasq has noresolv+strictorder+exactly two loopback servers, no plaintext" {
  run sh -c ". '$LIB'; dns_dnsmasq_encrypted"
  grep -q "set dhcp.@dnsmasq\[0\].noresolv=1" "$STUB_LOG"
  grep -q "set dhcp.@dnsmasq\[0\].strictorder=1" "$STUB_LOG"
  grep -q "add_list dhcp.@dnsmasq\[0\].server=127.0.0.1#5453" "$STUB_LOG"
  grep -q "add_list dhcp.@dnsmasq\[0\].server=127.0.0.1#5454" "$STUB_LOG"
}

@test "reload gate: a render that fails --test does NOT restart dnsmasq" {
  # Force a bad confdir line the stub will reject.
  printf 'server=not a valid server\n' > "$BATS_TEST_TMPDIR/bad.conf"
  run sh -c ". '$LIB'; AMNEZIA_DNSMASQ_TESTCONF='$BATS_TEST_TMPDIR/bad.conf' dns_dnsmasq_reload"
  [ "$status" -ne 0 ]
  run grep -q "dnsmasq restart" "$STUB_LOG"; [ "$status" -ne 0 ]
}
```

- [ ] **Step 3: Run to verify failure** — `bats test/unit/dns-lock.bats` → FAIL.

- [ ] **Step 4: Implement the primitives** — append to `openwrt/lib/amnezia-dns-lib.sh`

```sh
AMNEZIA_DNSMASQ_INIT="${AMNEZIA_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
AMNEZIA_DNSMASQ_TESTCONF="${AMNEZIA_DNSMASQ_TESTCONF:-/var/etc/dnsmasq.conf.cfg01411c}"

dnsmasq_lock() {   # fd 8 — DISTINCT from force-load's fd 9
  exec 8>"$DNSMASQ_LOCK" 2>/dev/null || return 0
  flock -x 8 2>/dev/null || true
}
dnsmasq_unlock() { flock -u 8 2>/dev/null || true; exec 8>&- 2>/dev/null || true; }

dns_iprule_set() {   # $1 = DoT IP
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

dns_dnsmasq_add_plain() {   # live-read provider IPs at gate time
  for _ip in $(awk '/^nameserver /{print $2}' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null); do
    uci -q del_list "dhcp.@dnsmasq[0].server=$_ip"
    uci add_list "dhcp.@dnsmasq[0].server=$_ip"
  done
}
dns_dnsmasq_del_plain() {
  for _ip in $(awk '/^nameserver /{print $2}' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null); do
    uci -q del_list "dhcp.@dnsmasq[0].server=$_ip"
  done
}
dns_dnsmasq_restore() {
  uci -q delete "dhcp.@dnsmasq[0].noresolv"
  uci -q delete "dhcp.@dnsmasq[0].strictorder"
  for _p in "$DOT_PORT" "$DOH_PORT"; do
    uci -q del_list "dhcp.@dnsmasq[0].server=127.0.0.1#$_p"
  done
  dns_dnsmasq_del_plain
}

dns_dnsmasq_reload() {
  uci commit dhcp
  if dnsmasq --test -C "$AMNEZIA_DNSMASQ_TESTCONF" >/dev/null 2>&1; then
    "$AMNEZIA_DNSMASQ_INIT" restart 2>/dev/null || true
    return 0
  fi
  return 1   # bad config: never reload
}
```

- [ ] **Step 5: Run to verify pass** — `bats test/unit/dns-lock.bats` → PASS.

- [ ] **Step 6: Commit**

```bash
git add openwrt/lib/amnezia-dns-lib.sh test/stubs/dnsmasq test/unit/dns-lock.bats
git commit -m "feat(dns): dnsmasq encrypted/plain wiring, fd-8 lock, ip rule, --test gate"
```

---

## Task 4: `apply` orchestration + missing-binary fallback

**Files:**
- Create: `openwrt/amnezia-dns-ctl.sh` (dispatch + `apply`)
- Test: `test/unit/dns-ctl.bats`

**Interfaces:**
- Consumes: all Task 1–3 lib functions; `dns_profile` of `amnezia.config.dns_provider`.
- Produces: `amnezia-dns-ctl apply` — **under `dnsmasq_lock`**: render stubby+DoH, set encrypted dnsmasq, set `ip rule`, `dns_dnsmasq_reload`; releases lock. If `stubby`/`https-dns-proxy` binary missing ⇒ skip encrypted render, set plain provider DNS, `dns_active_tier=plaintext`, log a warning, exit 0 (never wedge). Honors `AMNEZIA_HAS_BIN` override (`command -v` shim) for tests.

- [ ] **Step 1: Write the failing apply tests** — `test/unit/dns-ctl.bats`

```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
CTL="$HARNESS_DIR/../openwrt/amnezia-dns-ctl.sh"

setup() { export UCI_FAKE='amnezia.config.dns_provider=quad9 amnezia.config.dot_enabled=1'; }

@test "apply (binaries present) renders both daemons, encrypted dnsmasq, ip rule, reload" {
  run sh -c "AMNEZIA_HAS_BIN=1 sh '$CTL' apply"
  [ "$status" -eq 0 ]
  grep -q "stubby restart" "$STUB_LOG"
  grep -q "https-dns-proxy restart" "$STUB_LOG"
  grep -q "rule add to 9.9.9.9 lookup 100 pref 30900" "$STUB_LOG"
  grep -q "dnsmasq restart" "$STUB_LOG"
}

@test "apply with missing binary falls back to plain + active_tier=plaintext, never wedges" {
  run sh -c "AMNEZIA_HAS_BIN=0 sh '$CTL' apply"
  [ "$status" -eq 0 ]
  run grep -q "stubby restart" "$STUB_LOG"; [ "$status" -ne 0 ]
  grep -q "set amnezia.config.dns_active_tier=plaintext" "$STUB_LOG"
}
```

- [ ] **Step 2: Run to verify failure** — FAIL (no `amnezia-dns-ctl.sh`).

- [ ] **Step 3: Implement dispatch + apply** — `openwrt/amnezia-dns-ctl.sh`

```sh
#!/bin/sh
# amnezia-dns-ctl: encrypted-DNS state machine. POSIX sh.
set -eu
AMZ_LIBDIR="${AMZ_LIBDIR:-/usr/lib/amnezia}"
. "$AMZ_LIBDIR/amnezia-common.sh"
. "$AMZ_LIBDIR/amnezia-dns-lib.sh"

_has_bin() {   # overridable in tests via AMNEZIA_HAS_BIN
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
  dns_render_stubby
  dns_render_doh
  dns_dnsmasq_encrypted
  dns_iprule_set "$DNS_DOT_IP"
  dns_dnsmasq_reload || { amz_log "dns: dnsmasq --test failed"; dnsmasq_unlock; return 1; }
  dnsmasq_unlock
}

case "${1:-}" in
  apply) cmd_apply ;;
  *) echo "usage: amnezia-dns-ctl {apply|enable|disable|set-provider|status|watchdog}" >&2; exit 2 ;;
esac
```

- [ ] **Step 4: Run to verify pass** — `bats test/unit/dns-ctl.bats` → PASS.

- [ ] **Step 5: Commit**

```bash
git add openwrt/amnezia-dns-ctl.sh test/unit/dns-ctl.bats
git commit -m "feat(dns): amnezia-dns-ctl apply with missing-binary fallback"
```

---

## Task 5: `enable` / `disable` / `set-provider` (verify outside lock, auto-revert)

**Files:**
- Modify: `openwrt/amnezia-dns-ctl.sh`
- Test: `test/unit/dns-ctl.bats` (append)

**Interfaces:**
- Consumes: `cmd_apply`, `dns_profile`.
- Produces:
  - `enable` — preflight `_has_bin` (else exit 1, no mutation); set `dot_enabled=1`; `apply`; **verify outside the lock** via `_verify_encrypted` (probe `127.0.0.1#5453` then `#5454` with `nslookup`); on fail ⇒ `disable` internals + `dot_enabled=0` + exit 1.
  - `disable` — `dns_dnsmasq_restore` under lock + reload; `dns_iprule_clear`; stop stubby/DoH/watchdog; `dot_enabled=0`; `dns_active_tier` cleared.
  - `set-provider <name>` — validate; persist `dns_provider_prev`; set new; if enabled ⇒ `apply`+verify, on fail roll back to prev+verify, on second fail ⇒ plain + `dot_enabled=0`.
  - `_verify_encrypted` — returns 0 iff an encrypted listener resolves a control domain. Honors `AMNEZIA_VERIFY` override (`pass`/`fail`) for tests.

- [ ] **Step 1: Failing tests** — append to `test/unit/dns-ctl.bats`

```bash
@test "enable verifies through an encrypted listener (not #53)" {
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_VERIFY=pass sh '$CTL' enable"
  [ "$status" -eq 0 ]
  grep -q "nslookup .* 127.0.0.1#5453" "$STUB_LOG" || grep -q "127.0.0.1#5453" "$STUB_LOG"
  grep -q "set amnezia.config.dot_enabled=1" "$STUB_LOG"
}

@test "enable auto-reverts to plain when encrypted verify fails" {
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_VERIFY=fail sh '$CTL' enable"
  [ "$status" -ne 0 ]
  grep -q "set amnezia.config.dot_enabled=0" "$STUB_LOG"
  grep -q "delete dhcp.@dnsmasq\[0\].noresolv" "$STUB_LOG"
}

@test "disable restores resolvfile and clears the ip rule" {
  run sh -c "sh '$CTL' disable"
  [ "$status" -eq 0 ]
  grep -q "delete dhcp.@dnsmasq\[0\].noresolv" "$STUB_LOG"
  grep -q "rule del to 9.9.9.9" "$STUB_LOG" || grep -q "rule del to" "$STUB_LOG"
}
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement the verbs** — insert into `openwrt/amnezia-dns-ctl.sh` (before the `case`)

```sh
AMNEZIA_NSLOOKUP="${AMNEZIA_NSLOOKUP:-nslookup}"

_verify_encrypted() {
  [ -n "${AMNEZIA_VERIFY:-}" ] && { [ "$AMNEZIA_VERIFY" = pass ]; return; }
  for _l in "127.0.0.1#$DOT_PORT" "127.0.0.1#$DOH_PORT"; do
    "$AMNEZIA_NSLOOKUP" -timeout=3 openwrt.org "$_l" >/dev/null 2>&1 && return 0
  done
  return 1
}

cmd_disable() {
  dnsmasq_lock; dns_dnsmasq_restore; dns_dnsmasq_reload || true; dnsmasq_unlock
  _prov=$(uci -q get amnezia.config.dns_provider || echo quad9)
  dns_profile "$_prov" 2>/dev/null && dns_iprule_clear "$DNS_DOT_IP"
  "$AMNEZIA_STUBBY_INIT" stop 2>/dev/null || true
  "$AMNEZIA_DOH_INIT" stop 2>/dev/null || true
  "${AMNEZIA_DNS_INIT:-/etc/init.d/amnezia-dns}" stop 2>/dev/null || true
  uci set amnezia.config.dot_enabled=0
  uci -q delete amnezia.config.dns_active_tier
  uci commit amnezia
}

cmd_enable() {
  _has_bin || { echo "install stubby + https-dns-proxy first" >&2; return 1; }
  uci set amnezia.config.dot_enabled=1; uci commit amnezia
  cmd_apply || { cmd_disable; return 1; }
  if _verify_encrypted; then return 0; fi
  amz_log "dns: encrypted verify failed -> auto-revert"
  cmd_disable; return 1
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
git add openwrt/amnezia-dns-ctl.sh test/unit/dns-ctl.bats
git commit -m "feat(dns): enable/disable/set-provider with encrypted-tier verify + auto-revert"
```

---

## Task 6: Watchdog state machine (hysteresis) + `status`

**Files:**
- Modify: `openwrt/amnezia-dns-ctl.sh` (`cmd_watchdog`, `cmd_status`)
- Test: `test/unit/dns-watchdog.bats`

**Interfaces:**
- Produces:
  - `watchdog` — loop (interval `${AMNEZIA_DNS_WD_INTERVAL:-20}`s): probe both encrypted listeners; **enter** plaintext after `N=${AMNEZIA_DNS_WD_N:-3}` consecutive both-down; **exit** after `M=${AMNEZIA_DNS_WD_M:-2}` consecutive healthy **and** min dwell `${AMNEZIA_DNS_WD_DWELL:-120}`s. Each transition takes `dnsmasq_lock`, mutates plaintext `server=`, reloads, writes `dns_active_tier`. A `AMNEZIA_DNS_WD_ONCE=1` runs exactly one tick (test hook).
  - `status` — emit JSON `{enabled, provider, active_tier, encrypted, healthy}`; bounded probes (`nslookup -timeout=1`); never calls `apply`.

- [ ] **Step 1: Failing watchdog tests** — `test/unit/dns-watchdog.bats`

```bash
#!/usr/bin/env bats
load '../lib/harness.bash'
CTL="$HARNESS_DIR/../openwrt/amnezia-dns-ctl.sh"

@test "watchdog enters plaintext after N consecutive both-down probes" {
  run sh -c "AMNEZIA_DNS_WD_ONCE=1 AMNEZIA_DNS_WD_N=1 AMNEZIA_VERIFY=fail sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dns_active_tier=plaintext" "$STUB_LOG"
  grep -q "add_list dhcp.@dnsmasq\[0\].server=" "$STUB_LOG"
}

@test "watchdog stays encrypted while a tier is healthy (no plaintext, no flap)" {
  run sh -c "AMNEZIA_DNS_WD_ONCE=1 AMNEZIA_VERIFY=pass sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  run grep -q "dns_active_tier=plaintext" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "status emits bounded JSON and never calls apply" {
  run sh -c "AMNEZIA_VERIFY=pass sh '$CTL' status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"active_tier"'
  run grep -q "stubby restart" "$STUB_LOG"; [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement watchdog + status** — append to `openwrt/amnezia-dns-ctl.sh`

```sh
_enter_plain() {
  dnsmasq_lock; dns_dnsmasq_add_plain; dns_dnsmasq_reload || true; dnsmasq_unlock
  uci set amnezia.config.dns_active_tier=plaintext; uci commit amnezia
}
_exit_plain() {
  dnsmasq_lock; dns_dnsmasq_del_plain; dns_dnsmasq_reload || true; dnsmasq_unlock
  uci set amnezia.config.dns_active_tier=dot; uci commit amnezia
}

cmd_watchdog() {
  _n=${AMNEZIA_DNS_WD_N:-3}; _m=${AMNEZIA_DNS_WD_M:-2}
  _fail=0; _ok=0; _tier=$(uci -q get amnezia.config.dns_active_tier || echo dot)
  while :; do
    if _verify_encrypted; then
      _fail=0; _ok=$((_ok+1))
      [ "$_tier" = plaintext ] && [ "$_ok" -ge "$_m" ] && { _exit_plain; _tier=dot; }
    else
      _ok=0; _fail=$((_fail+1))
      [ "$_tier" != plaintext ] && [ "$_fail" -ge "$_n" ] && { _enter_plain; _tier=plaintext; }
    fi
    [ -n "${AMNEZIA_DNS_WD_ONCE:-}" ] && break
    sleep "${AMNEZIA_DNS_WD_INTERVAL:-20}"
  done
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
git commit -m "feat(dns): health-gated plaintext watchdog (hysteresis) + status JSON"
```

---

## Task 7: force-load shared-lock wrap (minimal, logic-neutral)

**Files:**
- Modify: `openwrt/amnezia-force-load.sh` (wrap the `uci commit dhcp`+restart region in the fd-8 lock)
- Test: `test/unit/dns-lock.bats` (append interleave assertion)

**Interfaces:**
- Consumes: `dnsmasq_lock`/`dnsmasq_unlock` from `amnezia-dns-lib.sh` (fd 8). force-load keeps its own fd-9 force-lock as the **outer** lock.

- [ ] **Step 1: Failing test — force-load takes the fd-8 dnsmasq lock around its dnsmasq restart** — append to `test/unit/dns-lock.bats`

```bash
@test "force-load wraps its dnsmasq restart in the shared fd-8 dnsmasq lock" {
  run grep -nE 'dnsmasq_lock|flock[[:space:]]+-x[[:space:]]+8' "$HARNESS_DIR/../openwrt/amnezia-force-load.sh"
  [ "$status" -eq 0 ]
  # force-load must NOT reuse fd 9 for the dnsmasq lock (fd 9 is its own force-lock)
  run grep -nE 'exec[[:space:]]+9>.*dnsmasq' "$HARNESS_DIR/../openwrt/amnezia-force-load.sh"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Source the dns-lib and wrap the restart** — `openwrt/amnezia-force-load.sh`

Near the top (after sourcing common), add a guarded source so force-load gains the lock helpers without hard-depending on them in dev:

```sh
[ -f "${AMZ_LIBDIR:-/usr/lib/amnezia}/amnezia-dns-lib.sh" ] && . "${AMZ_LIBDIR:-/usr/lib/amnezia}/amnezia-dns-lib.sh"
```

Wrap **only** the existing `uci commit dhcp` + `"$AMNEZIA_DNSMASQ_INIT" restart` region (around line 195–231) in the shared lock — outer force-lock (fd 9, already held) stays; inner is fd 8:

```sh
  command -v dnsmasq_lock >/dev/null 2>&1 && dnsmasq_lock
  uci commit dhcp
  # ... existing nftset confdir write ...
  "$AMNEZIA_DNSMASQ_INIT" restart 2>/dev/null || true
  command -v dnsmasq_unlock >/dev/null 2>&1 && dnsmasq_unlock
```

(No logic change: hash-gating, atomic `mv`, synchronous restart all untouched — only an additional advisory lock around the commit+restart.)

- [ ] **Step 4: Run to verify pass** — `bats test/unit/dns-lock.bats` → PASS; also re-run `bats test/unit/force-load.bats` to confirm no regression.

- [ ] **Step 5: Commit**

```bash
git add openwrt/amnezia-force-load.sh test/unit/dns-lock.bats
git commit -m "feat(dns): serialize force-load's dnsmasq restart on the shared fd-8 lock"
```

---

## Task 8: Persistence — init + firewall hotplug

**Files:**
- Create: `openwrt/amnezia-dns.init` → `/etc/init.d/amnezia-dns`
- Create: `openwrt/99-amnezia-dns.hotplug` → `/etc/hotplug.d/firewall/99-amnezia-dns`
- Test: `test/unit/dns-ctl.bats` (append init-behavior assertions) / lint via shellcheck suites

**Interfaces:**
- Consumes: `amnezia-dns-ctl apply` / `watchdog`.

- [ ] **Step 1: Failing test — init applies only when enabled and starts the watchdog** — append to `test/unit/dns-ctl.bats`

```bash
@test "init script: start runs apply + launches watchdog only when dot_enabled=1" {
  INIT="$HARNESS_DIR/../openwrt/amnezia-dns.init"
  grep -q "amnezia-dns-ctl apply" "$INIT"
  grep -q "procd_set_param command" "$INIT"
  grep -q "watchdog" "$INIT"
}
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Write the init** — `openwrt/amnezia-dns.init`

```sh
#!/bin/sh /etc/rc.common
# Encrypted-DNS boot apply + watchdog. Starts AFTER network/failover.
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

- [ ] **Step 4: Write the firewall hotplug** — `openwrt/99-amnezia-dns.hotplug`

```sh
#!/bin/sh
# Re-assert the DoT ip rule + refresh live provider IPs on firewall reload
# (proven trigger; sidesteps the awg ifup/ifupdate boot race).
[ "$ACTION" = reload ] || exit 0
[ "$(uci -q get amnezia.config.dot_enabled)" = 1 ] || exit 0
/usr/bin/amnezia-dns-ctl apply >/dev/null 2>&1 &
```

- [ ] **Step 5: Run to verify pass + shellcheck** — `bats test/unit/dns-ctl.bats` → PASS; `bats test/unit/shellcheck-phaseB.bats` stays green (add the new files to its file list if it enumerates).

- [ ] **Step 6: Commit**

```bash
git add openwrt/amnezia-dns.init openwrt/99-amnezia-dns.hotplug test/unit/dns-ctl.bats
git commit -m "feat(dns): boot init (apply+watchdog) + firewall-reload hotplug"
```

---

## Task 9: LuCI UI toggle + provider dropdown + warning, ACL

**Files:**
- Modify: `openwrt/luci-app-amnezia/view/main.js`
- Modify: `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json`
- Test: `test/unit/luci-js.bats`, `test/unit/acl.bats` (append)

**Interfaces:**
- Consumes: `fs.exec('/usr/bin/amnezia-dns-ctl', [...])`; `status` JSON.

- [ ] **Step 1: Failing ACL test** — append to `test/unit/acl.bats`

```bash
@test "acl grants exec on amnezia-dns-ctl under write.file" {
  run jsonfilter -i "$HARNESS_DIR/../openwrt/luci-app-amnezia/acl/luci-app-amnezia.json" \
    -e '@["luci-app-amnezia"].write.file["/usr/bin/amnezia-dns-ctl"][0]'
  [ "$output" = "exec" ]
}
```

- [ ] **Step 2: Failing UI test** — append to `test/unit/luci-js.bats`

```bash
@test "main.js wires the DoT toggle + provider dropdown to amnezia-dns-ctl" {
  JS="$HARNESS_DIR/../openwrt/luci-app-amnezia/view/main.js"
  grep -q "amnezia-dns-ctl" "$JS"
  grep -Eq "enable|disable" "$JS"
  grep -q "set-provider" "$JS"
  grep -q "active_tier" "$JS"   # plaintext warning surface
}
```

- [ ] **Step 3: Run to verify failure** — FAIL.

- [ ] **Step 4: Add the ACL entry** — `openwrt/luci-app-amnezia/acl/luci-app-amnezia.json`, in the existing `write.file` object:

```json
"/usr/bin/amnezia-dns-ctl": [ "exec" ]
```

- [ ] **Step 5: Add the UI controls** — `openwrt/luci-app-amnezia/view/main.js`

Add a DNS section near the routing-mode block, mirroring the `set-routing-mode` handler at `main.js:866`. A toggle calling `enable`/`disable`, a `<select>` of the six profiles calling `set-provider`, and a status line that reads `amnezia-dns-ctl status` and renders a warning when `active_tier === 'plaintext'`:

```javascript
function setDot(on) {
  return fs.exec('/usr/bin/amnezia-dns-ctl', [ on ? 'enable' : 'disable' ]).then(function(res) {
    if (res.code !== 0) ui.addNotification(null, E('p', {}, _('DoT change failed: ') + (res.stderr||'')), 'danger');
    return refreshDnsStatus();
  });
}
function setDnsProvider(name) {
  return fs.exec('/usr/bin/amnezia-dns-ctl', [ 'set-provider', name ]).then(refreshDnsStatus);
}
function refreshDnsStatus() {
  return fs.exec('/usr/bin/amnezia-dns-ctl', [ 'status' ]).then(function(res) {
    var st = {}; try { st = JSON.parse(res.stdout||'{}'); } catch(e) {}
    var warn = (st.active_tier === 'plaintext');
    // render toggle state = st.enabled, select value = st.provider, and a
    // visible warning banner when warn (encrypted DNS unavailable -> plaintext).
    renderDnsRow(st, warn);
  });
}
```

(Match the file's existing `E(...)`/`L.bind` rendering idiom for `renderDnsRow`; the provider `<select>` options are `quad9, adguard, dns0, mullvad, google, custom`, with help-text on `google` = "large US provider".)

- [ ] **Step 6: Run to verify pass** — `bats test/unit/acl.bats test/unit/luci-js.bats` → PASS.

- [ ] **Step 7: Commit**

```bash
git add openwrt/luci-app-amnezia/view/main.js openwrt/luci-app-amnezia/acl/luci-app-amnezia.json test/unit/acl.bats test/unit/luci-js.bats
git commit -m "feat(dns): LuCI DoT toggle + provider dropdown + plaintext warning + ACL"
```

---

## Task 10: Installer + sync-to-packages + packages mirror

**Files:**
- Modify: `openwrt/install-amnezia-pbr.sh` (opkg install + place new files)
- Modify: `dev/sync-to-packages.sh` (mirror new files; add `hotplug.d/firewall` already exists, add CLI/lib/init/config/ACL)
- Generated: `packages/...` mirror via the sync script
- Test: `test/unit/sync.bats`, `test/unit/packaging.bats` (append)

**Interfaces:** none new — wiring only.

- [ ] **Step 1: Failing sync test** — append to `test/unit/sync.bats`

```bash
@test "sync mirrors the new DNS files into packages/" {
  bash "$HARNESS_DIR/../dev/sync-to-packages.sh" >/dev/null 2>&1 || true
  for f in usr/bin/amnezia-dns-ctl usr/lib/amnezia/amnezia-dns-lib.sh \
           etc/init.d/amnezia-dns etc/hotplug.d/firewall/99-amnezia-dns; do
    [ -e "$HARNESS_DIR/../packages/amnezia-pbr/files/$f" ] || { echo "missing $f"; false; }
  done
}
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Extend the installer** — `openwrt/install-amnezia-pbr.sh`

Before any dnsmasq mutation (near the existing `opkg update`/install block ~line 1108), add a guarded install on the working resolver:

```sh
for pkg in stubby https-dns-proxy; do
  opkg list-installed 2>/dev/null | grep -q "^$pkg " || opkg install "$pkg" || amz_log "dns: opkg install $pkg failed (DoT optional)"
done
```

Place the new runtime files (CLI → `/usr/bin`, lib → `/usr/lib/amnezia`, init → `/etc/init.d`, hotplug → `/etc/hotplug.d/firewall`) alongside the existing file-placement steps, `chmod +x` the CLI/init/hotplug, and `/etc/init.d/amnezia-dns enable`.

- [ ] **Step 4: Extend the sync script** — `dev/sync-to-packages.sh`

Add the new files to the explicit copy list (CLI to `usr/bin/amnezia-dns-ctl`, lib to `usr/lib/amnezia/amnezia-dns-lib.sh`, init to `etc/init.d/amnezia-dns`, hotplug to `etc/hotplug.d/firewall/99-amnezia-dns`, ACL + config into the luci-app + base trees). `hotplug.d/firewall` mkdir already exists; no new dir needed.

- [ ] **Step 5: Run the sync, verify pass** — `bash dev/sync-to-packages.sh && bats test/unit/sync.bats test/unit/packaging.bats` → PASS.

- [ ] **Step 6: Full suite + shellcheck** — `bats test/unit/` → all green.

- [ ] **Step 7: Commit**

```bash
git add openwrt/install-amnezia-pbr.sh dev/sync-to-packages.sh packages/ test/unit/sync.bats test/unit/packaging.bats
git commit -m "feat(dns): installer opkg+place, sync openwrt<->packages parity"
```

---

## Out of scope for these phases (design doc → live-only gates)

These are **not** unit-testable (the VM's dnsmasq doesn't serve real queries) and are executed during live-router bring-up, each preceded by its rollback + WAN/DNS/handshake check:
- **Leak test:** `tcpdump` WAN `:53` with tier-1 stalled → zero cleartext until the watchdog deliberately gates plaintext.
- **nftset tagging:** resolve a force-listed domain under DoT → IP lands in `amnezia_force4` and routes through the tunnel.
- **Failover interaction:** force a sticky failover → DNS continues via the new sticky tunnel.
- **Enable auto-revert (live):** `enable` against a deliberately-broken endpoint → auto-revert to plain.
- **Per-profile IP pin:** confirm each profile's two resolver anycast IPs against provider docs + a live probe; drop any that can't satisfy the distinct-IP / cert invariant.
- **Plan-time pins:** exact stubby/dnsmasq timeouts, watchdog `N`/`M`/dwell, reload-wait-under-lock decision, v6 LAN posture.

---

## Self-review notes

- **Spec coverage:** chain (T3/T4), two-distinct-IP invariant (T1), no-Cloudflare (T2), encrypted-tier verify + auto-revert (T5), watchdog+hysteresis (T6), shared fd-8 lock incl. force-load (T3/T7), `--test` gate + stub upgrade (T3), persistence (T8), UI+ACL (T9), installer/sync/packages (T10), live-only gates (listed, deferred). All design sections map to a task.
- **Type/name consistency:** `dns_profile` outputs (`DNS_DOT_IP`/`DNS_DOT_HOST`/`DNS_DOH_HOST`/`DNS_DOH_BOOTSTRAP`), `RULE_PREF_DOT=30900`, ports 5453/5454, lock fd 8, `dns_active_tier` values `dot|doh|plaintext` — used identically across T1–T9.
- **Test override env vars** (`AMNEZIA_HAS_BIN`, `AMNEZIA_VERIFY`, `AMNEZIA_*_INIT`, `AMNEZIA_DNS_WD_*`, `AMNEZIA_DNSMASQ_TESTCONF`) are declared in the task that introduces them and reused consistently.
