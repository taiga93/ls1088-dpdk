/*
 * bmchwaccel-engine: forwards the accelerated connections between its ports
 * and hands everything else to the kernel (spec: Engine; ADR-0012).
 *
 *   bmchwaccel-engine EAL-ARGS -- --port NAME,WIRE,KERNEL[,MTU] ... [OPTIONS]
 *
 * --port         an engine port: the kernel's name of it (eth0), the ethdev
 *                of its cable side (dpni.X) and of its kernel side (dpni.Y),
 *                the largest IPv4 packet out of it (1500). In order: the
 *                first is port 0.
 * --conns N      connections the table holds (131072)
 * --learn-max N  learned records kept (65536)
 * --learn-ttl MS how long a learned record stays usable (10000)
 * --socket PATH  the control socket (/var/run/bmchwaccel-engine.sock)
 * --event        the workers sleep in eventdev 0 (event_dpaa2) instead of
 *                polling the ethdevs
 * --sas N        SAs of ESP the engine holds (24576: 4096 tunnels, 6 SAs
 *                each while they rekey)
 * --tunnels N    tunnels of Tunnel IPsec the engine holds, IPSEC_MAX_TUNNELS
 *                at most (and by default): fewer, for the tests
 * --tx-limit NAME,MBPS
 *                the cable side of port NAME sends at most MBPS (8 to 10000,
 *                down to a step of 8), evenly (ticket 21): for an SFP+
 *                module that brings 10G
 *                down to a slower link without pause frames, which spoils
 *                frames when bursts of 10G reach it. A device without the
 *                traffic manager of DPAA2 sends without the limit and says
 *                so.
 *
 * The main lcore serves the control socket (ctl.c) and makes the link of the
 * kernel side of each port follow the one of its wire side, so that the
 * kernel's port (dpni.Z, linked to dpni.Y) has a carrier only while the
 * cable has one. Each other lcore of the EAL is a worker w: it takes Rx
 * queue w of every ethdev (RSS spreads the flows over the queues) and sends
 * on Tx queue w. In poll mode it polls those queues; with --event, Rx queue
 * w of every ethdev feeds parallel event queue w, which only worker w
 * links, and the worker sleeps in the dequeue while there is nothing to do.
 * dpdk-pdump can capture the ports (rte_pdump). Ends on SIGTERM or SIGINT.
 *
 * ESP ("ESP ops", esp.h): with the SEC in the container (a DPSECI), each
 * worker has queue pairs of its own, whose results come back to it as
 * events of its event queue (--event) or when it polls them. Before the
 * ports start, each worker sends a packet through an outbound SA on each
 * of its queue pairs and back through the inbound one; the engine runs
 * without ESP when that fails.
 *
 * Tunnel IPsec (ipsec.h): the daemon hands over the SAs of the kernel
 * (sa-add of ctl.c). The ESP the kernel sends on an outbound SA held is
 * taken out of what the kernel sends before the core sees it, numbered
 * again on the SEC, and sent out of the wire side of the same port; the
 * ESP from the wire on an inbound SA held is taken out the same way, and
 * decrypted. What the SEC decrypted goes through the core, and the packets
 * the core puts into a tunnel go to the SEC (ipsec_tunnel()). The worker of
 * a tunnel encrypts all of its packets: the others put theirs into its ring
 * and, with --event, wake it with an event of their own (one for what they
 * hand over at once: event_dpaa2 allocates each). The daemon's session
 * closing lets go of the SAs too.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <rte_cycles.h>
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_event_eth_rx_adapter.h>
#include <rte_eventdev.h>
#include <rte_ip.h>
#include <rte_lcore.h>
#include <rte_mbuf.h>
#include <rte_ring_elem.h>
#include <rte_tm.h>
#ifdef RTE_LIB_PDUMP
#include <rte_pdump.h>
#endif
#include <rte_udp.h>

#include "engine.h"

/*
 * Per queue. On DPAA2 the Rx one is the tail drop of the queue in frames;
 * 16 queues of 512 stay under the 11264 the dpaa2 PMD warns about.
 */
#define RX_DESC 512
#define TX_DESC 512
#define MAX_CLIENTS 16
#define LINE_MAX_LEN CTL_LINE_MAX
#define EVENT_TIMEOUT_MS 100	/* longest sleep of a worker in the dequeue */
#define LINK_POLL_MS 100	/* how often the links of the wire sides are read */
#define WHOLE_MBUFS 128		/* datagrams of ESP put together at once (ipsec.h, whole) */
#define AWAY_RING 1024		/* packets into its tunnels a worker can be handed */
/*
 * --tx-limit, in Mbps: the shapers of DPAA2 go in steps of 8 Mbps (the dpaa2
 * PMD gives the MC (bytes/s / 2^20) * 8), so a limit is taken down to one;
 * below 8 the MC would get 0, which is no limit at all.
 */
#define TX_LIMIT_MIN 8
#define TX_LIMIT_MAX 10000
#define TX_LIMIT_STEP 8
/*
 * --tx-limit: the bucket of each shaper, two frames of 1500 B, and what each
 * frame takes on the cable besides its bytes (preamble, gap, FCS), which the
 * PMD gives the port's shaper only. Ticket 21: at 980 Mbps (976) no frame
 * reached a 1G PC behind a 10GBASE-T module spoiled.
 */
#define TX_LIMIT_BURST 3000
#define TX_LIMIT_OVERHEAD 24
#define TX_LIMIT_PROFILE 1	/* the shaper profile of rte_tm, for every node */
#define TX_LIMIT_ROOT 1000	/* node ids of rte_tm: above those of the Tx queues */

static volatile int quit;
static uint64_t ev_timeout;	/* EVENT_TIMEOUT_MS in ticks of the eventdev */

static struct {
	unsigned conns, learn_max, learn_ttl, sas, tunnels;
	int event;
	const char *socket;
	/* --tx-limit, as given: put on the ports once all of them are known */
	struct {
		char name[16];
		unsigned mbps;
	} limit[CORE_MAX_PORTS];
	unsigned nlimits;
} o = {
	.conns = 131072, .learn_max = 65536, .learn_ttl = 10000, .sas = 4096 * 6,
	.tunnels = IPSEC_MAX_TUNNELS,
	.socket = CTL_SOCKET,
};

static void
die(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	fprintf(stderr, "bmchwaccel-engine: ");
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

uint32_t
engine_now(const struct engine *e)
{
	return (uint32_t)(rte_get_timer_cycles() / e->ms_cycles);
}

static void
on_signal(int sig)
{
	(void)sig;
	quit = 1;
}

static uint16_t
ethdev_named(const char *name)
{
	uint16_t id;

	if (rte_eth_dev_get_port_by_name(name, &id))
		die("no ethdev %s", name);
	return id;
}

static unsigned
number(const char *opt, const char *s)
{
	char *end;
	unsigned long v = strtoul(s, &end, 10);

	if (*s == '\0' || *end != '\0' || v == 0 || v > UINT32_MAX)
		die("%s %s", opt, s);
	return (unsigned)v;
}

/* NAME,WIRE,KERNEL[,MTU] */
static void
port_parse(struct engine *e, char *arg)
{
	struct engine_port *p = &e->port[e->nports];
	char *f[4] = { NULL }, *save = NULL, *t;
	unsigned n = 0, mtu;

	if (e->nports == CORE_MAX_PORTS)
		die("more than %d ports", CORE_MAX_PORTS);
	for (t = strtok_r(arg, ",", &save); t && n < 4; t = strtok_r(NULL, ",", &save))
		f[n++] = t;
	if (n < 3 || t || strlen(f[0]) >= sizeof(p->name))
		die("--port NAME,WIRE,KERNEL[,MTU]");
	strcpy(p->name, f[0]);
	p->ethdev[CORE_WIRE] = ethdev_named(f[1]);
	p->ethdev[CORE_KERNEL] = ethdev_named(f[2]);
	mtu = f[3] ? number("--port MTU", f[3]) : 1500;
	if (mtu < 68 || mtu > 65535)
		die("--port %s: MTU %u", f[0], mtu);
	p->mtu = (uint16_t)mtu;
	e->nports++;
}

/* NAME,MBPS */
static void
tx_limit_parse(char *arg)
{
	char *mbps = strchr(arg, ',');
	unsigned v;

	if (!mbps || mbps == arg || (size_t)(mbps - arg) >= sizeof(o.limit[0].name))
		die("--tx-limit NAME,MBPS");
	*mbps++ = '\0';
	v = number("--tx-limit MBPS", mbps);
	if (v < TX_LIMIT_MIN || v > TX_LIMIT_MAX)
		die("--tx-limit %s: %u Mbps, %u to %u", arg, v, TX_LIMIT_MIN, TX_LIMIT_MAX);
	if (o.nlimits == CORE_MAX_PORTS)
		die("--tx-limit: more than %d", CORE_MAX_PORTS);
	strcpy(o.limit[o.nlimits].name, arg);
	o.limit[o.nlimits++].mbps = v;
}

static void
tx_limits_to_ports(struct engine *e)
{
	unsigned i, p;

	for (i = 0; i < o.nlimits; i++) {
		for (p = 0; p < e->nports && strcmp(e->port[p].name, o.limit[i].name); p++)
			;
		if (p == e->nports)
			die("--tx-limit %s: no such port", o.limit[i].name);
		if (e->port[p].tx_mbps)
			die("--tx-limit %s: given twice", o.limit[i].name);
		e->port[p].tx_mbps = (uint16_t)o.limit[i].mbps;
	}
}

static void
options(struct engine *e, int argc, char **argv)
{
	static const struct option lo[] = {
		{ "port", required_argument, NULL, 'p' },
		{ "conns", required_argument, NULL, 'c' },
		{ "learn-max", required_argument, NULL, 'm' },
		{ "learn-ttl", required_argument, NULL, 't' },
		{ "socket", required_argument, NULL, 's' },
		{ "event", no_argument, NULL, 'e' },
		{ "sas", required_argument, NULL, 'a' },
		{ "tunnels", required_argument, NULL, 'T' },
		{ "tx-limit", required_argument, NULL, 'L' },
		{ NULL, 0, NULL, 0 },
	};
	int c;

	while ((c = getopt_long(argc, argv, "", lo, NULL)) != -1)
		switch (c) {
		case 'p':
			port_parse(e, optarg);
			break;
		case 'c':
			o.conns = number("--conns", optarg);
			break;
		case 'm':
			o.learn_max = number("--learn-max", optarg);
			break;
		case 't':
			o.learn_ttl = number("--learn-ttl", optarg);
			break;
		case 's':
			o.socket = optarg;
			break;
		case 'e':
			o.event = 1;
			break;
		case 'a':
			o.sas = number("--sas", optarg);
			break;
		case 'T':
			o.tunnels = number("--tunnels", optarg);
			if (!o.tunnels || o.tunnels > IPSEC_MAX_TUNNELS)
				die("--tunnels: 1 to %u", IPSEC_MAX_TUNNELS);
			break;
		case 'L':
			tx_limit_parse(optarg);
			break;
		default:
			die("unknown option");
		}
	if (optind != argc || e->nports == 0)
		die("usage: bmchwaccel-engine EAL-ARGS -- --port NAME,WIRE,KERNEL[,MTU] ...");
	tx_limits_to_ports(e);
}

static void
ethdev_setup(struct engine *e, uint16_t id, struct rte_mempool *mp)
{
	struct rte_eth_conf conf = { 0 };
	struct rte_eth_dev_info info;
	uint16_t q, nq = (uint16_t)e->nworkers;
	int ret;

	ret = rte_eth_dev_info_get(id, &info);
	if (ret)
		die("ethdev %u: info: %s", id, rte_strerror(-ret));
	if (nq > info.max_rx_queues || nq > info.max_tx_queues)
		die("ethdev %u: %u workers, but %u Rx and %u Tx queues", id, nq,
		    info.max_rx_queues, info.max_tx_queues);
	if (nq > 1) {
		/* a flow always reaches the same worker, which keeps its packets in order */
		conf.rxmode.mq_mode = RTE_ETH_MQ_RX_RSS;
		conf.rx_adv_conf.rss_conf.rss_hf = info.flow_type_rss_offloads &
			(RTE_ETH_RSS_IP | RTE_ETH_RSS_TCP | RTE_ETH_RSS_UDP);
	}
	ret = rte_eth_dev_configure(id, nq, nq, &conf);
	if (ret)
		die("ethdev %u: configure %u queues: %s", id, nq, rte_strerror(-ret));
	for (q = 0; q < nq; q++) {
		ret = rte_eth_rx_queue_setup(id, q, RX_DESC, rte_eth_dev_socket_id(id), NULL, mp);
		if (ret)
			die("ethdev %u: Rx queue %u: %s", id, q, rte_strerror(-ret));
		ret = rte_eth_tx_queue_setup(id, q, TX_DESC, rte_eth_dev_socket_id(id), NULL);
		if (ret)
			die("ethdev %u: Tx queue %u: %s", id, q, rte_strerror(-ret));
	}
}

/*
 * --tx-limit of port p, before its cable side starts: the traffic manager of
 * DPAA2 shapes the port (its LNI, level 0) and each of its channels (level
 * 1) at the rate. The port alone is not enough: its shaper is taken but has
 * no effect while the DPNI has several channels (ticket 21); with the
 * channels alone, the Tx queues of all workers would still add up past the
 * rate. The rate is given in the PMD's units (see TX_LIMIT_STEP), so that
 * the MC gets the limit taken down to a step.
 */
static void
tx_limit(const struct engine_port *ep)
{
	uint16_t id = ep->ethdev[CORE_WIRE];
	unsigned mbps = ep->tx_mbps / TX_LIMIT_STEP * TX_LIMIT_STEP;
	struct rte_tm_shaper_params sp = {
		.committed = { .rate = (uint64_t)mbps / 8 << 20, .size = TX_LIMIT_BURST },
		.pkt_length_adjust = TX_LIMIT_OVERHEAD,
	};
	struct rte_tm_node_params np = { .shaper_profile_id = TX_LIMIT_PROFILE };
	struct rte_tm_level_capabilities lc;
	struct rte_tm_error err = { 0 };
	unsigned c, channels = 0;
	int ret;

	ret = rte_tm_level_capabilities_get(id, 1, &lc, &err);
	if (!ret) {
		channels = lc.n_nodes_max;
		ret = rte_tm_shaper_profile_add(id, TX_LIMIT_PROFILE, &sp, &err);
	}
	if (!ret)
		ret = rte_tm_node_add(id, TX_LIMIT_ROOT, RTE_TM_NODE_ID_NULL, 0, 1, 0, &np, &err);
	for (c = 0; !ret && c < channels; c++)
		ret = rte_tm_node_add(id, TX_LIMIT_ROOT + 1 + c, TX_LIMIT_ROOT, 0, 1, 1, &np, &err);
	if (!ret)
		ret = rte_tm_hierarchy_commit(id, 1, &err);
	if (ret)
		printf("%s sends without its limit of %u Mbps: %s\n", ep->name, ep->tx_mbps,
		       err.message ? err.message : rte_strerror(-ret));
	else if (mbps != ep->tx_mbps)
		printf("%s sends at most %u Mbps (%u channels; %u asked, in steps of %u)\n",
		       ep->name, mbps, channels, ep->tx_mbps, TX_LIMIT_STEP);
	else
		printf("%s sends at most %u Mbps (%u channels)\n", ep->name, mbps, channels);
}

static void
ethdev_start(uint16_t id)
{
	int ret = rte_eth_dev_start(id);

	if (ret)
		die("ethdev %u: start: %s", id, rte_strerror(-ret));
	/*
	 * Every frame: on the cable side the kernel filters by MAC (dpaa2-eth
	 * on dpni.Z), and the kernel side passes what the kernel sends to any
	 * MAC, the gateway's or a host's.
	 */
	rte_eth_promiscuous_enable(id);
}

/*
 * --event: worker w links event queue w, which Rx queue w of every ethdev
 * feeds. Parallel queues: a flow stays in one Rx queue, so in one worker,
 * and in order without the cost of atomic or ordered scheduling (ticket 01).
 */
static void
event_setup(struct engine *e)
{
	struct rte_event_dev_info info;
	struct rte_event_dev_config c = { 0 };
	struct rte_event_queue_conf q;
	struct rte_event_port_conf pc;
	struct rte_event_eth_rx_adapter_queue_conf qc = { 0 };
	unsigned p, s, w;
	uint8_t qid;
	int ret;

	if (rte_event_dev_count() < 1)
		die("--event: no eventdev (--vdev=event_dpaa2, with a DPCI in the container)");
	rte_event_dev_info_get(0, &info);
	c.nb_event_queues = (uint8_t)e->nworkers;
	c.nb_event_ports = (uint8_t)e->nworkers;
	c.nb_events_limit = info.max_num_events;
	c.nb_event_queue_flows = info.max_event_queue_flows;
	c.nb_event_port_dequeue_depth = info.max_event_port_dequeue_depth;
	c.nb_event_port_enqueue_depth = info.max_event_port_enqueue_depth;
	c.event_dev_cfg = RTE_EVENT_DEV_CFG_PER_DEQUEUE_TIMEOUT;
	ret = rte_event_dev_configure(0, &c);
	if (ret)
		die("eventdev: configure %u queues: %s", e->nworkers, rte_strerror(-ret));
	rte_event_queue_default_conf_get(0, 0, &q);
	q.event_queue_cfg = 0;
	q.schedule_type = RTE_SCHED_TYPE_PARALLEL;
	for (w = 0; w < e->nworkers; w++) {
		qid = (uint8_t)w;
		ret = rte_event_queue_setup(0, qid, &q);
		if (!ret)
			ret = rte_event_port_setup(0, (uint8_t)w, NULL);
		if (ret)
			die("eventdev: queue or port %u: %s", w, rte_strerror(-ret));
		if (rte_event_port_link(0, (uint8_t)w, &qid, NULL, 1) != 1)
			die("eventdev: link port %u to queue %u", w, w);
	}
	ret = rte_event_dequeue_timeout_ticks(0, (uint64_t)EVENT_TIMEOUT_MS * 1000000, &ev_timeout);
	if (ret)
		die("eventdev: timeout: %s", rte_strerror(-ret));

	rte_event_port_default_conf_get(0, 0, &pc);
	ret = rte_event_eth_rx_adapter_create(0, 0, &pc);
	if (ret)
		die("eventdev: Rx adapter: %s", rte_strerror(-ret));
	qc.ev.sched_type = RTE_SCHED_TYPE_PARALLEL;
	qc.ev.priority = RTE_EVENT_DEV_PRIORITY_NORMAL;
	for (p = 0; p < e->nports; p++)
		for (s = 0; s < 2; s++)
			for (w = 0; w < e->nworkers; w++) {
				qc.ev.queue_id = (uint8_t)w;
				ret = rte_event_eth_rx_adapter_queue_add(0, e->port[p].ethdev[s],
									 (int32_t)w, &qc);
				if (ret)
					die("eventdev: Rx queue %u of ethdev %u: %s", w,
					    e->port[p].ethdev[s], rte_strerror(-ret));
			}
	ret = rte_event_dev_start(0);
	if (ret)
		die("eventdev: start: %s", rte_strerror(-ret));
}

static void
send_all(struct engine *e, unsigned w, struct core_out *out)
{
	unsigned p, s;

	for (p = 0; p < e->nports; p++)
		for (s = 0; s < 2; s++) {
			uint16_t n = out->n[p][s], sent;

			if (!n)
				continue;
			sent = rte_eth_tx_burst(e->port[p].ethdev[s], (uint16_t)w,
						out->pkts[p][s], n);
			if (sent < n)
				rte_pktmbuf_free_bulk(&out->pkts[p][s][sent], n - sent);
		}
}

struct worker_arg {
	struct engine *e;
	unsigned w;
	int ok;			/* the self-test of ESP passed */
};

/*
 * Packets into a tunnel another worker encrypts: into its ring, and with
 * --event an event that wakes it if it sleeps.
 */
static void
hand_over(struct engine *e, unsigned w, const struct ipsec_away *a, unsigned n)
{
	uint8_t woken[CORE_MAX_WORKERS] = { 0 };
	unsigned i;

	for (i = 0; i < n; i++) {
		unsigned to = a[i].worker;
		struct core_tun t = a[i].t;

		if (to >= e->nworkers || rte_ring_enqueue_elem(e->away[to], &t, sizeof(t)) != 0) {
			rte_pktmbuf_free(a[i].t.m);
			continue;
		}
		if (o.event && !woken[to]) {
			struct rte_event ev = {
				.event_type = RTE_EVENT_TYPE_CPU,
				.queue_id = (uint8_t)to,
				.op = RTE_EVENT_OP_NEW,
				.sched_type = RTE_SCHED_TYPE_PARALLEL,
				.priority = RTE_EVENT_DEV_PRIORITY_NORMAL,
			};

			/* none: it finds them when it wakes anyway, within EVENT_TIMEOUT_MS */
			rte_event_enqueue_new_burst(0, (uint8_t)w, &ev, 1);
			woken[to] = 1;
		}
	}
}

/* What ipsec.c sends: out of each side of each port, and to other workers. */
static void
send_ipsec(struct engine *e, unsigned w, struct ipsec_out *out)
{
	unsigned p, s;

	if (out->naway)
		hand_over(e, w, out->away, out->naway);

	for (p = 0; p < e->nports; p++)
		for (s = 0; s < 2; s++) {
			uint16_t n = out->n[p][s], sent = 0;

			while (sent < n) {
				uint16_t k = rte_eth_tx_burst(e->port[p].ethdev[s], (uint16_t)w,
							      out->pkts[p][s] + sent, n - sent);

				if (!k)
					break;
				sent += k;
			}
			if (sent < n)
				rte_pktmbuf_free_bulk(&out->pkts[p][s][sent], n - sent);
		}
}

/* What came back from the SEC: to ipsec.c, which hands it on or sends it. */
static void
esp_back(struct engine *e, unsigned w, const struct esp_result *r, unsigned n)
{
	struct ipsec_out out;
	unsigned i;

	if (e->ipsec) {
		ipsec_done(e->ipsec, w, r, n, engine_now(e), &out);
		send_ipsec(e, w, &out);
		return;
	}
	for (i = 0; i < n; i++) {
		rte_pktmbuf_free(r[i].job.m);
		rte_pktmbuf_free(r[i].job.dst);
	}
}

/* The results of a backend that does not send them as events. */
static void
esp_poll_back(struct engine *e, unsigned w)
{
	struct esp_result r[ESP_BURST];

	if (e->esp && !esp_dev(e->esp)->events)
		esp_back(e, w, r, esp_poll(e->esp, w, r, ESP_BURST));
}

/*
 * The ESP the kernel sends on an SA held, and the ESP from the wire on one,
 * go to the SEC; what is left, to the core.
 */
static unsigned
take_esp(struct engine *e, unsigned w, struct rte_mbuf **pkts, unsigned n)
{
	struct ipsec_out out;

	if (!e->ipsec)
		return n;
	n = ipsec_kernel(e->ipsec, w, pkts, n, rte_get_timer_cycles(), &out);
	send_ipsec(e, w, &out);
	return ipsec_wire(e->ipsec, w, pkts, n);
}

/* What core_rx() sorted: out of the ports, and into tunnels through the SEC. */
static void
send_core(struct engine *e, unsigned w, struct core_out *out)
{
	struct ipsec_out io;

	if (out->ntun) {
		ipsec_tunnel(e->ipsec, w, out->tun, out->ntun, &io);
		send_ipsec(e, w, &io);
	}
	send_all(e, w, out);
}

/* The packets into its tunnels the other workers handed to worker w. */
static void
take_away(struct engine *e, unsigned w)
{
	struct core_tun t[CORE_BURST];
	struct ipsec_out io;
	unsigned n;

	if (!e->ipsec)
		return;
	while ((n = rte_ring_dequeue_burst_elem(e->away[w], t, sizeof(t[0]), CORE_BURST, NULL))) {
		ipsec_tunnel(e->ipsec, w, t, n, &io);
		send_ipsec(e, w, &io);
		if (n < CORE_BURST)
			break;
	}
}

static void
poll_loop(struct engine *e, unsigned w)
{
	struct rte_mbuf *pkts[CORE_BURST];
	struct core_out out;
	unsigned p, s;

	while (!quit) {
		for (p = 0; p < e->nports; p++)
			for (s = 0; s < 2; s++) {
				uint16_t n = rte_eth_rx_burst(e->port[p].ethdev[s], (uint16_t)w,
							      pkts, CORE_BURST);

				n = (uint16_t)take_esp(e, w, pkts, n);
				if (!n)
					continue;
				core_rx(e->core, w, pkts, n, engine_now(e), &out);
				send_core(e, w, &out);
			}
		esp_poll_back(e, w);
		take_away(e, w);
		core_worker_quiescent(e->core, w);
	}
}

/*
 * The Rx callbacks of the ethdevs, such as the one of dpdk-pdump: poll mode
 * runs them in rte_eth_rx_burst(), but events come from the hardware without
 * it. The packets of ethdev d in the burst are Rx queue w of d. A callback
 * that drops packets is not supported; dpdk-pdump only copies them.
 */
static void
rx_callbacks(struct engine *e, unsigned w, struct rte_mbuf **pkts, uint16_t n)
{
#ifdef RTE_ETHDEV_RXTX_CALLBACKS
	struct rte_mbuf *m[CORE_BURST];
	unsigned p, s;
	uint16_t i, k;

	for (p = 0; p < e->nports; p++)
		for (s = 0; s < 2; s++) {
			uint16_t d = e->port[p].ethdev[s];
			void *cb = __atomic_load_n((void **)&rte_eth_fp_ops[d].rxq.clbk[w],
						   __ATOMIC_RELAXED);

			if (likely(cb == NULL))
				continue;
			for (i = k = 0; i < n; i++)
				if (pkts[i]->port == d)
					m[k++] = pkts[i];
			if (k)
				rte_eth_call_rx_callbacks(d, (uint16_t)w, m, k, k, cb);
		}
#else
	(void)e;
	(void)w;
	(void)pkts;
	(void)n;
#endif
}

static void
event_loop(struct engine *e, unsigned w)
{
	struct rte_event ev[CORE_BURST];
	struct rte_mbuf *pkts[CORE_BURST];
	void *ops[CORE_BURST];
	struct esp_result r[CORE_BURST];
	struct core_out out;
	uint16_t n, i, np, nc;

	while (!quit) {
		/* it may sleep in the dequeue: the control thread does not wait for it */
		core_worker_offline(e->core, w);
		n = rte_event_dequeue_burst(0, (uint8_t)w, ev, CORE_BURST, ev_timeout);
		core_worker_online(e->core, w);
		esp_poll_back(e, w);
		take_away(e, w);
		if (!n)
			continue;
		/* RTE_EVENT_TYPE_CPU: another worker woke it for its ring, read above */
		for (i = np = nc = 0; i < n; i++)
			if (ev[i].event_type == RTE_EVENT_TYPE_CRYPTODEV)
				ops[nc++] = ev[i].event_ptr;
			else if (ev[i].event_type != RTE_EVENT_TYPE_CPU)
				pkts[np++] = ev[i].mbuf;
		/* none without ESP, but one that failed its self-test and came back late */
		if (nc && e->esp)
			esp_back(e, w, r, esp_events(e->esp, w, ops, nc, r));
		if (!np)
			continue;
		rx_callbacks(e, w, pkts, np);
		np = (uint16_t)take_esp(e, w, pkts, np);
		if (!np)
			continue;
		core_rx(e->core, w, pkts, np, engine_now(e), &out);
		send_core(e, w, &out);
	}
}

static int
worker(void *arg)
{
	struct worker_arg *a = arg;

	core_worker_start(a->e->core, a->w);
	if (o.event)
		event_loop(a->e, a->w);
	else
		poll_loop(a->e, a->w);
	core_worker_stop(a->e->core, a->w);
	return 0;
}

/*
 * The self-test of ESP. SA 2q encrypts into ESP in UDP, as the VPN page
 * makes tunnels (aes256-cbc, hmac-sha256-128), on queue pair q of each
 * worker; SA 2q + 1, its inbound twin, decrypts.
 */
#define TEST_SA(q, dir) (2 * (q) + (dir))

static struct rte_mempool *test_mp;	/* the packets of the self-test */

static void
test_conf(struct esp_sa_conf *c, unsigned q, int dir)
{
	unsigned i;

	*c = (struct esp_sa_conf){
		.dir = (uint8_t)dir,
		.cipher = ESP_AES_CBC,
		.auth = ESP_HMAC_SHA256_128,
		.key_len = 32,
		.auth_key_len = 32,
		.spi = 0xffff0000u + q,
		.src = rte_cpu_to_be_32(RTE_IPV4(192, 0, 2, 1)),
		.dst = rte_cpu_to_be_32(RTE_IPV4(192, 0, 2, 2)),
		.sport = 4500,
		.dport = 4500,
		.lane = q,
	};
	for (i = 0; i < 32; i++) {
		c->key[i] = (uint8_t)(0x10 + i);
		c->auth_key[i] = (uint8_t)(0x40 + i);
	}
}

/* A UDP packet of 100 bytes from 198.51.100.1 to 198.51.100.2. */
static struct rte_mbuf *
test_packet(unsigned q)
{
	struct rte_mbuf *m = rte_pktmbuf_alloc(test_mp);
	struct rte_ipv4_hdr *ip;
	uint8_t *p;
	unsigned i;

	if (!m)
		return NULL;
	p = (uint8_t *)rte_pktmbuf_append(m, 100);
	for (i = 0; i < 100; i++)
		p[i] = (uint8_t)(i + q);
	ip = (struct rte_ipv4_hdr *)p;
	*ip = (struct rte_ipv4_hdr){
		.version_ihl = RTE_IPV4_VHL_DEF,
		.total_length = rte_cpu_to_be_16(100),
		.time_to_live = 64,
		.next_proto_id = IPPROTO_UDP,
		.src_addr = rte_cpu_to_be_32(RTE_IPV4(198, 51, 100, 1)),
		.dst_addr = rte_cpu_to_be_32(RTE_IPV4(198, 51, 100, 2)),
	};
	ip->hdr_checksum = rte_ipv4_cksum(ip);
	*(struct rte_udp_hdr *)(ip + 1) = (struct rte_udp_hdr){
		.src_port = rte_cpu_to_be_16(5000),
		.dst_port = rte_cpu_to_be_16(5001),
		.dgram_len = rte_cpu_to_be_16(80),
	};
	return m;
}

/* One job of worker w through the SEC, back the way results come; 1: ok. */
static int
test_job(struct engine *e, unsigned w, struct esp_job *j, struct esp_result *r)
{
	uint64_t end = rte_get_timer_cycles() + rte_get_timer_hz();

	if (esp_submit(e->esp, w, j, 1))
		return 0;
	while (rte_get_timer_cycles() < end) {
		struct rte_event ev;

		if (!esp_dev(e->esp)->events) {
			if (esp_poll(e->esp, w, r, 1))
				return r->ok;
		} else if (rte_event_dequeue_burst(0, (uint8_t)w, &ev, 1, 0)) {
			/* nothing else comes before the ports start */
			if (ev.event_type == RTE_EVENT_TYPE_CRYPTODEV)
				return esp_events(e->esp, w, &ev.event_ptr, 1, r) && r->ok;
			rte_pktmbuf_free(ev.mbuf);
		}
	}
	return 0;
}

static int
test_worker(void *arg)
{
	struct worker_arg *a = arg;
	unsigned q;

	a->ok = 1;
	for (q = 0; q < esp_dev(a->e->esp)->nqp && a->ok; q++) {
		struct rte_mbuf *m = test_packet(q), *want = test_packet(q);
		struct esp_job j = { .m = m, .sa = TEST_SA(q, ESP_OUT) };
		struct esp_result r = { 0 };

		if (!m || !want) {
			rte_pktmbuf_free(m);
			rte_pktmbuf_free(want);
			a->ok = 0;
			break;
		}
		a->ok = test_job(a->e, a->w, &j, &r);
		if (a->ok) {
			j = (struct esp_job){ .m = r.job.m, .sa = TEST_SA(q, ESP_IN) };
			a->ok = test_job(a->e, a->w, &j, &r) && r.job.m->pkt_len == 100 &&
				!memcmp(rte_pktmbuf_mtod(r.job.m, void *),
					rte_pktmbuf_mtod(want, void *), 100);
			m = r.job.m;
		}
		/* a job that did not come back keeps its mbuf: left in test_mp */
		if (a->ok)
			rte_pktmbuf_free(m);
		rte_pktmbuf_free(want);
	}
	return 0;
}

/*
 * ESP on the SEC of the container, before the ports start; none when the
 * container has no SEC or it fails its self-test.
 */
static void
esp_setup(struct engine *e, struct worker_arg *wa)
{
	struct esp_dev_params dp = {
		.nworkers = e->nworkers, .max_sa = o.sas, .events = o.event,
		.socket_id = (int)rte_socket_id(),
	};
	struct esp_params ep = { .nworkers = e->nworkers, .max_sa = o.sas,
				 .socket_id = (int)rte_socket_id() };
	struct esp_dev *dev;
	struct esp_sa_conf c;
	const char *why = "no memory";
	unsigned lcore, w, q, nqp;
	int ok = 1;

	e->max_sa = o.sas;
	e->esp_state = "none";
	dev = esp_dev_open(&dp, &why);
	if (!dev) {
		printf("no ESP: %s\n", why);
		return;
	}
	nqp = dev->nqp;
	e->esp = esp_create(&ep, dev);
	if (!e->esp) {
		dev->ops->free(dev);
		printf("no ESP: no memory for %u SAs\n", o.sas);
		return;
	}
	e->esp_state = "failed";
	test_mp = rte_pktmbuf_pool_create("esp_test", 4 * e->nworkers * nqp + 64, 0, 0,
					  RTE_MBUF_DEFAULT_BUF_SIZE, (int)rte_socket_id());
	for (q = 0; q < nqp && ok; q++) {
		test_conf(&c, q, ESP_OUT);
		ok = test_mp && !esp_sa_add(e->esp, TEST_SA(q, ESP_OUT), &c);
		test_conf(&c, q, ESP_IN);
		ok = ok && !esp_sa_add(e->esp, TEST_SA(q, ESP_IN), &c);
	}
	if (ok) {
		w = 0;
		RTE_LCORE_FOREACH_WORKER(lcore) {
			wa[w] = (struct worker_arg){ e, w, 0 };
			rte_eal_remote_launch(test_worker, &wa[w], lcore);
			w++;
		}
		rte_eal_mp_wait_lcore();
		for (w = 0; w < e->nworkers; w++)
			ok = ok && wa[w].ok;
	}
	for (q = 0; q < nqp && ok; q++)
		ok = !esp_sa_del(e->esp, TEST_SA(q, ESP_OUT)) &&
		     !esp_sa_del(e->esp, TEST_SA(q, ESP_IN));
	if (!ok) {
		printf("no ESP: %s failed its self-test\n", dev->name);
		esp_free(e->esp);
		e->esp = NULL;
		return;
	}
	e->esp_state = "ok";
	rte_mempool_free(test_mp);
	test_mp = NULL;
	printf("ESP on %s: %u queue pairs per worker, results %s, self-test passed\n",
	       dev->name, nqp, dev->events ? "as events" : "polled");
}

/*
 * The kernel's port of an engine port (dpni.Z) has a carrier while the
 * kernel side (dpni.Y) it is linked to is up: the kernel side is up only
 * while the cable of the wire side has a link, so that netifd, mwan3 and
 * bmcMultiWAN see the cable as they do without the engine. Software ports
 * cannot set their link; they are left as they are.
 */
static void
links_follow(struct engine *e)
{
	unsigned p;

	for (p = 0; p < e->nports; p++) {
		struct engine_port *ep = &e->port[p];
		struct rte_eth_link l;
		int up, ret;

		if (rte_eth_link_get_nowait(ep->ethdev[CORE_WIRE], &l))
			continue;
		up = l.link_status == RTE_ETH_LINK_UP;
		if (up == ep->kernel_link)
			continue;
		ret = up ? rte_eth_dev_set_link_up(ep->ethdev[CORE_KERNEL]) :
			   rte_eth_dev_set_link_down(ep->ethdev[CORE_KERNEL]);
		if (ret && ret != -ENOTSUP) {
			/* tried again at the next poll; said once */
			if (ep->link_failed != up + 1)
				printf("%s: the kernel's port could not follow the cable %s: %s\n",
				       ep->name, up ? "up" : "down", rte_strerror(-ret));
			ep->link_failed = up + 1;
			continue;
		}
		ep->link_failed = 0;
		if (ep->kernel_link >= 0 || !up)
			printf("%s: cable %s\n", ep->name, up ? "up" : "down");
		ep->kernel_link = (int8_t)up;
	}
	fflush(stdout);
}

/* The control socket. */

struct client {
	int fd;
	size_t len;
	char line[LINE_MAX_LEN];
};

static int
listen_on(const char *path)
{
	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	int fd;

	if (strlen(path) >= sizeof(sa.sun_path))
		die("socket path too long: %s", path);
	strcpy(sa.sun_path, path);
	fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
	if (fd < 0)
		die("socket: %s", strerror(errno));
	unlink(path);
	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) || chmod(path, 0600) || listen(fd, 8))
		die("%s: %s", path, strerror(errno));
	return fd;
}

static int
write_all(int fd, const char *s, size_t n)
{
	while (n) {
		ssize_t k = send(fd, s, n, MSG_NOSIGNAL);

		if (k < 0 && errno == EINTR)
			continue;
		if (k < 0 && errno == EAGAIN) {
			struct pollfd pf = { .fd = fd, .events = POLLOUT };

			if (poll(&pf, 1, 1000) <= 0)
				return -1;
			continue;
		}
		if (k <= 0)
			return -1;
		s += k;
		n -= (size_t)k;
	}
	return 0;
}

/* Reads what the client sent and answers its complete lines; -1: close it. */
static int
client_read(struct engine *e, struct client *cl, struct buf *out)
{
	char buf[1024];
	ssize_t n = recv(cl->fd, buf, sizeof(buf), 0);
	ssize_t i;

	if (n < 0 && (errno == EAGAIN || errno == EINTR))
		return 0;
	if (n <= 0)
		return -1;
	for (i = 0; i < n; i++) {
		if (buf[i] != '\n') {
			if (cl->len < sizeof(cl->line) - 1)
				cl->line[cl->len++] = buf[i];
			continue;
		}
		cl->line[cl->len] = '\0';
		cl->len = 0;
		out->len = 0;
		ctl_request(e, cl->fd, cl->line, out);
		if (write_all(cl->fd, out->s, out->len))
			return -1;
	}
	return 0;
}

/*
 * The session of the daemon closed: it stopped or died. Nobody would take a
 * connection back when it ends or its route changes, so every connection
 * goes through the kernel again; a daemon that starts hands them over anew.
 */
static void
daemon_gone(struct engine *e)
{
	e->daemon = -1;
	printf("the daemon's session closed: %u connections go through the kernel again\n",
	       core_flush(e->core, engine_now(e)));
	/* nobody would write the engine's numbers into the kernel's SAs any more */
	if (e->ipsec && ipsec_sa_count(e->ipsec))
		printf("the daemon's session closed: %u keys of Tunnel IPsec go through the kernel again\n",
		       ipsec_sa_flush(e->ipsec, engine_now(e), NULL, NULL, NULL));
	fflush(stdout);
}

static void
control(struct engine *e, int lfd)
{
	struct client cl[MAX_CLIENTS];
	struct pollfd pf[MAX_CLIENTS + 1];
	struct buf out = { 0 };
	char hello[32];
	unsigned n = 0, i;
	uint32_t links_at = engine_now(e);

	snprintf(hello, sizeof(hello), CTL_GREETING "\n", ENGINE_PROTOCOL);
	while (!quit) {
		pf[0] = (struct pollfd){ .fd = lfd, .events = POLLIN };
		for (i = 0; i < n; i++)
			pf[i + 1] = (struct pollfd){ .fd = cl[i].fd, .events = POLLIN };
		poll(pf, n + 1, 10);
		for (i = 0; i < n; i++)
			if (pf[i + 1].revents && client_read(e, &cl[i], &out)) {
				if (cl[i].fd == e->daemon)
					daemon_gone(e);
				close(cl[i].fd);
				cl[i] = cl[--n];
				pf[i + 1] = pf[n + 1];
				i--;
			}
		if (pf[0].revents & POLLIN) {
			int fd = accept4(lfd, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);

			if (fd >= 0 && (n == MAX_CLIENTS || write_all(fd, hello, strlen(hello)))) {
				close(fd);
			} else if (fd >= 0) {
				cl[n].fd = fd;
				cl[n++].len = 0;
			}
		}
		core_poll(e->core, engine_now(e));
		if (e->ipsec)
			ipsec_poll(e->ipsec);
		if ((uint32_t)(engine_now(e) - links_at) >= LINK_POLL_MS) {
			links_at = engine_now(e);
			links_follow(e);
		}
	}
	for (i = 0; i < n; i++)
		close(cl[i].fd);
	free(out.s);
}

int
main(int argc, char **argv)
{
	static struct engine e;
	struct worker_arg wa[CORE_MAX_WORKERS];
	struct core_params cp = { 0 };
	struct rte_mempool *mp;
	unsigned lcore, p, s, w, nmbufs;
	int ret, lfd;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		die("EAL: %s", rte_strerror(rte_errno));
	argc -= ret;
	argv += ret;
	options(&e, argc, argv);
	e.nworkers = rte_lcore_count() - 1;
	if (e.nworkers == 0 || e.nworkers > CORE_MAX_WORKERS)
		die("1 to %d worker lcores besides the main one", CORE_MAX_WORKERS);
	e.ms_cycles = rte_get_timer_hz() / 1000;
	e.daemon = -1;

	/*
	 * The descriptors of every queue, plus what is in flight in the
	 * workers, plus ESP: what the queue pairs hold, fragments being put
	 * together. The private area holds what ipsec.c keeps of a packet the
	 * SEC has.
	 */
	nmbufs = 2 * e.nports * e.nworkers * (RX_DESC + TX_DESC) + e.nworkers * 2 * CORE_BURST *
		 2 * CORE_MAX_PORTS + 4096 + e.nworkers * (ESP_WAIT_MAX + 256) + 1024;
	mp = rte_pktmbuf_pool_create("engine", nmbufs, 256, IPSEC_PRIV_SIZE,
				     RTE_MBUF_DEFAULT_BUF_SIZE, (int)rte_socket_id());
	if (!mp)
		die("mbuf pool of %u: %s", nmbufs, rte_strerror(rte_errno));
	for (p = 0; p < e.nports; p++)
		for (s = 0; s < 2; s++)
			ethdev_setup(&e, e.port[p].ethdev[s], mp);
	if (o.event)
		event_setup(&e);
	esp_setup(&e, wa);
	for (p = 0; p < e.nports; p++)
		if (e.port[p].tx_mbps)
			tx_limit(&e.port[p]);
	fflush(stdout);
	for (p = 0; p < e.nports; p++) {
		for (s = 0; s < 2; s++)
			ethdev_start(e.port[p].ethdev[s]);
		e.port[p].kernel_link = -1;
	}
	/* the kernel side is up from its start: down at once when the cable is */
	links_follow(&e);
	if (o.event) {
		ret = rte_event_eth_rx_adapter_start(0);
		if (ret)
			die("eventdev: start the Rx adapter: %s", rte_strerror(-ret));
	}
#ifdef RTE_LIB_PDUMP
	/* none without the files of a primary process (--no-shconf): no capture then */
	if (rte_pdump_init())
		printf("no capture with dpdk-pdump: %s\n", rte_strerror(rte_errno));
#endif

	cp.nports = e.nports;
	for (p = 0; p < e.nports; p++)
		cp.mtu[p] = e.port[p].mtu;
	cp.nworkers = e.nworkers;
	cp.max_conns = o.conns;
	cp.learn_max = o.learn_max;
	cp.learn_ttl = o.learn_ttl;
	cp.socket_id = (int)rte_socket_id();
	e.core = core_create(&cp);
	if (!e.core)
		die("no memory for the table of %u connections", o.conns);
	for (p = 0; p < e.nports; p++)
		for (s = 0; s < 2; s++)
			core_map_ethdev(e.core, e.port[p].ethdev[s], p, (int)s);
	if (e.esp) {
		struct ipsec_params xp = {
			.nworkers = e.nworkers, .nports = e.nports, .max_tunnels = o.tunnels,
			.max_sa = o.sas, .core = e.core, .mp = mp,
			.socket_id = (int)rte_socket_id(),
		};
		struct rte_mempool *whole;

		/* the ESP of large packets without DF, put together: rare (spec-ipsec) */
		whole = rte_pktmbuf_pool_create("ipsec_whole", WHOLE_MBUFS, 0, IPSEC_PRIV_SIZE,
						IPSEC_WHOLE_SIZE, (int)rte_socket_id());
		if (!whole)
			die("mbuf pool of %u large datagrams: %s", WHOLE_MBUFS,
			    rte_strerror(rte_errno));
		xp.whole = whole;

		for (p = 0; p < e.nports; p++)
			xp.mtu[p] = e.port[p].mtu;
		e.ipsec = ipsec_create(&xp, e.esp);
		if (!e.ipsec)
			die("no memory for the keys of %u tunnels of Tunnel IPsec", o.tunnels);
		for (p = 0; p < e.nports; p++) {
			ipsec_map_kernel(e.ipsec, e.port[p].ethdev[CORE_KERNEL], p);
			ipsec_map_wire(e.ipsec, e.port[p].ethdev[CORE_WIRE], p);
		}
		for (w = 0; w < e.nworkers; w++) {
			char name[RTE_RING_NAMESIZE];

			snprintf(name, sizeof(name), "away%u", w);
			e.away[w] = rte_ring_create_elem(name, sizeof(struct core_tun), AWAY_RING,
							 (int)rte_socket_id(), RING_F_SC_DEQ);
			if (!e.away[w])
				die("no memory for the ring of worker %u", w);
		}
	}

	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	lfd = listen_on(o.socket);
	w = 0;
	RTE_LCORE_FOREACH_WORKER(lcore) {
		wa[w] = (struct worker_arg){ &e, w, 0 };
		rte_eal_remote_launch(worker, &wa[w], lcore);
		w++;
	}
	control(&e, lfd);
	rte_eal_mp_wait_lcore();
	close(lfd);
	unlink(o.socket);
#ifdef RTE_LIB_PDUMP
	rte_pdump_uninit();
#endif
	ipsec_free(e.ipsec);
	esp_free(e.esp);
	if (o.event) {
		rte_event_eth_rx_adapter_stop(0);
		rte_event_dev_stop(0);
	}
	for (p = 0; p < e.nports; p++)
		for (s = 0; s < 2; s++)
			rte_eth_dev_stop(e.port[p].ethdev[s]);
	core_free(e.core);
	rte_eal_cleanup();
	return 0;
}
