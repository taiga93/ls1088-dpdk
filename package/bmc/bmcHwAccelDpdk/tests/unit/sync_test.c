/*
 * Seam 3, its part without I/O: what bmchwaccel-syncd decides for each
 * conntrack message (sync.h). Each test gives connections as conntrack
 * messages give them and looks at what the module says to do.
 *
 *   sync_test [TEST...]
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdlib.h>

#include "../../src/sync.h"
#include "testlib.h"

#define IPS_SEEN_REPLY 0x2
#define IPS_ASSURED 0x4
#define TCP_SYN_RECV 2
#define TCP_FIN_WAIT 4

/* The masqueraded connection of the example: 192.168.5.10:40000 -> 203.0.113.5:443. */
static struct sync_ct
web(uint8_t proto)
{
	struct sync_ct ct = {
		.ipv4 = 1,
		.proto = proto,
		.status = IPS_SEEN_REPLY | IPS_ASSURED,
		.tcp_state = proto == IPPROTO_TCP ? SYNC_TCP_ESTABLISHED : SYNC_TCP_UNKNOWN,
	};

	ct.orig.sip = inet_addr("192.168.5.10");
	ct.orig.dip = inet_addr("203.0.113.5");
	ct.orig.sport = htons(40000);
	ct.orig.dport = htons(443);
	ct.reply.sip = ct.orig.dip;
	ct.reply.dip = inet_addr("198.51.100.2");
	ct.reply.sport = ct.orig.dport;
	ct.reply.dport = ct.orig.sport;
	return ct;
}

/* Another connection: the next source port. */
static struct sync_ct
web_next(uint8_t proto, unsigned i)
{
	struct sync_ct ct = web(proto);

	ct.orig.sport = htons((uint16_t)(40000 + i));
	ct.reply.dport = ct.orig.sport;
	return ct;
}

static struct sync *s;

static void
fresh(void)
{
	sync_free(s);
	s = sync_create();
}

/* sync_ct() said BIND: the engine took it. */
static enum sync_do
bind_ok(struct sync_ct *ct, enum sync_msg msg, uint32_t now)
{
	enum sync_do d = sync_ct(s, msg, ct, now);

	if (d == SYNC_BIND)
		sync_bound(s, ct->proto, &ct->orig, SYNC_OK, now);
	return d;
}

static void
count_due(const struct sync_conn *c, void *arg)
{
	(*(unsigned *)arg)++;
	(void)c;
}

/* The connections due at now, each refused again as r. */
struct refuse {
	enum sync_result r;
	uint32_t now;
	unsigned n;
};

static void
refuse_due(const struct sync_conn *c, void *arg)
{
	struct refuse *a = arg;

	a->n++;
	sync_bound(s, c->proto, &c->orig, a->r, a->now);
}

TEST(an_assured_established_tcp_connection_is_bound)
{
	struct sync_ct ct = web(IPPROTO_TCP);

	fresh();
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 0) == SYNC_BIND);
	sync_bound(s, IPPROTO_TCP, &ct.orig, SYNC_OK, 0);
	CHECK(sync_is_bound(s, IPPROTO_TCP, &ct.orig));
	/* the next messages of it change nothing */
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 5) == SYNC_NOTHING);
	CHECK(sync_ct(s, SYNC_FULL, &ct, 6) == SYNC_NOTHING);
}

TEST(a_udp_connection_is_bound_once_conntrack_assures_it)
{
	struct sync_ct ct = web(IPPROTO_UDP);

	fresh();
	ct.status = 0;
	CHECK(sync_ct(s, SYNC_NEW, &ct, 0) == SYNC_NOTHING);
	ct.status = IPS_SEEN_REPLY;
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 1) == SYNC_NOTHING);
	ct.status = IPS_SEEN_REPLY | IPS_ASSURED;
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 2000) == SYNC_BIND);
}

TEST(a_connection_that_is_not_ipv4_tcp_or_udp_is_never_bound)
{
	struct sync_ct ct = web(IPPROTO_TCP);

	fresh();
	ct.ipv4 = 0;
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 0) == SYNC_NOTHING);
	ct = web(IPPROTO_ICMP);
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 0) == SYNC_NOTHING);
	ct = web(132);	/* SCTP */
	CHECK(sync_ct(s, SYNC_FULL, &ct, 0) == SYNC_NOTHING);
}

TEST(a_connection_kept_on_the_cpu_is_never_bound)
{
	struct sync_ct ct = web(IPPROTO_TCP);

	fresh();
	ct.mark = SYNC_KEEP_BIT | 0x0100;
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 0) == SYNC_NOTHING);
	CHECK(sync_ct(s, SYNC_FULL, &ct, 0) == SYNC_NOTHING);
	/* the marks of mwan3 and bmcqos do not keep it */
	ct.mark = 0x3f00 | 0xff;
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 0) == SYNC_BIND);
}

TEST(a_connection_with_a_helper_is_never_bound)
{
	struct sync_ct ct = web(IPPROTO_TCP);

	fresh();
	ct.helper = 1;
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 0) == SYNC_NOTHING);
	CHECK(sync_ct(s, SYNC_FULL, &ct, 0) == SYNC_NOTHING);
}

TEST(a_tcp_connection_is_bound_only_while_established)
{
	struct sync_ct ct = web(IPPROTO_TCP);

	fresh();
	ct.tcp_state = TCP_SYN_RECV;
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 0) == SYNC_NOTHING);
	ct.tcp_state = TCP_FIN_WAIT;
	CHECK(sync_ct(s, SYNC_FULL, &ct, 0) == SYNC_NOTHING);
}

TEST(an_update_without_the_tcp_state_of_an_unknown_connection_asks_conntrack)
{
	struct sync_ct ct = web(IPPROTO_TCP);

	fresh();
	ct.tcp_state = SYNC_TCP_UNKNOWN;
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 0) == SYNC_QUERY);
	/* not worth a question when something else rules it out */
	ct.mark = SYNC_KEEP_BIT;
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 0) == SYNC_NOTHING);
	/* the answer */
	ct.mark = 0;
	ct.tcp_state = SYNC_TCP_ESTABLISHED;
	CHECK(sync_ct(s, SYNC_FULL, &ct, 0) == SYNC_BIND);
}

TEST(an_update_without_the_tcp_state_of_a_known_connection_keeps_its_state)
{
	struct sync_ct ct = web(IPPROTO_TCP);

	fresh();
	CHECK(bind_ok(&ct, SYNC_UPDATE, 0) == SYNC_BIND);
	ct.tcp_state = SYNC_TCP_UNKNOWN;
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 1) == SYNC_NOTHING);
	CHECK(sync_is_bound(s, IPPROTO_TCP, &ct.orig));
}

TEST(destroy_takes_a_bound_connection_back)
{
	struct sync_ct ct = web(IPPROTO_TCP);
	unsigned b, w;

	fresh();
	bind_ok(&ct, SYNC_UPDATE, 0);
	/* a destroy message says little more than the tuples */
	ct.status = 0;
	ct.tcp_state = SYNC_TCP_UNKNOWN;
	CHECK(sync_ct(s, SYNC_DESTROY, &ct, 1) == SYNC_UNBIND);
	CHECK(!sync_is_bound(s, IPPROTO_TCP, &ct.orig));
	sync_count(s, &b, &w);
	CHECK(b == 0 && w == 0);
	CHECK(sync_ct(s, SYNC_DESTROY, &ct, 2) == SYNC_NOTHING);
}

TEST(destroy_of_a_connection_waiting_for_its_bind_forgets_it)
{
	struct sync_ct ct = web(IPPROTO_UDP);
	unsigned b, w, n = 0;

	fresh();
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 0) == SYNC_BIND);
	sync_bound(s, IPPROTO_UDP, &ct.orig, SYNC_UNLEARNED, 0);
	CHECK(sync_ct(s, SYNC_DESTROY, &ct, 10) == SYNC_NOTHING);
	sync_count(s, &b, &w);
	CHECK(b == 0 && w == 0);
	sync_due(s, 60000, count_due, &n);
	CHECK(n == 0);
}

TEST(a_tcp_connection_that_leaves_established_is_taken_back)
{
	struct sync_ct ct = web(IPPROTO_TCP);

	fresh();
	bind_ok(&ct, SYNC_UPDATE, 0);
	ct.tcp_state = TCP_FIN_WAIT;
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 1) == SYNC_UNBIND);
	CHECK(!sync_is_bound(s, IPPROTO_TCP, &ct.orig));
	/* and is not bound again */
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 2) == SYNC_NOTHING);
}

TEST(a_connection_that_gets_the_keep_bit_is_taken_back)
{
	struct sync_ct ct = web(IPPROTO_UDP);

	fresh();
	bind_ok(&ct, SYNC_UPDATE, 0);
	ct.mark = SYNC_KEEP_BIT;
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 1) == SYNC_UNBIND);
	/* the bit cleared again (release): accelerated again */
	ct.mark = 0;
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 2) == SYNC_BIND);
}

TEST(a_tcp_connection_that_loses_the_keep_bit_is_asked_for_its_state)
{
	struct sync_ct ct = web(IPPROTO_TCP);

	fresh();
	ct.mark = SYNC_KEEP_BIT;
	CHECK(sync_ct(s, SYNC_FULL, &ct, 0) == SYNC_NOTHING);
	/* conntrack -U --mark 0/0x10000: the event has the mark, not the state */
	ct.mark = 0;
	ct.tcp_state = SYNC_TCP_UNKNOWN;
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 1) == SYNC_QUERY);
}

TEST(a_bind_the_engine_could_not_make_is_tried_again_less_and_less_often)
{
	struct sync_ct ct = web(IPPROTO_TCP);
	struct refuse a = { SYNC_UNLEARNED, 0, 0 };
	uint32_t t = 0, gap = SYNC_RETRY_FIRST;
	unsigned i, n = 0;

	fresh();
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 0) == SYNC_BIND);
	sync_bound(s, IPPROTO_TCP, &ct.orig, SYNC_UNLEARNED, 0);
	/* events about it do not ask for more binds meanwhile */
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 10) == SYNC_NOTHING);
	for (i = 0; i < 8; i++) {
		a.now = t + gap - 1;
		a.n = 0;
		sync_due(s, a.now, refuse_due, &a);
		CHECK(a.n == 0);
		t += gap;
		a.now = t;
		sync_due(s, a.now, refuse_due, &a);
		CHECK(a.n == 1);
		gap = gap * 2 > SYNC_RETRY_MAX ? SYNC_RETRY_MAX : gap * 2;
	}
	CHECK(gap == SYNC_RETRY_MAX);
	/* a full table is tried again too; then it is bound */
	a.r = SYNC_NOSPACE;
	a.now = t + SYNC_RETRY_MAX;
	sync_due(s, a.now, refuse_due, &a);
	CHECK(a.n == 2);
	t = a.now + SYNC_RETRY_MAX;
	a.r = SYNC_OK;
	a.now = t;
	sync_due(s, t, refuse_due, &a);
	CHECK(a.n == 3);
	CHECK(sync_is_bound(s, IPPROTO_TCP, &ct.orig));
	sync_due(s, t + 10 * SYNC_RETRY_MAX, count_due, &n);
	CHECK(n == 0);
}

TEST(a_bind_refused_for_another_reason_is_not_tried_again)
{
	struct sync_ct ct = web(IPPROTO_TCP);
	unsigned n = 0;

	fresh();
	sync_ct(s, SYNC_UPDATE, &ct, 0);
	sync_bound(s, IPPROTO_TCP, &ct.orig, SYNC_REFUSED, 0);
	sync_due(s, 10 * SYNC_RETRY_MAX, count_due, &n);
	CHECK(n == 0);
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 1) == SYNC_NOTHING);
	CHECK(!sync_is_bound(s, IPPROTO_TCP, &ct.orig));
}

TEST(a_connection_the_engine_already_has_is_bound)
{
	struct sync_ct ct = web(IPPROTO_UDP);

	fresh();
	sync_ct(s, SYNC_UPDATE, &ct, 0);
	sync_bound(s, IPPROTO_UDP, &ct.orig, SYNC_EXISTS, 0);
	CHECK(sync_is_bound(s, IPPROTO_UDP, &ct.orig));
}

TEST(tcp_and_udp_of_the_same_tuple_are_two_connections)
{
	struct sync_ct t = web(IPPROTO_TCP), u = web(IPPROTO_UDP);

	fresh();
	bind_ok(&t, SYNC_UPDATE, 0);
	CHECK(!sync_is_bound(s, IPPROTO_UDP, &u.orig));
	CHECK(bind_ok(&u, SYNC_UPDATE, 0) == SYNC_BIND);
	CHECK(sync_ct(s, SYNC_DESTROY, &u, 1) == SYNC_UNBIND);
	CHECK(sync_is_bound(s, IPPROTO_TCP, &t.orig));
}

TEST(a_connection_the_engine_let_go_of_is_bound_again_soon)
{
	struct sync_ct ct = web(IPPROTO_TCP), other = web_next(IPPROTO_TCP, 1);
	struct refuse a = { SYNC_OK, 0, 0 };
	unsigned b, w, n = 0;

	fresh();
	bind_ok(&ct, SYNC_UPDATE, 0);
	bind_ok(&other, SYNC_UPDATE, 0);
	/* tried and refused a few times before: the next tries start from the first wait again */
	sync_unbound(s, IPPROTO_TCP, &ct.orig, 100000);
	CHECK(!sync_is_bound(s, IPPROTO_TCP, &ct.orig));
	CHECK(sync_is_bound(s, IPPROTO_TCP, &other.orig));
	sync_count(s, &b, &w);
	CHECK(b == 1 && w == 1);
	CHECK(sync_due(s, 100000 + SYNC_RETRY_FIRST - 1, count_due, &n) == 0);
	a.now = 100000 + SYNC_RETRY_FIRST;
	CHECK(sync_due(s, a.now, refuse_due, &a) == 1);
	CHECK(sync_is_bound(s, IPPROTO_TCP, &ct.orig));
	/* its conntrack messages change nothing meanwhile, nor after */
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, a.now + 1) == SYNC_NOTHING);
	/* one the module does not know, or no longer bound, stays as it is */
	ct = web_next(IPPROTO_TCP, 7);
	sync_unbound(s, IPPROTO_TCP, &ct.orig, 0);
	sync_count(s, &b, &w);
	CHECK(b == 2 && w == 0);
}

TEST(a_connection_the_engine_let_go_of_is_tried_again_less_and_less_often)
{
	struct sync_ct ct = web(IPPROTO_UDP);
	struct refuse a = { SYNC_UNLEARNED, 0, 0 };

	fresh();
	bind_ok(&ct, SYNC_UPDATE, 0);
	sync_unbound(s, IPPROTO_UDP, &ct.orig, 0);
	a.now = SYNC_RETRY_FIRST;
	CHECK(sync_due(s, a.now, refuse_due, &a) == 1);
	CHECK(sync_due(s, a.now + SYNC_RETRY_FIRST - 1, count_due, &a.n) == 0);
	a.now += SYNC_RETRY_FIRST;
	CHECK(sync_due(s, a.now, refuse_due, &a) == 1);
	CHECK(sync_due(s, a.now + 2 * SYNC_RETRY_FIRST - 1, count_due, &a.n) == 0);
	a.now += 2 * SYNC_RETRY_FIRST;
	CHECK(sync_due(s, a.now, refuse_due, &a) == 1);
	/* destroyed meanwhile: forgotten */
	CHECK(sync_ct(s, SYNC_DESTROY, &ct, a.now) == SYNC_NOTHING);
	CHECK(sync_due(s, a.now + SYNC_RETRY_MAX, count_due, &a.n) == 0);
}

TEST(when_the_engine_let_go_of_everything_every_bound_connection_waits_again)
{
	struct sync_ct ct;
	unsigned i, b, w, n = 0;

	fresh();
	for (i = 0; i < 100; i++) {
		ct = web_next(IPPROTO_TCP, i);
		if (i % 2)
			bind_ok(&ct, SYNC_UPDATE, 0);
		else if (sync_ct(s, SYNC_UPDATE, &ct, 0) == SYNC_BIND)
			sync_bound(s, IPPROTO_TCP, &ct.orig, SYNC_UNLEARNED, 0);
	}
	sync_unbound_all(s, 5000);
	sync_count(s, &b, &w);
	CHECK(b == 0 && w == 100);
	/* the ones bound until now are due again after the first wait, the others were due already */
	CHECK(sync_due(s, 5000 + SYNC_RETRY_FIRST, count_due, &n) == 100);
}

TEST(after_a_change_of_the_routing_every_waiting_connection_is_tried_again_soon)
{
	struct sync_ct ct = web(IPPROTO_TCP), refused = web_next(IPPROTO_TCP, 1);
	struct refuse a = { SYNC_UNLEARNED, 0, 0 };
	unsigned n = 0;

	fresh();
	CHECK(sync_ct(s, SYNC_UPDATE, &ct, 0) == SYNC_BIND);
	CHECK(sync_ct(s, SYNC_UPDATE, &refused, 0) == SYNC_BIND);
	sync_bound(s, IPPROTO_TCP, &refused.orig, SYNC_REFUSED, 0);
	/* not learned at 1, 2, 4 and 8 s: the next try at 16 s */
	for (a.now = 1000; a.n < 4; a.now *= 2)
		CHECK(sync_due(s, a.now, refuse_due, &a) == 1);
	sync_retry_soon(s, 10000);
	CHECK(sync_due(s, 10000 + SYNC_RETRY_FIRST - 1, count_due, &n) == 0);
	/* the one refused for good stays so */
	CHECK(sync_due(s, 10000 + SYNC_RETRY_FIRST, count_due, &n) == 1);
	/* and a refusal after it starts from the first wait again */
	a.now = 10000 + SYNC_RETRY_FIRST;
	CHECK(sync_due(s, a.now, refuse_due, &a) == 1);
	CHECK(sync_due(s, a.now + SYNC_RETRY_FIRST, count_due, &n) == 1);
}

TEST(reset_forgets_every_connection)
{
	struct sync_ct ct;
	unsigned i, b, w;

	fresh();
	for (i = 0; i < 1000; i++) {
		ct = web_next(IPPROTO_TCP, i);
		if (i % 2)
			bind_ok(&ct, SYNC_UPDATE, 0);
		else if (sync_ct(s, SYNC_UPDATE, &ct, 0) == SYNC_BIND)
			sync_bound(s, IPPROTO_TCP, &ct.orig, SYNC_UNLEARNED, 0);
	}
	sync_count(s, &b, &w);
	CHECK(b == 500 && w == 500);
	sync_reset(s);
	sync_count(s, &b, &w);
	CHECK(b == 0 && w == 0);
	ct = web_next(IPPROTO_TCP, 1);
	CHECK(!sync_is_bound(s, IPPROTO_TCP, &ct.orig));
	CHECK(sync_ct(s, SYNC_FULL, &ct, 1) == SYNC_BIND);
}

TEST(many_connections_come_and_go)
{
	struct sync_ct ct;
	unsigned i, b, w;

	fresh();
	for (i = 0; i < 20000; i++) {
		ct = web_next(IPPROTO_UDP, i);
		ct.orig.sip = htonl(0x0a000000 + i / 16);
		CHECK(bind_ok(&ct, SYNC_UPDATE, i) == SYNC_BIND);
	}
	for (i = 0; i < 20000; i += 2) {
		ct = web_next(IPPROTO_UDP, i);
		ct.orig.sip = htonl(0x0a000000 + i / 16);
		CHECK(sync_ct(s, SYNC_DESTROY, &ct, 30000) == SYNC_UNBIND);
	}
	sync_count(s, &b, &w);
	CHECK(b == 10000 && w == 0);
	for (i = 1; i < 20000; i += 2) {
		ct = web_next(IPPROTO_UDP, i);
		ct.orig.sip = htonl(0x0a000000 + i / 16);
		CHECK(sync_is_bound(s, IPPROTO_UDP, &ct.orig));
		sync_forget(s, IPPROTO_UDP, &ct.orig);
	}
	sync_count(s, &b, &w);
	CHECK(b == 0 && w == 0);
}

TEST(conntrack_ends_a_connection_after_the_kernel_timeout_from_its_last_packet)
{
	CHECK(sync_timeout(180, 0) == 180);
	CHECK(sync_timeout(180, 999) == 180);
	/* never sooner than the kernel would: what is left, rounded up */
	CHECK(sync_timeout(180, 30500) == 150);
	CHECK(sync_timeout(7440, 10000) == 7430);
	CHECK(sync_timeout(180, 179999) == 1);
	CHECK(sync_timeout(180, 400000) == 1);
}

int
main(int argc, char **argv)
{
	int r = test_main(argc - 1, argv + 1);

	sync_free(s);
	return r;
}
