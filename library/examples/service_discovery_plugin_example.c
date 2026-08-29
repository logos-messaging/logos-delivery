/*
 * Worked example and end-to-end check of the service-discovery plugin surface
 * declared in ../logosdelivery_service_discovery.h.
 *
 * It implements a stub plugin as real C entry points, registers it over the
 * FFI surface, and drives a node through the whole path:
 *
 *   host thread -> logosdelivery_set_service_discovery_plugin
 *               -> node's FFI thread -> SetServiceDiscoveryPlugin broker
 *               -> guarded vtable slot -> discovery worker thread
 *               -> the plugin entry points below
 *
 * It also pins the contract that registration needs BOTH halves: a node
 * configured for external discovery and a valid plugin. The first node here
 * has no configuration, so registration must be refused.
 *
 * Note the entry points run on the discovery worker thread, not the thread
 * that registered the plugin -- hence the volatile flags below.
 *
 * Build and run, from the repository root:
 *
 *   make service_discovery_plugin_example
 *   ./build/service_discovery_plugin_example
 *
 * Exits 0 when every check passes.
 */
#include "../logosdelivery_service_discovery.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile int g_started = 0;   /* plugin start() was invoked */
static volatile int g_lookups = 0;   /* lookup()/randomLookup() invoked */
static volatile int g_stopped = 0;

static char g_install_msg[512];
static volatile int g_install_ret = -99;

static const char *kPeersJson =
    "[{\"peerId\":\"peer-from-plugin\",\"seqNo\":7,"
    "\"addrs\":[\"/ip4/1.2.3.4/tcp/60000\"],"
    "\"services\":[{\"id\":\"/mix/1.0.0\",\"data\":\"AQID\"}]}]";

/* Records which plugin context the call carried, so a two-node run can show
 * that each node drives its own plugin and not its neighbour's. */
static volatile int g_start_ctx = -1;
static int p_start(void *c, char *e, size_t n) {
    (void)e;(void)n; g_started = 1; g_start_ctx = (int)(intptr_t)c; return LD_DISCO_OK;
}
static int p_stop(void *c, char *e, size_t n) { (void)c;(void)e;(void)n; g_stopped = 1; return LD_DISCO_OK; }
static int p_lookup(void *c, const char *k, int64_t l, char **o, char *e, size_t n) {
    (void)c;(void)k;(void)l;(void)e;(void)n;
    *o = strdup(kPeersJson); g_lookups++; return LD_DISCO_OK;
}
static int p_rand(void *c, char **o, char *e, size_t n) {
    (void)c;(void)e;(void)n;
    *o = strdup(kPeersJson); g_lookups++; return LD_DISCO_OK;
}
static void p_free(void *c, char *s) { (void)c; free(s); }
static int p_adv(void *c, const char *k, const uint8_t *d, size_t dl,
                 const uint8_t *r, size_t rl, char *e, size_t n)
{ (void)c;(void)k;(void)d;(void)dl;(void)r;(void)rl;(void)e;(void)n; return LD_DISCO_OK; }
static int p_key(void *c, const char *k, char *e, size_t n) { (void)c;(void)k;(void)e;(void)n; return LD_DISCO_OK; }
static int p_boot(void *c, const char *const *en, size_t l, char *e, size_t n)
{ (void)c;(void)en;(void)l;(void)e;(void)n; return LD_DISCO_OK; }

static LdServiceDiscoveryPlugin g_plugin = {
    LD_DISCO_ABI_VERSION, NULL, 2000,
    p_start, p_stop, p_lookup, p_rand, p_free,
    p_adv, p_key, p_key, p_key, p_boot,
};

static void on_install(int caller_ret, char *msg, size_t len, void *ud) {
    (void)ud;
    g_install_ret = caller_ret;
    size_t n = len < sizeof(g_install_msg) - 1 ? len : sizeof(g_install_msg) - 1;
    if (msg && n) memcpy(g_install_msg, msg, n);
    g_install_msg[n] = '\0';
}

static volatile int g_stop_ret = -99;
static void on_stop(int ret, char *msg, size_t len, void *ud) {
    (void)msg; (void)len; (void)ud;
    g_stop_ret = ret;
}

static void on_scalar(int ret, char *msg, size_t len, void *ud) {
    printf("   [%s] ret=%d %.*s\n", (const char *)ud, ret, (int)len, msg ? msg : "");
}

static volatile int g_created = -1;
static void on_created(int ret, const char *ctx_addr, const char *err_msg, void *ud) {
    (void)ud; (void)ctx_addr;
    g_created = ret;
    if (ret != 0) printf("   create failed: %s\n", err_msg ? err_msg : "");
}

static int failures = 0;
static void expect(int cond, const char *what) {
    printf("%s %s\n", cond ? "  PASS" : "  FAIL", what);
    if (!cond) failures++;
}

static void *make_node(const char *config) {
    g_created = -1;
    LogosdeliveryCreateNodeCtorReq req; memset(&req, 0, sizeof(req));
    req.configJson = config;
    void *ctx = logosdelivery_create_node(&req, on_created, NULL);
    for (int i = 0; i < 100 && g_created == -1; i++) usleep(100000);
    return ctx;
}

int main(void) {
    /* ---- 1. node WITHOUT external discovery: registration must be refused --- */
    printf("\n1. node without external discovery configured\n");
    const char *plainCfg =
        "{\"entryLayer\":\"kernel\",\"kernelConf\":{\"log-level\":\"WARN\","
        "\"cluster-id\":16,\"tcp-port\":61150,\"discv5-discovery\":false}}";
    void *ctx = make_node(plainCfg);
    if (!ctx || g_created != 0) { printf("  FAIL could not create node\n"); return 1; }

    g_install_ret = -99; g_install_msg[0] = '\0';
    logosdelivery_install_service_discovery_plugin(ctx, &g_plugin, on_install, NULL);
    for (int i = 0; i < 50 && g_install_ret == -99; i++) usleep(100000);
    printf("   reply: ret=%d msg=%s\n", g_install_ret, g_install_msg);
    expect(g_install_ret != 0, "registration refused when not configured");
    expect(strstr(g_install_msg, "no provider registered") != NULL,
           "refusal names the missing provider");
    logosdelivery_destroy(ctx);

    /* ---- 2. node WITH external discovery: full path ------------------------ */
    printf("\n2. node with external discovery enabled\n");
    const char *extCfg =
        "{\"entryLayer\":\"kernel\",\"kernelConf\":{\"log-level\":\"WARN\","
        "\"cluster-id\":16,\"tcp-port\":61151,\"discv5-discovery\":false,"
        "\"enable-external-discovery\":true,"
        "\"external-discovery-service-lookup-interval-ms\":500,"
        "\"external-discovery-random-lookup-interval-ms\":500}}";
    const char *extCfg2 =
        "{\"entryLayer\":\"kernel\",\"kernelConf\":{\"log-level\":\"WARN\","
        "\"cluster-id\":16,\"tcp-port\":61152,\"discv5-discovery\":false,"
        "\"enable-external-discovery\":true,"
        "\"external-discovery-service-lookup-interval-ms\":500,"
        "\"external-discovery-random-lookup-interval-ms\":500}}";

    ctx = make_node(extCfg);
    if (!ctx || g_created != 0) { printf("  FAIL could not create node\n"); return 1; }

    g_install_ret = -99; g_install_msg[0] = '\0';
    logosdelivery_install_service_discovery_plugin(ctx, &g_plugin, on_install, NULL);
    for (int i = 0; i < 50 && g_install_ret == -99; i++) usleep(100000);
    printf("   reply: ret=%d msg=%s\n", g_install_ret, g_install_msg);
    expect(g_install_ret == 0, "registration accepted");

    printf("   starting node...\n");
    logosdelivery_start_node(ctx, on_scalar, (void *)"start_node");
    for (int i = 0; i < 100 && !g_started; i++) usleep(100000);
    expect(g_started, "plugin start() called by the backend");

    for (int i = 0; i < 60 && g_lookups < 2; i++) usleep(100000);
    printf("   lookups seen: %d\n", g_lookups);
    expect(g_lookups >= 2, "lookup loops drive the plugin on the worker thread");

    /* stopping the node stops the plugin too */
    g_stop_ret = -99;
    logosdelivery_stop_node(ctx, on_stop, NULL);
    for (int i = 0; i < 100 && g_stop_ret == -99; i++) usleep(100000);
    expect(g_stop_ret == 0, "node stopped");
    expect(g_stopped, "plugin stop() called by the backend");

    /* clearing must disable the verbs again */
    g_install_ret = -99; g_install_msg[0] = '\0';
    logosdelivery_clear_service_discovery_plugin(ctx, on_install, NULL);
    for (int i = 0; i < 50 && g_install_ret == -99; i++) usleep(100000);
    printf("   clear reply: ret=%d msg=%s\n", g_install_ret, g_install_msg);
    expect(g_install_ret == 0, "clear accepted");
    logosdelivery_destroy(ctx);

    /* ---- 3. clearing the plugin before stopping is a healthy shutdown ------ */
    /* Telling a plugin that is already gone to stop is not a failure, and must
     * not put an error in the log of an ordinary shutdown. */
    printf("\n3. plugin cleared before the node stops\n");
    ctx = make_node(extCfg2);
    if (!ctx || g_created != 0) { printf("  FAIL could not create node\n"); return 1; }

    g_install_ret = -99;
    logosdelivery_install_service_discovery_plugin(ctx, &g_plugin, on_install, NULL);
    for (int i = 0; i < 50 && g_install_ret == -99; i++) usleep(100000);
    expect(g_install_ret == 0, "registration accepted");

    g_started = 0;
    logosdelivery_start_node(ctx, on_scalar, (void *)"start_node");
    for (int i = 0; i < 100 && !g_started; i++) usleep(100000);
    expect(g_started, "plugin start() called again on the second node");

    g_install_ret = -99;
    logosdelivery_clear_service_discovery_plugin(ctx, on_install, NULL);
    for (int i = 0; i < 50 && g_install_ret == -99; i++) usleep(100000);
    expect(g_install_ret == 0, "clear accepted while running");

    g_stop_ret = -99;
    logosdelivery_stop_node(ctx, on_stop, NULL);
    for (int i = 0; i < 100 && g_stop_ret == -99; i++) usleep(100000);
    expect(g_stop_ret == 0, "stop succeeds with the plugin already cleared");
    logosdelivery_destroy(ctx);

    /* ---- 4. two nodes at once, each with its own plugin ------------------- */
    /* The plugin slot and the discovery worker are per broker context. Were
     * they process-wide, the second registration would overwrite the first and
     * the second node would find no worker provider at all. */
    printf("\n4. two concurrent nodes, each with its own plugin\n");
    const char *cfgA =
        "{\"entryLayer\":\"kernel\",\"kernelConf\":{\"log-level\":\"WARN\","
        "\"cluster-id\":16,\"tcp-port\":61153,\"discv5-discovery\":false,"
        "\"enable-external-discovery\":true,"
        "\"external-discovery-service-lookup-interval-ms\":500,"
        "\"external-discovery-random-lookup-interval-ms\":500}}";
    const char *cfgB =
        "{\"entryLayer\":\"kernel\",\"kernelConf\":{\"log-level\":\"WARN\","
        "\"cluster-id\":16,\"tcp-port\":61154,\"discv5-discovery\":false,"
        "\"enable-external-discovery\":true,"
        "\"external-discovery-service-lookup-interval-ms\":500,"
        "\"external-discovery-random-lookup-interval-ms\":500}}";

    void *ctxA = make_node(cfgA);
    if (!ctxA || g_created != 0) { printf("  FAIL could not create node A\n"); return 1; }
    void *ctxB = make_node(cfgB);
    if (!ctxB || g_created != 0) { printf("  FAIL could not create node B\n"); return 1; }

    /* Distinct plugin contexts, as a glue layer with per-node state would use. */
    LdServiceDiscoveryPlugin pluginA = g_plugin; pluginA.pluginCtx = (void *)(intptr_t)1;
    LdServiceDiscoveryPlugin pluginB = g_plugin; pluginB.pluginCtx = (void *)(intptr_t)2;

    g_install_ret = -99;
    logosdelivery_install_service_discovery_plugin(ctxA, &pluginA, on_install, NULL);
    for (int i = 0; i < 50 && g_install_ret == -99; i++) usleep(100000);
    expect(g_install_ret == 0, "node A registered its plugin");

    g_install_ret = -99;
    logosdelivery_install_service_discovery_plugin(ctxB, &pluginB, on_install, NULL);
    for (int i = 0; i < 50 && g_install_ret == -99; i++) usleep(100000);
    expect(g_install_ret == 0, "node B registered its plugin");

    g_started = 0; g_start_ctx = -1;
    logosdelivery_start_node(ctxA, on_scalar, (void *)"A start");
    for (int i = 0; i < 100 && !g_started; i++) usleep(100000);
    printf("   A drove pluginCtx=%d\n", g_start_ctx);
    expect(g_start_ctx == 1, "node A drives its own plugin, not node B's");

    g_started = 0; g_start_ctx = -1;
    logosdelivery_start_node(ctxB, on_scalar, (void *)"B start");
    for (int i = 0; i < 100 && !g_started; i++) usleep(100000);
    printf("   B drove pluginCtx=%d\n", g_start_ctx);
    expect(g_started, "node B has a working backend of its own");
    expect(g_start_ctx == 2, "node B drives its own plugin");

    /* Tearing one node down must leave the other's worker alone. */
    g_stop_ret = -99;
    logosdelivery_stop_node(ctxA, on_stop, NULL);
    for (int i = 0; i < 100 && g_stop_ret == -99; i++) usleep(100000);
    logosdelivery_destroy(ctxA);

    g_started = 0; g_start_ctx = -1;
    g_install_ret = -99;
    logosdelivery_clear_service_discovery_plugin(ctxB, on_install, NULL);
    for (int i = 0; i < 50 && g_install_ret == -99; i++) usleep(100000);
    expect(g_install_ret == 0, "node B still reachable after node A was destroyed");

    g_stop_ret = -99;
    logosdelivery_stop_node(ctxB, on_stop, NULL);
    for (int i = 0; i < 100 && g_stop_ret == -99; i++) usleep(100000);
    expect(g_stop_ret == 0, "node B stops cleanly");
    logosdelivery_destroy(ctxB);

    printf("\n%s (%d failure(s))\n", failures ? "FAILED" : "ALL PASSED", failures);
    return failures ? 1 : 0;
}
