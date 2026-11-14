/*
 * "ESP ops": the SAs, the credit of each SA in each worker and the jobs
 * waiting for it, over a backend (esp.h).
 */
#include <errno.h>
#include <string.h>

#include <rte_common.h>
#include <rte_malloc.h>

#include "esp.h"

#define NO_QP 0xff		/* esp.qp of a number that is no SA */
#define NO_NODE 0xffff

/* An SA in a worker. */
struct wsa {
	uint32_t inflight;	/* ns of work of its jobs in its queue pair */
	uint16_t queued;	/* its jobs in the queue pair */
	uint16_t waiting;	/* and waiting for credit */
	uint16_t head, tail;	/* the waiting ones, a list of nodes */
	uint64_t ok, failed, taken, dropped;
};

struct node {
	struct esp_job job;
	uint16_t next;
};

struct worker {
	struct wsa *sa;
	struct node *node;	/* ESP_WAIT_MAX */
	uint16_t free;		/* list of the free nodes */
	unsigned nb[ESP_MAX_QP];
	struct esp_job batch[ESP_MAX_QP][ESP_BURST];
} __rte_cache_aligned;

struct esp {
	struct esp_dev *dev;
	unsigned nworkers, max_sa, nqp, count;
	uint8_t *qp;		/* of each SA in a worker; NO_QP: none */
	struct worker w[];
};

const struct esp_dev *
esp_dev(const struct esp *e)
{
	return e->dev;
}

void
esp_free(struct esp *e)
{
	unsigned w;

	if (!e)
		return;
	for (w = 0; w < e->nworkers; w++) {
		rte_free(e->w[w].sa);
		rte_free(e->w[w].node);
	}
	rte_free(e->qp);
	if (e->dev)
		e->dev->ops->free(e->dev);
	rte_free(e);
}

struct esp *
esp_create(const struct esp_params *p, struct esp_dev *dev)
{
	struct esp *e;
	unsigned w, i;

	if (!dev || !p->nworkers || !p->max_sa || !dev->nqp || dev->nqp > ESP_MAX_QP)
		return NULL;
	e = rte_zmalloc_socket("esp", sizeof(*e) + p->nworkers * sizeof(e->w[0]),
			       RTE_CACHE_LINE_SIZE, p->socket_id);
	if (!e)
		return NULL;
	e->dev = dev;
	e->nworkers = p->nworkers;
	e->max_sa = p->max_sa;
	e->nqp = dev->nqp;
	e->qp = rte_malloc_socket("esp_qp", p->max_sa, 0, p->socket_id);
	if (!e->qp)
		goto fail;
	memset(e->qp, NO_QP, p->max_sa);
	for (w = 0; w < p->nworkers; w++) {
		struct worker *wk = &e->w[w];

		wk->sa = rte_zmalloc_socket("esp_sa", (size_t)p->max_sa * sizeof(*wk->sa),
					    RTE_CACHE_LINE_SIZE, p->socket_id);
		wk->node = rte_malloc_socket("esp_wait", ESP_WAIT_MAX * sizeof(*wk->node),
					     RTE_CACHE_LINE_SIZE, p->socket_id);
		if (!wk->sa || !wk->node)
			goto fail;
		for (i = 0; i < ESP_WAIT_MAX; i++)
			wk->node[i].next = (uint16_t)(i + 1 < ESP_WAIT_MAX ? i + 1 : NO_NODE);
		wk->free = 0;
	}
	return e;
fail:
	e->dev = NULL;		/* the caller still has it */
	esp_free(e);
	return NULL;
}

static int
conf_ok(const struct esp_sa_conf *c)
{
	if (c->dir > ESP_IN || (c->key_len != 16 && c->key_len != 32))
		return 0;
	if (c->cipher == ESP_AES_GCM)
		return c->auth == ESP_AUTH_NONE;
	return c->cipher == ESP_AES_CBC && c->auth > ESP_AUTH_NONE &&
	       c->auth <= ESP_HMAC_SHA512_256 && c->auth_key_len == esp_auth_key_len[c->auth];
}

int
esp_sa_add(struct esp *e, uint32_t sa, const struct esp_sa_conf *c)
{
	unsigned w;
	int ret;

	if (sa >= e->max_sa || !conf_ok(c))
		return -EINVAL;
	if (e->qp[sa] != NO_QP)
		return -EEXIST;
	ret = e->dev->ops->sa_add(e->dev, sa, c);
	if (ret)
		return ret;
	for (w = 0; w < e->nworkers; w++)
		e->w[w].sa[sa] = (struct wsa){ .head = NO_NODE, .tail = NO_NODE };
	/* the workers see the SA once its session and its state are there */
	__atomic_store_n(&e->qp[sa], (uint8_t)(c->lane % e->nqp), __ATOMIC_RELEASE);
	e->count++;
	return 0;
}

int
esp_sa_del(struct esp *e, uint32_t sa)
{
	unsigned w;

	if (sa >= e->max_sa || e->qp[sa] == NO_QP)
		return -ENOENT;
	for (w = 0; w < e->nworkers; w++) {
		const struct wsa *s = &e->w[w].sa[sa];

		if (__atomic_load_n(&s->queued, __ATOMIC_ACQUIRE) ||
		    __atomic_load_n(&s->waiting, __ATOMIC_ACQUIRE))
			return -EBUSY;
	}
	__atomic_store_n(&e->qp[sa], NO_QP, __ATOMIC_RELEASE);
	e->dev->ops->sa_del(e->dev, sa);
	e->count--;
	return 0;
}

unsigned
esp_sa_count(const struct esp *e)
{
	return e->count;
}

int
esp_sa_stats(const struct esp *e, uint32_t sa, struct esp_sa_stats *st)
{
	unsigned w;

	if (sa >= e->max_sa || e->qp[sa] == NO_QP)
		return -ENOENT;
	memset(st, 0, sizeof(*st));
	for (w = 0; w < e->nworkers; w++) {
		const struct wsa *s = &e->w[w].sa[sa];

		st->ok += s->ok;
		st->failed += s->failed;
		st->taken += s->taken;
		st->dropped += s->dropped;
		st->queued += s->queued;
		st->waiting += s->waiting;
	}
	return 0;
}

static void
drop(struct esp_job *j)
{
	rte_pktmbuf_free(j->m);
	rte_pktmbuf_free(j->dst);
}

/* Hands the batch of queue pair q to the backend; returns how many it refused. */
static unsigned
flush(struct esp *e, unsigned w, unsigned q)
{
	struct worker *wk = &e->w[w];
	unsigned n = wk->nb[q], took, i;

	if (!n)
		return 0;
	wk->nb[q] = 0;
	took = e->dev->ops->enqueue(e->dev, w, q, wk->batch[q], n);
	/* the queue pair is full: dropped, their credit back */
	for (i = took; i < n; i++) {
		struct esp_job *j = &wk->batch[q][i];
		struct wsa *s = &wk->sa[j->sa];

		s->inflight -= j->cost;
		__atomic_store_n(&s->queued, (uint16_t)(s->queued - 1), __ATOMIC_RELEASE);
		s->dropped++;
		drop(j);
	}
	return n - took;
}

/* A job of SA s into the batch of its queue pair; what a flush refused. */
static unsigned
to_batch(struct esp *e, unsigned w, struct wsa *s, const struct esp_job *j)
{
	struct worker *wk = &e->w[w];
	unsigned q = e->qp[j->sa];

	s->inflight += j->cost;
	__atomic_store_n(&s->queued, (uint16_t)(s->queued + 1), __ATOMIC_RELEASE);
	wk->batch[q][wk->nb[q]++] = *j;
	return wk->nb[q] == ESP_BURST ? flush(e, w, q) : 0;
}

unsigned
esp_submit(struct esp *e, unsigned w, struct esp_job *jobs, unsigned n)
{
	struct worker *wk = &e->w[w];
	unsigned i, q, dropped = 0;

	for (i = 0; i < n; i++) {
		struct esp_job *j = &jobs[i];
		struct wsa *s;

		if (j->sa >= e->max_sa || __atomic_load_n(&e->qp[j->sa], __ATOMIC_ACQUIRE) == NO_QP) {
			drop(j);
			dropped++;
			continue;
		}
		s = &wk->sa[j->sa];
		j->cost = esp_cost(j->m->pkt_len);
		/* behind the ones waiting, so that the jobs of the SA keep their order */
		if (!s->waiting && s->inflight < ESP_SA_BUDGET) {
			__atomic_store_n(&s->taken, s->taken + 1, __ATOMIC_RELAXED);
			dropped += to_batch(e, w, s, j);
		} else if (s->waiting < ESP_SA_WAIT && wk->free != NO_NODE) {
			uint16_t k = wk->free;

			__atomic_store_n(&s->taken, s->taken + 1, __ATOMIC_RELAXED);
			wk->free = wk->node[k].next;
			wk->node[k] = (struct node){ .job = *j, .next = NO_NODE };
			if (s->tail == NO_NODE)
				s->head = k;
			else
				wk->node[s->tail].next = k;
			s->tail = k;
			__atomic_store_n(&s->waiting, (uint16_t)(s->waiting + 1), __ATOMIC_RELEASE);
		} else {
			s->dropped++;
			drop(j);
			dropped++;
		}
	}
	for (q = 0; q < e->nqp; q++)
		dropped += flush(e, w, q);
	return dropped;
}

void
esp_done(struct esp *e, unsigned w, const struct esp_result *r, unsigned n)
{
	struct worker *wk = &e->w[w];
	unsigned i, q;

	for (i = 0; i < n; i++) {
		struct wsa *s = &wk->sa[r[i].job.sa];

		s->inflight -= r[i].job.cost;
		__atomic_store_n(&s->queued, (uint16_t)(s->queued - 1), __ATOMIC_RELEASE);
		if (r[i].ok)
			s->ok++;
		else
			s->failed++;
		while (s->waiting && s->inflight < ESP_SA_BUDGET) {
			uint16_t k = s->head;
			struct esp_job j = wk->node[k].job;

			s->head = wk->node[k].next;
			if (s->head == NO_NODE)
				s->tail = NO_NODE;
			wk->node[k].next = wk->free;
			wk->free = k;
			__atomic_store_n(&s->waiting, (uint16_t)(s->waiting - 1), __ATOMIC_RELEASE);
			to_batch(e, w, s, &j);
		}
	}
	for (q = 0; q < e->nqp; q++)
		flush(e, w, q);
}

unsigned
esp_poll(struct esp *e, unsigned w, struct esp_result *r, unsigned max)
{
	unsigned n = e->dev->ops->poll ? e->dev->ops->poll(e->dev, w, r, max) : 0;

	esp_done(e, w, r, n);
	return n;
}

unsigned
esp_events(struct esp *e, unsigned w, void *const *objs, unsigned n, struct esp_result *r)
{
	n = e->dev->ops->events ? e->dev->ops->events(e->dev, objs, n, r) : 0;
	esp_done(e, w, r, n);
	return n;
}
