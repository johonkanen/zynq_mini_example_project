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

## OLED (0.96" SSD1306, bit-banged 4-wire)

| Signal | Pin |
|---|---|
| `gpio_rtl_1` | `E19` |
| `gpio_rtl_2` | `E18` |
| `gpio_rtl_3` | `F16` |
| `gpio_rtl_4` | `F17` |

From `arm_fpga_08_pl_oled` (4× AXI-GPIO → DC / RES / SCLK / SDIN — confirm order
against the board silk). `E18` is shared with HDMI_HPD below.

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

*Not exhaustive — the board also has a 34-pin PL GPIO header, I²C EEPROM, and a
second SD/eMMC on the PS. Pull the specific vendor example's XDC when you need a
peripheral not listed here.*
