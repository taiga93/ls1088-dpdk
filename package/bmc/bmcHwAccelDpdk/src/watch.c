/*
 * See watch.h. The neighbours are in an open-addressing hash table keyed by
 * interface and address, never deleted from; the interfaces in an array.
 */
#include <stdlib.h>
#include <string.h>

#include "watch.h"

struct neigh {
	int ifindex;		/* 0: a free slot */
	uint32_t ip;
	uint8_t mac[6];
};

struct link {
	int ifindex;
	int up;
};

struct watch {
	char ports[WATCH_PORTS_MAX][WATCH_NAME_MAX];
	unsigned nports;
	struct neigh *neigh;
	uint32_t size, used;	/* size: a power of 2 */
	struct link *link;
	unsigned nlinks, links_size;
};

struct watch *
watch_create(void)
{
	struct watch *w = calloc(1, sizeof(*w));

	if (!w)
		return NULL;
	w->size = 1024;
	w->neigh = calloc(w->size, sizeof(*w->neigh));
	if (!w->neigh) {
		free(w);
		return NULL;
	}
	return w;
}

void
watch_free(struct watch *w)
{
	if (!w)
		return;
	free(w->neigh);
	free(w->link);
	free(w);
}

void
watch_ports(struct watch *w, const char *const *names, unsigned n)
{
	unsigned i;

	w->nports = 0;
	for (i = 0; i < n && i < WATCH_PORTS_MAX; i++) {
		strncpy(w->ports[i], names[i], WATCH_NAME_MAX - 1);
		w->ports[i][WATCH_NAME_MAX - 1] = '\0';
		w->nports++;
	}
}

static enum watch_do
act(struct watch_act *a, enum watch_do what)
{
	memset(a, 0, sizeof(*a));
	a->what = what;
	return what;
}

enum watch_do
watch_route(struct watch *w, uint32_t dst, unsigned len, int cloned, struct watch_act *a)
{
	(void)w;
	if (cloned)
		return act(a, WATCH_NOTHING);
	if (len == 0)
		return act(a, WATCH_FLUSH);
	act(a, WATCH_FLUSH_ROUTE);
	a->dst = dst;
	a->len = len > 32 ? 32 : len;
	return a->what;
}

enum watch_do
watch_rule(struct watch *w, struct watch_act *a)
{
	(void)w;
	return act(a, WATCH_FLUSH);
}

enum watch_do
watch_nexthop(struct watch *w, struct watch_act *a)
{
	(void)w;
	return act(a, WATCH_FLUSH);
}

enum watch_do
watch_addr_gone(struct watch *w, struct watch_act *a)
{
	(void)w;
	return act(a, WATCH_FLUSH);
}

/* Interfaces. */

static struct link *
link_find(struct watch *w, int ifindex)
{
	unsigned i;

	for (i = 0; i < w->nlinks; i++)
		if (w->link[i].ifindex == ifindex)
			return &w->link[i];
	return NULL;
}

static int
is_port(const struct watch *w, const char *name)
{
	unsigned i;

	for (i = 0; i < w->nports; i++)
		if (!strcmp(w->ports[i], name))
			return 1;
	return 0;
}

enum watch_do
watch_link(struct watch *w, int ifindex, const char *name, int up, int bridged, int gone,
	   struct watch_act *a)
{
	struct link *l = link_find(w, ifindex);
	int was_up = l && l->up;

	if (gone) {
		if (l)
			*l = w->link[--w->nlinks];
	} else if (l) {
		l->up = up;
	} else {
		if (w->nlinks == w->links_size) {
			unsigned n = w->links_size ? 2 * w->links_size : 32;
			struct link *nl = realloc(w->link, n * sizeof(*nl));

			/* without memory it is heard of again next time */
			if (!nl)
				return act(a, WATCH_NOTHING);
			w->link = nl;
			w->links_size = n;
		}
		w->link[w->nlinks++] = (struct link){ ifindex, up };
	}
	if (!was_up || (up && !gone))
		return act(a, WATCH_NOTHING);
	if (bridged && !is_port(w, name))
		return act(a, WATCH_NOTHING);
	act(a, is_port(w, name) ? WATCH_FLUSH_PORT : WATCH_FLUSH);
	strncpy(a->port, name, WATCH_NAME_MAX - 1);
	return a->what;
}

/* Neighbours. */

static uint32_t
neigh_hash(int ifindex, uint32_t ip)
{
	uint64_t h = ((uint64_t)(uint32_t)ifindex << 32 | ip) * 0x9e3779b97f4a7c15ULL;

	return (uint32_t)(h >> 32);
}

static struct neigh *
neigh_slot(struct neigh *t, uint32_t size, int ifindex, uint32_t ip)
{
	uint32_t i = neigh_hash(ifindex, ip) & (size - 1);

	while (t[i].ifindex && (t[i].ifindex != ifindex || t[i].ip != ip))
		i = (i + 1) & (size - 1);
	return &t[i];
}

/* Twice as many slots: 0, or -1 without memory. */
static int
neigh_grow(struct watch *w)
{
	uint32_t size = 2 * w->size, i;
	struct neigh *t = calloc(size, sizeof(*t));

	if (!t)
		return -1;
	for (i = 0; i < w->size; i++)
		if (w->neigh[i].ifindex)
			*neigh_slot(t, size, w->neigh[i].ifindex, w->neigh[i].ip) = w->neigh[i];
	free(w->neigh);
	w->neigh = t;
	w->size = size;
	return 0;
}

enum watch_do
watch_neigh(struct watch *w, int ifindex, uint32_t ip, const uint8_t *mac, struct watch_act *a)
{
	static const uint8_t zero[6];
	struct neigh *n;

	if (!mac || !memcmp(mac, zero, 6) || ifindex == 0)
		return act(a, WATCH_NOTHING);
	n = neigh_slot(w->neigh, w->size, ifindex, ip);
	if (n->ifindex) {
		if (!memcmp(n->mac, mac, 6))
			return act(a, WATCH_NOTHING);
		act(a, WATCH_FLUSH_MAC);
		memcpy(a->mac, n->mac, 6);
		memcpy(n->mac, mac, 6);
		return a->what;
	}
	/* at most half full; past WATCH_NEIGH_MAX a new neighbour is not remembered */
	if (2 * (w->used + 1) > w->size) {
		if (w->used >= WATCH_NEIGH_MAX || neigh_grow(w))
			return act(a, WATCH_NOTHING);
		n = neigh_slot(w->neigh, w->size, ifindex, ip);
	}
	n->ifindex = ifindex;
	n->ip = ip;
	memcpy(n->mac, mac, 6);
	w->used++;
	return act(a, WATCH_NOTHING);
}
