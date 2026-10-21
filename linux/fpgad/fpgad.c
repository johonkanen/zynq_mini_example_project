/*
 * fpgad - the one process that touches the FPGA.
 *
 * Owns the PL: loads FPGA designs (bitstream + device-tree overlay, see
 * doc/network_update.md) and owns the axi_regs window they bring (M_AXI_GP0 @
 * 0x4000_0000, via UIO). Everything else - the web server (fpga-web), fpgactl,
 * future processes - talks to fpgad over a UNIX socket and never maps the PL
 * itself. That keeps the safety rules in one place:
 *   - registers are accessed only while the loaded design passed its checks
 *     (SIGNATURE 0x5A5A1234, BUILD_ID as in its manifest, a known REGMAP); a
 *     GP0 read with no working design behind it hangs the SoC
 *   - loading a design blocks every other access meanwhile
 *   - a new design is loaded as a trial and kept only if it passes; otherwise
 *     the last good design (/data/pl/good) is loaded again. A reset during a
 *     trial (the design hung the bus -> hardware watchdog) also ends up on the
 *     good design at the next start.
 *   - the hardware watchdog (/dev/watchdog) is kicked only after a register
 *     read returned, so a bus hang resets the board instead of needing JTAG
 *
 * Protocol (one request line in, one response line out; text, '\n'-ended):
 *   ping                          -> ok pong
 *   status                        -> ok {"ok":true,"pl":"operating",...}
 *   read <off>                    -> ok 0x0000abcd
 *   write <off> <value>           -> ok
 *   activate [<dir>]              -> ok {design...}    trial-load a design tree
 *        (default /data/rauc/pl/design, where RAUC installs PL bundles):
 *        zynq-mini-pl.bit.bin + zynq-mini-pl.dtbo + manifest.json. Kept as the
 *        good design if it passes, else the good one is reloaded (err ...).
 *   load <dir>                    -> same as activate
 *   pl                            -> ok {"loaded":true,"version":...,"build_id":...}
 *   oled <row> <text>             -> ok                (OLED row 0..7, 16 chars;
 *                                     the rest of the line, spaces kept)
 *   oled clear                    -> ok
 *   capture [key=value...]        -> ok capture {meta...,"bytes":N} + N raw bytes
 *        one oscilloscope acquisition (src/hdl/scope_capture.vhd). Keys (any
 *        left out keep their current register value):
 *          src=a,b,c,d  channel sources 0..15     div=N    sample every N clk, 1..100000
 *          trig=0..3    trigger channel           edge=rise|fall    level=-32768..32767
 *          pre=0..4095  samples before trigger    timeout=ms  wait for a trigger, 0..5000
 *          auto=0|1     force a trigger after the timeout (1) or reply "ok timeout" (0)
 *        Data: int16 little-endian, channel-major [ch][n], in time order; the
 *        trigger sample is number "pre".
 *   sensors                       -> ok {"temp":45.12,"vccint":1.001,...}
 *        Zynq XADC via the kernel's IIO driver (xilinx-xadc, PS-XADC interface):
 *        die temperature in degC and the supply rails in V. Works without the PL.
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
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <linux/watchdog.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
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
#define REG_BUILD_ID    0x28
#define REG_REGMAP      0x2C
#define REG_SIGNATURE   0x1C
#define SIGNATURE_VALUE 0x5A5A1234u
#define REG_OLED_CTRL   0x20
#define REG_OLED_STAT   0x24
#define REG_OLED_TEXT   0x80            /* 128 chars, 4 per word, little-endian */
#define OLED_COLS       16
#define OLED_ROWS       8
#define REG_SCOPE_CMD   0x40            /* bit0 arm, bit1 force, bit2 abort */
#define REG_SCOPE_STAT  0x44
#define REG_SCOPE_TRIG  0x48
#define REG_SCOPE_PRE   0x4C
#define REG_SCOPE_DIV   0x50
#define REG_SCOPE_SRC   0x54
#define REG_SCOPE_INFO  0x58
#define REG_GEN_FTW_A   0x60
#define REG_GEN_FTW_B   0x64
#define SCOPE_RAM       0x8000
#define SCOPE_CH        4
#define SCOPE_DEPTH     4096
#define SCOPE_INFO_VAL  0x00640C04u     /* 100 MHz, 2^12 deep, 4 channels */
#define SCOPE_FCLK_HZ   100000000.0
#define SCOPE_DIV_MAX   100000
#define MAX_CLIENTS     32
#define MAX_STREAM_REGS 8

static volatile sig_atomic_t stopping;
static int sim, foreground, no_watchdog;
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

/* number at the start of s (stops at the first non-digit) */
static int parse_u32_prefix(const char *s, uint32_t *out)
{
    char *end;
    errno = 0;
    unsigned long long v = strtoull(s, &end, 0);
    if (errno || end == s || v > 0xFFFFFFFFull)
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
static uint32_t sim_build_id;           /* BUILD_ID of the "loaded" sim design */
static uint64_t sim_hb_zero_ns;         /* when HEARTBEAT was last 0 */
static uint32_t sim_oled_ctrl = 0x00007F01;
static uint32_t sim_oled_text[32];      /* reset text set up in main() */
/* SCOPE_TRIG, PRE, DIV, SRC, -, -, GEN_FTW_A, B (reset values as in axi_regs.vhd) */
static uint32_t sim_scope[8] = { 0, 2048, 1, 0x7421, 0, 0, 0x028F5C29, 0x00A3D70A };

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
    if (idx >= REG_SCOPE_TRIG / 4 && idx <= REG_GEN_FTW_B / 4 && idx != REG_SCOPE_INFO / 4 &&
        idx != REG_SCOPE_INFO / 4 + 1)
        return sim_scope[idx - REG_SCOPE_TRIG / 4];
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
    case REG_SCOPE_INFO / 4: return SCOPE_INFO_VAL;
    case REG_BUILD_ID / 4: return sim_build_id;
    case REG_REGMAP / 4: return 1;
    case REG_SCOPE_STAT / 4: return 4;  /* done; sim captures happen in sim_capture() */
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
    } else if (idx >= REG_SCOPE_TRIG / 4 && idx <= REG_GEN_FTW_B / 4 && idx != REG_SCOPE_INFO / 4 &&
               idx != REG_SCOPE_INFO / 4 + 1) {
        sim_scope[idx - REG_SCOPE_TRIG / 4] = v;
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

/* the PL went away behind our back (only fpgad loads designs, so this should
 * not happen); never re-enable on our own - only a load checks a design */
static void *monitor(void *arg)
{
    (void)arg;
    while (!stopping) {
        char state[64], msg[160];
        if (pl_ok && !pl_operating(state, sizeof state)) {
            pthread_rwlock_wrlock(&pl_lock);
            pl_ok = 0;
            snprintf(msg, sizeof msg, "PL not configured any more (fpga_manager: %s)", state);
            set_status(0, "not configured", msg);
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

/* ---- FPGA designs: overlay + bitstream, trial and rollback ---------------- */

#define PL_FW_NAME      "zynq-mini-pl.bit.bin"
#define PL_DTBO_NAME    "zynq-mini-pl.dtbo"
#define PL_MANIFEST     "manifest.json"
#define PL_CANDIDATE    "/data/rauc/pl/design"      /* RAUC artifact link */
#define OVERLAY_DIR     "/sys/kernel/config/device-tree/overlays/pl"

/* register maps this fpgad understands (axi_regs.vhd REGMAP_VERSION) */
static const uint32_t REGMAPS[] = { 1 };

static char pl_dir[128] = "/data/pl";               /* good/ + trial marker; FPGAD_PL_DIR */

struct design {
    char version[64], git[32], date[32];
    uint32_t build_id, regmap;
};
static struct design pl_cur;                        /* loaded design (valid while pl_ok) */
static char pl_note[200];                           /* e.g. a trial that did not survive */

static int json_str(const char *j, const char *key, char *out, size_t n)
{
    char k[48];
    snprintf(k, sizeof k, "\"%s\":\"", key);
    const char *p = strstr(j, k);
    if (!p)
        return -1;
    p += strlen(k);
    size_t len = strcspn(p, "\"");
    snprintf(out, n, "%.*s", (int)(len < n ? len : n - 1), p);
    return 0;
}

static int json_u32(const char *j, const char *key, uint32_t *out)
{
    char k[48];
    snprintf(k, sizeof k, "\"%s\":", key);
    const char *p = strstr(j, k);
    if (!p)
        return -1;
    return parse_u32_prefix(p + strlen(k), out);
}

static int read_file(const char *path, char *buf, size_t n, size_t *len)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    ssize_t r = read(fd, buf, n - 1);
    close(fd);
    if (r < 0)
        return -1;
    buf[r] = 0;
    if (len)
        *len = (size_t)r;
    return 0;
}

static int read_manifest(const char *dir, struct design *d, char *err, size_t n)
{
    char path[256], j[1024];
    snprintf(path, sizeof path, "%s/" PL_MANIFEST, dir);
    memset(d, 0, sizeof *d);
    if (read_file(path, j, sizeof j, NULL) < 0) {
        snprintf(err, n, "no %.250s", path);
        return -1;
    }
    if (json_u32(j, "build_id", &d->build_id) || json_u32(j, "regmap", &d->regmap) ||
        json_str(j, "version", d->version, sizeof d->version)) {
        snprintf(err, n, "%s: no build_id / regmap / version", path);
        return -1;
    }
    json_str(j, "git", d->git, sizeof d->git);
    json_str(j, "date", d->date, sizeof d->date);
    return 0;
}

static int regmap_supported(uint32_t v)
{
    for (size_t i = 0; i < sizeof REGMAPS / sizeof REGMAPS[0]; i++)
        if (REGMAPS[i] == v)
            return 1;
    return 0;
}

static void unmap_uio(void)
{
    if (regs)
        munmap((void *)regs, map_size);
    regs = NULL;
}

static int write_all_file(const char *path, const void *data, size_t len)
{
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    const char *p = data;
    while (len) {
        ssize_t w = write(fd, p, len);
        if (w <= 0) {
            close(fd);
            return -1;
        }
        p += w;
        len -= (size_t)w;
    }
    return close(fd);
}

/* the read-back checks every design has to pass; caller holds pl_lock (write) */
static int check_design(const struct design *want, char *err, size_t n)
{
    uint32_t sig = raw_read(REG_SIGNATURE);
    if (sig != SIGNATURE_VALUE) {
        snprintf(err, n, "SIGNATURE 0x%08" PRIx32 " (want 0x%08x)", sig, SIGNATURE_VALUE);
        return -1;
    }
    uint32_t bid = raw_read(REG_BUILD_ID), rm = raw_read(REG_REGMAP);
    if (bid != want->build_id) {
        snprintf(err, n, "BUILD_ID %" PRIu32 " but the manifest says %" PRIu32 " - not this "
                 "bundle's bitstream", bid, want->build_id);
        return -1;
    }
    if (rm != want->regmap || !regmap_supported(rm)) {
        snprintf(err, n, "REGMAP %" PRIu32 " (manifest %" PRIu32 ") not supported by this fpgad",
                 rm, want->regmap);
        return -1;
    }
    return 0;
}

/*
 * Load the design in dir: remove the old overlay (unbinds its UIO node), point
 * /lib/firmware/zynq-mini-pl.bit.bin at the new bitstream, apply the new
 * overlay (the kernel programs the PL, then creates the nodes), map the new
 * UIO node and run the checks. Caller holds pl_lock for writing.
 */
static int load_design_locked(const char *dir, char *err, size_t n)
{
    struct design d;
    char real[PATH_MAX], path[PATH_MAX + 32], buf[64];
    if (read_manifest(dir, &d, err, n) < 0)
        return -1;
    if (!realpath(dir, real)) {
        snprintf(err, n, "%.200s: %s", dir, strerror(errno));
        return -1;
    }
    pl_ok = 0;
    set_status(0, "loading", d.version);
    logmsg(LOG_INFO, "loading design %s (build_id %" PRIu32 ") from %s", d.version, d.build_id, real);

    if (sim) {
        /* test hook: a design dir with a "sim-bad" file reads back the wrong BUILD_ID */
        snprintf(path, sizeof path, "%s/sim-bad", real);
        sim_build_id = access(path, F_OK) == 0 ? d.build_id ^ 1 : d.build_id;
    } else {
        unmap_uio();
        if (access(OVERLAY_DIR, F_OK) == 0 && rmdir(OVERLAY_DIR) < 0) {
            snprintf(err, n, "removing the old overlay: %s", strerror(errno));
            goto fail;
        }
        /* the overlay's firmware-name refers to this link */
        mkdir(FIRMWARE_DIR, 0755);
        snprintf(path, sizeof path, "%s/" PL_FW_NAME, real);
        if (access(path, R_OK) < 0) {
            snprintf(err, n, "no %.250s", path);
            goto fail;
        }
        unlink(FIRMWARE_DIR "/." PL_FW_NAME ".new");
        if (symlink(path, FIRMWARE_DIR "/." PL_FW_NAME ".new") < 0 ||
            rename(FIRMWARE_DIR "/." PL_FW_NAME ".new", FIRMWARE_DIR "/" PL_FW_NAME) < 0) {
            snprintf(err, n, "firmware link: %s", strerror(errno));
            goto fail;
        }
        static char dtbo[65536];
        size_t len;
        snprintf(path, sizeof path, "%s/" PL_DTBO_NAME, real);
        if (read_file(path, dtbo, sizeof dtbo, &len) < 0 || len == 0) {
            snprintf(err, n, "no %.250s", path);
            goto fail;
        }
        if (mkdir(OVERLAY_DIR, 0755) < 0) {
            snprintf(err, n, "creating " OVERLAY_DIR ": %s (CONFIG_OF_CONFIGFS? configfs mounted?)",
                     strerror(errno));
            goto fail;
        }
        /* writing the overlay applies it: bitstream first, then the nodes */
        int wr = write_all_file(OVERLAY_DIR "/dtbo", dtbo, len);
        if (read_sysfs(OVERLAY_DIR "/status", buf, sizeof buf) < 0 || strcmp(buf, "applied")) {
            snprintf(err, n, "overlay not applied (%s%s%s) - bad bitstream or dtbo?", buf,
                     wr < 0 ? ", " : "", wr < 0 ? strerror(errno) : "");
            rmdir(OVERLAY_DIR);
            goto fail;
        }
        if (!pl_operating(buf, sizeof buf)) {
            snprintf(err, n, "fpga_manager state %s after the load", buf);
            rmdir(OVERLAY_DIR);
            goto fail;
        }
        int tries = 0;
        while (map_uio() < 0 && ++tries < 30)
            usleep(100000);             /* udev-less: the node appears right away, but wait a bit */
        if (!regs) {
            snprintf(err, n, "no UIO device " UIO_NAME " after the overlay "
                     "(kernel arg uio_pdrv_genirq.of_id=generic-uio?)");
            goto fail;
        }
    }
    if (check_design(&d, err, n) < 0)
        goto fail;
    pl_cur = d;
    pl_ok = 1;
    char m[96];
    snprintf(m, sizeof m, "ready: design %s", d.version);
    set_status(1, "operating", m);
    logmsg(LOG_INFO, "design %s is up", d.version);
    return 0;
fail:
    pl_ok = 0;
    set_status(0, "failed", err);
    logmsg(LOG_ERR, "design %s: %s", d.version, err);
    return -1;
}

static int copy_file(const char *src, const char *dst)
{
    int in = open(src, O_RDONLY | O_CLOEXEC);
    if (in < 0)
        return -1;
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (out < 0) {
        close(in);
        return -1;
    }
    char buf[65536];
    ssize_t r;
    int rc = 0;
    while ((r = read(in, buf, sizeof buf)) > 0)
        if (write(out, buf, (size_t)r) != r) {
            rc = -1;
            break;
        }
    if (r < 0 || fsync(out) < 0)
        rc = -1;
    close(in);
    if (close(out) < 0)
        rc = -1;
    return rc;
}

static void remove_design_dir(const char *dir)
{
    char p[256];
    const char *files[] = { PL_FW_NAME, PL_DTBO_NAME, PL_MANIFEST };
    for (size_t i = 0; i < 3; i++) {
        snprintf(p, sizeof p, "%s/%s", dir, files[i]);
        unlink(p);
    }
    rmdir(dir);
}

/* copy dir's design to pl_dir/good: good.new, then swap it in with renames */
static int keep_as_good(const char *dir, char *err, size_t n)
{
    char good[160], gnew[160], gold[160], a[256], b[256];
    snprintf(good, sizeof good, "%s/good", pl_dir);
    snprintf(gnew, sizeof gnew, "%s/good.new", pl_dir);
    snprintf(gold, sizeof gold, "%s/good.old", pl_dir);
    char r1[PATH_MAX], r2[PATH_MAX];
    if (realpath(dir, r1) && realpath(good, r2) && !strcmp(r1, r2))
        return 0;                       /* it is the good design already */
    remove_design_dir(gnew);
    if (mkdir(gnew, 0755) < 0) {
        snprintf(err, n, "%.150s: %s", gnew, strerror(errno));
        return -1;
    }
    const char *files[] = { PL_FW_NAME, PL_DTBO_NAME, PL_MANIFEST };
    for (size_t i = 0; i < 3; i++) {
        snprintf(a, sizeof a, "%s/%s", dir, files[i]);
        snprintf(b, sizeof b, "%s/%s", gnew, files[i]);
        if (copy_file(a, b) < 0) {
            snprintf(err, n, "copying %.200s: %s", a, strerror(errno));
            remove_design_dir(gnew);
            return -1;
        }
    }
    remove_design_dir(gold);
    if ((access(good, F_OK) == 0 && rename(good, gold) < 0) || rename(gnew, good) < 0) {
        snprintf(err, n, "installing %.150s: %s", good, strerror(errno));
        return -1;
    }
    remove_design_dir(gold);
    sync();
    return 0;
}

static void trial_mark(const char *version)
{
    char path[160];
    snprintf(path, sizeof path, "%s/trial", pl_dir);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd >= 0) {
        if (write(fd, version, strlen(version)) < 0)
            logmsg(LOG_WARNING, "writing %s: %s", path, strerror(errno));
        fsync(fd);
        close(fd);
    }
    sync();
}

static void trial_clear(void)
{
    char path[160];
    snprintf(path, sizeof path, "%s/trial", pl_dir);
    unlink(path);
    sync();
}

/* trial-load a new design; keep it if it passes, else reload the good one */
static int pl_activate(const char *dir, char *err, size_t n)
{
    struct design d;
    char good[160];
    if (read_manifest(dir, &d, err, n) < 0)
        return -1;
    if (!regmap_supported(d.regmap)) {
        snprintf(err, n, "design %s has REGMAP %" PRIu32 ", which this fpgad does not support - "
                 "not loaded (update fpgad first)", d.version, d.regmap);
        return -1;
    }
    snprintf(good, sizeof good, "%s/good", pl_dir);

    pthread_rwlock_wrlock(&pl_lock);
    trial_mark(d.version);              /* a reset from here on means: back to good */
    int rc = load_design_locked(dir, err, n);
    if (rc == 0) {
        rc = keep_as_good(dir, err, n);
        trial_clear();
        pl_note[0] = 0;
    } else {
        char why[320];
        snprintf(why, sizeof why, "%s", err);
        trial_clear();
        if (access(good, F_OK) == 0 && load_design_locked(good, err, n) == 0)
            snprintf(err, n, "design %s failed (%.150s); back on the good design %s", d.version, why,
                     pl_cur.version);
        else
            snprintf(err, n, "design %s failed (%.150s), and the good design did not load either",
                     d.version, why);
        snprintf(pl_note, sizeof pl_note, "%.199s", err);
        rc = -1;
    }
    pthread_rwlock_unlock(&pl_lock);
    return rc;
}

/* at start: drop a stale trial, then (re)load or adopt the good design */
static void pl_boot(void)
{
    char good[160], path[160], v[64] = "", err[320];
    /* overlays live in configfs, which Buildroot's fstab doesn't mount */
    if (!sim && access("/sys/kernel/config/device-tree", F_OK) < 0) {
        if (mount("configfs", "/sys/kernel/config", "configfs", 0, NULL) < 0)
            logmsg(LOG_ERR, "mounting configfs on /sys/kernel/config: %s", strerror(errno));
        else
            logmsg(LOG_INFO, "mounted configfs on /sys/kernel/config");
    }
    snprintf(good, sizeof good, "%s/good", pl_dir);
    snprintf(path, sizeof path, "%s/trial", pl_dir);
    if (read_file(path, v, sizeof v, NULL) == 0) {
        v[strcspn(v, "\r\n")] = 0;
        snprintf(pl_note, sizeof pl_note, "the board reset while design %s was on trial - "
                 "staying on the good design", v);
        logmsg(LOG_WARNING, "%s", pl_note);
        trial_clear();
    }
    pthread_rwlock_wrlock(&pl_lock);
    struct design gd;
    if (read_manifest(good, &gd, err, sizeof err) < 0) {
        set_status(0, "no design", "no FPGA design installed (/data/pl/good) - install a PL bundle");
        logmsg(LOG_WARNING, "no good design: %s", err);
    } else if (!sim && access(OVERLAY_DIR, F_OK) == 0 && map_uio() == 0 &&
               check_design(&gd, err, sizeof err) == 0) {
        /* fpgad restarted: our overlay with the good design is still applied */
        pl_cur = gd;
        pl_ok = 1;
        char m[96];
        snprintf(m, sizeof m, "ready: design %s", gd.version);
        set_status(1, "operating", m);
        logmsg(LOG_INFO, "design %s already loaded", gd.version);
    } else {
        load_design_locked(good, err, sizeof err);
    }
    pthread_rwlock_unlock(&pl_lock);
}

static void design_json(char *out, size_t n)
{
    pthread_rwlock_rdlock(&pl_lock);
    if (pl_ok)
        snprintf(out, n, "{\"loaded\":true,\"version\":\"%s\",\"build_id\":%" PRIu32
                 ",\"regmap\":%" PRIu32 ",\"git\":\"%s\",\"date\":\"%s\",\"note\":\"%s\"}",
                 pl_cur.version, pl_cur.build_id, pl_cur.regmap, pl_cur.git, pl_cur.date, pl_note);
    else
        snprintf(out, n, "{\"loaded\":false,\"note\":\"%s\"}", pl_note);
    pthread_rwlock_unlock(&pl_lock);
}

/* ---- hardware watchdog ------------------------------------------------------ */

/* Kick only after a register read came back: a design that hangs the bus
 * stalls this thread, the watchdog resets the board, and pl_boot() lands on
 * the good design. A clean stop disarms it ('V', magic close). */
static void *watchdog_thread(void *arg)
{
    int fd = (int)(intptr_t)arg;
    while (!stopping) {
        pthread_rwlock_rdlock(&pl_lock);
        if (pl_ok)
            (void)raw_read(REG_SIGNATURE);
        pthread_rwlock_unlock(&pl_lock);
        ioctl(fd, WDIOC_KEEPALIVE, 0);
        sleep(1);
    }
    if (write(fd, "V", 1) != 1)
        logmsg(LOG_WARNING, "watchdog: magic close failed - the board will reset");
    close(fd);
    logmsg(LOG_INFO, "watchdog disarmed");
    return NULL;
}

/* ---- oscilloscope capture ------------------------------------------------- */

static pthread_mutex_t scope_lock = PTHREAD_MUTEX_INITIALIZER;   /* one capture at a time */

/* n words from off under one read lock; 0 or -1 with err */
static int reg_read_block(uint32_t off, uint32_t *out, size_t n, char *err, size_t errlen)
{
    if (off % 4 || off + 4 * n > map_size) {
        snprintf(err, errlen, "0x%" PRIx32 "+%zu words outside the 0x%zx-byte window", off, n,
                 map_size);
        return -1;
    }
    pthread_rwlock_rdlock(&pl_lock);
    if (!pl_ok) {
        pthread_rwlock_unlock(&pl_lock);
        snprintf(err, errlen, "PL not ready");
        return -1;
    }
    for (size_t i = 0; i < n; i++)
        out[i] = raw_read(off + 4 * (uint32_t)i);
    pthread_rwlock_unlock(&pl_lock);
    return 0;
}

/* the client hung up (or sent something) while we wait: give up the capture */
static int client_gone(int fd)
{
    struct pollfd p = { .fd = fd, .events = POLLIN };
    char c;
    return poll(&p, 1, 0) > 0 && recv(fd, &c, 1, MSG_PEEK | MSG_DONTWAIT) <= 0;
}

/* one sample of source src at time t (s) - the FPGAD_SIM stand-in for the PL */
static int16_t sim_source(unsigned src, double t)
{
    double fa = sim_scope[6] * SCOPE_FCLK_HZ / 4294967296.0;
    double fb = sim_scope[7] * SCOPE_FCLK_HZ / 4294967296.0;
    double pa = fmod(t * fa, 1.0), noise = (rand() / (double)RAND_MAX - 0.5) * 2.0;
    switch (src) {
    case 1: return (int16_t)lrint(30000 * sin(2 * M_PI * pa));
    case 2: return (int16_t)lrint(pa < 0.5 ? -30000 + 120000 * pa : 90000 - 120000 * pa);
    case 3: return pa < 0.5 ? 30000 : -30000;
    case 4: return (int16_t)lrint(30000 * sin(2 * M_PI * fmod(t * fb, 1.0)));
    case 5: return (int16_t)lrint(32767 * noise);
    case 6: return (int16_t)lrint(15000 * sin(2 * M_PI * pa) + 4096 * noise);
    case 7: {                           /* OLED SPI: a 1.66 ms burst every 33 ms, 5 MHz SCLK */
        double f = fmod(t, 1.0 / 30), b = f * 5e6;
        if (f > 1.66e-3)
            return 4;                   /* RES# high, idle */
        int bit = (int)b % 8, byte = (int)(b / 8);
        return (int16_t)(4 | (byte >= 12 ? 8 : 0) | (fmod(b, 1.0) >= 0.5 ? 2 : 0) |
                         (((0xA5u >> (7 - bit)) ^ (unsigned)byte) & 1));
    }
    default: return 0;
    }
}

static int sim_capture(unsigned trig, int falling, int level, unsigned pre, unsigned div,
                       const unsigned src[SCOPE_CH], int force, int16_t *out, int *triggered)
{
    const double ts = div / SCOPE_FCLK_HZ, t0 = (now_ns() - t0_ns) * 1e-9;
    enum { LOOK = 4 * SCOPE_DEPTH };
    int start = -1;
    int16_t prev = sim_source(src[trig], t0 + (pre - 1.0) * ts);
    for (int i = (int)pre; i < LOOK && start < 0; i++) {
        int16_t cur = sim_source(src[trig], t0 + i * ts);
        if (falling ? (prev > level && cur <= level) : (prev < level && cur >= level))
            start = i - (int)pre;
        prev = cur;
    }
    *triggered = start >= 0;
    if (start < 0) {
        if (!force)
            return -1;
        start = 0;
    }
    for (int c = 0; c < SCOPE_CH; c++)
        for (int i = 0; i < SCOPE_DEPTH; i++)
            out[c * SCOPE_DEPTH + i] = sim_source(src[c], t0 + (start + i) * ts);
    return 0;
}

static void do_capture(int fd, char **argv, int argc)
{
    char err[320];
    uint32_t cfg[4];                    /* TRIG PRE DIV SRC */
    uint32_t timeout = 200, autof = 1;

    pthread_mutex_lock(&scope_lock);
    uint32_t info = 0;
    if (map_size < SCOPE_RAM + 4 * 2 * SCOPE_DEPTH && !sim) {
        sendf(fd, "err capture RAM (0x8000..0xffff) is outside the 0x%zx-byte UIO window: "
                  "update the device tree (axi_regs reg size 0x10000)\n", map_size);
        goto out;
    }
    if (reg_access(0, REG_SCOPE_INFO, &info, err, sizeof err) || reg_read_block(REG_SCOPE_TRIG, cfg, 4, err, sizeof err)) {
        sendf(fd, "err %s\n", err);
        goto out;
    }
    if (info != SCOPE_INFO_VAL) {
        sendf(fd, "err no oscilloscope in this PL design (SCOPE_INFO 0x%08" PRIx32 ")\n", info);
        goto out;
    }

    for (int i = 1; i < argc; i++) {
        char *k = argv[i], *v = strchr(k, '=');
        long x;
        char *end;
        if (!v) {
            sendf(fd, "err bad argument '%s' (key=value)\n", k);
            goto out;
        }
        *v++ = 0;
        x = strtol(v, &end, 0);
        int num_ok = *v && !*end;
        if (!strcmp(k, "src")) {
            uint32_t s4 = 0;
            int n = 0;
            for (char *t = strtok(v, ","); t; t = strtok(NULL, ","), n++) {
                long e = strtol(t, &end, 0);
                if (*end || e < 0 || e > 15 || n >= SCOPE_CH)
                    break;
                s4 |= (uint32_t)e << (4 * n);
            }
            if (n != SCOPE_CH) {
                sendf(fd, "err src needs %d sources 0..15, e.g. src=1,2,4,7\n", SCOPE_CH);
                goto out;
            }
            cfg[3] = s4;
        } else if (!strcmp(k, "div") && num_ok && x >= 1 && x <= SCOPE_DIV_MAX) {
            cfg[2] = (uint32_t)x;
        } else if (!strcmp(k, "trig") && num_ok && x >= 0 && x < SCOPE_CH) {
            cfg[0] = (cfg[0] & ~3u) | (uint32_t)x;
        } else if (!strcmp(k, "edge") && (!strcmp(v, "rise") || !strcmp(v, "fall"))) {
            cfg[0] = (cfg[0] & ~0x10u) | (v[0] == 'f' ? 0x10u : 0);
        } else if (!strcmp(k, "level") && num_ok && x >= -32768 && x <= 32767) {
            cfg[0] = (cfg[0] & 0xFFFFu) | ((uint32_t)(x & 0xFFFF) << 16);
        } else if (!strcmp(k, "pre") && num_ok && x >= 0 && x < SCOPE_DEPTH) {
            cfg[1] = (uint32_t)x;
        } else if (!strcmp(k, "timeout") && num_ok && x >= 0 && x <= 5000) {
            timeout = (uint32_t)x;
        } else if (!strcmp(k, "auto") && num_ok && (x == 0 || x == 1)) {
            autof = (uint32_t)x;
        } else {
            sendf(fd, "err bad %s=%s (src div trig edge level pre timeout auto)\n", k, v);
            goto out;
        }
    }

    const unsigned trig = cfg[0] & 3, pre = cfg[1] & (SCOPE_DEPTH - 1), div = cfg[2] ? cfg[2] : 1;
    const int falling = (cfg[0] >> 4) & 1, level = (int16_t)(cfg[0] >> 16);
    unsigned src[SCOPE_CH];
    for (int c = 0; c < SCOPE_CH; c++)
        src[c] = (cfg[3] >> (4 * c)) & 15;
    for (int i = 0; i < 4; i++)
        if (reg_access(1, REG_SCOPE_TRIG + 4 * (uint32_t)i, &cfg[i], err, sizeof err)) {
            sendf(fd, "err %s\n", err);
            goto out;
        }

    static int16_t data[SCOPE_CH * SCOPE_DEPTH];
    static uint32_t words[2 * SCOPE_DEPTH];
    int triggered = 0;
    if (sim) {
        if (sim_capture(trig, falling, level, pre, div, src, autof, data, &triggered) < 0) {
            sendf(fd, "ok timeout\n");
            goto out;
        }
    } else {
        /* arm; the capture itself takes DEPTH * div / fclk */
        const uint64_t fill_ns = (uint64_t)((double)SCOPE_DEPTH * div / SCOPE_FCLK_HZ * 1e9);
        const uint64_t t_arm = now_ns();
        uint64_t deadline = t_arm + fill_ns + (uint64_t)timeout * 1000000ull;
        uint32_t cmd = 1, st = 0;
        int forced = 0;
        if (reg_access(1, REG_SCOPE_CMD, &cmd, err, sizeof err))
            goto fail;
        for (;;) {
            if (reg_access(0, REG_SCOPE_STAT, &st, err, sizeof err))
                goto fail;
            if (st & 4)
                break;                  /* done */
            uint64_t now = now_ns();
            if (client_gone(fd) || stopping) {
                cmd = 4;
                reg_access(1, REG_SCOPE_CMD, &cmd, err, sizeof err);
                goto out;
            }
            if (now > deadline) {
                if (!autof || forced) {
                    cmd = 4;            /* abort */
                    if (reg_access(1, REG_SCOPE_CMD, &cmd, err, sizeof err))
                        goto fail;
                    if (forced) {
                        snprintf(err, sizeof err, "capture did not finish after a forced trigger");
                        goto fail;
                    }
                    sendf(fd, "ok timeout\n");
                    goto out;
                }
                cmd = 2;                /* auto: force a trigger, then wait for the post fill */
                if (reg_access(1, REG_SCOPE_CMD, &cmd, err, sizeof err))
                    goto fail;
                forced = 1;
                deadline = now + fill_ns + 100000000ull;
            }
            usleep(fill_ns > 20000000 ? 5000 : 300);
        }
        triggered = (st >> 3) & 1;
        const unsigned ptr = (st >> 16) & (SCOPE_DEPTH - 1);
        if (reg_read_block(SCOPE_RAM, words, 2 * SCOPE_DEPTH, err, sizeof err))
            goto fail;
        /* unroll the ring: sample i of the capture is RAM index ptr - pre + i */
        for (int i = 0; i < SCOPE_DEPTH; i++) {
            unsigned r = (ptr - pre + (unsigned)i) & (SCOPE_DEPTH - 1);
            uint32_t lo = words[2 * r], hi = words[2 * r + 1];
            data[0 * SCOPE_DEPTH + i] = (int16_t)(lo & 0xFFFF);
            data[1 * SCOPE_DEPTH + i] = (int16_t)(lo >> 16);
            data[2 * SCOPE_DEPTH + i] = (int16_t)(hi & 0xFFFF);
            data[3 * SCOPE_DEPTH + i] = (int16_t)(hi >> 16);
        }
    }

    if (sendf(fd, "ok capture {\"n\":%d,\"ch\":%d,\"pre\":%u,\"div\":%u,\"fs\":%.6g,"
                  "\"trig\":%u,\"edge\":\"%s\",\"level\":%d,\"triggered\":%s,"
                  "\"src\":[%u,%u,%u,%u],\"bytes\":%zu}\n",
              SCOPE_DEPTH, SCOPE_CH, pre, div, SCOPE_FCLK_HZ / div, trig, falling ? "fall" : "rise",
              level, triggered ? "true" : "false", src[0], src[1], src[2], src[3], sizeof data) == 0)
        send_all(fd, (const char *)data, sizeof data);
    goto out;
fail:
    sendf(fd, "err %s\n", err);
out:
    pthread_mutex_unlock(&scope_lock);
}

/* ---- XADC sensors (kernel IIO driver) ------------------------------------- */

/* IIO channels of xilinx-xadc-core.c worth showing; the VP/VN and VAUX inputs
 * are unconnected on this board. value = (raw + offset) * scale / 1000 */
static const struct { const char *key, *file; } SENSORS[] = {
    { "temp",    "in_temp0" },              /* degC */
    { "vccint",  "in_voltage0_vccint" },    /* V, PL core 1.0 */
    { "vccaux",  "in_voltage1_vccaux" },    /* PL aux 1.8 */
    { "vccbram", "in_voltage2_vccbram" },   /* BRAM 1.0 */
    { "vccpint", "in_voltage3_vccpint" },   /* PS core 1.0 */
    { "vccpaux", "in_voltage4_vccpaux" },   /* PS aux 1.8 */
    { "vccoddr", "in_voltage5_vccoddr" },   /* DDR I/O 1.5 */
};
#define NSENSORS (sizeof SENSORS / sizeof SENSORS[0])

static pthread_mutex_t xadc_lock = PTHREAD_MUTEX_INITIALIZER;
static char xadc_dir[64];                   /* /sys/bus/iio/devices/iio:deviceN, "" = not found */
static double xadc_scale[NSENSORS], xadc_offset[NSENSORS];

static int read_double(const char *path, double *v)
{
    char buf[64];
    if (read_sysfs(path, buf, sizeof buf) < 0 || !buf[0])
        return -1;
    *v = strtod(buf, NULL);
    return 0;
}

/* find the xadc IIO device once and cache the (constant) scales and offsets */
static int xadc_find(void)
{
    if (xadc_dir[0])
        return 0;
    glob_t gl;
    char name[64], path[160];
    if (glob("/sys/bus/iio/devices/iio:device*/name", 0, NULL, &gl) != 0)
        return -1;
    for (size_t i = 0; i < gl.gl_pathc && !xadc_dir[0]; i++)
        if (read_sysfs(gl.gl_pathv[i], name, sizeof name) == 0 && strstr(name, "xadc")) {
            size_t n = strlen(gl.gl_pathv[i]) - strlen("/name");
            snprintf(xadc_dir, sizeof xadc_dir, "%.*s", (int)n, gl.gl_pathv[i]);
        }
    globfree(&gl);
    if (!xadc_dir[0])
        return -1;
    for (size_t k = 0; k < NSENSORS; k++) {
        snprintf(path, sizeof path, "%s/%s_scale", xadc_dir, SENSORS[k].file);
        if (read_double(path, &xadc_scale[k]) < 0)
            xadc_scale[k] = 0;                  /* channel missing: reported as null */
        snprintf(path, sizeof path, "%s/%s_offset", xadc_dir, SENSORS[k].file);
        if (read_double(path, &xadc_offset[k]) < 0)
            xadc_offset[k] = 0;
    }
    logmsg(LOG_INFO, "XADC sensors at %s", xadc_dir);
    return 0;
}

static void do_sensors(int fd)
{
    char out[512];
    size_t o = (size_t)snprintf(out, sizeof out, "ok {");
    pthread_mutex_lock(&xadc_lock);
    if (sim) {
        double t = (now_ns() - t0_ns) * 1e-9, nz = (rand() / (double)RAND_MAX - 0.5);
        const double nominal[NSENSORS] = { 0, 1.0, 1.8, 1.0, 1.0, 1.8, 1.5 };
        for (size_t k = 0; k < NSENSORS; k++) {
            double v = k == 0 ? 44.0 + 2.5 * sin(t / 30.0) + 0.25 * nz
                              : nominal[k] * (1.0 + 0.002 * nz);
            o += (size_t)snprintf(out + o, sizeof out - o, "%s\"%s\":%.3f", k ? "," : "",
                                  SENSORS[k].key, v);
        }
    } else if (xadc_find() < 0) {
        pthread_mutex_unlock(&xadc_lock);
        sendf(fd, "err no XADC IIO device (kernel CONFIG_XILINX_XADC, DT adc@f8007100)\n");
        return;
    } else {
        for (size_t k = 0; k < NSENSORS; k++) {
            char path[160];
            double raw;
            snprintf(path, sizeof path, "%s/%s_raw", xadc_dir, SENSORS[k].file);
            if (!xadc_scale[k] || read_double(path, &raw) < 0)
                o += (size_t)snprintf(out + o, sizeof out - o, "%s\"%s\":null", k ? "," : "",
                                      SENSORS[k].key);
            else
                o += (size_t)snprintf(out + o, sizeof out - o, "%s\"%s\":%.3f", k ? "," : "",
                                      SENSORS[k].key, (raw + xadc_offset[k]) * xadc_scale[k] / 1000.0);
        }
    }
    pthread_mutex_unlock(&xadc_lock);
    snprintf(out + o, sizeof out - o, "}\n");
    sendf(fd, "%s", out);
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
    } else if (!strcmp(argv[0], "activate") || !strcmp(argv[0], "load")) {
        char info[512];
        if (argc > 2 || (argc == 1 && !strcmp(argv[0], "load")))
            sendf(fd, "err usage: activate [<design dir>, default " PL_CANDIDATE "] | load <dir>\n");
        else if (pl_activate(argc == 2 ? argv[1] : PL_CANDIDATE, err, sizeof err))
            sendf(fd, "err %s\n", err);
        else {
            design_json(info, sizeof info);
            sendf(fd, "ok %s\n", info);
        }
    } else if (!strcmp(argv[0], "pl")) {
        char info[512];
        design_json(info, sizeof info);
        sendf(fd, "ok %s\n", info);
    } else if (!strcmp(argv[0], "stream")) {
        do_stream(fd, argv, argc);
    } else if (!strcmp(argv[0], "capture")) {
        do_capture(fd, argv, argc);
    } else if (!strcmp(argv[0], "sensors")) {
        do_sensors(fd);
    } else {
        sendf(fd, "err unknown command '%s' (ping status read write activate pl stream oled capture sensors)\n",
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
    while ((opt = getopt(argc, argv, "s:fnh")) != -1) {
        switch (opt) {
        case 's': sock_path = optarg; break;
        case 'f': foreground = 1; break;
        case 'n': no_watchdog = 1; break;
        default:
            fprintf(stderr, "usage: %s [-s socket] [-f] [-n]\n"
                            "  -s  UNIX socket path (default " DEFAULT_SOCK ")\n"
                            "  -f  foreground: also log to stderr\n"
                            "  -n  don't arm the hardware watchdog\n"
                            "  env FPGAD_SIM=1 simulates axi_regs; FPGAD_PL_DIR overrides /data/pl\n",
                    argv[0]);
            return opt == 'h' ? 0 : 2;
        }
    }
    sim = getenv("FPGAD_SIM") != NULL;
    if (sim)
        map_size = 0x10000;             /* like the real UIO window: regs + capture RAM */
    if (getenv("FPGAD_PL_DIR"))
        snprintf(pl_dir, sizeof pl_dir, "%s", getenv("FPGAD_PL_DIR"));
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

    /* watchdog first: if loading the good design hangs the bus, it resets us */
    pthread_t wdt;
    int wdt_started = 0;
    if (!sim && !no_watchdog) {
        int wfd = open("/dev/watchdog", O_WRONLY | O_CLOEXEC);
        if (wfd < 0)
            logmsg(LOG_WARNING, "no hardware watchdog (/dev/watchdog: %s)", strerror(errno));
        else {
            int timeout = 0;
            ioctl(wfd, WDIOC_GETTIMEOUT, &timeout);
            logmsg(LOG_INFO, "hardware watchdog armed, %d s timeout", timeout);
            wdt_started = pthread_create(&wdt, NULL, watchdog_thread, (void *)(intptr_t)wfd) == 0;
        }
    }

    pl_boot();

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
    if (wdt_started)
        pthread_join(wdt, NULL);        /* disarms it */
    close(ls);
    unlink(sock_path);
    return 0;
}
