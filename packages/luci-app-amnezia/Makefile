# SPDX-License-Identifier: GPL-2.0-only
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-amnezia
PKG_VERSION:=0.2.0
PKG_RELEASE:=5
PKG_MAINTAINER:=JonniK <esmirnov@socialprofiler.com>
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-amnezia
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI app for amnezia-pbr (AmneziaWG failover + tunnel mgmt + DoT + autolearn)
  URL:=https://github.com/JonniK/amnezia-openwrt
  PKGARCH:=all
  DEPENDS:= \
    +amnezia-pbr \
    +luci-base \
    +rpcd
endef

define Package/luci-app-amnezia/description
 LuCI panel for managing the amnezia-pbr installation:
   - Failover tunnel table: status, uptime, peer endpoint, set-mode/set-sticky
   - Add / remove AmneziaWG tunnels (paste .conf or vpn:// link)
   - Routing mode toggle (tunnel-default / direct-default) + allowlist sources
   - Manual force-tunnel list editor + RU CIDR refresh stamp
   - Domain probe (direct_ok / direct_geoblocked / direct_dpi_blocked / direct_unreachable)
   - Verify list (run probe across N domains in one go)
   - Blockcheck runner with live log and apply/revert of nfqws strategies
   - Encrypted DNS toggle (DoT/DoH via stubby + https-dns-proxy, opt-in)
   - Auto-learning bypass: harvest visited domains, probe, auto-add to force list
 Reachable at Network -> Amnezia.
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-amnezia/install
	$(CP) ./files/. $(1)/
endef

define Package/luci-app-amnezia/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# Clear LuCI menu + module caches so the new entry shows up on next request.
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache 2>/dev/null || true
# Reload rpcd so the new ACL allow-list is honored (otherwise the panel
# loads but every fs.exec call returns 403 until a reload happens). uhttpd
# reload picks up the new view JS path.
/etc/init.d/rpcd reload >/dev/null 2>&1 || /etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd reload >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,luci-app-amnezia))
