# Cấu hình build: lý do của từng lựa chọn

File cấu hình dùng để build là `.config` đầy đủ ở gốc repo (`make defconfig`
sinh ra, không có chú thích): `config_LS1046ARDB`. `build.sh` và `./bmc_build_prepare.sh`
chép nó thành `.config` rồi chạy `make defconfig`.

Dưới đây là các dòng được chọn có chủ đích, kèm lý do, giữ nguyên văn từ file
seed cũ đã được thay bằng các file đầy đủ. Chỉ để đọc, build không dùng tới.
Khi đổi một lựa chọn ở đây, đổi luôn trong file đầy đủ (xem
"Đổi cấu hình" trong `bmc_build_prepare.sh`).

## `config_LS1046ARDB`

```
CONFIG_TARGET_layerscape=y
CONFIG_TARGET_layerscape_armv8_64b=y
CONFIG_TARGET_layerscape_armv8_64b_DEVICE_fsl_ls1046a-rdb-sdboot=y
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
CONFIG_PACKAGE_bmcHwAccel=y
# bmcqos, as in the 24.10 profile, with its qdisc modules (cake, IFB, ctinfo)
# and tc. bmcHwAccel keeps the WAN it shapes on the CPU.
CONFIG_PACKAGE_bmcqos=y
# CONFIG_PACKAGE_nftables-json is not set
# CONFIG_PACKAGE_kmod-nft-offload is not set
# Built but not installed: the PPPoE server that tests/qemu-test.sh lets the
# board dial.
CONFIG_PACKAGE_rp-pppoe-server=m
# The BMC packages brought over from the 24.10 firmware. bmcwebUI is not in
# this repository: see "The web UI" in README.md.
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
# ip-full is in the image already; apk refuses ip-tiny next to it (the 24.10
# profile has both).
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
