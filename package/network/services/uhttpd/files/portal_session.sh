#!/bin/sh

echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo ""

json_escape() {
    printf '%s' "$1" | tr '\r\n' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

normalize_text() {
    case "$1" in
        ""|"*"|"-")
            printf '%s' "unknown"
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

normalize_mac() {
    printf '%s' "$1" | tr '[:upper:]-' '[:lower:]:'
}

get_query_param() {
    printf '%s' "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1
}

url_decode() {
    printf '%s' "$1" | awk '
        function hex2dec(hex,    i, c, value, digit) {
            value = 0
            for (i = 1; i <= length(hex); i++) {
                c = substr(hex, i, 1)
                if (c >= "0" && c <= "9") {
                    digit = c + 0
                } else if (c >= "A" && c <= "F") {
                    digit = index("ABCDEF", c) + 9
                } else if (c >= "a" && c <= "f") {
                    digit = index("abcdef", c) + 9
                } else {
                    return -1
                }
                value = (value * 16) + digit
            }
            return value
        }

        {
            input = $0
            output = ""
            index_pos = 1

            while (index_pos <= length(input)) {
                ch = substr(input, index_pos, 1)

                if (ch == "+") {
                    output = output " "
                    index_pos++
                } else if (ch == "%" && index_pos + 2 <= length(input)) {
                    code = substr(input, index_pos + 1, 2)
                    decoded = hex2dec(code)
                    if (decoded >= 0) {
                        output = output sprintf("%c", decoded)
                        index_pos += 3
                    } else {
                        output = output ch
                        index_pos++
                    }
                } else {
                    output = output ch
                    index_pos++
                }
            }

            printf "%s", output
        }
    '
}

CLIENT_IP="$(url_decode "$(get_query_param client_ip)")"

if [ -z "$CLIENT_IP" ]; then
    CLIENT_IP="$REMOTE_ADDR"
fi

CLIENT_IP="${CLIENT_IP#::ffff:}"

if [ -z "$CLIENT_IP" ]; then
    printf '{\n'
    printf '  "status": -1,\n'
    printf '  "message": "Cannot determine client IP"\n'
    printf '}\n'
    exit 0
fi

if ! command -v /usr/sbin/chilli_query >/dev/null 2>&1; then
    printf '{\n'
    printf '  "status": -1,\n'
    printf '  "message": "chilli_query command is not available"\n'
    printf '}\n'
    exit 0
fi

SESSION_LINE=$(
    /usr/sbin/chilli_query list 2>/dev/null | awk -v target_ip="$CLIENT_IP" '
        function is_session_token(value) {
            return value ~ /^[0-9]+\/[0-9]+$/ || value ~ /^[0-9]+$/
        }

        function is_unknown_token(value) {
            return value == "" || value == "-" || value == "*"
        }

        {
            mac = $1
            ip = $2
            state = $3
            authorized = $5
            user = ""
            session = ""

            if (ip != target_ip) {
                next
            }

            if (NF >= 7 && is_session_token($7)) {
                session = $7
            } else {
                for (i = 4; i <= NF; i++) {
                    if (is_session_token($i)) {
                        session = $i
                        break
                    }
                }
            }

            if (NF >= 6 && !is_unknown_token($6) && !is_session_token($6)) {
                user = $6
            }

            if (user == "") {
                for (i = NF; i >= 4; i--) {
                    if ($i == session || is_unknown_token($i) || is_session_token($i)) {
                        continue
                    }

                    if ($i != state && $i != authorized) {
                        user = $i
                        break
                    }
                }
            }

            print mac "|" ip "|" state "|" authorized "|" user "|" session
            exit
        }
    '
)

NOW="$(date +%s)"

if [ -z "$SESSION_LINE" ]; then
    printf '{\n'
    printf '  "status": 0,\n'
    printf '  "found": false,\n'
    printf '  "client_ip": "%s",\n' "$(json_escape "$CLIENT_IP")"
    printf '  "collected_at": %s,\n' "$NOW"
    printf '  "session": null\n'
    printf '}\n'
    exit 0
fi

IFS='|' read -r RAW_MAC RAW_IP RAW_STATE RAW_AUTHORIZED RAW_USER RAW_SESSION <<EOF
$SESSION_LINE
EOF

MAC="$(normalize_text "$(normalize_mac "$RAW_MAC")")"
IP="$(normalize_text "$RAW_IP")"
STATE="$(normalize_text "$RAW_STATE")"
AUTHORIZED="$(normalize_text "$RAW_AUTHORIZED")"
USER="$(normalize_text "$RAW_USER")"
SESSION_VALUE="$(normalize_text "$RAW_SESSION")"

CURRENT_SECONDS=""
TOTAL_SECONDS=""
REMAINING_SECONDS=""

case "$SESSION_VALUE" in
    */*)
        CURRENT_SECONDS="${SESSION_VALUE%%/*}"
        TOTAL_SECONDS="${SESSION_VALUE##*/}"
        case "$CURRENT_SECONDS" in ''|*[!0-9]*) CURRENT_SECONDS="" ;; esac
        case "$TOTAL_SECONDS" in ''|*[!0-9]*) TOTAL_SECONDS="" ;; esac
        if [ -n "$TOTAL_SECONDS" ] && [ "$TOTAL_SECONDS" -le 0 ] 2>/dev/null; then
            TOTAL_SECONDS=""
        fi
        if [ -n "$CURRENT_SECONDS" ] && [ -n "$TOTAL_SECONDS" ] && [ "$TOTAL_SECONDS" -ge "$CURRENT_SECONDS" ] 2>/dev/null; then
            REMAINING_SECONDS=$((TOTAL_SECONDS - CURRENT_SECONDS))
        fi
        ;;
    *)
        case "$SESSION_VALUE" in ''|*[!0-9]*) ;;
            *) CURRENT_SECONDS="$SESSION_VALUE" ;;
        esac
        ;;
esac

printf '{\n'
printf '  "status": 0,\n'
printf '  "found": true,\n'
printf '  "client_ip": "%s",\n' "$(json_escape "$CLIENT_IP")"
printf '  "collected_at": %s,\n' "$NOW"
printf '  "session": {\n'
printf '    "user": "%s",\n' "$(json_escape "$USER")"
printf '    "ip": "%s",\n' "$(json_escape "$IP")"
printf '    "mac": "%s",\n' "$(json_escape "$MAC")"
printf '    "state": "%s",\n' "$(json_escape "$STATE")"
printf '    "authorized": "%s",\n' "$(json_escape "$AUTHORIZED")"
printf '    "raw_session": "%s",\n' "$(json_escape "$SESSION_VALUE")"

if [ -n "$CURRENT_SECONDS" ]; then
    printf '    "current_seconds": %s,\n' "$CURRENT_SECONDS"
else
    printf '    "current_seconds": null,\n'
fi

if [ -n "$TOTAL_SECONDS" ]; then
    printf '    "total_seconds": %s,\n' "$TOTAL_SECONDS"
else
    printf '    "total_seconds": null,\n'
fi

if [ -n "$REMAINING_SECONDS" ]; then
    printf '    "remaining_seconds": %s\n' "$REMAINING_SECONDS"
else
    printf '    "remaining_seconds": null\n'
fi

printf '  }\n'
printf '}\n'
