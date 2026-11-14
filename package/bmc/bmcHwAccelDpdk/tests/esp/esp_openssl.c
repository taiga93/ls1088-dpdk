/*
 * The OpenSSL backend of "ESP ops" (esp_openssl.h): RFC 4303 tunnel mode,
 * RFC 3948 ESP in UDP, RFC 4106 AES-GCM.
 */
#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/evp.h>
#include <openssl/hmac.h>

#include <rte_byteorder.h>
#include <rte_ip.h>
#include <rte_malloc.h>
#include <rte_spinlock.h>
#include <rte_udp.h>

#include "esp_openssl.h"

#define MAX_LEN 8192		/* largest packet in or out: ESP of large packets put together too */

struct sa {
	struct esp_sa_conf c;
	int used;
	uint32_t seq;		/* outbound: the last one sent */
	uint16_t ip_id;
	rte_spinlock_t lock;	/* inbound: the window */
	uint32_t top;		/* highest sequence number taken */
	unsigned __int128 bits;	/* bit i: top - i was taken */
};

struct qp {
	struct esp_result r[ESP_OPENSSL_QP_DEPTH];
	unsigned head, n;
	unsigned allowed;	/* results that may come back while held */
};

struct dev {
	struct esp_dev d;
	unsigned nworkers, max_sa;
	int hold;
	struct sa *sa;
	struct qp *qp;		/* nworkers x nqp */
};

static const EVP_MD *
md_of(int auth)
{
	switch (auth) {
	case ESP_HMAC_SHA1_96: return EVP_sha1();
	case ESP_HMAC_SHA256_128: return EVP_sha256();
	case ESP_HMAC_SHA384_192: return EVP_sha384();
	default: return EVP_sha512();
	}
}

/* ICV bytes: the truncated HMAC, or the tag of GCM */
static unsigned
icv_len(const struct esp_sa_conf *c)
{
	return esp_icv_len[c->auth];
}

static const EVP_CIPHER *
cipher_of(const struct esp_sa_conf *c)
{
	if (c->cipher == ESP_AES_GCM)
		return c->key_len == 16 ? EVP_aes_128_gcm() : EVP_aes_256_gcm();
	return c->key_len == 16 ? EVP_aes_128_cbc() : EVP_aes_256_cbc();
}

static int
gcm(const struct esp_sa_conf *c, int enc, const uint8_t *iv8, const uint8_t *aad,
    const uint8_t *in, unsigned len, uint8_t *out, uint8_t *tag)
{
	EVP_CIPHER_CTX *x = EVP_CIPHER_CTX_new();
	uint8_t nonce[12];
	int n, ok;

	memcpy(nonce, c->salt, 4);
	memcpy(nonce + 4, iv8, 8);
	ok = x && EVP_CipherInit_ex(x, cipher_of(c), NULL, NULL, NULL, enc) &&
	     EVP_CIPHER_CTX_ctrl(x, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) &&
	     EVP_CipherInit_ex(x, NULL, NULL, c->key, nonce, enc) &&
	     EVP_CipherUpdate(x, NULL, &n, aad, 8) &&
	     EVP_CipherUpdate(x, out, &n, in, (int)len) &&
	     (enc || EVP_CIPHER_CTX_ctrl(x, EVP_CTRL_GCM_SET_TAG, 16, tag)) &&
	     EVP_CipherFinal_ex(x, out + n, &n) &&
	     (!enc || EVP_CIPHER_CTX_ctrl(x, EVP_CTRL_GCM_GET_TAG, 16, tag));
	EVP_CIPHER_CTX_free(x);
	return ok;
}

static int
cbc(const struct esp_sa_conf *c, int enc, const uint8_t *iv, const uint8_t *in, unsigned len,
    uint8_t *out)
{
	EVP_CIPHER_CTX *x = EVP_CIPHER_CTX_new();
	int n, m, ok;

	ok = x && EVP_CipherInit_ex(x, cipher_of(c), NULL, c->key, iv, enc) &&
	     EVP_CIPHER_CTX_set_padding(x, 0) &&
	     EVP_CipherUpdate(x, out, &n, in, (int)len) &&
	     EVP_CipherFinal_ex(x, out + n, &m);
	EVP_CIPHER_CTX_free(x);
	return ok;
}

static void
hmac(const struct esp_sa_conf *c, const uint8_t *in, unsigned len, uint8_t *out)
{
	unsigned n;

	HMAC(md_of(c->auth), c->auth_key, c->auth_key_len, in, len, out, &n);
}

static void
put(struct rte_mbuf *m, const uint8_t *p, unsigned len)
{
	rte_pktmbuf_reset_headroom(m);
	m->data_len = (uint16_t)len;
	m->pkt_len = len;
	memcpy(rte_pktmbuf_mtod(m, uint8_t *), p, len);
}

static int
encrypt(struct sa *s, const struct rte_mbuf *m, uint8_t *out, unsigned *out_len)
{
	const struct esp_sa_conf *c = &s->c;
	const struct rte_ipv4_hdr *in = rte_pktmbuf_mtod(m, const struct rte_ipv4_hdr *);
	unsigned gcm_mode = c->cipher == ESP_AES_GCM, blk = gcm_mode ? 4 : 16, iv_len = gcm_mode ? 8 : 16;
	unsigned udp = c->sport || c->dport ? sizeof(struct rte_udp_hdr) : 0;
	unsigned len = m->pkt_len, pad = RTE_ALIGN_CEIL(len + 2, blk) - len - 2, i;
	unsigned esp_off = sizeof(struct rte_ipv4_hdr) + udp, ct_off = esp_off + 8 + iv_len;
	unsigned ct_len = len + pad + 2, total = ct_off + ct_len + icv_len(c);
	struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)out;
	uint8_t plain[MAX_LEN], *esp = out + esp_off, *iv = esp + 8;
	uint32_t seq;

	if (m->nb_segs != 1 || len < sizeof(*in) || total > MAX_LEN)
		return 0;
	seq = __atomic_add_fetch(&s->seq, 1, __ATOMIC_RELAXED);
	*ip = (struct rte_ipv4_hdr){
		.version_ihl = RTE_IPV4_VHL_DEF,
		/* the SEC copies DSCP and, with copy_df, DF of the inner packet */
		.type_of_service = in->type_of_service & 0xfc,
		.total_length = rte_cpu_to_be_16((uint16_t)total),
		.packet_id = rte_cpu_to_be_16(__atomic_fetch_add(&s->ip_id, 1, __ATOMIC_RELAXED)),
		.fragment_offset = in->fragment_offset & rte_cpu_to_be_16(RTE_IPV4_HDR_DF_FLAG),
		.time_to_live = 64,
		.next_proto_id = udp ? IPPROTO_UDP : IPPROTO_ESP,
		.src_addr = c->src,
		.dst_addr = c->dst,
	};
	ip->hdr_checksum = rte_ipv4_cksum(ip);
	if (udp)
		*(struct rte_udp_hdr *)(ip + 1) = (struct rte_udp_hdr){
			.src_port = rte_cpu_to_be_16(c->sport),
			.dst_port = rte_cpu_to_be_16(c->dport),
			.dgram_len = rte_cpu_to_be_16((uint16_t)(total - sizeof(*ip))),
		};
	*(uint32_t *)esp = rte_cpu_to_be_32(c->spi);
	*(uint32_t *)(esp + 4) = rte_cpu_to_be_32(seq);
	/* from the SPI and the sequence number: the same packets make the same ESP */
	for (i = 0; i < iv_len; i += 8)
		memcpy(iv + i, esp, 8);
	memcpy(plain, rte_pktmbuf_mtod(m, const uint8_t *), len);
	for (i = 0; i < pad; i++)
		plain[len + i] = (uint8_t)(i + 1);
	plain[len + pad] = (uint8_t)pad;
	plain[len + pad + 1] = IPPROTO_IPIP;
	if (gcm_mode) {
		if (!gcm(c, 1, iv, esp, plain, ct_len, out + ct_off, out + ct_off + ct_len))
			return 0;
	} else {
		uint8_t mac[EVP_MAX_MD_SIZE];

		if (!cbc(c, 1, iv, plain, ct_len, out + ct_off))
			return 0;
		hmac(c, esp, 8 + iv_len + ct_len, mac);
		memcpy(out + ct_off + ct_len, mac, icv_len(c));
	}
	*out_len = total;
	return 1;
}

/* The anti-replay window of RFC 4303, 3.4.3, up to 128 as on the SEC; 1: seq may pass. */
static int
replay_check(struct sa *s, uint32_t seq, int take)
{
	uint32_t w = s->c.replay;

	if (!w)
		return 1;
	if (seq == 0)
		return 0;
	if (seq > s->top) {
		if (take) {
			uint32_t d = seq - s->top;

			s->bits = d >= 128 ? 1 : (s->bits << d) | 1;
			s->top = seq;
		}
		return 1;
	}
	if (s->top - seq >= w || (s->bits >> (s->top - seq)) & 1)
		return 0;
	if (take)
		s->bits |= (unsigned __int128)1 << (s->top - seq);
	return 1;
}

static int
decrypt(struct sa *s, const struct rte_mbuf *m, uint8_t *out, unsigned *out_len)
{
	const struct esp_sa_conf *c = &s->c;
	const uint8_t *p = rte_pktmbuf_mtod(m, const uint8_t *), *esp, *iv;
	const struct rte_ipv4_hdr *ip = (const struct rte_ipv4_hdr *)p;
	unsigned gcm_mode = c->cipher == ESP_AES_GCM, iv_len = gcm_mode ? 8 : 16, icv = icv_len(c);
	unsigned hl, len = m->pkt_len, ct_len, pad;
	uint32_t seq;
	int ok;

	if (m->nb_segs != 1 || len < sizeof(*ip))
		return 0;
	hl = (ip->version_ihl & 0xf) * 4u;
	esp = p + hl;
	if (ip->next_proto_id == IPPROTO_UDP)
		esp += sizeof(struct rte_udp_hdr);
	else if (ip->next_proto_id != IPPROTO_ESP)
		return 0;
	if (esp + 8 + iv_len + icv > p + len)
		return 0;
	ct_len = (unsigned)(p + len - esp) - 8 - iv_len - icv;
	if (rte_be_to_cpu_32(*(const uint32_t *)esp) != c->spi || ct_len > MAX_LEN ||
	    ct_len % (gcm_mode ? 4 : 16) || ct_len < 2)
		return 0;
	seq = rte_be_to_cpu_32(*(const uint32_t *)(esp + 4));
	iv = esp + 8;
	rte_spinlock_lock(&s->lock);
	ok = replay_check(s, seq, 0);
	rte_spinlock_unlock(&s->lock);
	if (!ok)
		return 0;
	if (gcm_mode) {
		uint8_t tag[16];

		memcpy(tag, iv + iv_len + ct_len, 16);
		if (!gcm(c, 0, iv, esp, iv + iv_len, ct_len, out, tag))
			return 0;
	} else {
		uint8_t mac[EVP_MAX_MD_SIZE];

		hmac(c, esp, 8 + iv_len + ct_len, mac);
		if (CRYPTO_memcmp(mac, iv + iv_len + ct_len, icv) ||
		    !cbc(c, 0, iv, iv + iv_len, ct_len, out))
			return 0;
	}
	pad = out[ct_len - 2];
	if (out[ct_len - 1] != IPPROTO_IPIP || pad + 2 > ct_len)
		return 0;
	rte_spinlock_lock(&s->lock);
	ok = replay_check(s, seq, 1);
	rte_spinlock_unlock(&s->lock);
	*out_len = ct_len - pad - 2;
	return ok;
}

static int
sa_add(struct esp_dev *ed, uint32_t sa, const struct esp_sa_conf *c)
{
	struct dev *d = (struct dev *)ed;

	if (sa >= d->max_sa || c->replay > 128)
		return -EINVAL;
	d->sa[sa] = (struct sa){ .c = *c, .used = 1, .seq = c->seq ? c->seq - 1 : 0 };
	rte_spinlock_init(&d->sa[sa].lock);
	return 0;
}

static void
sa_del(struct esp_dev *ed, uint32_t sa)
{
	struct dev *d = (struct dev *)ed;

	d->sa[sa].used = 0;
}

static struct qp *
qp_of(struct dev *d, unsigned w, unsigned q)
{
	return &d->qp[w * d->d.nqp + q];
}

static unsigned
enqueue(struct esp_dev *ed, unsigned w, unsigned q, const struct esp_job *jobs, unsigned n)
{
	struct dev *d = (struct dev *)ed;
	struct qp *p = qp_of(d, w, q);
	unsigned i;

	for (i = 0; i < n && p->n < ESP_OPENSSL_QP_DEPTH; i++) {
		struct esp_result *r = &p->r[(p->head + p->n++) % ESP_OPENSSL_QP_DEPTH];
		struct sa *s = &d->sa[jobs[i].sa];
		uint8_t out[MAX_LEN];
		unsigned len = 0;

		r->job = jobs[i];
		r->ok = s->used && (s->c.dir == ESP_OUT ? encrypt(s, jobs[i].m, out, &len) :
						       decrypt(s, jobs[i].m, out, &len));
		if (r->ok)
			put(jobs[i].dst ? jobs[i].dst : jobs[i].m, out, len);
	}
	return i;
}

static unsigned
dev_poll(struct esp_dev *ed, unsigned w, struct esp_result *r, unsigned max)
{
	struct dev *d = (struct dev *)ed;
	unsigned q, n = 0;

	for (q = 0; q < d->d.nqp; q++) {
		struct qp *p = qp_of(d, w, q);

		while (n < max && p->n && (!d->hold || p->allowed)) {
			r[n++] = p->r[p->head];
			p->head = (p->head + 1) % ESP_OPENSSL_QP_DEPTH;
			p->n--;
			if (d->hold)
				p->allowed--;
		}
	}
	return n;
}

static void
dev_free(struct esp_dev *ed)
{
	struct dev *d = (struct dev *)ed;

	rte_free(d->qp);
	rte_free(d->sa);
	rte_free(d);
}

static const struct esp_dev_ops ops = {
	.sa_add = sa_add,
	.sa_del = sa_del,
	.enqueue = enqueue,
	.poll = dev_poll,
	.free = dev_free,
};

struct esp_dev *
esp_openssl_create(unsigned nworkers, unsigned max_sa, unsigned nqp)
{
	struct dev *d = rte_zmalloc("esp_openssl", sizeof(*d), 0);

	if (!d)
		return NULL;
	d->d.ops = &ops;
	strcpy(d->d.name, "openssl");
	d->d.nqp = nqp;
	d->nworkers = nworkers;
	d->max_sa = max_sa;
	d->sa = rte_zmalloc("esp_openssl_sa", max_sa * sizeof(*d->sa), 0);
	d->qp = rte_zmalloc("esp_openssl_qp", nworkers * nqp * sizeof(*d->qp), 0);
	if (!d->sa || !d->qp) {
		dev_free(&d->d);
		return NULL;
	}
	return &d->d;
}

void
esp_openssl_hold(struct esp_dev *ed, int hold)
{
	struct dev *d = (struct dev *)ed;
	unsigned i;

	d->hold = hold;
	for (i = 0; i < d->nworkers * d->d.nqp; i++)
		d->qp[i].allowed = 0;
}

void
esp_openssl_release(struct esp_dev *ed, unsigned w, unsigned q, unsigned n)
{
	qp_of((struct dev *)ed, w, q)->allowed += n;
}

unsigned
esp_openssl_queued(struct esp_dev *ed, unsigned w, unsigned q)
{
	return qp_of((struct dev *)ed, w, q)->n;
}

/* The backend of the engine on the build machine: ESP_MAX_QP queue pairs a worker. */
struct esp_dev *
esp_dev_open(const struct esp_dev_params *p, const char **why)
{
	struct esp_dev *d = esp_openssl_create(p->nworkers, p->max_sa, ESP_MAX_QP);

	if (!d)
		*why = "no memory";
	return d;
}
