/*
 * What bmchwaccel-syncd decides about the SAs of the kernel's xfrm
 * (spec-ipsec: Daemon đồng bộ, Số thứ tự; ADR-0014): whether the engine
 * may hold an SA, the request that hands it over, and which SAs it holds.
 * No I/O: syncd.c reads xfrm, talks to the engine, and writes the engine's
 * numbers and counters into the kernel's SAs.
 *
 * The engine may hold an SA of ESP, IPv4, tunnel mode, without ESN, plain
 * or in UDP (UDP_ENCAP_ESPINUDP), with AES-CBC 128/256 and HMAC-SHA1-96,
 * -SHA256-128, -SHA384-192 or -SHA512-256, or AES-GCM 128/256 with an ICV
 * of 16, not offloaded to a device, without compression; one of the router
 * (an outbound SA leaves from an address of it, an inbound one comes to
 * one) whose way to the peer leaves through a port of the engine, a VLAN
 * on one or a PPPoE session over either, and whose WAN no feature keeps on
 * the CPU (Q15: bmchwaccel keep, bmcqos); an inbound one with an
 * anti-replay window of 128 at most (the SEC's Era 8);
 * an outbound one whose numbers, once the engine starts SA_MARGIN past the
 * kernel's, start below SA_SEQ_LEAVE; and of a tunnel (reqid) the engine
 * holds already, or while it holds fewer than the most tunnels.
 *
 * The engine numbers nothing past SA_SEQ_MAX (IPSEC_SEQ_MAX of the engine,
 * Q12). The daemon lets go of an outbound SA in order once the engine's
 * number reaches SA_SEQ_LEAVE (sa_seq_leave()), before that: the kernel goes
 * on from SA_MARGIN past it, and strongSwan rekeys on its own.
 *
 * Addresses are in network byte order; SPIs, ports and numbers in host
 * order.
 */
#ifndef BMCHWACCEL_SA_H
#define BMCHWACCEL_SA_H

#include <stddef.h>
#include <stdint.h>

#define SA_MARGIN (1u << 24)	/* the engine's numbers start this far past the kernel's */
#define SA_SEQ_MAX ((uint32_t)-(1u << 26))	/* 2^32 - 2^26: the engine stays below (Q12) */
/* 2^22 numbers before it: 4 s of the fastest SA (spec: about 1 Mpps), 4 ticks of the daemon */
#define SA_SEQ_LEAVE (SA_SEQ_MAX - (1u << 22))
#define SA_MAX_TUNNELS 4096	/* Q16, as IPSEC_MAX_TUNNELS of the engine */
#define SA_KEY_MAX 64

enum sa_dir { SA_OUT, SA_IN, SA_NEITHER };

/* An SA as a message of xfrm gives it, with what syncd.c found out about it. */
struct sa_kernel {
	int ipv4;		/* the outer addresses and the selector are IPv4 */
	int esp, tunnel, esn, offload, comp;
	uint32_t spi;
	uint32_t saddr, daddr;
	uint32_t reqid;
	enum sa_dir dir;	/* whose address the router has */
	int via_engine;		/* the way to the peer leaves through a port of the engine */
	int kept;		/* a device on that way is kept on the CPU (Q15) */
	uint16_t encap;		/* the type of XFRMA_ENCAP, 0 without */
	uint16_t sport, dport;	/* of ESP in UDP */
	/* the algorithms by their names in xfrm, "" without; bits of key, of ICV */
	char crypt[64], auth[64], aead[64];
	unsigned crypt_bits, auth_bits, trunc_bits, aead_bits, icv_bits;
	uint8_t crypt_key[SA_KEY_MAX], auth_key[SA_KEY_MAX], aead_key[SA_KEY_MAX];
	uint32_t replay;	/* the anti-replay window */
	uint32_t oseq;		/* the last number the kernel used */
};

/*
 * Why the engine may not hold the SA, for the log; NULL when it may.
 * new_tunnel: whether there is room for one more tunnel, should the SA be
 * of one the engine does not hold yet (sas_room()).
 */
const char *sa_why(const struct sa_kernel *k, int new_tunnel);

/*
 * The way to the peer, for via_engine and kept (syncd.c reads the files):
 * sa_pppoe_device() gives in dev the device under the PPPoE session of the
 * PPP device ppp, from the text of /proc/net/pppoe (the kernel 6.12 of the
 * board lists Id, Address, Device, PPPDevice, Unit): 0, or -1 when ppp is
 * no session's or dev too small. sa_kept() says whether one of the n
 * devices of devs is registered in the text of /var/run/bmcHwAccel/on_cpu
 * (keep.sh of bmcHwAccel: a line of reason, scope and device,
 * tab-separated, for each feature that keeps a WAN on the CPU); the
 * devices of the way are the interface the kernel sends to the peer
 * through and those under it, as keep.sh covers what is stacked on the
 * device registered.
 */
int sa_pppoe_device(const char *pppoe, const char *ppp, char *dev, size_t n);
int sa_kept(const char *on_cpu, const char *const *devs, unsigned n);

/*
 * The request that hands the SA over (ctl.c, sa-add), without its newline:
 * an outbound SA starts at the kernel's oseq + SA_MARGIN. 0, or -1 when n
 * is too small.
 */
int sa_request(const struct sa_kernel *k, char *s, size_t n);

/* What the kernel's oseq becomes for the last number the engine may have used. */
static inline uint32_t
sa_kernel_oseq(uint32_t engine_last)
{
	return engine_last + SA_MARGIN;
}

/* Whether the engine, at engine_last, numbered an outbound SA close enough to the end. */
static inline int
sa_seq_leave(uint32_t engine_last)
{
	return engine_last >= SA_SEQ_LEAVE;
}

/* An SA the engine holds. */
struct sa_held {
	uint32_t spi, saddr, daddr, reqid;
	enum sa_dir dir;
	uint16_t sport, dport;	/* of ESP in UDP, as handed over */
	/* what of the engine's counters was added to the kernel's already */
	uint64_t bytes, packets;
	unsigned seen;		/* the dump that last saw it (sas_mark()) */
};

struct sas;

struct sas *sas_create(unsigned max_tunnels);
void sas_free(struct sas *s);

/* Whether an SA of reqid may be held: its tunnel is held, or there is room for one more. */
int sas_room(const struct sas *s, uint32_t reqid);
/* Held from now on; NULL without memory. */
struct sa_held *sas_add(struct sas *s, const struct sa_kernel *k);
struct sa_held *sas_find(struct sas *s, uint32_t spi, uint32_t daddr);
void sas_del(struct sas *s, uint32_t spi, uint32_t daddr);
/* The engine holds none any more (it went away, or let go of all). */
void sas_reset(struct sas *s);
unsigned sas_count(const struct sas *s);
unsigned sas_tunnels(const struct sas *s);
/*
 * Calls fn for each SA held; fn may sas_del() the one it is given, or
 * sas_reset() (the engine went away meanwhile), which ends the walk.
 */
void sas_walk(struct sas *s, void (*fn)(struct sa_held *, void *), void *arg);

/*
 * A dump of the kernel's SAs again (events were lost): sas_mark() starts
 * it, each SA of the dump that is held gets h->seen = the number returned,
 * and those held with another number afterwards are gone from the kernel.
 */
unsigned sas_mark(struct sas *s);

#endif
