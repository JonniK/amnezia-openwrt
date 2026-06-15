# Shared constants + helpers for amnezia multi-tunnel. POSIX sh (BusyBox ash).
STICKY_MARK=0x0A0000
POOL_MARK=0x0B0000
MARK_MASK=0x0FF0000
TBL_STICKY=100
TBL_POOL=101
SET_RU4=amnezia_ru4
SET_RU_TLD4=amnezia_ru_tld4
SET_STICKY4=amnezia_sticky4
STATE_FILE=/var/run/amnezia-failover.json
CONF_DIR=/etc/amnezia
RU_CIDR_PERSIST=/etc/amnezia/ru.cidr
MAX_TUNNELS=5

# Per-member conntrack mark (balance mode): low byte only, never the selector nibble.
member_ctmark() { printf '0x%06x\n' "$1"; }

amz_log() { logger -t amnezia-failover "$*" 2>/dev/null; [ -n "$AMNEZIA_DEBUG" ] && echo "amnezia: $*" >&2; }
