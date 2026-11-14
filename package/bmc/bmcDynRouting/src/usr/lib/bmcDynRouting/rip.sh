# Cấu hình RIP (RIPv2): đọc, kiểm tra, cảnh báo, sinh phần ripd của cấu hình FRR và rule firewall (ADR-0001, ADR-0007).

# Tuỳ chọn của section "rip": "option UCI:cờ CLI". Cờ bật/tắt (0|1, mặc định 0) và timer (trống = mặc định của FRR).
rip_flag_options='redistribute_static:--redistribute-static redistribute_connected:--redistribute-connected redistribute_ospf:--redistribute-ospf redistribute_bgp:--redistribute-bgp default_originate:--default-originate'
rip_timer_options='update_timer:--update-timer timeout_timer:--timeout-timer garbage_timer:--garbage-timer'

# Mặc định của FRR, dùng khi chỉ một phần các timer được đặt ("timers basic" cần đủ ba).
frr_default_update_timer=30
frr_default_timeout_timer=180
frr_default_garbage_timer=120

# Khoảng timer RIP mà mọi bản FRR đang dùng đều nhận: FRR 10.2 nhận từ 5 giây, FRR 10.4 nhận tới 32767 giây.
rip_timer_min=5
rip_timer_max=32767

rip_get_var() {
	eval "printf '%s' \"\${rip_$1}\""
}

rip_set_var() {
	eval "rip_$1=\$2"
}

load_rip() {
	rip_enabled=$(uci_get bmcDynRouting.rip.enabled)
	rip_enabled=${rip_enabled:-0}
	for entry in $rip_flag_options; do
		value=$(uci_get "bmcDynRouting.rip.${entry%%:*}")
		rip_set_var "${entry%%:*}" "${value:-0}"
	done
	for entry in $rip_timer_options; do
		rip_set_var "${entry%%:*}" "$(uci_get "bmcDynRouting.rip.${entry%%:*}")"
	done
}

# Mỗi Interface RIP là một section kiểu rip_interface tên "ri_<interface>" (ri = RIP interface).
rip_interface_sections() {
	uci_sections bmcDynRouting rip_interface
}

is_rip_interface() {
	[ -n "$(uci_find_section bmcDynRouting rip_interface interface "$1")" ]
}

# Tạo section "rip" trong batch nếu cấu hình (vd. từ phase 1) chưa có.
batch_add_rip_section() {
	if [ -z "$(uci_get bmcDynRouting.rip)" ]; then batch_add 'set bmcDynRouting.rip=rip'; fi
}

# --- Một dòng Interface RIP: rip_row_interface, rip_row_passive ---

rip_row_load() {
	rip_row_interface=$(uci_get "bmcDynRouting.$1.interface")
	rip_row_passive=$(uci_get "bmcDynRouting.$1.passive")
	rip_row_passive=${rip_row_passive:-0}
}

rip_row_error() {
	case "$rip_row_passive" in
		0|1) ;;
		*) printf 'passive of interface %s must be 0 or 1' "$rip_row_interface" ;;
	esac
}

# Lỗi của timer $1 (option UCI) có giá trị $2, hoặc không in gì.
rip_timer_error() {
	if [ -n "$2" ] && ! frr_number_valid "$2" "$rip_timer_min" "$rip_timer_max"; then
		printf '%s must be an integer from %s to %s' "$(printf '%s' "$1" | tr _ ' ')" "$rip_timer_min" "$rip_timer_max"
	fi
}

# Lỗi của Cấu hình RIP đang lưu (có thể đã bị sửa tay) dạng "field message", hoặc không in gì.
rip_config_error() {
	for section in $(rip_interface_sections); do
		rip_row_load "$section"
		error=$(rip_row_error)
		if [ -n "$error" ]; then
			printf 'interfaces %s' "$error"
			return 0
		fi
	done
	for entry in $rip_timer_options; do
		error=$(rip_timer_error "${entry%%:*}" "$(rip_get_var "${entry%%:*}")")
		if [ -n "$error" ]; then
			printf '%s %s' "${entry%%:*}" "$error"
			return 0
		fi
	done
}

# --- Sinh cấu hình FRR ---

# Thiết bị L3 của các Interface RIP có passive = $1 ("" = mọi Interface RIP), mỗi dòng một thiết bị.
rip_devices() {
	for section in $(rip_interface_sections); do
		rip_row_load "$section"
		[ -z "${1:-}" ] || [ "$rip_row_passive" = "$1" ] || continue
		device=$(interface_device "$rip_row_interface")
		if [ -n "$device" ]; then printf '%s\n' "$device"; fi
	done
}

# Phần ripd của frr.conf. "network <thiết bị>" đưa interface vào RIP theo tên, không theo dải mạng.
rip_frr_config() {
	printf 'router rip\n version 2\n'
	for device in $(rip_devices); do printf ' network %s\n' "$device"; done
	for device in $(rip_devices 1); do printf ' passive-interface %s\n' "$device"; done
	# Route tĩnh do netifd cài vào kernel: xem ghi chú ở ospf_frr_config.
	if [ "$rip_redistribute_static" = 1 ]; then printf ' redistribute kernel\n'; fi
	if [ "$rip_redistribute_connected" = 1 ]; then printf ' redistribute connected\n'; fi
	if [ "$rip_redistribute_ospf" = 1 ]; then printf ' redistribute ospf\n'; fi
	if [ "$rip_redistribute_bgp" = 1 ]; then bgp_into_igp_redistribute "$bgp_to_rip_route_map"; fi
	if [ "$rip_default_originate" = 1 ]; then printf ' default-information originate\n'; fi
	if [ -n "$rip_update_timer$rip_timeout_timer$rip_garbage_timer" ]; then
		printf ' timers basic %s %s %s\n' "${rip_update_timer:-$frr_default_update_timer}" \
			"${rip_timeout_timer:-$frr_default_timeout_timer}" "${rip_garbage_timer:-$frr_default_garbage_timer}"
	fi
	printf '!\n'
	if [ "$rip_redistribute_bgp" = 1 ]; then bgp_into_igp_route_map "$bgp_to_rip_route_map"; fi
}

# Gọi "$@" với từng lệnh iptables cần chèn: UDP 520 trên mọi Interface RIP, kể cả passive (vẫn nhận update).
rip_accept_rules() {
	for device in $(rip_devices); do
		"$@" iptables -I INPUT -i "$device" -p udp --dport 520 -m comment --comment "$rule_tag" -j ACCEPT
	done
}

# --- rip get / set ---

rip_row_json() {
	printf '{"interface":%s,"passive":%s}\n' "$(json_string "$rip_row_interface")" "$(json_bool "$rip_row_passive")"
}

rip_get() {
	options=$(for entry in $rip_flag_options; do
		printf ',"%s":%s' "${entry%%:*}" "$(json_bool "$(rip_get_var "${entry%%:*}")")"
	done
	for entry in $rip_timer_options; do
		printf ',"%s":%s' "${entry%%:*}" "$(json_string "$(rip_get_var "${entry%%:*}")")"
	done)
	interfaces=$(for section in $(rip_interface_sections); do rip_row_load "$section"; rip_row_json; done | json_array)
	advanced_lines=$(uci_list bmcDynRouting.rip.advanced_line | json_strings)
	warnings=$({
		redistribute_bgp_warning RIP "$rip_redistribute_bgp"
		for section in $(rip_interface_sections); do
			rip_row_load "$section"
			interface_warnings RIP "$rip_row_interface" "$rip_row_passive"
		done
	} | json_array)
	reply 0 'RIP configuration' ",\"enabled\":$(json_bool "$rip_enabled")$options,\"interfaces\":$interfaces,\"advanced_lines\":$advanced_lines,\"warnings\":$warnings"
}

# Kiểm tra dòng Interface RIP đang mở trong rip set, đưa nó vào batch và gom cảnh báo.
# Trả về 1 khi đã reply lỗi.
rip_close_row() {
	[ -n "$rip_row_interface" ] || return 0
	error=$(rip_row_error)
	if [ -n "$error" ]; then
		fail interfaces "$error" ",\"interface\":$(json_string "$rip_row_interface")"
		return 1
	fi
	section="ri_$rip_row_interface"
	batch_add "set bmcDynRouting.$section=rip_interface"
	batch_add "set bmcDynRouting.$section.interface=$(uci_quote "$rip_row_interface")"
	batch_add "set bmcDynRouting.$section.passive=$(uci_quote "$rip_row_passive")"
	set_warnings="$set_warnings$(interface_warnings RIP "$rip_row_interface" "$rip_row_passive")
"
	rip_row_interface=
}

rip_open_row() {
	if ! is_network_interface "$1"; then
		fail interfaces "interface $1 does not exist" ",\"interface\":$(json_string "$1")"
		return 1
	fi
	case "$listed_interfaces" in
		*" $1 "*) fail interfaces "interface $1 is listed more than once" ",\"interface\":$(json_string "$1")"; return 1 ;;
	esac
	listed_interfaces="$listed_interfaces$1 "
	rip_row_interface=$1 rip_row_passive=0
}

# Option UCI của section "rip" ứng với cờ CLI $1, hoặc không in gì.
rip_option_for_flag() {
	for entry in $rip_flag_options $rip_timer_options; do
		if [ "${entry#*:}" = "$1" ]; then printf '%s' "${entry%%:*}"; fi
	done
}

# Giá trị mới của option $1 do rip set nhận (biến new_<option>).
rip_new_get() {
	eval "printf '%s' \"\$new_$1\""
}

rip_set() {
	batch_reset
	batch_add_rip_section
	if [ "$#" -eq 2 ] && [ "$1" = --enabled ] && [ "$2" = 0 ]; then
		batch_add "set bmcDynRouting.rip.enabled='0'"
		save_and_apply 'RIP disabled' ''
		return
	fi
	new_enabled=
	for entry in $rip_flag_options; do eval "new_${entry%%:*}=0"; done
	for entry in $rip_timer_options; do eval "new_${entry%%:*}="; done
	listed_interfaces=' ' rip_row_interface= set_warnings=
	# Ghi đè toàn bộ: bỏ mọi Interface RIP và Dòng lệnh nâng cao cũ, rồi dựng lại từ tham số.
	for section in $(rip_interface_sections); do batch_add "delete bmcDynRouting.$section"; done
	if [ -n "$(uci_list bmcDynRouting.rip.advanced_line)" ]; then batch_add 'delete bmcDynRouting.rip.advanced_line'; fi
	while [ "$#" -gt 0 ]; do
		if [ "$#" -lt 2 ]; then
			reply -1 "option $1 requires a value"
			return
		fi
		option=$(rip_option_for_flag "$1")
		case "$1" in
			--enabled) new_enabled=$2 ;;
			--advanced-line)
				error=$(advanced_line_error "$2")
				if [ -n "$error" ]; then fail advanced_lines "$error"; return; fi
				batch_add "add_list bmcDynRouting.rip.advanced_line=$(uci_quote "$2")"
				;;
			--interface)
				rip_close_row || return 0
				rip_open_row "$2" || return 0
				;;
			--passive)
				if [ -z "$rip_row_interface" ]; then fail interfaces "$1 must follow --interface"; return; fi
				rip_row_passive=$2
				;;
			*)
				if [ -z "$option" ]; then reply -1 "unknown RIP option: $1"; return; fi
				eval "new_$option=\$2"
				;;
		esac
		shift 2
	done
	rip_close_row || return 0
	case "$new_enabled" in
		0|1) ;;
		*) fail enabled '--enabled must be 0 or 1'; return ;;
	esac
	for entry in $rip_flag_options; do
		case "$(rip_new_get "${entry%%:*}")" in
			0|1) ;;
			*)
				case "${entry%%:*}" in
					redistribute_*) fail redistribute 'redistribute options must be 0 or 1' ;;
					*) fail "${entry%%:*}" "${entry#*:} must be 0 or 1" ;;
				esac
				return
				;;
		esac
	done
	for entry in $rip_timer_options; do
		option=${entry%%:*}
		value=$(rip_new_get "$option")
		error=$(rip_timer_error "$option" "$value")
		if [ -n "$error" ]; then fail "$option" "$error"; return; fi
		if [ -n "$value" ]; then
			batch_add "set bmcDynRouting.rip.$option=$(uci_quote "$value")"
		elif uci_has "bmcDynRouting.rip.$option"; then
			batch_add "delete bmcDynRouting.rip.$option"
		fi
	done
	batch_add "set bmcDynRouting.rip.enabled='$new_enabled'"
	for entry in $rip_flag_options; do
		batch_add "set bmcDynRouting.rip.${entry%%:*}='$(rip_new_get "${entry%%:*}")'"
	done
	set_warnings="$(redistribute_bgp_warning RIP "$new_redistribute_bgp")
$set_warnings"
	save_and_apply 'RIP configuration saved' ",\"warnings\":$(printf '%s' "$set_warnings" | json_array)"
}

# --- status rip: ripd không có lệnh show dạng JSON, nên dựng JSON từ output văn bản của vtysh ---

# "show ip rip status" → {"interfaces":[{interface, send_version, receive_version, passive}],
#                          "neighbors":[{address, bad_packets, bad_routes, last_update}]}
rip_status_interfaces_json() {
	awk '
	function q(s,   out, i, c) {
		for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); out = out ((c == "\\" || c == "\"") ? "\\" : "") c }
		return "\"" out "\""
	}
	/^    Interface +Send +Recv/ { section = "interfaces"; next }
	/^  Routing for Networks:/ { section = ""; next }
	/^  Passive Interface\(s\):/ { section = "passive"; next }
	/^  Routing Information Sources:/ { section = ""; next }
	/^    Gateway +BadPackets/ { section = "neighbors"; next }
	/^  [^ ]/ { section = ""; next }
	section == "interfaces" && NF >= 3 { iface[++ni] = $1; send[ni] = $2; recv[ni] = $3 }
	section == "passive" && NF == 1 { passive[$1] = 1 }
	section == "neighbors" && NF >= 5 { nb[++nn] = sprintf("{\"address\":%s,\"bad_packets\":%d,\"bad_routes\":%d,\"last_update\":%s}", q($1), $2, $3, q($5)) }
	END {
		printf "{\"interfaces\":["
		for (i = 1; i <= ni; i++)
			printf "%s{\"interface\":%s,\"send_version\":%s,\"receive_version\":%s,\"passive\":%s}", (i > 1 ? "," : ""), q(iface[i]), q(send[i]), q(recv[i]), (iface[i] in passive ? "true" : "false")
		printf "],\"neighbors\":["
		for (i = 1; i <= nn; i++) printf "%s%s", (i > 1 ? "," : ""), nb[i]
		printf "]}"
	}'
}

# "show ip rip" → {"routes":[{code, sub_code, network, next_hop, metric, from, tag, time}]}.
# "from" là IP láng giềng, "self" hoặc "self (<giao thức>:<metric>)" với route redistribute.
rip_status_routes_json() {
	awk '
	function q(s,   out, i, c) {
		for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); out = out ((c == "\\" || c == "\"") ? "\\" : "") c }
		return "\"" out "\""
	}
	/^     Network +Next Hop/ { table = 1; next }
	table && match($0, /^[A-Za-z]\([a-z?]\) /) {
		code = substr($0, 1, 1); sub_code = substr($0, 3, 1)
		rest = substr($0, 6)
		network = rest; sub(/ .*/, "", network)
		# Cột sau network: next hop (có thể là "V6 Address Hidden"), metric, from, tag, time.
		rest = substr(rest, length(network) + 1); sub(/^ +/, "", rest)
		if (match(rest, /^V6 Address Hidden +/)) { next_hop = "V6 Address Hidden"; rest = substr(rest, RLENGTH + 1) }
		else { next_hop = rest; sub(/ .*/, "", next_hop); rest = substr(rest, length(next_hop) + 1); sub(/^ +/, "", rest) }
		metric = rest; sub(/ .*/, "", metric); rest = substr(rest, length(metric) + 1); sub(/^ +/, "", rest)
		if (match(rest, /^self \([^)]*\)/)) from = substr(rest, 1, RLENGTH)
		else { from = rest; sub(/ .*/, "", from) }
		rest = substr(rest, length(from) + 1); sub(/^ +/, "", rest)
		tag = rest; sub(/ .*/, "", tag); rest = substr(rest, length(tag) + 1); gsub(/^ +| +$/, "", rest)
		routes[++n] = sprintf("{\"code\":%s,\"sub_code\":%s,\"network\":%s,\"next_hop\":%s,\"metric\":%d,\"from\":%s,\"tag\":%d,\"time\":%s}", q(code), q(sub_code), q(network), q(next_hop), metric, q(from), tag, q(rest))
	}
	END {
		printf "{\"routes\":["
		for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? "," : ""), routes[i]
		printf "]}"
	}'
}
