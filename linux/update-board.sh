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
#   pl       output/pl-latest.raucb (or PL_BUNDLE=<file>) -> `rauc install`: signature
#            checked, design trial-loaded by fpgad, kept or rolled back. No reboot.
#            Make the bundle with linux/make-pl-bundle.sh (doc/network_update.md).
#   apps     output/apps-latest.raucb (or APPS_BUNDLE=<file>) -> `rauc install`: our
#            software (fpgad, fpgactl, fpga-web, oled-status) trial-run by appctl, kept
#            or rolled back. No reboot. Make it with linux/make-app-bundle.sh.
#            (fpgad, web: old names for apps)
#   all      kernel dtb pl apps
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
[ $# -ge 1 ] || die "usage: $0 [--no-reboot] [--new-hostkey] <board-ip> [kernel|dtb|pl|apps|all]..."
BOARD=$1; shift
parts=("${@:-all}")
want() { local p; for p in "${parts[@]}"; do [ "$p" = all ] || [ "$p" = "$1" ] && return 0; done; return 1; }
for p in "${parts[@]}"; do
    case "$p" in
        kernel|dtb|pl|apps|all) ;;
        fpgad|web) ;;                         # old names for apps
        bit) die "'bit' is gone: FPGA designs go as signed PL bundles - linux/make-pl-bundle.sh, then 'pl'" ;;
        *) die "unknown part '$p' (kernel dtb pl apps all)" ;;
    esac
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

# a signed bundle -> rauc install; the post-install handler activates it
install_bundle() {   # install_bundle <what> <file>
    rsh 'command -v rauc >/dev/null' || die "no rauc on the board - it needs a newer image (doc/network_update.md)"
    echo "   $(basename "$(readlink -f "$2")")"
    rsh "cat > /tmp/update.raucb" < "$2"
    rsh 'rauc install /tmp/update.raucb; rc=$?; rm -f /tmp/update.raucb; exit $rc' \
        || die "$1 bundle not installed (see above) - the board keeps what it had"
}

if want apps || want fpgad || want web; then
    log "our software (app bundle)"
    bundle=${APPS_BUNDLE:-$REPO/output/apps-latest.raucb}
    [ -f "$bundle" ] || die "no $bundle - run linux/make-app-bundle.sh"
    install_bundle app "$bundle"
    rsh 'appctl status'
fi

if want pl; then
    log "FPGA design (PL bundle)"
    bundle=${PL_BUNDLE:-$REPO/output/pl-latest.raucb}
    [ -f "$bundle" ] || die "no $bundle - run linux/make-pl-bundle.sh"
    install_bundle PL "$bundle"
    rsh 'fpgactl pl'
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
