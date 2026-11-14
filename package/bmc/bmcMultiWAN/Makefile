include $(TOPDIR)/rules.mk

PKG_NAME:=bmcMultiWAN
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_SOURCE_DIR:=./src

include $(INCLUDE_DIR)/package.mk

define Package/bmcMultiWAN
  SECTION:=net
  CATEGORY:=BMC
  TITLE:=BMC Multi-WAN
  DEPENDS:=+mwan3
endef

define Package/bmcMultiWAN/conffiles
/etc/config/bmcMultiWAN
/etc/config/mwan3
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(PKG_SOURCE_DIR)/etc $(PKG_BUILD_DIR)/
	$(CP) $(PKG_SOURCE_DIR)/usr $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Package/bmcMultiWAN/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults $(1)/usr/sbin $(1)/usr/lib/bmcMultiWAN \
		$(1)/usr/share/bmcMultiWAN
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/etc/config/bmcMultiWAN $(1)/etc/config/bmcMultiWAN
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/init.d/bmcMultiWAN $(1)/etc/init.d/bmcMultiWAN
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/uci-defaults/99-bmcMultiWAN $(1)/etc/uci-defaults/99-bmcMultiWAN
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/sbin/bmcmultiwan $(1)/usr/sbin/bmcmultiwan
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/usr/lib/bmcMultiWAN/*.sh $(1)/usr/lib/bmcMultiWAN/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/share/bmcMultiWAN/firewall.include $(1)/usr/share/bmcMultiWAN/firewall.include
endef

$(eval $(call BuildPackage,bmcMultiWAN))
