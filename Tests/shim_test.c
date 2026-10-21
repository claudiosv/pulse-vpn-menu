/* Checks the shim's typed session state: how libopenconnect's progress text
 * and callbacks turn into link state, ESP flag, drop count and change
 * notifications. Includes ocshim.c directly to reach its static functions.
 * Run with scripts/test-shim.sh. */
#include "../Sources/COpenConnectShim/ocshim.c"

#include <assert.h>

static int changes;

static void on_change(void *ctx) { (void)ctx; changes++; }

static ocshim_snapshot snap(ocshim_t *s)
{
    ocshim_snapshot out;
    ocshim_get_snapshot(s, &out);
    return out;
}

int main(void)
{
    ocshim_callbacks cb = { .state_changed = on_change };
    struct ocshim *s = ocshim_new(&cb, NULL);
    assert(s);

    /* Drop text before the tunnel is up is not a drop. */
    progress(s, PRG_INFO, "%s", "Detected dead peer!");
    assert(snap(s).drop_count == 0 && changes == 0);

    s->snap.link_state = OCSHIM_LINK_UP;

    /* A drop is one episode, however many retry lines follow. */
    progress(s, PRG_INFO, "%s", "Detected dead peer!");
    assert(snap(s).link_state == OCSHIM_LINK_RECONNECTING);
    assert(snap(s).drop_count == 1 && changes == 1);
    progress(s, PRG_INFO, "%s", "Failed to reconnect to host x: Connection refused");
    progress(s, PRG_INFO, "%s", "sleeping for 10 seconds; remaining timeout 290");
    assert(snap(s).drop_count == 1 && changes == 1);

    /* TCP reconnect brings the link back. */
    reconnected(s);
    assert(snap(s).link_state == OCSHIM_LINK_UP && changes == 2);
    reconnected(s);                       /* already up: no change */
    assert(changes == 2);

    /* A second episode counts again; ESP established also ends one. */
    progress(s, PRG_INFO, "%s", "Server closed connection");
    assert(snap(s).drop_count == 2 && changes == 3);
    progress(s, PRG_INFO, "%s", "ESP session established with server");
    assert(snap(s).link_state == OCSHIM_LINK_UP && snap(s).esp_established);
    assert(changes == 4);
    progress(s, PRG_INFO, "%s", "ESP session established with server");
    assert(changes == 4);                 /* nothing new */

    /* Asking for a reconnect forgets the old link's ESP state. */
    ocshim_request_reconnect(s);
    assert(!snap(s).esp_established && changes == 5);

    /* Counter samples bump the sequence and timestamp, without a "change". */
    struct oc_stats st = { .tx_pkts = 3, .tx_bytes = 300, .rx_pkts = 4, .rx_bytes = 400 };
    stats_handler(s, &st);
    assert(snap(s).stats_seq == 1 && snap(s).tx_bytes == 300 && snap(s).rx_pkts == 4);
    assert(snap(s).sampled_at > 1e9);
    assert(changes == 5);

    ocshim_free(s);
    puts("shim state ok");
    return 0;
}
