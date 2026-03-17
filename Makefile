include $(TOPDIR)/rules.mk

PKG_NAME:=opentether
PKG_VERSION:=1.2.1
PKG_RELEASE:=1

PKG_MAINTAINER:=Alisha Faye <helafaye@users.noreply.github.com>
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/opentether
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OpenTether - Phone-as-router bridge via ADB
  DEPENDS:=+hev-socks5-tunnel +adb +curl
  PKGARCH:=all
endef

define Package/opentether/description
  Bridges any Android phone running a SOCKS5 proxy to any OpenWrt
  router WAN via ADB port forwarding and hev-socks5-tunnel. Plug in
  the phone, approve USB debugging, and the tunnel comes up
  automatically.
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/opentether/conffiles
/etc/config/opentether
endef

define Package/opentether/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/opentether \
		$(1)/etc/init.d/opentether

	$(INSTALL_DIR) $(1)/etc/hotplug.d/usb
	$(INSTALL_BIN) ./files/etc/hotplug.d/usb/99-opentether \
		$(1)/etc/hotplug.d/usb/99-opentether

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/99-opentether-route \
		$(1)/etc/hotplug.d/iface/99-opentether-route

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/opentether-check \
		$(1)/usr/bin/opentether-check

	$(INSTALL_DIR) $(1)/usr/lib/opentether
	$(INSTALL_BIN) ./files/usr/lib/opentether/setup.sh \
		$(1)/usr/lib/opentether/setup.sh

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/opentether \
		$(1)/etc/config/opentether
endef

define Package/opentether/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/usr/lib/opentether/setup.sh install
exit 0
endef

define Package/opentether/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/usr/lib/opentether/setup.sh remove
exit 0
endef

$(eval $(call BuildPackage,opentether))
