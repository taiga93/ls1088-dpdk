include $(TOPDIR)/rules.mk

PKG_NAME:=bmc-dynrouting-virtual-bootstrap
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/bmc-dynrouting-virtual-bootstrap
  SECTION:=BMC
  CATEGORY:=BMC
  TITLE:=Cụm ảo DynRouting bootstrap
  DEPENDS:=+bmcDynRouting
endef

define Package/bmc-dynrouting-virtual-bootstrap/description
First-boot networking for the armsr Cụm ảo DynRouting only (scripts/dynrouting-cluster).
endef

define Build/Compile
endef

define Package/bmc-dynrouting-virtual-bootstrap/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/99-dynrouting-virtual-network $(1)/etc/uci-defaults/99-dynrouting-virtual-network
endef

$(eval $(call BuildPackage,bmc-dynrouting-virtual-bootstrap))
