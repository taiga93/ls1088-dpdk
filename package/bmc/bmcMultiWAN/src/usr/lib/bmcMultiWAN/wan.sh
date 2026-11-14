# `wan list|add|set|del`: the WANs of Multi-WAN.
#
# A WAN is an interface of /etc/config/network (source of truth for its port and protocol), a member of the
# firewall zone `wan` (masquerade) and an interface of /etc/config/mwan3 (its Internet check). `wan add`
# puts a new WAN last in the default Chính sách WAN, as its WAN dự phòng.

wan_json() {
	proto=$(uci_get "network.$1.proto")
	printf '{"name":%s,"port":%s,"proto":%s' "$(json_string "$1")" "$(json_string "$(interface_device "$1")")" \
		"$(json_string "$proto")"
	case "$proto" in
		static)
			# ipaddr may be written as ip/prefix (the WAN page of the web UI does): always split it.
			cidr=$(interface_cidr "$1") netmask=
			[ -z "$cidr" ] || netmask=$(ipv4_prefix_to_mask "${cidr#*/}")
			printf ',"ipaddr":%s,"netmask":%s,"gateway":%s,"dns":%s' \
				"$(json_string "${cidr%/*}")" "$(json_string "$netmask")" \
				"$(json_string "$(uci_get "network.$1.gateway")")" "$(uci_list "network.$1.dns" | json_strings)"
			;;
		pppoe)
			# The password is never returned.
			printf ',"username":%s' "$(json_string "$(uci_get "network.$1.username")")"
			;;
	esac
	removable=1
	[ "$1" != "$wan_original" ] || removable=0
	printf ',"removable":%s,"track_ip":%s,"down":%s,"up":%s}\n' "$(json_bool "$removable")" \
		"$(uci_list "mwan3.$1.track_ip" | json_strings)" "$(json_number_or_null "$(uci_get "mwan3.$1.down")")" \
		"$(json_number_or_null "$(uci_get "mwan3.$1.up")")"
}

wan_list() {
	wans=$(for wan in $(wan_sections); do wan_json "$wan"; done | json_array)
	reply 0 'WAN list' ",\"wans\":$wans"
}

wan_usage() {
	reply -1 'usage: wan list, wan add --name N --port P --proto dhcp|static|pppoe [--ipaddr IP --netmask MASK --gateway IP [--dns IP]...] [--username U --password P], wan set --name N [--track-ip IP]... [--down 1-10] [--up 1-10], wan del --name N'
}

# Prints why $1 cannot be the name of a new WAN; nothing when it can. PPPoE names its device pppoe-<name>,
# which must fit the 15 characters of a Linux interface name.
wan_name_error() {
	case "$1" in
		[[:lower:]]*) ;;
		*) printf 'name must start with a lowercase letter'; return 0 ;;
	esac
	case "$1" in
		*[![:lower:][:digit:]_]*) printf 'name may only contain lowercase letters, digits and _'; return 0 ;;
	esac
	if [ "${#1}" -gt 9 ]; then
		printf 'name must be at most 9 characters'
	elif [ -n "$(uci_get "network.$1")" ]; then
		printf 'name %s is already used in /etc/config/network' "$1"
	elif [ -n "$(uci_get "mwan3.$1")" ]; then
		printf 'name %s is already used in /etc/config/mwan3' "$1"
	fi
}

# Prints why port $1 cannot carry a new WAN; nothing when it can. A port of br-lan can: `wan add` takes it out
# of br-lan and `wan del` gives it back, like a Link định tuyến.
wan_port_error() {
	case "$1" in
		*[![:alnum:]._-]*) printf 'port %s is not a valid port name' "$1"; return 0 ;;
	esac
	if is_heartbeat_port "$1"; then
		printf 'port %s is a Cổng heartbeat of HA' "$1"
		return 0
	fi
	owner=$(interface_of_port "$1")
	if [ -n "$owner" ]; then
		if is_wan "$owner" || [ "$owner" = wan6 ]; then
			printf 'port %s is already WAN %s' "$1" "$owner"
		elif [ "$(uci_get "network.$owner.bmc_role")" = dynrouting_link ]; then
			printf 'port %s is a Link định tuyến (%s)' "$1" "$owner"
		else
			printf 'port %s is already used by interface %s' "$1" "$owner"
		fi
		return 0
	fi
	bridge=$(bridge_of_port "$1")
	case "$bridge" in
		'') ;;
		br-lan)
			if [ "$(uci_list "network.$(bridge_section br-lan).ports" | awk 'END { print NR }')" -le 1 ]; then
				printf 'port %s is the last port of br-lan' "$1"
			fi
			;;
		*) printf 'port %s belongs to Extra LAN bridge %s' "$1" "$bridge" ;;
	esac
}

# Prints why the static address $1/$2 with gateway $3 is wrong, as "field message"; nothing when it is right.
wan_static_error() {
	if ! ipv4_valid "$1"; then
		echo 'ipaddr ipaddr must be an IPv4 address'
		return 0
	fi
	prefix=$(ipv4_mask_to_prefix "$2")
	if [ -z "$prefix" ] || [ "$prefix" -lt 1 ] || [ "$prefix" -gt 30 ]; then
		echo 'netmask netmask must be a contiguous IPv4 netmask from 128.0.0.0 to 255.255.255.252'
		return 0
	fi
	if ! ipv4_valid "$3"; then
		echo 'gateway gateway must be an IPv4 address'
		return 0
	fi
	if [ "$3" = "$1" ] || ! ipv4_subnets_overlap "$3" 32 "$1" "$prefix"; then
		echo "gateway gateway must be another address of $(ipv4_network "$1" "$prefix")/$prefix"
		return 0
	fi
	for section in $(uci_sections network interface); do
		cidr=$(interface_cidr "$section")
		[ -n "$cidr" ] || continue
		if ipv4_subnets_overlap "$1" "$prefix" "${cidr%/*}" "${cidr#*/}"; then
			echo "ipaddr ipaddr/netmask overlaps with $(ipv4_network "${cidr%/*}" "${cidr#*/}")/${cidr#*/} of interface $section"
			return 0
		fi
	done
}

# Routing metric of a new WAN: the smallest multiple of 10 no other WAN uses (`wan` usually has none, i.e. 0),
# so that the default routes of the WANs never tie in the main table.
wan_next_metric() {
	for wan in $(wan_sections); do
		metric=$(uci_get "network.$wan.metric")
		echo "${metric:-0}"
	done | awk '{ used[$1 + 0] = 1 } END { for (m = 10; m in used; m += 10); print m }'
}

# Metric of the member that puts a new WAN last in the default Chính sách WAN.
wan_next_policy_metric() {
	for member in $(uci_list "mwan3.$mwan3_default_policy.use_member"); do
		uci_get "mwan3.$member.metric"
		echo
	done | awk 'NF && $1 + 0 > max { max = $1 + 0 } END { print max + 1 }'
}

wan_add() {
	name= port= proto= ipaddr= netmask= gateway= dns= username= password=
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--name|--port|--proto|--ipaddr|--netmask|--gateway|--dns|--username|--password)
				field=${1#--}
				if [ "$#" -lt 2 ]; then
					fail "$field" "option $1 requires a value"
					return
				fi
				case "$2" in
					*"$newline"*) fail "$field" "option $1 must not contain a newline"; return ;;
				esac
				if [ "$field" = dns ]; then
					dns="$dns$2$newline"
				else
					eval "$field=\$2"
				fi
				shift 2
				;;
			*)
				reply -1 "unknown option $1"
				return
				;;
		esac
	done
	if [ "$(wan_sections | awk 'END { print NR }')" -ge "$wan_max" ]; then
		fail name "Multi-WAN supports at most $wan_max WANs"
		return
	fi
	if [ -z "$name" ]; then
		fail name 'option --name is required'
		return
	fi
	error=$(wan_name_error "$name")
	if [ -n "$error" ]; then
		fail name "$error"
		return
	fi
	if [ -z "$port" ]; then
		fail port 'option --port is required'
		return
	fi
	error=$(wan_port_error "$port")
	if [ -n "$error" ]; then
		fail port "$error"
		return
	fi
	case "$proto" in
		dhcp|static|pppoe) ;;
		'') fail proto 'option --proto is required'; return ;;
		*) fail proto 'proto must be dhcp, static or pppoe'; return ;;
	esac
	for field in ipaddr netmask gateway dns username password; do
		case "$field" in
			username|password) [ "$proto" != pppoe ] || continue; need=pppoe ;;
			*) [ "$proto" != static ] || continue; need=static ;;
		esac
		if [ -n "$(value_of "$field")" ]; then
			fail "$field" "option --$field is only valid with --proto $need"
			return
		fi
	done
	case "$proto" in
		static)
			for field in ipaddr netmask gateway; do
				if [ -z "$(value_of "$field")" ]; then
					fail "$field" "option --$field is required with --proto static"
					return
				fi
			done
			error=$(wan_static_error "$ipaddr" "$netmask" "$gateway")
			if [ -n "$error" ]; then
				fail "${error%% *}" "${error#* }"
				return
			fi
			invalid=$(first_invalid_ipv4 "$dns")
			if [ -n "$invalid" ]; then
				fail dns "dns $invalid is not an IPv4 address"
				return
			fi
			;;
		pppoe)
			for field in username password; do
				if [ -z "$(value_of "$field")" ]; then
					fail "$field" "option --$field is required with --proto pppoe"
					return
				fi
			done
			;;
	esac
	zone=$(firewall_zone wan)
	if [ -z "$zone" ]; then
		reply -1 'firewall zone wan not found'
		return
	fi
	batch_reset
	from_lan=0
	if [ "$(bridge_of_port "$port")" = br-lan ]; then
		from_lan=1
		batch_add "del_list network.$(bridge_section br-lan).ports=$(uci_quote "$port")"
	fi
	batch_add "set network.$name=interface"
	batch_add "set network.$name.device=$(uci_quote "$port")"
	batch_add "set network.$name.proto='$proto'"
	case "$proto" in
		static)
			batch_add "set network.$name.ipaddr='$ipaddr'"
			batch_add "set network.$name.netmask='$netmask'"
			batch_add "set network.$name.gateway='$gateway'"
			for server in $dns; do
				batch_add "add_list network.$name.dns='$server'"
			done
			;;
		pppoe)
			batch_add "set network.$name.username=$(uci_quote "$username")"
			# A dry-run plan may be logged: it never shows the password.
			if [ "$dry_run" = 1 ]; then shown_password='<hidden>'; else shown_password=$password; fi
			batch_add "set network.$name.password=$(uci_quote "$shown_password")"
			# IPv4 only: no DHCPv6 over the PPPoE session.
			batch_add "set network.$name.ipv6='0'"
			;;
	esac
	batch_add "set network.$name.metric='$(wan_next_metric)'"
	batch_add "set network.$name.bmc_role='multiwan'"
	# Remembers that the port came from br-lan, so that `wan del` gives it back.
	if [ "$from_lan" = 1 ]; then batch_add "set network.$name.bmc_from_lan='1'"; fi
	batch_add "add_list firewall.$zone.network='$name'"
	mwan3_batch_wan "$name"
	if [ "$(uci_get "mwan3.$mwan3_default_policy")" = policy ]; then
		metric=$(wan_next_policy_metric)
		mwan3_batch_member "$name" "$metric"
		batch_add "add_list mwan3.$mwan3_default_policy.use_member='$(mwan3_member "$name" "$metric")'"
	fi
	change_plan_commands network firewall
	change_commit "WAN $name added" network firewall mwan3
}

wan_set() {
	name= track_ips= down= up= changes=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--name|--track-ip|--down|--up)
				field=$(printf '%s' "${1#--}" | tr - _)
				if [ "$#" -lt 2 ]; then
					fail "$field" "option $1 requires a value"
					return
				fi
				case "$field" in
					name) name=$2 ;;
					track_ip) track_ips="$track_ips$2$newline"; changes=1 ;;
					down) down=$2; changes=1 ;;
					up) up=$2; changes=1 ;;
				esac
				shift 2
				;;
			*)
				reply -1 "unknown option $1"
				return
				;;
		esac
	done
	if [ -z "$name" ]; then
		fail name 'option --name is required'
		return
	fi
	if ! is_wan "$name" || [ "$(uci_get "mwan3.$name")" != interface ]; then
		fail name "no such WAN: $name"
		return
	fi
	if [ "$changes" = 0 ]; then
		reply -1 'usage: wan set --name N [--track-ip IP]... [--down 1-10] [--up 1-10]'
		return
	fi
	if [ -n "$track_ips" ]; then
		if [ "$(printf '%s' "$track_ips" | awk 'END { print NR }')" -gt 4 ]; then
			fail track_ip 'at most 4 ping targets (--track-ip)'
			return
		fi
		invalid=$(first_invalid_ipv4 "$track_ips")
		if [ -n "$invalid" ]; then
			fail track_ip "ping target $invalid is not an IPv4 address"
			return
		fi
		duplicate=$(printf '%s' "$track_ips" | sort | uniq -d | head -n 1)
		if [ -n "$duplicate" ]; then
			fail track_ip "ping target $duplicate is given twice"
			return
		fi
	fi
	for field in down up; do
		value=$(value_of "$field")
		[ -n "$value" ] || continue
		case "$value" in
			''|*[!0-9]*) ;;
			*) [ "${#value}" -gt 2 ] || [ "$value" -lt 1 ] || [ "$value" -gt 10 ] || continue ;;
		esac
		fail "$field" "$field must be a number from 1 to 10"
		return
	done
	batch_reset
	if [ -n "$track_ips" ]; then
		batch_add "delete mwan3.$name.track_ip"
		for ip in $track_ips; do
			batch_add "add_list mwan3.$name.track_ip='$ip'"
		done
	fi
	if [ -n "$down" ]; then batch_add "set mwan3.$name.down='$down'"; fi
	if [ -n "$up" ]; then batch_add "set mwan3.$name.up='$up'"; fi
	change_plan_commands
	change_commit "WAN $name saved" mwan3
}

wan_del() {
	name=
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--name)
				if [ "$#" -lt 2 ]; then
					fail name 'option --name requires a value'
					return
				fi
				name=$2
				shift 2
				;;
			*)
				reply -1 "unknown option $1"
				return
				;;
		esac
	done
	if [ -z "$name" ]; then
		fail name 'option --name is required'
		return
	fi
	if [ "$name" = "$wan_original" ]; then
		fail name "WAN $wan_original cannot be deleted"
		return
	fi
	if ! is_added_wan "$name"; then
		fail name "no such WAN: $name"
		return
	fi
	members=$(uci_sections mwan3 member | while read -r member; do
		if [ "$(uci_get "mwan3.$member.interface")" = "$name" ]; then echo "$member"; fi
	done)
	batch_reset
	# The WAN leaves every Chính sách WAN; a policy it would leave without any WAN keeps it.
	for policy in $(uci_sections mwan3 policy); do
		kept=0 removed=
		for member in $(uci_list "mwan3.$policy.use_member"); do
			if printf '%s\n' "$members" | grep -Fxq -- "$member"; then
				removed="$removed $member"
			else
				kept=$((kept + 1))
			fi
		done
		[ -n "$removed" ] || continue
		if [ "$kept" = 0 ]; then
			fail name "cannot delete WAN $name: it is the only WAN of Chính sách WAN $policy" \
				",\"policy\":$(json_string "$policy")"
			return
		fi
		for member in $removed; do
			batch_add "del_list mwan3.$policy.use_member='$member'"
		done
	done
	for member in $members; do
		batch_add "delete mwan3.$member"
	done
	if [ -n "$(uci_get "mwan3.$name")" ]; then batch_add "delete mwan3.$name"; fi
	batch_add "delete network.$name"
	for zone in $(uci_sections firewall zone); do
		if uci_list_contains "firewall.$zone.network" "$name"; then
			batch_add "del_list firewall.$zone.network='$name'"
		fi
	done
	lan_bridge=$(bridge_section br-lan)
	if [ "$(uci_get "network.$name.bmc_from_lan")" = 1 ] && [ -n "$lan_bridge" ]; then
		batch_add "add_list network.$lan_bridge.ports=$(uci_quote "$(interface_device "$name")")"
	fi
	change_plan_commands network firewall
	change_commit "WAN $name deleted" network firewall mwan3
}

wan_command() {
	subcommand=${1:-}
	[ "$#" -eq 0 ] || shift
	case "$subcommand" in
		list) wan_list ;;
		add) wan_add "$@" ;;
		set) wan_set "$@" ;;
		del) wan_del "$@" ;;
		*) wan_usage ;;
	esac
}
