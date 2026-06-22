# Deep Review — Multi-tunnel AmneziaWG failover

**Date:** 2026-06-15 · **Branch:** `feat/multi-tunnel-failover` (51 commits, 95 files) · **Base:** main
**Workflow:** 8 generic + 3 feature dimensions, adversarially verified. 28 raw → 23 confirmed → **12 CRITICAL/HIGH**.

## Root-cause grouping

Six of the twelve C/H share ONE root cause: the `packages/<pkg>/files/` tree (built into the `.ipk` via the Makefile `$(CP) ./files/.`) was last regenerated at commit `87f1a85`, BEFORE the entire fix series. `sh dev/sync-to-packages.sh` produces a +326/−98 diff across 6 files → the shipped artifact still carries the pre-fix bugs (inverted ping, PSK leak, probe collision, missing `routing_firewall_apply`, stale migration). **Fix = run the sync and commit `packages/`, as the FINAL step after all `openwrt/` source fixes.**

## CRITICAL/HIGH findings

| # | Sev | Dimension | Fix |
|---|-----|-----------|-----|
| 1 | CRITICAL | spec-compliance | **Entrypoint never wires the new stack.** `install.sh`/`amnezia-pbr-setup` (no-arg, STEPS=3) falls into the legacy pbr path (now broken — templates dropped, `pbr` removed from DEPENDS); `first_install_wiring`/`migrate_from_pbr` have no caller. Rewire the entrypoint to invoke the new stack; preserve zapret/base setup. |
| 2 | CRITICAL | correctness | **RU reload hooks call `/usr/sbin/amnezia-ru-cidr`** but it ships at `/usr/bin/` → set never repopulated at boot/`fw4 reload`. Fix hook paths. |
| 3 | CRITICAL | correctness | Stale `packages/` tree (root cause). Re-sync. |
| 4 | CRITICAL | security | **Root command injection** in `parse_awg_conf`: `eval "AWG_${_k}=\$_v"` with unvalidated key from untrusted `.conf`. Allowlist `_k` before eval. |
| 5 | CRITICAL | concurrency | Stale `packages/` tree (root cause). Re-sync. |
| 6 | CRITICAL | regression-parity | Stale `amnezia-pbr-setup` in package (root cause). Re-sync. |
| 7 | HIGH | spec-compliance | **Failover conntrack flush only fires on all-down**, not on a normal awg1→awg2 switch (`[ -z "$_pool" ]` conjunct) → flows stranded on dead tunnel. Flush whenever `_changed=1` in failover mode. |
| 8 | HIGH | error-resources | Legacy path `chmod 755 /etc/pbr.d/ru-direct.sh` unconditional under `set -eu`; file no longer shipped → install aborts. Subsumed by #1 entrypoint rewire (legacy path retired) or guard the chmod. |
| 9 | HIGH | interface-contract | **Dead pbr panel:** ACL revoked `pbr-status`/`pbr-reload` exec + binaries deleted, but `main.js` still calls them → "Reload PBR" always errors, status stuck "pbr: unknown". Remove the pbr panel section from `main.js`. |
| 10 | HIGH | tests-quality | **False-green:** bats runs `openwrt/` source, ships `packages/`. Add a non-destructive drift check; re-sync. |
| 11 | HIGH | regression-parity | Stale `amnezia-routing.sh` in package (root cause). Re-sync. |
| 12 | HIGH | regression-parity | Stale `amnezia-failover` daemon in package (root cause). Re-sync. |

## MEDIUM/LOW (fixed opportunistically, non-gating)

- MED: balance per-member flush descoped vs design — ratify in design "Out of scope".
- MED: listener process-group kill assumes `setsid` not actually used → orphan `ubus listen`. Add busybox `setsid` or kill pipeline children.
- MED: `handshake_age` `-1`/`0` sentinels render as "-1s ago"/"never" in panel — fix `fmtAge` usage.
- MED: per-tunnel state contract declared but never validated (dead `state-schema.json`). [defer]
- LOW: migrate runs `configure-dnsmasq-amnezia.sh` twice → double dnsmasq restart. Remove redundant `set -e` delete+rerun.
- LOW: `member_ctmark()` dead code.
- LOW: `amnezia-failover-ctl` set-weight/toggle interpolate unvalidated `$2`/`$3` into uci key. Validate `^awg[0-9]+$` / `^[0-9]+$`.
- LOW: `amnezia-ru-cidr` feeds unparsed feed lines into `nft add element`. Validate CIDR shape.
- LOW: non-atomic state write races LuCI reader. Write temp + `mv`.
- LOW: sticky input prefills from `active_sticky` (effective), can overwrite configured `sticky_target`. [defer — needs JSON to expose configured value]
- LOW: `sync.bats` only greps the script text, never checks tree drift.
