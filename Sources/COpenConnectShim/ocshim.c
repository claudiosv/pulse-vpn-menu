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

    pthread_mutex_t mu;          /* guards snap */
    ocshim_snapshot snap;
};

static void notify_changed(struct ocshim *s)
{
    if (s->cb.state_changed)
        s->cb.state_changed(s->ctx);
}

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

/* DTLS_CONNECTED in openconnect-internal.h: the UDP data channel (DTLS or
 * ESP) is up. The value is internal to libopenconnect; DtlsStateTests checks
 * it against the vendored source. */
#define OCSHIM_DTLS_CONNECTED 5

/* libopenconnect doesn't expose DTLS/ESP state or "a reconnect has begun" as
 * callbacks, so the two transitions it only reports in text are recognised
 * here, once, and turned into typed state. (The TCP-reconnected callback
 * below covers the other direction without any text.) */
static const char *const drop_markers[] = {
    "detected dead peer",
    "read error on",
    "ssl connection failure",
    "failed to reconnect to host",
    "remaining timeout",
};

static void note_progress(struct ocshim *s, const char *msg)
{
    size_t i;
    int changed = 0;

    pthread_mutex_lock(&s->mu);
    if (strstr(msg, "ESP session established")) {
        if (!s->snap.esp_established ||
            s->snap.link_state == OCSHIM_LINK_RECONNECTING)
            changed = 1;
        s->snap.esp_established = 1;
        if (s->snap.link_state == OCSHIM_LINK_RECONNECTING)
            s->snap.link_state = OCSHIM_LINK_UP;
    } else if (s->snap.link_state == OCSHIM_LINK_UP) {
        for (i = 0; i < sizeof(drop_markers) / sizeof(drop_markers[0]); i++) {
            if (strcasestr(msg, drop_markers[i])) {
                /* One drop per episode, however many retry lines follow. */
                s->snap.link_state = OCSHIM_LINK_RECONNECTING;
                s->snap.drop_count++;
                changed = 1;
                break;
            }
        }
    }
    pthread_mutex_unlock(&s->mu);
    if (changed)
        notify_changed(s);
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
    int changed = 0;

    pthread_mutex_lock(&s->mu);
    if (s->snap.link_state == OCSHIM_LINK_RECONNECTING) {
        s->snap.link_state = OCSHIM_LINK_UP;
        changed = 1;
    }
    pthread_mutex_unlock(&s->mu);
    if (changed)
        notify_changed(s);
}

/* Whether the caller's trust_chain callback accepts the peer's chain. */
static int chain_trusted_by_system(struct ocshim *s)
{
    struct oc_cert *chain = NULL;
    const unsigned char **ders = NULL;
    int *lens = NULL;
    int i, n, ok = 0;
    const char *host;

    n = openconnect_get_peer_cert_chain(s->vpninfo, &chain);
    if (n > 0 && chain) {
        ders = calloc(n, sizeof(*ders));
        lens = calloc(n, sizeof(*lens));
        if (ders && lens) {
            for (i = 0; i < n; i++) {
                ders[i] = chain[i].der_data;
                lens[i] = chain[i].der_len;
            }
            host = openconnect_get_dnsname(s->vpninfo);
            if (!host)
                host = openconnect_get_hostname(s->vpninfo);
            ok = s->cb.trust_chain(s->ctx, ders, lens, n, host);
        }
    }
    free(ders);
    free(lens);
    if (chain)
        openconnect_free_peer_cert_chain(s->vpninfo, chain);
    return ok;
}

/* A certificate that fails normal validation is accepted only if it matches
 * the caller's pin or the system trusts it; otherwise the app is told (so it can offer to pin it)
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
    if (s->cb.trust_chain && chain_trusted_by_system(s)) {
        emitf(s, PRG_INFO, "Accepting server certificate trusted by the system (%s)\n", reason);
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
    struct timespec now;
    int changed = 0;
    /* The UDP data channel's own state, read straight from libopenconnect
     * (through the patch in scripts/patches), so ESP is noticed even if the
     * log line note_progress() watches for is ever reworded. This runs on
     * the mainloop thread, the one that changes the state. */
    int esp_up = openconnect_get_dtls_state(s->vpninfo) >= OCSHIM_DTLS_CONNECTED;

    pthread_mutex_lock(&s->mu);
    if (esp_up && !s->snap.esp_established) {
        s->snap.esp_established = 1;
        if (s->snap.link_state == OCSHIM_LINK_RECONNECTING)
            s->snap.link_state = OCSHIM_LINK_UP;
        changed = 1;
    }
    s->snap.tx_pkts = st->tx_pkts;
    s->snap.tx_bytes = st->tx_bytes;
    s->snap.rx_pkts = st->rx_pkts;
    s->snap.rx_bytes = st->rx_bytes;
    s->snap.stats_seq++;
    clock_gettime(CLOCK_REALTIME, &now);
    s->snap.sampled_at = (double)now.tv_sec + now.tv_nsec / 1e9;
    pthread_mutex_unlock(&s->mu);
    if (changed)
        notify_changed(s);
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
    s->cmd_fd = -1;
    signal(SIGPIPE, SIG_IGN); /* process-wide, like openconnect's main() */
    return s;
}

/* Flattens a libopenconnect route/domain list into `out` (at most `max`). */
static int flatten(const struct oc_split_include *list, const char **out, int max)
{
    int n = 0;

    for (; list && n < max; list = list->next)
        if (list->route)
            out[n++] = list->route;
    return n;
}

#define OCSHIM_MAX_ROUTES 512

/* Hands the server-assigned configuration to the caller; returns the packet
 * fd it gives back, or a negative errno. */
static int run_configure(struct ocshim *s, const struct oc_ip_info *ip)
{
    const char **lists;
    ocshim_netconfig cfg;
    int ret, i;

    if (!s->cb.configure)
        return -ENOTSUP;
    lists = calloc(3 * OCSHIM_MAX_ROUTES, sizeof(*lists));
    if (!lists)
        return -ENOMEM;

    memset(&cfg, 0, sizeof(cfg));
    cfg.gateway_addr = ip->gateway_addr;
    cfg.addr = ip->addr;
    cfg.netmask = ip->netmask;
    cfg.addr6 = ip->addr6;
    cfg.netmask6 = ip->netmask6;
    for (i = 0; i < 3; i++)
        cfg.dns[i] = ip->dns[i];
    cfg.domain = ip->domain;
    cfg.mtu = ip->mtu;
    cfg.split_includes = lists;
    cfg.n_split_includes = flatten(ip->split_includes, lists, OCSHIM_MAX_ROUTES);
    cfg.split_excludes = lists + OCSHIM_MAX_ROUTES;
    cfg.n_split_excludes = flatten(ip->split_excludes, lists + OCSHIM_MAX_ROUTES, OCSHIM_MAX_ROUTES);
    cfg.split_dns = lists + 2 * OCSHIM_MAX_ROUTES;
    cfg.n_split_dns = flatten(ip->split_dns, lists + 2 * OCSHIM_MAX_ROUTES, OCSHIM_MAX_ROUTES);

    ret = s->cb.configure(s->ctx, &cfg);
    free(lists);
    return ret;
}

int ocshim_run(ocshim_t *s, const char *url, const char *cookie,
               const char *pinned_cert,
               int reconnect_timeout, int dpd_seconds, int verbose)
{
    int ret, fd, tun_fd;
    const struct oc_ip_info *ip = NULL;
    time_t exp;

    s->pinned_cert = pinned_cert;
    pthread_mutex_lock(&s->mu);
    memset(&s->snap, 0, sizeof(s->snap));
    s->snap.link_state = OCSHIM_LINK_CONNECTING;
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

    if (openconnect_get_ip_info(s->vpninfo, &ip, NULL, NULL) < 0 || !ip) {
        emit(s, PRG_ERR, "The server assigned no addresses\n");
        ret = -EINVAL;
        goto out;
    }
    emitf(s, PRG_INFO, "Server assigned %s%s%s, MTU %d\n",
          ip->addr ? ip->addr : "",
          (ip->addr && ip->addr6) ? " + " : "",
          ip->addr6 ? ip->addr6 : "",
          ip->mtu);

    /* The caller applies the addresses, routes and DNS and gives us the
     * packet fd, so libopenconnect never creates a device or runs a script.
     * With no vpnc-script set it also leaves the fd open when it exits. */
    tun_fd = run_configure(s, ip);
    if (tun_fd < 0) {
        emitf(s, PRG_ERR, "Applying the tunnel network settings failed (%s)\n", strerror(-tun_fd));
        ret = tun_fd;
        goto out;
    }
    ret = openconnect_setup_tun_fd(s->vpninfo, tun_fd);
    if (ret) {
        emit(s, PRG_ERR, "Setting up the tunnel device failed\n");
        goto out;
    }

    pthread_mutex_lock(&s->mu);
    s->snap.link_state = OCSHIM_LINK_UP;
    snprintf(s->snap.address, sizeof(s->snap.address), "%s", ip->addr ? ip->addr : "");
    pthread_mutex_unlock(&s->mu);
    notify_changed(s);
    emit(s, PRG_INFO, "Tunnel up\n");

    exp = openconnect_get_auth_expiration(s->vpninfo);
    if (exp != 0) {
        char buf[80];
        struct tm tm;

        pthread_mutex_lock(&s->mu);
        s->snap.expires_at = (double)exp;
        pthread_mutex_unlock(&s->mu);
        notify_changed(s);

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
    notify_changed(s);
    send_cmd(s, OC_CMD_PAUSE);
}

void ocshim_get_snapshot(ocshim_t *s, ocshim_snapshot *out)
{
    pthread_mutex_lock(&s->mu);
    *out = s->snap;
    pthread_mutex_unlock(&s->mu);
}

void ocshim_request_stats(ocshim_t *s)
{
    send_cmd(s, OC_CMD_STATS);
}

void ocshim_free(ocshim_t *s)
{
    pthread_mutex_destroy(&s->mu);
    pthread_mutex_destroy(&s->cmd_lock);
    free(s);
}
