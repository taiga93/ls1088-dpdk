#!/bin/sh
# The BMC packages brought over from the 24.10 firmware, checked in the built
# root filesystem with its own programs: Node.js runs and can read the web UI
# and the FIDO server, the DNS filter starts far enough to say its version, the
# TR-069 client finds its XML library, the feature services of files/ are
# enabled, their configuration is read by uci, and the kernel modules of the
# matches their scripts use are there. Nothing is started for real: no
# network, no kernel modules. tests/qemu-test.sh boots the image for that.
#
# Run as root inside the build container (aarch64, same as the board):
#   docker exec ubuntu20 sh /home/working/<tree>/scripts/hwaccel/tests/bmc-packages-test.sh
#
# DEVICE is the board the image is for (fsl,ls1046a-rdb-sdboot);
# scripts/ls1088/build.sh test sets it for the LS1088A-RDB, whose image has
# its port script and, for now, no bmchwaccel.
set -u

TOP=$(cd "$(dirname "$0")/../../.." && pwd)
ROOT=$(ls -d "$TOP"/build_dir/target-*/root-layerscape 2>/dev/null | head -1)
[ -n "$ROOT" ] || { echo "bmc-packages-test: no root-layerscape under build_dir; build the image first" >&2; exit 2; }

NODE=v20.18.3
DEVICE=${DEVICE:-fsl,ls1046a-rdb-sdboot}
LAN_ADDR=192.168.5.1

W=$(mktemp -d)
trap 'umount "$W/root/proc" 2>/dev/null; rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rc=0

mkdir "$W/root"
(cd "$ROOT" && tar cf - --exclude=./lib/firmware .) | tar xf - -C "$W/root"
mkdir -p "$W/root/tmp" "$W/root/var/lock" "$W/root/proc"
# musl has ldd; on glibc (the LS1088A-RDB) the loader lists the libraries.
if [ ! -e "$W/root/usr/bin/ldd" ] && [ -x "$W/root/lib/ld-linux-aarch64.so.1" ]; then
	printf '#!/bin/sh\nexec /lib/ld-linux-aarch64.so.1 --list "$@"\n' > "$W/root/usr/bin/ldd"
	chmod 755 "$W/root/usr/bin/ldd"
fi
# Node.js reads /proc/self/exe.
mount -t proc proc "$W/root/proc" 2>/dev/null

in_root() { chroot "$W/root" /bin/sh -c "export PATH=/usr/sbin:/usr/bin:/sbin:/bin; $1"; }
ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; rc=1; }
check() { # description, command for the root filesystem
	if in_root "$2" > "$W/out" 2>&1; then
		ok "$1"
	else
		fail "$1"; sed 's/^/      | /' "$W/out"
	fi
}

check "Node.js is $NODE" "[ \"\$(node --version)\" = $NODE ]"
check "Node.js has its crypto, zlib and HTTPS modules" \
	"node -e 'require(\"crypto\").createHash(\"sha256\"); require(\"zlib\"); require(\"https\")'"
check "Node.js reads the web UI server" "node --check /etc/bmcweb/backend/server.bundle.js"
check "Node.js reads the FIDO server" "node --check /etc/bmcfido/app.js"
check "the web UI has its pages and its certificate" \
	"[ -f /etc/bmcweb/public/pages/mac_filter/mac_filter.html ] && [ -s /etc/certificate/bmc.key ] && [ -s /etc/certificate/bmc.crt ]"
check "the web UI has its accounts" "[ -s /etc/bmcweb/users.json ] || [ -s /etc/bmcweb/backend/users.json ]"
check "the DNS filter says its version" "bmcfirewall --version | grep -q -i 'version'"
check "the DNS filter has its configuration and its ipset list" \
	"[ -s /etc/bmcfirewall.yaml ] && [ -x /etc/create-ipset-lists.sh ] && [ -s /etc/ipset.conf ]"
check "the TR-069 client finds its libraries" \
	"[ -x /usr/sbin/easycwmpd ] && ls /usr/lib/libmicroxml.so* >/dev/null && ! ldd /usr/sbin/easycwmpd 2>&1 | grep -q 'not found'"

for s in bmcwebUI bmcfirewall bmcfido macfilter client_control nat_one2one ddos_protect dhcpguard ipsec; do
	# The scripts of macfilter and ddos_protect have CRLF line ends, as on the
	# 24.10 tree, and the name of their link has the CR of the START line in it.
	check "service $s is enabled" "find /etc/rc.d -name 'S[0-9][0-9]$s' -o -name 'S[0-9][0-9]?$s' | grep -q ."
done
case "$DEVICE" in
fsl,ls1088a-rdb*)
	check "the port script of the board is in the image and enabled" \
		"[ -x /etc/init.d/phy_init ] && ls /etc/rc.d/S90phy_init >/dev/null" ;;
*)
	# files/ is the same for both boards (scripts/ls1088/tests/phy-init-test.sh).
	check "the port script of the LS1088, if there, names only the LS1088A-RDB" \
		"[ ! -e /etc/init.d/phy_init ] || grep -q '^	fsl,ls1088a-rdb|fsl,ls1088a-rdb-sdboot) ' /etc/init.d/phy_init" ;;
esac
# IPsec, for the VPN page of the web UI: strongSwan with the old "ipsec"
# command and /etc/ipsec.conf, which the script of the page writes.
check "strongSwan finds its libraries and has the plugins of an IKEv2 tunnel with a shared key" \
	"for b in charon starter stroke; do [ -x /usr/lib/ipsec/\$b ] && ! ldd /usr/lib/ipsec/\$b 2>&1 | grep -q 'not found' || exit 1; done
	 for m in stroke kernel-netlink socket-default openssl hmac kdf nonce updown; do [ -f /usr/lib/ipsec/plugins/libstrongswan-\$m.so ] || exit 1; done"
check "the ipsec command is there and the script of the VPN page reads its files" \
	"[ -x /usr/sbin/ipsec ] && [ -f /etc/ipsec.conf ] && [ -f /etc/ipsec.secrets ] &&
	 bash /etc/bmcweb/backend/scripts/network/vpn_handle.sh list | grep -q '\"status\": 0'"
# The rules of acl_control are rules of the firewall configuration, which fw3
# reads at boot.
check "acl_control has no service" "[ ! -e /etc/init.d/acl_control ] && ! ls /etc/rc.d | grep -q acl_control"
check "the service of DHCPGuard calls a script that is in the image, which has the apply it calls" \
	"s=\$(sed -n 's/^SCRIPT=\"\\(.*\\)\"\$/\\1/p' /etc/init.d/dhcpguard); [ -f \"\$s\" ] && grep -q '^ *apply)' \"\$s\""

for c in account macfilter client_control ddos_protect nat11 acl_control dhcpguard bmcfirewall bmcfido; do
	check "uci reads /etc/config/$c" "uci -q show $c >/dev/null"
done
check "default network: wan on eth0, br-lan on eth1 to eth5 at $LAN_ADDR" \
	"[ \"\$(uci -q get network.wan.device)\" = eth0 ] && [ \"\$(uci -q get network.lan.ipaddr)\" = $LAN_ADDR ] &&
	 [ \"\$(uci -q get network.@device[0].ports)\" = 'eth1 eth2 eth3 eth4 eth5' ]"

# ---- captive portal and proxy

check "the programs of the captive portal and the proxy find their libraries" \
	"for b in /usr/sbin/chilli /usr/sbin/chilli_query /usr/sbin/radiusd /usr/sbin/squid /usr/bin/c-icap \
		/usr/lib/squid/security_file_certgen /usr/sbin/http-file-tracker; do
		[ -e \$b ] || { echo \"no \$b\"; exit 1; }
		if ldd \$b 2>&1 | grep 'not found'; then echo \"in \$b\"; exit 1; fi
	done"
# Plugins get their symbols from the program that loads them: the SQLite
# module of FreeRADIUS is loaded by the configuration check below, the
# antivirus service by the ICAP server and the match by iptables in
# tests/qemu-test.sh.
check "the ICAP server has its antivirus service" "[ -s /usr/lib/c_icap/squidclamav.so ]"
check "CoovaChilli says its version" "chilli --version | grep -q -i 'coova'"
check "CoovaChilli has its kernel match, loaded at boot, and the iptables side of it" \
	"ls /lib/modules/*/xt_coova.ko >/dev/null && grep -qx xt_coova /etc/modules.d/* && [ -s /usr/lib/iptables/libxt_coova.so ]"
check "the portal login script reads its user database with sqlite3 and asks chilli_query" \
	"[ -x /www/cgi-bin/portal_login.sh ] && grep -q chilli_query /www/cgi-bin/portal_login.sh && command -v sqlite3 >/dev/null"
check "FreeRADIUS says its version" "radiusd -v | grep -q 'FreeRADIUS Version 3\.'"
check "FreeRADIUS has the BMC sites and the SQLite module" \
	"grep -q 'filename = \"/etc/freeradius3/raddb/radius.db\"' /etc/freeradius3/mods-available/sql &&
	 [ -s /etc/freeradius3/sites-available/default ] && [ -s /etc/freeradius3/sites-available/inner-tunnel ]"
# What freeradius3_db_init does at boot, then the server reads its whole
# configuration: sites, modules, dictionaries, the user database.
check "FreeRADIUS accepts its configuration with the user database in place" \
	"mkdir -p /var/log /var/run /var/db/radacct /tmp/radiusd &&
	 ln -sf /etc/freeradius3/mods-available/sql /etc/freeradius3/mods-enabled/sql &&
	 sed -i 's|^#\\\$INCLUDE dictionary.rfc4818|\$INCLUDE dictionary.rfc4818|; s|^#\\\$INCLUDE dictionary.rfc6911|\$INCLUDE dictionary.rfc6911|' /usr/share/freeradius3/dictionary &&
	 sqlite3 /etc/freeradius3/raddb/radius.db < /etc/freeradius3/raddb/sql/sqlite/schema.sql &&
	 radiusd -XC > /tmp/radiusd.out 2>&1 || { tail -15 /tmp/radiusd.out; exit 1; }"
check "squid says its version, with ICAP and certificate generation" \
	"squid -v | grep -q 'Squid Cache: Version' && squid -v | grep -q -- '--enable-icap-client' && squid -v | grep -q -- '--enable-ssl-crtd'"
check "squid accepts the BMC configuration" \
	"mkdir -p /tmp/squid && squid -k parse -f /etc/squid/squid.conf > /tmp/squid.out 2>&1 || { grep -i -E 'fatal|error|bungled' /tmp/squid.out; tail -5 /tmp/squid.out; exit 1; }"
check "squid makes its certificate database" \
	"rm -rf /tmp/ssl_db && /usr/lib/squid/security_file_certgen -c -s /tmp/ssl_db -M 4MB && [ -d /tmp/ssl_db/certs ]"
check "the ICAP server is configured for the antivirus service squid asks" \
	"grep -q '^Service squidclamav squidclamav.so' /etc/c-icap/c-icap.conf &&
	 grep -q 'icap://127.0.0.1:1344/squidclamav' /etc/squid/squid.conf && [ -s /etc/c-icap/squidclamav.conf ]"
check "the HTTP file tracker reads the options its service gives it" \
	"http-file-tracker --help 2>&1 | grep -q -- '--lan-client' || http-file-tracker --disabled --interface br-lan --http-port 80 --capture-snaplen 262144"
for s in chilli add-cron radiusd freeradius3_db_init squid c-icap http-file-tracker; do
	check "service $s is enabled" "ls /etc/rc.d/S[0-9][0-9]$s >/dev/null"
done
for c in chilli squid http-file-tracker; do
	check "uci reads /etc/config/$c" "uci -q show $c >/dev/null"
done
check "the portal is CoovaChilli on br-lan, asking the RADIUS server of the board" \
	"[ \"\$(uci -q get chilli.@chilli[0].dhcpif)\" = br-lan ] && [ \"\$(uci -q get chilli.@chilli[0].radiusserver1)\" = 127.0.0.1 ] &&
	 [ \"\$(uci -q get chilli.@chilli[0].uamserver)\" = http://bmc.lan/portal.html ]"
check "the HTTP file tracker is disabled until it is given its clients" \
	"[ \"\$(uci -q get http-file-tracker.main.enabled)\" = 0 ]"

# The feature scripts are bash scripts that call these.
for t in bash jq ipset ebtables flock curl sqlite3; do
	check "the image has $t" "command -v $t >/dev/null"
done
# mac, time and limit; recent; set; physdev.
check "the kernel modules of the matches the feature scripts use are in the image" \
	"cd /lib/modules/* && ls xt_mac.ko xt_time.ko xt_recent.ko xt_limit.ko xt_set.ko xt_physdev.ko br_netfilter.ko >/dev/null"

# ---- bmcqos

check "uci reads /etc/config/bmcqos" "uci -q show bmcqos >/dev/null"
check "bmcqos is off and set for wan" \
	"[ \"\$(uci -q get bmcqos.global.enabled)\" = 0 ] && [ \"\$(uci -q get bmcqos.settings.WAN)\" = eth0 ]"
check "service bmcqos is enabled" "ls /etc/rc.d/S[0-9][0-9]bmcqos >/dev/null"
check "tc knows the qdisc and the action bmcqos uses" \
	"tc qdisc add dev lo root cake help 2>&1 | grep -q -i 'bandwidth' && tc actions add action ctinfo help 2>&1 | grep -q -i 'dscp'"
case "$DEVICE" in
fsl,ls1088a-rdb*)
	check "the init script of bmcqos registers its WAN with bmchwaccel, and goes on without it" \
		"grep -q 'hwaccel keep bmcqos wan' /etc/init.d/bmcqos && grep -q '\[ -x /usr/sbin/bmchwaccel \] || return 0' /etc/init.d/bmcqos" ;;
*)
	check "the init script of bmcqos registers its WAN with bmchwaccel" \
		"grep -q 'hwaccel keep bmcqos wan' /etc/init.d/bmcqos && [ -x /usr/sbin/bmchwaccel ]" ;;
esac

exit $rc
