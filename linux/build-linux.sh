#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# build-linux.sh - one-shot Buildroot Linux image for the Zynq Mini board.
#
# Runs the whole flow from doc/linux_build.md:
#   1. FPGA .xsa/.bit           (scripts/build.tcl, only if missing)
#   2. ps7_init_gpl.{c,h}       (unzip from the .xsa + patch K&R prototypes)
#   3. Buildroot checkout       (pinned, shallow clone)
#   4. rootfs overlay           (S95fpga -> fpgautil loads the PL at boot)
#   5. configs/zynqmini_defconfig  (zynq_zed_defconfig + board-specific deltas)
#   6. make                     (clean PATH so Buildroot tolerates WSL)
#
# Outputs: <build dir>/buildroot/output/images/
#   sdcard.img            - dd to a card, boot switch = SD
#   u-boot uImage zynq-zynqmini.dtb rootfs.cpio.uboot - JTAG path (step 9)
#
# Overridable via env:
#   LINUX_BUILD_DIR   where Buildroot lives   (default: <repo>/../zynqmini-linux)
#   BUILDROOT_VERSION git tag                 (default: 2026.08)
#   JOBS             make -j                  (default: nproc)
#   SKIP_FPGA=1      don't run ./build.sh even if the .xsa is missing
#-----------------------------------------------------------------------------
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LINUX_BUILD_DIR:=$(dirname "$REPO")/zynqmini-linux}"
: "${BUILDROOT_VERSION:=2026.08}"
: "${BUILDROOT_URL:=https://git.buildroot.net/buildroot}"
: "${JOBS:=$(nproc)}"
: "${SKIP_FPGA:=0}"

PROJECT=arm_fpga_zynq_mini
XSA="$REPO/output/$PROJECT.xsa"
BIT="$REPO/output/$PROJECT.bit"
DTS="$REPO/linux/zynq-zynqmini.dts"
BR="$LINUX_BUILD_DIR/buildroot"
XDIR="$LINUX_BUILD_DIR/xsa"
OV="$LINUX_BUILD_DIR/overlay"
PS7C="$XDIR/ps7_init_gpl.c"
PS7H="$XDIR/ps7_init_gpl.h"
CLEAN_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

#--- 0. host prerequisites --------------------------------------------------
missing=
for t in git make gcc g++ wget cpio unzip rsync bc flex bison perl file which; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
[ -z "$missing" ] || die "missing host tools:$missing"

#--- 1. FPGA hardware -> .xsa / .bit --------------------------------------
if [ ! -f "$XSA" ] || [ ! -f "$BIT" ]; then
    [ "$SKIP_FPGA" = 1 ] && die "no $XSA - run ./build.sh first (or unset SKIP_FPGA)"
    log "No .xsa/.bit yet - running the Vivado build (./build.sh)"
    ( cd "$REPO" && ./build.sh )
fi
[ -f "$XSA" ] && [ -f "$BIT" ] || die "FPGA build did not produce $XSA / $BIT"

#--- 2. ps7_init out of the .xsa, patch K&R prototypes -------------------
log "Extracting ps7_init_gpl.{c,h} + ps7_init.tcl from the .xsa"
mkdir -p "$XDIR"
( cd "$XDIR" && unzip -o "$XSA" ps7_init_gpl.c ps7_init_gpl.h ps7_init.tcl >/dev/null )

if grep -q '^int ps7_init();' "$PS7H"; then
    log "Patching K&R prototypes (Vivado emits foo(); U-Boot SPL wants foo(void))"
    sed -i -E \
      -e 's/^int (ps7_init|ps7_post_config|ps7_debug)\(\);/int \1(void);/' \
      -e 's/^void perf_reset_and_start_timer\(\); ?/void perf_reset_and_start_timer(void);/' \
      "$PS7H"
    sed -i -E \
      -e 's/^ps7GetSiliconVersion \(\) \{/ps7GetSiliconVersion (void) {/' \
      -e 's/^(ps7_post_config|ps7_debug|ps7_init)\(\) ?$/\1(void)/' \
      -e 's/^void perf_reset_and_start_timer\(\) ?$/void perf_reset_and_start_timer(void)/' \
      "$PS7C"
fi

#--- 3. Buildroot checkout ---------------------------------------------
if [ ! -d "$BR" ]; then
    log "Cloning Buildroot $BUILDROOT_VERSION"
    git clone --depth 1 --branch "$BUILDROOT_VERSION" "$BUILDROOT_URL" "$BR"
else
    log "Buildroot already at $BR ($(git -C "$BR" describe --tags --always 2>/dev/null || echo '?'))"
fi
[ -f "$BR/configs/zynq_zed_defconfig" ] || die "$BR has no zynq_zed_defconfig - wrong/old Buildroot?"

#--- 4. rootfs overlay: load the PL bitstream at boot -------------------
log "Writing rootfs overlay ($OV)"
mkdir -p "$OV/rootfs/etc/init.d"
cat > "$OV/rootfs/etc/init.d/S95fpga" <<'EOS'
#!/bin/sh
# Configure the PL via the Zynq FPGA manager so axi_regs (0x40000000) is live.
BIT=/lib/firmware/arm_fpga_zynq_mini.bit
case "$1" in
	start)
		[ -f "$BIT" ] || { echo "PL: no $BIT, skipping"; exit 0; }
		printf 'PL: loading %s ... ' "$(basename "$BIT")"
		fpgautil -b "$BIT" >/dev/null 2>&1 && echo ok || echo FAILED ;;
	stop|restart|reload) ;;
	*) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
EOS
chmod +x "$OV/rootfs/etc/init.d/S95fpga"

cat > "$OV/copy-bitstream.sh" <<EOS
#!/bin/sh
# Buildroot POST_BUILD hook (\$1 = TARGET_DIR): stage the bitstream into the rootfs.
set -e
if [ -f "$BIT" ]; then
	install -D -m 0644 "$BIT" "\$1/lib/firmware/arm_fpga_zynq_mini.bit"
	echo "post-build: staged \$(basename "$BIT") -> /lib/firmware"
else
	echo "post-build: WARNING $BIT missing - PL will not auto-load" >&2
fi
EOS
chmod +x "$OV/copy-bitstream.sh"

#--- 5. defconfig: zynq_zed_defconfig + board deltas -------------------
log "Generating configs/zynqmini_defconfig"
DEF="$BR/configs/zynqmini_defconfig"
sed -E \
  -e 's|^BR2_LINUX_KERNEL_INTREE_DTS_NAME=.*|BR2_LINUX_KERNEL_INTREE_DTS_NAME="zynq-zynqmini"|' \
  -e "s|^BR2_ROOTFS_POST_BUILD_SCRIPT=.*|BR2_ROOTFS_POST_BUILD_SCRIPT=\"board/zynq/post-build.sh $OV/copy-bitstream.sh\"|" \
  "$BR/configs/zynq_zed_defconfig" > "$DEF"
cat >> "$DEF" <<EOS
BR2_LINUX_KERNEL_CUSTOM_DTS_PATH="$DTS"
BR2_TARGET_UBOOT_ZYNQ=y
BR2_TARGET_UBOOT_ZYNQ_PS7_INIT_FILE="$PS7C"
BR2_TARGET_UBOOT_FORMAT_ELF=y
BR2_TARGET_ROOTFS_CPIO=y
BR2_TARGET_ROOTFS_CPIO_GZIP=y
BR2_TARGET_ROOTFS_CPIO_UIMAGE=y
BR2_ROOTFS_OVERLAY="$OV/rootfs"
EOS

#--- 6. build (clean PATH: Buildroot rejects the WSL Windows PATH) ------
log "make zynqmini_defconfig && make -j$JOBS"
env -i HOME="$HOME" PATH="$CLEAN_PATH" TERM="${TERM:-xterm}" \
    bash -c "cd '$BR' && make zynqmini_defconfig && make -j$JOBS"

#--- done ------------------------------------------------------------
IMG="$BR/output/images"
[ -f "$IMG/sdcard.img" ] || die "build finished but $IMG/sdcard.img is missing"
log "Done. Images in $IMG/"
( cd "$IMG" && ls -la sdcard.img boot.bin u-boot uImage zynq-zynqmini.dtb rootfs.cpio.uboot 2>/dev/null )
cat <<EOS

  SD boot :  sudo dd if=$IMG/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
             boot switch = SD
  console :  115200 8N1 on UART1 (MIO 48/49),  login: root  (no password)
  JTAG    :  see doc/linux_build.md section 9
EOS
