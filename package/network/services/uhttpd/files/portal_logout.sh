#!/bin/sh

echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo ""
AUDIT_LOG_FILE="${PORTAL_AUDIT_LOG_FILE:-/etc/bmcweb/logs/portal_audit.jsonl}"
AUDIT_LOG_MAX_BYTES="${PORTAL_AUDIT_LOG_MAX_BYTES:-1048576}"
AUDIT_LOG_ROTATE_FILES="${PORTAL_AUDIT_LOG_ROTATE_FILES:-2}"
CLIENT_EVENT_LOG_FILE="${CLIENT_EVENT_LOG_FILE:-/etc/bmcweb/logs/client_events.log}"
CLIENT_EVENT_RETENTION_SECONDS="${CLIENT_EVENT_RETENTION_SECONDS:-604800}"
LEASES_FILE="/tmp/dhcp.leases"

json_escape() {
    printf '%s' "$1" | tr '\r\n' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

safe_log() {
    logger -t portal_logout "$1" >/dev/null 2>&1 || true
}

rotate_audit_log() {
    log_file="$1"
    max_bytes="$2"
    rotate_files="$3"

    case "$max_bytes" in
        ''|*[!0-9]*) max_bytes=1048576 ;;
    esac
    case "$rotate_files" in
        ''|*[!0-9]*) rotate_files=2 ;;
    esac

    log_dir="${log_file%/*}"
    mkdir -p "$log_dir" 2>/dev/null || return 0
    [ -f "$log_file" ] || return 0

    size="$(wc -c < "$log_file" 2>/dev/null)"
    case "$size" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$size" -lt "$max_bytes" ] && return 0

    idx="$rotate_files"
    while [ "$idx" -gt 1 ]; do
        prev=$((idx - 1))
        [ -f "$log_file.$prev" ] && mv "$log_file.$prev" "$log_file.$idx" 2>/dev/null || true
        idx="$prev"
    done

    mv "$log_file" "$log_file.1" 2>/dev/null || : > "$log_file"
}

write_client_event_log() {
    message="$1"
    now_epoch="$(date +%s 2>/dev/null)"
    now_stamp="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)"
    [ -n "$now_epoch" ] || now_epoch=0
    [ -n "$now_stamp" ] || now_stamp="unknown"

    log_dir="${CLIENT_EVENT_LOG_FILE%/*}"
    mkdir -p "$log_dir" 2>/dev/null || return 0

    cutoff=$((now_epoch - CLIENT_EVENT_RETENTION_SECONDS))
    tmp_file="${CLIENT_EVENT_LOG_FILE}.$$"

    if [ -f "$CLIENT_EVENT_LOG_FILE" ]; then
        awk -v cutoff="$cutoff" '
            {
                epoch = 0
                for (i = 1; i <= NF; i += 1) {
                    if ($i ~ /^epoch=[0-9]+$/) {
                        epoch = substr($i, 7) + 0
                        break
                    }
                }
                if (epoch == 0 || epoch >= cutoff) {
                    print
                }
            }
        ' "$CLIENT_EVENT_LOG_FILE" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$CLIENT_EVENT_LOG_FILE"
        rm -f "$tmp_file" 2>/dev/null
    fi

    printf 'epoch=%s timestamp=%s %s\n' "$now_epoch" "$now_stamp" "$message" >> "$CLIENT_EVENT_LOG_FILE" 2>/dev/null || true
}

normalize_mac() {
    printf '%s' "$1" | tr '[:upper:]-' '[:lower:]:'
}

lookup_hostname() {
    client_ip="$1"
    client_mac="$(normalize_mac "$2")"

    [ -f "$LEASES_FILE" ] || {
        printf '%s' "unknown"
        return
    }

    hostname="$(awk -v target_ip="$client_ip" -v target_mac="$client_mac" '
        {
            lease_mac = tolower($2)
            gsub(/-/, ":", lease_mac)
            if (($3 == target_ip || (target_mac != "" && lease_mac == target_mac)) &&
                $4 != "" && $4 != "*" && $4 != "unknown" &&
                $4 != "root" && $4 != "bin" && $4 != "daemon" && $4 != "nobody") {
                print $4
                exit
            }
        }
    ' "$LEASES_FILE")"

    [ -n "$hostname" ] && printf '%s' "$hostname" || printf '%s' "unknown"
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

audit_log() {
    event="$1"
    result="$2"
    username="$3"
    client_ip="$4"
    mac="$5"
    message="$6"
    session_value="$7"
    hostname="$(lookup_hostname "$client_ip" "$mac")"
    now_epoch=$(date +%s 2>/dev/null)
    now_local=$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null)

    [ -n "$now_epoch" ] || now_epoch=0
    [ -n "$now_local" ] || now_local="unknown"
    rotate_audit_log "$AUDIT_LOG_FILE" "$AUDIT_LOG_MAX_BYTES" "$AUDIT_LOG_ROTATE_FILES"

    (
        printf '{'
        printf '"timestamp":"%s",' "$(json_escape "$now_local")"
        printf '"epoch":%s,' "$now_epoch"
        printf '"script":"portal_logout.sh",'
        printf '"event":"%s",' "$(json_escape "$event")"
        printf '"result":"%s",' "$(json_escape "$result")"
        printf '"username":"%s",' "$(json_escape "$username")"
        printf '"client_ip":"%s",' "$(json_escape "$client_ip")"
        printf '"mac":"%s",' "$(json_escape "$mac")"
        printf '"hostname":"%s",' "$(json_escape "$hostname")"
        printf '"remote_addr":"%s",' "$(json_escape "${REMOTE_ADDR#::ffff:}")"
        printf '"session":"%s",' "$(json_escape "$session_value")"
        printf '"message":"%s"' "$(json_escape "$message")"
        printf '}\n'
    ) >> "$AUDIT_LOG_FILE" 2>/dev/null || true

    write_client_event_log "script=portal_logout.sh event=$event result=$result mode=nac user=$username ip=$client_ip mac=$mac hostname=$hostname"
    logger -t portal_audit "script=portal_logout.sh event=$event result=$result user=$username ip=$client_ip mac=$mac hostname=$hostname session=$session_value message=$message" >/dev/null 2>&1 || true
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

get_session_line_by_ip() {
    target_ip="$1"

    /usr/sbin/chilli_query list 2>/dev/null | awk -v target_ip="$target_ip" '
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
}

CLIENT_IP="$(url_decode "$(get_query_param client_ip)")"

if [ -z "$CLIENT_IP" ]; then
    CLIENT_IP="$REMOTE_ADDR"
fi

CLIENT_IP="${CLIENT_IP#::ffff:}"

if [ -z "$CLIENT_IP" ]; then
    audit_log "logout" "invalid_request" "" "" "" "Cannot determine client IP" ""
    printf '{\n'
    printf '  "status": -1,\n'
    printf '  "message": "Cannot determine client IP"\n'
    printf '}\n'
    exit 0
fi

if ! command -v /usr/sbin/chilli_query >/dev/null 2>&1; then
    audit_log "logout" "system_error" "" "$CLIENT_IP" "" "chilli_query command is not available" ""
    printf '{\n'
    printf '  "status": -1,\n'
    printf '  "message": "chilli_query command is not available"\n'
    printf '}\n'
    exit 0
fi

SESSION_LINE="$(get_session_line_by_ip "$CLIENT_IP")"

if [ -z "$SESSION_LINE" ]; then
    audit_log "logout" "not_found" "" "$CLIENT_IP" "" "No active session found for this client IP" ""
    printf '{\n'
    printf '  "status": 0,\n'
    printf '  "success": true,\n'
    printf '  "message": "No active session found for this client IP",\n'
    printf '  "client_ip": "%s"\n' "$(json_escape "$CLIENT_IP")"
    printf '}\n'
    exit 0
fi

IFS='|' read -r RAW_MAC RAW_IP RAW_STATE RAW_AUTHORIZED RAW_USER RAW_SESSION <<EOF
$SESSION_LINE
EOF

MAC="$(normalize_mac "$RAW_MAC")"
USER="$(normalize_text "$RAW_USER")"
SESSION_VALUE="$(normalize_text "$RAW_SESSION")"

if /usr/sbin/chilli_query logout "$MAC" >/dev/null 2>&1; then
    safe_log "Logout successful for '$USER' from $CLIENT_IP ($MAC)"
    audit_log "logout" "success" "$USER" "$CLIENT_IP" "$MAC" "Logout successful" "$SESSION_VALUE"
    printf '{\n'
    printf '  "status": 0,\n'
    printf '  "success": true,\n'
    printf '  "message": "Logout successful",\n'
    printf '  "client_ip": "%s",\n' "$(json_escape "$CLIENT_IP")"
    printf '  "mac": "%s"\n' "$(json_escape "$MAC")"
    printf '}\n'
    exit 0
fi

safe_log "Failed to logout active session for '$USER' from $CLIENT_IP ($MAC)"
audit_log "logout" "failure" "$USER" "$CLIENT_IP" "$MAC" "Failed to logout active session" "$SESSION_VALUE"
printf '{\n'
printf '  "status": -1,\n'
printf '  "success": false,\n'
printf '  "message": "Failed to logout active session",\n'
printf '  "client_ip": "%s",\n' "$(json_escape "$CLIENT_IP")"
printf '  "mac": "%s"\n' "$(json_escape "$MAC")"
printf '}\n'
exit 0
