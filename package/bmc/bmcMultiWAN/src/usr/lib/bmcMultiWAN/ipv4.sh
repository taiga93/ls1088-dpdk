# IPv4 arithmetic. 32-bit integers are handled in awk because ash does not guarantee 64-bit arithmetic.

ipv4_valid() {
	printf '%s\n' "$1" | awk -F . 'NF == 4 {
		for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i + 0 > 255) exit 1
		exit 0
	} { exit 1 }'
}

# First line of $1 that is not an IPv4 address, or nothing. Once every line is valid, the list can be split
# on whitespace safely.
first_invalid_ipv4() {
	printf '%s' "$1" | while IFS= read -r ip; do
		if ! ipv4_valid "$ip"; then
			printf '%s' "$ip"
			break
		fi
	done
}

ipv4_to_int() {
	printf '%s\n' "$1" | awk -F . '{ printf "%.0f", $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 }'
}

ipv4_from_int() {
	awk -v n="$1" 'BEGIN {
		printf "%d.%d.%d.%d", int(n / 16777216) % 256, int(n / 65536) % 256, int(n / 256) % 256, n % 256
	}'
}

ipv4_prefix_to_mask() {
	ipv4_from_int "$(awk -v p="$1" 'BEGIN { printf "%.0f", 4294967296 - 2 ^ (32 - p) }')"
}

# Prints the prefix length of a dotted-quad netmask; prints nothing when the mask is not contiguous.
ipv4_mask_to_prefix() {
	ipv4_valid "$1" || return 0
	awk -v n="$(ipv4_to_int "$1")" 'BEGIN {
		for (p = 0; p <= 32; p++) if (4294967296 - 2 ^ (32 - p) == n) { print p; exit }
	}'
}

# Networks $1/$2 and $3/$4 overlap when they are the same network under the shorter prefix.
ipv4_subnets_overlap() {
	awk -v a="$(ipv4_to_int "$1")" -v pa="$2" -v b="$(ipv4_to_int "$3")" -v pb="$4" 'BEGIN {
		size = 2 ^ (32 - (pa < pb ? pa : pb))
		exit int(a / size) == int(b / size) ? 0 : 1
	}'
}

# Network address of $1/$2 (host bits cleared).
ipv4_network() {
	ipv4_from_int "$(awk -v a="$(ipv4_to_int "$1")" -v p="$2" 'BEGIN { size = 2 ^ (32 - p); printf "%.0f", int(a / size) * size }')"
}
