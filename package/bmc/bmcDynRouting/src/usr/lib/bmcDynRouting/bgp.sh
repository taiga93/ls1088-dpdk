# Cấu hình BGP (chỉ eBGP với Peer BGP nối trực tiếp, IPv4 unicast): đọc, kiểm tra, cảnh báo, sinh phần bgpd
# của cấu hình FRR cùng policy không transit (ADR-0008) và rule firewall TCP 179 theo IP peer (ADR-0007).

# Mỗi Peer BGP là một section kiểu bgp_peer tên "bp_<IP, dấu chấm thành _>" (bp = BGP peer).
# Bảng tuỳ chọn của nó: "option UCI:cờ CLI"; address đến từ --peer.
bgp_peer_options='remote_as:--remote-as description:--description enabled:--peer-enabled password:--password receive:--receive max_prefix:--max-prefix keepalive:--keepalive hold:--hold'

# Redistribute flags of the "bgp" section ("UCI option:CLI flag"), 0|1, default 0.
bgp_flag_options='redistribute_static:--redistribute-static redistribute_connected:--redistribute-connected redistribute_ospf:--redistribute-ospf redistribute_rip:--redistribute-rip'

# Giá trị dùng khi option để trống: giới hạn prefix theo ADR-0008, timer theo mặc định của FRR.
bgp_default_max_prefix=1000
frr_default_keepalive=60
frr_default_hold=180

# FRR nhận mật khẩu MD5 và mô tả peer tối đa 80 ký tự.
bgp_text_max=80

# Tên các đối tượng policy do firmware sinh (ADR-0008). Dòng lệnh nâng cao nối sau nên có thể mở lại chúng.
bgp_local_as_path=BMC-BGP-LOCAL
bgp_default_prefix_list=BMC-BGP-DEFAULT
bgp_out_route_map=BMC-BGP-OUT
bgp_in_all_route_map=BMC-BGP-IN-ALL
bgp_in_default_route_map=BMC-BGP-IN-DEFAULT
bgp_redistribute_route_map=BMC-BGP-REDISTRIBUTE

load_bgp() {
	bgp_enabled=$(uci_get bmcDynRouting.bgp.enabled)
	bgp_enabled=${bgp_enabled:-0}
	bgp_local_as=$(uci_get bmcDynRouting.bgp.local_as)
	for entry in $bgp_flag_options; do
		value=$(uci_get "bmcDynRouting.bgp.${entry%%:*}")
		eval "bgp_${entry%%:*}=\${value:-0}"
	done
}

bgp_flag_get() {
	eval "printf '%s' \"\${bgp_$1}\""
}

# New value of option $1 taken by bgp set (variable new_<option>).
bgp_new_get() {
	eval "printf '%s' \"\$new_$1\""
}

# UCI option of the "bgp" section for redistribute flag $1, or nothing.
bgp_option_for_redistribute_flag() {
	for entry in $bgp_flag_options; do
		if [ "${entry#*:}" = "$1" ]; then printf '%s' "${entry%%:*}"; fi
	done
}

bgp_peer_sections() {
	uci_sections bmcDynRouting bgp_peer
}

# Tạo section "bgp" trong batch nếu cấu hình (vd. từ phase 1) chưa có.
batch_add_bgp_section() {
	if [ -z "$(uci_get bmcDynRouting.bgp)" ]; then batch_add 'set bmcDynRouting.bgp=bgp'; fi
}

local_as_error() {
	if [ -z "$1" ]; then
		printf 'local AS is required when BGP is enabled'
	elif ! u32_valid "$1"; then
		printf 'local AS must be an integer from 1 to 4294967295'
	fi
}

# Lỗi của Mạng quảng bá BGP $1, hoặc không in gì. FRR từ chối prefix còn bit host.
bgp_network_error() {
	case "$1" in
		*/*) ipv4_valid "${1%/*}" && ipv4_prefix_valid "${1#*/}" && network=$(ipv4_network "${1%/*}" "${1#*/}") ;;
		*) false ;;
	esac || {
		printf 'network %s must be a prefix a.b.c.d/n' "$1"
		return 0
	}
	if [ "$network" != "${1%/*}" ]; then printf 'network %s has host bits set: use %s/%s' "$1" "$network" "${1#*/}"; fi
}

# Chỉ hỗ trợ eBGP: Peer BGP $1 không được có AS cục bộ $2.
bgp_same_as_error() {
	printf 'peer %s has the local AS %s: only eBGP peers are supported' "$1" "$2"
}

# Timer của FRR ("neighbor ... timers"): 0..65535; hold time 0 tắt keepalive, khác 0 thì từ 3 giây.
bgp_timer_valid() {
	case "$1" in 0) return 0 ;; ''|0*|*[!0-9]*) return 1 ;; esac
	[ "${#1}" -le 5 ] && [ "$1" -ge "${2:-1}" ] && [ "$1" -le 65535 ]
}

# --- Một dòng Peer BGP: bgp_peer_address và bgp_peer_<option> cho từng option trong bảng ---

bgp_peer_get() {
	eval "printf '%s' \"\${bgp_peer_$1}\""
}

bgp_peer_set() {
	eval "bgp_peer_$1=\$2"
}

# Tên option UCI ứng với cờ CLI $1, hoặc không in gì.
bgp_peer_option_for_flag() {
	for entry in $bgp_peer_options; do
		if [ "${entry#*:}" = "$1" ]; then printf '%s' "${entry%%:*}"; fi
	done
}

bgp_peer_reset() {
	bgp_peer_address=$1
	for entry in $bgp_peer_options; do bgp_peer_set "${entry%%:*}" ''; done
	bgp_peer_enabled=1 bgp_peer_receive=all
}

bgp_peer_load() {
	bgp_peer_reset "$(uci_get "bmcDynRouting.$1.address")"
	for entry in $bgp_peer_options; do
		value=$(uci_get "bmcDynRouting.$1.${entry%%:*}")
		if [ -n "$value" ]; then bgp_peer_set "${entry%%:*}" "$value"; fi
	done
}

bgp_peer_section_name() {
	printf 'bp_%s' "$(printf '%s' "$1" | tr . _)"
}

# Lỗi đầu tiên của dòng Peer BGP đang nạp, dạng "field message"; không in gì nếu hợp lệ.
# $1 là AS cục bộ để so với AS của peer (rỗng = chưa biết, không so).
bgp_peer_error() {
	if ! ipv4_valid "$bgp_peer_address"; then
		printf 'peers peer address %s must be a valid IPv4 address' "$bgp_peer_address"
		return 0
	fi
	if [ -z "$bgp_peer_remote_as" ]; then
		printf 'remote_as AS of peer %s is required' "$bgp_peer_address"
		return 0
	fi
	if ! u32_valid "$bgp_peer_remote_as"; then
		printf 'remote_as AS of peer %s must be an integer from 1 to 4294967295' "$bgp_peer_address"
		return 0
	fi
	if [ "$bgp_peer_remote_as" = "${1:-}" ]; then
		printf 'remote_as %s' "$(bgp_same_as_error "$bgp_peer_address" "$1")"
		return 0
	fi
	case "$bgp_peer_description" in
		*[[:cntrl:]]*) printf 'description description of peer %s must not contain control characters' "$bgp_peer_address"; return 0 ;;
	esac
	if [ "${#bgp_peer_description}" -gt "$bgp_text_max" ]; then
		printf 'description description of peer %s must be at most %s characters' "$bgp_peer_address" "$bgp_text_max"
		return 0
	fi
	case "$bgp_peer_enabled" in
		0|1) ;;
		*) printf 'enabled enabled of peer %s must be 0 or 1' "$bgp_peer_address"; return 0 ;;
	esac
	case "$bgp_peer_password" in
		*[[:space:][:cntrl:]]*) printf 'password password of peer %s must not contain spaces or control characters' "$bgp_peer_address"; return 0 ;;
	esac
	if [ "${#bgp_peer_password}" -gt "$bgp_text_max" ]; then
		printf 'password password of peer %s must be at most %s characters' "$bgp_peer_address" "$bgp_text_max"
		return 0
	fi
	case "$bgp_peer_receive" in
		all|default) ;;
		*) printf 'receive receive of peer %s must be all or default' "$bgp_peer_address"; return 0 ;;
	esac
	if [ -n "$bgp_peer_max_prefix" ] && ! u32_valid "$bgp_peer_max_prefix"; then
		printf 'max_prefix max prefix of peer %s must be an integer from 1 to 4294967295' "$bgp_peer_address"
		return 0
	fi
	if [ -n "$bgp_peer_keepalive" ] && ! bgp_timer_valid "$bgp_peer_keepalive" 0; then
		printf 'keepalive keepalive of peer %s must be an integer from 0 to 65535' "$bgp_peer_address"
		return 0
	fi
	if [ -n "$bgp_peer_hold" ] && ! bgp_timer_valid "$bgp_peer_hold" 3; then
		printf 'hold hold time of peer %s must be 0 or an integer from 3 to 65535' "$bgp_peer_address"
	fi
}

# Lỗi của Cấu hình BGP đang lưu (có thể đã bị sửa tay) dạng "field message", hoặc "field/IP message" với
# lỗi của Peer BGP IP; không in gì nếu hợp lệ.
bgp_config_error() {
	error=$(local_as_error "$bgp_local_as")
	if [ -n "$error" ]; then
		printf 'local_as %s' "$error"
		return 0
	fi
	for network in $(uci_list bmcDynRouting.bgp.network); do
		error=$(bgp_network_error "$network")
		if [ -n "$error" ]; then
			printf 'networks %s' "$error"
			return 0
		fi
	done
	for section in $(bgp_peer_sections); do
		bgp_peer_load "$section"
		error=$(bgp_peer_error "$bgp_local_as")
		if [ -n "$error" ]; then
			printf '%s/%s %s' "${error%% *}" "$bgp_peer_address" "${error#* }"
			return 0
		fi
	done
}

# --- Cảnh báo (không chặn việc lưu) ---

# Các subnet IPv4 của router (ip/prefix mỗi dòng), gồm địa chỉ lúc chạy như lease DHCP của WAN.
router_subnets() {
	known_subnets | awk '{ print $1 }'
}

# Cảnh báo của dòng Peer BGP đang nạp; $1 là các subnet của router (router_subnets).
bgp_peer_warnings() {
	ipv4_valid "$bgp_peer_address" || return 0
	for subnet in $1; do
		if ipv4_subnets_overlap "$bgp_peer_address" 32 "${subnet%/*}" "${subnet#*/}"; then return 0; fi
	done
	printf '{"peer":%s,"code":"bgp_peer_not_connected","message":%s}\n' "$(json_string "$bgp_peer_address")" \
		"$(json_string "Peer BGP $bgp_peer_address is not in any interface subnet: only directly connected eBGP peers are supported.")"
}

# --- Sinh cấu hình FRR ---

# Phần bgpd của frr.conf; Router ID nằm ở mức zebra (frr.sh). "no bgp default ipv4-unicast": peer chỉ trao
# đổi IPv4 unicast khi được activate tường minh trong address-family.
bgp_frr_config() {
	printf 'router bgp %s\n no bgp default ipv4-unicast\n' "$bgp_local_as"
	for section in $(bgp_peer_sections); do
		bgp_peer_load "$section"
		printf ' neighbor %s remote-as %s\n' "$bgp_peer_address" "$bgp_peer_remote_as"
		if [ -n "$bgp_peer_description" ]; then printf ' neighbor %s description %s\n' "$bgp_peer_address" "$bgp_peer_description"; fi
		if [ -n "$bgp_peer_password" ]; then printf ' neighbor %s password %s\n' "$bgp_peer_address" "$bgp_peer_password"; fi
		if [ "$bgp_peer_enabled" = 0 ]; then printf ' neighbor %s shutdown\n' "$bgp_peer_address"; fi
		if [ -n "$bgp_peer_keepalive$bgp_peer_hold" ]; then
			printf ' neighbor %s timers %s %s\n' "$bgp_peer_address" "${bgp_peer_keepalive:-$frr_default_keepalive}" "${bgp_peer_hold:-$frr_default_hold}"
		fi
	done
	printf ' !\n address-family ipv4 unicast\n'
	for network in $(uci_list bmcDynRouting.bgp.network); do printf '  network %s\n' "$network"; done
	# Static routes are kernel routes for zebra: see the note in ospf_frr_config.
	for entry in static:kernel connected:connected ospf:ospf rip:rip; do
		if [ "$(bgp_flag_get "redistribute_${entry%%:*}")" = 1 ]; then
			printf '  redistribute %s route-map %s\n' "${entry#*:}" "$bgp_redistribute_route_map"
		fi
	done
	for section in $(bgp_peer_sections); do
		bgp_peer_load "$section"
		if [ "$bgp_peer_receive" = default ]; then in_map=$bgp_in_default_route_map; else in_map=$bgp_in_all_route_map; fi
		printf '  neighbor %s activate\n' "$bgp_peer_address"
		printf '  neighbor %s route-map %s in\n' "$bgp_peer_address" "$in_map"
		printf '  neighbor %s route-map %s out\n' "$bgp_peer_address" "$bgp_out_route_map"
		printf '  neighbor %s maximum-prefix %s\n' "$bgp_peer_address" "${bgp_peer_max_prefix:-$bgp_default_max_prefix}"
	done
	printf ' exit-address-family\nexit\n!\n'
	bgp_policy_config
}

# No-transit policy (ADR-0008). Outbound only routes with an empty AS path, i.e. Route phát sinh nội bộ (Mạng
# quảng bá BGP and redistributed routes): a route learned from a Peer BGP always carries the peer's AS in its
# AS path, so it never reaches another peer. A BGP route that comes back through OSPF/RIP has lost its AS path
# but carries the tag set by the BGP -> IGP redistribution (protocol.sh), and the OSPF/RIP -> BGP
# redistribution denies that tag. No redistribution into BGP carries the default route either (the WAN's DHCP
# default, or an OSPF default of another router): announcing it to a Peer BGP would offer transit, so a default
# route is only announced when listed as a Mạng quảng bá BGP.
# Inbound: accept all, or only the default route. With route-maps in place "bgp ebgp-requires-policy" does not
# block the peers.
bgp_policy_config() {
	printf 'bgp as-path access-list %s seq 5 permit ^$\n!\n' "$bgp_local_as_path"
	printf 'ip prefix-list %s seq 5 permit 0.0.0.0/0\n!\n' "$bgp_default_prefix_list"
	printf 'route-map %s permit 10\n match as-path %s\nexit\n!\n' "$bgp_out_route_map" "$bgp_local_as_path"
	printf 'route-map %s permit 10\nexit\n!\n' "$bgp_in_all_route_map"
	printf 'route-map %s permit 10\n match ip address prefix-list %s\nexit\n!\n' "$bgp_in_default_route_map" "$bgp_default_prefix_list"
	if bgp_has_redistribution; then
		printf 'route-map %s deny 10\n match tag %s\nexit\n!\n' "$bgp_redistribute_route_map" "$bgp_igp_tag"
		printf 'route-map %s deny 20\n match ip address prefix-list %s\nexit\n!\n' "$bgp_redistribute_route_map" "$bgp_default_prefix_list"
		printf 'route-map %s permit 30\nexit\n!\n' "$bgp_redistribute_route_map"
	fi
}

bgp_has_redistribution() {
	for entry in $bgp_flag_options; do
		if [ "$(bgp_flag_get "${entry%%:*}")" = 1 ]; then return 0; fi
	done
	return 1
}

# Gọi "$@" với từng lệnh iptables cần chèn: TCP 179 chỉ từ IP của mỗi Peer BGP đang bật, không giới hạn
# interface (peer ISP nằm sau wan).
bgp_accept_rules() {
	for section in $(bgp_peer_sections); do
		bgp_peer_load "$section"
		[ "$bgp_peer_enabled" = 1 ] || continue
		"$@" iptables -I INPUT -s "$bgp_peer_address" -p tcp --dport 179 -m comment --comment "$rule_tag" -j ACCEPT
	done
}

# --- bgp get / set ---

# Mật khẩu không bao giờ được trả ra, chỉ password_set.
bgp_peer_json() {
	printf '{"address":%s' "$(json_string "$bgp_peer_address")"
	for entry in $bgp_peer_options; do
		option=${entry%%:*}
		case "$option" in
			enabled) printf ',"enabled":%s' "$(json_bool "$bgp_peer_enabled")" ;;
			password) if [ -n "$bgp_peer_password" ]; then printf ',"password_set":true'; else printf ',"password_set":false'; fi ;;
			*) printf ',"%s":%s' "$option" "$(json_string "$(bgp_peer_get "$option")")" ;;
		esac
	done
	printf '}\n'
}

bgp_get() {
	networks=$(uci_list bmcDynRouting.bgp.network | json_strings)
	peers=$(for section in $(bgp_peer_sections); do bgp_peer_load "$section"; bgp_peer_json; done | json_array)
	advanced_lines=$(uci_list bmcDynRouting.bgp.advanced_line | json_strings)
	subnets=$(router_subnets)
	warnings=$(for section in $(bgp_peer_sections); do bgp_peer_load "$section"; bgp_peer_warnings "$subnets"; done | json_array)
	flags=$(for entry in $bgp_flag_options; do
		printf ',"%s":%s' "${entry%%:*}" "$(json_bool "$(bgp_flag_get "${entry%%:*}")")"
	done)
	reply 0 'BGP configuration' ",\"enabled\":$(json_bool "$bgp_enabled"),\"local_as\":$(json_string "$bgp_local_as")$flags,\"networks\":$networks,\"peers\":$peers,\"advanced_lines\":$advanced_lines,\"warnings\":$warnings"
}

# Trả lời lỗi "field message" ($1) của Peer BGP $2.
bgp_peer_fail() {
	fail "${1%% *}" "${1#* }" ",\"peer\":$(json_string "$2")"
}

# Kiểm tra dòng Peer BGP đang mở trong bgp set (trừ so với AS cục bộ, chưa biết hết lúc này), đưa nó vào batch
# và gom cảnh báo. Trả về 1 khi đã reply lỗi.
bgp_close_peer() {
	[ -n "$bgp_peer_address" ] || return 0
	if [ "$bgp_peer_keep_password" = 1 ]; then
		if [ -n "$bgp_peer_password" ]; then
			fail password "use either --password or --keep-password for peer $bgp_peer_address" ",\"peer\":$(json_string "$bgp_peer_address")"
			return 1
		fi
		stored=$(uci_find_section bmcDynRouting bgp_peer address "$bgp_peer_address")
		if [ -n "$stored" ]; then bgp_peer_password=$(uci_get "bmcDynRouting.$stored.password"); fi
	fi
	error=$(bgp_peer_error)
	if [ -n "$error" ]; then
		bgp_peer_fail "$error" "$bgp_peer_address"
		return 1
	fi
	section=$(bgp_peer_section_name "$bgp_peer_address")
	batch_add "set bmcDynRouting.$section=bgp_peer"
	batch_add "set bmcDynRouting.$section.address=$(uci_quote "$bgp_peer_address")"
	for entry in $bgp_peer_options; do
		value=$(bgp_peer_get "${entry%%:*}")
		if [ -n "$value" ]; then batch_add "set bmcDynRouting.$section.${entry%%:*}=$(uci_quote "$value")"; fi
	done
	listed_remote_as="$listed_remote_as$bgp_peer_address $bgp_peer_remote_as
"
	set_warnings="$set_warnings$(bgp_peer_warnings "$subnets")
"
	bgp_peer_address=
}

bgp_open_peer() {
	if ! ipv4_valid "$1"; then
		fail peers "peer address $1 must be a valid IPv4 address" ",\"peer\":$(json_string "$1")"
		return 1
	fi
	case "$listed_peers" in
		*" $1 "*) fail peers "peer $1 is listed more than once" ",\"peer\":$(json_string "$1")"; return 1 ;;
	esac
	listed_peers="$listed_peers$1 "
	bgp_peer_reset "$1"
	bgp_peer_keep_password=0
}

bgp_set() {
	batch_reset
	batch_add_bgp_section
	if [ "$#" -eq 2 ] && [ "$1" = --enabled ] && [ "$2" = 0 ]; then
		batch_add "set bmcDynRouting.bgp.enabled='0'"
		save_and_apply 'BGP disabled' ''
		return
	fi
	for entry in $bgp_flag_options; do eval "new_${entry%%:*}=0"; done
	new_enabled= new_local_as= listed_peers=' ' listed_networks=' ' listed_remote_as= bgp_peer_address= set_warnings=
	subnets=$(router_subnets)
	# Ghi đè toàn bộ: bỏ mọi Peer BGP, Mạng quảng bá BGP và Dòng lệnh nâng cao cũ, rồi dựng lại từ tham số.
	for section in $(bgp_peer_sections); do batch_add "delete bmcDynRouting.$section"; done
	for list in network advanced_line; do
		if [ -n "$(uci_list "bmcDynRouting.bgp.$list")" ]; then batch_add "delete bmcDynRouting.bgp.$list"; fi
	done
	while [ "$#" -gt 0 ]; do
		# --keep-password là cờ không có giá trị.
		if [ "$1" = --keep-password ]; then
			if [ -z "$bgp_peer_address" ]; then fail peers "$1 must follow --peer"; return; fi
			bgp_peer_keep_password=1
			shift
			continue
		fi
		if [ "$#" -lt 2 ]; then
			reply -1 "option $1 requires a value"
			return
		fi
		option=$(bgp_peer_option_for_flag "$1")
		case "$1" in
			--enabled) new_enabled=$2 ;;
			--local-as) new_local_as=$2 ;;
			--network)
				error=$(bgp_network_error "$2")
				if [ -n "$error" ]; then fail networks "$error"; return; fi
				case "$listed_networks" in
					*" $2 "*) fail networks "network $2 is listed more than once"; return ;;
				esac
				listed_networks="$listed_networks$2 "
				batch_add "add_list bmcDynRouting.bgp.network=$(uci_quote "$2")"
				;;
			--advanced-line)
				error=$(advanced_line_error "$2")
				if [ -n "$error" ]; then fail advanced_lines "$error"; return; fi
				batch_add "add_list bmcDynRouting.bgp.advanced_line=$(uci_quote "$2")"
				;;
			--peer)
				bgp_close_peer || return 0
				bgp_open_peer "$2" || return 0
				;;
			*)
				redistribute_option=$(bgp_option_for_redistribute_flag "$1")
				if [ -n "$redistribute_option" ]; then
					eval "new_$redistribute_option=\$2"
					shift 2
					continue
				fi
				if [ -z "$option" ]; then reply -1 "unknown BGP option: $1"; return; fi
				if [ -z "$bgp_peer_address" ]; then fail peers "$1 must follow --peer"; return; fi
				bgp_peer_set "$option" "$2"
				;;
		esac
		shift 2
	done
	bgp_close_peer || return 0
	case "$new_enabled" in
		0|1) ;;
		*) fail enabled '--enabled must be 0 or 1'; return ;;
	esac
	for entry in $bgp_flag_options; do
		case "$(bgp_new_get "${entry%%:*}")" in
			0|1) ;;
			*) fail redistribute 'redistribute options must be 0 or 1'; return ;;
		esac
	done
	# AS cục bộ có thể để trống khi BGP tắt.
	if [ "$new_enabled" = 1 ] || [ -n "$new_local_as" ]; then
		error=$(local_as_error "$new_local_as")
		if [ -n "$error" ]; then fail local_as "$error"; return; fi
	fi
	address=$(printf '%s' "$listed_remote_as" | awk -v as="$new_local_as" '$2 == as { print $1; exit }')
	if [ -n "$address" ]; then
		fail remote_as "$(bgp_same_as_error "$address" "$new_local_as")" ",\"peer\":$(json_string "$address")"
		return
	fi
	if [ "$new_enabled" = 1 ]; then
		error=$(router_id_error)
		if [ -n "$error" ]; then fail router_id "$error"; return; fi
	fi
	if [ -n "$new_local_as" ]; then
		batch_add "set bmcDynRouting.bgp.local_as=$(uci_quote "$new_local_as")"
	elif uci_has bmcDynRouting.bgp.local_as; then
		batch_add 'delete bmcDynRouting.bgp.local_as'
	fi
	batch_add "set bmcDynRouting.bgp.enabled='$new_enabled'"
	for entry in $bgp_flag_options; do
		batch_add "set bmcDynRouting.bgp.${entry%%:*}='$(bgp_new_get "${entry%%:*}")'"
	done
	save_and_apply 'BGP configuration saved' ",\"warnings\":$(printf '%s' "$set_warnings" | json_array)"
}
