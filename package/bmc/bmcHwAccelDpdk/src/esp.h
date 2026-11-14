/*
 * "ESP ops": the seam between the engine and what does ESP for it
 * (spec-ipsec: Engine; Testing Decisions, seam 2). Two backends:
 *   esp_sec.c                the SEC of the board through dpaa2_sec, on the
 *                            DPSECI of the engine's container
 *   tests/esp/esp_openssl.c  ESP made with OpenSSL, on the build machine
 *
 * An SA here is one session of the backend: one way of ESP (encrypt a
 * packet into ESP, or decrypt ESP back into the packet) with one set of
 * keys. Tunnel mode, IPv4: the packet given to an outbound SA is the inner
 * IPv4 packet and comes back as outer IPv4 header [+ UDP] + ESP; an inbound
 * SA does the opposite. SAs are numbered by the caller, 0 to max_sa - 1.
 *
 * Each worker has queue pairs of its own (ESP_MAX_QP at most), and the
 * results of what it hands over come back to it alone: as events of its
 * event queue (dpaa2_sec attached to the eventdev), or from esp_poll().
 * The SAs of a lane (the tunnel of the SA) share one queue pair of each
 * worker, so that the queue pairs of a worker split its tunnels.
 *
 * Credit (ticket 13, part 3): the SEC takes the jobs of a queue pair in
 * order, and a job waits there while the DECO of its SA is busy with the
 * SA's jobs before it. An SA with many jobs in a queue pair makes every
 * other SA of that queue pair wait behind it. So each SA has at most
 * ESP_SA_BUDGET ns of work (esp_cost()) in a queue pair: what keeps one
 * DECO busy across the time a job takes to come back to the worker
 * (ticket 22). A job beyond it waits in a queue of the SA in the worker
 * (ESP_SA_WAIT jobs at most) and goes to the queue pair when a job of the
 * SA comes back; beyond that it is dropped and counted. The jobs of an SA
 * keep their order.
 *
 * Threads: a worker calls esp_submit(), esp_done(), esp_poll() and
 * esp_events() with its own id. The SAs are added and deleted by one
 * control thread; esp_sa_del() is for an SA the workers no longer hand
 * jobs to.
 */
#ifndef BMCHWACCEL_ESP_H
#define BMCHWACCEL_ESP_H

#include <stdint.h>

#include <rte_mbuf.h>

#define ESP_MAX_QP 2		/* queue pairs of a worker */
#define ESP_BURST 32		/* jobs handed to a queue pair at once */
/*
 * jobs of an SA waiting in a worker: the worker of a tunnel gets the
 * bursts of every worker into it (ipsec.h)
 */
#define ESP_SA_WAIT 256
#define ESP_WAIT_MAX 1024	/* jobs waiting in a worker, all SAs */

/*
 * Work of a job on a DECO, in ns: a fixed part and a part per byte of the
 * packet given. From the rates of one SA on one DECO (ticket 13, part 2,
 * aes256-cbc + hmac-sha256 encrypt): 64 B 0.64 us, 512 B 1.84 us, 1400 B
 * 4.2 us.
 *
 * The budget, 24 us: 6 jobs of 1400 B, 14 of 512 B, 37 of 64 B. Polled in a
 * closed loop, 2 jobs of 1400 B keep a DECO busy (ticket 13, part 3), but in
 * the engine a job comes back as an event of the worker, much later: on the
 * board one tunnel (iperf3 -P 4 through an SFP+ link brought to 1G, CBC) got
 * 692-855 Mbps at 6 us and dropped 0.2 % of its packets for want of credit,
 * 691-873 at 12 us with drops still, and 873 every time without a drop at
 * 18 and 24 us (ticket 22, twice each): some 4 jobs of 1400 B are in flight
 * at 873 Mbps. 24 rather than 18 for a margin over the 12 that was not
 * enough. What another SA of the queue pair waits behind a busy one is at
 * most about the budget (ticket 13): the bench could not show it, under the
 * milliseconds of the queues of its 1G link (a light tunnel on the same
 * worker and queue pair waited as long with no credit at all, the busy
 * one using a third of its DECO); a tunnel near a DECO (2.67
 * Gbps) needs more in flight and is measured again in ticket 20. Raising
 * ESP_SA_WAIT to 1024 cut the drops at 6 and 12 us only.
 */
#define ESP_COST_JOB 480
#ifndef ESP_SA_BUDGET
#define ESP_SA_BUDGET 24000
#endif

static inline uint32_t
esp_cost(uint32_t len)
{
	return ESP_COST_JOB + len * 8 / 3;
}

enum esp_dir { ESP_OUT, ESP_IN };
enum esp_cipher { ESP_AES_CBC, ESP_AES_GCM };
/* the ICV of AES-GCM is 16 bytes, with ESP_AUTH_NONE */
enum esp_auth {
	ESP_AUTH_NONE, ESP_HMAC_SHA1_96, ESP_HMAC_SHA256_128, ESP_HMAC_SHA384_192,
	ESP_HMAC_SHA512_256,
};

/* Of each esp_auth: the bytes of its key and of its ICV (GCM's with NONE). */
static const uint8_t esp_auth_key_len[] = { 0, 20, 32, 48, 64 };
static const uint8_t esp_icv_len[] = { 16, 12, 16, 24, 32 };

struct esp_sa_conf {
	uint8_t dir, cipher, auth;
	uint8_t key_len;		/* AES: 16 or 32 */
	uint8_t auth_key_len;
	uint8_t key[32];
	uint8_t auth_key[64];
	uint8_t salt[4];		/* AES-GCM: the 4 bytes xfrm puts after the key */
	uint32_t spi;
	uint32_t src, dst;		/* the outer addresses, network order */
	uint16_t sport, dport;		/* ESP in UDP, host order; 0 0: plain ESP */
	uint16_t replay;		/* inbound: the anti-replay window, 0: none */
	uint32_t lane;			/* the tunnel: its SAs share a queue pair */
	uint32_t seq;			/* outbound: the number of its first packet; 0: 1 */
};

/*
 * A job: the packet m through SA sa. Out of place when dst is not NULL:
 * the result is written to dst and m stays as it was. cost is the
 * esp layer's.
 */
struct esp_job {
	struct rte_mbuf *m, *dst;
	uint32_t sa;
	uint32_t cost;
};

/* What came back: the job, and whether the SA made the packet. */
struct esp_result {
	struct esp_job job;
	int ok;
};

/*
 * A backend. sa_add() makes the session of an SA, sa_del() lets it go.
 * enqueue() hands jobs to queue pair q of worker w and returns how many it
 * took, in order. poll() returns results that have come back to worker w,
 * for a backend whose results do not come as events; events() turns the
 * event_ptr of the RTE_EVENT_TYPE_CRYPTODEV events of a worker into
 * results.
 */
struct esp_dev;
struct esp_dev_ops {
	int (*sa_add)(struct esp_dev *d, uint32_t sa, const struct esp_sa_conf *c);
	void (*sa_del)(struct esp_dev *d, uint32_t sa);
	unsigned (*enqueue)(struct esp_dev *d, unsigned w, unsigned q, const struct esp_job *jobs,
			    unsigned n);
	unsigned (*poll)(struct esp_dev *d, unsigned w, struct esp_result *r, unsigned max);
	unsigned (*events)(struct esp_dev *d, void *const *objs, unsigned n, struct esp_result *r);
	void (*free)(struct esp_dev *d);
};

struct esp_dev {
	const struct esp_dev_ops *ops;
	char name[32];		/* dpsec-4, openssl */
	unsigned nqp;		/* queue pairs of each worker */
	int events;		/* results come as events of the eventdev */
};

/*
 * The backend of the engine: esp_sec.c on the board, the OpenSSL one in the
 * tests. NULL, with *why, when there is none (no DPSECI in the container).
 * With events, the queue pairs of worker w send their results to event
 * queue w of eventdev 0.
 */
struct esp_dev_params {
	unsigned nworkers;
	unsigned max_sa;
	int events;
	int socket_id;
};
struct esp_dev *esp_dev_open(const struct esp_dev_params *p, const char **why);

struct esp_params {
	unsigned nworkers;
	unsigned max_sa;
	int socket_id;
};

struct esp;

/* Takes the backend over: esp_free() frees it. */
struct esp *esp_create(const struct esp_params *p, struct esp_dev *dev);
void esp_free(struct esp *e);
const struct esp_dev *esp_dev(const struct esp *e);

/*
 * The control thread. esp_sa_add: 0, or -EINVAL (sa out of range, a
 * conf the backend cannot do), -EEXIST, or the backend's error.
 * esp_sa_del: 0, -ENOENT, or -EBUSY while jobs of it are with a worker or
 * in a queue pair.
 */
int esp_sa_add(struct esp *e, uint32_t sa, const struct esp_sa_conf *c);
int esp_sa_del(struct esp *e, uint32_t sa);
unsigned esp_sa_count(const struct esp *e);

struct esp_sa_stats {
	uint64_t ok, failed;	/* results */
	/*
	 * Jobs taken, to the queue pair or to wait for credit: at most that
	 * many packets go through the SA, so an outbound SA has used no number
	 * beyond its first + taken - 1.
	 */
	uint64_t taken;
	uint64_t dropped;	/* jobs beyond the credit and the wait queue */
	unsigned queued;	/* jobs in a queue pair */
	unsigned waiting;	/* jobs waiting for credit */
};
/* Summed over the workers, as they are when read; 0 or -ENOENT. */
int esp_sa_stats(const struct esp *e, uint32_t sa, struct esp_sa_stats *st);

/*
 * Workers. esp_submit() takes the n jobs (their cost is set here) and
 * returns how many were dropped: their mbufs (m and dst) are freed. A job
 * of an SA that does not exist is dropped too.
 * esp_done() takes n results that came back to worker w: their credit goes
 * back to their SA, whose waiting jobs go on; r is left as it was, for the
 * caller. esp_poll() and esp_events() get results from the backend, then
 * do the same.
 */
unsigned esp_submit(struct esp *e, unsigned w, struct esp_job *jobs, unsigned n);
void esp_done(struct esp *e, unsigned w, const struct esp_result *r, unsigned n);
unsigned esp_poll(struct esp *e, unsigned w, struct esp_result *r, unsigned max);
unsigned esp_events(struct esp *e, unsigned w, void *const *objs, unsigned n,
		    struct esp_result *r);

#endif
