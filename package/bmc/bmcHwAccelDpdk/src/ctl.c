/*
 * The control protocol of bmchwaccel-engine, over a UNIX stream socket. On
 * connect the engine says "bmchwaccel-engine 1" (1: the version). Each
 * request is one line; the reply is zero or more lines of data, then one
 * line "ok [...]" or "err REASON". Addresses are dotted IPv4, ports
 * decimal; a connection is given as conntrack has it, the tuple of the
 * original direction then the one of the reply direction, each as source
 * address, source port, destination address, destination port.
 *
 *   bind tcp|udp OSIP OSPORT ODIP ODPORT RSIP RSPORT RDIP RDPORT
 *        ok | err unlearned WHAT[,WHAT...] | err exists | err full
 *        WHAT: orig-in, orig-out, reply-in, reply-out (core.h)
 *   unbind tcp|udp OSIP OSPORT ODIP ODPORT          ok | err unknown
 *   flush                                           ok N
 *   flush-port PORT
 *   flush-route ADDRESS/LEN
 *   flush-mac MAC
 *           conn tcp|udp OSIP OSPORT ODIP ODPORT
 *           per connection let go of, then ok N (flush-port: or err
 *           unknown-port; the others: or err usage): the connections through
 *           PORT, the ones with a direction sent to an address of the
 *           network ADDRESS/LEN after NAT, the ones with a direction sent to
 *           the MAC address MAC (aa:bb:cc:dd:ee:ff); core_flush_port() and
 *           the others of core.h. flush-route also lets go of the
 *           connections through a Tunnel IPsec whose peer is in the
 *           network (ipsec_flush_peer()): the tunnel's outer packets go
 *           there. bmchwaccel-syncd sends them when a cable, a route or a
 *           neighbour changes, and binds the connections again.
 *   count                                           ok N
 *   list    conn tcp|udp OSIP OSPORT ODIP ODPORT RSIP RSPORT RDIP RDPORT
 *                orig_in=PORT orig_out=PORT orig_pkts=N orig_bytes=N orig_idle=MS
 *                reply_in=PORT reply_out=PORT reply_pkts=N reply_bytes=N reply_idle=MS
 *           per connection, then ok N
 *   stats   port PORT wire_rx=N wire_tx=N kernel_rx=N kernel_tx=N
 *           per port (packets of its two sides), then ok
 *   ports   port PORT link=up|down speed=MBPS|unknown rx_bytes=N tx_bytes=N
 *                rx_packets=N tx_packets=N
 *           per port, of its cable side: the link and speed of the MAC
 *           and what crossed the cable, then ok
 *   claim                                           ok | err claimed
 *           the session becomes the one of the daemon that hands
 *           connections over and takes them back (bmchwaccel-syncd): when
 *           it closes, the engine lets go of every connection, since nobody
 *           would take them back when they end. One session at a time.
 *   claimed                                         ok yes | ok no
 *   active MS
 *           conn tcp|udp OSIP OSPORT ODIP ODPORT idle=MS
 *           per connection that forwarded a packet within the last MS ms
 *           (idle: since the last one, either direction), then ok N
 *   esp     esp state=ok device=DEV queue_pairs=N sas=N max_sas=N
 *           | esp state=none | esp state=failed
 *           then ok: ESP on the SEC (esp.h); none: the container has no
 *           SEC; failed: it did not pass its self-test at the start.
 *           queue_pairs: of each worker
 *
 * Tunnel IPsec (ipsec.h), for bmchwaccel-syncd, which hands over the SAs of
 * the kernel. SPI in hex (0x optional), ports and numbers in decimal:
 *
 *   sa-add out|in SPI SRC DST SPORT DPORT REQID CIPHER KEY AUTH AUTHKEY REPLAY SEQ
 *        ok | err exists | err full | err unsupported | err no-esp | err usage
 *        an SA of the kernel: SRC and DST its outer addresses, SPORT DPORT
 *        those of ESP in UDP (0 0: plain ESP), REQID its tunnel; CIPHER cbc
 *        or gcm, KEY in hex (gcm: the key then the 4 bytes of salt, as
 *        xfrm has it); AUTH sha1, sha256, sha384, sha512 (HMAC, truncated as
 *        in RFC 4868 and 2404) or none (gcm), AUTHKEY in hex or -; REPLAY the
 *        window of an inbound SA, 0 for an outbound one; SEQ the number of
 *        the first packet of an outbound SA, 0 for an inbound one. full:
 *        a tunnel past IPSEC_MAX_TUNNELS, or no room for the SA
 *   sa-stop SPI DST     the SA's line, then ok | err unknown
 *   sa-del SPI DST      the SA's line, then ok | err unknown
 *   sa-flush            each SA's line, then ok N
 *           let go of, in order (ipsec.h): stop, after which the engine no
 *           longer uses the SA and drops the ESP the kernel sends on it (seq
 *           of the line is final), then del, after which that ESP goes out
 *           as it is; del (or flush) alone does both. A tunnel left without
 *           an outbound SA, or without an SA, lets go of its connections:
 *           conn tcp|udp OSIP OSPORT ODIP ODPORT for each, as flush-port has
 *           them (bmchwaccel-syncd binds them again): after the SA's line
 *           (sa-flush: before the line of the SA that let them go)
 *   sa      sa spi=0xSPI dir=out|in reqid=N src=A dst=B bytes=N packets=N
 *              [seq=N] failed=N dropped=N
 *           per SA held, then ok N: seq of an outbound one is the highest
 *           number it may have used; bytes and packets what the engine
 *           encrypted or decrypted on its own; failed, dropped its jobs the
 *           SEC failed and those lost on the way
 *
 * Anything else: err usage, or err unknown-command.
 */
#define _GNU_SOURCE	/* explicit_bzero */
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <rte_ethdev.h>

#include "engine.h"

void
buf_printf(struct buf *b, const char *fmt, ...)
{
	va_list ap;
	int n;

	for (;;) {
		va_start(ap, fmt);
		n = vsnprintf(b->s ? b->s + b->len : NULL, b->size - b->len, fmt, ap);
		va_end(ap);
		if (n < 0)
			return;
		if (b->len + (size_t)n < b->size) {
			b->len += (size_t)n;
			return;
		}
		b->size = (b->len + (size_t)n + 1) * 2;
		b->s = realloc(b->s, b->size);
		if (!b->s)
			abort();
	}
}

static int
proto_of(const char *s, uint8_t *proto)
{
	if (s && !strcmp(s, "tcp"))
		*proto = IPPROTO_TCP;
	else if (s && !strcmp(s, "udp"))
		*proto = IPPROTO_UDP;
	else
		return -1;
	return 0;
}

static const char *
proto_name(uint8_t proto)
{
	return proto == IPPROTO_TCP ? "tcp" : "udp";
}

static int
port_of(const char *s, uint16_t *port)
{
	char *end;
	unsigned long v;

	if (!s)
		return -1;
	v = strtoul(s, &end, 10);
	if (*s == '\0' || *end != '\0' || v > 65535)
		return -1;
	*port = rte_cpu_to_be_16((uint16_t)v);
	return 0;
}

/* Four words: address, port, address, port. */
static int
tuple_of(char **w, struct core_tuple *t)
{
	if (!w[0] || !w[2] || inet_pton(AF_INET, w[0], &t->sip) != 1 ||
	    inet_pton(AF_INET, w[2], &t->dip) != 1)
		return -1;
	return port_of(w[1], &t->sport) || port_of(w[3], &t->dport);
}

static void
tuple_print(struct buf *b, const struct core_tuple *t)
{
	char s[INET_ADDRSTRLEN], d[INET_ADDRSTRLEN];

	inet_ntop(AF_INET, &t->sip, s, sizeof(s));
	inet_ntop(AF_INET, &t->dip, d, sizeof(d));
	buf_printf(b, " %s %u %s %u", s, rte_be_to_cpu_16(t->sport), d, rte_be_to_cpu_16(t->dport));
}

static int
port_named(const struct engine *e, const char *name)
{
	unsigned i;

	for (i = 0; name && i < e->nports; i++)
		if (!strcmp(e->port[i].name, name))
			return (int)i;
	return -1;
}

/* The words after the name of a command; now: the time of the request. */
static void
do_bind(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	static const char *const what[] = { "orig-in", "orig-out", "reply-in", "reply-out" };
	struct core_tuple o, r;
	unsigned missing, i;
	const char *sep = " ";
	uint8_t proto;
	int ret;

	if (proto_of(w[0], &proto) || tuple_of(w + 1, &o) || tuple_of(w + 5, &r)) {
		buf_printf(out, "err usage\n");
		return;
	}
	ret = core_bind(e->core, proto, &o, &r, now, &missing);
	switch (ret) {
	case 0:
		buf_printf(out, "ok\n");
		break;
	case -ENOENT:
		buf_printf(out, "err unlearned");
		for (i = 0; i < RTE_DIM(what); i++)
			if (missing & 1u << i) {
				buf_printf(out, "%s%s", sep, what[i]);
				sep = ",";
			}
		buf_printf(out, "\n");
		break;
	case -EEXIST:
		buf_printf(out, "err exists\n");
		break;
	case -ENOSPC:
		buf_printf(out, "err full\n");
		break;
	default:
		buf_printf(out, "err usage\n");
	}
}

struct list_arg {
	struct engine *e;
	struct buf *out;
	uint32_t now;
	unsigned n;
};

static int
list_one(const struct core_conn *cn, void *arg)
{
	struct list_arg *a = arg;
	static const char *const dir[] = { "orig", "reply" };
	int d;

	buf_printf(a->out, "conn %s", proto_name(cn->proto));
	tuple_print(a->out, &cn->orig);
	tuple_print(a->out, &cn->reply);
	for (d = 0; d < 2; d++)
		buf_printf(a->out, " %s_in=%s %s_out=%s %s_pkts=%u %s_bytes=%llu %s_idle=%u",
			   dir[d], a->e->port[cn->in[d]].name, dir[d], a->e->port[cn->out[d]].name,
			   dir[d], cn->pkts[d], dir[d], (unsigned long long)cn->bytes[d], dir[d],
			   (uint32_t)(a->now - cn->last[d]));
	buf_printf(a->out, "\n");
	a->n++;
	return 0;
}

static void
do_unbind(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	struct core_tuple o;
	uint8_t proto;

	if (proto_of(w[0], &proto) || tuple_of(w + 1, &o))
		buf_printf(out, "err usage\n");
	else if (core_unbind(e->core, proto, &o, now))
		buf_printf(out, "err unknown\n");
	else
		buf_printf(out, "ok\n");
}

static void
do_flush(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	(void)w;
	buf_printf(out, "ok %u\n", core_flush(e->core, now));
}

/* A connection a flush let go of. */
static void
flushed_one(const struct core_conn *cn, void *arg)
{
	struct buf *out = arg;

	buf_printf(out, "conn %s", proto_name(cn->proto));
	tuple_print(out, &cn->orig);
	buf_printf(out, "\n");
}

static void
do_flush_port(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	int p = port_named(e, w[0]);

	if (p < 0)
		buf_printf(out, "err unknown-port\n");
	else
		buf_printf(out, "ok %u\n", core_flush_port(e->core, (unsigned)p, now, flushed_one, out));
}

static void
do_flush_route(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	char *slash = strchr(w[0], '/'), *end;
	unsigned long len;
	uint32_t dst;
	unsigned n;

	if (!slash) {
		buf_printf(out, "err usage\n");
		return;
	}
	*slash = '\0';
	len = strtoul(slash + 1, &end, 10);
	if (inet_pton(AF_INET, w[0], &dst) != 1 || slash[1] < '0' || slash[1] > '9' ||
	    *end != '\0' || len > 32) {
		buf_printf(out, "err usage\n");
		return;
	}
	n = core_flush_route(e->core, dst, (unsigned)len, now, flushed_one, out);
	if (e->ipsec)
		n += ipsec_flush_peer(e->ipsec, dst, (unsigned)len, now, flushed_one, out);
	buf_printf(out, "ok %u\n", n);
}

static void
do_flush_mac(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	struct rte_ether_addr mac;

	if (strlen(w[0]) != 17 || rte_ether_unformat_addr(w[0], &mac)) {
		buf_printf(out, "err usage\n");
		return;
	}
	buf_printf(out, "ok %u\n", core_flush_mac(e->core, mac.addr_bytes, now, flushed_one, out));
}

static void
do_count(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	(void)w;
	(void)now;
	buf_printf(out, "ok %u\n", core_count(e->core));
}

static void
do_list(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	struct list_arg a = { e, out, now, 0 };

	(void)w;
	core_conn_walk(e->core, list_one, &a);
	buf_printf(out, "ok %u\n", a.n);
}

static void
do_claim(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	(void)w;
	(void)now;
	if (e->daemon >= 0 && e->daemon != e->session) {
		buf_printf(out, "err claimed\n");
		return;
	}
	e->daemon = e->session;
	buf_printf(out, "ok\n");
}

static void
do_claimed(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	(void)w;
	(void)now;
	buf_printf(out, "ok %s\n", e->daemon >= 0 ? "yes" : "no");
}

struct active_arg {
	struct buf *out;
	uint32_t now, within;
	unsigned n;
};

static int
active_one(const struct core_conn *cn, void *arg)
{
	struct active_arg *a = arg;
	uint32_t idle = UINT32_MAX;
	int d;

	for (d = 0; d < 2; d++)
		if (cn->pkts[d] && (uint32_t)(a->now - cn->last[d]) < idle)
			idle = a->now - cn->last[d];
	if (idle >= a->within)
		return 0;
	buf_printf(a->out, "conn %s", proto_name(cn->proto));
	tuple_print(a->out, &cn->orig);
	buf_printf(a->out, " idle=%u\n", idle);
	a->n++;
	return 0;
}

static void
do_active(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	struct active_arg a = { out, now, 0, 0 };
	char *end;
	unsigned long ms = strtoul(w[0], &end, 10);

	if (*w[0] < '0' || *w[0] > '9' || *end != '\0' || ms > UINT32_MAX) {
		buf_printf(out, "err usage\n");
		return;
	}
	a.within = (uint32_t)ms;
	core_conn_walk(e->core, active_one, &a);
	buf_printf(out, "ok %u\n", a.n);
}

static void
do_stats(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	unsigned i;

	(void)w;
	(void)now;
	for (i = 0; i < e->nports; i++) {
		struct rte_eth_stats ws = { 0 }, ks = { 0 };

		rte_eth_stats_get(e->port[i].ethdev[CORE_WIRE], &ws);
		rte_eth_stats_get(e->port[i].ethdev[CORE_KERNEL], &ks);
		buf_printf(out, "port %s wire_rx=%llu wire_tx=%llu kernel_rx=%llu kernel_tx=%llu\n",
			   e->port[i].name, (unsigned long long)ws.ipackets,
			   (unsigned long long)ws.opackets, (unsigned long long)ks.ipackets,
			   (unsigned long long)ks.opackets);
	}
	buf_printf(out, "ok\n");
}

/*
 * The kernel's port of an engine port sees only what goes through the
 * kernel, and the speed of its link to the engine is none: the web UI reads
 * the cable side here instead. On DPAA2 the link of dpni.X is the one of
 * the dpmac it is linked to.
 */
static void
do_ports(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	unsigned i;

	(void)w;
	(void)now;
	for (i = 0; i < e->nports; i++) {
		uint16_t d = e->port[i].ethdev[CORE_WIRE];
		struct rte_eth_stats st = { 0 };
		struct rte_eth_link l = { 0 };
		int up;

		rte_eth_stats_get(d, &st);
		up = !rte_eth_link_get_nowait(d, &l) && l.link_status == RTE_ETH_LINK_UP;
		buf_printf(out, "port %s link=%s", e->port[i].name, up ? "up" : "down");
		if (up && l.link_speed != RTE_ETH_SPEED_NUM_NONE &&
		    l.link_speed != RTE_ETH_SPEED_NUM_UNKNOWN)
			buf_printf(out, " speed=%u", l.link_speed);
		else
			buf_printf(out, " speed=unknown");
		buf_printf(out, " rx_bytes=%llu tx_bytes=%llu rx_packets=%llu tx_packets=%llu\n",
			   (unsigned long long)st.ibytes, (unsigned long long)st.obytes,
			   (unsigned long long)st.ipackets, (unsigned long long)st.opackets);
	}
	buf_printf(out, "ok\n");
}

/* n bytes of hex into b, exactly. */
static int
hex_of(const char *s, uint8_t *b, size_t max, size_t *n)
{
	size_t len = strlen(s), i;

	if (len % 2 || len / 2 > max)
		return -1;
	for (i = 0; i < len / 2; i++) {
		unsigned v;

		if (sscanf(s + 2 * i, "%2x", &v) != 1 || !isxdigit((unsigned char)s[2 * i]) ||
		    !isxdigit((unsigned char)s[2 * i + 1]))
			return -1;
		b[i] = (uint8_t)v;
	}
	*n = len / 2;
	return 0;
}

static int
u32_of(const char *s, int base, uint32_t *v)
{
	char *end;
	unsigned long n;

	if (!s || !*s || *s == '-' || *s == '+')
		return -1;
	errno = 0;
	n = strtoul(s, &end, base);
	if (*end || errno || n > UINT32_MAX)
		return -1;
	*v = (uint32_t)n;
	return 0;
}

/* The words of sa-add into c; -1 when they are no SA. */
static int
sa_conf_of(char **w, struct esp_sa_conf *c)
{
	static const char *const auth[] = { "none", "sha1", "sha256", "sha384", "sha512" };
	uint32_t sport, dport, replay;
	uint8_t key[36];
	size_t n, i;

	memset(c, 0, sizeof(*c));
	if (!strcmp(w[0], "out"))
		c->dir = ESP_OUT;
	else if (!strcmp(w[0], "in"))
		c->dir = ESP_IN;
	else
		return -1;
	if (u32_of(w[1], 16, &c->spi) || inet_pton(AF_INET, w[2], &c->src) != 1 ||
	    inet_pton(AF_INET, w[3], &c->dst) != 1 || u32_of(w[4], 10, &sport) || sport > 65535 ||
	    u32_of(w[5], 10, &dport) || dport > 65535 || u32_of(w[6], 10, &c->lane) ||
	    u32_of(w[11], 10, &replay) || replay > 65535 || u32_of(w[12], 10, &c->seq))
		return -1;
	c->sport = (uint16_t)sport;
	c->dport = (uint16_t)dport;
	c->replay = (uint16_t)replay;
	if (hex_of(w[8], key, sizeof(key), &n))
		return -1;
	if (!strcmp(w[7], "gcm")) {
		if (n != 20 && n != 36)
			return -1;
		c->cipher = ESP_AES_GCM;
		c->key_len = (uint8_t)(n - 4);
		memcpy(c->salt, key + n - 4, 4);
	} else if (!strcmp(w[7], "cbc")) {
		c->cipher = ESP_AES_CBC;
		c->key_len = (uint8_t)n;
	} else {
		return -1;
	}
	memcpy(c->key, key, c->key_len);
	explicit_bzero(key, sizeof(key));
	for (i = 0; i < RTE_DIM(auth) && strcmp(w[9], auth[i]); i++)
		;
	if (i == RTE_DIM(auth))
		return -1;
	c->auth = (uint8_t)i;
	if (strcmp(w[10], "-")) {
		if (hex_of(w[10], c->auth_key, sizeof(c->auth_key), &n))
			return -1;
		c->auth_key_len = (uint8_t)n;
	}
	return 0;
}

static void
do_sa_add(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	struct esp_sa_conf c;
	int ret;

	(void)now;
	if (sa_conf_of(w, &c)) {
		buf_printf(out, "err usage\n");
		return;
	}
	if (!e->ipsec) {
		buf_printf(out, "err no-esp\n");
		return;
	}
	ret = ipsec_sa_add(e->ipsec, &c);
	/* the keys are no longer needed here */
	explicit_bzero(&c, sizeof(c));
	buf_printf(out, "%s\n", !ret ? "ok" : ret == -EEXIST ? "err exists" :
				  ret == -ENOSPC ? "err full" : "err unsupported");
}

static int
sa_line(const struct ipsec_sa_info *in, void *arg)
{
	struct buf *out = arg;
	char s[INET_ADDRSTRLEN], d[INET_ADDRSTRLEN];

	inet_ntop(AF_INET, &in->src, s, sizeof(s));
	inet_ntop(AF_INET, &in->dst, d, sizeof(d));
	buf_printf(out, "sa spi=0x%08x dir=%s reqid=%u src=%s dst=%s bytes=%llu packets=%llu",
		   in->spi, in->dir == ESP_OUT ? "out" : "in", in->reqid, s, d,
		   (unsigned long long)in->bytes, (unsigned long long)in->packets);
	if (in->dir == ESP_OUT)
		buf_printf(out, " seq=%u", in->last);
	buf_printf(out, " failed=%llu dropped=%llu\n", (unsigned long long)in->failed,
		   (unsigned long long)in->dropped);
	return 0;
}

static void
sa_flushed(const struct ipsec_sa_info *in, void *arg)
{
	sa_line(in, arg);
}

/* sa-stop and sa-del: the words SPI DST, then fn of ipsec.h. */
static void
sa_let_go(struct engine *e, char **w, uint32_t now, struct buf *out,
	  int (*fn)(struct ipsec *, uint32_t, uint32_t, uint32_t, struct ipsec_sa_info *,
		    core_flushed_fn *, void *))
{
	struct ipsec_sa_info in;
	struct buf conns = { 0 };	/* the connections let go of, after the SA's line */
	uint32_t spi, dst;

	if (u32_of(w[0], 16, &spi) || inet_pton(AF_INET, w[1], &dst) != 1)
		buf_printf(out, "err usage\n");
	else if (!e->ipsec || fn(e->ipsec, spi, dst, now, &in, flushed_one, &conns))
		buf_printf(out, "err unknown\n");
	else {
		sa_line(&in, out);
		if (conns.len)
			buf_printf(out, "%s", conns.s);
		buf_printf(out, "ok\n");
	}
	free(conns.s);
}

static void
do_sa_stop(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	sa_let_go(e, w, now, out, ipsec_sa_stop);
}

static void
do_sa_del(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	sa_let_go(e, w, now, out, ipsec_sa_del);
}

static void
do_sa_flush(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	(void)w;
	buf_printf(out, "ok %u\n",
		   e->ipsec ? ipsec_sa_flush(e->ipsec, now, sa_flushed, flushed_one, out) : 0);
}

static void
do_sa(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	(void)w;
	(void)now;
	if (e->ipsec)
		ipsec_sa_walk(e->ipsec, sa_line, out);
	buf_printf(out, "ok %u\n", e->ipsec ? ipsec_sa_count(e->ipsec) : 0);
}

static void
do_esp(struct engine *e, char **w, uint32_t now, struct buf *out)
{
	(void)w;
	(void)now;
	buf_printf(out, "esp state=%s", e->esp_state);
	if (e->esp)
		buf_printf(out, " device=%s queue_pairs=%u sas=%u max_sas=%u",
			   esp_dev(e->esp)->name, esp_dev(e->esp)->nqp, esp_sa_count(e->esp),
			   e->max_sa);
	buf_printf(out, "\nok\n");
}

static const struct {
	const char *name;
	unsigned words;		/* after the name */
	void (*run)(struct engine *e, char **w, uint32_t now, struct buf *out);
} commands[] = {
	{ "bind", 9, do_bind },
	{ "unbind", 5, do_unbind },
	{ "flush", 0, do_flush },
	{ "flush-port", 1, do_flush_port },
	{ "flush-route", 1, do_flush_route },
	{ "flush-mac", 1, do_flush_mac },
	{ "count", 0, do_count },
	{ "list", 0, do_list },
	{ "stats", 0, do_stats },
	{ "ports", 0, do_ports },
	{ "claim", 0, do_claim },
	{ "claimed", 0, do_claimed },
	{ "active", 1, do_active },
	{ "esp", 0, do_esp },
	{ "sa-add", 13, do_sa_add },
	{ "sa-stop", 2, do_sa_stop },
	{ "sa-del", 2, do_sa_del },
	{ "sa-flush", 0, do_sa_flush },
	{ "sa", 0, do_sa },
};

void
ctl_request(struct engine *e, int session, char *line, struct buf *out)
{
	char *w[16] = { NULL }, *save = NULL, *t;
	unsigned n = 0, i;

	for (t = strtok_r(line, " \t\r\n", &save); t; t = strtok_r(NULL, " \t\r\n", &save))
		if (n < RTE_DIM(w))
			w[n++] = t;
		else
			n = RTE_DIM(w) + 1;	/* too many: no command takes that many */
	for (i = 0; n && i < RTE_DIM(commands); i++)
		if (!strcmp(w[0], commands[i].name)) {
			if (n - 1 == commands[i].words) {
				e->session = session;
				commands[i].run(e, w + 1, engine_now(e), out);
			}
			else
				buf_printf(out, "err usage\n");
			return;
		}
	buf_printf(out, n ? "err unknown-command\n" : "err usage\n");
}
