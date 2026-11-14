# `rule list|set|del`: the Luật chọn WAN of Multi-WAN.
#
# A Luật chọn WAN is a rule of /etc/config/mwan3 sending the IPv4 traffic it matches to a Chính sách WAN. mwan3
# evaluates the rules in file order and the first match wins, so the CLI keeps the rules in the operator's
# order, the default rule (all traffic to the default Chính sách WAN) always last. Ports are written as iptables
# multiport wants them: ranges a:b, lists a,b; the CLI shows ranges as a-b.

# iptables multiport matches at most 15 ports, a range counting as 2.
rule_max_ports=15

# Rules of the operator (all but the default rule) in the order mwan3 evaluates them.
rule_sections() {
	for rule in $(uci_sections mwan3 rule); do
		if [ "$rule" != "$mwan3_default_rule" ]; then echo "$rule"; fi
	done
}

# Luật chọn WAN using Chính sách WAN $1, in the order they are evaluated.
rule_sections_using() {
	for rule in $(rule_sections); do
		if [ "$(uci_get "mwan3.$rule.use_policy")" = "$1" ]; then echo "$rule"; fi
	done
}

# rule_json <rule> <position, empty for the default rule>
rule_json() {
	proto=$(uci_get "mwan3.$1.proto")
	is_default=0
	[ "$1" != "$mwan3_default_rule" ] || is_default=1
	printf '{"name":%s,"policy":%s,"src_ip":%s,"dest_ip":%s,"proto":%s,"src_port":%s,"dest_port":%s,"position":%s,"default":%s}\n' \
		"$(json_string "$1")" "$(json_string "$(uci_get "mwan3.$1.use_policy")")" \
		"$(json_string "$(uci_get "mwan3.$1.src_ip")")" "$(json_string "$(uci_get "mwan3.$1.dest_ip")")" \
		"$(json_string "${proto:-all}")" "$(json_string "$(uci_get "mwan3.$1.src_port" | tr : -)")" \
		"$(json_string "$(uci_get "mwan3.$1.dest_port" | tr : -)")" "$(json_number_or_null "$2")" \
		"$(json_bool "$is_default")"
}

rule_list() {
	rules=$(
		position=0
		for rule in $(rule_sections); do
			position=$((position + 1))
			rule_json "$rule" "$position"
		done
		if [ "$(uci_get "mwan3.$mwan3_default_rule")" = rule ]; then rule_json "$mwan3_default_rule" ''; fi
	)
	reply 0 'Luật chọn WAN list' ",\"rules\":$(printf '%s\n' "$rules" | json_array)"
}

rule_usage() {
	reply -1 'usage: rule list, rule set --name N --policy P [--src-ip CIDR] [--dest-ip CIDR] [--proto tcp|udp|icmp|all] [--src-port SPEC] [--dest-port SPEC] [--position K], rule del --name N'
}

# Prints why $1 is not an IPv4 address or network a.b.c.d/n (host bits cleared); nothing when it is.
rule_ip_error() {
	case "$1" in
		*/*) address=${1%/*} prefix=${1#*/} ;;
		*) address=$1 prefix=32 ;;
	esac
	# No leading zero: the value is written as given.
	case "$prefix" in
		''|*[!0-9]*|0?*) prefix=33 ;;
	esac
	if ! ipv4_valid "$address" || [ "${#prefix}" -gt 2 ] || [ "$prefix" -gt 32 ]; then
		printf '%s is not an IPv4 address or network a.b.c.d/n' "$1"
		return 0
	fi
	network=$(ipv4_network "$address" "$prefix")
	if [ "$network" != "$address" ]; then printf '%s is not a network: did you mean %s/%s' "$1" "$network" "$prefix"; fi
}

# Prints why $1 is not a port SPEC (a port, a range a-b, a list a,b of both, at most 15 ports with a range
# counting as 2); nothing when it is.
rule_port_error() {
	printf '%s\n' "$1" | awk -F , -v max="$rule_max_ports" '{
		count = 0
		for (i = 1; i <= NF; i++) {
			# No leading zero: the value is written as given.
			if ($i ~ /^[1-9][0-9]*$/) {
				low = $i; high = $i; count++
			} else if ($i ~ /^[1-9][0-9]*-[1-9][0-9]*$/) {
				split($i, range, "-"); low = range[1]; high = range[2]; count += 2
			} else {
				printf "%s is not a port, a range a-b or a list a,b", $0; exit
			}
			if (length(low) > 5 || length(high) > 5 || low + 0 < 1 || high + 0 > 65535) {
				printf "%s is not a port from 1 to 65535", $i; exit
			}
			if (low + 0 > high + 0) { printf "range %s must start with the lower port", $i; exit }
		}
		if (count > max) printf "has more than %d ports, a range counting as 2", max
	}'
}

rule_set() {
	name= policy= src_ip= dest_ip= proto= src_port= dest_port= position=
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--name|--policy|--src-ip|--dest-ip|--proto|--src-port|--dest-port|--position)
				field=$(printf '%s' "${1#--}" | tr - _)
				if [ "$#" -lt 2 ] || [ -z "$2" ]; then
					fail "$field" "option $1 requires a value"
					return
				fi
				eval "$field=\$2"
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
	if [ "$name" = "$mwan3_default_rule" ]; then
		fail name 'the default Luật chọn WAN cannot be changed'
		return
	fi
	error=$(mwan3_name_error "$name" rule)
	if [ -n "$error" ]; then
		fail name "$error"
		return
	fi
	if [ -z "$policy" ]; then
		fail policy 'option --policy is required'
		return
	fi
	if [ "$(uci_get "mwan3.$policy")" != policy ]; then
		fail policy "no such Chính sách WAN: $policy"
		return
	fi
	for field in src_ip dest_ip; do
		value=$(value_of "$field")
		[ -n "$value" ] || continue
		error=$(rule_ip_error "$value")
		if [ -n "$error" ]; then
			fail "$field" "$field $error"
			return
		fi
	done
	case "${proto:=all}" in
		tcp|udp|icmp|all) ;;
		*) fail proto 'proto must be tcp, udp, icmp or all'; return ;;
	esac
	for field in src_port dest_port; do
		value=$(value_of "$field")
		[ -n "$value" ] || continue
		case "$proto" in
			tcp|udp) ;;
			*) fail "$field" "$field is only valid with --proto tcp or udp"; return ;;
		esac
		error=$(rule_port_error "$value")
		if [ -n "$error" ]; then
			fail "$field" "$field $error"
			return
		fi
	done
	# The new order of the rules: a new rule goes last unless --position says otherwise, a replaced one keeps
	# its position.
	others=$(rule_sections | grep -Fvx -- "$name" || true)
	count=$(printf '%s' "$others" | awk 'NF { n++ } END { print n + 0 }')
	current=$(rule_sections | awk -v name="$name" '$0 == name { print NR }')
	max=$((count + 1))
	if [ -z "$position" ]; then
		position=${current:-$max}
	else
		case "$position" in
			*[!0-9]*) position=0 ;;
		esac
		if [ "${#position}" -gt 2 ] || [ "$position" -lt 1 ] || [ "$position" -gt "$max" ]; then
			fail position "position must be from 1 to $max"
			return
		fi
	fi
	order=$(printf '%s\n' "$others" | awk -v name="$name" -v position="$position" '
		NR == position { print name } NF { print } END { if (position > NR) print name }')
	batch_reset
	# A replaced rule is written again from scratch: options not given are cleared.
	if [ -n "$current" ]; then batch_add "delete mwan3.$name"; fi
	batch_add "set mwan3.$name=rule"
	batch_add "set mwan3.$name.family='ipv4'"
	if [ -n "$src_ip" ]; then batch_add "set mwan3.$name.src_ip='$src_ip'"; fi
	if [ -n "$dest_ip" ]; then batch_add "set mwan3.$name.dest_ip='$dest_ip'"; fi
	batch_add "set mwan3.$name.proto='$proto'"
	if [ -n "$src_port" ]; then batch_add "set mwan3.$name.src_port='$(printf '%s' "$src_port" | tr - :)'"; fi
	if [ -n "$dest_port" ]; then batch_add "set mwan3.$name.dest_port='$(printf '%s' "$dest_port" | tr - :)'"; fi
	batch_add "set mwan3.$name.use_policy='$policy'"
	rule_batch_order "$order"
	change_plan_commands
	change_commit "Luật chọn WAN $name saved" mwan3
}

# Adds to the batch the moves that leave rules $1 (one per line) then the default rule at the end of
# /etc/config/mwan3, in this order. Each rule is moved to the last index: `uci reorder` takes an index among all
# sections and puts the section last when the index is past the end.
rule_batch_order() {
	last=$(uci_sections mwan3 | awk 'END { print NR }')
	last=$((last + $(printf '%s' "$uci_batch" | awk '/^set mwan3\.[^.=]*=/ { n++ } END { print n + 0 }')))
	for rule in $1; do
		batch_add "reorder mwan3.$rule=$last"
	done
	if [ "$(uci_get "mwan3.$mwan3_default_rule")" = rule ]; then batch_add "reorder mwan3.$mwan3_default_rule=$last"; fi
}

rule_del() {
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
	if [ "$name" = "$mwan3_default_rule" ]; then
		fail name 'the default Luật chọn WAN cannot be deleted'
		return
	fi
	if [ "$(uci_get "mwan3.$name")" != rule ]; then
		fail name "no such Luật chọn WAN: $name"
		return
	fi
	batch_reset
	batch_add "delete mwan3.$name"
	change_plan_commands
	change_commit "Luật chọn WAN $name deleted" mwan3
}

rule_command() {
	subcommand=${1:-}
	[ "$#" -eq 0 ] || shift
	case "$subcommand" in
		list) rule_list ;;
		set) rule_set "$@" ;;
		del) rule_del "$@" ;;
		*) rule_usage ;;
	esac
}
