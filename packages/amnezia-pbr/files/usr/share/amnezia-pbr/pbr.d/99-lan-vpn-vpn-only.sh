#!/bin/sh
# Step 2: LAN -> VPN only (no RU bypass).
nft add rule inet fw4 pbr_prerouting ip saddr { __LAN__ } goto pbr_mark_0x020000 comment "lan_via_vpn"
return 0
