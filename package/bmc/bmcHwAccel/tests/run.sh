#!/bin/sh
# Tests of the bmchwaccel CLI: run the real CLI in --dry-run mode on a `uci -X show` snapshot, with stand-ins
# for the daemon and for procd, and compare its WHOLE output with a golden file. Needs no uci, no module, no
# daemon and no board. The CLI of the DPAA2 boards (engine-dpdk.sh as engine.sh, the goldens dpdk-*) runs
# with the layout script of bmcHwAccelDpdk and a stand-in for the client of its engine.
#
#   sh tests/run.sh                    run the tests with the shell of this machine (macOS, Linux)
#   ROOTFS=<dir> sh tests/run.sh       run the CLI with the busybox of a built root filesystem (as root on an
#                                      aarch64 Linux): <dir> is build_dir/target-*/root-layerscape
#   UPDATE_GOLDEN=1 sh tests/run.sh    rewrite the goldens (review the git diff before committing)
#   TEST_SHELL=dash sh tests/run.sh    run the CLI with another shell
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
golden="$root/tests/golden"
shell=${TEST_SHELL:-sh}
passed=0
failed=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# The package as the DPAA2 boards have it, in <dir>/src, and the layout script of bmcHwAccelDpdk.
dpdk_copy() {
	mkdir -p "$1"
	cp -R "$root/src" "$1/"
	cp "$1/src/usr/lib/bmcHwAccel/engine-dpdk.sh" "$1/src/usr/lib/bmcHwAccel/engine.sh"
	cp "$root/../bmcHwAccelDpdk/files/layout" "$1/layout"
	chmod 755 "$1/layout"
}
if [ -n "${ROOTFS:-}" ]; then
	# A copy of the root filesystem with the package under /pkg (/pkg-dpdk as the DPAA2 boards have it): the
	# CLI, its libraries and the stand-ins all run in the image's own busybox.
	mkdir "$work/root"
	(cd "$ROOTFS" && tar cf - --exclude=./lib/modules --exclude=./lib/firmware .) | tar xf - -C "$work/root"
	mkdir "$work/root/pkg"
	cp -R "$root/src" "$root/tests" "$work/root/pkg/"
	dpdk_copy "$work/root/pkg-dpdk"
	pkg=/pkg
	pkg_dpdk=/pkg-dpdk
	shell="busybox of $ROOTFS"
	run_cli() {
		chroot "$work/root" /usr/bin/env "$@" /bin/sh "$src/usr/sbin/bmchwaccel" --dry-run $arguments
	}
else
	dpdk_copy "$work/dpdk"
	pkg=$root
	pkg_dpdk=$work/dpdk
	run_cli() {
		env "$@" "$shell" "$src/usr/sbin/bmchwaccel" --dry-run $arguments
	}
fi
fixtures="$pkg/tests/fixtures"
# The CLI of the LS1046 (NXP ASK) until "variant dpdk".
src=$pkg/src
variant() {
	if [ "$1" = dpdk ]; then src=$pkg_dpdk/src; else src=$pkg/src; fi
}

# Runtime state: procd's view of the daemon, the modules in the kernel, the number of Kết nối đã tăng tốc
# the daemon reports ("down": it does not answer), what the kernel log says about the microcode, the mark
# of module loads that never returned, and the state logged last.
ubus="$fixtures/fake-ubus-stopped.sh"
modules="$fixtures/modules-none"
accelerated=down
claimed=no
sa=none
microcode=none
marks="$fixtures/marks-none"
run="$fixtures/run-none"
# Whether the rules that mark what is kept on the CPU are in the firewall, and the devices of the router with
# what is stacked on them.
rules=missing
net="$fixtures/net-none"
pppoe="$fixtures/no-pppoe"
# What the features say they block, and the machines the router knows with their addresses.
blocked="$fixtures/blocked-none"
hosts="$fixtures/hosts"
# The ends of the connections that are bridged, as the firewall noted them.
bridged="$fixtures/bridged-none"

json_valid() {
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import json, sys; json.loads(sys.stdin.read())'
	fi
}

# Words that name the implementation, not the feature (CONTEXT.md): never in "message".
message_clean() {
	! sed -n 's/^{"status":[-0-9]*,"message":"\([^"]*\)".*/\1/p' |
		grep -q -i -E 'offload|fast.?path|cmm|cdx|(^|[^a-z])ask([^a-z]|$)|engine|dpdk'
}

# check <golden name> <fixture> <CLI arguments...>
check() {
	name=$1 fixture=$2
	shift 2
	arguments=$*
	raw=$(set +e; run_cli BMCHWACCEL_SNAPSHOT="$fixtures/$fixture.uci" BMCHWACCEL_UBUS="$ubus" \
		BMCHWACCEL_CMM="$fixtures/fake-cmm.sh" BMCHWACCEL_SYS_MODULE="$modules" \
		BMCHWACCEL_DMESG="$fixtures/fake-dmesg.sh" BMCHWACCEL_STATE_DIR="$marks" BMCHWACCEL_RUN_DIR="$run" \
		BMCHWACCEL_TABLES="$fixtures/fake-tables.sh" FAKE_ACCELERATED="$accelerated" FAKE_CLAIMED="$claimed" FAKE_MICROCODE="$microcode" \
		FAKE_SA="$sa" \
		FAKE_RULES="$rules" BMCHWACCEL_SYS_NET="$net" BMCHWACCEL_PPPOE="$pppoe" \
		BMCHWACCEL_BLOCKED_DIR="$blocked" BMCHWACCEL_HOSTS="$hosts" BMCHWACCEL_SETS="$fixtures/sets" \
		BMCHWACCEL_CONNTRACK="$fixtures/conntrack" BMCHWACCEL_BRIDGED="$bridged" \
		BMCHWACCEL_IP="$fixtures/fake-ip.sh" BMCHWACCEL_LAYOUT="$pkg_dpdk/layout" \
		BMCHWACCEL_ENGINE_CTL="$fixtures/fake-engine-ctl.sh" BMCHWACCEL_PROC="$fixtures/dpdk-proc" 2>&1; echo "exit=$?")
	output=$(printf '%s\n' "$raw" | sed '$d')
	if [ "${UPDATE_GOLDEN:-0}" = 1 ]; then
		printf '%s\n' "$raw" > "$golden/$name.out"
	fi
	if ! printf '%s\n' "$output" | json_valid 2>/dev/null; then
		printf 'FAIL %s: output is not one valid JSON object\n%s\n' "$name" "$output"
		failed=$((failed + 1))
	elif ! printf '%s\n' "$output" | message_clean; then
		printf 'FAIL %s: "message" names the implementation\n%s\n' "$name" "$output"
		failed=$((failed + 1))
	elif ! printf '%s\n' "$raw" | diff -u "$golden/$name.out" - >/dev/null 2>&1; then
		printf 'FAIL %s\n' "$name"
		printf '%s\n' "$raw" | diff -u "$golden/$name.out" - || true
		failed=$((failed + 1))
	else
		passed=$((passed + 1))
	fi
}

# get: Tăng tốc phần cứng is on by default, also on a router whose configuration file is missing.
check get-enabled enabled get
check get-disabled disabled get
check get-no-config no-config get

# status: "on" while the daemon runs and answers, with the number of Kết nối đã tăng tốc it reports. "on_cpu"
# is empty while no feature keeps traffic on the CPU.
ubus="$fixtures/fake-ubus-running.sh"
modules="$fixtures/modules-loaded"
microcode=ask
accelerated=12
check status-on enabled status
accelerated=0
check status-on-idle enabled status
# Disabled but not applied yet: the hardware still forwards.
accelerated=5
check status-on-apply-pending disabled status

# status: "unavailable" with a reason while enabled and the hardware does not forward.
# The daemon runs but does not answer; the daemon does not run.
accelerated=down
check status-unavailable-daemon-no-answer enabled status
ubus="$fixtures/fake-ubus-stopped.sh"
check status-unavailable-daemon enabled status
# A module is missing.
modules="$fixtures/modules-first-only"
check status-unavailable-module enabled status
modules="$fixtures/modules-none"
microcode=none
check status-unavailable-module-none enabled status
# The first module refused the public microcode; what the failed start left behind still tells once the
# kernel log has lost the line.
microcode=public
check status-unavailable-microcode enabled status
microcode=none
run="$fixtures/run-microcode"
check status-unavailable-microcode-noted enabled status
run="$fixtures/run-none"
# The module load did not return in the last two boots, so this boot left the modules alone. One such boot
# is not enough; a mark that the crash left empty counts as one.
marks="$fixtures/marks-two"
check status-unavailable-boot-skipped enabled status
marks="$fixtures/marks-one"
check status-unavailable-module-one-failed-boot enabled status
marks="$fixtures/marks-garbled"
check status-unavailable-module-garbled-mark enabled status
# Running in spite of the mark (loaded by hand): what the router does counts.
marks="$fixtures/marks-two"
ubus="$fixtures/fake-ubus-running.sh"
modules="$fixtures/modules-loaded"
accelerated=4
check status-on-with-mark enabled status

# status: "off" when disabled and the hardware does not forward, whatever else is wrong.
ubus="$fixtures/fake-ubus-stopped.sh"
modules="$fixtures/modules-none"
accelerated=down
microcode=public
check status-off-disabled disabled status
marks="$fixtures/marks-none"
microcode=none
check status-off-disabled-plain disabled status

# Giữ traffic trên CPU: a feature that does not work on a Kết nối đã tăng tốc registers what has to stay on
# the CPU (ADR-0011). status lists it with the reason, whatever the state.
ubus="$fixtures/fake-ubus-running.sh"
modules="$fixtures/modules-loaded"
accelerated=12
run="$fixtures/run-kept"
rules=installed
check status-on-kept enabled status
run="$fixtures/run-kept-two"
check status-on-kept-two enabled status
ubus="$fixtures/fake-ubus-stopped.sh"
accelerated=down
run="$fixtures/run-kept"
check status-off-kept disabled status

# keep: the first registration installs the rules that mark the connections through the WAN, and takes what
# is accelerated already out of the hardware: the daemon is stopped, every open connection is marked and the
# daemon is started again. Without a running daemon only the rules and the marks are needed.
ubus="$fixtures/fake-ubus-running.sh"
accelerated=12
run="$fixtures/run-none"
rules=missing
check keep-first enabled keep bmcqos wan eth0
ubus="$fixtures/fake-ubus-stopped.sh"
accelerated=down
check keep-first-not-running disabled keep bmcqos wan eth0
# Registered again (the feature restarted): nothing to do, unless the firewall lost the rules.
ubus="$fixtures/fake-ubus-running.sh"
accelerated=12
run="$fixtures/run-kept"
rules=installed
check keep-same enabled keep bmcqos wan eth0
rules=missing
check keep-same-rules-lost enabled keep bmcqos wan eth0
# A VLAN on the kept device and a PPPoE session over that VLAN pass the same device: the rules cover them,
# and are installed again once such a device has appeared.
net="$fixtures/net-stacked"
pppoe="$fixtures/pppoe-stacked"
check keep-stacked enabled keep bmcqos wan eth0
check refresh-stacked enabled refresh
net="$fixtures/net-none"
pppoe="$fixtures/no-pppoe"
# The feature moved to another WAN; a second feature keeps the same WAN, or another one.
rules=installed
check keep-other-wan enabled keep bmcqos wan pppoe-wan
check keep-second-reason-same-wan enabled keep other wan eth0
check keep-second-reason enabled keep other wan eth1.20

# release: the rules go, the marks are cleared and the daemon is started again, so open connections are
# accelerated again. Only the rules of that feature go while another one keeps something.
check release enabled release bmcqos
run="$fixtures/run-kept-two"
check release-one-of-two enabled release other
run="$fixtures/run-none"
rules=missing
check release-unknown enabled release bmcqos
# Left behind by a release that did not finish.
rules=installed
check release-leftover enabled release bmcqos

# refresh (after a firewall restart): installs the rules again when they are gone.
run="$fixtures/run-kept"
check refresh-none enabled refresh
rules=missing
check refresh-lost enabled refresh
run="$fixtures/run-none"
check refresh-empty enabled refresh

# apply: a daemon is never started while the rules of what is kept on the CPU are missing.
ubus="$fixtures/fake-ubus-stopped.sh"
accelerated=down
run="$fixtures/run-kept"
check apply-start-kept-rules-lost enabled apply
rules=installed
check apply-start-kept enabled apply

check keep-err-no-argument enabled keep
check keep-err-reason enabled keep 'bmc-qos' wan eth0
check keep-err-scope enabled keep bmcqos vlan eth0
check keep-err-device enabled keep bmcqos wan 'eth0;reboot'
check keep-err-device-long enabled keep bmcqos wan abcdefghijklmnop
check keep-err-device-option enabled keep bmcqos wan -j
check keep-err-extra enabled keep bmcqos wan eth0 eth1
check release-err-no-argument enabled release
check release-err-extra enabled release bmcqos now
check refresh-err-argument enabled refresh now
run="$fixtures/run-none"
rules=missing

# apply: the modules are loaded and the daemon runs exactly when Tăng tốc phần cứng is enabled. Only what is
# missing is loaded or started. Disabling stops the daemon and leaves the modules in the kernel.
ubus="$fixtures/fake-ubus-stopped.sh"
modules="$fixtures/modules-none"
accelerated=down
check apply-start enabled apply
check apply-start-no-config no-config apply
check apply-none-off disabled apply
modules="$fixtures/modules-first-only"
check apply-start-first-module-loaded enabled apply
modules="$fixtures/modules-loaded"
check apply-start-daemon-only enabled apply
ubus="$fixtures/fake-ubus-running.sh"
accelerated=3
check apply-none-on enabled apply
check apply-stop disabled apply
check apply-err-argument enabled apply now

# After two boots in a row that the module load broke, apply leaves the modules alone; one is not enough.
# enable tries again; disable has nothing to stop.
ubus="$fixtures/fake-ubus-stopped.sh"
modules="$fixtures/modules-none"
accelerated=down
marks="$fixtures/marks-two"
check apply-skip enabled apply
check apply-skip-no-config no-config apply
check apply-none-off-with-mark disabled apply
check enable-retry disabled enable
check enable-retry-enabled enabled enable
check disable-with-mark enabled disable
marks="$fixtures/marks-one"
check apply-start-one-failed-boot enabled apply
marks="$fixtures/marks-none"

# enable, disable: save "enabled", then do what apply does for the new value.
ubus="$fixtures/fake-ubus-stopped.sh"
modules="$fixtures/modules-none"
accelerated=down
check enable disabled enable
check enable-no-config no-config enable
check disable-not-running enabled disable
ubus="$fixtures/fake-ubus-running.sh"
modules="$fixtures/modules-loaded"
accelerated=3
check enable-already-on enabled enable
check disable enabled disable
check enable-err-argument disabled enable --now
check disable-err-argument enabled disable 0

# sweep: the connections of the machines a feature blocks by MAC address are taken out of the hardware, by
# deleting what conntrack has of them. Nothing to do while no feature blocks anyone.
ubus="$fixtures/fake-ubus-running.sh"
modules="$fixtures/modules-loaded"
accelerated=3
rules=installed
check sweep-none enabled sweep
# A firewall restart took out the rule that notes who opens connections.
rules=missing
check sweep-rule-lost enabled sweep
rules=installed
# A blocked machine loses every connection it is an end of, at each address it is known by. What a feature
# says is taken in either case of the letters; anything else it prints is left out.
blocked="$fixtures/blocked-one"
check sweep-block enabled sweep
# With a list of the machines that may open connections, every other machine loses those it opened.
blocked="$fixtures/blocked-allowlist"
check sweep-allowlist enabled sweep
# Both features at once.
blocked="$fixtures/blocked-both"
check sweep-both enabled sweep
# The blocked services of bmcfirewall: a connection goes when its machine is named, or when every machine
# is and this one has no lines of its own, and its other end is a member of the set. One command for a pair
# of addresses; the answering end counts as well, other protocols and an empty set do not.
blocked="$fixtures/blocked-services"
check sweep-services enabled sweep
# bmcfido: a machine of the LAN that is not in the set of those signed in. All of them at the first sweep ...
blocked="$fixtures/blocked-fido"
check sweep-fido-first enabled sweep
# ... later only one that was in the set at the last sweep ...
run="$fixtures/run-fido-before"
check sweep-fido-left enabled sweep
# ... and none while the set is what it was.
run="$fixtures/run-fido-same"
check sweep-fido-same enabled sweep
run="$fixtures/run-none"
# The machines that talk through a bridge: the kernel is told to resolve those it has no neighbour entry for,
# also one it failed to resolve before. Not one it knows, one behind a gateway, one it has no route to, or a
# link-local, broadcast or multicast address.
blocked="$fixtures/blocked-none"
bridged="$fixtures/bridged"
check sweep-neighbours enabled sweep
# No daemon, no Kết nối đã tăng tốc: every packet meets the rules already.
ubus="$fixtures/fake-ubus-stopped.sh"
accelerated=down
check sweep-not-running disabled sweep
bridged="$fixtures/bridged-none"
check sweep-err-argument enabled sweep now
blocked="$fixtures/blocked-none"

# The programs of blocked.d that read the rules of a feature, with stand-ins for iptables, ip and date: what
# the blocked services drop at this hour (Monday evening UTC, Tuesday morning here), and whom bmcfido lets
# send. Not in the root filesystem, where the stand-ins would have to be the image's.
provider() { # <golden name> <program> [<variable>=<value>]
	said=$(env PATH="$root/tests/fixtures/providers:$PATH" ${3:-PROVIDER=} "$shell" "$root/src/usr/share/bmcHwAccel/blocked.d/$2" 2>&1) || true
	[ "${UPDATE_GOLDEN:-0}" != 1 ] || printf '%s\n' "$said" > "$golden/$1.out"
	if printf '%s\n' "$said" | diff -u "$golden/$1.out" -; then
		passed=$((passed + 1))
	else
		echo "FAIL $1"
		failed=$((failed + 1))
	fi
}
if [ -z "${ROOTFS:-}" ]; then
	provider provider-services blocked_services
	provider provider-fido bmcfido
	provider provider-fido-off bmcfido FAKE_FIDO=off
fi

# ports: the hardware holds no port, the kernel counts all traffic of each: an empty list.
check ports enabled ports
check ports-err-argument enabled ports eth0
# sa: the hardware holds no key of Tunnel IPsec yet on this board: an empty list ("ipsec_sa" of status is 0).
check sa enabled sa
check sa-err-argument enabled sa 0xc0000001

# Anything else is answered with the usage; no command takes an argument.
check usage enabled
check bogus enabled bogus
check get-err-argument enabled get --enabled 0

# The DPAA2 boards (LS1088). The engine holds the 10G ports in the engine layout, which a boot builds when
# enabled; the layout of a boot never changes while it runs. Runtime state: the layout of this boot (in the
# run directory, as bmcHwAccelDpdk keeps it), the boot mark and the failure a boot left in the state
# directory, the number of Kết nối đã tăng tốc the engine reports ("down": it does not answer), procd's view
# of the daemon that hands connections to the engine, and whether that daemon holds its session with the
# engine ("claimed").
variant dpdk
ubus="$fixtures/fake-ubus-running.sh"
claimed=yes
modules="$fixtures/modules-none"
rules=missing
run="$fixtures/dpdk-run-engine"
marks="$fixtures/dpdk-state-none"
accelerated=0

# get: two more options, read at boot: workers (1 to 4, 4 by default) and the MACs of the engine
# (dpmac.1 and dpmac.2 by default). A value that is not valid comes with "field" and what the next boot
# uses instead; the configuration is still given.
check dpdk-get enabled get
check dpdk-get-workers-ports dpdk-workers-2 get
check dpdk-get-workers-wrong dpdk-workers-7 get
check dpdk-get-workers-word dpdk-workers-word get
check dpdk-get-port-wrong dpdk-port-wrong get

# status in the engine layout: "on" while the engine answers and the daemon holds its session with it, also
# in the first minute of the boot, whose own mark says nothing of the next boot.
check dpdk-status-on enabled status
marks="$fixtures/dpdk-state-mark-this-boot"
check dpdk-status-on-boot-marked enabled status
marks="$fixtures/dpdk-state-none"
# Disabled: "off" at once, with a restart to remove the engine layout; "on" while the engine still holds
# connections (not applied yet).
check dpdk-status-off-restart disabled status
accelerated=3
check dpdk-status-on-apply-pending disabled status
# The engine does not answer: it is being started again.
accelerated=down
check dpdk-status-unavailable-restarting enabled status
# The engine answers, but no daemon hands it connections: every connection goes through the kernel.
accelerated=0
claimed=no
check dpdk-status-unavailable-daemon enabled status
ubus="$fixtures/fake-ubus-stopped.sh"
check dpdk-status-unavailable-daemon-stopped enabled status

# status in the kernel layout, where no daemon runs. Enabled on it: "off" until a restart.
run="$fixtures/dpdk-run-kernel"
check dpdk-status-off-takes-effect-after-restart enabled status
check dpdk-status-off-disabled disabled status
# Two boots in a row did not finish starting the engine layout; one could not run the engine: unavailable, and
# the next boot is in the kernel layout as well.
marks="$fixtures/dpdk-state-mark"
check dpdk-status-unavailable-boot-skipped enabled status
marks="$fixtures/dpdk-state-failed"
check dpdk-status-unavailable-engine enabled status
marks="$fixtures/dpdk-state-failed-and-mark"
check dpdk-status-unavailable-engine-and-mark enabled status
check dpdk-status-off-disabled-failed disabled status
# This boot had not the memory of the engine: unavailable for this boot only, the next one tries again.
run="$fixtures/dpdk-run-kernel-memory"
marks="$fixtures/dpdk-state-none"
check dpdk-status-unavailable-memory enabled status
check dpdk-apply-skip-memory enabled apply
run="$fixtures/dpdk-run-kernel"
marks="$fixtures/dpdk-state-failed-and-mark"

# apply in the kernel layout: no daemon to start; in the kernel layout of a failed boot nothing is tried
# ("skip"). enable forgets the failed boots: the next boot tries the engine layout.
check dpdk-apply-skip enabled apply
check dpdk-enable-retry disabled enable
check dpdk-enable-retry-enabled enabled enable
check dpdk-disable-failed enabled disable
marks="$fixtures/dpdk-state-none"
check dpdk-apply-none-takes-effect-after-restart enabled apply
check dpdk-enable-kernel-layout disabled enable
check dpdk-disable-kernel-layout enabled disable
# In the engine layout, enabled: the daemon is started once the engine answers (its supervisor applies
# then), and the rules of what is kept on the CPU go in first; nothing to do while it runs. Disabled: the
# daemon is stopped, and the engine lets go of what it holds when its session closes; an engine that holds
# connections without a daemon lets go of them.
run="$fixtures/dpdk-run-engine"
accelerated=0
check dpdk-apply-start enabled apply
check dpdk-enable-engine-layout disabled enable
run="$fixtures/dpdk-run-engine-kept"
check dpdk-apply-start-kept enabled apply
run="$fixtures/dpdk-run-engine"
accelerated=down
check dpdk-apply-none-restarting enabled apply
accelerated=0
check dpdk-apply-none-off disabled apply
accelerated=3
check dpdk-apply-stop disabled apply
check dpdk-disable enabled disable
ubus="$fixtures/fake-ubus-running.sh"
claimed=yes
accelerated=0
check dpdk-apply-none-on enabled apply
accelerated=3
check dpdk-apply-stop-daemon disabled apply
check dpdk-disable-daemon enabled disable
accelerated=0
# What is kept on the CPU: the daemon looks at the mark when it hands a connection over, so it is stopped
# while every open connection gets the mark, as on the LS1046; without a daemon, the rules and marks only.
check dpdk-keep-daemon enabled keep bmcqos wan eth0
ubus="$fixtures/fake-ubus-stopped.sh"
claimed=no
check dpdk-keep-first enabled keep bmcqos wan eth0
rules=installed
check dpdk-sweep-none enabled sweep
# ports: in the engine layout the ports of the engine as their cables see them, whatever "enabled" says;
# none while the engine does not answer, and none in the kernel layout, whose kernel counts every packet.
check dpdk-ports enabled ports
check dpdk-ports-disabled disabled ports
accelerated=down
check dpdk-ports-no-answer enabled ports
# An answer this CLI cannot read is no answer: no port rather than some of them.
accelerated=garbled
check dpdk-ports-garbled enabled ports
run="$fixtures/dpdk-run-kernel"
accelerated=0
check dpdk-ports-kernel-layout enabled ports
# sa: the SAs of Tunnel IPsec the engine holds, with "seq" for an outbound one, and their number in "ipsec_sa"
# of status; none in the kernel layout or while the engine does not answer, or answers what cannot be read.
sa=tunnel
check dpdk-sa-kernel-layout enabled sa
run="$fixtures/dpdk-run-engine"
ubus="$fixtures/fake-ubus-running.sh"
claimed=yes
accelerated=3
check dpdk-sa enabled sa
check dpdk-status-on-ipsec enabled status
accelerated=down
check dpdk-sa-no-answer enabled sa
accelerated=0
sa=garbled
check dpdk-sa-garbled enabled sa
sa=none
check dpdk-sa-none enabled sa
claimed=no
variant ask

# daemon-running, for other features (bmcMultiWAN): exit 0 exactly while procd runs the daemon of the board,
# nothing printed.
check_daemon_running() { # variant, the service procd runs, wanted exit code
	variant "$1"
	got=0
	if [ -n "${ROOTFS:-}" ]; then
		chroot "$work/root" /usr/bin/env BMCHWACCEL_UBUS="$fixtures/fake-ubus-service.sh" FAKE_SERVICE="$2" \
			/bin/sh "$src/usr/lib/bmcHwAccel/daemon-running" > "$work/daemon-running.out" 2>&1 || got=$?
	else
		env BMCHWACCEL_UBUS="$fixtures/fake-ubus-service.sh" FAKE_SERVICE="$2" \
			"$shell" "$src/usr/lib/bmcHwAccel/daemon-running" > "$work/daemon-running.out" 2>&1 || got=$?
	fi
	if [ "$got" = "$3" ] && [ ! -s "$work/daemon-running.out" ]; then
		passed=$((passed + 1))
	else
		printf 'FAIL daemon-running %s with %s running: exit %s, wanted %s\n' "$1" "${2:-nothing}" "$got" "$3"
		cat "$work/daemon-running.out"
		failed=$((failed + 1))
	fi
	variant ask
}
check_daemon_running ask cmm 0
check_daemon_running ask bmchwaccel-syncd 1
check_daemon_running ask '' 1
check_daemon_running dpdk bmchwaccel-syncd 0
check_daemon_running dpdk cmm 1
check_daemon_running dpdk '' 1

# Real execution, only in the root filesystem: uci is the image's own, and stand-ins take the calls that would
# reach the kernel, procd and syslog. A "loaded" module is a directory, the control device comes with cdx, and
# the daemon "runs" while /tmp/daemon exists. With /tmp/slow a stopped daemon takes two seconds to be gone,
# with /tmp/stuck it stays, with /tmp/mute a started one never runs. modprobe notes the mark it finds; with
# /tmp/crash it takes the CLI down with it, as a load that crashes the router does. With /tmp/public the
# kernel log has the refusal of the public microcode. The supervisor runs /fake/daemon, which dies at once
# while /tmp/dies or (once) /tmp/dies-once exists. iptables and ip6tables keep the rules they are given in
# /tmp/tables and answer from them; with /tmp/deaf they take none. conntrack only notes its call.
if [ -n "${ROOTFS:-}" ]; then
	mkdir -p "$work/root/fake" "$work/root/tmp/modules"
	cat > "$work/root/fake/modprobe" <<'EOF'
#!/bin/sh
echo "modprobe $1 (mark: $(cat /etc/bmcHwAccel/loading 2>/dev/null || echo none))" >> /tmp/calls
[ ! -e /tmp/crash ] || kill -KILL "$PPID"
[ ! -e "/tmp/refuse-$1" ] || exit 1
mkdir -p "/tmp/modules/$1"
EOF
	cat > "$work/root/etc/init.d/cmm" <<'EOF'
#!/bin/sh
echo "/etc/init.d/cmm $1" >> /tmp/calls
case "$1" in
	start) [ -e /tmp/mute ] || : > /tmp/daemon ;;
	stop)
		if [ -e /tmp/stuck ]; then
			:
		elif [ -e /tmp/slow ]; then
			(sleep 2; rm -f /tmp/daemon) &
		else
			rm -f /tmp/daemon
		fi
		;;
esac
EOF
	cat > "$work/root/fake/logger" <<'EOF'
#!/bin/sh
echo "logger $*" >> /tmp/calls
EOF
	cat > "$work/root/fake/ubus" <<'EOF'
#!/bin/sh
if [ -e /tmp/daemon ]; then echo '{ "cmm": { "instances": { "cmm": { "running": true } } } }'; else echo '{}'; fi
EOF
	cat > "$work/root/fake/dmesg" <<'EOF'
#!/bin/sh
[ ! -e /tmp/public ] || echo '[   58.484938] cdx: FMAN firmware 106.4.18 lacks ASK support (need package >= 209). Load the ASK microcode in U-Boot.'
EOF
	cat > "$work/root/fake/daemon" <<'EOF'
#!/bin/sh
echo "daemon started" >> /tmp/calls
[ ! -e /tmp/dies ] || exit 1
if [ -e /tmp/dies-once ]; then rm /tmp/dies-once; exit 1; fi
trap 'echo "daemon got SIGTERM" >> /tmp/calls; rm -f /tmp/daemon; exit 0' TERM
: > /tmp/daemon
while :; do sleep 1; done
EOF
	cat > "$work/root/fake/cmm" <<'EOF'
#!/bin/sh
[ "$1" != -R ] || { echo "cmm -R" >> /tmp/calls; exit 0; }
[ -e /tmp/daemon ] || exit 0
printf 'Maximum Active Connections: 131072 \nNumber of Active Connections: 7 \n'
EOF
	cat > "$work/root/fake/iptables" <<'EOF'
#!/bin/sh
name=${0##*/}
state=/tmp/tables/$name
mkdir -p /tmp/tables
touch "$state"
[ "$1" != -w ] || shift
[ "$1" != -t ] || shift 2
op=$1
shift
case "$op" in -C|-S) ;; *) echo "$name $op $*" >> /tmp/calls ;; esac
drop() { grep -v "$@" "$state" > "$state.new"; mv "$state.new" "$state"; }
case "$op" in
	-N) ! grep -q -x ":$1" "$state" || exit 1; [ -e /tmp/deaf ] || echo ":$1" >> "$state" ;;
	-F) drop "^$1 " ;;
	-X) drop -x ":$1" ;;
	-A|-I) [ -e /tmp/deaf ] || echo "$*" >> "$state" ;;
	-D) grep -q -x -F -e "$*" "$state" || exit 1; drop -x -F -e "$*" ;;
	-C) grep -q -x -F -e "$*" "$state" ;;
	-S) grep -q -x ":$1" "$state" ;;
esac
EOF
	cp "$work/root/fake/iptables" "$work/root/fake/ip6tables"
	cat > "$work/root/fake/conntrack" <<'EOF'
#!/bin/sh
echo "conntrack $*" >> /tmp/calls
EOF
	chmod +x "$work/root/fake/"* "$work/root/etc/init.d/cmm"
	in_root() {
		chroot "$work/root" /usr/bin/env PATH=/fake:/usr/sbin:/usr/bin:/sbin:/bin BMCHWACCEL_SYS_MODULE=/tmp/modules \
			BMCHWACCEL_CONTROL_DEVICE=/tmp/modules/cdx /bin/sh -c "$1"
	}
	cli() {
		echo "\$ bmchwaccel $*"
		in_root "/bin/sh /pkg/src/usr/sbin/bmchwaccel $*; echo exit=\$?"
	}
	calls() {
		echo "calls:"
		in_root 'cat /tmp/calls 2>/dev/null; : > /tmp/calls'
	}
	mark() {
		echo "mark: $(in_root 'cat /etc/bmcHwAccel/loading 2>/dev/null || echo none')"
	}
	supervise="BMCHWACCEL_RESPAWN_DELAY=0 /bin/sh /pkg/src/usr/lib/bmcHwAccel/supervise /fake/daemon"
	{
		cli status
		cli apply; calls
		cli status
		cli apply; calls
		cli disable; calls
		echo "saved: $(in_root 'uci -q get bmchwaccel.global.enabled')"
		cli status
		cli enable; calls
		echo "saved: $(in_root 'uci -q get bmchwaccel.global.enabled')"
		# A stopped daemon empties the hardware before it goes: disable waits for it.
		in_root ': > /tmp/slow'
		cli disable; calls
		cli status
		in_root 'rm /tmp/slow'
		cli enable; calls
		# A daemon that does not go: the choice is saved, the failure is reported, nothing is logged.
		in_root ': > /tmp/stuck'
		cli disable; calls
		echo "saved: $(in_root 'uci -q get bmchwaccel.global.enabled')"
		cli status
		in_root 'rm /tmp/stuck'
		# Nothing to switch, nothing logged.
		cli enable; calls
		# A module that does not load ends the plan there: unavailable, logged once, and the load returned.
		in_root 'rm -rf /tmp/modules/* /tmp/daemon; : > /tmp/refuse-auto_bridge'
		cli apply; calls
		mark
		cli status
		cli apply; calls
		# Disabled while unavailable, then enabled again: each change is logged.
		cli disable; calls
		cli enable; calls
		# The first module refuses the public microcode.
		in_root 'rm -rf /tmp/modules/* /tmp/refuse-auto_bridge; : > /tmp/refuse-cdx; : > /tmp/public'
		cli apply; calls
		cli status
		# Disabled and enabled with the line gone from the kernel log: still the microcode.
		in_root 'rm /tmp/public'
		cli disable; calls
		cli enable; calls
		in_root 'rm -rf /tmp/refuse-cdx /tmp/run'
		# The modules load, the daemon never runs.
		in_root ': > /tmp/mute'
		cli apply; calls
		cli status
		in_root 'rm -rf /tmp/mute /tmp/modules/*'
		# A load that takes the router down, twice in a row: the third apply leaves the modules alone.
		in_root ': > /tmp/crash'
		cli apply 2>/dev/null; calls
		mark
		cli apply 2>/dev/null; calls
		mark
		in_root 'rm /tmp/crash'
		cli apply; calls
		cli status
		cli apply; calls
		# disable does not forget the failed boots, enable does and tries again.
		cli disable; calls
		mark
		cli enable; calls
		mark
		cli status
		cli disable; calls
		# The supervisor: a daemon that dies once is started again; the hardware is emptied in between and
		# both changes are logged. Stopping the service stops the daemon and logs nothing.
		in_root "rm -rf /tmp/run; : > /tmp/dies-once; $supervise & pid=\$!; sleep 4; echo starts=\$(cat /tmp/run/bmcHwAccel/daemon-starts); kill -TERM \$pid; wait \$pid; echo exit=\$?"
		calls
		# A daemon that keeps dying is given up: the hardware is left empty, one syslog line.
		in_root "rm -rf /tmp/run; : > /tmp/dies; $supervise; echo exit=\$?; echo state=\$(cat /tmp/run/bmcHwAccel/state) starts=\$(cat /tmp/run/bmcHwAccel/daemon-starts)"
		calls
		# Giữ traffic trên CPU. With the daemon running: the rules, then the daemon is stopped, every open
		# connection is marked, and the daemon is started again. One syslog line.
		in_root 'rm -rf /tmp/run /tmp/calls /tmp/dies'
		cli enable; calls
		cli keep bmcqos wan eth0; calls
		echo "kept: $(in_root 'cat /tmp/run/bmcHwAccel/on_cpu' | tr '\t' ' ')"
		cli status
		# Registered again: nothing is touched.
		cli keep bmcqos wan eth0; calls
		# A firewall restart took the rules out: refresh puts them back and keeps what is open on the CPU.
		in_root 'rm -rf /tmp/tables'
		cli refresh; calls
		cli refresh; calls
		# Another WAN while Tăng tốc phần cứng is disabled: rules and marks, no daemon.
		cli disable; calls
		cli keep bmcqos wan pppoe-wan; calls
		cli status
		# Enabled after the firewall lost the rules: they come back before the daemon starts.
		in_root 'rm -rf /tmp/tables'
		cli enable; calls
		# A firewall that takes no rule: the daemon is stopped and stays stopped, so nothing passes the
		# feature in the hardware. Starting it is refused as well, until the rules can be installed.
		in_root 'rm -rf /tmp/tables; : > /tmp/deaf'
		cli refresh; calls
		cli status
		cli apply; calls
		in_root 'rm /tmp/deaf'
		cli apply; calls
		cli status
		# A daemon that does not stop: reported, the registration stays.
		in_root 'rm -rf /tmp/tables; : > /tmp/stuck'
		cli refresh; calls
		in_root 'rm /tmp/stuck'
		cli refresh; calls
		# The control device is gone when the daemon is to start again: reported, and the next refresh
		# starts it.
		in_root 'rm -rf /tmp/tables; mv /tmp/modules/cdx /tmp/modules/cdx.away'
		cli refresh 2>&1 | cut -c1-120; calls
		cli status
		in_root 'mv /tmp/modules/cdx.away /tmp/modules/cdx'
		cli refresh 2>&1 | cut -c1-120; calls
		cli status
		# Released: the rules go, the marks are cleared, the daemon accelerates what is open again.
		cli release bmcqos; calls
		cli status
		cli release bmcqos; calls
	} > "$work/execute.out" 2>&1
	if [ "${UPDATE_GOLDEN:-0}" = 1 ]; then
		cp "$work/execute.out" "$golden/execute.out"
	fi
	if diff -u "$golden/execute.out" "$work/execute.out"; then
		passed=$((passed + 1))
	else
		echo 'FAIL execute'
		failed=$((failed + 1))
	fi

	# The same on the DPAA2 boards: the CLI of /pkg-dpdk, the layout script of bmcHwAccelDpdk, and the
	# supervisor of the engine. A boot is a new boot id, an empty run directory and the layout the boot
	# decided (with its mark in the engine layout, as the layout script writes it); the state directory
	# stays. The engine /fake/engine "answers" while /tmp/engine-up exists and it runs; it dies at once
	# as often as /tmp/dies-count says, and never answers with /tmp/mute. It holds /tmp/held connections,
	# which a flush lets go of, and so does the end of the daemon's session. The daemon runs while
	# /tmp/daemon-running exists (its init script /fake/syncd, procd's view /fake/ubus), and holds its
	# session with an engine that answers. logger and reboot only note their call.
	cat > "$work/root/fake/engine" <<'EOF'
#!/bin/sh
echo "engine started" >> /tmp/calls
echo $$ > /tmp/engine-pid
n=$(cat /tmp/dies-count 2>/dev/null || echo 0)
if [ "$n" -gt 0 ]; then echo $((n - 1)) > /tmp/dies-count; exit 1; fi
trap 'rm -f /tmp/engine-up; exit 0' TERM
[ -e /tmp/mute ] || : > /tmp/engine-up
while :; do sleep 1; done
EOF
	cat > "$work/root/fake/bmchwaccel-ctl" <<'EOF'
#!/bin/sh
[ -e /tmp/engine-up ] && kill -0 "$(cat /tmp/engine-pid)" 2>/dev/null || {
	echo 'bmchwaccel-ctl: /var/run/bmchwaccel-engine.sock: Connection refused' >&2
	exit 3
}
case "$1" in
	count) echo "ok $(cat /tmp/held 2>/dev/null || echo 0)" ;;
	claimed) if [ -e /tmp/daemon-running ]; then echo 'ok yes'; else echo 'ok no'; fi ;;
	flush) echo "bmchwaccel-ctl flush" >> /tmp/calls; echo "ok $(cat /tmp/held 2>/dev/null || echo 0)"; rm -f /tmp/held ;;
esac
EOF
	cat > "$work/root/fake/syncd" <<'EOF'
#!/bin/sh
echo "daemon $1" >> /tmp/calls
case "$1" in
	start) : > /tmp/daemon-running ;;
	stop) rm -f /tmp/daemon-running /tmp/held ;;
esac
EOF
	cat > "$work/root/fake/ubus" <<'EOF'
#!/bin/sh
if [ -e /tmp/daemon-running ]; then echo '{"bmchwaccel-syncd":{"instances":{"instance1":{"running":true}}}}'; else echo '{}'; fi
EOF
	printf '#!/bin/sh\necho "reboot" >> /tmp/calls\n' > "$work/root/fake/reboot"
	printf '#!/bin/sh\n' > "$work/root/fake/sysctl"
	chmod +x "$work/root/fake/"*
	dpdk_root() {
		chroot "$work/root" /usr/bin/env PATH=/fake:/usr/sbin:/usr/bin:/sbin:/bin BMCHWACCEL_RUN_DIR=/tmp/drun \
			BMCHWACCEL_STATE_DIR=/tmp/dstate BMCHWACCEL_PROC=/tmp/dproc BMCHWACCEL_LAYOUT=/pkg-dpdk/layout \
			BMCHWACCEL_ENGINE_CTL=/fake/bmchwaccel-ctl BMCHWACCEL_RESPAWN_DELAY=0 BMCHWACCEL_ANSWER_WAIT=3 \
			BMCHWACCEL_SETTLED=2 BMCHWACCEL_UBUS=/fake/ubus BMCHWACCEL_DAEMON_INITD=/fake/syncd /bin/sh -c "$1"
	}
	dcli() {
		echo "\$ bmchwaccel $*"
		dpdk_root "/bin/sh /pkg-dpdk/src/usr/sbin/bmchwaccel $*; echo exit=\$?"
	}
	dcalls() {
		echo "calls:"
		dpdk_root 'cat /tmp/calls 2>/dev/null; : > /tmp/calls'
	}
	boots=0
	dboot() { # engine | kernel
		boots=$((boots + 1))
		echo "-- boot $boots, $1 layout"
		dpdk_root "kill -KILL \$(cat /tmp/engine-pid 2>/dev/null) 2>/dev/null; rm -rf /tmp/drun /tmp/engine-up /tmp/held /tmp/dies-count /tmp/mute /tmp/daemon-running
			mkdir -p /tmp/drun /tmp/dstate /tmp/dproc/sys/kernel/random; echo boot-$boots > /tmp/dproc/sys/kernel/random/boot_id
			echo $1 > /tmp/drun/layout; [ $1 != engine ] || echo \$(cat /tmp/dstate/booting 2>/dev/null) boot-$boots > /tmp/dstate/booting"
	}
	dstate() {
		echo "kept: $(dpdk_root 'cd /tmp/dstate && for f in *; do [ -e "$f" ] && echo "$f=$(cat "$f")"; done' | tr '\n' ' ')"
	}
	supervise_start() {
		dpdk_root "/bin/sh /pkg-dpdk/src/usr/lib/bmcHwAccel/supervise-engine /fake/engine > /dev/null 2>&1 &
			echo \$! > /tmp/supervisor"
	}
	supervise_stop() {
		dpdk_root 'kill -TERM $(cat /tmp/supervisor); while kill -0 $(cat /tmp/supervisor) 2>/dev/null; do sleep 1; done'
	}
	{
		dpdk_root 'rm -rf /tmp/calls /tmp/dstate; uci set bmchwaccel.global.enabled=1; uci commit bmchwaccel'
		# Enabled: the engine of the boot answers, its daemon is started, Tăng tốc phần cứng goes on, and
		# the mark of the boot goes once the engine has run a while.
		dboot engine
		supervise_start
		sleep 5
		dcli status; dcalls; dstate
		# Disabled while it runs: the daemon stops and the engine lets go of what it holds; off at once,
		# the engine layout goes at the next boot. Enabled again: the daemon starts, on at once.
		dpdk_root 'echo 2 > /tmp/held'
		dcli disable; dcalls
		dcli status
		dcli disable; dcalls
		dcli enable; dcalls
		dcli status
		# The engine dies, twice: started again each time on the same container, its daemon claims it
		# again, back on.
		dpdk_root 'echo 1 > /tmp/dies-count; kill -KILL $(cat /tmp/engine-pid)'
		sleep 4
		dcalls
		dcli status
		# The daemon gone while the engine runs: unavailable; the next apply starts it again.
		dpdk_root 'rm -f /tmp/daemon-running'
		dcli status
		dcli apply; dcalls
		dcli status
		# A third time within 5 minutes: the boots after are in the kernel layout, the router restarts.
		dpdk_root 'kill -KILL $(cat /tmp/engine-pid)'
		sleep 2
		dcalls; dstate
		dpdk_root 'kill -0 $(cat /tmp/supervisor) 2>/dev/null && echo "supervisor: running" || echo "supervisor: gone"'
		# The next boot: unavailable, with the reason, until enabled; enabled, it takes a restart.
		dboot kernel
		dcli apply; dcalls
		dcli status
		dcli enable; dcalls; dstate
		dcli status
		# The boot after: the engine layout, on.
		dboot engine
		supervise_start
		sleep 2
		dcli status; dcalls
		supervise_stop; dcalls
		# Two boots in a row that hung before their engine ran: their marks stay, and the next boot is in the
		# kernel layout.
		dboot engine
		dboot engine
		dboot kernel
		dcli status
		dcli enable; dcalls; dstate
		dboot engine
		# An engine that never answers: the engine layout fails at once.
		dpdk_root ': > /tmp/mute'
		supervise_start
		sleep 6
		dcalls; dstate
		dpdk_root 'kill -0 $(cat /tmp/supervisor) 2>/dev/null && echo "supervisor: running" || echo "supervisor: gone"'
		# Stopped by procd (shutdown): the engine is stopped with it, nothing logged.
		dpdk_root 'rm -rf /tmp/dstate/*'
		dboot engine
		supervise_start
		sleep 2
		dcalls
		supervise_stop; dcalls
	} > "$work/dpdk-execute.out" 2>&1
	if [ "${UPDATE_GOLDEN:-0}" = 1 ]; then
		cp "$work/dpdk-execute.out" "$golden/dpdk-execute.out"
	fi
	if diff -u "$golden/dpdk-execute.out" "$work/dpdk-execute.out"; then
		passed=$((passed + 1))
	else
		echo 'FAIL dpdk-execute'
		failed=$((failed + 1))
	fi
fi

printf '%s passed, %s failed (%s)\n' "$passed" "$failed" "$shell"
[ "$failed" -eq 0 ]
