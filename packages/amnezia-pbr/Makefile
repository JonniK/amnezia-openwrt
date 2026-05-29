# SPDX-License-Identifier: GPL-2.0-only
include $(TOPDIR)/rules.mk

PKG_NAME:=amnezia-pbr
PKG_VERSION:=0.2.0
PKG_RELEASE:=1
PKG_MAINTAINER:=JonniK <esmirnov@socialprofiler.com>
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/amnezia-pbr
  SECTION:=net
  CATEGORY:=Network
  TITLE:=AmneziaWG + PBR with RU bypass and zapret integration
  URL:=https://github.com/JonniK/amnezia-openwrt
  PKGARCH:=all
  # Hard deps available in the official OpenWrt 24.10 feed.
  # AmneziaWG kmod + tools and zapret are NOT in the main feed; they get
  # downloaded from upstream GitHub releases by amnezia-pbr-setup on first
  # invocation, so we don't declare them here (opkg would error on missing
  # provider). Document the expected runtime deps in README instead.
  DEPENDS:= \
    +pbr \
    +dnsmasq-full \
    +resolveip \
    +ip-full \
    +curl \
    +wget \
    +nmap-ncat
endef

define Package/amnezia-pbr/description
 Wrappers, UCI scaffold, and PBR includes for amnezia-pbr-openwrt:
   - AmneziaWG tunnel UCI + first-run config from /etc/amnezia/awg.conf
   - Policy-based routing with .ru TLD + RU CIDR bypass via ipdeny + nftset
   - Optional zapret DPI desync layer with blockcheck/apply/verify tools

 Run /usr/sbin/amnezia-pbr-setup after providing your Amnezia-exported .conf
 at /etc/amnezia/awg.conf. The setup tool downloads the AmneziaWG kmod from
 Slava-Shchipunov/awg-openwrt and zapret from remittor/zapret-openwrt at
 first run (network connectivity required).
endef

define Package/amnezia-pbr/conffiles
/etc/config/amnezia
/etc/amnezia/awg.conf
endef

# No source compile -- this is a config + scripts package. The Build/Compile
# stub is required so OpenWrt's build system doesn't try to invoke autotools.
define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/amnezia-pbr/install
	$(CP) ./files/. $(1)/
endef

define Package/amnezia-pbr/postinst
#!/bin/sh
# Skip when opkg is staging for a sysupgrade image build, not real install.
[ -n "$${IPKG_INSTROOT}" ] && exit 0

# Weekly RU CIDR refresh. Idempotent: replace any prior entry tagged with
# our marker comment so a re-install doesn't duplicate the line.
CRON=/etc/crontabs/root
touch "$$CRON"
sed -i '/# amnezia-pbr$$/d' "$$CRON" 2>/dev/null || true
echo "30 4 * * 0 /usr/bin/awg-ru-update >/dev/null 2>&1 # amnezia-pbr" >> "$$CRON"
/etc/init.d/cron enable >/dev/null 2>&1 || true
/etc/init.d/cron reload >/dev/null 2>&1 || /etc/init.d/cron restart >/dev/null 2>&1 || true

cat <<'NEXT'

amnezia-pbr installed.

Next steps:
  1. Provide your Amnezia-exported .conf:
       mkdir -p /etc/amnezia
       vi /etc/amnezia/awg.conf
  2. Run first-time setup (downloads AmneziaWG kmod + zapret, configures UCI):
       amnezia-pbr-setup
  3. Manage from LuCI (Network -> Amnezia) -- install luci-app-amnezia if
     not already pulled in.

NEXT
exit 0
endef

define Package/amnezia-pbr/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
sed -i '/# amnezia-pbr$$/d' /etc/crontabs/root 2>/dev/null || true
/etc/init.d/cron reload >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,amnezia-pbr))
