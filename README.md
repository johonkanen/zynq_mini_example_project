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
   |
   +-- u_bd : zynq_mini            <- generated block-design entity (PS7 only)
   |     |
   |     |   DDR3 (MT41J256M16, 512 MB)
   |     +---processing_system7----- Ethernet GEM0 (RGMII + MDIO) -> PHY
   |     |        (PS7)              QSPI (single SS, x4)          -> boot flash
   |     |                           SD1                          -> eMMC
   |     |                           SD0                          -> microSD
   |     |                           UART1                        -> USB console
   |     |
   |     +-- M_AXI_GP0 (AXI3, raw)  +  FCLK_CLK0 (100 MHz) / FCLK_RESET0_N
   |            |                       exposed on the BD boundary
   |            v
   +-- u_axi_regs : axi_regs   <- AXI slave, 100% VHDL (src/hdl/axi_regs.vhd)
   |            |
   |     reg_ps2pl[127:0] / pl_active
   |            v
   +-- placeholder PL user logic  (counter on FCLK_CLK0 + the register bus)
```

## Layout

| Path | Purpose |
|------|---------|
| `scripts/config.tcl`          | part, names, paths, clock frequency, parallelism |
| `scripts/ps7_base_config.tcl` | full PS7 preset (DDR3 + GEM0 + UART1 + clocks), captured from the board |
| `scripts/create_bd.tcl`       | builds the PS7-only `zynq_mini` block design, routes M_AXI_GP0 to the boundary, generates it as a plain entity (no wrapper) |
| `scripts/build.tcl`           | top build flow: project → BD → add VHDL → synth → impl → bitstream → XSA |
| `src/hdl/axi_pkg.vhd`         | AXI bus **direction records** — `axi_mosi_t` (master→slave), `axi_miso_t` (slave→master), nested per channel |
| `src/hdl/axi_regs.vhd`        | **VHDL AXI slave** for the raw M_AXI_GP0 (AXI3); port is `s_axi_i : axi_mosi_t` / `s_axi_o : axi_miso_t` |
| `src/hdl/zynq_mini_top.vhd`   | **hand-written VHDL top**; maps the flat `M_AXI_GP0_*` pins onto the records, instantiates the BD + `axi_regs` |
| `src/constrs/zynq_mini.xdc`   | (empty — no external PL I/O in this design) |
| `sim/tb_axi_regs.vhd`         | VUnit testbench: AXI3 master BFM driving `axi_regs` |
| `sim/run.py`                  | VUnit run script (NVC backend) |
| `doc/mio_map.md`              | full PS MIO map of the board |

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
in the package. `zynq_mini_top` maps the block design's flat `M_AXI_GP0_*` pins
directly onto the record fields; `axi_regs` and the testbench use the records
end to end.

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
