# The test programs, built for the machine the tests run on, with the DPDK of
# host-dpdk.sh (run.sh sets PKG_CONFIG_PATH). Objects go to $(OUT).

SRC := ../src
OUT ?= out

DPDK_CFLAGS := $(shell pkg-config --cflags libdpdk)
DPDK_LIBS := $(shell pkg-config --static --libs libdpdk)
CFLAGS ?= -O2 -g
ALL_CFLAGS = $(CFLAGS) -std=gnu11 -Wall -Wextra -Werror -Wno-address-of-packed-member \
	-DALLOW_EXPERIMENTAL_API $(DPDK_CFLAGS)
# the tests override fields of default packets (TCP(...), UDP(...)), which
# gcc 9 also reports as missing initializers
TEST_CFLAGS := -Wno-override-init -Wno-override-init-side-effects -Wno-missing-field-initializers

all: $(OUT)/core_test $(OUT)/esp_test $(OUT)/ipsec_test $(OUT)/sync_test $(OUT)/watch_test $(OUT)/sa_test $(OUT)/bmchwaccel-engine $(OUT)/bmchwaccel-ctl $(OUT)/feeder

$(OUT)/%.o: $(SRC)/%.c $(SRC)/*.h | $(OUT)
	$(CC) $(ALL_CFLAGS) -c -o $@ $<

$(OUT)/%.o: unit/%.c unit/*.h $(SRC)/*.h esp/*.h | $(OUT)
	$(CC) $(ALL_CFLAGS) $(TEST_CFLAGS) -c -o $@ $<

$(OUT)/%.o: functional/%.c | $(OUT)
	$(CC) $(ALL_CFLAGS) -c -o $@ $<

# the OpenSSL backend of "ESP ops", in place of the SEC
$(OUT)/%.o: esp/%.c esp/*.h $(SRC)/*.h | $(OUT)
	$(CC) $(ALL_CFLAGS) -c -o $@ $<

$(OUT)/core_test: $(OUT)/core_test.o $(OUT)/testlib.o $(OUT)/core.o
	$(CC) -o $@ $^ $(DPDK_LIBS)

$(OUT)/esp_test: $(OUT)/esp_test.o $(OUT)/testlib.o $(OUT)/esp.o $(OUT)/esp_openssl.o
	$(CC) -o $@ $^ $(DPDK_LIBS) -lcrypto

$(OUT)/ipsec_test: $(OUT)/ipsec_test.o $(OUT)/testlib.o $(OUT)/ipsec.o $(OUT)/esp.o $(OUT)/esp_openssl.o $(OUT)/core.o
	$(CC) -o $@ $^ $(DPDK_LIBS) -lcrypto

# the decisions of bmchwaccel-syncd: no DPDK, no conntrack library
$(OUT)/sync_test: $(OUT)/sync_test.o $(OUT)/testlib.o $(OUT)/sync.o
	$(CC) -o $@ $^

# what bmchwaccel-syncd decides about the SAs of xfrm: no DPDK either
$(OUT)/sa_test: $(OUT)/sa_test.o $(OUT)/testlib.o $(OUT)/sa.o
	$(CC) -o $@ $^

# what bmchwaccel-syncd does when the routing changes: no DPDK either
$(OUT)/watch_test: $(OUT)/watch_test.o $(OUT)/testlib.o $(OUT)/watch.o
	$(CC) -o $@ $^

# with the OpenSSL backend of "ESP ops" in place of esp_sec.c
$(OUT)/bmchwaccel-engine: $(OUT)/engine.o $(OUT)/ctl.o $(OUT)/core.o $(OUT)/esp.o $(OUT)/ipsec.o $(OUT)/esp_openssl.o
	$(CC) -o $@ $^ $(DPDK_LIBS) -lcrypto

$(OUT)/bmchwaccel-ctl: $(SRC)/ctl-client.c $(SRC)/ctl.h | $(OUT)
	$(CC) $(CFLAGS) -std=gnu11 -Wall -Wextra -Werror -o $@ $<

$(OUT)/feeder: $(OUT)/feeder.o
	$(CC) -o $@ $^ $(DPDK_LIBS)

$(OUT):
	mkdir -p $@

clean:
	rm -rf $(OUT)

.PHONY: all clean
