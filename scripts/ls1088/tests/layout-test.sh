#!/bin/sh
# The DPAA2 layout of a boot as bmcHwAccelDpdk decides it
# (package/bmc/bmcHwAccelDpdk/files/layout), checked in a copy of the built
# root filesystem with the board's own busybox and uci. /proc/mounts, the
# boot id, the hugetlbfs mount point and the state directories are in the
# copy; mount, logger, sysctl and reboot are fakes, and the fake kernel gives
# at most HUGE_MAX hugepages.
# The script is taken from the source tree, so no rebuild is needed after
# editing it.
#
# Run as root inside the build container (aarch64, same as the board):
#   docker exec ubuntu20 sh /home/working/<tree>/scripts/ls1088/tests/layout-test.sh
set -u

TOP=$(cd "$(dirname "$0")/../../.." && pwd)
ROOT=$(ls -d "$TOP"/build_dir/target-*/root-layerscape 2>/dev/null | head -1)
[ -n "$ROOT" ] || { echo "layout-test: no root-layerscape under build_dir; build the image first" >&2; exit 2; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rc=0
ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; rc=1; }

R=$W/root
mkdir "$R"
(cd "$ROOT" && tar cf - --exclude=./lib/modules --exclude=./lib/firmware --exclude=./www \
	--exclude=./usr/lib/node_modules --exclude=./etc/bmcweb .) | tar xf - -C "$R"
mkdir -p "$R/fake" "$R/t/proc" "$R/usr/lib/bmcHwAccelDpdk"
cp "$TOP/package/bmc/bmcHwAccelDpdk/files/layout" "$R/usr/lib/bmcHwAccelDpdk/layout"
chmod 755 "$R/usr/lib/bmcHwAccelDpdk/layout"
printf '#!/bin/sh\necho "logger $*" >> /t/calls\n' > "$R/fake/logger"
printf '#!/bin/sh\necho "reboot $*" >> /t/calls\n' > "$R/fake/reboot"
printf '#!/bin/sh\necho "mount $*" >> /t/calls\necho "none $4 hugetlbfs rw 0 0" >> /t/proc/mounts\n' > "$R/fake/mount"
cat > "$R/fake/sysctl" <<'EOF'
#!/bin/sh
# sysctl -q -w vm.nr_hugepages=N, sysctl -n vm.nr_hugepages
case "$*" in
"-q -w vm.nr_hugepages="*)
	n=${3#*=}
	[ "$n" -le "$(cat /t/huge_max)" ] || n=$(cat /t/huge_max)
	echo "$n" > /t/nr_hugepages
	;;
"-n vm.nr_hugepages") cat /t/nr_hugepages ;;
*) echo "sysctl fake: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$R/fake/"*

# A boot: UCI is the content of /etc/config/bmchwaccel (none: no file). What
# is in /etc/bmcHwAccel stays, as on the card; each boot has a boot id of its
# own.
boots=0
boot() {
	boots=$((boots + 1))
	rm -rf "$R/t/run" "$R/t/huge" "$R/etc/config/bmchwaccel"
	mkdir -p "$R/t/proc/sys/kernel/random"
	echo "boot-$boots" > "$R/t/proc/sys/kernel/random/boot_id"
	: > "$R/t/calls"
	: > "$R/t/proc/mounts"
	echo 0 > "$R/t/nr_hugepages"
	echo "$HUGE_MAX" > "$R/t/huge_max"
	[ -z "$UCI" ] || printf '%s\n' "$UCI" > "$R/etc/config/bmchwaccel"
}

layout() {
	chroot "$R" /bin/sh -c "export PATH=/fake:/usr/sbin:/usr/bin:/sbin:/bin \
		BMCHWACCEL_RUN_DIR=/t/run BMCHWACCEL_STATE_DIR=/t/state BMCHWACCEL_PROC=/t/proc \
		BMCHWACCEL_HUGE_DIR=/t/huge; /usr/lib/bmcHwAccelDpdk/layout $*" 2>&1
}

hugepages() { cat "$R/t/nr_hugepages"; }

# A card written anew, or a sysupgrade: nothing in /etc/bmcHwAccel.
card() { rm -rf "$R/t/state"; }

state() { (cd "$R/t/state" 2>/dev/null && for f in *; do [ -e "$f" ] && echo "$f: $(cat "$f")"; done) | tr '\n' ';'; }

expect() { # description, got, wanted
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		fail "$1"
		echo "    | got:    $2"
		echo "    | wanted: $3"
		sed 's/^/    | /' "$R/t/calls"
	fi
}

calls() { tr '\n' ';' < "$R/t/calls"; }

HUGE_MAX=1000
UCI=
card
boot
expect "before any call decided: kernel, and nothing decided" "$(layout current)" kernel
expect "no UCI: enabled, the engine layout" "$(layout)" engine
expect "decided: current says so" "$(layout current)" engine
expect "the boot is marked before the engine layout is built" "$(state)" "booting: boot-$boots;"
expect "its own mark is no reason against the next boot" "$(layout reason; echo "exit=$?")" "exit=1"
expect "with the hugepages of 2 ports and 4 workers reserved, ESP too" "$(hugepages)" 129
expect "and mounted" "$(calls)" "mount -t hugetlbfs none /t/huge;"
expect "the engine has dpmac.1 and dpmac.2" "$(layout ports)" "dpmac.1 dpmac.2"
expect "and 4 workers" "$(layout workers)" 4
UCI="config global 'global'
	option enabled '0'"
expect "decided once a boot: the same answer when UCI changed since" "$(layout)" engine

card
boot
expect "enabled 0: the kernel layout" "$(layout)" kernel
expect "and no hugepages" "$(hugepages)" 0
expect "and nothing mounted or logged" "$(calls)" ""

UCI="config global 'global'
	option enabled '1'
	option workers '2'
	list port 'dpmac.1'"
card
boot
expect "enabled 1, one port and 2 workers: the engine layout" "$(layout)" engine
expect "with fewer hugepages" "$(hugepages)" 106
expect "the engine has dpmac.1" "$(layout ports)" "dpmac.1"
expect "and 2 workers" "$(layout workers)" 2
UCI="config global 'global'
	option workers '4'"
printf '%s\n' "$UCI" > "$R/etc/config/bmchwaccel"
expect "UCI changed since the boot: the ports of the boot still" "$(layout ports)" "dpmac.1"
expect "and its workers, which its hugepages are for" "$(layout workers)" 2

UCI="config global 'global'
	list port 'dpmac.1'
	list port 'eth1'"
card
boot
expect "a port that is not a MAC: the MACs by default" "$(layout ports)" "dpmac.1 dpmac.2"

for w in 0 5 x; do
	UCI="config global 'global'
	option workers '$w'"
	card
	boot
	expect "workers '$w' is out of 1 to 4: 4 workers" "$(layout workers)" 4
done

UCI=
card
boot
layout > /dev/null
: > "$R/t/calls"
layout fail "its ports could not be made at boot" > /dev/null
expect "a failed boot is kept for the next boots" "$(cat "$R/t/state/unavailable")" \
	"its ports could not be made at boot"
expect "and logged" "$(calls)" \
	"logger -t bmcHwAccel Tăng tốc phần cứng unavailable: its ports could not be made at boot; the next boot is without it;"
expect "the hugepages are given back" "$(hugepages)" 0
expect "the reason against the next boot" "$(layout reason)" "engine its ports could not be made at boot"
: > "$R/t/calls"
layout fail --reboot "it stopped 3 times within 5 minutes" > /dev/null
expect "failed again in the same boot, now with a restart: the first reason stays" \
	"$(cat "$R/t/state/unavailable")" "its ports could not be made at boot"
expect "and the router restarts, without a second line" "$(calls)" "reboot ;"
boot
expect "the next boot after a failed one: the kernel layout" "$(layout)" kernel
expect "and no hugepages" "$(hugepages)" 0
expect "and nothing logged here: bmcHwAccel tells" "$(calls)" ""
expect "the reason stays" "$(layout reason)" "engine its ports could not be made at boot"
boot
expect "and so does the kernel layout, boot after boot" "$(layout)" kernel
layout retry
expect "retry forgets the failure and the mark of the failed boot" "$(state)" ""
boot
expect "the boot after it tries the engine layout again" "$(layout)" engine

UCI=
card
boot
layout > /dev/null
: > "$R/t/calls"
layout fail --reboot "it did not start" > /dev/null
expect "a failure with a restart" "$(calls)" \
	"logger -t bmcHwAccel Tăng tốc phần cứng unavailable: it did not start; the next boot is without it;reboot ;"

# The boot mark: written before the engine layout is built, removed once the
# engine has run well. A boot that never got that far leaves its line. After
# two such boots in a row the boots are in the kernel layout; one is not
# enough (a power cut in the first minute).
UCI=
card
boot
layout > /dev/null
boot
expect "one boot that did not finish starting it: the next one tries again" "$(layout)" engine
expect "and is marked as well" "$(state)" "booting: boot-$((boots - 1)) boot-$boots;"
expect "one is no reason against the boot after" "$(layout reason; echo "exit=$?")" "exit=1"
layout ok
expect "a boot that runs well forgets the one before" "$(state)" ""
boot
layout > /dev/null
boot
layout > /dev/null
boot
expect "two boots in a row that did not finish: the next one is in the kernel layout" "$(layout)" kernel
expect "with no hugepages" "$(hugepages)" 0
expect "and the reason" "$(layout reason)" boot_skipped
expect "the marks of those boots stay" "$(state)" "booting: boot-$((boots - 2)) boot-$((boots - 1));"
layout ok
expect "ok in the kernel layout changes nothing" "$(state)" "booting: boot-$((boots - 2)) boot-$((boots - 1));"
boot
expect "kernel boot after boot" "$(layout)" kernel
layout retry
expect "retry forgets the marks" "$(state)" ""
boot
expect "retry: the engine layout again" "$(layout)" engine
expect "marked again" "$(state)" "booting: boot-$boots;"
layout retry
expect "retry keeps the mark of this boot" "$(state)" "booting: boot-$boots;"
layout ok
expect "ok: the mark of this boot is gone" "$(state)" ""
boot
layout > /dev/null
boot
layout > /dev/null
UCI="config global 'global'
	option enabled '0'"
boot
expect "disabled after two boots that did not finish: the kernel layout" "$(layout)" kernel
expect "and the reason still told, for when it is enabled again" "$(layout reason)" boot_skipped

# A boot without the memory of the engine: the kernel layout for this boot
# only, with the reason; the next boot tries again.
HUGE_MAX=80
UCI=
card
boot
expect "nothing skipped before the layout is decided" "$(layout skipped; echo "exit=$?")" "exit=1"
expect "fewer hugepages than the engine needs: the kernel layout" "$(layout)" kernel
expect "and the hugepages are given back" "$(hugepages)" 0
expect "and syslog says why" "$(calls)" \
	"logger -t bmcHwAccel Tăng tốc phần cứng off for this boot: 80 of 129 hugepages of memory;"
expect "and so does skipped, for this boot" "$(layout skipped)" "80 of 129 hugepages of memory"
expect "but nothing is kept for the next boot" "$(ls "$R/t/state" 2>/dev/null)" ""
expect "no reason against the next boot" "$(layout reason; echo "exit=$?")" "exit=1"
HUGE_MAX=1000
boot
expect "the next boot: the engine layout" "$(layout)" engine
expect "nothing skipped" "$(layout skipped; echo "exit=$?")" "exit=1"

# The limits of what the ports of the engine send (ticket 21), from UCI, for
# the ports the engine has now; a wrong one is left out with a syslog line,
# so that the engine still starts.
UCI=
boot
expect "no tx_limit: no option" "$(layout tx-limits eth0 eth1)" ""
UCI="config global 'global'
	list tx_limit 'eth0:980'
	list tx_limit 'eth1:300'"
boot
expect "one option a port" "$(layout tx-limits eth0 eth1)" "--tx-limit eth0,980
--tx-limit eth1,300"
expect "and nothing logged" "$(calls)" ""
expect "only the ports of the engine" "$(layout tx-limits eth0)" "--tx-limit eth0,980"
expect "the others left out, and said" "$(calls)" \
	"logger -t bmcHwAccel tx_limit 'eth1:300' left out: eth1 is no port of the engine;"
UCI="config global 'global'
	list tx_limit 'eth0:0'
	list tx_limit 'eth0:7'
	list tx_limit 'eth0:10001'
	list tx_limit 'eth0:*'
	list tx_limit 'eth0:0980'
	list tx_limit 'eth0:fast'
	list tx_limit 'eth0'
	list tx_limit 'eth1:1000'
	list tx_limit 'eth1:500'"
boot
expect "rates out of 8 to 10000, not a number, none, and a port twice: left out" \
	"$(layout tx-limits eth0 eth1)" "--tx-limit eth1,1000"
expect "each said" "$(calls)" "logger -t bmcHwAccel tx_limit 'eth0:0' left out: 0 is no rate of 8 to 10000 Mbps;\
logger -t bmcHwAccel tx_limit 'eth0:7' left out: 7 is no rate of 8 to 10000 Mbps;\
logger -t bmcHwAccel tx_limit 'eth0:10001' left out: 10001 is no rate of 8 to 10000 Mbps;\
logger -t bmcHwAccel tx_limit 'eth0:*' left out: * is no rate of 8 to 10000 Mbps;\
logger -t bmcHwAccel tx_limit 'eth0:0980' left out: 0980 is no rate of 8 to 10000 Mbps;\
logger -t bmcHwAccel tx_limit 'eth0:fast' left out: fast is no rate of 8 to 10000 Mbps;\
logger -t bmcHwAccel tx_limit 'eth0' left out: no rate (PORT:MBPS);\
logger -t bmcHwAccel tx_limit 'eth1:500' left out: eth1 is given twice;"

[ $rc -eq 0 ] && echo "layout-test: PASS" || echo "layout-test: FAIL"
exit $rc
