#!/bin/sh
# Test của CLI bmcdynrouting: chạy CLI thật ở chế độ --dry-run trên một snapshot `uci -X show`
# và so TOÀN BỘ output với golden file. Không cần uci, FRR hay thiết bị.
#
#   sh tests/run.sh                    chạy test
#   UPDATE_GOLDEN=1 sh tests/run.sh    ghi lại golden (xem kỹ git diff trước khi commit)
#   TEST_SHELL=dash sh tests/run.sh    chạy CLI bằng shell khác (gần ash của busybox hơn)
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cli="$root/src/usr/sbin/bmcdynrouting"
fixtures="$root/tests/fixtures"
golden="$root/tests/golden"
shell=${TEST_SHELL:-sh}
vtysh="$fixtures/fake-vtysh.sh"
addresses=
# Thư mục FRR đang dùng; mặc định không tồn tại, như lần apply đầu tiên.
frr_dir="$fixtures/frr-none"
passed=0
failed=0

# Golden lưu output với "\n" trong chuỗi JSON bung thành xuống dòng, để diff đọc được.
readable() {
	awk '{ gsub(/\\n/, "\n"); print }'
}

json_valid() {
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import json, sys; json.loads(sys.stdin.read())'
	fi
}

# check <tên golden> <fixture> <tham số CLI...>
check() {
	name=$1 fixture=$2
	shift 2
	raw=$(set +e; BMCDYNROUTING_SNAPSHOT="$fixtures/$fixture.uci" BMCDYNROUTING_VTYSH="$vtysh" BMCDYNROUTING_ADDRESSES="$addresses" BMCDYNROUTING_FRR_DIR="$frr_dir" "$shell" "$cli" --dry-run "$@" 2>&1; echo "exit=$?")
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

# apply: cấu hình FRR, daemons và rule firewall sinh từ UCI (kịch bản 3 router).
check apply-r1 r1 apply
check apply-r2 r2 apply
check apply-r3 r3 apply
check apply-r1-advanced r1-advanced apply
check apply-disabled disabled apply
check apply-bad-router-id bad-router-id apply
check apply-no-router-id no-router-id apply
# Restart theo daemon: chỉ daemon có phần cấu hình khác file đang dùng mới restart; phần zebra
# (header, Router ID) hoặc daemons khác, hay file không có marker (phase 1, "vtysh write memory")
# thì restart toàn bộ.
frr_dir="$fixtures/frr-r1-current"
check apply-r1-unchanged r1 apply
frr_dir="$fixtures/frr-r1-ospf-changed"
check apply-r1-ospf-changed r1 apply
frr_dir="$fixtures/frr-r1-router-id-changed"
check apply-r1-router-id-changed r1 apply
frr_dir="$fixtures/frr-r1-daemons-changed"
check apply-r1-daemons-changed r1 apply
frr_dir="$fixtures/frr-r1-phase1"
check apply-r1-phase1 r1 apply
# R3 chạy cả OSPF và RIP: đổi riêng phần RIP chỉ restart ripd; bật RIP (daemons đổi) thì restart toàn bộ.
frr_dir="$fixtures/frr-r3-rip-current"
check apply-r3-rip-unchanged r3-rip apply
frr_dir="$fixtures/frr-r3-rip-changed"
check apply-r3-rip-changed r3-rip apply
frr_dir="$fixtures/frr-r3-rip-advanced-changed"
check apply-r3-rip-advanced-changed r3-rip apply
frr_dir="$fixtures/frr-r3-ospf-only"
check apply-r3-rip-enabling r3-rip apply
# R1 chạy OSPF và BGP: đổi riêng phần BGP (hay Dòng lệnh nâng cao BGP) chỉ restart bgpd, đổi riêng OSPF không
# đụng bgpd; bật BGP (daemons đổi) hay tắt BGP thì restart toàn bộ.
frr_dir="$fixtures/frr-r1-bgp-current"
check apply-r1-bgp-unchanged r1-bgp apply
check apply-r1-bgp-disabling r1-bgp-disabled apply
frr_dir="$fixtures/frr-r1-bgp-changed"
check apply-r1-bgp-changed r1-bgp apply
frr_dir="$fixtures/frr-r1-bgp-advanced-changed"
check apply-r1-bgp-advanced-changed r1-bgp apply
frr_dir="$fixtures/frr-r1-bgp-ospf-changed"
check apply-r1-bgp-ospf-changed r1-bgp apply
frr_dir="$fixtures/frr-r1-current"
check apply-r1-bgp-enabling r1-bgp apply
frr_dir="$fixtures/frr-none"

# RIP: Interface RIP (kể cả passive) có rule UDP 520; RIP tắt thì không còn phần ripd, rule hay
# Dòng lệnh nâng cao của nó. RIP không cần Router ID.
check apply-r3-rip r3-rip apply
check apply-r3-rip-disabled r3-rip-disabled apply
check apply-rip-only rip-only apply
check apply-rip-bad-timer r3-rip-bad-timer apply
check apply-rip-bad-passive r3-rip-bad-passive apply

# BGP: R1↔ISP-A (nhận tất cả, MD5), R2↔ISP-B (chỉ default route, timer, giới hạn prefix), peer shutdown không
# có rule TCP 179. Policy không transit, Dòng lệnh nâng cao nối sau policy, chỉ khi BGP bật.
check apply-r1-bgp r1-bgp apply
check apply-r2-bgp r2-bgp apply
check apply-r1-bgp-disabled r1-bgp-disabled apply
check apply-bgp-no-router-id bgp-no-router-id apply
check apply-bgp-same-as bgp-same-as apply
check apply-bgp-missing-as bgp-missing-as apply
check apply-bgp-missing-local-as bgp-missing-local-as apply
check apply-bgp-bad-network bgp-bad-network apply

# Cross redistribution (ADR-0008): BGP routes enter OSPF/RIP through a route-map that sets a fixed tag, and
# OSPF/RIP routes enter BGP through a route-map that denies that tag. R1 BGP->OSPF, R2 OSPF->BGP (another BMC
# router of the same OSPF domain), R3 RIP->OSPF, OSPF->RIP with default originate, and BGP->RIP.
check apply-r1-bgp-redistribute r1-bgp-redistribute apply
check apply-r2-bgp-redistribute r2-bgp-redistribute apply
check apply-r3-rip-redistribute r3-rip-redistribute apply
# The tag route-maps belong to the part of the daemon that uses them: only ospfd and bgpd restart.
frr_dir="$fixtures/frr-r1-bgp-current"
check apply-r1-bgp-redistribute-changed r1-bgp-redistribute apply
frr_dir="$fixtures/frr-none"

# Router ID
check router-id-get r1 router-id get
check router-id-get-fresh fresh router-id get
check router-id-set fresh router-id set --router-id 4.4.4.4
check router-id-set-creates-global device-bmc router-id set --router-id 4.4.4.4
check router-id-set-clear-disabled disabled router-id set --router-id ''
check router-id-set-err-invalid r1 router-id set --router-id 1.1.1
check router-id-set-err-clear-enabled r1 router-id set --router-id ''
check router-id-set-err-clear-bgp bgp-no-router-id router-id set --router-id ''
check router-id-set-err-missing r1 router-id set
check router-id-set-err-unknown-option r1 router-id set --bogus 1

# Nâng cấp từ phase 1 (uci-defaults gọi "migrate"); chạy lại trên cấu hình đã chuyển không đổi gì.
check migrate-phase1 phase1-r1 migrate
check migrate-phase1-device device-bmc migrate
check migrate-partial migrate-partial migrate
check migrate-done r1 migrate
check migrate-done-fresh fresh migrate

# ospf get
check get-r1-advanced r1-advanced ospf get
check get-fresh fresh ospf get
check get-warnings warnings ospf get
check get-redistribute r1-bgp-redistribute ospf get

# ospf set: ghi đè toàn bộ Cấu hình OSPF
check set-full r1 ospf set --enabled 1 --redistribute-static 1 --redistribute-connected 0 \
	--interface lan --passive 1 \
	--interface link_eth6 --cost 10 --hello-interval 2 --dead-interval 8 --network-type broadcast \
	--interface guest --area 1 --passive 1 \
	--advanced-line 'router ospf' --advanced-line " ip ospf message-digest-key 1 md5 it's\\secret"
check set-remove-all r1-advanced ospf set --enabled 1
check set-disable-only r1 ospf set --enabled 0
check set-disabled-full fresh ospf set --enabled 0 --interface lan
check set-warnings warnings ospf set --enabled 1 --interface wan --interface guest --passive 1
check set-redistribute r1 ospf set --enabled 1 --redistribute-rip 1 --redistribute-bgp 1 --interface lan
check set-err-redistribute-bgp r1 ospf set --enabled 1 --redistribute-bgp yes
check set-err-enabled-missing r1 ospf set --redistribute-static 1
check set-err-router-id-missing no-router-id ospf set --enabled 1
check set-err-router-id-invalid bad-router-id ospf set --enabled 1
check set-err-router-id-option r1 ospf set --enabled 1 --router-id 1.1.1.1
check set-disabled-no-router-id no-router-id ospf set --enabled 0 --interface lan
check set-err-unknown-interface r1 ospf set --enabled 1 --interface nope
check set-err-duplicate r1 ospf set --enabled 1 --interface lan --interface lan
check set-err-area r1 ospf set --enabled 1 --interface lan --area 4294967296
check set-err-cost r1 ospf set --enabled 1 --interface lan --cost 0
check set-err-dead r1 ospf set --enabled 1 --interface lan --hello-interval 8 --dead-interval 8
check set-err-dead-below-default-hello r1 ospf set --enabled 1 --interface lan --dead-interval 5
check set-err-hello-above-default-dead r1 ospf set --enabled 1 --interface lan --hello-interval 50
check set-err-network-type r1 ospf set --enabled 1 --interface lan --network-type nbma
check set-err-passive r1 ospf set --enabled 1 --interface lan --passive yes
check set-err-orphan-option r1 ospf set --enabled 1 --cost 5
check set-err-advanced-control r1 ospf set --enabled 1 --advanced-line "$(printf 'a\tb')"
check set-err-missing-value r1 ospf set --enabled
check set-err-unknown-option r1 ospf set --enabled 1 --bogus 1

# rip get / set: ghi đè toàn bộ Cấu hình RIP
check rip-get r3-rip rip get
check rip-get-fresh fresh rip get
check rip-get-phase1 phase1-r1 rip get
check rip-get-redistribute r3-rip-redistribute rip get
check rip-set-full r3-rip rip set --enabled 1 --redistribute-static 1 --redistribute-connected 1 \
	--redistribute-ospf 0 --default-originate 0 --garbage-timer 90 \
	--interface link_eth5 --interface lan --passive 1 \
	--advanced-line 'router rip' --advanced-line ' neighbor 192.168.50.254'
check rip-set-first fresh rip set --enabled 1 --interface lan --passive 1 --interface guest --update-timer 5
check rip-set-remove-all r3-rip rip set --enabled 1
check rip-set-disable-only r3-rip rip set --enabled 0
check rip-set-disable-only-phase1 device-bmc rip set --enabled 0
check rip-set-disabled-full fresh rip set --enabled 0 --interface lan
check rip-set-warnings warnings rip set --enabled 1 --interface wan --interface lan
check rip-set-redistribute-bgp r3-rip rip set --enabled 1 --redistribute-bgp 1 --interface lan
check rip-set-err-redistribute-bgp r3-rip rip set --enabled 1 --redistribute-bgp 2
check rip-set-err-enabled-missing r3-rip rip set --interface lan
check rip-set-err-enabled r3-rip rip set --enabled yes
check rip-set-err-unknown-interface r3-rip rip set --enabled 1 --interface nope
check rip-set-err-duplicate r3-rip rip set --enabled 1 --interface lan --interface lan
check rip-set-err-passive r3-rip rip set --enabled 1 --interface lan --passive 2
check rip-set-err-orphan-passive r3-rip rip set --enabled 1 --passive 1
check rip-set-err-timer-low r3-rip rip set --enabled 1 --update-timer 4
check rip-set-err-timer-high r3-rip rip set --enabled 1 --timeout-timer 32768
check rip-set-timer-max r3-rip rip set --enabled 1 --interface link_eth5 --timeout-timer 32767
check rip-set-err-timer-text r3-rip rip set --enabled 1 --garbage-timer 1m
check rip-set-err-redistribute r3-rip rip set --enabled 1 --redistribute-ospf 2
check rip-set-err-default-originate r3-rip rip set --enabled 1 --default-originate on
check rip-set-err-advanced-control r3-rip rip set --enabled 1 --advanced-line "$(printf 'a\tb')"
check rip-set-err-missing-value r3-rip rip set --enabled 1 --update-timer
check rip-set-err-unknown-option r3-rip rip set --enabled 1 --area 0
check rip-bogus r3-rip rip bogus

# bgp get / set: ghi đè toàn bộ Cấu hình BGP; get không bao giờ trả mật khẩu.
check bgp-get r1-bgp bgp get
check bgp-get-fresh fresh bgp get
check bgp-get-phase1 phase1-r1 bgp get
check bgp-get-redistribute r2-bgp-redistribute bgp get
# IP peer ngoài mọi subnet UCI; WAN của R2 lấy địa chỉ qua DHCP nên chỉ thấy lúc chạy.
check bgp-get-not-connected r2-bgp bgp get
addresses="$fixtures/r2-bgp.addr"
check bgp-get-runtime-address r2-bgp bgp get
addresses=
check bgp-set-full r1-bgp bgp set --enabled 1 --local-as 65001 --network 192.168.1.0/24 --network 172.16.0.0/22 \
	--peer 203.0.113.1 --remote-as 64500 --description "ISP-A 'main' \\ uplink" --keep-password --receive default \
	--max-prefix 50 \
	--peer 203.0.113.2 --remote-as 64510 --password "n3w'pa\\ss" --peer-enabled 0 --keepalive 5 --hold 15 \
	--advanced-line 'route-map BMC-BGP-OUT permit 20'
check bgp-set-first fresh bgp set --enabled 0 --local-as 65001 --peer 203.0.113.1 --remote-as 64500
check bgp-set-drop-password r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as 64500
check bgp-set-keep-password-new-peer r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.9 --remote-as 64500 --keep-password
check bgp-set-remove-all r1-bgp bgp set --enabled 1 --local-as 65001
check bgp-set-disable-only r1-bgp bgp set --enabled 0
check bgp-set-disable-only-phase1 device-bmc bgp set --enabled 0
check bgp-set-disabled-no-local-as r1-bgp bgp set --enabled 0 --network 10.0.0.0/8
check bgp-set-warnings r1-bgp bgp set --enabled 1 --local-as 65001 --peer 192.0.2.9 --remote-as 64500 --peer 203.0.113.1 --remote-as 64501
check bgp-set-redistribute r1-bgp bgp set --enabled 1 --local-as 65001 --redistribute-static 1 \
	--redistribute-connected 1 --redistribute-ospf 1 --redistribute-rip 1
check bgp-set-err-redistribute r1-bgp bgp set --enabled 1 --local-as 65001 --redistribute-ospf 2
check bgp-set-err-router-id-missing bgp-no-router-id bgp set --enabled 1 --local-as 65001
check bgp-set-err-enabled-missing r1-bgp bgp set --local-as 65001
check bgp-set-err-enabled r1-bgp bgp set --enabled yes
check bgp-set-err-local-as-missing r1-bgp bgp set --enabled 1
check bgp-set-err-local-as-zero r1-bgp bgp set --enabled 1 --local-as 0
check bgp-set-err-local-as-high r1-bgp bgp set --enabled 1 --local-as 4294967296
check bgp-set-local-as-max r1-bgp bgp set --enabled 1 --local-as 4294967295
check bgp-set-err-network-host-bits r1-bgp bgp set --enabled 1 --local-as 65001 --network 192.168.1.1/24
check bgp-set-err-network-no-length r1-bgp bgp set --enabled 1 --local-as 65001 --network 192.168.1.0
check bgp-set-err-network-length r1-bgp bgp set --enabled 1 --local-as 65001 --network 10.0.0.0/33
check bgp-set-err-network-duplicate r1-bgp bgp set --enabled 1 --local-as 65001 --network 10.0.0.0/8 --network 10.0.0.0/8
check bgp-set-err-peer-address r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.256 --remote-as 64500
check bgp-set-err-peer-duplicate r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as 64500 --peer 203.0.113.1 --remote-as 64501
check bgp-set-err-remote-as-missing r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --description ISP-A
check bgp-set-err-remote-as-invalid r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as AS64500
# AS trùng (iBGP) bị từ chối, kể cả khi --local-as đứng sau peer.
check bgp-set-err-same-as r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as 65001
check bgp-set-err-same-as-late r1-bgp bgp set --enabled 1 --peer 203.0.113.1 --remote-as 64500 --peer 198.51.100.1 --remote-as 64501 --local-as 64501
check bgp-set-err-peer-enabled r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as 64500 --peer-enabled no
check bgp-set-err-receive r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as 64500 --receive none
check bgp-set-err-max-prefix r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as 64500 --max-prefix 0
check bgp-set-err-keepalive r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as 64500 --keepalive 65536
check bgp-set-err-hold-low r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as 64500 --hold 2
# Timer theo FRR: hold 0 tắt keepalive; keepalive lớn hơn hold vẫn hợp lệ (FRR dùng hold/3).
check bgp-set-timers-zero r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as 64500 --keepalive 0 --hold 0
check bgp-set-timers-keepalive-above-hold r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as 64500 --hold 50
check bgp-set-err-password-space r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as 64500 --password 'a b'
check bgp-set-err-password-long r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as 64500 --password "$(printf '%081d' 0)"
check bgp-set-err-password-and-keep r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as 64500 --password x --keep-password
check bgp-set-err-description r1-bgp bgp set --enabled 1 --local-as 65001 --peer 203.0.113.1 --remote-as 64500 --description "$(printf 'a\tb')"
check bgp-set-err-orphan-peer-option r1-bgp bgp set --enabled 1 --local-as 65001 --remote-as 64500
check bgp-set-err-orphan-keep-password r1-bgp bgp set --enabled 1 --local-as 65001 --keep-password
check bgp-set-err-advanced-control r1-bgp bgp set --enabled 1 --local-as 65001 --advanced-line "$(printf 'a\tb')"
check bgp-set-err-missing-value r1-bgp bgp set --enabled 1 --local-as
check bgp-set-err-unknown-option r1-bgp bgp set --enabled 1 --interface lan
check bgp-bogus r1-bgp bgp bogus

# interface list
check interface-list one-link interface list

# Link định tuyến
check link-add-first fresh link add eth6 10.0.12.1/30
check link-add-second one-link link add eth6 10.0.12.1/30
check link-add-err-vlan fresh link add eth1.100 10.0.100.1/30
check link-add-err-wan fresh link add eth0 10.0.12.1/30
check link-add-err-extra-lan fresh link add eth5 10.0.12.1/30
check link-add-err-already-link one-link link add eth7 10.0.16.1/30
check link-add-err-missing-port fresh link add eth9 10.0.12.1/30
check link-add-err-bad-cidr fresh link add eth6 10.0.12.1
check link-add-err-overlap-lan fresh link add eth6 192.168.5.5/30
check link-add-err-overlap-cidr-ipaddr fresh link add eth6 192.168.6.9/30
check link-add-err-overlap-link one-link link add eth6 10.0.13.2/30
# Địa chỉ WAN lấy qua DHCP không có trong UCI, chỉ thấy lúc chạy.
addresses="$fixtures/fresh.addr"
check link-add-err-overlap-runtime fresh link add eth6 10.0.12.1/30
addresses=
check link-del-keeps-zone two-links link del eth7
check link-del-last-removes-zone one-link link del eth7
check link-del-err-ospf r1 link del eth7
check link-del-err-rip rip-only link del eth5
check link-del-err-not-link fresh link del eth6
check link-list two-links link list
check link-available-ports-fresh fresh link available-ports
check link-available-ports-one-link one-link link available-ports

# hotplug
check hotplug-ospf-interface r1 hotplug link_eth6
check hotplug-other-interface r1 hotplug wan
check hotplug-disabled disabled hotplug link_eth6
check hotplug-rip-interface rip-only hotplug link_eth5
check hotplug-rip-disabled r3-rip-disabled hotplug link_eth5

# status
check status-neighbors r1 status ospf neighbors
check status-routes r1 status ospf routes
check status-database r1 status ospf database
check status-interfaces r1 status ospf interfaces
check status-disabled disabled status ospf neighbors
check status-bogus r1 status ospf bogus
check status-no-protocol r1 status
check status-old-command r1 status neighbors
check status-rip-routes r3-rip status rip routes
check status-rip-interfaces r3-rip status rip interfaces
check status-rip-disabled r3-rip-disabled status rip routes
check status-rip-bogus r3-rip status rip neighbors
check status-bgp-peers r1-bgp status bgp peers
check status-bgp-routes r1-bgp status bgp routes
check status-bgp-disabled r1-bgp-disabled status bgp peers
check status-bgp-bogus r1-bgp status bgp neighbors
vtysh="$fixtures/fake-vtysh-not-running.sh"
check status-not-running r1 status ospf neighbors
check status-rip-not-running r3-rip status rip interfaces
check status-bgp-not-running r1-bgp status bgp peers
vtysh="$fixtures/fake-vtysh-garbage.sh"
check status-garbage r1 status ospf neighbors
check status-rip-garbage r3-rip status rip routes
check status-bgp-garbage r1-bgp status bgp routes

# Snapshot chụp từ board thật (uci -X show, bốn config mà CLI đọc), giữ nguyên văn.
check device-ospf-get device-bmc ospf get
check device-interface-list device-bmc interface list
check device-available-ports device-bmc link available-ports
check device-link-add device-bmc link add eth6 10.0.12.1/30
check device-link-add-overlap device-bmc link add eth6 192.168.5.9/30
# Board phase 1 chưa có Router ID: lưu Cấu hình OSPF khi còn tắt vẫn được, kèm cảnh báo.
check device-set-wan-warnings device-bmc ospf set --enabled 0 --interface lan --passive 1 --interface wan
check device-set-err-no-router-id device-bmc ospf set --enabled 1 --interface lan --passive 1
check device-router-id-get device-bmc router-id get

check usage fresh

printf '%s passed, %s failed (%s)\n' "$passed" "$failed" "$shell"
[ "$failed" -eq 0 ]
