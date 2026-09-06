# Notes

## The board

**"Zynq Mini" XC7Z020-CLG400** — a cheap AliExpress Zynq-7020 board, reviewed on
Habr: [habr.com/ru/articles/721146](https://habr.com/ru/articles/721146/)
(English-friendly mirror: [pvsm.ru/fpga/383315](https://www.pvsm.ru/fpga/383315)).
The Habr author, **Andrey Zaostrovnykh (@andreyzaostrovnykh)**, has a whole
Zynq-7000 series covering this exact board and its close QMTech sibling.

| | |
|---|---|
| SoC | XC7Z020-CLG400, speed grade -2 |
| DDR3 | 512 MB, MT41J256M16 |
| QSPI flash | **16 MB**, SOIC-8 (socketed / upgradeable) |
| Ethernet | Gigabit **RTL8211E-class, RGMII**, on **PS GEM0 / MIO 16–27**, MDIO on MIO 52–53, **PHY address 0** |
| USB | Host on USB-C, ULPI PHY (USB3320-class) |
| HDMI | direct from PL GPIO, no companion/ESD chip (bit-banged TMDS: H16 H17 D19 D20 C20 B20 B19 A20 H18) |
| OLED | 128×64 SSD1306, bit-banged 4-wire from PL (this repo's sibling example uses AXI-GPIO → E19 E18 F16 F17) |
| clock | external 50 MHz oscillator to PL |
| storage | microSD (SDIO0) + on-board eMMC (SDIO1) |
| misc | I²C EEPROM 2 Kbit (PL), 5 LEDs (4 PL / 1 PS), 3 buttons (2 PL / 1 PS), 34 PL GPIO |
| boot | 3-position switch: JTAG / QSPI / SD; on-board JTAG programmer |

The board ships with a **microSD that already has Linux on it** — you don't
have to build anything to see it boot; the material below is for building your
own image.

## Booting Linux

This project only produces a bitstream + `.xsa`. Nothing in the FPGA design
needs to change to support Linux — DDR3, UART1 console, QSPI, microSD, eMMC and
GEM0 are all configured. The `.xsa` feeds the FSBL and the base device tree.

### Zaostrovnykh's Habr series — this board / its QMTech twin

| Article | What it covers |
|---|---|
| [721146](https://habr.com/ru/articles/721146/) | Zynq Mini board review (this board) |
| [559946](https://habr.com/ru/articles/559946/) | Getting started with Zynq-7000 (QMTech "Bajie", beginner) |
| [565368](https://habr.com/ru/articles/565368/) | **Build Linux from scratch**: `u-boot-xlnx` (`xilinx_zynq_virt_defconfig`) → DTG (`device-tree-xlnx`) → `linux-xlnx` (`xilinx_zynq_defconfig`, `uImage` @ `0x8000`) → prebuilt rootfs → `uramdisk` → `BOOT.BIN` → SD. Its Ethernet section is **identical to this project's config** (RGMII, bank1 1.8 V, MIO 16:27, MDIO 52:53, RTL8211E, "Link is Up - 1Gbps"). |
| [567408](https://habr.com/ru/articles/567408/) | Same, but rootfs + kernel via **Buildroot** (2021.05.x): ARM Cortex-A9 hardfp / glibc, kernel from `linux-xlnx` `xilinx_zynq_defconfig` `uImage`, SD FAT = `uImage` + `uramdisk.image.gz` + `devicetree.dtb`. |
| [835912](https://habr.com/ru/companies/timeweb/articles/835912/) | **Boot Linux over JTAG with XSCT** on the Zynq Mini (uses a `zynqmini.dtb`). No SD flashing: `connect` → `fpga *.bit` → `dow fsbl.elf` → `source ps7_init.tcl; ps7_init; ps7_post_config` → `dow -data zynqmini.dtb 0x10000` → `dow u-boot.elf` → `dow -data uImage 0x3000000` → `dow -data rootfs.cpio.uboot 0x2000000` → `bootm 0x3000000 0x2000000 0x1f00000`. Confirms `phyaddr 0, interface rgmii-id`. Great for bring-up. |
| [849032](https://habr.com/ru/companies/timeweb/articles/849032/) | HDMI from bare-metal on the Zynq Mini (companion, not Linux). Repo below. |

Repo of lesson materials for this board:
**<https://github.com/megalloid/zynq_mini_lessons>** (`first_lesson`, `hdmi_vdma`).

### Other useful references

| Resource | Notes |
|---|---|
| [habr 1042798](https://habr.com/ru/articles/1042798/) | Linux on Zynq RK-7020-F via **Buildroot + U-Boot SPL** (modern, no FSBL) |
| [habr 845714](https://habr.com/ru/companies/yadro/articles/845714/) / [852780](https://habr.com/ru/companies/yadro/articles/852780/) / [860428](https://habr.com/ru/companies/yadro/articles/860428/) | YADRO's thorough "Embedded Linux on Zynq" series (PL project → OS build → bring-up) |
| [habr 1052912](https://habr.com/ru/articles/1052912/) | Loading the bitstream from Linux via the FPGA Manager |
| <https://github.com/Risto97/zturn_linux> | MYIR Z-Turn 7020 (near-identical core board), full from-scratch README |
| [Xilinx Zynq7000 EDT, Ch. 7](https://xilinx.github.io/Embedded-Design-Tutorials/docs/2023.1/build/html/docs/Introduction/Zynq7000-EDT/7-linux-booting-debug.html) | Canonical FSBL → U-Boot → kernel → rootfs → `BOOT.BIN` |
| [Xilinx Wiki: Buildroot for Zynq-7000](https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/18842369/) | Lightweight path |
| <https://github.com/Digilent/Petalinux-Zybo-Z7-20> | Same XC7Z020; maintained `system-user.dtsi` to crib from |

### Recommended path

1. Start from the **stock SD image** or Zaostrovnykh's Buildroot config
   ([567408](https://habr.com/ru/articles/567408/)) and re-point the FSBL +
   device tree at `output/arm_fpga_zynq_mini.xsa`.
2. For fast iteration, boot over **JTAG with XSCT** as in
   [835912](https://habr.com/ru/companies/timeweb/articles/835912/) — no card
   swapping.
3. PetaLinux works too (`petalinux-config --get-hw-description output/arm_fpga_zynq_mini.xsa`).

SD card layout: p1 FAT32 (`BOOT.BIN`, `uImage`/`Image`, `*.dtb`, `boot.scr` or
`uramdisk.image.gz`), p2 ext4 (rootfs). Boot switch → SD.

### Using `axi_regs` from Linux

`axi_regs` sits at `0x4000_0000` (the whole M_AXI_GP0 window). It is not a BD IP,
so the Device Tree Generator will not create a node — add one by hand:

```dts
axi_regs@40000000 {
    compatible = "generic-uio";   /* or a custom driver */
    reg = <0x40000000 0x1000>;
};
```

Then `mmap` via UIO, or `devmem2 0x40000000` to poke SCRATCH0 / read
`0x4000001C` (SIGNATURE = `0x5A5A1234`).

## Ethernet — the board has TWO gigabit PHYs

Earlier drafts of this file flagged a possible RTL8201F / RMII / EMIO wiring,
from mistaking the board for a MicroPhase Z7-Lite. Wrong — it's the Zynq Mini,
and it has **two RTL8211E gigabit PHYs**:

1. **PS GEM0**, RGMII, on **MIO 16–27**, MDIO on MIO 52–53, **PHY address 0**,
   `phy-mode = "rgmii-id"`, `macb` / `cadence-gem` driver, bank 1 = 1.8 V.
   This is exactly what `ps7_base_config.tcl` sets. Confirmed by the vendor
   `arm_13_lwip` example, the QMTech twin in Habr
   [565368](https://habr.com/ru/articles/565368/), and the `zynqmini.dtb` in
   Habr [835912](https://habr.com/ru/companies/timeweb/articles/835912/)
   (`ZYNQ GEM: e000b000 ... phyaddr 0, interface rgmii-id`). This is the one
   Linux uses out of the box.

2. **A second RTL8211E wired to the PL fabric** (RGMII), the "Ethernet PHY
   connected to PL" from the board review. Pins (from `arm_fpga_09_pl_lwip` /
   `fpga_14_eth_pl_mdio`): MDC `G18`, MDIO `G19`, **reset `G17`**, TXC `J14`,
   TX_CTL `K14`, TD `N16 J19 H20 N15`, RXC `L16`, RX_CTL `L17`,
   RD `L20 K19 J18 J20`. Reach it via a soft MAC in the PL, or route GEM1 out
   through EMIO. See [`board_pinout.md`](board_pinout.md).

The PS GEM0 PHY has **no reset routed from the PS** — it relies on board POR; add
a MIO/EMIO GPIO reset if you ever need one. The PL PHY's reset is `G17`.
