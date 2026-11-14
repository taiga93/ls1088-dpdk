# JSON output helpers of the bmcmultiwan CLI.

# No gsub: every awk reads a "\" in the replacement of gsub its own way (busybox 1.36 and 1.37 differ).
json_escape() {
	printf '%s' "$1" | awk 'BEGIN { ORS = "" } {
		if (NR > 1) printf "\\n"
		out = ""
		for (i = 1; i <= length($0); i++) {
			c = substr($0, i, 1)
			if (c == "\\" || c == "\"") out = out "\\" c
			else if (c == "\t") out = out "\\t"
			else if (c == "\r") out = out "\\r"
			else out = out c
		}
		printf "%s", out
	}'
}

json_string() {
	printf '"%s"' "$(json_escape "$1")"
}

json_bool() {
	if [ "$1" = 1 ]; then printf true; else printf false; fi
}

# A non-negative integer as a JSON number, anything else as null.
json_number_or_null() {
	case "$1" in
		''|*[!0-9]*) printf null ;;
		*) printf '%s' "$1" ;;
	esac
}

# Joins the JSON values read from stdin (one per line) into an array.
json_array() {
	awk 'BEGIN { printf "[" } NF { printf "%s%s", (n++ ? "," : ""), $0 } END { printf "]" }'
}

# JSON array of the non-empty lines read from stdin, as strings.
json_strings() {
	while IFS= read -r line; do
		if [ -n "$line" ]; then json_string "$line"; echo; fi
	done | json_array
}
