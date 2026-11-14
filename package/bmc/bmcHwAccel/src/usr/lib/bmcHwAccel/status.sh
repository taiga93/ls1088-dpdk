# `status`: what the router is doing now. "on": the hardware forwards, whatever "enabled" says. "off":
# disabled, or enabled and waiting for a restart. "unavailable": enabled, but the hardware does not forward;
# "reason" says why (engine.sh). "reboot_required": the router runs another layout than the next boot
# builds (always false where a switch takes effect at once). "ipsec_sa": the keys of Tunnel IPsec the hardware
# holds (engine.sh). "on_cpu": what other features keep on the CPU (keep.sh), whatever the state.

status_command() {
	accelerated=$(accelerated_now)
	reason=
	if [ -n "$accelerated" ]; then
		state=on
	elif [ "$enabled" = 1 ] && reason=$(unavailable_reason) && [ -n "$reason" ]; then
		state=unavailable
	else
		state=off
	fi
	reboot_check
	engine_sas
	kept_load
	message="Tăng tốc phần cứng is $state"
	[ -z "$reason" ] || message="$message: $(reason_text "$reason")"
	[ "$reboot_required" = 0 ] || message="$message; $reboot_text"
	reply 0 "$message" ",\"state\":\"$state\"${reason:+,\"reason\":\"$reason\"},\"enabled\":$(json_bool "$enabled"),\"reboot_required\":$(json_bool "$reboot_required"),\"accelerated\":${accelerated:-0},\"ipsec_sa\":$sas_count,\"on_cpu\":$(kept_json "$kept")"
}
