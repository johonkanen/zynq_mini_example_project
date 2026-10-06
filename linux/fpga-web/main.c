/*
 * fpga-web - web UI for the FPGA. Never touches the hardware: every access
 * goes through fpgad (the process that owns the PL) via libfpgad-client.
 *
 *   GET  /                    the page (index.html, compiled into the binary)
 *   GET  /api/status          fpgad status JSON
 *   GET  /api/regs            all axi_regs registers: {"ok":true,"regs":[{...}]}
 *   GET  /api/reg?addr=0x1c   one register: {"ok":true,"addr":"0x1c","value":"0x5a5a1234"}
 *   POST /api/reg             addr=0x00&value=0x1234 (form body or query) -> {"ok":true}
 *   GET  /events              Server-Sent Events: HEARTBEAT batches + PL status changes
 *
 * Errors come back as {"ok":false,"error":"..."} with HTTP 400 (bad request)
 * or 503 (fpgad unreachable / PL not ready).
 */
#define _GNU_SOURCE
#include <inttypes.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>

#include "civetweb.h"
#include "fpgad_client.h"

extern const char index_html[];       /* page.S */
extern const char index_html_end[];

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

static int index_handler(struct mg_connection *c, void *cb)
{
    (void)cb;
    size_t len = (size_t)(index_html_end - index_html);
    mg_printf(c, "HTTP/1.1 200 OK\r\n"
                 "Content-Type: text/html; charset=utf-8\r\n"
                 "Content-Length: %zu\r\n"
                 "Cache-Control: no-cache\r\n"
                 "Connection: close\r\n\r\n", len);
    mg_write(c, index_html, len);
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
    const char *options[] = { "listening_ports", port, "num_threads", "16", NULL };
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
    mg_set_request_handler(ctx, "/$", index_handler, NULL);
    mg_set_request_handler(ctx, "/index.html$", index_handler, NULL);
    syslog(LOG_INFO, "listening on port %s, fpgad at %s", port, sock_path());

    while (!stopping)
        pause();
    syslog(LOG_INFO, "stopping");
    mg_stop(ctx);
    mg_exit_library();
    return 0;
}
