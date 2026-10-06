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
   |            |                    incl. OLED_CTRL + 128-char OLED_TEXT buffer
   |     reg_ps2pl[127:0] / pl_active      |
   |            v                          v
   +-- placeholder PL user logic    +-- u_oled : ssd1306_text  -> SPI -> 0.96" OLED
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
| video / display | HDMI direct from PL GPIO (no companion chip); 128×64 SSD1306 OLED on PL pins (4-wire SPI) — driven by `ssd1306_text` |
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
| `src/hdl/zynq_mini_top.vhd`   | **synthesis top** — `u_ps` + `u_axi_regs` + `u_oled` + user logic, PS↔PL bus is 2 record signals |
| `src/hdl/ssd1306_text.vhd`    | **OLED driver** — SSD1306 reset/init + 16×8 text mode refreshed over SPI from the `axi_regs` text buffer |
| `src/hdl/font8x8_pkg.vhd`     | 8×8 ASCII font ROM in SSD1306 column order (public-domain font8x8) |
| `src/constrs/zynq_mini.xdc`   | OLED pins; every other PL pin of the board listed, commented out |
| `sim/tb_axi_regs.vhd`         | VUnit testbench: AXI3 master BFM driving `axi_regs` |
| `sim/tb_ssd1306_text.vhd`     | VUnit testbench: SPI panel model checking init, frame commands and rendered text |
| `sim/run.py`                  | VUnit run script (NVC backend) |
| `sw/`                         | **bare-metal bring-up test** — PS UART1 + PS↔PL AXI, JTAG only (`sw/README.md`) |
| `linux/build-linux.sh`        | one-shot Buildroot Linux image build (`doc/linux_build.md`) |
| `linux/reflash-sd.sh` + `reflash_sd.bat`/`.tcl` | reflash the microSD in the board over TFTP, U-Boot driven via JTAG |
| `linux/fpgad/`                | `fpgad` (the one process that touches the FPGA), `fpgactl`, client library — `doc/linux_build.md` §12 |
| `linux/fpga-web/`             | web UI: register read/write + live uPlot charts over a binary WebSocket (`/ws`), talks only to `fpgad`; `vendor/` = uPlot (MIT) |
| `linux/br2-external/`         | Buildroot external tree: `fpgad` + `fpga-web` packages and init scripts |
| `linux/update-board.sh`       | push kernel/dtb/bitstream/web server to a running board over SSH — `doc/linux_build.md` §13 |
| `linux/zynq-zynqmini.dts`     | kernel device tree for the board (used by `doc/linux_build.md`) |
| `doc/mio_map.md`              | full PS MIO map of the board |
| `doc/board_pinout.md`        | PL pin map (LEDs, OLED, HDMI, 2nd Ethernet, cameras) from the vendor XDCs |
| `doc/notes.md`                | board details, Linux-boot resources (Habr series), `axi_regs` from Linux |
| `doc/linux_build.md`          | step-by-step: build a bootable SD-card Linux image with Buildroot |

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

## Simulate the AXI communication and the OLED driver (VUnit + NVC)

`sim/tb_axi_regs.vhd` contains a compact **AXI3 master bus-functional model**
that drives `axi_regs` exactly as the Zynq `M_AXI_GP0` port would — address
phase, data phase, write response, read data, transaction IDs and INCR/FIXED
bursts — and self-checks the results. `sim/tb_ssd1306_text.vhd` puts a model of
the SSD1306's SPI input on `ssd1306_text` and checks every byte it sends.

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
`status_word`, `control_and_heartbeat`, `oled_ctrl_and_status`, `oled_text_buffer`;
OLED driver: `init_sequence`, `first_frame_renders_text` (all 1024 display bytes
vs. the text buffer through the font), `controls_apply_next_frame`, `reset_restarts`.

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

The slave decodes AXI address bits `[7:2]` → 64 words (the map repeats every
256 bytes), at the base of the `M_AXI_GP0` window (**`0x4000_0000`**). Anything on GP0 lands here; from
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
| `0x20` | OLED_CTRL | R/W | PS → PL | bit0 display on, bit1 invert, bit2 flip 180°, bits[15:8] contrast; reset `0x0000_7F01` |
| `0x24` | OLED_STAT | RO  | PL → PS | bit0 ready (init done), bits[31:16] frames sent |
| `0x80`–`0xFC` | OLED_TEXT | R/W | PS → PL | 16×8 characters, 4 per word, little-endian |

Other offsets read 0.

`STATUS`: bit0 = `or SCRATCH0`, bit1 = `and SCRATCH1`, bit2 = `SCRATCH0 =
SCRATCH1`, bit3 = `CONTROL(0)`, bits[15:8] = popcount(SCRATCH2), bits[31:16] =
HEARTBEAT[15:0].

## OLED (`ssd1306_text`)

The board's 0.96" 128×64 SSD1306 OLED (J4) is driven **entirely from the PL**: no
Linux driver, no GPIO bit-banging from software. The panel is strapped for 4-wire
SPI with CS# tied low (schematic p.12), so the PL drives four pins — SCLK `E18`,
SDIN `E19`, D/C# `F16`, RES# `F17`.

After the bitstream loads, `ssd1306_text` pulses RES#, sends the init sequence
(internal charge pump: VBAT is 3.3 V) and then redraws the whole display 30× a
second at 5 MHz SCLK. Each frame renders the `OLED_TEXT` buffer through an 8×8 font:
row *r* of text is display page *r*, so each glyph column is one SSD1306 data byte.
The buffer resets to **"Hello, Zynq Mini"**, so the display says hello as soon as
the PL is configured, with no software involved.

Character *n* (row `n/16`, column `n%16`) is byte `n%4` of word `n/4`
at `0x80`, so a string copied there reads left to right. From Linux, go
through `fpgad` (it owns the PL):

```sh
fpgactl oled 0 "Hello, world"      # row 0..7, 16 characters, padded with spaces
fpgactl oled clear
fpgactl write 0x20 0x00FF0003      # on + inverted, full contrast
fpgactl write 0x20 0x00007F05      # upright text if the panel is mounted upside down
```

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
