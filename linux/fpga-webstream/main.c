/*
 * fpga-webstream - serve a live view of PL data over HTTP + Server-Sent Events.
 *
 *   GET /             the web page (index.html, compiled into the binary)
 *   GET /events       text/event-stream:
 *                       data: {"t":[us,...],"hb":[count,...]}   sample batches
 *                       event: status  data: {...}               PL state changes
 *   GET /api/status   the same status JSON, one-shot (handy for curl)
 *
 * Data source: the axi_regs slave (src/hdl/axi_regs.vhd) at the base of
 * M_AXI_GP0, reached through UIO (DT node axi_regs@40000000, compatible
 * "generic-uio", kernel arg uio_pdrv_genirq.of_id=generic-uio). A sampler
 * thread reads HEARTBEAT at a fixed rate into a ring buffer; every client's
 * /events handler streams from that ring in batches.
 *
 * The registers are only touched while the FPGA manager reports the PL as
 * "operating" and SIGNATURE reads back 0x5A5A1234: a GP0 read with no PL
 * design behind it can stall the bus.
 *
 * FPGA_WEBSTREAM_SIM=1 in the environment fakes the registers (a 100 MHz
 * counter) so the server and page can be tried on a PC.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <inttypes.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#include "civetweb.h"

/* axi_regs register map (word offsets) */
#define REG_HEARTBEAT   (0x10 / 4)
#define REG_SIGNATURE   (0x1C / 4)
#define SIGNATURE_VALUE 0x5A5A1234u

#define FPGA_STATE_FILE "/sys/class/fpga_manager/fpga0/state"
#define UIO_NAME        "axi_regs"

#define RING_SIZE   8192        /* samples, power of two */
#define BACKLOG     400         /* samples a new client gets straight away */

extern const char index_html[];       /* page.S */
extern const char index_html_end[];

struct sample { uint64_t t_us; uint32_t hb; };

static struct {
    pthread_mutex_t lock;
    pthread_cond_t  cond;
    struct sample   ring[RING_SIZE];
    uint64_t        head;        /* total samples ever written */
    unsigned        status_gen;  /* bumped whenever status changes */
    char            status[256]; /* JSON */
} g = { .lock = PTHREAD_MUTEX_INITIALIZER, .cond = PTHREAD_COND_INITIALIZER };

static volatile sig_atomic_t stopping;
static volatile uint32_t    *regs;
static int                   sim;
static unsigned              rate_hz = 200;
static unsigned              batch_hz = 20;
static uint64_t              t0_ns;

static void logmsg(int prio, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsyslog(prio, fmt, ap);
    va_end(ap);
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* ---- data source --------------------------------------------------------- */

static int pl_operating(void)
{
    if (sim)
        return 1;
    char buf[32] = "";
    FILE *f = fopen(FPGA_STATE_FILE, "r");
    if (!f)
        return 0;
    if (!fgets(buf, sizeof buf, f))
        buf[0] = 0;
    fclose(f);
    return strncmp(buf, "operating", 9) == 0;
}

/* find /sys/class/uio/uioN whose name is axi_regs; map it */
static int map_uio(void)
{
    glob_t gl;
    char path[128], name[64];
    int idx = -1;

    if (glob("/sys/class/uio/uio*/name", 0, NULL, &gl) != 0) {
        logmsg(LOG_ERR, "no UIO devices - is uio_pdrv_genirq.of_id=generic-uio on the kernel command line?");
        return -1;
    }
    for (size_t i = 0; i < gl.gl_pathc && idx < 0; i++) {
        FILE *f = fopen(gl.gl_pathv[i], "r");
        if (!f)
            continue;
        if (fgets(name, sizeof name, f) && strncmp(name, UIO_NAME, strlen(UIO_NAME)) == 0)
            sscanf(gl.gl_pathv[i], "/sys/class/uio/uio%d/", &idx);
        fclose(f);
    }
    globfree(&gl);
    if (idx < 0) {
        logmsg(LOG_ERR, "no UIO device named %s", UIO_NAME);
        return -1;
    }

    size_t size = 0x1000;
    snprintf(path, sizeof path, "/sys/class/uio/uio%d/maps/map0/size", idx);
    FILE *f = fopen(path, "r");
    if (f) {
        unsigned long v;
        if (fscanf(f, "%lx", &v) == 1 && v)
            size = v;
        fclose(f);
    }

    snprintf(path, sizeof path, "/dev/uio%d", idx);
    int fd = open(path, O_RDWR | O_SYNC);
    if (fd < 0) {
        logmsg(LOG_ERR, "open %s: %s", path, strerror(errno));
        return -1;
    }
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        logmsg(LOG_ERR, "mmap %s: %s", path, strerror(errno));
        close(fd);
        return -1;
    }
    regs = p;
    logmsg(LOG_INFO, "mapped %s (%zu bytes) for %s", path, size, UIO_NAME);
    return 0;
}

static uint32_t read_reg(unsigned word)
{
    if (sim) {
        if (word == REG_SIGNATURE)
            return SIGNATURE_VALUE;
        return (uint32_t)((now_ns() - t0_ns) / 10);   /* 100 MHz */
    }
    return regs[word];
}

static void set_status(int ok, const char *pl, const char *msg)
{
    pthread_mutex_lock(&g.lock);
    snprintf(g.status, sizeof g.status,
             "{\"ok\":%s,\"pl\":\"%s\",\"msg\":\"%s\",\"rate_hz\":%u,\"sim\":%s}",
             ok ? "true" : "false", pl, msg, rate_hz, sim ? "true" : "false");
    g.status_gen++;
    pthread_cond_broadcast(&g.cond);
    pthread_mutex_unlock(&g.lock);
}

static void *sampler(void *arg)
{
    (void)arg;
    const uint64_t period = 1000000000ull / rate_hz;
    const unsigned per_batch = rate_hz / batch_hz ? rate_hz / batch_hz : 1;
    int ok = 0, last = -1;
    unsigned tick = 0;
    struct timespec next;
    clock_gettime(CLOCK_MONOTONIC, &next);

    while (!stopping) {
        /* (re)check the PL once a second, and every tick while it is down */
        if (!ok || tick % rate_hz == 0) {
            int op = pl_operating();
            if (!op) {
                ok = 0;
                if (last != 1) {
                    set_status(0, "not configured", "PL not loaded (fpga_manager state is not operating)");
                    last = 1;
                }
            } else if (!ok) {
                if (!regs && !sim && map_uio() < 0) {
                    if (last != 2) {
                        set_status(0, "operating", "PL loaded but axi_regs UIO device missing");
                        last = 2;
                    }
                } else {
                    uint32_t sig = read_reg(REG_SIGNATURE);
                    if (sig == SIGNATURE_VALUE) {
                        ok = 1;
                        set_status(1, "operating", "streaming HEARTBEAT");
                        last = 0;
                        logmsg(LOG_INFO, "PL up, SIGNATURE ok - streaming at %u Hz", rate_hz);
                    } else if (last != 3) {
                        char m[96];
                        snprintf(m, sizeof m, "unexpected SIGNATURE 0x%08" PRIx32 " (want 0x%08x)",
                                 sig, SIGNATURE_VALUE);
                        set_status(0, "operating", m);
                        last = 3;
                    }
                }
            }
        }

        if (ok) {
            struct sample s;
            s.hb = read_reg(REG_HEARTBEAT);
            s.t_us = (now_ns() - t0_ns) / 1000;
            pthread_mutex_lock(&g.lock);
            g.ring[g.head % RING_SIZE] = s;
            g.head++;
            if (g.head % per_batch == 0)
                pthread_cond_broadcast(&g.cond);
            pthread_mutex_unlock(&g.lock);
        }

        tick++;
        next.tv_nsec += (long)period;
        while (next.tv_nsec >= 1000000000L) {
            next.tv_nsec -= 1000000000L;
            next.tv_sec++;
        }
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
    }
    pthread_mutex_lock(&g.lock);
    pthread_cond_broadcast(&g.cond);
    pthread_mutex_unlock(&g.lock);
    return NULL;
}

/* ---- HTTP handlers ------------------------------------------------------- */

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
    char st[sizeof g.status];
    pthread_mutex_lock(&g.lock);
    memcpy(st, g.status, sizeof st);
    pthread_mutex_unlock(&g.lock);
    mg_printf(c, "HTTP/1.1 200 OK\r\n"
                 "Content-Type: application/json\r\n"
                 "Content-Length: %zu\r\n"
                 "Cache-Control: no-cache\r\n"
                 "Connection: close\r\n\r\n%s", strlen(st), st);
    return 200;
}

static int events_handler(struct mg_connection *c, void *cb)
{
    (void)cb;
    /* worst case one batch = RING_SIZE samples x ~32 chars */
    size_t cap = RING_SIZE * 32 + 64;
    char *buf = malloc(cap);
    struct sample *tmp = malloc(sizeof(struct sample) * RING_SIZE);
    if (!buf || !tmp) {
        free(buf);
        free(tmp);
        mg_printf(c, "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
        return 503;
    }

    if (mg_printf(c, "HTTP/1.1 200 OK\r\n"
                     "Content-Type: text/event-stream\r\n"
                     "Cache-Control: no-cache\r\n"
                     "Connection: close\r\n\r\n"
                     "retry: 1000\n\n") <= 0)
        goto out;

    pthread_mutex_lock(&g.lock);
    uint64_t idx = g.head > BACKLOG ? g.head - BACKLOG : 0;
    unsigned seen_gen = g.status_gen - 1;   /* force an initial status event */
    pthread_mutex_unlock(&g.lock);

    while (!stopping) {
        char st[sizeof g.status];
        int send_status = 0;
        size_t n = 0;

        pthread_mutex_lock(&g.lock);
        if (g.head == idx && g.status_gen == seen_gen && !stopping) {
            struct timespec dl;
            clock_gettime(CLOCK_REALTIME, &dl);
            dl.tv_sec += 1;
            pthread_cond_timedwait(&g.cond, &g.lock, &dl);
        }
        if (g.status_gen != seen_gen) {
            memcpy(st, g.status, sizeof st);
            seen_gen = g.status_gen;
            send_status = 1;
        }
        if (g.head - idx > RING_SIZE)             /* client fell behind */
            idx = g.head - RING_SIZE;
        for (; idx < g.head; idx++)
            tmp[n++] = g.ring[idx % RING_SIZE];
        pthread_mutex_unlock(&g.lock);

        if (send_status && mg_printf(c, "event: status\ndata: %s\n\n", st) <= 0)
            break;

        if (n) {
            size_t o = 0;
            o += (size_t)snprintf(buf + o, cap - o, "data: {\"t\":[");
            for (size_t i = 0; i < n; i++)
                o += (size_t)snprintf(buf + o, cap - o, "%s%" PRIu64, i ? "," : "", tmp[i].t_us);
            o += (size_t)snprintf(buf + o, cap - o, "],\"hb\":[");
            for (size_t i = 0; i < n; i++)
                o += (size_t)snprintf(buf + o, cap - o, "%s%" PRIu32, i ? "," : "", tmp[i].hb);
            o += (size_t)snprintf(buf + o, cap - o, "]}\n\n");
            if (mg_write(c, buf, o) <= 0)
                break;
        } else if (!send_status) {
            if (mg_printf(c, ": ping\n\n") <= 0)      /* keep-alive, detects dead clients */
                break;
        }
    }
out:
    free(buf);
    free(tmp);
    return 200;
}

/* ---- main ---------------------------------------------------------------- */

static void on_signal(int sig)
{
    (void)sig;
    stopping = 1;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s [-p port] [-r sample_hz] [-f]\n"
            "  -p  listening port(s), civetweb syntax (default 80)\n"
            "  -r  HEARTBEAT sample rate in Hz (default 200)\n"
            "  -f  foreground: also log to stderr\n"
            "  env FPGA_WEBSTREAM_SIM=1 fakes the PL registers\n", argv0);
}

int main(int argc, char **argv)
{
    const char *port = "80";
    int fg = 0, opt;

    while ((opt = getopt(argc, argv, "p:r:fh")) != -1) {
        switch (opt) {
        case 'p': port = optarg; break;
        case 'r': rate_hz = (unsigned)strtoul(optarg, NULL, 0); break;
        case 'f': fg = 1; break;
        default:  usage(argv[0]); return opt == 'h' ? 0 : 2;
        }
    }
    if (rate_hz < batch_hz || rate_hz > 100000) {
        fprintf(stderr, "sample rate must be %u..100000 Hz\n", batch_hz);
        return 2;
    }
    sim = getenv("FPGA_WEBSTREAM_SIM") != NULL;
    openlog("fpga-webstream", LOG_PID | (fg ? LOG_PERROR : 0), LOG_DAEMON);
    t0_ns = now_ns();
    set_status(0, "starting", "starting");

    struct sigaction sa = { .sa_handler = on_signal };
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    pthread_t th;
    if (pthread_create(&th, NULL, sampler, NULL) != 0) {
        logmsg(LOG_ERR, "pthread_create failed");
        return 1;
    }

    mg_init_library(0);
    const char *options[] = {
        "listening_ports", port,
        "num_threads", "16",          /* each open /events stream holds one */
        NULL
    };
    struct mg_callbacks cbs;
    memset(&cbs, 0, sizeof cbs);
    struct mg_context *ctx = mg_start(&cbs, NULL, options);
    if (!ctx) {
        logmsg(LOG_ERR, "cannot start web server on port %s", port);
        stopping = 1;
        pthread_join(th, NULL);
        return 1;
    }
    mg_set_request_handler(ctx, "/events", events_handler, NULL);
    mg_set_request_handler(ctx, "/api/status", status_handler, NULL);
    mg_set_request_handler(ctx, "/$", index_handler, NULL);
    mg_set_request_handler(ctx, "/index.html$", index_handler, NULL);
    logmsg(LOG_INFO, "listening on port %s%s", port, sim ? " (simulated PL)" : "");

    while (!stopping)
        pause();

    logmsg(LOG_INFO, "stopping");
    pthread_mutex_lock(&g.lock);
    pthread_cond_broadcast(&g.cond);
    pthread_mutex_unlock(&g.lock);
    mg_stop(ctx);
    pthread_join(th, NULL);
    mg_exit_library();
    return 0;
}
