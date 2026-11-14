include $(TOPDIR)/rules.mk

PKG_NAME:=bmcDynRouting
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_SOURCE_DIR:=./src

include $(INCLUDE_DIR)/package.mk

define Package/bmcDynRouting
  SECTION:=net
  CATEGORY:=BMC
  TITLE:=BMC Dynamic Routing
  DEPENDS:=+frr +frr-zebra +frr-ospfd +frr-ripd +frr-bgpd +frr-watchfrr
endef

define Package/bmcDynRouting/conffiles
/etc/config/bmcDynRouting
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(PKG_SOURCE_DIR)/etc $(PKG_BUILD_DIR)/
	$(CP) $(PKG_SOURCE_DIR)/usr $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Package/bmcDynRouting/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults $(1)/etc/hotplug.d/iface $(1)/usr/sbin $(1)/usr/lib/bmcDynRouting $(1)/usr/share/bmcDynRouting
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/etc/config/bmcDynRouting $(1)/etc/config/bmcDynRouting
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/init.d/bmcDynRouting $(1)/etc/init.d/bmcDynRouting
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/uci-defaults/99-bmcDynRouting $(1)/etc/uci-defaults/99-bmcDynRouting
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/hotplug.d/iface/90-bmcDynRouting $(1)/etc/hotplug.d/iface/90-bmcDynRouting
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/sbin/bmcdynrouting $(1)/usr/sbin/bmcdynrouting
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/usr/lib/bmcDynRouting/*.sh $(1)/usr/lib/bmcDynRouting/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/share/bmcDynRouting/firewall.include $(1)/usr/share/bmcDynRouting/firewall.include
endef

$(eval $(call BuildPackage,bmcDynRouting))
