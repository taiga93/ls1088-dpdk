# WANs, bridges and ports of /etc/config/network, read from the UCI snapshot.
#
# The WANs of Multi-WAN are the existing `wan` plus the interfaces added by `bmcmultiwan wan add`, marked
# `option bmc_role 'multiwan'` (like Link định tuyến of bmcDynRouting are marked 'dynrouting_link').

wan_original=wan
wan_max=4

interface_device() {
	device=$(uci_get "network.$1.device")
	[ -n "$device" ] || device=$(uci_get "network.$1.ifname")
	printf '%s' "$device"
}

# Static address of interface $1 as ip/prefix, from a CIDR ipaddr or ipaddr + netmask; nothing if none.
interface_cidr() {
	cidr=$(uci_list "network.$1.ipaddr" | head -n 1)
	case "$cidr" in
		'') return 0 ;;
		*/*) ;;
		*) cidr="$cidr/$(ipv4_mask_to_prefix "$(uci_get "network.$1.netmask")")" ;;
	esac
	if ipv4_valid "${cidr%/*}" && [ -n "${cidr#*/}" ]; then printf '%s' "$cidr"; fi
}

is_added_wan() {
	[ "$(uci_get "network.$1")" = interface ] && [ "$(uci_get "network.$1.bmc_role")" = multiwan ]
}

is_wan() {
	if [ "$1" = "$wan_original" ]; then
		[ "$(uci_get "network.$1")" = interface ]
	else
		is_added_wan "$1"
	fi
}

# WANs in configuration order, `wan` first.
wan_sections() {
	if is_wan "$wan_original"; then echo "$wan_original"; fi
	for section in $(uci_sections network interface); do
		if is_added_wan "$section"; then echo "$section"; fi
	done
}

bridge_section() {
	uci_find_section network device name "$1"
}

# Name of the bridge holding port $1, or nothing.
bridge_of_port() {
	section=$(uci_find_section --list network device ports "$1")
	if [ -n "$section" ]; then uci_get "network.$section.name"; fi
}

# Interface (other than a bridge member) whose device is port $1, or nothing.
interface_of_port() {
	for section in $(uci_sections network interface); do
		if [ "$(interface_device "$section")" = "$1" ]; then
			printf '%s' "$section"
			return 0
		fi
	done
}

is_heartbeat_port() {
	[ "$1" = "$(uci_get bmcHA.cluster.heartbeat_port)" ] || [ "$1" = "$(uci_get bmcHA.cluster.heartbeat_port_backup)" ]
}

# Firewall zone (section name) named $1.
firewall_zone() {
	uci_find_section firewall zone name "$1"
}
