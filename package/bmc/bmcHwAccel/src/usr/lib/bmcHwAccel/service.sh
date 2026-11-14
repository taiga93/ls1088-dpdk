# `apply`, `enable`, `disable`: Tăng tốc phần cứng runs exactly when it is enabled. How it is started and
# stopped is the board's (engine.sh: apply_plan, apply_execute).

# Seconds the control device gets to appear once cdx is loaded, a started daemon to answer, and a stopped
# daemon to be gone (procd kills it after 5).
device_wait=5
start_wait=10
stop_wait=10

# Waits until the command $2... succeeds, at most $1 seconds.
wait_until() {
	wait_limit=$1
	shift
	waited=0
	until "$@"; do
		[ "$waited" -lt "$wait_limit" ] || return 1
		sleep 1
		waited=$((waited + 1))
	done
}

# On a board where a switch takes full effect only at the next boot (engine_reboots): sets reboot_json, the
# field "reboot_required", and reboot_message, the message $1 with what it means. $2: as reboot_check.
reboot_fields() {
	reboot_message=$1
	reboot_json=
	[ "$engine_reboots" = 1 ] || return 0
	reboot_check ${2:-}
	reboot_json=",\"reboot_required\":$(json_bool "$reboot_required")"
	[ "$reboot_required" = 0 ] || reboot_message="$1; $reboot_text"
}

apply_plan_json() {
	printf ',"action":"%s","commands":%s' "$apply_action" "$(printf '%s' "$apply_commands" | json_strings)"
}

# The plan fails with Tăng tốc phần cứng unavailable: sets apply_reason and apply_error ($1 and why), and
# logs it.
apply_unavailable() {
	apply_reason=$(unavailable_reason)
	apply_error="$1: $(reason_text "$apply_reason")"
	state_note unavailable "$apply_reason"
	return 1
}

# The fields of a failed apply_execute.
apply_failure_json() {
	printf '%s%s' "${apply_reason:+,\"reason\":\"$apply_reason\"}" "$(apply_plan_json)"
}

apply_command() {
	apply_plan
	if [ "$dry_run" = 1 ]; then
		reboot_fields 'Tăng tốc phần cứng plan ready'
		reply 0 "$reboot_message" "$reboot_json$(apply_plan_json)"
	elif ! apply_execute; then
		reply -1 "$apply_error" "$(apply_failure_json)"
	else
		case "$apply_action" in
			start) message='Tăng tốc phần cứng started' ;;
			stop) message='Tăng tốc phần cứng stopped' ;;
			*) message='Tăng tốc phần cứng: nothing to do' ;;
		esac
		reboot_fields "$message"
		reply 0 "$reboot_message" "$reboot_json$(apply_plan_json)"
	fi
}

# `enable` and `disable` ($1: 1 or 0): saves "enabled", then makes it effective as `apply` does. `enable`
# also forgets the boots that failed (engine_retry): it is tried again, now and at the next boots.
switch_command() {
	enabled=$1
	if [ "$enabled" = 1 ]; then message='Tăng tốc phần cứng enabled'; else message='Tăng tốc phần cứng disabled'; fi
	batch_reset
	batch_add 'set bmchwaccel.global=global'
	batch_add "set bmchwaccel.global.enabled='$enabled'"
	if [ "$enabled" = 1 ]; then apply_plan retry; else apply_plan; fi
	extra=",\"enabled\":$(json_bool "$enabled")"
	if [ "$dry_run" = 1 ]; then
		if [ "$enabled" = 1 ]; then reboot_fields "$message" retry; else reboot_fields "$message"; fi
		reply 0 "$reboot_message" ",\"uci_batch\":$(json_string "$uci_batch")$extra$reboot_json$(apply_plan_json)"
		return
	fi
	if ! batch_commit; then
		reply -1 'failed to save the configuration'
		return
	fi
	[ "$enabled" = 0 ] || engine_retry
	if ! apply_execute; then
		reply -1 "Saved, but $apply_error" "$extra$(apply_failure_json)"
	else
		reboot_fields "$message"
		reply 0 "$reboot_message" "$extra$reboot_json$(apply_plan_json)"
	fi
}
