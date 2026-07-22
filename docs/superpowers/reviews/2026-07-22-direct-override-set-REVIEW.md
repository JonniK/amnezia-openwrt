# Direct-override set — Deep Review

**Branch:** `feat/direct-override-set` · **Reviewed:** `main..HEAD` · express mode, 2 opus reviewers (force-load refactor lens + classifier/integration lens).

## Confirmed findings

### HIGH — `--flush` global across both nft sets (FIXED, commit 5f126b0)
Both reviewers independently confirmed. The refactor's `_amz_populate_set()` consulted a
single global `_do_flush`, so `amnezia-force-load --flush` flushed **both**
`amnezia_force4` and `amnezia_direct4`. `direct-remove` → `--flush` therefore flushed
`amnezia_force4`, evicting runtime-resolved CDN IPs and stripping the fwmark from
ESTABLISHED flows to RU-blocked hosts (the documented add-only footgun / "never break
client internet"). Also fired on a `not-found` no-op.

**Fix:** set-scoped flush. `--flush` → force4 only; new `--flush-direct` → direct4 only;
`_amz_populate_set` takes the flush decision per call. `direct-remove` uses
`--flush-direct` and no-ops entirely when the domain is `not-found`. Existing `--flush`
callers (force-update, app-ctl, set-routing-mode) unchanged. Regression tests added
(direct-remove flushes only direct4; `--flush` flushes only force4; not-found = no-op).

### MEDIUM — cross-set flush coupling (resolved by the HIGH fix)
Existing `--flush` callers would have transiently flushed direct4. Eliminated by the
set-scoped fix.

### LOW — `_ctl_direct_valid` accepted leading `-`/`/` (FIXED, [autofix])
`direct-add -x` could reach `nslookup -x` / emit a malformed `nftset=/-x/…` directive
(force-load's dnsmasq restart has no health-check/rollback → DNS-outage vector).
Validator tightened to reject leading dash/slash and require domain or IPv4/CIDR shape.
Also: `direct-add` skips force-load on `already-present`.

## Cleared (checked, no finding)
Classifier ordering/semantics (direct rule before sticky4/force4 in both mode
templates; unmarked `return` → WAN; fw4-include shape valid, both modes); input
validation/injection; exact-match dedup/removal; force-warm exit-gate; installer
idempotency; tests genuine (not tautological); openwrt↔packages sync.

**Outcome:** 0 open CRITICAL/HIGH. 700/700 bats green.
