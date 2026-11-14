#!/bin/sh

TUNTAP=$(basename $DEV)
UNDO_FILE=/var/run/chilli.$TUNTAP.sh

. /etc/chilli/functions

[ -e "$UNDO_FILE" ] && sh $UNDO_FILE 2>/dev/null
rm -f $UNDO_FILE 2>/dev/null

ipt() {
    opt=$1; shift
    echo "iptables -D $*" >> $UNDO_FILE
    iptables $opt $*
}

ipt_in() {
    ipt -I INPUT -i $TUNTAP $*
}

allow_bmc_management_input() {
    local dst
    local port
    local extra

    for dst in "$ADDR" "$(uci -q get network.lan.ipaddr 2>/dev/null)"; do
	[ -n "$dst" ] || continue
	for port in 80 443 3737 8081; do
	    ipt_in -p tcp -m tcp --dport "$port" --dst "$dst" -j ACCEPT
	done
    done

    for extra in $(uci -q show network 2>/dev/null | sed -n "s/^network\\.\\([^.=]*\\)\\.bmc_extra_lan='1'.*/\\1/p"); do
	dst="$(uci -q get network.$extra.ipaddr 2>/dev/null)"
	[ -n "$dst" ] || continue
	for port in 80 443 3737 8081; do
	    ipt_in -p tcp -m tcp --dport "$port" --dst "$dst" -j ACCEPT
	done
    done
}

disable_bmc_offload() {
    command -v ethtool >/dev/null 2>&1 || return 0

    for iface in "$HS_WANIF" "$DHCPIF" "$TUNTAP"; do
	[ -n "$iface" ] || continue
	[ -d "/sys/class/net/$iface" ] || continue
	ethtool -K "$iface" gro off gso off tso off rx on tx on 2>/dev/null || \
	    ethtool -K "$iface" gro off gso off tso off 2>/dev/null || true
    done
}

run_up() {
    # BMC NAC queue tuning: reduce packet drops under portal/client bursts.
    [ -n "$TUNTAP" ] && ip link set dev "$TUNTAP" txqueuelen 1000 2>/dev/null || true
    if [ -n "$TUNTAP" ]
    then
        # ifconfig $TUNTAP mtu $MTU
	if [ "$KNAME" != "" ]
	then
	    ipt -I FORWARD -i $DHCPIF -m coova --name $KNAME -j ACCEPT 
	    ipt -I FORWARD -o $DHCPIF -m coova --name $KNAME --dest -j ACCEPT
	    ipt -I FORWARD -i $TUNTAP -j ACCEPT
	    ipt -I FORWARD -o $TUNTAP -j ACCEPT
	    [ -n "$DHCPLISTEN" ] && ifconfig $DHCPIF $DHCPLISTEN
	else
	    if [ "$LAYER3" != "1" ]
	    then
		ipt_in --dst $ADDR -j DROP
		
		[ -n "$UAMPORT" -a "$UAMPORT" != "0" ] && \
		    ipt_in -p tcp -m tcp --dport $UAMPORT --dst $ADDR -j ACCEPT
		
		[ -n "$UAMUIPORT" -a "$UAMUIPORT" != "0" ] && \
		    ipt_in -p tcp -m tcp --dport $UAMUIPORT --dst $ADDR -j ACCEPT

		allow_bmc_management_input
		
		[ -n "$HS_TCP_PORTS" ] && {
		    for port in $HS_TCP_PORTS; do
			ipt_in -p tcp -m tcp --dport $port --dst $ADDR -j ACCEPT
		    done
		}

		[ -n "$HS_UDP_PORTS" ] && {
		    for port in $HS_UDP_PORTS; do
			ipt_in -p udp -m udp --dport $port --dst $ADDR -j ACCEPT
		    done
		}

		ipt_in -p udp -d 255.255.255.255 --destination-port 67:68 -j ACCEPT
		ipt_in -p udp -d $ADDR --destination-port 67:68 -j ACCEPT
		ipt_in -p udp --dst $ADDR --dport 53 -j ACCEPT
		ipt_in -p tcp --dst $ADDR --dport 53 -j ACCEPT
		ipt_in -p icmp --dst $ADDR -j ACCEPT
		
		# if [ "$ONLY8021Q" != "1" ]
		# then
		#     ipt -I INPUT -i $DHCPIF -j DROP
		# fi
	    fi
	    
	    if [ "$ONLY8021Q" != "1" ]
	    then
		ipt -I FORWARD -i $DHCPIF -j DROP
		ipt -I FORWARD -o $DHCPIF -j DROP
	    fi
	    
	    ipt -I FORWARD -i $TUNTAP -j ACCEPT
	    ipt -I FORWARD -o $TUNTAP -j ACCEPT
	    
            # Help out conntrack to not get confused
            # (stops masquerading from working)
            #ipt -I PREROUTING -t raw -j NOTRACK -i $DHCPIF
            #ipt -I OUTPUT -t raw -j NOTRACK -o $DHCPIF
	    
	    [ "$HS_LAN_ACCESS" != "on" -a "$HS_LAN_ACCESS" != "allow" ] && \
		ipt -I FORWARD -i $TUNTAP \! -o $HS_WANIF -j DROP
	    
	    ipt -I FORWARD -i $TUNTAP -o $HS_WANIF -j ACCEPT

            # Help out MTU issues with PPPoE, mesh, and CoovaChilli/GRO traffic.
            # These rules must be inserted after the ACCEPT/DROP rules above so
            # iptables -I leaves TCPMSS before the early ACCEPT path.
	    ipt -I FORWARD -i $TUNTAP -o $HS_WANIF -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
	    ipt -I FORWARD -t mangle -i $TUNTAP -o $HS_WANIF -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

	    CHILLI_NET=$(ip -4 addr show "$TUNTAP" 2>/dev/null | awk '/inet / {print $2; exit}')
	    [ -n "$CHILLI_NET" -a -n "$HS_WANIF" ] && \
		ipt -I POSTROUTING -t nat -s "$CHILLI_NET" -o $HS_WANIF -j MASQUERADE

	    disable_bmc_offload
	    
	    [ "$HS_LOCAL_DNS" = "on" ] && \
		ipt -I PREROUTING -t nat -i $TUNTAP -p udp --dport 53 -j DNAT --to-destination $ADDR
	fi
    fi

    # site specific stuff optional
    [ -e /etc/chilli/ipup.sh ] && . /etc/chilli/ipup.sh
}


FLOCK=$(which flock)
if [ -n "$FLOCK" ] && [ -z "$LOCKED_FILE" ]
then
    export LOCKED_FILE=/tmp/.chilli-flock
    flock -x $LOCKED_FILE -c "$0 $@"
else
    run_up
fi
