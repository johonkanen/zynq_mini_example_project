/* fpgad_client - see fpgad_client.h */
#define _GNU_SOURCE
#include "fpgad_client.h"

#include <errno.h>
#include <inttypes.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

struct fpgad_conn {
    int fd;
    size_t len;
    char buf[16384];
};

struct fpgad_conn *fpgad_open(const char *path)
{
    if (!path)
        path = getenv("FPGAD_SOCKET");
    if (!path)
        path = FPGAD_SOCKET;
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof addr.sun_path) {
        errno = ENAMETOOLONG;
        return NULL;
    }
    strcpy(addr.sun_path, path);
    struct fpgad_conn *c = calloc(1, sizeof *c);
    if (!c)
        return NULL;
    c->fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (c->fd < 0 || connect(c->fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        int e = errno;
        if (c->fd >= 0)
            close(c->fd);
        free(c);
        errno = e;
        return NULL;
    }
    return c;
}

void fpgad_close(struct fpgad_conn *c)
{
    if (c) {
        close(c->fd);
        free(c);
    }
}

int fpgad_readline(struct fpgad_conn *c, char *out, size_t outlen, int timeout_ms)
{
    for (;;) {
        char *nl = memchr(c->buf, '\n', c->len);
        if (nl) {
            size_t n = (size_t)(nl - c->buf);
            size_t k = n < outlen - 1 ? n : outlen - 1;
            memcpy(out, c->buf, k);
            out[k] = 0;
            memmove(c->buf, nl + 1, c->len - n - 1);
            c->len -= n + 1;
            return (int)k ? (int)k : 1;     /* an empty line still counts as a line */
        }
        if (c->len == sizeof c->buf)
            return -1;                      /* line longer than our buffer */
        if (timeout_ms >= 0) {
            struct pollfd p = { .fd = c->fd, .events = POLLIN };
            int r = poll(&p, 1, timeout_ms);
            if (r == 0)
                return 0;
            if (r < 0)
                return -1;
        }
        ssize_t r = recv(c->fd, c->buf + c->len, sizeof c->buf - c->len, 0);
        if (r <= 0)
            return -1;
        c->len += (size_t)r;
    }
}

int fpgad_request(struct fpgad_conn *c, const char *line, char *msg, size_t msglen)
{
    size_t n = strlen(line);
    char *req = malloc(n + 2);
    if (!req)
        return -1;
    memcpy(req, line, n);
    req[n++] = '\n';
    req[n] = 0;
    const char *p = req;
    while (n) {
        ssize_t w = send(c->fd, p, n, MSG_NOSIGNAL);
        if (w < 0 && errno == EINTR)
            continue;
        if (w <= 0) {
            free(req);
            return -1;
        }
        p += w;
        n -= (size_t)w;
    }
    free(req);

    char resp[4096];
    if (fpgad_readline(c, resp, sizeof resp, 10000) <= 0)
        return -1;
    int rc;
    const char *text;
    if (!strncmp(resp, "ok", 2) && (resp[2] == ' ' || !resp[2])) {
        rc = 0;
        text = resp[2] ? resp + 3 : "";
    } else if (!strncmp(resp, "err", 3)) {
        rc = 1;
        text = resp[3] ? resp + 4 : "";
    } else {
        return -1;
    }
    if (msg && msglen)
        snprintf(msg, msglen, "%s", text);
    return rc;
}

int fpgad_read(struct fpgad_conn *c, uint32_t off, uint32_t *val)
{
    char req[32], msg[256];
    snprintf(req, sizeof req, "read 0x%" PRIx32, off);
    int rc = fpgad_request(c, req, msg, sizeof msg);
    if (rc == 0)
        *val = (uint32_t)strtoul(msg, NULL, 0);
    return rc;
}

int fpgad_write(struct fpgad_conn *c, uint32_t off, uint32_t val)
{
    char req[48];
    snprintf(req, sizeof req, "write 0x%" PRIx32 " 0x%" PRIx32, off, val);
    return fpgad_request(c, req, NULL, 0);
}
