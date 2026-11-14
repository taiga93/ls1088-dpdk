# JSON output helpers of the bmchwaccel CLI.

json_escape() {
	printf '%s' "$1" | awk 'BEGIN { ORS = "" } {
		if (NR > 1) printf "\\n"
		gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
		printf "%s", $0
	}'
}

json_string() {
	printf '"%s"' "$(json_escape "$1")"
}

json_bool() {
	if [ "$1" = 1 ]; then printf true; else printf false; fi
}

# JSON array of the non-empty lines read from stdin, as strings.
json_strings() {
	while IFS= read -r line; do
		if [ -n "$line" ]; then json_string "$line"; echo; fi
	done | awk 'BEGIN { printf "[" } NF { printf "%s%s", (n++ ? "," : ""), $0 } END { printf "]" }'
}
