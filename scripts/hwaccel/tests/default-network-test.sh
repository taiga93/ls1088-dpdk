#!/bin/sh
# Default network of the LS1046A-RDB, checked in a copy of the built root
# filesystem with the board's own busybox, uci and board.d scripts: the
# configuration a first boot starts with, and which bridge ports are dropped
# when a port cannot be opened. The image carries its network configuration
# (files/etc/config/network, as the 24.10 firmware does), so the first boot
# generates none from board.d. "ip" and "logger" are fakes; files/ and the
# board.d and uci-defaults scripts are taken from the source tree, so no
# rebuild is needed after editing them.
#
# Run as root inside the build container (aarch64, same as the board):
#   docker exec ubuntu20 sh /home/working/<tree>/scripts/hwaccel/tests/default-network-test.sh
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

# Fresh root for one scenario: BOARD is the board name, EXISTING the ports the
# kernel has, NOPHY the ports that fail to open.
fresh_root() {
	rm -rf "$W/root"
	mkdir "$W/root"
	(cd "$ROOT" && tar cf - --exclude=./lib/modules --exclude=./lib/firmware .) | tar xf - -C "$W/root"
	cp "$SRC/board.d/02_network" "$W/root/etc/board.d/02_network"
	cp "$TOP/files/etc/config/network" "$W/root/etc/config/network"
	rm -f "$W/root"/etc/uci-defaults/*
	cp "$SRC/uci-defaults/20_ls1046a-rdb-lan-ports" "$W/root/etc/uci-defaults/"
	mkdir -p "$W/root/tmp/sysinfo" "$W/root/fake"
	echo "$BOARD" > "$W/root/tmp/sysinfo/board_name"
	cat > "$W/root/fake/ip" <<EOF
#!/bin/sh
# ip link show dev PORT | ip link set dev PORT up|down
echo "ip \$*" >> /tmp/calls
case " $EXISTING " in *" \$4 "*) ;; *) echo "Cannot find device \"\$4\"" >&2; exit 1 ;; esac
[ "\$2" = set ] && [ "\$5" = up ] || exit 0
case " $NOPHY " in *" \$4 "*) echo "RTNETLINK answers: No such device" >&2; exit 2 ;; esac
exit 0
EOF
	cat > "$W/root/fake/logger" <<'EOF'
#!/bin/sh
echo "logger $*" >> /tmp/calls
EOF
	chmod +x "$W/root/fake/ip" "$W/root/fake/logger"
	: > "$W/root/tmp/calls"
}

in_root() { chroot "$W/root" /bin/sh -c "export PATH=/fake:/usr/sbin:/usr/bin:/sbin:/bin; $1"; }

first_boot() {
	in_root '/bin/board_detect && /bin/config_generate >/dev/null && sh /etc/uci-defaults/20_ls1046a-rdb-lan-ports'
}

check() { # name expected-file
	{
		in_root 'echo "wan=$(uci -q get network.wan.device) $(uci -q get network.wan.proto)"
echo "lan=$(uci -q get network.lan.device) $(uci -q get network.lan.proto) $(uci -q get network.lan.ipaddr)"
echo "br-lan=$(uci -q get network.@device[0].ports)"'
		echo "-- calls --"
		cat "$W/root/tmp/calls"
	} > "$W/got" 2>&1
	if diff -u "$2" "$W/got" > "$W/diff"; then
		echo "ok    $1"
	else
		echo "FAIL  $1"; cat "$W/diff"; rc=1
	fi
}

# Every port has a PHY: wan on eth0, the other five ports bridged.
BOARD=fsl,ls1046a-rdb-sdboot EXISTING="eth0 eth1 eth2 eth3 eth4 eth5" NOPHY=
fresh_root; first_boot
cat > "$W/expected" <<'EOF'
wan=eth0 dhcp
lan=br-lan static 192.168.5.1
br-lan=eth1 eth2 eth3 eth4 eth5
-- calls --
ip link show dev eth3
ip link set dev eth3 up
ip link set dev eth3 down
EOF
check "all ports open" "$W/expected"

# Our board: no PHY on MAC6, eth3 cannot be opened and leaves the bridge.
NOPHY=eth3
fresh_root; first_boot
cat > "$W/expected" <<'EOF'
wan=eth0 dhcp
lan=br-lan static 192.168.5.1
br-lan=eth1 eth2 eth4 eth5
-- calls --
ip link show dev eth3
ip link set dev eth3 up
logger -t network eth3 cannot be opened (no PHY?), left out of br-lan
EOF
check "eth3 without PHY" "$W/expected"

# A second run (sysupgrade keeping the configuration) changes nothing more.
: > "$W/root/tmp/calls"
in_root 'sh /etc/uci-defaults/20_ls1046a-rdb-lan-ports'
cat > "$W/expected" <<'EOF'
wan=eth0 dhcp
lan=br-lan static 192.168.5.1
br-lan=eth1 eth2 eth4 eth5
-- calls --
ip link show dev eth3
ip link set dev eth3 up
EOF
check "second run" "$W/expected"

# A configured port the kernel does not have is neither opened nor removed.
NOPHY= EXISTING="eth0 eth1 eth2"
fresh_root; first_boot
cat > "$W/expected" <<'EOF'
wan=eth0 dhcp
lan=br-lan static 192.168.5.1
br-lan=eth1 eth2 eth3 eth4 eth5
-- calls --
ip link show dev eth3
EOF
check "missing ports" "$W/expected"

# On another board of the target the script leaves the bridge alone. (The
# configuration of the image is still the one of the LS1046A-RDB: the image
# is built for that board only.)
BOARD=fsl,ls1043a-rdb EXISTING="eth0 eth3" NOPHY="eth3"
fresh_root; first_boot
cat > "$W/expected" <<'EOF'
wan=eth0 dhcp
lan=br-lan static 192.168.5.1
br-lan=eth1 eth2 eth3 eth4 eth5
-- calls --
EOF
check "other board" "$W/expected"

exit $rc
