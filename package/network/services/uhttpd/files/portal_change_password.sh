#!/bin/sh

echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo ""

DB_PRIMARY="/etc/freeradius3/raddb/radius.db"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
DB_FALLBACK=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)/freeradius3/raddb/radius.db
AUDIT_LOG_FILE="${PORTAL_AUDIT_LOG_FILE:-/etc/bmcweb/logs/portal_audit.jsonl}"
AUDIT_LOG_MAX_BYTES="${PORTAL_AUDIT_LOG_MAX_BYTES:-1048576}"
AUDIT_LOG_ROTATE_FILES="${PORTAL_AUDIT_LOG_ROTATE_FILES:-2}"

json_escape() {
    printf '%s' "$1" | tr '\r\n' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

safe_log() {
    logger -t portal_change_password "$1" >/dev/null 2>&1 || true
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

audit_password_event() {
    event="$1"
    result="$2"
    username="$3"
    client_ip="$4"
    message="$5"
    now_epoch="$(date +%s 2>/dev/null)"
    now_local="$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null)"

    [ -n "$now_epoch" ] || now_epoch=0
    [ -n "$now_local" ] || now_local="unknown"
    rotate_audit_log "$AUDIT_LOG_FILE" "$AUDIT_LOG_MAX_BYTES" "$AUDIT_LOG_ROTATE_FILES"

    (
        printf '{'
        printf '"timestamp":"%s",' "$(json_escape "$now_local")"
        printf '"epoch":%s,' "$now_epoch"
        printf '"script":"portal_change_password.sh",'
        printf '"event":"%s",' "$(json_escape "$event")"
        printf '"result":"%s",' "$(json_escape "$result")"
        printf '"mode":"nac",'
        printf '"username":"%s",' "$(json_escape "$username")"
        printf '"client_ip":"%s",' "$(json_escape "$client_ip")"
        printf '"remote_addr":"%s",' "$(json_escape "${REMOTE_ADDR#::ffff:}")"
        printf '"message":"%s"' "$(json_escape "$message")"
        printf '}\n'
    ) >> "$AUDIT_LOG_FILE" 2>/dev/null || true

    logger -t portal_audit "script=portal_change_password.sh event=$event result=$result user=$username ip=$client_ip message=$message" >/dev/null 2>&1 || true
}

print_json() {
    status="$1"
    success="$2"
    message="$3"
    printf '{\n'
    printf '  "status": %s,\n' "$status"
    printf '  "success": %s,\n' "$success"
    printf '  "message": "%s"\n' "$(json_escape "$message")"
    printf '}\n'
    exit 0
}

get_json_value() {
    key="$1"
    printf '%s' "$BODY" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

get_session_user_by_ip() {
    target_ip="$1"

    [ -z "$target_ip" ] && return 0
    command -v /usr/sbin/chilli_query >/dev/null 2>&1 || return 0

    /usr/sbin/chilli_query list 2>/dev/null | awk -v target_ip="$target_ip" '
        function is_session_token(value) {
            return value ~ /^[0-9]+\/[0-9]+$/ || value ~ /^[0-9]+$/
        }

        function is_unknown_token(value) {
            return value == "" || value == "-" || value == "*"
        }

        {
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

            if (user != "") {
                print user
                exit
            }
        }
    '
}

BODY=$(cat)
USERNAME=$(get_json_value username)
CURRENT_PASSWORD=$(get_json_value current_password)
NEW_PASSWORD=$(get_json_value new_password)
CLIENTIP=$(get_json_value client_ip)

if [ -z "$CLIENTIP" ]; then
    CLIENTIP="$REMOTE_ADDR"
fi

CLIENTIP="${CLIENTIP#::ffff:}"

if [ -f "$DB_PRIMARY" ]; then
    DB="$DB_PRIMARY"
else
    DB="$DB_FALLBACK"
fi

[ -f "$DB" ] || print_json -1 false "Radius database not found"
command -v sqlite3 >/dev/null 2>&1 || print_json -1 false "sqlite3 command is not available"

[ -n "$USERNAME" ] || print_json -1 false "Missing username"
[ -n "$CURRENT_PASSWORD" ] || print_json -1 false "Please enter your current password"
[ -n "$NEW_PASSWORD" ] || print_json -1 false "Please enter a new password"
[ "$CURRENT_PASSWORD" != "$NEW_PASSWORD" ] || print_json -1 false "New password must be different from the current password"

new_password_length=$(printf '%s' "$NEW_PASSWORD" | awk '{ print length }')
[ "$new_password_length" -ge 4 ] || print_json -1 false "New password must be at least 4 characters"

if [ -n "$CLIENTIP" ]; then
    SESSION_USER=$(get_session_user_by_ip "$CLIENTIP")
    if [ -n "$SESSION_USER" ] && [ "$SESSION_USER" != "$USERNAME" ]; then
        safe_log "Denied password change for '$USERNAME' from IP '$CLIENTIP' because active session belongs to '$SESSION_USER'."
        print_json -1 false "Active session does not match this account"
    fi
fi

ESCAPED_USERNAME=$(sql_escape "$USERNAME")
STORED_PASSWORD=$(sqlite3 "$DB" "
    SELECT value
    FROM radcheck
    WHERE username = '$ESCAPED_USERNAME'
      AND attribute = 'Cleartext-Password'
    ORDER BY id DESC
    LIMIT 1;
")

[ -n "$STORED_PASSWORD" ] || print_json -1 false "Account not found"
[ "$CURRENT_PASSWORD" = "$STORED_PASSWORD" ] || print_json -1 false "Current password is incorrect"

ESCAPED_NEW_PASSWORD=$(sql_escape "$NEW_PASSWORD")

if ! sqlite3 "$DB" "
    BEGIN IMMEDIATE;
    DELETE FROM radcheck
    WHERE username = '$ESCAPED_USERNAME'
      AND attribute = 'Cleartext-Password';
    INSERT INTO radcheck (username, attribute, op, value)
    VALUES ('$ESCAPED_USERNAME', 'Cleartext-Password', ':=', '$ESCAPED_NEW_PASSWORD');
    COMMIT;
" >/dev/null 2>&1; then
    safe_log "Failed to update password for '$USERNAME'."
    print_json -1 false "Unable to update password"
fi

safe_log "Password updated for '$USERNAME' from IP '$CLIENTIP'."
audit_password_event "change_password" "success" "$USERNAME" "$CLIENTIP" "Password updated successfully"
print_json 0 true "Password updated successfully"
