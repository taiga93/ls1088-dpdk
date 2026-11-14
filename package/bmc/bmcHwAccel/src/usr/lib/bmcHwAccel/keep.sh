# Giữ traffic trên CPU (ADR-0011): a feature that does not work on a Kết nối đã tăng tốc registers what has
# to stay on the CPU with `keep`, and takes it back with `release`. `status` lists it in "on_cpu".
#
# How a connection is kept on the CPU: it carries one bit in its conntrack mark, and the daemon never hands a
# connection with that bit to the hardware (./fastforward). The rules of the chain below set the bit on the
# first packet of every connection through a kept WAN. The bit is outside the marks of mwan3 (0x3F00) and
# of bmcqos (0xff), and it is never copied into the mark of a packet, so no route lookup sees it.
#
# A feature registers the device it works on (bmcqos: the one that has its qdisc). What the router forwards
# may enter and leave through a device stacked on it instead, a VLAN or a PPPoE session, and still pass that
# qdisc: the rules cover the registered device and everything stacked on it (keep_stack). Such a device
# comes and goes; the hotplug script of the package runs `refresh` when an interface comes up.
#
# The daemon looks at the mark only when it first hands a connection over. So after a change of what is
# kept, the daemon is stopped (which empties the hardware), every open connection gets the bit, and the
# daemon is started again: connections that were open at the change continue on the CPU until they end,
# through whatever interface they go. `release` of the last registration clears the bit everywhere instead.
keep_bit=0x10000
keep_chain=BMCHWACCEL_KEEP
# One line per registration: reason, scope ("wan") and device, tab-separated and sorted. Gone at reboot:
# features register again when they start.
kept_file="$run_dir/on_cpu"
# The devices the rules in the firewall were last installed for, one per line.
keep_installed_for="$run_dir/on_cpu-devices"
# There while a change of what is kept has not been carried out to its end; it says "restart" when that
# change stopped the daemon, which the next one then has to start.
keep_pending="$run_dir/on_cpu-pending"

# BMCHWACCEL_TABLES replaces iptables and ip6tables with a script that gets the name first, for tests.
# Every call waits (-w) while another program holds the lock of the tables: a rule that could not be asked
# for is not a rule that is missing.
tables_ask() { # iptables|ip6tables <arguments...>
	if [ -n "${BMCHWACCEL_TABLES:-}" ]; then
		"$BMCHWACCEL_TABLES" "$@" >/dev/null 2>&1
	else
		"$@" >/dev/null 2>&1
	fi
}

kept_load() {
	kept=$(cat "$kept_file" 2>/dev/null) || kept=
}

kept_save() {
	mkdir -p "$run_dir" && printf '%s' "${1:+$1$newline}" > "$kept_file"
}

# The registrations $1 with that of the reason $2 replaced by scope $3, device $4.
kept_with() {
	{ kept_without "$1" "$2"; printf '%s\t%s\t%s\n' "$2" "$3" "$4"; } | sort
}

kept_without() {
	printf '%s\n' "$1" | awk -F '\t' -v reason="$2" 'NF == 3 && $1 != reason'
}

kept_devices() {
	printf '%s\n' "$1" | awk -F '\t' 'NF == 3 { print $3 }' | sort -u
}

# The device $1 and every device stacked on it: its upper devices (VLANs, and theirs), and the PPPoE
# sessions over any of them, which the kernel of this firmware lists with their device in the fourth column.
# BMCHWACCEL_SYS_NET and BMCHWACCEL_PPPOE replace /sys/class/net and /proc/net/pppoe, for tests.
keep_stack() {
	echo "$1"
	awk -v device="$1" 'NR > 1 && $3 == device && $4 != "" { print $4 }' \
		"${BMCHWACCEL_PPPOE:-/proc/net/pppoe}" 2>/dev/null || true
	for upper in "${BMCHWACCEL_SYS_NET:-/sys/class/net}/$1"/upper_*; do
		[ -e "$upper" ] || continue
		keep_stack "${upper##*/upper_}"
	done
}

# The devices whose connections the registrations $1 keep on the CPU, one per line.
keep_scope() {
	for device in $(kept_devices "$1"); do
		keep_stack "$device"
	done | sort -u
}

# Names are checked when they are registered: nothing in them needs escaping.
kept_json() {
	printf '%s\n' "$1" | awk -F '\t' 'BEGIN { printf "[" }
		NF == 3 { printf "%s{\"scope\":\"%s\",\"device\":\"%s\",\"reason\":\"%s\"}", (n++ ? "," : ""), $2, $3, $1 }
		END { printf "]" }'
}

# "wan eth0 (bmcqos), wan eth1 (other)", for syslog.
kept_text() {
	printf '%s\n' "$1" | awk -F '\t' 'NF == 3 { printf "%s%s %s (%s)", (n++ ? ", " : ""), $2, $3, $1 }
		END { if (!n) printf "nothing" }'
}

# Whether the firewall marks the connections through the devices $1, IPv4 and IPv6.
keep_installed() {
	for tables in iptables ip6tables; do
		tables_ask "$tables" -w -t mangle -C FORWARD -j "$keep_chain" || return 1
		for device in $1; do
			for direction in -o -i; do
				tables_ask "$tables" -w -t mangle -C "$keep_chain" "$direction" "$device" -j CONNMARK \
					--set-xmark "$keep_bit/$keep_bit" || return 1
			done
		done
	done
}

# Whether anything of the chain is left in the firewall.
keep_present() {
	tables_ask iptables -w -t mangle -S "$keep_chain" || tables_ask ip6tables -w -t mangle -S "$keep_chain"
}

# The commands that make the firewall mark the connections through the devices $1, and only those; with no
# device, that take the chain out. Creating a chain that is there and deleting a jump that is not fail, and
# are meant to.
keep_rule_commands() {
	for tables in iptables ip6tables; do
		if [ -n "$1" ]; then
			echo "$tables -w -t mangle -N $keep_chain"
			echo "$tables -w -t mangle -F $keep_chain"
			for device in $1; do
				for direction in -o -i; do
					echo "$tables -w -t mangle -A $keep_chain $direction $device -j CONNMARK --set-xmark $keep_bit/$keep_bit"
				done
			done
			echo "$tables -w -t mangle -D FORWARD -j $keep_chain"
			echo "$tables -w -t mangle -I FORWARD -j $keep_chain"
		else
			echo "$tables -w -t mangle -D FORWARD -j $keep_chain"
			echo "$tables -w -t mangle -F $keep_chain"
			echo "$tables -w -t mangle -X $keep_chain"
		fi
	done
}

# Before a daemon starts: sets keep_devices, the devices whose connections are kept on the CPU, and
# keep_restore, the commands (each with its newline) that put their rules and marks back when the firewall
# lost them, since a daemon that starts hands every open connection over. apply of engine.sh uses it.
keep_restore_plan() {
	kept_load
	keep_devices=$(keep_scope "$kept")
	keep_restore=
	[ -z "$keep_devices" ] || keep_installed "$keep_devices" ||
		keep_restore="$(keep_rule_commands "$keep_devices")$newline$(keep_mark_commands "$keep_devices")$newline"
}

# The commands that give every open connection the bit ($1 not empty) or clear it everywhere.
keep_mark_commands() {
	if [ -n "$1" ]; then mark="$keep_bit/$keep_bit"; else mark="0/$keep_bit"; fi
	echo "conntrack -U --mark $mark"
	echo "conntrack -U -f ipv6 --mark $mark"
}

# Sets keep_devices, keep_action (install|remove|none) and keep_commands for the registrations $1.
# "install" when the rules in the firewall are for other devices (a registration changed, or a device was
# stacked on a kept one), when the firewall lost them (a firewall restart), and when an earlier change
# failed half-way: in each case connections may have been accelerated without the bit meanwhile.
keep_plan() {
	keep_action=none
	keep_commands=
	keep_devices=$(keep_scope "$1")
	installed_for=$(cat "$keep_installed_for" 2>/dev/null) || installed_for=
	if [ -n "$keep_devices" ]; then
		if [ "$installed_for" != "$keep_devices" ] || [ -e "$keep_pending" ] ||
			! keep_installed "$keep_devices"; then
			keep_action=install
		fi
	elif [ -n "$installed_for" ] || [ -e "$keep_pending" ] || keep_present; then
		keep_action=remove
	fi
	[ "$keep_action" != none ] || return 0
	keep_commands=$(keep_rule_commands "$keep_devices")$newline
	if daemon_running; then
		keep_commands="$keep_commands$daemon_initd stop$newline$(keep_mark_commands "$keep_devices")$newline$daemon_initd start$newline"
	elif [ "$enabled" = 1 ] && grep -q -x restart "$keep_pending" 2>/dev/null; then
		keep_commands="$keep_commands$(keep_mark_commands "$keep_devices")$newline$daemon_initd start$newline"
	else
		keep_commands="$keep_commands$(keep_mark_commands "$keep_devices")$newline"
	fi
}

keep_plan_json() {
	printf ',"on_cpu":%s,"action":"%s","commands":%s' "$(kept_json "$1")" "$keep_action" \
		"$(printf '%s' "$keep_commands" | json_strings)"
}

# Saves the registrations $1 and executes the plan; on error sets keep_error. The daemon is not started
# again without the rules: a feature is never left without effect, the router forwards on the CPU instead.
keep_execute() {
	keep_error=
	kept_save "$1" || { keep_error='failed to save what is kept on the CPU'; return 1; }
	[ "$keep_action" != none ] || return 0
	case "$keep_commands" in
		*"$daemon_initd start"*) echo restart > "$keep_pending" ;;
		*) : > "$keep_pending" ;;
	esac
	while IFS= read -r planned; do
		[ -n "$planned" ] || continue
		case "$planned" in
			"$daemon_initd start")
				if [ -n "$keep_devices" ] && ! keep_installed "$keep_devices"; then
					keep_error='failed to install the rules of what is kept on the CPU; Tăng tốc phần cứng stays stopped'
					state_note unavailable daemon
					return 1
				fi
				if ! wait_until "$device_wait" control_device_ready; then
					keep_error="Tăng tốc phần cứng failed to start again: $(reason_text daemon)"
					state_note unavailable daemon
					return 1
				fi
				;;
		esac
		$planned >/dev/null 2>&1 </dev/null || true
		case "$planned" in
			"$daemon_initd stop")
				if ! wait_until "$stop_wait" daemon_stopped; then
					keep_error='Tăng tốc phần cứng failed to stop'
					return 1
				fi
				;;
			"$daemon_initd start")
				if ! wait_until "$start_wait" daemon_answers; then
					keep_error="Tăng tốc phần cứng failed to start again: $(reason_text daemon)"
					state_note unavailable daemon
					return 1
				fi
				# Back after a change that had left it stopped.
				state_note on
				;;
		esac
	done <<EOF_COMMANDS
$keep_commands
EOF_COMMANDS
	if [ -n "$keep_devices" ] && ! keep_installed "$keep_devices"; then
		keep_error='failed to install the rules of what is kept on the CPU'
		return 1
	fi
	printf '%s' "${keep_devices:+$keep_devices$newline}" > "$keep_installed_for"
	rm -f "$keep_pending"
	logger -t bmcHwAccel "Tăng tốc phần cứng keeps on the CPU: $(kept_text "$1")" || true
}

# One command that changes the router at a time: features register from init scripts and hotplug while the
# operator may switch Tăng tốc phần cứng. Without a place for the lock the command runs unlocked.
keep_lock() {
	mkdir -p "$run_dir" 2>/dev/null && touch "$run_dir/lock" 2>/dev/null || return 0
	exec 9>"$run_dir/lock"
	flock 9 2>/dev/null || true
}

# Plans and executes the change of the registrations to $1, and answers with the message $2.
keep_change() {
	keep_plan "$1"
	if [ "$dry_run" = 1 ]; then
		reply 0 "$2" "$(keep_plan_json "$1")"
	elif ! keep_execute "$1"; then
		reply -1 "$keep_error" "$(keep_plan_json "$1")"
	else
		reply 0 "$2" "$(keep_plan_json "$1")"
	fi
}

valid_reason() {
	case "$1" in ''|*[!a-z0-9_]*) return 1 ;; esac
}

# An interface name of Linux: at most 15 characters. It becomes a word of an iptables command, so it may not
# look like an option.
valid_device() {
	case "$1" in ''|-*|*[!A-Za-z0-9_.@-]*|????????????????*) return 1 ;; esac
}

# `keep <reason> wan <device>`: every connection through that WAN stays on the CPU. A reason has one
# registration: registering again replaces it.
keep_command() {
	if [ "$#" -ne 3 ]; then
		reply -1 'usage: bmchwaccel keep <reason> wan <device>'
	elif ! valid_reason "$1"; then
		reply -1 "invalid reason: $1" ',"field":"reason"'
	elif [ "$2" != wan ]; then
		reply -1 "invalid scope: $2" ',"field":"scope"'
	elif ! valid_device "$3"; then
		reply -1 "invalid device: $3" ',"field":"device"'
	else
		kept_load
		keep_change "$(kept_with "$kept" "$1" "$2" "$3")" "Tăng tốc phần cứng keeps $2 $3 on the CPU for $1"
	fi
}

# `release <reason>`: takes the registration of that reason back.
release_command() {
	if [ "$#" -ne 1 ]; then
		reply -1 'usage: bmchwaccel release <reason>'
	elif ! valid_reason "$1"; then
		reply -1 "invalid reason: $1" ',"field":"reason"'
	else
		kept_load
		keep_change "$(kept_without "$kept" "$1")" "Tăng tốc phần cứng keeps nothing on the CPU for $1"
	fi
}

# `refresh`: the firewall runs this after each start and reload, which can take the rules out.
refresh_command() {
	kept_load
	keep_change "$kept" 'Tăng tốc phần cứng: what is kept on the CPU is in place'
}
