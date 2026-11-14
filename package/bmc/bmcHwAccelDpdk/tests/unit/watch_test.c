/*
 * Seam 3, its part without I/O: what bmchwaccel-syncd has the engine let go
 * of when the kernel's routing changes (watch.h). Each test tells the module
 * what rtnetlink would and looks at what it answers.
 *
 *   watch_test [TEST...]
 */
#include <arpa/inet.h>
#include <stdlib.h>

#include "../../src/watch.h"
#include "testlib.h"

/* The ports of the example: eth0 the WAN, eth1 on br-lan, both the engine's; eth3 a 1G port of br-lan. */
enum { ETH0 = 2, ETH1 = 3, ETH3 = 5, BRLAN = 10, PPPOE = 20 };

static const uint8_t pc_mac[6] = { 0x02, 0, 0, 0, 0, 0x0a };
static const uint8_t pc_new_mac[6] = { 0x02, 0, 0, 0, 0, 0x0b };

static struct watch *w;
static struct watch_act a;

static void
fresh(void)
{
	static const char *const ports[] = { "eth0", "eth1" };

	watch_free(w);
	w = watch_create();
	watch_ports(w, ports, 2);
	/* what a dump at start says: everything up */
	watch_link(w, ETH0, "eth0", 1, 0, 0, &a);
	watch_link(w, ETH1, "eth1", 1, 1, 0, &a);
	watch_link(w, ETH3, "eth3", 1, 1, 0, &a);
	watch_link(w, BRLAN, "br-lan", 1, 0, 0, &a);
}

static uint32_t
addr(const char *s)
{
	return inet_addr(s);
}

TEST(a_route_has_the_connections_to_its_network_let_go_of)
{
	fresh();
	CHECK(watch_route(w, addr("203.0.113.0"), 24, 0, &a) == WATCH_FLUSH_ROUTE);
	CHECK(a.what == WATCH_FLUSH_ROUTE && a.dst == addr("203.0.113.0") && a.len == 24);
	CHECK(watch_route(w, addr("192.168.5.10"), 32, 0, &a) == WATCH_FLUSH_ROUTE);
	CHECK(a.dst == addr("192.168.5.10") && a.len == 32);
}

TEST(the_default_route_has_every_connection_let_go_of)
{
	fresh();
	CHECK(watch_route(w, 0, 0, 0, &a) == WATCH_FLUSH);
	CHECK(a.what == WATCH_FLUSH);
}

TEST(a_cached_route_changes_nothing)
{
	fresh();
	CHECK(watch_route(w, addr("203.0.113.5"), 32, 1, &a) == WATCH_NOTHING);
	CHECK(a.what == WATCH_NOTHING);
}

TEST(a_rule_a_nexthop_or_an_address_that_went_has_every_connection_let_go_of)
{
	fresh();
	CHECK(watch_rule(w, &a) == WATCH_FLUSH);
	/* the routes of FRR follow their nexthop object, without a word of their own */
	CHECK(watch_nexthop(w, &a) == WATCH_FLUSH);
	CHECK(watch_addr_gone(w, &a) == WATCH_FLUSH);
}

TEST(a_neighbour_with_another_mac_address_has_the_connections_to_the_old_one_let_go_of)
{
	fresh();
	CHECK(watch_neigh(w, BRLAN, addr("192.168.5.10"), pc_mac, &a) == WATCH_NOTHING);
	/* the same address again: nothing */
	CHECK(watch_neigh(w, BRLAN, addr("192.168.5.10"), pc_mac, &a) == WATCH_NOTHING);
	CHECK(watch_neigh(w, BRLAN, addr("192.168.5.10"), pc_new_mac, &a) == WATCH_FLUSH_MAC);
	CHECK(!memcmp(a.mac, pc_mac, 6));
	/* and then that one is the address to compare with */
	CHECK(watch_neigh(w, BRLAN, addr("192.168.5.10"), pc_mac, &a) == WATCH_FLUSH_MAC);
	CHECK(!memcmp(a.mac, pc_new_mac, 6));
}

TEST(a_neighbour_the_kernel_forgot_is_remembered)
{
	fresh();
	watch_neigh(w, BRLAN, addr("192.168.5.10"), pc_mac, &a);
	/* deleted, failed, being resolved: no address */
	CHECK(watch_neigh(w, BRLAN, addr("192.168.5.10"), NULL, &a) == WATCH_NOTHING);
	CHECK(watch_neigh(w, BRLAN, addr("192.168.5.10"), pc_new_mac, &a) == WATCH_FLUSH_MAC);
	CHECK(!memcmp(a.mac, pc_mac, 6));
}

TEST(a_neighbour_of_another_interface_is_another_neighbour)
{
	fresh();
	watch_neigh(w, BRLAN, addr("192.168.5.10"), pc_mac, &a);
	CHECK(watch_neigh(w, PPPOE, addr("192.168.5.10"), pc_new_mac, &a) == WATCH_NOTHING);
	CHECK(watch_neigh(w, BRLAN, addr("192.168.5.11"), pc_new_mac, &a) == WATCH_NOTHING);
	CHECK(watch_neigh(w, BRLAN, addr("192.168.5.10"), pc_mac, &a) == WATCH_NOTHING);
}

TEST(an_all_zero_mac_address_is_none)
{
	static const uint8_t zero[6];

	fresh();
	watch_neigh(w, BRLAN, addr("192.168.5.10"), pc_mac, &a);
	CHECK(watch_neigh(w, BRLAN, addr("192.168.5.10"), zero, &a) == WATCH_NOTHING);
	CHECK(watch_neigh(w, BRLAN, addr("192.168.5.10"), pc_mac, &a) == WATCH_NOTHING);
}

TEST(many_neighbours_are_remembered)
{
	uint8_t m[6] = { 0x02, 0, 0, 0, 0, 0 };
	unsigned i, flushes = 0;

	fresh();
	for (i = 0; i < 20000; i++) {
		m[4] = (uint8_t)(i >> 8), m[5] = (uint8_t)i;
		watch_neigh(w, BRLAN, htonl(0x0a000000 + i), m, &a);
	}
	m[3] = 1;
	for (i = 0; i < 20000; i++) {
		m[4] = (uint8_t)(i >> 8), m[5] = (uint8_t)i;
		flushes += watch_neigh(w, BRLAN, htonl(0x0a000000 + i), m, &a) == WATCH_FLUSH_MAC &&
			   a.mac[3] == 0 && a.mac[5] == (uint8_t)i;
	}
	CHECK(flushes == 20000);
}

TEST(a_port_of_the_engine_that_goes_down_has_its_connections_let_go_of)
{
	fresh();
	CHECK(watch_link(w, ETH0, "eth0", 0, 0, 0, &a) == WATCH_FLUSH_PORT);
	CHECK(!strcmp(a.port, "eth0"));
	/* still down: once is enough */
	CHECK(watch_link(w, ETH0, "eth0", 0, 0, 0, &a) == WATCH_NOTHING);
	CHECK(watch_link(w, ETH0, "eth0", 1, 0, 0, &a) == WATCH_NOTHING);
	/* a port of the engine in a bridge too */
	CHECK(watch_link(w, ETH1, "eth1", 0, 1, 0, &a) == WATCH_FLUSH_PORT);
	CHECK(!strcmp(a.port, "eth1"));
}

TEST(a_port_of_a_bridge_that_goes_down_changes_nothing)
{
	fresh();
	CHECK(watch_link(w, ETH3, "eth3", 0, 1, 0, &a) == WATCH_NOTHING);
	CHECK(watch_link(w, ETH3, "eth3", 0, 1, 1, &a) == WATCH_NOTHING);
}

TEST(another_interface_that_goes_down_or_away_has_every_connection_let_go_of)
{
	fresh();
	CHECK(watch_link(w, BRLAN, "br-lan", 0, 0, 0, &a) == WATCH_FLUSH);
	CHECK(!strcmp(a.port, "br-lan"));
	CHECK(watch_link(w, BRLAN, "br-lan", 1, 0, 0, &a) == WATCH_NOTHING);
	watch_link(w, PPPOE, "pppoe-wan", 1, 0, 0, &a);
	CHECK(watch_link(w, PPPOE, "pppoe-wan", 1, 0, 1, &a) == WATCH_FLUSH);
	/* gone: a new interface with that index is new */
	CHECK(watch_link(w, PPPOE, "pppoe-wan", 0, 0, 0, &a) == WATCH_NOTHING);
}

TEST(the_first_word_of_an_interface_only_teaches)
{
	fresh();
	/* eth8, never cabled, and a new VLAN interface, down at first */
	CHECK(watch_link(w, 30, "eth8", 0, 0, 0, &a) == WATCH_NOTHING);
	CHECK(watch_link(w, 31, "eth0.10", 0, 0, 0, &a) == WATCH_NOTHING);
	CHECK(watch_link(w, 31, "eth0.10", 1, 0, 0, &a) == WATCH_NOTHING);
	CHECK(watch_link(w, 31, "eth0.10", 0, 0, 0, &a) == WATCH_FLUSH);
	/* one that goes away without having been heard of */
	CHECK(watch_link(w, 32, "veth9", 0, 0, 1, &a) == WATCH_NOTHING);
}

TEST(the_ports_of_the_engine_are_what_it_said_last)
{
	static const char *const ports[] = { "eth0" };

	fresh();
	watch_ports(w, ports, 1);
	CHECK(watch_link(w, ETH1, "eth1", 0, 1, 0, &a) == WATCH_NOTHING);
	watch_ports(w, NULL, 0);
	CHECK(watch_link(w, ETH0, "eth0", 0, 0, 0, &a) == WATCH_FLUSH);
}

TEST(an_interface_renamed_is_known_by_its_new_name)
{
	fresh();
	watch_link(w, 40, "eth9", 1, 0, 0, &a);
	watch_link(w, 40, "eth0", 1, 0, 0, &a);
	CHECK(watch_link(w, 40, "eth0", 0, 0, 0, &a) == WATCH_FLUSH_PORT);
}

TEST(many_interfaces_are_known)
{
	char name[16];
	int i;
	unsigned n = 0;

	fresh();
	for (i = 100; i < 400; i++) {
		snprintf(name, sizeof(name), "veth%d", i);
		watch_link(w, i, name, 1, 0, 0, &a);
	}
	for (i = 100; i < 400; i++) {
		snprintf(name, sizeof(name), "veth%d", i);
		n += watch_link(w, i, name, 0, 0, 0, &a) == WATCH_FLUSH;
	}
	CHECK(n == 300);
}

int
main(int argc, char **argv)
{
	int r = test_main(argc - 1, argv + 1);

	watch_free(w);
	return r;
}
