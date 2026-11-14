/*
 * bmchwaccel-ctl: one request to bmchwaccel-engine over its control socket
 * (protocol at the top of ctl.c), for scripts such as those of bmcHwAccel,
 * which have no client for a UNIX socket in busybox.
 *
 *   bmchwaccel-ctl [--socket PATH] [--timeout SECONDS] COMMAND [WORD...]
 *
 * The words make one line of request. Prints the reply: its lines of data,
 * then its last line ("ok ..." or "err ..."). Exit code: 0 for "ok", 1 for
 * "err", 2 for a wrong use, 3 when no engine answers (no socket, a protocol
 * of another version, or no complete reply within the timeout, 5 s by
 * default).
 */
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "ctl.h"

static const char *path = CTL_SOCKET;
static int timeout_ms = 5000;
static struct timespec start;

static void
usage(void)
{
	fprintf(stderr, "usage: bmchwaccel-ctl [--socket PATH] [--timeout SECONDS] COMMAND [WORD...]\n");
	exit(2);
}

static void __attribute__((noreturn))
no_engine(const char *why)
{
	fprintf(stderr, "bmchwaccel-ctl: %s: %s\n", path, why);
	exit(3);
}

/* Milliseconds left of the timeout. */
static int
left(void)
{
	struct timespec now;
	long ms;

	clock_gettime(CLOCK_MONOTONIC, &now);
	ms = (now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1000000;
	return ms >= timeout_ms ? 0 : (int)(timeout_ms - ms);
}

static void
timed_out(void)
{
	char why[64];

	snprintf(why, sizeof(why), "no answer within %d s", timeout_ms / 1000);
	no_engine(why);
}

/* Reads one line into line (without its newline); what came after it stays
 * in buf. */
static void
read_line(int fd, char *buf, size_t *have, char *line, size_t size)
{
	char *nl;

	while (!(nl = memchr(buf, '\n', *have))) {
		struct pollfd pf = { .fd = fd, .events = POLLIN };
		ssize_t n;
		int ms = left();

		if (*have >= size - 1)
			no_engine("a line of the reply is too long");
		if (!ms || poll(&pf, 1, ms) <= 0)
			timed_out();
		n = recv(fd, buf + *have, size - 1 - *have, 0);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			no_engine("the reply ended before its last line");
		*have += (size_t)n;
	}
	*nl = '\0';
	memcpy(line, buf, (size_t)(nl - buf) + 1);
	*have -= (size_t)(nl - buf) + 1;
	memmove(buf, nl + 1, *have);
}

int
main(int argc, char **argv)
{
	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	char req[CTL_LINE_MAX], buf[CTL_LINE_MAX * 2], line[CTL_LINE_MAX * 2], hello[32];
	size_t have = 0, len = 0;
	int fd, i = 1;

	for (; i < argc && !strncmp(argv[i], "--", 2); i += 2) {
		if (i + 1 >= argc)
			usage();
		if (!strcmp(argv[i], "--socket"))
			path = argv[i + 1];
		else if (!strcmp(argv[i], "--timeout") && atoi(argv[i + 1]) > 0)
			timeout_ms = atoi(argv[i + 1]) * 1000;
		else
			usage();
	}
	if (i >= argc)
		usage();
	for (; i < argc; i++) {
		int n = snprintf(req + len, sizeof(req) - len, "%s%s", len ? " " : "", argv[i]);

		if (n < 0 || len + (size_t)n >= sizeof(req) - 1) {
			fprintf(stderr, "bmchwaccel-ctl: the request is too long\n");
			return 2;
		}
		len += (size_t)n;
	}
	req[len++] = '\n';

	clock_gettime(CLOCK_MONOTONIC, &start);
	if (strlen(path) >= sizeof(sa.sun_path))
		no_engine("the path is too long");
	strcpy(sa.sun_path, path);
	fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0 || connect(fd, (struct sockaddr *)&sa, sizeof(sa)))
		no_engine(strerror(errno));
	snprintf(hello, sizeof(hello), CTL_GREETING, ENGINE_PROTOCOL);
	read_line(fd, buf, &have, line, sizeof(buf));
	if (strcmp(line, hello))
		no_engine("not an engine of this protocol");
	if (send(fd, req, len, MSG_NOSIGNAL) != (ssize_t)len)
		no_engine(strerror(errno));
	for (;;) {
		read_line(fd, buf, &have, line, sizeof(buf));
		puts(line);
		if (!strncmp(line, "ok", 2) && (line[2] == '\0' || line[2] == ' '))
			return 0;
		if (!strncmp(line, "err", 3) && (line[3] == '\0' || line[3] == ' '))
			return 1;
	}
}
