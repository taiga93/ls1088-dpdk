/*
 * What bmchwaccel-syncd decides about each connection of conntrack: when the
 * engine is to accelerate it, when to take it back, when to ask again, and
 * how long conntrack is to keep a connection the engine still forwards. No
 * I/O: syncd.c reads conntrack, talks to the engine, and tells this module
 * what came of it.
 *
 * A connection is handed to the engine when it is IPv4 TCP or UDP, ASSURED,
 * its conntrack mark has no SYNC_KEEP_BIT (kept on the CPU, keep.sh of
 * bmcHwAccel), it has no helper and is no expected connection of one, and,
 * for TCP, it is ESTABLISHED. Whether the engine learned both directions is
 * the engine's to say: a bind it refuses for that is tried again later, less
 * and less often. A connection that stops meeting those conditions, or that
 * conntrack destroys, is taken back.
 *
 * Addresses and ports are in network byte order. Times are in milliseconds
 * of a clock that may wrap.
 */
#ifndef BMCHWACCEL_SYNC_H
#define BMCHWACCEL_SYNC_H

#include <stdint.h>

#define SYNC_KEEP_BIT 0x10000	/* in the conntrack mark: kept on the CPU */
#define SYNC_RETRY_FIRST 1000	/* ms until a refused bind is tried again */
#define SYNC_RETRY_MAX 30000	/* and at most, doubling each time */

/* conntrack's TCP state ESTABLISHED (TCP_CONNTRACK_ESTABLISHED) */
#define SYNC_TCP_ESTABLISHED 3
#define SYNC_TCP_UNKNOWN -1

struct sync_tuple {
	uint32_t sip, dip;
	uint16_t sport, dport;
};

/* A connection as a conntrack message gives it. */
struct sync_ct {
	int ipv4;
	uint8_t proto;			/* IPPROTO_TCP, IPPROTO_UDP or another */
	struct sync_tuple orig, reply;	/* as each direction comes in */
	uint32_t status;		/* IPS_* bits */
	uint32_t mark;			/* 0 when the message has none */
	int tcp_state;			/* SYNC_TCP_UNKNOWN: not in the message */
	int helper;			/* it has a helper, or is expected by one */
};

enum sync_msg {
	SYNC_NEW,	/* event: a new connection */
	SYNC_UPDATE,	/* event: it changed; an update without a TCP state may come */
	SYNC_DESTROY,	/* event: it is gone */
	SYNC_FULL,	/* a dump or a query: everything about it */
};

enum sync_do {
	SYNC_NOTHING,
	SYNC_BIND,	/* hand it to the engine, then sync_bound() */
	SYNC_UNBIND,	/* take it back from the engine */
	SYNC_QUERY,	/* ask conntrack for it, then sync_ct() with SYNC_FULL */
};

/* What the engine said to a bind. */
enum sync_result {
	SYNC_OK,
	SYNC_EXISTS,		/* it already has it */
	SYNC_UNLEARNED,		/* not both directions: tried again later */
	SYNC_NOSPACE,		/* its table is full: tried again later */
	SYNC_REFUSED,		/* anything else: not tried again */
};

struct sync;

struct sync *sync_create(void);
void sync_free(struct sync *s);

/* Forgets every connection: the engine holds none (it was flushed or restarted). */
void sync_reset(struct sync *s);

/* What to do about the connection of a conntrack message received at now. */
enum sync_do sync_ct(struct sync *s, enum sync_msg msg, const struct sync_ct *ct, uint32_t now);

/* What came of the bind sync_ct() or sync_due() asked for. */
void sync_bound(struct sync *s, uint8_t proto, const struct sync_tuple *orig,
		enum sync_result r, uint32_t now);

/* A connection waiting for its bind, or bound. */
struct sync_conn {
	uint8_t proto;
	struct sync_tuple orig, reply;
	int bound;
};

/*
 * Calls fn for each connection whose bind is due again at now; fn binds it
 * and calls sync_bound(). The number of them.
 */
unsigned sync_due(struct sync *s, uint32_t now,
		  void (*fn)(const struct sync_conn *, void *), void *arg);

/* Whether the engine holds the connection as far as this module knows. */
int sync_is_bound(const struct sync *s, uint8_t proto, const struct sync_tuple *orig);

/* Forgets a connection: the engine has it no longer, or conntrack has it no longer. */
void sync_forget(struct sync *s, uint8_t proto, const struct sync_tuple *orig);

/*
 * The engine let go of a bound connection by itself (a flush after a route,
 * a neighbour or a cable changed): it waits for its bind again, the first
 * try SYNC_RETRY_FIRST after now, as a new connection does. sync_unbound_all():
 * every bound connection.
 */
void sync_unbound(struct sync *s, uint8_t proto, const struct sync_tuple *orig, uint32_t now);
void sync_unbound_all(struct sync *s, uint32_t now);

/*
 * The routing changed: the binds that wait are tried again SYNC_RETRY_FIRST
 * after now, however long they had waited, since the way they could not be
 * learned on may be another now. Those refused for good stay so.
 */
void sync_retry_soon(struct sync *s, uint32_t now);

/* Connections known: bound, and waiting for their bind. */
void sync_count(const struct sync *s, unsigned *bound, unsigned *waiting);

/*
 * The timeout in seconds to give in conntrack to a connection whose last
 * packet the engine forwarded idle ms ago, so that conntrack ends it when it
 * has been quiet for as long as the kernel's own timeout of its kind says
 * (timeout: nf_conntrack_tcp_timeout_established for TCP,
 * nf_conntrack_udp_timeout_stream for UDP); at least 1.
 */
uint32_t sync_timeout(uint32_t timeout, uint32_t idle);

#endif
