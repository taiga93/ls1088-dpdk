#
# Copyright (C) 2012-2014 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=libmicroxml
# apk takes neither dashes in a version nor a commit as the release. The
# tarball and the directory in it keep the date as upstream wrote it.
PKG_VERSION:=2012.06.11
PKG_RELEASE:=1

#PKG_SOURCE_PROTO:=git
#PKG_SOURCE_URL:=https://github.com/pivasoftware/microxml.git
PKG_SOURCE_SUBDIR:=$(PKG_NAME)-2012-06-11
PKG_SOURCE_VERSION:=caa8d3e6887f5c70e54df555dd78e4e45cfa74cc
PKG_SOURCE:=$(PKG_SOURCE_SUBDIR)-$(PKG_SOURCE_VERSION).tar.gz
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_SOURCE_SUBDIR)
# The tarball is kept next to this Makefile (./dist) on the hardware
# acceleration base, where dl/ is a download cache outside git; the 24.10 tree
# has it in dl/ already.
PKG_SOURCE_URL:=file://$(CURDIR)/dist
PKG_HASH:=63016302c2550d2e70bf84d3d0b0d3eb7c7197eb878aa7322f5fd67c24c97ba9
PKG_LICENSE:=LGPL-2.0
PKG_LICENSE_FILES:=COPYING

PKG_FIXUP:=autoreconf

include $(INCLUDE_DIR)/package.mk

define Package/libmicroxml
  SECTION:=libs
  CATEGORY:=Libraries
  TITLE:=XML library
  MAINTAINER:=Luka Perkov <luka@openwrt.org>
endef

define Package/libmicroxml/description
 A micro sized XML library
endef

CONFIGURE_ARGS += \
        --disable-threads \
        --enable-static \
        --enable-shared

define Build/InstallDev
	$(INSTALL_DIR) $(1)/usr/include
	$(CP) $(PKG_BUILD_DIR)/microxml.h $(1)/usr/include
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_BUILD_DIR)/libmicroxml.so* $(1)/usr/lib
	$(INSTALL_DIR) $(1)/usr/lib/pkgconfig
	$(CP) $(PKG_BUILD_DIR)/microxml.pc $(1)/usr/lib/pkgconfig
endef

define Package/libmicroxml/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_BUILD_DIR)/libmicroxml.so* $(1)/usr/lib
endef

$(eval $(call BuildPackage,libmicroxml))

