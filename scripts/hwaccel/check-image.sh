#!/bin/sh
# Check a built LS1046A-RDB SD image before it is written to a card:
#   - the kernel that was built is 6.12.94 and no kernel patch left a reject
#   - the kernel has the bridge netfilter family, which cdx and auto_bridge
#     hook into
#   - the device tree of the board sets the MDC frequency of the bus the
#     10G copper PHY gets its firmware over (2.5 MHz, from the FMan clock)
#   - the FMan microcode slot (offset 9M) holds the ASK microcode 210.10.1. A
#     development build made without that file holds the public 106.x one; this
#     is a warning, and a failure in a release build
#     (CONFIG_FMAN_UCODE_ASK_REQUIRED in .config, or HWACCEL_RELEASE=1 in the
#     environment)
#   - the U-Boot environment (offset 5M) gives every port a development MAC
#     address
#   - the root filesystem carries the ASK modules, daemon and port map
#   - it carries bmcHwAccel, enabled by default, with its configuration among
#     the files sysupgrade keeps; no ASK module is loaded by the boot itself
#   - the daemon is started so that traffic between two br-lan ports stays on
#     the CPU
#   - the firewall is fw3 on iptables-legacy: no fw4 and no software flow
#     offloading module
#   - VLAN interfaces and a PPPoE wan are possible: 802.1Q in the kernel, pppd
#     with its PPPoE plugin and module; the PPPoE server of the tests is not
#     in the image
#   - the packages brought over from the 24.10 firmware are in it: Node.js,
#     the web UI, the DNS filter, the FIDO server, the TR-069 client, and the
#     feature services and configuration of files/; the default network is
#     the one of files/ (br-lan on 192.168.5.1)
#   - the sysupgrade image built next to it has image version 3.0, so the
#     24.10 firmware (2.0) refuses it, with a message that says to write the
#     SD card; the root filesystem gives the board the same version
# The microcode and the environment are read from the image itself, the image
# version from the sysupgrade image. The kernel and the root filesystem are
# read from the build directories of this tree, so run this right after the
# build that produced the image.
#
# Usage: scripts/hwaccel/check-image.sh [sdcard.img.gz]
# Without an argument the image under bin/ of this tree is checked.
set -eu

TOP=$(cd "$(dirname "$0")/../.." && pwd)
case "${1:-}" in
''|/*) IMG=${1:-} ;;
*) IMG=$PWD/$1 ;;
esac
cd "$TOP"

IMG=${IMG:-$(ls bin/targets/layerscape/armv8_64b/*fsl_ls1046a-rdb-sdboot-squashfs-sdcard.img.gz 2>/dev/null | head -1)}
KERNEL=6.12.94
MDC_HZ=2500000
UCODE_OFFSET=9437184
UCODE_SIZE=51652
UCODE_SHA256=$(sh package/firmware/layerscape/fman-ucode/ask-ucode.sh expected | cut -d' ' -f1)
PUBLIC_UCODE=$(ls build_dir/target-*/fman-ucode-*/fsl_fman_ucode_ls1046_r1.0_106_4_18.bin 2>/dev/null | head -1)
ENV_OFFSET=5242880
ENV_SRC=package/boot/uboot-layerscape/files/fsl_ls1046a-rdb-sdboot-uEnv.txt
# ethaddr and eth1addr to eth7addr, as in the PoC.
DEV_MACS=8
# Image version of the hardware acceleration base; the 24.10 firmware has 2.0.
COMPAT=3.0
DEVICE=fsl,ls1046a-rdb-sdboot
# br-lan of a card written anew, from files/etc/config/network.
LAN_ADDR=192.168.5.1
FWTOOL=staging_dir/host/bin/fwtool

rc=0
warned=
ok()   { echo "ok    $*"; }
warn() { echo "WARN  $*"; warned=1; }
fail() { echo "FAIL  $*"; rc=1; }

sha256() { { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1; }
# sha256 of the first <size> bytes of the microcode slot of the image.
slot_sha256() { gunzip -c "$IMG" | tail -c +$((UCODE_OFFSET + 1)) | head -c "$1" | sha256; }
release_build() {
	[ "${HWACCEL_RELEASE:-0}" = 1 ] || grep -qx 'CONFIG_FMAN_UCODE_ASK_REQUIRED=y' .config 2>/dev/null
}

LINUX_DIR=$(ls -d build_dir/target-*/linux-layerscape_armv8_64b/linux-$KERNEL 2>/dev/null | head -1)
if [ -n "$LINUX_DIR" ]; then
	ok "kernel $KERNEL was built"
	rej=$(find "$LINUX_DIR" -name '*.rej' | wc -l)
	if [ "$rej" -eq 0 ]; then ok "no kernel patch reject"; else fail "$rej kernel patch reject file(s) in $LINUX_DIR"; fi
	if grep -qx 'CONFIG_NETFILTER_FAMILY_BRIDGE=y' "$LINUX_DIR/.config"; then
		ok "kernel has the bridge netfilter family"
	else
		fail "kernel lacks CONFIG_NETFILTER_FAMILY_BRIDGE; cdx and auto_bridge will not load"
	fi
	if grep -qx 'CONFIG_VLAN_8021Q=y' "$LINUX_DIR/.config"; then
		ok "kernel has 802.1Q VLAN"
	else
		fail "kernel lacks CONFIG_VLAN_8021Q"
	fi
else
	fail "no linux-$KERNEL build directory"
fi

# Without it the firmware upload of the AQR113C takes 27 s of the boot.
DTB=$(ls build_dir/target-*/linux-layerscape_armv8_64b/image-fsl-ls1046a-rdb-ask.dtb 2>/dev/null | head -1)
MDIO=/soc/fman@1a00000/mdio@fd000
if ! command -v fdtget >/dev/null 2>&1; then
	warn "no fdtget here; the MDC frequency in the device tree was not checked"
elif [ -z "$DTB" ]; then
	fail "no image-fsl-ls1046a-rdb-ask.dtb in the kernel build directory"
elif [ "$(fdtget -t u "$DTB" $MDIO clock-frequency 2>/dev/null)" = "$MDC_HZ" ] &&
	[ "$(fdtget -t x "$DTB" $MDIO clocks 2>/dev/null)" = "$(fdtget -t x "$DTB" /soc/fman@1a00000 clocks 2>/dev/null)" ]; then
	ok "device tree sets MDC of the 10G PHY bus to $MDC_HZ Hz from the FMan clock"
else
	fail "device tree does not set clock-frequency $MDC_HZ and the FMan clock on $MDIO"
fi

if [ -n "$IMG" ] && [ -f "$IMG" ]; then
	got=$(slot_sha256 $UCODE_SIZE)
	if [ "$got" = "$UCODE_SHA256" ]; then
		ok "ASK microcode 210.10.1 at 9M, sha256 matches"
	elif release_build; then
		fail "release build, but the microcode at 9M is not the ASK 210.10.1 file (sha256 $got)"
	elif [ -n "$PUBLIC_UCODE" ] &&
		[ "$(slot_sha256 "$(wc -c < "$PUBLIC_UCODE")")" = "$(sha256 < "$PUBLIC_UCODE")" ]; then
		warn "microcode at 9M is the public 106.4.18; hardware acceleration will not start, not for release"
	else
		fail "microcode at 9M is neither the ASK 210.10.1 file nor the public 106.4.18 (sha256 $got)"
	fi
	# The MAC variables of the development environment, as the image has them.
	env=$(gunzip -c "$IMG" | tail -c +$((ENV_OFFSET + 1)) | head -c $((UCODE_OFFSET - ENV_OFFSET)) |
		LC_ALL=C tr '\0' '\n' | LC_ALL=C grep -a -E '^eth[0-9]*addr=' || true)
	macs=0
	for v in $(grep -E '^eth[0-9]*addr=' "$ENV_SRC"); do
		! echo "$env" | grep -qxF "$v" || macs=$((macs + 1))
	done
	if [ $macs -eq $DEV_MACS ]; then
		ok "U-Boot environment has the $DEV_MACS development MAC addresses"
	else
		fail "U-Boot environment has $macs of the $DEV_MACS development MAC addresses of $ENV_SRC"
	fi
else
	fail "image not found: ${IMG:-bin/targets/layerscape/armv8_64b/*sdcard.img.gz}"
fi

ROOT=$(ls -d build_dir/target-*/root-layerscape 2>/dev/null | head -1)
[ -n "$ROOT" ] || fail "no root-layerscape build directory"

# The metadata of the sysupgrade image is what a running firmware decides on.
SYSUPGRADE=${IMG%-sdcard.img.gz}-sysupgrade.bin
if [ -z "$IMG" ] || [ ! -f "$SYSUPGRADE" ] || [ ! -x "$FWTOOL" ]; then
	fail "no sysupgrade image next to the SD card image, or no $FWTOOL"
elif ! meta=$("$FWTOOL" -q -i /dev/stdout "$SYSUPGRADE" 2>/dev/null); then
	fail "the sysupgrade image has no metadata that $FWTOOL can read"
else
	if echo "$meta" | grep -q "\"compat_version\": \"$COMPAT\""; then
		ok "sysupgrade image has image version $COMPAT"
	else
		fail "sysupgrade image does not have image version $COMPAT; the 24.10 firmware would install it"
	fi
	if echo "$meta" | grep -q '"compat_message": "[^"]*Write the whole SD card'; then
		ok "its message says to write the SD card"
	else
		fail "the message of the sysupgrade image does not say to write the SD card"
	fi
	if echo "$meta" | grep -q "\"new_supported_devices\": *\[\"$DEVICE\"\]"; then
		ok "it is for $DEVICE"
	else
		fail "the sysupgrade image is not for $DEVICE"
	fi
fi
# The board must know the same version, or it refuses its own updates.
if grep -A 4 "^[[:space:]]*$DEVICE)" "$ROOT/etc/uci-defaults/05_fix-compat-version" 2>/dev/null |
	grep -q "compat_version=\"$COMPAT\""; then
	ok "rootfs sets image version $COMPAT on $DEVICE"
else
	fail "rootfs does not set image version $COMPAT on $DEVICE (etc/uci-defaults/05_fix-compat-version)"
fi
for f in "lib/modules/$KERNEL/cdx.ko" "lib/modules/$KERNEL/fci.ko" \
	"lib/modules/$KERNEL/auto_bridge.ko" usr/bin/cmm usr/bin/dpa_app \
	etc/cdx_cfg/ls1046a-rdb.xml \
	sbin/fw3 usr/sbin/xtables-legacy-multi "lib/modules/$KERNEL/iptable_nat.ko" \
	"lib/modules/$KERNEL/xt_MASQUERADE.ko" etc/config/firewall \
	etc/uci-defaults/20_ls1046a-rdb-lan-ports \
	usr/sbin/pppd "lib/modules/$KERNEL/pppoe.ko" lib/netifd/proto/ppp.sh \
	usr/sbin/bmchwaccel usr/lib/bmcHwAccel/supervise etc/init.d/bmcHwAccel etc/rc.d/S54bmcHwAccel \
	etc/uci-defaults/99-bmcHwAccel; do
	if [ -n "$ROOT" ] && [ -e "$ROOT/$f" ]; then ok "rootfs has /$f"; else fail "rootfs lacks /$f"; fi
done

for f in usr/bin/node usr/bin/bmcfirewall etc/bmcfirewall.yaml etc/init.d/bmcfirewall \
	etc/bmcweb/backend/server.bundle.js etc/bmcweb/users.json etc/init.d/bmcwebUI \
	etc/bmcfido/app.js etc/init.d/bmcfido usr/sbin/easycwmpd \
	etc/certificate/bmc.key etc/certificate/bmc.crt etc/config/account \
	etc/init.d/macfilter etc/init.d/client_control etc/init.d/nat_one2one etc/init.d/ddos_protect \
	etc/config/macfilter etc/config/client_control etc/config/nat11 etc/config/ddos_protect \
	bin/bash usr/bin/jq usr/sbin/ipset usr/sbin/ebtables-legacy; do
	if [ -n "$ROOT" ] && [ -e "$ROOT/$f" ]; then ok "rootfs has /$f"; else fail "rootfs lacks /$f"; fi
done
# Captive portal and proxy, as in the 24.10 firmware.
for f in usr/sbin/chilli usr/sbin/chilli_query etc/init.d/chilli etc/config/chilli etc/chilli/up.sh \
	etc/chilli/check_brlan_ip.sh etc/chilli/check_listgarden_brlan.sh etc/init.d/add-cron \
	"lib/modules/$KERNEL/xt_coova.ko" usr/lib/iptables/libxt_coova.so "lib/modules/$KERNEL/tun.ko" \
	usr/sbin/radiusd etc/init.d/radiusd etc/init.d/freeradius3_db_init \
	etc/freeradius3/raddb/sql/sqlite/schema.sql etc/freeradius3/mods-available/sql \
	usr/lib/freeradius3/rlm_sql_sqlite.so usr/lib/ossl-modules/legacy.so \
	www/portal.html www/cgi-bin/portal_login.sh \
	usr/sbin/squid usr/lib/squid/security_file_certgen etc/squid/squid.conf etc/squid/ssl_cert/squid_CA.pem \
	etc/squid/update_squid_conf.sh etc/init.d/squid \
	usr/bin/c-icap etc/c-icap/c-icap.conf etc/init.d/c-icap \
	usr/lib/c_icap/squidclamav.so etc/c-icap/squidclamav.conf etc/hotplug.d/iface/99-squid-update \
	usr/sbin/http-file-tracker etc/config/http-file-tracker etc/init.d/http-file-tracker; do
	if [ -n "$ROOT" ] && [ -e "$ROOT/$f" ]; then ok "rootfs has /$f"; else fail "rootfs lacks /$f"; fi
done
# DynRouting and Multi-WAN, as in the 24.10 firmware: FRR and mwan3 with the two BMC CLIs.
for f in usr/sbin/zebra usr/sbin/mgmtd usr/sbin/ospfd usr/sbin/ripd usr/sbin/bgpd usr/sbin/watchfrr \
	usr/bin/vtysh usr/sbin/frrcommon.sh usr/sbin/watchfrr.sh etc/init.d/frr \
	usr/sbin/bmcdynrouting etc/init.d/bmcDynRouting etc/config/bmcDynRouting \
	etc/hotplug.d/iface/90-bmcDynRouting usr/share/bmcDynRouting/firewall.include \
	usr/sbin/mwan3 usr/sbin/mwan3track usr/sbin/mwan3rtmon etc/init.d/mwan3 \
	usr/sbin/bmcmultiwan etc/init.d/bmcMultiWAN etc/config/bmcMultiWAN \
	usr/share/bmcMultiWAN/firewall.include usr/lib/bmcMultiWAN/flush.sh; do
	if [ -n "$ROOT" ] && [ -e "$ROOT/$f" ]; then ok "rootfs has /$f"; else fail "rootfs lacks /$f"; fi
done
# bmcqos, and what bmcHwAccel needs to keep the WAN it shapes on the CPU: the rule
# the daemon reads, the firewall include, conntrack to mark open connections.
for f in etc/init.d/bmcqos etc/bmcqos/bmcqos.sh usr/lib/bmcqos/firewall.sh etc/config/bmcqos \
	usr/share/bmcqos/firewall.include etc/hotplug.d/iface/13-bmcqos sbin/tc \
	"lib/modules/$KERNEL/sch_cake.ko" "lib/modules/$KERNEL/ifb.ko" "lib/modules/$KERNEL/act_ctinfo.ko" \
	"lib/modules/$KERNEL/act_mirred.ko" "lib/modules/$KERNEL/xt_connmark.ko" "lib/modules/$KERNEL/xt_DSCP.ko" \
	usr/lib/bmcHwAccel/keep.sh usr/lib/bmcHwAccel/fastforward usr/share/bmcHwAccel/firewall.include \
	etc/hotplug.d/iface/20-bmcHwAccel \
	usr/sbin/conntrack usr/bin/flock; do
	# tc and flock are links with an absolute target.
	if [ -n "$ROOT" ] && { [ -e "$ROOT/$f" ] || [ -L "$ROOT/$f" ]; }; then ok "rootfs has /$f"; else fail "rootfs lacks /$f"; fi
done
if [ -n "$ROOT" ] && grep -q "option enabled '0'" "$ROOT/etc/config/bmcqos" 2>/dev/null &&
	grep -q "option WAN 'eth0'" "$ROOT/etc/config/bmcqos" 2>/dev/null; then
	ok "bmcqos is off on a card written anew, and set for wan (eth0)"
else
	fail "/etc/config/bmcqos does not set enabled '0' and WAN 'eth0'"
fi
if [ -n "$ROOT" ] && grep -q '^[[:space:]]*option mark 65536 mask 65536$' "$ROOT/usr/lib/bmcHwAccel/fastforward" 2>/dev/null &&
	grep -q '/usr/lib/bmcHwAccel/fastforward' "$ROOT/usr/sbin/cmm-supervise" 2>/dev/null; then
	ok "the daemon is started with the rule that keeps marked connections out of the hardware"
else
	fail "the daemon is not given /usr/lib/bmcHwAccel/fastforward (mark 0x10000)"
fi
# Bridged flows stay on the CPU (ticket 19): the daemon knows -B and is started
# with it unless the configuration of bmcHwAccel says "bridge" 1.
if [ -n "$ROOT" ] && grep -q 'c:f:n:hvFRB' "$ROOT/usr/bin/cmm" 2>/dev/null &&
	grep -q '^bridge=-B$' "$ROOT/usr/sbin/cmm-supervise" 2>/dev/null &&
	! grep -q 'option bridge' "$ROOT/etc/config/bmchwaccel" 2>/dev/null; then
	ok "the daemon is started with -B: traffic between two br-lan ports stays on the CPU"
else
	fail "the daemon is not started with -B, or does not know it: traffic between two br-lan ports would pass macfilter and client_control in the hardware"
fi
if [ -n "$ROOT" ] && grep -q "option enabled '0'" "$ROOT/etc/config/bmcMultiWAN" 2>/dev/null; then
	ok "Multi-WAN is off on a card written anew"
else
	fail "/etc/config/bmcMultiWAN does not set enabled '0'"
fi
if [ -n "$ROOT" ] && grep -q "'security_mode:string:nac'" "$ROOT/etc/init.d/system" 2>/dev/null; then
	ok "the security mode of a new board is nac, the captive portal"
else
	fail "/etc/init.d/system does not know the security mode (nac, fido, off)"
fi
if [ -n "$ROOT" ] && ls "$ROOT"/usr/lib/libmicroxml.so* >/dev/null 2>&1; then
	ok "rootfs has the XML library of the TR-069 client"
else
	fail "rootfs lacks /usr/lib/libmicroxml.so*"
fi
if [ -n "$ROOT" ] && grep -A 4 "^config interface 'lan'" "$ROOT/etc/config/network" 2>/dev/null |
	grep -q "option ipaddr '$LAN_ADDR'"; then
	ok "the default network is the one of files/, br-lan on $LAN_ADDR"
else
	fail "/etc/config/network does not put br-lan on $LAN_ADDR; files/ is not in the image"
fi

if [ -n "$ROOT" ] && grep -q "option enabled '1'" "$ROOT/etc/config/bmchwaccel" 2>/dev/null; then
	ok "hardware acceleration is enabled by default"
else
	fail "/etc/config/bmchwaccel does not set enabled '1'"
fi
if [ -n "$ROOT" ] && grep -rqx '/etc/config/bmchwaccel' "$ROOT"/lib/apk/packages/*.conffiles 2>/dev/null; then
	ok "/etc/config/bmchwaccel is kept by sysupgrade"
else
	fail "/etc/config/bmchwaccel is not a configuration file of a package; sysupgrade would not keep it"
fi
# bmcHwAccel loads them, and only while hardware acceleration is enabled.
if [ -z "$ROOT" ] || grep -rqx -E 'cdx|fci|auto_bridge' "$ROOT/etc/modules.d" "$ROOT/etc/modules-boot.d" 2>/dev/null; then
	fail "an ASK module is loaded at boot (/etc/modules.d)"
else
	ok "no ASK module is loaded at boot"
fi
if [ -n "$ROOT" ] && ls "$ROOT"/usr/lib/pppd/*/pppoe.so >/dev/null 2>&1; then
	ok "rootfs has the PPPoE plugin of pppd"
else
	fail "rootfs lacks /usr/lib/pppd/*/pppoe.so"
fi
if [ "$(readlink "$ROOT/usr/sbin/iptables" 2>/dev/null)" = xtables-legacy-multi ]; then
	ok "iptables is the legacy variant"
else
	fail "/usr/sbin/iptables is not xtables-legacy-multi"
fi
for f in sbin/fw4 "lib/modules/$KERNEL/nf_flow_table.ko" "lib/modules/$KERNEL/xt_FLOWOFFLOAD.ko" \
	usr/sbin/pppoe-server; do
	[ -n "$ROOT" ] || break
	if [ ! -e "$ROOT/$f" ]; then ok "rootfs has no /$f"; else fail "rootfs has /$f"; fi
done
if grep -q "flow_offloading" "$ROOT/etc/config/firewall" 2>/dev/null; then
	fail "/etc/config/firewall sets flow_offloading"
else
	ok "/etc/config/firewall does not set flow_offloading"
fi

[ $rc -eq 0 ] && echo "check-image: PASS${warned:+ with warnings}  $IMG" || echo "check-image: FAIL"
exit $rc
