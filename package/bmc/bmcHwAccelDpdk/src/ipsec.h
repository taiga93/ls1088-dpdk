/*
 * Tunnel IPsec in the engine (spec-ipsec: Engine; ADR-0014): the SAs of the
 * kernel that bmchwaccel-syncd hands over, and what the engine does with
 * the ESP the kernel sends on them. No I/O: the engine hands it the packets
 * of the kernel sides and the results of "ESP ops" (esp.h), and sends what
 * comes out.
 *
 * The kernel keeps its SAs. The engine is the only one that numbers the ESP
 * on the wire of an outbound SA it holds: each packet the kernel sends on
 * it is decrypted again with the keys of the SA (a session without
 * anti-replay), then encrypted again with the engine's numbers, which start
 * where the daemon says (oseq of the kernel + 2^24), and goes out of the
 * wire side of the port it came from, with the L2 header the kernel gave
 * it. A packet the SEC could not decrypt again is dropped: what the kernel
 * numbered never reaches the wire. The kernel sending a large packet
 * without DF fragments its ESP: those fragments are put together again,
 * numbered again, and fragmented again to the MTU of the port.
 *
 * ESP of an SPI the engine does not hold, IKE (UDP with the non-ESP
 * marker) and NAT-T keepalives go on as they were.
 *
 * Connections through a tunnel (spec-ipsec: Đường gói ①–④). The kernel's
 * ESP decrypted again tells the core (core_learn_tunnel()) that its tuple
 * goes into the tunnel of its SA, with the L2 header of that ESP. ESP from
 * the wire on an inbound SA held is decrypted out of place: the packet
 * decrypted goes to the core (core_rx_tunnel()), which forwards it when it
 * belongs to a connection that comes in from that SA's tunnel, or learns it
 * "in from the tunnel"; otherwise the ESP as it came goes up to the kernel,
 * which decrypts it itself, and the copy is dropped. ESP the SEC does not
 * decrypt goes up too: the kernel decides. The packets the core puts into
 * a tunnel (core_out.tun) are encrypted with the tunnel's current outbound
 * SA, its newest, and go out of the wire side of their port; without one
 * they are dropped (the tunnel's connections are let go of meanwhile).
 * One worker encrypts all of a tunnel's, so that its ESP leaves in the
 * order of its numbers, which the peer's anti-replay window needs (spec:
 * Thứ tự gói): the worker the kernel's ESP of the tunnel comes to, always
 * the same one (RSS). Another worker hands its packets into the tunnel
 * over to it (ipsec_out.away).
 * The engine counts what it encrypted and decrypted on its own on each SA.
 *
 * A tunnel is the reqid of its SAs, which strongSwan keeps across rekeys:
 * the SAs of a tunnel share a queue pair of each worker (esp.h, lane). The
 * engine holds the SAs of at most max_tunnels tunnels. When a tunnel loses
 * its last outbound SA, or its last SA, its connections are let go of
 * (core_flush_tunnel()).
 *
 * Threads: workers call ipsec_kernel(), ipsec_wire(), ipsec_tunnel() and
 * ipsec_done() with their own id and read the tables without locks;
 * everything else is for the control thread, which waits for the workers
 * through RCU (the core's quiescent states) before an SA it lets go of can
 * be used again.
 *
 * Addresses are in network byte order, SPIs and ports in host order, as in
 * esp.h.
 */
#ifndef BMCHWACCEL_IPSEC_H
#define BMCHWACCEL_IPSEC_H

#include <stdint.h>

#include <rte_mbuf.h>
#include <rte_rcu_qsbr.h>

#include "core.h"
#include "esp.h"

#define IPSEC_MAX_TUNNELS 4096	/* Q16: a constant of the build */
/*
 * Q12: the highest number the engine gives a packet of an outbound SA,
 * 2^32 - 2^26, so that the kernel's (the engine's + 2^24, bmchwaccel-syncd)
 * stays far below the end. Past it, the packets the engine would number are
 * dropped and counted, until the daemon lets go of the SA, which it does
 * before.
 */
#define IPSEC_SEQ_MAX ((uint32_t)-(1u << 26))
#define IPSEC_OUT_MAX 128	/* packets of one ipsec_done() out of a port */

struct ipsec_params {
	unsigned nworkers;
	unsigned nports;
	uint16_t mtu[CORE_MAX_PORTS];	/* largest IPv4 packet out of each port */
	unsigned max_tunnels;
	unsigned max_sa;		/* the SAs of esp: an outbound SA takes two */
	/* the connection table of the engine, whose quiescent states (core_rcu()) the workers report */
	struct core *core;
	/*
	 * The pool of the engine's packets, whose private area holds what the
	 * engine keeps of a packet while the SEC has it: at least
	 * IPSEC_PRIV_SIZE. Packets fragmented again come from it too.
	 */
	struct rte_mempool *mp;
	/*
	 * Datagrams put together that are longer than a packet of mp (the
	 * kernel fragments the ESP of a large packet without DF): packets of
	 * one segment of IPSEC_WHOLE_SIZE, with the private area of mp. One
	 * without a packet left is dropped and counted.
	 */
	struct rte_mempool *whole;
	int socket_id;
};

/* What a packet of the pool must have in its private area. */
#define IPSEC_PRIV_SIZE 40
/* The buffer of a packet of the pool of whole datagrams (its data room): the most rte_mbuf has. */
#define IPSEC_WHOLE_SIZE UINT16_MAX

struct ipsec;

/* NULL without memory. */
struct ipsec *ipsec_create(const struct ipsec_params *p, struct esp *esp);
void ipsec_free(struct ipsec *x);

/* Packets with mbuf.port == ethdev came from the kernel side, or the wire side, of port. */
int ipsec_map_kernel(struct ipsec *x, uint16_t ethdev, unsigned port);
int ipsec_map_wire(struct ipsec *x, uint16_t ethdev, unsigned port);

/*
 * The control thread. An SA as esp.h gives it, lane the reqid of its
 * tunnel; seq of an outbound SA is the number of its first packet.
 * 0, or -EINVAL (a conf esp cannot do, an outbound SA that would start past
 * IPSEC_SEQ_MAX), -EEXIST (its SPI and destination are held), -ENOSPC (a
 * tunnel past max_tunnels, or no SA of esp left), or the backend's error.
 * A new outbound SA of a tunnel encrypts for it from then on, whatever SA
 * did before: a rekey moves the tunnel's connections to it.
 */
int ipsec_sa_add(struct ipsec *x, const struct esp_sa_conf *c);

struct ipsec_sa_info {
	uint8_t dir;		/* ESP_OUT, ESP_IN */
	uint32_t spi, src, dst;
	uint32_t reqid;
	/*
	 * Outbound: the highest number the SA may have used, what was taken
	 * by it counted; final once it is let go of.
	 */
	uint32_t last;
	/* the packets the engine encrypted or decrypted on its own (③④ of the spec) */
	uint64_t bytes, packets;
	uint64_t failed;	/* jobs the SEC failed, both sessions */
	uint64_t dropped;	/* jobs beyond the credit, packets lost on the way */
};

/*
 * Lets go of the SA of spi to dst, in order (spec-ipsec: Số thứ tự): first
 * ipsec_sa_stop(), after which the engine no longer uses the SA and drops
 * the ESP the kernel sends on it, and *info (when not NULL) says its last
 * number; the daemon writes that into the kernel; then ipsec_sa_del(),
 * after which that ESP goes out as it is. ipsec_sa_del() alone does both
 * (an SA the kernel deleted). 0 or -ENOENT. Its sessions go once no job of
 * them is left (ipsec_poll()).
 * The tunnel of an SA let go of that has no outbound SA left, or no SA at
 * all, lets go of its connections: gone (when not NULL) is told each, so
 * that the daemon hands them over again once they can be. now: the core's
 * clock, for them.
 */
int ipsec_sa_stop(struct ipsec *x, uint32_t spi, uint32_t dst, uint32_t now,
		  struct ipsec_sa_info *info, core_flushed_fn *gone, void *arg);
int ipsec_sa_del(struct ipsec *x, uint32_t spi, uint32_t dst, uint32_t now,
		 struct ipsec_sa_info *info, core_flushed_fn *gone, void *arg);

/* Lets go of every SA, as ipsec_sa_del(); fn and gone (when not NULL) are told each. */
unsigned ipsec_sa_flush(struct ipsec *x, uint32_t now,
			void (*fn)(const struct ipsec_sa_info *, void *), core_flushed_fn *gone,
			void *arg);
/*
 * The way to the peers in dst/len changed (spec-ipsec: Route, neigh, link;
 * Q14): each tunnel with an SA to or from such a peer lets go of its
 * connections and of what was learned of it, its outer L2 header with it
 * (core_flush_tunnel()); gone is told each connection. The SAs stay.
 * len 0: every tunnel. How many connections.
 */
unsigned ipsec_flush_peer(struct ipsec *x, uint32_t dst, unsigned len, uint32_t now,
			  core_flushed_fn *gone, void *arg);
/* Calls fn for each SA held until fn returns non-zero. */
void ipsec_sa_walk(struct ipsec *x, int (*fn)(const struct ipsec_sa_info *, void *), void *arg);
unsigned ipsec_sa_count(const struct ipsec *x);

/* Lets go of the sessions of SAs let go of whose jobs are all back. Often. */
void ipsec_poll(struct ipsec *x);

/* A packet into a tunnel that worker encrypts, for ipsec_tunnel() there. */
struct ipsec_away {
	struct core_tun t;
	unsigned worker;
};

/*
 * Where the packets of ipsec_kernel(), ipsec_tunnel() and ipsec_done() go:
 * pkts[p][side] out of port p, away to the worker of their tunnel.
 */
struct ipsec_out {
	uint16_t n[CORE_MAX_PORTS][2];
	uint16_t naway;
	struct rte_mbuf *pkts[CORE_MAX_PORTS][2][IPSEC_OUT_MAX];
	struct ipsec_away away[IPSEC_OUT_MAX];
};

/*
 * Workers. ipsec_kernel() takes, out of the n packets of pkts (CORE_BURST
 * at most), the ESP the kernel sent on an SA the engine holds, and the
 * fragments of such ESP; the others are left in pkts, in their order, and
 * their number returned. Packets of a port's wire side are always left.
 * timer: rte_get_timer_cycles(). A datagram put together that is no ESP of
 * an SA held goes out fragmented again, into out (emptied first).
 * ipsec_wire() does the same with the packets of the wire sides: it takes
 * the ESP on an inbound SA held, to be decrypted.
 * ipsec_tunnel() takes the n packets the core put into tunnels, to be
 * encrypted by w, or handed over (out, emptied first).
 * ipsec_done() takes the n results (ESP_BURST at most) of "ESP ops" that
 * came back to worker w and puts the packets they make into out (emptied
 * first); now is the core's clock. What the engine does not use, it frees.
 */
unsigned ipsec_kernel(struct ipsec *x, unsigned w, struct rte_mbuf **pkts, unsigned n,
		      uint64_t timer, struct ipsec_out *out);
unsigned ipsec_wire(struct ipsec *x, unsigned w, struct rte_mbuf **pkts, unsigned n);
void ipsec_tunnel(struct ipsec *x, unsigned w, const struct core_tun *t, unsigned n,
		  struct ipsec_out *out);
void ipsec_done(struct ipsec *x, unsigned w, const struct esp_result *r, unsigned n,
		uint32_t now, struct ipsec_out *out);

#endif
