# Link định tuyến (ADR-0002, ADR-0003) và danh sách interface logic cho web UI.

interface_list() {
	interfaces=$(for section in $(uci_sections network interface); do
		device=$(interface_device "$section")
		[ "$device" != lo ] || continue
		link=0
		if is_link "$section"; then link=1; fi
		printf '{"name":%s,"device":%s,"link":%s}\n' "$(json_string "$section")" "$(json_string "$device")" "$(json_bool "$link")"
	done | json_array)
	reply 0 'Network interfaces' ",\"interfaces\":$interfaces"
}

link_list() {
	links=$(for section in $(link_sections); do
		cidr=$(interface_cidr "$section")
		printf '{"name":%s,"port":%s,"ip":%s,"prefix":%s}\n' "$(json_string "$section")" \
			"$(json_string "$(interface_device "$section")")" "$(json_string "${cidr%/*}")" "$(json_string "${cidr#*/}")"
	done | json_array)
	reply 0 'Link định tuyến list' ",\"links\":$links"
}

commit_link_batch() {
	plan_or_commit "$1" '' network dhcp firewall || return 0
	run_quietly /etc/init.d/network reload
	run_quietly /etc/init.d/dnsmasq reload
	run_quietly /etc/init.d/firewall reload
	reply 0 "$1"
}

# Zone dynrouting: không NAT, không mở quản trị cho láng giềng; gói định tuyến vào qua rule do firewall_sync chèn.
add_zone_to_batch() {
	batch_add "set firewall.dynrouting=zone"
	batch_add "set firewall.dynrouting.name='dynrouting'"
	batch_add "set firewall.dynrouting.input='REJECT'"
	batch_add "set firewall.dynrouting.output='ACCEPT'"
	batch_add "set firewall.dynrouting.forward='ACCEPT'"
	batch_add "set firewall.dynrouting_lan_in=forwarding"
	batch_add "set firewall.dynrouting_lan_in.src='lan'"
	batch_add "set firewall.dynrouting_lan_in.dest='dynrouting'"
	batch_add "set firewall.dynrouting_lan_out=forwarding"
	batch_add "set firewall.dynrouting_lan_out.src='dynrouting'"
	batch_add "set firewall.dynrouting_lan_out.dest='lan'"
	batch_add "set firewall.dynrouting_icmp=rule"
	batch_add "set firewall.dynrouting_icmp.name='Allow-DynRouting-ICMP'"
	batch_add "set firewall.dynrouting_icmp.src='dynrouting'"
	batch_add "set firewall.dynrouting_icmp.proto='icmp'"
	batch_add "set firewall.dynrouting_icmp.target='ACCEPT'"
}

# Ngược với add_zone_to_batch: link del của link cuối cùng gỡ đúng những gì link add đầu tiên đã tạo.
# Rule người vận hành tự thêm cho zone này được giữ nguyên (fw3 bỏ qua rule trỏ tới zone không còn).
remove_zone_from_batch() {
	batch_add "delete firewall.$1"
	for section in dynrouting_lan_in dynrouting_lan_out dynrouting_icmp; do
		if [ -n "$(uci_get "firewall.$section")" ]; then batch_add "delete firewall.$section"; fi
	done
}

# In lỗi đầu tiên khiến cổng $1 không dùng được cho Link định tuyến; không in gì nếu dùng được.
port_error() {
	case "$1" in
		*.*) printf 'port %s is a VLAN sub-interface: a Link định tuyến needs a physical port' "$1"; return 0 ;;
	esac
	if [ "$1" = "$(interface_device wan)" ] || [ "$1" = "$(interface_device wan6)" ]; then
		printf 'port %s is the WAN port and cannot be used for a Link định tuyến' "$1"
	elif [ -n "$(link_for_port "$1")" ]; then
		printf 'port %s is already a Link định tuyến' "$1"
	else
		bridge=$(bridge_of_port "$1")
		case "$bridge" in
			br-lan) ;;
			'') printf 'port %s is not a port of br-lan: only free LAN ports can become a Link định tuyến' "$1" ;;
			*) printf 'port %s already belongs to Extra LAN bridge %s' "$1" "$bridge" ;;
		esac
	fi
}


# In lỗi nếu $1 (ip/prefix) chồng lên một mạng đã có.
overlap_error() {
	known_subnets | while read -r cidr owner; do
		if ipv4_subnets_overlap "${1%/*}" "${1#*/}" "${cidr%/*}" "${cidr#*/}"; then
			printf 'IP/prefix overlaps with %s on %s' "$cidr" "$owner"
			break
		fi
	done
}

# Cổng của br-lan dùng được cho một Link định tuyến mới, để UI chỉ đưa ra lựa chọn mà link add nhận.
link_available_ports() {
	ports=$(for port in $(uci_list "network.$(bridge_section br-lan).ports"); do
		if [ -z "$(port_error "$port")" ]; then json_string "$port"; echo; fi
	done | json_array)
	reply 0 'Ports available for a Link định tuyến' ",\"ports\":$ports"
}

link_add() {
	if [ "$#" -ne 2 ]; then
		reply -1 'usage: link add <port> <ip/prefix>'
		return
	fi
	port=$1 cidr=$2
	lan_bridge=$(bridge_section br-lan)
	if [ -z "$lan_bridge" ]; then
		reply -1 'br-lan bridge not found'
		return
	fi
	error=$(port_error "$port")
	if [ -n "$error" ]; then
		fail port "$error"
		return
	fi
	link_ip=${cidr%/*} link_prefix=${cidr#*/}
	if [ "$link_ip" = "$cidr" ] || ! ipv4_valid "$link_ip" || ! ipv4_prefix_valid "$link_prefix"; then
		fail cidr 'IP/prefix is invalid'
		return
	fi
	error=$(overlap_error "$cidr")
	if [ -n "$error" ]; then
		fail cidr "$error"
		return
	fi
	name=$(link_name_for_port "$port")
	if [ -n "$(uci_get "network.$name")" ]; then
		fail port "network section $name already exists"
		return
	fi
	batch_reset
	batch_add "del_list network.$lan_bridge.ports=$(uci_quote "$port")"
	batch_add "set network.$name=interface"
	batch_add "set network.$name.device=$(uci_quote "$port")"
	batch_add "set network.$name.proto='static'"
	batch_add "set network.$name.ipaddr='$link_ip'"
	batch_add "set network.$name.netmask='$(ipv4_prefix_to_mask "$link_prefix")'"
	batch_add "set network.$name.bmc_role='dynrouting_link'"
	batch_add "set dhcp.$name=dhcp"
	batch_add "set dhcp.$name.interface='$name'"
	batch_add "set dhcp.$name.ignore='1'"
	zone=$(dynrouting_zone)
	if [ -z "$zone" ]; then
		add_zone_to_batch
		zone=dynrouting
	fi
	batch_add "add_list firewall.$zone.network='$name'"
	commit_link_batch 'Link định tuyến created'
}

link_del() {
	if [ "$#" -ne 1 ]; then
		reply -1 'usage: link del <port>'
		return
	fi
	port=$1
	name=$(link_for_port "$port")
	if [ -z "$name" ]; then
		reply -1 "no such Link định tuyến on port $port"
		return
	fi
	if is_ospf_interface "$name"; then
		reply -1 "cannot delete Link định tuyến on port $port: it is still an Interface OSPF, remove it from OSPF first"
		return
	fi
	if is_rip_interface "$name"; then
		reply -1 "cannot delete Link định tuyến on port $port: it is still an Interface RIP, remove it from RIP first"
		return
	fi
	batch_reset
	batch_add "delete network.$name"
	dhcp=$(uci_find_section dhcp dhcp interface "$name")
	if [ -n "$dhcp" ]; then batch_add "delete dhcp.$dhcp"; fi
	lan_bridge=$(bridge_section br-lan)
	if [ -n "$lan_bridge" ]; then batch_add "add_list network.$lan_bridge.ports=$(uci_quote "$port")"; fi
	zone=$(dynrouting_zone)
	if [ -n "$zone" ]; then
		if [ "$(link_sections | awk 'END { print NR }')" -le 1 ]; then
			remove_zone_from_batch "$zone"
		else
			batch_add "del_list firewall.$zone.network='$name'"
		fi
	fi
	commit_link_batch 'Link định tuyến deleted'
}
