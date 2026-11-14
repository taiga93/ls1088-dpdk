# Reads UCI through a `uci -X show` snapshot and builds commands for `uci batch`.
#
# The snapshot is normalized into "key<TAB>value" lines:
#   - section declaration: key "config.section", value is the section type;
#   - option: key "config.section.option";
#   - list: one line per item, same key.
# `uci show` prints a list on one line ('a' 'b'), wraps values in '...' and writes ' as '\''.
# -X prints the real name (cfgXXXXXX) of anonymous sections instead of @type[N], so it can be reused in a batch.

# network, firewall and bmcHA (Cổng heartbeat) are read to add and delete WANs.
uci_configs='bmcMultiWAN mwan3 network firewall bmcHA'

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

# BMCMULTIWAN_SNAPSHOT points to a file in `uci -X show` format, so that tests run without uci.
uci_load_snapshot() {
	if [ -n "${BMCMULTIWAN_SNAPSHOT:-}" ]; then
		uci_snapshot=$(uci_normalize < "$BMCMULTIWAN_SNAPSHOT")
	else
		uci_snapshot=$(for config in $uci_configs; do uci -q -X show "$config" || true; done | uci_normalize)
	fi
}

# Value of an option, or the section type when the key is "config.section".
uci_get() {
	printf '%s\n' "$uci_snapshot" | awk -F '\t' -v key="$1" '$1 == key { print $2; exit }'
}

# Items of a list, one per line (also works for an option: one line).
uci_list() {
	printf '%s\n' "$uci_snapshot" | awk -F '\t' -v key="$1" '$1 == key { print $2 }'
}

uci_list_contains() {
	uci_list "$1" | grep -Fxq -- "$2"
}

# Names of the sections of config $1 with type $2, or of every type when $2 is empty.
uci_sections() {
	printf '%s\n' "$uci_snapshot" | awk -F '\t' -v config="$1" -v type="${2:-}" '
		split($1, part, ".") == 2 && part[1] == config && (type == "" || $2 == type) { print part[2] }'
}

# First section of type $2 in config $1 whose option $3 equals $4; with --list, $3 is a list containing $4.
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

# Quotes any value so that `uci batch` reads it back verbatim.
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

# Runs the batch then commits configs $@; on error reverts them so that no half-done change is left.
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
