# `status` and `event`: state of each WAN, and the log of every Chuyển WAN.
#
# Runtime files of bmcmultiwan live in /var/run/bmcMultiWAN (tmpfs, never in UCI):
#   state/<wan>    state of the WAN at its last event: online, lost (Mất Internet) or link_down
#   last_switch    "<unix time> <wan> <state>" of the last Chuyển WAN

run_dir=${BMCMULTIWAN_RUN_DIR:-/var/run/bmcMultiWAN}

# WANs checked by mwan3: enabled IPv4 interfaces of /etc/config/mwan3, in configuration order.
mwan3_wans() {
	for wan in $(uci_sections mwan3 interface); do
		[ "$(uci_get "mwan3.$wan.enabled")" = 1 ] || continue
		case "$(uci_get "mwan3.$wan.family")" in
			''|ipv4) printf '%s\n' "$wan" ;;
		esac
	done
}

# mwan3track's STATUS of WAN $1 (online, offline, disconnecting, connecting, disabled), or nothing.
track_status() {
	cat "${BMCMULTIWAN_TRACK_DIR:-/var/run/mwan3track}/$1/STATUS" 2>/dev/null || true
}

# Internet state of WAN $1 from mwan3track: online, lost (Mất Internet) or unknown (no result yet, or the
# interface is down and its checks are paused). A WAN failing its first checks (disconnecting) still carries
# traffic, and a WAN passing its first checks (connecting) does not yet.
wan_internet_state() {
	case "$(track_status "$1")" in
		online|disconnecting) echo online ;;
		offline|connecting) echo lost ;;
		*) echo unknown ;;
	esac
}

# Sets wan_link (up|down) and wan_ip (first IPv4 address, or empty) of WAN $1 from netifd. ubus waits at most
# 5 s; an interface netifd does not know, or no answer, means no link.
wan_link_load() {
	wan_link=down wan_ip=
	iface_status=$("${BMCMULTIWAN_UBUS:-ubus}" -t 5 call "network.interface.$1" status 2>/dev/null) || return 0
	# ubus prints one key per line, indented by tabs: top-level keys have one tab. "inactive" holds an
	# ipv4-address list of its own, one level deeper.
	wan_link_ip=$(printf '%s\n' "$iface_status" | awk '
		/^\t"up": true/ { up = 1 }
		/^\t"ipv4-address": \[/ { in_list = 1; next }
		in_list && /^\t\]/ { in_list = 0 }
		in_list && ip == "" && /"address": "/ { ip = $0; sub(/.*"address": "/, "", ip); sub(/".*/, "", ip) }
		END { print (up ? "up" : "down") " " ip }')
	wan_link=${wan_link_ip%% *}
	wan_ip=${wan_link_ip#* }
}

# WAN carrying Chính sách WAN $1: its first WAN with link and Internet, from the "wan state" lines on stdin
# (state online, lost, unknown or link_down); nothing when none does (traffic follows the main routing table,
# last_resort default).
policy_carrier() {
	carrier_states=$(cat)
	for wan in $(mwan3_policy_wans "$1"); do
		if printf '%s\n' "$carrier_states" | grep -Fxq -- "$wan online"; then
			printf '%s' "$wan"
			return 0
		fi
	done
}

# One "wan link internet ip" line per WAN of mwan3: link up|down, internet online|lost|unknown (unknown without
# link: the checks are paused), ip empty when none.
wan_rows() {
	for wan in $(mwan3_wans); do
		wan_link_load "$wan"
		internet=unknown
		[ "$wan_link" != up ] || internet=$(wan_internet_state "$wan")
		echo "$wan $wan_link $internet $wan_ip"
	done
}

# "wan state" lines (state online, lost, unknown or link_down) from the wan_rows lines on stdin; WAN $1, when
# given, gets state $2.
rows_to_states() {
	awk -v wan="${1:-}" -v state="${2:-}" 'NF { print $1 " " ($1 == wan ? state : $2 == "up" ? $3 : "link_down") }'
}

# Last Chuyển WAN as JSON, or null.
last_switch_json() {
	last=$(cat "$run_dir/last_switch" 2>/dev/null) || last=
	set -- $last
	case "${1:-}" in
		''|*[!0-9]*) printf null; return 0 ;;
	esac
	printf '{"time":%s,"wan":%s,"state":%s}' "$1" "$(json_string "${2:-}")" "$(json_string "${3:-}")"
}

status_command() {
	if [ "$enabled" != 1 ]; then
		reply -1 'Multi-WAN disabled' ',"enabled":false'
		return
	fi
	if ! mwan3_running; then
		reply -1 'Multi-WAN is not running: run apply' ',"enabled":true'
		return
	fi
	rows=$(wan_rows)
	wans=$(printf '%s\n' "$rows" | while read -r wan link internet ip; do
		[ -n "$wan" ] || continue
		ip_json=null
		[ -z "$ip" ] || ip_json=$(json_string "$ip")
		printf '{"name":%s,"link":"%s","internet":"%s","ip":%s}\n' "$(json_string "$wan")" "$link" "$internet" "$ip_json"
	done | json_array)
	states=$(printf '%s\n' "$rows" | rows_to_states)
	default_wan=$(printf '%s\n' "$states" | policy_carrier "$mwan3_default_policy")
	default_wan_json=null
	[ -z "$default_wan" ] || default_wan_json=$(json_string "$default_wan")
	reply 0 'Multi-WAN status' ",\"wans\":$wans,\"default_policy_wan\":$default_wan_json,\"last_switch\":$(last_switch_json)"
}

# Chính sách WAN using WAN $1 and the WAN each now uses, as "<policy> now uses <wan>" joined by ", ", from the
# "wan state" lines on stdin.
affected_policies() {
	affected_states=$(cat)
	for policy in $(policy_sections); do
		mwan3_policy_wans "$policy" | grep -Fxq -- "$1" || continue
		policy_wan=$(printf '%s\n' "$affected_states" | policy_carrier "$policy")
		printf '%s now uses %s\n' "$policy" "${policy_wan:-the main routing table}"
	done | awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $0 }'
}

# Writes file $1 with content $2 atomically.
run_file_write() {
	mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1.tmp" && mv -f "$1.tmp" "$1"
}

# Internal command of the hook /etc/mwan3.user, run by mwan3 on every hotplug event of a WAN while mwan3 runs:
# ACTION $1 on WAN $2. Logs each Chuyển WAN to syslog (tag bmcMultiWAN) with the Chính sách WAN it affects and
# records it in the runtime files; "commands" is what removes the connections of the WAN
# (flush.sh). The hook runs one event at a time (16-mwan3-user holds procd's lock of mwan3).
#
# The new state of the WAN comes from the event:
#   disconnected   mwan3's hook runs /etc/mwan3.user under `env -i`, so MWAN3_SHUTDOWN is lost: the
#                  "disconnected" sent to every online WAN when mwan3 stops or restarts is told apart by
#                  mwan3track's STATUS, which a real loss sets to `offline` before the event and a stop leaves
#                  `online`. mwan3track also answers an ifdown with "disconnected", before or after netifd's own
#                  ifdown: while the interface is down it is that link loss (state link_down), logged once.
#   connected      Internet again. The first "connected" of a WAN (mwan3 start, link up) is only recorded, unless
#                  the WAN was recorded Mất Internet or without link: traffic then moves back to it (mwan3 starts
#                  every WAN online, initial_state).
#   ifdown         the link of the WAN is lost (netifd): traffic leaves it too, logged as "mất link".
event_command() {
	if [ "$#" -ne 2 ]; then
		reply -1 'usage: event ACTION WAN'
		return
	fi
	action=$1 wan=$2
	case "$wan" in
		''|*[!a-z0-9_]*) reply -1 "no such WAN: $wan"; return ;;
	esac
	if [ "$(uci_get "mwan3.$wan")" != interface ]; then
		reply -1 "no such WAN: $wan"
		return
	fi
	wan_json=",\"wan\":$(json_string "$wan")"
	case "$action" in
		disconnected)
			if [ "$(track_status "$wan")" != offline ]; then
				reply 0 'mwan3 is stopping: not a Chuyển WAN' "$wan_json"
				return
			fi
			wan_link_load "$wan"
			if [ "$wan_link" = up ]; then state=lost; else state=link_down; fi
			;;
		connected) state=online ;;
		ifdown) state=link_down ;;
		*)
			reply 0 "event $action: not a Chuyển WAN" "$wan_json"
			return
			;;
	esac
	recorded=$(cat "$run_dir/state/$wan" 2>/dev/null) || recorded=
	if [ "$state" = link_down ] && [ "$recorded" = link_down ]; then
		reply 0 "WAN $wan link already down: not a Chuyển WAN" "$wan_json"
		return
	fi
	state_json="$wan_json,\"state\":\"$state\""
	if [ "$state" = online ] && [ "$recorded" != lost ] && [ "$recorded" != link_down ]; then
		[ "$dry_run" = 1 ] || run_file_write "$run_dir/state/$wan" "$state"
		reply 0 "WAN $wan has Internet: first check, not a Chuyển WAN" "$state_json"
		return
	fi
	case "$state" in
		lost) text="$wan is Mất Internet" ;;
		online) text="$wan has Internet again" ;;
		link_down) text="$wan mất link" ;;
	esac
	policies=$(wan_rows | rows_to_states "$wan" "$state" | affected_policies "$wan")
	if [ -n "$policies" ]; then
		line="Chuyển WAN: $text; Chính sách WAN $policies"
	else
		line="Chuyển WAN: $text; no Chính sách WAN uses it"
	fi
	flush_plan "$wan" "$state"
	now=${BMCMULTIWAN_NOW:-$(date +%s)}
	if [ "$dry_run" != 1 ]; then
		logger -t bmcMultiWAN "$line"
		run_file_write "$run_dir/state/$wan" "$state"
		run_file_write "$run_dir/last_switch" "$now $wan $state"
		flush_execute "$wan"
	fi
	reply 0 'Chuyển WAN logged' "$state_json,\"log\":$(json_string "$line"),\"time\":$now,\"commands\":$(flush_plan_commands | json_strings)"
}
