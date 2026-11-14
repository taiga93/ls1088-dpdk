/*
 * See ipsec.h. The SAs are records in an array, found by the workers through
 * an rte_hash read without locks (SPI and destination); a second one holds
 * the address pairs of the outbound SAs, for the fragments of their ESP,
 * which carry no SPI past the first. The tunnels are an array the workers
 * read at the index the core gives them (core_out.tun). The control thread
 * writes all of them and waits for the workers (RCU) before a record, a
 * key, a tunnel or an SA of esp it let go of is used again.
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>

#include <rte_common.h>
#include <rte_cycles.h>
#include <rte_ether.h>
#include <rte_hash.h>
#include <rte_hash_crc.h>
#include <rte_ip.h>
#include <rte_ip_frag.h>
#include <rte_malloc.h>
#include <rte_spinlock.h>
#include <rte_udp.h>

#include "ipsec.h"

#define NONE UINT32_MAX
#define L2_MAX 26		/* Ethernet, one VLAN tag, PPPoE and PPP */
#define PPPOE_LEN 8		/* the PPPoE session header and PPP's protocol */
#define PPPOE_L2 (RTE_ETHER_HDR_LEN + PPPOE_LEN)	/* the shortest header with PPPoE */
#define ESP_HDR 8		/* SPI and sequence number */
#define FRAG_BUCKETS 64		/* of the table that puts fragments together */
#define FRAG_BUCKET_ENTRIES 4
#define FRAG_MAX 256		/* datagrams being put together at once */
#define FRAG_MS 500		/* longest wait for the rest of a datagram */

/* R_STOPPED: let go of, but the kernel's ESP on it is dropped until it is deleted */
enum { R_FREE, R_LIVE, R_STOPPED, R_GOING };
enum { ROLE_ENC, ROLE_DEC };	/* outbound: encrypt, decrypt again; inbound: decrypt */

struct skey {
	uint32_t spi, dst;
};

struct pkey {
	uint32_t src, dst;
};

/*
 * An SA of the kernel the engine holds. Records do not share a cache line:
 * the worker that numbers for one SA writes its numbered, which keeps the
 * workers of other SAs out of that line.
 */
struct rec {
	uint32_t spi, src, dst;
	uint16_t sport, dport;	/* ESP in UDP; 0 0: plain ESP */
	uint32_t reqid;
	uint32_t first;		/* outbound: the number of its first packet */
	uint32_t enc, dec;	/* its SAs of esp; NONE: none or let go of */
	uint32_t tunnel;
	uint32_t serial;	/* the order SAs were added in */
	int32_t key_pos;	/* of its key in the table of SAs */
	uint8_t dir, state;
	/* what ESP adds to a packet (spec-ipsec: Chiều đi vượt MTU) */
	uint8_t hdr;		/* outer IPv4 header [+ UDP], SPI, number, IV */
	uint8_t icv, blk;	/* the ICV; the payload is padded to blk */
	/* outbound: the numbers jobs took (Q12), the workers' to write */
	uint32_t numbered;
} __rte_cache_aligned;

struct tunnel {
	uint32_t reqid;
	unsigned nsa;
	uint32_t out;		/* the record of its current outbound SA, its newest; NONE */
	uint32_t worker;	/* that encrypts for it: the kernel's ESP of it comes to it; NONE */
};

/* What the engine keeps of a packet the SEC has, in its private area. */
struct meta {
	uint8_t l2[L2_MAX];
	uint8_t l2_len, port;
	uint16_t ip_id;		/* of the kernel's outer header: the SEC's is always 0 */
	uint16_t len;		/* of a packet the engine encrypts on its own: the inner one; 0 */
	uint32_t rec;
};

_Static_assert(sizeof(struct meta) <= IPSEC_PRIV_SIZE, "IPSEC_PRIV_SIZE holds the meta");

/* What a worker counts of an SA. */
struct wstat {
	uint64_t bytes, packets;
	uint64_t lost;		/* packets of it lost on the way: no room, no mbuf */
};

struct worker {
	struct wstat *st;	/* of each record */
	struct rte_ip_frag_death_row dr;
} __rte_cache_aligned;

struct stack {
	uint32_t *v, n;
};

struct ipsec {
	struct ipsec_params p;
	struct esp *esp;
	uint8_t kport[RTE_MAX_ETHPORTS];	/* port + 1 of a kernel side; 0: none */
	uint8_t wport[RTE_MAX_ETHPORTS];	/* port + 1 of a wire side; 0: none */
	struct rte_hash *sas;		/* skey -> record, read by the workers */
	struct rte_hash *pairs;		/* pkey -> outbound SAs with those addresses */
	struct rte_hash *tunnels;	/* reqid -> its tunnel, at the key's position */
	struct rec *rec;
	struct tunnel *tun;
	uint32_t *owner;		/* of each SA of esp: record << 1 | role, or NONE */
	unsigned *pair_n;		/* outbound SAs of each key of pairs */
	struct stack free_rec, free_sa, going;
	unsigned nout;			/* outbound SAs held: the workers look when > 0 */
	unsigned nin;			/* inbound ones, for the ESP from the wire */
	unsigned count, ntunnels;
	uint32_t serial;
	struct rte_ip_frag_tbl *frag;
	rte_spinlock_t frag_lock;
	struct worker w[];
};

static unsigned instances;	/* for the names of the DPDK objects */

static struct rte_hash *
hash_create(const char *what, unsigned id, unsigned entries, unsigned key_len, int lf,
	    int socket_id)
{
	char name[RTE_HASH_NAMESIZE];
	struct rte_hash_parameters hp = {
		.name = name,
		.entries = entries < 8 ? 8 : entries,
		.key_len = key_len,
		.hash_func = rte_hash_crc,
		.socket_id = socket_id,
		.extra_flag = RTE_HASH_EXTRA_FLAGS_EXT_TABLE |
			      (lf ? RTE_HASH_EXTRA_FLAGS_RW_CONCURRENCY_LF : 0),
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
stack_init(struct stack *s, const char *what, uint32_t n, int full, int socket_id)
{
	uint32_t i;

	s->v = zalloc(what, n ? n : 1, sizeof(uint32_t), socket_id);
	if (!s->v)
		return -ENOMEM;
	s->n = 0;
	for (i = 0; full && i < n; i++)
		s->v[s->n++] = n - 1 - i;
	return 0;
}

void
ipsec_free(struct ipsec *x)
{
	unsigned w;

	if (!x)
		return;
	for (w = 0; w < x->p.nworkers; w++)
		rte_free(x->w[w].st);
	rte_ip_frag_table_destroy(x->frag);
	rte_hash_free(x->sas);
	rte_hash_free(x->pairs);
	rte_hash_free(x->tunnels);
	rte_free(x->rec);
	rte_free(x->tun);
	rte_free(x->owner);
	rte_free(x->pair_n);
	rte_free(x->free_rec.v);
	rte_free(x->free_sa.v);
	rte_free(x->going.v);
	rte_free(x);
}

struct ipsec *
ipsec_create(const struct ipsec_params *p, struct esp *esp)
{
	unsigned id = __atomic_fetch_add(&instances, 1, __ATOMIC_RELAXED), w, i;
	struct ipsec *x;
	int s = p->socket_id;

	if (!esp || !p->core || !p->nworkers || !p->max_sa || !p->max_tunnels || !p->mp ||
	    !p->whole ||
	    rte_pktmbuf_priv_size(p->mp) < sizeof(struct meta) ||
	    rte_pktmbuf_priv_size(p->whole) < sizeof(struct meta))
		return NULL;
	x = rte_zmalloc_socket("ipsec", sizeof(*x) + p->nworkers * sizeof(x->w[0]),
			       RTE_CACHE_LINE_SIZE, s);
	if (!x)
		return NULL;
	x->p = *p;
	x->esp = esp;
	rte_spinlock_init(&x->frag_lock);
	x->sas = hash_create("ipsec_sa", id, p->max_sa, sizeof(struct skey), 1, s);
	x->pairs = hash_create("ipsec_pair", id, p->max_sa, sizeof(struct pkey), 1, s);
	x->tunnels = hash_create("ipsec_tun", id, p->max_tunnels, sizeof(uint32_t), 0, s);
	x->rec = zalloc("ipsec_rec", p->max_sa, sizeof(*x->rec), s);
	x->tun = zalloc("ipsec_tun", p->max_tunnels + 8, sizeof(*x->tun), s);
	x->owner = zalloc("ipsec_owner", p->max_sa, sizeof(*x->owner), s);
	x->pair_n = zalloc("ipsec_pairn", p->max_sa + 8, sizeof(*x->pair_n), s);
	x->frag = rte_ip_frag_table_create(FRAG_BUCKETS, FRAG_BUCKET_ENTRIES, FRAG_MAX,
					   rte_get_timer_hz() * FRAG_MS / 1000, s);
	if (!x->sas || !x->pairs || !x->tunnels || !x->rec || !x->tun || !x->owner ||
	    !x->pair_n || !x->frag || stack_init(&x->free_rec, "ipsec_frec", p->max_sa, 1, s) ||
	    stack_init(&x->free_sa, "ipsec_fsa", p->max_sa, 1, s) ||
	    stack_init(&x->going, "ipsec_going", p->max_sa, 0, s))
		goto fail;
	for (i = 0; i < p->max_sa; i++)
		x->owner[i] = NONE;
	for (w = 0; w < p->nworkers; w++) {
		x->w[w].st = zalloc("ipsec_st", p->max_sa, sizeof(struct wstat), s);
		if (!x->w[w].st)
			goto fail;
	}
	return x;
fail:
	ipsec_free(x);
	return NULL;
}

int
ipsec_map_kernel(struct ipsec *x, uint16_t ethdev, unsigned port)
{
	if (ethdev >= RTE_MAX_ETHPORTS || port >= x->p.nports)
		return -EINVAL;
	x->kport[ethdev] = (uint8_t)(port + 1);
	return 0;
}

int
ipsec_map_wire(struct ipsec *x, uint16_t ethdev, unsigned port)
{
	if (ethdev >= RTE_MAX_ETHPORTS || port >= x->p.nports)
		return -EINVAL;
	x->wport[ethdev] = (uint8_t)(port + 1);
	return 0;
}

/* The control thread. */

static void
rcu_wait(struct ipsec *x)
{
	rte_rcu_qsbr_synchronize(core_rcu(x->p.core), RTE_QSBR_THRID_INVALID);
}

/* The highest number an outbound SA may have used: its first, plus what its encryption took. */
static uint32_t
last_of(const struct ipsec *x, const struct rec *r)
{
	struct esp_sa_stats st;

	if (r->dir != ESP_OUT || esp_sa_stats(x->esp, r->enc, &st))
		return 0;
	return (uint32_t)(r->first - 1 + st.taken);
}

static int
pair_add(struct ipsec *x, uint32_t src, uint32_t dst)
{
	struct pkey k = { src, dst };
	int32_t pos = rte_hash_lookup(x->pairs, &k);

	if (pos < 0)
		pos = rte_hash_add_key(x->pairs, &k);
	if (pos < 0)
		return pos;
	x->pair_n[pos]++;
	return 0;
}

/* After rcu_wait(): no worker still reads the key. */
static int32_t
pair_drop(struct ipsec *x, uint32_t src, uint32_t dst)
{
	struct pkey k = { src, dst };
	int32_t pos = rte_hash_lookup(x->pairs, &k);

	if (pos < 0 || --x->pair_n[pos])
		return -1;
	return rte_hash_del_key(x->pairs, &k);
}

int
ipsec_sa_add(struct ipsec *x, const struct esp_sa_conf *c)
{
	struct skey k = { c->spi, c->dst };
	unsigned out = c->dir == ESP_OUT, need = out ? 2 : 1;
	int32_t tpos = rte_hash_lookup(x->tunnels, &c->lane);
	struct esp_sa_conf again;
	struct rec *r;
	uint32_t idx, enc, dec = NONE;
	unsigned w;
	int ret;

	if (c->dir > ESP_IN || (out && c->seq > IPSEC_SEQ_MAX))
		return -EINVAL;
	if (rte_hash_lookup(x->sas, &k) >= 0)
		return -EEXIST;
	if ((tpos < 0 && x->ntunnels >= x->p.max_tunnels) || x->free_sa.n < need || !x->free_rec.n)
		return -ENOSPC;
	enc = x->free_sa.v[x->free_sa.n - 1];
	ret = esp_sa_add(x->esp, enc, c);
	if (ret)
		return ret;
	if (out) {
		/* decrypts again what the kernel numbered: no window, it is not the peer's */
		again = *c;
		again.dir = ESP_IN;
		again.replay = 0;
		again.seq = 0;
		dec = x->free_sa.v[x->free_sa.n - 2];
		ret = esp_sa_add(x->esp, dec, &again);
		if (ret) {
			esp_sa_del(x->esp, enc);
			return ret;
		}
		ret = pair_add(x, c->src, c->dst);
		if (ret) {
			esp_sa_del(x->esp, dec);
			esp_sa_del(x->esp, enc);
			return -ENOSPC;
		}
	}
	if (tpos < 0) {
		tpos = rte_hash_add_key(x->tunnels, &c->lane);
		if (tpos < 0 || (unsigned)tpos >= x->p.max_tunnels + 8) {
			/* the table is sized for them: not expected */
			if (tpos >= 0)
				rte_hash_del_key(x->tunnels, &c->lane);
			if (out) {
				int32_t pair = pair_drop(x, c->src, c->dst);

				rcu_wait(x);
				if (pair >= 0)
					rte_hash_free_key_with_position(x->pairs, pair);
				esp_sa_del(x->esp, dec);
			}
			esp_sa_del(x->esp, enc);
			return -ENOSPC;
		}
		x->tun[tpos] = (struct tunnel){ .reqid = c->lane, .out = NONE, .worker = NONE };
		x->ntunnels++;
	}
	x->free_sa.n -= need;
	idx = x->free_rec.v[--x->free_rec.n];
	r = &x->rec[idx];
	*r = (struct rec){
		.spi = c->spi, .src = c->src, .dst = c->dst, .sport = c->sport, .dport = c->dport,
		.reqid = c->lane, .first = c->seq ? c->seq : 1, .enc = out ? enc : NONE,
		.dec = out ? dec : enc, .tunnel = (uint32_t)tpos, .serial = x->serial++,
		.dir = c->dir, .state = R_LIVE,
		/* as xfrm_state_mtu() of Linux has it, the IV of CBC 16 bytes and of GCM 8 */
		.hdr = (uint8_t)(sizeof(struct rte_ipv4_hdr) + (c->sport || c->dport ?
			sizeof(struct rte_udp_hdr) : 0) + ESP_HDR + (c->cipher == ESP_AES_GCM ? 8 : 16)),
		.icv = esp_icv_len[c->auth < RTE_DIM(esp_icv_len) ? c->auth : 0],
		.blk = c->cipher == ESP_AES_GCM ? 4 : 16,
	};
	x->tun[tpos].nsa++;
	for (w = 0; w < x->p.nworkers; w++)
		x->w[w].st[idx] = (struct wstat){ 0 };
	if (out)
		__atomic_store_n(&x->owner[enc], idx << 1 | ROLE_ENC, __ATOMIC_RELEASE);
	__atomic_store_n(&x->owner[r->dec], idx << 1 | ROLE_DEC, __ATOMIC_RELEASE);
	/* the workers find it once everything of it is there */
	r->key_pos = rte_hash_add_key_data(x->sas, &k, (void *)(uintptr_t)idx);
	if (r->key_pos < 0) {
		/* the table holds max_sa keys: not expected; nothing of it stays */
		int32_t pair = out ? pair_drop(x, c->src, c->dst) : -1;

		x->owner[enc] = NONE;
		x->owner[r->dec] = NONE;
		rcu_wait(x);
		if (pair >= 0)
			rte_hash_free_key_with_position(x->pairs, pair);
		if (!--x->tun[tpos].nsa) {
			rte_hash_del_key(x->tunnels, &c->lane);
			x->ntunnels--;
		}
		esp_sa_del(x->esp, enc);
		if (out)
			esp_sa_del(x->esp, dec);
		r->state = R_FREE;
		x->free_rec.v[x->free_rec.n++] = idx;
		x->free_sa.n += need;
		return -ENOSPC;
	}
	if (out) {
		/* the newest encrypts for its tunnel, as the kernel's newest does */
		__atomic_store_n(&x->tun[tpos].out, idx, __ATOMIC_RELEASE);
		__atomic_fetch_add(&x->nout, 1, __ATOMIC_RELEASE);
	} else {
		__atomic_fetch_add(&x->nin, 1, __ATOMIC_RELEASE);
	}
	x->count++;
	return 0;
}

/*
 * The outbound SA of record idx no longer encrypts for its tunnel: the
 * newest other one held does, and with none the connections of the tunnel
 * go through the kernel again.
 */
static void
tunnel_lose_out(struct ipsec *x, uint32_t idx, uint32_t now, core_flushed_fn *gone, void *arg)
{
	const struct rec *r = &x->rec[idx];
	struct tunnel *t = &x->tun[r->tunnel];
	uint32_t i, best = NONE;

	if (r->dir != ESP_OUT || t->out != idx)
		return;
	for (i = 0; i < x->p.max_sa; i++) {
		const struct rec *o = &x->rec[i];

		if (i != idx && o->state == R_LIVE && o->dir == ESP_OUT && o->tunnel == r->tunnel &&
		    (best == NONE || (int32_t)(o->serial - x->rec[best].serial) > 0))
			best = i;
	}
	__atomic_store_n(&t->out, best, __ATOMIC_RELEASE);
	if (best == NONE) {
		/* none still learns of the SA (its state says so) when its records are forgotten */
		rcu_wait(x);
		core_flush_tunnel(x->p.core, (uint16_t)r->tunnel, now, gone, arg);
	}
}

static void info_of(const struct ipsec *x, uint32_t idx, struct ipsec_sa_info *in);

/* Takes the record out of the workers' way; its sessions go in ipsec_poll(). */
static void
rec_let_go(struct ipsec *x, uint32_t idx, uint32_t now, struct ipsec_sa_info *info,
	   core_flushed_fn *gone, void *arg)
{
	struct rec *r = &x->rec[idx];
	struct skey k = { r->spi, r->dst };
	int32_t pair = -1;

	__atomic_store_n(&r->state, R_GOING, __ATOMIC_RELEASE);
	rte_hash_del_key(x->sas, &k);
	if (r->dir == ESP_OUT) {
		pair = pair_drop(x, r->src, r->dst);
		__atomic_fetch_sub(&x->nout, 1, __ATOMIC_RELEASE);
		tunnel_lose_out(x, idx, now, gone, arg);
	} else {
		__atomic_fetch_sub(&x->nin, 1, __ATOMIC_RELEASE);
	}
	/*
	 * No worker is between finding it and handing a job to it, nor
	 * between a result of it and the next job: what it took is all.
	 */
	rcu_wait(x);
	rte_hash_free_key_with_position(x->sas, r->key_pos);
	if (pair >= 0)
		rte_hash_free_key_with_position(x->pairs, pair);
	if (info)
		info_of(x, idx, info);
	if (!--x->tun[r->tunnel].nsa) {
		/*
		 * Its number may go to another tunnel: no entry, record or worker
		 * still has it then. None of its SAs makes records any more.
		 */
		core_flush_tunnel(x->p.core, (uint16_t)r->tunnel, now, gone, arg);
		rcu_wait(x);
		rte_hash_del_key(x->tunnels, &r->reqid);
		x->ntunnels--;
	}
	x->count--;
	x->going.v[x->going.n++] = idx;
}

static void
info_of(const struct ipsec *x, uint32_t idx, struct ipsec_sa_info *in)
{
	const struct rec *r = &x->rec[idx];
	struct esp_sa_stats st;
	unsigned w, i;

	*in = (struct ipsec_sa_info){ .dir = r->dir, .spi = r->spi, .src = r->src, .dst = r->dst,
				      .reqid = r->reqid, .last = last_of(x, r) };
	for (w = 0; w < x->p.nworkers; w++) {
		const struct wstat *s = &x->w[w].st[idx];

		in->bytes += s->bytes;
		in->packets += s->packets;
		in->dropped += s->lost;
	}
	for (i = 0; i < 2; i++) {
		uint32_t sa = i ? r->dec : r->enc;

		if (sa != NONE && !esp_sa_stats(x->esp, sa, &st)) {
			in->failed += st.failed;
			in->dropped += st.dropped;
		}
	}
}

int
ipsec_sa_stop(struct ipsec *x, uint32_t spi, uint32_t dst, uint32_t now,
	      struct ipsec_sa_info *info, core_flushed_fn *gone, void *arg)
{
	struct skey k = { spi, dst };
	void *data;
	uint32_t idx;

	if (rte_hash_lookup_data(x->sas, &k, &data) < 0)
		return -ENOENT;
	idx = (uint32_t)(uintptr_t)data;
	__atomic_store_n(&x->rec[idx].state, R_STOPPED, __ATOMIC_RELEASE);
	tunnel_lose_out(x, idx, now, gone, arg);
	/* as in rec_let_go(): what it took is all */
	rcu_wait(x);
	if (info)
		info_of(x, idx, info);
	return 0;
}

int
ipsec_sa_del(struct ipsec *x, uint32_t spi, uint32_t dst, uint32_t now,
	     struct ipsec_sa_info *info, core_flushed_fn *gone, void *arg)
{
	struct skey k = { spi, dst };
	void *data;

	if (rte_hash_lookup_data(x->sas, &k, &data) < 0)
		return -ENOENT;
	rec_let_go(x, (uint32_t)(uintptr_t)data, now, info, gone, arg);
	return 0;
}

unsigned
ipsec_sa_flush(struct ipsec *x, uint32_t now, void (*fn)(const struct ipsec_sa_info *, void *),
	       core_flushed_fn *gone, void *arg)
{
	unsigned n = 0;
	uint32_t i;

	for (i = 0; i < x->p.max_sa && x->count; i++) {
		struct ipsec_sa_info in;

		if (x->rec[i].state != R_LIVE && x->rec[i].state != R_STOPPED)
			continue;
		rec_let_go(x, i, now, &in, gone, arg);
		if (fn)
			fn(&in, arg);
		n++;
	}
	return n;
}

unsigned
ipsec_flush_peer(struct ipsec *x, uint32_t dst, unsigned len, uint32_t now,
		 core_flushed_fn *gone, void *arg)
{
	uint32_t mask = len ? rte_cpu_to_be_32(len >= 32 ? UINT32_MAX : ~(UINT32_MAX >> len)) : 0;
	/* the tunnels flushed already; a tunnel's number is below max_tunnels + 8 (ipsec_sa_add()) */
	uint8_t done[IPSEC_MAX_TUNNELS + 8];
	unsigned n = 0, seen = 0;
	uint32_t i;

	memset(done, 0, sizeof(done));
	dst &= mask;
	for (i = 0; i < x->p.max_sa && seen < x->count; i++) {
		const struct rec *r = &x->rec[i];

		if (r->state != R_LIVE && r->state != R_STOPPED)
			continue;
		seen++;
		if (r->tunnel >= sizeof(done) || done[r->tunnel] ||
		    ((r->dir == ESP_OUT ? r->dst : r->src) & mask) != dst)
			continue;
		done[r->tunnel] = 1;
		n += core_flush_tunnel(x->p.core, (uint16_t)r->tunnel, now, gone, arg);
	}
	return n;
}

void
ipsec_sa_walk(struct ipsec *x, int (*fn)(const struct ipsec_sa_info *, void *), void *arg)
{
	uint32_t i;
	unsigned seen = 0;

	for (i = 0; i < x->p.max_sa && seen < x->count; i++) {
		struct ipsec_sa_info in;

		if (x->rec[i].state != R_LIVE && x->rec[i].state != R_STOPPED)
			continue;
		seen++;
		info_of(x, i, &in);
		if (fn(&in, arg))
			return;
	}
}

unsigned
ipsec_sa_count(const struct ipsec *x)
{
	return x->count;
}

/* An SA of esp of a record let go of, deleted once no job of it is left; 1: gone. */
static int
session_gone(struct ipsec *x, uint32_t sa)
{
	if (sa == NONE || x->owner[sa] == NONE)
		return 1;
	if (esp_sa_del(x->esp, sa) == -EBUSY)
		return 0;
	__atomic_store_n(&x->owner[sa], NONE, __ATOMIC_RELEASE);
	return 1;
}

void
ipsec_poll(struct ipsec *x)
{
	uint32_t i, gone = 0;

	for (i = 0; i < x->going.n; i++) {
		struct rec *r = &x->rec[x->going.v[i]];

		/* & : both are tried each time */
		gone += session_gone(x, r->enc) & session_gone(x, r->dec);
	}
	if (!gone)
		return;
	/* no worker still reads the owner of their SAs of esp, nor the record */
	rcu_wait(x);
	for (i = 0; i < x->going.n;) {
		uint32_t idx = x->going.v[i];
		struct rec *r = &x->rec[idx];

		if (x->owner[r->dec] != NONE || (r->enc != NONE && x->owner[r->enc] != NONE)) {
			i++;
			continue;
		}
		x->free_sa.v[x->free_sa.n++] = r->dec;
		if (r->enc != NONE)
			x->free_sa.v[x->free_sa.n++] = r->enc;
		r->state = R_FREE;
		x->free_rec.v[x->free_rec.n++] = idx;
		x->going.v[i] = x->going.v[--x->going.n];
	}
}

/* Workers. */

static inline struct meta *
meta_of(struct rte_mbuf *m)
{
	return rte_mbuf_to_priv(m);
}

/*
 * Takes a sequence number of the outbound SA of record idx for one job of
 * worker w: 1, or 0 (the packet counted as lost) when none is left up to
 * IPSEC_SEQ_MAX. Workers may number for an SA at once (the tunnel's
 * worker, another before the tunnel has one): an atomic count, which the
 * load keeps from growing once it is past.
 */
static inline int
seq_take(struct ipsec *x, unsigned w, uint32_t idx)
{
	struct rec *r = &x->rec[idx];
	uint32_t left = IPSEC_SEQ_MAX - r->first;

	if (likely(__atomic_load_n(&r->numbered, __ATOMIC_RELAXED) <= left &&
		   __atomic_fetch_add(&r->numbered, 1, __ATOMIC_RELAXED) <= left))
		return 1;
	x->w[w].st[idx].lost++;
	return 0;
}

/*
 * The record of the SA of direction dir a packet of IPv4 is the ESP of: an
 * outbound one as the kernel sends it, an inbound one as it comes from the
 * peer. Plain ESP, or in UDP without the non-ESP marker of IKE, from the
 * SA's source and ports, held or stopped. NONE for anything else,
 * keepalives included (a byte of UDP). The headers are in the first
 * segment.
 */
static uint32_t
held(struct ipsec *x, const struct rte_ipv4_hdr *ip, unsigned len, int dir)
{
	const uint8_t *l4 = (const uint8_t *)(ip + 1), *esp = l4;
	struct skey k;
	const struct rec *r;
	void *data;
	int udp = ip->next_proto_id == IPPROTO_UDP;

	if (udp) {
		esp += sizeof(struct rte_udp_hdr);
		if (len < sizeof(*ip) + sizeof(struct rte_udp_hdr) + ESP_HDR ||
		    !memcmp(esp, "\0\0\0\0", 4))
			return NONE;
	} else if (len < sizeof(*ip) + ESP_HDR) {
		return NONE;
	}
	memcpy(&k.spi, esp, 4);
	k.spi = rte_be_to_cpu_32(k.spi);
	k.dst = ip->dst_addr;
	if (rte_hash_lookup_data(x->sas, &k, &data) < 0)
		return NONE;
	r = &x->rec[(uint32_t)(uintptr_t)data];
	if (r->dir != dir || r->src != ip->src_addr || udp != (r->sport || r->dport))
		return NONE;
	if (udp) {
		const struct rte_udp_hdr *u = (const struct rte_udp_hdr *)l4;

		if (rte_be_to_cpu_16(u->src_port) != r->sport ||
		    rte_be_to_cpu_16(u->dst_port) != r->dport)
			return NONE;
	}
	return (uint32_t)(uintptr_t)data;
}

/*
 * m in one segment, as the SEC and to_wire() take it: m itself, a copy, or
 * NULL (m freed). A copy longer than a packet of mp is one of whole.
 */
static struct rte_mbuf *
single(struct ipsec *x, struct rte_mbuf *m)
{
	struct rte_mempool *mp = x->p.mp;
	struct rte_mbuf *one;

	if (m->nb_segs == 1)
		return m;
	if (m->pkt_len > (unsigned)(rte_pktmbuf_data_room_size(mp) - RTE_PKTMBUF_HEADROOM))
		mp = x->p.whole;
	one = rte_pktmbuf_copy(m, mp, 0, UINT32_MAX);
	rte_pktmbuf_free(m);
	if (one && one->nb_segs != 1) {
		rte_pktmbuf_free(one);
		one = NULL;
	}
	return one;
}

/*
 * The kernel's ESP (whole, l2 bytes of header) on the SA of record idx: to
 * the SEC, to be decrypted again; dropped when the SA is stopped, since
 * the kernel's number may not leave before the daemon wrote the engine's
 * last one into the kernel.
 */
static void
to_sec(struct ipsec *x, unsigned w, struct rte_mbuf *m, unsigned l2, unsigned port,
       uint32_t idx, struct esp_job *jobs, unsigned *nj)
{
	struct meta *mt;
	const struct rte_ipv4_hdr *ip;

	if (__atomic_load_n(&x->rec[idx].state, __ATOMIC_ACQUIRE) != R_LIVE ||
	    !(m = single(x, m))) {
		x->w[w].st[idx].lost++;
		rte_pktmbuf_free(m);
		return;
	}
	mt = meta_of(m);
	memcpy(mt->l2, rte_pktmbuf_mtod(m, void *), l2);
	mt->l2_len = (uint8_t)l2;
	mt->port = (uint8_t)port;
	mt->rec = idx;
	mt->len = 0;
	rte_pktmbuf_adj(m, (uint16_t)l2);
	ip = rte_pktmbuf_mtod(m, const struct rte_ipv4_hdr *);
	mt->ip_id = ip->packet_id;
	/* the padding of a short frame is no part of the ESP */
	if (m->pkt_len > rte_be_to_cpu_16(ip->total_length))
		rte_pktmbuf_trim(m, (uint16_t)(m->pkt_len - rte_be_to_cpu_16(ip->total_length)));
	jobs[(*nj)++] = (struct esp_job){ .m = m, .sa = x->rec[idx].dec };
}

/* The PPPoE length of a frame of l2 bytes of header before an IPv4 packet of len. */
static void
pppoe_len(uint8_t *f, unsigned l2, unsigned len)
{
	uint16_t v = rte_cpu_to_be_16((uint16_t)(len + 2));

	if (l2 >= PPPOE_L2)
		memcpy(f + l2 - PPPOE_LEN + 4, &v, 2);
}

static void
out_put(struct ipsec_out *out, unsigned port, int side, struct rte_mbuf *m)
{
	if (out->n[port][side] < IPSEC_OUT_MAX)
		out->pkts[port][side][out->n[port][side]++] = m;
	else
		rte_pktmbuf_free(m);
}

/*
 * The IPv4 packet m (from its start, one segment) out of port with the L2
 * header l2: fragments of at most the MTU of the port (less PPPoE) when it
 * is longer, as Linux makes them, with the IP id *id when not NULL (the
 * SEC gives every packet 0: fragments of two would be put together as
 * one). m is used or freed; 0, or -1 when some of it could not go.
 */
static int
to_wire(struct ipsec *x, struct rte_mbuf *m, const uint8_t *l2, unsigned l2_len, unsigned port,
	const uint16_t *id, struct ipsec_out *out)
{
	const struct rte_ipv4_hdr *ip = rte_pktmbuf_mtod(m, const struct rte_ipv4_hdr *);
	unsigned len = rte_be_to_cpu_16(ip->total_length), hl = sizeof(*ip);
	unsigned mtu = x->p.mtu[port] - (l2_len >= PPPOE_L2 ? PPPOE_LEN : 0), step, off;
	uint16_t fo = rte_be_to_cpu_16(ip->fragment_offset);
	uint8_t *f;
	int ret = 0;

	if (len <= mtu) {
		f = (uint8_t *)rte_pktmbuf_prepend(m, (uint16_t)l2_len);
		if (!f) {
			rte_pktmbuf_free(m);
			return -1;
		}
		memcpy(f, l2, l2_len);
		pppoe_len(f, l2_len, len);
		out_put(out, port, CORE_WIRE, m);
		return 0;
	}
	/* fragments of what was a fragment keep their place in the datagram */
	step = (mtu - hl) & ~7u;
	for (off = 0; off < len - hl; off += step) {
		unsigned k = RTE_MIN(step, len - hl - off);
		struct rte_mbuf *fr = rte_pktmbuf_alloc(x->p.mp);
		struct rte_ipv4_hdr *h;
		uint16_t flags;

		if (!fr || !(f = (uint8_t *)rte_pktmbuf_append(fr, (uint16_t)(l2_len + hl + k)))) {
			rte_pktmbuf_free(fr);
			ret = -1;
			continue;
		}
		memcpy(f, l2, l2_len);
		h = (struct rte_ipv4_hdr *)(f + l2_len);
		memcpy(h, ip, hl);
		memcpy(h + 1, (const uint8_t *)ip + hl + off, k);
		flags = (uint16_t)((fo & RTE_IPV4_HDR_OFFSET_MASK) + off / 8);
		if (off + k < len - hl || (fo & RTE_IPV4_HDR_MF_FLAG))
			flags |= RTE_IPV4_HDR_MF_FLAG;
		h->fragment_offset = rte_cpu_to_be_16(flags);
		if (id)
			h->packet_id = *id;
		h->total_length = rte_cpu_to_be_16((uint16_t)(hl + k));
		h->hdr_checksum = 0;
		h->hdr_checksum = rte_ipv4_cksum(h);
		pppoe_len(f, l2_len, hl + k);
		fr->port = m->port;
		out_put(out, port, CORE_WIRE, fr);
	}
	rte_pktmbuf_free(m);
	return ret;
}

/*
 * A fragment the kernel sent between the addresses of an outbound SA: put
 * together with the others of its datagram. When it is whole, its ESP is
 * numbered again if it is of an SA held, or it goes out fragmented as it
 * came. 0: not such a fragment; 1: taken.
 */
static int
frag_in(struct ipsec *x, unsigned w, struct rte_mbuf *m, unsigned l2, unsigned port,
	struct rte_ipv4_hdr *ip, uint64_t timer, struct esp_job *jobs, unsigned *nj,
	struct ipsec_out *out)
{
	struct pkey pk = { ip->src_addr, ip->dst_addr };
	struct rte_mbuf *whole, *one;
	uint8_t hdr[L2_MAX];
	uint32_t idx;

	if (rte_hash_lookup(x->pairs, &pk) < 0)
		return 0;
	m->l2_len = l2;
	m->l3_len = sizeof(*ip);
	rte_spinlock_lock(&x->frag_lock);
	whole = rte_ipv4_frag_reassemble_packet(x->frag, &x->w[w].dr, m, timer, ip);
	rte_spinlock_unlock(&x->frag_lock);
	rte_ip_frag_free_death_row(&x->w[w].dr, 0);
	if (!whole)
		return 1;
	/* the headers are those of the first fragment, in the first segment */
	ip = rte_pktmbuf_mtod_offset(whole, struct rte_ipv4_hdr *, l2);
	idx = whole->data_len >= l2 + sizeof(*ip) + sizeof(struct rte_udp_hdr) + ESP_HDR ?
	      held(x, ip, rte_be_to_cpu_16(ip->total_length), ESP_OUT) : NONE;
	one = single(x, whole);
	if (!one) {
		if (idx != NONE)
			x->w[w].st[idx].lost++;
		return 1;
	}
	ip = rte_pktmbuf_mtod_offset(one, struct rte_ipv4_hdr *, l2);
	ip->hdr_checksum = 0;
	ip->hdr_checksum = rte_ipv4_cksum(ip);
	if (idx != NONE) {
		to_sec(x, w, one, l2, port, idx, jobs, nj);
		return 1;
	}
	memcpy(hdr, rte_pktmbuf_mtod(one, void *), l2);
	rte_pktmbuf_adj(one, (uint16_t)l2);
	to_wire(x, one, hdr, l2, port, NULL, out);
	return 1;
}

/* A packet of the kernel side of port: 1 when taken. */
static int
take(struct ipsec *x, unsigned w, struct rte_mbuf *m, unsigned port, uint64_t timer,
     struct esp_job *jobs, unsigned *nj, struct ipsec_out *out)
{
	unsigned l2 = core_l2_len(m), len;
	struct rte_ipv4_hdr *ip;
	uint32_t idx;

	if (!l2 || m->data_len < l2 + sizeof(*ip))
		return 0;
	ip = rte_pktmbuf_mtod_offset(m, struct rte_ipv4_hdr *, l2);
	len = rte_be_to_cpu_16(ip->total_length);
	if (ip->version_ihl != RTE_IPV4_VHL_DEF || l2 + len > m->pkt_len ||
	    (ip->next_proto_id != IPPROTO_ESP && ip->next_proto_id != IPPROTO_UDP))
		return 0;
	if (ip->fragment_offset & rte_cpu_to_be_16(RTE_IPV4_HDR_MF_FLAG | RTE_IPV4_HDR_OFFSET_MASK))
		return frag_in(x, w, m, l2, port, ip, timer, jobs, nj, out);
	/* the headers, up to the sequence number of ESP in UDP, in the first segment */
	if (m->data_len < l2 + RTE_MIN(len, sizeof(*ip) + sizeof(struct rte_udp_hdr) + ESP_HDR))
		return 0;
	idx = held(x, ip, len, ESP_OUT);
	if (idx == NONE)
		return 0;
	/* not a fragment: the ESP of the tunnel always comes to this worker */
	{
		uint32_t *tw = &x->tun[x->rec[idx].tunnel].worker, none = NONE;

		if (__atomic_load_n(tw, __ATOMIC_RELAXED) == NONE)
			__atomic_compare_exchange_n(tw, &none, w, 0, __ATOMIC_RELAXED,
						    __ATOMIC_RELAXED);
	}
	to_sec(x, w, m, l2, port, idx, jobs, nj);
	return 1;
}

unsigned
ipsec_kernel(struct ipsec *x, unsigned w, struct rte_mbuf **pkts, unsigned n, uint64_t timer,
	     struct ipsec_out *out)
{
	struct esp_job jobs[CORE_BURST];
	unsigned i, left = 0, nj = 0;

	memset(out->n, 0, sizeof(out->n));
	out->naway = 0;
	if (likely(!__atomic_load_n(&x->nout, __ATOMIC_ACQUIRE)))
		return n;
	for (i = 0; i < n; i++) {
		struct rte_mbuf *m = pkts[i];
		uint8_t kp = m->port < RTE_MAX_ETHPORTS ? x->kport[m->port] : 0;

		/* jobs holds one per packet: a whole datagram is one of its fragments */
		if (!kp || nj == CORE_BURST || !take(x, w, m, kp - 1u, timer, jobs, &nj, out))
			pkts[left++] = m;
	}
	if (nj)
		esp_submit(x->esp, w, jobs, nj);
	return left;
}

/*
 * ESP from the wire side of port on an inbound SA held: to the SEC,
 * decrypted out of place, so that it can go up as it came. 1 when taken.
 */
static int
take_wire(struct ipsec *x, struct rte_mbuf *m, unsigned port, struct esp_job *jobs, unsigned *nj)
{
	unsigned l2 = core_l2_len(m), len;
	const struct rte_ipv4_hdr *ip;
	struct rte_mbuf *d;
	struct meta *mt;
	uint32_t idx;

	if (!l2 || m->nb_segs != 1 || m->data_len < l2 + sizeof(*ip))
		return 0;
	ip = rte_pktmbuf_mtod_offset(m, const struct rte_ipv4_hdr *, l2);
	len = rte_be_to_cpu_16(ip->total_length);
	/* fragments of ESP go up as they are (spec-ipsec: Đường gói) */
	if (ip->version_ihl != RTE_IPV4_VHL_DEF || l2 + len > m->data_len ||
	    (ip->next_proto_id != IPPROTO_ESP && ip->next_proto_id != IPPROTO_UDP) ||
	    (ip->fragment_offset & rte_cpu_to_be_16(RTE_IPV4_HDR_MF_FLAG | RTE_IPV4_HDR_OFFSET_MASK)))
		return 0;
	idx = held(x, ip, len, ESP_IN);
	if (idx == NONE || __atomic_load_n(&x->rec[idx].state, __ATOMIC_ACQUIRE) != R_LIVE)
		return 0;
	d = rte_pktmbuf_alloc(x->p.mp);
	if (!d)
		return 0;
	mt = meta_of(m);
	mt->l2_len = (uint8_t)l2;
	mt->port = (uint8_t)port;
	mt->rec = idx;
	mt->len = 0;
	rte_pktmbuf_adj(m, (uint16_t)l2);
	if (m->pkt_len > len)
		rte_pktmbuf_trim(m, (uint16_t)(m->pkt_len - len));
	jobs[(*nj)++] = (struct esp_job){ .m = m, .dst = d, .sa = x->rec[idx].dec };
	return 1;
}

unsigned
ipsec_wire(struct ipsec *x, unsigned w, struct rte_mbuf **pkts, unsigned n)
{
	struct esp_job jobs[CORE_BURST];
	unsigned i, left = 0, nj = 0;

	if (likely(!__atomic_load_n(&x->nin, __ATOMIC_ACQUIRE)))
		return n;
	for (i = 0; i < n; i++) {
		struct rte_mbuf *m = pkts[i];
		uint8_t wp = m->port < RTE_MAX_ETHPORTS ? x->wport[m->port] : 0;

		if (!wp || nj == CORE_BURST || !take_wire(x, m, wp - 1u, jobs, &nj))
			pkts[left++] = m;
	}
	if (nj)
		esp_submit(x->esp, w, jobs, nj);
	return left;
}

/*
 * A packet of the core into tunnel t, out of port (core_tun), on worker w:
 * to the SEC, encrypted with the tunnel's current outbound SA, or away to
 * the worker of the tunnel; dropped without an SA.
 */
static void
encrypt(struct ipsec *x, unsigned w, struct rte_mbuf *m, uint16_t t, unsigned port,
	struct esp_job *jobs, unsigned *nj, struct ipsec_out *out)
{
	uint32_t idx = NONE, tw = NONE;
	unsigned l2 = m->l2_len, len;
	const struct rte_ipv4_hdr *ip;
	struct meta *mt;

	if (t < x->p.max_tunnels + 8) {
		idx = __atomic_load_n(&x->tun[t].out, __ATOMIC_ACQUIRE);
		tw = __atomic_load_n(&x->tun[t].worker, __ATOMIC_RELAXED);
	}
	if (idx != NONE && tw != NONE && tw != w && tw < x->p.nworkers) {
		if (out->naway < IPSEC_OUT_MAX)
			out->away[out->naway++] = (struct ipsec_away){
				.t = { .m = m, .tunnel = t, .port = (uint8_t)port }, .worker = tw };
		else
			rte_pktmbuf_free(m);
		return;
	}
	if (idx == NONE || __atomic_load_n(&x->rec[idx].state, __ATOMIC_ACQUIRE) != R_LIVE ||
	    m->nb_segs != 1 || l2 > L2_MAX || port >= x->p.nports || !seq_take(x, w, idx)) {
		rte_pktmbuf_free(m);
		return;
	}
	mt = meta_of(m);
	memcpy(mt->l2, rte_pktmbuf_mtod(m, void *), l2);
	mt->l2_len = (uint8_t)l2;
	mt->port = (uint8_t)port;
	mt->rec = idx;
	rte_pktmbuf_adj(m, (uint16_t)l2);
	ip = rte_pktmbuf_mtod(m, const struct rte_ipv4_hdr *);
	len = rte_be_to_cpu_16(ip->total_length);
	mt->ip_id = ip->packet_id;
	mt->len = (uint16_t)len;
	/* the padding of a short frame is no part of the packet */
	if (m->pkt_len > len)
		rte_pktmbuf_trim(m, (uint16_t)(m->pkt_len - len));
	jobs[(*nj)++] = (struct esp_job){ .m = m, .sa = x->rec[idx].enc };
}

void
ipsec_tunnel(struct ipsec *x, unsigned w, const struct core_tun *t, unsigned n,
	     struct ipsec_out *out)
{
	struct esp_job jobs[CORE_BURST];
	unsigned i, nj = 0;

	memset(out->n, 0, sizeof(out->n));
	out->naway = 0;
	for (i = 0; i < n && i < CORE_BURST; i++)
		encrypt(x, w, t[i].m, t[i].tunnel, t[i].port, jobs, &nj, out);
	if (nj)
		esp_submit(x->esp, w, jobs, nj);
}

/*
 * The largest inner packet the outbound SA r encrypts into ESP that fits
 * out of port with an L2 header of l2 bytes: xfrm_state_mtu() of Linux,
 * so that the packets the kernel sends through the tunnel do.
 */
static uint16_t
inner_mtu(const struct ipsec *x, const struct rec *r, unsigned port, unsigned l2)
{
	int mtu = x->p.mtu[port] - (l2 >= PPPOE_L2 ? PPPOE_LEN : 0) - r->hdr - r->icv;

	return mtu < r->blk ? 0 : (uint16_t)((mtu & ~(r->blk - 1)) - 2);
}

/* The ESP from the wire of a result (meta of m) up to the kernel side, as it came. */
static void
esp_up(struct ipsec_out *out, struct rte_mbuf *m)
{
	struct meta *mt = meta_of(m);

	/* decrypted out of place: its L2 header is still in front of it */
	rte_pktmbuf_prepend(m, mt->l2_len);
	out_put(out, mt->port, CORE_KERNEL, m);
}

/* What an inbound SA decrypted for ipsec_done(): the packet, the ESP it came in. */
struct dec {
	struct rte_mbuf *m[ESP_BURST], *esp[ESP_BURST];
	uint16_t tunnel[ESP_BURST];
	uint8_t port[ESP_BURST];
	uint16_t len[ESP_BURST];
	uint32_t rec[ESP_BURST];
	unsigned n;
};

/*
 * The packets decrypted out of tunnels through the core: forwarded, or
 * their ESP up to the kernel. jobs: those the core put into a tunnel.
 */
static void
inbound(struct ipsec *x, unsigned w, struct dec *d, uint32_t now, struct esp_job *jobs,
	unsigned *nj, struct ipsec_out *out)
{
	struct core_out co;
	uint64_t up = core_rx_tunnel(x->p.core, w, d->m, d->tunnel, d->port, d->n, now, &co);
	unsigned i, p, s, k;

	for (i = 0; i < d->n; i++) {
		if (up >> i & 1) {
			rte_pktmbuf_free(d->m[i]);
			esp_up(out, d->esp[i]);
			continue;
		}
		x->w[w].st[d->rec[i]].packets++;
		x->w[w].st[d->rec[i]].bytes += d->len[i];
		rte_pktmbuf_free(d->esp[i]);
	}
	for (p = 0; p < x->p.nports; p++)
		for (s = 0; s < 2; s++)
			for (k = 0; k < co.n[p][s]; k++)
				out_put(out, p, (int)s, co.pkts[p][s][k]);
	for (k = 0; k < co.ntun; k++)
		encrypt(x, w, co.tun[k].m, co.tun[k].tunnel, co.tun[k].port, jobs, nj, out);
}

void
ipsec_done(struct ipsec *x, unsigned w, const struct esp_result *r, unsigned n, uint32_t now,
	   struct ipsec_out *out)
{
	/* each result makes one job at most */
	struct esp_job jobs[ESP_BURST];
	struct dec d;
	unsigned i, nj = 0;

	memset(out->n, 0, sizeof(out->n));
	out->naway = 0;
	d.n = 0;
	for (i = 0; i < n && i < ESP_BURST; i++) {
		struct rte_mbuf *m = r[i].job.m, *dst = r[i].job.dst;
		uint32_t o = r[i].job.sa < x->p.max_sa ?
			     __atomic_load_n(&x->owner[r[i].job.sa], __ATOMIC_ACQUIRE) : NONE;
		const struct rec *rc;
		struct meta *mt;
		int live;

		/* none of an SA held: a self-test that came back late */
		if (o == NONE) {
			rte_pktmbuf_free(m);
			rte_pktmbuf_free(dst);
			continue;
		}
		rc = &x->rec[o >> 1];
		mt = meta_of(m);
		live = __atomic_load_n(&rc->state, __ATOMIC_ACQUIRE) == R_LIVE;
		if (rc->dir == ESP_IN) {
			/* what the SEC did not decrypt, or of an SA let go of: the kernel decides */
			if (!r[i].ok || !live) {
				rte_pktmbuf_free(dst);
				esp_up(out, m);
				continue;
			}
			/* the Rx flags of the ESP are none of the packet in it */
			dst->ol_flags = 0;
			d.m[d.n] = dst;
			d.esp[d.n] = m;
			d.tunnel[d.n] = (uint16_t)rc->tunnel;
			d.port[d.n] = mt->port;
			d.len[d.n] = (uint16_t)dst->pkt_len;
			d.rec[d.n++] = o >> 1;
			continue;
		}
		rte_pktmbuf_free(dst);
		/* the SEC counted it as failed: nothing of it may go on */
		if (!r[i].ok) {
			rte_pktmbuf_free(m);
			continue;
		}
		if ((o & 1) == ROLE_DEC) {
			/* decrypted again: numbered the engine's way, unless let go of meanwhile */
			if (!live || !seq_take(x, w, o >> 1)) {
				rte_pktmbuf_free(m);
				continue;
			}
			m->ol_flags = 0;
			core_learn_tunnel(x->p.core, w, m, mt->port, mt->l2, mt->l2_len,
					  (uint16_t)rc->tunnel, inner_mtu(x, rc, mt->port, mt->l2_len),
					  now);
			jobs[nj++] = (struct esp_job){ .m = m, .sa = rc->enc };
			continue;
		}
		if (mt->len) {
			x->w[w].st[o >> 1].packets++;
			x->w[w].st[o >> 1].bytes += mt->len;
		}
		if (to_wire(x, m, mt->l2, mt->l2_len, mt->port, &mt->ip_id, out))
			x->w[w].st[o >> 1].lost++;
	}
	if (d.n)
		inbound(x, w, &d, now, jobs, &nj, out);
	if (nj)
		esp_submit(x->esp, w, jobs, nj);
}
