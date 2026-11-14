#!/bin/sh
# fw3/iptables DSCP classifier for bmcqos.

. /lib/functions.sh

TAG=bmcqos
RUN_DIR=/var/run/bmcqos
V4_RULES="$RUN_DIR/iptables.rules"
V6_RULES="$RUN_DIR/ip6tables.rules"
IPSET_NAMES="$RUN_DIR/ipsets"

log() { logger -t "$TAG" "$*"; }

valid_name() {
	case "$1" in ''|*[!A-Za-z0-9_]* ) return 1 ;; esac
}

valid_value() {
	case "$1" in *[!A-Za-z0-9_@.,:/+-]* ) return 1 ;; esac
}

class_value() {
	case "$(echo "$1" | tr 'A-Z' 'a-z')" in
		cs0) echo 'CS0 0x80' ;; cs1) echo 'CS1 0x88' ;;
		cs2) echo 'CS2 0x90' ;; cs4) echo 'CS4 0xa0' ;;
		cs5) echo 'CS5 0xa8' ;; cs6) echo 'CS6 0xb0' ;;
		cs7) echo 'CS7 0xb8' ;; af11) echo 'AF11 0x8a' ;;
		af41) echo 'AF41 0xa2' ;; af42) echo 'AF42 0xa4' ;;
		ef) echo 'EF 0xae' ;; *) return 1 ;;
	esac
}

load_config() {
	config_load bmcqos || return 1
	config_get_bool enabled global enabled 0
	config_get backend global backend fw3
	config_get WAN settings WAN wan
	config_get DOWNRATE settings DOWNRATE 0
	config_get UPRATE settings UPRATE 0
	config_get hook firewall hook FORWARD
	config_get_bool ipv6_enabled firewall ipv6_enabled 1
	prefix=BMCQOS
	config_get_bool advanced_enabled advanced enabled 0
	config_get_bool wash_up advanced WASHDSCPUP 1
	config_get_bool wash_down advanced WASHDSCPDOWN 1
	config_get MSS advanced MSS 536
	config_get UDPBULKPORT advanced UDPBULKPORT ''
	config_get TCPBULKPORT advanced TCPBULKPORT ''
	config_get VIDCONFPORTS advanced VIDCONFPORTS ''
	config_get REALTIME4 advanced REALTIME4 ''
	config_get REALTIME6 advanced REALTIME6 ''
	config_get LOWPRIOLAN4 advanced LOWPRIOLAN4 ''
	config_get LOWPRIOLAN6 advanced LOWPRIOLAN6 ''
	if [ "$advanced_enabled" != 1 ]; then
		wash_up=0
		wash_down=0
		MSS=''
		UDPBULKPORT=''
		TCPBULKPORT=''
		VIDCONFPORTS=''
		REALTIME4=''
		REALTIME6=''
		LOWPRIOLAN4=''
		LOWPRIOLAN6=''
	fi
	[ "$backend" = fw3 ] || { log "Unsupported backend: $backend"; return 1; }
	valid_name "$prefix" || { log "Invalid chain_prefix: $prefix"; return 1; }
	[ "$hook" = FORWARD ] || { log "fw3 backend currently supports only the FORWARD hook"; return 1; }
	CLASSIFY="${prefix}_CLASSIFY"
	CONNMARK="${prefix}_CONNMARK"
	PRE="${prefix}_PRE"
}

cleanup_family() {
	local cmd="$1" chain
	command -v "$cmd" >/dev/null 2>&1 || return 0
	while "$cmd" -t mangle -C "$hook" -j "$PRE" >/dev/null 2>&1; do
		"$cmd" -t mangle -D "$hook" -j "$PRE" >/dev/null 2>&1 || break
	done
	for chain in "$PRE" "$CLASSIFY" "$CONNMARK"; do
		"$cmd" -t mangle -F "$chain" >/dev/null 2>&1
		"$cmd" -t mangle -X "$chain" >/dev/null 2>&1
	done
}

cleanup_ipsets() {
	[ -f "$IPSET_NAMES" ] || return 0
	while IFS= read -r setname; do
		[ -n "$setname" ] && ipset destroy "$setname" >/dev/null 2>&1
	done < "$IPSET_NAMES"
	rm -f "$IPSET_NAMES"
}

cleanup() {
	load_config >/dev/null 2>&1 || return 0
	cleanup_family iptables
	cleanup_family ip6tables
	cleanup_ipsets
}

emit() { printf '%s\n' "$2" >> "$1"; }

port_match() {
	local which="$1" ports="$2" one many
	[ -n "$ports" ] || return 0
	valid_value "$ports" || return 1
	ports=$(echo "$ports" | tr '-' ':')
	[ "$which" = source ] && { one=--sport; many=--sports; } || { one=--dport; many=--dports; }
	case "$ports" in *,*) printf '%s' " -m multiport $many $ports" ;; *) printf '%s' " $one $ports" ;; esac
}

address_match() {
	local direction="$1" value="$2" family="$3" setname
	[ -n "$value" ] || return 0
	valid_value "$value" || return 1
	case "$value" in
		@*)
			setname="${prefix}_${value#@}_${family}"
			valid_name "$setname" || return 1
			printf '%s' " -m set --match-set $setname $direction"
			;;
		*) [ "$direction" = src ] && printf '%s' " -s $value" || printf '%s' " -d $value" ;;
	esac
}

emit_rule_one() {
	local file="$1" family="$2" proto="$3" src_ip="$4" dest_ip="$5" src_port="$6" dest_port="$7" class="$8"
	local cv dscp mark match=''
	cv=$(class_value "$class") || { log "Ignoring rule with invalid class '$class'"; return 0; }
	dscp=${cv%% *}; mark=${cv#* }
	case "$proto" in
		''|all) ;;
		tcp|udp|gre|esp|ah) match="$match -p $proto" ;;
		icmp) [ "$family" = 4 ] || return 0; match="$match -p icmp" ;;
		icmpv6|ipv6-icmp) [ "$family" = 6 ] || return 0; match="$match -p ipv6-icmp" ;;
		*) log "Ignoring unsupported protocol '$proto'"; return 0 ;;
	esac
	match="$match$(address_match src "$src_ip" "$family")" || return 0
	match="$match$(address_match dst "$dest_ip" "$family")" || return 0
	if [ "$proto" = tcp ] || [ "$proto" = udp ]; then
		match="$match$(port_match source "$src_port")" || return 0
		match="$match$(port_match destination "$dest_port")" || return 0
	elif [ -n "$src_port$dest_port" ]; then
		log "Ignoring ports on a rule without tcp/udp protocol"
		return 0
	fi
	emit "$file" "-A $CLASSIFY$match -j DSCP --set-dscp-class $dscp"
}

emit_rule() {
	local section="$1" rule_enabled proto src_ip dest_ip src_port dest_port class family
	config_get_bool rule_enabled "$section" enabled 1
	[ "$rule_enabled" = 1 ] || return 0
	config_get proto "$section" proto all
	config_get src_ip "$section" src_ip ''
	config_get dest_ip "$section" dest_ip ''
	config_get src_port "$section" src_port ''
	config_get dest_port "$section" dest_port ''
	config_get class "$section" class cs0
	config_get family "$section" family auto
	case "$family:$src_ip$dest_ip" in ipv6:*|auto:*:*)
		[ "$ipv6_enabled" = 1 ] && emit_rule_one "$V6_RULES" 6 "$proto" "$src_ip" "$dest_ip" "$src_port" "$dest_port" "$class"
		;;
		ipv4:*|auto:*@*) emit_rule_one "$V4_RULES" 4 "$proto" "$src_ip" "$dest_ip" "$src_port" "$dest_port" "$class" ;;
	*)
		emit_rule_one "$V4_RULES" 4 "$proto" "$src_ip" "$dest_ip" "$src_port" "$dest_port" "$class"
		[ "$ipv6_enabled" = 1 ] && { case "$src_ip$dest_ip" in *@*) emit_rule_one "$V6_RULES" 6 "$proto" "$src_ip" "$dest_ip" "$src_port" "$dest_port" "$class" ;; '') emit_rule_one "$V6_RULES" 6 "$proto" '' '' "$src_port" "$dest_port" "$class" ;; esac; }
		;;
	esac
}

add_ipset_entry() {
	local entry="$1" setname="$2"
	case "$entry" in *-*) log "Ignoring unsupported IP range '$entry'"; return 0 ;; esac
	valid_value "$entry" || { log "Ignoring invalid ipset entry '$entry'"; return 0; }
	ipset add "$setname" "$entry" -exist || return 1
}

create_ipset() {
	local section="$1" set_enabled name family setname suffix list
	config_get_bool set_enabled "$section" enabled 1
	[ "$set_enabled" = 1 ] || return 0
	config_get name "$section" name "$section"
	config_get family "$section" family ipv4
	valid_name "$name" || { log "Ignoring invalid ipset name '$name'"; return 0; }
	case "$family" in ipv4) family=inet; suffix=4; list=ip4 ;; ipv6) family=inet6; suffix=6; list=ip6 ;; *) log "Ignoring invalid ipset family '$family'"; return 0 ;; esac
	setname="${prefix}_${name}_${suffix}"
	ipset create "$setname" hash:net family "$family" -exist || return 1
	ipset flush "$setname" || return 1
	printf '%s\n' "$setname" >> "$IPSET_NAMES"
	config_list_foreach "$section" "$list" add_ipset_entry "$setname"
}

emit_builtin_ports() {
	local proto="$1" ports="$2" class="$3"
	[ -n "$ports" ] || return 0
	emit_rule_one "$V4_RULES" 4 "$proto" '' '' '' "$ports" "$class"
	[ "$ipv6_enabled" = 1 ] && emit_rule_one "$V6_RULES" 6 "$proto" '' '' '' "$ports" "$class"
}

emit_builtin_ips() {
	local family="$1" ips="$2" class="$3" ip file
	[ "$family" = 6 ] && file="$V6_RULES" || file="$V4_RULES"
	for ip in $ips; do emit_rule_one "$file" "$family" all "$ip" '' '' '' "$class"; done
}

init_restore_file() {
	local file="$1"
	: > "$file"
	emit "$file" '*mangle'
	emit "$file" ":$PRE - [0:0]"
	emit "$file" ":$CLASSIFY - [0:0]"
	emit "$file" ":$CONNMARK - [0:0]"
	[ "$wash_up" = 1 ] && emit "$file" "-A $CLASSIFY -j DSCP --set-dscp-class CS0"
}

finish_restore_file() {
	local file="$1" cv dscp mark safe_mss
	emit "$file" "-A $CONNMARK -j CONNMARK --set-xmark 0x80/0xff"
	for cv in 'CS0 0x80' 'CS1 0x88' 'CS2 0x90' 'CS4 0xa0' 'CS5 0xa8' 'CS6 0xb0' 'CS7 0xb8' 'AF11 0x8a' 'AF41 0xa2' 'AF42 0xa4' 'EF 0xae'; do
		dscp=${cv%% *}; mark=${cv#* }
		emit "$file" "-A $CONNMARK -m dscp --dscp-class $dscp -j CONNMARK --set-xmark $mark/0xff"
	done
	emit "$file" "-A $CLASSIFY -j $CONNMARK"
	[ "$wash_down" = 1 ] && emit "$file" "-A $PRE -i $WAN -j DSCP --set-dscp-class CS0"
	if [ "$advanced_enabled" = 1 ]; then
		case "$MSS" in ''|*[!0-9]*) safe_mss=536 ;; *) safe_mss="$MSS" ;; esac
		[ "$safe_mss" -lt 536 ] && safe_mss=536
		[ "$safe_mss" -gt 1500 ] && safe_mss=1500
		case "$UPRATE" in ''|*[!0-9]*) ;; *) [ "$UPRATE" -gt 0 ] && [ "$UPRATE" -lt 3000 ] && emit "$file" "-A $PRE -i $WAN -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $safe_mss" ;; esac
		case "$DOWNRATE" in ''|*[!0-9]*) ;; *) [ "$DOWNRATE" -gt 0 ] && [ "$DOWNRATE" -lt 3000 ] && emit "$file" "-A $PRE -o $WAN -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $safe_mss" ;; esac
	fi
	emit "$file" "-A $PRE -o $WAN -j $CLASSIFY"
	emit "$file" "-A $hook -j $PRE"
	emit "$file" 'COMMIT'
}

apply_family() {
	local restore="$1" file="$2"
	command -v "$restore" >/dev/null 2>&1 || return 1
	"$restore" --test --noflush < "$file" || return 1
	"$restore" --noflush < "$file"
}

apply() {
	load_config || return 1
	[ "$enabled" = 1 ] || { cleanup; return 0; }
	mkdir -p "$RUN_DIR" || return 1
	# Remove only the chains/ipsets owned by bmcqos before compiling a fresh set.
	cleanup_family iptables
	cleanup_family ip6tables
	cleanup_ipsets
	: > "$IPSET_NAMES"
	command -v ipset >/dev/null 2>&1 || { log 'ipset is required'; return 1; }
	config_foreach create_ipset ipset || { cleanup_ipsets; return 1; }
	init_restore_file "$V4_RULES"
	init_restore_file "$V6_RULES"
	emit_builtin_ports udp "$UDPBULKPORT" cs1
	emit_builtin_ports tcp "$TCPBULKPORT" cs1
	emit_builtin_ports udp "$VIDCONFPORTS" af42
	emit_builtin_ports tcp "$VIDCONFPORTS" af42
	emit_builtin_ips 4 "$REALTIME4" cs5
	emit_builtin_ips 6 "$REALTIME6" cs5
	emit_builtin_ips 4 "$LOWPRIOLAN4" cs1
	emit_builtin_ips 6 "$LOWPRIOLAN6" cs1
	config_foreach emit_rule rule
	finish_restore_file "$V4_RULES"
	finish_restore_file "$V6_RULES"
	iptables-restore --test --noflush < "$V4_RULES" || { log 'IPv4 rules failed validation'; return 1; }
	if [ "$ipv6_enabled" = 1 ]; then ip6tables-restore --test --noflush < "$V6_RULES" || { log 'IPv6 rules failed validation'; return 1; }; fi
	cleanup_family iptables
	cleanup_family ip6tables
	apply_family iptables-restore "$V4_RULES" || { log 'Failed to apply IPv4 rules'; return 1; }
	if [ "$ipv6_enabled" = 1 ]; then apply_family ip6tables-restore "$V6_RULES" || { cleanup_family iptables; log 'Failed to apply IPv6 rules'; return 1; }; fi
	log 'fw3 classification rules applied'
}

status() {
	load_config || return 1
	iptables -t mangle -S "$CLASSIFY" 2>/dev/null
	[ "$ipv6_enabled" = 1 ] && ip6tables -t mangle -S "$CLASSIFY" 2>/dev/null
}

case "$1" in apply|reload) apply ;; cleanup|stop) cleanup ;; status) status ;; *) echo "Usage: $0 {apply|cleanup|status}" >&2; exit 2 ;; esac
