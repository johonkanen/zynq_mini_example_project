# Zynq Mini Board — PS MIO Map

Derived from the `processing_system7` (`PCW_MIO_TREE_*`) configuration aggregated across
all 26 example projects in `D:\dev\zynq_mini` (`ARM\`, `ARM+FPGA\`, and the loose Vivado
projects).

- **Device package:** `clg400` (XC7Z0xx-CLG400)
- **MIO bank 0:** MIO 0–15, **LVCMOS 3.3 V** (`PCW_PRESET_BANK0_VOLTAGE`)
- **MIO bank 1:** MIO 16–53, **LVCMOS 1.8 V** (`PCW_PRESET_BANK1_VOLTAGE`)
- **Console:** UART1 on MIO 48/49 (USB‑serial), used by every example
- No example enables PS I²C, PS SPI, PS CAN, NAND or NOR. OLED / HDMI / OV5640 (incl.
  its SCCB/I²C) / PL LEDs+keys / XADC are all on **PL** fabric, not MIO.

## Full MIO table

| MIO | Bank | Voltage | Peripheral (as used by examples) | Signal | Board function / notes |
|----:|:----:|:--------|:--------------------------------|:-------|:-----------------------|
| 0  | 0 | 3.3 V | GPIO | `gpio[0]` | **User push‑button (KEY)** — input, edge interrupt (`arm_02`, `arm_04`) |
| 1  | 0 | 3.3 V | Quad SPI Flash | `qspi0_ss_b` | **QSPI NOR boot flash** — chip select |
| 2  | 0 | 3.3 V | Quad SPI Flash | `qspi0_io[0]` | QSPI D0 (MOSI). Also boot‑mode strap pin (POR) |
| 3  | 0 | 3.3 V | Quad SPI Flash | `qspi0_io[1]` | QSPI D1 (MISO). Also boot‑mode strap pin (POR) |
| 4  | 0 | 3.3 V | Quad SPI Flash | `qspi0_io[2]` | QSPI D2. Also boot‑mode strap pin (POR) |
| 5  | 0 | 3.3 V | Quad SPI Flash | `qspi0_io[3]` / `HOLD_B` | QSPI D3. Also boot‑mode strap pin (POR) |
| 6  | 0 | 3.3 V | Quad SPI Flash | `qspi0_sclk` | QSPI clock. Also boot‑mode strap pin (POR) |
| 7  | 0 | 3.3 V | *(free)* | — | Brought to header; usable as PS GPIO output only (MIO7 is output‑only) |
| 8  | 0 | 3.3 V | *(free)* | — | Brought to header; usable as PS GPIO output only (MIO8 is output-only) |
| 9  | 0 | 3.3 V | GPIO | `gpio[9]` | **User LED (LED1)** — output (`arm_02`: `PS_LED1_MIO 9`) |
| 10 | 0 | 3.3 V | SD 1 | `data[0]` | **On‑board eMMC** (4‑bit) — `arm_12_emmc_fatfs` |
| 11 | 0 | 3.3 V | SD 1 | `cmd` | eMMC command |
| 12 | 0 | 3.3 V | SD 1 | `clk` | eMMC clock |
| 13 | 0 | 3.3 V | SD 1 | `data[1]` | eMMC |
| 14 | 0 | 3.3 V | SD 1 | `data[2]` | eMMC |
| 15 | 0 | 3.3 V | SD 1 | `data[3]` | eMMC |
| 16 | 1 | 1.8 V | Enet 0 | `tx_clk` | **Gigabit Ethernet (GEM0), RGMII** to external PHY |
| 17 | 1 | 1.8 V | Enet 0 | `txd[0]` | GEM0 RGMII |
| 18 | 1 | 1.8 V | Enet 0 | `txd[1]` | GEM0 RGMII |
| 19 | 1 | 1.8 V | Enet 0 | `txd[2]` | GEM0 RGMII |
| 20 | 1 | 1.8 V | Enet 0 | `txd[3]` | GEM0 RGMII |
| 21 | 1 | 1.8 V | Enet 0 | `tx_ctl` | GEM0 RGMII |
| 22 | 1 | 1.8 V | Enet 0 | `rx_clk` | GEM0 RGMII |
| 23 | 1 | 1.8 V | Enet 0 | `rxd[0]` | GEM0 RGMII |
| 24 | 1 | 1.8 V | Enet 0 | `rxd[1]` | GEM0 RGMII |
| 25 | 1 | 1.8 V | Enet 0 | `rxd[2]` | GEM0 RGMII |
| 26 | 1 | 1.8 V | Enet 0 | `rxd[3]` | GEM0 RGMII |
| 27 | 1 | 1.8 V | Enet 0 | `rx_ctl` | GEM0 RGMII |
| 28 | 1 | 1.8 V | USB 0 | `data[4]` | **USB0 ULPI** to USB PHY (OTG/host) — `arm_fpga_04/10` |
| 29 | 1 | 1.8 V | USB 0 | `dir` | USB0 ULPI |
| 30 | 1 | 1.8 V | USB 0 | `stp` | USB0 ULPI |
| 31 | 1 | 1.8 V | USB 0 | `nxt` | USB0 ULPI |
| 32 | 1 | 1.8 V | USB 0 | `data[0]` | USB0 ULPI |
| 33 | 1 | 1.8 V | USB 0 | `data[1]` | USB0 ULPI |
| 34 | 1 | 1.8 V | USB 0 | `data[2]` | USB0 ULPI |
| 35 | 1 | 1.8 V | USB 0 | `data[3]` | USB0 ULPI |
| 36 | 1 | 1.8 V | USB 0 | `clk` | USB0 ULPI clock |
| 37 | 1 | 1.8 V | USB 0 | `data[5]` | USB0 ULPI |
| 38 | 1 | 1.8 V | USB 0 | `data[6]` | USB0 ULPI |
| 39 | 1 | 1.8 V | USB 0 | `data[7]` | USB0 ULPI |
| 40 | 1 | 1.8 V | SD 0 | `clk` | **microSD card socket** (4‑bit) — `arm_06_sdcard_fatfs` |
| 41 | 1 | 1.8 V | SD 0 | `cmd` | microSD command |
| 42 | 1 | 1.8 V | SD 0 | `data[0]` | microSD |
| 43 | 1 | 1.8 V | SD 0 | `data[1]` | microSD |
| 44 | 1 | 1.8 V | SD 0 | `data[2]` | microSD |
| 45 | 1 | 1.8 V | SD 0 | `data[3]` | microSD |
| 46 | 1 | 1.8 V | *(free)* | — | Brought to header; usable as PS GPIO |
| 47 | 1 | 1.8 V | *(free)* | — | Brought to header; usable as PS GPIO |
| 48 | 1 | 1.8 V | UART 1 | `tx` | **Debug console TX** (USB‑serial), 115200 8N1 |
| 49 | 1 | 1.8 V | UART 1 | `rx` | **Debug console RX** |
| 50 | 1 | 1.8 V | *(free)* | — | Brought to header; usable as PS GPIO |
| 51 | 1 | 1.8 V | *(free)* | — | Brought to header; usable as PS GPIO |
| 52 | 1 | 1.8 V | Enet 0 | `mdc` | Ethernet PHY management clock |
| 53 | 1 | 1.8 V | Enet 0 | `mdio` | Ethernet PHY management data |

## Peripheral summary

| Peripheral | MIO pins | Present on board | Example project(s) |
|:-----------|:---------|:----------------:|:-------------------|
| QSPI NOR flash (boot) | 1–6 | yes | `arm_09_read_write_flash`, `arm_14_tcp_flash_update`, all FSBLs |
| eMMC (SD1) | 10–15 | yes | `arm_12_emmc_fatfs` |
| Gigabit Ethernet GEM0 (RGMII + MDIO) | 16–27, 52–53 | yes | `arm_13_lwip`, `arm_14`, `arm_fpga_04/09/10` |
| USB0 (ULPI) | 28–39 | yes | `arm_fpga_04_hdmi_output`, `arm_fpga_10_hdmi_sdbmp` |
| microSD (SD0) | 40–45 | yes | `arm_06_sdcard_fatfs` |
| UART1 console | 48–49 | yes | every project |
| User KEY / User LED | 0 / 9 | yes | `arm_02_mio_inout`, `arm_04_axi_gpio_interrupt` |
| Free PS GPIO to headers | 7, 8, 46, 47, 50, 51 | header | `arm_02_mio_inout` (all‑GPIO mode) |

## Notes for the new VHDL‑2008 example

- If this example uses the PS at all, start from the board preset used by the existing
  projects: **UART1 (MIO 48/49) enabled**, bank 0 = 3.3 V, bank 1 = 1.8 V, package
  `clg400`. Add SD0/QSPI/ENET/USB only as the example needs them — their MIO ranges are
  fixed as above.
- All MIO peripherals are hard‑routed; the PL‑facing I/O (OLED, HDMI, OV5640, PL LEDs,
  buttons, XADC) is where custom VHDL‑2008 RTL belongs. See the per‑example `*.xdc` files
  under each project's `*.srcs/constrs_1/` for PL pin assignments.
- Set VHDL‑2008 on your sources in Vivado:
  `set_property file_type "VHDL 2008" [get_files *.vhd]`.
