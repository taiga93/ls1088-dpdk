#!/bin/sh
echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo ""
# Flush header immediately
exec 1>&1

# Read body JSON from POST
BODY=$(cat)
AUDIT_LOG_FILE="${PORTAL_AUDIT_LOG_FILE:-/etc/bmcweb/logs/portal_audit.jsonl}"
AUDIT_LOG_MAX_BYTES="${PORTAL_AUDIT_LOG_MAX_BYTES:-1048576}"
AUDIT_LOG_ROTATE_FILES="${PORTAL_AUDIT_LOG_ROTATE_FILES:-2}"
CLIENT_EVENT_LOG_FILE="${CLIENT_EVENT_LOG_FILE:-/etc/bmcweb/logs/client_events.log}"
CLIENT_EVENT_RETENTION_SECONDS="${CLIENT_EVENT_RETENTION_SECONDS:-604800}"
RADIUS_DB="${PORTAL_RADIUS_DB:-/etc/freeradius3/raddb/radius.db}"
LEASES_FILE="/tmp/dhcp.leases"

json_escape() {
    printf '%s' "$1" | tr '\r\n' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

safe_log() {
    logger -t login.sh "$1" >/dev/null 2>&1 || true
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

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

audit_log() {
    event="$1"
    result="$2"
    username="$3"
    client_ip="$4"
    mac="$5"
    message="$6"
    userurl="$7"
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
        printf '"script":"portal_login.sh",'
        printf '"event":"%s",' "$(json_escape "$event")"
        printf '"result":"%s",' "$(json_escape "$result")"
        printf '"username":"%s",' "$(json_escape "$username")"
        printf '"client_ip":"%s",' "$(json_escape "$client_ip")"
        printf '"mac":"%s",' "$(json_escape "$mac")"
        printf '"hostname":"%s",' "$(json_escape "$hostname")"
        printf '"remote_addr":"%s",' "$(json_escape "${REMOTE_ADDR#::ffff:}")"
        printf '"userurl":"%s",' "$(json_escape "$userurl")"
        printf '"message":"%s"' "$(json_escape "$message")"
        printf '}\n'
    ) >> "$AUDIT_LOG_FILE" 2>/dev/null || true

    write_client_event_log "script=portal_login.sh event=$event result=$result mode=nac user=$username ip=$client_ip mac=$mac hostname=$hostname"
    logger -t portal_audit "script=portal_login.sh event=$event result=$result user=$username ip=$client_ip mac=$mac hostname=$hostname message=$message" >/dev/null 2>&1 || true
}

# Use grep/sed for more robust JSON parsing in shell
USERNAME=$(printf '%s' "$BODY" | sed -n 's/.*"username"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
PASSWORD=$(printf '%s' "$BODY" | sed -n 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
USERURL=$(printf '%s' "$BODY"  | sed -n 's/.*"userurl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
CLIENTIP=$(printf '%s' "$BODY"  | sed -n 's/.*"client_ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

if [ -z "$CLIENTIP" ]; then
    CLIENTIP="$REMOTE_ADDR"
fi

CLIENTIP="${CLIENTIP#::ffff:}"
is_ip_authorized() {
    ip="$1"

    /usr/sbin/chilli_query list 2>/dev/null | awk -v ip="$ip" '
        $2 == ip && ($3 == "pass" || $5 == "1") { found=1 }
        END { exit found ? 0 : 1 }
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

confirm_login_session() {
    username="$1"
    client_ip="$2"
    max_attempts="${3:-12}"
    attempt=1

    while [ "$attempt" -le "$max_attempts" ]; do
        session_line="$(get_session_line_by_ip "$client_ip")"

        if [ -n "$session_line" ]; then
            IFS='|' read -r session_mac session_ip session_state session_authorized session_user session_value <<EOF
$session_line
EOF

            if [ "$session_state" = "pass" ] || [ "$session_authorized" = "1" ]; then
                printf '%s' "$session_line"
                return 0
            fi
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            /bin/sleep 1
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

verify_local_credentials() {
    username="$1"
    password="$2"

    [ -f "$RADIUS_DB" ] || return 2
    command -v sqlite3 >/dev/null 2>&1 || return 2

    escaped_username="$(sql_escape "$username")"
    expected_password="$(sqlite3 "$RADIUS_DB" "
        SELECT value
        FROM radcheck
        WHERE username = '$escaped_username'
          AND attribute = 'Cleartext-Password'
        ORDER BY id DESC
        LIMIT 1;
    " 2>/dev/null)"

    [ -n "$expected_password" ] || return 1
    [ "$expected_password" = "$password" ]
}

authorize_local_session() {
    username="$1"
    client_ip="$2"

    /usr/sbin/chilli_query authorize ip "$client_ip" username "$username" >/dev/null 2>&1
}

get_other_sessions_same_user() {
    username="$1"
    current_ip="$2"

    /usr/sbin/chilli_query list 2>/dev/null | awk -v username="$username" -v current_ip="$current_ip" '
        {
            matched_user = 0
            for (i = 1; i <= NF; i++) {
                if ($i == username) {
                    matched_user = 1
                    break
                }
            }

            if (matched_user && $1 != "" && $2 != "" && $2 != current_ip) {
                print $1 " " $2
            }
        }
    ' | sort -u
}

get_mac_by_ip() {
    ip="$1"

    /usr/sbin/chilli_query list 2>/dev/null | awk -v ip="$ip" '
        $2 == ip {
            print $1
            exit
        }
    '
}

if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    audit_log "login" "invalid_request" "$USERNAME" "$CLIENTIP" "" "Missing username or password" "$USERURL"
    echo '{"success": false, "message": "Missing username or password"}'
    exit 0
fi

if [ -z "$CLIENTIP" ]; then
    audit_log "login" "invalid_request" "$USERNAME" "" "" "Cannot determine client IP" "$USERURL"
    echo '{"success": false, "message": "Cannot determine client IP"}'
    exit 0
fi

safe_log "Parsed USERNAME=$USERNAME PASSWORD=**** USERURL=$USERURL CLIENTIP=$CLIENTIP"
audit_log "login" "attempt" "$USERNAME" "$CLIENTIP" "" "Portal login requested" "$USERURL"

LOCAL_AUTH_STATUS="unknown"
if verify_local_credentials "$USERNAME" "$PASSWORD"; then
    LOCAL_AUTH_STATUS="ok"
elif [ "$?" -eq 1 ]; then
    LOCAL_AUTH_STATUS="failed"
    audit_log "login" "rejected" "$USERNAME" "$CLIENTIP" "" "Local credential check failed" "$USERURL"
    echo '{"success": false, "message": "Invalid username or password"}'
    exit 0
else
    LOCAL_AUTH_STATUS="unavailable"
fi

if [ "$LOCAL_AUTH_STATUS" = "ok" ]; then
    safe_log "Local credential check passed for $USERNAME ($CLIENTIP), authorizing Chilli session."
    audit_log "login" "local_auth" "$USERNAME" "$CLIENTIP" "" "Local credential check passed; authorizing Chilli session" "$USERURL"
    authorize_local_session "$USERNAME" "$CLIENTIP"
    CONFIRMED_SESSION_LINE="$(confirm_login_session "$USERNAME" "$CLIENTIP" 5)"
else
    safe_log "Executing LOGIN: chilli_query login ip $CLIENTIP username $USERNAME password ****"
    if ! /usr/sbin/chilli_query login ip "$CLIENTIP" username "$USERNAME" password "$PASSWORD" >/dev/null 2>&1; then
        safe_log "Login command execution failed and local credential check is not available."
        audit_log "login" "system_error" "$USERNAME" "$CLIENTIP" "" "Login command execution failed" "$USERURL"
        echo '{"success": false, "message": "Login failed (System error, try again)"}'
        exit 0
    fi

    CONFIRMED_SESSION_LINE="$(confirm_login_session "$USERNAME" "$CLIENTIP")"
fi

if [ -z "$CONFIRMED_SESSION_LINE" ] && [ "$LOCAL_AUTH_STATUS" = "ok" ]; then
    safe_log "Session not pass yet for $USERNAME ($CLIENTIP), applying local authorize fallback."
    audit_log "login" "fallback" "$USERNAME" "$CLIENTIP" "" "Session was not authorized after login; applying local authorize fallback" "$USERURL"
    authorize_local_session "$USERNAME" "$CLIENTIP"
    CONFIRMED_SESSION_LINE="$(confirm_login_session "$USERNAME" "$CLIENTIP" 5)"
fi

if [ -n "$CONFIRMED_SESSION_LINE" ] || is_ip_authorized "$CLIENTIP"; then
    if [ -n "$CONFIRMED_SESSION_LINE" ]; then
        IFS='|' read -r CONFIRM_RAW_MAC CONFIRM_RAW_IP CONFIRM_RAW_STATE CONFIRM_RAW_AUTHORIZED CONFIRM_RAW_USER CONFIRM_RAW_SESSION <<EOF
$CONFIRMED_SESSION_LINE
EOF
        CURRENT_MAC=$(normalize_mac "$CONFIRM_RAW_MAC")
        CURRENT_STATE="$CONFIRM_RAW_STATE"
        CURRENT_AUTHORIZED="$CONFIRM_RAW_AUTHORIZED"
    else
        CURRENT_MAC=$(normalize_mac "$(get_mac_by_ip "$CLIENTIP")")
        CURRENT_STATE="pass"
        CURRENT_AUTHORIZED="1"
    fi

    OLD_SESSIONS=$(get_other_sessions_same_user "$USERNAME" "$CLIENTIP")

    if [ -n "$OLD_SESSIONS" ]; then
        printf '%s\n' "$OLD_SESSIONS" | while read -r OLD_MAC OLD_IP; do
            [ -z "$OLD_MAC" ] && continue
            NORMALIZED_OLD_MAC=$(normalize_mac "$OLD_MAC")
            safe_log "Logging out previous session for $USERNAME at $OLD_IP ($NORMALIZED_OLD_MAC), keeping new session $CLIENTIP"
            if ! /usr/sbin/chilli_query logout "$NORMALIZED_OLD_MAC" >/dev/null 2>&1; then
                safe_log "Failed to logout previous session for $USERNAME at $OLD_IP ($NORMALIZED_OLD_MAC)"
                audit_log "session_replaced" "failure" "$USERNAME" "$OLD_IP" "$NORMALIZED_OLD_MAC" "Failed to logout previous session after new login from $CLIENTIP" "$USERURL"
            else
                audit_log "session_replaced" "success" "$USERNAME" "$OLD_IP" "$NORMALIZED_OLD_MAC" "Previous session logged out after new login from $CLIENTIP" "$USERURL"
            fi
        done
    fi

    safe_log "Authorization success confirmed for $USERNAME ($CLIENTIP). State=$CURRENT_STATE Authorized=$CURRENT_AUTHORIZED"
    audit_log "login" "success" "$USERNAME" "$CLIENTIP" "$CURRENT_MAC" "Authorization success confirmed. State=$CURRENT_STATE Authorized=$CURRENT_AUTHORIZED" "$USERURL"
    echo "{\"success\": true, \"message\": \"Login success\", \"redirect\": \"${USERURL}\", \"client_ip\": \"${CLIENTIP}\"}"
else
    STATUS_CHECK=$(/usr/sbin/chilli_query list 2>/dev/null | awk -v ip="$CLIENTIP" '$2 == ip { print $3 "/" $5; exit }')
    safe_log "Authorization failed for $USERNAME ($CLIENTIP). Final Status=$STATUS_CHECK"
    FAILED_MAC=$(normalize_mac "$(get_mac_by_ip "$CLIENTIP")")
    audit_log "login" "rejected" "$USERNAME" "$CLIENTIP" "$FAILED_MAC" "Authorization failed. Final status=$STATUS_CHECK" "$USERURL"
    echo '{"success": false, "message": "Login was accepted but the session is not authorized yet. Please try again."}'
fi
