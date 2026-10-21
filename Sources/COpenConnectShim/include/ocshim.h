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
    /* One line of libopenconnect output (no trailing newline guaranteed to be
     * stripped; level is PRG_ERR=0, PRG_INFO=1, PRG_DEBUG=2, PRG_TRACE=3). */
    void (*log)(void *ctx, int level, const char *msg);
    /* Reply to ocshim_request_stats(). */
    void (*stats)(void *ctx, uint64_t tx_pkts, uint64_t tx_bytes,
                  uint64_t rx_pkts, uint64_t rx_bytes);
    /* Tunnel is up (before DTLS/ESP negotiation). Strings valid only for the
     * duration of the call; any may be NULL. */
    void (*connected)(void *ctx, const char *addr, const char *netmask,
                      const char *gateway, int mtu);
} ocshim_callbacks;

ocshim_t *ocshim_new(const ocshim_callbacks *cb, void *ctx);

/* Blocks until the session ends. Returns libopenconnect's result:
 * -EINTR user cancel, -EPERM cookie rejected, -EPIPE server ended session,
 * other negative errno for connection/tunnel setup failures. */
int ocshim_run(ocshim_t *s, const char *url, const char *cookie,
               const char *vpnc_script, int reconnect_timeout, int dpd_seconds);

void ocshim_cancel(ocshim_t *s);             /* ~ SIGTERM */
void ocshim_request_stats(ocshim_t *s);      /* ~ SIGUSR1 */
void ocshim_request_reconnect(ocshim_t *s);  /* ~ SIGUSR2 */

/* Only after ocshim_run() has returned. */
void ocshim_free(ocshim_t *s);

#endif
