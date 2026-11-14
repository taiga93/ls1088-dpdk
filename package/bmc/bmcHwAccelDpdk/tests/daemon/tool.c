/*
 * Seam 3: what the test of bmchwaccel-syncd runs on the router in QEMU
 * (qemu-test.sh), next to the real daemon and the real conntrack.
 *
 *   tool engine SOCKET DIR
 *        a stand-in for bmchwaccel-engine on SOCKET. Every request line goes
 *        to DIR/log, as do "-- connected" and "-- closed" for each session.
 *        Answers: bind "ok", or "err unlearned orig-in" while the number in
 *        DIR/unlearned is above 0 (it counts down); active: the lines of
 *        DIR/active, then "ok N"; flush-port, flush-route, flush-mac: the
 *        lines of DIR/flushed, then "ok N"; ports: the lines of DIR/ports,
 *        then "ok"; claim, unbind: "ok"; flush, count: "ok 0"; claimed:
 *        "ok yes"; sa-add: "err full" while DIR/sa-full is there, else
 *        "ok"; sa: the lines of DIR/sa, then "ok N"; sa-stop, sa-del SPI DST:
 *        the line of DIR/sa with spi=SPI, the lines of DIR/sa-conns (the
 *        connections its tunnel let go of; the file goes once told), then
 *        "ok", or "err unknown"; sa-flush: "ok 0"; anything else
 *        "err unknown-command".
 *   tool ct PROTO SIP SPORT DIP DPORT
 *        what conntrack holds of the connection with that original tuple:
 *        "timeout=S mark=M liberal=orig,reply" (the directions with
 *        IP_CT_TCP_FLAG_BE_LIBERAL), or exit 1 without it
 *   tool tcp-serve PORT
 *        accepts TCP connections on PORT and holds each until its peer closes
 *   tool tcp-hold DIP DPORT
 *        opens a TCP connection and holds it, sending nothing, until killed
 *   tool udp-echo PORT
 *        answers each UDP datagram to PORT with the same bytes
 *   tool udp-ping DIP DPORT SPORT COUNT MS [noreply]
 *        sends COUNT datagrams from SPORT, one each MS ms; without
 *        "noreply", each waits for its answer for up to 1 s
 */
#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <libnetfilter_conntrack/libnetfilter_conntrack.h>

#define IP_CT_TCP_FLAG_BE_LIBERAL 0x08

static void
die(const char *what)
{
	fprintf(stderr, "tool: %s: %s\n", what, strerror(errno));
	exit(2);
}

static void
note(const char *dir, const char *line)
{
	char path[256];
	FILE *f;

	snprintf(path, sizeof(path), "%s/log", dir);
	f = fopen(path, "a");
	if (!f)
		die(path);
	fprintf(f, "%s\n", line);
	fclose(f);
}

/* The number in DIR/unlearned; one less is written back. */
static int
take_unlearned(const char *dir)
{
	char path[256];
	FILE *f;
	int n = 0;

	snprintf(path, sizeof(path), "%s/unlearned", dir);
	f = fopen(path, "r");
	if (!f)
		return 0;
	if (fscanf(f, "%d", &n) != 1)
		n = 0;
	fclose(f);
	if (n <= 0)
		return 0;
	f = fopen(path, "w");
	if (f) {
		fprintf(f, "%d\n", n - 1);
		fclose(f);
	}
	return 1;
}

/* The lines of DIR/name into out at len; their number. */
static unsigned
lines_of(const char *dir, const char *name, char *out, size_t size, size_t *len)
{
	char path[256], line[512];
	unsigned n = 0;
	FILE *f;

	snprintf(path, sizeof(path), "%s/%s", dir, name);
	f = fopen(path, "r");
	while (f && fgets(line, sizeof(line), f) && *len + strlen(line) + 32 < size) {
		*len += (size_t)snprintf(out + *len, size - *len, "%s", line);
		n++;
	}
	if (f)
		fclose(f);
	return n;
}

static void
answer(int fd, const char *dir, const char *req)
{
	char out[65536], path[256];
	size_t len = 0;
	unsigned n;

	out[0] = '\0';
	if (!strncmp(req, "bind ", 5))
		len = (size_t)snprintf(out, sizeof(out), "%s\n",
				       take_unlearned(dir) ? "err unlearned orig-in" : "ok");
	else if (!strncmp(req, "active ", 7)) {
		n = lines_of(dir, "active", out, sizeof(out), &len);
		len += (size_t)snprintf(out + len, sizeof(out) - len, "ok %u\n", n);
	} else if (!strncmp(req, "flush-port ", 11) || !strncmp(req, "flush-route ", 12) ||
		   !strncmp(req, "flush-mac ", 10)) {
		n = lines_of(dir, "flushed", out, sizeof(out), &len);
		len += (size_t)snprintf(out + len, sizeof(out) - len, "ok %u\n", n);
	} else if (!strcmp(req, "ports")) {
		lines_of(dir, "ports", out, sizeof(out), &len);
		len += (size_t)snprintf(out + len, sizeof(out) - len, "ok\n");
	} else if (!strncmp(req, "sa-add ", 7)) {
		snprintf(path, sizeof(path), "%s/sa-full", dir);
		len = (size_t)snprintf(out, sizeof(out), "%s\n", access(path, F_OK) ? "ok" : "err full");
	} else if (!strcmp(req, "sa")) {
		n = lines_of(dir, "sa", out, sizeof(out), &len);
		len += (size_t)snprintf(out + len, sizeof(out) - len, "ok %u\n", n);
	} else if (!strncmp(req, "sa-del ", 7) || !strncmp(req, "sa-stop ", 8)) {
		char spi[32], all[65536], *l, *save = NULL;
		size_t alen = 0;

		snprintf(spi, sizeof(spi), "spi=%.12s ", strchr(req, ' ') + 1);
		*strchr(spi + 4, ' ') = '\0';
		strcat(spi, " ");
		all[0] = '\0';
		lines_of(dir, "sa", all, sizeof(all), &alen);
		for (l = strtok_r(all, "\n", &save); l; l = strtok_r(NULL, "\n", &save))
			if (strstr(l, spi)) {
				len = (size_t)snprintf(out, sizeof(out), "%s\n", l);
				lines_of(dir, "sa-conns", out, sizeof(out), &len);
				snprintf(path, sizeof(path), "%s/sa-conns", dir);
				unlink(path);
				len += (size_t)snprintf(out + len, sizeof(out) - len, "ok\n");
				break;
			}
		if (!len)
			len = (size_t)snprintf(out, sizeof(out), "err unknown\n");
	} else if (!strcmp(req, "sa-flush")) {
		len = (size_t)snprintf(out, sizeof(out), "ok 0\n");
	} else if (!strcmp(req, "claim") || !strncmp(req, "unbind ", 7))
		len = (size_t)snprintf(out, sizeof(out), "ok\n");
	else if (!strcmp(req, "flush") || !strcmp(req, "count"))
		len = (size_t)snprintf(out, sizeof(out), "ok 0\n");
	else if (!strcmp(req, "claimed"))
		len = (size_t)snprintf(out, sizeof(out), "ok yes\n");
	else
		len = (size_t)snprintf(out, sizeof(out), "err unknown-command\n");
	if (write(fd, out, len) != (ssize_t)len)
		return;
}

static __attribute__((noreturn)) void
engine(const char *sock, const char *dir)
{
	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	int lfd = socket(AF_UNIX, SOCK_STREAM, 0), cfd = -1;
	char buf[4096], line[1024];
	size_t ll = 0;

	signal(SIGPIPE, SIG_IGN);
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", sock);
	unlink(sock);
	if (lfd < 0 || bind(lfd, (struct sockaddr *)&sa, sizeof(sa)) || listen(lfd, 4))
		die(sock);
	for (;;) {
		struct pollfd pf[2] = { { .fd = lfd, .events = POLLIN }, { .fd = cfd, .events = POLLIN } };
		ssize_t k, i;

		if (poll(pf, cfd < 0 ? 1 : 2, -1) < 0)
			continue;
		if (cfd >= 0 && pf[1].revents) {
			k = read(cfd, buf, sizeof(buf));
			if (k <= 0) {
				close(cfd);
				cfd = -1;
				ll = 0;
				note(dir, "-- closed");
				continue;
			}
			for (i = 0; i < k; i++) {
				if (buf[i] != '\n') {
					if (ll < sizeof(line) - 1)
						line[ll++] = buf[i];
					continue;
				}
				line[ll] = '\0';
				ll = 0;
				note(dir, line);
				answer(cfd, dir, line);
			}
		}
		if (pf[0].revents & POLLIN) {
			int fd = accept(lfd, NULL, NULL);

			if (fd < 0)
				continue;
			if (cfd >= 0) {
				/* one session at a time, as the daemon needs */
				close(fd);
				continue;
			}
			cfd = fd;
			note(dir, "-- connected");
			if (write(cfd, "bmchwaccel-engine 1\n", 20) != 20)
				die("greeting");
		}
	}
}

static int
on_ct(enum nf_conntrack_msg_type type, struct nf_conntrack *c, void *arg)
{
	char liberal[16] = "";

	(void)type;
	(void)arg;
	if (nfct_attr_is_set(c, ATTR_TCP_FLAGS_ORIG) > 0 &&
	    nfct_get_attr_u8(c, ATTR_TCP_FLAGS_ORIG) & IP_CT_TCP_FLAG_BE_LIBERAL)
		strcat(liberal, "orig");
	if (nfct_attr_is_set(c, ATTR_TCP_FLAGS_REPL) > 0 &&
	    nfct_get_attr_u8(c, ATTR_TCP_FLAGS_REPL) & IP_CT_TCP_FLAG_BE_LIBERAL)
		strcat(liberal, *liberal ? ",reply" : "reply");
	printf("timeout=%u mark=0x%x liberal=%s\n", nfct_get_attr_u32(c, ATTR_TIMEOUT),
	       nfct_attr_is_set(c, ATTR_MARK) > 0 ? nfct_get_attr_u32(c, ATTR_MARK) : 0,
	       *liberal ? liberal : "none");
	return NFCT_CB_STOP;
}

static int
ct(char **a)
{
	struct nfct_handle *h = nfct_open(CONNTRACK, 0);
	struct nf_conntrack *c = nfct_new();
	struct in_addr s, d;

	if (!h || !c || inet_pton(AF_INET, a[1], &s) != 1 || inet_pton(AF_INET, a[3], &d) != 1)
		die("ct");
	nfct_set_attr_u8(c, ATTR_ORIG_L3PROTO, AF_INET);
	nfct_set_attr_u8(c, ATTR_ORIG_L4PROTO, !strcmp(a[0], "tcp") ? IPPROTO_TCP : IPPROTO_UDP);
	nfct_set_attr_u32(c, ATTR_ORIG_IPV4_SRC, s.s_addr);
	nfct_set_attr_u32(c, ATTR_ORIG_IPV4_DST, d.s_addr);
	nfct_set_attr_u16(c, ATTR_ORIG_PORT_SRC, htons((uint16_t)atoi(a[2])));
	nfct_set_attr_u16(c, ATTR_ORIG_PORT_DST, htons((uint16_t)atoi(a[4])));
	nfct_callback_register(h, NFCT_T_ALL, on_ct, NULL);
	return nfct_query(h, NFCT_Q_GET, c) ? 1 : 0;
}

static __attribute__((noreturn)) void
tcp_serve(int port)
{
	struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
	int fd = socket(AF_INET, SOCK_STREAM, 0), one = 1;
	struct pollfd pf[64];
	unsigned n = 1, i;
	char buf[2048];

	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	if (fd < 0 || bind(fd, (struct sockaddr *)&sa, sizeof(sa)) || listen(fd, 16))
		die("tcp-serve");
	pf[0] = (struct pollfd){ .fd = fd, .events = POLLIN };
	for (;;) {
		if (poll(pf, n, -1) <= 0)
			continue;
		for (i = 1; i < n; i++)
			if (pf[i].revents && read(pf[i].fd, buf, sizeof(buf)) <= 0) {
				close(pf[i].fd);
				pf[i--] = pf[--n];
			}
		if (pf[0].revents & POLLIN) {
			int c = accept(fd, NULL, NULL);

			if (c >= 0 && n < 64)
				pf[n++] = (struct pollfd){ .fd = c, .events = POLLIN };
			else if (c >= 0)
				close(c);
		}
	}
}

static int
tcp_hold(const char *ip, int port)
{
	struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	char buf[256];

	if (fd < 0 || inet_pton(AF_INET, ip, &sa.sin_addr) != 1 ||
	    connect(fd, (struct sockaddr *)&sa, sizeof(sa)))
		die("tcp-hold");
	while (read(fd, buf, sizeof(buf)) > 0)
		;
	return 0;
}

static __attribute__((noreturn)) void
udp_echo(int port)
{
	struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	char buf[2048];

	if (fd < 0 || bind(fd, (struct sockaddr *)&sa, sizeof(sa)))
		die("udp-echo");
	for (;;) {
		struct sockaddr_in from;
		socklen_t fl = sizeof(from);
		ssize_t n = recvfrom(fd, buf, sizeof(buf), 0, (struct sockaddr *)&from, &fl);

		if (n >= 0)
			sendto(fd, buf, (size_t)n, 0, (struct sockaddr *)&from, fl);
	}
}

static int
udp_ping(char **a, int argc)
{
	struct sockaddr_in me = { .sin_family = AF_INET, .sin_port = htons((uint16_t)atoi(a[2])) };
	struct sockaddr_in to = { .sin_family = AF_INET, .sin_port = htons((uint16_t)atoi(a[1])) };
	int fd = socket(AF_INET, SOCK_DGRAM, 0), count = atoi(a[3]), ms = atoi(a[4]), i, got = 0;
	int reply = !(argc > 5 && !strcmp(a[5], "noreply"));
	char buf[64] = "ping";

	if (fd < 0 || inet_pton(AF_INET, a[0], &to.sin_addr) != 1 ||
	    bind(fd, (struct sockaddr *)&me, sizeof(me)))
		die("udp-ping");
	for (i = 0; i < count; i++) {
		struct pollfd pf = { .fd = fd, .events = POLLIN };
		struct timespec t = { ms / 1000, (long)(ms % 1000) * 1000000 };

		sendto(fd, buf, 4, 0, (struct sockaddr *)&to, sizeof(to));
		if (reply && poll(&pf, 1, 1000) > 0 && recv(fd, buf, sizeof(buf), 0) > 0)
			got++;
		nanosleep(&t, NULL);
	}
	printf("%d sent, %d answered\n", count, got);
	return 0;
}

int
main(int argc, char **argv)
{
	if (argc == 4 && !strcmp(argv[1], "engine"))
		engine(argv[2], argv[3]);
	if (argc == 7 && !strcmp(argv[1], "ct"))
		return ct(argv + 2);
	if (argc == 3 && !strcmp(argv[1], "tcp-serve"))
		tcp_serve(atoi(argv[2]));
	if (argc == 4 && !strcmp(argv[1], "tcp-hold"))
		return tcp_hold(argv[2], atoi(argv[3]));
	if (argc == 3 && !strcmp(argv[1], "udp-echo"))
		udp_echo(atoi(argv[2]));
	if ((argc == 7 || argc == 8) && !strcmp(argv[1], "udp-ping"))
		return udp_ping(argv + 2, argc - 2);
	fprintf(stderr, "usage: tool engine SOCKET DIR | ct PROTO SIP SPORT DIP DPORT | tcp-serve PORT |"
		" tcp-hold DIP DPORT | udp-echo PORT |"
		" udp-ping DIP DPORT SPORT COUNT MS [noreply]\n");
	return 2;
}
