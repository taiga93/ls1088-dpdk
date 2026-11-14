include $(TOPDIR)/rules.mk

PKG_NAME:=squidclamav
PKG_VERSION:=7.3
PKG_RELEASE:=1

# Tag v7.3 of https://github.com/darold/squidclamav.git.
# The tarball is kept next to this Makefile (./dist) on the hardware
# acceleration base, where dl/ is a download cache outside git; the 24.10 tree
# has it in dl/.
PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.zst
PKG_SOURCE_URL:=file://$(CURDIR)/dist
PKG_HASH:=d3cf0213b8fc46b136513450d81edda342410f5e768d9078ac0fb6d3a5501347

PKG_MAINTAINER:=Your Name <you@example.com>
PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=COPYING

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=net
  CATEGORY:=Network
  TITLE:=SquidClamav ICAP antivirus filter
  DEPENDS:=+c-icap
endef

define Package/$(PKG_NAME)/description
 [Community] SquidClamav is a dedicated ICAP service to scan HTTP traffic for viruses using ClamAV.
endef

CONFIGURE_ARGS += HAVE_TEMPLATE="-DHAVE_CICAP_TEMPLATE" \
	--with-c-icap=$(STAGING_DIR)/usr \
	--with-clamav=$(STAGING_DIR)/usr

TARGET_CFLAGS += -DHAVE_CICAP_TEMPLATE

MAKE_FLAGS += \
	CFLAGS="$(TARGET_CFLAGS) -I$(STAGING_DIR)/usr/include -I$(STAGING_DIR)/usr/include/c_icap" \
	LDFLAGS="$(TARGET_LDFLAGS) -L$(STAGING_DIR)/usr/lib"

# TARGET_CFLAGS += -I$(STAGING_DIR)/usr/include -I$(STAGING_DIR)/usr/include/c_icap


define Build/Prepare
	$(call Build/Prepare/Default)
endef

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS) -I$(STAGING_DIR)/usr/include -I$(STAGING_DIR)/usr/include/c_icap" \
		LDFLAGS="$(TARGET_LDFLAGS) -L$(STAGING_DIR)/usr/lib"
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/lib/c_icap
	$(INSTALL_DIR) $(1)/etc/c-icap
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/src/.libs/squidclamav.so \
		$(1)/usr/lib/c_icap/squidclamav.so
	$(INSTALL_CONF) ./files/squidclamav.conf $(1)/etc/c-icap
	$(INSTALL_BIN) ./files/update_squidclamav_ip.sh $(1)/etc/c-icap/
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/99-squid-update $(1)/etc/hotplug.d/iface/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))