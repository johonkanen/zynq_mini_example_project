#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# build-linux.sh - one-shot Buildroot Linux image for the Zynq Mini board.
#
# Runs the whole flow from doc/linux_build.md:
#   1. FPGA .xsa/.bit           (scripts/build.tcl, only if missing)
#   2. ps7_init_gpl.{c,h}       (unzip from the .xsa + patch K&R prototypes)
#   3. Buildroot checkout       (pinned, shallow clone)
#   4. rootfs overlay           (RAUC config + keyring, the first FPGA design
#                                in /data/pl/good, root's SSH authorized_keys)
#      + BR2_EXTERNAL linux/br2-external: fpgad (owns the FPGA, loads designs
#        through device-tree overlays) + fpga-web (web UI)
#      + RAUC signing keys, created once in <build dir>/rauc-keys (not in the repo)
#   5. configs/zynqmini_defconfig  (zynq_zed_defconfig + board-specific deltas)
#   6. make                     (clean PATH so Buildroot tolerates WSL)
#
# Outputs: <build dir>/buildroot/output/images/
#   sdcard.img            - dd to a card, boot switch = SD
#   u-boot uImage zynq-zynqmini.dtb rootfs.cpio.uboot - JTAG path (step 9)
# FPGA updates afterwards: linux/make-pl-bundle.sh + update-board.sh pl
#   (doc/network_update.md)
#
# Overridable via env:
#   LINUX_BUILD_DIR   where Buildroot lives   (default: <repo>/../zynqmini-linux)
#   BUILDROOT_VERSION git tag                 (default: 2026.08)
#   JOBS             make -j                  (default: nproc)
#   SKIP_FPGA=1      don't run ./build.sh even if the .xsa is missing
#   SSH_PUBKEYS      public key file(s) allowed to SSH in as root
#                    (default: ~/.ssh/*.pub; the image has no root password,
#                    so without a key SSH login is impossible - serial still works)
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
BR2_EXT="$REPO/linux/br2-external"
XDIR="$LINUX_BUILD_DIR/xsa"
OV="$LINUX_BUILD_DIR/overlay"
PS7C="$XDIR/ps7_init_gpl.c"
PS7H="$XDIR/ps7_init_gpl.h"
CLEAN_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

#--- 0. host prerequisites --------------------------------------------------
missing=
for t in git make gcc g++ wget cpio unzip rsync bc flex bison perl file which openssl python3; do
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
# The PL is loaded by fpgad now (device-tree overlay + bitstream from /data/pl/good,
# doc/network_update.md); the old fpga_manager-sysfs loader is gone.
rm -f "$OV/rootfs/etc/init.d/S95fpga"

# RAUC: config, post-install handler, keyring (the CA certificate only), and the
# directories it expects to exist. /data is a directory on the rootfs for now;
# phase 3 makes it a partition.
KEYS="$LINUX_BUILD_DIR/rauc-keys"
if [ ! -f "$KEYS/signing.key.pem" ]; then
    log "Creating development RAUC signing keys in $KEYS (keep them off the repo)"
    mkdir -p "$KEYS" && chmod 700 "$KEYS"
    ( cd "$KEYS"
      openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -keyout ca.key.pem -out ca.cert.pem \
          -subj "/O=zynq-mini/CN=zynq-mini development CA" \
          -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
      openssl req -newkey rsa:4096 -nodes -keyout signing.key.pem -out signing.csr.pem \
          -subj "/O=zynq-mini/CN=zynq-mini development signing" 2>/dev/null
      printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > leaf.ext
      openssl x509 -req -in signing.csr.pem -CA ca.cert.pem -CAkey ca.key.pem -CAcreateserial \
          -days 3650 -extfile leaf.ext -out signing.cert.pem 2>/dev/null
      rm -f signing.csr.pem leaf.ext
      chmod 600 ca.key.pem signing.key.pem )
fi
mkdir -p "$OV/rootfs/etc/rauc" "$OV/rootfs/usr/lib/rauc" "$OV/rootfs/data/rauc/pl" "$OV/rootfs/data/pl"
cp "$REPO/linux/rauc/system.conf" "$OV/rootfs/etc/rauc/system.conf"
cp "$KEYS/ca.cert.pem" "$OV/rootfs/etc/rauc/keyring.pem"
install -m 0755 "$REPO/linux/rauc/post-install.sh" "$OV/rootfs/usr/lib/rauc/post-install.sh"

# Fixed MAC for eth0, set before networking starts. U-Boot invents a random
# ethaddr on every boot (and patches it into the DT), so the DHCP address kept
# changing - awkward for SSH and for updates. 02:... = locally administered.
# A second board needs its own: put ETHADDR=02:.. in /etc/default/ethaddr.
cat > "$OV/rootfs/etc/init.d/S38ethaddr" <<'EOS'
#!/bin/sh
ETHADDR=02:5a:4d:00:00:01
[ -r /etc/default/ethaddr ] && . /etc/default/ethaddr
case "$1" in
	start)
		ip link set dev eth0 down 2>/dev/null
		ip link set dev eth0 address "$ETHADDR" && echo "eth0: MAC $ETHADDR" ;;
	stop|restart|reload) ;;
	*) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
EOS
chmod +x "$OV/rootfs/etc/init.d/S38ethaddr"

# Zero devcfg.MULTIBOOT_ADDR at boot so a soft reboot always finds BOOT.BIN
# (see the script's header and doc/linux_build.md 'Soft reboot').
cat > "$OV/rootfs/etc/init.d/S01multiboot" <<'EOS'
#!/bin/sh
#
# Zero devcfg.MULTIBOOT_ADDR (0xF800702C) at boot.
#
# The register survives warm resets. After any failed BootROM boot attempt it
# is left non-zero, and from then on every warm reset (reboot, watchdog,
# U-Boot reset) makes the BootROM look for BOOT000<n>.BIN instead of BOOT.BIN
# on the SD card -> REBOOT_STATUS error 0x200A, silent console, and the board
# only comes back after a power cycle. Zeroing it here means "reboot" always
# finds BOOT.BIN again. (A Xilinx FSBL does this job; U-Boot SPL doesn't.)
#
case "$1" in
	start)
		devmem 0xF8007034 32 0x757BDF0D   # devcfg UNLOCK key (harmless if already unlocked)
		mb=$(devmem 0xF800702C 32)
		devmem 0xF800702C 32 0
		[ "$((mb & 0x1FFF))" -ne 0 ] && echo "multiboot: reset MULTIBOOT_ADDR $mb -> 0 (a boot had failed since power-on)"
		exit 0 ;;
	stop|restart|reload) ;;
	*) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
EOS
chmod +x "$OV/rootfs/etc/init.d/S01multiboot"

# SSH: key-only root login (root has no password; dropbear rejects blank
# passwords unless run with -B, so password login over the network stays off)
rm -rf "$OV/rootfs/root/.ssh"
keys=$(ls ${SSH_PUBKEYS:-$HOME/.ssh/*.pub} 2>/dev/null || true)
if [ -n "$keys" ]; then
    mkdir -p "$OV/rootfs/root/.ssh"
    chmod 700 "$OV/rootfs/root" "$OV/rootfs/root/.ssh"
    cat $keys > "$OV/rootfs/root/.ssh/authorized_keys"
    chmod 600 "$OV/rootfs/root/.ssh/authorized_keys"
    echo "SSH: authorized_keys <- $(echo $keys | tr '\n' ' ')"
else
    printf '\033[1;33mWARNING: no SSH public key found (SSH_PUBKEYS / ~/.ssh/*.pub) - SSH login will not work\033[0m\n'
fi

cat > "$OV/copy-bitstream.sh" <<EOS
#!/bin/sh
# Buildroot POST_BUILD hook (\$1 = TARGET_DIR): stage the FPGA design as the
# first "good" design fpgad loads at boot (bitstream + overlay + manifest,
# the same tree a PL bundle installs - linux/make-pl-bundle.sh).
set -e
rm -f "\$1/lib/firmware/arm_fpga_zynq_mini.bit" "\$1/lib/firmware/arm_fpga_zynq_mini.bit.bin"
rm -f "\$1/etc/init.d/S95fpga"      # replaced by fpgad's own boot-time load
rm -rf "\$1/data/pl/good"
if [ -f "$BIT" ]; then
	LINUX_BUILD_DIR="$LINUX_BUILD_DIR" "$REPO/linux/make-pl-bundle.sh" --tree "\$1/data/pl/good"
else
	echo "post-build: WARNING $BIT missing - no FPGA design in the image" >&2
fi
# fpga-webstream was replaced by fpgad + fpga-web: drop its leftovers from an
# existing target tree (Buildroot never removes files of a dropped package)
rm -f "\$1/usr/bin/fpga-webstream" "\$1/etc/init.d/S97fpga-webstream"
# bind the generic-uio axi_regs node to /dev/uioN (fpgad needs it)
EXT="\$BINARIES_DIR/extlinux.conf"
if [ -f "\$EXT" ] && ! grep -q 'uio_pdrv_genirq.of_id' "\$EXT"; then
	sed -i '/^ *append / s/\$/ uio_pdrv_genirq.of_id=generic-uio/' "\$EXT"
	echo "post-build: extlinux.conf += uio_pdrv_genirq.of_id=generic-uio"
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
BR2_SYSTEM_DHCP="eth0"
BR2_PACKAGE_DROPBEAR=y
BR2_PACKAGE_DROPBEAR_DISABLE_REVERSEDNS=y
BR2_PACKAGE_FPGAD=y
BR2_PACKAGE_FPGA_WEB=y
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="$REPO/linux/kernel-rauc.config"
BR2_PACKAGE_RAUC=y
BR2_PACKAGE_HOST_RAUC=y
EOS

#--- 6. build (clean PATH: Buildroot rejects the WSL Windows PATH) ------
log "make zynqmini_defconfig && make -j$JOBS"
env -i HOME="$HOME" PATH="$CLEAN_PATH" TERM="${TERM:-xterm}" \
    bash -c "cd '$BR' && make BR2_EXTERNAL='$BR2_EXT' zynqmini_defconfig && \
             { [ ! -d output/build/ifupdown-scripts ] || make ifupdown-scripts-reinstall; } && \
             { [ ! -f output/images/zynq-zynqmini.dtb ] || [ ! '$DTS' -nt output/images/zynq-zynqmini.dtb ] \
               || make linux-rebuild; } && \
             { ! ls output/build/linux-custom/.config >/dev/null 2>&1 || \
               [ ! '$REPO/linux/kernel-rauc.config' -nt output/build/linux-custom/.config ] \
               || make linux-reconfigure; } && \
             { ! ls output/target/usr/lib/libcivetweb.so.1.* >/dev/null 2>&1 || \
               grep -aq 258EAFA5 output/target/usr/lib/libcivetweb.so.1.* || make civetweb-dirclean; } && \
             { [ ! -d output/build/fpgad-1.0 ] || make fpgad-rebuild; } && \
             { [ ! -d output/build/fpga-web-1.0 ] || make fpga-web-rebuild; } && \
             make -j$JOBS"
# Incremental-build traps handled above (Buildroot never redoes a built package):
#  - ifupdown-scripts writes /etc/network/interfaces from BR2_SYSTEM_DHCP only at
#    install time -> reinstall it
#  - the custom DTS is copied into the kernel tree only during the linux build
#    -> linux-rebuild when the repo DTS is newer than the built .dtb
#  - fpgad / fpga-web are local-source packages -> rebuild to pick up source edits
#  - the kernel config fragment is merged only at configure time -> linux-reconfigure
#    when linux/kernel-rauc.config is newer than the kernel's .config
#  - civetweb built before fpga-web.mk turned on WITH_WEBSOCKET lacks the
#    WebSocket handshake (its RFC 6455 GUID 258EAFA5-...) -> dirclean, rebuilt

#--- done ------------------------------------------------------------
IMG="$BR/output/images"
[ -f "$IMG/sdcard.img" ] || die "build finished but $IMG/sdcard.img is missing"
log "Done. Images in $IMG/"
( cd "$IMG" && ls -la sdcard.img boot.bin u-boot uImage zynq-zynqmini.dtb rootfs.cpio.uboot 2>/dev/null )
cat <<EOS

  SD boot :  sudo dd if=$IMG/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
             boot switch = SD
  console :  115200 8N1 on UART1 (MIO 48/49),  login: root  (no password)
  network :  eth0 via DHCP;  ssh root@<board-ip>  (key auth only)
  web     :  http://<board-ip>/   FPGA registers + live data (fpga-web -> fpgad)
  shell   :  fpgactl regs | read <off> | write <off> <val> | status
  JTAG    :  see doc/linux_build.md section 9
EOS
