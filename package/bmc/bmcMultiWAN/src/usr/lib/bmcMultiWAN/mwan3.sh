# /etc/config/mwan3 as written by bmcMultiWAN.
#
# Naming convention (hidden from the operator): the member of WAN W with metric M in a policy is "W_mM".
# mwan3 reserves the use_policy values "default", "unreachable" and "blackhole", and limits policy and rule
# names to 15 characters, hence "default_policy" and "default_rule".

mwan3_default_policy=default_policy
mwan3_default_rule=default_rule
# Option set by bmcMultiWAN on mwan3.globals once it owns /etc/config/mwan3 (mwan3 ignores it).
mwan3_marker=bmc_managed

# Adds to the batch the mwan3 interface of WAN $1 with the default Internet check: ping 1.1.1.1 and 8.8.8.8
# every 5 s, one answer is enough; Mất Internet after 3 failed rounds, Internet again after 5 good ones.
# mwan3track pings the targets one after the other: a failed round lasts up to 2 x 2 s (timeout) + 5 s, so
# Mất Internet is reported about 25 s after the targets stop answering.
# flush_conntrack is not set: existing connections stay on the WAN they use.
mwan3_batch_wan() {
	batch_add "set mwan3.$1=interface"
	batch_add "set mwan3.$1.enabled='1'"
	batch_add "set mwan3.$1.family='ipv4'"
	batch_add "add_list mwan3.$1.track_ip='1.1.1.1'"
	batch_add "add_list mwan3.$1.track_ip='8.8.8.8'"
	batch_add "set mwan3.$1.reliability='1'"
	batch_add "set mwan3.$1.interval='5'"
	batch_add "set mwan3.$1.timeout='2'"
	batch_add "set mwan3.$1.down='3'"
	batch_add "set mwan3.$1.up='5'"
	batch_add "set mwan3.$1.initial_state='online'"
}

# "mark/mask" of the connections of WAN $1, as mwan3 computes it: the position of the WAN among the interfaces
# of /etc/config/mwan3 (from 1), its bits spread over the bits set in mmx_mask (hexadecimal or decimal, as
# mwan3 takes it). Nothing when the WAN is not there or the mask is not a number.
mwan3_wan_mark() {
	mark_mask=$(uci_get mwan3.globals.mmx_mask)
	mark_mask=${mark_mask:-0x3F00}
	case "$mark_mask" in
		0[xX]*[!0-9a-fA-F]*|0[xX]) return 0 ;;
		0[xX]*) ;;
		*[!0-9]*) return 0 ;;
	esac
	mark_mask=$((mark_mask))
	mark_id=$(uci_sections mwan3 interface | awk -v wan="$1" '$0 == wan { print NR; exit }')
	[ -n "$mark_id" ] || return 0
	mark=0 mark_bit=0 mark_from=0
	while [ "$mark_bit" -lt 32 ]; do
		if [ $(((mark_mask >> mark_bit) & 1)) = 1 ]; then
			[ $(((mark_id >> mark_from) & 1)) = 0 ] || mark=$((mark | (1 << mark_bit)))
			mark_from=$((mark_from + 1))
		fi
		mark_bit=$((mark_bit + 1))
	done
	printf '0x%x/0x%x' "$mark" "$mark_mask"
}

# Name of the member of WAN $1 with metric $2.
mwan3_member() {
	printf '%s_m%s' "$1" "$2"
}

# Adds to the batch member "$1_m$2" (WAN $1, metric $2).
mwan3_batch_member() {
	member=$(mwan3_member "$1" "$2")
	batch_add "set mwan3.$member=member"
	batch_add "set mwan3.$member.interface='$1'"
	batch_add "set mwan3.$member.metric='$2'"
	batch_add "set mwan3.$member.weight='1'"
}

# Prints why $1 cannot name a $2 (policy or rule) of /etc/config/mwan3; nothing when it can. Policies and
# rules share one namespace with the interfaces and members of mwan3, and names ending in _m<number> are left
# to the hidden members.
mwan3_name_error() {
	case "$1" in
		[[:lower:]]*) ;;
		*) printf 'name must start with a lowercase letter'; return 0 ;;
	esac
	case "$1" in
		*[![:lower:][:digit:]_]*) printf 'name may only contain lowercase letters, digits and _'; return 0 ;;
	esac
	if [ "${#1}" -gt 15 ]; then
		printf 'name must be at most 15 characters'
		return 0
	fi
	if [ "$2" = policy ]; then
		case "$1" in
			default|unreachable|blackhole) printf 'name %s is reserved by mwan3' "$1"; return 0 ;;
		esac
	fi
	if printf '%s' "$1" | grep -Eq '_m[0-9]+$'; then
		printf 'names ending in _m<number> are reserved'
		return 0
	fi
	section_type=$(uci_get "mwan3.$1")
	[ -n "$section_type" ] && [ "$section_type" != "$2" ] || return 0
	case "$section_type" in
		interface) printf 'name %s is already used by a WAN' "$1" ;;
		policy) printf 'name %s is already used by a Chính sách WAN' "$1" ;;
		rule) printf 'name %s is already used by a Luật chọn WAN' "$1" ;;
		*) printf 'name %s is already used in /etc/config/mwan3' "$1" ;;
	esac
}

# WANs of Chính sách WAN $1 in order of preference (lowest member metric first, mwan3's default metric is 1),
# one per line.
mwan3_policy_wans() {
	for member in $(uci_list "mwan3.$1.use_member"); do
		printf '%s\t%s\n' "$(uci_get "mwan3.$member.metric")" "$(uci_get "mwan3.$member.interface")"
	done | awk -F '\t' '{ print ($1 == "" ? 1 : $1 + 0) "\t" NR "\t" $2 }' | sort -n -k 1,1 -k 2,2 | cut -f 3
}

# Adds to the batch the deletion of every member that no Chính sách WAN uses once policy $1 uses the members
# listed in $2 (one per line; empty when $1 is deleted).
mwan3_batch_prune_members() {
	used=$(for policy in $(uci_sections mwan3 policy); do
		if [ "$policy" != "$1" ]; then uci_list "mwan3.$policy.use_member"; fi
	done)
	used="$used$newline$2"
	for member in $(uci_sections mwan3 member); do
		if ! printf '%s\n' "$used" | grep -Fxq -- "$member"; then batch_add "delete mwan3.$member"; fi
	done
}

# Replaces the sample /etc/config/mwan3 of the mwan3 package (wanb, wan6, https rule, ...) with the minimal
# Multi-WAN configuration: the existing "wan" is the first WAN, the default Chính sách WAN uses it and the
# default rule sends all IPv4 traffic to that policy. When every WAN of the policy is Mất Internet, traffic
# falls back to the main routing table (last_resort default) instead of being dropped.
mwan3_batch_defaults() {
	for section in $(uci_sections mwan3); do
		batch_add "delete mwan3.$section"
	done
	batch_add "set mwan3.globals=globals"
	batch_add "set mwan3.globals.mmx_mask='0x3F00'"
	batch_add "set mwan3.globals.$mwan3_marker='1'"
	mwan3_batch_wan wan
	mwan3_batch_member wan 1
	batch_add "set mwan3.$mwan3_default_policy=policy"
	batch_add "add_list mwan3.$mwan3_default_policy.use_member='wan_m1'"
	batch_add "set mwan3.$mwan3_default_policy.last_resort='default'"
	batch_add "set mwan3.$mwan3_default_rule=rule"
	batch_add "set mwan3.$mwan3_default_rule.family='ipv4'"
	batch_add "set mwan3.$mwan3_default_rule.dest_ip='0.0.0.0/0'"
	batch_add "set mwan3.$mwan3_default_rule.use_policy='$mwan3_default_policy'"
}

# Internal command of uci-defaults: runs once per install or upgrade.
defaults_command() {
	if [ "$(uci_get "mwan3.globals.$mwan3_marker")" = 1 ]; then
		reply 0 'Multi-WAN default configuration already written' ',"action":"none"'
		return
	fi
	batch_reset
	mwan3_batch_defaults
	plan_or_commit 'Multi-WAN default configuration written' '' mwan3 || return 0
	reply 0 'Multi-WAN default configuration written'
}
