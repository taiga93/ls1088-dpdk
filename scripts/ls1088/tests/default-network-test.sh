#!/bin/sh
# Default network of the LS1088A-RDB, checked in a copy of the built root
# filesystem with the board's own busybox, uci and board.d scripts: wan on
# eth0, br-lan over eth1 to eth7, eth8 in neither. The image carries the
# network configuration of files/, which is the one of the LS1046A-RDB (br-lan
# up to eth5); the first boot of an LS1088A-RDB adds the two ports it has
# beyond that. files/ and the board.d and uci-defaults scripts are taken from
# the source tree, so no rebuild is needed after editing them.
#
# Run as root inside the build container (aarch64, same as the board):
#   docker exec ubuntu20 sh /home/working/<tree>/scripts/ls1088/tests/default-network-test.sh
set -u

TOP=$(cd "$(dirname "$0")/../../.." && pwd)
SRC=$TOP/target/linux/layerscape/base-files/etc
ROOT=$(ls -d "$TOP"/build_dir/target-*/root-layerscape 2>/dev/null | head -1)
[ -n "$ROOT" ] || { echo "default-network-test: no root-layerscape under build_dir; build the image first" >&2; exit 2; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rc=0

# Fresh root for one scenario: BOARD is the board name. Both port scripts of
# the target are there, as in the image; the ports of the kernel are not
# asked for on this board, so "ip" only records that it was called.
fresh_root() {
	rm -rf "$W/root"
	mkdir "$W/root"
	(cd "$ROOT" && tar cf - --exclude=./lib/modules --exclude=./lib/firmware .) | tar xf - -C "$W/root"
	cp "$SRC/board.d/02_network" "$W/root/etc/board.d/02_network"
	cp "$TOP/files/etc/config/network" "$W/root/etc/config/network"
	rm -f "$W/root"/etc/uci-defaults/*
	cp "$SRC/uci-defaults/20_ls1046a-rdb-lan-ports" "$SRC/uci-defaults/20_ls1088a-rdb-lan-ports" \
		"$W/root/etc/uci-defaults/"
	mkdir -p "$W/root/tmp/sysinfo" "$W/root/fake"
	echo "$BOARD" > "$W/root/tmp/sysinfo/board_name"
	printf '#!/bin/sh\necho "ip $*" >> /tmp/calls\n' > "$W/root/fake/ip"
	printf '#!/bin/sh\necho "logger $*" >> /tmp/calls\n' > "$W/root/fake/logger"
	chmod +x "$W/root/fake/ip" "$W/root/fake/logger"
	: > "$W/root/tmp/calls"
}

in_root() { chroot "$W/root" /bin/sh -c "export PATH=/fake:/usr/sbin:/usr/bin:/sbin:/bin; $1"; }

port_scripts() { in_root 'for s in /etc/uci-defaults/*; do sh "$s"; done'; }

first_boot() { in_root '/bin/board_detect && /bin/config_generate >/dev/null' && port_scripts; }

check() { # name expected-file
	{
		in_root 'echo "wan=$(uci -q get network.wan.device) $(uci -q get network.wan.proto)"
echo "lan=$(uci -q get network.lan.device) $(uci -q get network.lan.proto) $(uci -q get network.lan.ipaddr)"
echo "br-lan=$(uci -q get network.@device[0].ports)"
echo "eth8=$(uci show network | grep -c eth8)"'
		echo "-- calls --"
		cat "$W/root/tmp/calls"
	} > "$W/got" 2>&1
	if diff -u "$2" "$W/got" > "$W/diff"; then
		echo "ok    $1"
	else
		echo "FAIL  $1"; cat "$W/diff"; rc=1
	fi
}

cat > "$W/ls1088" <<'EOF'
wan=eth0 dhcp
lan=br-lan static 192.168.5.1
br-lan=eth1 eth2 eth3 eth4 eth5 eth6 eth7
eth8=0
-- calls --
EOF

BOARD=fsl,ls1088a-rdb-sdboot
fresh_root; first_boot
check "LS1088A-RDB SD boot: wan on eth0, br-lan over eth1 to eth7, eth8 not used" "$W/ls1088"

# A second run (sysupgrade keeping the configuration) adds nothing more.
port_scripts
check "second run" "$W/ls1088"

BOARD=fsl,ls1088a-rdb
fresh_root; first_boot
check "LS1088A-RDB flash boot" "$W/ls1088"

# A br-lan whose ports were chosen on the board is left as it is, also when
# eth6 and eth7 are not among them.
BOARD=fsl,ls1088a-rdb-sdboot
fresh_root
in_root 'uci delete network.@device[0].ports; uci add_list network.@device[0].ports=eth1;
uci add_list network.@device[0].ports=eth2; uci commit network'
port_scripts
cat > "$W/expected" <<'EOF'
wan=eth0 dhcp
lan=br-lan static 192.168.5.1
br-lan=eth1 eth2
eth8=0
-- calls --
EOF
check "br-lan chosen on the board" "$W/expected"

# The LS1046A-RDB keeps the configuration of files/.
BOARD=fsl,ls1046a-rdb-sdboot
fresh_root; first_boot
cat > "$W/expected" <<'EOF'
wan=eth0 dhcp
lan=br-lan static 192.168.5.1
br-lan=eth1 eth2 eth3 eth4 eth5
eth8=0
-- calls --
ip link show dev eth3
ip link set dev eth3 up
ip link set dev eth3 down
EOF
check "LS1046A-RDB: not touched by the script of the LS1088A-RDB" "$W/expected"

[ $rc -eq 0 ] && echo "default-network-test: PASS" || echo "default-network-test: FAIL"
exit $rc
