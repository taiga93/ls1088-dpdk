/*
 * The backend of "ESP ops" on the board (esp.h): the SEC through
 * crypto_dpaa2_sec, IPsec protocol offload (lookaside, rte_security), on
 * the DPSECI of the engine's container (spec-ipsec: Engine).
 *
 * Queue pair q of worker w is queue pair w * nqp + q of the DPSECI, and
 * only worker w enqueues on it, with its own portal. With events, the
 * results of its queue pairs go to event queue w of eventdev 0 (crypto
 * adapter, internal port: dpaa2_sec_eventq_attach), through the DPCON of
 * that queue: no service core, no polling, no other DPCON.
 *
 * The DPSECI is the one made at boot and outlives the engine: after a
 * kill -9 it is still enabled, with results of the dead engine maybe left
 * in its queues. Stopping the cryptodev once before it is attached resets
 * it (dpseci_reset), so that nothing of the engine before comes back.
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>

#include <rte_crypto.h>
#include <rte_cryptodev.h>
#include <rte_event_crypto_adapter.h>
#include <rte_eventdev.h>
#include <rte_malloc.h>
#include <rte_security.h>

#include "esp.h"

#define DRIVER "crypto_dpaa2_sec"
#define QP_DESC 1024		/* jobs a queue pair holds: the least dpaa2_sec takes */
#define ADAPTER 0		/* id of the crypto adapter */

struct dev {
	struct esp_dev d;
	uint8_t cdev;
	unsigned max_sa;
	struct rte_security_ctx *ctx;
	struct rte_mempool *sess_mp, *op_mp;
	void **sess;		/* of each SA */
	int adapter;		/* the crypto adapter was made */
};

/* The job of an op, in its private data. */
static inline struct esp_job *
job_of(struct rte_crypto_op *op)
{
	return (struct esp_job *)(op->sym + 1);
}

static int
sa_add(struct esp_dev *ed, uint32_t sa, const struct esp_sa_conf *c)
{
	static const enum rte_crypto_auth_algorithm auth[] = {
		0, RTE_CRYPTO_AUTH_SHA1_HMAC, RTE_CRYPTO_AUTH_SHA256_HMAC,
		RTE_CRYPTO_AUTH_SHA384_HMAC, RTE_CRYPTO_AUTH_SHA512_HMAC,
	};
	struct dev *d = (struct dev *)ed;
	int out = c->dir == ESP_OUT;
	struct rte_crypto_sym_xform x = { 0 }, a = { 0 };
	struct rte_security_session_conf conf = {
		.action_type = RTE_SECURITY_ACTION_TYPE_LOOKASIDE_PROTOCOL,
		.protocol = RTE_SECURITY_PROTOCOL_IPSEC,
		.ipsec = {
			.spi = c->spi,
			.direction = out ? RTE_SECURITY_IPSEC_SA_DIR_EGRESS :
					   RTE_SECURITY_IPSEC_SA_DIR_INGRESS,
			.proto = RTE_SECURITY_IPSEC_SA_PROTO_ESP,
			.mode = RTE_SECURITY_IPSEC_SA_MODE_TUNNEL,
			.tunnel = {
				.type = RTE_SECURITY_IPSEC_TUNNEL_IPV4,
				.ipv4 = {
					.src_ip.s_addr = c->src,
					.dst_ip.s_addr = c->dst,
					.ttl = 64,
				},
			},
			/*
			 * DF of the inner packet, as Linux does. The SEC copies
			 * DSCP without copy_dscp (ticket 13); with it, Era 8
			 * fails every packet (0x40003382, ticket 14).
			 */
			.options = {
				.copy_df = 1,
				.udp_encap = c->sport || c->dport,
			},
			.udp = { .sport = c->sport, .dport = c->dport },
			.replay_win_sz = c->replay,
		},
		.crypto_xform = &x,
	};
	void *s;

	if (sa >= d->max_sa)
		return -EINVAL;
	memcpy(&conf.ipsec.salt, c->salt, 4);
	/* without ESN, the first number (patch 003 of the dpdk package) */
	if (out)
		conf.ipsec.esn.low = c->seq;
	if (c->cipher == ESP_AES_GCM) {
		x.type = RTE_CRYPTO_SYM_XFORM_AEAD;
		x.aead.algo = RTE_CRYPTO_AEAD_AES_GCM;
		x.aead.op = out ? RTE_CRYPTO_AEAD_OP_ENCRYPT : RTE_CRYPTO_AEAD_OP_DECRYPT;
		x.aead.key.data = c->key;
		x.aead.key.length = c->key_len;
		x.aead.iv.length = 12;
		x.aead.digest_length = 16;
		x.aead.aad_length = 8;
	} else {
		x.type = RTE_CRYPTO_SYM_XFORM_CIPHER;
		x.cipher.algo = RTE_CRYPTO_CIPHER_AES_CBC;
		x.cipher.op = out ? RTE_CRYPTO_CIPHER_OP_ENCRYPT : RTE_CRYPTO_CIPHER_OP_DECRYPT;
		x.cipher.key.data = c->key;
		x.cipher.key.length = c->key_len;
		x.cipher.iv.length = 16;
		a.type = RTE_CRYPTO_SYM_XFORM_AUTH;
		a.auth.algo = auth[c->auth];
		a.auth.op = out ? RTE_CRYPTO_AUTH_OP_GENERATE : RTE_CRYPTO_AUTH_OP_VERIFY;
		a.auth.key.data = c->auth_key;
		a.auth.key.length = c->auth_key_len;
		a.auth.digest_length = esp_icv_len[c->auth];
		/* encrypt then authenticate; verify then decrypt */
		if (out) {
			x.next = &a;
		} else {
			a.next = &x;
			conf.crypto_xform = &a;
		}
	}
	s = rte_security_session_create(d->ctx, &conf, d->sess_mp);
	if (!s)
		return rte_errno ? -rte_errno : -ENOTSUP;
	d->sess[sa] = s;
	return 0;
}

static void
sa_del(struct esp_dev *ed, uint32_t sa)
{
	struct dev *d = (struct dev *)ed;

	rte_security_session_destroy(d->ctx, d->sess[sa]);
	d->sess[sa] = NULL;
}

static unsigned
enqueue(struct esp_dev *ed, unsigned w, unsigned q, const struct esp_job *jobs, unsigned n)
{
	struct dev *d = (struct dev *)ed;
	struct rte_crypto_op *ops[ESP_BURST];
	uint16_t sent, i;

	if (n > ESP_BURST)
		n = ESP_BURST;
	if (rte_crypto_op_bulk_alloc(d->op_mp, RTE_CRYPTO_OP_TYPE_SYMMETRIC, ops, (uint16_t)n) == 0)
		return 0;
	for (i = 0; i < n; i++) {
		ops[i]->sym->m_src = jobs[i].m;
		ops[i]->sym->m_dst = jobs[i].dst;
		rte_security_attach_session(ops[i], d->sess[jobs[i].sa]);
		*job_of(ops[i]) = jobs[i];
	}
	sent = rte_cryptodev_enqueue_burst(d->cdev, (uint16_t)(w * d->d.nqp + q), ops, (uint16_t)n);
	if (sent < n)
		rte_mempool_put_bulk(d->op_mp, (void **)&ops[sent], n - sent);
	return sent;
}

static void
result(struct dev *d, struct rte_crypto_op *op, struct esp_result *r)
{
	r->job = *job_of(op);
	r->ok = op->status == RTE_CRYPTO_OP_STATUS_SUCCESS;
	rte_mempool_put(d->op_mp, op);
}

static unsigned
dev_poll(struct esp_dev *ed, unsigned w, struct esp_result *r, unsigned max)
{
	struct dev *d = (struct dev *)ed;
	struct rte_crypto_op *ops[ESP_BURST];
	unsigned q, n = 0, i, k;

	for (q = 0; q < d->d.nqp && n < max; q++) {
		k = rte_cryptodev_dequeue_burst(d->cdev, (uint16_t)(w * d->d.nqp + q), ops,
						(uint16_t)RTE_MIN(max - n, (unsigned)ESP_BURST));
		for (i = 0; i < k; i++)
			result(d, ops[i], &r[n++]);
	}
	return n;
}

static unsigned
dev_events(struct esp_dev *ed, void *const *objs, unsigned n, struct esp_result *r)
{
	struct dev *d = (struct dev *)ed;
	unsigned i;

	for (i = 0; i < n; i++)
		result(d, objs[i], &r[i]);
	return n;
}

static void
dev_free(struct esp_dev *ed)
{
	struct dev *d = (struct dev *)ed;
	unsigned i;

	rte_cryptodev_stop(d->cdev);
	if (d->adapter)
		rte_event_crypto_adapter_free(ADAPTER);
	for (i = 0; d->sess && i < d->max_sa; i++)
		if (d->sess[i])
			rte_security_session_destroy(d->ctx, d->sess[i]);
	rte_free(d->sess);
	rte_mempool_free(d->op_mp);
	rte_mempool_free(d->sess_mp);
	rte_free(d);
}

static const struct esp_dev_ops ops = {
	.sa_add = sa_add,
	.sa_del = sa_del,
	.enqueue = enqueue,
	.poll = dev_poll,
	.events = dev_events,
	.free = dev_free,
};

/* The queue pairs of each worker give their results to its event queue. */
static const char *
attach(struct dev *d, unsigned nworkers)
{
	struct rte_event_port_conf pc;
	struct rte_event_crypto_adapter_queue_conf qc = { 0 };
	uint32_t caps = 0, need = RTE_EVENT_CRYPTO_ADAPTER_CAP_INTERNAL_PORT_OP_NEW |
				  RTE_EVENT_CRYPTO_ADAPTER_CAP_INTERNAL_PORT_QP_EV_BIND;
	unsigned w, q;

	if (rte_event_crypto_adapter_caps_get(0, d->cdev, &caps) || (caps & need) != need)
		return "the eventdev takes no results of the SEC";
	rte_event_port_default_conf_get(0, 0, &pc);
	if (rte_event_crypto_adapter_create(ADAPTER, 0, &pc, RTE_EVENT_CRYPTO_ADAPTER_OP_NEW))
		return "no crypto adapter";
	d->adapter = 1;
	qc.ev.event_type = RTE_EVENT_TYPE_CRYPTODEV;
	qc.ev.sched_type = RTE_SCHED_TYPE_PARALLEL;
	/* not the highest: dpaa2_sec divides by it */
	qc.ev.priority = RTE_EVENT_DEV_PRIORITY_NORMAL;
	for (w = 0; w < nworkers; w++)
		for (q = 0; q < d->d.nqp; q++) {
			qc.ev.queue_id = (uint8_t)w;
			if (rte_event_crypto_adapter_queue_pair_add(ADAPTER, d->cdev,
								    (int32_t)(w * d->d.nqp + q), &qc))
				return "a queue pair could not be attached to its worker";
		}
	return NULL;
}

struct esp_dev *
esp_dev_open(const struct esp_dev_params *p, const char **why)
{
	struct rte_cryptodev_config cfg = { .socket_id = p->socket_id,
					    .ff_disable = RTE_CRYPTODEV_FF_ASYMMETRIC_CRYPTO };
	struct rte_cryptodev_qp_conf qc = { .nb_descriptors = QP_DESC };
	struct rte_cryptodev_info info;
	struct dev *d;
	unsigned i, nqp;
	uint8_t c;
	uint32_t ssz;

	for (c = 0; c < rte_cryptodev_count(); c++) {
		rte_cryptodev_info_get(c, &info);
		if (!strcmp(info.driver_name, DRIVER))
			break;
	}
	if (c == rte_cryptodev_count()) {
		*why = "no DPSECI in the container";
		return NULL;
	}
	nqp = RTE_MIN((unsigned)ESP_MAX_QP, info.max_nb_queue_pairs / p->nworkers);
	if (!nqp) {
		*why = "fewer queue pairs than workers";
		return NULL;
	}
	d = rte_zmalloc_socket("esp_sec", sizeof(*d), 0, p->socket_id);
	if (!d) {
		*why = "no memory";
		return NULL;
	}
	d->d.ops = &ops;
	snprintf(d->d.name, sizeof(d->d.name), "%s", rte_cryptodev_name_get(c));
	d->d.nqp = nqp;
	d->d.events = p->events;
	d->cdev = c;
	d->max_sa = p->max_sa;
	d->ctx = rte_cryptodev_get_sec_ctx(c);
	if (!d->ctx) {
		*why = "the SEC has no rte_security";
		goto fail;
	}
	ssz = rte_security_session_get_size(d->ctx);
	if (rte_cryptodev_sym_get_private_session_size(c) > ssz)
		ssz = rte_cryptodev_sym_get_private_session_size(c);
	d->sess_mp = rte_cryptodev_sym_session_pool_create("esp_sess", p->max_sa, ssz, 0, 0,
							   p->socket_id);
	d->op_mp = rte_crypto_op_pool_create("esp_ops", RTE_CRYPTO_OP_TYPE_SYMMETRIC,
					     p->nworkers * nqp * QP_DESC + p->nworkers * 2 * 64, 64,
					     sizeof(struct esp_job), p->socket_id);
	d->sess = rte_zmalloc_socket("esp_sec_sa", p->max_sa * sizeof(*d->sess), 0, p->socket_id);
	*why = "no memory";
	if (!d->sess_mp || !d->op_mp || !d->sess)
		goto fail;
	cfg.nb_queue_pairs = (uint16_t)(p->nworkers * nqp);
	*why = "the SEC could not be set up";
	if (rte_cryptodev_configure(c, &cfg))
		goto fail;
	qc.mp_session = d->sess_mp;
	for (i = 0; i < cfg.nb_queue_pairs; i++)
		if (rte_cryptodev_queue_pair_setup(c, (uint16_t)i, &qc, p->socket_id))
			goto fail;
	/* resets the DPSECI: see above */
	if (rte_cryptodev_start(c))
		goto fail;
	rte_cryptodev_stop(c);
	if (p->events && (*why = attach(d, p->nworkers)))
		goto fail;
	*why = "the SEC could not be started";
	if (rte_cryptodev_start(c))
		goto fail;
	if (d->adapter && rte_event_crypto_adapter_start(ADAPTER))
		goto fail;
	return &d->d;
fail:
	dev_free(&d->d);
	return NULL;
}
