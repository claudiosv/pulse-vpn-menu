#include "ocshim.h"

#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "openconnect.h"

struct ocshim {
    ocshim_callbacks cb;
    void *ctx;
    struct openconnect_info *vpninfo;
    const char *pinned_cert;     /* borrowed from ocshim_run's caller */
    pthread_mutex_t cmd_lock;    /* serializes command writes with fd teardown */
    int cmd_fd;                  /* -1 until ocshim_run() has set up the pipe */
    int esp_established;         /* only touched on the mainloop thread */
};

static void emit(struct ocshim *s, int level, const char *msg)
{
    if (s->cb.log)
        s->cb.log(s->ctx, level, msg);
}

static void emitf(struct ocshim *s, int level, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));

static void emitf(struct ocshim *s, int level, const char *fmt, ...)
{
    char buf[2048];
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    emit(s, level, buf);
}

static void progress(void *priv, int level, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));

static void progress(void *priv, int level, const char *fmt, ...)
{
    struct ocshim *s = priv;
    char buf[2048];
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (strstr(buf, "ESP session established"))
        s->esp_established = 1;
    emit(s, level, buf);
}

/* A certificate that fails normal validation is accepted only if it matches
 * the caller's pin; otherwise the app is told (so it can offer to pin it)
 * and the connection aborts. */
static int validate_peer_cert(void *priv, const char *reason)
{
    struct ocshim *s = priv;
    const char *hash = openconnect_get_peer_cert_hash(s->vpninfo);

    if (s->pinned_cert && *s->pinned_cert &&
        openconnect_check_peer_cert_hash(s->vpninfo, s->pinned_cert) == 0) {
        emitf(s, PRG_INFO, "Accepting pinned server certificate (%s)\n", reason);
        return 0;
    }
    emitf(s, PRG_ERR, "Server certificate rejected: %s (%s)\n", reason, hash ? hash : "no hash");
    if (s->cb.cert_rejected)
        s->cb.cert_rejected(s->ctx, reason, hash);
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

/* Same text as openconnect's print_connection_info(); the DTLS/ESP state is
 * inferred from the "ESP session established" log line, since the library
 * doesn't expose its dtls_state. */
static void print_connection_info(struct ocshim *s)
{
    const struct oc_ip_info *ip;
    const char *ssl_compr, *udp_compr;
    time_t exp;

    if (openconnect_get_ip_info(s->vpninfo, &ip, NULL, NULL) < 0)
        return;
    ssl_compr = openconnect_get_cstp_compression(s->vpninfo);
    udp_compr = openconnect_get_dtls_compression(s->vpninfo);
    emitf(s, PRG_INFO, "Configured as %s%s%s, with SSL%s%s connected and ESP%s%s %s\n",
          ip->addr ? ip->addr : "",
          ((ip->netmask6 || ip->addr6) && ip->addr) ? " + " : "",
          ip->netmask6 ? ip->netmask6 : (ip->addr6 ? ip->addr6 : ""),
          ssl_compr ? " + " : "", ssl_compr ? ssl_compr : "",
          udp_compr ? " + " : "", udp_compr ? udp_compr : "",
          s->esp_established ? "established" : "in progress");

    exp = openconnect_get_auth_expiration(s->vpninfo);
    if (exp != 0) {
        char buf[80];
        struct tm tm;

        localtime_r(&exp, &tm);
        strftime(buf, sizeof(buf), "%a, %d %b %Y %H:%M:%S %Z", &tm);
        emitf(s, PRG_INFO, "Session authentication will expire at %s\n", buf);
    }
}

static void stats_handler(void *priv, const struct oc_stats *st)
{
    struct ocshim *s = priv;
    const char *cipher;

    print_connection_info(s);
    emitf(s, PRG_INFO, "RX: %" PRIu64 " packets (%" PRIu64 " B); TX: %" PRIu64 " packets (%" PRIu64 " B)\n",
          st->rx_pkts, st->rx_bytes, st->tx_pkts, st->tx_bytes);
    cipher = openconnect_get_cstp_cipher(s->vpninfo);
    if (cipher)
        emitf(s, PRG_INFO, "SSL ciphersuite: %s\n", cipher);
}

ocshim_t *ocshim_new(const ocshim_callbacks *cb, void *ctx)
{
    struct ocshim *s = calloc(1, sizeof(*s));

    if (!s)
        return NULL;
    s->cb = *cb;
    s->ctx = ctx;
    pthread_mutex_init(&s->cmd_lock, NULL);
    s->cmd_fd = -1;
    signal(SIGPIPE, SIG_IGN); /* process-wide, like openconnect's main() */
    return s;
}

int ocshim_run(ocshim_t *s, const char *url, const char *cookie,
               const char *vpnc_script, const char *pinned_cert,
               int reconnect_timeout, int dpd_seconds)
{
    int ret, fd;
    const struct oc_ip_info *ip;

    s->pinned_cert = pinned_cert;
    s->esp_established = 0;
    s->vpninfo = openconnect_vpninfo_new(
        "AnyConnect-compatible OpenConnect VPN Agent",
        validate_peer_cert, write_new_config, process_auth_form, progress, s);
    if (!s->vpninfo)
        return -ENOMEM;

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

    fd = openconnect_setup_cmd_pipe(s->vpninfo);
    if (fd < 0) {
        emit(s, PRG_ERR, "Error opening command pipe\n");
        ret = -errno;
        goto out;
    }
    pthread_mutex_lock(&s->cmd_lock);
    s->cmd_fd = fd;
    pthread_mutex_unlock(&s->cmd_lock);

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

    if (openconnect_get_ip_info(s->vpninfo, &ip, NULL, NULL) >= 0) {
        if (s->cb.connected)
            s->cb.connected(s->ctx, ip->addr, ip->netmask, ip->gateway_addr, ip->mtu);
        print_connection_info(s);
    }

    if (openconnect_setup_dtls(s->vpninfo, 60))
        emit(s, PRG_ERR, "Set up UDP failed; using SSL instead\n");

    /* Returns 0 on a requested reconnect (PAUSE), nonzero when the session
     * is over — same loop as openconnect's main(). */
    do {
        ret = openconnect_mainloop(s->vpninfo, reconnect_timeout,
                                   RECONNECT_INTERVAL_MIN);
    } while (ret == 0);

out:
    /* After this, no command write can touch the fd vpninfo_free() closes. */
    pthread_mutex_lock(&s->cmd_lock);
    s->cmd_fd = -1;
    pthread_mutex_unlock(&s->cmd_lock);
    openconnect_vpninfo_free(s->vpninfo); /* also closes the command pipe */
    s->vpninfo = NULL;
    return ret;
}

static void send_cmd(struct ocshim *s, char cmd)
{
    pthread_mutex_lock(&s->cmd_lock);
    if (s->cmd_fd >= 0 && write(s->cmd_fd, &cmd, 1) < 0) {
        /* session already torn down; nothing to do */
    }
    pthread_mutex_unlock(&s->cmd_lock);
}

void ocshim_cancel(ocshim_t *s)            { send_cmd(s, OC_CMD_CANCEL); }
void ocshim_request_stats(ocshim_t *s)     { send_cmd(s, OC_CMD_STATS); }
void ocshim_request_reconnect(ocshim_t *s) { send_cmd(s, OC_CMD_PAUSE); }

void ocshim_free(ocshim_t *s)
{
    pthread_mutex_destroy(&s->cmd_lock);
    free(s);
}
