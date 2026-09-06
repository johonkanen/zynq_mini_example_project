# sw/ — bare-metal UART1 test (no SD card)

Verifies the board's UART1 (PS UART on MIO 48/49 → CH340 USB-serial, 115200 8N1)
with the board connected only by JTAG. Needs **Vitis 2024.2** (`xsct` on `PATH`
or `set XSCT=C:\Xilinx\Vitis\2024.2\bin\xsct.bat`) and
`output/arm_fpga_zynq_mini.xsa` (run `build.bat` first).

## Quick smoke test — no build

```
xsct sw/uart_poke.tcl
```

Connects over JTAG, runs `ps7_init`, then pokes test text straight into the
UART1 TX FIFO. If it shows up on your serial terminal (**115200 8N1**), then
UART1 TX + MIO 48/49 + the CH340 + your cable/terminal all work. Takes ~15 s.

## Full test — bare-metal app

```
sw\uart_test.bat            :: build + load + run
sw\uart_test.bat build      :: build only  -> build_sw/uart_test/.../uart_test.elf
sw\uart_test.bat run        :: load + run only
```

Verified on the board: the controller self-test reports
`UART1 CONTROLLER SELF-TEST : PASS (256/256)` back over JTAG.

`sw/uart_test/src/main.c` does two things:

1. **Controller self-test** — puts UART1 in internal local-loopback, sends
   0–255 through it, checks every byte returns. The result is left in two
   globals; `run_uart_test.tcl` reads them back over JTAG and prints
   `PASS`/`FAIL` — so this half is verified even without a terminal.
2. **Interactive test on the real pins** — prints a banner, echoes every
   character you type, and prints a `[tick]` line every few seconds.

Expected on the serial terminal:

```
=====================================
 Zynq Mini - UART1 test (bare metal)
=====================================
 UART1 base   : 0xe0001000  (MIO 48/49, 115200 8N1)
 loopback test: PASS  (256/256 bytes)

 Type characters - they are echoed back.
 A [tick] line prints every few seconds.

[tick] alive - 0 chars echoed
```

## Files

| File | Purpose |
|------|---------|
| `uart_poke.tcl`        | instant register-poke smoke test |
| `uart_test/src/main.c` | bare-metal app: loopback self-test + RX echo |
| `build_uart_test.tcl`  | XSCT: platform from XSA + build the app |
| `run_uart_test.tcl`    | XSCT: JTAG connect → `ps7_init` → download → run → read result |
| `uart_test.bat`        | Windows wrapper (build + run) |

`build_sw/` (the generated Vitis workspace) is git-ignored.
