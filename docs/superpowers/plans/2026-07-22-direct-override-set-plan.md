# Direct-override set (`amnezia_direct4`) — Implementation Plan (express)

Design: `docs/superpowers/specs/2026-07-22-direct-override-set-design.md`. Read it first.

**Global constraints:** POSIX sh / BusyBox ash only. Never break client internet —
change is additive. `uci -q get` for values (never grep|sed). Stubs must mirror real
`nft`/`dnsmasq`/`uci` output. Keep `openwrt/ ↔ packages/` in sync (last step).
Source of truth is `openwrt/`.

## Phase 1 — classifier set + override rule (both templates)

**Files:** `openwrt/nftables.d/30-amnezia-classify.nft`,
`openwrt/nftables.d/30-amnezia-classify-direct.nft`.

- In **each** template, add the set declaration next to the others:
  `set amnezia_direct4  { type ipv4_addr; flags interval; auto-merge; }`
- In **each** `chain amnezia_classify`, insert immediately after the
  `iifname != "@@LAN_IFNAME@@" return` line:
  `ip daddr @amnezia_direct4 return   # direct-override: WAN, wins over force/sticky`
- Ordering is load-bearing: the direct rule MUST precede the `amnezia_sticky4` and
  `amnezia_force4` rules in both files.

## Phase 2 — populate `amnezia_direct4` from `direct-tunnel.list`

**Files:** `openwrt/amnezia-force-load.sh`, new `openwrt/direct-tunnel.list`.

- Extract the existing per-set body (classify merged entries into IP/CIDR vs domain →
  batch-load IPs into the set → write byte-chunked `nftset=…/4#inet#fw4#<set>`
  directives to a conf file → compute/compare a domain-hash) into a shell function
  parameterised by `set_name`, `conf_file`, `hash_file`, and the list of source files.
  Preserve every existing safety property: flock (fd 9), add-only unless `--flush`,
  atomic `mv`, octet validation, `save-manual` (force-only).
- Call the function twice inside the single flock:
  - force4: sources `force.d/*.list` + `force-tunnel.list`, conf `amnezia-force.conf`,
    hash `.force-domains.hash` (behaviour byte-identical to today).
  - direct4: source `direct-tunnel.list`, conf `amnezia-direct.conf`, hash
    `.direct-domains.hash`.
- Fire **one** `dnsmasq restart`, only if **either** hash changed (keep it inside the
  dnsmasq lock as today). Confdir wiring stays as-is (both conf files live in the
  same `AMZ_DNSMASQ_CONFDIR`).
- `direct-tunnel.list`: new file seeded with a single line `chat.google.com`.

**Verify:** `bats test/unit/direct-override.bats` (Phase 4) + existing
`test/unit/force-load*.bats` / `autotunnel.bats` still green.

## Phase 3 — warm, CLI, installer

**Files:** `openwrt/amnezia-force-warm.sh`, `openwrt/amnezia-failover-ctl.sh`,
`openwrt/install-amnezia-pbr.sh`.

- **warm:** after the existing `force-tunnel.list` re-resolve loop, add an identical
  loop over `direct-tunnel.list` (guard `[ -f … ]`, same wave/timeout logic, resolver
  `127.0.0.1`). Refactor the loop body into a helper if it keeps it DRY; otherwise a
  second guarded loop is fine.
- **CLI verbs** in the case dispatch:
  - `direct-add <domain>`: validate (reject empty/garbage; accept domain or IP/CIDR),
    append to `direct-tunnel.list` if not already present, `amnezia-force-load`,
    then `timeout 5 nslookup <domain> 127.0.0.1` once. Print
    `{"domain":"…","result":"added|already-present"}`.
  - `direct-remove <domain>`: remove matching line, `amnezia-force-load --flush`.
    Print `{"domain":"…","result":"removed|not-found"}`.
  - `direct-list`: cat the list (skip comments/blanks).
- **installer:** mirror the `force-tunnel.list` seed block (lines ~315-328) for
  `direct-tunnel.list` — create-if-absent from the shipped seed else `touch`,
  `chmod 0644`.

## Phase 4 — tests

**File:** new `openwrt`-agnostic `test/unit/direct-override.bats` (mirror existing
bats style + stubs in `test/stubs/`).

Cases (see design §Testing): (1) both templates declare the set and order the direct
rule before force; (2) force-load populates `amnezia_direct4` from `direct-tunnel.list`
(IP→set, domain→`#amnezia_direct4` conf line); (3) a domain in both lists yields both
directives + structural precedence; (4) force4 regression unchanged; (5)
`direct-add`/`direct-remove` mutate the list and call force-load; (6) empty list →
empty `amnezia-direct.conf`.

## Phase 5 — sync

`sh dev/sync-to-packages.sh` then confirm `git status` shows the mirrored
`packages/**` changes; commit. CI sync-check must pass.

## Done-criteria

- `bats test/unit/` all green (new + regression).
- Both classifier templates: `amnezia_direct4` declared, override rule before force.
- `openwrt/ ↔ packages/` in sync.
- Commits are logically grouped; branch ready for deep-review + live smoke.
