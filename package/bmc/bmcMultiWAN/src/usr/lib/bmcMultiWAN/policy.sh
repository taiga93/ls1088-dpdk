# `policy list|set|del`: the Chính sách WAN of Multi-WAN.
#
# A Chính sách WAN is a policy of /etc/config/mwan3: 1-4 WANs in order of preference. Its members are hidden from
# the operator: the WAN at position K is member "<wan>_m<K>" (metric K, weight 1), shared by every policy that
# has this WAN at this position, created when a policy needs it and deleted once no policy uses it. When every
# WAN of a policy is Mất Internet, its traffic follows the main routing table (last_resort default).

policy_max_wans=4

# Policies with the default Chính sách WAN first, then in configuration order.
policy_sections() {
	if [ "$(uci_get "mwan3.$mwan3_default_policy")" = policy ]; then echo "$mwan3_default_policy"; fi
	for policy in $(uci_sections mwan3 policy); do
		if [ "$policy" != "$mwan3_default_policy" ]; then echo "$policy"; fi
	done
}

policy_json() {
	is_default=0
	[ "$1" != "$mwan3_default_policy" ] || is_default=1
	printf '{"name":%s,"wans":%s,"default":%s,"rules":%s}\n' "$(json_string "$1")" \
		"$(mwan3_policy_wans "$1" | json_strings)" "$(json_bool "$is_default")" "$(rule_sections_using "$1" | json_strings)"
}

policy_list() {
	policies=$(for policy in $(policy_sections); do policy_json "$policy"; done | json_array)
	reply 0 'Chính sách WAN list' ",\"policies\":$policies"
}

policy_usage() {
	reply -1 'usage: policy list, policy set --name N --wan W1 [--wan W2]..., policy del --name N'
}

policy_set() {
	name= wans=
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--name|--wan)
				field=${1#--}
				if [ "$#" -lt 2 ]; then
					fail "$field" "option $1 requires a value"
					return
				fi
				if [ "$field" = name ]; then
					name=$2
				else
					# A WAN name has no space, newline or glob character: the list can be split on whitespace.
					case "$2" in
						''|*[![:alnum:]_]*) fail wan "no such WAN: $2"; return ;;
					esac
					wans="$wans$2$newline"
				fi
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
	error=$(mwan3_name_error "$name" policy)
	if [ -n "$error" ]; then
		fail name "$error"
		return
	fi
	if [ -z "$wans" ]; then
		fail wan 'option --wan is required'
		return
	fi
	if [ "$(printf '%s' "$wans" | awk 'END { print NR }')" -gt "$policy_max_wans" ]; then
		fail wan "a Chính sách WAN has at most $policy_max_wans WANs"
		return
	fi
	for wan in $wans; do
		if ! is_wan "$wan" || [ "$(uci_get "mwan3.$wan")" != interface ]; then
			fail wan "no such WAN: $wan"
			return
		fi
	done
	duplicate=$(printf '%s' "$wans" | sort | uniq -d | awk 'NR == 1')
	if [ -n "$duplicate" ]; then
		fail wan "WAN $duplicate is given twice"
		return
	fi
	batch_reset
	if [ "$(uci_get "mwan3.$name")" = policy ]; then
		batch_add "delete mwan3.$name.use_member"
	else
		batch_add "set mwan3.$name=policy"
		batch_add "set mwan3.$name.last_resort='default'"
	fi
	position=0 members=
	for wan in $wans; do
		position=$((position + 1))
		member=$(mwan3_member "$wan" "$position")
		if [ "$(uci_get "mwan3.$member")" != member ]; then mwan3_batch_member "$wan" "$position"; fi
		batch_add "add_list mwan3.$name.use_member='$member'"
		members="$members$member$newline"
	done
	mwan3_batch_prune_members "$name" "$members"
	change_plan_commands
	change_commit "Chính sách WAN $name saved" mwan3
}

policy_del() {
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
	if [ "$name" = "$mwan3_default_policy" ]; then
		fail name 'the default Chính sách WAN cannot be deleted'
		return
	fi
	if [ "$(uci_get "mwan3.$name")" != policy ]; then
		fail name "no such Chính sách WAN: $name"
		return
	fi
	# awk, not head: head exits after one line and ash then reports "write error: Broken pipe" on stderr.
	rule=$(rule_sections_using "$name" | awk 'NR == 1')
	if [ -n "$rule" ]; then
		fail name "cannot delete Chính sách WAN $name: Luật chọn WAN $rule uses it" \
			",\"rule\":$(json_string "$rule")"
		return
	fi
	batch_reset
	batch_add "delete mwan3.$name"
	mwan3_batch_prune_members "$name" ''
	change_plan_commands
	change_commit "Chính sách WAN $name deleted" mwan3
}

policy_command() {
	subcommand=${1:-}
	[ "$#" -eq 0 ] || shift
	case "$subcommand" in
		list) policy_list ;;
		set) policy_set "$@" ;;
		del) policy_del "$@" ;;
		*) policy_usage ;;
	esac
}
