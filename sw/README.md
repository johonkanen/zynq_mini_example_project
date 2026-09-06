# sw/ — bare-metal board bring-up test (no SD card)

With the board connected by JTAG only, verifies:

1. **PS UART1** — MIO 48/49 → CH340 USB-serial, 115200 8N1
2. **PS ↔ PL link** — the `M_AXI_GP0` bus to the VHDL `axi_regs` slave at
   `0x4000_0000` (SIGNATURE, PS→PL→PS loopback, PL-computed SUM, HEARTBEAT,
   STATUS)

Needs **Vitis 2024.2** (`xsct` on `PATH` or
`set XSCT=C:\Xilinx\Vitis\2024.2\bin\xsct.bat`), `output/*.xsa` and `output/*.bit`
(run `build.bat` first).

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

Verified on hardware — `run_uart_test.tcl` reads both results back over JTAG:

```
[run] ============================================================
[run]   UART1 controller  : PASS   (256/256 bytes looped back)
[run]   PS <-> PL (AXI)   : PASS   (SIGNATURE / loopback / SUM / HEARTBEAT / STATUS)
[run] ============================================================
```

`sw/uart_test/src/main.c` runs three phases:

1. **UART1 controller self-test** — internal local-loopback, all 256 byte
   values. Result in a global, read back over JTAG (works with no terminal).
2. **PS ↔ PL link** — loads nothing itself; the run script loads the `.bit`
   first. Reads SIGNATURE (`0x5A5A1234`), does a SCRATCH0/1 write→read
   loopback, checks `SUM == SCRATCH0 + SCRATCH1` (computed in the PL), that
   `HEARTBEAT` advances (PL clock alive), and that `STATUS` bit 3 mirrors
   `CONTROL(0)`. Reports `SKIP` (not `FAIL`) if the PL is unconfigured.
   Result + a per-subtest fail-mask in globals, read back over JTAG.
3. **Interactive** — prints the full report, then echoes typed characters and
   a `[tick]` line every few seconds.

Expected on the serial terminal:

```
======================================
 Zynq Mini - board bring-up test
======================================
 UART1     : loopback PASS  (256/256)
 SIGNATURE : 0x5a5a1234   OK
 SCRATCH   : wrote a5a50001/00001111  read a5a50001/00001111   OK
 SUM (PL)  : 0xa5a51112  expect 0xa5a51112   OK
 HEARTBEAT : 1234 -> 5678   running
 STATUS    : 0x...   (bit3=CONTROL(0) echo)   OK
 PS<->PL   : PASS

 Type characters - they are echoed back.
```

## Files

| File | Purpose |
|------|---------|
| `uart_poke.tcl`        | instant UART1-only register-poke smoke test |
| `uart_test/src/main.c` | 3-phase test: UART1 loopback + PS↔PL (axi_regs) + echo |
| `build_uart_test.tcl`  | XSCT: standalone BSP from XSA + `arm-none-eabi-gcc` |
| `run_uart_test.tcl`    | XSCT: `fpga` → `ps7_init` → download → run → read results |
| `uart_test.bat`        | Windows wrapper (build + run) |

`build_sw/` (the generated Vitis workspace) is git-ignored.
