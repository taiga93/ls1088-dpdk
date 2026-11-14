# Part of `sweep`: the router learns the neighbours of the machines that talk to each other through a bridge.
#
# The daemon hands a connection to the hardware once the kernel has a neighbour entry for each end. For a
# connection the router routes, the kernel resolves the ends itself. For one between two ports of a bridge
# it sends nothing, so it resolves nothing: a machine the router never talked to had no entry, and its
# traffic with another machine of the LAN stayed on the CPU, at half the speed (measured on the board,
# ticket 25: after a boot, until the router pinged the machine). The daemon asks for the address itself, but
# the kernel takes no entry from an answer it did not ask for.
#
# The firewall notes both ends of every connection that is bridged in two ipsets, one per family, and the
# sweep tells the kernel to resolve those it has no entry for (`ip neigh replace ... use`: the kernel sends
# the ARP request or the neighbour solicitation, as for a packet of its own). The daemon sees the new entry
# and hands the connections that waited for it to the hardware, the running ones included (measured: within
# two seconds). After that the daemon keeps the entry alive while a connection uses it.
#
# An address the router has no route to on a link (it would go through a gateway) is left alone, and so are
# a broadcast or multicast address and a link-local IPv6 address, which names no device. An address is
# noted for five minutes after the last connection it was an end of: one that does not answer is asked
# again at each sweep, for that long.
bridged_set=bmchwaccel_bridged
bridged_timeout=300
# Addresses asked for in one sweep, at most.
bridged_most=256

# BMCHWACCEL_IP replaces ip with a stand-in, for tests.
ip_ask() {
	"${BMCHWACCEL_IP:-ip}" "$@"
}

# "<iptables|ip6tables> <set> <family> <end>" of each rule.
bridged_rules() {
	for end in src dst; do
		echo "iptables $bridged_set inet $end"
		echo "ip6tables ${bridged_set}6 inet6 $end"
	done
}

bridged_rule() { # <set> <end>
	echo "-m physdev --physdev-is-bridged -m conntrack --ctstate NEW -j SET --add-set $1 $2 --exist"
}

# The commands that put back what is missing of the sets and the rules. A firewall restart takes the rules
# out, not the sets.
bridged_commands() {
	bridged_rules | while read -r tables name family end; do
		tables_ask ipset -q list -n "$name" || [ "$end" != src ] ||
			echo "ipset -exist create $name hash:ip family $family timeout $bridged_timeout maxelem 65536"
		# shellcheck disable=SC2046
		tables_ask "$tables" -w -t mangle -C FORWARD $(bridged_rule "$name" "$end") ||
			echo "$tables -w -t mangle -A FORWARD $(bridged_rule "$name" "$end")"
	done
}

# The addresses noted, one a line. BMCHWACCEL_BRIDGED replaces the sets with a file, for tests.
bridged_list() {
	if [ -n "${BMCHWACCEL_BRIDGED:-}" ]; then
		cat "$BMCHWACCEL_BRIDGED"
	else
		for name in "$bridged_set" "${bridged_set}6"; do
			ipset list "$name" 2>/dev/null | awk 'members { print $1 } /^Members:/ { members = 1 }'
		done
	fi
}

# The commands that make the kernel resolve the noted addresses it has no neighbour entry for.
neighbours_commands() {
	noted=$(bridged_list | grep -v -i '^fe80:' | sort -u)
	[ -n "$noted" ] || return 0
	{ ip_ask neigh show 2>/dev/null || true; printf '%s\n%s\n' -- "$noted"; } | awk '
		$1 == "--" { noted = 1; next }
		!noted { for (i = 2; i < NF; i++) if ($i == "lladdr") known[$1] = 1; next }
		!known[$1] { print $1 }' | head -n "$bridged_most" | while read -r address; do
		route=$(ip_ask -o route get "$address" 2>/dev/null) || continue
		# The route to a machine on a link begins with the address; one to a broadcast or multicast
		# address, which the firewall notes as well, with that word.
		case "$route" in "$address "*) ;; *) continue ;; esac
		case " $route " in *" via "*) continue ;; esac
		device=$(printf '%s\n' "$route" | sed -n 's/.* dev \([^ ]*\) .*/\1/p')
		[ -z "$device" ] || echo "ip neigh replace $address dev $device use"
	done
}
