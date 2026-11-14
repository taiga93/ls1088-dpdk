/*
 * What bmchwaccel-syncd decides about the SAs of xfrm (src/sa.h): which ones
 * the engine may hold, the request that hands one over, the SAs and the
 * tunnels it holds. No DPDK, no netlink.
 *
 *   sa_test [TEST...]
 */
#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>

#include "../../src/sa.h"
#include "testlib.h"

static uint32_t
addr(const char *s)
{
	uint32_t a;

	inet_pton(AF_INET, s, &a);
	return a;
}

/* The VPN page's outbound SA: aes256-cbc + hmac-sha256-128, ESP in UDP 4500, through eth0. */
static struct sa_kernel
vpn(void)
{
	struct sa_kernel k = {
		.ipv4 = 1, .esp = 1, .tunnel = 1,
		.spi = 0xc0000001, .saddr = addr("192.168.2.10"), .daddr = addr("192.168.2.1"),
		.reqid = 1, .dir = SA_OUT, .via_engine = 1,
		.encap = 2, .sport = 4500, .dport = 4500,
		.crypt = "cbc(aes)", .crypt_bits = 256,
		.auth = "hmac(sha256)", .auth_bits = 256, .trunc_bits = 128,
		.replay = 32, .oseq = 5,
	};
	unsigned i;

	for (i = 0; i < 32; i++) {
		k.crypt_key[i] = (uint8_t)(0x10 + i);
		k.auth_key[i] = (uint8_t)(0x40 + i);
	}
	return k;
}

static struct sa_kernel
inbound(void)
{
	struct sa_kernel k = vpn();

	k.spi = 0xc0000002;
	k.saddr = addr("192.168.2.1");
	k.daddr = addr("192.168.2.10");
	k.dir = SA_IN;
	return k;
}

static struct sa_kernel
gcm(void)
{
	struct sa_kernel k = vpn();
	unsigned i;

	*k.crypt = *k.auth = '\0';
	k.crypt_bits = k.auth_bits = k.trunc_bits = 0;
	strcpy(k.aead, "rfc4106(gcm(aes))");
	k.aead_bits = 288;
	k.icv_bits = 128;
	for (i = 0; i < 36; i++)
		k.aead_key[i] = (uint8_t)(0x10 + i);
	return k;
}

TEST(the_sas_of_the_vpn_page_may_go_to_the_engine)
{
	struct sa_kernel out = vpn(), in = inbound();

	CHECK(!sa_why(&out, 1));
	CHECK(!sa_why(&in, 1));
}

TEST(each_algorithm_of_the_spec_may_go_and_none_other)
{
	static const struct { const char *auth; unsigned bits, trunc; int ok; } a[] = {
		{ "hmac(sha1)", 160, 96, 1 }, { "hmac(sha256)", 256, 128, 1 },
		{ "hmac(sha384)", 384, 192, 1 }, { "hmac(sha512)", 512, 256, 1 },
		/* the truncation of an old proposal, a key of another length, MD5 */
		{ "hmac(sha256)", 256, 96, 0 }, { "hmac(sha1)", 128, 96, 0 }, { "hmac(md5)", 128, 96, 0 },
	};
	struct sa_kernel k;
	unsigned i, bits;

	for (i = 0; i < sizeof(a) / sizeof(a[0]); i++) {
		k = vpn();
		strcpy(k.auth, a[i].auth);
		k.auth_bits = a[i].bits;
		k.trunc_bits = a[i].trunc;
		CHECK((sa_why(&k, 1) == NULL) == a[i].ok);
	}
	for (bits = 128; bits <= 256; bits += 64) {
		k = vpn();
		k.crypt_bits = bits;
		CHECK((sa_why(&k, 1) == NULL) == (bits != 192));
	}
	k = vpn();
	strcpy(k.crypt, "cbc(des3_ede)");
	k.crypt_bits = 192;
	CHECK(sa_why(&k, 1));
	k = gcm();
	CHECK(!sa_why(&k, 1));
	k.aead_bits = 160;
	CHECK(!sa_why(&k, 1));
	k.icv_bits = 64;
	CHECK(sa_why(&k, 1));
	k = gcm();
	strcpy(k.aead, "rfc7539esp(chacha20,poly1305)");
	CHECK(!strcmp(sa_why(&k, 1), "algorithms the hardware does not do"));
}

TEST(what_the_spec_leaves_to_the_kernel_stays_there)
{
	struct sa_kernel k;

	k = vpn(), k.ipv4 = 0;
	CHECK(!strcmp(sa_why(&k, 1), "not IPv4"));
	k = vpn(), k.esp = 0;
	CHECK(!strcmp(sa_why(&k, 1), "not ESP"));
	k = vpn(), k.tunnel = 0;
	CHECK(!strcmp(sa_why(&k, 1), "not tunnel mode"));
	k = vpn(), k.esn = 1;
	CHECK(!strcmp(sa_why(&k, 1), "extended sequence numbers"));
	k = vpn(), k.offload = 1;
	CHECK(sa_why(&k, 1));
	k = vpn(), k.comp = 1;
	CHECK(sa_why(&k, 1));
	k = vpn(), k.encap = 1;		/* UDP_ENCAP_ESPINUDP_NON_IKE */
	CHECK(sa_why(&k, 1));
	k = vpn(), k.encap = 0, k.sport = k.dport = 0;
	CHECK(!sa_why(&k, 1));
	k = vpn(), k.dir = SA_NEITHER;
	CHECK(!strcmp(sa_why(&k, 1), "not of an address of the router"));
	k = vpn(), k.via_engine = 0;
	CHECK(!strcmp(sa_why(&k, 1), "not through a port of Tăng tốc phần cứng"));
}

/* Q15: bmcqos shapes the WAN of the tunnel (bmchwaccel keep): its SAs stay with the kernel. */
TEST(an_sa_of_a_wan_kept_on_the_cpu_stays_with_the_kernel)
{
	struct sa_kernel k = vpn(), in = inbound();

	k.kept = 1;
	in.kept = 1;
	CHECK(!strcmp(sa_why(&k, 1), "its WAN is kept on the CPU"));
	CHECK(!strcmp(sa_why(&in, 1), "its WAN is kept on the CPU"));
	/* the port first: a WAN on a 1G port is kept or not, it never goes */
	k.via_engine = 0;
	CHECK(!strcmp(sa_why(&k, 1), "not through a port of Tăng tốc phần cứng"));
}

/* /proc/net/pppoe of the kernel 6.12 of the board: 5 columns, the PPP device in the 4th. */
static const char pppoe[] =
	"Id       Address              Device   PPPDevice  Unit\n"
	"00000001 02:00:00:00:00:10    eth0.30  pppoe-wan  0\n"
	"00000002 02:00:00:00:00:11       eth4  pppoe-wan2 1\n";

TEST(the_device_of_a_pppoe_session_is_read_from_the_kernel)
{
	char dev[16];

	CHECK(!sa_pppoe_device(pppoe, "pppoe-wan", dev, sizeof(dev)));
	CHECK(!strcmp(dev, "eth0.30"));
	CHECK(!sa_pppoe_device(pppoe, "pppoe-wan2", dev, sizeof(dev)));
	CHECK(!strcmp(dev, "eth4"));
	/* not a session: a device of no PPPoE, the header, a name that only starts the same */
	CHECK(sa_pppoe_device(pppoe, "eth0", dev, sizeof(dev)) == -1);
	CHECK(sa_pppoe_device(pppoe, "PPPDevice", dev, sizeof(dev)) == -1);
	CHECK(sa_pppoe_device(pppoe, "pppoe-wa", dev, sizeof(dev)) == -1);
	CHECK(sa_pppoe_device("Id Address Device PPPDevice Unit\n", "pppoe-wan", dev, sizeof(dev)) == -1);
	CHECK(sa_pppoe_device("", "pppoe-wan", dev, sizeof(dev)) == -1);
	/* a session that is not on a device yet, a name too long for dev */
	CHECK(sa_pppoe_device("Id Address Device PPPDevice Unit\n00000003 02:00:00:00:00:12\n",
			      "pppoe-wan", dev, sizeof(dev)) == -1);
	CHECK(sa_pppoe_device(pppoe, "pppoe-wan", dev, 4) == -1);
}

/* The registrations of /var/run/bmcHwAccel/on_cpu: reason, scope and device, tab-separated. */
TEST(the_wan_of_an_sa_is_kept_when_a_device_on_its_way_is_registered)
{
	const char *on_cpu = "bmcqos\twan\teth0\nother\twan\teth2\n";
	const char *vlan_pppoe[] = { "pppoe-wan", "eth0.30", "eth0" };
	const char *plain[] = { "eth0" };
	const char *other[] = { "eth1", "eth0.30" };
	const char *partly[] = { "eth00" };

	CHECK(sa_kept(on_cpu, vlan_pppoe, 3));
	CHECK(sa_kept(on_cpu, plain, 1));
	CHECK(!sa_kept(on_cpu, other, 2));
	CHECK(!sa_kept(on_cpu, partly, 1));
	CHECK(!sa_kept("", plain, 1));
	CHECK(!sa_kept(NULL, plain, 1));
	/* a line of another shape is no registration */
	CHECK(!sa_kept("eth0\n", plain, 1));
	CHECK(!sa_kept("bmcqos\twan\n", plain, 1));
	CHECK(!sa_kept("bmcqos\twan\teth0\textra\n", plain, 1));
	/* the last line without its newline still counts */
	CHECK(sa_kept("bmcqos\twan\teth0", plain, 1));
}

TEST(an_inbound_sa_with_a_window_above_128_stays_with_the_kernel)
{
	struct sa_kernel k = inbound();

	k.replay = 128;
	CHECK(!sa_why(&k, 1));
	k.replay = 256;
	CHECK(!strcmp(sa_why(&k, 1), "an anti-replay window above 128"));
	/* an outbound SA numbers, it has no window to keep */
	k = vpn();
	k.replay = 1024;
	CHECK(!sa_why(&k, 1));
}

/*
 * Q12: not handed over when the engine would start at SA_SEQ_LEAVE or past
 * it, where the daemon lets go of it again (below).
 */
TEST(an_outbound_sa_near_the_end_of_its_numbers_stays_with_the_kernel)
{
	struct sa_kernel k = vpn();

	k.oseq = SA_SEQ_LEAVE - SA_MARGIN - 1;
	CHECK(!sa_why(&k, 1));
	k.oseq++;
	CHECK(!strcmp(sa_why(&k, 1), "sequence numbers near their end"));
	/* an inbound one has no numbers of its own */
	k = inbound();
	k.oseq = UINT32_MAX;
	CHECK(!sa_why(&k, 1));
}

/*
 * Q12: the daemon lets go of an outbound SA in order once the engine's
 * number reaches SA_SEQ_LEAVE, some seconds of the fastest SA before the
 * engine's SA_SEQ_MAX; the kernel goes on from SA_MARGIN past it, still
 * below 2^32.
 */
TEST(an_outbound_sa_whose_numbers_near_their_end_goes_back_to_the_kernel)
{
	CHECK(!sa_seq_leave(SA_SEQ_LEAVE - 1));
	CHECK(sa_seq_leave(SA_SEQ_LEAVE));
	CHECK(sa_seq_leave(SA_SEQ_MAX));
	CHECK(SA_SEQ_MAX - SA_SEQ_LEAVE >= 4u << 20);
	CHECK((uint64_t)SA_SEQ_MAX + SA_MARGIN < 1ull << 32);
}

TEST(the_request_hands_over_the_keys_and_the_engines_first_number)
{
	struct sa_kernel out = vpn(), in = inbound(), g = gcm();
	char s[512];

	CHECK(sa_request(&out, s, sizeof(s)) == 0);
	CHECK(!strcmp(s, "sa-add out 0xc0000001 192.168.2.10 192.168.2.1 4500 4500 1 cbc "
			 "101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f sha256 "
			 "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f 0 16777221"));
	CHECK(sa_request(&in, s, sizeof(s)) == 0);
	CHECK(!strncmp(s, "sa-add in 0xc0000002 192.168.2.1 192.168.2.10 4500 4500 1 cbc ", 62));
	CHECK(!strcmp(s + strlen(s) - 5, " 32 0"));
	g.encap = 0;
	CHECK(sa_request(&g, s, sizeof(s)) == 0);
	CHECK(!strcmp(s, "sa-add out 0xc0000001 192.168.2.10 192.168.2.1 0 0 1 gcm "
			 "101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30313233 "
			 "none - 0 16777221"));
	CHECK(sa_request(&out, s, 40) == -1);
	CHECK(sa_kernel_oseq(16777221) == 33554437);
}

TEST(the_sas_held_are_found_and_let_go_of)
{
	struct sas *s = sas_create(4);
	struct sa_kernel out = vpn(), in = inbound();
	struct sa_held *h;

	CHECK(s);
	CHECK(sas_add(s, &out) && sas_add(s, &in));
	CHECK(sas_count(s) == 2 && sas_tunnels(s) == 1);
	h = sas_find(s, out.spi, out.daddr);
	CHECK(h && h->dir == SA_OUT && h->reqid == 1 && h->saddr == out.saddr);
	CHECK(!sas_find(s, out.spi, in.daddr));
	sas_del(s, out.spi, out.daddr);
	CHECK(!sas_find(s, out.spi, out.daddr) && sas_find(s, in.spi, in.daddr));
	CHECK(sas_count(s) == 1 && sas_tunnels(s) == 1);
	sas_del(s, in.spi, in.daddr);
	CHECK(sas_count(s) == 0 && sas_tunnels(s) == 0);
	sas_free(s);
}

TEST(no_sa_of_a_tunnel_past_the_most_tunnels)
{
	struct sas *s = sas_create(2);
	struct sa_kernel k = vpn();

	CHECK(s);
	for (k.reqid = 1; k.reqid <= 2; k.reqid++) {
		k.spi = 0x100 + k.reqid;
		CHECK(sas_room(s, k.reqid));
		CHECK(sas_add(s, &k));
	}
	CHECK(!sas_room(s, 3));
	CHECK(!strcmp(sa_why(&k, sas_room(s, 3)), "the most tunnels already"));
	/* another SA of a tunnel held: a rekey */
	CHECK(sas_room(s, 2));
	sas_del(s, 0x102, k.daddr);
	CHECK(sas_room(s, 3));
	sas_free(s);
}

static void
count_one(struct sa_held *h, void *arg)
{
	(void)h;
	(*(unsigned *)arg)++;
}

static void
drop_one(struct sa_held *h, void *arg)
{
	sas_del(arg, h->spi, h->daddr);
}

TEST(many_sas_come_and_go)
{
	struct sas *s = sas_create(SA_MAX_TUNNELS);
	struct sa_kernel k = vpn();
	unsigned i, n = 0;

	CHECK(s);
	for (i = 0; i < 24576; i++) {
		k.spi = 0x10000 + i;
		k.reqid = i / 6;
		CHECK(sas_add(s, &k));
	}
	CHECK(sas_count(s) == 24576 && sas_tunnels(s) == SA_MAX_TUNNELS);
	CHECK(!sas_room(s, 99999));
	for (i = 0; i < 24576; i += 2)
		sas_del(s, 0x10000 + i, k.daddr);
	for (i = 0; i < 24576; i++)
		CHECK((sas_find(s, 0x10000 + i, k.daddr) != NULL) == (i & 1));
	sas_walk(s, count_one, &n);
	CHECK(n == 12288);
	sas_walk(s, drop_one, s);
	CHECK(sas_count(s) == 0 && sas_tunnels(s) == 0);
	k.spi = 1;
	CHECK(sas_add(s, &k) && sas_count(s) == 1);
	sas_reset(s);
	CHECK(sas_count(s) == 0 && !sas_find(s, 1, k.daddr));
	CHECK(sas_add(s, &k) && sas_count(s) == 1);
	sas_free(s);
}

struct reset_arg {
	struct sas *s;
	unsigned seen;
};

static void
reset_one(struct sa_held *h, void *arg)
{
	struct reset_arg *a = arg;

	(void)h;
	a->seen++;
	sas_reset(a->s);
}

/* The engine went away while the SAs were walked: the walk ends there. */
TEST(a_walk_ends_when_the_sas_are_reset)
{
	struct sas *s = sas_create(4);
	struct sa_kernel k = vpn();
	struct reset_arg a = { s, 0 };

	CHECK(s && sas_add(s, &k));
	k.spi++;
	CHECK(sas_add(s, &k));
	sas_walk(s, reset_one, &a);
	CHECK(a.seen == 1 && sas_count(s) == 0);
	sas_free(s);
}

TEST(a_dump_again_tells_the_sas_gone_from_the_kernel)
{
	struct sas *s = sas_create(4);
	struct sa_kernel a = vpn(), b = inbound();
	unsigned m;

	CHECK(s && sas_add(s, &a) && sas_add(s, &b));
	m = sas_mark(s);
	sas_find(s, a.spi, a.daddr)->seen = m;
	CHECK(sas_find(s, a.spi, a.daddr)->seen == m && sas_find(s, b.spi, b.daddr)->seen != m);
	sas_free(s);
}

int
main(int argc, char **argv)
{
	return test_main(argc - 1, argv + 1);
}
