# What implements Tăng tốc phần cứng on the router: three kernel modules and a daemon that hands established
# connections to the hardware (NXP ASK, the DPAA1 boards: LS1046). The DPAA2 boards have their own
# engine-dpdk.sh, installed as engine.sh instead of this one (Makefile).
#
# What each engine.sh gives the rest of bmcHwAccel:
#   daemon_initd, daemon_running, daemon_stopped, daemon_answers, accelerated_count, engine_empty,
#   control_device_ready        the daemon that hands connections over (keep.sh, evict.sh, supervise)
#   apply_plan [retry], apply_execute
#                               what `apply` does (service.sh)
#   accelerated_now             the number of Kết nối đã tăng tốc while the router accelerates, nothing
#                               otherwise: "on" (status.sh)
#   unavailable_reason, reason_text
#                               why an enabled Tăng tốc phần cứng does not forward, nothing when it only
#                               waits for a restart
#   engine_reboots, reboot_check [retry]
#                               whether a switch takes full effect only at the next boot; sets
#                               reboot_required (0 or 1) and reboot_text
#   engine_retry                `enable` forgets the boots that failed
#   engine_config               sets config_json (more fields of `get`), config_error and config_field
#   engine_ports                sets ports_json, the JSON array of `ports`, and ports_text, its message
#   engine_sas                  sets sas_json, the JSON array of `sa`, sas_text, its message, and
#                               sas_count, the "ipsec_sa" of `status`

# Load order: cdx drives the hardware, auto_bridge reports bridged flows to the daemon (which exits without
# it), fci carries the daemon's commands to cdx.
engine_modules='cdx auto_bridge fci'

# The daemon's own init script is disabled (uci-defaults): bmcHwAccel starts and stops it according to
# "enabled". A daemon that starts hands the connections that are already open to the hardware. A daemon that
# is stopped first takes every connection out of the hardware (package/ask/cmm/patches); it leaves the kernel
# lenient about their TCP window, which the kernel last saw before they were accelerated. procd runs the
# daemon under ./supervise, which handles a daemon that dies by itself.
daemon_initd=/etc/init.d/cmm

# BMCHWACCEL_SYS_MODULE replaces /sys/module with a directory, for tests.
module_loaded() {
	[ -d "${BMCHWACCEL_SYS_MODULE:-/sys/module}/$1" ]
}

modules_loaded() {
	for module in $engine_modules; do
		module_loaded "$module" || return 1
	done
}

# Whether cdx refused to load because the hardware runs the public microcode (106.x), which cannot hand
# connections to the hardware. BMCHWACCEL_DMESG replaces dmesg with a script, for tests.
microcode_refused() {
	"${BMCHWACCEL_DMESG:-dmesg}" 2>/dev/null | grep -q 'cdx: FMAN firmware .* lacks ASK support'
}

# Whether the device the daemon talks to cdx through is there. The kernel has no devtmpfs: procd creates the
# node a moment after cdx is loaded, and the daemon's init script refuses to start without it.
# BMCHWACCEL_CONTROL_DEVICE replaces the path, for tests.
control_device_ready() {
	[ -e "${BMCHWACCEL_CONTROL_DEVICE:-/dev/cdx_ctrl}" ]
}

# Whether procd runs the daemon. BMCHWACCEL_UBUS replaces ubus with a script, for tests.
daemon_running() {
	"${BMCHWACCEL_UBUS:-ubus}" -t 5 call service list '{"name":"cmm"}' 2>/dev/null | grep -q '"running": *true'
}

# For wait_until: procd no longer runs the daemon.
daemon_stopped() {
	! daemon_running
}

# Number of Kết nối đã tăng tốc (one per connection, both directions together), or nothing when the daemon
# does not answer. The daemon's client always exits 0, so only its output tells. BMCHWACCEL_CMM replaces the
# client with a script, for tests.
accelerated_count() {
	"${BMCHWACCEL_CMM:-cmm}" -c 'show stat connection query' 2>/dev/null |
		awk '/^Number of Active Connections:/ && $5 ~ /^[0-9]+$/ { print $5; exit }'
}

daemon_answers() {
	[ -n "$(accelerated_count)" ]
}

# Takes every Kết nối đã tăng tốc out of the hardware after a daemon died with them in it. The daemon's
# binary does it without a daemon, and refuses while one runs (package/ask/cmm/patches).
engine_empty() {
	"${BMCHWACCEL_CMM:-cmm}" -R >/dev/null 2>&1 || true
}

# The mark of a module load in progress. It has to outlive a reboot, and a sysupgrade drops it, so a new
# firmware is tried again. BMCHWACCEL_STATE_DIR replaces the directory, for tests.
load_mark=${BMCHWACCEL_STATE_DIR:-/etc/bmcHwAccel}/loading

# The mark is written before the modules are loaded and removed once the load has returned, whatever came
# of it. It holds the number of loads in a row that never returned: the router crashed or hung in them.
load_attempts() {
	[ -e "$load_mark" ] || { echo 0; return; }
	attempts=$(cat "$load_mark" 2>/dev/null) || attempts=
	# A mark that a crash left empty or garbled still stands for one load.
	case "$attempts" in ''|*[!0-9]*) attempts=1 ;; esac
	echo "$attempts"
}

load_begin() {
	mkdir -p "${load_mark%/*}"
	echo "$(($(load_attempts) + 1))" > "$load_mark"
	sync
}

load_end() {
	[ -e "$load_mark" ] || return 0
	rm -f "$load_mark"
	sync
}

# After two loads in a row that never returned, the next ones are not tried: the router boots and forwards on
# the CPU, and nobody needs the serial console. `bmchwaccel enable` removes the mark.
load_skipped() {
	[ "$(load_attempts)" -ge 2 ] && ! modules_loaded
}

# Why an enabled Tăng tốc phần cứng does not forward:
#   boot_skipped    the modules are not loaded after two failed boots in a row
#   microcode       the hardware runs the public microcode, which the modules refuse
#   module          a module did not load, for another reason
#   daemon          the daemon does not run, or does not answer
# The kernel log loses the refusal on a router that has been up for long, and the microcode cannot change
# without a reboot: the first failed start that sees the refusal leaves a file that remembers it.
unavailable_reason() {
	if load_skipped; then
		echo boot_skipped
	elif modules_loaded; then
		echo daemon
	elif [ -e "$run_dir/microcode-refused" ] || microcode_refused; then
		echo microcode
	else
		echo module
	fi
}

# The reason $1 in words, for "message" and syslog.
reason_text() {
	case "$1" in
		boot_skipped) echo 'not started after two failed boots in a row; enable it to try again' ;;
		microcode) echo 'the microcode of the network hardware does not support it' ;;
		module) echo 'its kernel modules did not load' ;;
		daemon) echo 'its service is not running' ;;
	esac
}

# Sets apply_action (start|stop|skip|none) and apply_commands (one per line) from "enabled" and what is
# loaded and running. Stopping leaves the modules in the kernel; the daemon takes every Kết nối đã tăng tốc
# out of the hardware before it goes (engine.sh), so open connections continue on the CPU. "skip": the
# modules are not loaded after two failed boots in a row (unavailable.sh), unless $1 is "retry".
# A daemon that starts hands every open connection to the hardware: when the firewall lost the rules of what
# is kept on the CPU (keep.sh), they are put back first, and every open connection is kept.
apply_plan() {
	apply_action=none
	apply_commands=
	if [ "$enabled" = 1 ] && [ "${1:-}" != retry ] && load_skipped; then
		apply_action=skip
	elif [ "$enabled" = 1 ]; then
		for module in $engine_modules; do
			module_loaded "$module" || apply_commands="${apply_commands}modprobe $module$newline"
		done
		if ! daemon_running; then
			keep_restore_plan
			apply_commands="$apply_commands$keep_restore$daemon_initd start$newline"
		fi
		[ -z "$apply_commands" ] || apply_action=start
	elif daemon_running; then
		apply_action=stop
		apply_commands="$daemon_initd stop$newline"
	fi
}

# Executes the plan and logs the change of state it made; on error sets apply_error, and apply_reason when
# Tăng tốc phần cứng is left unavailable. The exit codes of modprobe and of the init script say little, so
# the outcome is checked on the running system instead.
apply_execute() {
	apply_error=
	apply_reason=
	loading=0
	while IFS= read -r planned; do
		[ -n "$planned" ] || continue
		case "$planned" in
			modprobe\ *)
				# A load that takes the router down leaves the mark behind (unavailable.sh).
				[ "$loading" = 1 ] || load_begin
				loading=1
				;;
			"$daemon_initd start")
				# Never a daemon without the rules of what is kept on the CPU.
				[ -z "${keep_devices:-}" ] || keep_installed "$keep_devices" || break
				wait_until "$device_wait" control_device_ready || break
				;;
		esac
		$planned >/dev/null 2>&1 </dev/null || true
		# Nothing after a module that did not load can work.
		case "$planned" in
			modprobe\ *) module_loaded "${planned#modprobe }" || break ;;
		esac
	done <<EOF_COMMANDS
$apply_commands
EOF_COMMANDS
	[ "$loading" = 0 ] || load_end
	case "$apply_action" in
		start)
			modules_loaded && wait_until "$start_wait" daemon_answers ||
				apply_unavailable 'Tăng tốc phần cứng failed to start' || return 1
			state_switch on
			;;
		stop)
			apply_error='Tăng tốc phần cứng failed to stop'
			wait_until "$stop_wait" daemon_stopped || return 1
			apply_error=
			state_switch off
			;;
		skip) apply_unavailable 'Tăng tốc phần cứng is unavailable' || return 1 ;;
		none)
			# Disabled while it was unavailable: no longer so.
			[ "$enabled" = 1 ] || [ -z "$(state_noted)" ] || state_note off
			;;
	esac
}

accelerated_now() {
	! daemon_running || accelerated_count
}

# A switch takes effect at once: no restart is ever required.
engine_reboots=0
reboot_check() {
	reboot_required=0
	reboot_text=
}

engine_retry() {
	load_end
}

# The hardware holds no port: the kernel counts what it forwards for each port as well.
engine_ports() {
	ports_json='[]'
	ports_text='Tăng tốc phần cứng holds no port: the kernel counts all traffic of every port'
}

# The keys of Tunnel IPsec the hardware holds: none yet on this board (its ticket 24 of IPsec), every tunnel
# goes through the kernel.
engine_sas() {
	sas_json='[]'
	sas_count=0
	sas_text='Tăng tốc phần cứng holds no key of Tunnel IPsec: every tunnel goes through the kernel'
}

engine_config() {
	config_json=
	config_error=
	config_field=
}
