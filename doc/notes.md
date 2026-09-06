# Notes

## Booting Linux on this board

This project only produces a bitstream + `.xsa`. Linux is a separate build on top
of the `.xsa` (FSBL → U-Boot → kernel + device tree → rootfs, packed into
`BOOT.BIN` + an SD card). Nothing in the FPGA design needs to change to support
it — DDR3 (512 MB), UART1 console, QSPI, SD0 (microSD), SD1 (eMMC) and GEM0 are
all already configured.

### The board

Appears to be a **MicroPhase Z7-Lite 7020** (or a close clone). Matches the
reference manual: `XC7Z020-1CLG400C` speed grade -2, one 512 MB DDR3
(MT41J/MT41K 256M16), `W25Q128` 128 MB QSPI, `USB3320` ULPI PHY, JTAG/QSPI/SD
boot jumper (J1). The vendor example set (OLED, dual OV5640, HDMI, lwIP) is
MicroPhase's line-up. MicroPhase sells it "running Ubuntu/Debian", so a working
Linux stack for this exact board exists — ask them for the PetaLinux BSP / SD
image.

### Board-specific resources

| Resource | What it is |
|---|---|
| <https://github.com/smirnovich/microphase-z7> | `linux/` folder with **Buildroot** instructions for the Z7-Lite (Vivado 2023.1). Incomplete in places but board-specific. |
| <https://github.com/vanbwodonk/zynq_z7lite_training> | FPGA-only tutorials, **but ships `Schematic/Z7-LITE_Rev1_1.pdf`** — use it to confirm the Ethernet PHY wiring (see caveat below). |
| <https://github.com/MicroPhase/fpga-docs> · <https://fpga-docs.microphase.cn> | Vendor docs. Z7-Lite manual points to Baidu courseware for the OS side. |
| <https://github.com/hw/Microphase-Z7-Lite> | Z7-Lite **7010** notes; links to `github.com/vanbwodonk/zynq_z7lite_training`. |

### From-scratch walkthroughs for XC7Z020

| Resource | Notes |
|---|---|
| <https://github.com/Risto97/zturn_linux> | MYIR Z-Turn 7020, a near-identical XC7Z020 core board. **Full step-by-step README**: hardware export → FSBL in SDK → device tree via DTG → `make_uboot.sh` / `make_kernel.sh` → `BOOT.BIN` via a `.bif`. Most directly transferable recipe. |
| <https://xilinx.github.io/Embedded-Design-Tutorials/docs/2023.1/build/html/docs/Introduction/Zynq7000-EDT/7-linux-booting-debug.html> | AMD/Xilinx *Zynq7000 Embedded Design Tutorials*, Ch. 7 "Linux Boot Image Configuration" — the canonical FSBL → U-Boot → kernel → rootfs → `BOOT.BIN` guide. |
| <https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/18842369/Build+Linux+for+Zynq-7000+AP+SoC+using+Buildroot> | Xilinx Wiki — the lightweight Buildroot path. |
| <https://github.com/Digilent/Petalinux-Zybo-Z7-20> | Same XC7Z020; maintained `system-user.dtsi` worth cribbing from. |
| <https://www.allpcb.com/allelectrohub/building-a-linux-system-on-zynq-7020> · <https://pcbsync.com/xilinx-zynq-linux/> | Blog-style from-scratch writeups. |

### Recommended path

1. Check for a **MicroPhase PetaLinux BSP / SD image** first (vendor download or
   support). Re-point it at `output/arm_fpga_zynq_mini.xsa`.
2. Otherwise **PetaLinux**: `petalinux-create -t project -n zynqlin`,
   `petalinux-config --get-hw-description output/arm_fpga_zynq_mini.xsa`, fix the
   Ethernet / SD / flash nodes in `project-spec/meta-user/.../system-user.dtsi`,
   `petalinux-build`, `petalinux-package --boot`. With a known PHY: ~1 day.
3. Or **Buildroot** (`zynq_*_defconfig` template) for a lighter, faster stack.

SD card layout: p1 FAT32 (`BOOT.BIN`, `Image`, `system.dtb`, `boot.scr`),
p2 ext4 (rootfs). Set the J1 jumper to SD boot.

### Using `axi_regs` from Linux

`axi_regs` sits at `0x4000_0000` (the whole M_AXI_GP0 window). It is not a BD IP,
so the Device Tree Generator will not create a node — add one by hand:

```dts
axi_regs@40000000 {
    compatible = "generic-uio";   /* or a custom driver */
    reg = <0x40000000 0x1000>;
};
```

Then `mmap` via UIO, or just `devmem2 0x40000000` to poke SCRATCH0 / read
`0x4000001C` (SIGNATURE = `0x5A5A1234`).

---

## ⚠ Ethernet PHY caveat

The PS7 configuration in this project was lifted from the vendor's bare-metal
`arm_13_lwip` example. It puts **GEM0 on MIO 16–27 as RGMII** with MDIO on
MIO 52–53 — which implies a **gigabit RGMII PHY** (RTL8211-class).

But the **Z7-Lite reference manual says RTL8201F (10/100)**, and
`github.com/smirnovich/microphase-z7` describes the PHY reached via **EMIO / RMII**,
not MIO / RGMII. These disagree — most likely different board revisions.

**Before writing the Linux Ethernet device-tree node, confirm against the actual
board / schematic (`Z7-LITE_Rev1_1.pdf`):**

- PHY chip (RTL8211E/F ⇒ RGMII gigabit, or RTL8201F ⇒ RMII 10/100)
- MIO RGMII vs EMIO RMII (Zynq GEM via the MIO pin group is **RGMII-only**;
  RMII/MII need EMIO)
- MDIO/PHY address
- PHY reset line (this design routes none from the PS — if the PHY needs a
  GPIO reset it must be added in the block design, or it is handled by board
  hardware/POR)

If the board really is RGMII gigabit on MIO (as the current config assumes), the
DT node is standard: `phy-mode = "rgmii-id"`, `macb`/`cadence-gem` driver, PHY at
its MDIO address. If it is RTL8201F on EMIO/RMII, the PS7 config **and** the
block design need reworking (EMIO ENET0, `phy-mode = "rmii"`) — that is a design
change, not just a device-tree edit.
