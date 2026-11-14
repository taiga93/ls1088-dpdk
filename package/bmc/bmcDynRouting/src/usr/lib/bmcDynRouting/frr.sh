# Cấu hình FRR tích hợp (frr.conf, daemons) sinh từ UCI, rule firewall, và việc áp chúng lên router (ADR-0001).
#
# frr.conf chia thành phần theo daemon bằng dòng chú thích "! bmcDynRouting: <daemon>"; các dòng trước marker
# đầu tiên (header, Router ID) là phần zebra. apply so từng phần với file đang dùng và chỉ restart daemon có
# phần đổi: frrcommon.sh khởi động một daemon rồi chạy "vtysh -b -d <daemon>", nên daemon đó nạp đúng phần của
# nó trong frr.conf tích hợp. Phần zebra hoặc file daemons đổi thì restart toàn bộ FRR. File không có marker
# (của phase 1, hay do "vtysh write memory" ghi) chỉ có phần zebra, nên cũng dẫn tới restart toàn bộ.

# Nơi FRR đọc cấu hình; test trỏ sang thư mục fixture.
frr_dir=${BMCDYNROUTING_FRR_DIR:-/etc/frr}
frr_part_marker='! bmcDynRouting:'

# Tag của rule iptables do feature này thêm, để gỡ đúng các rule đó khi đồng bộ.
rule_tag=bmcDynRouting

# Daemon của các giao thức đang bật, mỗi dòng một daemon, theo thứ tự trong frr.conf.
frr_enabled_daemons() {
	if [ "$ospf_enabled" = 1 ]; then echo ospfd; fi
	if [ "$rip_enabled" = 1 ]; then echo ripd; fi
	if [ "$bgp_enabled" = 1 ]; then echo bgpd; fi
}

frr_config() {
	printf 'frr version 10\nfrr defaults traditional\nhostname bmcDynRouting\nservice integrated-vtysh-config\n!\n'
	if [ -n "$router_id" ]; then printf 'router-id %s\n!\n' "$router_id"; fi
	if [ "$ospf_enabled" = 1 ]; then
		printf '%s ospfd\n' "$frr_part_marker"
		ospf_frr_config
	fi
	if [ "$rip_enabled" = 1 ]; then
		printf '%s ripd\n' "$frr_part_marker"
		rip_frr_config
	fi
	if [ "$bgp_enabled" = 1 ]; then
		printf '%s bgpd\n' "$frr_part_marker"
		bgp_frr_config
	fi
	# Dòng lệnh nâng cao nằm ở cuối file (OSPF, RIP rồi BGP), nên được tự mở lại "router ospf", "router rip",
	# "interface ..." hay route-map của policy BGP; chúng thuộc phần của daemon giao thức đó, và chỉ có khi
	# giao thức bật.
	frr_advanced_part ospf ospfd "$ospf_enabled"
	frr_advanced_part rip ripd "$rip_enabled"
	frr_advanced_part bgp bgpd "$bgp_enabled"
}

# Dòng lệnh nâng cao của giao thức $1 (daemon $2) khi nó bật ($3 = 1).
frr_advanced_part() {
	if [ "$3" = 1 ] && [ -n "$(advanced_config "$1")" ]; then
		printf '%s %s\n' "$frr_part_marker" "$2"
		advanced_config "$1"
	fi
}

daemons_config() {
	enabled_daemons=$(frr_enabled_daemons)
	printf 'zebra=yes\n'
	for daemon in ospfd ripd bgpd; do
		case " $(printf '%s' "$enabled_daemons" | tr '\n' ' ') " in
			*" $daemon "*) printf '%s=yes\n' "$daemon" ;;
			*) printf '%s=no\n' "$daemon" ;;
		esac
	done
	printf 'ospf6d=no\nwatchfrr=yes\n'
}

# Phần của daemon $1 trong cấu hình FRR đọc từ stdin.
frr_part() {
	awk -v daemon="$1" '$1 == "!" && $2 == "bmcDynRouting:" { part = $3; next } (part == "" ? "zebra" : part) == daemon'
}

frr_part_changed() {
	[ "$(printf '%s\n' "$new_frr_conf" | frr_part "$1")" != "$(printf '%s\n' "$current_frr_conf" | frr_part "$1")" ]
}

# Các daemon cần restart để FRR chạy đúng cấu hình sinh ra, mỗi dòng một daemon; có zebra (đứng đầu) nghĩa là
# restart toàn bộ FRR. Chỉ so với file đang dùng, không xét daemon nào đang chạy.
frr_restart_plan() {
	new_frr_conf=$(frr_config)
	current_frr_conf=$(cat "$frr_dir/frr.conf" 2>/dev/null || true)
	if [ "$(daemons_config)" != "$(cat "$frr_dir/daemons" 2>/dev/null || true)" ] || frr_part_changed zebra; then
		echo zebra
		frr_enabled_daemons
		return 0
	fi
	for daemon in $(frr_enabled_daemons); do
		if frr_part_changed "$daemon"; then echo "$daemon"; fi
	done
}

# Lỗi của cấu hình đang lưu (có thể đã bị sửa tay) dạng "field message" ("field/IP message" với lỗi của một
# Peer BGP), hoặc không in gì.
stored_config_error() {
	if router_id_required; then
		error=$(router_id_error)
		if [ -n "$error" ]; then
			printf 'router_id %s' "$error"
			return 0
		fi
	fi
	if [ "$ospf_enabled" = 1 ]; then
		error=$(ospf_config_error)
		if [ -n "$error" ]; then
			printf 'interfaces %s' "$error"
			return 0
		fi
	fi
	if [ "$rip_enabled" = 1 ]; then
		error=$(rip_config_error)
		if [ -n "$error" ]; then
			printf '%s' "$error"
			return 0
		fi
	fi
	if [ "$bgp_enabled" = 1 ]; then bgp_config_error; fi
}

# --- Rule firewall cho gói điều khiển định tuyến (ADR-0007) ---

# Gọi "$@" với từng lệnh iptables cần chèn.
accept_rules() {
	if [ "$ospf_enabled" = 1 ]; then ospf_accept_rules "$@"; fi
	if [ "$rip_enabled" = 1 ]; then rip_accept_rules "$@"; fi
	if [ "$bgp_enabled" = 1 ]; then bgp_accept_rules "$@"; fi
}

run_quietly() {
	"$@" >/dev/null 2>&1 || true
}

# Gỡ mọi rule mang tag rồi chèn lại theo cấu hình hiện tại (không còn rule nào khi mọi giao thức tắt).
# Không cần reload firewall, và chạy lại nhiều lần không sinh rule trùng.
firewall_sync() {
	iptables -S INPUT 2>/dev/null | sed -n "s/^-A \\(.*--comment $rule_tag .*\\)/-D \\1/p" | while read -r rule; do
		# shellcheck disable=SC2086 # rule là danh sách tham số do iptables -S in ra
		run_quietly iptables $rule
	done
	accept_rules run_quietly
}

# --- apply ---

apply_plan() {
	if [ -z "$(frr_enabled_daemons)" ]; then
		reply 0 'routing protocols disabled' ',"action":"stop","firewall_rules":""'
		return
	fi
	error=$(stored_config_error)
	if [ -n "$error" ]; then
		apply_error_set "$error"
		apply_fail ''
		return
	fi
	# Kế hoạch cũng không để lộ mật khẩu MD5 của Peer BGP.
	plan_conf=$(frr_config | sed 's/^\( neighbor [^ ]* password \).*/\1<hidden>/')
	reply 0 'routing plan ready' ",\"action\":\"start\",\"frr_restart\":$(frr_restart_plan | json_strings),\"frr_conf\":$(json_string "$plan_conf"),\"daemons\":$(json_string "$(daemons_config)"),\"firewall_rules\":$(json_string "$(accept_rules echo)")"
}

# Daemon nhận cấu hình qua mgmtd (FRR 10). mgmtd giữ cấu hình của chúng qua lần restart của riêng daemon và
# đẩy lại bản cũ, nên mgmtd được restart trước: nó nạp phần của mình trong frr.conf mới ("vtysh -b -d mgmtd"),
# rồi đẩy cho daemon khi daemon khởi động lại. zebra (cũng là backend của mgmtd) và ospfd vẫn chạy.
# mgmtd khi đó cũng được báo trong frr_restarted.
frr_mgmtd_backends='ripd'

# Restart riêng một daemon qua frrcommon.sh, như watchfrr làm khi daemon chết: dừng, khởi động, rồi
# "vtysh -b -d <daemon>" nạp phần của nó trong frr.conf.
frr_restart_daemon() {
	case " $frr_mgmtd_backends " in
		*" $1 "*)
			/usr/sbin/watchfrr.sh restart mgmtd >/dev/null 2>&1 || true
			pidof mgmtd >/dev/null 2>&1 || return 1
			frr_restarted="$frr_restarted
mgmtd"
			;;
	esac
	/usr/sbin/watchfrr.sh restart "$1" >/dev/null 2>&1 || true
	pidof "$1" >/dev/null 2>&1
}

# Tách lỗi "field[/IP] message" của stored_config_error vào apply_error_field, apply_error_peer và apply_error.
apply_error_set() {
	apply_error_field=${1%% *} apply_error=${1#* } apply_error_peer=
	case "$apply_error_field" in
		*/*) apply_error_peer=${apply_error_field#*/} apply_error_field=${apply_error_field%%/*} ;;
	esac
}

# Ghi frr.conf; nó chứa mật khẩu MD5 của Peer BGP nên chỉ root đọc được (vtysh -b chạy với quyền root).
frr_conf_write() {
	conf=$(frr_config) || return 1
	(umask 077 && printf '%s\n' "$conf" > "$frr_dir/frr.conf.tmp") || return 1
	chmod 600 "$frr_dir/frr.conf.tmp" || return 1
	mv "$frr_dir/frr.conf.tmp" "$frr_dir/frr.conf"
}

# Áp cấu hình đang lưu lên FRR và firewall; khi lỗi, apply_error giữ lý do, apply_error_field ô liên quan và
# apply_error_peer Peer BGP liên quan.
# frr_restarted là các daemon lần apply này đã restart (mỗi dòng một daemon; có zebra là restart toàn bộ).
apply_config() {
	apply_error= apply_error_field= apply_error_peer= frr_restarted=
	if [ -z "$(frr_enabled_daemons)" ]; then
		run_quietly /etc/init.d/frr stop
		firewall_sync
		return 0
	fi
	error=$(stored_config_error)
	if [ -n "$error" ]; then
		apply_error_set "$error"
		return 1
	fi
	firewall_sync
	restart=$(frr_restart_plan)
	# Daemon không chạy (FRR đã dừng, daemon chết) cũng phải khởi động lại; thiếu zebra thì restart toàn bộ.
	for daemon in zebra $(frr_enabled_daemons); do
		pidof "$daemon" >/dev/null 2>&1 || restart="$restart
$daemon"
	done
	if printf '%s\n' "$restart" | grep -qx zebra; then
		restart="zebra
$(frr_enabled_daemons)"
	fi
	restart=$(printf '%s\n' "$restart" | awk 'NF && !seen[$0]++')
	[ -n "$restart" ] || return 0
	mkdir -p "$frr_dir"
	if ! frr_conf_write; then
		apply_error='failed to write the FRR configuration'
		return 1
	fi
	daemons_config > "$frr_dir/daemons"
	if printf '%s\n' "$restart" | grep -qx zebra; then
		if ! /etc/init.d/frr restart >/dev/null 2>&1; then
			apply_error='FRR failed to restart'
			return 1
		fi
	else
		for daemon in $restart; do
			if ! frr_restart_daemon "$daemon"; then
				apply_error="FRR failed to restart $daemon"
				return 1
			fi
			frr_restarted="$frr_restarted
$daemon"
		done
		frr_restarted=$(printf '%s\n' "$frr_restarted" | awk 'NF && !seen[$0]++')
		return 0
	fi
	frr_restarted=$restart
}

# Trả lời lỗi của apply_config, với tiền tố $1.
apply_fail() {
	if [ -n "$apply_error_peer" ]; then
		fail "$apply_error_field" "$1$apply_error" ",\"peer\":$(json_string "$apply_error_peer")"
	elif [ -n "$apply_error_field" ]; then
		fail "$apply_error_field" "$1$apply_error"
	else
		reply -1 "$1$apply_error"
	fi
}

apply_command() {
	if [ "$dry_run" = 1 ]; then
		apply_plan
	elif ! apply_config; then
		apply_fail ''
	elif [ -n "$(frr_enabled_daemons)" ]; then
		reply 0 'routing configuration applied' ",\"action\":\"start\",\"frr_restarted\":$(printf '%s\n' "$frr_restarted" | json_strings)"
	else
		reply 0 'routing protocols disabled' ',"action":"stop"'
	fi
}

# Ghi batch vào bmcDynRouting, nạp lại snapshot và apply. $1 message, $2 phần JSON thêm của reply.
save_and_apply() {
	plan_or_commit "$1" "$2" bmcDynRouting || return 0
	uci_load_snapshot
	load_config
	if apply_config; then
		reply 0 "$1" "$2,\"frr_restarted\":$(printf '%s\n' "$frr_restarted" | json_strings)"
	else
		apply_fail 'configuration saved but not applied: '
	fi
}
