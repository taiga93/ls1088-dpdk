/*
 * See sync.h. The connections known (bound, or waiting for a bind) are in an
 * open-addressing hash table keyed by protocol and original tuple.
 */
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>

#include "sync.h"

#define IPS_ASSURED 0x4
#define NEVER 0		/* retry_at of a connection not tried again */

enum { FREE, USED, GONE };	/* a slot: empty, a connection, one deleted */

struct entry {
	uint8_t slot, proto, bound;
	int8_t tcp_state;	/* the last one conntrack said */
	uint32_t retry_at;	/* while waiting; NEVER: not tried again */
	uint32_t backoff;	/* ms between the last two tries */
	struct sync_tuple orig, reply;
};

struct sync {
	struct entry *e;
	uint32_t size;		/* a power of 2 */
	uint32_t used, gone;
	unsigned bound, waiting;
};

static uint32_t
hash(uint8_t proto, const struct sync_tuple *t)
{
	uint64_t h = ((uint64_t)t->sip << 32 | t->dip) * 0x9e3779b97f4a7c15ULL;

	h ^= ((uint64_t)t->sport << 24 | (uint64_t)t->dport << 8 | proto) * 0xc2b2ae3d27d4eb4fULL;
	h ^= h >> 29;
	return (uint32_t)h;
}

static int
same(const struct entry *e, uint8_t proto, const struct sync_tuple *t)
{
	return e->proto == proto && e->orig.sip == t->sip && e->orig.dip == t->dip &&
	       e->orig.sport == t->sport && e->orig.dport == t->dport;
}

static struct entry *
find(const struct sync *s, uint8_t proto, const struct sync_tuple *t)
{
	uint32_t i = hash(proto, t) & (s->size - 1);

	for (;; i = (i + 1) & (s->size - 1)) {
		struct entry *e = &s->e[i];

		if (e->slot == FREE)
			return NULL;
		if (e->slot == USED && same(e, proto, t))
			return e;
	}
}

/* The table rebuilt with size slots, without deleted ones: 0, or -1 without memory. */
static int
grow(struct sync *s, uint32_t size)
{
	struct entry *old = s->e, *e;
	uint32_t n = s->size, i, j;

	e = calloc(size, sizeof(*e));
	if (!e)
		return -1;
	for (i = 0; i < n; i++) {
		if (old[i].slot != USED)
			continue;
		for (j = hash(old[i].proto, &old[i].orig) & (size - 1); e[j].slot != FREE;
		     j = (j + 1) & (size - 1))
			;
		e[j] = old[i];
	}
	free(old);
	s->e = e;
	s->size = size;
	s->gone = 0;
	return 0;
}

static struct entry *
add(struct sync *s, uint8_t proto, const struct sync_ct *ct)
{
	struct entry *e;
	uint32_t i;

	/* at most half full, deleted slots counted */
	if (2 * (s->used + s->gone + 1) > s->size &&
	    grow(s, 2 * (s->used + 1) > s->size / 2 ? 2 * s->size : s->size))
		return NULL;
	for (i = hash(proto, &ct->orig) & (s->size - 1); s->e[i].slot == USED;
	     i = (i + 1) & (s->size - 1))
		;
	e = &s->e[i];
	if (e->slot == GONE)
		s->gone--;
	memset(e, 0, sizeof(*e));
	e->slot = USED;
	e->proto = proto;
	e->orig = ct->orig;
	e->reply = ct->reply;
	s->used++;
	return e;
}

static void
del(struct sync *s, struct entry *e)
{
	if (e->bound)
		s->bound--;
	else
		s->waiting--;
	e->slot = GONE;
	s->used--;
	s->gone++;
}

struct sync *
sync_create(void)
{
	struct sync *s = calloc(1, sizeof(*s));

	if (!s)
		return NULL;
	s->size = 1024;
	s->e = calloc(s->size, sizeof(*s->e));
	if (!s->e) {
		free(s);
		return NULL;
	}
	return s;
}

void
sync_free(struct sync *s)
{
	if (!s)
		return;
	free(s->e);
	free(s);
}

void
sync_reset(struct sync *s)
{
	memset(s->e, 0, s->size * sizeof(*s->e));
	s->used = s->gone = 0;
	s->bound = s->waiting = 0;
}

/* The bind of a waiting connection is due again ms after now; a clock that wraps onto NEVER skips it. */
static void
retry_in(struct entry *e, uint32_t now, uint32_t ms)
{
	e->retry_at = now + ms;
	if (e->retry_at == NEVER)
		e->retry_at++;
}

/* Everything but the TCP state: whether the connection may go to the engine. */
static int
allowed(const struct sync_ct *ct)
{
	return (ct->status & IPS_ASSURED) && !(ct->mark & SYNC_KEEP_BIT) && !ct->helper;
}

enum sync_do
sync_ct(struct sync *s, enum sync_msg msg, const struct sync_ct *ct, uint32_t now)
{
	struct entry *e;
	int state, bound;

	if (!ct->ipv4 || (ct->proto != IPPROTO_TCP && ct->proto != IPPROTO_UDP))
		return SYNC_NOTHING;
	e = find(s, ct->proto, &ct->orig);
	if (msg == SYNC_DESTROY) {
		if (!e)
			return SYNC_NOTHING;
		bound = e->bound;
		del(s, e);
		return bound ? SYNC_UNBIND : SYNC_NOTHING;
	}
	state = ct->tcp_state;
	if (state == SYNC_TCP_UNKNOWN && e)
		state = e->tcp_state;
	if (ct->proto == IPPROTO_TCP && state == SYNC_TCP_UNKNOWN)
		return allowed(ct) ? SYNC_QUERY : SYNC_NOTHING;
	if (allowed(ct) && (ct->proto == IPPROTO_UDP || state == SYNC_TCP_ESTABLISHED)) {
		if (e) {
			e->tcp_state = (int8_t)state;
			return SYNC_NOTHING;
		}
		e = add(s, ct->proto, ct);
		if (!e)
			return SYNC_NOTHING;
		e->tcp_state = (int8_t)state;
		/* tried again if the bind could not even be asked for */
		retry_in(e, now, SYNC_RETRY_FIRST);
		s->waiting++;
		return SYNC_BIND;
	}
	if (!e)
		return SYNC_NOTHING;
	bound = e->bound;
	del(s, e);
	return bound ? SYNC_UNBIND : SYNC_NOTHING;
}

void
sync_bound(struct sync *s, uint8_t proto, const struct sync_tuple *orig, enum sync_result r,
	   uint32_t now)
{
	struct entry *e = find(s, proto, orig);

	if (!e || e->bound)
		return;
	switch (r) {
	case SYNC_OK:
	case SYNC_EXISTS:
		e->bound = 1;
		s->waiting--;
		s->bound++;
		break;
	case SYNC_UNLEARNED:
	case SYNC_NOSPACE:
		e->backoff = !e->backoff ? SYNC_RETRY_FIRST :
			     2 * e->backoff > SYNC_RETRY_MAX ? SYNC_RETRY_MAX : 2 * e->backoff;
		retry_in(e, now, e->backoff);
		break;
	case SYNC_REFUSED:
		e->retry_at = NEVER;
		break;
	}
}

unsigned
sync_due(struct sync *s, uint32_t now, void (*fn)(const struct sync_conn *, void *), void *arg)
{
	uint32_t i;
	unsigned n = 0;

	for (i = 0; s->waiting && i < s->size; i++) {
		struct entry *e = &s->e[i];
		struct sync_conn c;

		if (e->slot != USED || e->bound || e->retry_at == NEVER ||
		    (int32_t)(now - e->retry_at) < 0)
			continue;
		c = (struct sync_conn){ e->proto, e->orig, e->reply, 0 };
		n++;
		fn(&c, arg);
	}
	return n;
}

int
sync_is_bound(const struct sync *s, uint8_t proto, const struct sync_tuple *orig)
{
	const struct entry *e = find(s, proto, orig);

	return e && e->bound;
}

void
sync_forget(struct sync *s, uint8_t proto, const struct sync_tuple *orig)
{
	struct entry *e = find(s, proto, orig);

	if (e)
		del(s, e);
}

/* A bound connection waits for its bind again, as a new one. */
static void
unbound(struct sync *s, struct entry *e, uint32_t now)
{
	e->bound = 0;
	e->backoff = 0;
	retry_in(e, now, SYNC_RETRY_FIRST);
	s->bound--;
	s->waiting++;
}

void
sync_unbound(struct sync *s, uint8_t proto, const struct sync_tuple *orig, uint32_t now)
{
	struct entry *e = find(s, proto, orig);

	if (e && e->bound)
		unbound(s, e, now);
}

void
sync_unbound_all(struct sync *s, uint32_t now)
{
	uint32_t i;

	for (i = 0; s->bound && i < s->size; i++)
		if (s->e[i].slot == USED && s->e[i].bound)
			unbound(s, &s->e[i], now);
}

void
sync_retry_soon(struct sync *s, uint32_t now)
{
	uint32_t i;

	for (i = 0; s->waiting && i < s->size; i++) {
		struct entry *e = &s->e[i];

		if (e->slot != USED || e->bound || e->retry_at == NEVER)
			continue;
		e->backoff = 0;
		retry_in(e, now, SYNC_RETRY_FIRST);
	}
}

void
sync_count(const struct sync *s, unsigned *bound, unsigned *waiting)
{
	*bound = s->bound;
	*waiting = s->waiting;
}

uint32_t
sync_timeout(uint32_t timeout, uint32_t idle)
{
	uint32_t gone = idle / 1000;	/* whole seconds: what is left is rounded up */

	return gone >= timeout ? 1 : timeout - gone;
}
