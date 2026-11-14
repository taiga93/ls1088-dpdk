# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2016 Jiang Yutang <jiangyutang1978@gmail.com>

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/image.mk

LS_SD_KERNELPART_SIZE = 40
LS_SD_KERNELPART_OFFSET = 16
LS_SD_ROOTFSPART_OFFSET = 64

ifeq ($(DUMP),)
LS_SD_IMAGE_SIZE = $(shell echo $$((($(LS_SD_ROOTFSPART_OFFSET) + \
	$(CONFIG_TARGET_ROOTFS_PARTSIZE)))))
endif

# The limitation of flash sysupgrade.bin is 1MB dtb + 16MB kernel + 32MB rootfs
LS_SYSUPGRADE_IMAGE_SIZE = 49m

define Image/Prepare
	# Build .dtb for all boards we may run on
	$(foreach dts,$(DEVICE_DTS_LIST),
		$(call Image/BuildDTB,$(DTS_DIR)/$(dts).dts,$(DTS_DIR)/$(dts).dtb)
	)
endef

define Build/ls-clean
	rm -f $@
endef

define Build/ls-append
	dd if=$(STAGING_DIR_IMAGE)/$(1) >> $@
endef

define Build/ls-append-dtb
	dd if=$(DEVICE_DTS_DIR)/$(1).dtb >> $@
endef

define Build/ls-append-kernel
	mkdir -p $@.tmp && \
	cp $(IMAGE_KERNEL) $@.tmp/fitImage && \
	make_ext4fs -J -L kernel -l "$(LS_SD_KERNELPART_SIZE)M" \
		$(if $(SOURCE_DATE_EPOCH),-T $(SOURCE_DATE_EPOCH)) \
		"$@.kernel.part" "$@.tmp" && \
	dd if=$@.kernel.part >> $@ && \
	rm -rf $@.tmp && \
	rm -f $@.kernel.part
endef

define Build/ls-append-sdhead
	./gen_sdcard_head_img.sh $(STAGING_DIR_IMAGE)/$(1)-sdcard-head.img \
		$(LS_SD_KERNELPART_OFFSET) $(LS_SD_KERNELPART_SIZE) \
		$(LS_SD_ROOTFSPART_OFFSET) $(CONFIG_TARGET_ROOTFS_PARTSIZE)
	dd if=$(STAGING_DIR_IMAGE)/$(1)-sdcard-head.img >> $@
endef

define Build/traverse-fit-ls1088
    ./mkits-multiple-config.sh -o $@.its -A $(LINUX_KARCH) \
	-v $(LINUX_VERSION) -k $@ -a $(KERNEL_LOADADDR) \
	-e $(if $(KERNEL_ENTRY),$(KERNEL_ENTRY),$(KERNEL_LOADADDR)) \
	-C gzip -c 1 -c 2 \
	-d $(DTS_DIR)/freescale/fsl-ls1088a-ten64.dtb \
	-D "TEN64" -n "ten64" -a $(FDT_LOADADDR) -c 1 \
	-d $(DTS_DIR)/freescale/fsl-ls1088a-rdb.dtb \
	-D "LS1088ARDB" -n "ls1088ardb" -a $(FDT_LOADADDR) -c 2
	PATH=$(LINUX_DIR)/scripts/dtc:$(PATH) mkimage -f $@.its $@.new
	@mv -f $@.new $@
endef

define Device/fix-sysupgrade
  DEVICE_COMPAT_VERSION := 2.0
  DEVICE_COMPAT_MESSAGE := DTB was added to sysupgrade. Image format is different. \
	To use sysupgrade You need to change firmware partition in bootargs to "49m@0xf00000(firmware)" and saveenv. \
	After that, You can use "sysupgrade -F".
endef

define Device/rework-sdcard-images
  DEVICE_COMPAT_VERSION := 2.0
  DEVICE_COMPAT_MESSAGE := SD-card images were changed to squashfs + ext4 overlay combined images. \
	It is required to flash the entire sd-card again and manually copy config.
endef

# Firmware on the hardware acceleration base (OpenWrt 25.12 with NXP ASK). It
# needs the ASK FMan microcode and MAC addresses in the U-Boot environment,
# both on the card outside what sysupgrade writes, so a board on the 24.10
# firmware (image version 2.0) must not take it. The device side is
# base-files/etc/uci-defaults/05_fix-compat-version.
define Device/hwaccel-base
  DEVICE_COMPAT_VERSION := 3.0
  DEVICE_COMPAT_MESSAGE := This firmware is on the hardware acceleration base. \
	It needs an FMan microcode and MAC addresses that sysupgrade does not write. \
	Write the whole SD card image instead.
endef

# The LS1088A-RDB firmware on the same base, with glibc. No board in the field
# runs the 24.10 firmware of the LS1088A-RDB, and an update from it is not
# supported: a board on that firmware (image version 2.0) must not take this
# image, and gets the whole card written instead. The device side is
# base-files/etc/uci-defaults/05_fix-compat-version.
define Device/ls1088-base
  DEVICE_COMPAT_VERSION := 3.0
  DEVICE_COMPAT_MESSAGE := This firmware is on the hardware acceleration base. \
	An update from the 24.10 firmware of this board is not supported. \
	Write the whole SD card image instead.
endef

include $(SUBTARGET).mk

$(eval $(call BuildImage))
