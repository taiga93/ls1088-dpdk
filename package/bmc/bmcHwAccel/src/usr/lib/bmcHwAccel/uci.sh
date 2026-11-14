# Reads UCI through a `uci -X show` snapshot and builds commands for `uci batch`.
#
# The snapshot is normalized into "key<TAB>value" lines:
#   - section declaration: key "config.section", value is the section type;
#   - option: key "config.section.option".
# `uci show` wraps values in '...' and writes ' as '\''.

uci_normalize() {
	awk '
	{
		eq = index($0, "=")
		if (!eq) next
		key = substr($0, 1, eq - 1)
		rest = substr($0, eq + 1)
		if (substr(rest, 1, 1) != "\047") { print key "\t" rest; next }
		gsub(/\047\\\047\047/, "\001", rest)
		gsub(/\047/, "", rest)
		gsub(/\001/, "\047", rest)
		print key "\t" rest
	}'
}

# BMCHWACCEL_SNAPSHOT points to a file in `uci -X show` format, so that tests run without uci.
uci_load_snapshot() {
	if [ -n "${BMCHWACCEL_SNAPSHOT:-}" ]; then
		uci_snapshot=$(uci_normalize < "$BMCHWACCEL_SNAPSHOT")
	else
		uci_snapshot=$(uci -q -X show bmchwaccel | uci_normalize || true)
	fi
}

# Value of an option, or the section type when the key is "config.section".
uci_get() {
	printf '%s\n' "$uci_snapshot" | awk -F '\t' -v key="$1" '$1 == key { print $2; exit }'
}

batch_reset() {
	uci_batch=
}

batch_add() {
	uci_batch="$uci_batch$1
"
}

# Runs the batch then commits; on error reverts so that no half-done change is left. uci refuses a
# configuration that has no file.
batch_commit() {
	[ -e /etc/config/bmchwaccel ] || : > /etc/config/bmchwaccel
	if printf '%s' "$uci_batch" | uci batch >/dev/null 2>&1 && uci commit bmchwaccel; then
		return 0
	fi
	uci revert bmchwaccel >/dev/null 2>&1 || true
	return 1
}
