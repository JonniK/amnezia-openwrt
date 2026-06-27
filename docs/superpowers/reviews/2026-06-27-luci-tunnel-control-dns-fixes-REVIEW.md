# Deep Review — LuCI tunnel control, DoT fixes, exit-IP, master switch

**Date:** 2026-06-27 · **Branch:** `feat/luci-tunnel-control-dns-fixes` · **Diff:** `main..HEAD` (13 commits, ~1230 lines)

Two-lens adversarial deep review of the integrated whole (after per-phase reviews cleared each slice). Verdict: **0 CRITICAL, 1 HIGH (fixed), all MEDIUM/LOW dispositioned.** All six design items confirmed delivered end-to-end; `openwrt/↔packages/` parity holds; 440 unit tests + 4 JS-harness gates green.

## Confirmed findings (fixed in `43f0adb`)

| Sev | Finding | Fix |
|---|---|---|
| HIGH | Orphan exit-IP cache survived `amnezia-tunnel-ctl remove` → a re-added slot showed the **previous tenant's** exit IP for up to TTL (privacy/correctness). | `tunnel-ctl` remove now clears `exitip.<awgN>.{ip,ts}` + debounce state; daemon seed clears cache for first-seen slots. |
| MED | `test/stubs/curl` claimed to validate the tunnel binding but didn't → Item 5's egress-safety property (`--interface if!awgN`) was **unproven** by the green test (the repo's #1 scar class). | Stub now `exit 3` in probe-mode when `--interface if!` is absent → the daemon's binding is actually asserted. |
| MED | `master off` relied on `dns-ctl disable`'s side effect to drop the pref-30900 DoT rule; if `disable` failed, the rule stranded against a flushed table 100 (technical fail-open violation). | `master off` now calls `dns_iprule_flush` unconditionally after `disable`. |
| MED | `master off` left a stale `/var/run/amnezia-failover.json` → the dimmed accordion dishonestly showed tunnels "UP" under the "routing disabled" strip. | `master off` removes `$STATE_FILE` → table honestly shows "No tunnel state available". |
| MED | `_refresh_exit_ips` test only asserted `exit 0`. | Added a test asserting the probe worker actually writes the cache (content == probed IP). |
| LOW | Stale `# exit_ip is deferred…` comment; `master on` cold-start verify could log a false "FAILED" before the first poll/handshake. | Comment deleted; `master on` verify retries 3×2s before logging. |

## Verified clean (no finding)
Fail-open master-off contract (only removes policy routing → WAN direct; `fw4 reload` can't resurrect the master-gated init's ip rules); force-pin × sticky independence; force-pin fail-closed scoped to the pool only (never strands all internet); `make-default` hide logic vs null `active_pool` (no deref); older-daemon JSON degrade (undefined fields → banner hidden, `—` shown); `data[]` index 10/11 append shifts nothing; no refresh→exec→refresh storm; curl-stub dual-mode preserves zapret-probe/force-update behavior; dns.js activeElement guard preserved.

## ⚠️ Device smoke-test checklist (live-only — MUST verify on the AX3000T before/at deploy)
The unit suite cannot prove these; verify on the router (SSH `openWRT`, LAN-side recovery channel; backup first):

1. **Real exit-IP egress** — each UP tunnel shows a *different/expected* public IP (proves `curl --interface if!awgN` egresses through the tunnel, not WAN).
2. **`flock` presence on BusyBox** — `command -v flock` on the router. If ABSENT, `_refresh_exit_ips` silently no-ops (exit-IP column stays `—` forever) — would then need the `mkdir`-mutex fallback. **This is the highest-priority device check.**
3. **Master-OFF teardown** — `master off` → confirm LAN keeps internet via WAN-direct, fwmark prefs 31000/31001 + pref-30900 gone, tables 100/101 empty; then `fw4 reload` does NOT resurrect routing.
4. **Master-OFF reboot persistence** — reboot with master OFF → daemon does not start, internet stays WAN-direct, DoT/autolearn stay off; `master on` restores the full stack (incl. the snapshotted DoT/autolearn preference).
5. **DoT enable/disable** under `master on/off` — real timing (nslookup-bounded verify).
6. **make-default `_restart_monitor`** brief rules-gone window (force-pin avoids it via the `immediate` trigger; make-default uses the restart path — confirm acceptable).

## Deferred (logged, non-gating)
Accordion dim is CSS-only (keyboard could fire inert handlers against the gated daemon — buttons could also set `disabled`); a redundant inline reconcile-read test; background-probe child reaping. None affect connectivity or correctness.
