/*
 * Tunnel IPsec in the engine (src/ipsec.h) on the build machine, over "ESP
 * ops" with the OpenSSL backend, with the core (src/core.h) of the engine
 * around it. The kernel's ESP is what the Linux kernel of the board made
 * (tests/esp/linux) or what an OpenSSL SA with the same keys makes,
 * sequence number 1; what the engine sends is read back by the peer: an
 * inbound SA with the same keys, in a backend of its own. The peer's ESP is
 * made by an outbound SA of yet another backend. The tests look only at
 * what leaves the engine and what it says of its SAs and connections.
 *
 *   ipsec_test EAL-ARGS [-- TEST...]
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

#include <rte_cycles.h>
#include <rte_eal.h>
#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_mbuf.h>
#include <rte_tcp.h>
#include <rte_udp.h>

#include "../../src/ipsec.h"
#include "../esp/esp_openssl.h"
#include "testlib.h"

static struct rte_mempool *pool;
/* packets longer than one of pool: the tests' own, and the engine's datagrams put together */
static struct rte_mempool *big;

#define LEFT RTE_IPV4(192, 168, 2, 10)	/* the router, on the WAN */
#define RIGHT RTE_IPV4(192, 168, 2, 1)	/* the peer */
#define PC1 RTE_IPV4(192, 168, 5, 10)
#define FAR RTE_IPV4(10, 20, 0, 10)	/* behind the peer */
#define WIRE_ETH 6			/* the ethdevs of port 0, the WAN */
#define KERNEL_ETH 7
#define LAN_WIRE_ETH 8			/* and of port 1, the LAN */
#define LAN_KERNEL_ETH 9
#define WAN 0
#define LAN 1
#define NOW 1000			/* the core's clock */
#define SPI 0xc0010001u
#define SPI_IN 0xc0010002u		/* the peer's to the router */
#define FIRST ((1u << 24) + 1)		/* the engine's first number: oseq 1 + 2^24 */
#define MAX_GOT 64

static const uint8_t ROUTER_MAC[6] = { 2, 0, 0, 0, 0, 2 }, PEER_MAC[6] = { 2, 0, 0, 0, 0, 0xfe };
static const uint8_t ROUTER_LAN_MAC[6] = { 2, 0, 0, 0, 0, 1 }, PC1_MAC[6] = { 2, 0, 0, 0, 0, 0x0a };

/* An SA of the tunnel LEFT -> RIGHT with the keys of tests/esp/linux-esp.sh. */
static struct esp_sa_conf
sa_conf(int dir, int cipher, int auth, unsigned key_len, int udp)
{
	struct esp_sa_conf c = {
		.dir = (uint8_t)dir,
		.cipher = (uint8_t)cipher,
		.auth = (uint8_t)auth,
		.key_len = (uint8_t)key_len,
		.salt = { 0xa1, 0xb2, 0xc3, 0xd4 },
		.spi = SPI,
		.src = rte_cpu_to_be_32(LEFT),
		.dst = rte_cpu_to_be_32(RIGHT),
		.sport = udp ? 4500 : 0,
		.dport = udp ? 4500 : 0,
		.lane = 1,
	};
	unsigned i;

	for (i = 0; i < sizeof(c.key); i++)
		c.key[i] = (uint8_t)(0x10 + i);
	c.auth_key_len = esp_auth_key_len[auth];
	for (i = 0; i < c.auth_key_len; i++)
		c.auth_key[i] = (uint8_t)(0x40 + i);
	if (dir == ESP_OUT)
		c.seq = FIRST;
	return c;
}

/* The VPN page's tunnel: aes256-cbc + hmac-sha256-128, ESP in UDP. */
static struct esp_sa_conf
vpn(void)
{
	return sa_conf(ESP_OUT, ESP_AES_CBC, ESP_HMAC_SHA256_128, 32, 1);
}

/*
 * The engine of 2 workers (the tests use worker 0 unless they say) with
 * port 0 the WAN and port 1 the LAN (MTU 1500),
 * the peer that reads what it sends, the far end that sends the peer's
 * ESP, and the kernel's ESP.
 */
struct env {
	struct esp *e, *peer, *kernel, *far;
	struct esp_dev *d;
	struct core *c;
	struct ipsec *x;
};

static int
env_new(struct env *v, unsigned max_tunnels)
{
	struct esp_params ep = { .nworkers = 1, .max_sa = 64, .socket_id = SOCKET_ID_ANY };
	struct esp_params ep2 = { .nworkers = 2, .max_sa = 64, .socket_id = SOCKET_ID_ANY };
	struct core_params cp = { .nports = 2, .mtu = { 1500, 1500 }, .nworkers = 2,
				  .max_conns = 64, .learn_max = 256, .learn_ttl = 10000,
				  .socket_id = SOCKET_ID_ANY };
	struct ipsec_params xp = { .nworkers = 2, .nports = 2, .mtu = { 1500, 1500 },
				   .max_tunnels = max_tunnels, .max_sa = 64, .mp = pool,
				   .whole = big, .socket_id = SOCKET_ID_ANY };
	struct esp_dev *pd = esp_openssl_create(1, 64, 2), *kd = esp_openssl_create(1, 64, 2);
	struct esp_dev *fd = esp_openssl_create(1, 64, 2);

	memset(v, 0, sizeof(*v));
	v->d = esp_openssl_create(2, 64, 2);
	v->e = v->d ? esp_create(&ep2, v->d) : NULL;
	v->peer = pd ? esp_create(&ep, pd) : NULL;
	v->kernel = kd ? esp_create(&ep, kd) : NULL;
	v->far = fd ? esp_create(&ep, fd) : NULL;
	v->c = core_create(&cp);
	xp.core = v->c;
	v->x = v->e && v->c ? ipsec_create(&xp, v->e) : NULL;
	CHECKR(v->x && v->peer && v->kernel && v->far);
	CHECKR(core_map_ethdev(v->c, WIRE_ETH, WAN, CORE_WIRE) == 0);
	CHECKR(core_map_ethdev(v->c, KERNEL_ETH, WAN, CORE_KERNEL) == 0);
	CHECKR(core_map_ethdev(v->c, LAN_WIRE_ETH, LAN, CORE_WIRE) == 0);
	CHECKR(core_map_ethdev(v->c, LAN_KERNEL_ETH, LAN, CORE_KERNEL) == 0);
	CHECKR(ipsec_map_kernel(v->x, KERNEL_ETH, WAN) == 0);
	CHECKR(ipsec_map_wire(v->x, WIRE_ETH, WAN) == 0);
	CHECKR(ipsec_map_kernel(v->x, LAN_KERNEL_ETH, LAN) == 0);
	CHECKR(ipsec_map_wire(v->x, LAN_WIRE_ETH, LAN) == 0);
	return 0;
}

static void
env_free(struct env *v)
{
	ipsec_free(v->x);
	core_free(v->c);
	esp_free(v->e);
	esp_free(v->peer);
	esp_free(v->kernel);
	esp_free(v->far);
}

/* Runs the results of the backend through the engine until none is left; what goes out into got. */
static void
drain(struct env *v, struct rte_mbuf **got, unsigned *ngot)
{
	struct esp_result r[ESP_BURST];
	struct ipsec_out out;
	unsigned k, i;

	while ((k = esp_poll(v->e, 0, r, ESP_BURST))) {
		ipsec_done(v->x, 0, r, k, NOW, &out);
		for (i = 0; i < out.n[WAN][CORE_WIRE]; i++)
			got[(*ngot)++] = out.pkts[WAN][CORE_WIRE][i];
	}
}

/* The packets of the kernel side; what the engine left of them is returned, the rest goes into got. */
static unsigned
feed(struct env *v, struct rte_mbuf **pkts, unsigned n, struct rte_mbuf **got, unsigned *ngot)
{
	struct ipsec_out out;
	unsigned left, i;

	for (i = 0; i < n; i++)
		if (pkts[i]->port != WIRE_ETH)
			pkts[i]->port = KERNEL_ETH;
	left = ipsec_kernel(v->x, 0, pkts, n, rte_get_timer_cycles(), &out);
	for (i = 0; i < out.n[WAN][CORE_WIRE]; i++)
		got[(*ngot)++] = out.pkts[WAN][CORE_WIRE][i];
	drain(v, got, ngot);
	return left;
}

/* The pool for a packet of len bytes, with room for ESP around it. */
static struct rte_mempool *
pool_for(unsigned len)
{
	return len + RTE_PKTMBUF_HEADROOM + 128 <= rte_pktmbuf_data_room_size(pool) ? pool : big;
}

static struct rte_mbuf *
bytes(const uint8_t *p, unsigned len)
{
	struct rte_mbuf *m = rte_pktmbuf_alloc(pool_for(len));

	if (m)
		memcpy(rte_pktmbuf_append(m, (uint16_t)len), p, len);
	return m;
}

/* The frame of tests/esp/linux/NAME.pcap: ESP the kernel of the board made, sequence number 1. */
static struct rte_mbuf *
linux_frame(const char *name)
{
	char path[512];
	uint8_t buf[2048];
	size_t n;
	FILE *f;

	snprintf(path, sizeof(path), "%s/%s.pcap", getenv("ESP_LINUX") ? getenv("ESP_LINUX") : ".",
		 name);
	f = fopen(path, "rb");
	if (!f)
		return NULL;
	n = fread(buf, 1, sizeof(buf), f);
	fclose(f);
	/* the file header and the header of the frame */
	return n > 24 + 16 + 14 ? bytes(buf + 40, (unsigned)(n - 40)) : NULL;
}

/* An L2 header: Ethernet, with a VLAN tag and/or a PPPoE session header. */
static unsigned
l2_header(uint8_t *h, int vlan, int pppoe, unsigned iplen)
{
	unsigned n = 12;

	memcpy(h, PEER_MAC, 6);
	memcpy(h + 6, ROUTER_MAC, 6);
	if (vlan) {
		h[n++] = 0x81, h[n++] = 0x00, h[n++] = 0, h[n++] = (uint8_t)vlan;
	}
	if (pppoe) {
		h[n++] = 0x88, h[n++] = 0x64;
		h[n++] = 0x11, h[n++] = 0, h[n++] = 0, h[n++] = (uint8_t)pppoe;
		h[n++] = (uint8_t)((iplen + 2) >> 8), h[n++] = (uint8_t)(iplen + 2);
		h[n++] = 0, h[n++] = 0x21;
	} else {
		h[n++] = 0x08, h[n++] = 0x00;
	}
	return n;
}

/* The IPv4 packet m (from its start) behind an L2 header. */
static struct rte_mbuf *
framed(struct rte_mbuf *m, int vlan, int pppoe)
{
	uint8_t h[32];
	unsigned n = l2_header(h, vlan, pppoe, m->pkt_len);

	memcpy(rte_pktmbuf_prepend(m, (uint16_t)n), h, n);
	return m;
}

/* An inner IPv4/UDP packet of len bytes, PC1 to FAR, without DF. */
static struct rte_mbuf *
inner(unsigned len, uint8_t seed)
{
	struct rte_mbuf *m = rte_pktmbuf_alloc(pool_for(len));
	struct rte_ipv4_hdr *ip;
	uint8_t *p;
	unsigned i;

	if (!m)
		return NULL;
	p = (uint8_t *)rte_pktmbuf_append(m, (uint16_t)len);
	for (i = 0; i < len; i++)
		p[i] = (uint8_t)(seed + i);
	ip = (struct rte_ipv4_hdr *)p;
	*ip = (struct rte_ipv4_hdr){
		.version_ihl = RTE_IPV4_VHL_DEF,
		.total_length = rte_cpu_to_be_16((uint16_t)len),
		.time_to_live = 63,
		.next_proto_id = IPPROTO_UDP,
		.src_addr = rte_cpu_to_be_32(PC1),
		.dst_addr = rte_cpu_to_be_32(FAR),
	};
	ip->hdr_checksum = rte_ipv4_cksum(ip);
	*(struct rte_udp_hdr *)(ip + 1) = (struct rte_udp_hdr){
		.src_port = rte_cpu_to_be_16(40000),
		.dst_port = rte_cpu_to_be_16(5201),
		.dgram_len = rte_cpu_to_be_16((uint16_t)(len - sizeof(*ip))),
	};
	return m;
}

/* One job through an esp of the tests' own (the kernel's, the peer's); 1: it made the packet. */
static int
run1(struct esp *e, uint32_t sa, struct rte_mbuf *m)
{
	struct esp_job j = { .m = m, .sa = sa };
	struct esp_result r;

	return !esp_submit(e, 0, &j, 1) && esp_poll(e, 0, &r, 1) == 1 && r.ok;
}

/* What the kernel sends on SA c: inner encrypted from sequence number 1 (no L2 header). */
static struct rte_mbuf *
kernel_esp(struct env *v, const struct esp_sa_conf *c, struct rte_mbuf *in)
{
	struct esp_sa_conf k = *c;

	k.seq = 0;
	esp_sa_del(v->kernel, 0);
	if (esp_sa_add(v->kernel, 0, &k) || !run1(v->kernel, 0, in)) {
		rte_pktmbuf_free(in);
		return NULL;
	}
	return in;
}

/* The ESP of a frame out of the engine, decrypted by the peer (a copy); NULL when it cannot. */
static struct rte_mbuf *
peer_reads(struct env *v, const struct esp_sa_conf *out, const struct rte_mbuf *frame,
	   unsigned l2)
{
	struct esp_sa_conf in = *out;
	struct rte_mbuf *m = rte_pktmbuf_copy(frame, pool_for(frame->pkt_len), l2, UINT32_MAX);

	in.dir = ESP_IN;
	in.seq = 0;
	esp_sa_del(v->peer, 0);
	if (!m || esp_sa_add(v->peer, 0, &in) || !run1(v->peer, 0, m)) {
		rte_pktmbuf_free(m);
		return NULL;
	}
	return m;
}

static int
same(const struct rte_mbuf *a, const struct rte_mbuf *b)
{
	return a && b && a->pkt_len == b->pkt_len &&
	       !memcmp(rte_pktmbuf_mtod(a, const void *), rte_pktmbuf_mtod(b, const void *),
		       a->pkt_len);
}

/* The sequence number of the ESP of a frame with l2 bytes of header. */
static uint32_t
seq_of(const struct rte_mbuf *m, unsigned l2)
{
	const struct rte_ipv4_hdr *ip = rte_pktmbuf_mtod_offset(m, const struct rte_ipv4_hdr *, l2);
	const uint8_t *esp = (const uint8_t *)(ip + 1);
	uint32_t s;

	if (ip->next_proto_id == IPPROTO_UDP)
		esp += sizeof(struct rte_udp_hdr);
	memcpy(&s, esp + 4, 4);
	return rte_be_to_cpu_32(s);
}

struct infos {
	unsigned n;
	struct ipsec_sa_info in[8];
};

static int
info_one(const struct ipsec_sa_info *in, void *arg)
{
	struct infos *a = arg;

	if (a->n < 8)
		a->in[a->n++] = *in;
	return 0;
}

static struct infos
infos(struct env *v)
{
	struct infos a = { 0 };

	ipsec_sa_walk(v->x, info_one, &a);
	return a;
}

static void
free_all(struct rte_mbuf **m, unsigned n)
{
	unsigned i;

	for (i = 0; i < n; i++)
		rte_pktmbuf_free(m[i]);
}

/*
 * The kernel's ESP of each algorithm of the spec, as the Linux kernel of
 * the board makes it: the engine sends it again with its own number, the
 * same L2 header, and the peer reads the same packet out of it.
 */
TEST(the_kernels_esp_on_an_sa_held_goes_out_with_the_engines_number)
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

	for (i = 0; i < RTE_DIM(fx); i++) {
		struct env v;
		struct esp_sa_conf c = sa_conf(ESP_OUT, fx[i].cipher, fx[i].auth, fx[i].key_len,
					       (int)fx[i].udp);
		struct rte_mbuf *m = linux_frame(fx[i].name), *got[MAX_GOT], *want, *read;
		unsigned ngot = 0;

		uint8_t eth[RTE_ETHER_HDR_LEN];

		CHECK(!env_new(&v, 4) && m);
		memcpy(eth, rte_pktmbuf_mtod(m, void *), sizeof(eth));
		want = peer_reads(&v, &c, m, RTE_ETHER_HDR_LEN);
		CHECK(want);
		CHECK(ipsec_sa_add(v.x, &c) == 0);
		CHECK(feed(&v, &m, 1, got, &ngot) == 0);
		CHECK(ngot == 1);
		CHECK(!memcmp(rte_pktmbuf_mtod(got[0], void *), eth, sizeof(eth)));
		CHECK(seq_of(got[0], RTE_ETHER_HDR_LEN) == FIRST);
		read = peer_reads(&v, &c, got[0], RTE_ETHER_HDR_LEN);
		CHECK(same(read, want));
		CHECK(infos(&v).n == 1 && infos(&v).in[0].last == FIRST);
		rte_pktmbuf_free(read);
		rte_pktmbuf_free(want);
		free_all(got, ngot);
		env_free(&v);
	}
}

TEST(the_engines_numbers_follow_each_other_whatever_the_kernel_numbered)
{
	struct env v;
	struct esp_sa_conf c = vpn();
	struct rte_mbuf *m[3], *got[MAX_GOT];
	unsigned ngot = 0, i;

	CHECK(!env_new(&v, 4));
	CHECK(ipsec_sa_add(v.x, &c) == 0);
	/* the kernel's numbers are all 1 */
	for (i = 0; i < 3; i++)
		CHECK((m[i] = linux_frame("cbc256-sha256-udp")));
	CHECK(feed(&v, m, 3, got, &ngot) == 0);
	CHECK(ngot == 3);
	for (i = 0; i < 3; i++)
		CHECK(seq_of(got[i], RTE_ETHER_HDR_LEN) == FIRST + i);
	CHECK(infos(&v).in[0].last == FIRST + 2);
	free_all(got, ngot);
	env_free(&v);
}

/* What is no ESP of an SA held goes on as it came, and nothing else goes out. */
TEST(the_rest_of_what_the_kernel_sends_is_left_as_it_is)
{
	struct env v;
	struct esp_sa_conf c = vpn(), other = vpn();
	struct rte_mbuf *m[8], *keep[8], *got[MAX_GOT];
	uint8_t ike[64] = { 0 }, ka[64] = { 0 };
	struct rte_ipv4_hdr *ip;
	unsigned ngot = 0, i, n = 0, l2;

	CHECK(!env_new(&v, 4));
	/* nothing held: the engine does not even look */
	CHECK((m[0] = linux_frame("cbc256-sha256-udp")));
	CHECK(feed(&v, m, 1, got, &ngot) == 1 && ngot == 0);
	rte_pktmbuf_free(m[0]);
	other.spi = SPI + 1;
	CHECK(ipsec_sa_add(v.x, &other) == 0);
	CHECK(ipsec_sa_add(v.x, &c) == 0);
	/* ESP of an SPI not held */
	CHECK((m[n] = linux_frame("cbc256-sha256-udp")));
	rte_pktmbuf_mtod(m[n], uint8_t *)[RTE_ETHER_HDR_LEN + 28 + 3] ^= 0x40;
	n++;
	/* from another source */
	CHECK((m[n] = linux_frame("cbc256-sha256-udp")));
	ip = rte_pktmbuf_mtod_offset(m[n], struct rte_ipv4_hdr *, RTE_ETHER_HDR_LEN);
	n++;
	ip->src_addr = rte_cpu_to_be_32(RTE_IPV4(192, 168, 2, 11));
	/* plain ESP on the SA of ESP in UDP */
	CHECK((m[n++] = linux_frame("cbc128-sha1-esp")));
	/* the same ESP from the wire */
	CHECK((m[n] = linux_frame("cbc256-sha256-udp")));
	m[n++]->port = WIRE_ETH;
	/* IKE on 4500: the non-ESP marker; and on 500 */
	l2 = l2_header(ike, 0, 0, 0);
	ip = (struct rte_ipv4_hdr *)(ike + l2);
	*ip = (struct rte_ipv4_hdr){ .version_ihl = RTE_IPV4_VHL_DEF,
				     .total_length = rte_cpu_to_be_16(44), .time_to_live = 64,
				     .next_proto_id = IPPROTO_UDP, .src_addr = c.src, .dst_addr = c.dst };
	*(struct rte_udp_hdr *)(ip + 1) = (struct rte_udp_hdr){
		.src_port = rte_cpu_to_be_16(4500), .dst_port = rte_cpu_to_be_16(4500),
		.dgram_len = rte_cpu_to_be_16(24) };
	CHECK((m[n++] = bytes(ike, l2 + 44)));
	((struct rte_udp_hdr *)(ip + 1))->src_port = rte_cpu_to_be_16(500);
	((struct rte_udp_hdr *)(ip + 1))->dst_port = rte_cpu_to_be_16(500);
	memset((uint8_t *)ip + 28, 0x11, 4);
	CHECK((m[n++] = bytes(ike, l2 + 44)));
	/* a NAT-T keepalive: one byte 0xff, in a frame padded to 60 bytes */
	memcpy(ka, ike, sizeof(ka));
	ip = (struct rte_ipv4_hdr *)(ka + l2);
	ip->total_length = rte_cpu_to_be_16(29);
	((struct rte_udp_hdr *)(ip + 1))->dgram_len = rte_cpu_to_be_16(9);
	((uint8_t *)ip)[28] = 0xff;
	CHECK((m[n++] = bytes(ka, 60)));
	for (i = 0; i < n; i++)
		CHECK((keep[i] = rte_pktmbuf_copy(m[i], pool, 0, UINT32_MAX)));
	CHECK(feed(&v, m, n, got, &ngot) == n);
	CHECK(ngot == 0);
	for (i = 0; i < n; i++)
		CHECK(same(m[i], keep[i]));
	free_all(m, n);
	free_all(keep, n);
	env_free(&v);
}

/* A packet the kernel numbered that the SEC cannot decrypt again never reaches the wire. */
TEST(the_kernels_esp_that_does_not_decrypt_again_is_dropped_and_counted)
{
	struct env v;
	struct esp_sa_conf c = vpn();
	struct rte_mbuf *m, *got[MAX_GOT];
	unsigned ngot = 0;

	CHECK(!env_new(&v, 4));
	CHECK(ipsec_sa_add(v.x, &c) == 0);
	CHECK((m = linux_frame("cbc256-sha256-udp")));
	rte_pktmbuf_mtod(m, uint8_t *)[m->pkt_len - 1] ^= 1;
	CHECK(feed(&v, &m, 1, got, &ngot) == 0);
	CHECK(ngot == 0);
	CHECK(infos(&v).in[0].failed == 1);
	env_free(&v);
}

/* The L2 header the kernel gave goes out with the ESP: a VLAN tag, PPPoE with its new length. */
TEST(the_kernels_l2_header_goes_out_vlan_and_pppoe)
{
	static const struct { int vlan, pppoe; unsigned l2; } fx[] = {
		{ 35, 0, 18 }, { 0, 0x1234, 22 }, { 35, 0x1234, 26 },
	};
	unsigned i;

	for (i = 0; i < RTE_DIM(fx); i++) {
		struct env v;
		struct esp_sa_conf c = vpn();
		struct rte_mbuf *m = linux_frame("cbc256-sha256-udp"), *got[MAX_GOT], *want, *read;
		uint8_t h[32];
		unsigned ngot = 0, iplen;

		CHECK(!env_new(&v, 4) && m);
		rte_pktmbuf_adj(m, RTE_ETHER_HDR_LEN);
		iplen = m->pkt_len;
		framed(m, fx[i].vlan, fx[i].pppoe);
		want = peer_reads(&v, &c, m, fx[i].l2);
		CHECK(want);
		CHECK(ipsec_sa_add(v.x, &c) == 0);
		CHECK(feed(&v, &m, 1, got, &ngot) == 0 && ngot == 1);
		CHECK(seq_of(got[0], fx[i].l2) == FIRST);
		/* the header the kernel sent, its PPPoE length that of the new packet */
		l2_header(h, fx[i].vlan, fx[i].pppoe, got[0]->pkt_len - fx[i].l2);
		CHECK(!memcmp(rte_pktmbuf_mtod(got[0], void *), h, fx[i].l2));
		CHECK(got[0]->pkt_len - fx[i].l2 == iplen);
		read = peer_reads(&v, &c, got[0], fx[i].l2);
		CHECK(same(read, want));
		rte_pktmbuf_free(read);
		rte_pktmbuf_free(want);
		free_all(got, ngot);
		env_free(&v);
	}
}

/* The fragments of the IPv4 packet m (from its start) of at most mtu, behind an L2 header. */
static unsigned
fragments(const struct rte_mbuf *m, unsigned mtu, struct rte_mbuf **f, int pppoe)
{
	const struct rte_ipv4_hdr *ip = rte_pktmbuf_mtod(m, const struct rte_ipv4_hdr *);
	unsigned len = m->pkt_len, step = (mtu - 20) & ~7u, off, n = 0;

	for (off = 0; off < len - 20; off += step) {
		unsigned k = RTE_MIN(step, len - 20 - off);
		struct rte_mbuf *fr = rte_pktmbuf_alloc(pool);
		struct rte_ipv4_hdr *h = (struct rte_ipv4_hdr *)rte_pktmbuf_append(fr, (uint16_t)(20 + k));

		memcpy(h, ip, 20);
		memcpy(h + 1, (const uint8_t *)ip + 20 + off, k);
		h->total_length = rte_cpu_to_be_16((uint16_t)(20 + k));
		h->fragment_offset = rte_cpu_to_be_16((uint16_t)(off / 8 |
					(off + k < len - 20 ? RTE_IPV4_HDR_MF_FLAG : 0)));
		h->hdr_checksum = 0;
		h->hdr_checksum = rte_ipv4_cksum(h);
		f[n++] = framed(fr, 0, pppoe);
	}
	return n;
}

/* The fragments of frames with l2 bytes of header put together: the IPv4 packet, or NULL. */
static struct rte_mbuf *
together(struct rte_mbuf **f, unsigned n, unsigned l2, unsigned mtu)
{
	uint8_t p[8192];
	struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)p;
	unsigned i, total = 0;

	for (i = 0; i < n; i++) {
		const struct rte_ipv4_hdr *h =
			rte_pktmbuf_mtod_offset(f[i], const struct rte_ipv4_hdr *, l2);
		uint16_t fo = rte_be_to_cpu_16(h->fragment_offset);
		unsigned len = rte_be_to_cpu_16(h->total_length), off = (fo & 0x1fff) * 8u;

		if (len > mtu || rte_ipv4_cksum(h) != 0 || (fo & RTE_IPV4_HDR_DF_FLAG) ||
		    20 + off + len - 20 > sizeof(p))
			return NULL;
		if (!off)
			memcpy(p, h, 20);
		memcpy(p + 20 + off, h + 1, len - 20);
		if (!(fo & RTE_IPV4_HDR_MF_FLAG))
			total = 20 + off + len - 20;
	}
	if (!total)
		return NULL;
	ip->total_length = rte_cpu_to_be_16((uint16_t)total);
	ip->fragment_offset = 0;
	ip->hdr_checksum = 0;
	ip->hdr_checksum = rte_ipv4_cksum(ip);
	return bytes(p, total);
}

/*
 * A large packet without DF: the kernel fragments its ESP. The fragments,
 * in any order, are put together, numbered again, and fragmented again to
 * the MTU of the port; on PPPoE, 8 bytes less. ESP longer than a packet of
 * the engine's pool too (4000 bytes of UDP).
 */
TEST(the_kernels_fragmented_esp_is_put_together_numbered_and_fragmented_again)
{
	static const struct { int pppoe; unsigned mtu, l2, len, n; } fx[] = {
		{ 0, 1500, 14, 1500, 2 }, { 7, 1492, 22, 1500, 2 }, { 0, 1500, 14, 4000, 3 },
		{ 7, 1492, 22, 4000, 3 },
	};
	unsigned i;

	for (i = 0; i < RTE_DIM(fx); i++) {
		struct env v;
		struct esp_sa_conf c = vpn();
		struct rte_mbuf *esp, *f[8], *got[MAX_GOT], *whole, *read, *want = inner(fx[i].len, 3);
		unsigned ngot = 0, n, k;

		CHECK(!env_new(&v, 4) && want);
		esp = kernel_esp(&v, &c, rte_pktmbuf_copy(want, pool_for(want->pkt_len), 0, UINT32_MAX));
		CHECK(esp && esp->pkt_len > fx[i].mtu);
		/* the kernel's IP id: the fragments out carry it, not the SEC's 0 */
		rte_pktmbuf_mtod(esp, struct rte_ipv4_hdr *)->packet_id = rte_cpu_to_be_16(0x4321);
		n = fragments(esp, fx[i].mtu, f, fx[i].pppoe);
		rte_pktmbuf_free(esp);
		CHECK(n == fx[i].n);
		CHECK(ipsec_sa_add(v.x, &c) == 0);
		/* the last one first */
		CHECK(feed(&v, &f[1], n - 1, got, &ngot) == 0 && ngot == 0);
		CHECK(feed(&v, &f[0], 1, got, &ngot) == 0);
		CHECK(ngot == fx[i].n);
		for (k = 0; k < ngot; k++) {
			CHECK(!memcmp(rte_pktmbuf_mtod(got[k], void *), PEER_MAC, 6));
			CHECK(rte_pktmbuf_mtod_offset(got[k], struct rte_ipv4_hdr *, fx[i].l2)->packet_id ==
			      rte_cpu_to_be_16(0x4321));
		}
		whole = together(got, ngot, fx[i].l2, fx[i].mtu);
		CHECK(whole);
		CHECK(seq_of(whole, 0) == FIRST);
		read = peer_reads(&v, &c, whole, 0);
		CHECK(same(read, want));
		rte_pktmbuf_free(read);
		rte_pktmbuf_free(whole);
		rte_pktmbuf_free(want);
		free_all(got, ngot);
		env_free(&v);
	}
}

/*
 * ESP put together without a packet left in the pool of whole datagrams:
 * none of it goes out, and the SA counts it as dropped.
 */
TEST(fragmented_esp_without_room_to_put_it_together_is_counted_as_dropped)
{
	struct env v;
	struct esp_sa_conf c = vpn();
	struct rte_mbuf *esp, *f[8], *got[MAX_GOT], *hold[256], *want = inner(4000, 4);
	unsigned ngot = 0, nhold = 0, n;
	struct infos a;

	CHECK(!env_new(&v, 4) && want);
	esp = kernel_esp(&v, &c, want);
	CHECK(esp);
	n = fragments(esp, 1500, f, 0);
	rte_pktmbuf_free(esp);
	CHECK(n == 3);
	CHECK(ipsec_sa_add(v.x, &c) == 0);
	while (nhold < RTE_DIM(hold) && (hold[nhold] = rte_pktmbuf_alloc(big)))
		nhold++;
	CHECK(nhold < RTE_DIM(hold));
	CHECK(feed(&v, f, n, got, &ngot) == 0 && ngot == 0);
	a = infos(&v);
	CHECK(a.n == 1 && a.in[0].dropped == 1);
	free_all(hold, nhold);
	env_free(&v);
}

/*
 * A fragmented datagram between the addresses of an SA that is no ESP of it
 * (a large IKE message) goes out fragmented again with what it carried; a
 * fragment between other addresses is left.
 */
TEST(fragments_that_are_no_esp_held_go_on)
{
	struct env v;
	struct esp_sa_conf c = vpn();
	struct rte_mbuf *ike = inner(1700, 9), *f[8], *got[MAX_GOT], *whole, *other[8];
	struct rte_ipv4_hdr *ip = rte_pktmbuf_mtod(ike, struct rte_ipv4_hdr *);
	unsigned ngot = 0, n, k;

	CHECK(!env_new(&v, 4) && ike);
	ip->src_addr = c.src;
	ip->dst_addr = c.dst;
	ip->hdr_checksum = 0;
	ip->hdr_checksum = rte_ipv4_cksum(ip);
	((struct rte_udp_hdr *)(ip + 1))->src_port = rte_cpu_to_be_16(500);
	((struct rte_udp_hdr *)(ip + 1))->dst_port = rte_cpu_to_be_16(500);
	CHECK(ipsec_sa_add(v.x, &c) == 0);
	n = fragments(ike, 1500, f, 0);
	CHECK(feed(&v, f, n, got, &ngot) == 0);
	whole = together(got, ngot, RTE_ETHER_HDR_LEN, 1500);
	CHECK(same(whole, ike));
	rte_pktmbuf_free(whole);
	free_all(got, ngot);
	ngot = 0;
	ip->src_addr = rte_cpu_to_be_32(RTE_IPV4(192, 168, 2, 11));
	ip->hdr_checksum = 0;
	ip->hdr_checksum = rte_ipv4_cksum(ip);
	n = fragments(ike, 1500, other, 0);
	CHECK(feed(&v, other, n, got, &ngot) == n && ngot == 0);
	for (k = 0; k < n; k++)
		rte_pktmbuf_free(other[k]);
	rte_pktmbuf_free(ike);
	env_free(&v);
}

/*
 * Let go of: the highest number the SA may have used, and from then on the
 * kernel's ESP on it goes out as it is. Its sessions go once no job of
 * them is left.
 */
TEST(an_sa_let_go_of_says_its_last_number_and_the_kernels_esp_goes_on)
{
	struct env v;
	struct esp_sa_conf c = vpn(), in = sa_conf(ESP_IN, ESP_AES_CBC, ESP_HMAC_SHA256_128, 32, 1);
	struct rte_mbuf *m[2], *got[MAX_GOT];
	struct ipsec_sa_info last;
	unsigned ngot = 0;

	CHECK(!env_new(&v, 4));
	in.spi = 0xc0010002;
	in.src = c.dst;
	in.dst = c.src;
	in.replay = 32;
	CHECK(ipsec_sa_add(v.x, &c) == 0 && ipsec_sa_add(v.x, &in) == 0);
	CHECK(ipsec_sa_count(v.x) == 2 && esp_sa_count(v.e) == 3);
	CHECK((m[0] = linux_frame("cbc256-sha256-udp")) && (m[1] = linux_frame("cbc256-sha256-udp")));
	CHECK(feed(&v, m, 2, got, &ngot) == 0 && ngot == 2);
	free_all(got, ngot);
	ngot = 0;
	CHECK(ipsec_sa_del(v.x, c.spi, c.dst, NOW, &last, NULL, NULL) == 0);
	CHECK(last.dir == ESP_OUT && last.spi == SPI && last.last == FIRST + 1);
	CHECK(ipsec_sa_del(v.x, c.spi, c.dst, NOW, &last, NULL, NULL) == -ENOENT);
	CHECK(ipsec_sa_del(v.x, in.spi, in.dst, NOW, &last, NULL, NULL) == 0);
	CHECK(last.dir == ESP_IN && last.last == 0);
	CHECK(ipsec_sa_count(v.x) == 0);
	ipsec_poll(v.x);
	CHECK(esp_sa_count(v.e) == 0);
	CHECK((m[0] = linux_frame("cbc256-sha256-udp")));
	CHECK(feed(&v, m, 1, got, &ngot) == 1 && ngot == 0);
	CHECK(seq_of(m[0], RTE_ETHER_HDR_LEN) == 1);
	rte_pktmbuf_free(m[0]);
	/* held again, from a later number */
	c.seq = FIRST + 100;
	CHECK(ipsec_sa_add(v.x, &c) == 0);
	CHECK((m[0] = linux_frame("cbc256-sha256-udp")));
	CHECK(feed(&v, m, 1, got, &ngot) == 0 && ngot == 1);
	CHECK(seq_of(got[0], RTE_ETHER_HDR_LEN) == FIRST + 100);
	free_all(got, ngot);
	env_free(&v);
}

/*
 * Let go of in two steps: stopped, the SA says its last number and the
 * kernel's ESP on it is dropped, neither numbered nor left as it is, until
 * the daemon wrote that number into the kernel and deleted it.
 */
TEST(the_kernels_esp_on_an_sa_stopped_is_dropped_until_it_is_deleted)
{
	struct env v;
	struct esp_sa_conf c = vpn();
	struct rte_mbuf *m, *got[MAX_GOT];
	struct ipsec_sa_info in;
	unsigned ngot = 0;

	CHECK(!env_new(&v, 4));
	CHECK(ipsec_sa_add(v.x, &c) == 0);
	CHECK((m = linux_frame("cbc256-sha256-udp")));
	CHECK(feed(&v, &m, 1, got, &ngot) == 0 && ngot == 1);
	free_all(got, ngot);
	ngot = 0;
	CHECK(ipsec_sa_stop(v.x, c.spi, c.dst, NOW, &in, NULL, NULL) == 0 && in.last == FIRST);
	CHECK((m = linux_frame("cbc256-sha256-udp")));
	CHECK(feed(&v, &m, 1, got, &ngot) == 0 && ngot == 0);
	CHECK(infos(&v).n == 1 && infos(&v).in[0].dropped == 1 && infos(&v).in[0].last == FIRST);
	CHECK(ipsec_sa_del(v.x, c.spi, c.dst, NOW, &in, NULL, NULL) == 0 && in.last == FIRST);
	CHECK((m = linux_frame("cbc256-sha256-udp")));
	CHECK(feed(&v, &m, 1, got, &ngot) == 1 && ngot == 0);
	rte_pktmbuf_free(m);
	CHECK(ipsec_sa_stop(v.x, c.spi, c.dst, NOW, &in, NULL, NULL) == -ENOENT);
	env_free(&v);
}

/*
 * Let go of while the SEC has its jobs: they count in its last number; a
 * packet decrypted again after it was let go of goes no further, and its
 * sessions stay until their jobs are back.
 */
TEST(an_sa_let_go_of_with_jobs_in_the_sec_counts_them_and_sends_nothing_more)
{
	struct env v;
	struct esp_sa_conf c = vpn();
	struct rte_mbuf *m[3], *got[MAX_GOT];
	struct ipsec_out out;
	struct ipsec_sa_info last;
	unsigned ngot = 0, i;

	CHECK(!env_new(&v, 4));
	CHECK(ipsec_sa_add(v.x, &c) == 0);
	esp_openssl_hold(v.d, 1);
	for (i = 0; i < 3; i++)
		CHECK((m[i] = linux_frame("cbc256-sha256-udp")));
	for (i = 0; i < 3; i++)
		m[i]->port = KERNEL_ETH;
	CHECK(ipsec_kernel(v.x, 0, m, 3, rte_get_timer_cycles(), &out) == 0);
	CHECK(ipsec_sa_del(v.x, c.spi, c.dst, NOW, &last, NULL, NULL) == 0);
	/* each of them could still be numbered: an upper bound */
	CHECK(last.last >= FIRST - 1 && last.last <= FIRST + 2);
	/* the encryption has no job: it goes at once */
	ipsec_poll(v.x);
	CHECK(esp_sa_count(v.e) == 1);
	esp_openssl_hold(v.d, 0);
	drain(&v, got, &ngot);
	CHECK(ngot == 0);
	ipsec_poll(v.x);
	CHECK(esp_sa_count(v.e) == 0);
	env_free(&v);
}

/* At most max_tunnels reqids; a tunnel holds as many SAs as it has. */
TEST(the_sas_of_a_tunnel_past_the_most_tunnels_are_refused)
{
	struct env v;
	struct esp_sa_conf c = vpn();
	unsigned t;

	CHECK(!env_new(&v, 2));
	for (t = 1; t <= 2; t++) {
		c.lane = t;
		c.spi = SPI + 2 * t;
		CHECK(ipsec_sa_add(v.x, &c) == 0);
		/* a rekey: a second outbound SA of the tunnel */
		c.spi++;
		CHECK(ipsec_sa_add(v.x, &c) == 0);
	}
	c.lane = 3;
	c.spi = SPI + 100;
	CHECK(ipsec_sa_add(v.x, &c) == -ENOSPC);
	CHECK(ipsec_sa_count(v.x) == 4);
	/* a tunnel whose SAs all went leaves room */
	CHECK(ipsec_sa_del(v.x, SPI + 4, c.dst, NOW, NULL, NULL, NULL) == 0);
	CHECK(ipsec_sa_add(v.x, &c) == -ENOSPC);
	CHECK(ipsec_sa_del(v.x, SPI + 5, c.dst, NOW, NULL, NULL, NULL) == 0);
	CHECK(ipsec_sa_add(v.x, &c) == 0);
	env_free(&v);
}

TEST(an_sa_held_twice_or_that_esp_cannot_do_is_refused)
{
	struct env v;
	struct esp_sa_conf c = vpn(), bad = vpn();

	CHECK(!env_new(&v, 4));
	CHECK(ipsec_sa_add(v.x, &c) == 0);
	CHECK(ipsec_sa_add(v.x, &c) == -EEXIST);
	bad.spi = SPI + 1;
	bad.key_len = 24;
	CHECK(ipsec_sa_add(v.x, &bad) == -EINVAL);
	CHECK(ipsec_sa_count(v.x) == 1 && esp_sa_count(v.e) == 2);
	env_free(&v);
}

static void
flushed_one(const struct ipsec_sa_info *in, void *arg)
{
	struct infos *a = arg;

	a->in[a->n++] = *in;
}

TEST(flush_lets_go_of_every_sa_and_says_each)
{
	struct env v;
	struct esp_sa_conf c = vpn(), in = sa_conf(ESP_IN, ESP_AES_GCM, ESP_AUTH_NONE, 32, 1);
	struct infos a = { 0 };
	struct rte_mbuf *m, *got[MAX_GOT];
	unsigned ngot = 0, i, outs = 0;

	CHECK(!env_new(&v, 4));
	in.spi = 0xc0010002;
	in.src = c.dst;
	in.dst = c.src;
	in.replay = 128;
	CHECK(ipsec_sa_add(v.x, &c) == 0 && ipsec_sa_add(v.x, &in) == 0);
	CHECK((m = linux_frame("cbc256-sha256-udp")));
	CHECK(feed(&v, &m, 1, got, &ngot) == 0 && ngot == 1);
	free_all(got, ngot);
	CHECK(ipsec_sa_flush(v.x, NOW, flushed_one, NULL, &a) == 2);
	CHECK(a.n == 2 && ipsec_sa_count(v.x) == 0);
	for (i = 0; i < 2; i++) {
		CHECK(a.in[i].reqid == 1);
		if (a.in[i].dir == ESP_OUT) {
			CHECK(a.in[i].spi == SPI && a.in[i].last == FIRST);
			outs++;
		} else {
			CHECK(a.in[i].spi == 0xc0010002 && a.in[i].src == c.dst);
		}
	}
	CHECK(outs == 1);
	ipsec_poll(v.x);
	CHECK(esp_sa_count(v.e) == 0);
	env_free(&v);
}

/*
 * Connections through the tunnel (spec-ipsec: Đường gói ①–④): what goes
 * out of each side of each port of the engine, as the engine's loop sends
 * it (engine.c): the ESP of the kernel and of the wire to the SEC, the rest
 * to the core, what the core puts into a tunnel to the SEC, and every
 * result back through ipsec_done().
 */
struct seen {
	unsigned n[2][2];
	struct rte_mbuf *m[2][2][MAX_GOT];
};

static void
seen_put(struct seen *g, unsigned p, unsigned s, struct rte_mbuf *m)
{
	if (g->n[p][s] < MAX_GOT)
		g->m[p][s][g->n[p][s]++] = m;
	else
		rte_pktmbuf_free(m);
}

static void
seen_out(struct seen *g, const struct ipsec_out *out)
{
	unsigned p, s, i;

	for (p = 0; p < 2; p++)
		for (s = 0; s < 2; s++)
			for (i = 0; i < out->n[p][s]; i++)
				seen_put(g, p, s, out->pkts[p][s][i]);
}

static unsigned
seen_count(const struct seen *g)
{
	return g->n[0][0] + g->n[0][1] + g->n[1][0] + g->n[1][1];
}

static void
seen_free(struct seen *g)
{
	unsigned p, s;

	for (p = 0; p < 2; p++)
		for (s = 0; s < 2; s++)
			free_all(g->m[p][s], g->n[p][s]);
	memset(g, 0, sizeof(*g));
}

/* One packet into the engine from ethdev; what comes out of it into g (emptied first). */
static void
engine_rx(struct env *v, uint16_t ethdev, struct rte_mbuf *m, struct seen *g)
{
	struct esp_result r[ESP_BURST];
	struct ipsec_out io;
	struct core_out co;
	unsigned n, k, p, s, i;

	memset(g, 0, sizeof(*g));
	m->port = ethdev;
	n = ipsec_kernel(v->x, 0, &m, 1, rte_get_timer_cycles(), &io);
	seen_out(g, &io);
	n = ipsec_wire(v->x, 0, &m, n);
	if (n) {
		core_rx(v->c, 0, &m, n, NOW, &co);
		if (co.ntun) {
			ipsec_tunnel(v->x, 0, co.tun, co.ntun, &io);
			seen_out(g, &io);
		}
		for (p = 0; p < 2; p++)
			for (s = 0; s < 2; s++)
				for (i = 0; i < co.n[p][s]; i++)
					seen_put(g, p, s, co.pkts[p][s][i]);
	}
	while ((k = esp_poll(v->e, 0, r, ESP_BURST))) {
		ipsec_done(v->x, 0, r, k, NOW, &io);
		seen_out(g, &io);
	}
	core_poll(v->c, NOW);
}

/* A packet of IPv4 of len bytes, UDP or TCP with flags, without checksum of its own. */
static struct rte_mbuf *
packet(int proto, uint32_t src, uint16_t sport, uint32_t dst, uint16_t dport, unsigned len,
       uint8_t ttl, uint8_t flags)
{
	struct rte_mbuf *m = inner(len, (uint8_t)sport);
	struct rte_ipv4_hdr *ip;

	if (!m)
		return NULL;
	ip = rte_pktmbuf_mtod(m, struct rte_ipv4_hdr *);
	ip->src_addr = rte_cpu_to_be_32(src);
	ip->dst_addr = rte_cpu_to_be_32(dst);
	ip->time_to_live = ttl;
	ip->next_proto_id = (uint8_t)proto;
	ip->hdr_checksum = 0;
	ip->hdr_checksum = rte_ipv4_cksum(ip);
	if (proto == IPPROTO_TCP) {
		struct rte_tcp_hdr *t = (struct rte_tcp_hdr *)(ip + 1);

		memset(t, 0, sizeof(*t));
		t->data_off = 5 << 4;
		t->tcp_flags = flags;
	}
	((struct rte_udp_hdr *)(ip + 1))->src_port = rte_cpu_to_be_16(sport);
	((struct rte_udp_hdr *)(ip + 1))->dst_port = rte_cpu_to_be_16(dport);
	if (proto == IPPROTO_UDP)
		((struct rte_udp_hdr *)(ip + 1))->dgram_cksum = 0;
	return m;
}

/* The flow of the tests: UDP PC1:40000 -> FAR:5201, and its reply. */
static struct rte_mbuf *
orig_pkt(unsigned len, uint8_t ttl)
{
	return packet(IPPROTO_UDP, PC1, 40000, FAR, 5201, len, ttl, 0);
}

static struct rte_mbuf *
reply_pkt(unsigned len, uint8_t ttl)
{
	return packet(IPPROTO_UDP, FAR, 5201, PC1, 40000, len, ttl, 0);
}

/* The IPv4 packet m behind the L2 header of the LAN: from PC1, or to it. */
static struct rte_mbuf *
on_lan(struct rte_mbuf *m, int to_pc1)
{
	uint8_t *f = (uint8_t *)rte_pktmbuf_prepend(m, RTE_ETHER_HDR_LEN);

	memcpy(f, to_pc1 ? PC1_MAC : ROUTER_LAN_MAC, 6);
	memcpy(f + 6, to_pc1 ? ROUTER_LAN_MAC : PC1_MAC, 6);
	f[12] = 0x08;
	f[13] = 0;
	return m;
}

/* The peer's ESP from the wire: the inner packet in through the peer's SA sa of v->far. */
static struct rte_mbuf *
from_peer(struct env *v, uint32_t sa, struct rte_mbuf *in)
{
	uint8_t *f;

	if (!in || !run1(v->far, sa, in)) {
		rte_pktmbuf_free(in);
		return NULL;
	}
	f = (uint8_t *)rte_pktmbuf_prepend(in, RTE_ETHER_HDR_LEN);
	memcpy(f, ROUTER_MAC, 6);
	memcpy(f + 6, PEER_MAC, 6);
	f[12] = 0x08;
	f[13] = 0;
	return in;
}

/* The inbound SA of the tunnel of vpn(), and the peer's twin of it in v->far (sa). */
static struct esp_sa_conf
vpn_in(struct env *v, uint32_t sa, uint32_t spi, uint32_t lane)
{
	struct esp_sa_conf c = sa_conf(ESP_IN, ESP_AES_CBC, ESP_HMAC_SHA256_128, 32, 1), f;

	c.spi = spi;
	c.src = rte_cpu_to_be_32(RIGHT);
	c.dst = rte_cpu_to_be_32(LEFT);
	c.replay = 32;
	c.lane = lane;
	f = c;
	f.dir = ESP_OUT;
	f.replay = 0;
	esp_sa_del(v->far, sa);
	esp_sa_add(v->far, sa, &f);
	return c;
}

static int
bind_flow(struct env *v)
{
	struct core_tuple o = { rte_cpu_to_be_32(PC1), rte_cpu_to_be_32(FAR),
				rte_cpu_to_be_16(40000), rte_cpu_to_be_16(5201) };
	struct core_tuple r = { rte_cpu_to_be_32(FAR), rte_cpu_to_be_32(PC1),
				rte_cpu_to_be_16(5201), rte_cpu_to_be_16(40000) };
	unsigned missing;

	return core_bind(v->c, IPPROTO_UDP, &o, &r, NOW, &missing);
}

/*
 * The first packets of the flow through the kernel (① and ②), each where
 * the kernel and the cables would see it: 0 when each went its way.
 */
static int
first_packets(struct env *v, const struct esp_sa_conf *out, uint32_t far_sa)
{
	struct rte_mbuf *m, *keep;
	struct seen g;

	/* ① PC1's packet goes up; the kernel sends it on in ESP, numbered again */
	CHECKR((m = on_lan(orig_pkt(200, 64), 0)) && (keep = rte_pktmbuf_copy(m, pool, 0, UINT32_MAX)));
	engine_rx(v, LAN_WIRE_ETH, m, &g);
	CHECKR(g.n[LAN][CORE_KERNEL] == 1 && seen_count(&g) == 1 && same(g.m[LAN][CORE_KERNEL][0], keep));
	seen_free(&g);
	rte_pktmbuf_free(keep);
	CHECKR((m = kernel_esp(v, out, orig_pkt(200, 63))));
	engine_rx(v, KERNEL_ETH, framed(m, 0, 0), &g);
	CHECKR(g.n[WAN][CORE_WIRE] == 1 && seen_count(&g) == 1);
	seen_free(&g);
	/* ② the reply's ESP goes up as it came; the kernel sends the reply to PC1 */
	CHECKR((m = from_peer(v, far_sa, reply_pkt(300, 64))));
	CHECKR((keep = rte_pktmbuf_copy(m, pool, 0, UINT32_MAX)));
	engine_rx(v, WIRE_ETH, m, &g);
	CHECKR(g.n[WAN][CORE_KERNEL] == 1 && seen_count(&g) == 1 && same(g.m[WAN][CORE_KERNEL][0], keep));
	seen_free(&g);
	rte_pktmbuf_free(keep);
	CHECKR((m = on_lan(reply_pkt(300, 63), 1)) && (keep = rte_pktmbuf_copy(m, pool, 0, UINT32_MAX)));
	engine_rx(v, LAN_KERNEL_ETH, m, &g);
	CHECKR(g.n[LAN][CORE_WIRE] == 1 && seen_count(&g) == 1 && same(g.m[LAN][CORE_WIRE][0], keep));
	seen_free(&g);
	rte_pktmbuf_free(keep);
	return 0;
}

/* An SA's line of infos(), by SPI. */
static struct ipsec_sa_info
info_of_spi(struct env *v, uint32_t spi)
{
	struct infos a = infos(v);
	struct ipsec_sa_info none = { 0 };
	unsigned i;

	for (i = 0; i < a.n; i++)
		if (a.in[i].spi == spi)
			return a.in[i];
	return none;
}

TEST(a_connection_through_the_tunnel_is_accelerated_once_learned)
{
	struct env v;
	struct esp_sa_conf c = vpn(), in;
	struct rte_mbuf *m, *want, *read;
	struct seen g;
	struct core_conn cc;
	struct core_tuple o = { rte_cpu_to_be_32(PC1), rte_cpu_to_be_32(FAR),
				rte_cpu_to_be_16(40000), rte_cpu_to_be_16(5201) };

	CHECK(!env_new(&v, 4));
	in = vpn_in(&v, 0, SPI_IN, c.lane);
	CHECK(ipsec_sa_add(v.x, &c) == 0 && ipsec_sa_add(v.x, &in) == 0);
	CHECK(first_packets(&v, &c, 0) == 0);
	CHECK(bind_flow(&v) == 0 && core_count(v.c) == 1);
	CHECK(core_conn_get(v.c, IPPROTO_UDP, &o, &cc) == 0);
	CHECK(cc.in[0] == LAN && cc.out[0] == WAN && cc.in[1] == WAN && cc.out[1] == LAN);
	/* ③ PC1's packet: TTL - 1, in ESP with the engine's next number, the L2 header of the kernel's */
	CHECK((m = on_lan(orig_pkt(500, 64), 0)));
	engine_rx(&v, LAN_WIRE_ETH, m, &g);
	CHECK(g.n[WAN][CORE_WIRE] == 1 && seen_count(&g) == 1);
	m = g.m[WAN][CORE_WIRE][0];
	CHECK(!memcmp(rte_pktmbuf_mtod(m, uint8_t *), PEER_MAC, 6));
	CHECK(!memcmp(rte_pktmbuf_mtod(m, uint8_t *) + 6, ROUTER_MAC, 6));
	CHECK(seq_of(m, RTE_ETHER_HDR_LEN) == FIRST + 1);
	CHECK((want = orig_pkt(500, 63)));
	read = peer_reads(&v, &c, m, RTE_ETHER_HDR_LEN);
	CHECK(same(read, want));
	rte_pktmbuf_free(read);
	rte_pktmbuf_free(want);
	seen_free(&g);
	/* ④ the reply's ESP: decrypted, TTL - 1, to PC1 */
	CHECK((m = from_peer(&v, 0, reply_pkt(700, 64))));
	engine_rx(&v, WIRE_ETH, m, &g);
	CHECK(g.n[LAN][CORE_WIRE] == 1 && seen_count(&g) == 1);
	CHECK((want = on_lan(reply_pkt(700, 63), 1)));
	CHECK(same(g.m[LAN][CORE_WIRE][0], want));
	rte_pktmbuf_free(want);
	seen_free(&g);
	/* the SAs count what the engine did on its own: ③ and ④, not ① and ② */
	CHECK(info_of_spi(&v, SPI).packets == 1 && info_of_spi(&v, SPI).bytes == 500);
	CHECK(info_of_spi(&v, SPI_IN).packets == 1 && info_of_spi(&v, SPI_IN).bytes == 700);
	CHECK(info_of_spi(&v, SPI).last == FIRST + 1);
	CHECK(core_conn_get(v.c, IPPROTO_UDP, &o, &cc) == 0 && cc.pkts[0] == 1 && cc.pkts[1] == 1);
	env_free(&v);
}

/* What another tunnel decrypted is not of the connection, even with its tuple. */
TEST(a_packet_of_another_tunnel_goes_up_as_the_esp_it_came_in)
{
	struct env v;
	struct esp_sa_conf c = vpn(), in, other;
	struct rte_mbuf *m, *keep;
	struct seen g;

	CHECK(!env_new(&v, 4));
	in = vpn_in(&v, 0, SPI_IN, c.lane);
	other = vpn_in(&v, 1, SPI_IN + 1, c.lane + 1);
	CHECK(ipsec_sa_add(v.x, &c) == 0 && ipsec_sa_add(v.x, &in) == 0);
	CHECK(ipsec_sa_add(v.x, &other) == 0);
	CHECK(first_packets(&v, &c, 0) == 0);
	CHECK(bind_flow(&v) == 0);
	CHECK((m = from_peer(&v, 1, reply_pkt(300, 64))));
	CHECK((keep = rte_pktmbuf_copy(m, pool, 0, UINT32_MAX)));
	engine_rx(&v, WIRE_ETH, m, &g);
	CHECK(g.n[WAN][CORE_KERNEL] == 1 && seen_count(&g) == 1);
	CHECK(same(g.m[WAN][CORE_KERNEL][0], keep));
	CHECK(info_of_spi(&v, SPI_IN + 1).packets == 0);
	rte_pktmbuf_free(keep);
	seen_free(&g);
	env_free(&v);
}

/*
 * The packets the kernel must see (spec: always to the kernel), a packet of
 * no connection, and ESP the SEC does not decrypt: up as the ESP they came
 * in, and nothing else goes out.
 */
TEST(what_the_kernel_must_see_goes_up_as_the_esp_it_came_in)
{
	struct env v;
	struct esp_sa_conf c = vpn(), in;
	struct rte_mbuf *pkts[8], *m, *keep;
	struct rte_ipv4_hdr *ip;
	struct seen g;
	unsigned n = 0, i;

	CHECK(!env_new(&v, 4));
	in = vpn_in(&v, 0, SPI_IN, c.lane);
	CHECK(ipsec_sa_add(v.x, &c) == 0 && ipsec_sa_add(v.x, &in) == 0);
	CHECK(first_packets(&v, &c, 0) == 0);
	CHECK(bind_flow(&v) == 0);
	pkts[n++] = packet(IPPROTO_TCP, FAR, 5201, PC1, 40000, 60, 64, RTE_TCP_SYN_FLAG);
	pkts[n++] = packet(IPPROTO_TCP, FAR, 5201, PC1, 40000, 60, 64, RTE_TCP_FIN_FLAG);
	pkts[n++] = packet(IPPROTO_ICMP, FAR, 0, PC1, 0, 84, 64, 0);
	pkts[n++] = reply_pkt(300, 1);
	pkts[n] = reply_pkt(300, 64);
	ip = rte_pktmbuf_mtod(pkts[n], struct rte_ipv4_hdr *);
	ip->fragment_offset = rte_cpu_to_be_16(RTE_IPV4_HDR_MF_FLAG);
	ip->hdr_checksum = 0;
	ip->hdr_checksum = rte_ipv4_cksum(ip);
	n++;
	/* of no connection */
	pkts[n++] = packet(IPPROTO_UDP, FAR, 5202, PC1, 40000, 300, 64, 0);
	for (i = 0; i < n; i++) {
		CHECK((m = from_peer(&v, 0, pkts[i])));
		CHECK((keep = rte_pktmbuf_copy(m, pool, 0, UINT32_MAX)));
		engine_rx(&v, WIRE_ETH, m, &g);
		CHECK(g.n[WAN][CORE_KERNEL] == 1 && seen_count(&g) == 1);
		CHECK(same(g.m[WAN][CORE_KERNEL][0], keep));
		rte_pktmbuf_free(keep);
		seen_free(&g);
	}
	/* an ICV broken: the SEC fails it, the kernel decides */
	CHECK((m = from_peer(&v, 0, reply_pkt(300, 64))));
	rte_pktmbuf_mtod(m, uint8_t *)[m->pkt_len - 1] ^= 1;
	CHECK((keep = rte_pktmbuf_copy(m, pool, 0, UINT32_MAX)));
	engine_rx(&v, WIRE_ETH, m, &g);
	CHECK(g.n[WAN][CORE_KERNEL] == 1 && seen_count(&g) == 1);
	CHECK(same(g.m[WAN][CORE_KERNEL][0], keep));
	CHECK(info_of_spi(&v, SPI_IN).failed == 1 && info_of_spi(&v, SPI_IN).packets == 0);
	rte_pktmbuf_free(keep);
	seen_free(&g);
	env_free(&v);
}

/*
 * The ESP Linux made, as from the peer: an inbound SA with its keys
 * decrypts it, and its ping, which no connection has, goes up as it came.
 */
TEST(the_esp_linux_made_is_decrypted_on_an_inbound_sa_and_goes_up)
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

	for (i = 0; i < RTE_DIM(fx); i++) {
		struct env v;
		/* the router is the peer of the pcap: RIGHT */
		struct esp_sa_conf c = sa_conf(ESP_IN, fx[i].cipher, fx[i].auth, fx[i].key_len,
					       (int)fx[i].udp);
		struct rte_mbuf *m = linux_frame(fx[i].name), *keep;
		struct seen g;
		struct esp_sa_stats st;
		uint64_t ok = 0;
		uint32_t sa;

		c.replay = 32;
		CHECK(!env_new(&v, 4) && m && (keep = rte_pktmbuf_copy(m, pool, 0, UINT32_MAX)));
		CHECK(ipsec_sa_add(v.x, &c) == 0);
		engine_rx(&v, WIRE_ETH, m, &g);
		CHECK(g.n[WAN][CORE_KERNEL] == 1 && seen_count(&g) == 1);
		CHECK(same(g.m[WAN][CORE_KERNEL][0], keep));
		CHECK(info_of_spi(&v, SPI).failed == 0 && info_of_spi(&v, SPI).dropped == 0);
		/* the session of the SA made the packet */
		for (sa = 0; sa < 64; sa++)
			if (!esp_sa_stats(v.e, sa, &st))
				ok += st.ok;
		CHECK(ok == 1);
		rte_pktmbuf_free(keep);
		seen_free(&g);
		env_free(&v);
	}
}

/*
 * Spec: Chiều đi vượt MTU. The largest inner packet whose ESP fits 1500
 * bytes is 1422 with aes256-cbc + hmac-sha256-128 in UDP (Linux's MTU of
 * the tunnel); one byte more goes up in the clear, for the kernel.
 */
TEST(a_packet_too_large_for_the_tunnel_goes_up_in_the_clear)
{
	struct env v;
	struct esp_sa_conf c = vpn(), in;
	struct rte_mbuf *m, *keep;
	const struct rte_ipv4_hdr *ip;
	struct seen g;

	CHECK(!env_new(&v, 4));
	in = vpn_in(&v, 0, SPI_IN, c.lane);
	CHECK(ipsec_sa_add(v.x, &c) == 0 && ipsec_sa_add(v.x, &in) == 0);
	CHECK(first_packets(&v, &c, 0) == 0);
	CHECK(bind_flow(&v) == 0);
	CHECK((m = on_lan(orig_pkt(1422, 64), 0)));
	engine_rx(&v, LAN_WIRE_ETH, m, &g);
	CHECK(g.n[WAN][CORE_WIRE] == 1 && seen_count(&g) == 1);
	ip = rte_pktmbuf_mtod_offset(g.m[WAN][CORE_WIRE][0], const struct rte_ipv4_hdr *,
				     RTE_ETHER_HDR_LEN);
	CHECK(rte_be_to_cpu_16(ip->total_length) <= 1500);
	CHECK(!(ip->fragment_offset & rte_cpu_to_be_16(RTE_IPV4_HDR_MF_FLAG)));
	seen_free(&g);
	CHECK((m = on_lan(orig_pkt(1423, 64), 0)) && (keep = rte_pktmbuf_copy(m, pool, 0, UINT32_MAX)));
	engine_rx(&v, LAN_WIRE_ETH, m, &g);
	CHECK(g.n[LAN][CORE_KERNEL] == 1 && seen_count(&g) == 1);
	CHECK(same(g.m[LAN][CORE_KERNEL][0], keep));
	rte_pktmbuf_free(keep);
	seen_free(&g);
	env_free(&v);
}

/*
 * The tunnel encrypts with its newest outbound SA; when its last one stops,
 * its connections go through the kernel again, and what PC1 sends goes up.
 */
TEST(the_newest_outbound_sa_encrypts_and_without_one_the_connections_go_back)
{
	struct env v;
	struct esp_sa_conf c = vpn(), c2 = vpn(), in;
	struct rte_mbuf *m, *keep;
	struct seen g;

	CHECK(!env_new(&v, 4));
	in = vpn_in(&v, 0, SPI_IN, c.lane);
	c2.spi = SPI + 8;
	c2.seq = 100;
	CHECK(ipsec_sa_add(v.x, &c) == 0 && ipsec_sa_add(v.x, &in) == 0);
	CHECK(first_packets(&v, &c, 0) == 0);
	CHECK(bind_flow(&v) == 0);
	CHECK(ipsec_sa_add(v.x, &c2) == 0);
	CHECK((m = on_lan(orig_pkt(200, 64), 0)));
	engine_rx(&v, LAN_WIRE_ETH, m, &g);
	CHECK(g.n[WAN][CORE_WIRE] == 1 && seen_count(&g) == 1);
	CHECK(seq_of(g.m[WAN][CORE_WIRE][0], RTE_ETHER_HDR_LEN) == 100);
	seen_free(&g);
	/* the newest stops: the older one encrypts again */
	CHECK(ipsec_sa_stop(v.x, c2.spi, c2.dst, NOW, NULL, NULL, NULL) == 0 && core_count(v.c) == 1);
	CHECK((m = on_lan(orig_pkt(200, 64), 0)));
	engine_rx(&v, LAN_WIRE_ETH, m, &g);
	CHECK(g.n[WAN][CORE_WIRE] == 1 && seen_count(&g) == 1);
	CHECK(seq_of(g.m[WAN][CORE_WIRE][0], RTE_ETHER_HDR_LEN) == FIRST + 1);
	seen_free(&g);
	/* none left: the connection goes back to the kernel */
	CHECK(ipsec_sa_del(v.x, c.spi, c.dst, NOW, NULL, NULL, NULL) == 0);
	CHECK(core_count(v.c) == 0);
	CHECK((m = on_lan(orig_pkt(200, 64), 0)) && (keep = rte_pktmbuf_copy(m, pool, 0, UINT32_MAX)));
	engine_rx(&v, LAN_WIRE_ETH, m, &g);
	CHECK(g.n[LAN][CORE_KERNEL] == 1 && seen_count(&g) == 1 && same(g.m[LAN][CORE_KERNEL][0], keep));
	rte_pktmbuf_free(keep);
	seen_free(&g);
	env_free(&v);
}

/*
 * Another tunnel's packet with the tuple of the reply, learned before the
 * kernel checks its policy: the connection goes into the tunnel of its
 * outbound SA, so its reply must come in from that tunnel, which it does
 * once the tunnel's own reply comes again.
 */
TEST(a_reply_learned_from_another_tunnel_is_not_bound)
{
	struct env v;
	struct esp_sa_conf c = vpn(), in, other;
	struct rte_mbuf *m;
	struct seen g;
	unsigned missing;
	struct core_tuple o = { rte_cpu_to_be_32(PC1), rte_cpu_to_be_32(FAR),
				rte_cpu_to_be_16(40000), rte_cpu_to_be_16(5201) };
	struct core_tuple r = { rte_cpu_to_be_32(FAR), rte_cpu_to_be_32(PC1),
				rte_cpu_to_be_16(5201), rte_cpu_to_be_16(40000) };

	CHECK(!env_new(&v, 4));
	in = vpn_in(&v, 0, SPI_IN, c.lane);
	other = vpn_in(&v, 1, SPI_IN + 1, c.lane + 1);
	CHECK(ipsec_sa_add(v.x, &c) == 0 && ipsec_sa_add(v.x, &in) == 0);
	CHECK(ipsec_sa_add(v.x, &other) == 0);
	CHECK(first_packets(&v, &c, 0) == 0);
	CHECK((m = from_peer(&v, 1, reply_pkt(300, 64))));
	engine_rx(&v, WIRE_ETH, m, &g);
	seen_free(&g);
	CHECK(core_bind(v.c, IPPROTO_UDP, &o, &r, NOW, &missing) == -ENOENT);
	CHECK(missing == CORE_MISS_REPLY_IN);
	CHECK((m = from_peer(&v, 0, reply_pkt(300, 64))));
	engine_rx(&v, WIRE_ETH, m, &g);
	seen_free(&g);
	CHECK(bind_flow(&v) == 0);
	env_free(&v);
}

/*
 * Spec: Thứ tự gói. The worker the kernel's ESP of a tunnel comes to
 * encrypts all of the tunnel's, in one order: another worker hands its
 * packets into the tunnel over to it, and sends nothing of them.
 */
TEST(the_worker_the_kernels_esp_comes_to_encrypts_for_the_tunnel)
{
	struct env v;
	struct esp_sa_conf c = vpn(), in;
	struct esp_result r[ESP_BURST];
	struct rte_mbuf *m;
	struct ipsec_out io;
	struct core_out co;
	struct seen g;
	unsigned k;

	CHECK(!env_new(&v, 4));
	in = vpn_in(&v, 0, SPI_IN, c.lane);
	CHECK(ipsec_sa_add(v.x, &c) == 0 && ipsec_sa_add(v.x, &in) == 0);
	/* through worker 0: the tunnel's from then on */
	CHECK(first_packets(&v, &c, 0) == 0);
	CHECK(bind_flow(&v) == 0);
	CHECK((m = on_lan(orig_pkt(200, 64), 0)));
	m->port = LAN_WIRE_ETH;
	core_rx(v.c, 1, &m, 1, NOW, &co);
	CHECK(co.ntun == 1);
	ipsec_tunnel(v.x, 1, co.tun, co.ntun, &io);
	CHECK(io.naway == 1 && io.away[0].worker == 0 && io.away[0].t.m == m);
	CHECK(esp_poll(v.e, 1, r, ESP_BURST) == 0);
	/* worker 0 takes it */
	ipsec_tunnel(v.x, 0, &io.away[0].t, 1, &io);
	CHECK(io.naway == 0);
	memset(&g, 0, sizeof(g));
	while ((k = esp_poll(v.e, 0, r, ESP_BURST))) {
		ipsec_done(v.x, 0, r, k, NOW, &io);
		seen_out(&g, &io);
	}
	CHECK(g.n[WAN][CORE_WIRE] == 1 && seen_count(&g) == 1);
	CHECK(seq_of(g.m[WAN][CORE_WIRE][0], RTE_ETHER_HDR_LEN) == FIRST + 1);
	seen_free(&g);
	env_free(&v);
}

/* A tunnel gone: what was learned of it goes too, its number may be another's. */
TEST(what_was_learned_of_a_tunnel_goes_with_it)
{
	struct env v;
	struct esp_sa_conf c = vpn(), in;
	unsigned missing;
	struct core_tuple o = { rte_cpu_to_be_32(PC1), rte_cpu_to_be_32(FAR),
				rte_cpu_to_be_16(40000), rte_cpu_to_be_16(5201) };
	struct core_tuple r = { rte_cpu_to_be_32(FAR), rte_cpu_to_be_32(PC1),
				rte_cpu_to_be_16(5201), rte_cpu_to_be_16(40000) };

	CHECK(!env_new(&v, 4));
	in = vpn_in(&v, 0, SPI_IN, c.lane);
	CHECK(ipsec_sa_add(v.x, &c) == 0 && ipsec_sa_add(v.x, &in) == 0);
	CHECK(first_packets(&v, &c, 0) == 0);
	CHECK(ipsec_sa_flush(v.x, NOW, NULL, NULL, NULL) == 2);
	CHECK(ipsec_sa_add(v.x, &c) == 0 && ipsec_sa_add(v.x, &in) == 0);
	CHECK(core_bind(v.c, IPPROTO_UDP, &o, &r, NOW, &missing) == -ENOENT);
	CHECK(missing == (CORE_MISS_ORIG_OUT | CORE_MISS_REPLY_IN));
	env_free(&v);
}

/* The connections the engine says it let go of. */
struct told {
	unsigned n;
	struct core_tuple orig[4];
};

static void
told_one(const struct core_conn *cn, void *arg)
{
	struct told *t = arg;

	if (t->n < RTE_DIM(t->orig))
		t->orig[t->n] = cn->orig;
	t->n++;
}

static int
is_the_flow(const struct core_tuple *o)
{
	return o->sip == rte_cpu_to_be_32(PC1) && o->dip == rte_cpu_to_be_32(FAR) &&
	       o->sport == rte_cpu_to_be_16(40000) && o->dport == rte_cpu_to_be_16(5201);
}

/* ③: PC1's packet of len goes out in ESP numbered seq, which the peer reads with SA out. */
static int
goes_out_on(struct env *v, const struct esp_sa_conf *out, unsigned len, uint32_t seq)
{
	struct rte_mbuf *m, *want, *read;
	struct seen g;
	int ok;

	CHECKR((m = on_lan(orig_pkt(len, 64), 0)));
	engine_rx(v, LAN_WIRE_ETH, m, &g);
	CHECKR(g.n[WAN][CORE_WIRE] == 1 && seen_count(&g) == 1);
	CHECKR(seq_of(g.m[WAN][CORE_WIRE][0], RTE_ETHER_HDR_LEN) == seq);
	want = orig_pkt(len, 63);
	read = peer_reads(v, out, g.m[WAN][CORE_WIRE][0], RTE_ETHER_HDR_LEN);
	ok = same(read, want);
	rte_pktmbuf_free(read);
	rte_pktmbuf_free(want);
	seen_free(&g);
	return ok ? 0 : -1;
}

/* ④: the peer's reply of len in ESP through its SA far_sa reaches PC1, TTL - 1. */
static int
comes_in_on(struct env *v, uint32_t far_sa, unsigned len)
{
	struct rte_mbuf *m, *want;
	struct seen g;
	int ok;

	CHECKR((m = from_peer(v, far_sa, reply_pkt(len, 64))));
	engine_rx(v, WIRE_ETH, m, &g);
	CHECKR(g.n[LAN][CORE_WIRE] == 1 && seen_count(&g) == 1);
	want = on_lan(reply_pkt(len, 63), 1);
	ok = same(g.m[LAN][CORE_WIRE][0], want);
	rte_pktmbuf_free(want);
	seen_free(&g);
	return ok ? 0 : -1;
}

/* m from ethdev goes on as it came, to side of port, and nothing else does. */
static int
goes_on_as_it_is(struct env *v, uint16_t ethdev, struct rte_mbuf *m, unsigned port, unsigned side)
{
	struct rte_mbuf *keep = m ? rte_pktmbuf_copy(m, pool_for(m->pkt_len), 0, UINT32_MAX) : NULL;
	struct seen g;
	int ok;

	CHECKR(keep);
	engine_rx(v, ethdev, m, &g);
	ok = g.n[port][side] == 1 && seen_count(&g) == 1 && same(g.m[port][side][0], keep);
	rte_pktmbuf_free(keep);
	seen_free(&g);
	return ok ? 0 : -1;
}

/*
 * Q9: a rekey. The new SAs go through the kernel until they are handed
 * over; then the tunnel's connection goes out on the new outbound SA,
 * numbered from its first, and comes in on the new inbound one, without
 * being let go of (an entry is of its tunnel, not of an SPI). The old SAs
 * deleted, nothing of the tunnel goes.
 */
TEST(a_rekey_moves_the_tunnels_connection_to_the_new_sas)
{
	struct env v;
	struct esp_sa_conf c = vpn(), c2 = vpn(), in, in2;
	struct rte_mbuf *m;
	struct told t = { 0 };

	CHECK(!env_new(&v, 4));
	in = vpn_in(&v, 0, SPI_IN, c.lane);
	CHECK(ipsec_sa_add(v.x, &c) == 0 && ipsec_sa_add(v.x, &in) == 0);
	CHECK(first_packets(&v, &c, 0) == 0);
	CHECK(bind_flow(&v) == 0);
	CHECK(goes_out_on(&v, &c, 500, FIRST + 1) == 0);
	/* strongSwan made the new SAs: not handed over yet, the kernel numbers its ESP on them */
	c2.spi = SPI + 8;
	c2.seq = FIRST + 1000;
	in2 = vpn_in(&v, 1, SPI_IN + 8, c.lane);
	CHECK((m = kernel_esp(&v, &c2, orig_pkt(200, 63))));
	CHECK(goes_on_as_it_is(&v, KERNEL_ETH, framed(m, 0, 0), WAN, CORE_WIRE) == 0);
	CHECK(goes_on_as_it_is(&v, WIRE_ETH, from_peer(&v, 1, reply_pkt(300, 64)), WAN,
			       CORE_KERNEL) == 0);
	CHECK(comes_in_on(&v, 0, 700) == 0);
	/* handed over */
	CHECK(ipsec_sa_add(v.x, &c2) == 0 && ipsec_sa_add(v.x, &in2) == 0);
	CHECK(core_count(v.c) == 1);
	CHECK(goes_out_on(&v, &c2, 500, FIRST + 1000) == 0);
	CHECK(comes_in_on(&v, 1, 700) == 0);
	/* the peer still sends on the old inbound one for a while */
	CHECK(comes_in_on(&v, 0, 700) == 0);
	/* the old ones deleted */
	CHECK(ipsec_sa_del(v.x, c.spi, c.dst, NOW, NULL, told_one, &t) == 0);
	CHECK(ipsec_sa_del(v.x, in.spi, in.dst, NOW, NULL, told_one, &t) == 0);
	CHECK(t.n == 0 && core_count(v.c) == 1 && ipsec_sa_count(v.x) == 2);
	CHECK(goes_out_on(&v, &c2, 500, FIRST + 1001) == 0);
	CHECK(comes_in_on(&v, 1, 700) == 0);
	CHECK(info_of_spi(&v, c2.spi).packets == 2 && info_of_spi(&v, in2.spi).packets == 2);
	env_free(&v);
}

/*
 * The connections a tunnel lets go of because it has no outbound SA left,
 * or no SA at all, are told, so that the daemon hands them over again once
 * they can be: stopping its only outbound SA, flushing.
 */
TEST(the_connections_a_tunnel_lets_go_of_are_told)
{
	struct env v;
	struct esp_sa_conf c = vpn(), in;
	struct told t = { 0 };

	CHECK(!env_new(&v, 4));
	in = vpn_in(&v, 0, SPI_IN, c.lane);
	CHECK(ipsec_sa_add(v.x, &c) == 0 && ipsec_sa_add(v.x, &in) == 0);
	CHECK(first_packets(&v, &c, 0) == 0);
	CHECK(bind_flow(&v) == 0);
	CHECK(ipsec_sa_stop(v.x, c.spi, c.dst, NOW, NULL, told_one, &t) == 0);
	CHECK(t.n == 1 && is_the_flow(&t.orig[0]) && core_count(v.c) == 0);
	CHECK(ipsec_sa_del(v.x, c.spi, c.dst, NOW, NULL, told_one, &t) == 0 && t.n == 1);
	/* held again and learned again */
	c.seq = FIRST + 10;
	CHECK(ipsec_sa_add(v.x, &c) == 0);
	CHECK(first_packets(&v, &c, 0) == 0);
	CHECK(bind_flow(&v) == 0);
	/* the inbound SA alone goes: the tunnel still has its outbound one */
	CHECK(ipsec_sa_del(v.x, in.spi, in.dst, NOW, NULL, told_one, &t) == 0 && t.n == 1);
	CHECK(core_count(v.c) == 1);
	CHECK(ipsec_sa_flush(v.x, NOW, NULL, told_one, &t) == 1);
	CHECK(t.n == 2 && is_the_flow(&t.orig[1]) && core_count(v.c) == 0);
	env_free(&v);
}

/*
 * Q12: the engine numbers no packet past 2^32 - 2^26. Past it, the kernel's
 * ESP and the connection's packets are dropped and counted, and the SA says
 * it used the last number, for the daemon to let go of it.
 */
TEST(the_engine_numbers_nothing_past_the_end_of_the_numbers)
{
	struct env v;
	struct esp_sa_conf c = vpn(), in;
	struct rte_mbuf *m, *got[MAX_GOT];
	struct seen g;
	unsigned ngot = 0;

	CHECK(!env_new(&v, 4));
	in = vpn_in(&v, 0, SPI_IN, c.lane);
	c.seq = IPSEC_SEQ_MAX - 1;
	CHECK(ipsec_sa_add(v.x, &c) == 0 && ipsec_sa_add(v.x, &in) == 0);
	/* the kernel's first ESP takes IPSEC_SEQ_MAX - 1 */
	CHECK(first_packets(&v, &c, 0) == 0);
	CHECK(bind_flow(&v) == 0);
	CHECK(goes_out_on(&v, &c, 500, IPSEC_SEQ_MAX) == 0);
	CHECK(info_of_spi(&v, SPI).last == IPSEC_SEQ_MAX && info_of_spi(&v, SPI).dropped == 0);
	CHECK((m = on_lan(orig_pkt(500, 64), 0)));
	engine_rx(&v, LAN_WIRE_ETH, m, &g);
	CHECK(seen_count(&g) == 0);
	CHECK((m = linux_frame("cbc256-sha256-udp")));
	CHECK(feed(&v, &m, 1, got, &ngot) == 0 && ngot == 0);
	CHECK(info_of_spi(&v, SPI).last == IPSEC_SEQ_MAX && info_of_spi(&v, SPI).dropped == 2);
	/* inbound, nothing changes */
	CHECK(comes_in_on(&v, 0, 700) == 0);
	env_free(&v);
}

TEST(an_outbound_sa_without_a_number_left_is_refused)
{
	struct env v;
	struct esp_sa_conf c = vpn();

	CHECK(!env_new(&v, 4));
	c.seq = IPSEC_SEQ_MAX + 1;
	CHECK(ipsec_sa_add(v.x, &c) == -EINVAL);
	CHECK(ipsec_sa_count(v.x) == 0 && esp_sa_count(v.e) == 0);
	c.seq = IPSEC_SEQ_MAX;
	CHECK(ipsec_sa_add(v.x, &c) == 0);
	env_free(&v);
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
	pool = rte_pktmbuf_pool_create("test", 2047, 0, IPSEC_PRIV_SIZE, RTE_MBUF_DEFAULT_BUF_SIZE,
				       SOCKET_ID_ANY);
	big = rte_pktmbuf_pool_create("big", 63, 0, IPSEC_PRIV_SIZE, IPSEC_WHOLE_SIZE, SOCKET_ID_ANY);
	if (!pool || !big) {
		fprintf(stderr, "no mbuf pool\n");
		return 2;
	}
	/* argv[0] is the program's name again */
	return test_main(argc - 1, argv + 1);
}
