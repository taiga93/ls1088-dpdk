/*
 * bmchwaccel-syncd: hands the established connections of conntrack to
 * bmchwaccel-engine and takes them back (spec: Daemon đồng bộ; Q7).
 *
 *   bmchwaccel-syncd [--socket PATH] [--keepalive SECONDS] [--tunnels N]
 *                    [--kept FILE] [--pppoe FILE] [--verbose]
 *
 * --socket     the control socket of the engine (/var/run/bmchwaccel-engine.sock)
 * --keepalive  how often conntrack is told that the connections the engine
 *              still forwards are alive (10)
 * --tunnels    the most tunnels of Tunnel IPsec handed over (4096); smaller for tests
 * --kept       what other features keep on the CPU (/var/run/bmcHwAccel/on_cpu, of
 *              bmcHwAccel): an SA of Tunnel IPsec whose WAN is kept stays with the kernel
 * --pppoe      the PPPoE sessions of the kernel (/proc/net/pppoe); another file for tests
 * --verbose    a line for each connection handed over or taken back, and for
 *              each SA of Tunnel IPsec handed over, taken back or kept on the
 *              kernel
 *
 * It reads the events of conntrack over ctnetlink and decides with sync.c.
 * On connect it claims the engine: the engine lets go of every connection
 * when this session closes, so a daemon that stops or dies never leaves a
 * connection in the engine that nobody takes back. Then it empties the
 * engine, dumps conntrack and hands over what is open. Its log names the
 * engine as the feature it is (Tăng tốc phần cứng), as the spec wants. An engine that goes away is waited for and
 * claimed again, with a new dump. Events lost by the kernel (ENOBUFS) cost
 * the same: the engine is emptied and everything handed over anew.
 *
 * What the engine forwards conntrack never sees: every KEEPALIVE seconds the
 * daemon asks the engine which connections forwarded a packet since the last
 * time, and gives each the timeout of its kind in conntrack, counted from
 * its last packet. A connection that goes quiet then ends in conntrack as it
 * would without the engine, and its destroy event takes it back. A TCP
 * connection handed over gets the flag BE_LIBERAL in conntrack: the kernel
 * did not see its window move meanwhile, and its FIN or RST must not be
 * INVALID when it reaches the kernel.
 *
 * The engine sends a connection the way the kernel sent it when it was
 * handed over. The daemon reads the routes, rules, nexthop objects,
 * addresses, interfaces and neighbours of the kernel over rtnetlink and decides with watch.c: when a
 * route, a rule or a neighbour changes, or an interface goes down, the
 * engine lets go of the connections that went that way (flush-route,
 * flush-mac, flush-port, or flush when what changed cannot be told). Their
 * next packets go through the kernel, which sends them the new way, and the
 * daemon hands them over again, as new connections, once the engine learned
 * that way; the connections that wait for their bind are tried again soon
 * too.
 *
 * Ends on SIGTERM or SIGINT.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <libnetfilter_conntrack/libnetfilter_conntrack.h>
#include <libnfnetlink/libnfnetlink.h>
#include <linux/neighbour.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/xfrm.h>
#include <net/if.h>

#include "ctl.h"
#include "sa.h"
#include "sync.h"
#include "watch.h"

#define IP_CT_TCP_FLAG_BE_LIBERAL 0x08
#define TICK_MS 1000		/* how often due binds are tried */
#define RECONNECT_MS 1000	/* how often an engine that is gone is tried */
#define ANSWER_MS 5000		/* longest wait for an answer of the engine */
#define EVENT_BUFFER (8 << 20)	/* receive buffer of the events */
#define SA_COUNT_TICKS 5	/* the engine's counters into the kernel's SAs every so many ticks */
#define LOCALS_MAX 256		/* addresses of the router */
#define ROUTING_BUFFER (1 << 20)	/* receive buffer of the routing events */
#define WAY_MAX 8		/* devices on the way to a peer: PPPoE, VLAN, port... */
#define TEXT_MAX (64 << 10)	/* of a file read whole (on_cpu, /proc/net/pppoe) */

/* the most attributes of a link, neighbour or route message */
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define ATTRS_MAX MAX(MAX(IFLA_MAX, NDA_MAX), RTA_MAX)

#ifndef IFF_LOWER_UP
#define IFF_LOWER_UP 0x10000	/* linux/if.h, which clashes with net/if.h */
#endif

static volatile sig_atomic_t quit;

static struct {
	const char *socket;
	unsigned keepalive;
	int verbose;
	const char *kept, *pppoe;
} o = { CTL_SOCKET, 10, 0, "/var/run/bmcHwAccel/on_cpu", "/proc/net/pppoe" };

static struct sync *known;	/* what sync.c knows of the connections */
static struct sas *held;	/* the SAs of the kernel the engine holds (sa.c) */
static int xfrm_events = -1;	/* of the SAs: new, updated, deleted, flushed, expired */
static unsigned max_tunnels = SA_MAX_TUNNELS;
static unsigned sa_ticks;
/* the routing changed: an SA that stayed with the kernel may go now (sa_dump() at the next tick) */
static int sa_again;
/* the names of the engine's ports (engine_ports()) */
static char port_name[WATCH_PORTS_MAX][WATCH_NAME_MAX];
static unsigned nport_names;
/* the addresses of the router, read again after one changed */
static uint32_t locals[LOCALS_MAX];
static unsigned nlocals;
static int locals_dirty = 1;
static struct watch *watched;	/* what watch.c knows of the routing */
static int routing = -1;	/* the rtnetlink socket of the routing events */
/* a change of the routing that needs every connection let go of: what it was, or "" */
static char flush_why[64];
static struct nfct_handle *events, *dumps, *queries;
/* the session with the engine; -1 while there is none */
static int engine = -1;
static uint32_t reconnect_at, keepalive_at, last_keepalive;
/* what the engine sent beyond the answer being read */
static char rbuf[CTL_LINE_MAX * 8];
static size_t rlen;

static void
say(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	putchar('\n');
	fflush(stdout);
}

static void
die(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	fprintf(stderr, "bmchwaccel-syncd: ");
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

static uint32_t
now_ms(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint32_t)((uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000);
}

static void
on_signal(int sig)
{
	(void)sig;
	quit = 1;
}

static const char *
proto_name(uint8_t proto)
{
	return proto == IPPROTO_TCP ? "tcp" : "udp";
}

/* " SIP SPORT DIP DPORT" */
static int
tuple_text(char *s, size_t n, const struct sync_tuple *t)
{
	char a[INET_ADDRSTRLEN], b[INET_ADDRSTRLEN];

	inet_ntop(AF_INET, &t->sip, a, sizeof(a));
	inet_ntop(AF_INET, &t->dip, b, sizeof(b));
	return snprintf(s, n, " %s %u %s %u", a, ntohs(t->sport), b, ntohs(t->dport));
}

/* The engine. */

static void handover(void);
static void engine_ports(void);
static void sa_dump(void);

static void
engine_close(void)
{
	if (engine < 0)
		return;
	close(engine);
	engine = -1;
	rlen = 0;
	sync_reset(known);
	sas_reset(held);
	reconnect_at = now_ms() + RECONNECT_MS;
}

/* The engine went away: what it held is gone with it. */
static void
engine_lost(const char *why)
{
	say("lost Tăng tốc phần cứng (%s): every connection goes through the kernel until it is back", why);
	engine_close();
}

/* The next line from the engine, without its newline, into line; -1 on EOF, error or timeout. */
static int
engine_line(char *line, size_t n)
{
	uint32_t start = now_ms();

	for (;;) {
		char *nl = memchr(rbuf, '\n', rlen);
		struct pollfd pf = { .fd = engine, .events = POLLIN };
		ssize_t k;
		int left;

		if (nl) {
			size_t len = (size_t)(nl - rbuf);

			if (len >= n)
				len = n - 1;
			memcpy(line, rbuf, len);
			line[len] = '\0';
			rlen -= (size_t)(nl + 1 - rbuf);
			memmove(rbuf, nl + 1, rlen);
			return 0;
		}
		if (rlen == sizeof(rbuf))
			return -1;	/* no line is that long */
		left = (int)ANSWER_MS - (int)(now_ms() - start);
		if (left <= 0 || poll(&pf, 1, left) <= 0)
			return -1;
		k = recv(engine, rbuf + rlen, sizeof(rbuf) - rlen, 0);
		if (k < 0 && errno == EINTR)
			continue;
		if (k <= 0)
			return -1;
		rlen += (size_t)k;
	}
}

/*
 * One request; the data lines of the reply, each with its newline, go to
 * *data (malloc'd, when data is not NULL), the last line to answer. 0, or -1
 * when the engine is lost.
 */
static int
engine_ask(char *answer, size_t n, char **data, const char *fmt, ...)
{
	char req[CTL_LINE_MAX], line[CTL_LINE_MAX];
	size_t len = 0, size = 0;
	va_list ap;
	int k;

	if (data)
		*data = NULL;
	if (engine < 0)
		return -1;
	va_start(ap, fmt);
	k = vsnprintf(req, sizeof(req) - 1, fmt, ap);
	va_end(ap);
	if (k < 0 || (size_t)k >= sizeof(req) - 1)
		return -1;
	req[k++] = '\n';
	if (send(engine, req, (size_t)k, MSG_NOSIGNAL) != k) {
		engine_lost("it does not take requests");
		return -1;
	}
	for (;;) {
		if (engine_line(line, sizeof(line))) {
			free(data ? *data : NULL);
			if (data)
				*data = NULL;
			engine_lost("it does not answer");
			return -1;
		}
		if (!strncmp(line, "ok", 2) || !strncmp(line, "err", 3))
			break;
		if (!data)
			continue;
		k = (int)strlen(line);
		if (len + (size_t)k + 2 > size) {
			size = (len + (size_t)k + 2) * 2;
			*data = realloc(*data, size);
			if (!*data)
				die("no memory");
		}
		memcpy(*data + len, line, (size_t)k);
		len += (size_t)k;
		(*data)[len++] = '\n';
		(*data)[len] = '\0';
	}
	snprintf(answer, n, "%s", line);
	return 0;
}

/* The names of the engine's ports, for watch.c. */
static void
engine_ports(void)
{
	char line[CTL_LINE_MAX], *data, *l, *save = NULL;
	char names[WATCH_PORTS_MAX][WATCH_NAME_MAX];
	const char *name[WATCH_PORTS_MAX];
	unsigned n = 0;

	if (engine_ask(line, sizeof(line), &data, "ports"))
		return;
	for (l = data ? strtok_r(data, "\n", &save) : NULL; l && n < WATCH_PORTS_MAX;
	     l = strtok_r(NULL, "\n", &save))
		if (sscanf(l, "port %15s", names[n]) == 1) {
			name[n] = names[n];
			snprintf(port_name[n], sizeof(port_name[n]), "%s", names[n]);
			n++;
		}
	free(data);
	nport_names = n;
	watch_ports(watched, name, n);
}

/* Connects and claims the engine, then hands over what is open. */
static void
engine_connect(void)
{
	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	char line[CTL_LINE_MAX], hello[64];
	static int said;

	reconnect_at = now_ms() + RECONNECT_MS;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", o.socket);
	engine = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (engine < 0)
		die("socket: %s", strerror(errno));
	if (connect(engine, (struct sockaddr *)&sa, sizeof(sa))) {
		/* said once while it stays away */
		if (!said)
			say("waiting for Tăng tốc phần cứng on %s", o.socket);
		said = 1;
		close(engine);
		engine = -1;
		return;
	}
	snprintf(hello, sizeof(hello), CTL_GREETING, ENGINE_PROTOCOL);
	if (engine_line(line, sizeof(line)) || strcmp(line, hello)) {
		say("Tăng tốc phần cứng on %s does not speak version %d", o.socket, ENGINE_PROTOCOL);
		engine_close();
		return;
	}
	if (engine_ask(line, sizeof(line), NULL, "claim"))
		return;
	if (strcmp(line, "ok")) {
		say("Tăng tốc phần cứng refused this daemon: %s", line);
		engine_close();
		return;
	}
	/* in step with conntrack from nothing, whatever another session bound */
	if (engine_ask(line, sizeof(line), NULL, "flush"))
		return;
	said = 0;
	sync_reset(known);
	engine_ports();
	/* nor an SA another session handed over */
	if (engine < 0 || engine_ask(line, sizeof(line), NULL, "sa-flush"))
		return;
	sas_reset(held);
	/* a change of the routing before the flush is behind us */
	*flush_why = '\0';
	last_keepalive = now_ms();
	keepalive_at = last_keepalive + o.keepalive * 1000;
	/* the tunnels first: a connection through one needs its keys (ticket 16) */
	sa_dump();
	if (engine >= 0 && sas_count(held))
		say("claimed Tăng tốc phần cứng: %u keys of Tunnel IPsec, %u tunnels, accelerated",
		    sas_count(held), sas_tunnels(held));
	if (engine >= 0)
		handover();
}

/* conntrack. */

static struct nf_conntrack *
ct_tuple(uint8_t proto, const struct sync_tuple *orig)
{
	struct nf_conntrack *c = nfct_new();

	if (!c)
		die("no memory");
	nfct_set_attr_u8(c, ATTR_ORIG_L3PROTO, AF_INET);
	nfct_set_attr_u32(c, ATTR_ORIG_IPV4_SRC, orig->sip);
	nfct_set_attr_u32(c, ATTR_ORIG_IPV4_DST, orig->dip);
	nfct_set_attr_u8(c, ATTR_ORIG_L4PROTO, proto);
	nfct_set_attr_u16(c, ATTR_ORIG_PORT_SRC, orig->sport);
	nfct_set_attr_u16(c, ATTR_ORIG_PORT_DST, orig->dport);
	return c;
}

/* A change to a connection of conntrack: 0, or -1 with errno (ENOENT: it is gone). */
static int
ct_update(struct nf_conntrack *c)
{
	int r = nfct_query(queries, NFCT_Q_UPDATE, c);

	nfct_destroy(c);
	return r;
}

static void
ct_of(const struct nf_conntrack *c, struct sync_ct *ct)
{
	memset(ct, 0, sizeof(*ct));
	ct->ipv4 = nfct_get_attr_u8(c, ATTR_ORIG_L3PROTO) == AF_INET;
	ct->proto = nfct_get_attr_u8(c, ATTR_ORIG_L4PROTO);
	ct->tcp_state = SYNC_TCP_UNKNOWN;
	if (!ct->ipv4)
		return;
	ct->orig.sip = nfct_get_attr_u32(c, ATTR_ORIG_IPV4_SRC);
	ct->orig.dip = nfct_get_attr_u32(c, ATTR_ORIG_IPV4_DST);
	ct->reply.sip = nfct_get_attr_u32(c, ATTR_REPL_IPV4_SRC);
	ct->reply.dip = nfct_get_attr_u32(c, ATTR_REPL_IPV4_DST);
	if (ct->proto == IPPROTO_TCP || ct->proto == IPPROTO_UDP) {
		ct->orig.sport = nfct_get_attr_u16(c, ATTR_ORIG_PORT_SRC);
		ct->orig.dport = nfct_get_attr_u16(c, ATTR_ORIG_PORT_DST);
		ct->reply.sport = nfct_get_attr_u16(c, ATTR_REPL_PORT_SRC);
		ct->reply.dport = nfct_get_attr_u16(c, ATTR_REPL_PORT_DST);
	}
	if (nfct_attr_is_set(c, ATTR_STATUS) > 0)
		ct->status = nfct_get_attr_u32(c, ATTR_STATUS);
	/* the kernel leaves the mark out of an event only while it is 0 */
	if (nfct_attr_is_set(c, ATTR_MARK) > 0)
		ct->mark = nfct_get_attr_u32(c, ATTR_MARK);
	if (ct->proto == IPPROTO_TCP && nfct_attr_is_set(c, ATTR_TCP_STATE) > 0)
		ct->tcp_state = nfct_get_attr_u8(c, ATTR_TCP_STATE);
	/* a helper, or a connection a helper expected (FTP data, SIP media) */
	ct->helper = nfct_attr_is_set(c, ATTR_HELPER_NAME) > 0 ||
		     nfct_attr_is_set(c, ATTR_MASTER_L3PROTO) > 0;
}

/* Hands the connection to the engine, and tells sync.c what came of it. */
static void
bind_one(uint8_t proto, const struct sync_tuple *orig, const struct sync_tuple *reply)
{
	char o_s[64], r_s[64], line[CTL_LINE_MAX];
	enum sync_result r;

	tuple_text(o_s, sizeof(o_s), orig);
	tuple_text(r_s, sizeof(r_s), reply);
	if (engine_ask(line, sizeof(line), NULL, "bind %s%s%s", proto_name(proto), o_s, r_s))
		return;
	if (!strcmp(line, "ok"))
		r = SYNC_OK;
	else if (!strcmp(line, "err exists"))
		r = SYNC_EXISTS;
	else if (!strncmp(line, "err unlearned", 13))
		r = SYNC_UNLEARNED;
	else if (!strcmp(line, "err full"))
		r = SYNC_NOSPACE;
	else
		r = SYNC_REFUSED;
	if (r == SYNC_REFUSED || (o.verbose && r != SYNC_UNLEARNED))
		say("bind %s%s%s: %s", proto_name(proto), o_s, r_s, line);
	sync_bound(known, proto, orig, r, now_ms());
	if ((r == SYNC_OK || r == SYNC_EXISTS) && proto == IPPROTO_TCP) {
		struct nf_conntrack *c = ct_tuple(proto, orig);

		nfct_set_attr_u8(c, ATTR_TCP_FLAGS_ORIG, IP_CT_TCP_FLAG_BE_LIBERAL);
		nfct_set_attr_u8(c, ATTR_TCP_MASK_ORIG, IP_CT_TCP_FLAG_BE_LIBERAL);
		nfct_set_attr_u8(c, ATTR_TCP_FLAGS_REPL, IP_CT_TCP_FLAG_BE_LIBERAL);
		nfct_set_attr_u8(c, ATTR_TCP_MASK_REPL, IP_CT_TCP_FLAG_BE_LIBERAL);
		/* gone meanwhile: its destroy event follows */
		ct_update(c);
	}
}

static void
unbind_one(uint8_t proto, const struct sync_tuple *orig)
{
	char o_s[64], line[CTL_LINE_MAX];

	tuple_text(o_s, sizeof(o_s), orig);
	if (engine_ask(line, sizeof(line), NULL, "unbind %s%s", proto_name(proto), o_s))
		return;
	if (o.verbose)
		say("unbind %s%s: %s", proto_name(proto), o_s, line);
}

static struct nf_conntrack *answered;

static int
on_answer(enum nf_conntrack_msg_type type, struct nf_conntrack *c, void *arg)
{
	(void)type;
	(void)arg;
	if (!answered)
		answered = nfct_clone(c);
	return NFCT_CB_CONTINUE;
}

static void handle(enum sync_msg msg, const struct sync_ct *ct);

/* Asks conntrack for everything about the connection, and decides again. */
static void
query(const struct sync_ct *ct)
{
	struct nf_conntrack *c = ct_tuple(ct->proto, &ct->orig);
	struct sync_ct full;

	answered = NULL;
	/* gone meanwhile: its destroy event follows */
	if (nfct_query(queries, NFCT_Q_GET, c) == 0 && answered) {
		ct_of(answered, &full);
		handle(SYNC_FULL, &full);
	}
	nfct_destroy(c);
	if (answered)
		nfct_destroy(answered);
	answered = NULL;
}

static void
handle(enum sync_msg msg, const struct sync_ct *ct)
{
	switch (sync_ct(known, msg, ct, now_ms())) {
	case SYNC_BIND:
		bind_one(ct->proto, &ct->orig, &ct->reply);
		break;
	case SYNC_UNBIND:
		unbind_one(ct->proto, &ct->orig);
		break;
	case SYNC_QUERY:
		query(ct);
		break;
	case SYNC_NOTHING:
		break;
	}
}

static int
on_event(enum nf_conntrack_msg_type type, struct nf_conntrack *c, void *arg)
{
	struct sync_ct ct;

	(void)arg;
	/* nothing to keep in step with while there is no engine: a dump follows */
	if (engine < 0)
		return NFCT_CB_CONTINUE;
	ct_of(c, &ct);
	handle(type == NFCT_T_NEW ? SYNC_NEW : type == NFCT_T_DESTROY ? SYNC_DESTROY : SYNC_UPDATE, &ct);
	return NFCT_CB_CONTINUE;
}

static int
on_dump(enum nf_conntrack_msg_type type, struct nf_conntrack *c, void *arg)
{
	struct sync_ct ct;

	(void)type;
	(void)arg;
	if (engine < 0)
		return NFCT_CB_STOP;
	ct_of(c, &ct);
	handle(SYNC_FULL, &ct);
	return NFCT_CB_CONTINUE;
}

/*
 * Hands over every open connection that may go to the engine. The events
 * are read since before the dump: a connection that ends during it is taken
 * back by its destroy event afterwards.
 */
static void
handover(void)
{
	uint32_t family = AF_INET;
	unsigned bound, waiting;

	if (nfct_query(dumps, NFCT_Q_DUMP, &family) < 0 && engine >= 0)
		say("conntrack could not be read: %s", strerror(errno));
	if (engine < 0)
		return;
	sync_count(known, &bound, &waiting);
	say("claimed Tăng tốc phần cứng: %u connections accelerated, %u waiting for both directions",
	    bound, waiting);
}

/* The kernel lost events: nobody knows what changed, so everything is handed over anew. */
static void
events_lost(void)
{
	char line[CTL_LINE_MAX];

	say("conntrack events were lost: every connection is handed over anew");
	if (engine_ask(line, sizeof(line), NULL, "flush"))
		return;
	sync_reset(known);
	handover();
}

static void
bind_due(const struct sync_conn *c, void *arg)
{
	(void)arg;
	bind_one(c->proto, &c->orig, &c->reply);
}

/* A timeout of the kernel, in seconds, or def. */
static uint32_t
sysctl_seconds(const char *name, uint32_t def)
{
	char path[128];
	unsigned v;
	FILE *f;

	snprintf(path, sizeof(path), "/proc/sys/net/netfilter/%s", name);
	f = fopen(path, "r");
	if (!f)
		return def;
	if (fscanf(f, "%u", &v) != 1 || v == 0)
		v = def;
	fclose(f);
	return v;
}

/*
 * The connections that forwarded a packet since the last keepalive get the
 * timeout of their kind in conntrack, from their last packet. One the engine
 * holds without this daemon knowing it, or that conntrack no longer has, is
 * taken back.
 */
static void
keepalive(void)
{
	uint32_t now = now_ms(), tcp, udp;
	char line[CTL_LINE_MAX], *data, *l, *save = NULL;

	tcp = sysctl_seconds("nf_conntrack_tcp_timeout_established", 7440);
	udp = sysctl_seconds("nf_conntrack_udp_timeout_stream", 180);
	/* a second more: no packet falls between two keepalives */
	if (engine_ask(line, sizeof(line), &data, "active %u", now - last_keepalive + 1000))
		return;
	last_keepalive = now;
	for (l = data ? strtok_r(data, "\n", &save) : NULL; l; l = strtok_r(NULL, "\n", &save)) {
		char proto[4], sip[INET_ADDRSTRLEN], dip[INET_ADDRSTRLEN];
		unsigned sport, dport, idle;
		struct sync_tuple t;
		struct nf_conntrack *c;
		uint8_t p;

		if (sscanf(l, "conn %3s %15s %u %15s %u idle=%u", proto, sip, &sport, dip, &dport,
			   &idle) != 6 || (strcmp(proto, "tcp") && strcmp(proto, "udp")) ||
		    inet_pton(AF_INET, sip, &t.sip) != 1 || inet_pton(AF_INET, dip, &t.dip) != 1 ||
		    sport > 65535 || dport > 65535)
			continue;
		t.sport = htons((uint16_t)sport);
		t.dport = htons((uint16_t)dport);
		p = !strcmp(proto, "tcp") ? IPPROTO_TCP : IPPROTO_UDP;
		if (!sync_is_bound(known, p, &t)) {
			unbind_one(p, &t);
			continue;
		}
		c = ct_tuple(p, &t);
		nfct_set_attr_u32(c, ATTR_TIMEOUT, sync_timeout(p == IPPROTO_TCP ? tcp : udp, idle));
		if (ct_update(c) && errno == ENOENT) {
			sync_forget(known, p, &t);
			unbind_one(p, &t);
		}
		if (engine < 0)
			break;
	}
	free(data);
}

/* The routing of the kernel. */

/*
 * The connections the engine said it let go of, a line "conn tcp|udp OSIP
 * OSPORT ODIP ODPORT" each among the lines of data (cut up): they wait to
 * be handed over again. How many.
 */
static unsigned
conns_let_go(char *data)
{
	char *l, *save = NULL;
	unsigned n = 0;

	for (l = data ? strtok_r(data, "\n", &save) : NULL; l; l = strtok_r(NULL, "\n", &save)) {
		char proto[4], sip[INET_ADDRSTRLEN], dip[INET_ADDRSTRLEN];
		unsigned sport, dport;
		struct sync_tuple t;

		if (sscanf(l, "conn %3s %15s %u %15s %u", proto, sip, &sport, dip, &dport) != 5 ||
		    (strcmp(proto, "tcp") && strcmp(proto, "udp")) ||
		    inet_pton(AF_INET, sip, &t.sip) != 1 || inet_pton(AF_INET, dip, &t.dip) != 1 ||
		    sport > 65535 || dport > 65535)
			continue;
		t.sport = htons((uint16_t)sport);
		t.dport = htons((uint16_t)dport);
		sync_unbound(known, !strcmp(proto, "tcp") ? IPPROTO_TCP : IPPROTO_UDP, &t, now_ms());
		n++;
	}
	return n;
}

/*
 * Has the engine let go of the connections a flush command names, and hands
 * them over again later; why says what changed, for the log.
 */
static void
flush_some(const char *why, const char *fmt, ...)
{
	char req[CTL_LINE_MAX], line[CTL_LINE_MAX], *data;
	unsigned n;
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(req, sizeof(req), fmt, ap);
	va_end(ap);
	if (engine_ask(line, sizeof(line), &data, "%s", req))
		return;
	n = conns_let_go(data);
	free(data);
	if (strncmp(line, "ok", 2))
		say("%s: %s", req, line);
	else if (n || o.verbose)
		say("%s: %u connections go through the kernel until they are accelerated again", why, n);
}

/* What watch.c answered. Every connection is let go of once all events read are seen to. */
static void
let_go(const struct watch_act *a, const char *why)
{
	char what[64], ip[INET_ADDRSTRLEN], mac[18];

	if (engine < 0 || a->what == WATCH_NOTHING)
		return;
	/* what could not be learned the old way may be learned the new one */
	sync_retry_soon(known, now_ms());
	/* and an SA whose peer had no way through the engine may have one */
	sa_again = 1;
	switch (a->what) {
	case WATCH_NOTHING:
		break;
	case WATCH_FLUSH:
		if (!*flush_why && *a->port)
			snprintf(flush_why, sizeof(flush_why), "%s went down", a->port);
		else if (!*flush_why)
			snprintf(flush_why, sizeof(flush_why), "%s", why);
		break;
	case WATCH_FLUSH_PORT:
		snprintf(what, sizeof(what), "%s went down", a->port);
		flush_some(what, "flush-port %s", a->port);
		break;
	case WATCH_FLUSH_ROUTE:
		inet_ntop(AF_INET, &a->dst, ip, sizeof(ip));
		snprintf(what, sizeof(what), "the route to %s/%u changed", ip, a->len);
		flush_some(what, "flush-route %s/%u", ip, a->len);
		break;
	case WATCH_FLUSH_MAC:
		snprintf(mac, sizeof(mac), "%02x:%02x:%02x:%02x:%02x:%02x", a->mac[0], a->mac[1],
			 a->mac[2], a->mac[3], a->mac[4], a->mac[5]);
		snprintf(what, sizeof(what), "a neighbour left %s", mac);
		flush_some(what, "flush-mac %s", mac);
		break;
	}
}

/* The engine lets go of every connection, after a change of the routing that cannot be told apart. */
static void
flush_all(void)
{
	char line[CTL_LINE_MAX];
	unsigned bound, waiting;

	if (!*flush_why || engine < 0)
		return;
	sync_count(known, &bound, &waiting);
	if (engine_ask(line, sizeof(line), NULL, "flush"))
		return;
	sync_unbound_all(known, now_ms());
	say("%s: every connection goes through the kernel until it is accelerated again (%u were)",
	    flush_why, bound);
	*flush_why = '\0';
}

/* The attributes of a routing message after its fixed part of len bytes. */
static void
rt_attrs(const struct nlmsghdr *h, size_t len, const struct rtattr **tb, unsigned max)
{
	const struct rtattr *rta = (const struct rtattr *)((const char *)NLMSG_DATA(h) + NLMSG_ALIGN(len));
	int left = (int)h->nlmsg_len - (int)NLMSG_LENGTH(NLMSG_ALIGN(len));

	memset(tb, 0, max * sizeof(*tb));
	for (; RTA_OK(rta, left); rta = RTA_NEXT(rta, left))
		if (rta->rta_type < max)
			tb[rta->rta_type] = rta;
}

/* One routing message: what changed, told to watch.c, and what it answers done. */
static void
on_routing(const struct nlmsghdr *h)
{
	const struct rtattr *tb[ATTRS_MAX + 1];
	struct watch_act a = { WATCH_NOTHING, "", 0, 0, { 0 } };

	switch (h->nlmsg_type) {
	case RTM_NEWLINK:
	case RTM_DELLINK: {
		const struct ifinfomsg *ifi = NLMSG_DATA(h);
		char name[IFNAMSIZ] = "";

		/* a bridge says the same of its ports with AF_BRIDGE */
		if (h->nlmsg_len < NLMSG_LENGTH(sizeof(*ifi)) || ifi->ifi_family != AF_UNSPEC)
			return;
		rt_attrs(h, sizeof(*ifi), tb, IFLA_MAX + 1);
		if (tb[IFLA_IFNAME])
			snprintf(name, sizeof(name), "%.*s", (int)RTA_PAYLOAD(tb[IFLA_IFNAME]),
				 (const char *)RTA_DATA(tb[IFLA_IFNAME]));
		watch_link(watched, ifi->ifi_index, name,
			   (ifi->ifi_flags & IFF_UP) && (ifi->ifi_flags & IFF_LOWER_UP),
			   tb[IFLA_MASTER] != NULL, h->nlmsg_type == RTM_DELLINK, &a);
		let_go(&a, "an interface went away");
		break;
	}
	case RTM_NEWNEIGH:
	case RTM_DELNEIGH: {
		const struct ndmsg *nd = NLMSG_DATA(h);
		const uint8_t *mac = NULL;
		uint32_t ip;

		if (h->nlmsg_len < NLMSG_LENGTH(sizeof(*nd)) || nd->ndm_family != AF_INET)
			return;
		rt_attrs(h, sizeof(*nd), tb, NDA_MAX + 1);
		if (!tb[NDA_DST] || RTA_PAYLOAD(tb[NDA_DST]) != 4)
			return;
		memcpy(&ip, RTA_DATA(tb[NDA_DST]), 4);
		if (h->nlmsg_type == RTM_NEWNEIGH && tb[NDA_LLADDR] && RTA_PAYLOAD(tb[NDA_LLADDR]) == 6 &&
		    !(nd->ndm_state & (NUD_INCOMPLETE | NUD_FAILED)))
			mac = RTA_DATA(tb[NDA_LLADDR]);
		watch_neigh(watched, nd->ndm_ifindex, ip, mac, &a);
		let_go(&a, "a neighbour changed");
		break;
	}
	case RTM_NEWROUTE:
	case RTM_DELROUTE: {
		const struct rtmsg *rt = NLMSG_DATA(h);
		uint32_t dst = 0;

		if (h->nlmsg_len < NLMSG_LENGTH(sizeof(*rt)) || rt->rtm_family != AF_INET)
			return;
		rt_attrs(h, sizeof(*rt), tb, RTA_MAX + 1);
		if (tb[RTA_DST] && RTA_PAYLOAD(tb[RTA_DST]) == 4)
			memcpy(&dst, RTA_DATA(tb[RTA_DST]), 4);
		watch_route(watched, dst, rt->rtm_dst_len, (rt->rtm_flags & RTM_F_CLONED) != 0, &a);
		let_go(&a, "the default route changed");
		break;
	}
	case RTM_NEWRULE:
	case RTM_DELRULE: {
		const struct rtmsg *rt = NLMSG_DATA(h);	/* the family where struct fib_rule_hdr has it */

		if (h->nlmsg_len < NLMSG_LENGTH(sizeof(*rt)) || rt->rtm_family != AF_INET)
			return;
		watch_rule(watched, &a);
		let_go(&a, "a routing rule changed");
		break;
	}
	case RTM_NEWNEXTHOP:
	case RTM_DELNEXTHOP:
		watch_nexthop(watched, &a);
		let_go(&a, "a nexthop changed");
		break;
	case RTM_NEWADDR:
		/* the SAs of an address are the router's */
		locals_dirty = 1;
		sa_again = 1;
		break;
	case RTM_DELADDR: {
		const struct ifaddrmsg *ifa = NLMSG_DATA(h);

		if (h->nlmsg_len < NLMSG_LENGTH(sizeof(*ifa)) || ifa->ifa_family != AF_INET)
			return;
		locals_dirty = 1;
		watch_addr_gone(watched, &a);
		let_go(&a, "an address went away");
		break;
	}
	}
}

/*
 * The messages waiting on fd, each to on_routing(); until a dump is done
 * when dump is set. 0, or -1 with errno (EAGAIN: none left; ENOBUFS: the
 * kernel lost some).
 */
static int
routing_read(int fd, int dump)
{
	static char buf[64 << 10] __attribute__((aligned(NLMSG_ALIGNTO)));

	for (;;) {
		ssize_t n = recv(fd, buf, sizeof(buf), 0);
		const struct nlmsghdr *h;
		int left;

		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return -1;
		left = (int)n;
		for (h = (const struct nlmsghdr *)buf; NLMSG_OK(h, left); h = NLMSG_NEXT(h, left)) {
			if (h->nlmsg_type == NLMSG_DONE)
				return 0;
			if (h->nlmsg_type == NLMSG_ERROR) {
				if (dump)
					return 0;
				continue;
			}
			on_routing(h);
		}
	}
}

/* What the kernel has now of type (RTM_GETLINK, RTM_GETNEIGH): watch.c learns it. */
static void
routing_dump(int type)
{
	struct {
		struct nlmsghdr h;
		struct rtgenmsg g;
	} req = {
		.h = { .nlmsg_len = NLMSG_LENGTH(sizeof(struct rtgenmsg)), .nlmsg_type = (uint16_t)type,
		       .nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP, .nlmsg_seq = 1 },
		.g = { .rtgen_family = type == RTM_GETNEIGH ? AF_INET : AF_UNSPEC },
	};
	int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);

	if (fd < 0)
		die("rtnetlink: %s", strerror(errno));
	if (send(fd, &req, req.h.nlmsg_len, 0) < 0 || routing_read(fd, 1) < 0)
		say("the routing of the kernel could not be read: %s", strerror(errno));
	close(fd);
}

/* The events of the routing, then what the kernel has now: watch.c knows it from then on. */
static void
routing_open(void)
{
	struct sockaddr_nl sa = {
		.nl_family = AF_NETLINK,
		.nl_groups = RTMGRP_LINK | RTMGRP_NEIGH | RTMGRP_IPV4_IFADDR | RTMGRP_IPV4_ROUTE |
			     RTMGRP_IPV4_RULE,
	};
	int size = ROUTING_BUFFER;

	routing = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC | SOCK_NONBLOCK, NETLINK_ROUTE);
	if (routing < 0 || bind(routing, (struct sockaddr *)&sa, sizeof(sa)))
		die("rtnetlink: %s", strerror(errno));
	if (setsockopt(routing, SOL_SOCKET, SO_RCVBUFFORCE, &size, sizeof(size)))
		setsockopt(routing, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
	/* past the 32 groups of nl_groups */
	if (setsockopt(routing, SOL_NETLINK, NETLINK_ADD_MEMBERSHIP, &(int){ RTNLGRP_NEXTHOP },
		       sizeof(int)))
		say("nexthop objects cannot be followed: %s", strerror(errno));
	routing_dump(RTM_GETLINK);
	routing_dump(RTM_GETNEIGH);
}

/* The routing events waiting. Lost ones: every connection is let go of, and the routing read anew. */
static void
routing_events(void)
{
	if (routing_read(routing, 0) < 0 && errno == ENOBUFS) {
		say("routing events were lost");
		if (engine >= 0 && !*flush_why)
			snprintf(flush_why, sizeof(flush_why), "routing events were lost");
		routing_dump(RTM_GETLINK);
		routing_dump(RTM_GETNEIGH);
	}
	flush_all();
}

/*
 * Tunnel IPsec (spec-ipsec: Daemon đồng bộ; ADR-0014). The kernel keeps its
 * SAs; the engine holds a copy of those sa.c lets it, and numbers the ESP
 * of the outbound ones. Every second the kernel's oseq of each becomes the
 * engine's last number + SA_MARGIN, so that the kernel goes on past every
 * number the engine gave should the engine or this daemon die; every
 * SA_COUNT_TICKS seconds what the engine encrypted and decrypted on its own
 * is added to the counters of the kernel's SAs. An SA let go of in order
 * (deleted from the engine while the kernel keeps it) has its last number
 * written the same way.
 */

static int
local(uint32_t a)
{
	unsigned i;

	if (locals_dirty) {
		struct ifaddrs *all, *ifa;

		nlocals = 0;
		if (!getifaddrs(&all)) {
			for (ifa = all; ifa && nlocals < LOCALS_MAX; ifa = ifa->ifa_next)
				if (ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_INET)
					locals[nlocals++] = ((struct sockaddr_in *)ifa->ifa_addr)->sin_addr.s_addr;
			freeifaddrs(all);
			locals_dirty = 0;
		}
	}
	for (i = 0; i < nlocals; i++)
		if (locals[i] == a)
			return 1;
	return 0;
}

/* The interface the kernel sends to dst from src through, or 0. */
static int
route_oif(uint32_t dst, uint32_t src)
{
	struct {
		struct nlmsghdr h;
		struct rtmsg r;
		char attrs[64];
	} req = {
		.h = { .nlmsg_len = NLMSG_LENGTH(sizeof(struct rtmsg)), .nlmsg_type = RTM_GETROUTE,
		       .nlmsg_flags = NLM_F_REQUEST, .nlmsg_seq = 1 },
		.r = { .rtm_family = AF_INET, .rtm_dst_len = 32, .rtm_src_len = 32 },
	};
	static char buf[4096] __attribute__((aligned(NLMSG_ALIGNTO)));
	const struct rtattr *tb[RTA_MAX + 1];
	struct rtattr *a;
	int fd, oif = 0;
	ssize_t n;

	a = (struct rtattr *)((char *)&req + NLMSG_ALIGN(req.h.nlmsg_len));
	a->rta_type = RTA_DST;
	a->rta_len = RTA_LENGTH(4);
	memcpy(RTA_DATA(a), &dst, 4);
	req.h.nlmsg_len = NLMSG_ALIGN(req.h.nlmsg_len) + RTA_ALIGN(a->rta_len);
	a = (struct rtattr *)((char *)&req + req.h.nlmsg_len);
	a->rta_type = RTA_SRC;
	a->rta_len = RTA_LENGTH(4);
	memcpy(RTA_DATA(a), &src, 4);
	req.h.nlmsg_len += RTA_ALIGN(a->rta_len);
	fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
	if (fd < 0)
		return 0;
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &(struct timeval){ 1, 0 }, sizeof(struct timeval));
	if (send(fd, &req, req.h.nlmsg_len, 0) > 0 && (n = recv(fd, buf, sizeof(buf), 0)) > 0) {
		const struct nlmsghdr *h = (const struct nlmsghdr *)buf;

		if (NLMSG_OK(h, (unsigned)n) && h->nlmsg_type == RTM_NEWROUTE) {
			rt_attrs(h, sizeof(struct rtmsg), tb, RTA_MAX + 1);
			if (tb[RTA_OIF] && RTA_PAYLOAD(tb[RTA_OIF]) == 4)
				memcpy(&oif, RTA_DATA(tb[RTA_OIF]), 4);
		}
	}
	close(fd);
	return oif;
}

/* A file read whole, NUL-terminated, or NULL; free() it. */
static char *
file_text(const char *path)
{
	FILE *f = fopen(path, "r");
	char *t;
	size_t n;

	if (!f)
		return NULL;
	t = malloc(TEXT_MAX + 1);
	if (!t)
		die("no memory");
	n = fread(t, 1, TEXT_MAX, f);
	fclose(f);
	t[n] = '\0';
	return t;
}

static int
way_has(char devs[][IF_NAMESIZE], unsigned n, const char *name)
{
	unsigned i;

	for (i = 0; i < n; i++)
		if (!strcmp(devs[i], name))
			return 1;
	return 0;
}

static void
way_add(char devs[][IF_NAMESIZE], unsigned *n, const char *name)
{
	if (*n < WAY_MAX && strlen(name) < IF_NAMESIZE && !way_has(devs, *n, name))
		snprintf(devs[(*n)++], IF_NAMESIZE, "%s", name);
}

/*
 * The devices of the way out of name: name, the device under its PPPoE
 * session, and the lower devices of each (a VLAN's: /sys/class/net/X/lower_Y),
 * WAY_MAX at most. How many.
 */
static unsigned
way_devices(const char *name, char devs[][IF_NAMESIZE])
{
	char *pppoe = file_text(o.pppoe), dev[IF_NAMESIZE], path[256];
	unsigned i, n = 0;

	way_add(devs, &n, name);
	for (i = 0; i < n; i++) {
		DIR *d;
		struct dirent *e;

		if (pppoe && !sa_pppoe_device(pppoe, devs[i], dev, sizeof(dev)))
			way_add(devs, &n, dev);
		snprintf(path, sizeof(path), "/sys/class/net/%s", devs[i]);
		if (!(d = opendir(path)))
			continue;
		while ((e = readdir(d)))
			if (!strncmp(e->d_name, "lower_", 6))
				way_add(devs, &n, e->d_name + 6);
		closedir(d);
	}
	free(pppoe);
	return n;
}

/*
 * The kernel's way between the router's address of k and its peer: whether
 * it leaves through a port of the engine (or a VLAN on one, or a PPPoE
 * session over either), and whether a device of it is kept on the CPU.
 */
static void
sa_way(struct sa_kernel *k)
{
	char name[IF_NAMESIZE], devs[WAY_MAX][IF_NAMESIZE], *kept;
	const char *list[WAY_MAX];
	uint32_t peer = k->dir == SA_OUT ? k->daddr : k->saddr;
	uint32_t mine = k->dir == SA_OUT ? k->saddr : k->daddr;
	unsigned i, n;
	int oif;

	k->via_engine = k->kept = 0;
	if (k->dir == SA_NEITHER)
		return;
	oif = route_oif(peer, mine);
	if (!oif || !if_indextoname((unsigned)oif, name))
		return;
	n = way_devices(name, devs);
	for (i = 0; i < n; i++) {
		list[i] = devs[i];
		if (way_has(port_name, nport_names, devs[i]))
			k->via_engine = 1;
	}
	kept = file_text(o.kept);
	k->kept = sa_kept(kept, list, n);
	free(kept);
}

/* "Tunnel IPsec to PEER (key 0xSPI, out)" for the log: never "SA" there (spec). */
static const char *
sa_name(uint32_t spi, uint32_t saddr, uint32_t daddr, enum sa_dir dir)
{
	static char s[96];
	char a[INET_ADDRSTRLEN];

	inet_ntop(AF_INET, dir == SA_IN ? &saddr : &daddr, a, sizeof(a));
	snprintf(s, sizeof(s), "Tunnel IPsec of %s (key 0x%08x, %s)", a, spi,
		 dir == SA_IN ? "in" : "out");
	return s;
}

/* An SA of a message of xfrm (struct xfrm_usersa_info, then its attributes). */
static int
sa_of(const struct nlmsghdr *h, size_t off, struct sa_kernel *k)
{
	const struct xfrm_usersa_info *p = (const void *)((const char *)NLMSG_DATA(h) + off);
	const struct rtattr *tb[XFRMA_MAX + 1], *rta;

	memset(k, 0, sizeof(*k));
	if (h->nlmsg_len < NLMSG_LENGTH(off + sizeof(*p)))
		return -1;
	rt_attrs(h, off + sizeof(*p), tb, XFRMA_MAX + 1);
	/* a selector of any family is one of every packet */
	k->ipv4 = p->family == AF_INET && (p->sel.family == AF_INET || p->sel.family == AF_UNSPEC);
	k->esp = p->id.proto == IPPROTO_ESP;
	k->tunnel = p->mode == XFRM_MODE_TUNNEL;
	k->esn = !!(p->flags & XFRM_STATE_ESN);
	k->spi = ntohl(p->id.spi);
	k->saddr = p->saddr.a4;
	k->daddr = p->id.daddr.a4;
	k->reqid = p->reqid;
	k->replay = p->replay_window;
	k->offload = tb[XFRMA_OFFLOAD_DEV] != NULL;
	k->comp = tb[XFRMA_ALG_COMP] != NULL;
	if ((rta = tb[XFRMA_ALG_CRYPT]) && RTA_PAYLOAD(rta) >= sizeof(struct xfrm_algo)) {
		const struct xfrm_algo *a = RTA_DATA(rta);

		snprintf(k->crypt, sizeof(k->crypt), "%.*s", (int)sizeof(a->alg_name), a->alg_name);
		k->crypt_bits = a->alg_key_len;
		if (a->alg_key_len / 8 > SA_KEY_MAX ||
		    RTA_PAYLOAD(rta) < sizeof(*a) + a->alg_key_len / 8)
			return -1;
		memcpy(k->crypt_key, a->alg_key, a->alg_key_len / 8);
	}
	if ((rta = tb[XFRMA_ALG_AUTH_TRUNC]) && RTA_PAYLOAD(rta) >= sizeof(struct xfrm_algo_auth)) {
		const struct xfrm_algo_auth *a = RTA_DATA(rta);

		snprintf(k->auth, sizeof(k->auth), "%.*s", (int)sizeof(a->alg_name), a->alg_name);
		k->auth_bits = a->alg_key_len;
		k->trunc_bits = a->alg_trunc_len;
		if (a->alg_key_len / 8 > SA_KEY_MAX ||
		    RTA_PAYLOAD(rta) < sizeof(*a) + a->alg_key_len / 8)
			return -1;
		memcpy(k->auth_key, a->alg_key, a->alg_key_len / 8);
	}
	if ((rta = tb[XFRMA_ALG_AEAD]) && RTA_PAYLOAD(rta) >= sizeof(struct xfrm_algo_aead)) {
		const struct xfrm_algo_aead *a = RTA_DATA(rta);

		snprintf(k->aead, sizeof(k->aead), "%.*s", (int)sizeof(a->alg_name), a->alg_name);
		k->aead_bits = a->alg_key_len;
		k->icv_bits = a->alg_icv_len;
		if (a->alg_key_len / 8 > SA_KEY_MAX ||
		    RTA_PAYLOAD(rta) < sizeof(*a) + a->alg_key_len / 8)
			return -1;
		memcpy(k->aead_key, a->alg_key, a->alg_key_len / 8);
	}
	if ((rta = tb[XFRMA_ENCAP]) && RTA_PAYLOAD(rta) >= sizeof(struct xfrm_encap_tmpl)) {
		const struct xfrm_encap_tmpl *e = RTA_DATA(rta);

		k->encap = e->encap_type;
		k->sport = ntohs(e->encap_sport);
		k->dport = ntohs(e->encap_dport);
	}
	if ((rta = tb[XFRMA_REPLAY_ESN_VAL]) &&
	    RTA_PAYLOAD(rta) >= sizeof(struct xfrm_replay_state_esn)) {
		const struct xfrm_replay_state_esn *r = RTA_DATA(rta);

		k->replay = r->replay_window;
		k->oseq = r->oseq;
	} else if ((rta = tb[XFRMA_REPLAY_VAL]) && RTA_PAYLOAD(rta) >= sizeof(struct xfrm_replay_state)) {
		k->oseq = ((const struct xfrm_replay_state *)RTA_DATA(rta))->oseq;
	}
	if (!k->ipv4)
		k->dir = SA_NEITHER;
	else if (local(k->saddr))
		k->dir = SA_OUT;
	else if (local(k->daddr))
		k->dir = SA_IN;
	else
		k->dir = SA_NEITHER;
	/* the way to the peer: sa_way(), only when it is needed */
	return 0;
}

/*
 * A request of xfrm and its answer into buf, on a socket of its own kept
 * open: the length, or -1. The answer is the message of the request's
 * sequence number, of type want or an error; others (late answers) are
 * skipped.
 */
static ssize_t
xfrm_talk(struct nlmsghdr *req, char *buf, size_t size, int want)
{
	static int fd = -1;
	static uint32_t seq;
	ssize_t n = -1;

	if (fd < 0) {
		fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_XFRM);
		if (fd < 0)
			return -1;
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &(struct timeval){ 1, 0 },
			   sizeof(struct timeval));
	}
	req->nlmsg_seq = ++seq;
	if (send(fd, req, req->nlmsg_len, 0) != (ssize_t)req->nlmsg_len)
		return -1;
	for (;;) {
		const struct nlmsghdr *h;

		n = recv(fd, buf, size, 0);
		if (n <= 0)
			return -1;
		h = (const struct nlmsghdr *)buf;
		if (NLMSG_OK(h, (unsigned)n) && h->nlmsg_seq == seq &&
		    (h->nlmsg_type == want || h->nlmsg_type == NLMSG_ERROR))
			return n;
	}
}

/*
 * Into the kernel's SA of the engine's SA h: oseq at least what set_oseq
 * gives (0: unchanged), and bytes, packets added to its counters. Its
 * replay state and lifetime are read first, so that the rest of them
 * stays. 0, or -1 (gone meanwhile, or the kernel refused).
 */
static int
kernel_ae(const struct sa_held *h, uint32_t oseq, uint64_t bytes, uint64_t packets)
{
	/* the replay state of a window of up to 2^14 */
	struct {
		struct nlmsghdr n;
		struct xfrm_aevent_id id;
		char attrs[2304];
	} req;
	static char buf[8192] __attribute__((aligned(NLMSG_ALIGNTO)));
	const struct rtattr *tb[XFRMA_MAX + 1], *rta;
	char replay[2048 + sizeof(struct xfrm_replay_state_esn)];
	unsigned short rtype = 0;
	unsigned rlen = 0;
	struct xfrm_lifetime_cur lt;
	const struct nlmsghdr *a;
	struct rtattr *at;
	ssize_t n;

	if (!oseq && !bytes && !packets)
		return 0;
	memset(&req, 0, sizeof(req));
	req.n.nlmsg_len = NLMSG_LENGTH(sizeof(req.id));
	req.n.nlmsg_type = XFRM_MSG_GETAE;
	req.n.nlmsg_flags = NLM_F_REQUEST;
	req.n.nlmsg_seq = 1;
	req.id.sa_id.daddr.a4 = h->daddr;
	req.id.sa_id.spi = htonl(h->spi);
	req.id.sa_id.family = AF_INET;
	req.id.sa_id.proto = IPPROTO_ESP;
	req.id.saddr.a4 = h->saddr;
	req.id.flags = XFRM_AE_RVAL | XFRM_AE_LVAL;
	req.id.reqid = h->reqid;
	n = xfrm_talk(&req.n, buf, sizeof(buf), XFRM_MSG_NEWAE);
	a = (const struct nlmsghdr *)buf;
	if (n <= 0 || !NLMSG_OK(a, (unsigned)n) || a->nlmsg_type != XFRM_MSG_NEWAE)
		return -1;
	rt_attrs(a, sizeof(req.id), tb, XFRMA_MAX + 1);
	rta = tb[XFRMA_REPLAY_ESN_VAL] ? tb[XFRMA_REPLAY_ESN_VAL] : tb[XFRMA_REPLAY_VAL];
	if (oseq && rta && RTA_PAYLOAD(rta) <= sizeof(replay)) {
		uint32_t *o;

		rtype = rta->rta_type;
		rlen = (unsigned)RTA_PAYLOAD(rta);
		memcpy(replay, RTA_DATA(rta), rlen);
		o = rtype == XFRMA_REPLAY_ESN_VAL ? &((struct xfrm_replay_state_esn *)replay)->oseq :
						    &((struct xfrm_replay_state *)replay)->oseq;
		/* never back: the kernel may have gone past it on its own */
		if ((int32_t)(oseq - *o) > 0)
			*o = oseq;
		else
			rtype = 0;
	}
	if ((bytes || packets) && (rta = tb[XFRMA_LTIME_VAL]) && RTA_PAYLOAD(rta) >= sizeof(lt)) {
		memcpy(&lt, RTA_DATA(rta), sizeof(lt));
		lt.bytes += bytes;
		lt.packets += packets;
	} else {
		bytes = packets = 0;
	}
	if (!rtype && !bytes && !packets)
		return 0;
	req.n.nlmsg_len = NLMSG_LENGTH(sizeof(req.id));
	req.n.nlmsg_type = XFRM_MSG_NEWAE;
	req.n.nlmsg_flags = NLM_F_REQUEST | NLM_F_REPLACE | NLM_F_ACK;
	if (rtype) {
		at = (struct rtattr *)((char *)&req + NLMSG_ALIGN(req.n.nlmsg_len));
		at->rta_type = rtype;
		at->rta_len = (unsigned short)RTA_LENGTH(rlen);
		memcpy(RTA_DATA(at), replay, rlen);
		req.n.nlmsg_len = NLMSG_ALIGN(req.n.nlmsg_len) + RTA_ALIGN(at->rta_len);
	}
	if (bytes || packets) {
		at = (struct rtattr *)((char *)&req + NLMSG_ALIGN(req.n.nlmsg_len));
		at->rta_type = XFRMA_LTIME_VAL;
		at->rta_len = (unsigned short)RTA_LENGTH(sizeof(lt));
		memcpy(RTA_DATA(at), &lt, sizeof(lt));
		req.n.nlmsg_len = NLMSG_ALIGN(req.n.nlmsg_len) + RTA_ALIGN(at->rta_len);
	}
	n = xfrm_talk(&req.n, buf, sizeof(buf), NLMSG_ERROR);
	a = (const struct nlmsghdr *)buf;
	return n > 0 && NLMSG_OK(a, (unsigned)n) && a->nlmsg_type == NLMSG_ERROR &&
			       !((const struct nlmsgerr *)NLMSG_DATA(a))->error ? 0 : -1;
}

/* A line of the engine about an SA (ctl.c, sa). */
struct sa_line {
	uint32_t spi, daddr;
	int out;
	uint32_t seq;
	uint64_t bytes, packets;
};

static int
sa_line_of(const char *l, struct sa_line *s)
{
	char dir[4], src[INET_ADDRSTRLEN], dst[INET_ADDRSTRLEN];
	unsigned spi, reqid;
	unsigned long long b, p;
	const char *seq = strstr(l, " seq=");

	if (sscanf(l, "sa spi=0x%x dir=%3s reqid=%u src=%15s dst=%15s bytes=%llu packets=%llu", &spi,
		   dir, &reqid, src, dst, &b, &p) != 7 || inet_pton(AF_INET, dst, &s->daddr) != 1)
		return -1;
	s->spi = spi;
	s->out = !strcmp(dir, "out");
	s->seq = seq ? (uint32_t)strtoul(seq + 5, NULL, 10) : 0;
	s->bytes = b;
	s->packets = p;
	return 0;
}

/*
 * What the engine counted of h since the last time, into the kernel; and
 * its last number. 0, or -1 when the kernel did not take it (tried again
 * at the next tick).
 */
static int
sa_write(struct sa_held *h, const struct sa_line *l, int counters)
{
	uint64_t b = counters && l->bytes > h->bytes ? l->bytes - h->bytes : 0;
	uint64_t p = counters && l->packets > h->packets ? l->packets - h->packets : 0;

	if (kernel_ae(h, l->out ? sa_kernel_oseq(l->seq) : 0, b, p))
		return -1;
	h->bytes += b;
	h->packets += p;
	return 0;
}

/*
 * The engine lets go of h. In order when the kernel still has the SA: its
 * last number and what it counted go into the kernel first. A tunnel left
 * without an outbound SA lets go of its connections, which wait to be
 * handed over again (a new SA of the tunnel lets them be learned). loud:
 * logged without --verbose.
 */
static void
sa_take(struct sa_held *h, int kernel_has_it, const char *why, int loud)
{
	char line[CTL_LINE_MAX], dst[INET_ADDRSTRLEN], name[96], *data;
	struct sa_line l;
	uint32_t spi = h->spi, daddr = h->daddr;
	unsigned conns = 0;

	snprintf(name, sizeof(name), "%s", sa_name(h->spi, h->saddr, h->daddr, h->dir));
	inet_ntop(AF_INET, &h->daddr, dst, sizeof(dst));
	/* stopped, the engine drops the kernel's ESP on it until its last number is in the kernel */
	if (kernel_has_it) {
		if (engine_ask(line, sizeof(line), &data, "sa-stop 0x%08x %s", spi, dst))
			return;
		if (!strcmp(line, "ok") && data && !sa_line_of(data, &l) && sa_write(h, &l, 1))
			say("%s: its last number could not be written into the kernel", name);
		conns += conns_let_go(data);
		free(data);
	}
	if (engine_ask(line, sizeof(line), &data, "sa-del 0x%08x %s", spi, dst))
		return;
	conns += conns_let_go(data);
	free(data);
	if (loud || o.verbose || strcmp(line, "ok"))
		say("%s goes through the kernel again: %s", name, strcmp(line, "ok") ? line : why);
	if (conns)
		say("%s: %u connections go through the kernel until they are accelerated again", name,
		    conns);
	sas_del(held, spi, daddr);
}

/* Hands the SA over when sa.c lets it; seen: the mark of a dump. */
static void
sa_give(struct sa_kernel *k, unsigned seen)
{
	char req[CTL_LINE_MAX], line[CTL_LINE_MAX];
	struct sa_held *h = sas_find(held, k->spi, k->daddr);
	const char *why;
	int n;

	if (h) {
		h->seen = seen;
		return;
	}
	sa_way(k);
	why = sa_why(k, sas_room(held, k->reqid));
	if (why) {
		if (o.verbose)
			say("%s stays on the kernel: %s", sa_name(k->spi, k->saddr, k->daddr, k->dir), why);
		return;
	}
	if (sa_request(k, req, sizeof(req)))
		return;
	n = engine_ask(line, sizeof(line), NULL, "%s", req);
	explicit_bzero(req, sizeof(req));
	if (n)
		return;
	if (strcmp(line, "ok") && strcmp(line, "err exists")) {
		say("%s stays on the kernel: %s", sa_name(k->spi, k->saddr, k->daddr, k->dir), line);
		return;
	}
	h = sas_add(held, k);
	if (!h)
		die("no memory");
	h->seen = seen;
	if (o.verbose)
		say("%s is accelerated", sa_name(k->spi, k->saddr, k->daddr, k->dir));
	/* at once: the kernel's next number is past the engine's first */
	if (k->dir == SA_OUT) {
		struct sa_line l = { .out = 1, .seq = k->oseq + SA_MARGIN - 1 };

		sa_write(h, &l, 0);
		/* what waits for the tunnel (a rekey that came late) may be learned now */
		sync_retry_soon(known, now_ms());
	}
}

static void
take_unseen(struct sa_held *h, void *arg)
{
	if (h->seen != *(unsigned *)arg)
		sa_take(h, 0, "it is gone from the kernel", 0);
}

/*
 * The SAs of the kernel, each handed over when it may be; those held that
 * the kernel no longer has are let go of.
 */
static void
sa_dump(void)
{
	struct {
		struct nlmsghdr n;
		struct xfrm_usersa_info p;	/* the kernel wants room for one */
	} req = { .n = { .nlmsg_len = NLMSG_LENGTH(sizeof(struct xfrm_usersa_info)),
			 .nlmsg_type = XFRM_MSG_GETSA, .nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP,
			 .nlmsg_seq = 1 } };
	static char buf[64 << 10] __attribute__((aligned(NLMSG_ALIGNTO)));
	unsigned mark = sas_mark(held);
	int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_XFRM), done = 0;

	if (fd < 0)
		die("xfrm: %s", strerror(errno));
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &(struct timeval){ 2, 0 }, sizeof(struct timeval));
	if (send(fd, &req, req.n.nlmsg_len, 0) < 0)
		done = -1;
	while (!done) {
		ssize_t n = recv(fd, buf, sizeof(buf), 0);
		const struct nlmsghdr *h;
		int left = (int)n;

		if (n <= 0) {
			done = -1;
			break;
		}
		for (h = (const struct nlmsghdr *)buf; NLMSG_OK(h, left); h = NLMSG_NEXT(h, left)) {
			struct sa_kernel k;

			if (h->nlmsg_type == NLMSG_DONE || h->nlmsg_type == NLMSG_ERROR) {
				done = 1;
				break;
			}
			if (h->nlmsg_type == XFRM_MSG_NEWSA && !sa_of(h, 0, &k) && engine >= 0)
				sa_give(&k, mark);
		}
	}
	close(fd);
	if (done < 0) {
		say("the keys of Tunnel IPsec could not be read: %s", strerror(errno));
		return;
	}
	if (engine >= 0)
		sas_walk(held, take_unseen, &mark);
}

static void
take_gone(struct sa_held *h, void *arg)
{
	(void)arg;
	sa_take(h, 0, "the kernel flushed its keys", 0);
}

/* One message of xfrm about an SA. */
static void
on_xfrm(const struct nlmsghdr *h)
{
	struct sa_kernel k;
	struct sa_held *s;

	switch (h->nlmsg_type) {
	case XFRM_MSG_NEWSA:
	case XFRM_MSG_UPDSA:
		if (sa_of(h, 0, &k))
			return;
		s = sas_find(held, k.spi, k.daddr);
		if (s)
			sa_way(&k);
		/* changed so that the engine's copy is wrong, or may not be held now */
		if (s && (sa_why(&k, 1) || s->saddr != k.saddr ||
			  s->sport != (k.encap ? k.sport : 0) || s->dport != (k.encap ? k.dport : 0)))
			sa_take(s, 1, "it changed", 0);
		sa_give(&k, 0);
		break;
	case XFRM_MSG_DELSA: {
		const struct xfrm_usersa_id *id = NLMSG_DATA(h);

		if (h->nlmsg_len >= NLMSG_LENGTH(sizeof(*id)) && id->family == AF_INET &&
		    (s = sas_find(held, ntohl(id->spi), id->daddr.a4)))
			sa_take(s, 0, "the kernel deleted it", 0);
		break;
	}
	case XFRM_MSG_EXPIRE: {
		const struct xfrm_user_expire *e = NLMSG_DATA(h);

		/* a soft one asks for a rekey; a hard one deletes the SA */
		if (h->nlmsg_len >= NLMSG_LENGTH(sizeof(*e)) && e->hard && e->state.family == AF_INET &&
		    (s = sas_find(held, ntohl(e->state.id.spi), e->state.id.daddr.a4)))
			sa_take(s, 0, "it expired", 0);
		break;
	}
	case XFRM_MSG_FLUSHSA:
		sas_walk(held, take_gone, NULL);
		break;
	}
}

/* The events of xfrm waiting; lost ones: the SAs are read again. */
static void
xfrm_read(void)
{
	static char buf[64 << 10] __attribute__((aligned(NLMSG_ALIGNTO)));

	for (;;) {
		ssize_t n = recv(xfrm_events, buf, sizeof(buf), 0);
		const struct nlmsghdr *h;
		int left = (int)n;

		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0 && errno == ENOBUFS) {
			if (engine >= 0) {
				say("events of Tunnel IPsec were lost: its keys are read again");
				sa_dump();
			}
			continue;
		}
		if (n <= 0)
			return;
		/* nothing to keep in step with while there is no engine: a dump follows */
		for (h = (const struct nlmsghdr *)buf; engine >= 0 && NLMSG_OK(h, left);
		     h = NLMSG_NEXT(h, left))
			on_xfrm(h);
	}
}

static void
xfrm_open(void)
{
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK, .nl_groups = XFRMGRP_SA | XFRMGRP_EXPIRE };
	int size = ROUTING_BUFFER;

	xfrm_events = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC | SOCK_NONBLOCK, NETLINK_XFRM);
	if (xfrm_events < 0 || bind(xfrm_events, (struct sockaddr *)&sa, sizeof(sa)))
		die("xfrm: %s", strerror(errno));
	if (setsockopt(xfrm_events, SOL_SOCKET, SO_RCVBUFFORCE, &size, sizeof(size)))
		setsockopt(xfrm_events, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
}

/* Every second: the engine's numbers into the kernel; every SA_COUNT_TICKS, its counters too. */
static void
sa_tick(void)
{
	char line[CTL_LINE_MAX], *data, *l, *save = NULL;
	int counters;

	if (!sas_count(held))
		return;
	counters = ++sa_ticks % SA_COUNT_TICKS == 0;
	if (engine_ask(line, sizeof(line), &data, "sa"))
		return;
	for (l = data ? strtok_r(data, "\n", &save) : NULL; l; l = strtok_r(NULL, "\n", &save)) {
		struct sa_line s;
		struct sa_held *h;

		if (sa_line_of(l, &s))
			continue;
		h = sas_find(held, s.spi, s.daddr);
		if (!h)
			continue;
		sa_write(h, &s, counters);
		/* Q12: before the engine runs out of numbers; the kernel goes on past them */
		if (s.out && sa_seq_leave(s.seq))
			sa_take(h, 1, "its sequence numbers near their end", 1);
	}
	free(data);
}

static void
take_ordered(struct sa_held *h, void *arg)
{
	(void)arg;
	sa_take(h, 1, "the daemon stops", 0);
}

static struct nfct_handle *
ct_open(unsigned groups, int (*cb)(enum nf_conntrack_msg_type, struct nf_conntrack *, void *))
{
	struct nfct_handle *h = nfct_open(CONNTRACK, groups);

	if (!h)
		die("conntrack: %s", strerror(errno));
	if (nfct_callback_register(h, NFCT_T_ALL, cb, NULL) < 0)
		die("conntrack: %s", strerror(errno));
	return h;
}

static void
options(int argc, char **argv)
{
	static const struct option lo[] = {
		{ "socket", required_argument, NULL, 's' },
		{ "keepalive", required_argument, NULL, 'k' },
		{ "verbose", no_argument, NULL, 'v' },
		{ "tunnels", required_argument, NULL, 't' },
		{ "kept", required_argument, NULL, 'K' },
		{ "pppoe", required_argument, NULL, 'P' },
		{ NULL, 0, NULL, 0 },
	};
	char *end;
	int c;

	while ((c = getopt_long(argc, argv, "", lo, NULL)) != -1)
		switch (c) {
		case 's':
			o.socket = optarg;
			break;
		case 'k':
			o.keepalive = (unsigned)strtoul(optarg, &end, 10);
			if (*optarg == '\0' || *end != '\0' || o.keepalive == 0 || o.keepalive > 3600)
				die("--keepalive %s: 1 to 3600 seconds", optarg);
			break;
		case 'v':
			o.verbose = 1;
			break;
		case 'K':
			o.kept = optarg;
			break;
		case 'P':
			o.pppoe = optarg;
			break;
		case 't':
			max_tunnels = (unsigned)strtoul(optarg, &end, 10);
			if (*optarg == '\0' || *end != '\0' || max_tunnels == 0 ||
			    max_tunnels > SA_MAX_TUNNELS)
				die("--tunnels %s: 1 to %u", optarg, SA_MAX_TUNNELS);
			break;
		default:
			die("usage: bmchwaccel-syncd [--socket PATH] [--keepalive SECONDS] [--tunnels N] [--kept FILE] [--pppoe FILE] [--verbose]");
		}
	if (optind != argc)
		die("usage: bmchwaccel-syncd [--socket PATH] [--keepalive SECONDS] [--tunnels N] [--kept FILE] [--pppoe FILE] [--verbose]");
}

int
main(int argc, char **argv)
{
	uint32_t tick_at;
	int efd;

	options(argc, argv);
	known = sync_create();
	watched = watch_create();
	held = sas_create(max_tunnels);
	if (!known || !watched || !held)
		die("no memory");
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	signal(SIGPIPE, SIG_IGN);
	events = ct_open(NF_NETLINK_CONNTRACK_NEW | NF_NETLINK_CONNTRACK_UPDATE |
			 NF_NETLINK_CONNTRACK_DESTROY, on_event);
	dumps = ct_open(0, on_dump);
	queries = ct_open(0, on_answer);
	nfnl_rcvbufsiz(nfct_nfnlh(events), EVENT_BUFFER);
	efd = nfct_fd(events);
	fcntl(efd, F_SETFL, fcntl(efd, F_GETFL) | O_NONBLOCK);
	routing_open();
	xfrm_open();

	tick_at = now_ms();
	reconnect_at = tick_at;
	while (!quit) {
		struct pollfd pf[4] = {
			{ .fd = efd, .events = POLLIN },
			{ .fd = routing, .events = POLLIN },
			{ .fd = xfrm_events, .events = POLLIN },
			{ .fd = engine, .events = POLLIN },
		};
		uint32_t now = now_ms(), next = tick_at;
		int wait;

		if (engine < 0 && (int32_t)(now - reconnect_at) >= 0)
			engine_connect();
		if (engine < 0)
			next = reconnect_at;
		else if ((int32_t)(keepalive_at - next) < 0)
			next = keepalive_at;
		wait = (int32_t)(next - now) > 0 ? (int)(next - now) : 0;
		if (poll(pf, engine < 0 ? 3 : 4, wait) < 0 && errno != EINTR)
			die("poll: %s", strerror(errno));
		if (pf[0].revents && nfct_catch(events) < 0 && errno == ENOBUFS && engine >= 0)
			events_lost();
		if (pf[1].revents)
			routing_events();
		if (pf[2].revents)
			xfrm_read();
		/* the engine never speaks unasked: it closed, or died */
		if (engine >= 0 && pf[3].revents)
			engine_lost("it closed the session");
		now = now_ms();
		if ((int32_t)(now - tick_at) >= 0) {
			tick_at = now + TICK_MS;
			if (engine >= 0)
				sync_due(known, now, bind_due, NULL);
			if (engine >= 0)
				sa_tick();
			if (engine >= 0 && sa_again) {
				sa_again = 0;
				sa_dump();
			}
		}
		if (engine >= 0 && (int32_t)(now - keepalive_at) >= 0) {
			keepalive_at = now + o.keepalive * 1000;
			keepalive();
		}
	}
	/*
	 * In order: the connections, then the SAs, each with its last number
	 * written into the kernel; closing the session would let go of both,
	 * without those numbers.
	 */
	if (engine >= 0) {
		char line[CTL_LINE_MAX];

		engine_ask(line, sizeof(line), NULL, "flush");
		if (engine >= 0)
			sas_walk(held, take_ordered, NULL);
	}
	if (engine >= 0)
		close(engine);
	close(xfrm_events);
	sas_free(held);
	nfct_close(events);
	nfct_close(dumps);
	nfct_close(queries);
	close(routing);
	sync_free(known);
	watch_free(watched);
	return 0;
}
