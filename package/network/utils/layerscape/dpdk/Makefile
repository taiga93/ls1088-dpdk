#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#
# NXP DPDK 22.11.7, the one of the NXP release for kernel 6.12
# (lf-6.12.49-2.2.0), for the DPAA2 boards (LS1088A, LS2088A). Options as in
# dpdk_22.11.bb of the NXP Yocto distribution. The applications are linked
# with the DPDK libraries and drivers statically and need only the C library.
#
# Two packages:
#   dpdk        what a router with Tăng tốc phần cứng may carry: dpdk-pdump
#               (captures the ports of a running DPDK process) and
#               dpdk-proc-info. The engine of bmcHwAccelDpdk links the static
#               libraries this package stages.
#   dpdk-tools  test applications that take DPAA2 ports for themselves:
#               testpmd, l2fwd, l3fwd, dpdk-test, the measurements of the
#               SEC (dpdk-test-crypto-perf, dpdk-test-security-perf,
#               ipsec-secgw), and dynamic_dpl.sh, which gives ports to DPDK
#               at run time. Development images only: on a router they could
#               take a port away from the engine.
#
# Before a test application runs, the board needs hugepages (2 MB pages, e.g.
# 256 of them), which the engine layout of bmcHwAccelDpdk reserves at boot
# and the kernel layout does not:
#   echo 256 > /proc/sys/vm/nr_hugepages
#   mkdir -p /dev/hugepages && mount -t hugetlbfs none /dev/hugepages
# and a container of DPAA2 objects for DPDK, made by dynamic_dpl.sh from
# DPAA2 MACs the kernel does not use. Its DPNIs must not have
# DPNI_OPT_SINGLE_SENDER, its default: with the MC 10.39.0 the second one
# made breaks Tx queues of a kernel port (.scratch/hw-accel/mc-single-sender-bug):
#   DPNI_OPTIONS=DPNI_OPT_CUSTOM_CG,DPNI_OPT_HAS_OPR,DPNI_OPT_OPR_PER_TC \
#   MAX_TCS=1 . dynamic_dpl.sh dpni-dpni
# On the LS1088A the DPNIs of the kernel leave room in the WRIOP lookup
# tables for DPNIs of one traffic class only, hence MAX_TCS=1.

include $(TOPDIR)/rules.mk

PKG_NAME:=dpdk
PKG_VERSION:=22.11.7
PKG_RELEASE:=1

NXP_RELEASE:=lf-6.12.49-2.2.0
PKG_SOURCE:=$(PKG_NAME)-$(NXP_RELEASE).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/nxp-qoriq/dpdk/tar.gz/$(NXP_RELEASE)?
PKG_HASH:=084c4939b0cb369e8de624ddbc52bf5d2cc3ac2e3577975d18068c17c42e4dad
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(NXP_RELEASE)

PKG_LICENSE:=BSD-3-Clause
PKG_LICENSE_FILES:=license/bsd-3-clause.txt

PKG_FLAGS:=nonshared

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/meson.mk

# -O3, as NXP builds it (-Doptimization=3 below): the -Os of the target flags
# comes after it on the command line and would win.
TARGET_CFLAGS:=$(filter-out -O%,$(TARGET_CFLAGS))

# The build runs python scripts that read ELF files with pyelftools
# (buildtools/pmdinfogen.py). It is plain python and needs no build, so it is
# taken from its source archive. The host build of python-pyelftools in the
# packages feed of v25.12.5 fails: it does not ask for setuptools.
PYELFTOOLS:=pyelftools-0.32
define Download/pyelftools
  FILE:=$(PYELFTOOLS).tar.gz
  URL:=https://files.pythonhosted.org/packages/source/p/pyelftools
  HASH:=6de90ee7b8263e740c8715a925382d4099b354f29ac48ea40d840cf7aa14ace5
endef
$(eval $(call Download,pyelftools))

MESON_VARS+=PYTHONPATH=$(PKG_BUILD_DIR)/$(PYELFTOOLS)

define Build/Prepare
	$(call Build/Prepare/Default)
	$(TAR) -C $(PKG_BUILD_DIR) -xzf $(DL_DIR)/$(PYELFTOOLS).tar.gz $(PYELFTOOLS)/elftools
endef

define Package/dpdk/Default
  SECTION:=net
  CATEGORY:=Network
  URL:=https://github.com/nxp-qoriq/dpdk
endef

define Package/dpdk
  $(call Package/dpdk/Default)
  TITLE:=NXP DPDK for DPAA2
  # libpcap, jansson, libelf, libbsd: DPDK uses them when it finds them
  # staged, and then links them into every application. Named here so that
  # the result does not depend on the order of the build.
  # KERNEL_PROC_PAGE_MONITOR: /proc/self/pagemap. The fslmc bus looks up the
  # physical address of every hugepage before it maps it into the IOMMU, in
  # IOVA as VA mode too, and finds no DPAA2 port without it.
  DEPENDS:=@TARGET_layerscape_armv8_64b +restool +libpcap +jansson +libelf +libbsd \
	+@KERNEL_PROC_PAGE_MONITOR
endef

define Package/dpdk/description
  NXP DPDK 22.11.7 with the DPAA2 drivers (fslmc bus, dpaa2 net, event and
  sec) and the TAP and virtio-user ports: dpdk-pdump, which captures the
  ports of a running DPDK process, and dpdk-proc-info. Its static libraries
  are for applications such as bmchwaccel-engine (bmcHwAccelDpdk).
endef

define Package/dpdk-tools
  $(call Package/dpdk/Default)
  TITLE:=NXP DPDK test applications for DPAA2
  # bash: dynamic_dpl.sh. zlib: the compression tests of dpdk-test. tun: the
  # TAP port of testpmd.
  DEPENDS:=@TARGET_layerscape_armv8_64b +dpdk +bash +kmod-tun +zlib
endef

define Package/dpdk-tools/description
  The DPDK applications for tests on a DPAA2 board, which take ports for
  themselves: testpmd, l2fwd, l3fwd, dpdk-test, dpdk-test-crypto-perf,
  dpdk-test-security-perf and ipsec-secgw for the SEC, and dynamic_dpl.sh,
  which gives DPAA2 ports to DPDK at run time. Not for a router in use.
endef

# Only the drivers of the DPAA2 boards and the software ports. DPDK picks up
# every library it finds in the staging directory otherwise, and the
# applications would then need them on the board. dpdk-pdump writes its
# capture through a net_pcap port that the primary process (the engine)
# makes as well, so net/pcap is in both.
DPDK_DRIVERS:= \
	common/dpaax \
	bus/fslmc bus/vdev bus/pci \
	mempool/dpaa2 mempool/ring \
	dma/dpaa2 \
	net/dpaa2 net/tap net/virtio net/ring net/null net/pcap \
	event/dpaa2 \
	crypto/dpaa2_sec

MESON_ARGS+= \
	--cross-file $(PKG_BUILD_DIR)/dpaa-cross.txt \
	-Ddefault_library=static \
	-Doptimization=3 \
	-Denable_kmods=false \
	-Denable_driver_sdk=true \
	-Denable_docs=false \
	-Denable_drivers=$(subst $(space),$(comma),$(strip $(DPDK_DRIVERS))) \
	-Denable_apps=test-pmd,proc-info,pdump,test-crypto-perf,test-security-perf \
	-Dexamples=l2fwd,l3fwd,ipsec-secgw \
	-Denable_examples_bin_install=true \
	-Denable_examples_source_install=false \
	-Ddrivers_install_subdir=

# The SoC is a property of the cross file; a second cross file adds it to
# the one of meson.mk.
define Build/Configure
	printf "[properties]\nplatform = 'dpaa'\n" > $(PKG_BUILD_DIR)/dpaa-cross.txt
	$(call Build/Configure/Meson)
endef

DPDK_APPS:=dpdk-pdump dpdk-proc-info
DPDK_TOOLS:=dpdk-testpmd dpdk-l2fwd dpdk-l3fwd dpdk-test \
	dpdk-test-crypto-perf dpdk-test-security-perf dpdk-ipsec-secgw

# Headers, static libraries and libdpdk.pc, for applications linked with
# DPDK statically, such as bmchwaccel-engine (package bmcHwAccelDpdk).
define Build/InstallDev
	$(INSTALL_DIR) $(1)/usr/include $(1)/usr/lib/pkgconfig
	$(CP) $(PKG_INSTALL_DIR)/usr/include/* $(1)/usr/include/
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/*.a $(1)/usr/lib/
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/pkgconfig/libdpdk*.pc $(1)/usr/lib/pkgconfig/
endef

define Package/dpdk/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(foreach app,$(DPDK_APPS),$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/$(app) $(1)/usr/bin/;)
endef

define Package/dpdk-tools/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(foreach app,$(DPDK_TOOLS),$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/$(app) $(1)/usr/bin/;)
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/nxp/dpaa2/dynamic_dpl.sh $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/nxp/dpaa2/destroy_dynamic_dpl.sh $(1)/usr/bin/
endef

$(eval $(call BuildPackage,dpdk))
$(eval $(call BuildPackage,dpdk-tools))
