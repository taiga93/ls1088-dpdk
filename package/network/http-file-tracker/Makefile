include $(TOPDIR)/rules.mk

PKG_NAME:=http-file-tracker
PKG_VERSION:=0.1.1
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
# The 24.10 tree names 0.1.0 in dl/, a tarball that is in no tree; 0.1.1 is
# the release of the tracker's own repository, kept next to this Makefile
# (./dist) because dl/ is a download cache outside git on this base.
PKG_SOURCE_URL:=file://$(CURDIR)/dist
PKG_HASH:=c3b177248107c18753d871ab7f48a53ca825ac9b07d1831271fb6f09d1bd3765
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/http-file-tracker
  SECTION:=net
  CATEGORY:=Network
  TITLE:=HTTP file transfer tracker
  DEPENDS:=+libpcap +libstdcpp +pcapplusplus
endef

define Package/http-file-tracker/description
  Logs CPU-visible cleartext HTTP file transfers for configured LAN clients.
endef

CMAKE_OPTIONS += \
        -DHTTP_FILE_TRACKER_BUILD_TESTS=OFF \
        -DHTTP_FILE_TRACKER_ENABLE_PCAP=ON

define Package/http-file-tracker/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/http-file-tracker $(1)/usr/sbin/http-file-tracker
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/http-file-tracker.config $(1)/etc/config/http-file-tracker
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/http-file-tracker.init $(1)/etc/init.d/http-file-tracker
endef

$(eval $(call BuildPackage,http-file-tracker))
