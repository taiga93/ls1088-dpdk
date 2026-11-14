/*
 * The seam "ESP ops" (src/esp.h) on the build machine, with the OpenSSL
 * backend (tests/esp/esp_openssl.c) in place of the SEC. The tests look at
 * what comes back from the backend, in which order, and at the counters of
 * the SAs: the packets an SA makes, the credit that keeps a busy SA from
 * holding up the others of its queue pair, the jobs dropped beyond it.
 *
 *   esp_test EAL-ARGS [-- TEST...]
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_ip.h>
#include <rte_mbuf.h>
#include <rte_udp.h>

#include "../../src/esp.h"
#include "../esp/esp_openssl.h"
#include "testlib.h"

static struct rte_mempool *pool;

#define LEFT RTE_IPV4(192, 168, 2, 10)	/* the router, on the WAN */
#define RIGHT RTE_IPV4(192, 168, 2, 1)	/* the peer */
#define PC1 RTE_IPV4(192, 168, 5, 10)
#define FAR RTE_IPV4(10, 20, 0, 10)	/* behind the peer */

/* An inner IPv4/UDP packet of len bytes, PC1 to FAR, the payload from seed. */
static struct rte_mbuf *
inner(unsigned len, uint8_t seed, uint8_t tos, int df)
{
	struct rte_mbuf *m = rte_pktmbuf_alloc(pool);
	struct rte_ipv4_hdr *ip;
	struct rte_udp_hdr *udp;
	uint8_t *p;
	unsigned i;

	if (!m)
		return NULL;
	p = (uint8_t *)rte_pktmbuf_append(m, (uint16_t)len);
	ip = (struct rte_ipv4_hdr *)p;
	udp = (struct rte_udp_hdr *)(ip + 1);
	for (i = sizeof(*ip) + sizeof(*udp); i < len; i++)
		p[i] = (uint8_t)(seed + i);
	*ip = (struct rte_ipv4_hdr){
		.version_ihl = RTE_IPV4_VHL_DEF,
		.type_of_service = tos,
		.total_length = rte_cpu_to_be_16((uint16_t)len),
		.fragment_offset = rte_cpu_to_be_16(df ? RTE_IPV4_HDR_DF_FLAG : 0),
		.time_to_live = 63,
		.next_proto_id = IPPROTO_UDP,
		.src_addr = rte_cpu_to_be_32(PC1),
		.dst_addr = rte_cpu_to_be_32(FAR),
	};
	ip->hdr_checksum = rte_ipv4_cksum(ip);
	*udp = (struct rte_udp_hdr){
		.src_port = rte_cpu_to_be_16(40000),
		.dst_port = rte_cpu_to_be_16(5201),
		.dgram_len = rte_cpu_to_be_16((uint16_t)(len - sizeof(*ip))),
	};
	return m;
}

static int
same(const struct rte_mbuf *a, const struct rte_mbuf *b)
{
	return a->pkt_len == b->pkt_len &&
	       !memcmp(rte_pktmbuf_mtod(a, const void *), rte_pktmbuf_mtod(b, const void *),
		       a->pkt_len);
}

static struct rte_mbuf *
copy(const struct rte_mbuf *m)
{
	return rte_pktmbuf_copy(m, pool, 0, UINT32_MAX);
}

/* An SA of the tunnel LEFT <-> RIGHT; its inbound twin has the same keys. */
static struct esp_sa_conf
sa_conf(int dir, int cipher, int auth, unsigned key_len, int udp)
{
	struct esp_sa_conf c = {
		.dir = (uint8_t)dir,
		.cipher = (uint8_t)cipher,
		.auth = (uint8_t)auth,
		.key_len = (uint8_t)key_len,
		.salt = { 0xa1, 0xb2, 0xc3, 0xd4 },
		.spi = 0xc0010001,
		.src = rte_cpu_to_be_32(LEFT),
		.dst = rte_cpu_to_be_32(RIGHT),
		.sport = udp ? 4500 : 0,
		.dport = udp ? 4500 : 0,
	};
	unsigned i;

	for (i = 0; i < sizeof(c.key); i++)
		c.key[i] = (uint8_t)(0x10 + i);
	c.auth_key_len = esp_auth_key_len[auth];
	for (i = 0; i < c.auth_key_len; i++)
		c.auth_key[i] = (uint8_t)(0x40 + i);
	return c;
}

static struct esp_sa_conf
inbound(struct esp_sa_conf c)
{
	c.dir = ESP_IN;
	c.src ^= c.dst;
	c.dst ^= c.src;
	c.src ^= c.dst;
	return c;
}

/* An esp of 1 worker with 2 queue pairs, and its backend. */
static struct esp *
esp_new(struct esp_dev **dev)
{
	struct esp_params p = { .nworkers = 1, .max_sa = 64, .socket_id = SOCKET_ID_ANY };

	*dev = esp_openssl_create(1, 64, 2);
	return *dev ? esp_create(&p, *dev) : NULL;
}

/* Runs one job through the backend; the result in *r. 1: it came back. */
static int
run1(struct esp *e, uint32_t sa, struct rte_mbuf *m, struct rte_mbuf *dst, struct esp_result *r)
{
	struct esp_job j = { .m = m, .dst = dst, .sa = sa };

	if (esp_submit(e, 0, &j, 1))
		return 0;
	return esp_poll(e, 0, r, 1) == 1;
}

/* The outer header of an ESP packet made by SA c. */
static int
outer_is(const struct rte_mbuf *m, const struct esp_sa_conf *c, uint32_t seq, uint8_t tos, int df)
{
	const struct rte_ipv4_hdr *ip = rte_pktmbuf_mtod(m, const struct rte_ipv4_hdr *);
	const uint8_t *esp = (const uint8_t *)(ip + 1);
	struct rte_ipv4_hdr h = *ip;

	h.hdr_checksum = 0;
	CHECKR(ip->version_ihl == RTE_IPV4_VHL_DEF);
	CHECKR(rte_be_to_cpu_16(ip->total_length) == m->pkt_len);
	CHECKR(rte_ipv4_cksum(&h) == ip->hdr_checksum);
	CHECKR(ip->src_addr == c->src && ip->dst_addr == c->dst);
	CHECKR(ip->time_to_live == 64);
	CHECKR(ip->type_of_service == (tos & 0xfc));
	CHECKR(!!(rte_be_to_cpu_16(ip->fragment_offset) & RTE_IPV4_HDR_DF_FLAG) == df);
	if (c->sport) {
		const struct rte_udp_hdr *u = (const struct rte_udp_hdr *)esp;

		CHECKR(ip->next_proto_id == IPPROTO_UDP);
		CHECKR(rte_be_to_cpu_16(u->src_port) == c->sport);
		CHECKR(rte_be_to_cpu_16(u->dst_port) == c->dport);
		CHECKR(rte_be_to_cpu_16(u->dgram_len) == m->pkt_len - sizeof(*ip));
		CHECKR(u->dgram_cksum == 0);
		esp += sizeof(*u);
	} else {
		CHECKR(ip->next_proto_id == IPPROTO_ESP);
	}
	CHECKR(rte_be_to_cpu_32(*(const uint32_t *)esp) == c->spi);
	CHECKR(rte_be_to_cpu_32(*(const uint32_t *)(esp + 4)) == seq);
	return 0;
}

/* Each algorithm of the spec, plain ESP and ESP in UDP: out, then back in. */
TEST(an_outbound_sa_makes_esp_that_its_inbound_twin_turns_back)
{
	static const struct { int cipher, auth; unsigned key_len; } algo[] = {
		{ ESP_AES_CBC, ESP_HMAC_SHA1_96, 16 },
		{ ESP_AES_CBC, ESP_HMAC_SHA256_128, 32 },
		{ ESP_AES_CBC, ESP_HMAC_SHA384_192, 32 },
		{ ESP_AES_CBC, ESP_HMAC_SHA512_256, 16 },
		{ ESP_AES_GCM, ESP_AUTH_NONE, 16 },
		{ ESP_AES_GCM, ESP_AUTH_NONE, 32 },
	};
	unsigned a, udp, len;

	for (a = 0; a < sizeof(algo) / sizeof(algo[0]); a++)
		for (udp = 0; udp < 2; udp++) {
			struct esp_dev *d;
			struct esp *e = esp_new(&d);
			struct esp_sa_conf out = sa_conf(ESP_OUT, algo[a].cipher, algo[a].auth,
							 algo[a].key_len, (int)udp);
			struct esp_sa_conf in = inbound(out);
			uint32_t seq = 0;

			CHECK(e);
			CHECK(esp_sa_add(e, 1, &out) == 0);
			CHECK(esp_sa_add(e, 2, &in) == 0);
			for (len = 28; len <= 1400; len += 343) {
				struct rte_mbuf *m = inner(len, (uint8_t)len, 0x29, len & 1);
				struct rte_mbuf *want = copy(m);
				struct esp_result r;
				unsigned blk = algo[a].cipher == ESP_AES_CBC ? 16 : 4;
				unsigned iv = algo[a].cipher == ESP_AES_CBC ? 16 : 8;
				unsigned icv = esp_icv_len[algo[a].auth];

				CHECK(run1(e, 1, m, NULL, &r) && r.ok && r.job.m == m);
				CHECK(!outer_is(m, &out, ++seq, 0x29, (int)(len & 1)));
				CHECK(m->pkt_len == 20 + (udp ? 8 : 0) + 8 + iv +
				      RTE_ALIGN_CEIL(len + 2, blk) + icv);
				CHECK(run1(e, 2, m, NULL, &r) && r.ok);
				CHECK(same(m, want));
				rte_pktmbuf_free(m);
				rte_pktmbuf_free(want);
			}
			esp_free(e);
		}
}

/*
 * The frame of a pcap with one frame, without its Ethernet header, in an
 * mbuf; NULL when it cannot be read.
 */
static struct rte_mbuf *
pcap_frame(const char *name)
{
	char path[512];
	uint8_t buf[2048];
	struct rte_mbuf *m = NULL;
	FILE *f;
	size_t n;

	snprintf(path, sizeof(path), "%s/%s.pcap", getenv("ESP_LINUX") ? getenv("ESP_LINUX") : ".",
		 name);
	f = fopen(path, "rb");
	if (!f)
		return NULL;
	/* the file header, the header of the frame, the Ethernet header */
	n = fread(buf, 1, sizeof(buf), f);
	fclose(f);
	if (n > 24 + 16 + 14 && (m = rte_pktmbuf_alloc(pool)))
		memcpy(rte_pktmbuf_append(m, (uint16_t)(n - 54)), buf + 54, n - 54);
	return m;
}

/*
 * ESP the Linux kernel of the board made with the same keys (tests/esp/
 * linux-esp.sh): a ping of PC1 to FAR, 100 bytes of data, sequence number 1.
 */
TEST(an_inbound_sa_takes_the_esp_linux_made)
{
	static const struct { const char *name; int cipher, auth; unsigned key_len, udp; } fx[] = {
		{ "cbc256-sha256-udp", ESP_AES_CBC, ESP_HMAC_SHA256_128, 32, 1 },
		{ "cbc128-sha1-esp", ESP_AES_CBC, ESP_HMAC_SHA1_96, 16, 0 },
		{ "cbc128-sha384-esp", ESP_AES_CBC, ESP_HMAC_SHA384_192, 16, 0 },
		{ "cbc256-sha512-udp", ESP_AES_CBC, ESP_HMAC_SHA512_256, 32, 1 },
		{ "gcm256-udp", ESP_AES_GCM, ESP_AUTH_NONE, 32, 1 },
		{ "gcm128-esp", ESP_AES_GCM, ESP_AUTH_NONE, 16, 0 },
	};
	unsigned i;

	for (i = 0; i < sizeof(fx) / sizeof(fx[0]); i++) {
		struct esp_dev *d;
		struct esp *e = esp_new(&d);
		struct esp_sa_conf in = sa_conf(ESP_IN, fx[i].cipher, fx[i].auth, fx[i].key_len,
						(int)fx[i].udp);
		struct rte_mbuf *m = pcap_frame(fx[i].name);
		const struct rte_ipv4_hdr *ip;
		struct esp_result r;

		CHECK(e && m);
		/* the inbound SA of the peer, from the router to it */
		in.replay = 32;
		CHECK(esp_sa_add(e, 1, &in) == 0);
		CHECK(run1(e, 1, m, NULL, &r) && r.ok);
		ip = rte_pktmbuf_mtod(m, const struct rte_ipv4_hdr *);
		CHECK(m->pkt_len == 128 && rte_be_to_cpu_16(ip->total_length) == 128);
		CHECK(ip->src_addr == rte_cpu_to_be_32(PC1) && ip->dst_addr == rte_cpu_to_be_32(FAR));
		CHECK(ip->next_proto_id == IPPROTO_ICMP && rte_ipv4_cksum(ip) == 0);
		rte_pktmbuf_free(m);
		esp_free(e);
	}
}

TEST(the_sequence_numbers_of_an_sa_start_at_1_and_the_ip_ids_at_0)
{
	struct esp_dev *d;
	struct esp *e = esp_new(&d);
	struct esp_sa_conf out = sa_conf(ESP_OUT, ESP_AES_GCM, ESP_AUTH_NONE, 32, 1);
	unsigned i;

	CHECK(e);
	CHECK(esp_sa_add(e, 1, &out) == 0);
	for (i = 0; i < 3; i++) {
		struct rte_mbuf *m = inner(100, 1, 0, 0);
		struct esp_result r;

		CHECK(run1(e, 1, m, NULL, &r) && r.ok);
		CHECK(!outer_is(m, &out, i + 1, 0, 0));
		CHECK(rte_pktmbuf_mtod(m, struct rte_ipv4_hdr *)->packet_id == rte_cpu_to_be_16(i));
		rte_pktmbuf_free(m);
	}
	esp_free(e);
}

/*
 * An SA the kernel already sent on goes on from a number the engine sets
 * (ticket 15): the first packet carries it, the next ones follow.
 */
TEST(an_outbound_sa_starts_at_the_number_it_is_given)
{
	struct esp_dev *d;
	struct esp *e = esp_new(&d);
	struct esp_sa_conf out = sa_conf(ESP_OUT, ESP_AES_CBC, ESP_HMAC_SHA256_128, 32, 1);
	unsigned i;

	CHECK(e);
	out.seq = (1u << 24) + 5;
	CHECK(esp_sa_add(e, 1, &out) == 0);
	for (i = 0; i < 3; i++) {
		struct rte_mbuf *m = inner(100, 1, 0, 0);
		struct esp_result r;

		CHECK(run1(e, 1, m, NULL, &r) && r.ok);
		CHECK(!outer_is(m, &out, (1u << 24) + 5 + i, 0, 0));
		rte_pktmbuf_free(m);
	}
	esp_free(e);
}

/*
 * Jobs of len bytes of one SA in its queue pair at once: an SA takes one
 * more while its work there is under ESP_SA_BUDGET.
 */
static unsigned
credit_jobs(unsigned len)
{
	return (ESP_SA_BUDGET + esp_cost(len) - 1) / esp_cost(len);
}

/*
 * taken counts every job an SA took, sent to the queue pair or waiting for
 * credit, and none it dropped: an outbound SA has used no number past
 * first + taken - 1, whatever is still in flight.
 */
TEST(taken_counts_the_jobs_an_sa_took_in_flight_or_waiting)
{
	struct esp_dev *d;
	struct esp *e = esp_new(&d);
	struct esp_sa_conf out = sa_conf(ESP_OUT, ESP_AES_CBC, ESP_HMAC_SHA256_128, 32, 1);
	unsigned credit = credit_jobs(1400), i, n = credit + ESP_SA_WAIT + 8, back = 0;
	struct esp_job j[ESP_SA_BUDGET / ESP_COST_JOB + ESP_SA_WAIT + 8];
	struct esp_sa_stats st;
	struct esp_result r[ESP_SA_BUDGET / ESP_COST_JOB + ESP_SA_WAIT + 8];

	CHECK(e);
	esp_openssl_hold(d, 1);
	CHECK(esp_sa_add(e, 1, &out) == 0);
	for (i = 0; i < n; i++)
		j[i] = (struct esp_job){ .m = inner(1400, 1, 0, 0), .sa = 1 };
	/* the credit's jobs of 1400 B, ESP_SA_WAIT wait, the rest are dropped */
	CHECK(esp_submit(e, 0, j, n) == n - credit - ESP_SA_WAIT);
	CHECK(esp_sa_stats(e, 1, &st) == 0);
	CHECK(st.taken == credit + ESP_SA_WAIT && st.queued == credit && st.waiting == ESP_SA_WAIT);
	esp_openssl_release(d, 0, 0, n);
	while (back < credit + ESP_SA_WAIT) {
		unsigned k = esp_poll(e, 0, r, n);

		CHECK(k);
		for (i = 0; i < k; i++)
			rte_pktmbuf_free(r[i].job.m);
		back += k;
	}
	CHECK(esp_sa_stats(e, 1, &st) == 0);
	CHECK(st.taken == credit + ESP_SA_WAIT && st.ok == credit + ESP_SA_WAIT && !st.queued && !st.waiting);
	esp_free(e);
}

/* Out of place: the result goes to dst, the ESP given stays for the kernel. */
TEST(out_of_place_the_packet_given_stays_as_it_was)
{
	struct esp_dev *d;
	struct esp *e = esp_new(&d);
	struct esp_sa_conf out = sa_conf(ESP_OUT, ESP_AES_CBC, ESP_HMAC_SHA256_128, 32, 1);
	struct esp_sa_conf in = inbound(out);
	struct rte_mbuf *m = inner(600, 3, 0, 1), *want = copy(m), *esp, *dst;
	struct esp_result r;

	CHECK(e);
	CHECK(esp_sa_add(e, 1, &out) == 0 && esp_sa_add(e, 2, &in) == 0);
	CHECK(run1(e, 1, m, NULL, &r) && r.ok);
	esp = copy(m);
	dst = rte_pktmbuf_alloc(pool);
	CHECK(run1(e, 2, m, dst, &r) && r.ok);
	CHECK(r.job.m == m && r.job.dst == dst);
	CHECK(same(dst, want));
	CHECK(same(m, esp));
	rte_pktmbuf_free(m);
	rte_pktmbuf_free(dst);
	rte_pktmbuf_free(esp);
	rte_pktmbuf_free(want);
	esp_free(e);
}

TEST(esp_changed_on_its_way_fails_and_is_counted)
{
	struct esp_dev *d;
	struct esp *e = esp_new(&d);
	struct esp_sa_conf out = sa_conf(ESP_OUT, ESP_AES_CBC, ESP_HMAC_SHA1_96, 16, 0);
	struct esp_sa_conf in = inbound(out);
	struct esp_sa_conf gout = sa_conf(ESP_OUT, ESP_AES_GCM, ESP_AUTH_NONE, 16, 0);
	struct esp_sa_conf gin = inbound(gout);
	struct esp_sa_stats st;
	uint32_t sa;

	CHECK(e);
	gout.spi = gin.spi = 0xc0010002;
	CHECK(esp_sa_add(e, 1, &out) == 0 && esp_sa_add(e, 2, &in) == 0);
	CHECK(esp_sa_add(e, 3, &gout) == 0 && esp_sa_add(e, 4, &gin) == 0);
	for (sa = 1; sa <= 3; sa += 2) {
		struct rte_mbuf *m = inner(300, 9, 0, 0);
		struct esp_result r;

		CHECK(run1(e, sa, m, NULL, &r) && r.ok);
		rte_pktmbuf_mtod(m, uint8_t *)[m->pkt_len - 40] ^= 1;
		CHECK(run1(e, sa + 1, m, NULL, &r) && !r.ok);
		CHECK(esp_sa_stats(e, sa + 1, &st) == 0 && st.failed == 1 && st.ok == 0);
		rte_pktmbuf_free(m);
	}
	esp_free(e);
}

TEST(an_inbound_sa_with_a_window_refuses_a_packet_it_had)
{
	struct esp_dev *d;
	struct esp *e = esp_new(&d);
	struct esp_sa_conf out = sa_conf(ESP_OUT, ESP_AES_GCM, ESP_AUTH_NONE, 32, 1);
	struct esp_sa_conf in = inbound(out), off = inbound(out);
	struct rte_mbuf *m = inner(200, 5, 0, 0), *esp;
	struct esp_result r;

	CHECK(e);
	in.replay = 32;
	CHECK(esp_sa_add(e, 1, &out) == 0 && esp_sa_add(e, 2, &in) == 0);
	CHECK(esp_sa_add(e, 3, &off) == 0);
	CHECK(run1(e, 1, m, NULL, &r) && r.ok);
	esp = copy(m);
	CHECK(run1(e, 2, m, NULL, &r) && r.ok);
	rte_pktmbuf_free(m);
	m = copy(esp);
	CHECK(run1(e, 2, m, NULL, &r) && !r.ok);
	rte_pktmbuf_free(m);
	/* anti-replay off, as the session that decrypts again what the kernel sent */
	m = copy(esp);
	CHECK(run1(e, 3, m, NULL, &r) && r.ok);
	rte_pktmbuf_free(m);
	m = copy(esp);
	CHECK(run1(e, 3, m, NULL, &r) && r.ok);
	rte_pktmbuf_free(m);
	rte_pktmbuf_free(esp);
	esp_free(e);
}

/*
 * The credit. SA 1 (busy) and SA 2 share lane 0, so queue pair 0. The
 * backend gives back one result at a time, as a SEC that finishes the jobs
 * of the queue pair in order: how many come back before the one job of SA
 * 2 is how long it waited behind SA 1.
 */
static unsigned
results_before(struct esp *e, struct esp_dev *d, unsigned busy_len, unsigned busy_jobs,
	       unsigned *busy_done)
{
	struct esp_job j[256];
	struct esp_result r[1];
	unsigned i, before = 0, guard = 0;

	*busy_done = 0;
	for (i = 0; i < busy_jobs; i++)
		j[i] = (struct esp_job){ .m = inner(busy_len, 1, 0, 0), .sa = 1 };
	j[i++] = (struct esp_job){ .m = inner(1400, 2, 0, 0), .sa = 2 };
	esp_openssl_hold(d, 1);
	esp_submit(e, 0, j, i);
	for (;;) {
		esp_openssl_release(d, 0, 0, 1);
		if (esp_poll(e, 0, r, 1) != 1) {
			if (++guard > 2)
				break;
			continue;
		}
		guard = 0;
		rte_pktmbuf_free(r[0].job.m);
		if (r[0].job.sa == 2)
			break;
		before++;
	}
	/* the rest of SA 1 */
	esp_openssl_hold(d, 0);
	while (esp_poll(e, 0, r, 1) == 1) {
		rte_pktmbuf_free(r[0].job.m);
		(*busy_done)++;
	}
	*busy_done += before;
	return before;
}

static struct esp *
two_sas_one_queue_pair(struct esp_dev **d)
{
	struct esp *e = esp_new(d);
	struct esp_sa_conf c = sa_conf(ESP_OUT, ESP_AES_CBC, ESP_HMAC_SHA256_128, 32, 1);

	if (!e || esp_sa_add(e, 1, &c))
		return NULL;
	c.spi++;
	if (esp_sa_add(e, 2, &c))
		return NULL;
	return e;
}

/* What esp.h says the default budget lets in (ticket 22): 6, 14 and 37 jobs. */
TEST(the_default_budget_lets_6_14_and_37_jobs_in)
{
#if ESP_SA_BUDGET == 24000
	CHECK(credit_jobs(1400) == 6 && credit_jobs(512) == 14 && credit_jobs(64) == 37);
#endif
}

TEST(a_busy_sa_does_not_hold_up_another_sa_of_its_queue_pair)
{
	static const unsigned size[] = { 1400, 512, 64 };
	unsigned s;

	for (s = 0; s < 3; s++) {
		struct esp_dev *d;
		struct esp *e = two_sas_one_queue_pair(&d);
		unsigned busy = credit_jobs(size[s]) + 20, done;

		CHECK(e);
		CHECK(busy < 256);
		/* more jobs at once than the credit: what fits it, the others wait */
		CHECK(results_before(e, d, size[s], busy, &done) == credit_jobs(size[s]));
		CHECK(done == busy);
		esp_free(e);
	}
}

TEST(the_jobs_of_an_sa_keep_their_order)
{
	struct esp_dev *d;
	struct esp *e = two_sas_one_queue_pair(&d);
	struct esp_job j[40];
	struct esp_result r[8];
	unsigned i, n, k, got = 0;
	uint32_t next = 1;

	CHECK(e);
	for (i = 0; i < 40; i++)
		j[i] = (struct esp_job){ .m = inner(1400, 1, 0, 0), .sa = 1 + (i % 3 == 2) };
	/* more than the credit of SA 1: some wait, and go on as results come back */
	CHECK(esp_submit(e, 0, j, 20) == 0);
	CHECK(esp_submit(e, 0, j + 20, 20) == 0);
	while ((n = esp_poll(e, 0, r, 8)) > 0)
		for (k = 0; k < n; k++, got++) {
			const uint8_t *p = rte_pktmbuf_mtod(r[k].job.m, const uint8_t *) + 28;

			CHECK(r[k].ok);
			if (r[k].job.sa == 1) {
				CHECK(rte_be_to_cpu_32(*(const uint32_t *)(p + 4)) == next);
				next++;
			}
			rte_pktmbuf_free(r[k].job.m);
		}
	CHECK(got == 40);
	CHECK(next == 1 + 27);
	esp_free(e);
}

/* bursts of one SA, more than its credit and its wait take */
#define BURSTS ((ESP_SA_WAIT + ESP_SA_BUDGET / ESP_COST_JOB) / ESP_BURST + 2)

TEST(jobs_beyond_the_credit_and_the_wait_are_dropped_and_counted)
{
	struct esp_dev *d;
	struct esp *e = two_sas_one_queue_pair(&d);
	unsigned free_before = rte_mempool_avail_count(pool), i, dropped = 0;
	struct esp_job j[ESP_BURST];
	struct esp_result r[ESP_BURST];
	struct esp_sa_stats st;

	CHECK(e);
	esp_openssl_hold(d, 1);
	for (i = 0; i < BURSTS; i++) {
		unsigned k;

		for (k = 0; k < ESP_BURST; k++)
			j[k] = (struct esp_job){ .m = inner(1400, 1, 0, 0), .sa = 1 };
		dropped += esp_submit(e, 0, j, ESP_BURST);
	}
	/* the credit's jobs in the queue pair, ESP_SA_WAIT waiting */
	CHECK(dropped == BURSTS * ESP_BURST - credit_jobs(1400) - ESP_SA_WAIT);
	CHECK(esp_sa_stats(e, 1, &st) == 0);
	CHECK(st.dropped == dropped && st.queued == credit_jobs(1400) && st.waiting == ESP_SA_WAIT);
	CHECK(esp_openssl_queued(d, 0, 0) == credit_jobs(1400));
	esp_openssl_hold(d, 0);
	for (;;) {
		unsigned n = esp_poll(e, 0, r, ESP_BURST), k;

		if (!n)
			break;
		for (k = 0; k < n; k++)
			rte_pktmbuf_free(r[k].job.m);
	}
	CHECK(esp_sa_stats(e, 1, &st) == 0);
	CHECK(st.ok == credit_jobs(1400) + ESP_SA_WAIT && st.queued == 0 && st.waiting == 0);
	CHECK(rte_mempool_avail_count(pool) == free_before);
	esp_free(e);
}

TEST(sas_of_another_lane_go_to_the_other_queue_pair)
{
	struct esp_dev *d;
	struct esp *e = esp_new(&d);
	struct esp_sa_conf c = sa_conf(ESP_OUT, ESP_AES_CBC, ESP_HMAC_SHA256_128, 32, 1);
	struct esp_job j[2] = {
		{ .m = inner(1400, 1, 0, 0), .sa = 1 },
		{ .m = inner(1400, 1, 0, 0), .sa = 2 },
	};
	struct esp_result r[2];

	CHECK(e);
	c.lane = 6;
	CHECK(esp_sa_add(e, 1, &c) == 0);
	c.spi++;
	c.lane = 7;
	CHECK(esp_sa_add(e, 2, &c) == 0);
	esp_openssl_hold(d, 1);
	CHECK(esp_submit(e, 0, j, 2) == 0);
	CHECK(esp_openssl_queued(d, 0, 0) == 1 && esp_openssl_queued(d, 0, 1) == 1);
	esp_openssl_release(d, 0, 1, 1);
	CHECK(esp_poll(e, 0, r, 2) == 1 && r[0].job.sa == 2);
	rte_pktmbuf_free(r[0].job.m);
	esp_openssl_release(d, 0, 0, 1);
	CHECK(esp_poll(e, 0, r, 2) == 1 && r[0].job.sa == 1);
	rte_pktmbuf_free(r[0].job.m);
	esp_free(e);
}

TEST(a_job_of_an_sa_that_does_not_exist_is_dropped)
{
	struct esp_dev *d;
	struct esp *e = esp_new(&d);
	unsigned free_before = rte_mempool_avail_count(pool);
	struct esp_job j[2] = {
		{ .m = inner(100, 1, 0, 0), .sa = 5 },
		{ .m = inner(100, 1, 0, 0), .dst = inner(100, 1, 0, 0), .sa = 64 },
	};
	struct esp_result r;

	CHECK(e);
	CHECK(esp_submit(e, 0, j, 2) == 2);
	CHECK(esp_poll(e, 0, &r, 1) == 0);
	CHECK(rte_mempool_avail_count(pool) == free_before);
	esp_free(e);
}

TEST(sas_are_added_once_and_deleted_once_nothing_of_them_is_left)
{
	struct esp_dev *d;
	struct esp *e = esp_new(&d);
	struct esp_sa_conf c = sa_conf(ESP_OUT, ESP_AES_GCM, ESP_AUTH_NONE, 16, 0);
	struct esp_job j = { .sa = 3 };
	struct esp_result r;
	struct esp_sa_stats st;

	CHECK(e);
	CHECK(esp_sa_add(e, 64, &c) == -EINVAL);
	CHECK(esp_sa_add(e, 3, &c) == 0);
	CHECK(esp_sa_add(e, 3, &c) == -EEXIST);
	CHECK(esp_sa_count(e) == 1);
	esp_openssl_hold(d, 1);
	j.m = inner(100, 1, 0, 0);
	CHECK(esp_submit(e, 0, &j, 1) == 0);
	CHECK(esp_sa_del(e, 3) == -EBUSY);
	esp_openssl_hold(d, 0);
	CHECK(esp_poll(e, 0, &r, 1) == 1);
	rte_pktmbuf_free(r.job.m);
	CHECK(esp_sa_del(e, 3) == 0);
	CHECK(esp_sa_del(e, 3) == -ENOENT);
	CHECK(esp_sa_stats(e, 3, &st) == -ENOENT);
	CHECK(esp_sa_count(e) == 0);
	/* the same number again: a new SA, its counters from 0 */
	CHECK(esp_sa_add(e, 3, &c) == 0);
	CHECK(esp_sa_stats(e, 3, &st) == 0 && st.ok == 0);
	esp_free(e);
}

TEST(an_sa_the_backend_cannot_do_is_refused)
{
	struct esp_dev *d;
	struct esp *e = esp_new(&d);
	struct esp_sa_conf c = sa_conf(ESP_OUT, ESP_AES_CBC, ESP_HMAC_SHA256_128, 24, 0);

	CHECK(e);
	CHECK(esp_sa_add(e, 1, &c) == -EINVAL);
	c = sa_conf(ESP_OUT, ESP_AES_GCM, ESP_HMAC_SHA256_128, 16, 0);
	CHECK(esp_sa_add(e, 1, &c) == -EINVAL);
	CHECK(esp_sa_count(e) == 0);
	esp_free(e);
}

int
main(int argc, char **argv)
{
	int n = rte_eal_init(argc, argv);

	if (n < 0) {
		fprintf(stderr, "rte_eal_init failed\n");
		return 2;
	}
	argc -= n;
	argv += n;
	pool = rte_pktmbuf_pool_create("test", 1023, 0, 0, RTE_MBUF_DEFAULT_BUF_SIZE, SOCKET_ID_ANY);
	if (!pool) {
		fprintf(stderr, "no mbuf pool\n");
		return 2;
	}
	return test_main(argc - 1, argv + 1);
}
