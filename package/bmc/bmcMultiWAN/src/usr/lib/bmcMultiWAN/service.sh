# Control of the mwan3 service: `apply` runs mwan3 exactly when Multi-WAN is enabled.

# mwan3's own init script is disabled (uci-defaults): bmcMultiWAN starts and stops it according to "enabled".
# Never call `mwan3 start|stop`, which also enable or disable that init script.
mwan3_initd=/etc/init.d/mwan3

# Whether procd runs the mwan3 service. `/etc/init.d/mwan3 running` cannot be used: it only tests that
# /var/run/mwan3 exists, and mwan3's iface hotplug script creates that directory even while mwan3 is stopped.
mwan3_running() {
	service_running mwan3
}

# Whether procd runs an instance of service $1.
service_running() {
	"${BMCMULTIWAN_UBUS:-ubus}" -t 5 call service list "{\"name\":\"$1\"}" 2>/dev/null | grep -q '"running": *true'
}

# What mwan3 has in the kernel, one item per line: ip rules in the 1000-3999 range it uses, routing tables
# 1-60 of its WANs (mmx_mask 0x3F00), mangle chains and ipsets named mwan3_*. Empty once mwan3 is fully stopped.
# BMCMULTIWAN_LEFTOVERS replaces this probe with a script, for tests.
mwan3_leftovers() {
	if [ -n "${BMCMULTIWAN_LEFTOVERS:-}" ]; then
		"$BMCMULTIWAN_LEFTOVERS"
		return
	fi
	ip -4 rule show 2>/dev/null | awk -F : '$1 >= 1000 && $1 <= 3999 { print "ip rule " $1 }'
	ip -4 route show table all 2>/dev/null |
		awk '{ for (i = 1; i < NF; i++) if ($i == "table" && $(i + 1) ~ /^[0-9]+$/ && $(i + 1) >= 1 && $(i + 1) <= 60) print "routing table " $(i + 1) }' |
		sort -u
	iptables -t mangle -S 2>/dev/null | awk '$1 == "-N" && $2 ~ /^mwan3_/ { print "iptables chain " $2 }'
	ipset -n list 2>/dev/null | awk '/^mwan3_/ { print "ipset " $0 }'
}

# Sets apply_action (start|restart|stop|none) from "enabled" and the state of mwan3. A running mwan3 is
# restarted to load its configuration; a disabled Multi-WAN also stops an mwan3 that procd no longer runs but
# whose rules are still in the kernel.
apply_plan() {
	if [ "$enabled" = 1 ]; then
		if mwan3_running; then apply_action=restart; else apply_action=start; fi
	elif mwan3_running || [ -n "$(mwan3_leftovers)" ]; then
		apply_action=stop
	else
		apply_action=none
	fi
}

apply_plan_json() {
	if [ "$apply_action" = none ]; then
		printf ',"action":"none","commands":[]'
	else
		printf ',"action":"%s","commands":[%s]' "$apply_action" "$(json_string "$mwan3_initd $apply_action")"
	fi
}

# Executes the plan; on error sets apply_error. The exit code of mwan3's init script says little (its stop
# never fails), so the outcome is checked on the running system instead.
apply_execute() {
	apply_error=
	[ "$apply_action" != none ] || return 0
	"$mwan3_initd" "$apply_action" >/dev/null 2>&1 || true
	case "$apply_action" in
		start|restart)
			mwan3_running || apply_error='Multi-WAN failed to start'
			;;
		stop)
			# The state of each WAN and the last Chuyển WAN belong to this run of Multi-WAN.
			rm -rf "$run_dir"
			leftovers=$(mwan3_leftovers)
			[ -z "$leftovers" ] || apply_error="Multi-WAN stopped but left: $(printf '%s\n' "$leftovers" | awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $0 }')"
			;;
	esac
	[ -z "$apply_error" ]
}

apply_command() {
	apply_plan
	if [ "$dry_run" = 1 ]; then
		reply 0 'Multi-WAN plan ready' "$(apply_plan_json)"
	elif ! apply_execute; then
		reply -1 "$apply_error" "$(apply_plan_json)"
	else
		case "$apply_action" in
			start|restart) message='Multi-WAN started' ;;
			stop) message='Multi-WAN stopped' ;;
			none) message='Multi-WAN disabled: nothing to do' ;;
		esac
		reply 0 "$message" "$(apply_plan_json)"
	fi
}

# Whether mwan3's jumps are in mangle PREROUTING and OUTPUT. BMCMULTIWAN_HOOK_PROBE replaces this probe with a
# script, for tests.
mwan3_hooked() {
	if [ -n "${BMCMULTIWAN_HOOK_PROBE:-}" ]; then
		"$BMCMULTIWAN_HOOK_PROBE"
		return
	fi
	iptables -w -t mangle -C PREROUTING -j mwan3_hook 2>/dev/null &&
		iptables -w -t mangle -C OUTPUT -j mwan3_hook 2>/dev/null
}

# Internal command of the firewall include, run after every firewall start, reload and restart. A reload keeps
# mwan3's chains (fw3 only removes its own rules), but a restart or stop (`fw3 flush`) deletes every chain of
# the mangle table: mwan3 then no longer marks anything while its ip rules and ipsets stay. A running mwan3
# whose jumps are gone is restarted, which rebuilds all of it (after a stop: on the next firewall start). This runs inside fw3, before its later includes,
# so that their iptables commands do not race mwan3's for the xtables lock.
firewall_apply_command() {
	apply_action=none
	if [ "$enabled" != 1 ]; then
		message='Multi-WAN disabled: nothing to do'
	elif ! mwan3_running; then
		message='Multi-WAN is not running: nothing to do'
	elif mwan3_hooked; then
		message='mwan3 rules in place: nothing to do'
	else
		apply_action=restart
		message='Multi-WAN restarted: its firewall rules were gone'
	fi
	if [ "$dry_run" = 1 ] && [ "$apply_action" != none ]; then
		message='Multi-WAN plan ready'
	elif [ "$apply_action" != none ]; then
		logger -t bmcMultiWAN 'mwan3 rules were removed by a firewall restart: restarting Multi-WAN'
		if ! apply_execute; then
			logger -t bmcMultiWAN "$apply_error"
			reply -1 "$apply_error" "$(apply_plan_json)"
			return
		fi
	fi
	reply 0 "$message" "$(apply_plan_json)"
}

# Plans the commands that make a configuration change effective: reload of services $@ (network, firewall),
# then a restart of mwan3 when Multi-WAN runs, so that the new /etc/config/mwan3 is used at once (mwan3 would
# otherwise load it on the next reload_config of any feature, through its procd reload trigger).
change_plan_commands() {
	change_reload_services=$*
	change_commands=
	for service in "$@"; do
		change_commands="$change_commands/etc/init.d/$service reload$newline"
	done
	change_restart_mwan3=0
	if [ "$enabled" = 1 ] && mwan3_running; then
		change_restart_mwan3=1
		change_commands="$change_commands$mwan3_initd restart$newline"
	fi
}

# Saves the batch into configs $2... then runs the planned commands; replies $1 on success.
change_commit() {
	message=$1
	shift
	extra=",\"commands\":$(printf '%s' "$change_commands" | json_strings)"
	plan_or_commit "$message" "$extra" "$@" || return 0
	for service in $change_reload_services; do
		"/etc/init.d/$service" reload >/dev/null 2>&1 || true
	done
	if [ "$change_restart_mwan3" = 1 ]; then
		apply_action=restart
		if ! apply_execute; then
			reply -1 "$message, but $apply_error" "$extra"
			return
		fi
	fi
	reply 0 "$message" "$extra"
}
