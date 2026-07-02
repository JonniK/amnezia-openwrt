#!/bin/sh
# Install luci-app-amnezia: menu entry, ACL, JS view, RU update tooling, cron.
# Expects /tmp/luci-app-amnezia/ to contain {menu,acl,view}/ AND
# /tmp/awg-ru-update.sh to be present.
# Idempotent.
set -eu

SRC="${SRC:-/tmp/luci-app-amnezia}"
RU_UPDATE_SRC="${RU_UPDATE_SRC:-/tmp/awg-ru-update.sh}"

MENU_DST=/usr/share/luci/menu.d/luci-app-amnezia.json
ACL_DST=/usr/share/rpcd/acl.d/luci-app-amnezia.json
VIEW_DIR=/www/luci-static/resources/view/amnezia
VIEW_DST="$VIEW_DIR/main.js"
RU_UPDATE_DST=/usr/bin/awg-ru-update
CRON_FILE=/etc/crontabs/root
CRON_MARK='# amnezia-ru-update'

[ -f "$SRC/menu/luci-app-amnezia.json" ]       || { echo "missing $SRC/menu/luci-app-amnezia.json"; exit 1; }
[ -f "$SRC/acl/luci-app-amnezia.json" ]        || { echo "missing $SRC/acl/luci-app-amnezia.json"; exit 1; }
[ -f "$SRC/view/main.js" ]                     || { echo "missing $SRC/view/main.js"; exit 1; }
[ -f "$RU_UPDATE_SRC" ]                        || { echo "missing $RU_UPDATE_SRC"; exit 1; }
# Preflight: amnezia resource modules must be present.
[ -f "$SRC/amnezia/util.js" ]                  || { echo "missing $SRC/amnezia/util.js"; exit 1; }
[ -f "$SRC/amnezia/section/failover.js" ]      || { echo "missing $SRC/amnezia/section/failover.js"; exit 1; }
[ -f "$SRC/amnezia/section/routing.js" ]       || { echo "missing $SRC/amnezia/section/routing.js"; exit 1; }
[ -f "$SRC/amnezia/section/zapret.js" ]        || { echo "missing $SRC/amnezia/section/zapret.js"; exit 1; }
[ -f "$SRC/amnezia/section/dns.js" ]           || { echo "missing $SRC/amnezia/section/dns.js"; exit 1; }

# Place RU update script.
cp "$RU_UPDATE_SRC" "$RU_UPDATE_DST"
chmod 0755 "$RU_UPDATE_DST"
mkdir -p /etc/amnezia

# Place LuCI artifacts.
mkdir -p "$VIEW_DIR"
mkdir -p /www/luci-static/resources/amnezia/section
cp "$SRC/menu/luci-app-amnezia.json" "$MENU_DST"
cp "$SRC/acl/luci-app-amnezia.json"  "$ACL_DST"
# Copy amnezia resource modules (util.js + section/*.js) before main.js so
# on-device require() resolves modules before the entry point is loaded.
cp -r "$SRC/amnezia/." /www/luci-static/resources/amnezia/
find /www/luci-static/resources/amnezia -name '*.js' -exec chmod 0644 {} +
# main.js is copied last (entry point; require()s the modules above).
cp "$SRC/view/main.js"               "$VIEW_DST"
chmod 0644 "$MENU_DST" "$ACL_DST" "$VIEW_DST"

# Register weekly cron (Sun 04:30). Replace any prior entry marked with CRON_MARK.
touch "$CRON_FILE"
_tmp=/tmp/crontabs.amnezia.$$
grep -v "$CRON_MARK" "$CRON_FILE" > "$_tmp" || true
echo "30 4 * * 0 $RU_UPDATE_DST >/dev/null 2>&1 $CRON_MARK" >> "$_tmp"
mv "$_tmp" "$CRON_FILE"
/etc/init.d/cron enable >/dev/null 2>&1 || true
/etc/init.d/cron reload >/dev/null 2>&1 || /etc/init.d/cron restart >/dev/null 2>&1 || true

# Clear LuCI caches so new menu + ACL are picked up.
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/rpcd reload >/dev/null 2>&1 || /etc/init.d/rpcd restart >/dev/null 2>&1 || true

cat <<EOF
luci-app-amnezia: installed.

  Menu:     Network -> Amnezia
  RU sync:  /usr/bin/awg-ru-update  (cron: Sundays 04:30)
  Stamp:    /etc/amnezia/ru-update.json

NOTE: if the new menu entry does not appear in LuCI right away, log out and
back in (or hard-refresh with Ctrl-Shift-R) to clear the browser's menu cache.
EOF
