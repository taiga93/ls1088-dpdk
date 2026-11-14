#!/bin/sh
# ESP made by the Linux kernel, for the tests of the OpenSSL backend
# (tests/unit/esp_test.c): the SAs of the tests, with their keys, in two
# network namespaces joined by a veth pair; ping sends a packet of PC1
# (192.168.5.10) to 10.20.0.10, 100 bytes of data, through each, and
# tcpdump keeps the ESP that reaches the peer. Run as root on a board of
# the image (kernel 6.12, ip-full, tcpdump, veth); nothing outside the two
# namespaces changes. The pcaps of tests/esp/linux come from the LS1088.
#
#   sh linux-esp.sh DIR      one DIR/NAME.pcap per SA below
set -eu

out=${1:?usage: linux-esp.sh DIR}
mkdir -p "$out"
a=espgen-left
b=espgen-right

cleanup() {
	ip netns del $a 2>/dev/null || true
	ip netns del $b 2>/dev/null || true
}
trap cleanup EXIT
cleanup

ip netns add $a
ip netns add $b
ip link add va netns $a type veth peer name vb netns $b
ip -n $a addr add 192.168.2.10/24 dev va
ip -n $b addr add 192.168.2.1/24 dev vb
ip -n $a link set va up
ip -n $b link set vb up
ip -n $a link set lo up
ip -n $a addr add 192.168.5.10/32 dev lo
ip -n $a route add 10.20.0.0/24 via 192.168.2.1 src 192.168.5.10
# the peer's MAC first: the ESP of a packet that waits for it is not sent
sleep 1
ip netns exec $a ping -c 1 -W 2 192.168.2.1 >/dev/null

# hex of n bytes from b, b+1, ...
bytes() {
	i=0
	s=0x
	while [ $i -lt "$2" ]; do
		s=$s$(printf %02x $(($1 + i)))
		i=$((i + 1))
	done
	echo $s
}

# NAME, udp (ESP in UDP 4500) or esp, then the algorithm arguments of ip xfrm
sa() {
	name=$1 kind=$2
	shift 2
	encap=
	[ "$kind" = esp ] || encap="encap espinudp 4500 4500 0.0.0.0"
	ip -n $a xfrm state flush
	ip -n $a xfrm policy flush
	ip -n $a xfrm state add src 192.168.2.10 dst 192.168.2.1 proto esp spi 0xc0010001 \
		reqid 1 mode tunnel "$@" $encap
	ip -n $a xfrm policy add src 192.168.5.0/24 dst 10.20.0.0/24 dir out \
		tmpl src 192.168.2.10 dst 192.168.2.1 proto esp reqid 1 mode tunnel
	ip netns exec $b tcpdump -i vb -U -w "$out/$name.pcap" -c 1 "ip proto 50 or udp port 4500" \
		2>/dev/null &
	dump=$!
	sleep 1
	ip netns exec $a ping -c 1 -s 100 -I 192.168.5.10 10.20.0.10 >/dev/null 2>&1 || true
	sleep 1
	kill $dump 2>/dev/null || true
	wait $dump 2>/dev/null || true
	echo "$name: $(wc -c < "$out/$name.pcap") bytes"
}

sa cbc256-sha256-udp udp enc 'cbc(aes)' $(bytes 16 32) auth-trunc 'hmac(sha256)' $(bytes 64 32) 128
sa cbc128-sha1-esp esp enc 'cbc(aes)' $(bytes 16 16) auth-trunc 'hmac(sha1)' $(bytes 64 20) 96
sa cbc128-sha384-esp esp enc 'cbc(aes)' $(bytes 16 16) auth-trunc 'hmac(sha384)' $(bytes 64 48) 192
sa cbc256-sha512-udp udp enc 'cbc(aes)' $(bytes 16 32) auth-trunc 'hmac(sha512)' $(bytes 64 64) 256
sa gcm256-udp udp aead 'rfc4106(gcm(aes))' $(bytes 16 32)a1b2c3d4 128
sa gcm128-esp esp aead 'rfc4106(gcm(aes))' $(bytes 16 16)a1b2c3d4 128
