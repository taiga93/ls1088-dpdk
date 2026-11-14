/*
 * Seam 1: the per-packet core on the build machine. Each test builds packets
 * as they come off the cable or out of the kernel, runs them through
 * core_rx() and the control functions, and looks only at where the packets
 * go, what they look like then, and what the control functions answer.
 * Expected packets are built from scratch, with the checksums of DPDK's
 * rte_ipv4_cksum() and rte_ipv4_udptcp_cksum().
 *
 *   core_test EAL-ARGS [-- TEST...]
 */
#include <errno.h>
#include <stdlib.h>
#include <time.h>

#include <rte_eal.h>
#include <rte_ether.h>
#include <rte_launch.h>
#include <rte_ip.h>
#include <rte_mbuf.h>
#include <rte_tcp.h>
#include <rte_udp.h>

#include "../../src/core.h"
#include "testlib.h"

/*
 * The example of the spec: the WAN is port 0 (eth0), the LAN port 1 (eth1).
 * mbuf.port of the four sides.
 */
enum { WAN, LAN };
enum { WAN_WIRE = 10, WAN_KERNEL = 11, LAN_WIRE = 20, LAN_KERNEL = 21 };

#define MAC(x) ((struct rte_ether_addr){ { 0x02, 0, 0, 0, 0, (x) } })
#define HOST_MAC MAC(0x0a)	/* PC 192.168.5.10 on the LAN */
#define SRV_MAC MAC(0x14)	/* server 192.168.5.20 on the LAN */
#define RLAN_MAC MAC(0x01)	/* the router on the LAN */
#define RWAN_MAC MAC(0x02)	/* the router on the WAN */
#define GW_MAC MAC(0xfe)	/* the gateway of the ISP */
static const struct rte_ether_addr bcast_mac = { { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff } };
static const struct rte_ether_addr mcast_mac = { { 0x01, 0x00, 0x5e, 0x01, 0x01, 0x01 } };

#define HOST RTE_IPV4(192, 168, 5, 10)
#define SRV RTE_IPV4(192, 168, 5, 20)
#define RWAN RTE_IPV4(198, 51, 100, 2)
#define WEB RTE_IPV4(203, 0, 113, 5)
#define CLIENT RTE_IPV4(203, 0, 113, 9)

static struct rte_mempool *pool;

/* A frame to build; addresses and ports in host order. */
struct pkt {
	struct rte_ether_addr dst, src;
	uint16_t ethertype;
	uint32_t sip, dip;
	uint16_t sport, dport;
	uint8_t proto, ttl, tcp_flags, ihl;
	uint16_t frag;		/* the flags and offset word */
	uint16_t payload;	/* bytes after the L4 header */
	int udp_nocsum;		/* UDP checksum 0 */
	uint8_t seed;		/* of the payload bytes */
	const uint8_t *data;	/* the payload bytes, instead */
	uint16_t vlan;		/* an 802.1Q tag with this VLAN id */
	uint16_t pppoe;		/* a PPPoE session header with this session id */
	int ip6;		/* IPv6 instead of IPv4 (the ports, no checksums) */
};

#define TCP(...) ((struct pkt){ .ethertype = RTE_ETHER_TYPE_IPV4, .proto = IPPROTO_TCP,	\
	.ttl = 64, .ihl = 5, .tcp_flags = RTE_TCP_ACK_FLAG, .payload = 100, __VA_ARGS__ })
#define UDP(...) ((struct pkt){ .ethertype = RTE_ETHER_TYPE_IPV4, .proto = IPPROTO_UDP,	\
	.ttl = 64, .ihl = 5, .payload = 100, __VA_ARGS__ })

static struct rte_mbuf *
mk(struct pkt p, uint16_t port)
{
	struct rte_mbuf *m = rte_pktmbuf_alloc(pool);
	unsigned l4len = p.proto == IPPROTO_TCP ? sizeof(struct rte_tcp_hdr) :
			 p.proto == IPPROTO_UDP ? sizeof(struct rte_udp_hdr) : 8;
	unsigned optlen = (p.ihl - 5) * 4;
	unsigned l3len = p.ip6 ? sizeof(struct rte_ipv6_hdr) : sizeof(struct rte_ipv4_hdr) + optlen;
	unsigned iplen = l3len + l4len + p.payload;
	unsigned l2len = RTE_ETHER_HDR_LEN + (p.vlan ? 4 : 0) + (p.pppoe ? 8 : 0);
	struct rte_ether_hdr *eh;
	struct rte_ipv4_hdr *ip;
	uint8_t *l2, *l3, *l4, *data;
	uint16_t *type;
	unsigned i;

	if (!m)
		abort();
	l2 = (uint8_t *)rte_pktmbuf_append(m, l2len + iplen);
	if (!l2)
		abort();
	memset(l2, 0, l2len + iplen);
	eh = (struct rte_ether_hdr *)l2;
	eh->dst_addr = p.dst;
	eh->src_addr = p.src;
	type = &eh->ether_type;
	l3 = l2 + RTE_ETHER_HDR_LEN;
	if (p.vlan) {
		*type = rte_cpu_to_be_16(RTE_ETHER_TYPE_VLAN);
		*(uint16_t *)l3 = rte_cpu_to_be_16(p.vlan);
		type = (uint16_t *)(l3 + 2);
		l3 += 4;
	}
	if (p.pppoe) {
		*type = rte_cpu_to_be_16(RTE_ETHER_TYPE_PPPOE_SESSION);
		l3[0] = 0x11;	/* version 1, type 1; code 0: session data */
		*(uint16_t *)(l3 + 2) = rte_cpu_to_be_16(p.pppoe);
		*(uint16_t *)(l3 + 4) = rte_cpu_to_be_16(2 + iplen);
		*(uint16_t *)(l3 + 6) = rte_cpu_to_be_16(0x0021);	/* PPP: IPv4 */
		l3 += 8;
	} else {
		*type = rte_cpu_to_be_16(p.ip6 ? RTE_ETHER_TYPE_IPV6 : p.ethertype);
	}
	l4 = l3 + l3len;
	data = l4 + l4len;
	for (i = 0; i < p.payload; i++)
		data[i] = p.data ? p.data[i] : (uint8_t)(i * 7 + 1 + p.seed);
	ip = (struct rte_ipv4_hdr *)l3;
	if (p.ip6) {
		struct rte_ipv6_hdr *ip6 = (struct rte_ipv6_hdr *)l3;

		ip6->vtc_flow = rte_cpu_to_be_32(6u << 28);
		ip6->payload_len = rte_cpu_to_be_16(l4len + p.payload);
		ip6->proto = p.proto;
		ip6->hop_limits = p.ttl;
		ip6->src_addr[0] = ip6->dst_addr[0] = 0x20;
		ip6->src_addr[1] = ip6->dst_addr[1] = 0x01;
		memcpy(&ip6->src_addr[12], &(uint32_t){ rte_cpu_to_be_32(p.sip) }, 4);
		memcpy(&ip6->dst_addr[12], &(uint32_t){ rte_cpu_to_be_32(p.dip) }, 4);
	} else {
		ip->version_ihl = 0x40 | p.ihl;
		ip->total_length = rte_cpu_to_be_16(iplen);
		ip->packet_id = rte_cpu_to_be_16(0x1234);
		ip->fragment_offset = rte_cpu_to_be_16(p.frag);
		ip->time_to_live = p.ttl;
		ip->next_proto_id = p.proto;
		ip->src_addr = rte_cpu_to_be_32(p.sip);
		ip->dst_addr = rte_cpu_to_be_32(p.dip);
		for (i = 0; i < optlen; i++)
			((uint8_t *)(ip + 1))[i] = 1;	/* NOP options */
	}
	if (p.proto == IPPROTO_TCP) {
		struct rte_tcp_hdr *th = (struct rte_tcp_hdr *)l4;

		th->src_port = rte_cpu_to_be_16(p.sport);
		th->dst_port = rte_cpu_to_be_16(p.dport);
		th->sent_seq = rte_cpu_to_be_32(1000);
		th->recv_ack = rte_cpu_to_be_32(2000);
		th->data_off = 5 << 4;
		th->tcp_flags = p.tcp_flags;
		th->rx_win = rte_cpu_to_be_16(64240);
		if (!p.ip6)
			th->cksum = rte_ipv4_udptcp_cksum(ip, th);
	} else if (p.proto == IPPROTO_UDP) {
		struct rte_udp_hdr *uh = (struct rte_udp_hdr *)l4;

		uh->src_port = rte_cpu_to_be_16(p.sport);
		uh->dst_port = rte_cpu_to_be_16(p.dport);
		uh->dgram_len = rte_cpu_to_be_16(l4len + p.payload);
		uh->dgram_cksum = p.udp_nocsum || p.ip6 ? 0 : rte_ipv4_udptcp_cksum(ip, uh);
	}
	if (!p.ip6)
		ip->hdr_checksum = rte_ipv4_cksum(ip);
	m->port = port;
	return m;
}

/* Where core_rx() sent one packet. */
struct dest {
	int port, side;		/* -1 when it went nowhere */
	struct rte_mbuf *m;
};

static struct dest
go(struct core *c, struct rte_mbuf *m, uint32_t now)
{
	struct core_out out;
	struct dest d = { -1, -1, NULL };
	int p, s;

	core_rx(c, 0, &m, 1, now, &out);
	for (p = 0; p < CORE_MAX_PORTS; p++)
		for (s = 0; s < 2; s++)
			if (out.n[p][s]) {
				d.port = p;
				d.side = s;
				d.m = out.pkts[p][s][0];
			}
	return d;
}

static int
same(const struct rte_mbuf *a, const struct rte_mbuf *b)
{
	return a && b && a->pkt_len == b->pkt_len &&
	       !memcmp(rte_pktmbuf_mtod(a, void *), rte_pktmbuf_mtod(b, void *), a->pkt_len);
}

static struct core *
mkcore_with(unsigned max_conns, unsigned learn_max, unsigned learn_ttl)
{
	struct core_params p = {
		.nports = 2, .mtu = { 1500, 1500 }, .nworkers = 1, .max_conns = max_conns,
		.learn_max = learn_max, .learn_ttl = learn_ttl, .socket_id = SOCKET_ID_ANY,
	};
	struct core *c = core_create(&p);

	if (!c)
		abort();
	core_map_ethdev(c, WAN_WIRE, WAN, CORE_WIRE);
	core_map_ethdev(c, WAN_KERNEL, WAN, CORE_KERNEL);
	core_map_ethdev(c, LAN_WIRE, LAN, CORE_WIRE);
	core_map_ethdev(c, LAN_KERNEL, LAN, CORE_KERNEL);
	return c;
}

static struct core *
mkcore(void)
{
	return mkcore_with(1024, 1024, 10000);
}

TEST(packet_of_no_connection_goes_up_to_the_kernel_of_its_port_unchanged)
{
	struct core *c = mkcore();
	struct pkt p = TCP(.dst = RLAN_MAC, .src = HOST_MAC, .sip = HOST, .dip = WEB,
			   .sport = 40000, .dport = 443);
	struct rte_mbuf *want = mk(p, LAN_WIRE);
	struct dest d = go(c, mk(p, LAN_WIRE), 1000);

	CHECK(d.port == LAN && d.side == CORE_KERNEL);
	CHECK(same(d.m, want));
	core_free(c);
}

TEST(packet_the_kernel_sends_goes_out_of_the_cable_of_the_same_port_unchanged)
{
	struct core *c = mkcore();
	struct pkt p = TCP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = WEB,
			   .sport = 40000, .dport = 443, .ttl = 63);
	struct rte_mbuf *want = mk(p, WAN_KERNEL);
	struct dest d = go(c, mk(p, WAN_KERNEL), 1000);

	CHECK(d.port == WAN && d.side == CORE_WIRE);
	CHECK(same(d.m, want));
	core_free(c);
}

/* A tuple of core_bind(), from host-order addresses and ports. */
static struct core_tuple
tup(uint32_t sip, uint16_t sport, uint32_t dip, uint16_t dport)
{
	return (struct core_tuple){ rte_cpu_to_be_32(sip), rte_cpu_to_be_32(dip),
				    rte_cpu_to_be_16(sport), rte_cpu_to_be_16(dport) };
}

/*
 * The connection of the spec's example: the PC 192.168.5.10 on eth1 opens
 * 203.0.113.5:443 through eth0, masqueraded as 198.51.100.2, as conntrack
 * gives it.
 */
static const struct core_tuple *
masq_orig(void)
{
	static struct core_tuple t;

	t = tup(HOST, 40000, WEB, 443);
	return &t;
}

static const struct core_tuple *
masq_reply(void)
{
	static struct core_tuple t;

	t = tup(WEB, 443, RWAN, 40000);
	return &t;
}

TEST(bind_of_a_connection_nothing_was_learned_of_is_refused_with_all_four_missing)
{
	struct core *c = mkcore();
	unsigned missing = 0;

	CHECK(core_bind(c, IPPROTO_TCP, masq_orig(), masq_reply(), 1000, &missing) == -ENOENT);
	CHECK(missing == (CORE_MISS_ORIG_IN | CORE_MISS_ORIG_OUT | CORE_MISS_REPLY_IN |
			  CORE_MISS_REPLY_OUT));
	CHECK(core_count(c) == 0);
	core_free(c);
}

/* Runs a packet through the core and frees what comes out. */
static void
pass(struct core *c, struct pkt p, uint16_t port, uint32_t now)
{
	struct dest d = go(c, mk(p, port), now);

	rte_pktmbuf_free(d.m);
}

/*
 * The handshake of the masqueraded connection as the engine sees it while
 * the kernel handles it: the SYN of the PC from the LAN cable, the SYN the
 * kernel sends out of eth0 after NAT, the SYN-ACK of the server from the
 * WAN cable, the SYN-ACK the kernel sends back out of eth1.
 */
static void
masq_handshake_but(struct core *c, uint32_t now, unsigned skip)
{
	if (skip != 0)
		pass(c, TCP(.dst = RLAN_MAC, .src = HOST_MAC, .sip = HOST, .dip = WEB,
			    .sport = 40000, .dport = 443, .tcp_flags = RTE_TCP_SYN_FLAG,
			    .payload = 0), LAN_WIRE, now);
	if (skip != 1)
		pass(c, TCP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = WEB,
			    .sport = 40000, .dport = 443, .ttl = 63, .tcp_flags = RTE_TCP_SYN_FLAG,
			    .payload = 0), WAN_KERNEL, now);
	if (skip != 2)
		pass(c, TCP(.dst = RWAN_MAC, .src = GW_MAC, .sip = WEB, .dip = RWAN,
			    .sport = 443, .dport = 40000, .ttl = 50,
			    .tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG, .payload = 0),
		     WAN_WIRE, now);
	if (skip != 3)
		pass(c, TCP(.dst = HOST_MAC, .src = RLAN_MAC, .sip = WEB, .dip = HOST,
			    .sport = 443, .dport = 40000, .ttl = 49,
			    .tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG, .payload = 0),
		     LAN_KERNEL, now);
}

static void
masq_handshake(struct core *c, uint32_t now)
{
	masq_handshake_but(c, now, 4);
}

TEST(data_of_a_masqueraded_connection_goes_out_of_the_wan_cable_as_the_kernel_would_send_it)
{
	struct core *c = mkcore();
	unsigned missing = 0;
	struct rte_mbuf *want;
	struct dest d;

	masq_handshake(c, 1000);
	CHECK(core_bind(c, IPPROTO_TCP, masq_orig(), masq_reply(), 1001, &missing) == 0);
	CHECK(core_count(c) == 1);
	d = go(c, mk(TCP(.dst = RLAN_MAC, .src = HOST_MAC, .sip = HOST, .dip = WEB, .sport = 40000,
			 .dport = 443, .payload = 1000), LAN_WIRE), 1002);
	want = mk(TCP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = WEB, .sport = 40000,
		      .dport = 443, .ttl = 63, .payload = 1000), LAN_WIRE);
	CHECK(d.port == WAN && d.side == CORE_WIRE);
	CHECK(same(d.m, want));
	core_free(c);
}

/* A core with the masqueraded connection accelerated. */
static struct core *
masq_core(void)
{
	struct core *c = mkcore();
	unsigned missing;

	masq_handshake(c, 1000);
	if (core_bind(c, IPPROTO_TCP, masq_orig(), masq_reply(), 1001, &missing))
		abort();
	return c;
}

/* A data packet of the masqueraded connection from the PC, as it comes in. */
#define MASQ_OUT(...) TCP(.dst = RLAN_MAC, .src = HOST_MAC, .sip = HOST, .dip = WEB,	\
	.sport = 40000, .dport = 443, __VA_ARGS__)
/* ... and one of the server. */
#define MASQ_BACK(...) TCP(.dst = RWAN_MAC, .src = GW_MAC, .sip = WEB, .dip = RWAN,	\
	.sport = 443, .dport = 40000, .ttl = 50, __VA_ARGS__)

TEST(data_of_the_server_goes_out_of_the_lan_cable_to_the_pc_as_the_kernel_would_send_it)
{
	struct core *c = masq_core();
	struct dest d = go(c, mk(MASQ_BACK(.payload = 1400), WAN_WIRE), 1002);
	struct rte_mbuf *want = mk(TCP(.dst = HOST_MAC, .src = RLAN_MAC, .sip = WEB, .dip = HOST,
				       .sport = 443, .dport = 40000, .ttl = 49, .payload = 1400),
				   WAN_WIRE);

	CHECK(d.port == LAN && d.side == CORE_WIRE);
	CHECK(same(d.m, want));
	core_free(c);
}

/*
 * Port forwarding: the client 203.0.113.9 on the Internet opens
 * 198.51.100.2:8080, which the router forwards to the server
 * 192.168.5.20:80 on the LAN.
 */
TEST(a_forwarded_port_is_accelerated_both_ways)
{
	struct core *c = mkcore();
	struct core_tuple o = tup(CLIENT, 5555, RWAN, 8080), r = tup(SRV, 80, CLIENT, 5555);
	unsigned missing;
	struct dest d;

	pass(c, TCP(.dst = RWAN_MAC, .src = GW_MAC, .sip = CLIENT, .dip = RWAN, .sport = 5555,
		    .dport = 8080, .tcp_flags = RTE_TCP_SYN_FLAG, .payload = 0), WAN_WIRE, 1000);
	pass(c, TCP(.dst = SRV_MAC, .src = RLAN_MAC, .sip = CLIENT, .dip = SRV, .sport = 5555,
		    .dport = 80, .ttl = 63, .tcp_flags = RTE_TCP_SYN_FLAG, .payload = 0),
	     LAN_KERNEL, 1000);
	pass(c, TCP(.dst = RLAN_MAC, .src = SRV_MAC, .sip = SRV, .dip = CLIENT, .sport = 80,
		    .dport = 5555, .tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG, .payload = 0),
	     LAN_WIRE, 1000);
	pass(c, TCP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = CLIENT, .sport = 8080,
		    .dport = 5555, .ttl = 63, .tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG,
		    .payload = 0), WAN_KERNEL, 1000);
	CHECK(core_bind(c, IPPROTO_TCP, &o, &r, 1001, &missing) == 0);

	d = go(c, mk(TCP(.dst = RWAN_MAC, .src = GW_MAC, .sip = CLIENT, .dip = RWAN, .sport = 5555,
			 .dport = 8080, .payload = 300), WAN_WIRE), 1002);
	CHECK(d.port == LAN && d.side == CORE_WIRE);
	CHECK(same(d.m, mk(TCP(.dst = SRV_MAC, .src = RLAN_MAC, .sip = CLIENT, .dip = SRV,
			       .sport = 5555, .dport = 80, .ttl = 63, .payload = 300), 0)));
	d = go(c, mk(TCP(.dst = RLAN_MAC, .src = SRV_MAC, .sip = SRV, .dip = CLIENT, .sport = 80,
			 .dport = 5555, .payload = 1200), LAN_WIRE), 1003);
	CHECK(d.port == WAN && d.side == CORE_WIRE);
	CHECK(same(d.m, mk(TCP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = CLIENT,
			       .sport = 8080, .dport = 5555, .ttl = 63, .payload = 1200), 0)));
	core_free(c);
}

/* A UDP flow of the PC to a DNS server through the masquerade, accelerated. */
static struct core *
udp_core(void)
{
	struct core *c = mkcore();
	struct core_tuple o = tup(HOST, 50000, WEB, 53), r = tup(WEB, 53, RWAN, 50000);
	unsigned missing;

	/* UDP has no handshake: the first packet each way is learned */
	pass(c, UDP(.dst = RLAN_MAC, .src = HOST_MAC, .sip = HOST, .dip = WEB, .sport = 50000,
		    .dport = 53), LAN_WIRE, 1000);
	pass(c, UDP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = WEB, .sport = 50000,
		    .dport = 53, .ttl = 63), WAN_KERNEL, 1000);
	pass(c, UDP(.dst = RWAN_MAC, .src = GW_MAC, .sip = WEB, .dip = RWAN, .sport = 53,
		    .dport = 50000), WAN_WIRE, 1000);
	pass(c, UDP(.dst = HOST_MAC, .src = RLAN_MAC, .sip = WEB, .dip = HOST, .sport = 53,
		    .dport = 50000, .ttl = 63), LAN_KERNEL, 1000);
	if (core_bind(c, IPPROTO_UDP, &o, &r, 1001, &missing))
		abort();
	return c;
}

TEST(udp_is_accelerated_both_ways)
{
	struct core *c = udp_core();
	struct dest d;

	d = go(c, mk(UDP(.dst = RLAN_MAC, .src = HOST_MAC, .sip = HOST, .dip = WEB, .sport = 50000,
			 .dport = 53, .payload = 77), LAN_WIRE), 1002);
	CHECK(d.port == WAN && d.side == CORE_WIRE);
	CHECK(same(d.m, mk(UDP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = WEB,
			       .sport = 50000, .dport = 53, .ttl = 63, .payload = 77), 0)));
	d = go(c, mk(UDP(.dst = RWAN_MAC, .src = GW_MAC, .sip = WEB, .dip = RWAN, .sport = 53,
			 .dport = 50000, .payload = 513), WAN_WIRE), 1003);
	CHECK(d.port == LAN && d.side == CORE_WIRE);
	CHECK(same(d.m, mk(UDP(.dst = HOST_MAC, .src = RLAN_MAC, .sip = WEB, .dip = HOST,
			       .sport = 53, .dport = 50000, .ttl = 63, .payload = 513), 0)));
	core_free(c);
}

TEST(udp_without_a_checksum_keeps_none)
{
	struct core *c = udp_core();
	struct dest d = go(c, mk(UDP(.dst = RLAN_MAC, .src = HOST_MAC, .sip = HOST, .dip = WEB,
				     .sport = 50000, .dport = 53, .udp_nocsum = 1), LAN_WIRE), 1002);

	CHECK(d.port == WAN && d.side == CORE_WIRE);
	CHECK(same(d.m, mk(UDP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = WEB,
			       .sport = 50000, .dport = 53, .ttl = 63, .udp_nocsum = 1), 0)));
	core_free(c);
}

/* The packet came out of the kernel side of the port it came in on, as it came in. */
static int
goes_up_unchanged(struct core *c, struct pkt p, uint16_t ethdev, unsigned port)
{
	struct rte_mbuf *want = mk(p, ethdev);
	struct dest d = go(c, mk(p, ethdev), 1002);
	int ok = d.port == (int)port && d.side == CORE_KERNEL && same(d.m, want);

	rte_pktmbuf_free(want);
	rte_pktmbuf_free(d.m);
	return ok;
}

/* The packet was forwarded out of the cable of port. */
static int
forwarded(struct core *c, struct pkt p, uint16_t ethdev, unsigned port)
{
	struct dest d = go(c, mk(p, ethdev), 1002);
	int ok = d.port == (int)port && d.side == CORE_WIRE;

	rte_pktmbuf_free(d.m);
	return ok;
}

TEST(tcp_syn_fin_and_rst_of_an_accelerated_connection_go_up_to_the_kernel)
{
	struct core *c = masq_core();

	CHECK(goes_up_unchanged(c, MASQ_OUT(.tcp_flags = RTE_TCP_SYN_FLAG), LAN_WIRE, LAN));
	CHECK(goes_up_unchanged(c, MASQ_OUT(.tcp_flags = RTE_TCP_FIN_FLAG | RTE_TCP_ACK_FLAG),
				LAN_WIRE, LAN));
	CHECK(goes_up_unchanged(c, MASQ_BACK(.tcp_flags = RTE_TCP_RST_FLAG), WAN_WIRE, WAN));
	CHECK(forwarded(c, MASQ_OUT(.tcp_flags = RTE_TCP_PSH_FLAG | RTE_TCP_ACK_FLAG), LAN_WIRE, WAN));
	core_free(c);
}

TEST(fragments_and_packets_with_ip_options_go_up_to_the_kernel)
{
	struct core *c = masq_core();

	CHECK(goes_up_unchanged(c, MASQ_OUT(.frag = RTE_IPV4_HDR_MF_FLAG), LAN_WIRE, LAN));
	CHECK(goes_up_unchanged(c, MASQ_OUT(.frag = 185), LAN_WIRE, LAN));
	CHECK(goes_up_unchanged(c, MASQ_OUT(.ihl = 6), LAN_WIRE, LAN));
	CHECK(forwarded(c, MASQ_OUT(.frag = RTE_IPV4_HDR_DF_FLAG), LAN_WIRE, WAN));
	core_free(c);
}

TEST(packets_with_a_ttl_of_one_or_less_go_up_to_the_kernel)
{
	struct core *c = masq_core();
	struct dest d;

	CHECK(goes_up_unchanged(c, MASQ_OUT(.ttl = 1), LAN_WIRE, LAN));
	CHECK(goes_up_unchanged(c, MASQ_OUT(.ttl = 0), LAN_WIRE, LAN));
	d = go(c, mk(MASQ_OUT(.ttl = 2), LAN_WIRE), 1002);
	CHECK(d.port == WAN && d.side == CORE_WIRE);
	CHECK(same(d.m, mk(TCP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = WEB,
			       .sport = 40000, .dport = 443, .ttl = 1), 0)));
	core_free(c);
}

TEST(packets_bigger_than_the_mtu_of_the_port_out_go_up_to_the_kernel)
{
	struct core *c = masq_core();

	/* 20 + 20 + 1460 = 1500, the MTU of eth0 */
	CHECK(forwarded(c, MASQ_OUT(.payload = 1460), LAN_WIRE, WAN));
	CHECK(goes_up_unchanged(c, MASQ_OUT(.payload = 1461), LAN_WIRE, LAN));
	core_free(c);
}

TEST(what_is_not_ipv4_unicast_tcp_or_udp_goes_up_to_the_kernel)
{
	struct core *c = masq_core();
	struct core_tuple o = tup(HOST, 5000, RTE_IPV4(239, 1, 1, 1), 5000);
	struct core_tuple r = tup(RTE_IPV4(239, 1, 1, 1), 5000, RWAN, 5000);
	unsigned missing = 0;

	CHECK(goes_up_unchanged(c, MASQ_OUT(.ethertype = RTE_ETHER_TYPE_ARP), LAN_WIRE, LAN));
	CHECK(goes_up_unchanged(c, MASQ_OUT(.proto = IPPROTO_ICMP), LAN_WIRE, LAN));
	CHECK(goes_up_unchanged(c, MASQ_OUT(.dst = bcast_mac), LAN_WIRE, LAN));
	CHECK(goes_up_unchanged(c, MASQ_OUT(.dst = mcast_mac), LAN_WIRE, LAN));
	/* a multicast or broadcast flow is never learned, so never accelerated */
	pass(c, UDP(.dst = mcast_mac, .src = HOST_MAC, .sip = HOST, .dip = RTE_IPV4(239, 1, 1, 1), .sport = 5000,
		    .dport = 5000), LAN_WIRE, 1000);
	pass(c, UDP(.dst = RLAN_MAC, .src = HOST_MAC, .sip = HOST, .dip = RTE_IPV4(239, 1, 1, 1),
		    .sport = 5000, .dport = 5000), LAN_WIRE, 1000);
	pass(c, UDP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = RTE_IPV4(239, 1, 1, 1),
		    .sport = 5000, .dport = 5000, .ttl = 63), WAN_KERNEL, 1000);
	CHECK(core_bind(c, IPPROTO_UDP, &o, &r, 1001, &missing) == -ENOENT);
	CHECK((missing & (CORE_MISS_ORIG_IN | CORE_MISS_ORIG_OUT)) ==
	      (CORE_MISS_ORIG_IN | CORE_MISS_ORIG_OUT));
	o = tup(HOST, 5000, RTE_IPV4(255, 255, 255, 255), 5000);
	pass(c, UDP(.dst = RLAN_MAC, .src = HOST_MAC, .sip = HOST,
		    .dip = RTE_IPV4(255, 255, 255, 255), .sport = 5000, .dport = 5000),
	     LAN_WIRE, 1000);
	CHECK(core_bind(c, IPPROTO_UDP, &o, &r, 1001, &missing) == -ENOENT);
	CHECK(missing & CORE_MISS_ORIG_IN);
	core_free(c);
}

TEST(ipv6_goes_up_to_the_kernel)
{
	struct core *c = masq_core();

	CHECK(goes_up_unchanged(c, MASQ_OUT(.ip6 = 1), LAN_WIRE, LAN));
	CHECK(goes_up_unchanged(c, MASQ_BACK(.ip6 = 1, .proto = IPPROTO_UDP), WAN_WIRE, WAN));
	core_free(c);
}

/* The packet m came out of the kernel side of port as it came in. */
static int
up_unchanged(struct core *c, struct rte_mbuf *m, unsigned port)
{
	struct rte_mbuf *want = rte_pktmbuf_copy(m, pool, 0, UINT32_MAX);
	struct dest d = go(c, m, 1002);
	int ok = d.port == (int)port && d.side == CORE_KERNEL && same(d.m, want);

	rte_pktmbuf_free(want);
	rte_pktmbuf_free(d.m);
	return ok;
}

/* Writes the 16-bit word v at offset off of the frame, in network order. */
static struct rte_mbuf *
poke16(struct rte_mbuf *m, unsigned off, uint16_t v)
{
	*rte_pktmbuf_mtod_offset(m, uint16_t *, off) = rte_cpu_to_be_16(v);
	return m;
}

/* Offsets in a frame with a PPPoE header straight after Ethernet. */
#define PPPOE_VER_CODE 14
#define PPPOE_SESSION 16
#define PPPOE_LENGTH 18
#define PPP_PROTOCOL 20

/*
 * The tuple of a connection on a VLAN or in a PPPoE session is another
 * connection: the masqueraded one is on neither.
 */
TEST(the_packets_of_a_connection_on_a_vlan_or_in_pppoe_it_is_not_on_go_up_to_the_kernel)
{
	struct core *c = masq_core();

	CHECK(goes_up_unchanged(c, MASQ_OUT(.vlan = 30), LAN_WIRE, LAN));
	CHECK(goes_up_unchanged(c, MASQ_BACK(.pppoe = 0x1234), WAN_WIRE, WAN));
	CHECK(goes_up_unchanged(c, MASQ_BACK(.vlan = 35, .pppoe = 0x1234), WAN_WIRE, WAN));
	/* VLAN 0, a priority tag, and session 0 would have the key of no tag, no session */
	CHECK(goes_up_unchanged(c, MASQ_OUT(.vlan = 0xa000), LAN_WIRE, LAN));
	CHECK(up_unchanged(c, poke16(mk(MASQ_BACK(.pppoe = 0x1234), WAN_WIRE), PPPOE_SESSION, 0),
			   WAN));
	CHECK(forwarded(c, MASQ_OUT(), LAN_WIRE, WAN));
	core_free(c);
}

TEST(packets_the_hardware_found_broken_go_up_to_the_kernel)
{
	struct core *c = masq_core();
	uint64_t bad[] = { RTE_MBUF_F_RX_IP_CKSUM_BAD, RTE_MBUF_F_RX_L4_CKSUM_BAD };
	unsigned i;

	for (i = 0; i < RTE_DIM(bad); i++) {
		struct rte_mbuf *m = mk(MASQ_OUT(), LAN_WIRE);
		struct dest d;

		m->ol_flags = bad[i];
		d = go(c, m, 1002);
		CHECK(d.port == LAN && d.side == CORE_KERNEL);
		CHECK(same(d.m, mk(MASQ_OUT(), 0)));
	}
	core_free(c);
}

TEST(truncated_and_chained_packets_go_up_to_the_kernel)
{
	struct core *c = masq_core();
	struct rte_mbuf *m = mk(MASQ_OUT(.payload = 100), LAN_WIRE), *want, *tail;
	struct dest d;

	/* the IP length says 140 bytes, the frame has 130 of them */
	rte_pktmbuf_trim(m, 10);
	want = rte_pktmbuf_copy(m, pool, 0, UINT32_MAX);
	d = go(c, m, 1002);
	CHECK(d.port == LAN && d.side == CORE_KERNEL);
	CHECK(same(d.m, want));

	m = mk(MASQ_OUT(.payload = 100), LAN_WIRE);
	tail = rte_pktmbuf_alloc(pool);
	memset(rte_pktmbuf_append(tail, 10), 0, 10);
	CHECK(rte_pktmbuf_chain(m, tail) == 0);
	want = mk(MASQ_OUT(.payload = 100), 0);
	d = go(c, m, 1002);
	CHECK(d.port == LAN && d.side == CORE_KERNEL);
	CHECK(!memcmp(rte_pktmbuf_mtod(d.m, void *), rte_pktmbuf_mtod(want, void *), want->pkt_len));
	core_free(c);
}

static uint64_t rnd = 0x9e3779b97f4a7c15ULL;

static uint32_t
xrand(void)
{
	rnd ^= rnd << 13;
	rnd ^= rnd >> 7;
	rnd ^= rnd << 17;
	return (uint32_t)(rnd >> 16);
}

/* Learns and binds one connection, as masq_handshake() does, of any NAT. */
static int
learn_and_bind(struct core *c, uint8_t proto, struct pkt orig, struct pkt nat_out,
	       struct pkt reply, struct pkt nat_back)
{
	struct core_tuple o = tup(orig.sip, orig.sport, orig.dip, orig.dport);
	struct core_tuple r = tup(reply.sip, reply.sport, reply.dip, reply.dport);
	unsigned missing;

	pass(c, orig, LAN_WIRE, 1000);
	pass(c, nat_out, WAN_KERNEL, 1000);
	pass(c, reply, WAN_WIRE, 1000);
	pass(c, nat_back, LAN_KERNEL, 1000);
	return core_bind(c, proto, &o, &r, 1001, &missing);
}

/*
 * The checksums of the packet, after an L2 header of l2len bytes, are what
 * computing them again gives.
 */
static int
checksums_right_at(struct rte_mbuf *m, unsigned l2len)
{
	struct rte_ipv4_hdr *ip = rte_pktmbuf_mtod_offset(m, struct rte_ipv4_hdr *, l2len);
	uint16_t got = ip->hdr_checksum, l4got;
	uint16_t *l4c = ip->next_proto_id == IPPROTO_TCP ?
			&((struct rte_tcp_hdr *)(ip + 1))->cksum :
			&((struct rte_udp_hdr *)(ip + 1))->dgram_cksum;
	int ok;

	ip->hdr_checksum = 0;
	ok = rte_ipv4_cksum(ip) == got;
	ip->hdr_checksum = got;
	l4got = *l4c;
	if (ip->next_proto_id == IPPROTO_UDP && l4got == 0)
		return ok;
	*l4c = 0;
	ok &= rte_ipv4_udptcp_cksum(ip, ip + 1) == l4got;
	*l4c = l4got;
	return ok;
}

static int
checksums_right(struct rte_mbuf *m)
{
	return checksums_right_at(m, RTE_ETHER_HDR_LEN);
}

TEST(incremental_checksums_are_what_computing_them_again_gives)
{
	struct core *c = mkcore_with(4096, 16384, 10000);
	unsigned i, nocsum = 0, bad = 0, n = 2000;

	for (i = 0; i < n; i++) {
		uint8_t proto = xrand() & 1 ? IPPROTO_UDP : IPPROTO_TCP;
		uint32_t host = RTE_IPV4(10, 0, 0, 0) + (xrand() & 0xffffff);
		uint32_t far = RTE_IPV4(1, 0, 0, 0) + xrand() % (RTE_IPV4(223, 0, 0, 0));
		uint32_t nat = RTE_IPV4(100, 64, 0, 0) + (xrand() & 0x3fffff);
		uint16_t hport = (uint16_t)(1 + xrand() % 65535), fport = (uint16_t)(1 + xrand() % 65535);
		uint16_t nport = (uint16_t)(1 + xrand() % 65535);
		uint8_t ttl = (uint8_t)(2 + xrand() % 254);
		uint16_t len = (uint16_t)(xrand() % 1401);
		int zero = proto == IPPROTO_UDP && xrand() % 8 == 0;
		/* a VLAN on the LAN, PPPoE on the WAN, and a VLAN under it, some of the time */
		uint16_t lan_vlan = xrand() % 3 ? 0 : (uint16_t)(1 + xrand() % 4094);
		uint16_t wan_pppoe = xrand() % 2 ? 0 : (uint16_t)(1 + xrand() % 0xffff);
		uint16_t wan_vlan = xrand() % 3 ? 0 : (uint16_t)(1 + xrand() % 4094);
		unsigned l2out;
		struct pkt base = { .ethertype = RTE_ETHER_TYPE_IPV4, .proto = proto, .ihl = 5,
				    .ttl = 64, .tcp_flags = RTE_TCP_ACK_FLAG };
		struct pkt orig = base, nat_out = base, reply = base, nat_back = base, data;
		struct rte_mbuf *m;
		struct dest d;
		struct rte_ipv4_hdr *ip;
		uint8_t *l4;

		if (proto == IPPROTO_TCP)
			orig.tcp_flags = nat_out.tcp_flags = reply.tcp_flags = nat_back.tcp_flags =
				RTE_TCP_SYN_FLAG;
		orig.dst = RLAN_MAC, orig.src = HOST_MAC;
		orig.sip = host, orig.sport = hport, orig.dip = far, orig.dport = fport;
		nat_out.dst = GW_MAC, nat_out.src = RWAN_MAC;
		nat_out.sip = nat, nat_out.sport = nport, nat_out.dip = far, nat_out.dport = fport;
		reply.dst = RWAN_MAC, reply.src = GW_MAC;
		reply.sip = far, reply.sport = fport, reply.dip = nat, reply.dport = nport;
		nat_back.dst = HOST_MAC, nat_back.src = RLAN_MAC;
		nat_back.sip = far, nat_back.sport = fport, nat_back.dip = host, nat_back.dport = hport;
		orig.vlan = nat_back.vlan = lan_vlan;
		nat_out.vlan = reply.vlan = wan_vlan;
		nat_out.pppoe = reply.pppoe = wan_pppoe;
		if (learn_and_bind(c, proto, orig, nat_out, reply, nat_back) == -EEXIST)
			continue;	/* the same tuple drawn twice */

		data = xrand() & 1 ? orig : reply;
		data.tcp_flags = RTE_TCP_ACK_FLAG | RTE_TCP_PSH_FLAG;
		data.ttl = ttl;
		data.payload = len;
		data.seed = (uint8_t)xrand();
		data.udp_nocsum = zero;
		m = mk(data, data.sip == host ? LAN_WIRE : WAN_WIRE);
		d = go(c, m, 1002);
		if (d.side != CORE_WIRE) {
			bad++;
			rte_pktmbuf_free(d.m);
			continue;
		}
		l2out = data.sip == host ?
			RTE_ETHER_HDR_LEN + (wan_vlan ? 4 : 0) + (wan_pppoe ? 8 : 0) :
			RTE_ETHER_HDR_LEN + (lan_vlan ? 4 : 0);
		ip = rte_pktmbuf_mtod_offset(d.m, struct rte_ipv4_hdr *, l2out);
		l4 = (uint8_t *)(ip + 1);
		if (d.m->pkt_len != l2out + rte_be_to_cpu_16(ip->total_length) ||
		    !checksums_right_at(d.m, l2out) || ip->time_to_live != ttl - 1 ||
		    (zero && ((struct rte_udp_hdr *)l4)->dgram_cksum != 0) ||
		    ip->src_addr != rte_cpu_to_be_32(data.sip == host ? nat : far) ||
		    ip->dst_addr != rte_cpu_to_be_32(data.sip == host ? far : host))
			bad++;
		nocsum += zero;
		rte_pktmbuf_free(d.m);
	}
	CHECK(bad == 0);
	CHECK(nocsum > 50);
	CHECK(core_count(c) > n - 10);
	core_free(c);
}

/* RFC 768: a UDP checksum that computes to 0 is sent as 0xffff. */
TEST(a_udp_checksum_that_comes_to_zero_is_sent_as_ffff)
{
	struct core *c = udp_core();
	uint8_t payload[100];
	struct pkt want = UDP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = WEB,
			      .sport = 50000, .dport = 53, .ttl = 63, .data = payload);
	struct rte_mbuf *m;
	struct rte_udp_hdr *uh;
	uint16_t c0;
	struct dest d;
	unsigned i;

	/* the last word of the payload makes the sum after NAT 0xffff */
	for (i = 0; i < sizeof(payload); i++)
		payload[i] = (uint8_t)(i * 13 + 5);
	payload[98] = payload[99] = 0;
	m = mk(want, 0);
	uh = rte_pktmbuf_mtod_offset(m, struct rte_udp_hdr *,
				     RTE_ETHER_HDR_LEN + sizeof(struct rte_ipv4_hdr));
	c0 = uh->dgram_cksum;
	memcpy(&payload[98], &c0, 2);
	rte_pktmbuf_free(m);
	m = mk(want, 0);
	uh = rte_pktmbuf_mtod_offset(m, struct rte_udp_hdr *,
				     RTE_ETHER_HDR_LEN + sizeof(struct rte_ipv4_hdr));
	CHECK(uh->dgram_cksum == 0xffff);

	d = go(c, mk(UDP(.dst = RLAN_MAC, .src = HOST_MAC, .sip = HOST, .dip = WEB, .sport = 50000,
			 .dport = 53, .data = payload), LAN_WIRE), 1002);
	CHECK(d.port == WAN && d.side == CORE_WIRE);
	CHECK(same(d.m, m));
	core_free(c);
}

/*
 * VLAN and PPPoE (ticket 10). The LAN of the PC is the VLAN interface
 * eth1.30, the WAN the PPPoE session 0x1234, straight on eth0 or on its
 * VLAN 35 as some ISPs have it. A field at 0 is not there.
 */
struct l2 {
	uint16_t lan_vlan, wan_vlan, wan_pppoe;
};

/* The packets of the masqueraded connection the kernel sends out, after NAT. */
#define NAT_OUT(...) TCP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = WEB,	\
	.sport = 40000, .dport = 443, .ttl = 63, __VA_ARGS__)
#define NAT_BACK(...) TCP(.dst = HOST_MAC, .src = RLAN_MAC, .sip = WEB, .dip = HOST,	\
	.sport = 443, .dport = 40000, .ttl = 49, __VA_ARGS__)

/* The handshake of the masqueraded connection with its ends on l, then its bind. */
static int
masq_bind_on(struct core *c, struct l2 l, uint32_t now)
{
	unsigned missing;

	pass(c, MASQ_OUT(.tcp_flags = RTE_TCP_SYN_FLAG, .payload = 0, .vlan = l.lan_vlan),
	     LAN_WIRE, now);
	pass(c, NAT_OUT(.tcp_flags = RTE_TCP_SYN_FLAG, .payload = 0, .vlan = l.wan_vlan,
			.pppoe = l.wan_pppoe), WAN_KERNEL, now);
	pass(c, MASQ_BACK(.tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG, .payload = 0,
			  .vlan = l.wan_vlan, .pppoe = l.wan_pppoe), WAN_WIRE, now);
	pass(c, NAT_BACK(.tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG, .payload = 0,
			 .vlan = l.lan_vlan), LAN_KERNEL, now);
	return core_bind(c, IPPROTO_TCP, masq_orig(), masq_reply(), now + 1, &missing);
}

static struct core *
masq_core_on(struct l2 l)
{
	struct core *c = mkcore();

	if (masq_bind_on(c, l, 1000))
		abort();
	return c;
}

TEST(vlan_and_pppoe_are_accelerated_both_ways_with_the_header_the_kernel_sends)
{
	static const struct l2 ways[] = {
		{ .lan_vlan = 30 },				/* VLAN to a plain WAN */
		{ .wan_pppoe = 0x1234 },			/* a plain LAN to PPPoE */
		{ .lan_vlan = 30, .wan_pppoe = 0x1234 },	/* VLAN to PPPoE */
		{ .lan_vlan = 30, .wan_vlan = 35, .wan_pppoe = 0x1234 },	/* PPPoE on a VLAN */
		{ .lan_vlan = 4094, .wan_vlan = 1 },
	};
	static const uint16_t sizes[] = { 1000, 1, 0 };
	unsigned i, j;

	for (i = 0; i < RTE_DIM(ways); i++) {
		struct l2 l = ways[i];
		struct core *c = masq_core_on(l);
		unsigned wan_l2 = RTE_ETHER_HDR_LEN + (l.wan_vlan ? 4 : 0) + (l.wan_pppoe ? 8 : 0);
		unsigned lan_l2 = RTE_ETHER_HDR_LEN + (l.lan_vlan ? 4 : 0);

		for (j = 0; j < RTE_DIM(sizes); j++) {
			struct dest d = go(c, mk(MASQ_OUT(.payload = sizes[j], .vlan = l.lan_vlan),
						 LAN_WIRE), 1002);

			CHECK(d.port == WAN && d.side == CORE_WIRE);
			CHECK(same(d.m, mk(NAT_OUT(.payload = sizes[j], .vlan = l.wan_vlan,
						   .pppoe = l.wan_pppoe), 0)));
			CHECK(checksums_right_at(d.m, wan_l2));
			rte_pktmbuf_free(d.m);
			d = go(c, mk(MASQ_BACK(.payload = sizes[j], .vlan = l.wan_vlan,
					       .pppoe = l.wan_pppoe), WAN_WIRE), 1003);
			CHECK(d.port == LAN && d.side == CORE_WIRE);
			CHECK(same(d.m, mk(NAT_BACK(.payload = sizes[j], .vlan = l.lan_vlan), 0)));
			CHECK(checksums_right_at(d.m, lan_l2));
			rte_pktmbuf_free(d.m);
		}
		core_free(c);
	}
}

/* The priority bits of a tag are not part of the VLAN: they go out as the kernel set them. */
TEST(a_tag_of_the_vlan_with_other_priority_bits_is_the_same_vlan)
{
	struct core *c = masq_core_on((struct l2){ .lan_vlan = 30 });
	struct dest d = go(c, mk(MASQ_OUT(.payload = 10, .vlan = 0xa000 | 30), LAN_WIRE), 1002);

	CHECK(d.port == WAN && d.side == CORE_WIRE);
	CHECK(same(d.m, mk(NAT_OUT(.payload = 10), 0)));
	core_free(c);
}

/* A second tag in front of the first. */
static struct rte_mbuf *
push_vlan(struct rte_mbuf *m, uint16_t tci)
{
	uint8_t *f = (uint8_t *)rte_pktmbuf_prepend(m, 4);

	memmove(f, f + 4, 2 * RTE_ETHER_ADDR_LEN);
	*(uint16_t *)(f + 12) = rte_cpu_to_be_16(RTE_ETHER_TYPE_VLAN);
	*(uint16_t *)(f + 14) = rte_cpu_to_be_16(tci);
	return m;
}

/*
 * Of the VLAN and PPPoE frames, only one 802.1Q tag, then IPv4 or a PPPoE
 * session header that carries all of an IPv4 packet, are forwarded.
 */
TEST(other_vlans_other_sessions_and_other_pppoe_go_up_to_the_kernel)
{
	struct core *c = masq_core_on((struct l2){ .lan_vlan = 30, .wan_pppoe = 0x1234 });

	CHECK(goes_up_unchanged(c, MASQ_OUT(), LAN_WIRE, LAN));
	CHECK(goes_up_unchanged(c, MASQ_OUT(.vlan = 31), LAN_WIRE, LAN));
	/* 802.1ad, two 802.1Q tags, something else after the tag */
	CHECK(up_unchanged(c, poke16(mk(MASQ_OUT(.vlan = 30), LAN_WIRE), 12, RTE_ETHER_TYPE_QINQ),
			   LAN));
	CHECK(up_unchanged(c, push_vlan(mk(MASQ_OUT(.vlan = 40), LAN_WIRE), 30), LAN));
	CHECK(goes_up_unchanged(c, MASQ_OUT(.vlan = 30, .ethertype = RTE_ETHER_TYPE_ARP), LAN_WIRE,
				LAN));
	CHECK(goes_up_unchanged(c, MASQ_BACK(), WAN_WIRE, WAN));
	CHECK(goes_up_unchanged(c, MASQ_BACK(.pppoe = 0x1235), WAN_WIRE, WAN));
	/* PPPoE version 1 type 2; a code other than session data */
	CHECK(up_unchanged(c, poke16(mk(MASQ_BACK(.pppoe = 0x1234), WAN_WIRE), PPPOE_VER_CODE,
				     0x1200), WAN));
	CHECK(up_unchanged(c, poke16(mk(MASQ_BACK(.pppoe = 0x1234), WAN_WIRE), PPPOE_VER_CODE,
				     0x1165), WAN));
	/* LCP, IPv6 */
	CHECK(up_unchanged(c, poke16(mk(MASQ_BACK(.pppoe = 0x1234), WAN_WIRE), PPP_PROTOCOL,
				     0xc021), WAN));
	CHECK(up_unchanged(c, poke16(mk(MASQ_BACK(.pppoe = 0x1234), WAN_WIRE), PPP_PROTOCOL,
				     0x0057), WAN));
	/* a PPPoE length that is not that of the IPv4 packet and PPP's 2 bytes: 140 + 2 */
	CHECK(up_unchanged(c, poke16(mk(MASQ_BACK(.pppoe = 0x1234), WAN_WIRE), PPPOE_LENGTH, 143),
			   WAN));
	CHECK(up_unchanged(c, poke16(mk(MASQ_BACK(.pppoe = 0x1234), WAN_WIRE), PPPOE_LENGTH, 141),
			   WAN));
	/* and what is right */
	CHECK(forwarded(c, MASQ_BACK(.pppoe = 0x1234), WAN_WIRE, LAN));
	CHECK(forwarded(c, MASQ_OUT(.vlan = 30), LAN_WIRE, WAN));
	core_free(c);
}

/*
 * VLAN 4095, which 802.1Q reserves, is the core's own mark of a packet
 * decrypted out of a tunnel (Tunnel IPsec): no frame from a cable has it.
 */
TEST(a_frame_of_vlan_4095_is_never_accelerated)
{
	struct core *c = mkcore();

	CHECK(masq_bind_on(c, (struct l2){ .lan_vlan = 4095 }, 1000) == -ENOENT);
	CHECK(goes_up_unchanged(c, MASQ_OUT(.vlan = 4095), LAN_WIRE, LAN));
	core_free(c);
}

/*
 * The MTU of a port counts what follows the Ethernet header and its VLAN
 * tag: the IPv4 packet, and the 8 bytes of PPPoE and PPP before it.
 */
TEST(the_largest_packet_out_leaves_room_for_the_pppoe_header)
{
	struct core *c = masq_core_on((struct l2){ .lan_vlan = 30, .wan_pppoe = 0x1234 });

	/* 20 + 20 + 1452 = 1492, the MTU of pppoe-wan */
	CHECK(forwarded(c, MASQ_OUT(.payload = 1452, .vlan = 30), LAN_WIRE, WAN));
	CHECK(goes_up_unchanged(c, MASQ_OUT(.payload = 1453, .vlan = 30), LAN_WIRE, LAN));
	CHECK(forwarded(c, MASQ_BACK(.payload = 1452, .pppoe = 0x1234), WAN_WIRE, LAN));
	core_free(c);

	c = masq_core_on((struct l2){ .wan_vlan = 35, .wan_pppoe = 0x1234 });
	CHECK(forwarded(c, MASQ_OUT(.payload = 1452), LAN_WIRE, WAN));
	CHECK(goes_up_unchanged(c, MASQ_OUT(.payload = 1453), LAN_WIRE, LAN));
	core_free(c);

	/* a VLAN tag is not in the MTU of eth1.30 */
	c = masq_core_on((struct l2){ .lan_vlan = 30 });
	CHECK(forwarded(c, MASQ_OUT(.payload = 1460, .vlan = 30), LAN_WIRE, WAN));
	CHECK(goes_up_unchanged(c, MASQ_OUT(.payload = 1461, .vlan = 30), LAN_WIRE, LAN));
	CHECK(forwarded(c, MASQ_BACK(.payload = 1460), WAN_WIRE, LAN));
	CHECK(goes_up_unchanged(c, MASQ_BACK(.payload = 1461), WAN_WIRE, WAN));
	core_free(c);
}

/* m with only room bytes in front of its frame. */
static struct rte_mbuf *
headroom(struct rte_mbuf *m, uint16_t room)
{
	memmove((uint8_t *)m->buf_addr + room, rte_pktmbuf_mtod(m, void *), m->data_len);
	m->data_off = room;
	return m;
}

/* A header that grows needs room in front of the frame; without it, the kernel sends it. */
TEST(a_packet_with_no_room_for_a_longer_header_goes_up_to_the_kernel)
{
	struct core *c = masq_core_on((struct l2){ .lan_vlan = 30, .wan_pppoe = 0x1234 });
	struct dest d;

	/* 18 bytes in, 22 out */
	CHECK(up_unchanged(c, headroom(mk(MASQ_OUT(.vlan = 30), LAN_WIRE), 3), LAN));
	d = go(c, headroom(mk(MASQ_OUT(.vlan = 30), LAN_WIRE), 4), 1002);
	CHECK(d.port == WAN && d.side == CORE_WIRE);
	CHECK(same(d.m, mk(NAT_OUT(.pppoe = 0x1234), 0)));
	/* one that gets shorter needs none */
	d = go(c, headroom(mk(MASQ_BACK(.pppoe = 0x1234), WAN_WIRE), 0), 1002);
	CHECK(d.port == LAN && d.side == CORE_WIRE);
	CHECK(same(d.m, mk(NAT_BACK(.vlan = 30), 0)));
	core_free(c);
}

/* The padding of a short frame does not follow it into a header of another length. */
TEST(a_padded_frame_whose_header_changes_goes_out_with_its_ip_packet_only)
{
	struct core *c = masq_core_on((struct l2){ .wan_pppoe = 0x1234 });
	struct rte_mbuf *m = mk(MASQ_OUT(.payload = 0), LAN_WIRE);
	struct dest d;

	/* 14 + 40 = 54 bytes, padded to 60 */
	memset(rte_pktmbuf_append(m, 6), 0, 6);
	d = go(c, m, 1002);
	CHECK(d.port == WAN && d.side == CORE_WIRE);
	CHECK(same(d.m, mk(NAT_OUT(.payload = 0, .pppoe = 0x1234), 0)));
	core_free(c);
}

/*
 * PPPoE dials again: pppoe-wan goes away, so the daemon flushes the engine
 * (watch.c). The next connections, even of the same tuples, are learned in
 * the new session and accelerated in it; what still comes in the old one
 * goes up to the kernel.
 */
TEST(after_pppoe_dials_again_connections_are_accelerated_in_the_new_session)
{
	struct core *c = masq_core_on((struct l2){ .lan_vlan = 30, .wan_pppoe = 0x1234 });
	struct dest d;

	CHECK(core_flush(c, 2000) == 1);
	CHECK(masq_bind_on(c, (struct l2){ .lan_vlan = 30, .wan_pppoe = 0x2345 }, 3000) == 0);
	d = go(c, mk(MASQ_OUT(.payload = 100, .vlan = 30), LAN_WIRE), 3002);
	CHECK(d.port == WAN && d.side == CORE_WIRE);
	CHECK(same(d.m, mk(NAT_OUT(.payload = 100, .pppoe = 0x2345), 0)));
	CHECK(goes_up_unchanged(c, MASQ_BACK(.pppoe = 0x1234), WAN_WIRE, WAN));
	CHECK(forwarded(c, MASQ_BACK(.pppoe = 0x2345), WAN_WIRE, LAN));
	core_free(c);
}

/* The MAC address a connection is sent to is the first of its header, VLAN and PPPoE or not. */
TEST(a_neighbour_change_finds_the_connections_sent_through_a_vlan_or_pppoe)
{
	struct l2 l = { .lan_vlan = 30, .wan_vlan = 35, .wan_pppoe = 0x1234 };
	struct core *c = masq_core_on(l);

	CHECK(core_flush_mac(c, GW_MAC.addr_bytes, 1002, NULL, NULL) == 1);
	core_free(c);
	c = masq_core_on(l);
	CHECK(core_flush_mac(c, HOST_MAC.addr_bytes, 1002, NULL, NULL) == 1);
	core_free(c);
}

TEST(bind_says_which_of_the_four_learned_records_it_did_not_have)
{
	/* the packet left out of the handshake, and what is then missing */
	static const unsigned miss[4] = {
		CORE_MISS_ORIG_IN, CORE_MISS_ORIG_OUT, CORE_MISS_REPLY_IN, CORE_MISS_REPLY_OUT,
	};
	unsigned skip;

	for (skip = 0; skip < 4; skip++) {
		struct core *c = mkcore();
		unsigned missing = 0;

		masq_handshake_but(c, 1000, skip);
		CHECK(core_bind(c, IPPROTO_TCP, masq_orig(), masq_reply(), 1001, &missing) ==
		      -ENOENT);
		CHECK(missing == miss[skip]);
		CHECK(goes_up_unchanged(c, MASQ_OUT(), LAN_WIRE, LAN));
		core_free(c);
	}
}

/*
 * A PC on a 1G port (eth3) the kernel keeps: only the WAN half of its
 * connection passes the engine, the SYN the kernel sends out of eth0 and
 * the SYN-ACK of the server.
 */
TEST(a_connection_from_a_1g_port_is_never_accelerated)
{
	struct core *c = mkcore();
	unsigned missing = 0;

	pass(c, TCP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = WEB, .sport = 40000,
		    .dport = 443, .ttl = 63, .tcp_flags = RTE_TCP_SYN_FLAG, .payload = 0),
	     WAN_KERNEL, 1000);
	pass(c, TCP(.dst = RWAN_MAC, .src = GW_MAC, .sip = WEB, .dip = RWAN, .sport = 443,
		    .dport = 40000, .ttl = 50, .tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG,
		    .payload = 0), WAN_WIRE, 1000);
	CHECK(core_bind(c, IPPROTO_TCP, masq_orig(), masq_reply(), 1001, &missing) == -ENOENT);
	CHECK(missing == (CORE_MISS_ORIG_IN | CORE_MISS_REPLY_OUT));
	CHECK(goes_up_unchanged(c, MASQ_BACK(), WAN_WIRE, WAN));
	CHECK(core_count(c) == 0);
	core_free(c);
}

TEST(learned_records_are_usable_for_their_time_to_live_only)
{
	struct core *c = mkcore_with(1024, 1024, 10000);
	unsigned missing = 0;

	masq_handshake(c, 1000);
	CHECK(core_bind(c, IPPROTO_TCP, masq_orig(), masq_reply(), 11001, &missing) == -ENOENT);
	CHECK(missing == (CORE_MISS_ORIG_IN | CORE_MISS_ORIG_OUT | CORE_MISS_REPLY_IN |
			  CORE_MISS_REPLY_OUT));
	core_free(c);

	c = mkcore_with(1024, 1024, 10000);
	masq_handshake(c, 1000);
	CHECK(core_bind(c, IPPROTO_TCP, masq_orig(), masq_reply(), 11000, &missing) == 0);
	core_free(c);

	/* learning the same again starts the time to live again */
	c = mkcore_with(1024, 1024, 10000);
	masq_handshake(c, 1000);
	masq_handshake(c, 9000);
	CHECK(core_bind(c, IPPROTO_TCP, masq_orig(), masq_reply(), 15000, &missing) == 0);
	core_free(c);

	/* across the wrap of the clock */
	c = mkcore_with(1024, 1024, 10000);
	masq_handshake(c, 0xfffff000);
	CHECK(core_bind(c, IPPROTO_TCP, masq_orig(), masq_reply(), 0x100, &missing) == 0);
	core_free(c);
}

/* The handshake of the masqueraded connection of PC port hport. */
static void
handshake_of(struct core *c, uint16_t hport, uint32_t now)
{
	struct pkt a = TCP(.dst = RLAN_MAC, .src = HOST_MAC, .sip = HOST, .dip = WEB, .sport = hport,
			   .dport = 443, .tcp_flags = RTE_TCP_SYN_FLAG, .payload = 0);
	struct pkt b = a, r, d;

	b.dst = GW_MAC, b.src = RWAN_MAC, b.sip = RWAN;
	r = TCP(.dst = RWAN_MAC, .src = GW_MAC, .sip = WEB, .dip = RWAN, .sport = 443,
		.dport = hport, .tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG, .payload = 0);
	d = r;
	d.dst = HOST_MAC, d.src = RLAN_MAC, d.dip = HOST;
	pass(c, a, LAN_WIRE, now);
	pass(c, b, WAN_KERNEL, now);
	pass(c, r, WAN_WIRE, now);
	pass(c, d, LAN_KERNEL, now);
}

static int
bind_of(struct core *c, uint16_t hport, uint32_t now)
{
	struct core_tuple o = tup(HOST, hport, WEB, 443), r = tup(WEB, 443, RWAN, hport);
	unsigned missing;

	return core_bind(c, IPPROTO_TCP, &o, &r, now, &missing);
}

TEST(the_oldest_learned_records_go_when_there_are_too_many)
{
	/* room for the records of two connections */
	struct core *c = mkcore_with(1024, 8, 10000);

	handshake_of(c, 40001, 1000);
	handshake_of(c, 40002, 1001);
	handshake_of(c, 40003, 1002);
	CHECK(bind_of(c, 40001, 1003) == -ENOENT);
	CHECK(bind_of(c, 40002, 1003) == 0);
	CHECK(bind_of(c, 40003, 1003) == 0);
	core_free(c);

	/* learning again makes a record the newest */
	c = mkcore_with(1024, 8, 10000);
	handshake_of(c, 40001, 1000);
	handshake_of(c, 40002, 1001);
	handshake_of(c, 40001, 1002);
	handshake_of(c, 40003, 1003);
	CHECK(bind_of(c, 40001, 1004) == 0);
	CHECK(bind_of(c, 40002, 1004) == -ENOENT);
	core_free(c);
}

TEST(a_connection_bound_twice_is_refused_the_second_time)
{
	struct core *c = masq_core();
	unsigned missing;

	CHECK(core_bind(c, IPPROTO_TCP, masq_orig(), masq_reply(), 1002, &missing) == -EEXIST);
	CHECK(core_count(c) == 1);
	core_free(c);
}

TEST(bind_is_refused_when_the_table_is_full)
{
	struct core *c = mkcore_with(2, 1024, 10000);

	handshake_of(c, 40001, 1000);
	handshake_of(c, 40002, 1000);
	handshake_of(c, 40003, 1000);
	CHECK(bind_of(c, 40001, 1001) == 0);
	CHECK(bind_of(c, 40002, 1001) == 0);
	CHECK(bind_of(c, 40003, 1001) == -ENOSPC);
	CHECK(core_count(c) == 2);
	core_free(c);
}

TEST(bind_of_anything_but_tcp_or_udp_is_refused)
{
	struct core *c = mkcore();
	unsigned missing;

	masq_handshake(c, 1000);
	CHECK(core_bind(c, IPPROTO_ICMP, masq_orig(), masq_reply(), 1001, &missing) == -EINVAL);
	core_free(c);
}

TEST(each_direction_counts_its_packets_bytes_and_the_time_of_the_last)
{
	struct core *c = masq_core();
	struct core_conn cn;

	pass(c, MASQ_OUT(.payload = 100), LAN_WIRE, 2000);	/* 154 bytes */
	pass(c, MASQ_OUT(.payload = 200), LAN_WIRE, 2500);	/* 254 */
	pass(c, MASQ_BACK(.payload = 1000), WAN_WIRE, 3000);	/* 1054 */
	/* not forwarded, not counted */
	pass(c, MASQ_OUT(.tcp_flags = RTE_TCP_FIN_FLAG), LAN_WIRE, 4000);
	CHECK(core_conn_get(c, IPPROTO_TCP, masq_orig(), &cn) == 0);
	CHECK(cn.proto == IPPROTO_TCP);
	CHECK(!memcmp(&cn.orig, masq_orig(), sizeof(cn.orig)));
	CHECK(!memcmp(&cn.reply, masq_reply(), sizeof(cn.reply)));
	CHECK(cn.in[0] == LAN && cn.out[0] == WAN && cn.in[1] == WAN && cn.out[1] == LAN);
	CHECK(cn.pkts[0] == 2 && cn.bytes[0] == 154 + 254 && cn.last[0] == 2500);
	CHECK(cn.pkts[1] == 1 && cn.bytes[1] == 1054 && cn.last[1] == 3000);
	CHECK(core_conn_get(c, IPPROTO_UDP, masq_orig(), &cn) == -ENOENT);
	core_free(c);
}

TEST(an_unbound_connection_goes_through_the_kernel_and_is_learned_again)
{
	struct core *c = masq_core();
	unsigned missing = 0;

	CHECK(core_unbind(c, IPPROTO_TCP, masq_orig(), 1002) == 0);
	CHECK(core_count(c) == 0);
	CHECK(goes_up_unchanged(c, MASQ_OUT(), LAN_WIRE, LAN));
	CHECK(goes_up_unchanged(c, MASQ_BACK(), WAN_WIRE, WAN));
	CHECK(core_unbind(c, IPPROTO_TCP, masq_orig(), 1002) == -ENOENT);
	/*
	 * What was learned before is gone, since the way out may have changed:
	 * the two packets that went up since are learned again, the way the
	 * kernel sends them out is not yet.
	 */
	CHECK(core_bind(c, IPPROTO_TCP, masq_orig(), masq_reply(), 1003, &missing) == -ENOENT);
	CHECK(missing == (CORE_MISS_ORIG_OUT | CORE_MISS_REPLY_OUT));
	masq_handshake(c, 1004);
	CHECK(core_bind(c, IPPROTO_TCP, masq_orig(), masq_reply(), 1005, &missing) == 0);
	CHECK(forwarded(c, MASQ_OUT(), LAN_WIRE, WAN));
	core_free(c);
}

/* What a flush said it let go of: the source ports of the original direction. */
struct flushed {
	unsigned n;
	uint16_t sport[8];
};

static void
note_flushed(const struct core_conn *cn, void *arg)
{
	struct flushed *f = arg;

	if (f->n < RTE_DIM(f->sport))
		f->sport[f->n] = rte_be_to_cpu_16(cn->orig.sport);
	f->n++;
}

TEST(flush_unbinds_every_connection)
{
	struct core *c = mkcore();

	handshake_of(c, 40001, 1000);
	handshake_of(c, 40002, 1000);
	handshake_of(c, 40003, 1000);
	CHECK(bind_of(c, 40001, 1001) == 0);
	CHECK(bind_of(c, 40002, 1001) == 0);
	CHECK(bind_of(c, 40003, 1001) == 0);
	CHECK(core_flush(c, 1002) == 3);
	CHECK(core_count(c) == 0);
	CHECK(goes_up_unchanged(c, MASQ_OUT(.sport = 40002), LAN_WIRE, LAN));
	CHECK(bind_of(c, 40002, 1003) == -ENOENT);
	CHECK(core_flush(c, 1003) == 0);
	core_free(c);
}

/* A third port, a second WAN (eth2 for the test). */
enum { WAN2 = 2 };
enum { WAN2_WIRE = 30, WAN2_KERNEL = 31 };
#define RWAN2 RTE_IPV4(192, 0, 2, 2)
#define RWAN2_MAC MAC(0x03)
#define GW2_MAC MAC(0xfd)

static struct core *
three_port_core(void)
{
	struct core_params p = {
		.nports = 3, .mtu = { 1500, 1500, 1500 }, .nworkers = 1, .max_conns = 1024,
		.learn_max = 1024, .learn_ttl = 10000, .socket_id = SOCKET_ID_ANY,
	};
	struct core *c = core_create(&p);

	if (!c)
		abort();
	core_map_ethdev(c, WAN_WIRE, WAN, CORE_WIRE);
	core_map_ethdev(c, WAN_KERNEL, WAN, CORE_KERNEL);
	core_map_ethdev(c, LAN_WIRE, LAN, CORE_WIRE);
	core_map_ethdev(c, LAN_KERNEL, LAN, CORE_KERNEL);
	core_map_ethdev(c, WAN2_WIRE, WAN2, CORE_WIRE);
	core_map_ethdev(c, WAN2_KERNEL, WAN2, CORE_KERNEL);
	return c;
}

TEST(flush_of_a_port_unbinds_the_connections_through_it_only)
{
	struct core *c = three_port_core();
	struct core_tuple o2 = tup(HOST, 40002, WEB, 443), r2 = tup(WEB, 443, RWAN2, 40002);
	struct flushed fl = { 0 };
	unsigned missing = 0;

	/* 40001 leaves through eth0, 40002 through the second WAN */
	handshake_of(c, 40001, 1000);
	pass(c, TCP(.dst = RLAN_MAC, .src = HOST_MAC, .sip = HOST, .dip = WEB, .sport = 40002,
		    .dport = 443, .tcp_flags = RTE_TCP_SYN_FLAG, .payload = 0), LAN_WIRE, 1000);
	pass(c, TCP(.dst = GW2_MAC, .src = RWAN2_MAC, .sip = RWAN2, .dip = WEB, .sport = 40002,
		    .dport = 443, .tcp_flags = RTE_TCP_SYN_FLAG, .payload = 0), WAN2_KERNEL, 1000);
	pass(c, TCP(.dst = RWAN2_MAC, .src = GW2_MAC, .sip = WEB, .dip = RWAN2, .sport = 443,
		    .dport = 40002, .tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG, .payload = 0),
	     WAN2_WIRE, 1000);
	pass(c, TCP(.dst = HOST_MAC, .src = RLAN_MAC, .sip = WEB, .dip = HOST, .sport = 443,
		    .dport = 40002, .tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG, .payload = 0),
	     LAN_KERNEL, 1000);
	CHECK(bind_of(c, 40001, 1001) == 0);
	CHECK(core_bind(c, IPPROTO_TCP, &o2, &r2, 1001, &missing) == 0);
	CHECK(forwarded(c, MASQ_OUT(.sport = 40002), LAN_WIRE, WAN2));

	CHECK(core_flush_port(c, WAN2, 1002, note_flushed, &fl) == 1);
	CHECK(fl.n == 1 && fl.sport[0] == 40002);
	CHECK(core_count(c) == 1);
	CHECK(goes_up_unchanged(c, MASQ_OUT(.sport = 40002), LAN_WIRE, LAN));
	CHECK(forwarded(c, MASQ_OUT(.sport = 40001), LAN_WIRE, WAN));
	/* what was learned of the second WAN is gone, what was learned of the LAN stays */
	CHECK(core_bind(c, IPPROTO_TCP, &o2, &r2, 1003, &missing) == -ENOENT);
	CHECK(missing == (CORE_MISS_ORIG_OUT | CORE_MISS_REPLY_IN));
	core_free(c);
}

static int
collect(const struct core_conn *cn, void *arg)
{
	unsigned *ports = arg;

	ports[ports[0] + 1] = rte_be_to_cpu_16(cn->orig.sport);
	return ++ports[0] == 2;	/* stop after two */
}

TEST(walk_visits_the_connections_until_told_to_stop)
{
	struct core *c = mkcore();
	unsigned seen[4] = { 0 };

	handshake_of(c, 40001, 1000);
	handshake_of(c, 40002, 1000);
	handshake_of(c, 40003, 1000);
	CHECK(bind_of(c, 40001, 1001) == 0);
	CHECK(bind_of(c, 40002, 1001) == 0);
	CHECK(bind_of(c, 40003, 1001) == 0);
	core_conn_walk(c, collect, seen);
	CHECK(seen[0] == 2);
	CHECK(seen[1] != seen[2]);
	CHECK(seen[1] >= 40001 && seen[1] <= 40003 && seen[2] >= 40001 && seen[2] <= 40003);
	core_free(c);
}

/* A second web server, in another network than WEB. */
#define WEB2 RTE_IPV4(198, 18, 7, 7)

/* The handshake of a masqueraded connection of PC port hport to web:443. */
static void
handshake_to(struct core *c, uint16_t hport, uint32_t web, uint32_t now)
{
	struct pkt a = TCP(.dst = RLAN_MAC, .src = HOST_MAC, .sip = HOST, .dip = web, .sport = hport,
			   .dport = 443, .tcp_flags = RTE_TCP_SYN_FLAG, .payload = 0);
	struct pkt b = a, r, d;

	b.dst = GW_MAC, b.src = RWAN_MAC, b.sip = RWAN;
	r = TCP(.dst = RWAN_MAC, .src = GW_MAC, .sip = web, .dip = RWAN, .sport = 443,
		.dport = hport, .tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG, .payload = 0);
	d = r;
	d.dst = HOST_MAC, d.src = RLAN_MAC, d.dip = HOST;
	pass(c, a, LAN_WIRE, now);
	pass(c, b, WAN_KERNEL, now);
	pass(c, r, WAN_WIRE, now);
	pass(c, d, LAN_KERNEL, now);
}

static int
bind_to(struct core *c, uint16_t hport, uint32_t web, uint32_t now, unsigned *missing)
{
	struct core_tuple o = tup(HOST, hport, web, 443), r = tup(web, 443, RWAN, hport);

	return core_bind(c, IPPROTO_TCP, &o, &r, now, missing);
}

TEST(a_route_change_unbinds_the_connections_to_its_network_only)
{
	struct core *c = mkcore();
	struct flushed fl = { 0 };
	unsigned missing = 0;

	handshake_to(c, 40001, WEB, 1000);
	handshake_to(c, 40002, WEB2, 1000);
	CHECK(bind_to(c, 40001, WEB, 1001, &missing) == 0);
	CHECK(bind_to(c, 40002, WEB2, 1001, &missing) == 0);
	/* learned, not bound yet */
	handshake_to(c, 40003, WEB, 1001);
	CHECK(core_flush_route(c, rte_cpu_to_be_32(RTE_IPV4(203, 0, 113, 0)), 24, 1002,
			       note_flushed, &fl) == 1);
	CHECK(fl.n == 1 && fl.sport[0] == 40001);
	CHECK(core_count(c) == 1);
	CHECK(goes_up_unchanged(c, MASQ_OUT(.sport = 40001), LAN_WIRE, LAN));
	CHECK(forwarded(c, MASQ_OUT(.sport = 40002, .dip = WEB2), LAN_WIRE, WAN));
	/* the way out towards that network was learned before the change: gone too */
	CHECK(bind_to(c, 40003, WEB, 1003, &missing) == -ENOENT);
	CHECK(missing == CORE_MISS_ORIG_OUT);
	core_free(c);
}

TEST(a_route_change_towards_the_lan_unbinds_the_connections_back_to_it)
{
	struct core *c = mkcore();
	struct flushed fl = { 0 };
	unsigned missing = 0;

	handshake_to(c, 40001, WEB, 1000);
	CHECK(bind_to(c, 40001, WEB, 1001, &missing) == 0);
	CHECK(core_flush_route(c, rte_cpu_to_be_32(HOST), 32, 1002, note_flushed, &fl) == 1);
	CHECK(core_count(c) == 0);
	CHECK(goes_up_unchanged(c, MASQ_BACK(.dport = 40001), WAN_WIRE, WAN));
	core_free(c);
}

TEST(a_change_of_the_default_route_unbinds_every_connection)
{
	struct core *c = mkcore();
	struct flushed fl = { 0 };
	unsigned missing = 0;

	handshake_to(c, 40001, WEB, 1000);
	handshake_to(c, 40002, WEB2, 1000);
	CHECK(bind_to(c, 40001, WEB, 1001, &missing) == 0);
	CHECK(bind_to(c, 40002, WEB2, 1001, &missing) == 0);
	CHECK(core_flush_route(c, 0, 0, 1002, note_flushed, &fl) == 2);
	CHECK(fl.n == 2 && core_count(c) == 0);
	CHECK(core_flush_route(c, 0, 0, 1003, NULL, NULL) == 0);
	core_free(c);
}

TEST(a_route_to_a_network_nothing_goes_to_unbinds_nothing)
{
	struct core *c = mkcore();
	unsigned missing = 0;

	handshake_to(c, 40001, WEB, 1000);
	CHECK(bind_to(c, 40001, WEB, 1001, &missing) == 0);
	CHECK(core_flush_route(c, rte_cpu_to_be_32(RTE_IPV4(203, 0, 113, 128)), 25, 1002,
			       NULL, NULL) == 0);
	CHECK(core_flush_route(c, rte_cpu_to_be_32(RTE_IPV4(192, 168, 5, 11)), 32, 1002,
			       NULL, NULL) == 0);
	CHECK(core_count(c) == 1);
	CHECK(forwarded(c, MASQ_OUT(.sport = 40001), LAN_WIRE, WAN));
	core_free(c);
}

TEST(a_neighbour_with_a_new_mac_address_unbinds_the_connections_sent_to_the_old_one)
{
	struct core *c = mkcore();
	struct core_tuple o = tup(CLIENT, 5555, RWAN, 8080), r = tup(SRV, 80, CLIENT, 5555);
	struct rte_ether_addr srv = SRV_MAC, gw = GW_MAC;
	struct flushed fl = { 0 };
	unsigned missing = 0;

	/* the masqueraded connection, and the port forwarded to the server on the LAN */
	handshake_to(c, 40001, WEB, 1000);
	CHECK(bind_to(c, 40001, WEB, 1001, &missing) == 0);
	pass(c, TCP(.dst = RWAN_MAC, .src = GW_MAC, .sip = CLIENT, .dip = RWAN, .sport = 5555,
		    .dport = 8080, .tcp_flags = RTE_TCP_SYN_FLAG, .payload = 0), WAN_WIRE, 1000);
	pass(c, TCP(.dst = SRV_MAC, .src = RLAN_MAC, .sip = CLIENT, .dip = SRV, .sport = 5555,
		    .dport = 80, .ttl = 63, .tcp_flags = RTE_TCP_SYN_FLAG, .payload = 0),
	     LAN_KERNEL, 1000);
	pass(c, TCP(.dst = RLAN_MAC, .src = SRV_MAC, .sip = SRV, .dip = CLIENT, .sport = 80,
		    .dport = 5555, .tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG, .payload = 0),
	     LAN_WIRE, 1000);
	pass(c, TCP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = CLIENT, .sport = 8080,
		    .dport = 5555, .ttl = 63, .tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG,
		    .payload = 0), WAN_KERNEL, 1000);
	CHECK(core_bind(c, IPPROTO_TCP, &o, &r, 1001, &missing) == 0);
	/* learned, not bound yet */
	handshake_to(c, 40002, WEB2, 1001);

	CHECK(core_flush_mac(c, srv.addr_bytes, 1002, note_flushed, &fl) == 1);
	CHECK(fl.n == 1 && fl.sport[0] == 5555);
	CHECK(core_count(c) == 1);
	CHECK(forwarded(c, MASQ_OUT(.sport = 40001), LAN_WIRE, WAN));
	/* both connections go out to the gateway */
	CHECK(core_flush_mac(c, gw.addr_bytes, 1003, NULL, NULL) == 1);
	CHECK(core_count(c) == 0);
	CHECK(goes_up_unchanged(c, MASQ_OUT(.sport = 40001), LAN_WIRE, LAN));
	/* what was learned of the way out to the gateway is gone too */
	CHECK(bind_to(c, 40002, WEB2, 1004, &missing) == -ENOENT);
	CHECK(missing == CORE_MISS_ORIG_OUT);
	core_free(c);
}

TEST(a_mac_address_no_connection_is_sent_to_unbinds_nothing)
{
	struct core *c = mkcore();
	struct rte_ether_addr other = MAC(0x77);
	unsigned missing = 0;

	handshake_to(c, 40001, WEB, 1000);
	CHECK(bind_to(c, 40001, WEB, 1001, &missing) == 0);
	CHECK(core_flush_mac(c, other.addr_bytes, 1002, NULL, NULL) == 0);
	CHECK(core_count(c) == 1);
	core_free(c);
}

/*
 * One worker and one control thread at once. The worker runs, again and
 * again, the handshake and two data packets of one of 32 connections and
 * checks every packet it forwards; the control thread binds, unbinds and
 * flushes them meanwhile. A freed entry a worker could still use would
 * forward a packet with the poison of a freed action, or not as the
 * connection is.
 */
#define RACE_CONNS 32
#define RACE_PORT0 41000

struct race {
	struct core *c;
	volatile int stop;
	uint64_t bursts, forwarded, up, wrong;
};

static int
race_worker(void *arg)
{
	struct race *r = arg;
	uint64_t x = 0x2545f4914f6cdd1dULL;

	core_worker_start(r->c, 0);
	while (!r->stop) {
		uint16_t hport;
		struct rte_mbuf *m[6];
		struct core_out out;
		int p, side;
		unsigned k;

		x ^= x << 13, x ^= x >> 7, x ^= x << 17;
		hport = (uint16_t)(RACE_PORT0 + x % RACE_CONNS);
		m[0] = mk(TCP(.dst = RLAN_MAC, .src = HOST_MAC, .sip = HOST, .dip = WEB,
			      .sport = hport, .dport = 443, .tcp_flags = RTE_TCP_SYN_FLAG,
			      .payload = 0), LAN_WIRE);
		m[1] = mk(TCP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = WEB,
			      .sport = hport, .dport = 443, .ttl = 63,
			      .tcp_flags = RTE_TCP_SYN_FLAG, .payload = 0), WAN_KERNEL);
		m[2] = mk(TCP(.dst = RWAN_MAC, .src = GW_MAC, .sip = WEB, .dip = RWAN,
			      .sport = 443, .dport = hport, .ttl = 50,
			      .tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG, .payload = 0),
			  WAN_WIRE);
		m[3] = mk(TCP(.dst = HOST_MAC, .src = RLAN_MAC, .sip = WEB, .dip = HOST,
			      .sport = 443, .dport = hport, .ttl = 49,
			      .tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG, .payload = 0),
			  LAN_KERNEL);
		m[4] = mk(MASQ_OUT(.sport = hport), LAN_WIRE);
		m[5] = mk(MASQ_BACK(.dport = hport), WAN_WIRE);
		core_rx(r->c, 0, m, 6, 1000, &out);
		for (p = 0; p < CORE_MAX_PORTS; p++)
			for (side = 0; side < 2; side++)
				for (k = 0; k < out.n[p][side]; k++) {
					struct rte_mbuf *o = out.pkts[p][side][k];
					struct rte_ipv4_hdr *ip = rte_pktmbuf_mtod_offset(o,
						struct rte_ipv4_hdr *, RTE_ETHER_HDR_LEN);
					struct rte_tcp_hdr *th = (struct rte_tcp_hdr *)(ip + 1);

					if (p > LAN)
						r->wrong++;
					else if (side == CORE_KERNEL)
						r->up++;
					else if (ip->time_to_live == 63 && p == WAN) {
						/* the data packet of the PC, NATed */
						r->forwarded++;
						r->wrong += ip->src_addr != rte_cpu_to_be_32(RWAN) ||
							    th->src_port != rte_cpu_to_be_16(hport) ||
							    !checksums_right(o);
					} else if (ip->time_to_live == 49 && p == LAN &&
						   th->tcp_flags == RTE_TCP_ACK_FLAG) {
						r->forwarded++;
						r->wrong += ip->dst_addr != rte_cpu_to_be_32(HOST) ||
							    th->dst_port != rte_cpu_to_be_16(hport) ||
							    !checksums_right(o);
					}
					rte_pktmbuf_free(o);
				}
		r->bursts++;
		core_worker_quiescent(r->c, 0);
	}
	core_worker_stop(r->c, 0);
	return 0;
}

TEST(a_worker_forwards_right_while_the_control_thread_binds_and_unbinds)
{
	struct race r = { .c = mkcore_with(RACE_CONNS, 4096, 0x7fffffff) };
	unsigned binds = 0, unbinds = 0, flushes = 0, i;
	uint64_t x = 0x9e3779b97f4a7c15ULL;
	struct timespec t0, t;

	CHECK(rte_eal_remote_launch(race_worker, &r, rte_get_next_lcore(-1, 1, 0)) == 0);
	clock_gettime(CLOCK_MONOTONIC, &t0);
	do {
		for (i = 0; i < 100; i++) {
			uint16_t hport;
			struct core_tuple o, rp;
			unsigned missing;

			x ^= x << 13, x ^= x >> 7, x ^= x << 17;
			hport = (uint16_t)(RACE_PORT0 + x % RACE_CONNS);
			o = tup(HOST, hport, WEB, 443);
			rp = tup(WEB, 443, RWAN, hport);
			if (x % 1000 == 0)
				flushes += core_flush(r.c, 1000) > 0;
			else if (x % 1000 == 1)
				flushes += core_flush_port(r.c, WAN, 1000, NULL, NULL) > 0;
			else if (core_unbind(r.c, IPPROTO_TCP, &o, 1000) == 0)
				unbinds++;
			else if (core_bind(r.c, IPPROTO_TCP, &o, &rp, 1000, &missing) == 0)
				binds++;
		}
		core_poll(r.c, 1000);
		clock_gettime(CLOCK_MONOTONIC, &t);
	} while (t.tv_sec - t0.tv_sec < 2);
	r.stop = 1;
	rte_eal_mp_wait_lcore();
	printf("    %lu bursts, %lu forwarded, %lu up, %u binds, %u unbinds, %u flushes\n",
	       (unsigned long)r.bursts, (unsigned long)r.forwarded, (unsigned long)r.up, binds,
	       unbinds, flushes);
	CHECK(r.wrong == 0);
	CHECK(r.forwarded > 1000 && r.up > 1000 && binds > 1000 && unbinds > 1000);

	/* every entry deleted is free again: the whole table can be bound */
	core_flush(r.c, 1000);
	core_poll(r.c, 1000);
	for (i = 0; i < RACE_CONNS; i++)
		handshake_of(r.c, (uint16_t)(RACE_PORT0 + i), 1000);
	for (i = 0; i < RACE_CONNS; i++)
		CHECK(bind_of(r.c, (uint16_t)(RACE_PORT0 + i), 1000) == 0);
	CHECK(core_count(r.c) == RACE_CONNS);
	core_free(r.c);
}

/*
 * Conntrack never has one tuple in two connections; if it did, the second
 * would take the entry of the first.
 */
TEST(a_connection_whose_entry_another_one_has_is_refused)
{
	struct core *c = masq_core();
	/* its reply direction is the original direction of the masqueraded one */
	struct core_tuple o = tup(CLIENT, 6000, RWAN, 7000), r = *masq_orig();
	unsigned missing;

	pass(c, TCP(.dst = RWAN_MAC, .src = GW_MAC, .sip = CLIENT, .dip = RWAN, .sport = 6000,
		    .dport = 7000, .tcp_flags = RTE_TCP_SYN_FLAG, .payload = 0), WAN_WIRE, 1000);
	pass(c, TCP(.dst = GW_MAC, .src = RWAN_MAC, .sip = RWAN, .dip = CLIENT, .sport = 7000,
		    .dport = 6000, .tcp_flags = RTE_TCP_SYN_FLAG, .payload = 0), WAN_KERNEL, 1000);
	CHECK(core_bind(c, IPPROTO_TCP, &o, &r, 1001, &missing) == -EEXIST);
	CHECK(core_count(c) == 1);
	CHECK(forwarded(c, MASQ_OUT(), LAN_WIRE, WAN));
	core_free(c);
}

/* The kernel sees the packets of a burst in the order they came in. */
TEST(packets_going_up_to_the_kernel_keep_their_order)
{
	struct core *c = masq_core();
	struct rte_mbuf *m[4], *want[4];
	struct core_out out;
	unsigned i;

	/* decided as they are parsed (FIN, ARP) or after the lookup (too big, no entry) */
	want[0] = mk(MASQ_OUT(.payload = 1461), LAN_WIRE);
	want[1] = mk(MASQ_OUT(.tcp_flags = RTE_TCP_FIN_FLAG | RTE_TCP_ACK_FLAG), LAN_WIRE);
	want[2] = mk(MASQ_OUT(.sport = 40009), LAN_WIRE);
	want[3] = mk(MASQ_OUT(.ethertype = RTE_ETHER_TYPE_ARP), LAN_WIRE);
	for (i = 0; i < 4; i++)
		m[i] = rte_pktmbuf_copy(want[i], pool, 0, UINT32_MAX);
	core_rx(c, 0, m, 4, 1002, &out);
	CHECK(out.n[LAN][CORE_KERNEL] == 4);
	for (i = 0; i < 4; i++)
		CHECK(same(out.pkts[LAN][CORE_KERNEL][i], want[i]));
	core_free(c);
}

TEST(a_packet_of_an_ethdev_the_core_was_not_told_about_goes_nowhere)
{
	struct core *c = masq_core();
	unsigned free_before = rte_mempool_avail_count(pool), p, s, out = 0;
	/* an ethdev that is not one of the engine's, and an mbuf of no ethdev */
	struct rte_mbuf *m[2] = { mk(MASQ_OUT(), 25), mk(MASQ_OUT(), RTE_MBUF_PORT_INVALID) };
	struct core_out o;

	core_rx(c, 0, m, 2, 1002, &o);
	for (p = 0; p < CORE_MAX_PORTS; p++)
		for (s = 0; s < 2; s++)
			out += o.n[p][s];
	CHECK(out == 0);
	CHECK(rte_mempool_avail_count(pool) == free_before);
	core_free(c);
}

int
main(int argc, char **argv)
{
	int n = rte_eal_init(argc, argv);

	if (n < 0) {
		fprintf(stderr, "rte_eal_init failed\n");
		return 2;
	}
	argc -= n;
	argv += n;
	pool = rte_pktmbuf_pool_create("test", 8191, 0, 0, RTE_MBUF_DEFAULT_BUF_SIZE, SOCKET_ID_ANY);
	if (!pool) {
		fprintf(stderr, "no mbuf pool\n");
		return 2;
	}
	return test_main(argc - 1, argv + 1);
}
