#!/bin/sh
# shellcheck disable=SC3043,SC1091,SC2155,SC3020,SC3010,SC2016,SC2317,SC3060,SC3057,SC3003

VERSION="1.2.0" # will become obsolete in future releases as version string is now in the init script

# uncomment to enable debug messages
# BMCQOS_DEBUG=1

_NL_='
'
DEFAULT_IFS=" 	${_NL_}"
IFS="$DEFAULT_IFS"

: "${VERSION}" "${global_enabled:=}" "${nongameqdisc:=}" "${nongameqdiscoptions:=}" "${OVERHEAD:=}"

. /lib/functions.sh

# Config is loaded by the caller (bmcqos init), this is a fallback just in case
[ -n "$BMCQOS_CONFIG_LOADED" ] || {
    . /etc/init.d/bmcqos
    load_and_fix_config || exit 1
}

error_out() { log_msg -err "${@}"; }

# prints each argument to a separate line
print_msg() {
    # Write to the inherited descriptors instead of redirecting to /dev/stdout: that re-opens the
    # target, and when stdout is a regular file '>' truncates it.
    local _arg to_stderr='' msgs_prefix=''
    for _arg in "$@"
    do
        case "${_arg}" in
            -err) to_stderr=1 msgs_prefix="Error: " ;;
            -warn) to_stderr=1 msgs_prefix="Warning: " ;;
            '') printf '\n' ;; # print out empty lines
            *)
                if [ -n "$to_stderr" ]; then
                    printf '%s\n' "${msgs_prefix}${_arg}" >&2
                else
                    printf '%s\n' "${msgs_prefix}${_arg}"
                fi
                msgs_prefix=''
        esac
    done
    :
}

# logs each argument separately and prints to a separate line
# optional arguments: '-err', '-warn' to set logged error level
log_msg() {
    local msgs_prefix='' _arg err_l=info

    local IFS="$DEFAULT_IFS"
    for _arg in "$@"
    do
        case "${_arg}" in
            "-err") err_l=err msgs_prefix="Error: " ;;
            "-warn") err_l=warn msgs_prefix="Warning: " ;;
            '') printf '\n' ;; # print out empty lines
            *)
                case "$err_l" in
                    err|warn) printf '%s\n' "${msgs_prefix}${_arg}" >&2 ;;
                    *) printf '%s\n' "${msgs_prefix}${_arg}"
                esac
                logger -t bmcqos -p user."$err_l" "${msgs_prefix}${_arg}"
                msgs_prefix=''
        esac
    done
    :
}

config_load 'bmcqos' || { error_out "Failed to get UCI config."; exit 1; }

# Check if Software Flow Offloading is enabled
SFO_ENABLED=0
[ "$(uci -q get firewall.@defaults[0].flow_offloading)" = "1" ] && SFO_ENABLED=1

# Calculated values
FIRST500MS=$((DOWNRATE * 500 / 8))
FIRST10S=$((DOWNRATE * 10000 / 8))

# Get tc stab parameters for HFSC/HTB/Hybrid
get_tc_overhead_params() {
    local preset="$COMMON_LINK_PRESETS"
    local overhead="$OVERHEAD"
    
    # Detect ATM-based presets
    case "$preset" in
        *atm*|*adsl*|*pppoa*|*pppoe*|*bridged*|*ipoa*|conservative)
            printf '%s' "stab mtu 2047 tsize 512 mpu 68 overhead ${overhead:-44} linklayer atm"
            ;;
        docsis)
            printf '%s' "stab overhead ${overhead:-25} linklayer ethernet"
            ;;
        cake-ethernet)
            printf '%s' "stab overhead ${overhead:-38} linklayer ethernet"
            ;;
        raw)
            printf '%s' "stab overhead ${overhead:-0} linklayer ethernet"
            ;;
        *)
            printf '%s' "stab overhead ${overhead:-40} linklayer ethernet"
            ;;
    esac
}

# Get CAKE parameters from common link settings
# $1 = "hybrid": CAKE runs below an HFSC root that already accounts for the overhead
get_cake_link_params() {
    local preset="$COMMON_LINK_PRESETS"
    local oh="${OVERHEAD}"
    local base=""

    # The HFSC root carries a tc stab, which rewrites qdisc_pkt_len for the whole
    # hierarchy. "raw" makes CAKE bill that already adjusted length instead of
    # adding the overhead a second time.
    [ "$1" = "hybrid" ] && { printf 'raw'; return; }

    # Determine base keyword and default overhead
    case "$preset" in
        *atm*|*adsl*|*pppoa*|*pppoe*|*bridged*|*ipoa*|conservative)
            base="${preset}"
            : "${oh:=44}"
            ;;
        docsis)       base="docsis";   : "${oh:=25}" ;;
        cake-ethernet) base="ethernet"; oh="" ;;
        raw)          base="raw";      : "${oh:=0}" ;;
        ethernet|*)   base="ethernet"; : "${oh:=40}" ;;
    esac

    # Build parameters
    printf "%s%s%s%s" \
        "$base" \
        "${oh:+ overhead $oh}" \
        "${MPU:+ mpu $MPU}" \
        "${ETHER_VLAN_KEYWORD:+ $ETHER_VLAN_KEYWORD}"
}

# Select cake or cake_mq based on USE_MQ setting and system capabilities
# $1: interface name to check for multi-queue support
# Sets REPLY to "cake" or "cake_mq"
select_cake_qdisc() {
    local iface="$1" num_queues=0
    REPLY="cake"

    [ "$USE_MQ" != "1" ] && return

    num_queues=$(find /sys/class/net/"$iface"/queues/ -maxdepth 1 -type d -name 'tx-*' 2>/dev/null | wc -l)

    if [ "$num_queues" -gt 1 ] && tc qdisc replace dev "$iface" root cake_mq 2>/dev/null; then
        tc qdisc del dev "$iface" root 2>/dev/null
        log_msg "Using cake_mq for $iface ($num_queues TX queues)"
        REPLY="cake_mq"
    else
        if [ "$num_queues" -le 1 ]; then
            log_msg "cake_mq not used for $iface: only $num_queues TX queue(s), using cake"
        else
            log_msg "cake_mq not available in kernel, using cake for $iface"
        fi
    fi
}

##############################
# Variable checks and dynamic rule generation
##############################

# Debug function
debug_log() {
    [ -n "$BMCQOS_DEBUG" ] || return 0
    logger -s -t bmcqos "$1" >&2
}

# Apply the fw3 classifier before attaching qdiscs. The classifier writes DSCP
# into conntrack; tc-ctinfo restores it on the redirected ingress path.
/usr/lib/bmcqos/firewall.sh apply || {
    error_out "Failed to apply fw3/iptables classification rules."
    exit 1
}

## Set up ctinfo downstream shaping

if [ "$SHAPE_INGRESS" = 1 ]; then
    print_msg "" "Setting up ctinfo downstream shaping..."

    # Set up ingress handle for WAN interface
    tc qdisc add dev "$WAN" handle ffff: ingress

    # Create IFB interface (multi-queue when USE_MQ is enabled for cake_mq ingress support)
    # Match the WAN TX queue count so egress and ingress CAKE instances are symmetric
    ifb_mq_args=""
    if [ "$USE_MQ" = "1" ]; then
        wan_tx_queues=$(find /sys/class/net/"$WAN"/queues/ -maxdepth 1 -type d -name 'tx-*' 2>/dev/null | wc -l)
        [ "$wan_tx_queues" -gt 1 ] && ifb_mq_args="numtxqueues $wan_tx_queues"
    fi
    # shellcheck disable=SC2086  # ifb_mq_args needs word splitting (e.g. "numtxqueues 4" → two args)
    ip link add name "ifb-$WAN" $ifb_mq_args type ifb
    ip link set "ifb-$WAN" up

    # Redirect ingress traffic from WAN to IFB and restore DSCP from conntrack
    tc filter add dev "$WAN" parent ffff: protocol all matchall action ctinfo dscp 63 128 mirred egress redirect dev "ifb-$WAN"
    LAN=ifb-$WAN
else
    # Rate 0 disables this direction: drop a previously created ingress path
    print_msg "" "Ingress shaping disabled (DOWNRATE=0) - removing ingress path."
    LAN=''
    tc qdisc del dev "ifb-$WAN" root > /dev/null 2>&1
    tc qdisc del dev "$WAN" ingress > /dev/null 2>&1
    ip link del "ifb-$WAN" > /dev/null 2>&1
fi

# Minimum jitter estimate; only meaningful for a direction that is actually shaped
jitter_up="not shaped (UPRATE=0)"
jitter_down="not shaped (DOWNRATE=0)"
[ "$SHAPE_EGRESS" = 1 ] && jitter_up="$(((1500*8)*3/UPRATE)) ms"
[ "$SHAPE_INGRESS" = 1 ] && jitter_down="$(((1500*8)*3/DOWNRATE)) ms"

cat <<EOF

This script prioritizes the UDP packets from / to a set of gaming
machines into a real-time HFSC queue with guaranteed total bandwidth 

Based on your settings:

Game upload guarantee = $GAMEUP kbps
Game download guarantee = $GAMEDOWN kbps

Download direction only works if you install this on a *wired* router
and there is a separate AP wired into your network, because otherwise
there are multiple parallel queues for traffic to leave your router
heading to the LAN.

Based on your link total bandwidth, the **minimum** amount of jitter
you should expect in your network is about:

UP = $jitter_up

DOWN = $jitter_down

In order to get lower minimum jitter you must upgrade the speed of
your link, no queuing system can help.

Please note for your display rate that:

at 30Hz, one on screen frame lasts:   33.3 ms
at 60Hz, one on screen frame lasts:   16.6 ms
at 144Hz, one on screen frame lasts:   6.9 ms

This means the typical gamer is sensitive to as little as on the order
of 5ms of jitter. To get 5ms minimum jitter you should have bandwidth
in each direction of at least:

$((1500*8*3/5)) kbps

The queue system can ONLY control bandwidth and jitter in the link
between your router and the VERY FIRST device in the ISP
network. Typically you will have 5 to 10 devices between your router
and your gaming server, any of those can have variable delay and ruin
your gaming, and there is NOTHING that your router can do about it.

EOF


##############################
#       QoS Setup Functions
##############################

# 1 - device
# 2 - class enum
# 3 - family (ipv4|ipv6)
add_tc_filter() {
    local class_id dsfield hex_match proto prio match_str \
        dev="$1" \
        class_enum="$2" \
        family="$3"

    case "$class_enum" in
        cs0|CS0) class_id=1:13 dsfield=0x00 hex_match=0x0000 ;; # 0 -> Default
        ef|EF) class_id=1:11 dsfield=0xb8 hex_match=0x0B80 ;; # 46
        cs1|CS1) class_id=1:15 dsfield=0x20 hex_match=0x0200 ;; # 8
        cs2|CS2) class_id=1:14 dsfield=0x40 hex_match=0x0400 ;; # 16
        cs4|CS4) class_id=1:12 dsfield=0x80 hex_match=0x0800 ;; # 32
        cs5|CS5) class_id=1:11 dsfield=0xa0 hex_match=0x0A00 ;; # 40
        cs6|CS6) class_id=1:11 dsfield=0xc0 hex_match=0x0C00 ;; # 48
        cs7|CS7) class_id=1:11 dsfield=0xe0 hex_match=0x0E00 ;; # 56
        af11|AF11) class_id=1:14 dsfield=0x28 hex_match=0x0280 ;; # 10
        af41|AF41) class_id=1:12 dsfield=0x88 hex_match=0x0880 ;; # 34
        af42|AF42) class_id=1:12 dsfield=0x90 hex_match=0x0900 ;; # 36
        *) # TODO: throw an error
    esac

    case "$family" in
        ipv4)
            proto=ip prio=10 match_str="ip dsfield $dsfield 0xfc"
            ;;
        ipv6)
            proto=ipv6 prio=11 match_str="u16 $hex_match 0x0FC0 at 0"
            ;;
    esac

    # shellcheck disable=SC2086
    tc filter add dev "$dev" parent 1: protocol "$proto" prio "$prio" u32 match $match_str classid "$class_id"
}

# Function to setup the specific game qdisc (pfifo, red, fq_codel, netem, etc.)
# Arguments: $1:DEV, $2:RATE, $3:GAMERATE, $4:QDISC_TYPE, $5:DIR, $6:MTU, ... HFSC params ...
setup_game_qdisc() {
    local DEV="$1" RATE="$2" GAMERATE="$3" QDISC_TYPE="$4" DIR="$5" MTU="$6"
    local MAXDEL="$7" PFIFOMIN="$8" PACKETSIZE="$9"
    local netemdelayms="${10}" netemjitterms="${11}" netemdist="${12}" NETEM_DIRECTION="${13}" pktlossp="${14}"

    # Ensure rates/packetsize are non-zero to avoid errors in calculations
    [ "$RATE" -le 0 ] && RATE=1
    [ "$GAMERATE" -le 0 ] && GAMERATE=1
    [ "$PACKETSIZE" -le 0 ] && PACKETSIZE=1

    # Calculate REDMIN and REDMAX based on gamerate and MAXDEL
    local REDMIN=$((GAMERATE * MAXDEL / 3 / 8))
    local REDMAX=$((GAMERATE * MAXDEL / 8))
    # Calculate BURST: (min + min + max)/(3 * avpkt) as per RED documentation
    local BURST=$(( (REDMIN + REDMIN + REDMAX) / (3 * 500) )); [ $BURST -lt 2 ] && BURST=2

    # for fq_codel
    local INTVL=$((100+2*1500*8/RATE))
    local TARG=$((540*8/RATE+4))

    # Delete previous qdisc on this handle if it exists (optional, but good practice)
    tc qdisc del dev "$DEV" parent 1:11 handle 10: > /dev/null 2>&1

    case $QDISC_TYPE in
        "drr")
            tc qdisc add dev "$DEV" parent 1:11 handle 10: drr
            tc class add dev "$DEV" parent 10: classid 10:1 drr quantum 8000
            tc qdisc add dev "$DEV" parent 10:1 handle 11: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth "${RATE}kbit" probability 1.0 burst $BURST
            tc class add dev "$DEV" parent 10: classid 10:2 drr quantum 4000
            tc qdisc add dev "$DEV" parent 10:2 handle 12: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth "${RATE}kbit" probability 1.0 burst $BURST
            tc class add dev "$DEV" parent 10: classid 10:3 drr quantum 1000
            tc qdisc add dev "$DEV" parent 10:3 handle 13: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth "${RATE}kbit" probability 1.0 burst $BURST
        ;;
        "qfq")
            tc qdisc add dev "$DEV" parent 1:11 handle 10: qfq
            tc class add dev "$DEV" parent 10: classid 10:1 qfq weight 8000
            tc qdisc add dev "$DEV" parent 10:1 handle 11: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth "${RATE}kbit" probability 1.0 burst $BURST
            tc class add dev "$DEV" parent 10: classid 10:2 qfq weight 4000
            tc qdisc add dev "$DEV" parent 10:2 handle 12: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth "${RATE}kbit" probability 1.0 burst $BURST
            tc class add dev "$DEV" parent 10: classid 10:3 qfq weight 1000
            tc qdisc add dev "$DEV" parent 10:3 handle 13: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth "${RATE}kbit" probability 1.0 burst $BURST
        ;;
        "pfifo")
            tc qdisc add dev "$DEV" parent 1:11 handle 10: pfifo limit $((PFIFOMIN+MAXDEL*RATE/8/PACKETSIZE))
        ;;
        "bfifo")
            tc qdisc add dev "$DEV" parent 1:11 handle 10: bfifo limit $((MAXDEL * GAMERATE / 8))
            #tc qdisc add dev "$DEV" parent 1:11 handle 10: bfifo limit $((MAXDEL * RATE / 8))
        ;;
        "red")
            tc qdisc add dev "$DEV" parent 1:11 handle 10: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth "${RATE}kbit" burst $BURST probability 1.0
            ## send game packets to 10:, they're all treated the same
        ;;
        "fq_codel")
        tc qdisc add dev "$DEV" parent "1:11" handle 10: fq_codel memory_limit $((RATE*200/8)) interval "${INTVL}ms" target "${TARG}ms" quantum $((MTU * 2))
        ;;
        "netem")
            # Only apply NETEM if this direction is enabled
            if [ "$NETEM_DIRECTION" = "both" ] || \
               { [ "$NETEM_DIRECTION" = "egress" ] && [ "$DIR" = "wan" ]; } || \
               { [ "$NETEM_DIRECTION" = "ingress" ] && [ "$DIR" = "lan" ]; }; then
                
                NETEM_CMD="tc qdisc add dev \"$DEV\" parent 1:11 handle 10: netem limit $((4+9*RATE/8/500))"
                
                # If jitter is set but delay is 0, force minimum delay of 1ms
                if [ "$netemjitterms" -ne 0 ] && [ "$netemdelayms" -eq 0 ]; then
                    netemdelayms=1
                fi

                # Add delay parameter if set (either original or forced minimum)
                if [ "$netemdelayms" -ne 0 ]; then
                    NETEM_CMD="$NETEM_CMD delay ${netemdelayms}ms"
                    
                    # Add jitter if set
                    if [ "$netemjitterms" -ne 0 ]; then
                        NETEM_CMD="$NETEM_CMD ${netemjitterms}ms"
                        NETEM_CMD="$NETEM_CMD distribution $netemdist"
                    fi
                fi
                
                # Add packet loss if set
                if [ "$pktlossp" != "none" ] && [ -n "$pktlossp" ]; then
                    NETEM_CMD="$NETEM_CMD loss $pktlossp"
                fi
                
                eval "$NETEM_CMD"
            else
                # Use pfifo as fallback when NETEM is not applied in this direction
                tc qdisc add dev "$DEV" parent 1:11 handle 10: pfifo limit $((PFIFOMIN+MAXDEL*RATE/8/PACKETSIZE))
            fi
        ;;
        *)
            print_msg -err "Unsupported game qdisc type '$QDISC_TYPE'. Using pfifo fallback."
            # pfifo fallback limit calculation
            tc qdisc add dev "$DEV" parent 1:11 handle 10: pfifo limit $((PFIFOMIN+MAXDEL*RATE/8/PACKETSIZE))
        ;;
    esac
}

# Function to setup HFSC qdisc structure
# Arguments: $1:DEV, $2:RATE, $3:GAMERATE, $4:GAME_QDISC_TYPE, $5:DIR
setup_hfsc() {
    local DEV="$1" RATE="$2" GAMERATE="$3" GAME_QDISC_TYPE="$4" DIR="$5"
    local MTU=1500

    tc qdisc del dev "$DEV" root > /dev/null 2>&1

    # Get overhead parameters from CAKE configuration
    local TC_OH_PARAMS
    TC_OH_PARAMS=$(get_tc_overhead_params)
    
    # Apply root qdisc
    # shellcheck disable=SC2086
    tc qdisc replace dev "$DEV" handle 1: root ${TC_OH_PARAMS} hfsc default 13

    # DUR calculation
    local DUR=$((5*1500*8/RATE)); [ $DUR -lt 25 ] && DUR=25

    # Router traffic class (only on LAN/IFB)
    if [ "$DIR" = "lan" ]; then
        tc class add dev "$DEV" parent 1: classid 1:2 hfsc ls m1 50000kbit d "${DUR}ms" m2 10000kbit
    fi

    # Main link class
    tc class add dev "$DEV" parent 1: classid 1:1 hfsc ls m2 "${RATE}kbit" ul m2 "${RATE}kbit"
    # gameburst calculation
    local gameburst=$((GAMERATE*10)); [ $gameburst -gt $((RATE*97/100)) ] && gameburst=$((RATE*97/100));

    # Define HFSC Classes
    tc class add dev "$DEV" parent 1:1 classid 1:11 hfsc rt m1 "${gameburst}kbit" d "${DUR}ms" m2 "${GAMERATE}kbit" # Realtime
    tc class add dev "$DEV" parent 1:1 classid 1:12 hfsc ls m1 "$((RATE*70/100))kbit" d "${DUR}ms" m2 "$((RATE*30/100))kbit" # Fast
    tc class add dev "$DEV" parent 1:1 classid 1:13 hfsc ls m1 "$((RATE*20/100))kbit" d "${DUR}ms" m2 "$((RATE*45/100))kbit" # Normal (Default)
    tc class add dev "$DEV" parent 1:1 classid 1:14 hfsc ls m1 "$((RATE*7/100))kbit" d "${DUR}ms" m2 "$((RATE*15/100))kbit"  # Low Prio
    tc class add dev "$DEV" parent 1:1 classid 1:15 hfsc ls m1 "$((RATE*3/100))kbit" d "${DUR}ms" m2 "$((RATE*10/100))kbit"  # Bulk

    # Attach Qdiscs
    setup_game_qdisc "$DEV" "$RATE" "$GAMERATE" "$GAME_QDISC_TYPE" "$DIR" \
                     "$MTU" "$MAXDEL" "$PFIFOMIN" "$PACKETSIZE" \
                     "$netemdelayms" "$netemjitterms" "$netemdist" "$NETEM_DIRECTION" "$pktlossp"

    # Attach non-game qdiscs
    local INTVL=$((100+2*1500*8/RATE))
    local TARG=$((540*8/RATE+4))
    for i in 12 13 14 15; do 
        if [ "$nongameqdisc" = "cake" ]; then
            # shellcheck disable=SC2086  # nongameqdiscoptions needs word splitting (e.g. "besteffort ack-filter")
            tc qdisc add dev "$DEV" parent "1:$i" cake $nongameqdiscoptions
        elif [ "$nongameqdisc" = "fq_codel" ]; then
            tc qdisc add dev "$DEV" parent "1:$i" fq_codel memory_limit "$((RATE*200/8))" interval "${INTVL}ms" target "${TARG}ms" quantum "$((MTU * 2))"
        else
            print_msg -err "Unsupported qdisc for non-game traffic: $nongameqdisc"
            exit 1
        fi
    done

    # fw3 sets DSCP but cannot set nftables meta priority. Map DSCP to the
    # appropriate class with tc filters in both directions.
    if true; then
        # Delete existing filters first
        tc filter del dev "$DEV" parent 1: prio 1 > /dev/null 2>&1
        tc filter del dev "$DEV" parent 1: prio 2 > /dev/null 2>&1 # Also delete prio 2

        local family class_enum
        for family in ipv4 ipv6; do
            for class_enum in ef cs5 cs6 cs7 cs4 af41 af42 cs2 af11 cs1 cs0; do
                add_tc_filter "$DEV" "$class_enum" "$family"
            done
        done
    fi
    :
}


qdisc_setup_failed() {
    [ -n "$1" ] && error_out "$1"
    error_out "Failed to set up $ROOT_QDISC."
    # *** Any additional error handling needed? ***
    exit 1
}

# Appends option to ${CAKE_OPTS}
# 1: parameter: nat|wash|ack_filter|*
# 2: selector (1|0)
#    for wash, nat, ack-filter: selector value '1' translates to prefix '', any other value translates to prefix 'no[-]'
#    for other options: selector value '1' translates to 'don't skip option', any other value translates to 'skip option'
append_cake_opt() {
    [ ${#} = 2 ] || { error_out "append_cake_opt: invalid args '$*'."; return 1; }
    local prefix='' \
        param="$1" selector="$2"
    [ -n "$param" ] || return 0
    [ "$selector" != 1 ] &&
        case "$param" in
            wash|nat) prefix='no' ;;
            ack-filter) prefix='no-' ;;
            *) return 0 ;;
        esac
    CAKE_OPTS="${CAKE_OPTS} ${prefix}${param}"
    :
}

# Function to setup CAKE qdisc
setup_cake() {
    tc qdisc del dev "$WAN" root > /dev/null 2>&1
    tc qdisc del dev "$LAN" root > /dev/null 2>&1
    
    # Get CAKE link parameters
    local ack_filter_egress_val cake_link_params="$(get_cake_link_params)"

    # Select cake or cake_mq based on WAN capabilities (IFB mirrors WAN queue count)
    local CAKE_QDISC_EGR CAKE_QDISC_IGR CAKE_OPTS
    select_cake_qdisc "$WAN"
    CAKE_QDISC_EGR="$REPLY"
    CAKE_QDISC_IGR="$REPLY"

    # Egress (Upload) CAKE setup
    if [ "$SHAPE_EGRESS" = 1 ]; then
        case "$ACK_FILTER_EGRESS" in
            # 'auto' needs a known download rate; keep the filter off without ingress shaping
            auto) ack_filter_egress_val=$(( DOWNRATE > 0 && (DOWNRATE / UPRATE) >= 15 )) ;;
            *[!0-9]*|'') qdisc_setup_failed "Invalid value '$ACK_FILTER_EGRESS' for ACK_FILTER_EGRESS." ;;
            *) ack_filter_egress_val=$ACK_FILTER_EGRESS ;;
        esac

        CAKE_OPTS="bandwidth ${UPRATE}kbit"
        # shellcheck disable=SC2086
        append_cake_opt "$PRIORITY_QUEUE_EGRESS" "1" &&
        append_cake_opt "dual-srchost" "$HOST_ISOLATION" &&
        append_cake_opt "rtt ${RTT}ms" "${RTT:+1}" &&
        append_cake_opt "$cake_link_params" "1" &&
        append_cake_opt "$LINK_COMPENSATION" "1" &&
        append_cake_opt "$EXTRA_PARAMETERS_EGRESS" "1" &&
        append_cake_opt "nat" "$NAT_EGRESS" &&
        append_cake_opt "wash" "$WASHDSCPUP" &&
        append_cake_opt "ack-filter" "$ack_filter_egress_val" &&
        tc qdisc add dev "$WAN" root handle 1: "$CAKE_QDISC_EGR" $CAKE_OPTS || qdisc_setup_failed
        debug_log "EGRESS $CAKE_QDISC_EGR opts: '$CAKE_OPTS'"
    fi
    

    # Ingress (Download) CAKE setup
    if [ "$SHAPE_INGRESS" = 1 ]; then
        CAKE_OPTS="bandwidth ${DOWNRATE}kbit ingress"
        # shellcheck disable=SC2086
        append_cake_opt "autorate-ingress" "$AUTORATE_INGRESS" &&
        append_cake_opt "$PRIORITY_QUEUE_INGRESS" "1" &&
        append_cake_opt "dual-dsthost" "$HOST_ISOLATION" &&
        append_cake_opt "rtt ${RTT}ms" "${RTT:+1}" &&
        append_cake_opt "$cake_link_params" "1" &&
        append_cake_opt "$LINK_COMPENSATION" "1" &&
        append_cake_opt "$EXTRA_PARAMETERS_INGRESS" "1" &&
        append_cake_opt "nat" "$NAT_INGRESS" &&
        append_cake_opt "wash" "$WASHDSCPDOWN" &&
        tc qdisc add dev "$LAN" root "$CAKE_QDISC_IGR" $CAKE_OPTS || qdisc_setup_failed
        debug_log "INGRESS $CAKE_QDISC_IGR opts: '$CAKE_OPTS'"
    fi

    # Write active cake qdisc type for autorate daemon
    printf '%s\n' "$CAKE_QDISC_EGR" > /tmp/bmcqos/cake_type
}

# Helper function to set up hybrid qdisc on an interface
# Arguments: $1:DEV, $2:RATE, $3:GAMERATE, $4:DIR
setup_hybrid() {
    local DEV="$1" RATE="$2" GAMERATE="$3" DIR="$4"
    local MTU=1500

    # Calculate parameters
    local DUR=$((5*1500*8/RATE)); [ $DUR -lt 25 ] && DUR=25
    local gameburst=$((GAMERATE*10)); [ $gameburst -gt $((RATE*97/100)) ] && gameburst=$((RATE*97/100));

    # Setup root HFSC qdisc (default to 1:13 - CAKE class)
    local TC_OH_PARAMS
    TC_OH_PARAMS=$(get_tc_overhead_params)
    
    # Ensure previous root is deleted before replacing
    tc qdisc del dev "$DEV" root > /dev/null 2>&1
    tc qdisc replace dev "$DEV" handle 1: root ${TC_OH_PARAMS} hfsc default 13

    # Router traffic class (only on LAN/IFB)
    if [ "$DIR" = "lan" ]; then
        tc class add dev "$DEV" parent 1: classid 1:2 hfsc ls m1 50000kbit d "${DUR}ms" m2 10000kbit
    fi

    # Main link class
    tc class add dev "$DEV" parent 1: classid 1:1 hfsc ls m2 "${RATE}kbit" ul m2 "${RATE}kbit"

    # Class 1:11 - High priority realtime (HFSC RT + gameqdisc)
    tc class add dev "$DEV" parent 1:1 classid 1:11 hfsc rt m1 "${gameburst}kbit" d "${DUR}ms" m2 "${GAMERATE}kbit"
    # Attach game qdisc (using $gameqdisc from HFSC config)
    setup_game_qdisc "$DEV" "$RATE" "$GAMERATE" "$gameqdisc" "$DIR" \
                     "$MTU" "$MAXDEL" "$PFIFOMIN" "$PACKETSIZE" \
                     "$netemdelayms" "$netemjitterms" "$netemdist" "$NETEM_DIRECTION" "$pktlossp"

    # Class 1:13 - CAKE class (most traffic - default)
    local cake_rate=$((RATE - GAMERATE)); [ $cake_rate -le 0 ] && cake_rate=1
    tc class add dev "$DEV" parent 1:1 classid 1:13 hfsc ls m1 "${cake_rate}kbit" d "${DUR}ms" m2 "${cake_rate}kbit"

    # Attach CAKE qdisc - use "hybrid" mode to match HFSC overhead
    local cake_link_params="$(get_cake_link_params "hybrid")"
    local CAKE_OPTS=""
    tc qdisc del dev "$DEV" parent 1:13 handle 13: > /dev/null 2>&1
    
    # shellcheck disable=SC2086
    if [ "$DIR" = "wan" ]; then
        CAKE_OPTS="besteffort" # Default for non-realtime in hybrid
        append_cake_opt "dual-srchost" "$HOST_ISOLATION" &&
        append_cake_opt "$EXTRA_PARAMETERS_EGRESS" "1" &&
        append_cake_opt "nat" "$NAT_EGRESS" &&
        append_cake_opt "wash" "$WASHDSCPUP"
    else # lan (ingress)
        CAKE_OPTS="besteffort ingress" # Default for non-realtime in hybrid
        append_cake_opt "dual-dsthost" "$HOST_ISOLATION" &&
        append_cake_opt "$EXTRA_PARAMETERS_INGRESS" "1" &&
        append_cake_opt "nat" "$NAT_INGRESS" &&
        append_cake_opt "wash" "$WASHDSCPDOWN"
    fi &&
    append_cake_opt "rtt ${RTT}ms" "${RTT:+1}" &&
    append_cake_opt "$cake_link_params" "1" &&
    append_cake_opt "$LINK_COMPENSATION" "1" &&
    tc qdisc replace dev "$DEV" parent 1:13 handle 13: cake $CAKE_OPTS || qdisc_setup_failed
debug_log "$DIR HYBRID cake opts: '$CAKE_OPTS'"

    # Class 1:15 - Bulk traffic (HFSC LS + fq_codel)
    # Use HFSC limits: m1 3%, m2 10%
    local bulk_rate_m1=$((RATE*3/100)); [ $bulk_rate_m1 -le 0 ] && bulk_rate_m1=1
    local bulk_rate_m2=$((RATE*10/100)); [ $bulk_rate_m2 -le 0 ] && bulk_rate_m2=1
    tc class add dev "$DEV" parent 1:1 classid 1:15 hfsc ls m1 "${bulk_rate_m1}kbit" d "${DUR}ms" m2 "${bulk_rate_m2}kbit"
    # Attach fq_codel (using calculations and options from HFSC config)
    local INTVL=$((100+2*1500*8/RATE))
    local TARG=$((540*8/RATE+4))
    tc qdisc del dev "$DEV" parent 1:15 handle 15: > /dev/null 2>&1
    tc qdisc replace dev "$DEV" parent 1:15 handle 15: fq_codel memory_limit $((RATE*200/8)) interval "${INTVL}ms" target "${TARG}ms" quantum $((MTU * 2))

    # fw3 provides DSCP only, so both directions need tc class filters.
    if true; then
        # Delete existing filters
        tc filter del dev "$DEV" parent 1: prio 1 > /dev/null 2>&1
        tc filter del dev "$DEV" parent 1: prio 2 > /dev/null 2>&1

        local class_enum

        # IPv4 Filters (prio 1)
        # EF, CS5, CS6, CS7 -> Realtime
        # CS1 -> Bulk
        for class_enum in ef cs5 cs6 cs7 cs1; do
            add_tc_filter "$DEV" "$class_enum" "ipv4"
        done
        # Default rule sends to 1:13 (CAKE)

        # IPv6 Filters (prio 2)
        for class_enum in ef cs5 cs6 cs7 cs1 cs0; do
            add_tc_filter "$DEV" "$class_enum" "ipv6"
        done
    fi
}

# Helper functions for HTB dynamic parameter calculation
# Calculate optimal HTB quantum based on rate
calculate_htb_quantum() {
    local rate="$1"
    local duration_us="${2:-1000}"  # Default 1ms = 1000µs
    local MTU=1500
    
    # Duration-based calculation (SQM-style)
    # rate in kbit/s, duration in µs, result in bytes
    local quantum=$(((duration_us * rate) / 8000))
    
    # ATM-aware minimum
    if [ "$COMMON_LINK_PRESETS" = "atm" ]; then
        local min_quantum=$(((MTU + 48 + 47) / 48 * 53))
        [ $quantum -lt $min_quantum ] && quantum=$min_quantum
    else
        [ $quantum -lt $MTU ] && quantum=$MTU
    fi
    
    # Maximum reasonable quantum (200KB)
    [ $quantum -gt 200000 ] && quantum=200000
    
    echo $quantum
}

# Calculate HTB burst size based on rate and target latency
calculate_htb_burst() {
    local rate="$1"
    local duration_us="${2:-10000}"  # Default 10ms = 10000µs
    
    # burst in bytes for given duration
    local burst=$(((duration_us * rate) / 8000))
    
    # Minimum burst should be at least 1 MTU
    [ $burst -lt 1500 ] && burst=1500
    
    echo $burst
}

# Function to setup HTB qdisc (simple.qos style with 3 classes)
setup_htb() {
    local DEV="$1" RATE="$2" DIR="$3"
    local MTU=1500

    # Ensure rate is valid
    [ "$RATE" -le 0 ] && RATE=1

    # Delete existing qdisc
    tc qdisc del dev "$DEV" root > /dev/null 2>&1

    # Get overhead parameters from CAKE configuration
    local TC_OH_PARAMS
    TC_OH_PARAMS=$(get_tc_overhead_params)

    # Setup HTB root with default to best effort (class 13)
    tc qdisc add dev "$DEV" root handle 1: $TC_OH_PARAMS htb default 13

    # Calculate HTB quantum for root (all use same quantum)
    local HTB_QUANTUM="$(calculate_htb_quantum "$RATE")"

    # Root class gets modest burst since we typically configure 80-90% of physical rate
    # This allows brief bursts into the headroom without causing bufferbloat
    local ROOT_BURST="$(calculate_htb_burst "$RATE" 1000)"   # 1ms burst
    local ROOT_CBURST="$(calculate_htb_burst "$RATE" 1000)"  # 1ms cburst

    # Create main rate limiting class
    tc class add dev "$DEV" parent 1: classid 1:1 htb \
        quantum "$HTB_QUANTUM" \
        rate "${RATE}kbit" ceil "${RATE}kbit" \
        burst "$ROOT_BURST" cburst "$ROOT_CBURST"

    # Smart calculation that scales smoothly across all bandwidths
    # Formula: percent = 15 + (50000 / RATE), capped between 5-40%
    #
    # This creates a hyperbolic curve that provides:
    # - High percentage (up to 40%) for very low bandwidth connections
    # - Smooth decrease as bandwidth increases
    # - Stabilizes around 15% for high bandwidth connections
    #
    # Examples:
    # - 1 Mbit:   15 + 50 = 65% → capped at 40% → 400 kbit → min 800 kbit
    # - 5 Mbit:   15 + 10 = 25% → 1250 kbit
    # - 10 Mbit:  15 + 5  = 20% → 2000 kbit
    # - 50 Mbit:  15 + 1  = 16% → 8000 kbit
    # - 100 Mbit: 15 + 0.5 = 15.5% → 15500 kbit
    #
    # Visualization:
    #   40% |*
    #       |  *
    #   30% |    *
    #       |      *
    #   20% |        * * * * *
    #   15% |                  * * * * * * * *
    #       +---------------------------------> Bandwidth
    #       1    5   10   20   50  100  200 Mbit
    #
    # Two safety mechanisms ensure adequate priority bandwidth:
    # 1. Percentage-based: Scales with total bandwidth
    # 2. Absolute minimum: 800 kbit for gaming/VoIP needs

    # Calculate sliding percentage (higher % for lower rates)
    local percent=$((15 + 50000 / RATE))
    [ $percent -gt 40 ] && percent=40  # Cap at 40%
    [ $percent -lt 5 ] && percent=5     # Floor at 5%

    local percent_based=$((RATE * percent / 100))
    local absolute_min=800              # Gaming/VoIP minimum

    # Take the maximum of percentage-based and absolute minimum
    local PRIO_RATE_MIN=$percent_based
    [ $absolute_min -gt $PRIO_RATE_MIN ] && PRIO_RATE_MIN=$absolute_min

    # Calculate ceiling - ensure it's at least min + some headroom
    local PRIO_CEIL=$((RATE / 3))  # Start with 33%

    # Ensure ceiling is at least min rate + 10%
    local min_ceiling=$((PRIO_RATE_MIN * 110 / 100))
    [ $PRIO_CEIL -lt $min_ceiling ] && PRIO_CEIL=$min_ceiling

    # Calculate BE and BK rates
    local BE_MIN_RATE=$((RATE / 6))    # 16% guaranteed
    local BK_MIN_RATE=$((RATE / 6))    # 16% guaranteed

    # Adjust if total mins exceed available bandwidth
    local total_min=$((PRIO_RATE_MIN + BE_MIN_RATE + BK_MIN_RATE))
    if [ $total_min -gt $((RATE * 90 / 100)) ]; then
        # Scale down proportionally
        BE_MIN_RATE=$((BE_MIN_RATE * RATE * 90 / 100 / total_min))
        BK_MIN_RATE=$((BK_MIN_RATE * RATE * 90 / 100 / total_min))
    fi

    # BE/BK ceiling - almost full rate minus a small reserve
    local BE_CEIL=$((RATE - 16))

    # Calculate individual burst values for each class
    # Priority class burst - based on its own rate
    local PRIO_BURST="$(calculate_htb_burst $PRIO_RATE_MIN 10000)"  # 10ms burst for rate
    local PRIO_CBURST="$(calculate_htb_burst $PRIO_RATE_MIN 5000)"  # 5ms burst for ceiling
    [ "$PRIO_CBURST" -lt 1500 ] && PRIO_CBURST=1500

    # Priority class (1:11) - for realtime/gaming traffic
    tc class add dev "$DEV" parent 1:1 classid 1:11 htb \
        quantum "$HTB_QUANTUM" \
        rate "${PRIO_RATE_MIN}kbit" ceil "${PRIO_CEIL}kbit" \
        burst "$PRIO_BURST" cburst "$PRIO_CBURST" prio 1

    # Calculate BE burst values - based on its own guaranteed rate
    local BE_BURST="$(calculate_htb_burst $BE_MIN_RATE 10000)"  # 10ms burst for rate
    local BE_CBURST="$(calculate_htb_burst $BE_MIN_RATE 5000)"  # 5ms burst for ceiling
    [ "$BE_CBURST" -lt 1500 ] && BE_CBURST=1500

    # Best Effort class (1:13) - default traffic
    tc class add dev "$DEV" parent 1:1 classid 1:13 htb \
        quantum "$HTB_QUANTUM" \
        rate "${BE_MIN_RATE}kbit" ceil "${BE_CEIL}kbit" \
        burst "$BE_BURST" cburst "$BE_CBURST" prio 2

    # Calculate BK burst values - based on its own guaranteed rate
    local BK_BURST="$(calculate_htb_burst $BK_MIN_RATE 10000)"  # 10ms burst for rate
    local BK_CBURST="$(calculate_htb_burst $BK_MIN_RATE 5000)"  # 5ms burst for ceiling
    [ "$BK_CBURST" -lt 1500 ] && BK_CBURST=1500

    # Background/Bulk class (1:15) - low priority
    tc class add dev "$DEV" parent 1:1 classid 1:15 htb \
        quantum "$HTB_QUANTUM" \
        rate "${BK_MIN_RATE}kbit" ceil "${BE_CEIL}kbit" \
        burst "$BK_BURST" cburst "$BK_CBURST" prio 3

    # Attach leaf qdiscs
    # Calculate fq_codel parameters
    local INTVL=$((100+2*1500*8/RATE))
    local TARG=$((540*8/RATE+4))

    # Priority class gets fq_codel with aggressive settings
    tc qdisc add dev "$DEV" parent 1:11 handle 110: fq_codel \
        interval "${INTVL}ms" target "${TARG}ms" \
        quantum 300

    # Best effort with standard settings
    tc qdisc add dev "$DEV" parent 1:13 handle 130: fq_codel \
        interval "${INTVL}ms" target "${TARG}ms" \
        quantum 1500

    # Background with larger target
    tc qdisc add dev "$DEV" parent 1:15 handle 150: fq_codel \
        interval "$((INTVL*2))ms" target "$((TARG*2))ms" \
        quantum 300

    # fw3 provides DSCP only, so both directions need tc class filters.
    if true; then
        # Delete existing filters
        tc filter del dev "$DEV" parent 1: prio 1 > /dev/null 2>&1
        tc filter del dev "$DEV" parent 1: prio 2 > /dev/null 2>&1

        # IPv4 filters (prio 1)
        # Priority class: EF, CS5, CS6, CS7 -> 1:11
        # Background class: CS1 -> 1:15
        for class_enum in ef cs5 cs6 cs7 cs1; do
            add_tc_filter "$DEV" "$class_enum" "ipv4"
        done

        # IPv6 filters (prio 2)
        for class_enum in ef cs5 cs6 cs7 cs1 cs0; do
            add_tc_filter "$DEV" "$class_enum" "ipv6"
        done
    fi
}


##############################
#       Main Logic
##############################

# Validate gameqdisc choice (used by HFSC and Hybrid)
if [ "$ROOT_QDISC" = "hfsc" ] || [ "$ROOT_QDISC" = "hybrid" ]; then
    case "$gameqdisc" in
        drr|qfq|pfifo|bfifo|red|fq_codel|netem) ;; # Supported qdiscs
        *)
            print_msg -warn "Unsupported gameqdisc '$gameqdisc' selected in config. Reverting to 'pfifo'."
            gameqdisc="pfifo" # Revert to a simple default as fallback
            ;;
    esac
fi

# A rate of 0 disables that direction. Remove leftovers of a disabled direction so that
# switching a rate to 0 takes effect even without a full service restart.
[ "$SHAPE_EGRESS" = 1 ] || {
    print_msg "" "Egress shaping disabled (UPRATE=0) - removing root qdisc on $WAN."
    tc qdisc del dev "$WAN" root > /dev/null 2>&1
}
[ "$SHAPE_EGRESS" = 1 ] || [ "$SHAPE_INGRESS" = 1 ] ||
    log_msg -warn "No shaping active: both UPRATE and DOWNRATE are 0. Only iptables DSCP marking is applied."

# Main logic for selecting and applying the QoS system
case "$ROOT_QDISC" in
    hfsc)
        print_msg "Applying HFSC queueing discipline."
        # Call the renamed function (formerly setqdisc)
        [ "$SHAPE_EGRESS" = 1 ] && setup_hfsc "$WAN" "$UPRATE" "$GAMEUP" "$gameqdisc" wan
        [ "$SHAPE_INGRESS" = 1 ] && setup_hfsc "$LAN" "$DOWNRATE" "$GAMEDOWN" "$gameqdisc" lan
        ;;
    hybrid)
        print_msg "Applying Hybrid (HFSC+CAKE) queueing discipline."
        # Setup WAN (egress/upload) and LAN (ingress/download) directly
        [ "$SHAPE_EGRESS" = 1 ] && setup_hybrid "$WAN" "$UPRATE" "$GAMEUP" "wan"
        [ "$SHAPE_INGRESS" = 1 ] && setup_hybrid "$LAN" "$DOWNRATE" "$GAMEDOWN" "lan"
        # cake_mq not supported as child qdisc under HFSC
        printf '%s\n' "cake" > /tmp/bmcqos/cake_type
        ;;
    cake)
        print_msg "Applying CAKE queueing discipline."
        setup_cake
        ;;
    htb)
        print_msg "Applying HTB queueing discipline."
        [ "$SHAPE_EGRESS" = 1 ] && setup_htb "$WAN" "$UPRATE" "wan"
        [ "$SHAPE_INGRESS" = 1 ] && setup_htb "$LAN" "$DOWNRATE" "lan"
        ;;
    *) # Fallback for unsupported ROOT_QDISC
        print_msg -err "Unsupported ROOT_QDISC: '$ROOT_QDISC'. Check /etc/config/bmcqos."
        print_msg -warn "Falling back to default HFSC mode with pfifo game qdisc."
        ROOT_QDISC="hfsc"
        gameqdisc="pfifo" # Safe default for fallback
        # Apply the fallback configuration using the renamed function
        [ "$SHAPE_EGRESS" = 1 ] && setup_hfsc "$WAN" "$UPRATE" "$GAMEUP" "$gameqdisc" wan
        [ "$SHAPE_INGRESS" = 1 ] && setup_hfsc "$LAN" "$DOWNRATE" "$GAMEDOWN" "$gameqdisc" lan
        ;;
esac

[ "$SFO_ENABLED" = "1" ] &&
    print_msg -warn "Software Flow Offloading is enabled; disable it so all packets pass through fw3 classification."

print_msg "DONE!"

# Conditional output of tc status
if [ "$ROOT_QDISC" = "hfsc" ] && [ "$gameqdisc" = "red" ]; then
   print_msg "Can not output tc -s qdisc because it crashes on OpenWrt when using RED qdisc, but things are working!"
# Add check for hybrid mode with red gameqdisc
elif [ "$ROOT_QDISC" = "hybrid" ] && [ "$gameqdisc" = "red" ]; then
   print_msg "Can not output tc -s qdisc because it crashes on OpenWrt when using RED qdisc in hybrid mode, but things are working!"
else
   # Check if tc command exists before trying to run it
   if command -v tc >/dev/null; then
       [ "$SHAPE_EGRESS" = 1 ] && { print_msg "--- Egress ($WAN) ---"; tc -s qdisc show dev "$WAN"; }
       [ "$SHAPE_INGRESS" = 1 ] && { print_msg "--- Ingress ($LAN) ---"; tc -s qdisc show dev "$LAN"; }
   else
        print_msg "Warning: 'tc' command not found. Cannot display QoS status."
   fi
fi

exit 0
