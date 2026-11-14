# Chuyển WAN next to Tăng tốc phần cứng: the connections of a WAN that is Mất Internet or lost its link are
# removed.
#
# mwan3 leaves open connections on the WAN they use: each carries the mark of its WAN in its conntrack mark,
# and the mark of a packet, taken from there, selects the routing table of that WAN. For a WAN that is Mất
# Internet mwan3 changes neither a route nor an ip rule, only the chains that choose a WAN for new connections.
# The daemon of Tăng tốc phần cứng follows routes, so it is told nothing: a Kết nối đã tăng tốc would stay in
# the hardware and keep flowing into that WAN for as long as its sender goes on. When the link is lost mwan3
# removes the table of the WAN, and the daemon would move the connection to the route of the main table, out
# of another WAN with the source address of the lost one.
#
# The daemon takes a connection out of the hardware when its conntrack entry goes. So at such a Chuyển WAN
# every conntrack entry with the mark of the WAN is deleted: what the sender transmits next is a new
# connection, which mwan3 gives to the WAN that now carries the Chính sách WAN. Connections kept on the CPU go
# the same way; which entries are in the hardware cannot be asked per WAN. Without Tăng tốc phần cứng nothing
# is deleted, as before. A WAN that has Internet again loses nothing: connections stay on the WAN they use.

# Whether the daemon of Tăng tốc phần cứng runs: only then is anything in the hardware. bmcHwAccel says so, for
# whichever board it runs on (cmm on the LS1046, bmchwaccel-syncd on the LS1088); a router without it has
# nothing in the hardware. BMCMULTIWAN_HWACCEL_DAEMON replaces its query, for tests.
hwaccel_daemon=${BMCMULTIWAN_HWACCEL_DAEMON:-/usr/lib/bmcHwAccel/daemon-running}

hwaccel_running() {
	[ -x "$hwaccel_daemon" ] && "$hwaccel_daemon" >/dev/null 2>&1
}

# Sets flush_mark, the "mark/mask" of the connections to remove of WAN $1, whose new state is $2; empty when
# nothing has to go.
flush_plan() {
	flush_mark=
	case "$2" in
		lost|link_down) ;;
		*) return 0 ;;
	esac
	hwaccel_running || return 0
	flush_mark=$(mwan3_wan_mark "$1")
}

# The plan as the command it runs, for the reply.
flush_plan_commands() {
	[ -z "$flush_mark" ] || printf 'conntrack -D --mark %s\n' "$flush_mark"
}

# Executes the plan for WAN $1 and logs how many connections went. conntrack reports the number on stderr, and
# fails when there was none to delete; a router without conntrack gets a line that says so.
flush_execute() {
	[ -n "$flush_mark" ] || return 0
	if ! command -v conntrack >/dev/null 2>&1; then
		logger -t bmcMultiWAN "Chuyển WAN: the connections through $1 could not be removed: no conntrack on this router"
		return 0
	fi
	flush_removed=$({ conntrack -D --mark "$flush_mark" 2>&1 >/dev/null || true; } |
		awk '/flow entries have been deleted/ { for (i = 1; i < NF; i++) if ($(i + 1) == "flow") n += $i } END { print n + 0 }')
	logger -t bmcMultiWAN "Chuyển WAN: $flush_removed connections through $1 removed, so that none stays accelerated towards it"
}
