# LuCI Modular Accordion — Deep Review (Stage 8)

**Date:** 2026-06-23 · **Branch:** `feat/luci-modular-accordion` · **Surface:** `main..HEAD` (12 commits, 23 files)
**Workflow:** 11 lenses (8 generic + 3 refactor-specific), each finding adversarially refuted.

**Verdict:** **0 CRITICAL / 0 HIGH** confirmed (cycle-1 clean → converged). 7 MEDIUM/LOW confirmed, all tracing to **two** root issues — both fixed in `265b6ee`.

## Confirmed findings & disposition

| # | Sev (orig) | Dimension(s) | Issue | Disposition |
|---|---|---|---|---|
| 1 | MED (HIGH) | error-resources, interface-contract, spec-compliance, concurrency, regression-parity (×5 reports, same root) | **DNS poll-leg lost its `L.resolveDefault` guard.** Original monolith had `p8 = L.resolveDefault(refreshDnsStatus(), null)` — the *only* guard, since `refreshDnsStatus()` is internally unguarded. Refactor returned it bare → on a router without `amnezia-dns-ctl` (supported degraded state, DoT default-OFF), the exec rejects → shell `Promise.all` short-circuits → unhandled rejection every 5s. Real behavior regression vs the zero-change contract. | **FIXED** `265b6ee`: `dns.refresh` now `return L.resolveDefault(refreshDnsStatus(), null)` — self-guards like all 4 sibling legs. |
| 2 | MED | tests-quality | **Harness never executed any `refresh()`** — the one cross-module coupling had zero runtime coverage (which is why it missed #1). | **FIXED** `265b6ee`: harness rejection-mode self-test reloads all section modules with a rejecting `fs` stub and asserts every `refresh()` still resolves. Teeth-proven: exits 1 without the guard, 0 with it. |
| 3 | MED | tests-quality | `main.render` invoked with the view object as the `data` arg (shell render is `render(data)`, 1-arg LuCI signature) → render exercised against garbage data. | **FIXED** `265b6ee`: `main.render.call(main, DATA)`. |

## Adversarially refuted (not confirmed)

The refuter downrated the DNS finding HIGH→MEDIUM (poller is not torn down by a rejected step; other panels keep updating; effect is a console rejection + unpainted DNS row on DoT-less routers — degraded UX, not internet/correctness/security). No correctness, security, or concurrency defect survived refutation. The behavior-parity lens confirmed: verbatim moves, `candidatesSig` seed present, DoT focus-guard + both failover→routing `activeElement` guards preserved, `#failover-tunnel-table` sentinel intact, load() bundle indices correctly mapped. Delivery-surface lens confirmed all 4 surfaces ship to `resources/amnezia/` with modules-before-main ordering.

## Post-fix state

`node --check` all 7 JS files clean · `node test/lib/luci-harness.js` → `harness ok: modules=6 panels=5 details=12` + `refresh-reject-safe ok` · `bats test/unit/luci-js.bats` 38/38 · sync parity `git diff --quiet -- packages/` exit 0.
