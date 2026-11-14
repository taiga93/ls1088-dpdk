# Phần dùng chung của các Cấu hình giao thức (OSPF, RIP, BGP): số của FRR, Dòng lệnh nâng cao, cảnh báo interface.

# Số nguyên dương có tối đa 5 chữ số, trong khoảng $2..$3 (mặc định 1..65535).
frr_number_valid() {
	case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
	[ "${#1}" -le 5 ] && [ "$1" -ge "${2:-1}" ] && [ "$1" -le "${3:-65535}" ]
}

# Số nguyên không dấu 32-bit khác 0 (AS, giới hạn prefix của BGP), như FRR.
u32_valid() {
	case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
	[ "${#1}" -le 10 ] && awk -v n="$1" 'BEGIN { exit n + 0 <= 4294967295 ? 0 : 1 }'
}

# --- Cross redistribution of BGP routes (ADR-0008) ---

# Tag set on every BGP route redistributed into OSPF or RIP. OSPF carries it in the external LSA and RIPv2 in
# the route tag (16 bits), so it survives the trip to another BMC router of the same IGP domain, and every
# OSPF/RIP -> BGP redistribution denies it: a route learned from one Peer BGP never reaches another one.
bgp_igp_tag=64512
bgp_to_ospf_route_map=BMC-BGP-TO-OSPF
bgp_to_rip_route_map=BMC-BGP-TO-RIP

# "redistribute bgp" line of the IGP router block (route-map $1) and, after that block, the route-map that tags
# the routes; both go in the part of the IGP daemon.
bgp_into_igp_redistribute() {
	printf ' redistribute bgp route-map %s\n' "$1"
}

bgp_into_igp_route_map() {
	printf 'route-map %s permit 10\n set tag %s\nexit\n!\n' "$1" "$bgp_igp_tag"
}

# Warning shown while protocol $1 (OSPF|RIP) redistributes BGP ($2 = 1).
redistribute_bgp_warning() {
	[ "$2" = 1 ] || return 0
	printf '{"code":"redistribute_bgp_into_igp","message":%s}\n' \
		"$(json_string "$1 redistributes BGP: every route accepted from a Peer BGP (up to its maximum prefix count) is injected into $1 and advertised to every $1 router.")"
}

advanced_line_error() {
	case "$1" in
		'') printf 'advanced command lines must not be empty' ;;
		*[[:cntrl:]]*) printf 'advanced command lines must not contain control characters' ;;
	esac
}

# Dòng lệnh nâng cao của giao thức $1 (section UCI), nối ở cuối frr.conf; không in gì khi không có dòng nào.
advanced_config() {
	if [ -n "$(uci_list "bmcDynRouting.$1.advanced_line")" ]; then
		uci_list "bmcDynRouting.$1.advanced_line"
		printf '!\n'
	fi
}

# --- Cảnh báo cấu hình (không chặn việc lưu) ---

warning() {
	printf '{"interface":%s,"code":"%s","message":%s}\n' "$(json_string "$1")" "$2" "$(json_string "$3")"
}

# In các cảnh báo của interface $2 thuộc giao thức $1 (OSPF|RIP), passive = $3, mỗi dòng một object JSON.
interface_warnings() {
	case "$1" in
		OSPF) working='the adjacency is up' ;;
		*) working='routes are exchanged' ;;
	esac
	zone=$(uci_find_section --list firewall zone network "$2")
	if [ -n "$zone" ]; then
		zone_name=$(uci_get "firewall.$zone.name")
		if [ "$(uci_get "firewall.$zone.masq")" = 1 ]; then
			warning "$2" zone_masquerade "Interface $1 $2 is in zone $zone_name, which masquerades: LAN-to-LAN traffic through it will be NATed."
		fi
		case "$(uci_get "firewall.$zone.forward")" in
			REJECT|DROP) warning "$2" zone_forward_blocked "Interface $1 $2 is in zone $zone_name, which blocks forwarding: LAN-to-LAN traffic through it will be dropped even when $working." ;;
		esac
	fi
	if [ "$3" != 1 ]; then
		dhcp=$(uci_find_section dhcp dhcp interface "$2")
		if [ -n "$dhcp" ] && [ "$(uci_get "dhcp.$dhcp.ignore")" != 1 ]; then
			warning "$2" dhcp_on_active_interface "Interface $1 $2 is not passive but runs a DHCP server."
		fi
	fi
}
