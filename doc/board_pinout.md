# Zynq Mini — PL pin map (XC7Z020-CLG400)

The lessons repo <https://github.com/megalloid/zynq_mini_lessons> has **no
constraint files** (only Verilog + C snippets). This map is reconstructed from
the **vendor example projects** in `D:\dev\zynq_mini` — their user-written
`*.srcs/constrs_1/new/*.xdc` files are the authoritative board pinout.

All PL I/O below is **`LVCMOS33`**. PS MIO peripherals are in
[`mio_map.md`](mio_map.md).

## Basics

| Function | Pin(s) | Source example |
|---|---|---|
| PL clock — **50 MHz** oscillator | `K17` | `fpga_01_pl_led_stream`, `fpga_08_uart_eco` |
| User button / reset-in (active low) | `M19` | used as `rst_n` / key / gpio-in everywhere |
| User LEDs `led[0..3]` | `W13` `V12` `U12` `T12` | `fpga_01_pl_led_stream` |
| 4-pin header group (PWM / UART / EMIO-I²C) | `P15` `U15` `V15` `W15` | `arm_fpga_03` PWM = `ch1_n`/`ch1_p`/`ch2`/`ch3`; `fpga_08_uart` `rxd`=`P15` `txd`=`U15` |

## 40-pin EXT IO header (CAM1, "EXT IO 3.3V")

Schematic page 9. A 2×20 strip: pins 1–20 along the board edge, 21–40 on the inner row,
pin 20/21 at the SD-card end. Pins 1, 19, 22 = GND, 20/21 = VCC_3V3, 40 = VCC5.0; the other
34 are bank-34 PL pins (net `FPGA_GPIO_<pair>_34`, LVCMOS33). Constrained by header pin
number in `src/constrs/zynq_mini.xdc` (`ext_lo[2..18]`, `ext_hi[23..39]`).

| pin | net | ball | | pin | net | ball |
|---|---|---|---|---|---|---|
| 2  | 11N | `U15` | | 39 | 24P | `P15` |
| 3  | 10N | `W15` | | 38 | 10P | `V15` |
| 4  | 9N  | `U17` | | 37 | 21P | `V17` |
| 5  | 21N | `V18` | | 36 | 17P | `Y18` |
| 6  | 22P | `W18` | | 35 | 17N | `Y19` |
| 7  | 12N | `U19` | | 34 | 22N | `W19` |
| 8  | 11P | `U14` | | 33 | 23P | `N17` |
| 9  | 8N  | `Y14` | | 32 | 8P  | `W14` |
| 10 | 18P | `V16` | | 31 | 24N | `P16` |
| 11 | 12P | `U18` | | 30 | 19P | `R16` |
| 12 | 20P | `T17` | | 29 | 9P  | `T16` |
| 13 | 19N | `R17` | | 28 | 18N | `W16` |
| 14 | 16N | `W20` | | 27 | 20N | `R18` |
| 15 | 16P | `V20` | | 26 | 13N | `P19` |
| 16 | 15N | `U20` | | 25 | 23N | `P18` |
| 17 | 15P | `T20` | | 24 | 13P | `N18` |
| 18 | 14N | `P20` | | 23 | 14P | `N20` |

Verified on the board (2026-10-22): every pin driven at *pin number* × 10 kHz and
identified on a scope; pins 14, 15, 17 and 18 matched exactly. The vendor's "4-pin
group" (`P15 U15 V15 W15`) is pins 39, 2, 38, 3.

The current design uses pins 17/15/14/18 for the high-resolution PWM test
(`src/hdl/hrpwm.vhd`, web page `/pwm.html`) and drives the other header pins with the
identification pattern — don't connect anything that drives those pins.

## OLED (0.96" SSD1306, 4-wire SPI)

| Schematic net | SSD1306 pin | Function | Pin | top-level port |
|---|---|---|---|---|
| `OLED_D0`  | D0   | SCLK     | `E18` | `oled_sclk` |
| `OLED_D1`  | D1   | SDIN     | `E19` | `oled_sdin` |
| `OLED_DC`  | D/C# | 0 = command, 1 = data | `F16` | `oled_dc` |
| `OLED_RST` | RES# | reset, active low | `F17` | `oled_res_n` |

From the schematic (page 12, J4 `OLED12864`): CS#, BS0, BS1, BS2, E/RD# and R/W#
are tied to GND, so the panel is always selected and in 4-wire SPI mode. VBAT is
3.3 V, so it needs the internal charge pump (`8D 14`). Driven by
`src/hdl/ssd1306_text.vhd`. `E18` is also wired to HDMI_HPD below.

## HDMI out (TMDS straight from PL — no level-shifter/buffer chip)

| Signal | p / n |
|---|---|
| TMDS clock  | `H16` / `H17` |
| TMDS data 0 | `D19` / `D20` |
| TMDS data 1 | `C20` / `B20` |
| TMDS data 2 | `B19` / `A20` |
| `HDMI_EN`   | `H18` |
| `HDMI_HPD`  | `E18` |

From `arm_fpga_04_hdmi_output` / `_10` / `_11` / `_12`. Matches Habr 849032.

## Second Gigabit Ethernet — **RTL8211E on the PL** (RGMII)

Separate from the PS GEM0 PHY. This is the "Ethernet PHY connected to PL" the
Habr review mentions.

| Signal | Pin |
|---|---|
| `MDC` | `G18` |
| `MDIO` | `G19` |
| PHY reset `phy_rst_n` (active low) | `G17` |
| `RGMII txc` | `J14` |
| `RGMII tx_ctl` | `K14` |
| `RGMII td[0..3]` | `N16` `J19` `H20` `N15` |
| `RGMII rxc` | `L16` |
| `RGMII rx_ctl` | `L17` |
| `RGMII rd[0..3]` | `L20` `K19` `J18` `J20` |

From `arm_fpga_09_pl_lwip` and `FPGA逻辑部分/fpga_14_eth_pl_mdio` (`rtl8211e_mdio.v`).

## OV5640 camera 0 (bank pins + EMIO SCCB)

| Signal | Pin | | Signal | Pin |
|---|---|---|---|---|
| `reset` | `N20` | | `data[0]` | `P18` |
| `pclk`  | `U20` | | `data[1]` | `W16` |
| `href`  | `N18` | | `data[2]` | `R17` |
| `vsync` | `T20` | | `data[3]` | `T17` |
| `scl`   | `T16` | | `data[4]` | `R18` |
| `sda`   | `V16` | | `data[5]` | `P19` |
|         |       | | `data[6]` | `U18` |
|         |       | | `data[7]` | `R16` |

## OV5640 camera 1 (dual-camera board only)

| Signal | Pin | | Signal | Pin |
|---|---|---|---|---|
| `reset` | `W18` | | `data[0]` | `U17` |
| `pclk`  | `Y14` | | `data[1]` | `Y19` |
| `href`  | `Y18` | | `data[2]` | `W19` |
| `vsync` | `W14` | | `data[3]` | `U19` |
|         |       | | `data[4]` | `V15` |
| EMIO SCCB bus (shared) | `V16` `T16` `W15` `U15` | | `data[5]` | `V17` |
|         |       | | `data[6]` | `V18` |
|         |       | | `data[7]` | `P15` |

From `arm_fpga_11_ov5640` / `arm_fpga_12_double_ov5640`.

---

*Not exhaustive — the board also has an I²C EEPROM and a
second SD/eMMC on the PS. Pull the specific vendor example's XDC when you need a
peripheral not listed here.*
