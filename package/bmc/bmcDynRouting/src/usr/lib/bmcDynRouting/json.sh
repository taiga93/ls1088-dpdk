# Dựng output JSON cho CLI bmcdynrouting.

# Không dùng gsub: dấu "\" trong chuỗi thay thế của gsub được mỗi awk hiểu một kiểu (busybox 1.36 và 1.37 khác nhau).
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

# Gộp các giá trị JSON trên stdin (mỗi dòng một giá trị) thành một mảng.
json_array() {
	awk 'BEGIN { printf "[" } NF { printf "%s%s", (n++ ? "," : ""), $0 } END { printf "]" }'
}

# Mảng JSON các chuỗi đọc từ stdin, mỗi dòng không rỗng một chuỗi.
json_strings() {
	while IFS= read -r line; do
		if [ -n "$line" ]; then json_string "$line"; echo; fi
	done | json_array
}
