# Tính toán IPv4. Số nguyên 32-bit được xử lý trong awk vì ash không bảo đảm số học 64-bit.

ipv4_valid() {
	printf '%s\n' "$1" | awk -F . 'NF == 4 {
		for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i + 0 > 255) exit 1
		exit 0
	} { exit 1 }'
}

ipv4_to_int() {
	printf '%s\n' "$1" | awk -F . '{ printf "%.0f", $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 }'
}

ipv4_from_int() {
	awk -v n="$1" 'BEGIN {
		printf "%d.%d.%d.%d", int(n / 16777216) % 256, int(n / 65536) % 256, int(n / 256) % 256, n % 256
	}'
}

ipv4_prefix_valid() {
	case "$1" in ''|*[!0-9]*) return 1 ;; esac
	[ "${#1}" -le 2 ] && [ "$1" -ge 1 ] && [ "$1" -le 32 ]
}

ipv4_prefix_to_mask() {
	ipv4_from_int "$(awk -v p="$1" 'BEGIN { printf "%.0f", 4294967296 - 2 ^ (32 - p) }')"
}

# In độ dài prefix của một netmask dạng dotted-quad; không in gì nếu mask không liên tục.
ipv4_mask_to_prefix() {
	awk -v n="$(ipv4_to_int "$1")" 'BEGIN {
		for (p = 0; p <= 32; p++) if (4294967296 - 2 ^ (32 - p) == n) { print p; exit }
	}'
}

# Hai mạng $1/$2 và $3/$4 chồng nhau khi cùng network dưới prefix ngắn hơn.
ipv4_subnets_overlap() {
	awk -v a="$(ipv4_to_int "$1")" -v pa="$2" -v b="$(ipv4_to_int "$3")" -v pb="$4" 'BEGIN {
		size = 2 ^ (32 - (pa < pb ? pa : pb))
		exit int(a / size) == int(b / size) ? 0 : 1
	}'
}

# Địa chỉ mạng của $1/$2 (bỏ các bit host).
ipv4_network() {
	ipv4_from_int "$(awk -v a="$(ipv4_to_int "$1")" -v p="$2" 'BEGIN { size = 2 ^ (32 - p); printf "%.0f", int(a / size) * size }')"
}
