/*
 * fpgad_client - talk to fpgad, the process that owns the FPGA.
 *
 * Link with -lfpgad-client. Every process that needs the PL (fpga-web,
 * fpgactl, your own) goes through this instead of mapping the hardware:
 *
 *     struct fpgad_conn *c = fpgad_open(NULL);         // default socket
 *     uint32_t v;
 *     if (fpgad_read(c, 0x1C, &v) == 0) ...            // SIGNATURE
 *     fpgad_write(c, 0x00, 0x12340000);                // SCRATCH0
 *     fpgad_close(c);
 *
 * Streams: fpgad_request(c, "stream 200 20 0x10", ...) then fpgad_readline()
 * for "data {...}" / "status {...}" lines.
 * Captures: fpgad_request(c, "capture ...", meta, ...) -> "capture {...,"bytes":N}",
 * then fpgad_read_bytes(c, buf, N, ...) for the samples. The wire protocol is documented in
 * fpgad.c; it's plain text, so `echo status | socat - UNIX:/var/run/fpgad.sock`
 * works too.
 */
#ifndef FPGAD_CLIENT_H
#define FPGAD_CLIENT_H

#include <stddef.h>
#include <stdint.h>

#define FPGAD_SOCKET "/var/run/fpgad.sock"

struct fpgad_conn;

/* connect; path NULL = $FPGAD_SOCKET or FPGAD_SOCKET. NULL on error (errno set) */
struct fpgad_conn *fpgad_open(const char *path);
void fpgad_close(struct fpgad_conn *c);

/* send one request line, read one response line.
 * returns 0 on "ok ...", 1 on "err ...", -1 on I/O error;
 * msg (if non-NULL) receives the text after "ok "/"err " */
int fpgad_request(struct fpgad_conn *c, const char *line, char *msg, size_t msglen);

/* next line from the connection (no '\n'); timeout_ms < 0 = wait forever.
 * returns length, 0 on timeout, -1 on EOF/error */
int fpgad_readline(struct fpgad_conn *c, char *buf, size_t len, int timeout_ms);

/* exactly n raw bytes (after a reply that announced them); 0 ok, -1 error/timeout */
int fpgad_read_bytes(struct fpgad_conn *c, void *buf, size_t n, int timeout_ms);

/* convenience; 0 ok, 1 fpgad error, -1 I/O error */
int fpgad_read(struct fpgad_conn *c, uint32_t off, uint32_t *val);
int fpgad_write(struct fpgad_conn *c, uint32_t off, uint32_t val);

#endif
