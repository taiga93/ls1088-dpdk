/*
 * The test backend of "ESP ops" (src/esp.h): ESP made with OpenSSL on the
 * build machine, as the SEC makes it through dpaa2_sec: tunnel mode, IPv4,
 * plain ESP or ESP in UDP, AES-CBC with HMAC-SHA1/256/384/512 and AES-GCM.
 * Its outer header is the one the SEC writes (TTL 64, DSCP and DF of the
 * inner packet, an IP id of each SA from 0, UDP checksum 0); the padding
 * is RFC 4303's 1, 2, 3...; the IV is made from the SPI and the sequence
 * number, so that the same packets make the same ESP.
 *
 * Each queue pair is a queue: a job is done when it is enqueued and its
 * result waits there until polled, in order. By default poll() returns
 * every result; esp_openssl_hold() makes the queue pairs give results back
 * only as esp_openssl_release() lets them, like a SEC that has finished
 * that many jobs of the queue pair.
 */
#ifndef BMCHWACCEL_ESP_OPENSSL_H
#define BMCHWACCEL_ESP_OPENSSL_H

#include "../../src/esp.h"

#define ESP_OPENSSL_QP_DEPTH 2048	/* jobs a queue pair holds */

struct esp_dev *esp_openssl_create(unsigned nworkers, unsigned max_sa, unsigned nqp);
void esp_openssl_hold(struct esp_dev *d, int hold);
/* n more results of queue pair q of worker w may come back */
void esp_openssl_release(struct esp_dev *d, unsigned w, unsigned q, unsigned n);
/* the jobs in queue pair q of worker w, not yet polled */
unsigned esp_openssl_queued(struct esp_dev *d, unsigned w, unsigned q);

#endif
