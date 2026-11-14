/*
 * See sa.h. The SAs held are in a chained hash by SPI and destination, the
 * tunnels in another by reqid, with how many SAs each has.
 */
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sa.h"

#define BUCKETS 8192		/* of each hash: a power of 2 */
#define NONE UINT32_MAX
#define UDP_ENCAP_ESPINUDP 2	/* linux/udp.h: RFC 3948, what strongSwan uses */

/* The algorithms of the spec: the names and sizes of xfrm, the words of sa-add. */
static const struct {
	const char *name;
	unsigned key_bits, trunc_bits;
	const char *word;
} auths[] = {
	{ "hmac(sha1)", 160, 96, "sha1" },
	{ "hmac(sha256)", 256, 128, "sha256" },
	{ "hmac(sha384)", 384, 192, "sha384" },
	{ "hmac(sha512)", 512, 256, "sha512" },
};

static int
auth_of(const struct sa_kernel *k)
{
	unsigned i;

	for (i = 0; i < sizeof(auths) / sizeof(auths[0]); i++)
		if (!strcmp(k->auth, auths[i].name) && k->auth_bits == auths[i].key_bits &&
		    k->trunc_bits == auths[i].trunc_bits)
			return (int)i;
	return -1;
}

static int
gcm(const struct sa_kernel *k)
{
	/* the key and 32 bits of salt */
	return !strcmp(k->aead, "rfc4106(gcm(aes))") && !*k->crypt && !*k->auth &&
	       (k->aead_bits == 160 || k->aead_bits == 288) && k->icv_bits == 128;
}

static int
cbc(const struct sa_kernel *k)
{
	return !strcmp(k->crypt, "cbc(aes)") && !*k->aead &&
	       (k->crypt_bits == 128 || k->crypt_bits == 256) && auth_of(k) >= 0;
}

const char *
sa_why(const struct sa_kernel *k, int new_tunnel)
{
	if (!k->ipv4)
		return "not IPv4";
	if (!k->esp)
		return "not ESP";
	if (!k->tunnel)
		return "not tunnel mode";
	if (k->esn)
		return "extended sequence numbers";
	if (k->offload)
		return "handed to a network device";
	if (k->comp)
		return "compression";
	if (k->encap && k->encap != UDP_ENCAP_ESPINUDP)
		return "ESP in UDP of another kind";
	if (!cbc(k) && !gcm(k))
		return "algorithms the hardware does not do";
	if (k->dir == SA_NEITHER)
		return "not of an address of the router";
	if (!k->via_engine)
		return "not through a port of Tăng tốc phần cứng";
	if (k->kept)
		return "its WAN is kept on the CPU";
	if (k->dir == SA_IN && k->replay > 128)
		return "an anti-replay window above 128";
	if (k->dir == SA_OUT && k->oseq >= SA_SEQ_LEAVE - SA_MARGIN)
		return "sequence numbers near their end";
	if (!new_tunnel)
		return "the most tunnels already";
	return NULL;
}

/* The next line of text into l (cut at its size), *at past it; 0 at the end. */
static int
line_next(const char **at, char *l, size_t n)
{
	const char *s = *at, *e;
	size_t len;

	if (!s || !*s)
		return 0;
	e = strchr(s, '\n');
	len = e ? (size_t)(e - s) : strlen(s);
	*at = e ? e + 1 : s + len;
	if (len >= n)
		len = n - 1;
	memcpy(l, s, len);
	l[len] = '\0';
	return 1;
}

int
sa_pppoe_device(const char *pppoe, const char *ppp, char *dev, size_t n)
{
	char l[256], id[64], mac[64], d[64], p[64];
	int first = 1;

	while (line_next(&pppoe, l, sizeof(l))) {
		/* the first line names the columns */
		if (first) {
			first = 0;
			continue;
		}
		if (sscanf(l, "%63s %63s %63s %63s", id, mac, d, p) == 4 && !strcmp(p, ppp)) {
			if (strlen(d) >= n)
				return -1;
			memcpy(dev, d, strlen(d) + 1);
			return 0;
		}
	}
	return -1;
}

int
sa_kept(const char *on_cpu, const char *const *devs, unsigned n)
{
	char l[256];
	unsigned i;

	while (line_next(&on_cpu, l, sizeof(l))) {
		char *scope = strchr(l, '\t'), *dev = scope ? strchr(scope + 1, '\t') : NULL;

		if (!dev || strchr(dev + 1, '\t'))
			continue;
		for (i = 0; i < n; i++)
			if (!strcmp(dev + 1, devs[i]))
				return 1;
	}
	return 0;
}

static int
hex(char *s, size_t n, const uint8_t *b, unsigned len)
{
	unsigned i;

	if (n < 2 * (size_t)len + 1)
		return -1;
	for (i = 0; i < len; i++)
		snprintf(s + 2 * i, 3, "%02x", b[i]);
	s[2 * len] = '\0';
	return 0;
}

int
sa_request(const struct sa_kernel *k, char *s, size_t n)
{
	char src[INET_ADDRSTRLEN], dst[INET_ADDRSTRLEN], key[2 * SA_KEY_MAX + 1],
		akey[2 * SA_KEY_MAX + 1] = "-";
	const char *cipher = "gcm", *auth = "none";
	int a = auth_of(k), w;

	inet_ntop(AF_INET, &k->saddr, src, sizeof(src));
	inet_ntop(AF_INET, &k->daddr, dst, sizeof(dst));
	if (gcm(k)) {
		hex(key, sizeof(key), k->aead_key, k->aead_bits / 8);
	} else {
		cipher = "cbc";
		auth = auths[a].word;
		hex(key, sizeof(key), k->crypt_key, k->crypt_bits / 8);
		hex(akey, sizeof(akey), k->auth_key, k->auth_bits / 8);
	}
	w = snprintf(s, n, "sa-add %s 0x%08x %s %s %u %u %u %s %s %s %s %u %u",
		     k->dir == SA_OUT ? "out" : "in", k->spi, src, dst, k->encap ? k->sport : 0,
		     k->encap ? k->dport : 0, k->reqid, cipher, key, auth, akey,
		     k->dir == SA_IN ? k->replay : 0, k->dir == SA_OUT ? k->oseq + SA_MARGIN : 0);
	return w < 0 || (size_t)w >= n ? -1 : 0;
}

/* The table. */

struct entry {
	struct sa_held h;
	uint32_t next;		/* in its bucket, or in the free list */
};

struct tunnel {
	uint32_t reqid;
	unsigned n;		/* its SAs held */
	uint32_t next;
};

struct sas {
	unsigned max_tunnels, count, ntunnels, mark;
	unsigned resets;	/* a walk ends when one comes */
	uint32_t bucket[BUCKETS], tbucket[BUCKETS];
	struct entry *e;
	struct tunnel *t;
	uint32_t size, tsize, free, tfree;
};

static unsigned
hash(uint32_t a, uint32_t b)
{
	uint64_t x = ((uint64_t)a << 32 | b) * 0x9e3779b97f4a7c15ull;

	return (unsigned)(x >> 51) & (BUCKETS - 1);
}

struct sas *
sas_create(unsigned max_tunnels)
{
	struct sas *s = calloc(1, sizeof(*s));
	unsigned i;

	if (!s)
		return NULL;
	s->max_tunnels = max_tunnels;
	for (i = 0; i < BUCKETS; i++)
		s->bucket[i] = s->tbucket[i] = NONE;
	s->free = s->tfree = NONE;
	return s;
}

void
sas_free(struct sas *s)
{
	if (!s)
		return;
	free(s->e);
	free(s->t);
	free(s);
}

static uint32_t
tunnel_find(const struct sas *s, uint32_t reqid)
{
	uint32_t i;

	for (i = s->tbucket[hash(reqid, 0)]; i != NONE; i = s->t[i].next)
		if (s->t[i].reqid == reqid)
			return i;
	return NONE;
}

int
sas_room(const struct sas *s, uint32_t reqid)
{
	return tunnel_find(s, reqid) != NONE || s->ntunnels < s->max_tunnels;
}

/* A free slot of an array that grows; NONE without memory. */
static uint32_t
slot(void **a, size_t esize, uint32_t *size, uint32_t *free_list, size_t next_off)
{
	uint32_t i;

	if (*free_list == NONE) {
		uint32_t n = *size ? *size * 2 : 64, k;
		void *b = realloc(*a, n * esize);

		if (!b)
			return NONE;
		*a = b;
		for (k = *size; k < n; k++)
			memcpy((char *)b + k * esize + next_off, &(uint32_t){ k + 1 < n ? k + 1 : NONE },
			       sizeof(uint32_t));
		*free_list = *size;
		*size = n;
	}
	i = *free_list;
	memcpy(free_list, (char *)*a + i * esize + next_off, sizeof(uint32_t));
	return i;
}

struct sa_held *
sas_add(struct sas *s, const struct sa_kernel *k)
{
	uint32_t i, t = tunnel_find(s, k->reqid);
	unsigned b = hash(k->spi, k->daddr);

	if (t == NONE) {
		t = slot((void **)&s->t, sizeof(*s->t), &s->tsize, &s->tfree,
			 offsetof(struct tunnel, next));
		if (t == NONE)
			return NULL;
		s->t[t] = (struct tunnel){ .reqid = k->reqid, .next = s->tbucket[hash(k->reqid, 0)] };
		s->tbucket[hash(k->reqid, 0)] = t;
		s->ntunnels++;
	}
	i = slot((void **)&s->e, sizeof(*s->e), &s->size, &s->free, offsetof(struct entry, next));
	if (i == NONE)
		return NULL;
	s->t[t].n++;
	s->e[i] = (struct entry){
		.h = { .spi = k->spi, .saddr = k->saddr, .daddr = k->daddr, .reqid = k->reqid,
		       .dir = k->dir, .sport = k->encap ? k->sport : 0,
		       .dport = k->encap ? k->dport : 0, .seen = s->mark },
		.next = s->bucket[b],
	};
	s->bucket[b] = i;
	s->count++;
	return &s->e[i].h;
}

struct sa_held *
sas_find(struct sas *s, uint32_t spi, uint32_t daddr)
{
	uint32_t i;

	for (i = s->bucket[hash(spi, daddr)]; i != NONE; i = s->e[i].next)
		if (s->e[i].h.spi == spi && s->e[i].h.daddr == daddr)
			return &s->e[i].h;
	return NULL;
}

static void
tunnel_drop(struct sas *s, uint32_t reqid)
{
	uint32_t *p = &s->tbucket[hash(reqid, 0)], i;

	for (i = *p; i != NONE; p = &s->t[i].next, i = *p)
		if (s->t[i].reqid == reqid) {
			if (--s->t[i].n)
				return;
			*p = s->t[i].next;
			s->t[i].next = s->tfree;
			s->tfree = i;
			s->ntunnels--;
			return;
		}
}

void
sas_del(struct sas *s, uint32_t spi, uint32_t daddr)
{
	uint32_t *p = &s->bucket[hash(spi, daddr)], i;

	for (i = *p; i != NONE; p = &s->e[i].next, i = *p)
		if (s->e[i].h.spi == spi && s->e[i].h.daddr == daddr) {
			*p = s->e[i].next;
			tunnel_drop(s, s->e[i].h.reqid);
			s->e[i].next = s->free;
			s->free = i;
			s->count--;
			return;
		}
}

void
sas_reset(struct sas *s)
{
	unsigned max = s->max_tunnels, resets = s->resets + 1;

	free(s->e);
	free(s->t);
	memset(s, 0, sizeof(*s));
	s->max_tunnels = max;
	s->resets = resets;
	memset(s->bucket, 0xff, sizeof(s->bucket));
	memset(s->tbucket, 0xff, sizeof(s->tbucket));
	s->free = s->tfree = NONE;
}

unsigned
sas_count(const struct sas *s)
{
	return s->count;
}

unsigned
sas_tunnels(const struct sas *s)
{
	return s->ntunnels;
}

void
sas_walk(struct sas *s, void (*fn)(struct sa_held *, void *), void *arg)
{
	unsigned b, resets = s->resets;
	uint32_t i, next;

	for (b = 0; b < BUCKETS; b++)
		for (i = s->bucket[b]; i != NONE; i = next) {
			/* fn may let go of it */
			next = s->e[i].next;
			fn(&s->e[i].h, arg);
			if (s->resets != resets)
				return;
		}
}

unsigned
sas_mark(struct sas *s)
{
	return ++s->mark;
}
