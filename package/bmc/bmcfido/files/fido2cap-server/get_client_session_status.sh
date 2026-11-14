#!/bin/sh

IPSET_NAME="authorized_table"
USER_MAP_FILE="/tmp/authorized_client_users.map"
CLIENT_IP="$1"
NOW="$(date +%s)"

json_escape() {
    printf '%s' "$1" | tr '\r\n' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

normalize_value() {
    case "$1" in
        ""|"*")
            printf '%s' "unknown"
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

get_mapped_user() {
    [ -f "$USER_MAP_FILE" ] || return 0
    awk -F'|' -v target="$1" '$1 == target { print $2; exit }' "$USER_MAP_FILE"
}

if [ -z "$CLIENT_IP" ]; then
    printf '{\n'
    printf '  "status": -1,\n'
    printf '  "message": "Missing client IP"\n'
    printf '}\n'
    exit 1
fi

if ! command -v ipset >/dev/null 2>&1; then
    printf '{\n'
    printf '  "status": -1,\n'
    printf '  "message": "ipset command is not available"\n'
    printf '}\n'
    exit 1
fi

LINE="$(ipset list "$IPSET_NAME" 2>/dev/null | awk -v target="$CLIENT_IP" '$1 == target { print; exit }')"

if [ -z "$LINE" ]; then
    printf '{\n'
    printf '  "status": 0,\n'
    printf '  "found": false,\n'
    printf '  "collected_at": %s,\n' "$NOW"
    printf '  "session": null,\n'
    printf '  "message": "No active authorized session found for this client IP"\n'
    printf '}\n'
    exit 0
fi

TIMEOUT="$(printf '%s\n' "$LINE" | awk '{for (i = 1; i <= NF; i++) if ($i == "timeout") { print $(i + 1); exit }}')"
USER="$(printf '%s\n' "$LINE" | sed -n 's/.*comment "\(.*\)".*/\1/p')"
[ -n "$USER" ] || USER="$(get_mapped_user "$CLIENT_IP")"

USER="$(normalize_value "$USER")"

if [ -n "$TIMEOUT" ] && printf '%s' "$TIMEOUT" | grep -Eq '^[0-9]+$'; then
    EXPIRES_AT=$((NOW + TIMEOUT))
    REMAINING_SECONDS="$TIMEOUT"
    COUNTDOWN_ENABLED=true
else
    TIMEOUT=0
    EXPIRES_AT=""
    REMAINING_SECONDS=""
    COUNTDOWN_ENABLED=false
fi

printf '{\n'
printf '  "status": 0,\n'
printf '  "found": true,\n'
printf '  "collected_at": %s,\n' "$NOW"
printf '  "session": {\n'
printf '    "ip": "%s",\n' "$(json_escape "$CLIENT_IP")"
printf '    "user": "%s",\n' "$(json_escape "$USER")"
printf '    "timeout": %s,\n' "$TIMEOUT"
if [ "$COUNTDOWN_ENABLED" = true ]; then
    printf '    "expires_at": %s,\n' "$EXPIRES_AT"
    printf '    "remaining_seconds": %s,\n' "$REMAINING_SECONDS"
else
    printf '    "expires_at": null,\n'
    printf '    "remaining_seconds": null,\n'
fi
printf '    "countdown_enabled": %s\n' "$COUNTDOWN_ENABLED"
printf '  }\n'
printf '}\n'
