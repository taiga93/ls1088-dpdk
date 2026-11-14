/*
 * The per-packet core of bmchwaccel-engine: parse, connection table, NAT,
 * TTL, checksums, and learning the way out of a connection from the packets
 * the kernel sends (ADR-0012). It does no I/O and knows nothing of DPAA2:
 * the caller hands it bursts of mbufs and sends what comes out.
 *
 * Each engine port has two sides. Packets from the wire side come in from
 * the cable; packets from the kernel side are the ones the kernel sends out
 * of that port. A packet from the wire either belongs to an accelerated
 * connection, and then goes out of the wire side of the port its entry
 * names, rewritten, or goes up to the kernel side of the port it came in
 * on, unchanged. A packet from the kernel always goes out of the wire side
 * of the same port, unchanged.
 *
 * Learning: a packet that goes up to the kernel records "this tuple comes
 * in from this port", a packet from the kernel records "this tuple goes
 * out of this port, with this L2 header". core_bind() turns the four
 * records of a connection (both directions, both ends) into two entries.
 *
 * Tunnel IPsec (ipsec.h): a connection may go out into a tunnel and come
 * in from one. ipsec.c hands the core what it decrypted: the packets the
 * kernel sent into a tunnel, decrypted again, record "this tuple goes into
 * this tunnel, out of this port with this outer L2 header"
 * (core_learn_tunnel()); the packets decrypted out of a tunnel either
 * belong to a connection that comes in from that tunnel or record "this
 * tuple comes in from this tunnel" (core_rx_tunnel()). The packets of an
 * entry that goes into a tunnel come out of core_rx() rewritten, the outer
 * L2 header in front, for ipsec.c to encrypt (core_out.tun).
 *
 * Threads: workers call core_rx() and the core_worker_*() functions with
 * their own worker id; the table is read without locks. Everything else is
 * for one control thread, which updates the table through RCU.
 *
 * Addresses and ports are in network byte order everywhere. Times are in
 * milliseconds of a clock that may wrap: only differences matter.
 */
#ifndef BMCHWACCEL_CORE_H
#define BMCHWACCEL_CORE_H

#include <stdint.h>

#include <rte_mbuf.h>

#define CORE_BURST 32		/* most packets in one core_rx() call */
#define CORE_MAX_PORTS 8	/* three bits of the key */
#define CORE_MAX_WORKERS 8

enum { CORE_WIRE, CORE_KERNEL };

struct core_params {
	unsigned nports;
	uint16_t mtu[CORE_MAX_PORTS];	/* largest IPv4 packet out of each port */
	unsigned nworkers;
	unsigned max_conns;		/* connections, two table entries each */
	unsigned learn_max;		/* learned records kept; the oldest goes */
	unsigned learn_ttl;		/* ms a learned record stays usable */
	int socket_id;
};

struct core;

struct core *core_create(const struct core_params *p);
void core_free(struct core *c);

/*
 * Packets with mbuf.port == ethdev came in on that side of an engine port.
 * core_rx() frees a packet of an ethdev it was not told about.
 */
int core_map_ethdev(struct core *c, uint16_t ethdev, unsigned port, int side);

/*
 * A packet into a tunnel: the outer L2 header (m->l2_len bytes), then the
 * inner IPv4 packet, rewritten; it goes out of port once encrypted.
 */
struct core_tun {
	struct rte_mbuf *m;
	uint16_t tunnel;
	uint8_t port;
};

/* Where the packets of one core_rx() go: pkts[p][side] out of port p, tun into a tunnel. */
struct core_out {
	uint16_t n[CORE_MAX_PORTS][2];
	uint16_t ntun;
	struct rte_mbuf *pkts[CORE_MAX_PORTS][2][CORE_BURST];
	struct core_tun tun[CORE_BURST];
};

/*
 * Workers. core_rx() sorts up to CORE_BURST packets into out, rewriting
 * those of accelerated connections, and counts them at time now. A worker
 * that sleeps goes offline first, so that the control thread does not wait
 * for it.
 */
void core_rx(struct core *c, unsigned worker, struct rte_mbuf **pkts, unsigned n,
	     uint32_t now, struct core_out *out);
/*
 * The n packets decrypted out of tunnel tunnel[i] that came in on port[i],
 * each from its IPv4 header, in one segment: those of an accelerated
 * connection that comes in from that tunnel are rewritten into out (emptied
 * first), as core_rx() does. The others the kernel must see: bit i of the
 * result is set for them, which are left as they are and learned "in from
 * the tunnel" when they may be bound.
 */
uint64_t core_rx_tunnel(struct core *c, unsigned worker, struct rte_mbuf **pkts,
			const uint16_t *tunnel, const uint8_t *port, unsigned n, uint32_t now,
			struct core_out *out);
/*
 * A packet the kernel sent into tunnel, decrypted again (m from its IPv4
 * header): its tuple goes into the tunnel, out of port with the outer L2
 * header l2 (l2_len bytes), and at most mtu bytes of inner IPv4 packet fit.
 */
void core_learn_tunnel(struct core *c, unsigned worker, const struct rte_mbuf *m, unsigned port,
		       const uint8_t *l2, unsigned l2_len, uint16_t tunnel, uint16_t mtu,
		       uint32_t now);
void core_worker_start(struct core *c, unsigned worker);
void core_worker_quiescent(struct core *c, unsigned worker);
void core_worker_offline(struct core *c, unsigned worker);
void core_worker_online(struct core *c, unsigned worker);
void core_worker_stop(struct core *c, unsigned worker);

/* The control thread. */
struct core_tuple {
	uint32_t sip, dip;
	uint16_t sport, dport;
};

/* What core_bind() did not find; which of them, in *missing on -ENOENT. */
#define CORE_MISS_ORIG_IN	0x1	/* no packet of the original direction came in */
#define CORE_MISS_ORIG_OUT	0x2	/* the kernel sent none of them out */
#define CORE_MISS_REPLY_IN	0x4
#define CORE_MISS_REPLY_OUT	0x8

/*
 * Accelerate a connection, given as conntrack has it: orig is the tuple of
 * the original direction as it comes in, reply the tuple of the reply
 * direction as it comes in. 0, or -EINVAL (not TCP/UDP), -EEXIST, -ENOSPC
 * (table full) or -ENOENT (not learned: *missing says what). A direction
 * learned in from a tunnel other than the one the other direction goes
 * into is not learned.
 */
int core_bind(struct core *c, uint8_t proto, const struct core_tuple *orig,
	      const struct core_tuple *reply, uint32_t now, unsigned *missing);
/*
 * Stop accelerating: 0 or -ENOENT. What was learned of the connection, or
 * of the port, or everything, is forgotten too, so that the next bind uses
 * the way the kernel sends the next packets.
 */
int core_unbind(struct core *c, uint8_t proto, const struct core_tuple *orig, uint32_t now);
unsigned core_flush(struct core *c, uint32_t now);
unsigned core_count(const struct core *c);

struct core_conn {
	uint8_t proto;
	struct core_tuple orig, reply;
	/* [0] the original direction, [1] the reply direction */
	uint8_t in[2], out[2];
	uint32_t pkts[2];
	uint64_t bytes[2];
	uint32_t last[2];	/* time the last packet was forwarded */
};

/*
 * The flushes of what a change of the kernel's routing makes wrong: each
 * unbinds some connections, calls fn (when not NULL) for each of them, and
 * returns how many. What was learned of the same ways is forgotten too, so
 * that a connection bound later uses the way the kernel sends its packets
 * after the change.
 *
 * core_flush_port: the connections that come in or go out on port (its
 * cable went down), and everything learned on it.
 * core_flush_route: the connections with a direction whose packets go out
 * to an address in dst/len after NAT (the route to that network changed;
 * len 0: every connection), and what was learned of packets the kernel sent
 * to such an address.
 * core_flush_mac: the connections with a direction sent to the MAC address
 * mac (a neighbour took another one), and what was learned of packets the
 * kernel sent to it.
 */
typedef void core_flushed_fn(const struct core_conn *conn, void *arg);
unsigned core_flush_port(struct core *c, unsigned port, uint32_t now, core_flushed_fn *fn,
			 void *arg);
unsigned core_flush_route(struct core *c, uint32_t dst, unsigned len, uint32_t now,
			  core_flushed_fn *fn, void *arg);
unsigned core_flush_mac(struct core *c, const uint8_t mac[6], uint32_t now, core_flushed_fn *fn,
			void *arg);
/*
 * core_flush_tunnel: the connections that go into or come in from tunnel,
 * and everything learned of it (the tunnel has no outbound SA left, or is
 * gone and its number may be given to another).
 */
unsigned core_flush_tunnel(struct core *c, uint16_t tunnel, uint32_t now, core_flushed_fn *fn,
			   void *arg);

int core_conn_get(struct core *c, uint8_t proto, const struct core_tuple *orig,
		  struct core_conn *conn);
/* Calls fn for each accelerated connection until fn returns non-zero. */
void core_conn_walk(struct core *c, int (*fn)(const struct core_conn *, void *), void *arg);

/* Take in what the workers learned and free what they no longer use. Often. */
void core_poll(struct core *c, uint32_t now);

/*
 * For the other tables of the engine. core_l2_len(): the length of the L2
 * header of a frame of IPv4 as the core takes it (Ethernet, one 802.1Q tag,
 * a PPPoE session, or a tag then PPPoE), 0 for anything else.
 * core_rcu(): the quiescent states the workers report, which a table they
 * read without locks can wait for too.
 */
unsigned core_l2_len(const struct rte_mbuf *m);
struct rte_rcu_qsbr *core_rcu(const struct core *c);

#endif
