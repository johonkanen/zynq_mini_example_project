#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# reflash-over-ssh.sh - write a new sdcard.img to a running board over the
# network, no JTAG and no card swapping (doc/network_update.md, section 1.8).
#
#   ./linux/reflash-over-ssh.sh <board-ip> [<console tty>]
#
# With a console tty (the board's CH340, e.g. /dev/ttyUSB1) the script reads the
# ramdisk's IP address from the serial console if the network scan misses it.
#
# 1. copies the new kernel, dtb and ramdisk rootfs (rootfs.cpio.uboot - the same
#    image, with SSH) to the FAT boot partition and makes them the extlinux
#    default, then reboots the board into that ramdisk;
# 2. finds the board again (the new image sets a fixed MAC, so its DHCP address
#    may differ from the old one once - it looks for fpga-web on the /24);
# 3. streams sdcard.img to /dev/mmcblk0 over SSH, reads it back to compare, and
#    reboots into the new card. The new card's extlinux.conf no longer has the
#    ramdisk entry, so step 1's change is gone with it.
#
# If the board doesn't come back in step 2, the ramdisk didn't boot: take the
# card out and write sdcard.img on a PC (the old image is untouched until 3).
#
# Env: LINUX_BUILD_DIR (default <repo>/../zynqmini-linux)
#-----------------------------------------------------------------------------
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LINUX_BUILD_DIR:=$(dirname "$REPO")/zynqmini-linux}"
IMG="$LINUX_BUILD_DIR/buildroot/output/images"
KNOWN="$LINUX_BUILD_DIR/known_hosts"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: $0 <board-ip> [<console tty>]"
BOARD=$1
TTY=${2:-}
for f in sdcard.img uImage zynq-zynqmini.dtb rootfs.cpio.uboot; do
    [ -f "$IMG/$f" ] || die "missing $IMG/$f - run linux/build-linux.sh"
done

ssh_old() { ssh -o UserKnownHostsFile="$KNOWN" -o BatchMode=yes -o ConnectTimeout=5 "root@$BOARD" "$@"; }
# the ramdisk makes a fresh host key on every boot: accept it, but only for this session
TMPKNOWN=$(mktemp)
trap 'rm -f "$TMPKNOWN"' EXIT
ssh_rd() { ssh -o UserKnownHostsFile="$TMPKNOWN" -o StrictHostKeyChecking=accept-new \
               -o BatchMode=yes -o ConnectTimeout=5 "root@$1" "${@:2}"; }

#--- 1. ramdisk boot entry on the FAT partition --------------------------------
log "connecting to root@$BOARD"
ssh_old true || die "cannot SSH to $BOARD (known_hosts: $KNOWN)"
log "copying kernel + dtb + ramdisk to the boot partition"
ssh_old 'mkdir -p /mnt/boot && { mountpoint -q /mnt/boot || mount /dev/mmcblk0p1 /mnt/boot; } && mkdir -p /mnt/boot/ramdisk'
for f in uImage zynq-zynqmini.dtb rootfs.cpio.uboot; do
    ssh_old "cat > /mnt/boot/ramdisk/$f" < "$IMG/$f"
    l=$(md5sum < "$IMG/$f" | cut -d' ' -f1)
    r=$(ssh_old "md5sum < /mnt/boot/ramdisk/$f" | cut -d' ' -f1)
    [ "$l" = "$r" ] || die "checksum mismatch copying $f"
done
ssh_old "cp /mnt/boot/extlinux/extlinux.conf /mnt/boot/extlinux/extlinux.conf.orig 2>/dev/null; \
         cat > /mnt/boot/extlinux/extlinux.conf" <<'EOF'
default ramdisk
label ramdisk
  kernel /ramdisk/uImage
  devicetree /ramdisk/zynq-zynqmini.dtb
  initrd /ramdisk/rootfs.cpio.uboot
  append console=ttyPS0,115200 uio_pdrv_genirq.of_id=generic-uio
EOF
ssh_old 'sync; umount /mnt/boot'
log "rebooting into the ramdisk"
ssh_old 'reboot' || true

#--- 2. find it again ---------------------------------------------------------------
NET=${BOARD%.*}
is_ramdisk() { ssh_rd "$1" '! grep -q "^/dev/mmcblk0p2 / " /proc/mounts' 2>/dev/null; }
scan() {    # ping first so ARP is warm, then ask fpga-web; one address per line
    seq 1 254 | xargs -P 64 -I{} ping -c 1 -W 1 "$NET.{}" >/dev/null 2>&1 || true
    seq 1 254 | xargs -P 16 -I{} sh -c \
        'curl -s -m 4 http://'"$NET"'.{}/api/status 2>/dev/null | grep -q "\"pl\"" && echo '"$NET"'.{}' || true
}
console_ip() {   # log in on the serial console and ask for eth0's address
    [ -n "$TTY" ] || return 0
    env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I - "$TTY" <<'PY' 2>/dev/null || true
import re, serial, sys, time
s = serial.Serial(sys.argv[1], 115200, timeout=1)
s.write(b"\n"); time.sleep(1); r = s.read(8192)
if b"login:" in r:
    s.write(b"root\n"); time.sleep(1.5); s.read(8192)
s.write(b"ip -4 -o addr show eth0\n"); time.sleep(1.5)
m = re.search(rb"inet (\d+\.\d+\.\d+\.\d+)/", s.read(8192))
print(m.group(1).decode() if m else "")
PY
}
log "waiting for the ramdisk to come up (scanning $NET.0/24${TTY:+, console $TTY})"
sleep 30
RD=
for try in $(seq 1 20); do
    for ip in $(console_ip) $(scan); do
        is_ramdisk "$ip" && { RD=$ip; break; }
    done
    [ -n "$RD" ] && break
    sleep 5
done
[ -n "$RD" ] || die "the board did not come back in the ramdisk - write sdcard.img to the card on a PC"
log "ramdisk is up at $RD"
ssh_rd "$RD" 'grep -q mmcblk0 /proc/mounts' && die "/dev/mmcblk0 is mounted in the ramdisk - refusing to write it"

#--- 3. write the card ---------------------------------------------------------------
size=$(stat -c %s "$IMG/sdcard.img")
log "writing sdcard.img ($((size / 1048576)) MB) to /dev/mmcblk0"
ssh_rd "$RD" 'dd of=/dev/mmcblk0 bs=1M conv=fsync 2>/dev/null' < "$IMG/sdcard.img"
log "reading it back"
l=$(md5sum < "$IMG/sdcard.img" | cut -d' ' -f1)
r=$(ssh_rd "$RD" "head -c $size /dev/mmcblk0 | md5sum" | cut -d' ' -f1)
[ "$l" = "$r" ] || die "read-back mismatch ($l vs $r) - the ramdisk is still running; run again"
log "card verified ($l); rebooting into the new image"
ssh_rd "$RD" 'sync; reboot' || true

# the new image makes a new host key on its first boot
ssh-keygen -f "$KNOWN" -R "$RD" >/dev/null 2>&1 || true
ssh-keygen -f "$KNOWN" -R "$BOARD" >/dev/null 2>&1 || true
log "done - the board comes up at $RD (fixed MAC from now on);"
echo "   first SSH: ./linux/update-board.sh --new-hostkey $RD ...  or  ssh -o UserKnownHostsFile=$KNOWN root@$RD"
