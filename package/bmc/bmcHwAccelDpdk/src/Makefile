# bmchwaccel-engine, linked with DPDK statically, as pkg-config finds it
# (the package Makefile points it at the staging directory); bmchwaccel-ctl,
# its client, and bmchwaccel-syncd, the daemon that hands connections over,
# without DPDK.

PKG_CONFIG ?= pkg-config
DPDK_CFLAGS := $(shell $(PKG_CONFIG) --cflags libdpdk)
DPDK_LIBS := $(shell $(PKG_CONFIG) --static --libs libdpdk)
CFLAGS ?= -O3
# after CFLAGS, which the package gives on the command line: the -mcpu of
# libdpdk.pc wins
ALL_CFLAGS = $(CFLAGS) -std=gnu11 -Wall -Wextra -Wno-address-of-packed-member \
	-DALLOW_EXPERIMENTAL_API $(DPDK_CFLAGS)

all: bmchwaccel-engine bmchwaccel-ctl bmchwaccel-syncd

# esp_sec.o: "ESP ops" on the SEC (dpaa2_sec); the tests link an OpenSSL one
bmchwaccel-engine: engine.o ctl.o core.o esp.o ipsec.o esp_sec.o
	$(CC) $(LDFLAGS) -o $@ $^ $(DPDK_LIBS)

bmchwaccel-ctl: ctl-client.c ctl.h
	$(CC) $(CFLAGS) -std=gnu11 -Wall -Wextra $(LDFLAGS) -o $@ ctl-client.c

bmchwaccel-syncd: syncd.c sync.c sync.h watch.c watch.h sa.c sa.h ctl.h
	$(CC) $(CFLAGS) -std=gnu11 -Wall -Wextra $(LDFLAGS) -o $@ syncd.c sync.c watch.c sa.c \
		-lnetfilter_conntrack -lnfnetlink

%.o: %.c *.h
	$(CC) $(ALL_CFLAGS) -c -o $@ $<

clean:
	rm -f bmchwaccel-engine bmchwaccel-ctl bmchwaccel-syncd *.o

.PHONY: all clean
