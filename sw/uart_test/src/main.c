/*
 * main.c - board bring-up test for the "Zynq Mini" (bare metal, Cortex-A9)
 *
 * Loaded over JTAG (no SD card needed). Three phases:
 *
 *   1. Internal loopback self-test of the UART1 controller. Sends 0..255
 *      through the controller's local-loopback path and checks every byte
 *      comes back.
 *
 *   2. PS <-> PL link test over M_AXI_GP0: talks to the VHDL axi_regs slave
 *      at 0x4000_0000 - SIGNATURE, PS->PL->PS loopback, PL-computed SUM,
 *      free-running HEARTBEAT, STATUS. Skipped (not failed) if the PL is not
 *      configured.
 *
 *   3. Interactive test on the real UART pins (MIO 48/49 -> USB-serial):
 *      banner, RX echo, periodic "[tick]" line.
 *
 * Phases 1 and 2 leave their results in globals so run_uart_test.tcl can read
 * PASS/FAIL over JTAG without a serial terminal. Open a terminal on the board's
 * COM port at 115200 8N1 to watch phase 3 (and see the phase 1/2 report).
 */

#include "xparameters.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xuartps_hw.h"

#ifndef STDOUT_BASEADDRESS
#define STDOUT_BASEADDRESS  XPAR_XUARTPS_0_BASEADDR   /* fallback */
#endif

/* ---- JTAG-readable results ------------------------------------------------ */
volatile unsigned int uart_selftest_status __attribute__((used)) = 0;
volatile unsigned int uart_selftest_bytes  __attribute__((used)) = 0;
volatile unsigned int axi_selftest_status  __attribute__((used)) = 0;
volatile unsigned int axi_fail_mask        __attribute__((used)) = 0xFFFFFFFFu;

#define MAGIC_OK      0xC0DE600Du
#define MAGIC_FAIL    0xBADF00D5u
#define MAGIC_SKIP    0x5C1FF00Du   /* PL not configured */

/* ---- axi_regs (src/hdl/axi_regs.vhd) at the M_AXI_GP0 base --------------- */
#define AXI_REGS_BASE   0x40000000u
#define REG_SCRATCH0    0x00u
#define REG_SCRATCH1    0x04u
#define REG_SCRATCH2    0x08u
#define REG_CONTROL     0x0Cu
#define REG_HEARTBEAT   0x10u
#define REG_SUM         0x14u
#define REG_STATUS      0x18u
#define REG_SIGNATURE   0x1Cu
#define AXI_SIGNATURE   0x5A5A1234u

/* devcfg PCFG_DONE - is the PL configured? */
#define DEVCFG_INT_STS  0xF800700Cu
#define PCFG_DONE_MASK  0x00000004u

static inline u32  rd(u32 off)          { return Xil_In32(AXI_REGS_BASE + off); }
static inline void wr(u32 off, u32 val) { Xil_Out32(AXI_REGS_BASE + off, val); }

/* ---- UART1 controller loopback self-test -------------------------------- */
static unsigned int uart_loopback_test(UINTPTR base)
{
    unsigned int ok = 0, i;
    u32 mr;

    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET, XUARTPS_CR_TX_DIS | XUARTPS_CR_RX_DIS);
    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET, XUARTPS_CR_TXRST | XUARTPS_CR_RXRST);

    mr = XUartPs_ReadReg(base, XUARTPS_MR_OFFSET);
    XUartPs_WriteReg(base, XUARTPS_MR_OFFSET,
                     (mr & ~XUARTPS_MR_CHMODE_MASK) | XUARTPS_MR_CHMODE_L_LOOP);
    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET,
                     XUARTPS_CR_TX_EN | XUARTPS_CR_RX_EN | XUARTPS_CR_STOPBRK);

    for (i = 0; i < 256u; i++) {
        unsigned int guard = 200000u;
        while (XUartPs_IsTransmitFull(base)) { if (--guard == 0u) goto done; }
        XUartPs_WriteReg(base, XUARTPS_FIFO_OFFSET, (u32)i);

        guard = 200000u;
        while (!XUartPs_IsReceiveData(base)) { if (--guard == 0u) goto done; }
        if ((XUartPs_ReadReg(base, XUARTPS_FIFO_OFFSET) & 0xFFu) != (i & 0xFFu))
            goto done;
        ok++;
    }

done:
    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET, XUARTPS_CR_TX_DIS | XUARTPS_CR_RX_DIS);
    XUartPs_WriteReg(base, XUARTPS_MR_OFFSET,
                     (mr & ~XUARTPS_MR_CHMODE_MASK) | XUARTPS_MR_CHMODE_NORM);
    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET, XUARTPS_CR_TXRST | XUARTPS_CR_RXRST);
    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET,
                     XUARTPS_CR_TX_EN | XUARTPS_CR_RX_EN | XUARTPS_CR_STOPBRK);
    return ok;
}

static void spin(volatile unsigned int n) { while (n--) { __asm__ volatile(""); } }

/* ---- PS <-> PL link test over M_AXI_GP0 -> axi_regs --------------------- */
/* bit set in the returned mask = that sub-test failed                       */
#define F_PLCFG     (1u << 0)
#define F_SIG       (1u << 1)
#define F_LOOPBACK  (1u << 2)
#define F_SUM       (1u << 3)
#define F_HEARTBEAT (1u << 4)
#define F_STATUS    (1u << 5)

static u32 axi_link_test(int verbose)
{
    u32 mask = 0;
    u32 sig, s0, s1, sum, hb0, hb1, st;

    if ((Xil_In32(DEVCFG_INT_STS) & PCFG_DONE_MASK) == 0u) {
        if (verbose) xil_printf(" PS<->PL   : SKIP  (PL not configured - load the .bit)\r\n");
        return F_PLCFG;
    }

    sig = rd(REG_SIGNATURE);
    if (sig != AXI_SIGNATURE) mask |= F_SIG;
    if (verbose) xil_printf(" SIGNATURE : 0x%08lx   %s\r\n",
                            (unsigned long)sig, (sig == AXI_SIGNATURE) ? "OK" : "MISMATCH");

    s0 = 0xA5A50001u; s1 = 0x00001111u;
    wr(REG_SCRATCH0, s0);
    wr(REG_SCRATCH1, s1);
    if (rd(REG_SCRATCH0) != s0 || rd(REG_SCRATCH1) != s1) mask |= F_LOOPBACK;
    if (verbose) xil_printf(" SCRATCH   : wrote %08lx/%08lx  read %08lx/%08lx   %s\r\n",
                            (unsigned long)s0, (unsigned long)s1,
                            (unsigned long)rd(REG_SCRATCH0), (unsigned long)rd(REG_SCRATCH1),
                            (mask & F_LOOPBACK) ? "FAIL" : "OK");

    sum = rd(REG_SUM);
    if (sum != (s0 + s1)) mask |= F_SUM;
    if (verbose) xil_printf(" SUM (PL)  : 0x%08lx  expect 0x%08lx   %s\r\n",
                            (unsigned long)sum, (unsigned long)(s0 + s1),
                            (mask & F_SUM) ? "FAIL" : "OK");

    hb0 = rd(REG_HEARTBEAT);
    spin(2000);
    hb1 = rd(REG_HEARTBEAT);
    if (hb1 == hb0) mask |= F_HEARTBEAT;
    if (verbose) xil_printf(" HEARTBEAT : %lu -> %lu   %s\r\n",
                            (unsigned long)hb0, (unsigned long)hb1,
                            (mask & F_HEARTBEAT) ? "STUCK" : "running");

    wr(REG_CONTROL, 0x1u);          /* CONTROL(0) is mirrored in STATUS(3) */
    st = rd(REG_STATUS);
    if (((st >> 3) & 1u) != 1u) mask |= F_STATUS;
    wr(REG_CONTROL, 0x0u);
    if (verbose) xil_printf(" STATUS    : 0x%08lx  (bit3=CONTROL(0) echo)   %s\r\n",
                            (unsigned long)st, (mask & F_STATUS) ? "FAIL" : "OK");

    return mask;
}

int main(void)
{
    const UINTPTR uart = (UINTPTR)STDOUT_BASEADDRESS;
    unsigned int bytes;
    u32 axi_mask;
    u32 ticks = 0, echoed = 0;

    /* -------- phase 1: UART1 controller self-test ----------------------- */
    bytes = uart_loopback_test(uart);
    uart_selftest_bytes  = bytes;
    uart_selftest_status = (bytes == 256u) ? MAGIC_OK : MAGIC_FAIL;

    /* -------- phase 2: PS <-> PL link (silent pass for JTAG readback) --- */
    axi_mask = axi_link_test(0);
    axi_fail_mask = axi_mask;
    axi_selftest_status = (axi_mask == 0u)      ? MAGIC_OK
                        : (axi_mask == F_PLCFG) ? MAGIC_SKIP
                                                : MAGIC_FAIL;

    /* -------- phase 3: banner + report + interactive echo -------------- */
    xil_printf("\r\n\r\n");
    xil_printf("======================================\r\n");
    xil_printf(" Zynq Mini - board bring-up test\r\n");
    xil_printf("======================================\r\n");
    xil_printf(" UART1     : loopback %s  (%u/256)\r\n",
               (bytes == 256u) ? "PASS" : "FAIL", bytes);
    axi_link_test(1);                 /* re-run, printing each line */
    xil_printf(" PS<->PL   : %s\r\n",
               (axi_selftest_status == MAGIC_OK)   ? "PASS"
             : (axi_selftest_status == MAGIC_SKIP) ? "SKIP (no bitstream)"
                                                   : "FAIL");
    xil_printf("\r\n Type characters - they are echoed back.\r\n");
    xil_printf(" A [tick] line prints every few seconds.\r\n\r\n");

    for (;;) {
        if (XUartPs_IsReceiveData(uart)) {
            u8 c = (u8)XUartPs_ReadReg(uart, XUARTPS_FIFO_OFFSET);
            XUartPs_SendByte(uart, c);
            if (c == '\r') XUartPs_SendByte(uart, '\n');
            echoed++;
        }
        if (++ticks >= 40000000u) {
            ticks = 0;
            xil_printf("[tick] alive - %lu chars echoed\r\n", (unsigned long)echoed);
        }
    }
    return 0;
}
