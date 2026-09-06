# Building a Linux image (Buildroot)

Step-by-step build of a bootable SD card for the **Zynq Mini** board, using
**Buildroot** for the toolchain + U-Boot + kernel + rootfs, and this project's
`output/arm_fpga_zynq_mini.xsa` for the board's PS7 configuration.

This is the path sketched in [`notes.md`](notes.md) → Habr
[567408](https://habr.com/ru/articles/567408/) (Buildroot) +
[1042798](https://habr.com/ru/articles/1042798/) (U-Boot SPL, no FSBL).
Nothing in the FPGA design has to change — DDR3, the UART1 console, QSPI,
microSD, eMMC and GEM0 Ethernet are all already configured by
`scripts/ps7_base_config.tcl`.

## What you get

```
sdcard.img
 ├─ p1  FAT32   boot.bin                  U-Boot SPL (+ PS7 init)   ← boot switch = SD
 │              u-boot.img                U-Boot proper
 │              uImage                    Linux kernel
 │              system.dtb                -> zynq-zynqmini.dtb
 │              extlinux/extlinux.conf    boot entry (console + rootfs)
 └─ p2  ext4    rootfs
```

Console: **UART1 on MIO 48/49**, `ttyPS0`, **115200 8N1** (the board's
USB-serial port — see [`mio_map.md`](mio_map.md)). Ethernet: **GEM0 / RGMII /
RTL8211E, PHY address 0, `phy-mode = "rgmii-id"`**.

## Prerequisites

| Tool | Notes |
|---|---|
| Vivado 2024.2 | to produce the `.xsa` (`./build.sh`) |
| A Linux host / WSL | to run Buildroot (needs `make`, `gcc`, `git`, `bc`, `flex`, `bison`, `libssl-dev`, `unzip`, `rsync`, `cpio`, `file`, `wget`) |
| `xsct` (from Vitis 2024.2) | **only to regenerate the device tree** (step 3) — the PS7 init comes straight out of the `.xsa` without it |
| A microSD card + reader | |
| USB-serial terminal | `picocom -b 115200 /dev/ttyUSB0` or PuTTY |

Everything below assumes the repo is at `~/dev/zynq_mini_example_project` and you
are building in `~/dev/zynqmini-linux`.

```bash
mkdir -p ~/dev/zynqmini-linux && cd ~/dev/zynqmini-linux
XSA=~/dev/zynq_mini_example_project/output/arm_fpga_zynq_mini.xsa
```

---

## 1. Build the FPGA hardware → `.xsa`

```bash
cd ~/dev/zynq_mini_example_project
./build.sh                       # -> output/arm_fpga_zynq_mini.xsa  (+ .bit)
```

The `.xsa` is a zip. It carries the PS7 register init the first-stage loader
needs (`ps7_init_gpl.c` / `.h`) and the hardware description (`*.hwh`).

---

## 2. Pull the PS init out of the `.xsa`

```bash
cd ~/dev/zynqmini-linux
mkdir -p xsa && (cd xsa && unzip -o "$XSA")
ls xsa/ps7_init_gpl.*            # ps7_init_gpl.c  ps7_init_gpl.h
```

`ps7_init_gpl.c/.h` = DDR3 (MT41J256M16, 512 MB), the PLLs/FCLKs, and the MIO
mux (GEM0 16–27, MDIO 52–53, QSPI 1–6, SD0 40–45, SD1/eMMC 10–15, UART1 48–49).
U-Boot's SPL compiles these in, so **no FSBL and no Vitis are required**.

**Patch the K&R prototypes.** Vivado 2024.2 emits `int ps7_init();` (empty
parens); modern U-Boot's SPL build has `-Werror=strict-prototypes` and rejects
it. Add `void` to the declarations *and* definitions — but not the internal
calls:

```bash
cd ~/dev/zynqmini-linux/xsa
sed -i -E \
  -e 's/^int (ps7_init|ps7_post_config|ps7_debug)\(\);/int \1(void);/' \
  -e 's/^void perf_reset_and_start_timer\(\); ?/void perf_reset_and_start_timer(void);/' \
  ps7_init_gpl.h
sed -i -E \
  -e 's/^ps7GetSiliconVersion \(\) \{/ps7GetSiliconVersion (void) {/' \
  -e 's/^(ps7_post_config|ps7_debug|ps7_init)\(\) ?$/\1(void)/' \
  -e 's/^void perf_reset_and_start_timer\(\) ?$/void perf_reset_and_start_timer(void)/' \
  ps7_init_gpl.c
```

---

## 3. The device tree

A ready-made device tree for this board lives in the repo:
**[`linux/zynq-zynqmini.dts`](../linux/zynq-zynqmini.dts)**.

It is hand-adapted from mainline `zynq-zed.dts` (Avnet ZedBoard — same SoC, same
512 MB DDR3, same GEM0-RGMII / UART1-console layout), with the deltas for this
board: on-board eMMC on `sdhci1`, the RTL8211E PHY at MDIO address 0, the PS
LED/button on MIO 9/0, and the `axi_regs` UIO node at `0x4000_0000`. It
`#include`s `xilinx/zynq-7000.dtsi` from the kernel tree, so it only compiles
inside a kernel build (Buildroot handles that in step 5).

Nothing to do here unless you change the PS7 config. If you do, regenerate the
base with the Xilinx DTG and re-apply the deltas:

```bash
cd ~/dev/zynqmini-linux
git clone -b xlnx_rel_v2024.2 https://github.com/Xilinx/device-tree-xlnx
/mnt/d/Xilinx/Vitis/2024.2/bin/xsct <<'EOF'
hsi open_hw_design xsa/arm_fpga_zynq_mini.xsa
hsi set_repo_path  device-tree-xlnx
hsi create_sw_design dt -os device_tree -proc ps7_cortexa9_0
hsi generate_target -dir dts
EOF
```

---

## 4. Buildroot: start from `zynq_zed_defconfig`

```bash
cd ~/dev/zynqmini-linux
git clone https://git.buildroot.net/buildroot
cd buildroot
git checkout 2026.02        # or current master; ZedBoard support tracks the Xilinx release
```

Buildroot has no entry for this exact board, but **`zynq_zed_defconfig`** is a
close match — same XC7Z020, same 512 MB DDR3 — and it already wires up the whole
modern Zynq flow: Bootlin ARMv7 glibc toolchain, `linux-xlnx` + `xilinx_zynq`
defconfig → `uImage`, `u-boot-xlnx` `xilinx_zynq_virt` + SPL (no FSBL), and the
shared `board/zynq/` image scripts (`genimage.cfg` → `sdcard.img`,
`extlinux.conf` with `console=ttyPS0,115200 root=/dev/mmcblk0p2`).

Only three things are board-specific: the **PS7 init** (DDR/clock/MIO — from
*your* `.xsa`), the **kernel device tree**, and the U-Boot proper DT name.

```bash
cp configs/zynq_zed_defconfig configs/zynqmini_defconfig
```

---

## 5. Buildroot: apply the board-specific settings

Edit `configs/zynqmini_defconfig`. Starting from the ZedBoard config, **change**:

```make
# --- kernel device tree: use this repo's DTS -----------------------------
# (was: BR2_LINUX_KERNEL_INTREE_DTS_NAME="xilinx/zynq-zed")
BR2_LINUX_KERNEL_INTREE_DTS_NAME="zynq-zynqmini"
BR2_LINUX_KERNEL_CUSTOM_DTS_PATH="/home/jari/dev/zynq_mini_example_project/linux/zynq-zynqmini.dts"

# --- U-Boot SPL PS7 init: use the ps7_init_gpl.c from step 2 -------------
BR2_TARGET_UBOOT_ZYNQ=y
BR2_TARGET_UBOOT_ZYNQ_PS7_INIT_FILE="/home/jari/dev/zynqmini-linux/xsa/ps7_init_gpl.c"

# --- extras for the JTAG path (step 9); harmless for the SD path --------
BR2_TARGET_UBOOT_FORMAT_ELF=y      # -> output/images/u-boot  (ELF)
BR2_TARGET_ROOTFS_CPIO=y           # keep EXT2 on too -> sdcard.img still built
BR2_TARGET_ROOTFS_CPIO_GZIP=y
BR2_TARGET_ROOTFS_CPIO_UIMAGE=y    # -> output/images/rootfs.cpio.uboot
```

- `BR2_LINUX_KERNEL_CUSTOM_DTS_PATH` copies `zynq-zynqmini.dts` into the kernel
  tree; `..._INTREE_DTS_NAME` set to the same basename makes `board/zynq/`'s
  `post-image.sh` create the `system.dtb` symlink that `extlinux.conf` loads.
- Buildroot passes the PS7 file to U-Boot as `CONFIG_XILINX_PS_INIT_FILE`
  (absolute path, resolved with `readlink -f`). `ps7_init_gpl.h` must sit next to
  the `.c` — it does, both came out of the `.xsa` in step 2.
- Leave `BR2_TARGET_UBOOT_CUSTOM_MAKEOPTS="DEVICE_TREE=zynq-zed"` as-is. U-Boot
  *proper* only needs UART1 + SD to load the kernel (DDR is already up from the
  SPL's PS7 init), and `zynq-zed` describes both correctly. The GEM PHY node
  would be wrong, but SD boot doesn't use Ethernet.

Then:

```bash
cd ~/dev/zynqmini-linux/buildroot
make zynqmini_defconfig
make menuconfig            # optional: add packages (dropbear, etc.)
```

> **eMMC vs microSD.** `extlinux.conf` roots on `/dev/mmcblk0p2`. On this board
> the controller probe order usually makes the microSD `mmcblk0` — verify on
> first boot (`cat /proc/partitions`) and, if the eMMC comes up first, either
> swap to `mmcblk1p2` in a custom `extlinux.conf` or disable `&sdhci1` in the
> DTS while you bring the card up.

---

## 6. Build

```bash
cd ~/dev/zynqmini-linux/buildroot
make -j"$(nproc)"
```

> **WSL:** Buildroot aborts with *"Your PATH contains spaces, TABs, and/or
> newline characters"* because WSL injects the Windows `PATH`. Run the build
> with a clean environment:
> ```bash
> env -i HOME="$HOME" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
>     TERM=xterm bash -c 'cd ~/dev/zynqmini-linux/buildroot && make -j$(nproc)'
> ```

First build ~30–90 min (it builds a toolchain, U-Boot, the kernel and a rootfs;
downloads from `ftpmirror.gnu.org` may 502 and retry — harmless). Results land in
`output/images/`:

```
output/images/
 ├─ boot.bin              (U-Boot SPL — runs your ps7_init, then loads u-boot.img)
 ├─ u-boot.img            (SD path)
 ├─ u-boot                (ELF — JTAG path)
 ├─ uImage                (Linux 6.18-xilinx, load 0x8000)
 ├─ zynq-zynqmini.dtb
 ├─ system.dtb            -> zynq-zynqmini.dtb (symlink, what extlinux loads)
 ├─ rootfs.ext4           (-> rootfs.ext2)      SD path
 ├─ rootfs.cpio.uboot     (ramdisk uImage)      JTAG path
 └─ sdcard.img            (32M FAT32 boot + 60M ext4 rootfs — flash this)
```

Verified with Buildroot **2026.08**: `boot.bin` is a valid Zynq image
(`0xaa995566` / `XNLX`), `uImage` is Linux 6.18.10-xilinx at load `0x8000`, and
`zynq-zynqmini.dtb` carries the `axi_regs@40000000` UIO node.

---

## 7. Write the SD card

```bash
lsblk                                   # find the card, e.g. /dev/sdX  (NOT a partition)
sudo dd if=output/images/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

WSL: attach the reader with `usbipd attach --wsl --busid <id>` first, or write
the image from Windows with Rufus / balenaEtcher / `Win32DiskImager`.

Set the board's **3-position boot switch to SD**.

---

## 8. Boot

1. Serial terminal: `picocom -b 115200 /dev/ttyUSB0`
2. Power on. Expected sequence:

```
U-Boot SPL 2026.01 ...
U-Boot 2026.01 ...
Hit any key to stop autoboot: 0
Retrieving file: /extlinux/extlinux.conf
1:    linux
Retrieving file: /uImage
Retrieving file: /system.dtb
Starting kernel ...
[    0.000000] Booting Linux on physical CPU 0x0
...
macb e000b000.ethernet eth0: Cadence GEM rev 0x00020118 at 0xe000b000 irq ...
libphy: MACB_mii_bus: probed
Realtek RTL8211E ... eth0: Link is Up - 1Gbps/Full
...
Welcome to Buildroot
buildroot login: root
```

- **Nothing prints at all** → boot switch not on SD, or the SPL's PS7 init is
  wrong/missing (`BR2_TARGET_UBOOT_ZYNQ_PS7_INIT_FILE` unset → non-functional
  `boot.bin`).
- **U-Boot banner but "Retrieving file" fails** → FAT partition has no
  `extlinux/extlinux.conf`, or `system.dtb` symlink missing (check
  `INTREE_DTS_NAME` matches the DTS basename).
- **Kernel starts then panics "unable to mount root"** → `mmcblk0` vs `mmcblk1`
  ordering; see the eMMC note in step 5.

---

## 9. Fast iteration over JTAG (no card swapping)

The `zynqmini_defconfig` here already enables `BR2_TARGET_UBOOT_FORMAT_ELF=y`
(→ `output/images/u-boot`, an ELF, entry `0x0400_0000`) and the ramdisk
(`BR2_TARGET_ROOTFS_CPIO` + `_GZIP` + `_UIMAGE` → `rootfs.cpio.uboot`, a
`-T ramdisk` uImage). With those plus `uImage` and `zynq-zynqmini.dtb`, load
everything into DDR over the on-board JTAG (cf. [`notes.md`](notes.md) → Habr
[835912](https://habr.com/ru/companies/timeweb/articles/835912/)):

```tcl
cd ~/dev/zynqmini-linux/buildroot/output/images
connect
targets -set -filter {name =~ "*Cortex-A9 #0"}
rst -system
source ~/dev/zynqmini-linux/xsa/ps7_init.tcl ; ps7_init ; ps7_post_config
dow            u-boot                              ;# ELF, self-locating
dow -data      uImage             0x08000000
dow -data      rootfs.cpio.uboot  0x0c000000
dow -data      zynq-zynqmini.dtb  0x0e000000
con
```

Stop autoboot, then in U-Boot:

```
bootm 0x08000000 0x0c000000 0x0e000000
```

(Addresses kept well clear of U-Boot's load/relocation area. `uImage` carries
load `0x8000`, so `bootm` relocates the kernel down itself.)

---

## 10. Loading the bitstream / using `axi_regs` from Linux

The PL is not needed to boot. To use `axi_regs` (at `0x4000_0000`, signature
`0x5A5A_1234`) you must configure the PL first:

```bash
# convert once, on the build host:
#   bootgen -image fpga.bif -arch zynq -process_bitstream bin   (fpga.bif lists the .bit)
# then on the target:
mkdir -p /lib/firmware
cp arm_fpga_zynq_mini.bit.bin /lib/firmware/
fpgautil -b /lib/firmware/arm_fpga_zynq_mini.bit.bin        # or echo to /sys/class/fpga_manager

devmem2 0x4000001C          # -> 0x5A5A1234
devmem2 0x40000000 w 0x12340000
devmem2 0x40000004 w 0x0000ABCD
devmem2 0x40000014         # SUM -> 0x1234ABCD
```

See [`notes.md`](notes.md) → Habr [1052912](https://habr.com/ru/articles/1052912/)
for the FPGA-manager route, and the `axi_regs` section there for the UIO node.

---

## Version matrix

| Component | Version | Config |
|---|---|---|
| Vivado / Vitis | 2024.2 | — |
| Buildroot | 2026.02 / master | `zynqmini_defconfig` (from `zynq_zed_defconfig`) |
| linux-xlnx | whatever the Buildroot Zynq defconfig pins (6.18 LTS series) | `xilinx_zynq` defconfig, `uImage`, load `0x8000` |
| u-boot-xlnx | ditto (v2026.01 series) | `xilinx_zynq_virt` + SPL |
| device-tree-xlnx | `xlnx_rel_v2024.2` (only if regenerating the DTS) | `-os device_tree -proc ps7_cortexa9_0` |

The kernel and U-Boot versions come straight from `zynq_zed_defconfig` — don't
override them unless you have a reason; the ZedBoard config keeps them matched.

## References

All Habr links, the YADRO series, the Xilinx EDT tutorial and the Z-Turn /
Zybo-Z7-20 from-scratch repos are collected in [`notes.md`](notes.md).
The FSBL + `bootgen` (instead of U-Boot SPL) alternative is Xilinx
[Zynq7000 EDT, Ch. 7](https://xilinx.github.io/Embedded-Design-Tutorials/docs/2023.1/build/html/docs/Introduction/Zynq7000-EDT/7-linux-booting-debug.html).
