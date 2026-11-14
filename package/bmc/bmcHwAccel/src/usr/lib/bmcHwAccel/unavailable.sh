# The syslog line of each change of the state of Tăng tốc phần cứng. Why it is unavailable is the board's
# (engine.sh: unavailable_reason, reason_text).

# The state last logged, and whether the microcode was refused; gone at reboot. BMCHWACCEL_RUN_DIR replaces
# the directory, for tests.
run_dir=${BMCHWACCEL_RUN_DIR:-/var/run/bmcHwAccel}

state_noted() {
	cat "$run_dir/state" 2>/dev/null || true
}

# One syslog line each time Tăng tốc phần cứng goes on, off, or unavailable for the reason $2, or is enabled
# for the next boot ("restart", where a switch takes full effect only then); nothing while the state stays
# what was logged last.
state_note() { # on | off | restart | unavailable <reason>
	noted="$1${2:+ $2}"
	[ "$(state_noted)" != "$noted" ] || return 0
	{
		mkdir -p "$run_dir" && echo "$noted" > "$run_dir/state"
		[ "${2:-}" != microcode ] || : > "$run_dir/microcode-refused"
	} 2>/dev/null || true
	case "$1" in
		unavailable) logger -t bmcHwAccel "Tăng tốc phần cứng unavailable: $(reason_text "$2")" || true ;;
		restart) logger -t bmcHwAccel 'Tăng tốc phần cứng enabled: it takes effect after a restart' || true ;;
		*) logger -t bmcHwAccel "Tăng tốc phần cứng turned $1" || true ;;
	esac
}

# A switch that `apply` just made is logged whatever was logged last.
state_switch() {
	rm -f "$run_dir/state"
	state_note "$1"
}
