#!/bin/sh
# LAN routing rules — appended to pbr.nft via PBR's nft() wrapper (do not use nft list/delete here).
nft add rule inet fw4 pbr_prerouting ip saddr { __LAN__ } ip daddr @pbr_ru_tld4 return comment "ru_tld_dns_skip"
nft add rule inet fw4 pbr_prerouting ip saddr { __LAN__ } ip daddr @pbr_wan_4_dst_ip_user return comment "ru_direct_skip"
nft add rule inet fw4 pbr_prerouting ip saddr { __LAN__ } goto pbr_mark_0x020000 comment "lan_via_vpn"
return 0
