#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=bmcfirewall
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_SOURCE:=bmcfirewall-$(PKG_VERSION).tar.gz
# The source is kept next to this Makefile (./src) on the hardware acceleration
# base, where dl/ is a download cache outside git, and under dl/ on the 24.10
# tree.
PKG_SRC_DIR :=$(if $(wildcard ./src),$(CURDIR)/src,$(DL_DIR)/$(PKG_NAME)-$(PKG_VERSION))
PKG_BUILD_DIR :=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_UNPACK=mkdir -p $(PKG_BUILD_DIR); $(CP) $(PKG_SRC_DIR)/. $(PKG_BUILD_DIR)/
HOST_UNPACK=mkdir -p $(HOST_BUILD_DIR); $(CP) $(PKG_SRC_DIR)/. $(HOST_BUILD_DIR)/

PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE.txt
PKG_CPE_ID:=cpe:/a:adguard:adguardhome
PKG_MAINTAINER:=Dobroslaw Kijowski <dobo90@gmail.com>

PKG_BUILD_DEPENDS:=golang/host node/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/AdguardTeam/AdGuardHome
GO_PKG_BUILD_PKG:=github.com/AdguardTeam/AdGuardHome

AGH_BUILD_TIME:=$(shell date -d @$(SOURCE_DATE_EPOCH) +%FT%TZ%z)
AGH_VERSION_PKG:=github.com/AdguardTeam/AdGuardHome/internal/version
GO_PKG_LDFLAGS_X:=$(AGH_VERSION_PKG).channel=release \
	$(AGH_VERSION_PKG).version=$(PKG_VERSION) \
	$(AGH_VERSION_PKG).buildtime=$(AGH_BUILD_TIME) \
	$(AGH_VERSION_PKG).goarm=$(GO_ARM) \
	$(AGH_VERSION_PKG).gomips=$(GO_MIPS)

include $(INCLUDE_DIR)/package.mk
include ../../../feeds/packages/lang/golang/golang-package.mk

define Package/bmcfirewall
	SECTION:=Firewall
	CATEGORY:=BMC
	TITLE:=Network-wide ads and trackers blocking DNS server
	DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle +iptables +ipset +IPV6:ip6tables
endef

define Package/bmcfirewall/conffiles
/etc/bmcfirewall.yaml
/etc/config/bmcfirewall
# BMC_CODE START
/etc/ipset.conf
# BMC_CODE END
endef

define Package/bmcfirewall/description
Free and open source, powerful network-wide ads and trackers blocking DNS server.
endef

define Build/Compile
	( \
		pushd $(PKG_BUILD_DIR) ; \
		make js-deps js-build ; \
		popd ; \
		$(call GoPackage/Build/Compile) ; \
	)
endef

define Package/bmcfirewall/install
	$(call GoPackage/Package/Install/Bin,$(1))
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/bmcfirewall.init $(1)/etc/init.d/bmcfirewall

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/bmcfirewall.config $(1)/etc/config/bmcfirewall

	$(INSTALL_DIR) $(1)/etc/
	$(INSTALL_DATA) ./files/bmcfirewall.yaml $(1)/etc/
	# BMC_CODE START
	$(INSTALL_BIN) ./files/create-ipset-lists.sh $(1)/etc/create-ipset-lists.sh
	$(INSTALL_DATA) ./files/ipset.conf $(1)/etc/ipset.conf
	$(INSTALL_DIR) $(1)/usr/share/bmcfirewall $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/firewall.include $(1)/usr/share/bmcfirewall/firewall.include
	$(INSTALL_BIN) ./files/bmcfirewall.defaults $(1)/etc/uci-defaults/99-bmcfirewall
	# BMC_CODE END
	mv $(1)/usr/bin/AdGuardHome $(1)/usr/bin/bmcfirewall
endef

$(eval $(call GoBinPackage,bmcfirewall))
$(eval $(call BuildPackage,bmcfirewall))
