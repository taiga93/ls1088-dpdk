include $(TOPDIR)/rules.mk

PKG_NAME:=bmcqos
PKG_VERSION:=1.0
PKG_RELEASE:=3

PKG_LICENSE:=GPL-3.0-or-later
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_SOURCE_DIR:=./src

include $(INCLUDE_DIR)/package.mk

define Package/bmcqos
  SECTION:=net
  CATEGORY:=BMC
  TITLE:=BMC QoS manager for firewall3
  DEPENDS:=+firewall +iptables-zz-legacy +ip6tables-zz-legacy +iptables-mod-ipopt \
	+iptables-mod-conntrack-extra +ipset +ip-full +tc-full +coreutils-sleep +kmod-veth \
	+kmod-ifb +kmod-netem +kmod-sched +kmod-sched-ctinfo \
	+kmod-sched-cake +kmod-sched-red
endef

define Package/bmcqos/description
  Traffic classification with firewall3/iptables and traffic shaping with
  CAKE, HFSC, HTB or Hybrid qdiscs.
endef

define Package/bmcqos/conffiles
/etc/config/bmcqos
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(PKG_SOURCE_DIR)/etc $(PKG_BUILD_DIR)/
	$(CP) $(PKG_SOURCE_DIR)/usr $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Package/bmcqos/install
	$(INSTALL_DIR) $(1)/etc/bmcqos $(1)/etc/config $(1)/etc/init.d $(1)/etc/hotplug.d/iface
	$(INSTALL_DIR) $(1)/etc/uci-defaults $(1)/usr/lib/bmcqos $(1)/usr/share/bmcqos
	$(INSTALL_DIR) $(1)/usr/lib/tc
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/etc/config/bmcqos $(1)/etc/config/bmcqos
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/bmcqos.sh $(1)/etc/bmcqos/bmcqos.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/bmcqos-autorate.sh $(1)/etc/bmcqos/bmcqos-autorate.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/bmcqos-autorate-tc.sh $(1)/etc/bmcqos/bmcqos-autorate-tc.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/init.d/bmcqos $(1)/etc/init.d/bmcqos
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/init.d/bmcqos-autorate $(1)/etc/init.d/bmcqos-autorate
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/hotplug.d/iface/13-bmcqos $(1)/etc/hotplug.d/iface/13-bmcqos
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/uci-defaults/99-bmcqos $(1)/etc/uci-defaults/99-bmcqos
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/bmcqos-firewall.sh $(1)/usr/lib/bmcqos/firewall.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/bmcqos-firewall.include $(1)/usr/share/bmcqos/firewall.include
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/usr/lib/tc/*.dist $(1)/usr/lib/tc/
endef

$(eval $(call BuildPackage,bmcqos))
