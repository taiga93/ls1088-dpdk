#!/bin/sh

# update_authorized_client.sh
# Add/Delete authorized client IP to ipset authorized_table
# Timeout: 4 hours

IPSET_NAME="authorized_table"
USER_MAP_FILE="/tmp/authorized_client_users.map"
HOSTNAME_MAP_FILE="/tmp/authorized_client_hostnames.map"
FIDO_KEY_MAP_FILE="/tmp/authorized_client_fido_keys.map"
LEASES_FILE="/tmp/dhcp.leases"
ODHCPD_HOSTS_FILE="${ODHCPD_HOSTS_FILE:-/tmp/hosts/odhcpd}"
CLIENT_EVENT_LOG_FILE="${CLIENT_EVENT_LOG_FILE:-/etc/bmcweb/logs/client_events.log}"
CLIENT_EVENT_RETENTION_SECONDS="${CLIENT_EVENT_RETENTION_SECONDS:-604800}"
TIMEOUT=3600
ACTION="$1"
CLIENT_IP="$2"
USERNAME="$3"
FIDO_CREDENTIAL_ID="$4"
FIDO_KEY_INDEX="$5"

log() {
    logger -t authorized_client "$1"
    case "$1" in
        event=*)
            write_client_event_log "$1"
            ;;
    esac
}

write_client_event_log() {
    local message="$1"
    local now_epoch
    local now_stamp
    local cutoff
    local log_dir
    local tmp_file

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

set_mapped_user() {
    local ip="$1"
    local user="$2"
    local tmp_file="${USER_MAP_FILE}.$$"

    [ -n "$ip" ] || return 0
    [ -n "$user" ] || return 0

    {
        if [ -f "$USER_MAP_FILE" ]; then
            awk -F'|' -v target="$ip" '$1 != target { print }' "$USER_MAP_FILE"
        fi
        printf '%s|%s\n' "$ip" "$user"
    } > "$tmp_file"

    mv "$tmp_file" "$USER_MAP_FILE"
}

get_mapped_user() {
    local ip="$1"

    [ -f "$USER_MAP_FILE" ] || return 0
    awk -F'|' -v target="$ip" '$1 == target { print $2; exit }' "$USER_MAP_FILE"
}

delete_mapped_user() {
    local ip="$1"
    local tmp_file="${USER_MAP_FILE}.$$"

    [ -n "$ip" ] || return 0
    [ -f "$USER_MAP_FILE" ] || return 0

    awk -F'|' -v target="$ip" '$1 != target { print }' "$USER_MAP_FILE" > "$tmp_file"
    mv "$tmp_file" "$USER_MAP_FILE"
}

set_mapped_fido_key() {
    local ip="$1"
    local credential_id="$2"
    local key_index="$3"
    local tmp_file="${FIDO_KEY_MAP_FILE}.$$"

    [ -n "$ip" ] || return 0
    [ -n "$credential_id" ] || return 0

    {
        if [ -f "$FIDO_KEY_MAP_FILE" ]; then
            awk -F'|' -v target="$ip" '$1 != target { print }' "$FIDO_KEY_MAP_FILE"
        fi
        printf '%s|%s|%s\n' "$ip" "$credential_id" "$key_index"
    } > "$tmp_file"

    mv "$tmp_file" "$FIDO_KEY_MAP_FILE"
}

delete_mapped_fido_key() {
    local ip="$1"
    local tmp_file="${FIDO_KEY_MAP_FILE}.$$"

    [ -n "$ip" ] || return 0
    [ -f "$FIDO_KEY_MAP_FILE" ] || return 0

    awk -F'|' -v target="$ip" '$1 != target { print }' "$FIDO_KEY_MAP_FILE" > "$tmp_file"
    mv "$tmp_file" "$FIDO_KEY_MAP_FILE"
}

normalize_hostname() {
    case "$1" in
        ""|"*"|"unknown"|"root"|"bin"|"daemon"|"nobody")
            return 1
            ;;
        *)
            printf '%s' "$1"
            return 0
            ;;
    esac
}

set_mapped_hostname() {
    local ip="$1"
    local mac="$2"
    local hostname="$3"
    local tmp_file="${HOSTNAME_MAP_FILE}.$$"

    [ -n "$ip" ] || return 0
    hostname="$(normalize_hostname "$hostname")" || return 0

    {
        if [ -f "$HOSTNAME_MAP_FILE" ]; then
            awk -F'|' -v target_ip="$ip" '$1 != target_ip { print }' "$HOSTNAME_MAP_FILE"
        fi
        printf '%s|%s|%s\n' "$ip" "$mac" "$hostname"
    } > "$tmp_file"

    mv "$tmp_file" "$HOSTNAME_MAP_FILE"
}

get_mapped_hostname() {
    local ip="$1"
    local mac="$2"

    [ -f "$HOSTNAME_MAP_FILE" ] || return 0
    awk -F'|' -v target_ip="$ip" -v target_mac="$mac" '
        $1 == target_ip && $3 != "" { print $3; exit }
        target_mac != "" && $2 == target_mac && $3 != "" { candidate = $3 }
        END { if (candidate != "") print candidate }
    ' "$HOSTNAME_MAP_FILE"
}

lookup_hostname_from_odhcpd() {
    local mac="$1"
    local plain_mac

    [ -f "$ODHCPD_HOSTS_FILE" ] || return 0
    plain_mac="$(normalize_mac "$mac" | tr -d ':')"
    [ -n "$plain_mac" ] || return 0

    awk -v target_mac="$plain_mac" '
        function is_bad_hostname(value) {
            return value == "" ||
                value == "*" ||
                value == "unknown" ||
                value == "root" ||
                value == "bin" ||
                value == "daemon" ||
                value == "nobody" ||
                value == "br-lan" ||
                value ~ /:/ ||
                value ~ /\// ||
                value ~ /^[0-9]+$/ ||
                value ~ /^[0-9a-fA-F]+$/ ||
                value ~ /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/
        }
        {
            line = tolower($0)
            if (target_mac != "" && index(line, target_mac) == 0) {
                next
            }
            for (i = 1; i <= NF; i += 1) {
                value = $i
                sub(/^#/, "", value)
                if (!is_bad_hostname(value)) {
                    print value
                    exit
                }
            }
        }
    ' "$ODHCPD_HOSTS_FILE"
}

normalize_mac() {
    printf '%s' "$1" | tr '[:upper:]-' '[:lower:]:'
}

get_mac_by_ip() {
    local ip="$1"
    local mac=""

    if command -v ip >/dev/null 2>&1; then
        mac="$(ip neigh show "$ip" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "lladdr") { print $(i + 1); exit }}')"
    fi

    if [ -z "$mac" ] && command -v arp >/dev/null 2>&1; then
        mac="$(arp -n "$ip" 2>/dev/null | awk 'tolower($4) ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/ { print $4; exit }')"
    fi

    normalize_mac "$mac"
}

get_lease_mac_by_ip() {
    local ip="$1"

    [ -f "$LEASES_FILE" ] || return 0
    awk -v target="$ip" '$3 == target && $2 != "" { print $2; exit }' "$LEASES_FILE"
}

get_log_mac() {
    local ip="$1"
    local mac

    mac="$(get_lease_mac_by_ip "$ip")"
    [ -n "$mac" ] || mac="$(get_mac_by_ip "$ip")"
    mac="$(normalize_mac "$mac")"
    [ -n "$mac" ] && printf '%s' "$mac" || printf '%s' "unknown"
}

get_log_hostname() {
    local ip="$1"
    local mac="$2"
    local hostname

    if [ -f "$LEASES_FILE" ]; then
        hostname="$(awk -v target_ip="$ip" -v target_mac="$mac" '
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
    fi

    [ -n "$hostname" ] || hostname="$(get_mapped_hostname "$ip" "$mac")"
    [ -n "$hostname" ] || hostname="$(lookup_hostname_from_odhcpd "$mac")"
    hostname="$(normalize_hostname "$hostname" 2>/dev/null || printf 'unknown')"
    [ "$hostname" = "unknown" ] || set_mapped_hostname "$ip" "$mac" "$hostname"
    printf '%s' "$hostname"
}

client_identity_fields() {
    local ip="$1"
    local mac
    local hostname

    mac="$(get_log_mac "$ip")"
    hostname="$(get_log_hostname "$ip" "$mac")"
    printf ' mac=%s hostname=%s' "$mac" "$hostname"
}

delete_dhcp_lease_by_ip() {
    local ip="$1"
    local tmp_file="${LEASES_FILE}.$$"

    [ -n "$ip" ] || return 0
    [ -f "$LEASES_FILE" ] || return 0

    awk -v target="$ip" '$3 != target { print }' "$LEASES_FILE" > "$tmp_file"
    mv "$tmp_file" "$LEASES_FILE"
}

remember_dhcp_hostname_by_ip() {
    local ip="$1"
    local mac
    local hostname

    [ -n "$ip" ] || return 0
    [ -f "$LEASES_FILE" ] || return 0

    mac="$(awk -v target="$ip" '$3 == target { print $2; exit }' "$LEASES_FILE")"
    hostname="$(awk -v target="$ip" '$3 == target { print $4; exit }' "$LEASES_FILE")"
    [ -n "$mac" ] || return 0

    mac="$(normalize_mac "$mac")"
    hostname="$(normalize_hostname "$hostname" 2>/dev/null || lookup_hostname_from_odhcpd "$mac")"
    set_mapped_hostname "$ip" "$mac" "$hostname"
}

ensure_dhcp_lease_by_ip() {
    local ip="$1"
    local user="$2"
    local mac
    local hostname
    local expires

    [ -n "$ip" ] || return 0
    if [ -f "$LEASES_FILE" ] && awk -v target="$ip" '$3 == target { found = 1 } END { exit found ? 0 : 1 }' "$LEASES_FILE"; then
        remember_dhcp_hostname_by_ip "$ip"
        return 0
    fi

    mac="$(get_mac_by_ip "$ip")"
    [ -n "$mac" ] || mac="00:00:00:00:00:00"
    hostname="$(get_mapped_hostname "$ip" "$mac")"
    hostname="$(normalize_hostname "$hostname" 2>/dev/null || printf '*')"
    expires=$(( $(date +%s) + TIMEOUT ))

    touch "$LEASES_FILE" 2>/dev/null || return 0
    printf '%s %s %s %s *\n' "$expires" "$mac" "$ip" "$hostname" >> "$LEASES_FILE"
    log "Restored DHCP lease for $ip ($mac, $hostname) in $LEASES_FILE"
}

if [ -z "$ACTION" ]; then
    echo "Usage: $0 {add|del|del_by_user} <client_ip|username> [username]"
    exit 1
fi

# Create ipset if it does not exist
if ! ipset list $IPSET_NAME >/dev/null 2>&1; then
    log "Creating ipset $IPSET_NAME with timeout $TIMEOUT"
    ipset create $IPSET_NAME hash:ip timeout $TIMEOUT comment
fi

case "$ACTION" in
    add)
        if [ -z "$CLIENT_IP" ]; then
            echo "Usage for add: $0 add <client_ip> [username]"
            exit 1
        fi
        
        if [ -n "$USERNAME" ]; then
            remember_dhcp_hostname_by_ip "$CLIENT_IP"
            if ipset -! add "$IPSET_NAME" "$CLIENT_IP" timeout "$TIMEOUT" 2>/dev/null; then
                set_mapped_user "$CLIENT_IP" "$USERNAME"
                set_mapped_fido_key "$CLIENT_IP" "$FIDO_CREDENTIAL_ID" "$FIDO_KEY_INDEX"
                ensure_dhcp_lease_by_ip "$CLIENT_IP" "$USERNAME"
                log "event=login result=success mode=fido user=$USERNAME ip=$CLIENT_IP$(client_identity_fields "$CLIENT_IP") timeout=${TIMEOUT}s"
            else
                log "event=login result=failure mode=fido user=$USERNAME ip=$CLIENT_IP reason=ipset_add_failed"
                exit 1
            fi
        else
            remember_dhcp_hostname_by_ip "$CLIENT_IP"
            if ipset -! add "$IPSET_NAME" "$CLIENT_IP" timeout "$TIMEOUT" 2>/dev/null; then
                set_mapped_fido_key "$CLIENT_IP" "$FIDO_CREDENTIAL_ID" "$FIDO_KEY_INDEX"
                ensure_dhcp_lease_by_ip "$CLIENT_IP" ""
                log "event=login result=success mode=fido user=unknown ip=$CLIENT_IP$(client_identity_fields "$CLIENT_IP") timeout=${TIMEOUT}s"
            else
                log "event=login result=failure mode=fido user=unknown ip=$CLIENT_IP reason=ipset_add_failed"
                exit 1
            fi
        fi
        ;;

    del|delete|remove)
        if [ -z "$CLIENT_IP" ]; then
            echo "Usage for del: $0 del <client_ip>"
            exit 1
        fi
        CURRENT_USER="$(ipset list "$IPSET_NAME" 2>/dev/null | awk -v target="$CLIENT_IP" '
            $1 == target {
                for (i = 1; i <= NF; i += 1) {
                    if ($i == "comment") {
                        value = $(i + 1)
                        gsub(/^"/, "", value)
                        gsub(/"$/, "", value)
                        print value
                        exit
                    }
                }
            }
        ')"
        [ -n "$CURRENT_USER" ] || CURRENT_USER="$(get_mapped_user "$CLIENT_IP")"
        [ -n "$CURRENT_USER" ] || CURRENT_USER="unknown"
        ipset del $IPSET_NAME $CLIENT_IP 2>/dev/null
        IDENTITY_FIELDS="$(client_identity_fields "$CLIENT_IP")"
        delete_mapped_user "$CLIENT_IP"
        delete_mapped_fido_key "$CLIENT_IP"
        delete_dhcp_lease_by_ip "$CLIENT_IP"
        log "event=logout result=success mode=fido user=$CURRENT_USER ip=$CLIENT_IP$IDENTITY_FIELDS"
        ;;

    del_by_user)
        # Here CLIENT_IP arg is actually acting as the username parameter
        TARGET_USER="$2"
        if [ -z "$TARGET_USER" ]; then
            echo "Usage for del_by_user: $0 del_by_user <username>"
            exit 1
        fi
        
        # Find IP(s) matching the user. Prefer the sidecar map because some
        # ipset builds crash when adding entries with the comment extension.
        IPS_TO_DELETE=$(
            {
                ipset list "$IPSET_NAME" 2>/dev/null | grep "comment \"$TARGET_USER\"" | awk '{print $1}'
                [ -f "$USER_MAP_FILE" ] && awk -F'|' -v target="$TARGET_USER" '$2 == target { print $1 }' "$USER_MAP_FILE"
            } | sort -u
        )
        
        if [ -z "$IPS_TO_DELETE" ]; then
            log "No IP found for user $TARGET_USER in $IPSET_NAME"
        else
            for IP in $IPS_TO_DELETE; do
                ipset del $IPSET_NAME "$IP" 2>/dev/null
                IDENTITY_FIELDS="$(client_identity_fields "$IP")"
                delete_mapped_user "$IP"
                delete_mapped_fido_key "$IP"
                delete_dhcp_lease_by_ip "$IP"
                log "event=logout result=success mode=fido user=$TARGET_USER ip=$IP$IDENTITY_FIELDS reason=user_removed"
            done
        fi
        ;;

    *)
        echo "Invalid action: $ACTION"
        exit 1
        ;;
esac

exit 0
