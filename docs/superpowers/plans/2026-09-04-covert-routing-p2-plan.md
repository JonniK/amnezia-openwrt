# Covert routing (P2) — classify the creator's egress like a LAN client

**Goal.** Traffic the covert creator (uid `amnezia-covert`) forwards for the
joiner must be classified exactly like a LAN client's: by the **active
`routing_mode`**, default direct, list-matched destinations through the
tunnels. Auto-on with covert (no separate toggle).

## Spike result (live router, 2026-09-04) — mechanism PROVEN

- A `type route hook output priority mangle` chain that sets `meta mark
  0x0a0000/0x0b0000` on router-origin packets triggers route reselection;
  the existing ip rules 31000/31001 send them through the tunnels
  (exit-ip flipped 5.166.4.4 -> 104.168.65.30 pool). `srcnat_vpn`
  masquerades the awgN egress, so the router's WAN source address is a
  non-issue. Verified with a `--resolve`-pinned probe (an unpinned probe
  is worthless here — ipify sits behind Cloudflare and rotates IPs).
- `meta skuid <uid>` matches the creator's own output packets (121 pkts/8s).
- VK + its TURN servers are already in `amnezia_ru4` (VK is Russian), so
  mirroring the LAN classifier keeps the cover traffic direct automatically.

## Design — DRY derivation, LAN classifier untouched

The covert marking is **identical** to the LAN classifier's; only the gate
and hook differ. So derive it from the same mode template — never duplicate
the mark logic (no drift).

New `routing_emit_covert_classifier <mode> <lan> <uid>` in
`lib/amnezia-routing.sh`: pipe `routing_emit_classifier <mode> <lan>` through
sed to (a) drop the `set amnezia_*` decls (already declared by the LAN
classifier — redeclaring errors), (b) rename chain -> `amnezia_covert_classify`,
(c) `type filter hook prerouting priority mangle` -> `type route hook output
priority mangle`, (d) gate `iifname != "<lan>" return` -> `meta skuid !=
<uid> return`. Emitted to `/etc/nftables.d/41-amnezia-covert-classify.nft`.

The LAN classifier (`30-amnezia-classify*.nft`) — the "never break client
internet" path — is NOT restructured. A unit test asserts the covert chain's
mark lines are byte-identical to the LAN classifier's, catching any drift.

The existing `40-amnezia-covert-egress.nft` (type filter, the uid egress
fence) is unchanged. The new `41-` chain is a separate marking chain.

## Wiring

- `covert-ctl` enable/apply: generate `41-` alongside `40-`, inside the same
  snapshot -> mv -> `fw4 check` -> restore-or-leave -> reload safety dance.
  disable: remove both, reload.
- `failover-ctl set-routing-mode`: after regenerating the LAN classifier, if
  covert is enabled, regenerate `41-` too, so both land in one fw4 reload.
- Launcher/init unchanged (the chain is uid-scoped, independent of the pid).

## Tests / gates

- Unit: `routing_emit_covert_classifier` for both modes (chain name, hook,
  skuid gate, uid substitution, no `set` decls); mark-lines == LAN
  classifier's (anti-drift); covert-ctl generates/removes `41-`; fw4 stubs.
- VM gate: `41-` generates, `fw4 check` passes, teardown removes it.
  (The VM has no real tunnels — actual egress routing is a live-only check,
  already proven in the spike and re-verified after apply.)
- Live: backup + emergency ready; apply; verify WAN/DNS/creator connected;
  re-confirm a force4 dest tunnels for uid and RU/VK stays direct.

## LuCI

The panel text "Does not participate in tunnel/DNS routing" is now false for
the data path. Update to reflect: covert egress is classified like LAN
(default direct, lists tunneled); DNS via the router's dnsmasq.

## Delivery

Commits appended to PR #27 (per user's choice).
