/*
 * What a change of the kernel's routing means for the connections the
 * engine holds (spec: Daemon đồng bộ, rút kết nối khi route, rule hay neigh
 * đổi, link của cổng xuống). The engine forwards a connection the way the
 * kernel sent its packets when it was bound; when that way changes, the
 * engine has to let go of it, and the next packet goes through the kernel,
 * which sends it the new way. No I/O: syncd.c reads rtnetlink, tells this
 * module, and asks the engine for what the module answers.
 *
 *   - a route changed (added, deleted, replaced, in any table): the
 *     connections sent to its network; the default route: every one;
 *   - a rule or a nexthop object changed, or an address went: every
 *     connection, since what that changed cannot be told (a route that uses
 *     a nexthop object, as FRR's do, follows it without a word of its own;
 *     the kernel takes the routes of an address away without saying so);
 *   - a neighbour took another MAC address: the connections sent to the old
 *     one. A neighbour is remembered after the kernel deleted it, since the
 *     engine may still send to it: the kernel no longer sees its packets;
 *   - the link of an interface went down (or it went away): the connections
 *     through it when it is a port of the engine; every connection for
 *     another interface, since its routes went with it, unless it is a port
 *     of a bridge, which carries no route.
 *
 * Addresses are in network byte order.
 */
#ifndef BMCHWACCEL_WATCH_H
#define BMCHWACCEL_WATCH_H

#include <stdint.h>

#define WATCH_NAME_MAX 16	/* IFNAMSIZ */
#define WATCH_PORTS_MAX 8
#define WATCH_NEIGH_MAX 65536	/* neighbours remembered; more are not */

enum watch_do {
	WATCH_NOTHING,
	WATCH_FLUSH,		/* every connection */
	WATCH_FLUSH_PORT,	/* the connections through the engine port named port */
				/* (WATCH_FLUSH of an interface: port names it too) */
	WATCH_FLUSH_ROUTE,	/* the connections sent to the network dst/len */
	WATCH_FLUSH_MAC,	/* the connections sent to the MAC address mac */
};

struct watch_act {
	enum watch_do what;
	char port[WATCH_NAME_MAX];
	uint32_t dst;
	unsigned len;
	uint8_t mac[6];
};

struct watch;

struct watch *watch_create(void);
void watch_free(struct watch *w);

/* The kernel's names of the engine's ports (eth0, eth1), as the engine gives them. */
void watch_ports(struct watch *w, const char *const *names, unsigned n);

/* An IPv4 route was added, deleted or replaced; cloned: a cached one, which routes nothing. */
enum watch_do watch_route(struct watch *w, uint32_t dst, unsigned len, int cloned,
			  struct watch_act *a);

/* An IPv4 rule was added or deleted. */
enum watch_do watch_rule(struct watch *w, struct watch_act *a);

/* A nexthop object was added, replaced or deleted. */
enum watch_do watch_nexthop(struct watch *w, struct watch_act *a);

/* An IPv4 address went away. */
enum watch_do watch_addr_gone(struct watch *w, struct watch_act *a);

/*
 * An interface as the kernel says it is now: up (administratively up with
 * its link up), bridged (it has a master), gone (deleted). The first word of
 * an interface (a dump, or a new one) only teaches the module.
 */
enum watch_do watch_link(struct watch *w, int ifindex, const char *name, int up, int bridged,
			 int gone, struct watch_act *a);

/*
 * An IPv4 neighbour of interface ifindex with the MAC address mac, or NULL
 * while it has none (being resolved, failed, deleted). The first MAC address
 * of a neighbour (a dump, or a new one) only teaches the module.
 */
enum watch_do watch_neigh(struct watch *w, int ifindex, uint32_t ip, const uint8_t *mac,
			  struct watch_act *a);

#endif
