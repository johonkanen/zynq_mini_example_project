#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# update-board.sh - push freshly built parts to a running board over SSH,
# without reflashing the SD card.
#
#   ./linux/update-board.sh [options] <board-ip> [part...]
#
# parts (default: all):
#   kernel   output/images/uImage            -> SD boot partition  /uImage
#   dtb      output/images/zynq-zynqmini.dtb -> SD boot partition  /system.dtb
#   bit      output/arm_fpga_zynq_mini.bit   -> /lib/firmware/*.bit.bin (via bit2bin.py), PL reloaded now
#   fpgad    fpgad + fpgactl + oled-status   -> /usr/sbin, /usr/bin, /etc/init.d; restarted
#   web      fpga-web + libcivetweb          -> /usr/bin, /usr/lib; service restarted
#   all      all of the above
#
# Unchanged files (same md5 as on the board) are skipped. The board reboots
# afterwards only if the kernel or the dtb actually changed. (Soft reboots work
# as long as the image has S01multiboot - see doc/linux_build.md.)
#
# options:
#   --no-reboot     don't reboot (new kernel/dtb take effect on the next boot)
#   --new-hostkey   forget the board's old SSH host key first (do this after
#                   reflashing the card: dropbear makes a new key on 1st boot)
#
# Needs the SSH key that build-linux.sh baked into the image (root login is
# key-only). Host keys are kept in <build dir>/known_hosts, not ~/.ssh.
# Rootfs-wide changes (new packages, /etc) need a reflash: doc §11.
#
# Env: LINUX_BUILD_DIR (default <repo>/../zynqmini-linux)
#-----------------------------------------------------------------------------
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LINUX_BUILD_DIR:=$(dirname "$REPO")/zynqmini-linux}"
BR="$LINUX_BUILD_DIR/buildroot/output"
KNOWN="$LINUX_BUILD_DIR/known_hosts"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

reboot_ok=1 forget=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-reboot)   reboot_ok=0; shift ;;
        --reboot)      reboot_ok=1; shift ;;   # the default; accepted for compatibility
        --new-hostkey) forget=1; shift ;;
        -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
        -*)            die "unknown option $1" ;;
        *)             break ;;
    esac
done
[ $# -ge 1 ] || die "usage: $0 [--no-reboot] [--new-hostkey] <board-ip> [kernel|dtb|bit|fpgad|web|all]..."
BOARD=$1; shift
parts=("${@:-all}")
want() { local p; for p in "${parts[@]}"; do [ "$p" = all ] || [ "$p" = "$1" ] && return 0; done; return 1; }
for p in "${parts[@]}"; do
    case "$p" in kernel|dtb|bit|fpgad|web|all) ;; *) die "unknown part '$p' (kernel dtb bit fpgad web all)" ;; esac
done

mkdir -p "$LINUX_BUILD_DIR"
[ "$forget" = 1 ] && ssh-keygen -q -f "$KNOWN" -R "$BOARD" >/dev/null 2>&1 || true
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new
         -o UserKnownHostsFile="$KNOWN" "root@$BOARD")
rsh() { "${SSH[@]}" "$@"; }

log "connecting to root@$BOARD"
if ! out=$(rsh true 2>&1); then
    echo "$out" >&2
    grep -q 'IDENTIFICATION HAS CHANGED' <<<"$out" &&
        die "host key changed (card reflashed?) - rerun with --new-hostkey"
    die "ssh to root@$BOARD failed (board up? on the network? image built with your key?)"
fi

# boot partition = the SD root partition with p2 -> p1 (JTAG/initramfs boots have no root=)
ROOTDEV=$(rsh "sed -n 's/.* root=\([^ ]*\).*/\1/p' /proc/cmdline")
BOOTDEV=${ROOTDEV%p2}p1
boot_mounted=0
mount_boot() {
    [ "$boot_mounted" = 1 ] && return 0
    case "$ROOTDEV" in /dev/mmcblk*p2) ;; *) die "board did not boot from SD (root='$ROOTDEV') - can't update the boot partition" ;; esac
    rsh "mkdir -p /mnt/boot && mount $BOOTDEV /mnt/boot"
    boot_mounted=1
}
cleanup() { [ "$boot_mounted" = 1 ] && rsh "umount /mnt/boot" || true; }
trap cleanup EXIT

# push <local file> <remote path> [mode] -> 0 if copied, 1 if already identical
push() {
    local src=$1 dst=$2 mode=${3:-644} lsum rsum
    [ -f "$src" ] || die "missing $src - build it first (./linux/build-linux.sh)"
    lsum=$(md5sum "$src" | cut -d' ' -f1)
    rsum=$(rsh "md5sum '$dst' 2>/dev/null | cut -d' ' -f1" || true)
    if [ "$lsum" = "$rsum" ]; then
        echo "   unchanged  $dst"
        return 1
    fi
    # write to a temp name, verify, then rename (atomic; also works for a running binary)
    rsh "cat > '$dst.new'" < "$src"
    rsum=$(rsh "md5sum '$dst.new' | cut -d' ' -f1")
    [ "$lsum" = "$rsum" ] || { rsh "rm -f '$dst.new'"; die "checksum mismatch copying $src"; }
    rsh "chmod $mode '$dst.new' && mv '$dst.new' '$dst' && sync"
    echo "   updated    $dst  ($(stat -c%s "$src") bytes)"
    return 0
}

need_reboot=0

if want kernel || want dtb; then
    mount_boot
    log "boot partition ($BOOTDEV)"
    want kernel && push "$BR/images/uImage"            /mnt/boot/uImage     && need_reboot=1 || true
    want dtb    && push "$BR/images/zynq-zynqmini.dtb" /mnt/boot/system.dtb && need_reboot=1 || true
fi

if want bit; then
    log "FPGA bitstream"
    [ -f "$REPO/output/arm_fpga_zynq_mini.bit" ] || die "missing output/arm_fpga_zynq_mini.bit - run ./build.sh"
    BINTMP=$(mktemp); trap 'rm -f "$BINTMP"; cleanup' EXIT
    python3 "$REPO/linux/bit2bin.py" "$REPO/output/arm_fpga_zynq_mini.bit" "$BINTMP"
    if push "$BINTMP" /lib/firmware/arm_fpga_zynq_mini.bit.bin; then
        # fpgad owns the PL: it blocks all register access while it reprograms.
        # (Images from before fpgad: fall back to the init scripts.)
        rsh 'if command -v fpgactl >/dev/null && fpgactl status >/dev/null 2>&1; then
                 printf "PL: fpgactl load ... "; fpgactl load arm_fpga_zynq_mini.bit.bin
             else
                 /etc/init.d/S97fpga-webstream stop >/dev/null 2>&1; /etc/init.d/S95fpga start
                 /etc/init.d/S97fpga-webstream start >/dev/null 2>&1; true
             fi'
    fi
fi

if want fpgad; then
    log "fpgad + fpgactl"
    push "$BR/target/usr/bin/fpgactl" /usr/bin/fpgactl 755 || true
    if push "$BR/target/usr/sbin/fpgad" /usr/sbin/fpgad 755; then
        rsh "/etc/init.d/S96fpgad restart"    # clients (fpga-web) reconnect on their own
    fi
    # IP + temperature on the OLED (an fpgad client)
    st=0
    push "$BR/target/usr/bin/oled-status" /usr/bin/oled-status 755 && st=1
    push "$BR/target/etc/init.d/S98oled-status" /etc/init.d/S98oled-status 755 && st=1
    [ "$st" = 0 ] || rsh "/etc/init.d/S98oled-status restart"
fi

if want web; then
    log "fpga-web"
    restart=0
    # civetweb with WebSocket support (fpga-web.mk turns it on) for /ws
    lib=$(cd "$BR/target/usr/lib" && ls libcivetweb.so.1.* 2>/dev/null | head -1)
    [ -n "$lib" ] || die "missing $BR/target/usr/lib/libcivetweb.so.1.* - build it first"
    push "$BR/target/usr/lib/$lib" "/usr/lib/$lib" 755 && restart=1
    push "$BR/target/usr/bin/fpga-web" /usr/bin/fpga-web 755 && restart=1
    [ "$restart" = 0 ] || rsh "/etc/init.d/S97fpga-web restart"
fi

if [ "$need_reboot" = 1 ]; then
    if [ "$reboot_ok" = 1 ]; then
        cleanup; boot_mounted=0
        log "kernel/dtb changed - rebooting the board"
        rsh "reboot" || true
    else
        log "kernel/dtb changed - takes effect on the next reboot (--no-reboot)"
    fi
fi
log "done"
