#!/bin/sh
# Tests of bmcHwAccelDpdk, on the build machine (inside the ubuntu20
# container), against a DPDK built for that machine by host-dpdk.sh:
#   unit        seam 1: the per-packet core (tests/unit/core_test.c), "ESP
#               ops" with the OpenSSL backend (tests/unit/esp_test.c), the
#               engine's Tunnel IPsec over it (tests/unit/ipsec_test.c), and
#               what bmchwaccel-syncd decides (tests/unit/sync_test.c,
#               tests/unit/watch_test.c, tests/unit/sa_test.c)
#   functional  seam 2: the engine with net_memif ports, fed and read by
#               tests/functional/feeder.c, scenarios in scenario.py
#
#   docker exec ubuntu20 sh /home/working/github/bmcfirewall_ls1046-ls1088-dpdk/package/bmc/bmcHwAccelDpdk/tests/run.sh
#   sh tests/run.sh unit [TEST...]     only seam 1, or only some of its tests
#   sh tests/run.sh functional [NAME...]  only seam 2, or only some scenarios
#   sh tests/run.sh ctl                bmchwaccel-ctl against the engine of seam 2
#   sh tests/run.sh args               the engine refuses wrong options
# Seam 2 keeps what it sent, got and expected in tests/out/functional/NAME.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pc=$(sh "$here/host-dpdk.sh")
export PKG_CONFIG_PATH=$pc
out=$here/out
# -B: the bind mount of Docker on macOS sometimes shows a file just changed with its old time
make -s -B -C "$here" OUT="$out" all

# DPDK without hugepages, PCI or shared files: the container has none of them
eal="--no-huge -m 512 --no-pci --no-shconf --no-telemetry --log-level=*:warning"

what=${1:-all}
[ $# -gt 0 ] && shift
rc=0
# what a scenario leaves running or lying around if the run is cut short
engine=
sock=
cleanup() {
	[ -n "$engine" ] && kill "$engine" 2>/dev/null
	[ -n "$sock" ] && rm -rf "$sock"
	return 0
}
trap cleanup EXIT
# --vdev options of the four memif streams of the engine's ports, with their
# sockets in $sock: ROLE server (the engine) or client (the feeder)
memif_vdevs() { # role
	for s in eth0_wire eth0_kernel eth1_wire eth1_kernel; do
		printf ' --vdev=net_memif_%s,role=%s,socket=%s/%s,socket-abstract=no' "$s" "$1" "$sock" "$s"
	done
}
# the ports of the engine of seam 2: eth0 the WAN (port 0), eth1 the LAN (port 1)
PORTS="--port eth0,net_memif_eth0_wire,net_memif_eth0_kernel --port eth1,net_memif_eth1_wire,net_memif_eth1_kernel"
trap 'exit 130' INT
trap 'exit 143' TERM
case $what in
unit | all)
	echo "== unit"
	# the core calls nothing of DPAA2: it builds and runs without it
	if nm -u "$out/core.o" | grep -i -E 'dpaa|fslmc|qbman'; then
		echo "FAIL the core calls DPAA2"
		rc=1
	fi
	"$out/core_test" -l 0-1 $eal --file-prefix core_test -- "$@" || rc=1
	ESP_LINUX=$here/esp/linux "$out/esp_test" -l 0 $eal --file-prefix esp_test -- "$@" || rc=1
	ESP_LINUX=$here/esp/linux "$out/ipsec_test" -l 0 $eal --file-prefix ipsec_test -- "$@" || rc=1
	"$out/sync_test" "$@" || rc=1
	"$out/watch_test" "$@" || rc=1
	"$out/sa_test" "$@" || rc=1
	if [ "$what" = all ]; then set --; fi
	;;
esac
case $what in
functional | all)
	echo "== functional"
	fn=$here/functional
	for name in ${*:-$(python3 "$fn/scenario.py" --list)}; do
		d=$out/functional/$name
		rm -rf "$d"
		mkdir -p "$d/got"
		python3 "$fn/scenario.py" "$name" "$d"
		# a UNIX socket path has at most 108 bytes
		sock=$(mktemp -d /tmp/bmchwaccel.XXXXXX)
		# one worker
		"$out/bmchwaccel-engine" -l 0-1 $eal --file-prefix "engine-$name" $(memif_vdevs server) -- \
			$PORTS --socket "$sock/engine" $(cat "$d/engine-args" 2>/dev/null) >"$d/engine.log" 2>&1 &
		engine=$!
		i=0
		while [ ! -S "$sock/engine" ] && [ $i -lt 100 ]; do
			sleep 0.1
			i=$((i + 1))
		done
		ok=1
		"$out/feeder" -l 2 $eal --file-prefix "feeder-$name" $(memif_vdevs client) -- \
			--socket "$sock/engine" --script "$d/script" --out "$d/got" \
			>"$d/feeder.log" 2>&1 || { ok=0; tail -5 "$d/feeder.log"; }
		kill "$engine" 2>/dev/null || true
		wait "$engine" || { ok=0; echo "the engine failed:"; tail -5 "$d/engine.log"; }
		engine=
		rm -rf "$sock"
		sock=
		if [ -f "$d/engine-log" ]; then
			while IFS= read -r line; do
				grep -qF -- "$line" "$d/engine.log" || { ok=0; echo "the engine did not log: $line"; }
			done <"$d/engine-log"
		fi
		if [ $ok = 1 ]; then
			sed -E 's/idle=[0-9]+/idle=*/g' "$d/got/transcript" >"$d/got/transcript.cmp"
			diff -u "$d/expect/transcript" "$d/got/transcript.cmp" || ok=0
			for s in eth0-wire eth0-kernel eth1-wire eth1-kernel; do
				python3 "$fn/pcapcmp.py" "$d/expect/$s.pcap" "$d/got/$s.pcap" || ok=0
			done
		fi
		if [ $ok = 1 ]; then
			echo "ok   $name"
		else
			echo "FAIL $name"
			rc=1
		fi
	done
	;;
esac
case $what in
args | all)
	# options the engine refuses: it stops before its ports run (exit 1), and says why
	echo "== args"
	args_check() { # description, wanted message, options...
		desc=$1 want=$2
		shift 2
		# the sockets of a server memif stay behind it: new ones each time
		sock=$(mktemp -d /tmp/bmchwaccel.XXXXXX)
		got_rc=0
		got=$("$out/bmchwaccel-engine" -l 0-1 $eal --file-prefix engine-args $(memif_vdevs server) -- \
			$PORTS --socket "$sock/engine" "$@" 2>&1) || got_rc=$?
		rm -rf "$sock"
		sock=
		if [ "$got_rc" = 1 ] && printf '%s\n' "$got" | grep -qxF -- "bmchwaccel-engine: $want"; then
			echo "ok   args: $desc"
		else
			echo "FAIL args: $desc"
			echo "    | got ($got_rc): $(printf '%s\n' "$got" | tail -1)"
			echo "    | wanted (1): bmchwaccel-engine: $want"
			rc=1
		fi
	}
	args_check "--tx-limit of no port" "--tx-limit eth9: no such port" --tx-limit eth9,100
	args_check "--tx-limit of 0 Mbps" "--tx-limit MBPS 0" --tx-limit eth0,0
	args_check "--tx-limit below the step of the shapers" "--tx-limit eth0: 7 Mbps, 8 to 10000" --tx-limit eth0,7
	args_check "--tx-limit above 10 Gbps" "--tx-limit eth0: 10001 Mbps, 8 to 10000" --tx-limit eth0,10001
	args_check "--tx-limit without its rate" "--tx-limit NAME,MBPS" --tx-limit eth0
	args_check "--tx-limit twice for a port" "--tx-limit eth0: given twice" \
		--tx-limit eth0,100 --tx-limit eth0,200
	;;
esac
case $what in
ctl | all)
	# bmchwaccel-ctl, the client bmcHwAccel talks to the engine with, against
	# the engine of seam 2
	echo "== ctl"
	sock=$(mktemp -d /tmp/bmchwaccel.XXXXXX)
	"$out/bmchwaccel-engine" -l 0-1 $eal --file-prefix engine-ctl $(memif_vdevs server) -- \
		$PORTS --socket "$sock/engine" >"$out/ctl-engine.log" 2>&1 &
	engine=$!
	i=0
	while [ ! -S "$sock/engine" ] && [ $i -lt 100 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	ctl_check() { # description, wanted exit code, wanted output, arguments...
		d=$1 want_rc=$2 want=$3
		shift 3
		got_rc=0
		got=$("$out/bmchwaccel-ctl" "$@" 2>&1) || got_rc=$?
		if [ "$got_rc" = "$want_rc" ] && [ "$got" = "$want" ]; then
			echo "ok   ctl: $d"
		else
			echo "FAIL ctl: $d"
			echo "    | got ($got_rc): $got"
			echo "    | wanted ($want_rc): $want"
			rc=1
		fi
	}
	ctl_check "the answer of a command" 0 "ok 0" --socket "$sock/engine" count
	ctl_check "its lines of data, then the answer" 0 "port eth0 wire_rx=0 wire_tx=0 kernel_rx=0 kernel_tx=0
port eth1 wire_rx=0 wire_tx=0 kernel_rx=0 kernel_tx=0
ok" --socket "$sock/engine" stats
	# no client on the memif sockets: no link, so no speed
	ctl_check "the ports with their cables out" 0 "port eth0 link=down speed=unknown rx_bytes=0 tx_bytes=0 rx_packets=0 tx_packets=0
port eth1 link=down speed=unknown rx_bytes=0 tx_bytes=0 rx_packets=0 tx_packets=0
ok" --socket "$sock/engine" ports
	# the OpenSSL backend in place of the SEC; its self-test ran at the start
	ctl_check "ESP, which passed its self-test" 0 "esp state=ok device=openssl queue_pairs=2 sas=0 max_sas=24576
ok" --socket "$sock/engine" esp
	ctl_check "the words of a command make one line" 0 "ok 0" --socket "$sock/engine" flush-port eth1
	# the session of the daemon holds the engine: no other session can claim it
	python3 -c 'import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile("rw")
f.readline(); f.write("claim\n"); f.flush(); print(f.readline().strip(), flush=True); time.sleep(30)' \
		"$sock/engine" >"$out/claim.log" &
	holder=$!
	i=0
	while ! grep -q . "$out/claim.log" && [ $i -lt 50 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	if [ "$(cat "$out/claim.log")" = ok ]; then
		echo "ok   ctl: the daemon claims the engine"
	else
		echo "FAIL ctl: the daemon claims the engine: $(cat "$out/claim.log")"
		rc=1
	fi
	ctl_check "claimed while its session is open" 0 "ok yes" --socket "$sock/engine" claimed
	ctl_check "a second claim is refused" 1 "err claimed" --socket "$sock/engine" claim
	kill "$holder"
	wait "$holder" 2>/dev/null || true
	ctl_check "no longer claimed once its session closed" 0 "ok no" --socket "$sock/engine" claimed
	ctl_check "an error of the engine: exit 1" 1 "err unknown-command" --socket "$sock/engine" bogus
	ctl_check "no command: usage, exit 2" 2 \
		"usage: bmchwaccel-ctl [--socket PATH] [--timeout SECONDS] COMMAND [WORD...]" --socket "$sock/engine"
	kill "$engine" 2>/dev/null || true
	wait "$engine" 2>/dev/null || true
	engine=
	ctl_check "no engine: exit 3" 3 "bmchwaccel-ctl: $sock/engine: No such file or directory" \
		--socket "$sock/engine" count
	# a socket nobody answers on: given up after the timeout
	python3 -c 'import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(5)' "$sock/mute" &
	mute=$!
	sleep 0.5
	ctl_check "an engine that does not answer: exit 3 after the timeout" 3 \
		"bmchwaccel-ctl: $sock/mute: no answer within 1 s" --socket "$sock/mute" --timeout 1 count
	kill "$mute" 2>/dev/null || true
	rm -rf "$sock"
	sock=
	;;
esac
case $what in
unit | functional | args | ctl | all) ;;
*)
	echo "usage: run.sh [all | unit [TEST...] | functional [NAME...] | args | ctl]" >&2
	exit 2
	;;
esac
exit $rc
