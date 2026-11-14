include $(TOPDIR)/rules.mk

PKG_NAME:=c-icap-server
PKG_VERSION:=0.6.4
PKG_RELEASE:=1

# Tag C_ICAP_0.6.4 of https://github.com/c-icap/c-icap-server.git.
# The tarball is kept next to this Makefile (./dist) on the hardware
# acceleration base, where dl/ is a download cache outside git; the 24.10 tree
# has it in dl/.
PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.zst
PKG_SOURCE_URL:=file://$(CURDIR)/dist
PKG_HASH:=079e16d11221f58abb3fa80aeb252f0cb1add91c4cc833ba2a21643967069fd6

PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=COPYING

PKG_FIXUP:=autoreconf
PKG_INSTALL:=1

include $(INCLUDE_DIR)/package.mk

define Package/c-icap
  SECTION:=net
  CATEGORY:=Network
  TITLE:=C-ICAP Server
  URL:=http://c-icap.sourceforge.net/
  DEPENDS:=+libpthread +zlib +libatomic +libopenssl +libbz2 +libzstd +libpcre2 +libicapapi
endef

define Package/c-icap/description
  [Community] c-icap is an implementation of an ICAP server. 
  It can be used with HTTP proxies (like Squid) 
  to provide content adaptation services.
endef

define Package/libicapapi
  SECTION:=libs
  CATEGORY:=Libraries
  TITLE:=ICAP API library
  DEPENDS:=+libatomic +libbz2 +libopenssl +libpcre2 +libzstd +zlib
endef

define Package/libicapapi/description
  Shared library containing the ICAP API used by c-icap modules.
endef

CONFIGURE_ARGS += \
	--prefix=/usr \
	--sysconfdir=/etc \
	--sbindir=/usr/bin \
	--localstatedir=/var \
	ac_cv_10031b_ipc_sem=yes \
	ac_cv_fcntl=yes \
	--enable-large-files \
	--with-openssl \
	--with-pcre \
	--sysconfdir=/etc/c-icap \
	--localstatedir=/var \
	--enable-shared \
	LDFLAGS="-L$(PKG_BUILD_DIR)/.libs -L$(STAGING_DIR)/usr/lib"

define Build/InstallDev
	$(INSTALL_DIR) $(1)/usr/include
	$(CP) $(PKG_INSTALL_DIR)/usr/include/* $(1)/usr/include/

	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/*.so* $(1)/usr/lib/
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/c_icap/*.so* $(1)/usr/lib/
endef

define Build/Install
	$(MAKE) -C $(PKG_BUILD_DIR) DESTDIR="$(PKG_INSTALL_DIR)" install
endef

define Package/c-icap/conffiles
/etc/c-icap/c-icap.conf
endef

define Package/c-icap/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_DIR) $(1)/etc/c-icap
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/c-icap $(1)/usr/bin/
	$(INSTALL_BIN) ./files/etc/init.d/c-icap $(1)/etc/init.d/c-icap
	$(CP) $(PKG_INSTALL_DIR)/etc/c-icap/* $(1)/etc/c-icap/
	$(INSTALL_CONF) ./files/etc/c-icap/c-icap.conf $(1)/etc/c-icap/c-icap.conf
endef

define Package/libicapapi/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libicapapi.so.* $(1)/usr/lib/
endef

$(eval $(call BuildPackage,c-icap))
$(eval $(call BuildPackage,libicapapi))
