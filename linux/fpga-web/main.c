/*
 * fpga-web - web UI for the FPGA. Never touches the hardware: every access
 * goes through fpgad (the process that owns the PL) via libfpgad-client.
 *
 *   GET  /                    the page (index.html, compiled into the binary)
 *   GET  /uPlot.iife.min.js, /uPlot.min.css   vendored uPlot (vendor/, MIT)
 *   GET  /api/status          fpgad status JSON
 *   GET  /api/regs            all axi_regs registers: {"ok":true,"regs":[{...}]}
 *   GET  /api/reg?addr=0x1c   one register: {"ok":true,"addr":"0x1c","value":"0x5a5a1234"}
 *   POST /api/reg             addr=0x00&value=0x1234 (form body or query) -> {"ok":true}
 *   GET  /events              Server-Sent Events: HEARTBEAT batches + PL status changes
 *   WS   /ws                  live register stream, binary frames (see "WebSocket" below)
 *
 * Errors come back as {"ok":false,"error":"..."} with HTTP 400 (bad request)
 * or 503 (fpgad unreachable / PL not ready).
 */
#define _GNU_SOURCE
#include <inttypes.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#include "civetweb.h"
#include "fpgad_client.h"

extern const char index_html[], index_html_end[];      /* page.S */
extern const char uplot_js[], uplot_js_end[];
extern const char uplot_css[], uplot_css_end[];

static volatile sig_atomic_t stopping;
static const char *fpgad_sock;        /* NULL = library default */
static unsigned stream_hz = 200, batch_hz = 20;

static const struct { uint32_t off; const char *name, *acc, *desc; } REGS[] = {
    { 0x00, "SCRATCH0",  "rw", "free R/W, PS->PL" },
    { 0x04, "SCRATCH1",  "rw", "free R/W, PS->PL" },
    { 0x08, "SCRATCH2",  "rw", "free R/W, PS->PL" },
    { 0x0C, "CONTROL",   "rw", "bit0 pl_active, bit1 holds HEARTBEAT at 0" },
    { 0x10, "HEARTBEAT", "ro", "free-running counter, 100 MHz" },
    { 0x14, "SUM",       "ro", "SCRATCH0 + SCRATCH1, added in the PL" },
    { 0x18, "STATUS",    "ro", "reductions / popcount / HEARTBEAT[15:0]" },
    { 0x1C, "SIGNATURE", "ro", "constant 0x5A5A1234" },
    { 0x20, "OLED_CTRL", "rw", "bit0 on, bit1 invert, bit2 flip, [15:8] contrast" },
    { 0x24, "OLED_STAT", "ro", "bit0 ready, [31:16] frames sent" },
};
#define NREGS (sizeof REGS / sizeof REGS[0])

/* ---- small HTTP helpers ------------------------------------------------- */

static void json_escape(char *dst, size_t n, const char *src)
{
    size_t o = 0;
    for (; *src && o + 2 < n; src++) {
        if (*src == '"' || *src == '\\') {
            if (o + 3 >= n)
                break;
            dst[o++] = '\\';
        }
        dst[o++] = (*src >= 0x20) ? *src : ' ';
    }
    dst[o] = 0;
}

static int reply(struct mg_connection *c, int code, const char *fmt, ...)
{
    char body[8192];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(body, sizeof body, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= sizeof body)
        n = (int)strlen(body);
    mg_printf(c, "HTTP/1.1 %d %s\r\n"
                 "Content-Type: application/json\r\n"
                 "Content-Length: %d\r\n"
                 "Cache-Control: no-cache\r\n"
                 "Connection: close\r\n\r\n%s",
              code, code == 200 ? "OK" : code == 400 ? "Bad Request" : "Service Unavailable",
              n, body);
    return code;
}

static int reply_err(struct mg_connection *c, int code, const char *msg)
{
    char esc[1024];
    json_escape(esc, sizeof esc, msg);
    return reply(c, code, "{\"ok\":false,\"error\":\"%s\"}", esc);
}

static const char *sock_path(void)
{
    if (fpgad_sock)
        return fpgad_sock;
    return getenv("FPGAD_SOCKET") ? getenv("FPGAD_SOCKET") : FPGAD_SOCKET;
}

static struct fpgad_conn *open_fpgad(struct mg_connection *c)
{
    struct fpgad_conn *f = fpgad_open(fpgad_sock);
    if (!f) {
        char m[256];
        snprintf(m, sizeof m, "fpgad not running (no %s)", sock_path());
        reply_err(c, 503, m);
    }
    return f;
}

/* addr/value from the query string or a form-encoded POST body */
static int get_param(struct mg_connection *c, const char *name, char *out, size_t n,
                     const char *body)
{
    const struct mg_request_info *ri = mg_get_request_info(c);
    if (ri->query_string && mg_get_var(ri->query_string, strlen(ri->query_string), name, out, n) > 0)
        return 0;
    if (body && mg_get_var(body, strlen(body), name, out, n) > 0)
        return 0;
    return -1;
}

static int parse_u32(const char *s, uint32_t *v)
{
    char *end;
    unsigned long long x = strtoull(s, &end, 0);
    if (!*s || *end || x > 0xFFFFFFFFull)
        return -1;
    *v = (uint32_t)x;
    return 0;
}

/* ---- handlers ------------------------------------------------------------ */

/* files compiled into the binary (page.S) */
struct asset { const char *data, *end, *type; };
static const struct asset ASSET_INDEX = { index_html, index_html_end, "text/html; charset=utf-8" };
static const struct asset ASSET_UPLOT_JS = { uplot_js, uplot_js_end, "text/javascript" };
static const struct asset ASSET_UPLOT_CSS = { uplot_css, uplot_css_end, "text/css" };

static int asset_handler(struct mg_connection *c, void *cb)
{
    const struct asset *a = cb;
    size_t len = (size_t)(a->end - a->data);
    mg_printf(c, "HTTP/1.1 200 OK\r\n"
                 "Content-Type: %s\r\n"
                 "Content-Length: %zu\r\n"
                 "Cache-Control: no-cache\r\n"
                 "Connection: close\r\n\r\n", a->type, len);
    mg_write(c, a->data, len);
    return 200;
}

static int status_handler(struct mg_connection *c, void *cb)
{
    (void)cb;
    struct fpgad_conn *f = open_fpgad(c);
    if (!f)
        return 503;
    char msg[1024];
    int rc = fpgad_request(f, "status", msg, sizeof msg);
    fpgad_close(f);
    if (rc != 0)
        return reply_err(c, 503, rc < 0 ? "fpgad connection failed" : msg);
    return reply(c, 200, "%s", msg);
}

static int regs_handler(struct mg_connection *c, void *cb)
{
    (void)cb;
    struct fpgad_conn *f = open_fpgad(c);
    if (!f)
        return 503;
    char body[4096], msg[1024];
    size_t o = (size_t)snprintf(body, sizeof body, "{\"ok\":true,\"regs\":[");
    for (size_t i = 0; i < NREGS; i++) {
        char req[32];
        snprintf(req, sizeof req, "read 0x%" PRIx32, REGS[i].off);
        int rc = fpgad_request(f, req, msg, sizeof msg);
        if (rc != 0) {
            fpgad_close(f);
            return reply_err(c, 503, rc < 0 ? "fpgad connection failed" : msg);
        }
        o += (size_t)snprintf(body + o, sizeof body - o,
                              "%s{\"addr\":\"0x%02" PRIx32 "\",\"name\":\"%s\",\"access\":\"%s\","
                              "\"desc\":\"%s\",\"value\":\"%s\"}",
                              i ? "," : "", REGS[i].off, REGS[i].name, REGS[i].acc,
                              REGS[i].desc, msg);
    }
    snprintf(body + o, sizeof body - o, "]}");
    fpgad_close(f);
    return reply(c, 200, "%s", body);
}

static int reg_handler(struct mg_connection *c, void *cb)
{
    (void)cb;
    const struct mg_request_info *ri = mg_get_request_info(c);
    int is_post = !strcmp(ri->request_method, "POST");
    if (!is_post && strcmp(ri->request_method, "GET"))
        return reply_err(c, 400, "use GET (read) or POST (write)");

    char body[512] = "";
    if (is_post) {
        int n = mg_read(c, body, sizeof body - 1);
        body[n > 0 ? n : 0] = 0;
    }
    char sa[32], sv[32];
    uint32_t addr, val = 0;
    if (get_param(c, "addr", sa, sizeof sa, body) || parse_u32(sa, &addr))
        return reply_err(c, 400, "missing or bad addr (e.g. addr=0x1c)");
    if (is_post && (get_param(c, "value", sv, sizeof sv, body) || parse_u32(sv, &val)))
        return reply_err(c, 400, "missing or bad value (e.g. value=0x1234)");

    struct fpgad_conn *f = open_fpgad(c);
    if (!f)
        return 503;
    char req[64], msg[1024];
    if (is_post)
        snprintf(req, sizeof req, "write 0x%" PRIx32 " 0x%" PRIx32, addr, val);
    else
        snprintf(req, sizeof req, "read 0x%" PRIx32, addr);
    int rc = fpgad_request(f, req, msg, sizeof msg);
    fpgad_close(f);
    if (rc < 0)
        return reply_err(c, 503, "fpgad connection failed");
    if (rc == 1)   /* fpgad refused: bad offset -> 400, PL not ready -> 503 */
        return reply_err(c, strstr(msg, "not ready") ? 503 : 400, msg);
    if (is_post) {
        syslog(LOG_INFO, "write 0x%02" PRIx32 " = 0x%08" PRIx32 " from %s", addr, val,
               ri->remote_addr);
        return reply(c, 200, "{\"ok\":true,\"addr\":\"0x%02" PRIx32 "\",\"value\":\"0x%08" PRIx32 "\"}",
                     addr, val);
    }
    return reply(c, 200, "{\"ok\":true,\"addr\":\"0x%02" PRIx32 "\",\"value\":\"%s\"}", addr, msg);
}

/* SSE relay of an fpgad stream: data -> message events, status -> "status" events */
static int events_handler(struct mg_connection *c, void *cb)
{
    (void)cb;
    if (mg_printf(c, "HTTP/1.1 200 OK\r\n"
                     "Content-Type: text/event-stream\r\n"
                     "Cache-Control: no-cache\r\n"
                     "Connection: close\r\n\r\n"
                     "retry: 1000\n\n") <= 0)
        return 200;

    struct fpgad_conn *f = fpgad_open(fpgad_sock);
    char req[64], line[65536];
    snprintf(req, sizeof req, "stream %u %u 0x10", stream_hz, batch_hz);
    if (!f || fpgad_request(f, req, line, sizeof line) != 0) {
        mg_printf(c, "event: status\ndata: {\"ok\":false,\"pl\":\"unknown\","
                     "\"msg\":\"fpgad not reachable\",\"sim\":false}\n\n");
        fpgad_close(f);
        return 200;
    }
    while (!stopping) {
        int n = fpgad_readline(f, line, sizeof line, 1000);
        if (n < 0)
            break;                                   /* fpgad went away */
        int w;
        if (n == 0)
            w = mg_printf(c, ": ping\n\n");          /* keep-alive, detects dead browsers */
        else if (!strncmp(line, "data ", 5))
            w = mg_printf(c, "data: %s\n\n", line + 5);
        else if (!strncmp(line, "status ", 7))
            w = mg_printf(c, "event: status\ndata: %s\n\n", line + 7);
        else
            w = 1;
        if (w <= 0)
            break;
    }
    fpgad_close(f);
    return 200;
}

/* ---- WebSocket /ws: binary register stream --------------------------------
 *
 * browser -> server, text:  "stream <hz> <off> [<off>...]"   1..10000 Hz, 1..8 offsets
 *                           "stop"
 *                           "scope run <auto|normal|single> [key=value...]"   oscilloscope;
 *                               keys as fpgad's "capture" (src div trig edge level pre)
 *                           "scope stop"
 * server -> browser, text:  {"type":"stream","hz":200,"regs":[16,28]}  (re)started
 *                           {"type":"status",...}   fpgad status (same fields as /api/status)
 *                           {"type":"scope","state":"running|waiting|stopped"}
 *                           {"type":"error","error":"..."}
 * server -> browser, binary, little-endian:
 *   register batch, one per ~40 ms:
 *     u8 type = 1 | u8 nregs | u16 0 | u32 n          8-byte header
 *     f64 t[n]                                        fpgad timestamps, µs
 *     u32 v[nregs][n]                                 values, register by register
 *   scope capture, one per acquisition (at most ~30/s):
 *     u8 type = 2 | u8 nch | u16 flags (bit0 triggered) | u32 n | u32 pre | u32 div
 *     f64 fs                                          sample rate, Hz   (24-byte header)
 *     i16 v[nch][n]                                   samples in time order, trigger at pre
 *   so the browser maps them straight onto typed arrays.
 *
 * Each connection gets a thread that relays one fpgad "stream" (fpgad's text
 * batches -> binary), and, once the page starts the scope, a second one that
 * loops fpgad "capture". Both reconnect to fpgad once a second if it goes away.
 */
#define WS_MAX_REGS  8
#define WS_BATCH_HZ  25
#define WS_MAX_N     10000                  /* samples per batch: 10 kHz at 1 batch/s */
#define WS_LINE_MAX  (WS_MAX_N * (21 + 11 * WS_MAX_REGS) + 64)

#define SCOPE_MAX_FPS 30
#define SCOPE_ARGS    200

enum { SCOPE_STOP, SCOPE_AUTO, SCOPE_NORMAL, SCOPE_SINGLE };

struct ws_client {
    struct mg_connection *conn;
    pthread_t th, scope_th;
    int th_started, scope_started;
    volatile int closing;
    pthread_mutex_t lock;                   /* guards the request fields */
    int changed;                            /* new request from the browser */
    unsigned hz;                            /* 0 = stopped */
    int nregs;
    uint32_t regs[WS_MAX_REGS];
    int scope_mode;                         /* SCOPE_*, guarded by lock */
    unsigned scope_gen;                     /* bumped on every scope command */
    char scope_args[SCOPE_ARGS];            /* key=value... for fpgad "capture" */
};

static int ws_text(struct ws_client *w, const char *fmt, ...)
{
    char buf[1200];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n < 0)
        return -1;
    if ((size_t)n >= sizeof buf)
        n = (int)sizeof buf - 1;
    return mg_websocket_write(w->conn, MG_WEBSOCKET_OPCODE_TEXT, buf, (size_t)n) > 0 ? 0 : -1;
}

static int ws_error(struct ws_client *w, const char *msg)
{
    char esc[1024];
    json_escape(esc, sizeof esc, msg);
    return ws_text(w, "{\"type\":\"error\",\"error\":\"%s\"}", esc);
}

/* fpgad batch {"t":[...],"v":[[...],...]} -> t[n], v[r*n + i]; returns n or -1 */
static int parse_batch(const char *s, int nregs, double *t, uint32_t *v)
{
    const char *p = strstr(s, "\"t\":[");
    if (!p)
        return -1;
    p += 5;
    int n = 0;
    while (*p && *p != ']') {
        char *e;
        unsigned long long x = strtoull(p, &e, 10);
        if (e == p || n >= WS_MAX_N)
            return -1;
        t[n++] = (double)x;
        p = *e == ',' ? e + 1 : e;
    }
    if (!(p = strstr(p, "\"v\":[")))
        return -1;
    p += 5;
    for (int r = 0; r < nregs; r++) {
        if (*p == ',')
            p++;
        if (*p++ != '[')
            return -1;
        int k = 0;
        while (*p && *p != ']') {
            char *e;
            unsigned long long x = strtoull(p, &e, 10);
            if (e == p || k >= n)
                return -1;
            v[(size_t)r * n + k++] = (uint32_t)x;
            p = *e == ',' ? e + 1 : e;
        }
        if (k != n || *p++ != ']')
            return -1;
    }
    return n;
}

static void *ws_thread(void *arg)
{
    struct ws_client *w = arg;
    struct fpgad_conn *f = NULL;
    char *line = malloc(WS_LINE_MAX);
    double *t = malloc(sizeof(double) * WS_MAX_N);
    uint32_t *v = malloc(sizeof(uint32_t) * WS_MAX_N * WS_MAX_REGS);
    uint8_t *bin = malloc(8 + (sizeof(double) + sizeof(uint32_t) * WS_MAX_REGS) * WS_MAX_N);
    unsigned hz = 0;
    int nregs = 0, retry = 0;
    uint32_t regs[WS_MAX_REGS];
    if (!line || !t || !v || !bin)
        goto out;

    while (!w->closing && !stopping) {
        pthread_mutex_lock(&w->lock);
        int changed = w->changed;
        if (changed) {
            w->changed = 0;
            hz = w->hz;
            nregs = w->nregs;
            memcpy(regs, w->regs, sizeof regs);
        }
        pthread_mutex_unlock(&w->lock);
        if (changed) {
            fpgad_close(f);
            f = NULL;
            retry = 0;
        }
        if (!hz) {                          /* stopped */
            usleep(100000);
            continue;
        }
        if (!f) {
            if (retry > 0) {                /* fpgad down: try again in ~1 s */
                retry--;
                usleep(100000);
                continue;
            }
            char req[160], msg[1024];
            int o = snprintf(req, sizeof req, "stream %u %u", hz, hz < WS_BATCH_HZ ? hz : WS_BATCH_HZ);
            for (int i = 0; i < nregs; i++)
                o += snprintf(req + o, sizeof req - (size_t)o, " 0x%" PRIx32, regs[i]);
            f = fpgad_open(fpgad_sock);
            int rc = f ? fpgad_request(f, req, msg, sizeof msg) : -1;
            if (rc != 0) {
                fpgad_close(f);
                f = NULL;
                retry = 10;
                if (ws_error(w, rc < 0 ? "fpgad not reachable, retrying" : msg) < 0)
                    break;
                continue;
            }
            char list[WS_MAX_REGS * 12] = "";
            for (int i = 0, lo = 0; i < nregs; i++)
                lo += snprintf(list + lo, sizeof list - (size_t)lo, "%s%" PRIu32, i ? "," : "", regs[i]);
            if (ws_text(w, "{\"type\":\"stream\",\"hz\":%u,\"regs\":[%s]}", hz, list) < 0)
                break;
        }
        int n = fpgad_readline(f, line, WS_LINE_MAX, 100);
        if (n == 0)
            continue;
        if (n < 0) {                        /* fpgad restarted / died */
            fpgad_close(f);
            f = NULL;
            retry = 10;
            if (ws_error(w, "fpgad stream ended, reconnecting") < 0)
                break;
            continue;
        }
        if (!strncmp(line, "status ", 7) && line[7] == '{') {
            if (ws_text(w, "{\"type\":\"status\",%s", line + 8) < 0)
                break;
        } else if (!strncmp(line, "data ", 5)) {
            int ns = parse_batch(line + 5, nregs, t, v);
            if (ns <= 0)
                continue;
            bin[0] = 1;
            bin[1] = (uint8_t)nregs;
            bin[2] = bin[3] = 0;
            uint32_t un = (uint32_t)ns;
            memcpy(bin + 4, &un, 4);
            memcpy(bin + 8, t, sizeof(double) * (size_t)ns);
            memcpy(bin + 8 + sizeof(double) * (size_t)ns, v, sizeof(uint32_t) * (size_t)ns * nregs);
            size_t len = 8 + (sizeof(double) + sizeof(uint32_t) * (size_t)nregs) * (size_t)ns;
            if (mg_websocket_write(w->conn, MG_WEBSOCKET_OPCODE_BINARY, (const char *)bin, len) <= 0)
                break;                      /* browser gone */
        }
    }
out:
    fpgad_close(f);
    free(line);
    free(t);
    free(v);
    free(bin);
    return NULL;
}

/* oscilloscope: loop fpgad "capture" while the page has the scope running */
static void *scope_thread(void *arg)
{
    struct ws_client *w = arg;
    struct fpgad_conn *f = NULL;
    enum { HDR = 24 };
    const size_t max_bytes = 4 * 4096 * sizeof(int16_t);
    uint8_t *frame = malloc(HDR + max_bytes);
    unsigned seen_gen = ~0u;
    int last_state = -1;                    /* 0 waiting, 1 running, 2 stopped (sent) */
    if (!frame)
        return NULL;

    while (!w->closing && !stopping) {
        char args[SCOPE_ARGS];
        pthread_mutex_lock(&w->lock);
        int mode = w->scope_mode;
        unsigned gen = w->scope_gen;
        memcpy(args, w->scope_args, sizeof args);
        pthread_mutex_unlock(&w->lock);
        if (gen != seen_gen) {
            seen_gen = gen;
            last_state = -1;
        }
        if (mode == SCOPE_STOP) {
            if (last_state != 2 && ws_text(w, "{\"type\":\"scope\",\"state\":\"stopped\"}") == 0)
                last_state = 2;
            fpgad_close(f);
            f = NULL;
            usleep(50000);
            continue;
        }
        if (!f && !(f = fpgad_open(fpgad_sock))) {
            ws_error(w, "scope: fpgad not reachable, retrying");
            sleep(1);
            continue;
        }

        /* auto: force a trigger after 100 ms; normal/single: wait, re-ask every 500 ms */
        char req[SCOPE_ARGS + 64], meta[1024];
        snprintf(req, sizeof req, "capture %s timeout=%d auto=%d", args,
                 mode == SCOPE_AUTO ? 100 : 500, mode == SCOPE_AUTO);
        uint64_t t0 = 0;
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        t0 = (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
        int rc = fpgad_request(f, req, meta, sizeof meta);
        if (rc < 0) {
            fpgad_close(f);
            f = NULL;
            continue;
        }
        if (rc == 1) {                      /* bad settings / no scope in the PL: stop */
            ws_error(w, meta);
            pthread_mutex_lock(&w->lock);
            if (w->scope_gen == gen)
                w->scope_mode = SCOPE_STOP;
            pthread_mutex_unlock(&w->lock);
            continue;
        }
        if (!strcmp(meta, "timeout")) {     /* normal / single: still waiting */
            if (last_state != 0 && ws_text(w, "{\"type\":\"scope\",\"state\":\"waiting\"}") == 0)
                last_state = 0;
            continue;
        }
        /* "capture {...}": pick the fields out of fpgad's JSON, then the samples */
        unsigned n = 0, nch = 0, pre = 0, div = 1;
        double fs = 0;
        size_t bytes = 0;
        const char *p;
        if ((p = strstr(meta, "\"n\":")))     n = (unsigned)strtoul(p + 4, NULL, 10);
        if ((p = strstr(meta, "\"ch\":")))    nch = (unsigned)strtoul(p + 5, NULL, 10);
        if ((p = strstr(meta, "\"pre\":")))   pre = (unsigned)strtoul(p + 6, NULL, 10);
        if ((p = strstr(meta, "\"div\":")))   div = (unsigned)strtoul(p + 6, NULL, 10);
        if ((p = strstr(meta, "\"fs\":")))    fs = strtod(p + 5, NULL);
        if ((p = strstr(meta, "\"bytes\":"))) bytes = strtoul(p + 8, NULL, 10);
        int trig = strstr(meta, "\"triggered\":true") != NULL;
        if (strncmp(meta, "capture ", 8) || !n || !nch || nch > 255 ||
            bytes != (size_t)n * nch * sizeof(int16_t) || bytes > max_bytes ||
            fpgad_read_bytes(f, frame + HDR, bytes, 5000) < 0) {
            fpgad_close(f);                 /* out of step with fpgad: start over */
            f = NULL;
            continue;
        }
        frame[0] = 2;
        frame[1] = (uint8_t)nch;
        uint16_t flags = (uint16_t)trig;
        memcpy(frame + 2, &flags, 2);
        memcpy(frame + 4, &n, 4);
        memcpy(frame + 8, &pre, 4);
        memcpy(frame + 12, &div, 4);
        memcpy(frame + 16, &fs, 8);
        if (last_state != 1 && ws_text(w, "{\"type\":\"scope\",\"state\":\"running\"}") == 0)
            last_state = 1;
        if (mg_websocket_write(w->conn, MG_WEBSOCKET_OPCODE_BINARY, (const char *)frame, HDR + bytes) <= 0)
            break;                          /* browser gone */
        if (mode == SCOPE_SINGLE) {
            pthread_mutex_lock(&w->lock);
            if (w->scope_gen == gen)
                w->scope_mode = SCOPE_STOP;
            pthread_mutex_unlock(&w->lock);
        }
        /* at most SCOPE_MAX_FPS acquisitions a second */
        clock_gettime(CLOCK_MONOTONIC, &ts);
        uint64_t el = (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000 - t0;
        if (el < 1000 / SCOPE_MAX_FPS)
            usleep((useconds_t)(1000 / SCOPE_MAX_FPS - el) * 1000);
    }
    fpgad_close(f);
    free(frame);
    return NULL;
}

/* "scope run <mode> key=value..." / "scope stop" */
static void ws_scope_cmd(struct ws_client *w, char *line)
{
    char *save, *verb = strtok_r(line, " \t\r\n", &save);   /* "scope" */
    verb = strtok_r(NULL, " \t\r\n", &save);
    int mode = -1;
    char args[SCOPE_ARGS] = "";
    if (verb && !strcmp(verb, "stop")) {
        mode = SCOPE_STOP;
    } else if (verb && !strcmp(verb, "run")) {
        char *m = strtok_r(NULL, " \t\r\n", &save);
        mode = !m ? -1 : !strcmp(m, "auto") ? SCOPE_AUTO : !strcmp(m, "normal") ? SCOPE_NORMAL
             : !strcmp(m, "single") ? SCOPE_SINGLE : -1;
        size_t o = 0;
        for (char *t; mode >= 0 && (t = strtok_r(NULL, " \t\r\n", &save));) {
            /* only key=value with plain characters reaches fpgad */
            if (strspn(t, "abcdefghijklmnopqrstuvwxyz0123456789=,-") != strlen(t) || !strchr(t, '=') ||
                o + strlen(t) + 2 > sizeof args) {
                mode = -1;
                break;
            }
            o += (size_t)snprintf(args + o, sizeof args - o, "%s%s", o ? " " : "", t);
        }
    }
    if (mode < 0) {
        ws_error(w, "usage: scope run <auto|normal|single> [src=a,b,c,d div= trig= edge= level= pre=] "
                    "| scope stop");
        return;
    }
    pthread_mutex_lock(&w->lock);
    w->scope_mode = mode;
    w->scope_gen++;
    memcpy(w->scope_args, args, sizeof args);
    pthread_mutex_unlock(&w->lock);
    if (!w->scope_started && mode != SCOPE_STOP)
        w->scope_started = pthread_create(&w->scope_th, NULL, scope_thread, w) == 0;
}

static int ws_connect(const struct mg_connection *c, void *cb)
{
    (void)c;
    (void)cb;
    return 0;                               /* accept */
}

static void ws_ready(struct mg_connection *c, void *cb)
{
    (void)cb;
    struct ws_client *w = calloc(1, sizeof *w);
    if (!w)
        return;
    w->conn = c;
    pthread_mutex_init(&w->lock, NULL);
    mg_set_user_connection_data(c, w);
    w->th_started = pthread_create(&w->th, NULL, ws_thread, w) == 0;
}

static int ws_data(struct mg_connection *c, int bits, char *data, size_t len, void *cb)
{
    (void)cb;
    struct ws_client *w = mg_get_user_connection_data(c);
    int op = bits & 0x0F;
    if (op == MG_WEBSOCKET_OPCODE_CONNECTION_CLOSE)
        return 0;
    if (op != MG_WEBSOCKET_OPCODE_TEXT || !w)
        return 1;

    char buf[256], *argv[2 + WS_MAX_REGS + 1];
    int argc = 0;
    if (len >= sizeof buf)
        len = sizeof buf - 1;
    memcpy(buf, data, len);
    buf[len] = 0;
    if (!strncmp(buf, "scope ", 6)) {
        ws_scope_cmd(w, buf);
        return 1;
    }
    for (char *tok = strtok(buf, " \t\r\n"); tok && argc < (int)(sizeof argv / sizeof argv[0]);
         tok = strtok(NULL, " \t\r\n"))
        argv[argc++] = tok;

    uint32_t hz = 0, regs[WS_MAX_REGS];
    int nregs = argc - 2;
    if (argc == 1 && !strcmp(argv[0], "stop")) {
        hz = 0;
        nregs = 0;
    } else if (argc >= 3 && !strcmp(argv[0], "stream") && nregs <= WS_MAX_REGS &&
               !parse_u32(argv[1], &hz) && hz >= 1 && hz <= 10000) {
        for (int i = 0; i < nregs; i++)
            if (parse_u32(argv[2 + i], &regs[i]) || regs[i] % 4 || regs[i] >= 0x1000) {
                ws_error(w, "bad register offset (0x0..0xffc, 4-byte aligned)");
                return 1;
            }
    } else {
        ws_error(w, "usage: stream <hz 1..10000> <off> [<off>... up to 8] | stop");
        return 1;
    }
    pthread_mutex_lock(&w->lock);
    w->hz = hz;
    w->nregs = nregs;
    memcpy(w->regs, regs, sizeof(uint32_t) * (size_t)nregs);
    w->changed = 1;
    pthread_mutex_unlock(&w->lock);
    return 1;
}

static void ws_close(const struct mg_connection *c, void *cb)
{
    (void)cb;
    struct ws_client *w = mg_get_user_connection_data(c);
    if (!w)
        return;
    w->closing = 1;
    if (w->th_started)
        pthread_join(w->th, NULL);          /* thread notices within ~100 ms */
    if (w->scope_started)
        pthread_join(w->scope_th, NULL);    /* waits out one capture in flight (<= ~5 s) */
    pthread_mutex_destroy(&w->lock);
    free(w);
}

/* ---- main ---------------------------------------------------------------- */

static void on_signal(int sig)
{
    (void)sig;
    stopping = 1;
}

int main(int argc, char **argv)
{
    const char *port = "80";
    int fg = 0, opt;
    while ((opt = getopt(argc, argv, "p:s:r:fh")) != -1) {
        switch (opt) {
        case 'p': port = optarg; break;
        case 's': fpgad_sock = optarg; break;
        case 'r': stream_hz = (unsigned)strtoul(optarg, NULL, 0); break;
        case 'f': fg = 1; break;
        default:
            fprintf(stderr, "usage: %s [-p port] [-s fpgad-socket] [-r stream_hz] [-f]\n"
                            "  -p  listening port(s), civetweb syntax (default 80)\n"
                            "  -s  fpgad socket (default $FPGAD_SOCKET or " FPGAD_SOCKET ")\n"
                            "  -r  HEARTBEAT stream rate in Hz (default 200)\n"
                            "  -f  foreground: also log to stderr\n", argv[0]);
            return opt == 'h' ? 0 : 2;
        }
    }
    if (stream_hz < batch_hz || stream_hz > 10000) {
        fprintf(stderr, "stream rate must be %u..10000 Hz\n", batch_hz);
        return 2;
    }
    openlog("fpga-web", LOG_PID | (fg ? LOG_PERROR : 0), LOG_DAEMON);

    struct sigaction sa = { .sa_handler = on_signal };
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    mg_init_library(0);
    /* every open WebSocket holds a worker thread for its lifetime */
    const char *options[] = { "listening_ports", port, "num_threads", "32", NULL };
    struct mg_callbacks cbs;
    memset(&cbs, 0, sizeof cbs);
    struct mg_context *ctx = mg_start(&cbs, NULL, options);
    if (!ctx) {
        syslog(LOG_ERR, "cannot start web server on port %s", port);
        return 1;
    }
    mg_set_request_handler(ctx, "/events", events_handler, NULL);
    mg_set_request_handler(ctx, "/api/status", status_handler, NULL);
    mg_set_request_handler(ctx, "/api/regs", regs_handler, NULL);
    mg_set_request_handler(ctx, "/api/reg$", reg_handler, NULL);
    mg_set_request_handler(ctx, "/$", asset_handler, (void *)&ASSET_INDEX);
    mg_set_request_handler(ctx, "/index.html$", asset_handler, (void *)&ASSET_INDEX);
    mg_set_request_handler(ctx, "/uPlot.iife.min.js$", asset_handler, (void *)&ASSET_UPLOT_JS);
    mg_set_request_handler(ctx, "/uPlot.min.css$", asset_handler, (void *)&ASSET_UPLOT_CSS);
    mg_set_websocket_handler(ctx, "/ws$", ws_connect, ws_ready, ws_data, ws_close, NULL);
    if (!mg_check_feature(16))
        syslog(LOG_WARNING, "civetweb built without WebSocket support: /ws will not work "
                            "(rebuild civetweb with WITH_WEBSOCKET=1)");
    syslog(LOG_INFO, "listening on port %s, fpgad at %s", port, sock_path());

    while (!stopping)
        pause();
    syslog(LOG_INFO, "stopping");
    mg_stop(ctx);
    mg_exit_library();
    return 0;
}
