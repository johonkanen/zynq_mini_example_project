/*
 * fpgactl - command-line client for fpgad.
 *
 *   fpgactl status
 *   fpgactl regs                       read all axi_regs registers, named
 *   fpgactl read 0x1c
 *   fpgactl write 0x00 0x12340000
 *   fpgactl load arm_fpga_zynq_mini.bit.bin
 *   fpgactl stream 200 20 0x10         prints data/status lines until Ctrl-C
 *   fpgactl oled 0 "Hello, world"      text on OLED row 0..7 (16 chars) / oled clear
 *   fpgactl sensors                    XADC die temperature + supply rails
 *   fpgactl raw "<request line>"
 *
 * -s <socket> or $FPGAD_SOCKET selects the socket (default /var/run/fpgad.sock).
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "fpgad_client.h"

static const struct { uint32_t off; const char *name, *acc; } REGS[] = {
    { 0x00, "SCRATCH0", "rw" }, { 0x04, "SCRATCH1", "rw" },
    { 0x08, "SCRATCH2", "rw" }, { 0x0C, "CONTROL", "rw" },
    { 0x10, "HEARTBEAT", "ro" }, { 0x14, "SUM", "ro" },
    { 0x18, "STATUS", "ro" },   { 0x1C, "SIGNATURE", "ro" },
    { 0x20, "OLED_CTRL", "rw" }, { 0x24, "OLED_STAT", "ro" },
};

static int usage(void)
{
    fprintf(stderr,
            "usage: fpgactl [-s socket] <command>\n"
            "  status | regs | read <off> | write <off> <val> | load <fw>\n"
            "  stream <hz> <batch_hz> <off>... | oled <row> <text> | oled clear | sensors\n"
            "  raw \"<line>\"\n");
    return 2;
}

int main(int argc, char **argv)
{
    const char *sock = NULL;
    int opt;
    while ((opt = getopt(argc, argv, "+s:h")) != -1) {
        if (opt == 's')
            sock = optarg;
        else
            return usage();
    }
    argc -= optind;
    argv += optind;
    if (argc < 1)
        return usage();

    struct fpgad_conn *c = fpgad_open(sock);
    if (!c) {
        perror("fpgactl: cannot connect to fpgad");
        return 1;
    }

    char line[1024] = "", msg[4096];
    int rc;
    if (!strcmp(argv[0], "regs")) {
        rc = 0;
        for (size_t i = 0; i < sizeof REGS / sizeof REGS[0]; i++) {
            uint32_t v;
            int r = fpgad_read(c, REGS[i].off, &v);
            if (r) {
                fprintf(stderr, "fpgactl: read 0x%02" PRIx32 " failed\n", REGS[i].off);
                rc = 1;
                break;
            }
            printf("0x%02" PRIx32 "  %-9s  %s  0x%08" PRIx32 "\n", REGS[i].off, REGS[i].name,
                   REGS[i].acc, v);
        }
        fpgad_close(c);
        return rc;
    }
    if (!strcmp(argv[0], "raw")) {
        if (argc != 2)
            return usage();
        snprintf(line, sizeof line, "%s", argv[1]);
    } else {
        for (int i = 0; i < argc; i++) {
            strncat(line, argv[i], sizeof line - strlen(line) - 2);
            if (i + 1 < argc)
                strcat(line, " ");
        }
    }

    rc = fpgad_request(c, line, msg, sizeof msg);
    if (rc < 0) {
        fprintf(stderr, "fpgactl: lost connection to fpgad\n");
        fpgad_close(c);
        return 1;
    }
    if (rc == 1) {
        fprintf(stderr, "fpgactl: %s\n", msg);
        fpgad_close(c);
        return 1;
    }
    if (*msg)
        printf("%s\n", msg);
    if (!strcmp(argv[0], "stream") || (!strcmp(argv[0], "raw") && !strncmp(line, "stream", 6))) {
        char buf[65536];
        while (fpgad_readline(c, buf, sizeof buf, -1) > 0) {
            puts(buf);
            fflush(stdout);
        }
    }
    fpgad_close(c);
    return 0;
}
