#!/bin/sh
# Tests of the bmcmultiwan CLI: run the real CLI in --dry-run mode on a `uci -X show` snapshot and compare
# its WHOLE output with a golden file. Needs no uci, mwan3, ubus or device.
#
#   sh tests/run.sh                    run the tests
#   UPDATE_GOLDEN=1 sh tests/run.sh    rewrite the goldens (review the git diff before committing)
#   TEST_SHELL=dash sh tests/run.sh    run the CLI with another shell (closer to busybox ash)
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cli="$root/src/usr/sbin/bmcmultiwan"
fixtures="$root/tests/fixtures"
golden="$root/tests/golden"
shell=${TEST_SHELL:-sh}
# Runtime state of mwan3: procd's view of the service, what it left in the kernel, mwan3track's status files,
# netifd's status of each WAN; runtime files of bmcmultiwan (state of each WAN, last Chuyển WAN) and the clock.
ubus="$fixtures/fake-ubus-stopped.sh"
leftovers="$fixtures/fake-leftovers-none.sh"
hook="$fixtures/fake-hook-present.sh"
track_dir="$fixtures/track-none"
iface_dir="$fixtures/ifaces-up"
run_dir="$fixtures/run-none"
# Whether the daemon of Tăng tốc phần cứng runs, as bmcHwAccel says (fake-hwaccel-daemon.sh).
hwaccel=stopped
now=1790000500
passed=0
failed=0

# Goldens keep "\n" inside JSON strings expanded to real newlines, so that diffs are readable.
readable() {
	awk '{ gsub(/\\n/, "\n"); print }'
}

json_valid() {
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import json, sys; json.loads(sys.stdin.read())'
	fi
}

# check <golden name> <fixture> <CLI arguments...>
check() {
	name=$1 fixture=$2
	shift 2
	raw=$(set +e; BMCMULTIWAN_SNAPSHOT="$fixtures/$fixture.uci" BMCMULTIWAN_UBUS="$ubus" BMCMULTIWAN_LEFTOVERS="$leftovers" BMCMULTIWAN_HOOK_PROBE="$hook" BMCMULTIWAN_TRACK_DIR="$track_dir" \
		FAKE_IFACE_DIR="$iface_dir" BMCMULTIWAN_HWACCEL_DAEMON="$fixtures/fake-hwaccel-daemon.sh" FAKE_HWACCEL="$hwaccel" BMCMULTIWAN_RUN_DIR="$run_dir" BMCMULTIWAN_NOW="$now" "$shell" "$cli" --dry-run "$@" 2>&1; echo "exit=$?")
	output=$(printf '%s\n' "$raw" | sed '$d')
	status=$(printf '%s\n' "$raw" | tail -n 1)
	actual=$(printf '%s\n%s\n' "$output" "$status" | readable)
	if [ "${UPDATE_GOLDEN:-0}" = 1 ]; then
		printf '%s\n' "$actual" > "$golden/$name.out"
	fi
	if ! printf '%s\n' "$output" | json_valid 2>/dev/null; then
		printf 'FAIL %s: output is not one valid JSON object\n%s\n' "$name" "$output"
		failed=$((failed + 1))
	elif ! printf '%s\n' "$actual" | diff -u "$golden/$name.out" - >/dev/null 2>&1; then
		printf 'FAIL %s\n' "$name"
		printf '%s\n' "$actual" | diff -u "$golden/$name.out" - || true
		failed=$((failed + 1))
	else
		passed=$((passed + 1))
	fi
}

# check_run <golden name> <fixture> <CLI arguments...>: runs the CLI for real, with stand-ins on PATH that record
# how they were called (tests/fixtures/fakebin) and a runtime directory of its own. The golden holds the
# output, the recorded calls and the runtime files.
check_run() {
	name=$1 fixture=$2
	shift 2
	work=$(mktemp -d)
	raw=$(set +e; PATH="$fixtures/fakebin:$PATH" FAKE_CALLS="$work/calls" BMCMULTIWAN_SNAPSHOT="$fixtures/$fixture.uci" \
		BMCMULTIWAN_UBUS="$ubus" BMCMULTIWAN_TRACK_DIR="$track_dir" FAKE_IFACE_DIR="$iface_dir" BMCMULTIWAN_HWACCEL_DAEMON="$fixtures/fake-hwaccel-daemon.sh" FAKE_HWACCEL="$hwaccel" \
		BMCMULTIWAN_RUN_DIR="$work/run" BMCMULTIWAN_NOW="$now" "$shell" "$cli" "$@" 2>&1; echo "exit=$?")
	actual=$({
		printf '%s\n' "$raw"
		echo '--- calls'
		cat "$work/calls" 2>/dev/null
		echo '--- runtime files'
		(cd "$work/run" 2>/dev/null && find . -type f | sort | while read -r file; do printf '%s: %s\n' "$file" "$(cat "$file")"; done)
	} | readable)
	rm -rf "$work"
	if [ "${UPDATE_GOLDEN:-0}" = 1 ]; then
		printf '%s\n' "$actual" > "$golden/$name.out"
	fi
	if ! printf '%s\n' "$raw" | sed '$d' | json_valid 2>/dev/null; then
		printf 'FAIL %s: output is not one valid JSON object\n%s\n' "$name" "$raw"
		failed=$((failed + 1))
	elif ! printf '%s\n' "$actual" | diff -u "$golden/$name.out" - >/dev/null 2>&1; then
		printf 'FAIL %s\n' "$name"
		printf '%s\n' "$actual" | diff -u "$golden/$name.out" - || true
		failed=$((failed + 1))
	else
		passed=$((passed + 1))
	fi
}

# get
check get-fresh fresh get
check get-configured configured get

# defaults (uci-defaults): replace the sample /etc/config/mwan3 of the mwan3 package once; a configuration
# already written by bmcMultiWAN (after a sysupgrade that keeps settings) is never overwritten.
check defaults-fresh fresh defaults
check defaults-configured configured defaults

# set: only saves "enabled"; apply makes it effective.
check set-enable fresh set --enabled 1
check set-disable configured set --enabled 0
check set-err-enabled fresh set --enabled yes
check set-err-enabled-missing fresh set
check set-err-missing-value fresh set --enabled
check set-err-unknown-option fresh set --enabled 1 --bogus 1

# apply: mwan3 runs exactly when Multi-WAN is enabled. A running mwan3 is restarted to load the
# configuration; stopping it removes its ip rules, routing tables, iptables chains and ipsets, also when
# procd no longer runs mwan3 but its state is still in the kernel.
check apply-fresh fresh apply
check apply-enable configured apply
ubus="$fixtures/fake-ubus-down.sh"
check apply-enable-ubus-down configured apply
ubus="$fixtures/fake-ubus-running.sh"
check apply-enable-running configured apply
check apply-disable-running disabled apply
ubus="$fixtures/fake-ubus-stopped.sh"
leftovers="$fixtures/fake-leftovers-hook.sh"
check apply-disable-leftovers disabled apply
leftovers="$fixtures/fake-leftovers-none.sh"

# firewall-apply (firewall include, after every firewall start, reload and restart): `firewall restart` flushes
# every chain of the mangle table, mwan3's too; a running mwan3 whose jumps are gone is restarted. A firewall
# reload keeps them: nothing to do.
check firewall-apply-disabled disabled firewall-apply
check firewall-apply-not-running configured firewall-apply
ubus="$fixtures/fake-ubus-running.sh"
check firewall-apply-hooked configured firewall-apply
hook="$fixtures/fake-hook-missing.sh"
check firewall-apply-unhooked configured firewall-apply
ubus="$fixtures/fake-ubus-stopped.sh"
check firewall-apply-unhooked-not-running configured firewall-apply
hook="$fixtures/fake-hook-present.sh"

# status: link, Internet state and IPv4 address of each enabled IPv4 WAN, the WAN carrying the default Chính sách
# WAN and the last Chuyển WAN. A WAN still counts as online while it fails its first checks (disconnecting) and
# stays Mất Internet ("lost") until it recovers (connecting); the Internet state of a WAN whose link is down is
# "unknown" (its checks are paused). The default Chính sách WAN is carried by its first WAN with link and Internet,
# or by none (null: traffic follows the main routing table).
check status-disabled fresh status
check status-not-running configured status
ubus="$fixtures/fake-ubus-running.sh"
track_dir="$fixtures/track-online"
check status-online configured status
track_dir="$fixtures/track-lost"
check status-lost configured status
track_dir="$fixtures/track-states"
check status-states states status
track_dir="$fixtures/track-two-online"
check status-two-online two-online status
track_dir="$fixtures/track-wan-lost"
run_dir="$fixtures/run-wan-lost"
check status-two-wan-lost two-online status
track_dir="$fixtures/track-two-online"
run_dir="$fixtures/run-none"
iface_dir="$fixtures/ifaces-wan2-down"
check status-two-link-down two-online status
# An interface netifd does not know (ubus "Not found") has no link.
iface_dir="$fixtures/ifaces-none"
check status-two-no-iface two-online status
ubus="$fixtures/fake-ubus-stopped.sh"
track_dir="$fixtures/track-none"
iface_dir="$fixtures/ifaces-up"

# event (hook /etc/mwan3.user, on every hotplug event of a WAN while mwan3 runs): logs each Chuyển WAN to syslog
# with the Chính sách WAN it affects, and records the new state of the WAN and the time of the last Chuyển WAN in
# runtime files. A restart of mwan3 sends "disconnected" for every online WAN whose tracking still says online:
# not a Chuyển WAN. The first "connected" of a WAN (mwan3 start, link up) is only recorded.
ubus="$fixtures/fake-ubus-running.sh"
track_dir="$fixtures/track-wan-lost"
check event-lost rules event disconnected wan
track_dir="$fixtures/track-all-online"
check event-restart rules event disconnected wan
check event-connected-first rules event connected wan
run_dir="$fixtures/run-wan-lost"
check event-connected-again rules event connected wan
run_dir="$fixtures/run-none"
check event-link-down rules event ifdown wan3
run_dir="$fixtures/run-wan3-link-down"
check event-link-down-again rules event ifdown wan3
check event-connected-after-link rules event connected wan3
run_dir="$fixtures/run-none"
# mwan3track answers an ifdown with "disconnected" too, before or after netifd's own ifdown reaches the hook: a
# "disconnected" while the interface is down is the same link loss, logged once.
track_dir="$fixtures/track-wan3-offline"
iface_dir="$fixtures/ifaces-wan3-down"
check event-lost-link-down rules event disconnected wan3
run_dir="$fixtures/run-wan3-link-down"
check event-lost-link-down-again rules event disconnected wan3
run_dir="$fixtures/run-none"
track_dir="$fixtures/track-all-online"
iface_dir="$fixtures/ifaces-up"
check event-ignored rules event disconnecting wan
check event-ifup rules event ifup wan2
check event-err-no-such rules event disconnected lan
check event-err-name rules event disconnected ../wan
check event-usage rules event disconnected
# With Tăng tốc phần cứng running, a WAN that is Mất Internet or lost its link also loses its connections: the
# hardware would keep forwarding them into that WAN (flush.sh). Every connection of the WAN carries its mark of
# mwan3, the position of the WAN in /etc/config/mwan3 spread over mmx_mask. Nothing is removed when a WAN has
# Internet again, when mwan3 only restarts, or for a link loss that was already handled.
hwaccel=running
track_dir="$fixtures/track-wan-lost"
check event-lost-accelerated rules event disconnected wan
track_dir="$fixtures/track-all-online"
check event-restart-accelerated rules event disconnected wan
run_dir="$fixtures/run-wan-lost"
check event-connected-again-accelerated rules event connected wan
run_dir="$fixtures/run-none"
check event-link-down-accelerated rules event ifdown wan3
run_dir="$fixtures/run-wan3-link-down"
check event-link-down-again-accelerated rules event ifdown wan3
run_dir="$fixtures/run-none"
track_dir="$fixtures/track-wan-lost"
check event-lost-accelerated-mask rules-mask event ifdown wan3
check event-lost-accelerated-mask-decimal rules-mask-decimal event disconnected wan
check event-lost-accelerated-mask-text rules-mask-text event disconnected wan
# Not a dry run: what the event runs and logs, with stand-ins for conntrack and logger on PATH (the event
# runs both by name).
check_run event-lost-run rules event disconnected wan
hwaccel=stopped
check_run event-lost-run-cpu rules event disconnected wan
ubus="$fixtures/fake-ubus-stopped.sh"
track_dir="$fixtures/track-none"

# wan list: `wan` first, then the WANs added by bmcmultiwan (bmc_role multiwan), each with its Internet check.
# The PPPoE password is never returned.
check wan-list-one board wan list
check wan-list-three two-wans wan list
# A static `wan` written as ip/prefix (as the WAN page saves it) is listed like the added WANs.
check wan-list-static-cidr wan-static-cidr wan list

# wan add: a new WAN in network (bmc_role multiwan, its own metric), in the firewall zone wan (masquerade),
# checked by mwan3 like `wan` and put last in the default Chính sách WAN. A br-lan port is taken out of br-lan.
check wan-add-dhcp board wan add --name wan2 --port eth1 --proto dhcp
check wan-add-static board wan add --name wan2 --port eth9 --proto static --ipaddr 198.51.100.3 \
	--netmask 255.255.255.0 --gateway 198.51.100.1 --dns 9.9.9.9 --dns 149.112.112.112
check wan-add-pppoe board wan add --name isp_b --port eth2 --proto pppoe --username "b'user" --password 'pa ss'
# The 4th WAN gets the first free metric and goes after the three others in the default Chính sách WAN.
check wan-add-fourth two-wans wan add --name wan4 --port eth3 --proto dhcp
# A running Multi-WAN is restarted to load the new WAN at once.
ubus="$fixtures/fake-ubus-running.sh"
check wan-add-running board wan add --name wan2 --port eth1 --proto dhcp
ubus="$fixtures/fake-ubus-stopped.sh"
check wan-add-err-fifth four-wans wan add --name wan5 --port eth9 --proto dhcp
check wan-add-err-name-missing board wan add --port eth1 --proto dhcp
check wan-add-err-name-used board wan add --name lan --port eth1 --proto dhcp
check wan-add-err-name-mwan3 board wan add --name wan_m1 --port eth1 --proto dhcp
check wan-add-err-name-chars board wan add --name wan-2 --port eth1 --proto dhcp
check wan-add-err-name-upper board wan add --name Wan2 --port eth1 --proto dhcp
check wan-add-err-name-long board wan add --name wan_backup --port eth1 --proto dhcp
check wan-add-err-port-missing board wan add --name wan2 --proto dhcp
check wan-add-err-port-heartbeat board wan add --name wan2 --port eth6 --proto dhcp
check wan-add-err-port-heartbeat-backup board wan add --name wan2 --port eth8 --proto dhcp
check wan-add-err-port-link board wan add --name wan2 --port eth7 --proto dhcp
check wan-add-err-port-extra-lan board wan add --name wan2 --port eth5 --proto dhcp
check wan-add-err-port-wan board wan add --name wan2 --port eth0 --proto dhcp
check wan-add-err-port-added-wan two-wans wan add --name wan4 --port eth1 --proto dhcp
check wan-add-err-port-last-lan lan-one-port wan add --name wan2 --port eth1 --proto dhcp
check wan-add-err-proto board wan add --name wan2 --port eth1 --proto l2tp
check wan-add-err-proto-missing board wan add --name wan2 --port eth1
check wan-add-err-option-proto board wan add --name wan2 --port eth1 --proto dhcp --ipaddr 198.51.100.3
check wan-add-err-pppoe-option board wan add --name wan2 --port eth1 --proto static --username u
check wan-add-err-static-missing board wan add --name wan2 --port eth1 --proto static --ipaddr 198.51.100.3 \
	--netmask 255.255.255.0
check wan-add-err-static-ip board wan add --name wan2 --port eth1 --proto static --ipaddr 198.51.100.300 \
	--netmask 255.255.255.0 --gateway 198.51.100.1
check wan-add-err-static-netmask board wan add --name wan2 --port eth1 --proto static --ipaddr 198.51.100.3 \
	--netmask 255.0.255.0 --gateway 198.51.100.1
check wan-add-err-static-gateway board wan add --name wan2 --port eth1 --proto static --ipaddr 198.51.100.3 \
	--netmask 255.255.255.0 --gateway 198.51.101.1
check wan-add-err-static-overlap board wan add --name wan2 --port eth1 --proto static --ipaddr 192.168.1.200 \
	--netmask 255.255.255.0 --gateway 192.168.1.254
check wan-add-err-static-dns board wan add --name wan2 --port eth1 --proto static --ipaddr 198.51.100.3 \
	--netmask 255.255.255.0 --gateway 198.51.100.1 --dns dns.example
check wan-add-err-static-dns-spaces board wan add --name wan2 --port eth1 --proto static --ipaddr 198.51.100.3 \
	--netmask 255.255.255.0 --gateway 198.51.100.1 --dns '9.9.9.9 1.1.1.1'
check wan-add-err-pppoe-password board wan add --name wan2 --port eth1 --proto pppoe --username u
check wan-add-err-missing-value board wan add --name wan2 --port
check wan-add-err-unknown-option board wan add --name wan2 --port eth1 --proto dhcp --vlan 10

# wan set: ping targets (1-4 IPv4) and the Mất Internet / Internet again thresholds (1-10 rounds) of one WAN;
# the check interval stays 5 s.
check wan-set-track two-wans wan set --name wan2 --track-ip 9.9.9.9 --track-ip 149.112.112.112 --down 5 --up 2
check wan-set-original board wan set --name wan --down 4
ubus="$fixtures/fake-ubus-running.sh"
check wan-set-running board wan set --name wan --track-ip 9.9.9.9
ubus="$fixtures/fake-ubus-stopped.sh"
check wan-set-err-no-such board wan set --name wan2 --down 4
check wan-set-err-nothing board wan set --name wan
check wan-set-err-track-count board wan set --name wan --track-ip 1.1.1.1 --track-ip 8.8.8.8 --track-ip 9.9.9.9 \
	--track-ip 1.0.0.1 --track-ip 8.8.4.4
check wan-set-err-track-ip board wan set --name wan --track-ip one.one
check wan-set-err-track-spaces board wan set --name wan --track-ip '1.1.1.1 8.8.8.8 9.9.9.9 1.0.0.1 8.8.4.4'
check wan-set-err-track-glob board wan set --name wan --track-ip '*'
check wan-set-err-track-twice board wan set --name wan --track-ip 1.1.1.1 --track-ip 1.1.1.1
check wan-set-err-down board wan set --name wan --down 0
check wan-set-err-up board wan set --name wan --up 11
check wan-set-err-up-text board wan set --name wan --up fast

# wan del: never `wan`; the WAN leaves every Chính sách WAN (refused if one would be left empty), its
# interface, zone membership and mwan3 configuration go, and a port taken from br-lan goes back to br-lan.
check wan-del-lan-port two-wans wan del --name wan2
check wan-del-free-port two-wans wan del --name wan3
ubus="$fixtures/fake-ubus-running.sh"
check wan-del-running two-wans wan del --name wan3
ubus="$fixtures/fake-ubus-stopped.sh"
check wan-del-err-original two-wans wan del --name wan
check wan-del-err-no-such two-wans wan del --name lan
check wan-del-err-empty-policy four-wans wan del --name wan2
check wan-del-err-name-missing two-wans wan del

check wan-usage board wan

# policy list: every Chính sách WAN with its WANs in order of preference and the Luật chọn WAN that use it;
# the default one first. Members of mwan3 never show.
check policy-list-one board policy list
check policy-list rules policy list

# policy set: creates or replaces a Chính sách WAN from 1-4 WANs in order of preference. The member of the WAN at
# position K is "<wan>_m<K>": created when missing, deleted once no Chính sách WAN uses it.
check policy-set-new two-wans policy set --name isp_b --wan wan2 --wan wan
check policy-set-new-members two-wans policy set --name c_first --wan wan3 --wan wan2 --wan wan
check policy-set-replace rules policy set --name b_first --wan wan2 --wan wan3
check policy-set-default two-wans policy set --name default_policy --wan wan2 --wan wan
ubus="$fixtures/fake-ubus-running.sh"
check policy-set-running two-wans policy set --name isp_b --wan wan2 --wan wan
ubus="$fixtures/fake-ubus-stopped.sh"
check policy-set-err-name-missing two-wans policy set --wan wan
check policy-set-err-name-chars two-wans policy set --name isp-b --wan wan
check policy-set-err-name-long two-wans policy set --name isp_b_then_isp_a --wan wan
check policy-set-err-name-reserved two-wans policy set --name default --wan wan
check policy-set-err-name-member two-wans policy set --name isp_m1 --wan wan
check policy-set-err-name-wan two-wans policy set --name wan2 --wan wan
check policy-set-err-name-rule rules policy set --name acct --wan wan
check policy-set-err-wan-missing two-wans policy set --name isp_b
check policy-set-err-wan-no-such two-wans policy set --name isp_b --wan wan2 --wan lan
check policy-set-err-wan-twice two-wans policy set --name isp_b --wan wan2 --wan wan --wan wan2
check policy-set-err-wan-count four-wans policy set --name all --wan wan --wan wan2 --wan wan3 --wan wan4 --wan wan
check policy-set-err-missing-value two-wans policy set --name isp_b --wan
check policy-set-err-unknown-option two-wans policy set --name isp_b --wan wan --weight 2

# policy del: never the default Chính sách WAN nor one a Luật chọn WAN still uses; its members no other
# Chính sách WAN uses go with it.
check policy-del rules policy del --name c_only
check policy-del-err-default rules policy del --name default_policy
check policy-del-err-used rules policy del --name b_first
check policy-del-err-no-such rules policy del --name wan2
check policy-del-err-name-missing rules policy del
check policy-usage board policy

# rule list: Luật chọn WAN in the order they are evaluated (first match wins), the default rule last.
check rule-list-default board rule list
check rule-list rules rule list

# rule set: creates or replaces a Luật chọn WAN. A new rule goes last before the default rule, or at --position;
# a replaced rule keeps its position unless --position moves it. /etc/config/mwan3 keeps the rules in that
# order (mwan3 evaluates them in file order) with the default rule last. Ports are stored as iptables
# multiport wants them (a:b).
check rule-set-acct two-wans rule set --name acct --policy b_first --src-ip 192.168.10.0/24
check rule-set-voip two-wans rule set --name voip --policy b_first --proto udp --dest-port 5060
check rule-set-position rules rule set --name web --policy c_only --proto tcp --dest-port 80,443 --position 1
check rule-set-move rules rule set --name rtp --policy b_first --proto udp --dest-port 5062,10000-20000 \
	--position 2
check rule-set-replace rules rule set --name acct --policy c_only --src-ip 192.168.10.0/24 --dest-ip 198.51.100.7
check rule-set-ports rules rule set --name tcp_all --policy c_only --proto tcp --src-port 1024-65535 \
	--dest-port 22,80,443,8000-8080
ubus="$fixtures/fake-ubus-running.sh"
check rule-set-running rules rule set --name voip --policy b_first --proto udp --dest-port 5060 --position 3
ubus="$fixtures/fake-ubus-stopped.sh"
check rule-set-err-name-missing rules rule set --policy b_first
check rule-set-err-name-default rules rule set --name default_rule --policy b_first
check rule-set-err-name-chars rules rule set --name 'voip.1' --policy b_first
check rule-set-err-name-long rules rule set --name accounting_rules --policy b_first
check rule-set-err-name-policy rules rule set --name c_only --policy b_first
check rule-set-err-policy-missing rules rule set --name acct --src-ip 192.168.10.0/24
check rule-set-err-policy-no-such rules rule set --name acct --policy wan2
check rule-set-err-src-ip rules rule set --name acct --policy b_first --src-ip 192.168.10.0/33
check rule-set-err-src-ip-host-bits rules rule set --name acct --policy b_first --src-ip 192.168.10.5/24
check rule-set-err-src-ip-zero rules rule set --name acct --policy b_first --src-ip 192.168.10.0/024
check rule-set-err-dest-ip rules rule set --name acct --policy b_first --dest-ip example.com
check rule-set-err-proto rules rule set --name acct --policy b_first --proto gre
check rule-set-err-port-icmp rules rule set --name ping --policy b_first --proto icmp --dest-port 7
check rule-set-err-port-all rules rule set --name dns --policy b_first --src-port 53
check rule-set-err-port-zero rules rule set --name voip --policy b_first --proto udp --dest-port 0
check rule-set-err-port-big rules rule set --name voip --policy b_first --proto udp --dest-port 65536
check rule-set-err-port-range rules rule set --name voip --policy b_first --proto udp --dest-port 5070-5060
check rule-set-err-port-text rules rule set --name voip --policy b_first --proto udp --src-port sip
check rule-set-err-port-leading-zero rules rule set --name web --policy b_first --proto tcp --dest-port 443,080
check rule-set-err-port-colon rules rule set --name voip --policy b_first --proto udp --dest-port 5060:5070
check rule-set-err-port-count rules rule set --name voip --policy b_first --proto udp \
	--dest-port 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15-16
check rule-set-err-position-zero rules rule set --name web --policy b_first --position 0
check rule-set-err-position-new rules rule set --name web --policy b_first --position 5
check rule-set-err-position-existing rules rule set --name acct --policy b_first --position 4
check rule-set-err-position-text rules rule set --name acct --policy b_first --position last
check rule-set-err-missing-value rules rule set --name acct --policy
check rule-set-err-unknown-option rules rule set --name acct --policy b_first --sticky 1

# rule del: never the default rule.
check rule-del rules rule del --name voip
check rule-del-err-default rules rule del --name default_rule
check rule-del-err-no-such rules rule del --name b_first
check rule-del-err-name-missing rules rule del
check rule-usage board rule

check usage fresh
check bogus fresh bogus

printf '%s passed, %s failed (%s)\n' "$passed" "$failed" "$shell"
[ "$failed" -eq 0 ]
