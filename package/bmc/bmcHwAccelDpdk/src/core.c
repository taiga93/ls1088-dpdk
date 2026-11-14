/*
 * See core.h. The table is an rte_hash read without locks by the workers
 * (RW_CONCURRENCY_LF) and written by the control thread only. Workers send
 * what they learn to the control thread through one ring each; the learned
 * records, the connections and the free lists belong to the control thread.
 * Little-endian only: the checksum deltas are sums of 16-bit words as they
 * lie in memory, and so are the checksums they fix.
 */
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include <rte_ethdev.h>
#include <rte_ether.h>
#include <rte_hash.h>
#include <rte_hash_crc.h>
#include <rte_ip.h>
#include <rte_malloc.h>
#include <rte_prefetch.h>
#include <rte_rcu_qsbr.h>
#include <rte_ring_elem.h>
#include <rte_tcp.h>
#include <rte_udp.h>

#include "core.h"

#define NOT_MAPPED 0xff
#define L2_MAX 26	/* Ethernet, one VLAN tag, PPPoE and PPP */
#define PPPOE_LEN 8	/* the PPPoE session header and PPP's protocol */
#define VLAN_ID 0x0fff
#define PPP_IPV4 0x0021
#define LEARN_RING 4096	/* records a worker can have in flight */
#define NONE UINT32_MAX
/*
 * The VLAN id of the key of a packet decrypted out of a tunnel, whose
 * PPPoE session is the tunnel: 4095, which 802.1Q reserves, so that no
 * frame from a cable has it (parse_l2()).
 */
#define VLAN_TUNNEL VLAN_ID
#define OUT_TUNNEL 0x80	/* action.out: into a tunnel, out of the port of the low bits */
#define OUT_PORT 0x7f

/*
 * The key of a table entry: 16 bytes, so that rte_hash compares it with one
 * vector load (ticket 01). The tuple as the packet comes in; for a packet
 * decrypted out of a tunnel, the port its ESP came in on and VLAN_TUNNEL,
 * with the tunnel in place of the PPPoE session.
 */
struct key {
	uint32_t sip, dip;
	uint16_t sport, dport;
	uint16_t meta;		/* META_UDP | in-port << 12 | VLAN id, 0 without */
	uint16_t pppoe;		/* PPPoE session as on the wire, 0 without */
};

#define META_UDP 0x8000
#define META_PORT_SHIFT 12

/* The port the packets of a key come in on. */
static inline unsigned
key_port(const struct key *k)
{
	return k->meta >> META_PORT_SHIFT & 7;
}

/* 1 + the tunnel the packets of a key are decrypted out of, 0 for none. */
static inline unsigned
key_tunnel(const struct key *k)
{
	return (k->meta & VLAN_ID) == VLAN_TUNNEL ? k->pppoe + 1u : 0;
}

/*
 * The length of their L2 header: neither VLAN 0 nor session 0 is in a key.
 * A packet decrypted out of a tunnel has none.
 */
static inline unsigned
key_l2_len(const struct key *k)
{
	if (key_tunnel(k))
		return 0;
	return RTE_ETHER_HDR_LEN + (k->meta & VLAN_ID ? RTE_VLAN_HLEN : 0) + (k->pppoe ? PPPOE_LEN : 0);
}

/* What the engine does with the packets of a key: one cache line. */
struct action {
	uint64_t bytes;
	uint32_t sip, dip;	/* after NAT */
	uint16_t sport, dport;
	uint16_t ip_delta;	/* ones' complement: addresses and TTL - 1 */
	uint16_t l4_delta;	/* addresses and ports */
	uint32_t last;
	uint32_t pkts;
	uint16_t mtu;		/* largest IPv4 packet out: into a tunnel, the inner one */
	uint8_t out;		/* port, with OUT_TUNNEL into a tunnel (core.tunnel says which) */
	uint8_t l2_in;		/* the length of the L2 header in */
	uint8_t l2_len;
	uint8_t pppoe_len_at;	/* where the PPPoE length is in l2, 0 without */
	uint8_t l2[L2_MAX];	/* the L2 header out: into a tunnel, the outer one */
} __rte_cache_aligned;

_Static_assert(offsetof(struct action, l2) + L2_MAX <= 64, "an action is a cache line of the A53");

/* A tuple as it passes a port in one direction; what is learned of it. */
enum { LEARN_IN, LEARN_OUT };

struct lkey {
	uint32_t sip, dip;
	uint16_t sport, dport;
	uint8_t proto, kind;
	uint16_t zero;
};

/*
 * What a worker tells the control thread: a learned record. l2_len is the
 * length of the L2 header either way; l2 is the header of a packet out,
 * the outer one of a packet into a tunnel.
 */
struct learn_ev {
	struct lkey k;
	uint32_t time;
	uint8_t port, l2_len;
	uint16_t vlan, pppoe;	/* as in the key; 0 0 into a tunnel */
	uint16_t tunnel;	/* 1 + the tunnel it goes into or came out of, 0 for none */
	uint16_t mtu;		/* into a tunnel: the largest inner packet */
	uint8_t l2[L2_MAX];
};

struct learned {
	struct learn_ev ev;
	uint32_t newer, older;	/* the list from the newest to the oldest */
};

/* An accelerated connection: the key of its two entries. */
struct ckey {
	uint32_t sip, dip;
	uint16_t sport, dport;
	uint8_t proto, zero[3];
};

struct conn {
	struct ckey ck;
	struct core_tuple reply;
	struct key key[2];
	struct action *act[2];
	uint16_t into[2];	/* 1 + the tunnel each direction goes into, 0 for none */
	int used;
};

/* An entry deleted from the table, freed once no worker can still see it. */
struct deleted {
	int32_t pos;		/* of its key in the table */
	uint32_t action;
};

#define POISON 0xa5	/* the bytes of a freed action */

struct worker {
	struct rte_ring *learn;
} __rte_cache_aligned;

/* The free slots of an array, as a stack of their indexes. */
struct freelist {
	uint32_t *idx, n;
};

struct core {
	struct core_params p;
	/* side << 7 | port of the packets with that mbuf.port */
	uint8_t from[RTE_MAX_ETHPORTS];
	struct rte_hash *table;
	struct action *actions;
	uint16_t *tunnel;		/* of each action into a tunnel: the tunnel */
	struct freelist free_actions;
	struct rte_hash *conns;
	struct conn *conn;
	struct freelist free_conns;
	struct rte_hash *learns;
	struct learned *learned;
	struct freelist free_learned;
	uint32_t newest, oldest;
	struct rte_rcu_qsbr *rcu;
	struct rte_rcu_qsbr_dq *deleted;
	struct worker worker[CORE_MAX_WORKERS];
};

static unsigned instances;	/* for the names of the DPDK objects */

static struct rte_hash *
hash_create(const char *what, unsigned id, unsigned entries, int lf, int socket_id)
{
	char name[RTE_HASH_NAMESIZE];
	struct rte_hash_parameters hp = {
		.name = name,
		.entries = entries < 8 ? 8 : entries,
		.key_len = 16,
		.hash_func = rte_hash_crc,
		.socket_id = socket_id,
		.extra_flag = lf ? RTE_HASH_EXTRA_FLAGS_RW_CONCURRENCY_LF : 0,
	};

	snprintf(name, sizeof(name), "%s%u", what, id);
	return rte_hash_create(&hp);
}

static void *
zalloc(const char *what, size_t n, size_t size, int socket_id)
{
	return rte_zmalloc_socket(what, n * size, RTE_CACHE_LINE_SIZE, socket_id);
}

static int
freelist_init(struct freelist *f, const char *what, uint32_t n, int socket_id)
{
	uint32_t i;

	f->idx = zalloc(what, n, sizeof(uint32_t), socket_id);
	if (!f->idx)
		return -ENOMEM;
	for (i = 0; i < n; i++)
		f->idx[i] = n - 1 - i;
	f->n = n;
	return 0;
}

static inline uint32_t
freelist_take(struct freelist *f)
{
	return f->idx[--f->n];
}

static inline void
freelist_give(struct freelist *f, uint32_t i)
{
	f->idx[f->n++] = i;
}

static void
entries_free(void *arg, void *e, unsigned n)
{
	struct core *c = arg;
	struct deleted *d = e;
	unsigned i;

	for (i = 0; i < n; i++) {
		rte_hash_free_key_with_position(c->table, d[i].pos);
		memset(&c->actions[d[i].action], POISON, sizeof(struct action));
		freelist_give(&c->free_actions, d[i].action);
	}
}

struct core *
core_create(const struct core_params *p)
{
	unsigned id = __atomic_fetch_add(&instances, 1, __ATOMIC_RELAXED), i;
	unsigned nentries = 2 * p->max_conns;
	struct core *c;

	if (p->nports == 0 || p->nports > CORE_MAX_PORTS || p->nworkers == 0 ||
	    p->nworkers > CORE_MAX_WORKERS || p->max_conns == 0 || p->learn_max == 0)
		return NULL;
	c = zalloc("core", 1, sizeof(*c), p->socket_id);
	if (!c)
		return NULL;
	c->p = *p;
	memset(c->from, NOT_MAPPED, sizeof(c->from));
	/* at most half full: cuckoo insertion then hardly ever fails (ticket 01) */
	c->table = hash_create("tbl", id, 2 * nentries, 1, p->socket_id);
	c->actions = zalloc("actions", nentries, sizeof(struct action), p->socket_id);
	c->tunnel = zalloc("act_tunnel", nentries, sizeof(uint16_t), p->socket_id);
	c->conns = hash_create("conn", id, 2 * p->max_conns, 0, p->socket_id);
	c->conn = zalloc("conn", p->max_conns, sizeof(struct conn), p->socket_id);
	c->learns = hash_create("lrn", id, 2 * p->learn_max, 0, p->socket_id);
	c->learned = zalloc("learned", p->learn_max, sizeof(struct learned), p->socket_id);
	if (!c->table || !c->actions || !c->tunnel || !c->conns || !c->conn || !c->learns || !c->learned ||
	    freelist_init(&c->free_actions, "free_actions", nentries, p->socket_id) ||
	    freelist_init(&c->free_conns, "free_conns", p->max_conns, p->socket_id) ||
	    freelist_init(&c->free_learned, "free_learned", p->learn_max, p->socket_id))
		goto fail;
	c->newest = c->oldest = NONE;
	c->rcu = zalloc("rcu", 1, rte_rcu_qsbr_get_memsize(p->nworkers), p->socket_id);
	if (!c->rcu || rte_rcu_qsbr_init(c->rcu, p->nworkers))
		goto fail;
	{
		char name[RTE_RING_NAMESIZE];
		struct rte_rcu_qsbr_dq_parameters dp = {
			.name = name,
			.flags = RTE_RCU_QSBR_DQ_MT_UNSAFE,
			.size = nentries,
			.esize = sizeof(struct deleted),
			.trigger_reclaim_limit = 32,
			.max_reclaim_size = 256,
			.free_fn = entries_free,
			.p = c,
			.v = c->rcu,
		};

		snprintf(name, sizeof(name), "del%u", id);
		c->deleted = rte_rcu_qsbr_dq_create(&dp);
		if (!c->deleted)
			goto fail;
	}
	for (i = 0; i < p->nworkers; i++) {
		char name[RTE_RING_NAMESIZE];

		snprintf(name, sizeof(name), "learn%u.%u", id, i);
		c->worker[i].learn = rte_ring_create_elem(name, sizeof(struct learn_ev), LEARN_RING,
							  p->socket_id, RING_F_SP_ENQ | RING_F_SC_DEQ);
		if (!c->worker[i].learn)
			goto fail;
	}
	return c;
fail:
	core_free(c);
	return NULL;
}

void
core_free(struct core *c)
{
	unsigned i;

	if (!c)
		return;
	if (c->deleted)
		rte_rcu_qsbr_dq_delete(c->deleted);
	rte_free(c->rcu);
	for (i = 0; i < CORE_MAX_WORKERS; i++)
		rte_ring_free(c->worker[i].learn);
	rte_hash_free(c->table);
	rte_hash_free(c->conns);
	rte_hash_free(c->learns);
	rte_free(c->actions);
	rte_free(c->tunnel);
	rte_free(c->free_actions.idx);
	rte_free(c->conn);
	rte_free(c->free_conns.idx);
	rte_free(c->learned);
	rte_free(c->free_learned.idx);
	rte_free(c);
}

int
core_map_ethdev(struct core *c, uint16_t ethdev, unsigned port, int side)
{
	if (ethdev >= RTE_MAX_ETHPORTS || port >= c->p.nports)
		return -EINVAL;
	c->from[ethdev] = (uint8_t)(side << 7 | port);
	return 0;
}

/* Workers. */

enum { PARSE_NO, PARSE_LEARN, PARSE_LOOKUP };

/*
 * The L2 header of a frame that is not plain IPv4 on Ethernet: one 802.1Q
 * tag, a PPPoE session header with PPP's IPv4 that carries all of the IPv4
 * packet, or both in that order. Its length, with the VLAN id and the
 * session of the key; 0 for anything else, and for VLAN 0 (a priority tag)
 * and session 0, whose keys would be those of a frame without them.
 */
static unsigned
parse_l2(const uint8_t *f, uint16_t *vlan, uint16_t *pppoe)
{
	unsigned l2 = RTE_ETHER_HDR_LEN;
	uint16_t type, w, iplen;

	memcpy(&type, f + 12, 2);
	if (type == rte_cpu_to_be_16(RTE_ETHER_TYPE_VLAN)) {
		memcpy(&w, f + 14, 2);
		*vlan = rte_be_to_cpu_16(w) & VLAN_ID;
		memcpy(&type, f + 16, 2);
		l2 += RTE_VLAN_HLEN;
		if (!*vlan || *vlan == VLAN_TUNNEL)
			return 0;
		if (type == rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4))
			return l2;
	}
	if (type != rte_cpu_to_be_16(RTE_ETHER_TYPE_PPPOE_SESSION))
		return 0;
	f += l2;
	memcpy(pppoe, f + 2, 2);
	/* version 1, type 1, code 0 (session data); PPP's protocol IPv4 */
	if (f[0] != 0x11 || f[1] || !*pppoe || f[6] != PPP_IPV4 >> 8 || f[7] != (PPP_IPV4 & 0xff))
		return 0;
	/* the PPPoE length against the length of the IPv4 packet */
	memcpy(&w, f + 4, 2);
	memcpy(&iplen, f + PPPOE_LEN + 2, 2);
	if (rte_be_to_cpu_16(w) != rte_be_to_cpu_16(iplen) + 2)
		return 0;
	return l2 + PPPOE_LEN;
}

/*
 * The IPv4 packet at ip, l2 bytes into m, for parse(); no is non-zero when
 * its L2 header already failed, meta and pppoe go into its key.
 */
static inline __attribute__((always_inline)) int
parse_ip(const struct rte_mbuf *m, const struct rte_ipv4_hdr *ip, unsigned l2, uint64_t no,
	 uint16_t meta, uint16_t pppoe, struct key *k)
{
	const uint8_t *l4 = (const uint8_t *)(ip + 1);
	unsigned len = rte_be_to_cpu_16(ip->total_length);
	unsigned tcp = ip->next_proto_id == IPPROTO_TCP, udp = ip->next_proto_id == IPPROTO_UDP;

	/*
	 * Every test at once, then one branch: on the in-order A53 a branch
	 * after each load would wait for that load (ticket 07).
	 */
	no |= (m->ol_flags & (RTE_MBUF_F_RX_IP_CKSUM_BAD | RTE_MBUF_F_RX_L4_CKSUM_BAD)) |
	     (uint64_t)(m->nb_segs != 1) |
	     (uint64_t)(ip->version_ihl != RTE_IPV4_VHL_DEF) |
	     (uint64_t)(ip->fragment_offset &
			rte_cpu_to_be_16(RTE_IPV4_HDR_MF_FLAG | RTE_IPV4_HDR_OFFSET_MASK)) |
	     (uint64_t)(ip->time_to_live <= 1) |
	     (uint64_t)(l2 + len > m->data_len) |
	     /* multicast, broadcast and reserved: 224.0.0.0 and up */
	     (uint64_t)(((const uint8_t *)&ip->dst_addr)[0] >= 224) |
	     (uint64_t)!(tcp | udp) |
	     (uint64_t)(len < sizeof(*ip) + (tcp ? sizeof(struct rte_tcp_hdr) :
					     sizeof(struct rte_udp_hdr)));
	if (unlikely(no))
		return PARSE_NO;
	k->sip = ip->src_addr;
	k->dip = ip->dst_addr;
	memcpy(&k->sport, l4, 4);
	k->meta = (uint16_t)((udp ? META_UDP : 0) | meta);
	k->pppoe = pppoe;
	return tcp && (((const struct rte_tcp_hdr *)l4)->tcp_flags &
		       (RTE_TCP_SYN_FLAG | RTE_TCP_FIN_FLAG | RTE_TCP_RST_FLAG)) ?
	       PARSE_LEARN : PARSE_LOOKUP;
}

/*
 * An IPv4 TCP or UDP packet to a unicast address, whole, in one segment,
 * without options, not a fragment, with a TTL above 1, which the hardware
 * did not find broken, on Ethernet, a VLAN or PPPoE: its key, and
 * PARSE_LOOKUP when it may belong to an accelerated connection or
 * PARSE_LEARN when the kernel must see it anyway (SYN, FIN, RST). PARSE_NO
 * for anything else. The reads past a short frame stay in its mbuf.
 */
static inline int
parse(const struct rte_mbuf *m, unsigned port, struct key *k)
{
	const struct rte_ether_hdr *eh = rte_pktmbuf_mtod(m, const struct rte_ether_hdr *);
	unsigned l2 = RTE_ETHER_HDR_LEN;
	uint16_t vlan = 0, pppoe = 0;

	/* plain Ethernet is the way of nearly every packet */
	if (unlikely(eh->ether_type != rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4))) {
		l2 = parse_l2((const uint8_t *)eh, &vlan, &pppoe);
		if (!l2)
			return PARSE_NO;
	}
	return parse_ip(m, (const struct rte_ipv4_hdr *)((const uint8_t *)eh + l2), l2,
			(uint64_t)(eh->dst_addr.addr_bytes[0] & 1),	/* multicast, broadcast */
			(uint16_t)(port << META_PORT_SHIFT | vlan), pppoe, k);
}

/* A packet decrypted out of tunnel, from its IPv4 header, its ESP in on port: as parse(). */
static inline int
parse_tunnel(const struct rte_mbuf *m, unsigned port, uint16_t tunnel, struct key *k)
{
	return parse_ip(m, rte_pktmbuf_mtod(m, const struct rte_ipv4_hdr *), 0, 0,
			(uint16_t)(port << META_PORT_SHIFT | VLAN_TUNNEL), tunnel, k);
}

static inline void
csum_fix(uint16_t *c, uint16_t d)
{
	uint32_t s = (uint16_t)~*c + (uint32_t)d;

	s = (s & 0xffff) + (s >> 16);
	*c = (uint16_t)~s;
}

/*
 * The L2 header out of a packet that did not come in plain Ethernet or
 * does not go out so: the frame starts l2_len bytes before the IPv4 header
 * and ends with the IPv4 packet, without the padding of a short frame,
 * which a longer header would carry out and a PPPoE length would not count.
 */
static void
l2_rewrite(struct rte_mbuf *m, const struct action *a, const struct rte_ipv4_hdr *ip)
{
	uint16_t len = rte_be_to_cpu_16(ip->total_length), w;
	uint8_t *f = (uint8_t *)(uintptr_t)ip - a->l2_len;

	m->data_off = (uint16_t)(m->data_off + a->l2_in - a->l2_len);
	m->data_len = (uint16_t)(a->l2_len + len);
	m->pkt_len = m->data_len;
	memcpy(f, a->l2, a->l2_len);
	if (a->pppoe_len_at) {
		w = rte_cpu_to_be_16((uint16_t)(len + 2));
		memcpy(f + a->pppoe_len_at, &w, 2);
	}
}

unsigned
core_l2_len(const struct rte_mbuf *m)
{
	const struct rte_ether_hdr *eh = rte_pktmbuf_mtod(m, const struct rte_ether_hdr *);
	uint16_t vlan = 0, pppoe = 0;

	if (m->data_len < RTE_ETHER_HDR_LEN + L2_MAX)
		return eh->ether_type == rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4) &&
		       m->data_len >= RTE_ETHER_HDR_LEN ? RTE_ETHER_HDR_LEN : 0;
	if (eh->ether_type == rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4))
		return RTE_ETHER_HDR_LEN;
	return parse_l2((const uint8_t *)eh, &vlan, &pppoe);
}

struct rte_rcu_qsbr *
core_rcu(const struct core *c)
{
	return c->rcu;
}

/* Rewrite a packet of an accelerated connection. */
static inline void
apply(struct rte_mbuf *m, struct action *a, uint32_t now)
{
	uint8_t *f = rte_pktmbuf_mtod(m, uint8_t *);
	struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(f + a->l2_in);
	uint8_t *l4 = (uint8_t *)(ip + 1);

	ip->src_addr = a->sip;
	ip->dst_addr = a->dip;
	ip->time_to_live--;
	csum_fix(&ip->hdr_checksum, a->ip_delta);
	memcpy(l4, &a->sport, 4);
	if (ip->next_proto_id == IPPROTO_TCP) {
		csum_fix(&((struct rte_tcp_hdr *)l4)->cksum, a->l4_delta);
	} else {
		uint16_t *c = &((struct rte_udp_hdr *)l4)->dgram_cksum;

		if (*c) {
			csum_fix(c, a->l4_delta);
			if (!*c)
				*c = 0xffff;
		}
	}
	a->pkts++;
	a->bytes += m->pkt_len;
	a->last = now;
	if (likely(a->l2_in == RTE_ETHER_HDR_LEN && a->l2_len == RTE_ETHER_HDR_LEN))
		memcpy(f, a->l2, RTE_ETHER_HDR_LEN);
	else
		l2_rewrite(m, a, ip);
}

static inline void
put(struct core_out *out, unsigned port, int side, struct rte_mbuf *m)
{
	out->pkts[port][side][out->n[port][side]++] = m;
}

/*
 * A packet of the entry of action a: rewritten, out of the port of a or
 * into its tunnel. 0, left as it is, when it is too long for the way out
 * or a longer header out has no room in front of the frame. The frame is
 * counted with its padding: only small frames are padded, and those never
 * come near the MTU.
 */
static inline int
forward(struct core *c, struct rte_mbuf *m, struct action *a, uint32_t now, struct core_out *out)
{
	if (unlikely(m->pkt_len - a->l2_in > a->mtu || a->l2_len > a->l2_in + m->data_off))
		return 0;
	apply(m, a, now);
	if (likely(!(a->out & OUT_TUNNEL))) {
		put(out, a->out, CORE_WIRE, m);
		return 1;
	}
	m->l2_len = a->l2_len;
	out->tun[out->ntun++] = (struct core_tun){ .m = m, .tunnel = c->tunnel[a - c->actions],
						   .port = (uint8_t)(a->out & OUT_PORT) };
	return 1;
}

static inline void
learn(struct learn_ev *ev, const struct key *k, int kind, uint32_t now, const struct rte_mbuf *m)
{
	ev->k.sip = k->sip;
	ev->k.dip = k->dip;
	ev->k.sport = k->sport;
	ev->k.dport = k->dport;
	ev->k.proto = k->meta & META_UDP ? IPPROTO_UDP : IPPROTO_TCP;
	ev->k.kind = (uint8_t)kind;
	ev->k.zero = 0;
	ev->time = now;
	ev->port = (uint8_t)key_port(k);
	ev->l2_len = (uint8_t)key_l2_len(k);
	ev->vlan = k->meta & VLAN_ID;
	ev->pppoe = k->pppoe;
	ev->tunnel = (uint16_t)key_tunnel(k);
	ev->mtu = 0;
	/* past a shorter header, bytes of the packet nothing reads */
	if (kind == LEARN_OUT)
		memcpy(ev->l2, rte_pktmbuf_mtod(m, void *), L2_MAX);
}

void
core_rx(struct core *c, unsigned worker, struct rte_mbuf **pkts, unsigned n,
	uint32_t now, struct core_out *out)
{
	struct key keys[CORE_BURST];
	const void *kp[CORE_BURST];
	void *data[CORE_BURST];
	uint8_t at[CORE_BURST];		/* the packet of each key */
	uint8_t in[CORE_BURST];		/* the port each packet came in on */
	struct learn_ev ev[CORE_BURST];
	uint64_t hits = 0, up = 0;	/* up: the packets for the kernel */
	unsigned i, nk = 0, nev = 0;

	memset(out->n, 0, sizeof(out->n));
	out->ntun = 0;
	for (i = 0; i < n; i++)
		rte_prefetch0(rte_pktmbuf_mtod(pkts[i], void *));
	for (i = 0; i < n; i++) {
		struct rte_mbuf *m = pkts[i];
		/* RTE_MBUF_PORT_INVALID and the like too: no read past the map */
		uint8_t from = likely(m->port < RTE_MAX_ETHPORTS) ? c->from[m->port] : NOT_MAPPED;
		unsigned port = from & 0x7f;
		struct key *k = &keys[nk];
		int r;

		/* NOT_MAPPED has the bit of the kernel side: no test on the way of the cable */
		if (from >> 7 == CORE_KERNEL) {
			if (unlikely(from == NOT_MAPPED)) {
				/* an ethdev core_map_ethdev() did not name: nowhere to go */
				rte_pktmbuf_free(m);
				continue;
			}
			if (parse(m, port, k) != PARSE_NO)
				learn(&ev[nev++], k, LEARN_OUT, now, m);
			put(out, port, CORE_WIRE, m);
			continue;
		}
		r = parse(m, port, k);
		in[i] = (uint8_t)port;
		if (r == PARSE_LOOKUP) {
			kp[nk] = k;
			at[nk++] = (uint8_t)i;
			continue;
		}
		if (r == PARSE_LEARN)
			learn(&ev[nev++], k, LEARN_IN, now, m);
		up |= 1ULL << i;
	}
	if (nk)
		rte_hash_lookup_bulk_data(c->table, kp, nk, &hits, data);
	for (i = 0; i < nk; i++)
		if (hits >> i & 1)
			rte_prefetch0(data[i]);
	for (i = 0; i < nk; i++) {
		struct rte_mbuf *m = pkts[at[i]];
		struct action *a = data[i];

		if (!(hits >> i & 1)) {
			learn(&ev[nev++], &keys[i], LEARN_IN, now, m);
			up |= 1ULL << at[i];
			continue;
		}
		if (unlikely(!forward(c, m, a, now, out)))
			up |= 1ULL << at[i];
	}
	/* in the order they came: the kernel sees the packets of a flow in order */
	while (up) {
		i = (unsigned)__builtin_ctzll(up);
		up &= up - 1;
		put(out, in[i], CORE_KERNEL, pkts[i]);
	}
	if (nev)
		rte_ring_enqueue_burst_elem(c->worker[worker].learn, ev, sizeof(ev[0]), nev, NULL);
}

uint64_t
core_rx_tunnel(struct core *c, unsigned worker, struct rte_mbuf **pkts, const uint16_t *tunnel,
	       const uint8_t *port, unsigned n, uint32_t now, struct core_out *out)
{
	struct key keys[CORE_BURST];
	const void *kp[CORE_BURST];
	void *data[CORE_BURST];
	uint8_t at[CORE_BURST];		/* the packet of each key */
	struct learn_ev ev[CORE_BURST];
	uint64_t hits = 0, up = 0;
	unsigned i, nk = 0, nev = 0;

	memset(out->n, 0, sizeof(out->n));
	out->ntun = 0;
	for (i = 0; i < n; i++) {
		struct key *k = &keys[nk];
		int r = parse_tunnel(pkts[i], port[i], tunnel[i], k);

		if (r == PARSE_LOOKUP) {
			kp[nk] = k;
			at[nk++] = (uint8_t)i;
			continue;
		}
		if (r == PARSE_LEARN)
			learn(&ev[nev++], k, LEARN_IN, now, pkts[i]);
		up |= 1ULL << i;
	}
	if (nk)
		rte_hash_lookup_bulk_data(c->table, kp, nk, &hits, data);
	for (i = 0; i < nk; i++) {
		struct rte_mbuf *m = pkts[at[i]];

		/* another tunnel's entry has another key: it is not found */
		if (!(hits >> i & 1)) {
			learn(&ev[nev++], &keys[i], LEARN_IN, now, m);
			up |= 1ULL << at[i];
			continue;
		}
		if (!forward(c, m, data[i], now, out))
			up |= 1ULL << at[i];
	}
	if (nev)
		rte_ring_enqueue_burst_elem(c->worker[worker].learn, ev, sizeof(ev[0]), nev, NULL);
	return up;
}

void
core_learn_tunnel(struct core *c, unsigned worker, const struct rte_mbuf *m, unsigned port,
		  const uint8_t *l2, unsigned l2_len, uint16_t tunnel, uint16_t mtu, uint32_t now)
{
	struct learn_ev ev;
	struct key k;

	if (port >= c->p.nports || l2_len > L2_MAX || parse_tunnel(m, 0, 0, &k) == PARSE_NO)
		return;
	ev = (struct learn_ev){
		.k = { .sip = k.sip, .dip = k.dip, .sport = k.sport, .dport = k.dport,
		       .proto = k.meta & META_UDP ? IPPROTO_UDP : IPPROTO_TCP, .kind = LEARN_OUT },
		.time = now,
		.port = (uint8_t)port,
		.l2_len = (uint8_t)l2_len,
		.tunnel = (uint16_t)(tunnel + 1),
		.mtu = mtu,
	};
	memcpy(ev.l2, l2, l2_len);
	rte_ring_enqueue_elem(c->worker[worker].learn, &ev, sizeof(ev));
}

void
core_worker_start(struct core *c, unsigned worker)
{
	rte_rcu_qsbr_thread_register(c->rcu, worker);
	rte_rcu_qsbr_thread_online(c->rcu, worker);
}

void
core_worker_quiescent(struct core *c, unsigned worker)
{
	rte_rcu_qsbr_quiescent(c->rcu, worker);
}

void
core_worker_offline(struct core *c, unsigned worker)
{
	rte_rcu_qsbr_thread_offline(c->rcu, worker);
}

void
core_worker_online(struct core *c, unsigned worker)
{
	rte_rcu_qsbr_thread_online(c->rcu, worker);
}

void
core_worker_stop(struct core *c, unsigned worker)
{
	rte_rcu_qsbr_thread_offline(c->rcu, worker);
	rte_rcu_qsbr_thread_unregister(c->rcu, worker);
}

/* The control thread: what was learned. */

static int
expired(const struct core *c, const struct learned *l, uint32_t now)
{
	return (uint32_t)(now - l->ev.time) > c->p.learn_ttl;
}

static void
learned_unlink(struct core *c, uint32_t i)
{
	struct learned *l = &c->learned[i];

	if (l->newer != NONE)
		c->learned[l->newer].older = l->older;
	else
		c->newest = l->older;
	if (l->older != NONE)
		c->learned[l->older].newer = l->newer;
	else
		c->oldest = l->newer;
}

static void
learned_link_newest(struct core *c, uint32_t i)
{
	struct learned *l = &c->learned[i];

	l->older = c->newest;
	l->newer = NONE;
	if (c->newest != NONE)
		c->learned[c->newest].newer = i;
	else
		c->oldest = i;
	c->newest = i;
}

static void
learned_del(struct core *c, uint32_t i)
{
	learned_unlink(c, i);
	rte_hash_del_key(c->learns, &c->learned[i].ev.k);
	freelist_give(&c->free_learned, i);
}

/* The record of k, if it is still usable at now. */
static const struct learned *
learned_get(struct core *c, const struct lkey *k, uint32_t now)
{
	void *data;

	if (rte_hash_lookup_data(c->learns, k, &data) < 0)
		return NULL;
	if (expired(c, data, now)) {
		learned_del(c, (uint32_t)((struct learned *)data - c->learned));
		return NULL;
	}
	return data;
}

/* A record from a worker: new, or newer than the one there. */
static void
learned_put(struct core *c, const struct learn_ev *ev)
{
	struct learned *l;
	void *data;
	uint32_t i;

	if (rte_hash_lookup_data(c->learns, &ev->k, &data) >= 0) {
		l = data;
		i = (uint32_t)(l - c->learned);
		learned_unlink(c, i);
	} else {
		if (!c->free_learned.n)
			learned_del(c, c->oldest);
		i = freelist_take(&c->free_learned);
		l = &c->learned[i];
		l->ev.k = ev->k;
		if (rte_hash_add_key_data(c->learns, &l->ev.k, l) < 0) {
			freelist_give(&c->free_learned, i);
			return;
		}
	}
	l->ev = *ev;
	learned_link_newest(c, i);
}

static void
learn_drain(struct core *c)
{
	struct learn_ev ev[64];
	unsigned w, n, i;

	for (w = 0; w < c->p.nworkers; w++)
		while ((n = rte_ring_dequeue_burst_elem(c->worker[w].learn, ev, sizeof(ev[0]),
							RTE_DIM(ev), NULL)) > 0)
			for (i = 0; i < n; i++)
				learned_put(c, &ev[i]);
}

static void
learned_forget(struct core *c, const struct lkey *k)
{
	void *data;

	if (rte_hash_lookup_data(c->learns, k, &data) >= 0)
		learned_del(c, (uint32_t)((struct learned *)data - c->learned));
}

void
core_poll(struct core *c, uint32_t now)
{
	learn_drain(c);
	while (c->oldest != NONE && expired(c, &c->learned[c->oldest], now))
		learned_del(c, c->oldest);
	rte_rcu_qsbr_dq_reclaim(c->deleted, UINT32_MAX, NULL, NULL, NULL);
}

/* The control thread: connections. */

static uint16_t
fold(uint32_t s)
{
	s = (s & 0xffff) + (s >> 16);
	s = (s & 0xffff) + (s >> 16);
	return (uint16_t)s;
}

/* Sum of ~old + new over the 16-bit words of n bytes, as they lie in memory. */
static uint32_t
delta(const void *old, const void *new, unsigned n)
{
	const uint8_t *a = old, *b = new;
	uint32_t s = 0;
	uint16_t x, y;
	unsigned j;

	for (j = 0; j < n; j += 2) {
		memcpy(&x, a + j, 2);
		memcpy(&y, b + j, 2);
		s += (uint16_t)~x + y;
	}
	return s;
}

static struct lkey
lkey_of(uint8_t proto, uint32_t sip, uint16_t sport, uint32_t dip, uint16_t dport, int kind)
{
	return (struct lkey){ .sip = sip, .dip = dip, .sport = sport, .dport = dport,
			      .proto = proto, .kind = (uint8_t)kind };
}

/*
 * The four records a connection is bound with, in the order of the
 * CORE_MISS_* bits: the original direction coming in, then going out after
 * NAT (the reverse of the reply tuple), the reply coming in, then going out.
 */
static void
conn_lkeys(uint8_t proto, const struct core_tuple *o, const struct core_tuple *r,
	   struct lkey k[4])
{
	k[0] = lkey_of(proto, o->sip, o->sport, o->dip, o->dport, LEARN_IN);
	k[1] = lkey_of(proto, r->dip, r->dport, r->sip, r->sport, LEARN_OUT);
	k[2] = lkey_of(proto, r->sip, r->sport, r->dip, r->dport, LEARN_IN);
	k[3] = lkey_of(proto, o->dip, o->dport, o->sip, o->sport, LEARN_OUT);
}

static struct ckey
ckey_of(uint8_t proto, const struct core_tuple *orig)
{
	return (struct ckey){ orig->sip, orig->dip, orig->sport, orig->dport, proto, { 0 } };
}

/*
 * The entry of one direction: packets of tuple t in from in, rewritten into
 * tuple to, out as out says.
 */
static void
entry_make(struct core *c, uint8_t proto, const struct core_tuple *t, const struct learned *in,
	   const struct core_tuple *to, const struct learned *out, struct key *k, struct action *a)
{
	/* the word TTL | protocol as it lies in memory loses 1 in its first byte */
	uint16_t ttl = (uint16_t)~rte_cpu_to_be_16(0x0100);
	uint32_t addr = delta(&t->sip, &to->sip, 8);

	memset(k, 0, sizeof(*k));
	k->sip = t->sip;
	k->dip = t->dip;
	k->sport = t->sport;
	k->dport = t->dport;
	k->meta = (uint16_t)((proto == IPPROTO_UDP ? META_UDP : 0) | in->ev.port << META_PORT_SHIFT |
			     in->ev.vlan);
	k->pppoe = in->ev.pppoe;
	memset(a, 0, sizeof(*a));
	a->sip = to->sip;
	a->dip = to->dip;
	a->sport = to->sport;
	a->dport = to->dport;
	a->ip_delta = fold(addr + ttl);
	a->l4_delta = fold(addr + delta(&t->sport, &to->sport, 4));
	a->out = out->ev.port;
	/* the MTU of pppoe-wan is that of its port less the PPPoE header */
	a->mtu = (uint16_t)(c->p.mtu[out->ev.port] - (out->ev.pppoe ? PPPOE_LEN : 0));
	a->l2_in = in->ev.l2_len;
	a->l2_len = out->ev.l2_len;
	/* the PPPoE length is the word before PPP's protocol */
	a->pppoe_len_at = (uint8_t)(out->ev.pppoe ? out->ev.l2_len - 4 : 0);
	memcpy(a->l2, out->ev.l2, sizeof(a->l2));
	/* ipsec.c sets the PPPoE length of the outer header, once encrypted */
	if (out->ev.tunnel) {
		a->out |= OUT_TUNNEL;
		a->mtu = out->ev.mtu;
		a->pppoe_len_at = 0;
	}
}

static void
action_free(struct core *c, struct action *a)
{
	freelist_give(&c->free_actions, (uint32_t)(a - c->actions));
}

/* Delete an entry; its key and action are freed once no worker can see them. */
static void
entry_del(struct core *c, const struct key *k, struct action *a)
{
	struct deleted e = {
		.pos = rte_hash_del_key(c->table, k),
		.action = (uint32_t)(a - c->actions),
	};

	if (rte_rcu_qsbr_dq_enqueue(c->deleted, &e)) {
		rte_rcu_qsbr_synchronize(c->rcu, RTE_QSBR_THRID_INVALID);
		entries_free(c, &e, 1);
	}
}

int
core_bind(struct core *c, uint8_t proto, const struct core_tuple *orig,
	  const struct core_tuple *reply, uint32_t now, unsigned *missing)
{
	const struct core_tuple *o = orig, *r = reply;
	struct lkey lk[4];
	const struct learned *l[4];
	/* the tuples the packets of each direction are rewritten into */
	struct core_tuple o_to = { r->dip, r->sip, r->dport, r->sport };
	struct core_tuple r_to = { o->dip, o->sip, o->dport, o->sport };
	struct ckey ck = ckey_of(proto, o);
	struct key k[2];
	struct action a[2];
	struct conn *cn;
	uint32_t ci;
	int d;

	*missing = 0;
	if (proto != IPPROTO_TCP && proto != IPPROTO_UDP)
		return -EINVAL;
	core_poll(c, now);
	conn_lkeys(proto, o, r, lk);
	for (d = 0; d < 4; d++) {
		l[d] = learned_get(c, &lk[d], now);
		if (!l[d])
			*missing |= 1u << d;
	}
	/*
	 * Each direction comes in from the tunnel the other one goes into, or
	 * neither does: the kernel chose the way into a tunnel, but a packet
	 * decrypted out of another one with the same tuple is learned before
	 * the kernel checks its policy. Until its own comes, it is not learned.
	 */
	if (!*missing && l[2]->ev.tunnel != l[1]->ev.tunnel)
		*missing |= CORE_MISS_REPLY_IN;
	if (!*missing && l[0]->ev.tunnel != l[3]->ev.tunnel)
		*missing |= CORE_MISS_ORIG_IN;
	if (*missing)
		return -ENOENT;
	if (rte_hash_lookup(c->conns, &ck) >= 0)
		return -EEXIST;
	entry_make(c, proto, o, l[0], &o_to, l[1], &k[0], &a[0]);
	entry_make(c, proto, r, l[2], &r_to, l[3], &k[1], &a[1]);
	/* conntrack never has one tuple twice; an entry is never taken over */
	if (rte_hash_lookup(c->table, &k[0]) >= 0 || rte_hash_lookup(c->table, &k[1]) >= 0 ||
	    !memcmp(&k[0], &k[1], sizeof(k[0])))
		return -EEXIST;
	if (c->free_actions.n < 2) {
		/* the entries deleted last may still be seen by a worker */
		rte_rcu_qsbr_synchronize(c->rcu, RTE_QSBR_THRID_INVALID);
		rte_rcu_qsbr_dq_reclaim(c->deleted, UINT32_MAX, NULL, NULL, NULL);
	}
	if (!c->free_conns.n || c->free_actions.n < 2)
		return -ENOSPC;
	ci = freelist_take(&c->free_conns);
	cn = &c->conn[ci];
	cn->ck = ck;
	cn->reply = *r;
	for (d = 0; d < 2; d++) {
		/* the record of the way out of each direction */
		const struct learned *out = l[2 * d + 1];

		cn->key[d] = k[d];
		cn->act[d] = &c->actions[freelist_take(&c->free_actions)];
		*cn->act[d] = a[d];
		cn->into[d] = out->ev.tunnel;
		if (out->ev.tunnel)
			c->tunnel[cn->act[d] - c->actions] = (uint16_t)(out->ev.tunnel - 1);
	}
	/* hardly ever full at half load; then a worker may see the first entry already */
	if (rte_hash_add_key_data(c->table, &cn->key[0], cn->act[0]) < 0) {
		action_free(c, cn->act[0]);
		action_free(c, cn->act[1]);
		goto full;
	}
	if (rte_hash_add_key_data(c->table, &cn->key[1], cn->act[1]) < 0) {
		entry_del(c, &cn->key[0], cn->act[0]);
		action_free(c, cn->act[1]);
		goto full;
	}
	if (rte_hash_add_key_data(c->conns, &ck, cn) < 0) {
		entry_del(c, &cn->key[0], cn->act[0]);
		entry_del(c, &cn->key[1], cn->act[1]);
		goto full;
	}
	cn->used = 1;
	return 0;
full:
	freelist_give(&c->free_conns, ci);
	return -ENOSPC;
}

unsigned
core_count(const struct core *c)
{
	return c->p.max_conns - c->free_conns.n;
}

static void
conn_info(const struct conn *cn, struct core_conn *info)
{
	int d;

	info->proto = cn->ck.proto;
	info->orig = (struct core_tuple){ cn->ck.sip, cn->ck.dip, cn->ck.sport, cn->ck.dport };
	info->reply = cn->reply;
	for (d = 0; d < 2; d++) {
		const struct action *a = cn->act[d];

		info->in[d] = (uint8_t)key_port(&cn->key[d]);
		info->out[d] = a->out & OUT_PORT;
		info->pkts[d] = a->pkts;
		info->bytes[d] = a->bytes;
		info->last[d] = a->last;
	}
}

int
core_conn_get(struct core *c, uint8_t proto, const struct core_tuple *orig,
	      struct core_conn *info)
{
	struct ckey ck = ckey_of(proto, orig);
	void *data;

	if (rte_hash_lookup_data(c->conns, &ck, &data) < 0)
		return -ENOENT;
	conn_info(data, info);
	return 0;
}

/* The four records core_bind() used for the connection. */
static void
conn_forget(struct core *c, const struct conn *cn)
{
	struct core_tuple o = { cn->ck.sip, cn->ck.dip, cn->ck.sport, cn->ck.dport };
	struct lkey k[4];
	unsigned i;

	conn_lkeys(cn->ck.proto, &o, &cn->reply, k);
	for (i = 0; i < RTE_DIM(k); i++)
		learned_forget(c, &k[i]);
}

static void
conn_del(struct core *c, struct conn *cn)
{
	entry_del(c, &cn->key[0], cn->act[0]);
	entry_del(c, &cn->key[1], cn->act[1]);
	rte_hash_del_key(c->conns, &cn->ck);
	cn->used = 0;
	freelist_give(&c->free_conns, (uint32_t)(cn - c->conn));
}

int
core_unbind(struct core *c, uint8_t proto, const struct core_tuple *orig, uint32_t now)
{
	struct ckey ck = ckey_of(proto, orig);
	void *data;

	/* first what the workers learned while it was bound, then forget it */
	core_poll(c, now);
	if (rte_hash_lookup_data(c->conns, &ck, &data) < 0)
		return -ENOENT;
	conn_forget(c, data);
	conn_del(c, data);
	return 0;
}

unsigned
core_flush(struct core *c, uint32_t now)
{
	unsigned i, n = 0;

	core_poll(c, now);
	for (i = 0; i < c->p.max_conns; i++)
		if (c->conn[i].used) {
			conn_del(c, &c->conn[i]);
			n++;
		}
	while (c->oldest != NONE)
		learned_del(c, c->oldest);
	return n;
}

/* Which connections and learned records a flush lets go of. */
struct flush_what {
	int (*conn)(const struct conn *cn, const struct flush_what *w);
	int (*learned)(const struct learned *l, const struct flush_what *w);
	unsigned port;
	uint32_t dst, mask;
	uint8_t mac[6];
	unsigned tunnel;	/* 1 + */
};

static void conn_info(const struct conn *cn, struct core_conn *info);

static unsigned
flush_where(struct core *c, const struct flush_what *w, uint32_t now, core_flushed_fn *fn,
	    void *arg)
{
	struct core_conn info;
	unsigned i, n = 0;
	uint32_t l, next;

	core_poll(c, now);
	for (i = 0; i < c->p.max_conns; i++) {
		struct conn *cn = &c->conn[i];

		if (!cn->used || !w->conn(cn, w))
			continue;
		if (fn)
			conn_info(cn, &info);
		conn_del(c, cn);
		n++;
		if (fn)
			fn(&info, arg);
	}
	/* from the oldest record to the newest */
	for (l = c->oldest; l != NONE; l = next) {
		next = c->learned[l].newer;
		if (w->learned(&c->learned[l], w))
			learned_del(c, l);
	}
	return n;
}

static int
port_conn(const struct conn *cn, const struct flush_what *w)
{
	return key_port(&cn->key[0]) == w->port || key_port(&cn->key[1]) == w->port ||
	       (cn->act[0]->out & OUT_PORT) == w->port || (cn->act[1]->out & OUT_PORT) == w->port;
}

static int
port_learned(const struct learned *l, const struct flush_what *w)
{
	return l->ev.port == w->port;
}

unsigned
core_flush_port(struct core *c, unsigned port, uint32_t now, core_flushed_fn *fn, void *arg)
{
	struct flush_what w = { .conn = port_conn, .learned = port_learned, .port = port };

	return flush_where(c, &w, now, fn, arg);
}

static int
route_conn(const struct conn *cn, const struct flush_what *w)
{
	return (cn->act[0]->dip & w->mask) == w->dst || (cn->act[1]->dip & w->mask) == w->dst;
}

static int
route_learned(const struct learned *l, const struct flush_what *w)
{
	return l->ev.k.kind == LEARN_OUT && (l->ev.k.dip & w->mask) == w->dst;
}

unsigned
core_flush_route(struct core *c, uint32_t dst, unsigned len, uint32_t now, core_flushed_fn *fn,
		 void *arg)
{
	struct flush_what w = { .conn = route_conn, .learned = route_learned };

	w.mask = len ? rte_cpu_to_be_32(len >= 32 ? UINT32_MAX : ~(UINT32_MAX >> len)) : 0;
	w.dst = dst & w.mask;
	return flush_where(c, &w, now, fn, arg);
}

/* The destination of an L2 header out, and the first bytes of the frame, are the MAC address. */
static int
mac_conn(const struct conn *cn, const struct flush_what *w)
{
	return !memcmp(cn->act[0]->l2, w->mac, 6) || !memcmp(cn->act[1]->l2, w->mac, 6);
}

static int
mac_learned(const struct learned *l, const struct flush_what *w)
{
	return l->ev.k.kind == LEARN_OUT && !memcmp(l->ev.l2, w->mac, 6);
}

unsigned
core_flush_mac(struct core *c, const uint8_t mac[6], uint32_t now, core_flushed_fn *fn, void *arg)
{
	struct flush_what w = { .conn = mac_conn, .learned = mac_learned };

	memcpy(w.mac, mac, sizeof(w.mac));
	return flush_where(c, &w, now, fn, arg);
}

static int
tunnel_conn(const struct conn *cn, const struct flush_what *w)
{
	return key_tunnel(&cn->key[0]) == w->tunnel || key_tunnel(&cn->key[1]) == w->tunnel ||
	       cn->into[0] == w->tunnel || cn->into[1] == w->tunnel;
}

static int
tunnel_learned(const struct learned *l, const struct flush_what *w)
{
	return l->ev.tunnel == w->tunnel;
}

unsigned
core_flush_tunnel(struct core *c, uint16_t tunnel, uint32_t now, core_flushed_fn *fn, void *arg)
{
	struct flush_what w = { .conn = tunnel_conn, .learned = tunnel_learned,
				.tunnel = tunnel + 1u };

	return flush_where(c, &w, now, fn, arg);
}

void
core_conn_walk(struct core *c, int (*fn)(const struct core_conn *, void *), void *arg)
{
	struct core_conn info;
	unsigned i;

	for (i = 0; i < c->p.max_conns; i++)
		if (c->conn[i].used) {
			conn_info(&c->conn[i], &info);
			if (fn(&info, arg))
				return;
		}
}
