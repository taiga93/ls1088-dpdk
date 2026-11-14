# Interface logic, bridge và Link định tuyến, đọc từ snapshot UCI.

is_network_interface() {
	[ "$(uci_get "network.$1")" = interface ]
}

interface_device() {
	device=$(uci_get "network.$1.device")
	[ -n "$device" ] || device=$(uci_get "network.$1.ifname")
	printf '%s' "$device"
}

# Địa chỉ tĩnh của interface dạng ip/prefix, từ ipaddr CIDR hoặc ipaddr + netmask; không in gì nếu không có.
interface_cidr() {
	cidr=$(uci_list "network.$1.ipaddr" | head -n 1)
	case "$cidr" in
		*/*) ;;
		*) cidr="$cidr/$(ipv4_mask_to_prefix "$(uci_get "network.$1.netmask")")" ;;
	esac
	if ipv4_valid "${cidr%/*}" && ipv4_prefix_valid "${cidr#*/}"; then printf '%s' "$cidr"; fi
}

# Địa chỉ IPv4 đang gán thật trên thiết bị ("device ip/prefix" mỗi dòng), gồm cả địa chỉ lấy qua DHCP.
# Test đưa vào qua BMCDYNROUTING_ADDRESSES (định dạng `ip -4 -o addr show`); chạy trên snapshot thì bỏ qua.
runtime_addresses() {
	if [ -n "${BMCDYNROUTING_ADDRESSES:-}" ]; then
		awk '$3 == "inet" && $2 != "lo" { print $2, $4 }' "$BMCDYNROUTING_ADDRESSES"
	elif [ -z "${BMCDYNROUTING_SNAPSHOT:-}" ]; then
		ip -4 -o addr show 2>/dev/null | awk '$3 == "inet" && $2 != "lo" { print $2, $4 }'
	fi
}

# Các mạng đã có trên router, mỗi dòng "cidr nơi-dùng": địa chỉ tĩnh trong UCI và địa chỉ đang chạy
# (vd. WAN lấy qua DHCP).
known_subnets() {
	for section in $(uci_sections network interface); do
		cidr=$(interface_cidr "$section")
		if [ -n "$cidr" ]; then printf '%s interface %s\n' "$cidr" "$section"; fi
	done
	runtime_addresses | while read -r device cidr; do printf '%s device %s\n' "$cidr" "$device"; done
}

is_link() {
	[ "$(uci_get "network.$1.bmc_role")" = dynrouting_link ]
}

link_sections() {
	for section in $(uci_sections network interface); do
		if is_link "$section"; then printf '%s\n' "$section"; fi
	done
}

link_for_port() {
	for section in $(link_sections); do
		if [ "$(interface_device "$section")" = "$1" ]; then
			printf '%s' "$section"
			return 0
		fi
	done
}

# Tên section UCI chỉ nhận [A-Za-z0-9_], nên cổng kiểu DSA như lan-4 thành link_lan_4.
link_name_for_port() {
	printf 'link_%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_')"
}

bridge_section() {
	uci_find_section network device name "$1"
}

# Tên bridge đang chứa cổng $1, hoặc không in gì.
bridge_of_port() {
	section=$(uci_find_section --list network device ports "$1")
	if [ -n "$section" ]; then uci_get "network.$section.name"; fi
}

dynrouting_zone() {
	uci_find_section firewall zone name dynrouting
}
