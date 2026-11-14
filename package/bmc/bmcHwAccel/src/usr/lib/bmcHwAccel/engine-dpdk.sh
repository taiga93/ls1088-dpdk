# What implements Tăng tốc phần cứng on the DPAA2 boards (LS1088): bmchwaccel-engine of bmcHwAccelDpdk.
# Installed as engine.sh instead of the one of NXP ASK (Makefile); what it gives the rest of bmcHwAccel is
# listed there.
#
# The engine holds the 10G ports in the engine layout, which the board builds at boot when Tăng tốc phần
# cứng is enabled, and never changes while it runs (/usr/lib/bmcHwAccelDpdk/layout, ADR-0013). So:
#   - disabling takes effect at once: the engine lets go of every Kết nối đã tăng tốc and passes every
#     packet to the kernel; the engine layout goes at the next boot ("reboot_required");
#   - enabling on a router in the kernel layout takes effect at the next boot; the router does not restart
#     by itself;
#   - unavailable: "boot_skipped" (two boots in a row did not finish starting the engine layout) or
#     "engine" (the engine kept dying or did not start, and the router restarted in the kernel layout),
#     until `enable`; "engine" also for a boot without the memory of the engine, for that boot only;
#     "restarting" while the engine of the engine layout is being started again; "daemon" while the engine
#     answers but no daemon hands it connections.
# The engine runs under ./supervise-engine, which starts it again and logs it going on and unavailable. The
# daemon bmchwaccel-syncd hands the engine the connections of conntrack and takes them back; it is the
# "daemon" of the rest of bmcHwAccel, as cmm is on the LS1046.
#
# BMCHWACCEL_LAYOUT, BMCHWACCEL_ENGINE_CTL and BMCHWACCEL_DAEMON_INITD replace the layout script of
# bmcHwAccelDpdk, the client of the engine's control socket and the init script of the daemon, for tests.

layout_cmd=${BMCHWACCEL_LAYOUT:-/usr/lib/bmcHwAccelDpdk/layout}
engine_ctl=${BMCHWACCEL_ENGINE_CTL:-/usr/sbin/bmchwaccel-ctl}

# The daemon's own init script is disabled (uci-defaults): bmcHwAccel starts and stops it according to
# "enabled", in the engine layout once the engine answers (./supervise-engine applies then). The daemon claims
# the engine; when it stops or dies the engine lets go of every Kết nối đã tăng tốc, which continue through
# the kernel. A daemon that starts, or claims an engine that was started again, hands every open connection
# over. procd runs it under ./supervise, which handles a daemon that dies by itself.
daemon_initd=${BMCHWACCEL_DAEMON_INITD:-/etc/init.d/bmchwaccel-syncd}

# Whether procd runs the daemon. BMCHWACCEL_UBUS replaces ubus with a script, for tests.
daemon_running() {
	"${BMCHWACCEL_UBUS:-ubus}" -t 5 call service list '{"name":"bmchwaccel-syncd"}' 2>/dev/null |
		grep -q '"running": *true'
}

daemon_stopped() {
	! daemon_running
}

# The daemon answers once it holds its session with the engine.
daemon_answers() {
	[ "$("$engine_ctl" claimed 2>/dev/null)" = 'ok yes' ]
}

# A daemon is started only on an engine that answers.
control_device_ready() {
	[ -n "$(accelerated_count)" ]
}

# The layout of this boot: engine or kernel.
layout_now() {
	"$layout_cmd" current 2>/dev/null || echo kernel
}

# Why the next boot is in the kernel layout even when enabled: "engine <text>", "boot_skipped" or nothing.
layout_reason() {
	"$layout_cmd" reason 2>/dev/null || true
}

# Why this boot only is in the kernel layout although enabled, or nothing.
layout_skipped() {
	"$layout_cmd" skipped 2>/dev/null || true
}

# Number of Kết nối đã tăng tốc, or nothing when no engine answers.
accelerated_count() {
	[ "$(layout_now)" = engine ] || return 0
	"$engine_ctl" count 2>/dev/null | awk '/^ok [0-9]+$/ { print $2 }'
}

# Lets go of every Kết nối đã tăng tốc: they continue through the kernel.
engine_empty() {
	"$engine_ctl" flush >/dev/null 2>&1 || true
}

# On while the engine answers and the daemon hands it connections (enabled), or while the engine still holds
# connections (disabled, not applied yet).
accelerated_now() {
	count=$(accelerated_count)
	[ -n "$count" ] || return 0
	if [ "$enabled" = 0 ]; then
		[ "$count" = 0 ] || echo "$count"
	elif daemon_answers; then
		echo "$count"
	fi
}

# The engine lets go of what it holds once the daemon's session closed; one that does not answer holds nothing.
engine_holds_nothing() {
	count=$(accelerated_count)
	[ -z "$count" ] || [ "$count" = 0 ]
}

# Enabled, but nothing accelerated: in the engine layout the engine does not answer, or no daemon hands it
# connections; in the kernel layout the boots before failed or this boot had not the memory, or nothing when
# the router waits for a restart.
unavailable_reason() {
	if [ "$(layout_now)" = engine ]; then
		if [ -n "$(accelerated_count)" ]; then echo daemon; else echo restarting; fi
		return
	fi
	reason=$(layout_reason)
	[ -n "$reason" ] || [ -z "$(layout_skipped)" ] || reason=engine
	echo "${reason%% *}"
}

reason_text() {
	case "$1" in
		boot_skipped) echo 'two boots in a row did not finish starting it; enable it to try again' ;;
		engine)
			reason=$(layout_reason)
			if [ -n "$reason" ]; then
				echo "${reason#engine }; the router restarted without it; enable it to try again"
			else
				# The next boot tries again: reboot_check says so.
				echo "this boot is without it: $(layout_skipped)"
			fi
			;;
		restarting) echo 'it is not running; it is being started again' ;;
		daemon) echo 'its service is not running' ;;
	esac
}

# The layout the next boot builds: the engine layout when enabled and no boot before failed, or when $1 is
# "retry" (`enable` forgets those boots).
layout_next() {
	if [ "$enabled" = 1 ] && { [ "${1:-}" = retry ] || [ -z "$(layout_reason)" ]; }; then
		echo engine
	else
		echo kernel
	fi
}

engine_reboots=1
reboot_check() {
	reboot_required=0
	reboot_text=
	next=$(layout_next "$@")
	[ "$(layout_now)" != "$next" ] || return 0
	reboot_required=1
	if [ "$next" = engine ]; then
		reboot_text='it takes effect after a restart'
	else
		reboot_text='restart the router to remove it completely'
	fi
}

engine_retry() {
	"$layout_cmd" retry
}

# Sets apply_action and apply_commands (one per line). Enabled: in the engine layout the daemon is started
# when the engine answers and procd does not run it, after the rules of what is kept on the CPU when the
# firewall lost them (keep.sh), as on the LS1046; nothing while the engine does not answer: its supervisor
# applies once it does. "skip" in the kernel layout of a failed boot, unless $1 is "retry". Disabled: the
# daemon is stopped, and the engine lets go of what it holds when its session closes; an engine that holds
# connections without a daemon is told to let go of them ("stop").
apply_plan() {
	apply_action=none
	apply_commands=
	if [ "$enabled" = 1 ]; then
		if [ "$(layout_now)" = kernel ]; then
			[ "${1:-}" = retry ] || [ -z "$(unavailable_reason)" ] || apply_action=skip
		elif [ -n "$(accelerated_count)" ] && ! daemon_running; then
			keep_restore_plan
			apply_commands="$keep_restore$daemon_initd start$newline"
			apply_action=start
		fi
	elif daemon_running; then
		apply_action=stop
		apply_commands="$daemon_initd stop$newline"
	elif count=$(accelerated_count) && [ -n "$count" ] && [ "$count" != 0 ]; then
		apply_action=stop
		apply_commands="bmchwaccel-ctl flush$newline"
	fi
}

# Executes the plan and logs the change of state it made; on error sets apply_error, and apply_reason when
# Tăng tốc phần cứng is left unavailable. Without a plan the state is logged once it changed: on in the
# engine layout once its daemon answers (./supervise-engine logs it at boot), off when disabled, enabled
# for the next boot in the kernel layout. The exit codes of the init script say little, so the outcome is
# checked on the running system instead.
apply_execute() {
	apply_error=
	apply_reason=
	while IFS= read -r planned; do
		[ -n "$planned" ] || continue
		case "$planned" in
			bmchwaccel-ctl\ *) "$engine_ctl" ${planned#bmchwaccel-ctl } >/dev/null 2>&1 </dev/null || true ;;
			"$daemon_initd start")
				# Never a daemon without the rules of what is kept on the CPU.
				[ -z "${keep_devices:-}" ] || keep_installed "$keep_devices" || break
				$planned >/dev/null 2>&1 </dev/null || true
				;;
			*) $planned >/dev/null 2>&1 </dev/null || true ;;
		esac
	done <<EOF_COMMANDS
$apply_commands
EOF_COMMANDS
	case "$apply_action" in
		start)
			wait_until "$start_wait" daemon_answers ||
				apply_unavailable 'Tăng tốc phần cứng failed to start' || return 1
			state_switch on
			;;
		stop)
			apply_error='Tăng tốc phần cứng failed to stop'
			wait_until "$stop_wait" daemon_stopped || return 1
			wait_until "$stop_wait" engine_holds_nothing || return 1
			apply_error=
			state_switch off
			;;
		skip) apply_unavailable 'Tăng tốc phần cứng is unavailable' || return 1 ;;
		none)
			if [ -n "$(accelerated_now)" ]; then
				state_note on
			elif [ "$enabled" = 1 ] && [ "$(layout_now)" = kernel ] && [ "$(layout_next)" = engine ]; then
				state_note restart
			elif [ "$enabled" = 0 ] && [ -n "$(state_noted)" ]; then
				state_note off
			fi
			;;
	esac
}

# The ports the engine holds in the engine layout, as their cables see them: the kernel's port of each
# (dpni.Z) sees only what goes through the kernel, and its link is the one to the engine, without a speed.
# None in the kernel layout, nor while the engine does not answer.
engine_ports() {
	ports_json='[]'
	if [ "$(layout_now)" != engine ]; then
		ports_text='Tăng tốc phần cứng holds no port in this boot: the kernel counts all traffic of every port'
		return
	fi
	ports_text='Tăng tốc phần cứng does not answer: the counters of its ports cannot be read now'
	answer=$("$engine_ctl" ports 2>/dev/null) || return 0
	# "port NAME link=up speed=MBPS|unknown rx_bytes=N tx_bytes=N rx_packets=N tx_packets=N" each, then "ok";
	# anything else is not an answer
	json=$(printf '%s\n' "$answer" | awk '
		$0 == "ok" { ok = 1; next }
		!(NF == 8 && $1 == "port" && $2 ~ /^[A-Za-z0-9._-]+$/ && $3 ~ /^link=(up|down)$/ &&
		$4 ~ /^speed=([0-9]+|unknown)$/ && $5 ~ /^rx_bytes=[0-9]+$/ && $6 ~ /^tx_bytes=[0-9]+$/ &&
		$7 ~ /^rx_packets=[0-9]+$/ && $8 ~ /^tx_packets=[0-9]+$/) { bad = 1; next }
		{
			for (i = 3; i <= 8; i++) {
				eq = index($i, "=")
				v[i] = substr($i, eq + 1)
			}
			if (v[4] == "unknown") v[4] = "\"unknown\""
			list = list (n++ ? "," : "") sprintf("{\"interface\":\"%s\",\"link\":\"%s\",\"speed\":%s,\"rx_bytes\":%s,\"tx_bytes\":%s,\"rx_packets\":%s,\"tx_packets\":%s}", $2, v[3], v[4], v[5], v[6], v[7], v[8])
		}
		END { if (!ok || bad) exit 1; printf "[%s]", list }') || return 0
	ports_json=$json
	ports_text='the ports Tăng tốc phần cứng holds: link, speed and counters of their cables'
}

# The SAs of Tunnel IPsec the engine holds (bmchwaccel-syncd hands them over), from its `sa`: each with "spi",
# "dir" (in or out), "reqid" (the tunnel), "peer" (the other end), "bytes" and "packets" the engine encrypted
# or decrypted on its own, and "seq" (the highest number an outbound one may have used). None in the kernel
# layout, nor while the engine does not answer.
engine_sas() {
	sas_json='[]'
	sas_count=0
	if [ "$(layout_now)" != engine ]; then
		sas_text='Tăng tốc phần cứng holds no key of Tunnel IPsec in this boot: every tunnel goes through the kernel'
		return
	fi
	sas_text='Tăng tốc phần cứng does not answer: its keys of Tunnel IPsec cannot be read now'
	answer=$("$engine_ctl" sa 2>/dev/null) || return 0
	# "sa spi=0xSPI dir=out|in reqid=N src=A dst=B bytes=N packets=N [seq=N] failed=N dropped=N" each, then
	# "ok N"; anything else is not an answer
	json=$(printf '%s\n' "$answer" | awk '
		$1 == "ok" && NF == 2 && $2 ~ /^[0-9]+$/ { ok = 1; n_said = $2; next }
		!($1 == "sa" && $2 ~ /^spi=0x[0-9a-f]+$/ && $3 ~ /^dir=(in|out)$/ && $4 ~ /^reqid=[0-9]+$/ &&
		$5 ~ /^src=[0-9.]+$/ && $6 ~ /^dst=[0-9.]+$/ && $7 ~ /^bytes=[0-9]+$/ && $8 ~ /^packets=[0-9]+$/ &&
		(($3 == "dir=out" && NF == 11 && $9 ~ /^seq=[0-9]+$/) || ($3 == "dir=in" && NF == 10))) { bad = 1; next }
		{
			for (i = 2; i <= NF; i++) {
				eq = index($i, "=")
				v[substr($i, 1, eq - 1)] = substr($i, eq + 1)
			}
			peer = v["dir"] == "out" ? v["dst"] : v["src"]
			s = sprintf("{\"spi\":\"%s\",\"dir\":\"%s\",\"reqid\":%s,\"peer\":\"%s\",\"bytes\":%s,\"packets\":%s", v["spi"], v["dir"], v["reqid"], peer, v["bytes"], v["packets"])
			if (v["dir"] == "out") s = s sprintf(",\"seq\":%s", v["seq"])
			list = list (n++ ? "," : "") s "}"
		}
		END { if (!ok || bad || n != n_said) exit 1; printf "%d [%s]", n, list }') || return 0
	sas_count=${json%% *}
	sas_json=${json#* }
	sas_text='the keys of Tunnel IPsec Tăng tốc phần cứng holds: what it encrypted and decrypted of each'
}

# The options of the engine, read at boot (layout): "workers", 1 to 4, and the list "port" of the MACs it
# holds. A value that is not valid is an error with "field"; the boot uses the default instead.
max_workers=4
default_ports='dpmac.1 dpmac.2'
engine_config() {
	config_error=
	config_field=
	workers=$(uci_get bmchwaccel.global.workers)
	case "$workers" in
		'') workers=$max_workers ;;
		[1-9]) [ "$workers" -gt "$max_workers" ] || workers=ok:$workers ;;
	esac
	case "$workers" in
		ok:*) workers=${workers#ok:} ;;
		"$max_workers") ;;
		*)
			config_error="workers must be from 1 to $max_workers: $workers; the next boot runs $max_workers"
			config_field=workers
			workers=$max_workers
			;;
	esac
	ports=$(uci_get bmchwaccel.global.port)
	for port in $ports; do
		case "$port" in
			dpmac.[1-9]|dpmac.[1-9][0-9]) ;;
			*)
				[ -n "$config_error" ] || {
					config_error="port must list MACs such as dpmac.1: $port; the next boot uses $default_ports"
					config_field=port
				}
				ports=
				break
				;;
		esac
	done
	[ -n "$ports" ] || ports=$default_ports
	config_json=",\"workers\":$workers,\"port\":$(printf '%s\n' $ports | json_strings)"
}
