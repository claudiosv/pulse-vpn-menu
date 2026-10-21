#ifndef OCSHIM_H
#define OCSHIM_H

#include <stdint.h>

/* Thin wrapper over libopenconnect for a cookie-authenticated Pulse session,
 * mirroring what openconnect's own main() does after authentication:
 * make_cstp_connection -> setup_tun_device (runs the vpnc-script) ->
 * setup_dtls -> mainloop. Everything blocking happens in ocshim_run();
 * the other entry points are safe to call from any thread. */

typedef struct ocshim ocshim_t;

typedef struct {
    /* One line of output (level is PRG_ERR=0, PRG_INFO=1, PRG_DEBUG=2,
     * PRG_TRACE=3). May or may not end in a newline. Human-readable only;
     * nothing needs to parse it — see ocshim_snapshot. */
    void (*log)(void *ctx, int level, const char *msg);
    /* Tunnel is up (before DTLS/ESP negotiation). Strings valid only for the
     * duration of the call; any may be NULL. */
    void (*connected)(void *ctx, const char *addr, const char *netmask,
                      const char *gateway, int mtu);
    /* The server's certificate failed validation and did not match the pin
     * passed to ocshim_run(); the connection is aborted. `hash` is the
     * "pin-sha256:..." fingerprint to pass back as the pin if the user
     * decides to trust it. */
    void (*cert_rejected)(void *ctx, const char *reason, const char *hash);
} ocshim_callbacks;

enum {
    OCSHIM_LINK_CONNECTING = 0,   /* before the tunnel is up */
    OCSHIM_LINK_UP = 1,
    OCSHIM_LINK_RECONNECTING = 2, /* link lost, libopenconnect retrying */
};

/* Typed session state, replacing what used to be scraped from log lines. */
typedef struct {
    int link_state;               /* OCSHIM_LINK_* */
    int esp_established;          /* ESP (UDP) data channel negotiated */
    uint32_t drop_count;          /* UP -> RECONNECTING transitions so far */
    uint64_t stats_seq;           /* increments on every fresh counter sample */
    uint64_t tx_pkts, tx_bytes, rx_pkts, rx_bytes;   /* cumulative */
} ocshim_snapshot;

ocshim_t *ocshim_new(const ocshim_callbacks *cb, void *ctx);

/* Blocks until the session ends. Returns libopenconnect's result:
 * -EINTR user cancel, -EPERM cookie rejected, -EPIPE server ended session,
 * other negative errno for connection/tunnel setup failures.
 * `pinned_cert` (may be NULL) is a "pin-sha256:..." hash; a certificate that
 * fails normal validation is accepted iff it matches. */
int ocshim_run(ocshim_t *s, const char *url, const char *cookie,
               const char *vpnc_script, const char *pinned_cert,
               int reconnect_timeout, int dpd_seconds);

void ocshim_cancel(ocshim_t *s);             /* ~ SIGTERM */
void ocshim_request_reconnect(ocshim_t *s);  /* ~ SIGUSR2; clears esp_established */

/* Latest state; the counters are as of the last sample. */
void ocshim_get_snapshot(ocshim_t *s, ocshim_snapshot *out);

/* Asks libopenconnect for fresh counters (~ SIGUSR1) and waits up to
 * `timeout_ms` for them. Fills `out` either way; returns 1 if the sample
 * is new, 0 on timeout or if the session ended. */
int ocshim_poll_stats(ocshim_t *s, int timeout_ms, ocshim_snapshot *out);

/* Only after ocshim_run() has returned. */
void ocshim_free(ocshim_t *s);

#endif
