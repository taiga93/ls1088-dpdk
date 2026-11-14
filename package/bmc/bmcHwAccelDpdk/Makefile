include $(TOPDIR)/rules.mk

PKG_NAME:=bmcHwAccelDpdk
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
# DPDK is linked statically: needed to build only
PKG_BUILD_DEPENDS:=dpdk

include $(INCLUDE_DIR)/package.mk

define Package/bmcHwAccelDpdk
  SECTION:=net
  CATEGORY:=BMC
  TITLE:=BMC hardware acceleration on the DPAA2 boards (DPDK)
  # dpdk: dpdk-pdump, which captures the engine's ports; restool: the
  # container script; the others: the shared libraries the static DPDK links to
  # libnetfilter-conntrack, libnfnetlink: bmchwaccel-syncd
  DEPENDS:=@TARGET_layerscape_armv8_64b +dpdk +restool +libpcap +jansson +libelf +libbsd \
	+libnetfilter-conntrack +libnfnetlink
endef

define Package/bmcHwAccelDpdk/description
  bmchwaccel-engine: forwards the established IPv4 TCP/UDP connections
  between the 10G ports of the LS1088 outside Linux's firewall and qdisc,
  and gives every other packet to the kernel; bmchwaccel-syncd hands it
  those connections from conntrack and takes them back. With it the board boots in
  the engine layout when Tăng tốc phần cứng is enabled: /etc/init.d/phy_init
  asks /usr/lib/bmcHwAccelDpdk/layout.
endef

# -O3 as in the measurements of ticket 01; -mcpu comes from libdpdk.pc
TARGET_CFLAGS:=$(filter-out -O%,$(TARGET_CFLAGS)) -O3

# BMCHWACCEL_HIDE_SYMS=1 (set on the make command line by the dpdk-only build)
# compiles the engine with hidden symbol visibility, so our function names do
# not go into the dynamic symbol table. The DPDK pkg-config --static libs pass
# -Wl,--export-dynamic (for shared PMDs we do not load), which otherwise exports
# every global function; strip --strip-all does not remove .dynsym. Hidden
# visibility does not change behaviour: the engine is one static executable, its
# functions are only called within it. Left unset, the binary is as before.
ifeq ($(BMCHWACCEL_HIDE_SYMS),1)
TARGET_CFLAGS += -fvisibility=hidden -fvisibility-inlines-hidden
# The same for the symbols of the static DPDK archives: --export-dynamic would
# put every rte_* function into .dynsym. Nothing loads a shared PMD or looks a
# symbol up in the engine at run time.
TARGET_LDFLAGS += -Wl,--exclude-libs,ALL
endif

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS) $(TARGET_CPPFLAGS)" \
		LDFLAGS="$(TARGET_LDFLAGS)" \
		PKG_CONFIG="$(PKG_CONFIG)"
endef

define Package/bmcHwAccelDpdk/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/usr/lib/bmcHwAccelDpdk $(1)/etc/init.d $(1)/etc/strongswan.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bmchwaccel-engine $(PKG_BUILD_DIR)/bmchwaccel-ctl \
		$(PKG_BUILD_DIR)/bmchwaccel-syncd $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/layout ./files/container $(1)/usr/lib/bmcHwAccelDpdk/
	$(INSTALL_BIN) ./files/bmchwaccel-layout.init $(1)/etc/init.d/bmchwaccel-layout
	$(INSTALL_BIN) ./files/bmchwaccel-engine.init $(1)/etc/init.d/bmchwaccel-engine
	$(INSTALL_BIN) ./files/bmchwaccel-syncd.init $(1)/etc/init.d/bmchwaccel-syncd
	$(INSTALL_DATA) ./files/strongswan.conf $(1)/etc/strongswan.d/bmchwaccel.conf
endef

$(eval $(call BuildPackage,bmcHwAccelDpdk))
