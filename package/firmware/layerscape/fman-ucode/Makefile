#
# Copyright (C) 2016 Jiang Yutang <jiangyutang1978@gmail.com>
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=fman-ucode
PKG_VERSION:=6.12.20.2.0.0
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/nxp-qoriq/qoriq-fm-ucode
PKG_SOURCE_VERSION:=lf-6.12.20-2.0.0
PKG_MIRROR_HASH:=15b5df228b23b4cbdd1af484c98069b558d32ece15a80f0dabe22af6e5ee1ba1

PKG_FLAGS:=nonshared

# ASK FMan microcode (NXP proprietary, never committed). When the file is
# present it replaces the public 106.x ucode in the LS1046A images, because
# CDX refuses to start on a ucode package older than 209. ask-ucode.sh looks
# for it in ./local/ first, then in $(ASK_UCODE_DIR), which defaults to
# ../ask-ucode/ next to the tree and can be set in the environment, and checks
# its sha256. With CONFIG_FMAN_UCODE_ASK_REQUIRED a missing file fails the
# build.
ASK_UCODE_DIR?=$(TOPDIR)/../ask-ucode
ASK_UCODE_FIND:=sh ./ask-ucode.sh find $(if $(CONFIG_FMAN_UCODE_ASK_REQUIRED),--release) \
	./local "$(ASK_UCODE_DIR)"

# The stamp of the configure step carries the sha256 of the file found, so the
# package is installed again when the file appears, disappears or changes.
ifndef DUMP
  ASK_UCODE_STATE:=$(shell sh ./ask-ucode.sh state ./local "$(ASK_UCODE_DIR)")
endif
PKG_CONFIG_DEPENDS:=CONFIG_FMAN_UCODE_ASK_REQUIRED ASK_UCODE_STATE

include $(INCLUDE_DIR)/package.mk

define Package/layerscape-fman
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=NXP FMan ucode
  DEPENDS:=@TARGET_layerscape||TARGET_qoriq
  DEFAULT:=y if TARGET_layerscape_armv8_64b||TARGET_qoriq
  HIDDEN:=1
endef

define Package/layerscape-fman/config
	config FMAN_UCODE_ASK_REQUIRED
		bool "Release build: fail without the ASK FMan microcode"
		depends on TARGET_layerscape_armv8_64b
		default n
		help
		  The LS1046A images need the proprietary ASK FMan microcode for
		  hardware acceleration. It is not part of the tree; without it
		  a build puts the public 106.x microcode into the image and
		  prints a warning.

		  Say Y for an image that is to be released: the build then
		  fails when the file is missing or its sha256 is wrong. See
		  scripts/hwaccel/README.md for where the file goes.
endef

define Build/Compile
endef

define Build/InstallDev
	$(INSTALL_DIR) $(STAGING_DIR_IMAGE)
	ucode="$$$$($(ASK_UCODE_FIND))" || exit 1; \
	$(CP) "$$$${ucode:-$(PKG_BUILD_DIR)/fsl_fman_ucode_ls1046_r1.0_106_4_18.bin}" \
		$(STAGING_DIR_IMAGE)/fsl_ls1046a-rdb-fman.bin && \
	echo "fman-ucode: LS1046A images use $$$${ucode:-the public ucode 106.4.18}"
	$(CP) $(PKG_BUILD_DIR)/fsl_fman_ucode_ls1043_r1.1_106_4_18.bin \
		$(STAGING_DIR_IMAGE)/fsl_ls1043a-rdb-fman.bin
	$(CP) $(PKG_BUILD_DIR)/fsl_fman_ucode_t4240_r2.0_106_4_18.bin \
		$(STAGING_DIR_IMAGE)/fsl_t4240-rdb-fman.bin
endef

$(eval $(call BuildPackage,layerscape-fman))
