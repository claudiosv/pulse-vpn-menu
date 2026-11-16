#ifndef OCSHIM_H
#define OCSHIM_H

#include <stdint.h>

/* Thin wrapper over libopenconnect for a cookie-authenticated Pulse session,
 * mirroring what openconnect's own main() does after authentication, except
 * that libopenconnect never creates a tun device or runs a vpnc-script:
 * make_cstp_connection -> configure callback (the caller applies the network
 * settings and hands back a packet fd) -> setup_tun_fd -> setup_dtls ->
 * mainloop. That is what lets it run inside a sandboxed Network Extension.
 * Everything blocking happens in ocshim_run(); the other entry points are
 * safe to call from any thread. */

typedef struct ocshim ocshim_t;

/* What the server assigned, straight from libopenconnect's oc_ip_info.
 * Everything except gateway_addr is server-provided text: validate it.
 * All pointers are valid only for the duration of the configure call. */
typedef struct {
    const char *gateway_addr;     /* the VPN server's IP address */
    const char *addr;             /* tunnel IPv4 address, or NULL */
    const char *netmask;          /* dotted quad, or NULL */
    const char *addr6;            /* tunnel IPv6 address, or NULL */
    const char *netmask6;         /* "address/prefixlen", or NULL */
    const char *dns[3];           /* unused entries are NULL */
    const char *domain;           /* search domains, space-separated, or NULL */
    int mtu;
    /* Routes as "a.b.c.d/255.255.0.0", "a.b.c.d/16" or "x:y::/64". */
    const char *const *split_includes;
    int n_split_includes;
    const char *const *split_excludes;
    int n_split_excludes;
    const char *const *split_dns;  /* domains to resolve through the tunnel */
    int n_split_dns;
} ocshim_netconfig;

typedef struct {
    /* One line of output (level is PRG_ERR=0, PRG_INFO=1, PRG_DEBUG=2,
     * PRG_TRACE=3). May or may not end in a newline. Human-readable only;
     * nothing needs to parse it — see ocshim_snapshot. */
    void (*log)(void *ctx, int level, const char *msg);
    /* The server has accepted the session and assigned addresses (before
     * DTLS/ESP negotiation). Required. Apply `cfg` to the system, then return
     * a datagram fd that carries the tunnel's packets with utun framing:
     * each datagram is a 4-byte address family in network byte order
     * (AF_INET / AF_INET6) followed by one IP packet. Return a negative
     * errno to abort. The fd stays owned by the caller, who closes it after
     * ocshim_run() returns. May block. */
    int (*configure)(void *ctx, const ocshim_netconfig *cfg);
    /* The server's certificate failed validation and did not match the pin
     * passed to ocshim_run(); the connection is aborted. `hash` is the
     * "pin-sha256:..." fingerprint to pass back as the pin if the user
     * decides to trust it. */
    void (*cert_rejected)(void *ctx, const char *reason, const char *hash);
    /* The snapshot's link state, ESP flag, drop count or tunnel identity
     * changed (not the counters). Called on whichever libopenconnect thread
     * noticed, with no shim locks held; read the new state with
     * ocshim_get_snapshot(). */
    void (*state_changed)(void *ctx);
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
    double sampled_at;            /* unix time of the last counter sample */
    double expires_at;            /* unix time the login expires; 0 if unknown */
    /* Set once the tunnel is up; empty before that. */
    char address[64];             /* the tunnel's IPv4 address, if it has one */
} ocshim_snapshot;

ocshim_t *ocshim_new(const ocshim_callbacks *cb, void *ctx);

/* Blocks until the session ends. `verbose` raises libopenconnect's log level
 * from info to debug. Returns libopenconnect's result:
 * -EINTR user cancel, -EPERM cookie rejected, -EPIPE server ended session,
 * other negative errno for connection/tunnel setup failures.
 * `pinned_cert` (may be NULL) is a "pin-sha256:..." hash; a certificate that
 * fails normal validation is accepted iff it matches. */
int ocshim_run(ocshim_t *s, const char *url, const char *cookie,
               const char *pinned_cert,
               int reconnect_timeout, int dpd_seconds, int verbose);

void ocshim_cancel(ocshim_t *s);             /* ~ SIGTERM */
void ocshim_request_reconnect(ocshim_t *s);  /* ~ SIGUSR2; clears esp_established */

/* Latest state; the counters are as of the last sample. */
void ocshim_get_snapshot(ocshim_t *s, ocshim_snapshot *out);

/* Asks libopenconnect to refresh the counters (~ SIGUSR1). Returns at once;
 * the sample lands in the snapshot (stats_seq increments) a moment later. */
void ocshim_request_stats(ocshim_t *s);

/* Only after ocshim_run() has returned. */
void ocshim_free(ocshim_t *s);

#endif
