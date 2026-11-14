#!/bin/sh
# Check a built LS1088A-RDB SD image before it goes to a board:
#   - the kernel that was built is 6.12.94, no kernel patch left a reject, and
#     it is the kernel the hardware acceleration of this board needs: patch
#     114 (vfio-fsl-mc maps the cache-enabled area of a QBMan portal as
#     Normal memory) is applied and /proc/self/pagemap is there
#     (CONFIG_PROC_PAGE_MONITOR). Patch 115 (dpaa2-eth drops frames from
#     queues without a context) is evidence of a bug of the MC only and must
#     not be applied. Both are looked for in the patch directory and in the
#     kernel source that was built.
#   - the kernel has 802.1Q VLAN, the bridge netfilter family (ebtables) and
#     the netlink interface of IPsec that strongSwan uses
#   - the ports are made at boot by phy_init, with one flow steering entry
#     each, and br-lan gets eth6 and eth7 on this board
#   - the sysupgrade image built next to it has image version 3.0, so the
#     24.10 firmware (2.0) refuses it, with a message that says to write the
#     SD card; the root filesystem gives the board the same version
#   - root has no password: credentials come when every feature is done
# The full image (config_LS1088ARDB) also has:
#   - the packages brought over from the 24.10 firmware, as on the LS1046A-RDB
#     image: Node.js, the web UI, the DNS filter, the FIDO server, the TR-069
#     client, the captive portal, the proxy, DynRouting, Multi-WAN, bmcqos,
#     the feature services and configuration of files/; the default network
#     is the one of files/ (br-lan on 192.168.5.1)
#   - the firewall is fw3 on iptables-legacy: no fw4 and no software flow
#     offloading module; VLAN interfaces and a PPPoE wan are possible, the
#     PPPoE server of the tests is not in the image
#   - nothing of NXP ASK, which is for the LS1046A-RDB only
#   - Tăng tốc phần cứng of this board: bmcHwAccel built for the engine, the
#     engine (bmcHwAccelDpdk) with its client, the scripts that decide and
#     build its layout at boot, dpdk-pdump; the DPDK
#     test applications (dpdk-tools) in a development image only, not in a
#     release image (LS1088_RELEASE=1)
# The minimal image (LS1088_MINIMAL=1, config_LS1088ARDB_MINIMAL) has the DPDK
# applications instead of the BMC packages.
# The image version is read from the sysupgrade image. The kernel and the root
# filesystem are read from the build directories of this tree, so run this
# right after the build that produced the image.
#
# Usage: [LS1088_MINIMAL=1] scripts/ls1088/check-image.sh [sdcard.img.gz]
# Without an argument the image under bin/ of this tree is checked.
set -eu

TOP=$(cd "$(dirname "$0")/../.." && pwd)
case "${1:-}" in
''|/*) IMG=${1:-} ;;
*) IMG=$PWD/$1 ;;
esac
cd "$TOP"

MINIMAL=
case "${LS1088_MINIMAL:-0}" in
0) ;;
1) MINIMAL=1 ;;
*) echo "check-image: LS1088_MINIMAL must be 0 or 1, not '$LS1088_MINIMAL'" >&2; exit 2 ;;
esac
RELEASE=
case "${LS1088_RELEASE:-0}" in
0) ;;
1) RELEASE=1 ;;
*) echo "check-image: LS1088_RELEASE must be 0 or 1, not '$LS1088_RELEASE'" >&2; exit 2 ;;
esac
DPDKONLY=
case "${LS1088_DPDKONLY:-0}" in
0) ;;
1) DPDKONLY=1 ;;
*) echo "check-image: LS1088_DPDKONLY must be 0 or 1, not '$LS1088_DPDKONLY'" >&2; exit 2 ;;
esac
IMG=${IMG:-$(ls bin/targets/layerscape/armv8_64b-glibc/*fsl_ls1088a-rdb-sdboot-squashfs-sdcard.img.gz 2>/dev/null | head -1)}
KERNEL=6.12.94
PATCHES=target/linux/layerscape/patches-6.12
PATCH_PAGEMAP=114-vfio-fsl-mc-map-qbman-cena-cacheable-non-shareable.patch
# Image version of the new base; the 24.10 firmware has 2.0.
COMPAT=3.0
DEVICE=fsl,ls1088a-rdb-sdboot
# br-lan of a card written anew, from files/etc/config/network.
LAN_ADDR=192.168.5.1
FWTOOL=staging_dir/host/bin/fwtool

rc=0
ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; rc=1; }
has()  { [ -n "$ROOT" ] && { [ -e "$ROOT/$1" ] || [ -L "$ROOT/$1" ]; }; }
# Each file must be in the root filesystem. tc and flock are links with an
# absolute target.
files() { for f; do if has "$f"; then ok "rootfs has /$f"; else fail "rootfs lacks /$f"; fi; done; }

LINUX_DIR=$(ls -d build_dir/target-*_glibc/linux-layerscape_armv8_64b/linux-$KERNEL 2>/dev/null | head -1)
if [ -n "$LINUX_DIR" ]; then
	ok "kernel $KERNEL was built"
	rej=$(find "$LINUX_DIR" -name '*.rej' | wc -l)
	if [ "$rej" -eq 0 ]; then ok "no kernel patch reject"; else fail "$rej kernel patch reject file(s) in $LINUX_DIR"; fi
	for opt in PROC_PAGE_MONITOR VLAN_8021Q NETFILTER_FAMILY_BRIDGE XFRM_USER; do
		if grep -qx "CONFIG_$opt=y" "$LINUX_DIR/.config"; then
			ok "kernel has CONFIG_$opt"
		else
			fail "kernel lacks CONFIG_$opt"
		fi
	done
	if [ -f "$PATCHES/$PATCH_PAGEMAP" ] &&
		grep -q 'pgprot_cached_ns(vma->vm_page_prot)' "$LINUX_DIR/drivers/vfio/fsl-mc/vfio_fsl_mc.c" 2>/dev/null; then
		ok "patch 114 is applied: the cache-enabled area of a QBMan portal is Normal memory"
	else
		fail "patch 114 ($PATCH_PAGEMAP) is not in $PATCHES or not in the kernel that was built"
	fi
	p115=$(ls "$PATCHES"/115-* 2>/dev/null | head -1)
	if [ -n "$p115" ]; then
		fail "patch 115 is in $PATCHES (${p115##*/}); it is kept as evidence only"
	elif grep -q 'without context' "$LINUX_DIR/drivers/net/ethernet/freescale/dpaa2/dpaa2-eth.c" 2>/dev/null; then
		fail "the kernel that was built has patch 115 (dpaa2-eth drops frames without context); build it again"
	else
		ok "patch 115 is not applied"
	fi
else
	fail "no linux-$KERNEL build directory"
fi

if [ -n "$IMG" ] && [ -f "$IMG" ]; then
	ok "image $IMG"
else
	fail "image not found: ${IMG:-bin/targets/layerscape/armv8_64b-glibc/*sdcard.img.gz}"
fi

ROOT=$(ls -d build_dir/target-*_glibc/root-layerscape 2>/dev/null | head -1)
[ -n "$ROOT" ] || fail "no glibc root-layerscape build directory"

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

files lib/ld-linux-aarch64.so.1 usr/bin/restool usr/bin/ls-addni bin/bash \
	etc/init.d/phy_init etc/rc.d/S90phy_init etc/uci-defaults/20_ls1088a-rdb-lan-ports
if has etc/init.d/phy_init && [ -x "$ROOT/etc/init.d/phy_init" ] &&
	grep -q 'ls-addni --fs-entries=1 ' "$ROOT/etc/init.d/phy_init"; then
	ok "phy_init makes the ports with one flow steering entry each"
else
	fail "/etc/init.d/phy_init is not executable or does not make the ports with ls-addni --fs-entries=1"
fi
if [ -n "$ROOT" ] && grep -q '^root::' "$ROOT/etc/shadow" 2>/dev/null; then
	ok "root has no password"
else
	fail "root has a password in /etc/shadow; credentials come when every feature is done"
fi
for f in usr/bin/cmm etc/init.d/cmm usr/lib/bmcHwAccel/fastforward "lib/modules/$KERNEL/cdx.ko" \
	"lib/modules/$KERNEL/fci.ko" "lib/modules/$KERNEL/auto_bridge.ko"; do
	if has "$f"; then fail "rootfs has /$f, which is NXP ASK for the LS1046A-RDB"; else ok "rootfs has no /$f"; fi
done

if [ -n "$MINIMAL" ]; then
	if has usr/sbin/bmchwaccel; then fail "the minimal image has /usr/sbin/bmchwaccel"; else ok "the minimal image has no bmchwaccel"; fi
	files usr/bin/dpdk-testpmd usr/bin/dpdk-l3fwd usr/bin/dpdk-test usr/bin/dynamic_dpl.sh
	[ $rc -eq 0 ] && echo "check-image: PASS (minimal image)  $IMG" || echo "check-image: FAIL"
	exit $rc
fi

if [ -n "$DPDKONLY" ]; then
	# The engine, its layout at boot, and bmcHwAccel driving it.
	files usr/sbin/bmchwaccel-engine usr/sbin/bmchwaccel-ctl usr/sbin/bmchwaccel-syncd \
		usr/sbin/bmchwaccel usr/lib/bmcHwAccelDpdk/layout usr/lib/bmcHwAccelDpdk/container \
		etc/init.d/bmchwaccel-layout etc/init.d/bmchwaccel-engine etc/init.d/bmchwaccel-syncd \
		etc/init.d/bmcHwAccel etc/config/bmchwaccel usr/lib/bmcHwAccel/engine.sh \
		usr/lib/bmcHwAccel/supervise usr/lib/bmcHwAccel/supervise-engine
	if [ -n "$ROOT" ] && grep -q 'bmchwaccel-ctl' "$ROOT/usr/lib/bmcHwAccel/engine.sh" 2>/dev/null &&
		[ ! -e "$ROOT/usr/lib/bmcHwAccel/engine-dpdk.sh" ]; then
		ok "bmcHwAccel drives bmchwaccel-engine (its engine.sh is the one of the DPAA2 boards)"
	else
		fail "/usr/lib/bmcHwAccel/engine.sh is not the one of the DPAA2 boards"
	fi
	# The firewall stack the engine keeps the first packet on: fw3 on iptables-legacy.
	files sbin/fw3 usr/sbin/xtables-legacy-multi usr/sbin/ipset usr/sbin/conntrack \
		usr/bin/flock etc/config/firewall
	if [ "$(readlink "$ROOT/usr/sbin/iptables" 2>/dev/null)" = xtables-legacy-multi ]; then
		ok "iptables is the legacy variant"
	else
		fail "/usr/sbin/iptables is not xtables-legacy-multi"
	fi
	# Nothing of the BMC feature set, and no dpdk-tools.
	for f in usr/bin/node usr/bin/bmcfirewall etc/bmcweb/backend/server.bundle.js \
		etc/bmcfido/app.js usr/sbin/easycwmpd usr/sbin/chilli usr/sbin/radiusd \
		usr/sbin/squid usr/bin/c-icap usr/sbin/clamd usr/sbin/http-file-tracker \
		usr/sbin/zebra usr/sbin/bmcdynrouting usr/sbin/mwan3 usr/sbin/bmcmultiwan \
		etc/init.d/bmcqos etc/bmcqos/bmcqos.sh sbin/fw4 \
		usr/bin/dpdk-testpmd usr/bin/dpdk-l2fwd usr/bin/dpdk-l3fwd usr/bin/dpdk-test usr/bin/dynamic_dpl.sh; do
		if has "$f"; then fail "the dpdk-only image has /$f"; else ok "the dpdk-only image has no /$f"; fi
	done
	# No IPsec: no strongSwan, so no SA is ever handed to the engine (the engine
	# layout also makes no DPSECI, see files/container). IPsec falls to the kernel.
	for f in usr/sbin/ipsec usr/lib/ipsec/charon usr/lib/ipsec/starter; do
		if has "$f"; then fail "the dpdk-only image has /$f (strongSwan)"; else ok "the dpdk-only image has no /$f"; fi
	done
	# The trimmed overlay: the default network of files/, but none of its BMC
	# services, their configuration, or the BMC certificates and keys.
	if [ -n "$ROOT" ] && grep -A 4 "^config interface 'lan'" "$ROOT/etc/config/network" 2>/dev/null |
		grep -q "option ipaddr '$LAN_ADDR'"; then
		ok "the default network is the one of files/, br-lan on $LAN_ADDR"
	else
		fail "/etc/config/network does not put br-lan on $LAN_ADDR; the overlay is wrong"
	fi
	for f in etc/certificate/bmc.key etc/certificate/bmc.crt etc/config/account \
		etc/init.d/macfilter etc/config/macfilter etc/init.d/client_control etc/config/client_control \
		etc/init.d/ddos_protect etc/config/ddos_protect etc/init.d/nat_one2one etc/config/nat11 \
		etc/init.d/dhcpguard etc/config/dhcpguard etc/config/acl_control; do
		if has "$f"; then fail "the dpdk-only image still has BMC overlay /$f"; else ok "the dpdk-only image has no /$f"; fi
	done
	# phy_init makes the ports; it is in the trimmed overlay.
	files etc/init.d/phy_init etc/rc.d/S90phy_init
	[ $rc -eq 0 ] && echo "check-image: PASS (dpdk-only image)  $IMG" || echo "check-image: FAIL"
	exit $rc
fi

files usr/bin/node usr/bin/bmcfirewall etc/bmcfirewall.yaml etc/init.d/bmcfirewall \
	etc/bmcweb/backend/server.bundle.js etc/bmcweb/users.json etc/init.d/bmcwebUI \
	etc/bmcfido/app.js etc/init.d/bmcfido usr/sbin/easycwmpd \
	etc/certificate/bmc.key etc/certificate/bmc.crt etc/config/account \
	etc/init.d/macfilter etc/init.d/client_control etc/init.d/nat_one2one etc/init.d/ddos_protect \
	etc/config/macfilter etc/config/client_control etc/config/nat11 etc/config/ddos_protect \
	usr/bin/jq usr/sbin/ipset usr/sbin/ebtables-legacy \
	sbin/fw3 usr/sbin/xtables-legacy-multi "lib/modules/$KERNEL/iptable_nat.ko" \
	"lib/modules/$KERNEL/xt_MASQUERADE.ko" etc/config/firewall \
	usr/sbin/pppd "lib/modules/$KERNEL/pppoe.ko" lib/netifd/proto/ppp.sh
# Captive portal and proxy, as in the 24.10 firmware.
files usr/sbin/chilli usr/sbin/chilli_query etc/init.d/chilli etc/config/chilli etc/chilli/up.sh \
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
	usr/sbin/http-file-tracker etc/config/http-file-tracker etc/init.d/http-file-tracker
# DynRouting and Multi-WAN, as in the 24.10 firmware: FRR and mwan3 with the two BMC CLIs.
files usr/sbin/zebra usr/sbin/mgmtd usr/sbin/ospfd usr/sbin/ripd usr/sbin/bgpd usr/sbin/watchfrr \
	usr/bin/vtysh usr/sbin/frrcommon.sh usr/sbin/watchfrr.sh etc/init.d/frr \
	usr/sbin/bmcdynrouting etc/init.d/bmcDynRouting etc/config/bmcDynRouting \
	etc/hotplug.d/iface/90-bmcDynRouting usr/share/bmcDynRouting/firewall.include \
	usr/sbin/mwan3 usr/sbin/mwan3track usr/sbin/mwan3rtmon etc/init.d/mwan3 \
	usr/sbin/bmcmultiwan etc/init.d/bmcMultiWAN etc/config/bmcMultiWAN \
	usr/share/bmcMultiWAN/firewall.include usr/lib/bmcMultiWAN/flush.sh
# bmcqos with its qdiscs and actions.
files etc/init.d/bmcqos etc/bmcqos/bmcqos.sh usr/lib/bmcqos/firewall.sh etc/config/bmcqos \
	usr/share/bmcqos/firewall.include etc/hotplug.d/iface/13-bmcqos sbin/tc \
	"lib/modules/$KERNEL/sch_cake.ko" "lib/modules/$KERNEL/ifb.ko" "lib/modules/$KERNEL/act_ctinfo.ko" \
	"lib/modules/$KERNEL/act_mirred.ko" "lib/modules/$KERNEL/xt_connmark.ko" "lib/modules/$KERNEL/xt_DSCP.ko" \
	usr/sbin/conntrack usr/bin/flock
# IPsec for the VPN page.
files usr/sbin/ipsec usr/lib/ipsec/charon usr/lib/ipsec/starter
# Tăng tốc phần cứng: the engine, its layout at boot, capture of its ports, and bmcHwAccel driving it.
files usr/sbin/bmchwaccel-engine usr/sbin/bmchwaccel-ctl usr/lib/bmcHwAccelDpdk/layout usr/lib/bmcHwAccelDpdk/container \
	etc/init.d/bmchwaccel-layout etc/rc.d/S11bmchwaccel-layout \
	etc/init.d/bmchwaccel-engine etc/rc.d/S91bmchwaccel-engine usr/bin/dpdk-pdump usr/bin/dpdk-proc-info \
	usr/sbin/bmchwaccel usr/lib/bmcHwAccel/engine.sh usr/lib/bmcHwAccel/supervise-engine \
	etc/init.d/bmcHwAccel etc/rc.d/S54bmcHwAccel etc/config/bmchwaccel \
	usr/sbin/bmchwaccel-syncd etc/init.d/bmchwaccel-syncd usr/lib/bmcHwAccel/supervise
# The daemon's own init script is disabled at first boot: bmcHwAccel starts it.
if [ -n "$ROOT" ] && grep -q 'daemon_initd=/etc/init.d/bmchwaccel-syncd\|BMCHWACCEL_DAEMON_INITD:-/etc/init.d/bmchwaccel-syncd' \
	"$ROOT/usr/lib/bmcHwAccel/engine.sh" 2>/dev/null &&
	grep -q '"$daemon_initd" disable' "$ROOT/etc/uci-defaults/99-bmcHwAccel" 2>/dev/null; then
	ok "bmcHwAccel starts and stops bmchwaccel-syncd, whose own init script the first boot disables"
else
	fail "bmchwaccel-syncd is not the daemon of bmcHwAccel, or its init script is not disabled at first boot"
fi
if [ -n "$ROOT" ] && grep -q 'bmchwaccel-ctl' "$ROOT/usr/lib/bmcHwAccel/engine.sh" 2>/dev/null &&
	[ ! -e "$ROOT/usr/lib/bmcHwAccel/engine-dpdk.sh" ]; then
	ok "bmcHwAccel drives bmchwaccel-engine (its engine.sh is the one of the DPAA2 boards)"
else
	fail "/usr/lib/bmcHwAccel/engine.sh is not the one of the DPAA2 boards"
fi
if [ -n "$RELEASE" ]; then
	for f in usr/bin/dpdk-testpmd usr/bin/dpdk-l2fwd usr/bin/dpdk-l3fwd usr/bin/dpdk-test usr/bin/dynamic_dpl.sh; do
		if has "$f"; then fail "release image has /$f (dpdk-tools)"; else ok "release image has no /$f"; fi
	done
else
	files usr/bin/dpdk-testpmd usr/bin/dpdk-l2fwd usr/bin/dpdk-l3fwd usr/bin/dpdk-test usr/bin/dynamic_dpl.sh
fi

if [ -n "$ROOT" ] && grep -q "option enabled '0'" "$ROOT/etc/config/bmcqos" 2>/dev/null &&
	grep -q "option WAN 'eth0'" "$ROOT/etc/config/bmcqos" 2>/dev/null; then
	ok "bmcqos is off on a card written anew, and set for wan (eth0)"
else
	fail "/etc/config/bmcqos does not set enabled '0' and WAN 'eth0'"
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
	if has "$f"; then fail "rootfs has /$f"; else ok "rootfs has no /$f"; fi
done
if grep -q "flow_offloading" "$ROOT/etc/config/firewall" 2>/dev/null; then
	fail "/etc/config/firewall sets flow_offloading"
else
	ok "/etc/config/firewall does not set flow_offloading"
fi

[ $rc -eq 0 ] && echo "check-image: PASS${RELEASE:+ (release image)}  $IMG" || echo "check-image: FAIL"
exit $rc
