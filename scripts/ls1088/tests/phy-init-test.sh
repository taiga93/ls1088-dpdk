#!/bin/sh
# The ports of the LS1088A-RDB as /etc/init.d/phy_init makes them at boot,
# checked in a copy of the built root filesystem with the board's own busybox
# and rc.common. restool, ls-addni, sleep, logger and ubus are fakes that keep
# the objects of the MC and the names the kernel gives in /state, as the
# board does: the DPL leaves dpni.0 on dpmac.5 as eth0, ls-addni takes the
# lowest free DPNI and the lowest free ethN. phy_init itself is taken from
# files/ of the source tree, so no rebuild is needed after editing it.
# For the engine layout, layout and container of bmcHwAccelDpdk are fakes
# too: LAYOUT is what layout answers (none: the package is not installed),
# the container takes a DPNI for each side of each MAC of the engine, or
# fails after the first one with BUILD_FAIL=1; CHECK_FAIL=1 makes its check
# fail.
#
# Run as root inside the build container (aarch64, same as the board):
#   docker exec ubuntu20 sh /home/working/<tree>/scripts/ls1088/tests/phy-init-test.sh
set -u

TOP=$(cd "$(dirname "$0")/../../.." && pwd)
ROOT=$(ls -d "$TOP"/build_dir/target-*/root-layerscape 2>/dev/null | head -1)
[ -n "$ROOT" ] || { echo "phy-init-test: no root-layerscape under build_dir; build the image first" >&2; exit 2; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rc=0
ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; rc=1; }

# Fresh root for one scenario: BOARD is the board name, FAIL the MACs that
# ls-addni cannot make a port for, TAKEN "dpmac.N=dpni.M" pairs connected
# before phy_init runs.
fresh_root() {
	rm -rf "$W/root"
	mkdir "$W/root"
	(cd "$ROOT" && tar cf - --exclude=./lib/modules --exclude=./lib/firmware .) | tar xf - -C "$W/root"
	cp "$TOP/files/etc/init.d/phy_init" "$W/root/etc/init.d/phy_init"
	chmod 755 "$W/root/etc/init.d/phy_init"
	mkdir -p "$W/root/tmp/sysinfo" "$W/root/var/run" "$W/root/var/lock" "$W/root/fake" "$W/root/state" \
		"$W/root/sys/bus/fsl-mc/drivers/fsl_dpaa2_eth"
	echo "$BOARD" > "$W/root/tmp/sysinfo/board_name"
	: > "$W/root/sys/bus/fsl-mc/drivers/fsl_dpaa2_eth/unbind"
	# The DPL of the board: dpni.0 on dpmac.5, eth0.
	echo dpni.0 > "$W/root/state/dpmac.5"
	echo dpni.0 > "$W/root/state/eth0"
	: > "$W/root/state/dpni.0"
	for pair in $TAKEN; do
		echo "${pair#*=}" > "$W/root/state/${pair%=*}"
		: > "$W/root/state/${pair#*=}"
		echo "${pair#*=}" > "$W/root/state/eth$(next_free eth)"
	done
	echo "$FAIL" > "$W/root/state/fail"
	cat > "$W/root/fake/restool" <<'EOF'
#!/bin/sh
# restool dpni info|destroy dpni.N, restool dpmac info dpmac.N,
# restool dprc connect dprc.1 --endpoint1=dpni.N --endpoint2=dpni.M
S=/state
case "$1 $2" in
"dprc connect")
	echo "restool $*" >> /tmp/calls
	a=${4#--endpoint1=}; b=${5#--endpoint2=}
	[ -e "$S/$a" ] && [ -e "$S/$b" ] || exit 1
	echo "$b" > "$S/link.$a"
	;;
"dpni info") [ -e "$S/$3" ] ;;
"dpni destroy")
	echo "restool $*" >> /tmp/calls
	[ -e "$S/$3" ] || exit 1
	rm -f "$S/$3"
	for f in "$S"/dpmac.* "$S"/eth*; do
		[ "$(cat "$f" 2>/dev/null)" != "$3" ] || rm -f "$f"
	done
	;;
"dpmac info")
	if [ -e "$S/$3" ]; then echo "endpoint: $(cat "$S/$3"), link is up"; else echo "endpoint: No object associated"; fi
	echo "MAC address: 00:04:9f:06:12:0${3#dpmac.}"
	;;
*) echo "restool fake: $*" >&2; exit 1 ;;
esac
EOF
	cat > "$W/root/fake/ls-addni" <<'EOF'
#!/bin/sh
S=/state
echo "ls-addni $*" >> /tmp/calls
mac= addr=
for a; do
	case "$a" in
	dpmac.*) mac=$a ;;
	--mac-addr=*) addr=${a#*=} ;;
	esac
done
case " $(cat $S/fail) " in *" ${mac:--n} "*) echo "Error: dpni object was not created!"; exit 1 ;; esac
[ -z "$mac" ] || [ ! -e "$S/$mac" ] || { echo "Error: $mac is already connected"; exit 1; }
i=0; while [ -e "$S/dpni.$i" ]; do i=$((i + 1)); done
e=0; while [ -e "$S/eth$e" ]; do e=$((e + 1)); done
: > "$S/dpni.$i"
echo "dpni.$i" > "$S/eth$e"
[ -z "$mac" ] || echo "dpni.$i" > "$S/$mac"
[ -z "$addr" ] || echo "$addr" > "$S/addr.dpni.$i"
echo "Created interface: eth$e (object:dpni.$i, endpoint: $mac)"
EOF
	if [ -n "$LAYOUT" ]; then
		mkdir -p "$W/root/usr/lib/bmcHwAccelDpdk"
		echo "$LAYOUT" > "$W/root/state/layout"
		cat > "$W/root/usr/lib/bmcHwAccelDpdk/layout" <<'EOF'
#!/bin/sh
case "${1:-}" in
'') echo "layout" >> /tmp/calls; cat /state/layout ;;
ports) echo "dpmac.1 dpmac.2" ;;
fail) echo "layout $*" >> /tmp/calls ;;
esac
EOF
		cat > "$W/root/usr/lib/bmcHwAccelDpdk/container" <<'EOF'
#!/bin/sh
# the DPNIs of the engine: X on the MAC, Y for the kernel side
S=/state
take() { i=0; while [ -e "$S/dpni.$i" ]; do i=$((i + 1)); done; : > "$S/dpni.$i"; echo dpni.$i; }
case "$1" in
build)
	shift
	echo "container build $*" >> /tmp/calls
	echo "dprc dprc.2"
	for mac; do
		x=$(take); echo "$x" > "$S/$mac"
		[ "${BUILD_FAIL:-0}" = 0 ] || { echo "container: $mac: no DPNI for the kernel side" >&2; exit 1; }
		y=$(take); echo "$y" > "$S/side.$mac"
		echo "port $mac $x $y"
	done
	;;
side) cat "$S/side.$2" 2>/dev/null ;;
check)
	echo "container check" >> /tmp/calls
	[ "${CHECK_FAIL:-0}" = 0 ] || { echo "container: dpmac.2: dpni.4 is linked to no port of the kernel"; exit 1; }
	echo "dprc dprc.2"
	;;
esac
EOF
		chmod +x "$W/root/usr/lib/bmcHwAccelDpdk/"*
	fi
	printf '#!/bin/sh\necho "sleep $*" >> /tmp/calls\n' > "$W/root/fake/sleep"
	printf '#!/bin/sh\necho "logger $*" >> /tmp/calls\n' > "$W/root/fake/logger"
	printf '#!/bin/sh\nexit 0\n' > "$W/root/fake/ubus"
	chmod +x "$W/root/fake/"*
	: > "$W/root/tmp/calls"
}

next_free() { i=0; while [ -e "$W/root/state/$1$i" ]; do i=$((i + 1)); done; echo $i; }

in_root() {
	chroot "$W/root" /bin/sh -c "export PATH=/fake:/usr/sbin:/usr/bin:/sbin:/bin \
		BUILD_FAIL=$BUILD_FAIL CHECK_FAIL=$CHECK_FAIL; $1"
}

start() { in_root '/etc/init.d/phy_init start' > "$W/out" 2>&1; }

# Each ethN with the dpmac behind it, as the fakes left them; "~dpmac.N"
# when it is linked to the engine's side of the MAC, with "@ADDRESS" when it
# was given one.
ports() {
	for f in "$W/root/state"/eth*; do
		[ -e "$f" ] || continue
		d=$(cat "$f")
		if [ -e "$W/root/state/link.$d" ]; then
			m=$(grep -lx "$(cat "$W/root/state/link.$d")" "$W/root/state"/side.dpmac.* 2>/dev/null | head -1)
			m="~${m##*/side.}"
		else
			m=$(grep -lx "$d" "$W/root/state"/dpmac.* 2>/dev/null | head -1)
			m=${m##*/}
		fi
		a=
		[ ! -e "$W/root/state/addr.$d" ] || a="@$(cat "$W/root/state/addr.$d")"
		echo "${f##*/}=$m$a"
	done | sort -t h -k 2 -n | tr '\n' ' ' | sed 's/ $//'
}

# Calls of the fakes, but for the lines of logger.
calls() { grep -v '^logger ' "$W/root/tmp/calls" | tr '\n' ';'; }
logged() { grep '^logger ' "$W/root/tmp/calls"; }

expect() { # description, got, wanted
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		fail "$1"
		echo "    | got:    $2"
		echo "    | wanted: $3"
		sed 's/^/    | /' "$W/out"
	fi
}

ALL_PORTS="eth0=dpmac.1 eth1=dpmac.2 eth2=dpmac.3 eth3=dpmac.4 eth4=dpmac.5 eth5=dpmac.6 eth6=dpmac.7 eth7=dpmac.8 eth8=dpmac.9"
made() { for m in "$@"; do printf 'ls-addni --fs-entries=1 dpmac.%s;sleep 2;' "$m"; done; }

LAYOUT= BUILD_FAIL=0 CHECK_FAIL=0
BOARD=fsl,ls1088a-rdb-sdboot FAIL= TAKEN= fresh_root
start
expect "LS1088A-RDB SD boot: eth0-eth8 are dpmac.1-9, dpmac.10 has no port" "$(ports)" "$ALL_PORTS"
expect "dpni.0 of the DPL goes first, then one port at a time with a pause after each" \
	"$(calls)" "restool dpni destroy dpni.0;sleep 2;$(made 1 2 3 4 5 6 7 8 9)"
expect "dpni.0 is unbound from dpaa2-eth before it is destroyed" \
	"$(cat "$W/root/sys/bus/fsl-mc/drivers/fsl_dpaa2_eth/unbind")" dpni.0
expect "syslog names each port" "$(logged | grep -c 'dpmac\.[1-9]: eth[0-8] (dpni\.[0-9]*)$')" 9

: > "$W/root/tmp/calls"
start
expect "started again in the same boot: nothing is made or destroyed" "$(calls)" ""
expect "and the ports are the same" "$(ports)" "$ALL_PORTS"

BOARD=fsl,ls1088a-rdb FAIL= TAKEN= fresh_root
start
expect "LS1088A-RDB flash boot: the same ports" "$(ports)" "$ALL_PORTS"

BOARD=fsl,ls1088a-rdb-sdboot FAIL=dpmac.3 TAKEN= fresh_root
start
expect "a MAC ls-addni fails on gets no port, the next ones still do" \
	"$(calls)" "restool dpni destroy dpni.0;sleep 2;$(made 1 2 3 4 5 6 7 8 9)"
expect "and syslog says which" "$(logged | grep -c 'dpmac\.3: no port: Error: dpni object was not created!')" 1
expect "and that the names after it are shifted" "$(logged | grep -c 'dpmac\.4 should have been eth3')" 1

BOARD=fsl,ls1088a-rdb-sdboot FAIL= TAKEN=dpmac.7=dpni.5 fresh_root
start
expect "a MAC with a DPNI already is left as it is" \
	"$(calls)" "restool dpni destroy dpni.0;sleep 2;$(made 1 2 3 4 5 6 8 9)"
expect "and syslog says so" "$(logged | grep -c 'dpmac\.7 has dpni\.5 already, left as it is')" 1

BOARD=fsl,ls1046a-rdb-sdboot FAIL= TAKEN= fresh_root
start
expect "LS1046A-RDB (no DPAA2): nothing is made or destroyed" "$(calls)" ""
expect "and nothing is unbound" "$(cat "$W/root/sys/bus/fsl-mc/drivers/fsl_dpaa2_eth/unbind")" ""

# The engine layout (bmcHwAccelDpdk installed).
BOARD=fsl,ls1088a-rdb-sdboot FAIL= TAKEN=
LAYOUT=kernel
fresh_root
start
expect "kernel layout asked for: the ports of the kernel layout" "$(ports)" "$ALL_PORTS"
expect "and nothing of the engine is made" \
	"$(calls)" "layout;restool dpni destroy dpni.0;sleep 2;$(made 1 2 3 4 5 6 7 8 9)"

ENGINE_PORTS="eth0=~dpmac.1@00:04:9f:06:12:01 eth1=~dpmac.2@00:04:9f:06:12:02 eth2=dpmac.3 eth3=dpmac.4 eth4=dpmac.5 eth5=dpmac.6 eth6=dpmac.7 eth7=dpmac.8 eth8=dpmac.9"
side_made() { # MAC number, Z, Y
	printf 'ls-addni -n --fs-entries=1 --mac-addr=00:04:9f:06:12:0%s;' "$1"
	printf 'restool dprc connect dprc.1 --endpoint1=%s --endpoint2=%s;sleep 2;' "$2" "$3"
}
LAYOUT=engine
fresh_root
start
expect "engine layout: eth0 and eth1 are DPNIs linked to the engine's sides of dpmac.1 and 2, with their addresses" \
	"$(ports)" "$ENGINE_PORTS"
expect "the container first, then the ports one at a time, then its check" "$(calls)" \
	"layout;restool dpni destroy dpni.0;sleep 2;container build dpmac.1 dpmac.2;sleep 2;$(side_made 1 dpni.4 dpni.1)$(side_made 2 dpni.5 dpni.3)$(made 3 4 5 6 7 8 9)container check;"
expect "syslog names each port" "$(logged | grep -c 'dpmac\.[1-9]: eth[0-8] (dpni\.[0-9]*)$')" 9

: > "$W/root/tmp/calls"
start
expect "engine layout, started again in the same boot: nothing is made" "$(calls)" ""

BUILD_FAIL=1
fresh_root
start
expect "the container cannot be made: the next boots are in the kernel layout" \
	"$(calls | grep -o 'layout fail [^;]*')" "layout fail its ports could not be made at boot"
expect "and the names stay: eth0 is a port without a link, with the address of dpmac.1, which is taken" "$(ports)" \
	"eth0=@00:04:9f:06:12:01 eth1=dpmac.2 eth2=dpmac.3 eth3=dpmac.4 eth4=dpmac.5 eth5=dpmac.6 eth6=dpmac.7 eth7=dpmac.8 eth8=dpmac.9"
expect "and syslog says why" "$(logged | grep -c 'Tăng tốc phần cứng: dprc dprc.2 container: dpmac.1: no DPNI for the kernel side')" 1
expect "and that dpmac.1 is taken" \
	"$(logged | grep -c 'dpmac\.1 has dpni\.0 already: eth0 (dpni\.[0-9]*) without a link, for the names after it')" 1

BUILD_FAIL=0 CHECK_FAIL=1
fresh_root
start
expect "the ports are not complete after the boot: the next boots are in the kernel layout" \
	"$(calls | grep -o 'layout fail [^;]*')" "layout fail its ports are not complete after the boot made them"
expect "and syslog says why" "$(logged | grep -c 'dpni.4 is linked to no port of the kernel')" 1
CHECK_FAIL=0

[ $rc -eq 0 ] && echo "phy-init-test: PASS" || echo "phy-init-test: FAIL"
exit $rc
