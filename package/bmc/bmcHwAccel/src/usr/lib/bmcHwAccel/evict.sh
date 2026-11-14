# `sweep`: the connections that a feature blocks by MAC address or by membership of an ipset are taken out of
# the hardware.
#
# macfilter and client_control drop packets by their source MAC address, client_control only at set hours;
# the blocked services of bmcfirewall drop what goes to the addresses of a service, and bmcfido what comes
# from a machine that has not signed in. A Kết nối đã tăng tốc does not pass their rules any more: a connection that was open when the rule started
# to block went on in the hardware until it ended (measured on the board, ticket 25). Connections opened
# later are not the trouble: their first packet always meets the rule.
#
# The daemon hands a connection to the hardware from what conntrack knows, and takes it out when conntrack
# drops it. So the conntrack entries of a blocked machine are deleted: its next packet is on the CPU again,
# meets the rule, and opens nothing. Stopping the daemon would not do: started again, it hands the same
# entries back.
#
# Who is blocked now is said by the features, one program per feature in ./blocked.d, which prints
#   block <MAC>           every packet of that machine is dropped: all its connections go
#   allowlist             only the machines of the `allow` lines may open connections ...
#   allow <MAC>           ... so of every other machine, the connections it opened go
#   to <set> <MAC>        what that machine sends to a member of the ipset <set> is dropped: its connections
#                         with such a member go
#   to <set> any          the same for every machine ...
#   own <MAC>             ... but those, which have `to` lines of their own
#   only <cidr> <set>     of the machines with an IPv4 address in <cidr>, only the members of the ipset <set>
#                         may send: a machine that is no member any more loses all its connections ...
#   also <address>        ... unless it has this address
# A feature runs `sweep` when its rules changed; cron runs it every minute, which is what makes a rule
# of client_control take hold when its hour begins, a minute late at most.
#
# conntrack knows addresses, not MAC addresses. The firewall notes the pair of every machine that opens a
# connection through the router in an ipset (the first packet of a connection is always on the CPU), and the
# neighbour table has those the router itself talks to. A connection of a blocked machine to the router
# itself is deleted as well; the kernel picks it up again with its next packet (nf_conntrack_tcp_loose).
#
# The `to` lines need the connections themselves: conntrack is listed once in a sweep, and only while a set
# named in such a line has a member. The `only` lines would name every machine that never was a member, at
# each sweep: what the set held at the last sweep is kept in $run_dir, and a machine goes once, when it has
# left the set (the first sweep of a set takes every machine that is not in it).
blocked_dir=${BMCHWACCEL_BLOCKED_DIR:-/usr/share/bmcHwAccel/blocked.d}
hosts_set=bmchwaccel_hosts
# A machine is remembered for a week after the last connection it opened.
hosts_timeout=604800

# Whether the firewall notes who opens connections. A firewall restart takes the rule out, not the set.
hosts_installed() {
	tables_ask ipset -q list -n "$hosts_set" &&
		tables_ask iptables -w -t mangle -C FORWARD -m conntrack --ctstate NEW -j SET --add-set "$hosts_set" src,src --exist
}

hosts_commands() {
	echo "ipset -exist create $hosts_set hash:ip,mac timeout $hosts_timeout maxelem 65536"
	echo "iptables -w -t mangle -A FORWARD -m conntrack --ctstate NEW -j SET --add-set $hosts_set src,src --exist"
}

# "<address> <mac>" of every machine known, MAC addresses in lower case. BMCHWACCEL_HOSTS replaces the set
# and the neighbour table with a file, for tests.
hosts_list() {
	if [ -n "${BMCHWACCEL_HOSTS:-}" ]; then
		cat "$BMCHWACCEL_HOSTS"
	else
		ipset list "$hosts_set" 2>/dev/null | awk '$1 ~ /^[0-9.]+,[0-9A-Fa-f:]+$/ { split($1, pair, ","); print pair[1], pair[2] }'
		ip neigh show 2>/dev/null | awk '{ for (i = 2; i < NF; i++) if ($i == "lladdr") print $1, $(i + 1) }'
	fi | tr 'A-F' 'a-f' | sort -u
}

# What the features say, checked: nothing else than these kinds of line reaches a command. MAC addresses
# come out in lower case.
blocked_read() {
	for provider in "$blocked_dir"/*; do
		[ -f "$provider" ] || continue
		sh "$provider" 2>/dev/null </dev/null || true
	done | awk '
		function mac(word) { return length(word) == 17 && tolower(word) ~ /^([0-9a-f][0-9a-f]:)+[0-9a-f][0-9a-f]$/ }
		function set(word) { return length(word) <= 31 && word ~ /^[A-Za-z0-9_.-]+$/ }
		function address(word) { return word ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ }
		NF == 2 && ($1 == "block" || $1 == "allow" || $1 == "own") && mac($2) { print $1, tolower($2) }
		NF == 1 && $1 == "allowlist" { print }
		NF == 3 && $1 == "to" && set($2) && $3 == "any" { print }
		NF == 3 && $1 == "to" && set($2) && mac($3) { print $1, $2, tolower($3) }
		NF == 3 && $1 == "only" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ && set($3) { print }
		NF == 2 && $1 == "also" && address($2) { print }' | sort -u
}

# The members of an ipset, one a line. BMCHWACCEL_SETS replaces the kernel's sets with a directory that has
# a file per set, for tests.
set_members() { # <set>
	if [ -n "${BMCHWACCEL_SETS:-}" ]; then
		cat "$BMCHWACCEL_SETS/$1" 2>/dev/null || true
	else
		ipset list "$1" 2>/dev/null | awk 'members { print $1 } /^Members:/ { members = 1 }'
	fi
}

# "<set> <member>" of every set that what is blocked ($1) names.
sets_read() {
	printf '%s\n' "$1" | awk '$1 == "to" { print $2 } $1 == "only" { print $3 }' | sort -u | while read -r name; do
		set_members "$name" | sed "s/^/$name /"
	done
}

# The file that has what a set of an `only` line held at the last sweep.
only_file() { # <set>
	echo "$run_dir/sweep-only-$1"
}

# "<set> <member>" as sets_read gives it, of the sets of the `only` lines at the last sweep; "<set> -" for
# a set that no sweep has seen yet.
only_before() {
	printf '%s\n' "$1" | awk '$1 == "only" { print $3 }' | sort -u | while read -r name; do
		if [ -f "$(only_file "$name")" ]; then
			sed "s/^/$name /" "$(only_file "$name")"
		else
			echo "$name -"
		fi
	done
}

# Keeps what the sets of the `only` lines hold now ($2, from sets_read), and forgets the sets no line names
# any more: such a set is new again when its feature is turned on the next time.
only_remember() {
	mkdir -p "$run_dir" 2>/dev/null || return 0
	names=$(printf '%s\n' "$1" | awk '$1 == "only" { print $3 }' | sort -u)
	for kept in "$run_dir"/sweep-only-*; do
		[ -f "$kept" ] || continue
		case "$newline$names$newline" in
			*"$newline${kept##*/sweep-only-}$newline"*) ;;
			*) rm -f "$kept" ;;
		esac
	done
	for name in $names; do
		printf '%s\n' "$2" | awk -v name="$name" '$1 == name { print $2 }' > "$(only_file "$name")"
	done
}

# From what is blocked ($1), the sets now ($2), the sets of the `only` lines before ($3) and the machines
# known ($4): "all <address>" for a machine whose connections all go, "opened <address>" for one that only
# loses those it opened.
evict_targets() {
	printf '%s\n--\n%s\n--\n%s\n--\n%s\n' "$1" "$2" "$3" "$4" | awk '
		function number(text,    part) {
			split(text, part, ".")
			return ((part[1] * 256 + part[2]) * 256 + part[3]) * 256 + part[4]
		}
		function within(text, cidr,    half, size) {
			split(cidr, half, "/")
			if (half[2] > 32) return 0
			size = 2 ^ (32 - half[2])
			return int(number(text) / size) == int(number(half[1]) / size)
		}
		$1 == "--" { part++; next }
		part == 0 {
			if ($1 == "block") block[$2] = 1
			else if ($1 == "allow") allow[$2] = 1
			else if ($1 == "allowlist") allowlist = 1
			else if ($1 == "only") { only_cidr[++only] = $2; only_set[only] = $3 }
			else if ($1 == "also") also[$2] = 1
			next
		}
		NF != 2 { next }
		part == 1 { member[$1, $2] = 1; next }
		part == 2 { if ($2 == "-") unseen[$1] = 1; else before[$1, $2] = 1; next }
		block[$2] { print "all", $1; next }
		{
			for (i = 1; i <= only; i++) {
				name = only_set[i]
				if ($1 ~ /:/ || also[$1] || (name, $1) in member || !within($1, only_cidr[i])) continue
				if (unseen[name] || (name, $1) in before) { print "all", $1; next }
			}
		}
		allowlist && !allow[$2] { print "opened", $1 }'
}

# The connections now, as conntrack lists them. BMCHWACCEL_CONNTRACK replaces them with a file, for tests.
connections_list() {
	if [ -n "${BMCHWACCEL_CONNTRACK:-}" ]; then
		cat "$BMCHWACCEL_CONNTRACK"
	else
		conntrack -L 2>/dev/null || true
		conntrack -L -f ipv6 2>/dev/null || true
	fi
}

# The commands for the `to` lines of what is blocked ($1), from the sets now ($2) and the machines known
# ($3): one for each pair of a machine and a member that have a TCP or UDP connection. Either direction of
# a connection counts: the rule drops what the machine sends, also as the answering end.
flow_commands() {
	printf '%s\n' "$1" | grep -q '^to ' || return 0
	[ -n "$2" ] || return 0
	{ printf '%s\n--\n%s\n--\n%s\n--\n' "$1" "$2" "$3"; connections_list; } | awk '
		function pair(from, to, by_from, by_to,    count, rule, i, who) {
			if (!(to in rules)) return
			count = split(rules[to], rule, " ")
			for (i = 1; i <= count; i++) {
				who = sender[rule[i]]
				if (who == "any" ? ((from in machine) && own[machine[from]]) : machine[from] != who) continue
				print "conntrack -D" (to ~ /:/ ? " -f ipv6" : ""), by_from, from, by_to, to
				return
			}
		}
		$1 == "--" { part++; next }
		part == 0 {
			if ($1 == "to") { sender[++lines] = $3; of_set[$2] = of_set[$2] " " lines }
			else if ($1 == "own") own[$2] = 1
			next
		}
		part == 1 { if (NF == 2 && ($1 in of_set)) rules[$2] = rules[$2] of_set[$1]; next }
		part == 2 { if (NF == 2) machine[$1] = $2; next }
		$1 != "tcp" && $1 != "udp" { next }
		{
			ends = 0
			for (i = 1; i <= NF && ends < 4; i++)
				if ($i ~ /^(src|dst)=/) end[++ends] = substr($i, 5)
			if (ends < 4) next
			pair(end[1], end[2], "-s", "-d")
			pair(end[3], end[4], "-r", "-q")
		}' | sort -u
}

# The connections a machine opened have its address as the source; those opened towards it, a port forward
# included, have it as the source of the replies.
evict_commands() {
	while read -r scope address; do
		case "$address" in
			*:*) family=' -f ipv6' ;;
			*) family= ;;
		esac
		echo "conntrack -D$family -s $address"
		[ "$scope" != all ] || echo "conntrack -D$family -r $address"
	done
}

# Runs one planned command; of a conntrack call, adds the entries it deleted to sweep_deleted.
sweep_run() {
	case "$1" in
		conntrack\ *)
			said=$($1 2>&1 >/dev/null </dev/null) || true
			deleted=$(printf '%s\n' "$said" | sed -n 's/.* \([0-9][0-9]*\) flow entries have been deleted.*/\1/p')
			sweep_deleted=$((sweep_deleted + ${deleted:-0}))
			;;
		*) $1 >/dev/null 2>&1 </dev/null || true ;;
	esac
}

# Nothing is deleted while the daemon does not run: every connection is on the CPU then, and meets the rules.
sweep_command() {
	sweep_commands=
	evictions=
	hosts_installed || sweep_commands=$(hosts_commands)$newline
	bridged_missing=$(bridged_commands)
	[ -z "$bridged_missing" ] || sweep_commands="$sweep_commands$bridged_missing$newline"
	blocked=
	sets=
	swept=0
	if daemon_running; then
		swept=1
		blocked=$(blocked_read)
		sets=$(sets_read "$blocked")
		if [ -n "$blocked" ]; then
			hosts=$(hosts_list)
			evictions=$(evict_targets "$blocked" "$sets" "$(only_before "$blocked")" "$hosts" | evict_commands
				flow_commands "$blocked" "$sets" "$hosts")
		fi
		[ -z "$evictions" ] || sweep_commands="$sweep_commands$evictions$newline"
		asked=$(neighbours_commands)
		[ -z "$asked" ] || sweep_commands="$sweep_commands$asked$newline"
	fi
	plan=",\"commands\":$(printf '%s' "$sweep_commands" | json_strings)"
	if [ "$dry_run" = 1 ]; then
		reply 0 'Tăng tốc phần cứng: connections of blocked machines to take out' "$plan"
		return
	fi
	[ "$swept" = 0 ] || only_remember "$blocked" "$sets"
	sweep_deleted=0
	while IFS= read -r planned; do
		[ -z "$planned" ] || sweep_run "$planned"
	done <<EOF_COMMANDS
$sweep_commands
EOF_COMMANDS
	[ "$sweep_deleted" = 0 ] ||
		logger -t bmcHwAccel "Tăng tốc phần cứng: $sweep_deleted connection(s) of blocked machines taken out" || true
	reply 0 'Tăng tốc phần cứng: connections of blocked machines taken out' ",\"deleted\":$sweep_deleted$plan"
}
