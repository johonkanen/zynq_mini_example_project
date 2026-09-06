# arm_fpga_zynq_mini

Minimal, script-built Zynq-7020 project for the **Zynq mini board**
(`xc7z020clg400-2`, Vivado 2024.2).

The block design is **just the PS7** (DDR3 + the board peripherals). Its
`M_AXI_GP0` AXI master is routed **straight to the fabric** — no AXI
interconnect, protocol converter or packaged IP anywhere. A hand-written VHDL
top instantiates the block design and wires the raw AXI3 bus to `axi_regs`, an
AXI slave written in VHDL.

```
   zynq_mini_top.vhd  (VHDL-2008, synthesis top)
   |  entity ports = DDR_* + FIXED_IO_* only (auto-constrained by PS7)
   |  internal PS<->PL bus = two record signals
   |
   +-- u_ps : zynq_ps_wrapper
   |     |   +-- zynq_mini  <- generated block-design entity (PS7 only)
   |     |         DDR3 (MT41J256M16, 512 MB)
   |     |         Ethernet GEM0 (RGMII + MDIO) / QSPI x4 / SD1 eMMC /
   |     |         SD0 microSD / UART1 console
   |     |
   |     +-- clk / resetn          (FCLK_CLK0 100 MHz / FCLK_RESET0_N)
   |     +-- m_axi_o : axi_mosi_t  \  raw M_AXI_GP0 (AXI3) packed into
   |     +-- m_axi_i : axi_miso_t  /  the axi_pkg direction records
   |            v
   +-- u_axi_regs : axi_regs   <- AXI slave, 100% VHDL (src/hdl/axi_regs.vhd)
   |            |
   |     reg_ps2pl[127:0] / pl_active
   |            v
   +-- placeholder PL user logic  (counter on FCLK_CLK0 + the register bus)
```

## The board

The cheap AliExpress **"Zynq Mini" XC7Z020-CLG400** board, reviewed on Habr:
[habr.com/ru/articles/721146](https://habr.com/ru/articles/721146/) (English-friendly
mirror: [pvsm.ru/fpga/383315](https://www.pvsm.ru/fpga/383315)).

| | |
|---|---|
| SoC | XC7Z020-CLG400, speed grade -2 |
| DDR3 | 512 MB, MT41J256M16 (16-bit, 533 MHz) |
| QSPI flash | 16 MB, socketed SOIC-8 |
| Ethernet | **two** gigabit RTL8211E PHYs: one on **PS GEM0 / MIO 16–27** (MDIO 52–53, PHY addr 0), one wired to the **PL fabric** (RGMII) |
| USB | host on USB-C, ULPI PHY |
| storage | microSD (SDIO0) + on-board eMMC (SDIO1) |
| video / display | HDMI direct from PL GPIO (no companion chip); 128×64 OLED bit-banged from PL |
| clocks | PS 33.333 MHz + external 50 MHz oscillator to PL |
| misc | I²C EEPROM, 5 LEDs, 3 buttons, 34 PL GPIO, on-board JTAG programmer, 3-way boot switch (JTAG / QSPI / SD) |

Andrey Zaostrovnykh (@andreyzaostrovnykh) has a Habr series covering this board
and its QMTech sibling, **including building Linux** — see [`doc/notes.md`](doc/notes.md):

| Article | Topic |
|---|---|
| [721146](https://habr.com/ru/articles/721146/) | Zynq Mini board review (this board) |
| [559946](https://habr.com/ru/articles/559946/) | getting started with Zynq-7000 (QMTech "Bajie") |
| [565368](https://habr.com/ru/articles/565368/) | build Linux from scratch (U-Boot + DTG + `linux-xlnx` + rootfs + `BOOT.BIN`) — its Ethernet setup is identical to this project's PS7 config |
| [567408](https://habr.com/ru/articles/567408/) | kernel + rootfs via Buildroot |
| [835912](https://habr.com/ru/companies/timeweb/articles/835912/) | boot Linux over JTAG with XSCT (`zynqmini.dtb`), no SD flashing |
| [849032](https://habr.com/ru/companies/timeweb/articles/849032/) | HDMI from bare-metal (repo: [github.com/megalloid/zynq_mini_lessons](https://github.com/megalloid/zynq_mini_lessons)) |

## Layout

| Path | Purpose |
|------|---------|
| `scripts/config.tcl`          | part, names, paths, clock frequency, parallelism |
| `scripts/ps7_base_config.tcl` | full PS7 preset (DDR3 + GEM0 + UART1 + clocks), captured from the board |
| `scripts/create_bd.tcl`       | builds the PS7-only `zynq_mini` block design, routes M_AXI_GP0 to the boundary, generates it as a plain entity (no wrapper) |
| `scripts/build.tcl`           | top build flow: project → BD → add VHDL → synth → impl → bitstream → XSA |
| `src/hdl/axi_pkg.vhd`         | AXI bus **direction records** — `axi_mosi_t` (master→slave), `axi_miso_t` (slave→master), nested per channel |
| `src/hdl/axi_regs.vhd`        | **VHDL AXI slave** for the raw M_AXI_GP0 (AXI3); port is `s_axi_i : axi_mosi_t` / `s_axi_o : axi_miso_t` |
| `src/hdl/zynq_ps_wrapper.vhd` | wraps the block design; packs the flat `M_AXI_GP0_*` pins into `m_axi_o`/`m_axi_i` records |
| `src/hdl/zynq_mini_top.vhd`   | **synthesis top** — just `u_ps` + `u_axi_regs` + user logic, PS↔PL bus is 2 record signals |
| `src/constrs/zynq_mini.xdc`   | (empty — no external PL I/O in this design) |
| `sim/tb_axi_regs.vhd`         | VUnit testbench: AXI3 master BFM driving `axi_regs` |
| `sim/run.py`                  | VUnit run script (NVC backend) |
| `sw/`                         | **bare-metal bring-up test** — PS UART1 + PS↔PL AXI, JTAG only (`sw/README.md`) |
| `doc/mio_map.md`              | full PS MIO map of the board |
| `doc/board_pinout.md`        | PL pin map (LEDs, OLED, HDMI, 2nd Ethernet, cameras) from the vendor XDCs |
| `doc/notes.md`                | board details, Linux-boot resources (Habr series), `axi_regs` from Linux |

`build/` and `output/` are generated and git-ignored. Everything is VHDL-2008.

## Build

Vivado 2024.2 on `PATH` (or set `VIVADO_BIN`).

```bat
build.bat            :: full build -> output\arm_fpga_zynq_mini.bit + .xsa
build.bat bd         :: stop after the block design
build.bat synth      :: stop after synthesis
build.bat impl       :: stop after implementation
build.bat gui        :: create the project and open the Vivado GUI
```

Linux/WSL: `./build.sh [bd|synth|impl|gui]`. Direct:
`vivado -mode batch -source scripts/build.tcl -tclargs bd`.

**Parallelism:** the build uses every logical CPU by default (`general.maxThreads`
+ `launch_runs -jobs`, detected from the machine, capped at Vivado's 32). Cap it
with `VIVADO_BUILD_JOBS` / `VIVADO_BUILD_THREADS` before launching — see
`scripts/config.tcl`.

Outputs in `output/`: `arm_fpga_zynq_mini.bit`, `arm_fpga_zynq_mini.xsa` (fixed
platform, bitstream included — hand to Vitis; the `.xsa` records the M_AXI_GP0
window at `0x4000_0000`–`0x7FFF_FFFF`), plus utilization / timing reports.

## Simulate the AXI communication (VUnit + NVC)

`sim/tb_axi_regs.vhd` contains a compact **AXI3 master bus-functional model**
that drives `axi_regs` exactly as the Zynq `M_AXI_GP0` port would — address
phase, data phase, write response, read data, transaction IDs and INCR/FIXED
bursts — and self-checks the results.

```
pip install -r sim/requirements.txt      # vunit_hdl
# NVC must be on PATH: https://github.com/nickg/nvc

python sim/run.py                 # run all cases
python sim/run.py -v              # verbose (per-check log)
python sim/run.py --list          # list cases
python sim/run.py --gui           # waveform
python sim/run.py "*burst*"       # subset
```

Cases: `signature`, `single_write_read`, `id_reflection` (BID/RID reflect
AW/AR ID), `incr_burst_write_then_read`, `fixed_burst_write`, `pl_computes_sum`,
`status_word`, `control_and_heartbeat`.

## Test the board — no SD card

With the board on JTAG only (Vitis 2024.2 + `xsct`, `output/*.xsa` + `*.bit` built):

```
sw\uart_test.bat          :: build + load a bare-metal app that checks
                          ::   1. PS UART1 (internal loopback, 256/256)
                          ::   2. PS <-> PL: the M_AXI_GP0 bus to axi_regs
                          ::      (SIGNATURE / loopback / SUM / HEARTBEAT / STATUS)
                          ::   3. banner + RX echo
xsct sw/uart_poke.tcl     :: 15 s UART1-only smoke test, no build
```

Both self-tests are read back over JTAG (`PASS`/`FAIL` without a terminal);
open a serial terminal at **115200 8N1** for the full report + echo. Verified
on hardware — both `PASS`. Details in [`sw/README.md`](sw/README.md).

## Register map (`axi_regs`)

The slave decodes AXI address bits `[4:2]` → 8 words, at the base of the
`M_AXI_GP0` window (**`0x4000_0000`**). Anything on GP0 lands here; from
bare-metal just use `0x40000000` (there is no `xparameters.h` entry because the
slave is not a BD IP).

| Offset | Name | Access | Direction | Meaning |
|-------:|------|:------:|:---------:|---------|
| `0x00` | SCRATCH0  | R/W | PS → PL | free R/W; exported on `reg_ps2pl(0)` |
| `0x04` | SCRATCH1  | R/W | PS → PL | free R/W; exported on `reg_ps2pl(1)` |
| `0x08` | SCRATCH2  | R/W | PS → PL | free R/W; exported on `reg_ps2pl(2)` |
| `0x0C` | CONTROL   | R/W | PS → PL | bit0 → `pl_active_o`; bit1 clears HEARTBEAT |
| `0x10` | HEARTBEAT | RO  | PL → PS | free-running counter |
| `0x14` | SUM       | RO  | PL → PS | `SCRATCH0 + SCRATCH1`, added in the PL |
| `0x18` | STATUS    | RO  | PL → PS | reductions/popcount of the scratch regs |
| `0x1C` | SIGNATURE | RO  | PL → PS | constant `0x5A5A_1234` |

`STATUS`: bit0 = `or SCRATCH0`, bit1 = `and SCRATCH1`, bit2 = `SCRATCH0 =
SCRATCH1`, bit3 = `CONTROL(0)`, bits[15:8] = popcount(SCRATCH2), bits[31:16] =
HEARTBEAT[15:0].

Bare-metal smoke test:

```c
#define BASE 0x40000000u
Xil_Out32(BASE + 0x00, 0x12340000);
Xil_Out32(BASE + 0x04, 0x0000ABCD);
xil_printf("SIG  = %08x\n", Xil_In32(BASE + 0x1C));  // 5a5a1234
xil_printf("SUM  = %08x\n", Xil_In32(BASE + 0x14));  // 1234abcd
xil_printf("BEAT = %08x\n", Xil_In32(BASE + 0x10));  // changes every read
```

## AXI records (`axi_pkg.vhd`)

The bus is carried on two direction records instead of ~60 loose signals:

```
axi_mosi_t  (master out / slave in)      axi_miso_t  (slave out / master in)
  aw : axi_ax_t   -- id addr len size ...   awready
  w  : axi_w_t    -- id data strb last ...  wready
  bready                                    b  : axi_b_t   -- id resp valid
  ar : axi_ax_t                             arready
  rready                                    r  : axi_r_t   -- id data resp last valid
```

Widths (`AXI_ADDR_WIDTH`=32, `AXI_DATA_WIDTH`=32, `AXI_ID_WIDTH`=12,
`AXI_LEN_WIDTH`=4) and the `AXI_BURST_*` / `AXI_RESP_*` / `*_IDLE` constants are
in the package. `zynq_ps_wrapper` is the only place the flat `M_AXI_GP0_*` pins
appear — it packs them into `m_axi_o` / `m_axi_i`, so `zynq_mini_top`, `axi_regs`
and the testbench see nothing but the two records.

## The VHDL AXI slave (`axi_regs.vhd`)

Speaks the raw **AXI3 GP** protocol: 32-bit data/address, 12-bit IDs, 4-bit
`AWLEN`/`ARLEN`, single- and multi-beat INCR/FIXED bursts (WRAP handled as
INCR — fine for a register file). `BID`/`RID` reflect the request IDs so the PS
never stalls. `AxLOCK`/`AxCACHE`/`AxPROT`/`AxQOS` are carried in the record but
ignored by the slave.

## Extending it

- **Add fabric logic**: write it in `zynq_mini_top.vhd` (or new files in
  `TOP_SOURCES`), clocked by `clk` / reset `resetn`. Read PS values from
  `reg_ps2pl`. To return values to the PS, add a read register in
  `axi_regs.vhd` (extend the read mux + the write decode).
- **Reuse the AXI records**: `axi_pkg` gives you `axi_mosi_t` / `axi_miso_t` for
  any other AXI slave (or a PL AXI master) you add.
- **Add real PL I/O**: add a port to the `zynq_mini_top` entity **and** a
  `PACKAGE_PIN` / `IOSTANDARD` line in `src/constrs/zynq_mini.xdc` (pin numbers:
  `doc/mio_map.md`). Unconstrained top-level ports fail bitstream DRC.
- **More AXI bandwidth**: expose `S_AXI_HP0` the same way and write a VHDL
  master/DMA, or raise `FCLK0_MHZ` in `scripts/config.tcl`.
- The MIO peripherals are hard-routed; never add pin constraints for DDR / GEM0 /
  QSPI / SD — the `processing_system7` IP constrains them.
