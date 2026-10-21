#include "ocshim.h"

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
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

    pthread_mutex_t mu;          /* guards snap and done */
    pthread_cond_t cv;           /* signalled on a new sample and on exit */
    ocshim_snapshot snap;
    int done;
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

/* libopenconnect doesn't expose DTLS/ESP state or "a reconnect has begun" as
 * callbacks, so the two transitions it only reports in text are recognised
 * here, once, and turned into typed state. (The TCP-reconnected callback
 * below covers the other direction without any text.) */
static const char *const drop_markers[] = {
    "detected dead peer",
    "server closed connection",
    "failed to reconnect to host",
    "remaining timeout",
};

static void note_progress(struct ocshim *s, const char *msg)
{
    size_t i;

    pthread_mutex_lock(&s->mu);
    if (strstr(msg, "ESP session established")) {
        s->snap.esp_established = 1;
        if (s->snap.link_state == OCSHIM_LINK_RECONNECTING)
            s->snap.link_state = OCSHIM_LINK_UP;
    } else if (s->snap.link_state == OCSHIM_LINK_UP) {
        for (i = 0; i < sizeof(drop_markers) / sizeof(drop_markers[0]); i++) {
            if (strcasestr(msg, drop_markers[i])) {
                /* One drop per episode, however many retry lines follow. */
                s->snap.link_state = OCSHIM_LINK_RECONNECTING;
                s->snap.drop_count++;
                break;
            }
        }
    }
    pthread_mutex_unlock(&s->mu);
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
    note_progress(s, buf);
    emit(s, level, buf);
}

/* TCP connection re-established after a drop. */
static void reconnected(void *priv)
{
    struct ocshim *s = priv;

    pthread_mutex_lock(&s->mu);
    if (s->snap.link_state == OCSHIM_LINK_RECONNECTING)
        s->snap.link_state = OCSHIM_LINK_UP;
    pthread_mutex_unlock(&s->mu);
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

/* Runs on the mainloop thread in response to OC_CMD_STATS. */
static void stats_handler(void *priv, const struct oc_stats *st)
{
    struct ocshim *s = priv;

    pthread_mutex_lock(&s->mu);
    s->snap.tx_pkts = st->tx_pkts;
    s->snap.tx_bytes = st->tx_bytes;
    s->snap.rx_pkts = st->rx_pkts;
    s->snap.rx_bytes = st->rx_bytes;
    s->snap.stats_seq++;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->mu);
}

ocshim_t *ocshim_new(const ocshim_callbacks *cb, void *ctx)
{
    struct ocshim *s = calloc(1, sizeof(*s));

    if (!s)
        return NULL;
    s->cb = *cb;
    s->ctx = ctx;
    pthread_mutex_init(&s->cmd_lock, NULL);
    pthread_mutex_init(&s->mu, NULL);
    pthread_cond_init(&s->cv, NULL);
    s->cmd_fd = -1;
    signal(SIGPIPE, SIG_IGN); /* process-wide, like openconnect's main() */
    return s;
}

int ocshim_run(ocshim_t *s, const char *url, const char *cookie,
               const char *vpnc_script, const char *pinned_cert,
               int reconnect_timeout, int dpd_seconds, int verbose)
{
    int ret, fd, have_ip;
    const struct oc_ip_info *ip;
    const char *ifname;
    time_t exp;

    s->pinned_cert = pinned_cert;
    pthread_mutex_lock(&s->mu);
    memset(&s->snap, 0, sizeof(s->snap));
    s->snap.link_state = OCSHIM_LINK_CONNECTING;
    s->done = 0;
    pthread_mutex_unlock(&s->mu);

    s->vpninfo = openconnect_vpninfo_new(
        "AnyConnect-compatible OpenConnect VPN Agent",
        validate_peer_cert, write_new_config, process_auth_form, progress, s);
    if (!s->vpninfo)
        return -ENOMEM;

    openconnect_set_loglevel(s->vpninfo, verbose ? PRG_DEBUG : PRG_INFO);
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
    openconnect_set_reconnected_handler(s->vpninfo, reconnected);

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

    have_ip = openconnect_get_ip_info(s->vpninfo, &ip, NULL, NULL) >= 0;
    ifname = openconnect_get_ifname(s->vpninfo);
    pthread_mutex_lock(&s->mu);
    s->snap.link_state = OCSHIM_LINK_UP;
    snprintf(s->snap.ifname, sizeof(s->snap.ifname), "%s", ifname ? ifname : "");
    snprintf(s->snap.address, sizeof(s->snap.address), "%s", have_ip && ip->addr ? ip->addr : "");
    pthread_mutex_unlock(&s->mu);

    if (have_ip) {
        emitf(s, PRG_INFO, "Tunnel up: %s%s%s, MTU %d\n",
              ip->addr ? ip->addr : "",
              (ip->addr && ip->addr6) ? " + " : "",
              ip->addr6 ? ip->addr6 : "",
              ip->mtu);
        if (s->cb.connected)
            s->cb.connected(s->ctx, ip->addr, ip->netmask, ip->gateway_addr, ip->mtu);
    }
    exp = openconnect_get_auth_expiration(s->vpninfo);
    if (exp != 0) {
        char buf[80];
        struct tm tm;

        localtime_r(&exp, &tm);
        strftime(buf, sizeof(buf), "%a, %d %b %Y %H:%M:%S %Z", &tm);
        emitf(s, PRG_INFO, "Session authentication will expire at %s\n", buf);
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
    /* Same wording as the messages openconnect's main() prints on exit. */
    switch (ret) {
    case -EPERM:
        emit(s, PRG_ERR, "Cookie was rejected by server; exiting.\n");
        break;
    case -EPIPE:
        emit(s, PRG_ERR, "Session terminated by server; exiting.\n");
        break;
    case -EINTR:
        emit(s, PRG_INFO, "User cancelled; exiting.\n");
        break;
    default:
        emitf(s, PRG_ERR, "Session ended with error %d (%s); exiting.\n", ret, strerror(-ret));
        break;
    }

    /* After this, no command write can touch the fd vpninfo_free() closes. */
    pthread_mutex_lock(&s->cmd_lock);
    s->cmd_fd = -1;
    pthread_mutex_unlock(&s->cmd_lock);
    openconnect_vpninfo_free(s->vpninfo); /* also closes the command pipe */
    s->vpninfo = NULL;

    /* Wake any ocshim_poll_stats() still waiting for a sample. */
    pthread_mutex_lock(&s->mu);
    s->done = 1;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->mu);
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

void ocshim_cancel(ocshim_t *s)
{
    send_cmd(s, OC_CMD_CANCEL);
}

void ocshim_request_reconnect(ocshim_t *s)
{
    /* Cleared first so a waiter can't see the old session's value: the new
     * "ESP session established" line may arrive any time after PAUSE. */
    pthread_mutex_lock(&s->mu);
    s->snap.esp_established = 0;
    pthread_mutex_unlock(&s->mu);
    send_cmd(s, OC_CMD_PAUSE);
}

void ocshim_get_snapshot(ocshim_t *s, ocshim_snapshot *out)
{
    pthread_mutex_lock(&s->mu);
    *out = s->snap;
    pthread_mutex_unlock(&s->mu);
}

int ocshim_poll_stats(ocshim_t *s, int timeout_ms, ocshim_snapshot *out)
{
    struct timespec deadline;
    uint64_t before;
    int fresh;

    pthread_mutex_lock(&s->mu);
    before = s->snap.stats_seq;
    pthread_mutex_unlock(&s->mu);

    send_cmd(s, OC_CMD_STATS);

    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000L;
    }

    pthread_mutex_lock(&s->mu);
    while (s->snap.stats_seq == before && !s->done) {
        if (pthread_cond_timedwait(&s->cv, &s->mu, &deadline) == ETIMEDOUT)
            break;
    }
    fresh = s->snap.stats_seq != before;
    *out = s->snap;
    pthread_mutex_unlock(&s->mu);
    return fresh;
}

void ocshim_free(ocshim_t *s)
{
    pthread_cond_destroy(&s->cv);
    pthread_mutex_destroy(&s->mu);
    pthread_mutex_destroy(&s->cmd_lock);
    free(s);
}
