#include "ocshim.h"

#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "openconnect.h"

struct ocshim {
    ocshim_callbacks cb;
    void *ctx;
    struct openconnect_info *vpninfo;
    _Atomic int cmd_fd; /* -1 until ocshim_run() has set up the command pipe */
};

static void emit(struct ocshim *s, int level, const char *msg)
{
    if (s->cb.log)
        s->cb.log(s->ctx, level, msg);
}

static void progress(void *priv, int level, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));

static void progress(void *priv, int level, const char *fmt, ...)
{
    char buf[2048];
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    emit(priv, level, buf);
}

/* Same outcome as the CLI in a non-interactive run (stdin is /dev/null in
 * the current helper): a certificate that fails normal validation aborts. */
static int validate_peer_cert(void *priv, const char *reason)
{
    char buf[1024];

    snprintf(buf, sizeof(buf), "Server certificate rejected: %s\n", reason);
    emit(priv, PRG_ERR, buf);
    return -1;
}

static int write_new_config(void *priv, const char *buf, int buflen)
{
    (void)priv; (void)buf; (void)buflen;
    return 0;
}

/* We always arrive with a session cookie; a form means it was rejected. */
static int process_auth_form(void *priv, struct oc_auth_form *form)
{
    (void)form;
    emit(priv, PRG_ERR, "Server requested interactive authentication\n");
    return -1;
}

static void stats_handler(void *priv, const struct oc_stats *st)
{
    struct ocshim *s = priv;

    if (s->cb.stats)
        s->cb.stats(s->ctx, st->tx_pkts, st->tx_bytes, st->rx_pkts, st->rx_bytes);
}

ocshim_t *ocshim_new(const ocshim_callbacks *cb, void *ctx)
{
    struct ocshim *s = calloc(1, sizeof(*s));

    if (!s)
        return NULL;
    s->cb = *cb;
    s->ctx = ctx;
    atomic_init(&s->cmd_fd, -1);
    signal(SIGPIPE, SIG_IGN); /* process-wide, like openconnect's main() */
    return s;
}

int ocshim_run(ocshim_t *s, const char *url, const char *cookie,
               const char *vpnc_script, int reconnect_timeout, int dpd_seconds)
{
    int ret;
    const struct oc_ip_info *ip;

    s->vpninfo = openconnect_vpninfo_new(
        "AnyConnect-compatible OpenConnect VPN Agent",
        validate_peer_cert, write_new_config, process_auth_form, progress, s);
    if (!s->vpninfo)
        return -ENOMEM;
    /* Callbacks above get `s` as privdata (the 6th argument to _new). */

    openconnect_set_loglevel(s->vpninfo, PRG_INFO);
    if (openconnect_set_protocol(s->vpninfo, "pulse") ||
        openconnect_parse_url(s->vpninfo, url) ||
        openconnect_set_cookie(s->vpninfo, cookie)) {
        emit(s, PRG_ERR, "Invalid protocol, URL or cookie\n");
        ret = -EINVAL;
        goto out;
    }
    if (dpd_seconds > 0)
        openconnect_set_dpd(s->vpninfo, dpd_seconds);
    openconnect_set_stats_handler(s->vpninfo, stats_handler);

    int fd = openconnect_setup_cmd_pipe(s->vpninfo);
    if (fd < 0) {
        emit(s, PRG_ERR, "Error opening command pipe\n");
        ret = -errno;
        goto out;
    }
    atomic_store(&s->cmd_fd, fd);

    ret = openconnect_make_cstp_connection(s->vpninfo);
    if (ret) {
        emit(s, PRG_ERR, "Creating SSL connection failed\n");
        goto out;
    }

    ret = openconnect_setup_tun_device(s->vpninfo, vpnc_script, NULL);
    if (ret) {
        emit(s, PRG_ERR, "Setting up the tunnel device failed\n");
        goto out;
    }

    if (s->cb.connected &&
        openconnect_get_ip_info(s->vpninfo, &ip, NULL, NULL) >= 0)
        s->cb.connected(s->ctx, ip->addr, ip->netmask, ip->gateway_addr, ip->mtu);

    if (openconnect_setup_dtls(s->vpninfo, 60))
        emit(s, PRG_ERR, "Set up UDP failed; using SSL instead\n");

    /* Returns 0 on a requested reconnect (PAUSE), nonzero when the session
     * is over — same loop as openconnect's main(). */
    do {
        ret = openconnect_mainloop(s->vpninfo, reconnect_timeout,
                                   RECONNECT_INTERVAL_MIN);
    } while (ret == 0);

out:
    atomic_store(&s->cmd_fd, -1);
    openconnect_vpninfo_free(s->vpninfo); /* also closes the command pipe */
    s->vpninfo = NULL;
    return ret;
}

static void send_cmd(struct ocshim *s, char cmd)
{
    int fd = atomic_load(&s->cmd_fd);

    if (fd >= 0 && write(fd, &cmd, 1) < 0) {
        /* session already torn down; nothing to do */
    }
}

void ocshim_cancel(ocshim_t *s)            { send_cmd(s, OC_CMD_CANCEL); }
void ocshim_request_stats(ocshim_t *s)     { send_cmd(s, OC_CMD_STATS); }
void ocshim_request_reconnect(ocshim_t *s) { send_cmd(s, OC_CMD_PAUSE); }

void ocshim_free(ocshim_t *s)
{
    free(s);
}
