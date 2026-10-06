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

## TL;DR — one script

[`linux/build-linux.sh`](../linux/build-linux.sh) runs steps 1–8 below
(idempotent — re-run it any time):

```bash
./linux/build-linux.sh
#   env knobs: LINUX_BUILD_DIR, BUILDROOT_VERSION, JOBS, SKIP_FPGA=1
```

It builds the `.xsa` if missing, extracts and patches `ps7_init_gpl.*`, clones
Buildroot, writes the overlay + `configs/zynqmini_defconfig`, and `make`s — into
`$LINUX_BUILD_DIR/buildroot/output/images/` (default `../zynqmini-linux`). The
rest of this doc is what it does, step by step.

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

# --- auto-load the PL bitstream at boot (step 10) ----------------------
BR2_ROOTFS_OVERLAY="<abs>/board/zynqmini/overlay/rootfs"
BR2_ROOTFS_POST_BUILD_SCRIPT="board/zynq/post-build.sh <abs>/board/zynqmini/overlay/copy-bitstream.sh"

# --- network: DHCP on eth0 + SSH (dropbear) ----------------------------
BR2_SYSTEM_DHCP="eth0"
BR2_PACKAGE_DROPBEAR=y
BR2_PACKAGE_DROPBEAR_DISABLE_REVERSEDNS=y   # no DNS on the LAN -> no slow logins
```

**SSH is key-only.** root has no password, and dropbear refuses blank passwords
(unless started with `-B`), so password login over the network is impossible.
`build-linux.sh` puts your public key(s) (`SSH_PUBKEYS`, default `~/.ssh/*.pub`)
into the overlay as `/root/.ssh/authorized_keys`; then `ssh root@<board-ip>`.
Host keys are generated on first boot and kept in `/etc/dropbear` (rootfs is rw).

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
dow -data      ../build/uboot-custom/u-boot.dtb  0x00100000  ;# U-Boot's OWN DT - the ELF has none
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

A JTAG-loaded U-Boot ELF reads its device tree from `0x100000`
(`CONFIG_XILINX_OF_BOARD_DTB_ADDR`); without that `dow` it has no DT and hangs.
`u-boot.dtb` is U-Boot's `zynq-zed` tree from the build dir, not the kernel's.

(Addresses kept well clear of U-Boot's load/relocation area. `uImage` carries
load `0x8000`, so `bootm` relocates the kernel down itself.)

---

## 10. Loading the bitstream at boot / using `axi_regs` from Linux

The PL is not needed to boot, but `axi_regs` (`0x4000_0000`, `SIGNATURE`
`0x5A5A_1234`) is dark until the PL is configured. The kernel has
`FPGA_MGR_ZYNQ_FPGA` + `FPGA_MGR_ZYNQ_AFI_FPGA` built in (the AFI part also
brings the PS↔PL AXI ports up), and `fpgautil` is in the rootfs
(`BR2_PACKAGE_XILINX_FPGAUTIL`, inherited from `zynq_zed_defconfig`).

### Auto-load at boot (both SD and JTAG)

A rootfs overlay stages the bitstream and a BusyBox init script loads it:

```
<build dir>/overlay/
├─ rootfs/etc/init.d/S95fpga  # fpgautil -b /lib/firmware/arm_fpga_zynq_mini.bit.bin
└─ copy-bitstream.sh          # POST_BUILD hook: output/*.bit -> linux/bit2bin.py -> /lib/firmware/*.bit.bin
```

**The FPGA manager needs a `.bin`, not the `.bit`.** Fed the raw Vivado `.bit`,
the Zynq FPGA manager fails with `write init error: 0xffffffea` (`-EINVAL`) and
the PL stays unconfigured (found on hardware). It wants the configuration data
with the `.bit` header stripped and every 32-bit word byte-swapped.
[`linux/bit2bin.py`](../linux/bit2bin.py) does that in pure Python, with output
byte-identical to `bootgen -arch zynq -process_bitstream bin`, so the build
doesn't need Vitis. `build-linux.sh` writes both scripts; `S95fpga`:

```sh
BIT=/lib/firmware/arm_fpga_zynq_mini.bit.bin
fpgautil -b "$BIT" && [ "$(cat /sys/class/fpga_manager/fpga0/state)" = operating ]  # -> "ok" / "FAILED (<state>)"
```

defconfig:
```make
BR2_ROOTFS_OVERLAY="<build dir>/overlay/rootfs"
BR2_ROOTFS_POST_BUILD_SCRIPT="board/zynq/post-build.sh <build dir>/overlay/copy-bitstream.sh"
```

The `.bin` lands in **both** `rootfs.ext4` (SD) and `rootfs.cpio.uboot` (JTAG), so
the PL comes up ~2 s into userspace either way. Check it with
`cat /sys/class/fpga_manager/fpga0/state` → `operating`.

> **Never read `0x4000_0000` while the PL isn't `operating`.** With no design
> behind `M_AXI_GP0` the read never completes and the whole SoC hangs (this
> happened during bring-up; only a JTAG `rst -system` or a power cycle recovers).
> `fpga-webstream` checks the state and `SIGNATURE` before it touches anything.

### Load it earlier, from U-Boot (optional)

U-Boot here has `CMD_FPGA` + `FPGA_ZYNQPL`; `fpga loadb` also eats the raw
`.bit`. The extlinux parser has no `fpga` directive, so this needs a `boot.scr`
(and dropping `extlinux.conf`) or a custom `CONFIG_BOOTCOMMAND`:
```
fatload mmc 0:1 0x02000000 arm_fpga_zynq_mini.bit && fpga loadb 0 0x02000000 ${filesize}
```

### Poke it

```bash
devmem2 0x4000001C          # -> 0x5A5A1234   (SIGNATURE)
devmem2 0x40000000 w 0x12340000
devmem2 0x40000004 w 0x0000ABCD
devmem2 0x40000014         # -> 0x1234ABCD   (SUM, computed in the PL)
devmem2 0x40000010         # HEARTBEAT, changes every read
```

See [`notes.md`](notes.md) → Habr [1052912](https://habr.com/ru/articles/1052912/)
for the FPGA-manager / `fpga-region` route and the `axi_regs` UIO node.

---

## 11. Reflash the SD card in the board over TFTP

Rewrite the microSD without taking it out: U-Boot is loaded over JTAG, pulls
`sdcard.img` from a TFTP server into RAM, writes it to `mmc 0`, reads it back and
compares, then boots the fresh card.

**Once per build** (WSL) — fills `build_tftp/` (gitignored):

```bash
./linux/reflash-sd.sh <pc-ip>                # board uses DHCP
./linux/reflash-sd.sh <pc-ip> <board-ip>     # or a static board IP
```

and serve `build_tftp/` over TFTP (UDP 69): on Windows Tftpd64 with its directory
set to the `\\wsl.localhost\...\build_tftp` path the script prints; or
`tftpd-hpa` inside WSL, which needs `networkingMode=mirrored` in `.wslconfig`
(WSL2's default NAT hides it from the LAN).

**Per card:** boot switch = **JTAG**, card in, Ethernet cable in, power on, then
on Windows:

```
linux\reflash_sd.bat          :: set XSCT=...\xsct.bat if xsct is not on PATH
```

`reflash_sd.tcl` checks the boot mode register (refuses unless JTAG), runs
`ps7_init`, loads `u-boot.dtb` @`0x100000`, `reflash.scr` @`0x3000000`
(`${scriptaddr}`) and the U-Boot ELF. In JTAG boot mode U-Boot's distro boot runs
`bootcmd_jtag` = `source ${scriptaddr}`, so the reflash starts on its own. The
serial console (115200 8N1) shows:

```
================ reflash microSD (mmc 0) from TFTP ================
reflash: tftp <pc-ip>:sdcard.img -> 0x08000000
reflash: writing 0x2e001 blocks to mmc 0 ...
reflash: reading back to verify ...
Total of 24117504 word(s) were the same
================ reflash: DONE - booting the new card ================
```

The script disables the `jtag`/`pxe`/`dhcp` boot targets after it runs, so on
success distro boot continues to `mmc0` and boots the new image right away. On
any failure it disables the rest too and stops at the U-Boot prompt. Set the
switch back to SD for normal power-ups.

Already at a U-Boot prompt on a board that boots (switch = SD)? Same script, one line:

```
setenv autoload no; dhcp; tftpboot ${scriptaddr} <pc-ip>:reflash.scr; source ${scriptaddr}
```

RAM buffers: image @`0x08000000`, read-back @`0x10000000`, so images up to
128 MB (today's is 96 MB).

---

## 12. Live PL data in the browser (`fpga-webstream`)

`http://<board-ip>/` shows a live chart of data read from the PL. Step 1 streams
the existing `axi_regs` `HEARTBEAT` counter (`0x4000_0010`, +1 per 100 MHz AXI
clock). The page plots the raw counter (a sawtooth that wraps every ~43 s) and
the PL clock measured from it (ΔHEARTBEAT/Δt ≈ 100 MHz), which exercises the
whole path end to end.

```
PL axi_regs ──GP0──► /dev/uioN (mmap) ──► fpga-webstream ──SSE──► browser
                                           sampler 200 Hz,           canvas chart,
                                           20 batches/s              last 10 s
```

- **Server:** `linux/fpga-webstream/` — C, on the civetweb library (Buildroot
  `BR2_PACKAGE_CIVETWEB_LIB`, MIT). The page (`index.html`) is compiled into the
  binary (`page.S` `.incbin`); the board needs no internet. Endpoints:
  `/` (page), `/events` (Server-Sent Events), `/api/status` (JSON).
- **Why SSE, not WebSocket:** Buildroot's civetweb is built without WebSocket
  support, and a display-only stream doesn't need it. SSE is plain HTTP and
  `EventSource` reconnects on its own. Controls can be added as HTTP POSTs.
- **Package:** `BR2_EXTERNAL` tree `linux/br2-external/` (`fpga-webstream`,
  `S97fpga-webstream` init script — after `S95fpga` loads the PL).
  `build-linux.sh` passes `BR2_EXTERNAL` and enables it.
- **UIO binding:** the DTS node `axi_regs@40000000` is `compatible =
  "generic-uio"`; the built-in `uio_pdrv_genirq` only binds it with
  `uio_pdrv_genirq.of_id=generic-uio` on the kernel command line. SD boot gets
  it from `extlinux.conf` (appended by the post-build hook), the JTAG/`bootm`
  path from the DTS `chosen/bootargs`.
- **Bus safety:** registers are read only while
  `/sys/class/fpga_manager/fpga0/state` is `operating` *and* `SIGNATURE` reads
  `0x5A5A1234` (a GP0 read with no PL design can stall the bus). Otherwise the
  page shows *PL: not configured* and the server re-checks every sample.

On the board:

```sh
/etc/init.d/S97fpga-webstream restart     # start/stop/restart
logread | grep fpga-webstream             # its log (syslog)
ls /sys/class/uio/                        # uio0 -> name "axi_regs"
curl http://127.0.0.1/api/status
```

Try it on a PC without the board (fakes a 100 MHz counter): build
`main.c page.S` against civetweb's `src/civetweb.c` (`-DNO_SSL`), then
`FPGA_WEBSTREAM_SIM=1 ./fpga-webstream -p 8088 -f` and open
`http://localhost:8088/`.

---

## 13. Update a running board over SSH (no reflash)

For day-to-day changes, push only what changed to a board that's up on the network:

```bash
./linux/update-board.sh <board-ip>              # kernel + dtb + bitstream + web server
./linux/update-board.sh <board-ip> bit web      # just some parts: kernel dtb bit web all
./linux/update-board.sh --no-reboot <board-ip>  # new kernel/dtb wait for the next boot
./linux/update-board.sh --new-hostkey <ip>      # after reflashing (dropbear made a new host key)
```

| part | from | to | then |
|---|---|---|---|
| `kernel` | `output/images/uImage` | SD p1 `/uImage` | reboot |
| `dtb` | `output/images/zynq-zynqmini.dtb` | SD p1 `/system.dtb` | reboot |
| `bit` | `output/arm_fpga_zynq_mini.bit` → `bit2bin.py` | `/lib/firmware/*.bit.bin` | web server stopped, PL reloaded, restarted |
| `web` | `fpga-webstream` | `/usr/bin/` | service restarted |

- Unchanged files (same md5 on the board) are skipped; the board reboots only if
  the kernel or dtb actually changed.
- Copies go through `ssh … 'cat > file.new'`, are md5-checked, then renamed into
  place: atomic, and safe for a running binary. No `scp`: recent OpenSSH `scp`
  uses SFTP, which dropbear doesn't provide.
- The PL is never reprogrammed while `fpga-webstream` is reading it over GP0.
- Uses the key `build-linux.sh` baked in; host keys go to
  `$LINUX_BUILD_DIR/known_hosts`, not `~/.ssh`.
- Refuses kernel/dtb updates on a JTAG/initramfs boot (there's no SD root).

New packages or changes elsewhere in the rootfs still need a full reflash (§11).

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
