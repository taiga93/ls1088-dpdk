include $(TOPDIR)/rules.mk

PKG_NAME:=bmcHwAccel
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_SOURCE_DIR:=./src
PKG_CONFIG_DEPENDS:=CONFIG_BMCHWACCEL_ASK CONFIG_BMCHWACCEL_DPDK

include $(INCLUDE_DIR)/package.mk

# What implements it is chosen by board: NXP ASK on the DPAA1 boards (LS1046), bmchwaccel-engine of
# bmcHwAccelDpdk on the DPAA2 boards (LS1088). Only engine.sh differs (engine-dpdk.sh is the DPAA2 one).
define Package/bmcHwAccel
  SECTION:=net
  CATEGORY:=BMC
  TITLE:=BMC hardware acceleration
  DEPENDS:=@TARGET_layerscape \
	+BMCHWACCEL_ASK:cmm +BMCHWACCEL_ASK:kmod-ask-cdx +BMCHWACCEL_ASK:kmod-ask-auto-bridge \
	+BMCHWACCEL_ASK:kmod-ask-fci +BMCHWACCEL_DPDK:bmcHwAccelDpdk \
	+firewall +iptables-zz-legacy +ip6tables-zz-legacy +iptables-mod-conntrack-extra +conntrack +flock \
	+ipset +kmod-ipt-ipset +iptables-mod-physdev +kmod-ipt-physdev +ip-full
endef

define Package/bmcHwAccel/config
  choice
	prompt "What implements Tăng tốc phần cứng"
	depends on PACKAGE_bmcHwAccel
	default BMCHWACCEL_DPDK if TARGET_layerscape_armv8_64b_DEVICE_fsl_ls1088a-rdb || TARGET_layerscape_armv8_64b_DEVICE_fsl_ls1088a-rdb-sdboot
	default BMCHWACCEL_ASK

	config BMCHWACCEL_ASK
	bool "NXP ASK (DPAA1: LS1046)"

	config BMCHWACCEL_DPDK
	bool "bmchwaccel-engine (DPAA2: LS1088)"
  endchoice
endef

define Package/bmcHwAccel/conffiles
/etc/config/bmchwaccel
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(PKG_SOURCE_DIR)/etc $(PKG_BUILD_DIR)/
	$(CP) $(PKG_SOURCE_DIR)/usr $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Package/bmcHwAccel/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults $(1)/usr/sbin $(1)/usr/lib/bmcHwAccel
	$(INSTALL_DIR) $(1)/usr/share/bmcHwAccel/blocked.d $(1)/etc/hotplug.d/iface
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/usr/share/bmcHwAccel/blocked.d/* $(1)/usr/share/bmcHwAccel/blocked.d/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/hotplug.d/iface/20-bmcHwAccel $(1)/etc/hotplug.d/iface/20-bmcHwAccel
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/etc/config/bmchwaccel $(1)/etc/config/bmchwaccel
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/init.d/bmcHwAccel $(1)/etc/init.d/bmcHwAccel
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/uci-defaults/99-bmcHwAccel $(1)/etc/uci-defaults/99-bmcHwAccel
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/sbin/bmchwaccel $(1)/usr/sbin/bmchwaccel
	$(INSTALL_DATA) $(addprefix $(PKG_BUILD_DIR)/usr/lib/bmcHwAccel/,$(filter-out engine.sh engine-dpdk.sh, \
		$(notdir $(wildcard $(PKG_SOURCE_DIR)/usr/lib/bmcHwAccel/*.sh)))) \
		$(1)/usr/lib/bmcHwAccel/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/share/bmcHwAccel/firewall.include $(1)/usr/share/bmcHwAccel/firewall.include
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/lib/bmcHwAccel/supervise $(1)/usr/lib/bmcHwAccel/supervise
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/lib/bmcHwAccel/daemon-running $(1)/usr/lib/bmcHwAccel/daemon-running
	$(call Package/bmcHwAccel/install/$(if $(CONFIG_BMCHWACCEL_DPDK),dpdk,ask),$(1))
endef

define Package/bmcHwAccel/install/ask
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/usr/lib/bmcHwAccel/engine.sh $(1)/usr/lib/bmcHwAccel/engine.sh
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/usr/lib/bmcHwAccel/fastforward $(1)/usr/lib/bmcHwAccel/fastforward
endef

define Package/bmcHwAccel/install/dpdk
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/usr/lib/bmcHwAccel/engine-dpdk.sh $(1)/usr/lib/bmcHwAccel/engine.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/lib/bmcHwAccel/supervise-engine $(1)/usr/lib/bmcHwAccel/supervise-engine
endef

$(eval $(call BuildPackage,bmcHwAccel))
