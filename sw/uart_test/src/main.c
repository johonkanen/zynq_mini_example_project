/*
 * main.c - UART1 test for the "Zynq Mini" board (bare metal, Cortex-A9)
 *
 * Loaded over JTAG (no SD card needed). Two phases:
 *
 *   1. Internal loopback self-test of the UART1 controller. Sends 0..255
 *      through the controller's local-loopback path and checks every byte
 *      comes back. The result is left in two globals so the JTAG side
 *      (run_uart_test.tcl) can read PASS/FAIL without a serial terminal.
 *
 *   2. Interactive test on the real pins (MIO 48/49 -> USB-serial): prints a
 *      banner, echoes every character it receives, and prints a "[tick]" line
 *      periodically so you can see it is alive.
 *
 * Open a terminal on the board's COM port at 115200 8N1 to watch phase 2.
 */

#include "xparameters.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xuartps_hw.h"

#ifndef STDOUT_BASEADDRESS
#define STDOUT_BASEADDRESS  XPAR_XUARTPS_0_BASEADDR   /* fallback */
#endif

/* JTAG-readable results (run_uart_test.tcl reads these symbols) */
volatile unsigned int uart_selftest_status __attribute__((used)) = 0;
volatile unsigned int uart_selftest_bytes  __attribute__((used)) = 0;

#define SELFTEST_MAGIC_OK    0xC0DE600Du
#define SELFTEST_MAGIC_FAIL  0xBADF00D5u

/* ---- minimal UART1 controller loopback self-test ------------------------ */
static unsigned int uart_loopback_test(UINTPTR base)
{
    unsigned int ok = 0;
    unsigned int i;
    u32 mr;

    /* stop, flush FIFOs */
    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET,
                     XUARTPS_CR_TX_DIS | XUARTPS_CR_RX_DIS);
    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET,
                     XUARTPS_CR_TXRST | XUARTPS_CR_RXRST);

    /* keep the current framing, switch to local loopback */
    mr = XUartPs_ReadReg(base, XUARTPS_MR_OFFSET);
    XUartPs_WriteReg(base, XUARTPS_MR_OFFSET,
                     (mr & ~XUARTPS_MR_CHMODE_MASK) | XUARTPS_MR_CHMODE_L_LOOP);

    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET,
                     XUARTPS_CR_TX_EN | XUARTPS_CR_RX_EN | XUARTPS_CR_STOPBRK);

    for (i = 0; i < 256u; i++) {
        unsigned int guard = 200000u;

        while (XUartPs_IsTransmitFull(base)) {
            if (--guard == 0u) goto done;
        }
        XUartPs_WriteReg(base, XUARTPS_FIFO_OFFSET, (u32)i);

        guard = 200000u;
        while (!XUartPs_IsReceiveData(base)) {
            if (--guard == 0u) goto done;
        }
        if ((XUartPs_ReadReg(base, XUARTPS_FIFO_OFFSET) & 0xFFu) != (i & 0xFFu))
            goto done;

        ok++;
    }

done:
    /* back to normal mode + clean FIFOs so phase 2 starts fresh */
    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET,
                     XUARTPS_CR_TX_DIS | XUARTPS_CR_RX_DIS);
    XUartPs_WriteReg(base, XUARTPS_MR_OFFSET,
                     (mr & ~XUARTPS_MR_CHMODE_MASK) | XUARTPS_MR_CHMODE_NORM);
    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET,
                     XUARTPS_CR_TXRST | XUARTPS_CR_RXRST);
    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET,
                     XUARTPS_CR_TX_EN | XUARTPS_CR_RX_EN | XUARTPS_CR_STOPBRK);
    return ok;
}

int main(void)
{
    const UINTPTR uart = (UINTPTR)STDOUT_BASEADDRESS;
    unsigned int bytes;
    u32 ticks = 0, echoed = 0;

    /* -------- phase 1: controller self-test (JTAG reads the result) ------- */
    bytes = uart_loopback_test(uart);
    uart_selftest_bytes  = bytes;
    uart_selftest_status = (bytes == 256u) ? SELFTEST_MAGIC_OK
                                           : SELFTEST_MAGIC_FAIL;

    /* -------- phase 2: real pins, interactive ---------------------------- */
    xil_printf("\r\n\r\n");
    xil_printf("=====================================\r\n");
    xil_printf(" Zynq Mini - UART1 test (bare metal)\r\n");
    xil_printf("=====================================\r\n");
    xil_printf(" UART1 base   : 0x%08lx  (MIO 48/49, 115200 8N1)\r\n",
               (unsigned long)uart);
    xil_printf(" loopback test: %s  (%u/256 bytes)\r\n",
               (bytes == 256u) ? "PASS" : "FAIL", bytes);
    xil_printf("\r\n Type characters - they are echoed back.\r\n");
    xil_printf(" A [tick] line prints every few seconds.\r\n\r\n");

    for (;;) {
        if (XUartPs_IsReceiveData(uart)) {
            u8 c = (u8)XUartPs_ReadReg(uart, XUARTPS_FIFO_OFFSET);
            XUartPs_SendByte(uart, c);
            if (c == '\r')
                XUartPs_SendByte(uart, '\n');
            echoed++;
        }

        if (++ticks >= 40000000u) {
            ticks = 0;
            xil_printf("[tick] alive - %lu chars echoed\r\n",
                       (unsigned long)echoed);
        }
    }

    return 0;
}
