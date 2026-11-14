# Cấu hình OSPF: đọc, kiểm tra, cảnh báo, sinh phần ospfd của cấu hình FRR và rule firewall (ADR-0001, ADR-0007).

# Mỗi Interface OSPF là một section kiểu ospf_interface tên "oi_<interface>" (oi = OSPF interface).
# Bảng tuỳ chọn của nó: "option UCI:cờ CLI". Mọi nơi đọc/ghi/kiểm tra một Interface OSPF đi qua bảng này.
ospf_interface_options='area:--area passive:--passive cost:--cost hello_interval:--hello-interval dead_interval:--dead-interval network_type:--network-type'

# Giá trị mặc định của FRR, dùng khi chỉ một trong hai timer được đặt.
frr_default_hello_interval=10
frr_default_dead_interval=40

load_ospf() {
	ospf_enabled=$(uci_get bmcDynRouting.ospf.enabled)
	redistribute_static=$(uci_get bmcDynRouting.ospf.redistribute_static)
	redistribute_connected=$(uci_get bmcDynRouting.ospf.redistribute_connected)
	redistribute_rip=$(uci_get bmcDynRouting.ospf.redistribute_rip)
	redistribute_bgp=$(uci_get bmcDynRouting.ospf.redistribute_bgp)
	ospf_enabled=${ospf_enabled:-0}
	redistribute_static=${redistribute_static:-0}
	redistribute_connected=${redistribute_connected:-0}
	redistribute_rip=${redistribute_rip:-0}
	redistribute_bgp=${redistribute_bgp:-0}
}

ospf_interface_sections() {
	uci_sections bmcDynRouting ospf_interface
}

is_ospf_interface() {
	[ -n "$(uci_find_section bmcDynRouting ospf_interface interface "$1")" ]
}

default_network_type() {
	if is_link "$1"; then printf point-to-point; else printf broadcast; fi
}

# --- Một dòng Interface OSPF: row_interface và row_<option> cho từng option trong bảng ---

row_get() {
	eval "printf '%s' \"\${row_$1}\""
}

row_set() {
	eval "row_$1=\$2"
}

# Tên option UCI ứng với cờ CLI $1, hoặc không in gì.
option_for_flag() {
	for entry in $ospf_interface_options; do
		if [ "${entry#*:}" = "$1" ]; then printf '%s' "${entry%%:*}"; fi
	done
}

row_reset() {
	row_interface=$1
	for entry in $ospf_interface_options; do row_set "${entry%%:*}" ''; done
	row_area=0 row_passive=0
}

row_load() {
	row_reset "$(uci_get "bmcDynRouting.$1.interface")"
	for entry in $ospf_interface_options; do
		value=$(uci_get "bmcDynRouting.$1.${entry%%:*}")
		if [ -n "$value" ]; then row_set "${entry%%:*}" "$value"; fi
	done
}

# Area nhận số thập phân 32-bit hoặc dotted-quad, như FRR.
area_valid() {
	case "$1" in
		''|*[!0-9.]*) return 1 ;;
		*.*) ipv4_valid "$1" ;;
		*) [ "${#1}" -le 10 ] && awk -v n="$1" 'BEGIN { exit n + 0 <= 4294967295 ? 0 : 1 }' ;;
	esac
}

area_dotted() {
	case "$1" in
		*.*) printf '%s' "$1" ;;
		*) ipv4_from_int "$1" ;;
	esac
}

# In lỗi đầu tiên của dòng Interface OSPF đang nạp; không in gì nếu hợp lệ.
row_error() {
	if ! area_valid "$row_area"; then
		printf 'area of interface %s must be a number or a dotted-quad' "$row_interface"
		return 0
	fi
	case "$row_passive" in
		0|1) ;;
		*) printf 'passive of interface %s must be 0 or 1' "$row_interface"; return 0 ;;
	esac
	for option in cost hello_interval dead_interval; do
		value=$(row_get "$option")
		if [ -n "$value" ] && ! frr_number_valid "$value"; then
			printf '%s of interface %s must be an integer from 1 to 65535' "$(printf '%s' "$option" | tr _ ' ')" "$row_interface"
			return 0
		fi
	done
	hello=${row_hello_interval:-$frr_default_hello_interval}
	dead=${row_dead_interval:-$frr_default_dead_interval}
	if [ "$dead" -le "$hello" ]; then
		printf 'dead interval (%s) of interface %s must be greater than its hello interval (%s)' "$dead" "$row_interface" "$hello"
		return 0
	fi
	case "$row_network_type" in
		''|point-to-point|broadcast) ;;
		*) printf 'network type of interface %s must be point-to-point or broadcast' "$row_interface" ;;
	esac
}

row_to_batch() {
	section="oi_$row_interface"
	batch_add "set bmcDynRouting.$section=ospf_interface"
	batch_add "set bmcDynRouting.$section.interface=$(uci_quote "$row_interface")"
	for entry in $ospf_interface_options; do
		value=$(row_get "${entry%%:*}")
		if [ -n "$value" ]; then batch_add "set bmcDynRouting.$section.${entry%%:*}=$(uci_quote "$value")"; fi
	done
}

row_json() {
	json=$(for entry in $ospf_interface_options; do
		option=${entry%%:*}
		if [ "$option" = passive ]; then
			printf ',"%s":%s' "$option" "$(json_bool "$row_passive")"
		else
			printf ',"%s":%s' "$option" "$(json_string "$(row_get "$option")")"
		fi
	done)
	printf '{"interface":%s%s,"default_network_type":%s}\n' "$(json_string "$row_interface")" "$json" \
		"$(json_string "$(default_network_type "$row_interface")")"
}

# Lỗi của các Interface OSPF đang lưu (có thể đã bị sửa tay), hoặc không in gì.
ospf_config_error() {
	for section in $(ospf_interface_sections); do
		row_load "$section"
		error=$(row_error)
		if [ -n "$error" ]; then
			printf '%s' "$error"
			return 0
		fi
	done
}

# In các cảnh báo của dòng Interface OSPF đang nạp, mỗi dòng một object JSON.
row_warnings() {
	interface_warnings OSPF "$row_interface" "$row_passive"
}

# --- Sinh cấu hình FRR ---

render_row() {
	device=$(interface_device "$row_interface")
	[ -n "$device" ] || return 0
	printf 'interface %s\n ip ospf area %s\n' "$device" "$(area_dotted "$row_area")"
	if [ "$row_passive" = 1 ]; then printf ' ip ospf passive\n'; fi
	if [ -n "$row_cost" ]; then printf ' ip ospf cost %s\n' "$row_cost"; fi
	if [ -n "$row_hello_interval" ]; then printf ' ip ospf hello-interval %s\n' "$row_hello_interval"; fi
	if [ -n "$row_dead_interval" ]; then printf ' ip ospf dead-interval %s\n' "$row_dead_interval"; fi
	printf ' ip ospf network %s\n!\n' "${row_network_type:-$(default_network_type "$row_interface")}"
}

# Phần ospfd của frr.conf; Router ID nằm ở mức zebra (frr.sh).
ospf_frr_config() {
	printf 'router ospf\n'
	# Route tĩnh của router do netifd cài vào kernel (proto static); zebra xếp chúng vào loại kernel,
	# nên "redistribute static" (chỉ cho route của staticd) không thấy chúng. Default route không bị
	# quảng bá theo đường này nếu không có default-information originate.
	if [ "$redistribute_static" = 1 ]; then printf ' redistribute kernel\n'; fi
	if [ "$redistribute_connected" = 1 ]; then printf ' redistribute connected\n'; fi
	if [ "$redistribute_rip" = 1 ]; then printf ' redistribute rip\n'; fi
	if [ "$redistribute_bgp" = 1 ]; then bgp_into_igp_redistribute "$bgp_to_ospf_route_map"; fi
	printf '!\n'
	for section in $(ospf_interface_sections); do
		row_load "$section"
		render_row
	done
	if [ "$redistribute_bgp" = 1 ]; then bgp_into_igp_route_map "$bgp_to_ospf_route_map"; fi
}

# --- Rule firewall cho gói OSPF (proto 89), kể cả trên interface passive ---

ospf_devices() {
	for section in $(ospf_interface_sections); do
		row_load "$section"
		device=$(interface_device "$row_interface")
		if [ -n "$device" ]; then printf '%s\n' "$device"; fi
	done
}

# Gọi "$@" với từng lệnh iptables cần chèn. Rule đứng đầu INPUT để đi trước rule do web UI chèn.
ospf_accept_rules() {
	for device in $(ospf_devices); do
		"$@" iptables -I INPUT -i "$device" -p 89 -m comment --comment "$rule_tag" -j ACCEPT
	done
}

# --- ospf get / set ---

ospf_get() {
	interfaces=$(for section in $(ospf_interface_sections); do row_load "$section"; row_json; done | json_array)
	advanced_lines=$(uci_list bmcDynRouting.ospf.advanced_line | json_strings)
	warnings=$({
		redistribute_bgp_warning OSPF "$redistribute_bgp"
		for section in $(ospf_interface_sections); do row_load "$section"; row_warnings; done
	} | json_array)
	reply 0 'OSPF configuration' ",\"enabled\":$(json_bool "$ospf_enabled"),\"redistribute_static\":$(json_bool "$redistribute_static"),\"redistribute_connected\":$(json_bool "$redistribute_connected"),\"redistribute_rip\":$(json_bool "$redistribute_rip"),\"redistribute_bgp\":$(json_bool "$redistribute_bgp"),\"interfaces\":$interfaces,\"advanced_lines\":$advanced_lines,\"warnings\":$warnings"
}

# Kiểm tra dòng Interface OSPF đang mở trong ospf set, đưa nó vào batch và gom cảnh báo.
# Trả về 1 khi đã reply lỗi.
close_row() {
	[ -n "$row_interface" ] || return 0
	error=$(row_error)
	if [ -n "$error" ]; then
		fail interfaces "$error" ",\"interface\":$(json_string "$row_interface")"
		return 1
	fi
	row_to_batch
	set_warnings="$set_warnings$(row_warnings)
"
	row_interface=
}

open_row() {
	if ! is_network_interface "$1"; then
		fail interfaces "interface $1 does not exist" ",\"interface\":$(json_string "$1")"
		return 1
	fi
	case "$listed_interfaces" in
		*" $1 "*) fail interfaces "interface $1 is listed more than once" ",\"interface\":$(json_string "$1")"; return 1 ;;
	esac
	listed_interfaces="$listed_interfaces$1 "
	row_reset "$1"
}

ospf_set() {
	batch_reset
	if [ "$#" -eq 2 ] && [ "$1" = --enabled ] && [ "$2" = 0 ]; then
		batch_add "set bmcDynRouting.ospf.enabled='0'"
		save_and_apply 'OSPF disabled' ''
		return
	fi
	new_enabled= new_static=0 new_connected=0 new_rip=0 new_bgp=0
	listed_interfaces=' ' row_interface= set_warnings=
	# Ghi đè toàn bộ: bỏ mọi Interface OSPF và Dòng lệnh nâng cao cũ, rồi dựng lại từ tham số.
	for section in $(ospf_interface_sections); do batch_add "delete bmcDynRouting.$section"; done
	if [ -n "$(uci_list bmcDynRouting.ospf.advanced_line)" ]; then batch_add 'delete bmcDynRouting.ospf.advanced_line'; fi
	while [ "$#" -gt 0 ]; do
		if [ "$#" -lt 2 ]; then
			reply -1 "option $1 requires a value"
			return
		fi
		option=$(option_for_flag "$1")
		case "$1" in
			--enabled) new_enabled=$2 ;;
			--router-id) fail router_id '--router-id is no longer an OSPF option: use "router-id set --router-id ID"'; return ;;
			--redistribute-static) new_static=$2 ;;
			--redistribute-connected) new_connected=$2 ;;
			--redistribute-rip) new_rip=$2 ;;
			--redistribute-bgp) new_bgp=$2 ;;
			--advanced-line)
				error=$(advanced_line_error "$2")
				if [ -n "$error" ]; then fail advanced_lines "$error"; return; fi
				batch_add "add_list bmcDynRouting.ospf.advanced_line=$(uci_quote "$2")"
				;;
			--interface)
				close_row || return 0
				open_row "$2" || return 0
				;;
			*)
				if [ -z "$option" ]; then reply -1 "unknown OSPF option: $1"; return; fi
				if [ -z "$row_interface" ]; then fail interfaces "$1 must follow --interface"; return; fi
				row_set "$option" "$2"
				;;
		esac
		shift 2
	done
	close_row || return 0
	case "$new_enabled" in
		0|1) ;;
		*) fail enabled '--enabled must be 0 or 1'; return ;;
	esac
	for flag in "$new_static" "$new_connected" "$new_rip" "$new_bgp"; do
		case "$flag" in 0|1) ;; *) fail redistribute 'redistribute options must be 0 or 1'; return ;; esac
	done
	if [ "$new_enabled" = 1 ]; then
		error=$(router_id_error)
		if [ -n "$error" ]; then fail router_id "$error"; return; fi
	fi
	batch_add "set bmcDynRouting.ospf.enabled='$new_enabled'"
	batch_add "set bmcDynRouting.ospf.redistribute_static='$new_static'"
	batch_add "set bmcDynRouting.ospf.redistribute_connected='$new_connected'"
	batch_add "set bmcDynRouting.ospf.redistribute_rip='$new_rip'"
	batch_add "set bmcDynRouting.ospf.redistribute_bgp='$new_bgp'"
	set_warnings="$(redistribute_bgp_warning OSPF "$new_bgp")
$set_warnings"
	save_and_apply 'OSPF configuration saved' ",\"warnings\":$(printf '%s' "$set_warnings" | json_array)"
}
