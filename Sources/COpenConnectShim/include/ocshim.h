#ifndef OCSHIM_H
#define OCSHIM_H

#include <stdint.h>

/* Thin wrapper over libopenconnect for a cookie-authenticated Pulse session,
 * mirroring what openconnect's own main() does after authentication:
 * make_cstp_connection -> setup_tun_device (runs the vpnc-script) ->
 * setup_dtls -> mainloop. Everything blocking happens in ocshim_run();
 * the other entry points are safe to call from any thread.
 *
 * The status lines the CLI printed on each stats dump ("Configured as ...",
 * "RX: ... TX: ...", "SSL ciphersuite: ...", "Session authentication will
 * expire at ...") are emitted through the log callback in the same format,
 * since the app's log parser keys off them. */

typedef struct ocshim ocshim_t;

typedef struct {
    /* One line of output (level is PRG_ERR=0, PRG_INFO=1, PRG_DEBUG=2,
     * PRG_TRACE=3). May or may not end in a newline. */
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
void ocshim_request_stats(ocshim_t *s);      /* ~ SIGUSR1: logs the lines above */
void ocshim_request_reconnect(ocshim_t *s);  /* ~ SIGUSR2 */

/* Only after ocshim_run() has returned. */
void ocshim_free(ocshim_t *s);

#endif
