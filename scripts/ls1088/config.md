# Cấu hình build: lý do của từng lựa chọn

File cấu hình dùng để build là `.config` đầy đủ ở gốc repo (`make defconfig`
sinh ra, không có chú thích): `config_LS1088ARDB` (image đầy đủ), `config_LS1088ARDB_MINIMAL` (`LS1088_MINIMAL=1`). `build.sh` và `./bmc_build_prepare.sh`
chép nó thành `.config` rồi chạy `make defconfig`.

Dưới đây là các dòng được chọn có chủ đích, kèm lý do, giữ nguyên văn từ file
seed cũ đã được thay bằng các file đầy đủ. Chỉ để đọc, build không dùng tới.
Khi đổi một lựa chọn ở đây, đổi luôn trong file đầy đủ (xem
"Đổi cấu hình" trong `bmc_build_prepare.sh`).

## `config_LS1088ARDB`

```
CONFIG_TARGET_layerscape=y
CONFIG_TARGET_layerscape_armv8_64b=y
CONFIG_TARGET_layerscape_armv8_64b_DEVICE_fsl_ls1088a-rdb-sdboot=y
# glibc, as on the 24.10 firmware: the hardware acceleration of this board
# (DPDK) runs its workers on threads with the default stack, 128 KiB on musl,
# and keeps the backtrace of a crash. The base picks a libc only with these two on. Must stay
# as the toolchain was built with them.
CONFIG_DEVEL=y
CONFIG_TOOLCHAINOPTS=y
CONFIG_LIBC_USE_GLIBC=y
CONFIG_TARGET_ROOTFS_PARTSIZE=256
# The board image is squashfs. The ext4 image of the root filesystem that the
# build makes besides is used by nothing, and with bmcqos the files no longer
# fit the 256 MB it is made with.
# CONFIG_TARGET_ROOTFS_EXT4FS is not set
CONFIG_PACKAGE_firewall=y
# CONFIG_PACKAGE_firewall4 is not set
CONFIG_PACKAGE_iptables-zz-legacy=y
CONFIG_PACKAGE_kmod-ebtables=y
CONFIG_PACKAGE_ip6tables-zz-legacy=y
# Tăng tốc phần cứng on DPAA2: bmcHwAccel (the CLI bmchwaccel, as on the
# LS1046) drives the engine (bmcHwAccelDpdk, linked with the DPDK of the dpdk
# package), which boots the board in the engine layout. What it drives on the
# LS1046, NXP ASK, is for DPAA1 and does not run on the DPAA2 of this board;
# the device of this board picks the engine (BMCHWACCEL_DPDK). The ASK
# kernel patches are in the kernel all the same, with none of its modules
# loaded.
CONFIG_PACKAGE_bmcHwAccel=y
CONFIG_BMCHWACCEL_DPDK=y
CONFIG_PACKAGE_bmcHwAccelDpdk=y
# The DPDK test applications, in development images only: build.sh leaves
# them out of a release image (LS1088_RELEASE=1).
CONFIG_PACKAGE_dpdk-tools=y
# bmcqos, as in the 24.10 profile, with its qdisc modules (cake, IFB, ctinfo)
# and tc.
CONFIG_PACKAGE_bmcqos=y
# CONFIG_PACKAGE_nftables-json is not set
# CONFIG_PACKAGE_kmod-nft-offload is not set
# Built but not installed: the PPPoE server of the LS1046A-RDB tests
# (scripts/hwaccel/tests/qemu-test.sh), as in that seed.
CONFIG_PACKAGE_rp-pppoe-server=m
# The BMC packages brought over from the 24.10 firmware. bmcwebUI is not in
# this repository: see "The web UI" in scripts/hwaccel/README.md.
CONFIG_PACKAGE_bmcfirewall=y
CONFIG_PACKAGE_bmcfido=y
CONFIG_PACKAGE_bmcwebUI=y
CONFIG_PACKAGE_easycwmp=y
CONFIG_PACKAGE_libmicroxml=y
# CONFIG_EASYCWMP_DATA_MODEL_TR181 is not set
CONFIG_EASYCWMP_DATA_MODEL_TR98=y
# What the web UI and the feature scripts of files/ call, as selected in the
# 24.10 profile. Not carried:
# the nftables variants of the tables tools, flow offloading, opkg (the base
# has apk).
CONFIG_PACKAGE_node=y
CONFIG_PACKAGE_node-npm=y
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_isc-dhcp-relay-ipv4=y
CONFIG_PACKAGE_uhttpd=y
CONFIG_PACKAGE_rpcd=y
CONFIG_PACKAGE_haserl=y
CONFIG_PACKAGE_syslog-ng=y
CONFIG_PACKAGE_logrotate=y
CONFIG_PACKAGE_jq=y
CONFIG_PACKAGE_sqlite3-cli=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_openssl-util=y
CONFIG_PACKAGE_coreutils=y
CONFIG_PACKAGE_coreutils-base64=y
CONFIG_PACKAGE_coreutils-sleep=y
CONFIG_PACKAGE_flock=y
CONFIG_PACKAGE_getopt=y
CONFIG_PACKAGE_tar=y
# CONFIG_PACKAGE_TAR_XZ is not set
CONFIG_PACKAGE_gzip=y
CONFIG_PACKAGE_bzip2=y
CONFIG_PACKAGE_strace=y
# ip-full and not ip-tiny: apk refuses the two together (the 24.10 profile has
# both). With it the tools the LS1046 image has as device packages.
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_ethtool-full=y
CONFIG_PACKAGE_tcpdump=y
CONFIG_PACKAGE_iperf3=y
CONFIG_PACKAGE_conntrack=y
# The DPAA2 ports: restool and its ls-addni, which /etc/init.d/phy_init calls
# at boot (restool is a device package, ls-addni needs bash).
CONFIG_PACKAGE_restool=y
# The kernel the hardware acceleration of this board needs, with or without
# the dpdk package (which selects it too): the DPAA2 bus of DPDK reads
# /proc/self/pagemap.
CONFIG_KERNEL_PROC_PAGE_MONITOR=y
# The TAP device of the captive portal.
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_ip-bridge=y
CONFIG_PACKAGE_iputils-arping=y
CONFIG_PACKAGE_resolveip=y
CONFIG_PACKAGE_bind-client=y
CONFIG_PACKAGE_block-mount=y
CONFIG_PACKAGE_mount-utils=y
CONFIG_PACKAGE_nand-utils=y
CONFIG_PACKAGE_uboot-envtools=y
CONFIG_PACKAGE_zoneinfo-core=y
CONFIG_PACKAGE_zoneinfo-asia=y
# Tables tools and matches (fw3 on iptables-legacy).
CONFIG_PACKAGE_ipset=y
CONFIG_PACKAGE_arptables-legacy=y
CONFIG_PACKAGE_ebtables-legacy=y
CONFIG_PACKAGE_ebtables-legacy-utils=y
CONFIG_PACKAGE_kmod-ebtables-ipv4=y
CONFIG_PACKAGE_kmod-ebtables-ipv6=y
CONFIG_PACKAGE_kmod-ebtables-watchers=y
CONFIG_PACKAGE_kmod-br-netfilter=y
CONFIG_PACKAGE_iptables-mod-checksum=y
CONFIG_PACKAGE_iptables-mod-cluster=y
CONFIG_PACKAGE_iptables-mod-conntrack-extra=y
CONFIG_PACKAGE_iptables-mod-extra=y
CONFIG_PACKAGE_iptables-mod-filter=y
CONFIG_PACKAGE_iptables-mod-hashlimit=y
CONFIG_PACKAGE_iptables-mod-ipopt=y
CONFIG_PACKAGE_iptables-mod-iprange=y
CONFIG_PACKAGE_iptables-mod-ipsec=y
CONFIG_PACKAGE_iptables-mod-led=y
CONFIG_PACKAGE_iptables-mod-nat-extra=y
CONFIG_PACKAGE_iptables-mod-nflog=y
CONFIG_PACKAGE_iptables-mod-nfqueue=y
CONFIG_PACKAGE_iptables-mod-physdev=y
CONFIG_PACKAGE_iptables-mod-rpfilter=y
CONFIG_PACKAGE_iptables-mod-socket=y
CONFIG_PACKAGE_iptables-mod-tee=y
CONFIG_PACKAGE_iptables-mod-tproxy=y
CONFIG_PACKAGE_iptables-mod-trace=y
CONFIG_PACKAGE_iptables-mod-u32=y
CONFIG_PACKAGE_ip6tables-extra=y
CONFIG_PACKAGE_ip6tables-mod-nat=y
CONFIG_PACKAGE_kmod-ipt-ipset=y
CONFIG_PACKAGE_kmod-ipt-raw=y
CONFIG_PACKAGE_kmod-ipt-raw6=y
CONFIG_PACKAGE_kmod-ipt-conntrack-label=y
CONFIG_PACKAGE_kmod-nf-nathelper=y
CONFIG_PACKAGE_kmod-nf-nathelper-extra=y
CONFIG_PACKAGE_kmod-nf-ipvs=y
CONFIG_PACKAGE_kmod-nf-ipvs-ftp=y
CONFIG_PACKAGE_kmod-nf-ipvs-sip=y
# IPsec, for the VPN page of the web UI (/etc/ipsec.conf, "ipsec"): the
# strongSwan packages of the 24.10 profile, one by one. strongswan-full, which
# selects them there, cannot be selected without CONFIG_DEVEL on this base, and
# strongSwan 6 no longer has the bliss, newhope, ntru and uci plugins.
# strongswan-swanctl is left out: its service starts a second charon next to
# the one of the "ipsec" service, and the two cannot run together.
# strongswan-mod-af-alg is left out: at every start it asks the kernel for each
# algorithm it knows, and each one the kernel does not have costs a modprobe.
# In the QEMU test that takes longer than the starter waits, which then kills
# charon and starts it again without end. The openssl plugin has what IKE needs.
CONFIG_PACKAGE_kmod-ipsec=y
CONFIG_PACKAGE_kmod-ipsec4=y
CONFIG_PACKAGE_kmod-ipsec6=y
CONFIG_PACKAGE_kmod-xfrm-interface=y
CONFIG_PACKAGE_strongswan=y
CONFIG_PACKAGE_strongswan-charon=y
CONFIG_PACKAGE_strongswan-charon-cmd=y
CONFIG_PACKAGE_strongswan-ipsec=y
CONFIG_PACKAGE_strongswan-libtls=y
CONFIG_PACKAGE_strongswan-mod-addrblock=y
CONFIG_PACKAGE_strongswan-mod-aes=y
CONFIG_PACKAGE_strongswan-mod-agent=y
CONFIG_PACKAGE_strongswan-mod-attr=y
CONFIG_PACKAGE_strongswan-mod-attr-sql=y
CONFIG_PACKAGE_strongswan-mod-blowfish=y
CONFIG_PACKAGE_strongswan-mod-ccm=y
CONFIG_PACKAGE_strongswan-mod-chapoly=y
CONFIG_PACKAGE_strongswan-mod-cmac=y
CONFIG_PACKAGE_strongswan-mod-connmark=y
CONFIG_PACKAGE_strongswan-mod-constraints=y
CONFIG_PACKAGE_strongswan-mod-coupling=y
CONFIG_PACKAGE_strongswan-mod-ctr=y
CONFIG_PACKAGE_strongswan-mod-curl=y
CONFIG_PACKAGE_strongswan-mod-curve25519=y
CONFIG_PACKAGE_strongswan-mod-des=y
CONFIG_PACKAGE_strongswan-mod-dhcp=y
CONFIG_PACKAGE_strongswan-mod-dnskey=y
CONFIG_PACKAGE_strongswan-mod-drbg=y
CONFIG_PACKAGE_strongswan-mod-duplicheck=y
CONFIG_PACKAGE_strongswan-mod-eap-dynamic=y
CONFIG_PACKAGE_strongswan-mod-eap-identity=y
CONFIG_PACKAGE_strongswan-mod-eap-md5=y
CONFIG_PACKAGE_strongswan-mod-eap-mschapv2=y
CONFIG_PACKAGE_strongswan-mod-eap-radius=y
CONFIG_PACKAGE_strongswan-mod-eap-tls=y
CONFIG_PACKAGE_strongswan-mod-farp=y
CONFIG_PACKAGE_strongswan-mod-fips-prf=y
CONFIG_PACKAGE_strongswan-mod-forecast=y
CONFIG_PACKAGE_strongswan-mod-gcm=y
CONFIG_PACKAGE_strongswan-mod-gcrypt=y
CONFIG_PACKAGE_strongswan-mod-gmp=y
CONFIG_PACKAGE_strongswan-mod-ha=y
CONFIG_PACKAGE_strongswan-mod-hmac=y
CONFIG_PACKAGE_strongswan-mod-kdf=y
CONFIG_PACKAGE_strongswan-mod-kernel-netlink=y
CONFIG_PACKAGE_strongswan-mod-ldap=y
CONFIG_PACKAGE_strongswan-mod-led=y
CONFIG_PACKAGE_strongswan-mod-load-tester=y
CONFIG_PACKAGE_strongswan-mod-md4=y
CONFIG_PACKAGE_strongswan-mod-md5=y
CONFIG_PACKAGE_strongswan-mod-mgf1=y
CONFIG_PACKAGE_strongswan-mod-mysql=y
CONFIG_PACKAGE_strongswan-mod-openssl=y
CONFIG_PACKAGE_strongswan-mod-pem=y
CONFIG_PACKAGE_strongswan-mod-pgp=y
CONFIG_PACKAGE_strongswan-mod-pkcs1=y
CONFIG_PACKAGE_strongswan-mod-pkcs11=y
CONFIG_PACKAGE_strongswan-mod-pkcs12=y
CONFIG_PACKAGE_strongswan-mod-pkcs7=y
CONFIG_PACKAGE_strongswan-mod-pkcs8=y
CONFIG_PACKAGE_strongswan-mod-pubkey=y
CONFIG_PACKAGE_strongswan-mod-random=y
CONFIG_PACKAGE_strongswan-mod-rc2=y
CONFIG_PACKAGE_strongswan-mod-resolve=y
CONFIG_PACKAGE_strongswan-mod-revocation=y
CONFIG_PACKAGE_strongswan-mod-sha1=y
CONFIG_PACKAGE_strongswan-mod-sha2=y
CONFIG_PACKAGE_strongswan-mod-sha3=y
CONFIG_PACKAGE_strongswan-mod-smp=y
CONFIG_PACKAGE_strongswan-mod-socket-default=y
CONFIG_PACKAGE_strongswan-mod-sql=y
CONFIG_PACKAGE_strongswan-mod-sqlite=y
CONFIG_PACKAGE_strongswan-mod-sshkey=y
CONFIG_PACKAGE_strongswan-mod-stroke=y
CONFIG_PACKAGE_strongswan-mod-test-vectors=y
CONFIG_PACKAGE_strongswan-mod-unity=y
CONFIG_PACKAGE_strongswan-mod-updown=y
CONFIG_PACKAGE_strongswan-mod-vici=y
CONFIG_PACKAGE_strongswan-mod-whitelist=y
CONFIG_PACKAGE_strongswan-mod-wolfssl=y
CONFIG_PACKAGE_strongswan-mod-x509=y
CONFIG_PACKAGE_strongswan-mod-xauth-eap=y
CONFIG_PACKAGE_strongswan-mod-xauth-generic=y
CONFIG_PACKAGE_strongswan-mod-xcbc=y
CONFIG_PACKAGE_strongswan-pki=y
# Tunnels and dynamic DNS pages of the web UI.
CONFIG_PACKAGE_kmod-wireguard=y
CONFIG_PACKAGE_gre=y
CONFIG_PACKAGE_kmod-gre6=y
CONFIG_PACKAGE_kmod-vxlan=y
CONFIG_PACKAGE_kmod-veth=y
CONFIG_PACKAGE_map=y
CONFIG_PACKAGE_ddns-scripts=y
CONFIG_PACKAGE_ddns-scripts-cloudflare=y
CONFIG_PACKAGE_ddns-scripts-cnkuai=y
CONFIG_PACKAGE_ddns-scripts-digitalocean=y
CONFIG_PACKAGE_ddns-scripts-dnspod=y
CONFIG_PACKAGE_ddns-scripts-dnspod-v3=y
CONFIG_PACKAGE_ddns-scripts-freedns=y
CONFIG_PACKAGE_ddns-scripts-gandi=y
CONFIG_PACKAGE_ddns-scripts-gcp=y
CONFIG_PACKAGE_ddns-scripts-godaddy=y
CONFIG_PACKAGE_ddns-scripts-huaweicloud=y
CONFIG_PACKAGE_ddns-scripts-luadns=y
CONFIG_PACKAGE_ddns-scripts-noip=y
CONFIG_PACKAGE_ddns-scripts-ns1=y
CONFIG_PACKAGE_ddns-scripts-nsupdate=y
CONFIG_PACKAGE_ddns-scripts-one=y
CONFIG_PACKAGE_ddns-scripts-pdns=y
CONFIG_PACKAGE_ddns-scripts-porkbun=y
CONFIG_PACKAGE_ddns-scripts-route53=y
CONFIG_PACKAGE_ddns-scripts-transip=y
# Captive portal (NAC, the security mode a new board starts in): CoovaChilli
# with its kernel match, FreeRADIUS with the SQLite user database. The feed
# packages with the BMC changes are in package/coova-chilli and
# package/freeradius3. Selections as in the 24.10 profile.
CONFIG_PACKAGE_coova-chilli=y
CONFIG_COOVACHILLI_MINIPORTAL=y
CONFIG_COOVACHILLI_OPENSSL=y
CONFIG_PACKAGE_kmod-ipt-coova=y
CONFIG_PACKAGE_freeradius3=y
CONFIG_FREERADIUS3_OPENSSL=y
CONFIG_PACKAGE_freeradius3-common=y
CONFIG_PACKAGE_freeradius3-default=y
CONFIG_PACKAGE_freeradius3-democerts=y
CONFIG_PACKAGE_freeradius3-mod-always=y
CONFIG_PACKAGE_freeradius3-mod-attr-filter=y
CONFIG_PACKAGE_freeradius3-mod-chap=y
CONFIG_PACKAGE_freeradius3-mod-detail=y
CONFIG_PACKAGE_freeradius3-mod-digest=y
CONFIG_PACKAGE_freeradius3-mod-eap=y
CONFIG_PACKAGE_freeradius3-mod-eap-gtc=y
CONFIG_PACKAGE_freeradius3-mod-eap-md5=y
CONFIG_PACKAGE_freeradius3-mod-eap-mschapv2=y
CONFIG_PACKAGE_freeradius3-mod-eap-peap=y
CONFIG_PACKAGE_freeradius3-mod-eap-pwd=y
CONFIG_PACKAGE_freeradius3-mod-eap-tls=y
CONFIG_PACKAGE_freeradius3-mod-eap-ttls=y
CONFIG_PACKAGE_freeradius3-mod-exec=y
CONFIG_PACKAGE_freeradius3-mod-expiration=y
CONFIG_PACKAGE_freeradius3-mod-expr=y
CONFIG_PACKAGE_freeradius3-mod-files=y
CONFIG_PACKAGE_freeradius3-mod-logintime=y
CONFIG_PACKAGE_freeradius3-mod-mschap=y
CONFIG_PACKAGE_freeradius3-mod-pap=y
CONFIG_PACKAGE_freeradius3-mod-preprocess=y
CONFIG_PACKAGE_freeradius3-mod-radutmp=y
CONFIG_PACKAGE_freeradius3-mod-realm=y
CONFIG_PACKAGE_freeradius3-mod-sql=y
CONFIG_PACKAGE_freeradius3-mod-sql-sqlite=y
CONFIG_PACKAGE_freeradius3-mod-unix=y
CONFIG_PACKAGE_freeradius3-utils=y
# Proxy: squid (package/community/squid: the feed package with the BMC
# configuration), the ICAP server and its antivirus service. ClamAV itself is
# not selected in the 24.10 profile either.
CONFIG_PACKAGE_squid=y
CONFIG_SQUID_enable-ipv6=y
CONFIG_SQUID_enable-icap-client=y
CONFIG_SQUID_enable-ssl-crtd=y
CONFIG_SQUID_use-openssl=y
CONFIG_SQUID_with-nettle=y
CONFIG_PACKAGE_c-icap=y
CONFIG_PACKAGE_libicapapi=y
CONFIG_PACKAGE_squidclamav=y
# ClamAV 1.x needs rust/host; on an aarch64 build host that is a host with
# glibc >= 2.41 (the debian13 container), see working/docker/debian13.
CONFIG_PACKAGE_clamav=y
CONFIG_PACKAGE_freshclam=y
# The log of HTTP file transfers seen on br-lan.
CONFIG_PACKAGE_http-file-tracker=y
CONFIG_PACKAGE_pcapplusplus=y
# DynRouting and Multi-WAN: FRR and mwan3 of the packages feed of v25.12.5,
# selections as in the 24.10 profile. Both features are off after a flash.
CONFIG_PACKAGE_frr=y
CONFIG_FRR_INTERNAL=y
CONFIG_FRR_NO_SNMP=y
CONFIG_PACKAGE_frr-bgpd=y
CONFIG_PACKAGE_frr-ospfd=y
CONFIG_PACKAGE_frr-ripd=y
CONFIG_PACKAGE_frr-watchfrr=y
CONFIG_PACKAGE_frr-zebra=y
CONFIG_PACKAGE_bmcDynRouting=y
CONFIG_PACKAGE_mwan3=y
CONFIG_PACKAGE_bmcMultiWAN=y
```

## `config_LS1088ARDB_MINIMAL`

```
CONFIG_TARGET_layerscape=y
CONFIG_TARGET_layerscape_armv8_64b=y
CONFIG_TARGET_layerscape_armv8_64b_DEVICE_fsl_ls1088a-rdb-sdboot=y
# The board on its own: the packages of the base for this device and what a
# first boot on the bench needs, none of the BMC packages. glibc as in
# config_LS1088ARDB, which must stay as the toolchain was built.
CONFIG_DEVEL=y
CONFIG_TOOLCHAINOPTS=y
CONFIG_LIBC_USE_GLIBC=y
CONFIG_TARGET_ROOTFS_PARTSIZE=256
# CONFIG_TARGET_ROOTFS_EXT4FS is not set
# The DPAA2 ports: restool and its ls-addni (a bash script), which
# /etc/init.d/phy_init calls at boot.
CONFIG_PACKAGE_restool=y
CONFIG_PACKAGE_bash=y
# To look at the ports and push traffic through them.
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_ethtool-full=y
CONFIG_PACKAGE_tcpdump=y
CONFIG_PACKAGE_iperf3=y
CONFIG_PACKAGE_kmod-tun=y
# NXP DPDK with its test applications, for the first measurements on the
# board. Hugepages are not reserved at boot: see the dpdk Makefile.
CONFIG_PACKAGE_dpdk=y
CONFIG_PACKAGE_dpdk-tools=y
```

## `config_LS1088ARDB_DPDKONLY` (`LS1088_DPDKONLY=1`)

```
CONFIG_TARGET_layerscape=y
CONFIG_TARGET_layerscape_armv8_64b=y
CONFIG_TARGET_layerscape_armv8_64b_DEVICE_fsl_ls1088a-rdb-sdboot=y
# The LS1088 DPAA2 board with Tăng tốc phần cứng (the DPDK engine) and nothing
# of the BMC feature set: no web UI, bmcfirewall, bmcfido, bmcqos, Multi-WAN,
# DynRouting, captive portal, proxy/ClamAV, and no IPsec. The engine's IPsec
# code is in its binary all the same (it is one build), but it is never used:
# the container makes no DPSECI (so ESP stays with the kernel) and there is no
# strongSwan to hand the engine an SA. An image to hand over on its own, with
# the forwarding engine and the firewall stack it keeps the first packet on,
# and no source of ours outside the stripped engine binary. build.sh builds it
# with LS1088_DPDKONLY=1; it reserves the trimmed overlay of
# scripts/ls1088/files-dpdk-only (phy_init, network, dhcp only), not files/.
#
# glibc as in config_LS1088ARDB, which the toolchain was built with.
CONFIG_DEVEL=y
CONFIG_TOOLCHAINOPTS=y
CONFIG_LIBC_USE_GLIBC=y
CONFIG_TARGET_ROOTFS_PARTSIZE=256
# CONFIG_TARGET_ROOTFS_EXT4FS is not set
# The fslmc bus of DPDK reads /proc/self/pagemap.
CONFIG_KERNEL_PROC_PAGE_MONITOR=y
# The DPAA2 ports: restool and its ls-addni (a bash script), which
# /etc/init.d/phy_init calls at boot, and ip to look at them and push traffic.
CONFIG_PACKAGE_restool=y
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_ip-full=y
# Enough to measure the image on the bench; none of it is our source.
CONFIG_PACKAGE_ethtool-full=y
CONFIG_PACKAGE_tcpdump=y
CONFIG_PACKAGE_iperf3=y
# NXP DPDK, linked statically into the engine. No dpdk-tools: the test
# applications (dpdk-testpmd, dpdk-pdump, ...) could take a port from the
# engine and let whoever has the image watch the data plane.
CONFIG_PACKAGE_dpdk=y
# CONFIG_PACKAGE_dpdk-tools is not set
# Tăng tốc phần cứng on DPAA2: bmcHwAccel (the CLI bmchwaccel, the layout
# choice at boot, the supervisor) built for bmchwaccel-engine (BMCHWACCEL_DPDK),
# and the engine itself (bmcHwAccelDpdk: bmchwaccel-engine, bmchwaccel-syncd,
# bmchwaccel-ctl). Selecting these two pulls the firewall stack the engine
# keeps the first packet on (fw3 on iptables-legacy, conntrack, ipset,
# physdev, ebtables, flock) through the DEPENDS of bmcHwAccel, and the shared
# libraries of the static DPDK (libpcap, jansson, libelf, libbsd,
# libnetfilter-conntrack, libnfnetlink) through those of bmcHwAccelDpdk.
CONFIG_PACKAGE_bmcHwAccel=y
CONFIG_BMCHWACCEL_DPDK=y
CONFIG_PACKAGE_bmcHwAccelDpdk=y
# fw3, not fw4: the firewall of this board is iptables-legacy, with no nftables
# flow offloading. As in config_LS1088ARDB.
CONFIG_PACKAGE_firewall=y
# CONFIG_PACKAGE_firewall4 is not set
# CONFIG_PACKAGE_kmod-nft-offload is not set
# CONFIG_PACKAGE_kmod-ipt-offload is not set
```
