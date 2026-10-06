/*
 * fpgad - the one process that touches the FPGA.
 *
 * Owns the axi_regs window (M_AXI_GP0 @ 0x4000_0000, via UIO) and the FPGA
 * manager. Everything else - the web server (fpga-web), fpgactl, future
 * processes - talks to fpgad over a UNIX socket and never maps the PL itself.
 * That keeps the safety rules in one place:
 *   - registers are accessed only while the PL is "operating" and SIGNATURE
 *     reads 0x5A5A1234 (a GP0 read with no PL design behind it hangs the SoC)
 *   - "load" reprograms the PL with every other access blocked meanwhile
 *
 * Protocol (one request line in, one response line out; text, '\n'-ended):
 *   ping                          -> ok pong
 *   status                        -> ok {"ok":true,"pl":"operating",...}
 *   read <off>                    -> ok 0x0000abcd
 *   write <off> <value>           -> ok
 *   load <firmware-file>          -> ok operating      (file in /lib/firmware)
 *   oled <row> <text>             -> ok                (OLED row 0..7, 16 chars;
 *                                     the rest of the line, spaces kept)
 *   oled clear                    -> ok
 *   stream <hz> <batch_hz> <off>... -> ok streaming, then until disconnect:
 *        data {"t":[us,...],"v":[[r0,...],[r1,...]]}   one line per batch
 *        status {...}                                   when the PL state changes
 * Errors: err <message>. Numbers accept 0x.. hex or decimal. <off> is a byte
 * offset into the axi_regs window, 4-byte aligned.
 *
 * FPGAD_SIM=1 in the environment simulates axi_regs (src/hdl/axi_regs.vhd)
 * so the whole stack runs on a PC.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <inttypes.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_SOCK    "/var/run/fpgad.sock"
#define FPGA_MGR        "/sys/class/fpga_manager/fpga0"
#define FIRMWARE_DIR    "/lib/firmware"
#define UIO_NAME        "axi_regs"
#define REG_HEARTBEAT   0x10
#define REG_SIGNATURE   0x1C
#define SIGNATURE_VALUE 0x5A5A1234u
#define REG_OLED_CTRL   0x20
#define REG_OLED_STAT   0x24
#define REG_OLED_TEXT   0x80            /* 128 chars, 4 per word, little-endian */
#define OLED_COLS       16
#define OLED_ROWS       8
#define MAX_CLIENTS     32
#define MAX_STREAM_REGS 8

static volatile sig_atomic_t stopping;
static int sim, foreground;
static volatile uint32_t *regs;
static size_t map_size = 0x1000;
static uint64_t t0_ns;

/* PL state: accesses hold the read lock, "load" holds the write lock */
static pthread_rwlock_t pl_lock = PTHREAD_RWLOCK_INITIALIZER;
static pthread_mutex_t st_lock = PTHREAD_MUTEX_INITIALIZER;
static int pl_ok;                       /* registers safe to touch */
static unsigned status_gen;             /* bumped on every status change */
static char status_json[256];
static int nclients;

/* ---- helpers ------------------------------------------------------------- */

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

static int send_all(int fd, const char *buf, size_t len)
{
    while (len) {
        ssize_t n = send(fd, buf, len, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

static int sendf(int fd, const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n < 0)
        return -1;
    return send_all(fd, buf, (size_t)n < sizeof buf ? (size_t)n : sizeof buf - 1);
}

static int parse_u32(const char *s, uint32_t *out)
{
    char *end;
    if (!s || !*s)
        return -1;
    errno = 0;
    unsigned long long v = strtoull(s, &end, 0);
    if (errno || *end || v > 0xFFFFFFFFull)
        return -1;
    *out = (uint32_t)v;
    return 0;
}

static void set_status(int ok, const char *pl, const char *msg)
{
    pthread_mutex_lock(&st_lock);
    char next[sizeof status_json];
    snprintf(next, sizeof next,
             "{\"ok\":%s,\"pl\":\"%s\",\"msg\":\"%s\",\"sim\":%s}",
             ok ? "true" : "false", pl, msg, sim ? "true" : "false");
    if (strcmp(next, status_json) != 0) {
        memcpy(status_json, next, sizeof next);
        status_gen++;
        logmsg(ok ? LOG_INFO : LOG_WARNING, "status: %s - %s", pl, msg);
    }
    pthread_mutex_unlock(&st_lock);
}

static unsigned get_status(char *out, size_t n)
{
    pthread_mutex_lock(&st_lock);
    snprintf(out, n, "%s", status_json);
    unsigned g = status_gen;
    pthread_mutex_unlock(&st_lock);
    return g;
}

/* ---- simulated axi_regs (mirrors src/hdl/axi_regs.vhd) -------------------- */

static uint32_t sim_regs[4];            /* SCRATCH0..2, CONTROL */
static uint64_t sim_hb_zero_ns;         /* when HEARTBEAT was last 0 */
static uint32_t sim_oled_ctrl = 0x00007F01;
static uint32_t sim_oled_text[32];      /* reset text set up in main() */

static uint32_t sim_heartbeat(void)
{
    if (sim_regs[3] & 2) {              /* CONTROL bit1 holds it at 0 */
        sim_hb_zero_ns = now_ns();
        return 0;
    }
    return (uint32_t)((now_ns() - sim_hb_zero_ns) / 10);   /* 100 MHz */
}

static uint32_t sim_read(uint32_t off)
{
    unsigned idx = (off >> 2) & 63;     /* the map repeats every 256 bytes */
    uint32_t hb = sim_heartbeat();
    if (idx >= REG_OLED_TEXT / 4)
        return sim_oled_text[idx - REG_OLED_TEXT / 4];
    switch (idx) {
    case 0: case 1: case 2: case 3: return sim_regs[idx];
    case 4: return hb;
    case 5: return sim_regs[0] + sim_regs[1];
    case 6: return (sim_regs[0] != 0)
                 | ((uint32_t)(sim_regs[1] == 0xFFFFFFFFu) << 1)
                 | ((uint32_t)(sim_regs[0] == sim_regs[1]) << 2)
                 | ((sim_regs[3] & 1) << 3)
                 | ((uint32_t)__builtin_popcount(sim_regs[2]) << 8)
                 | ((hb & 0xFFFF) << 16);
    case 7: return SIGNATURE_VALUE;
    case REG_OLED_CTRL / 4: return sim_oled_ctrl;
    case REG_OLED_STAT / 4: return ((uint32_t)((now_ns() - t0_ns) / 33333333u) << 16) | 1;
    default: return 0;
    }
}

static void sim_oled_set_row(int row, const char *s)
{
    for (int i = 0; i < OLED_COLS; i++) {
        unsigned n = (unsigned)(row * OLED_COLS + i);
        uint32_t c = (uint8_t)(*s ? *s++ : ' ');
        sim_oled_text[n / 4] = (sim_oled_text[n / 4] & ~(0xFFu << (8 * (n % 4)))) | c << (8 * (n % 4));
    }
}

static void sim_write(uint32_t off, uint32_t v)
{
    unsigned idx = (off >> 2) & 63;
    if (idx < 4) {
        if (idx == 3 && (sim_regs[3] & 2) && !(v & 2))
            sim_hb_zero_ns = now_ns();  /* released from clear: count from 0 */
        sim_regs[idx] = v;
    } else if (idx == REG_OLED_CTRL / 4) {
        sim_oled_ctrl = v;
    } else if (idx >= REG_OLED_TEXT / 4) {
        sim_oled_text[idx - REG_OLED_TEXT / 4] = v;
    }
}

/* ---- PL state + mapping -------------------------------------------------- */

static int read_sysfs(const char *path, char *buf, size_t n)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    if (!fgets(buf, (int)n, f))
        buf[0] = 0;
    fclose(f);
    buf[strcspn(buf, "\n")] = 0;
    return 0;
}

static int pl_operating(char *state, size_t n)
{
    if (sim) {
        snprintf(state, n, "operating");
        return 1;
    }
    if (read_sysfs(FPGA_MGR "/state", state, n) < 0)
        snprintf(state, n, "no fpga_manager");
    return strcmp(state, "operating") == 0;
}

static int map_uio(void)
{
    glob_t gl;
    char path[128], name[64];
    int idx = -1;

    if (glob("/sys/class/uio/uio*/name", 0, NULL, &gl) != 0)
        return -1;
    for (size_t i = 0; i < gl.gl_pathc && idx < 0; i++)
        if (read_sysfs(gl.gl_pathv[i], name, sizeof name) == 0 &&
            strncmp(name, UIO_NAME, strlen(UIO_NAME)) == 0)
            sscanf(gl.gl_pathv[i], "/sys/class/uio/uio%d/", &idx);
    globfree(&gl);
    if (idx < 0)
        return -1;

    snprintf(path, sizeof path, "/sys/class/uio/uio%d/maps/map0/size", idx);
    if (read_sysfs(path, name, sizeof name) == 0) {
        unsigned long v = strtoul(name, NULL, 0);
        if (v)
            map_size = v;
    }
    snprintf(path, sizeof path, "/dev/uio%d", idx);
    int fd = open(path, O_RDWR | O_SYNC);
    if (fd < 0)
        return -1;
    void *p = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED)
        return -1;
    regs = p;
    logmsg(LOG_INFO, "mapped %s (%zu bytes) for %s", path, map_size, UIO_NAME);
    return 0;
}

static inline uint32_t raw_read(uint32_t off)
{
    return sim ? sim_read(off) : regs[off / 4];
}

static inline void raw_write(uint32_t off, uint32_t v)
{
    if (sim)
        sim_write(off, v);
    else
        regs[off / 4] = v;
}

/* (re)validate the PL; caller holds pl_lock for writing */
static void check_pl_locked(void)
{
    char state[64], msg[160];
    if (!pl_operating(state, sizeof state)) {
        pl_ok = 0;
        snprintf(msg, sizeof msg, "PL not configured (fpga_manager: %s)", state);
        set_status(0, "not configured", msg);
        return;
    }
    if (!sim && !regs && map_uio() < 0) {
        pl_ok = 0;
        set_status(0, "operating",
                   "no UIO device " UIO_NAME " (kernel arg uio_pdrv_genirq.of_id=generic-uio?)");
        return;
    }
    uint32_t sig = raw_read(REG_SIGNATURE);
    if (sig != SIGNATURE_VALUE) {
        pl_ok = 0;
        snprintf(msg, sizeof msg, "unexpected SIGNATURE 0x%08" PRIx32 " (want 0x%08x)", sig,
                 SIGNATURE_VALUE);
        set_status(0, "operating", msg);
        return;
    }
    pl_ok = 1;
    set_status(1, "operating", "ready");
}

/* re-check once a second: catches the PL going away / coming up */
static void *monitor(void *arg)
{
    (void)arg;
    while (!stopping) {
        char state[64];
        int op = pl_operating(state, sizeof state);
        if (op != pl_ok) {
            pthread_rwlock_wrlock(&pl_lock);
            check_pl_locked();
            pthread_rwlock_unlock(&pl_lock);
        }
        sleep(1);
    }
    return NULL;
}

/* checked register access; returns 0 or -1 with err filled */
static int reg_access(int write, uint32_t off, uint32_t *val, char *err, size_t n)
{
    if (off % 4 || off >= map_size) {
        snprintf(err, n, "offset 0x%" PRIx32 " outside the 0x%zx-byte window or unaligned", off,
                 map_size);
        return -1;
    }
    pthread_rwlock_rdlock(&pl_lock);
    if (!pl_ok) {
        pthread_rwlock_unlock(&pl_lock);
        char st[sizeof status_json];
        get_status(st, sizeof st);
        snprintf(err, n, "PL not ready %s", st);
        return -1;
    }
    if (write)
        raw_write(off, *val);
    else
        *val = raw_read(off);
    pthread_rwlock_unlock(&pl_lock);
    return 0;
}

/* reprogram the PL; everything else waits on the write lock meanwhile */
static int pl_load(const char *name, char *err, size_t n)
{
    char path[256];
    if (!*name || strchr(name, '/') || strstr(name, "..")) {
        snprintf(err, n, "firmware must be a plain file name in " FIRMWARE_DIR);
        return -1;
    }
    snprintf(path, sizeof path, FIRMWARE_DIR "/%s", name);
    if (!sim && access(path, R_OK) != 0) {
        snprintf(err, n, "no %s", path);
        return -1;
    }
    pthread_rwlock_wrlock(&pl_lock);
    pl_ok = 0;
    set_status(0, "loading", name);
    logmsg(LOG_INFO, "loading PL from %s", path);
    int rc = 0;
    if (!sim) {
        FILE *f = fopen(FPGA_MGR "/flags", "w");
        if (f) {
            fputs("0", f);                      /* full bitstream */
            fclose(f);
        }
        /* the load happens on this write; a bad bitstream fails at fclose (flush) */
        f = fopen(FPGA_MGR "/firmware", "w");
        int bad = !f;
        if (f) {
            bad = fputs(name, f) < 0;
            if (fclose(f) != 0)
                bad = 1;
        }
        if (bad) {
            snprintf(err, n, "writing " FPGA_MGR "/firmware failed: %s", strerror(errno));
            rc = -1;
        }
    }
    check_pl_locked();
    if (rc == 0 && !pl_ok) {
        char st[sizeof status_json];
        get_status(st, sizeof st);
        snprintf(err, n, "PL not usable after load %s", st);
        rc = -1;
    }
    pthread_rwlock_unlock(&pl_lock);
    return rc;
}

/* ---- OLED text ----------------------------------------------------------- */

/* write one 16-character row of the OLED text buffer (padded with spaces,
 * non-printable -> '?'), or blank the whole display for row < 0 */
static int oled_text(int row, const char *s, char *err, size_t n)
{
    int first = row < 0 ? 0 : row, last = row < 0 ? OLED_ROWS - 1 : row;
    for (int r = first; r <= last; r++) {
        const char *p = row < 0 ? "" : s;
        for (int w = 0; w < OLED_COLS / 4; w++) {
            uint32_t v = 0;
            for (int b = 0; b < 4; b++) {
                uint8_t c = *p ? (uint8_t)*p++ : ' ';
                v |= (uint32_t)(c >= 0x20 && c < 0x7F ? c : '?') << (8 * b);
            }
            uint32_t off = REG_OLED_TEXT + (uint32_t)(r * OLED_COLS + w * 4);
            if (reg_access(1, off, &v, err, n))
                return -1;
        }
    }
    return 0;
}

static void do_oled(int fd, char *args)
{
    char err[320], *end;
    while (*args == ' ' || *args == '\t')
        args++;
    args[strcspn(args, "\r")] = 0;
    if (!strcmp(args, "clear")) {
        if (oled_text(-1, NULL, err, sizeof err))
            sendf(fd, "err %s\n", err);
        else
            sendf(fd, "ok\n");
        return;
    }
    long row = strtol(args, &end, 10);
    if (end == args || row < 0 || row >= OLED_ROWS || (*end && *end != ' ' && *end != '\t')) {
        sendf(fd, "err usage: oled <row 0..%d> <text> | oled clear\n", OLED_ROWS - 1);
        return;
    }
    if (*end)
        end++;                                  /* one separator; the rest is the text */
    if (strlen(end) > OLED_COLS)
        logmsg(LOG_INFO, "oled: row %ld text truncated to %d chars", row, OLED_COLS);
    if (oled_text((int)row, end, err, sizeof err))
        sendf(fd, "err %s\n", err);
    else
        sendf(fd, "ok\n");
}

/* ---- streaming ----------------------------------------------------------- */

static void do_stream(int fd, char **argv, int argc)
{
    uint32_t hz, batch_hz, offs[MAX_STREAM_REGS];
    int nregs = argc - 3;
    if (argc < 4 || nregs > MAX_STREAM_REGS ||
        parse_u32(argv[1], &hz) || parse_u32(argv[2], &batch_hz) ||
        hz < 1 || hz > 10000 || batch_hz < 1 || batch_hz > hz) {
        sendf(fd, "err usage: stream <hz 1..10000> <batch_hz 1..hz> <off> [<off>... up to %d]\n",
              MAX_STREAM_REGS);
        return;
    }
    for (int i = 0; i < nregs; i++)
        if (parse_u32(argv[3 + i], &offs[i]) || offs[i] % 4 || offs[i] >= map_size) {
            sendf(fd, "err bad offset %s\n", argv[3 + i]);
            return;
        }
    if (sendf(fd, "ok streaming\n") < 0)
        return;

    const unsigned per_batch = hz / batch_hz;
    const uint64_t period = 1000000000ull / hz;
    size_t cap = (size_t)per_batch * (12 + 12 * (size_t)nregs) + 64;
    char *buf = malloc(cap);
    uint64_t *ts = malloc(sizeof(uint64_t) * per_batch);
    uint32_t *vals = malloc(sizeof(uint32_t) * per_batch * (size_t)nregs);
    if (!buf || !ts || !vals)
        goto out;

    unsigned seen_gen = ~0u, n = 0;
    struct timespec next;
    clock_gettime(CLOCK_MONOTONIC, &next);
    while (!stopping) {
        char st[sizeof status_json];
        unsigned g = get_status(st, sizeof st);
        if (g != seen_gen) {
            seen_gen = g;
            if (sendf(fd, "status %s\n", st) < 0)
                break;
            n = 0;                              /* drop a half batch across a state change */
        }
        pthread_rwlock_rdlock(&pl_lock);
        if (pl_ok) {
            ts[n] = (now_ns() - t0_ns) / 1000;
            for (int r = 0; r < nregs; r++)
                vals[(size_t)r * per_batch + n] = raw_read(offs[r]);
            n++;
        }
        pthread_rwlock_unlock(&pl_lock);

        if (n == per_batch) {
            size_t o = (size_t)snprintf(buf, cap, "data {\"t\":[");
            for (unsigned i = 0; i < n; i++)
                o += (size_t)snprintf(buf + o, cap - o, "%s%" PRIu64, i ? "," : "", ts[i]);
            o += (size_t)snprintf(buf + o, cap - o, "],\"v\":[");
            for (int r = 0; r < nregs; r++) {
                o += (size_t)snprintf(buf + o, cap - o, "%s[", r ? "," : "");
                for (unsigned i = 0; i < n; i++)
                    o += (size_t)snprintf(buf + o, cap - o, "%s%" PRIu32, i ? "," : "",
                                          vals[(size_t)r * per_batch + i]);
                o += (size_t)snprintf(buf + o, cap - o, "]");
            }
            o += (size_t)snprintf(buf + o, cap - o, "]}\n");
            if (send_all(fd, buf, o) < 0)
                break;
            n = 0;
        }
        next.tv_nsec += (long)period;
        while (next.tv_nsec >= 1000000000L) {
            next.tv_nsec -= 1000000000L;
            next.tv_sec++;
        }
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
    }
out:
    free(buf);
    free(ts);
    free(vals);
}

/* ---- clients ------------------------------------------------------------- */

static void handle_line(int fd, char *line)
{
    if (!strncmp(line, "oled", 4) && (line[4] == ' ' || line[4] == '\t' || !line[4])) {
        do_oled(fd, line + 4);                  /* before strtok: the text keeps its spaces */
        return;
    }
    char *argv[16];
    int argc = 0;
    for (char *tok = strtok(line, " \t\r"); tok && argc < 16; tok = strtok(NULL, " \t\r"))
        argv[argc++] = tok;
    if (!argc)
        return;

    char err[320];
    uint32_t off, val;
    if (!strcmp(argv[0], "ping")) {
        sendf(fd, "ok pong\n");
    } else if (!strcmp(argv[0], "status")) {
        char st[sizeof status_json];
        get_status(st, sizeof st);
        sendf(fd, "ok %s\n", st);
    } else if (!strcmp(argv[0], "read")) {
        if (argc != 2 || parse_u32(argv[1], &off))
            sendf(fd, "err usage: read <off>\n");
        else if (reg_access(0, off, &val, err, sizeof err))
            sendf(fd, "err %s\n", err);
        else
            sendf(fd, "ok 0x%08" PRIx32 "\n", val);
    } else if (!strcmp(argv[0], "write")) {
        if (argc != 3 || parse_u32(argv[1], &off) || parse_u32(argv[2], &val))
            sendf(fd, "err usage: write <off> <value>\n");
        else if (reg_access(1, off, &val, err, sizeof err))
            sendf(fd, "err %s\n", err);
        else
            sendf(fd, "ok\n");
    } else if (!strcmp(argv[0], "load")) {
        if (argc != 2)
            sendf(fd, "err usage: load <firmware-file in " FIRMWARE_DIR ">\n");
        else if (pl_load(argv[1], err, sizeof err))
            sendf(fd, "err %s\n", err);
        else
            sendf(fd, "ok operating\n");
    } else if (!strcmp(argv[0], "stream")) {
        do_stream(fd, argv, argc);
    } else {
        sendf(fd, "err unknown command '%s' (ping status read write load stream oled)\n",
              argv[0]);
    }
}

static void *client(void *arg)
{
    int fd = (int)(intptr_t)arg;
    char buf[1024];
    size_t len = 0;
    for (;;) {
        ssize_t n = recv(fd, buf + len, sizeof buf - 1 - len, 0);
        if (n <= 0)
            break;
        len += (size_t)n;
        buf[len] = 0;
        char *nl;
        while ((nl = memchr(buf, '\n', len))) {
            *nl = 0;
            handle_line(fd, buf);
            size_t used = (size_t)(nl - buf) + 1;
            memmove(buf, nl + 1, len - used);
            len -= used;
            buf[len] = 0;
        }
        if (len == sizeof buf - 1) {
            sendf(fd, "err line too long\n");
            break;
        }
    }
    close(fd);
    __atomic_sub_fetch(&nclients, 1, __ATOMIC_SEQ_CST);
    return NULL;
}

/* ---- main ---------------------------------------------------------------- */

static void on_signal(int sig)
{
    (void)sig;
    stopping = 1;
}

int main(int argc, char **argv)
{
    const char *sock_path = DEFAULT_SOCK;
    int opt;
    while ((opt = getopt(argc, argv, "s:fh")) != -1) {
        switch (opt) {
        case 's': sock_path = optarg; break;
        case 'f': foreground = 1; break;
        default:
            fprintf(stderr, "usage: %s [-s socket] [-f]\n"
                            "  -s  UNIX socket path (default " DEFAULT_SOCK ")\n"
                            "  -f  foreground: also log to stderr\n"
                            "  env FPGAD_SIM=1 simulates axi_regs\n", argv[0]);
            return opt == 'h' ? 0 : 2;
        }
    }
    sim = getenv("FPGAD_SIM") != NULL;
    openlog("fpgad", LOG_PID | (foreground ? LOG_PERROR : 0), LOG_DAEMON);
    t0_ns = sim_hb_zero_ns = now_ns();
    static const char *const sim_text[OLED_ROWS] = {   /* OLED_TEXT_RESET in axi_regs.vhd */
        "Hello, Zynq Mini", "", "SSD1306 driven", "from the PL", "", "", "", "fpgactl oled ...",
    };
    for (int r = 0; r < OLED_ROWS; r++)
        sim_oled_set_row(r, sim_text[r]);

    struct sigaction sa = { .sa_handler = on_signal };
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    pthread_rwlock_wrlock(&pl_lock);
    check_pl_locked();
    pthread_rwlock_unlock(&pl_lock);

    int ls = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    if (ls < 0 || strlen(sock_path) >= sizeof addr.sun_path) {
        logmsg(LOG_ERR, "bad socket path %s", sock_path);
        return 1;
    }
    strcpy(addr.sun_path, sock_path);
    unlink(sock_path);
    mode_t old = umask(0117);                   /* socket 0660 */
    int rc = bind(ls, (struct sockaddr *)&addr, sizeof addr);
    umask(old);
    if (rc < 0 || listen(ls, 16) < 0) {
        logmsg(LOG_ERR, "cannot listen on %s: %s", sock_path, strerror(errno));
        return 1;
    }

    pthread_t mon;
    pthread_create(&mon, NULL, monitor, NULL);
    logmsg(LOG_INFO, "listening on %s%s", sock_path, sim ? " (simulated PL)" : "");

    while (!stopping) {
        struct pollfd pfd = { .fd = ls, .events = POLLIN };
        if (poll(&pfd, 1, 500) <= 0)
            continue;
        int c = accept4(ls, NULL, NULL, SOCK_CLOEXEC);
        if (c < 0)
            continue;
        if (__atomic_add_fetch(&nclients, 1, __ATOMIC_SEQ_CST) > MAX_CLIENTS) {
            sendf(c, "err busy (%d clients)\n", MAX_CLIENTS);
            close(c);
            __atomic_sub_fetch(&nclients, 1, __ATOMIC_SEQ_CST);
            continue;
        }
        pthread_t th;
        pthread_attr_t at;
        pthread_attr_init(&at);
        pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&th, &at, client, (void *)(intptr_t)c) != 0) {
            close(c);
            __atomic_sub_fetch(&nclients, 1, __ATOMIC_SEQ_CST);
        }
        pthread_attr_destroy(&at);
    }
    logmsg(LOG_INFO, "stopping");
    close(ls);
    unlink(sock_path);
    return 0;
}
