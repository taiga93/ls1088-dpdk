/*
 * Seam 2: plays the cables and the kernel around a running bmchwaccel-engine.
 * Each side of each engine port is a net_memif pair: the engine is the
 * server, this program the client, with its own ethdev named
 * net_memif_PORT_wire or net_memif_PORT_kernel for the stream PORT-wire or
 * PORT-kernel.
 *
 *   feeder EAL-ARGS -- --socket ENGINE-SOCKET --script FILE --out DIR
 *
 * The script, a line each:
 *   send STREAM FILE.pcap   sends the packets of the file into the engine
 *   quiet                   waits until the engine took every packet sent
 *                           and every packet it sent has arrived
 *   ctl REQUEST             sends a request to the control socket
 *   reconnect               closes the control session and opens a new one
 * At the end: a last quiet, then DIR/STREAM.pcap with what the engine sent
 * on each stream, and DIR/transcript with "> REQUEST" and "< REPLY" lines.
 */
#include <errno.h>
#include <getopt.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>

#define MAX_STREAMS 16
#define MAX_PKTS 4096

struct stream {
	char name[32];		/* eth1-wire */
	char port[16];		/* eth1 */
	int kernel;
	uint16_t ethdev;
	uint64_t sent, got;
	unsigned npkts;
	struct rte_mbuf *pkts[MAX_PKTS];	/* what the engine sent */
};

static struct stream st[MAX_STREAMS];
static unsigned nst;
static struct rte_mempool *mp;
static FILE *ctl_in, *transcript;
static int ctl_fd;
static const char *ctl_path;

static void
die(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	fprintf(stderr, "feeder: ");
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

static struct stream *
stream_named(const char *name)
{
	unsigned i;

	for (i = 0; i < nst; i++)
		if (!strcmp(st[i].name, name))
			return &st[i];
	die("no stream %s", name);
	return NULL;
}

/* The streams are the memif ethdevs the EAL made: net_memif_PORT_SIDE. */
static void
streams_start(void)
{
	struct rte_eth_conf conf = { 0 };
	uint16_t id;

	RTE_ETH_FOREACH_DEV(id) {
		char name[RTE_ETH_NAME_MAX_LEN], *side;
		struct stream *s = &st[nst];
		struct rte_eth_link link;
		int i;

		if (nst == MAX_STREAMS)
			die("too many streams");
		rte_eth_dev_get_name_by_port(id, name);
		if (strncmp(name, "net_memif_", 10) || !(side = strrchr(name, '_')) ||
		    side - name - 10 >= (int)sizeof(s->port))
			die("ethdev %s is not net_memif_PORT_wire|kernel", name);
		memcpy(s->port, name + 10, (size_t)(side - name - 10));
		s->kernel = !strcmp(side + 1, "kernel");
		snprintf(s->name, sizeof(s->name), "%s-%s", s->port, side + 1);
		s->ethdev = id;
		if (rte_eth_dev_configure(id, 1, 1, &conf) ||
		    rte_eth_rx_queue_setup(id, 0, 1024, 0, NULL, mp) ||
		    rte_eth_tx_queue_setup(id, 0, 1024, 0, NULL) || rte_eth_dev_start(id))
			die("cannot start %s", name);
		for (i = 0; i < 500; i++) {
			rte_eth_link_get_nowait(id, &link);
			if (link.link_status)
				break;
			usleep(10000);
		}
		if (!link.link_status)
			die("%s: no link with the engine", name);
		nst++;
	}
}

static void
ctl_connect(const char *path)
{
	ctl_path = path;
	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	char line[256];

	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", path);
	ctl_fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (ctl_fd < 0 || connect(ctl_fd, (struct sockaddr *)&sa, sizeof(sa)))
		die("%s: %s", path, strerror(errno));
	ctl_in = fdopen(dup(ctl_fd), "r");
	if (!ctl_in || !fgets(line, sizeof(line), ctl_in) ||
	    strcmp(line, "bmchwaccel-engine 1\n"))
		die("the engine does not speak version 1");
}

/* Sends a request; the reply lines go to fn, or to the transcript. */
static void
ctl(const char *req, void (*fn)(const char *, void *), void *arg)
{
	char line[1024];
	size_t n = strlen(req);

	if (write(ctl_fd, req, n) != (ssize_t)n || write(ctl_fd, "\n", 1) != 1)
		die("control socket: %s", strerror(errno));
	if (!fn)
		fprintf(transcript, "> %s\n", req);
	while (fgets(line, sizeof(line), ctl_in)) {
		if (fn)
			fn(line, arg);
		else
			fprintf(transcript, "< %s", line);
		if (!strncmp(line, "ok", 2) || !strncmp(line, "err", 3))
			return;
	}
	die("control socket closed");
}

static void
receive(void)
{
	unsigned i;

	for (i = 0; i < nst; i++) {
		struct rte_mbuf *b[32];
		uint16_t n = rte_eth_rx_burst(st[i].ethdev, 0, b, 32), k;

		for (k = 0; k < n; k++) {
			if (st[i].npkts == MAX_PKTS)
				die("%s: more than %d packets", st[i].name, MAX_PKTS);
			st[i].pkts[st[i].npkts++] = b[k];
		}
		st[i].got += n;
	}
}

/* "port NAME wire_rx=N wire_tx=N kernel_rx=N kernel_tx=N" against what we sent and got */
static void
stats_line(const char *line, void *arg)
{
	int *settled = arg;
	unsigned long long c[4];
	char port[16];
	unsigned i;

	if (sscanf(line, "port %15s wire_rx=%llu wire_tx=%llu kernel_rx=%llu kernel_tx=%llu",
		   port, &c[0], &c[1], &c[2], &c[3]) != 5)
		return;
	for (i = 0; i < nst; i++)
		if (!strcmp(st[i].port, port) &&
		    (st[i].sent != c[st[i].kernel * 2] || st[i].got != c[st[i].kernel * 2 + 1]))
			*settled = 0;
}

static void
quiet(void)
{
	struct timespec t0, t;
	int settled;

	clock_gettime(CLOCK_MONOTONIC, &t0);
	do {
		usleep(2000);
		receive();
		settled = 1;
		ctl("stats", stats_line, &settled);
		clock_gettime(CLOCK_MONOTONIC, &t);
		if (t.tv_sec - t0.tv_sec > 10)
			die("the engine did not settle in 10 s");
	} while (!settled);
}

/* Little-endian pcap of Ethernet frames, microsecond time stamps. */
struct pcap_hdr {
	uint32_t magic;
	uint16_t major, minor;
	int32_t zone;
	uint32_t sigfigs, snaplen, linktype;
};

struct pcap_rec {
	uint32_t sec, usec, caplen, len;
};

static void
send_pcap(struct stream *s, const char *path)
{
	FILE *f = fopen(path, "rb");
	struct pcap_hdr h;
	struct pcap_rec r;

	if (!f || fread(&h, sizeof(h), 1, f) != 1 || h.magic != 0xa1b2c3d4 || h.linktype != 1)
		die("%s: not a little-endian Ethernet pcap", path);
	while (fread(&r, sizeof(r), 1, f) == 1) {
		struct rte_mbuf *m = rte_pktmbuf_alloc(mp);
		char *d;

		if (!m || r.caplen > 2048 || !(d = rte_pktmbuf_append(m, (uint16_t)r.caplen)) ||
		    fread(d, r.caplen, 1, f) != 1)
			die("%s: a packet of %u bytes", path, r.caplen);
		while (rte_eth_tx_burst(s->ethdev, 0, &m, 1) != 1)
			receive();
		s->sent++;
	}
	fclose(f);
}

static void
write_pcaps(const char *dir)
{
	struct pcap_hdr h = { 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1 };
	unsigned i, k;

	for (i = 0; i < nst; i++) {
		char path[512];
		FILE *f;

		snprintf(path, sizeof(path), "%s/%s.pcap", dir, st[i].name);
		f = fopen(path, "wb");
		if (!f || fwrite(&h, sizeof(h), 1, f) != 1)
			die("%s: %s", path, strerror(errno));
		for (k = 0; k < st[i].npkts; k++) {
			struct rte_mbuf *m = st[i].pkts[k];
			struct pcap_rec r = { 0, 0, m->pkt_len, m->pkt_len };
			static uint8_t frame[65536];
			const void *d = rte_pktmbuf_read(m, 0, m->pkt_len, frame);

			if (!d || fwrite(&r, sizeof(r), 1, f) != 1 || fwrite(d, m->pkt_len, 1, f) != 1)
				die("%s: %s", path, strerror(errno));
		}
		fclose(f);
	}
}

int
main(int argc, char **argv)
{
	static const struct option lo[] = {
		{ "socket", required_argument, NULL, 's' },
		{ "script", required_argument, NULL, 'c' },
		{ "out", required_argument, NULL, 'o' },
		{ NULL, 0, NULL, 0 },
	};
	const char *sock = NULL, *script = NULL, *outdir = NULL;
	char line[1024], path[512];
	FILE *f;
	int ret, c, lineno = 0;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		die("EAL: %s", rte_strerror(rte_errno));
	argc -= ret;
	argv += ret;
	while ((c = getopt_long(argc, argv, "", lo, NULL)) != -1)
		switch (c) {
		case 's': sock = optarg; break;
		case 'c': script = optarg; break;
		case 'o': outdir = optarg; break;
		default: die("unknown option");
		}
	if (!sock || !script || !outdir)
		die("usage: feeder EAL-ARGS -- --socket PATH --script FILE --out DIR");
	mp = rte_pktmbuf_pool_create("feeder", 16383, 256, 0, RTE_MBUF_DEFAULT_BUF_SIZE,
				     (int)rte_socket_id());
	if (!mp)
		die("no mbuf pool");
	streams_start();
	/*
	 * In copy mode the rings from the engine get their free buffers when
	 * this side first receives: until then the engine could not send.
	 */
	for (c = 0; c < 10; c++) {
		receive();
		usleep(1000);
	}
	ctl_connect(sock);
	snprintf(path, sizeof(path), "%s/transcript", outdir);
	transcript = fopen(path, "w");
	f = fopen(script, "r");
	if (!transcript || !f)
		die("%s or %s: %s", path, script, strerror(errno));
	while (fgets(line, sizeof(line), f)) {
		char *w1, *w2, *save = NULL;

		lineno++;
		line[strcspn(line, "\n")] = '\0';
		w1 = strtok_r(line, " ", &save);
		if (!w1 || *w1 == '#')
			continue;
		if (!strcmp(w1, "send") && (w2 = strtok_r(NULL, " ", &save)))
			send_pcap(stream_named(w2), strtok_r(NULL, " ", &save));
		else if (!strcmp(w1, "quiet"))
			quiet();
		else if (!strcmp(w1, "ctl"))
			ctl(line + 4, NULL, NULL);
		else if (!strcmp(w1, "reconnect")) {
			fclose(ctl_in);
			close(ctl_fd);
			ctl_connect(ctl_path);
			fprintf(transcript, "-- reconnect\n");
		}
		else
			die("%s:%d: what is %s", script, lineno, w1);
	}
	quiet();
	write_pcaps(outdir);
	fclose(transcript);
	return 0;
}
