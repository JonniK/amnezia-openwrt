# Multi-tunnel failover — Manual Hardware Spike Runbook (Tier 3)

> **NOT run by the CI pipeline.** This is the backup-gated, manual validation
> sequence executed on the live router by the developer + agent. Complete every
> numbered step in order. Never skip the backup step.

---

## Prerequisites

- Router: AX3000T (MT7981) with AmneziaWG kmod installed
- At least two AWG configs: `/etc/amnezia/awg1.conf` and `/etc/amnezia/awg2.conf`
- SSH alias `openwrt` configured (see `dev/` workflow notes)
- `zapret` already installed and running

---

## Step 1 — Backup FIRST (mandatory gate)

```sh
sh dev/openwrt-backup.sh before-multitunnel-spike
```

Verify the archive exists and is timestamped with `before-multitunnel-spike`.
**Do not proceed without a valid backup.**

---

## Step 2 — Verify baseline (before any changes)

```sh
ssh openwrt 'uci show amnezia; ip rule show; nft list ruleset | grep amnezia || echo NONE'
ssh openwrt 'ping -c3 8.8.8.8 -I br-lan; curl -s -o /dev/null -w "%{http_code}" https://yandex.ru'
```

Expected: existing pbr routes active, yandex.ru reachable, 8.8.8.8 pingable.

---

## Step 3 — Install routing tables

```sh
scp openwrt/iproute2-amnezia-rt_tables.conf openwrt:/etc/iproute2/rt_tables.d/amnezia.conf
ssh openwrt 'cat /etc/iproute2/rt_tables.d/amnezia.conf'
```

Expected output:
```
100 vpn_sticky
101 vpn_pool
```

---

## Step 4 — Install ip rules (masked fwmark)

```sh
ssh openwrt '
  ip rule add fwmark 0x0a0000/0x0ff0000 lookup 100 2>/dev/null || true
  ip rule add fwmark 0x0b0000/0x0ff0000 lookup 101 2>/dev/null || true
  ip rule show | grep -E "0x0[ab]0000"
'
```

Expected: two lines with `lookup 100` and `lookup 101`.

---

## Step 5 — Install and activate the nft classifier

```sh
LAN_DEV=$(ssh openwrt 'uci get network.lan.device 2>/dev/null || echo br-lan')
sed "s/@@LAN_IFNAME@@/$LAN_DEV/" openwrt/nftables.d/30-amnezia-classify.nft | \
  ssh openwrt 'cat > /etc/nftables.d/30-amnezia-classify.nft'

# Stage the reload in the background to avoid killing the SSH session
ssh openwrt 'nft -c -f /etc/nftables.d/30-amnezia-classify.nft && echo SYNTAX_OK'
ssh openwrt '( sleep 2 && fw4 reload ) &'
sleep 5
ssh openwrt 'nft list chain inet fw4 amnezia_classify && echo CHAIN_OK'
```

---

## Step 6 — Bring up second tunnel (awg2)

```sh
scp openwrt/config/amnezia openwrt:/tmp/amnezia-new.conf
ssh openwrt '
  # Add awg2 interface (copy awg1 params, adjust addresses)
  uci set network.awg2=interface
  uci set network.awg2.proto=amneziawg
  uci set network.awg2.private_key="$(awk -F= "/PrivateKey/{print \$2}" /etc/amnezia/awg2.conf | tr -d " ")"
  # ... (fill from awg2.conf fields)
  uci commit network
  ( sleep 1 && ifup awg2 ) &
'
sleep 5
ssh openwrt 'ip link show awg2; awg show awg2 latest-handshakes'
```

---

## Step 7 — Verify RU-direct still works (zapret coexistence)

```sh
ssh openwrt 'curl -s -o /dev/null -w "HTTP %{http_code}\n" --interface br-lan https://yandex.ru'
```

Expected: HTTP 200. Traffic should leave via wan (not via VPN), marked `0x0` (unmatch in ru4 set means bypass).

---

## Step 8 — Verify amnezia_block_quic rule survived

```sh
ssh openwrt 'uci show firewall.amnezia_block_quic && echo QUIC_OK'
```

Expected: rule present and intact. If absent, run rollback (Step 13).

---

## Step 9 — Install monitor daemon

```sh
scp openwrt/amnezia-failover openwrt:/usr/sbin/amnezia-failover
scp openwrt/amnezia-failover.init openwrt:/etc/init.d/amnezia-failover
ssh openwrt 'chmod 0755 /usr/sbin/amnezia-failover /etc/init.d/amnezia-failover'
scp openwrt/lib/amnezia-common.sh openwrt:/usr/lib/amnezia/amnezia-common.sh
scp openwrt/lib/amnezia-routing.sh openwrt:/usr/lib/amnezia/amnezia-routing.sh
ssh openwrt '
  mkdir -p /usr/lib/amnezia
  /etc/init.d/amnezia-failover enable
  ( sleep 1 && /etc/init.d/amnezia-failover start ) &
'
sleep 5
ssh openwrt 'cat /var/run/amnezia-failover.json 2>/dev/null || echo STATE_MISSING'
```

---

## Step 10 — Simulate failover: pull tunnel 1

```sh
# Record current pool default
ssh openwrt 'ip route show table 101'

# Pull awg1 down
ssh openwrt 'ifdown awg1'
sleep 10  # wait for debounce (3 × health interval ≈ 9s)

# Assert pool moved to awg2
ssh openwrt 'ip route show table 101 | grep "default dev awg2"'
ssh openwrt 'cat /var/run/amnezia-failover.json'
```

Expected: `default dev awg2 table 101` present. State JSON shows `active_pool: "awg2"` and `all_down: false`.

---

## Step 11 — Verify fail-closed (pull awg2 too)

```sh
ssh openwrt 'ifdown awg2'
sleep 10

# Both blackhole
ssh openwrt 'ip route show table 101 | grep blackhole'
ssh openwrt 'ip route show table 100 | grep blackhole'
ssh openwrt 'cat /var/run/amnezia-failover.json | grep all_down'
```

Expected: `blackhole default` in both tables. `all_down: true` in JSON.

---

## Step 12 — Verify failback (restore awg1)

```sh
ssh openwrt 'ifup awg1'
sleep 10

ssh openwrt 'ip route show table 101 | grep "default dev awg1"'
ssh openwrt 'cat /var/run/amnezia-failover.json | grep active_pool'
```

Expected: pool returns to awg1 (metric 1, lower than awg2 metric 2).

---

## Step 13 — Rollback (if anything is broken)

```sh
sh dev/openwrt-restore.sh before-multitunnel-spike
```

Then verify baseline is restored:
```sh
ssh openwrt 'ip rule show; nft list ruleset | grep amnezia; ping -c2 8.8.8.8'
```

---

## Step 14 — MT7981 kernel feature checks (spike items)

```sh
# CONFIG_IP_ROUTE_MULTIPATH — needed for balance mode
ssh openwrt 'zcat /proc/config.gz 2>/dev/null | grep MULTIPATH || echo NOT_IN_CONFIG'

# Resilient nexthop support (kernel 5.10+ feature)
ssh openwrt 'ip nexthop help 2>&1 | head -3 || echo NEXTHOP_UNSUPPORTED'

# DFS CAC interaction: reloading fw4 should not trigger DFS channel change
ssh openwrt '( sleep 2 && fw4 reload ) & iw dev wlan0 scan 2>&1 | grep -c DFS_CAC || true'
```

Record results in spike notes. If `NEXTHOP_UNSUPPORTED`, balance mode falls
back to single-dev routing (failover mode still works correctly).

---

## Completion checklist

- [ ] Backup exists: `before-multitunnel-spike`
- [ ] Routing tables installed in `/etc/iproute2/rt_tables.d/amnezia.conf`
- [ ] ip rules installed for marks `0x0a0000` and `0x0b0000`
- [ ] Classifier active: `nft list chain inet fw4 amnezia_classify` shows 3 rules
- [ ] RU-direct still working (yandex.ru via wan, not VPN)
- [ ] `amnezia_block_quic` rule intact
- [ ] Failover observed: awg1 down → pool moves to awg2
- [ ] Fail-closed verified: all tunnels down → blackhole routes
- [ ] Failback verified: awg1 up → pool returns
- [ ] MT7981 kernel feature check documented
- [ ] `zapret` still running after fw4 reload
