/*
 * bmchwaccel-engine: the ports, the workers and the control socket around
 * the per-packet core (core.h).
 */
#ifndef BMCHWACCEL_ENGINE_H
#define BMCHWACCEL_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#include "core.h"
#include "ctl.h"
#include "esp.h"
#include "ipsec.h"

struct engine_port {
	char name[16];		/* the kernel's name of the port: eth0 */
	uint16_t ethdev[2];	/* of its CORE_WIRE and CORE_KERNEL side */
	uint16_t mtu;
	uint16_t tx_mbps;	/* the most its cable side sends (--tx-limit), 0: no limit */
	int8_t kernel_link;	/* the link last given to the kernel side; -1: none yet */
	int8_t link_failed;	/* 1 + the link that could not be given, 0: none */
};

struct engine {
	struct core *core;
	unsigned nports;
	struct engine_port port[CORE_MAX_PORTS];
	unsigned nworkers;
	uint64_t ms_cycles;	/* timer cycles in a millisecond */
	struct esp *esp;	/* ESP on the SEC; NULL: none (esp_state says why) */
	struct ipsec *ipsec;	/* the SAs of the kernel held, over esp; NULL without it */
	/* of each worker: the packets into a tunnel it encrypts, from the others (ipsec.h) */
	struct rte_ring *away[CORE_MAX_WORKERS];
	const char *esp_state;	/* ok, none (no SEC), failed (it did not pass its test) */
	unsigned max_sa;
	int daemon;		/* the session that claimed the engine (claim), -1: none */
	int session;		/* the session of the request being run */
};

uint32_t engine_now(const struct engine *e);

/* A reply being written: grows as needed. */
struct buf {
	char *s;
	size_t len, size;
};

void buf_printf(struct buf *b, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

/*
 * Runs one request line of the control protocol from the session (any
 * number that names it while it is open); the reply goes to out.
 */
void ctl_request(struct engine *e, int session, char *line, struct buf *out);

#endif
