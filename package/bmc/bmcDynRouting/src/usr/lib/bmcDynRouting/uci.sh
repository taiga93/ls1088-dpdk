# Đọc UCI qua snapshot `uci -X show` và dựng lệnh cho `uci batch`.
#
# Snapshot được chuẩn hoá thành các dòng "khoá<TAB>giá trị":
#   - dòng khai báo section: khoá "config.section", giá trị là kiểu section;
#   - option: khoá "config.section.option";
#   - list: mỗi phần tử một dòng, cùng khoá.
# `uci show` in list trên một dòng ('a' 'b'), bọc giá trị trong '...' và viết ' thành '\''.
# -X in tên thật (cfgXXXXXX) của section ẩn danh thay vì @type[N], nên tên đó dùng lại được trong batch.

uci_configs='bmcDynRouting network firewall dhcp'

uci_normalize() {
	awk '
	{
		eq = index($0, "=")
		if (!eq) next
		key = substr($0, 1, eq - 1)
		rest = substr($0, eq + 1)
		if (substr(rest, 1, 1) != "\047") { print key "\t" rest; next }
		item = ""; quoted = 0; have = 0
		for (i = 1; i <= length(rest); i++) {
			c = substr(rest, i, 1)
			if (quoted) {
				if (c == "\047") quoted = 0; else item = item c
			} else if (c == "\047") {
				quoted = 1; have = 1
			} else if (c == "\\") {
				i++; item = item substr(rest, i, 1); have = 1
			} else if (c == " ") {
				if (have) print key "\t" item
				item = ""; have = 0
			} else {
				item = item c; have = 1
			}
		}
		if (have) print key "\t" item
	}'
}

# BMCDYNROUTING_SNAPSHOT trỏ tới một file có định dạng `uci -X show` để test chạy không cần uci.
uci_load_snapshot() {
	if [ -n "${BMCDYNROUTING_SNAPSHOT:-}" ]; then
		uci_snapshot=$(uci_normalize < "$BMCDYNROUTING_SNAPSHOT")
	else
		uci_snapshot=$(for config in $uci_configs; do uci -q -X show "$config" || true; done | uci_normalize)
	fi
}

# Giá trị của một option, hoặc kiểu của section nếu khoá là "config.section".
uci_get() {
	printf '%s\n' "$uci_snapshot" | awk -F '\t' -v key="$1" '$1 == key { print $2; exit }'
}

# Option $1 có trong snapshot không (kể cả khi giá trị rỗng).
uci_has() {
	printf '%s\n' "$uci_snapshot" | awk -F '\t' -v key="$1" '$1 == key { found = 1; exit } END { exit !found }'
}

# Các phần tử của một list, mỗi phần tử một dòng.
uci_list() {
	printf '%s\n' "$uci_snapshot" | awk -F '\t' -v key="$1" '$1 == key { print $2 }'
}

uci_list_contains() {
	uci_list "$1" | grep -Fxq -- "$2"
}

# Tên các section có kiểu $2 trong config $1.
uci_sections() {
	printf '%s\n' "$uci_snapshot" | awk -F '\t' -v config="$1" -v type="$2" '
		split($1, part, ".") == 2 && part[1] == config && $2 == type { print part[2] }'
}

# Section đầu tiên kiểu $2 trong config $1 có option $3 bằng $4.
# Với --list, $3 là một list và chỉ cần chứa $4.
uci_find_section() {
	uci_match=option
	if [ "$1" = --list ]; then
		uci_match=list
		shift
	fi
	for uci_section in $(uci_sections "$1" "$2"); do
		if [ "$uci_match" = list ]; then
			uci_list_contains "$1.$uci_section.$3" "$4" || continue
		else
			[ "$(uci_get "$1.$uci_section.$3")" = "$4" ] || continue
		fi
		printf '%s' "$uci_section"
		return 0
	done
}

# Bọc một giá trị tuỳ ý để `uci batch` đọc lại nguyên văn.
uci_quote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

batch_reset() {
	uci_batch=
}

batch_add() {
	uci_batch="$uci_batch$1
"
}

# Chạy batch rồi commit các config $@; nếu lỗi thì revert để không để lại thay đổi dở dang.
batch_commit() {
	if printf '%s' "$uci_batch" | uci batch >/dev/null 2>&1; then
		for config in "$@"; do
			uci commit "$config" || return 1
		done
		return 0
	fi
	for config in "$@"; do
		uci revert "$config" >/dev/null 2>&1 || true
	done
	return 1
}
