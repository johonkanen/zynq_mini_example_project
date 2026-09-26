#-----------------------------------------------------------------------------
# reflash_sd.tcl - boot U-Boot over JTAG and have it reflash the microSD from TFTP
#
#   xsct linux/reflash_sd.tcl        (or linux\reflash_sd.bat)
#
# Prerequisites:
#   - ./linux/reflash-sd.sh <server-ip> has filled build_tftp/
#   - a TFTP server is serving build_tftp/
#   - board boot switch = JTAG, SD card in the slot, Ethernet plugged in
#
# Loads into DDR: U-Boot's own DTB @0x100000 (CONFIG_XILINX_OF_BOARD_DTB_ADDR),
# reflash.scr @0x3000000 (${scriptaddr}), then the U-Boot ELF. In JTAG boot mode
# U-Boot's distro boot runs bootcmd_jtag = "source ${scriptaddr}", so the
# reflash starts by itself after the 2 s autoboot delay.
#-----------------------------------------------------------------------------

set here [file normalize [file dirname [info script]]]
set repo [file normalize "$here/.."]
set pay  [file normalize "$repo/build_tftp"]

foreach f {u-boot u-boot.dtb reflash.scr ps7_init.tcl sdcard.img} {
    if {![file exists "$pay/$f"]} {
        error "missing $pay/$f - run  ./linux/reflash-sd.sh <server-ip>  (in WSL) first"
    }
}

puts "\[reflash] connecting ..."
connect
targets -set -nocase -filter {name =~ "*A9*MPCore #0" || name =~ "*A9*#0" || name =~ "ARM*#0"}

rst -processor
after 300

# U-Boot only runs the script when it sees JTAG boot mode (SLCR BOOT_MODE[2:0] == 0)
set bm [expr {[mrd -value 0xF800025C] & 0x7}]
if {$bm != 0} {
    set names {0 JTAG 1 QSPI 2 NOR 4 NAND 5 SD}
    set n [expr {[dict exists $names $bm] ? [dict get $names $bm] : $bm}]
    error "boot switch is set to $n - set it to JTAG and power-cycle the board"
}

puts "\[reflash] ps7_init"
source "$pay/ps7_init.tcl"
ps7_init
ps7_post_config

puts "\[reflash] u-boot.dtb  -> 0x00100000"
dow -data "$pay/u-boot.dtb"  0x00100000
puts "\[reflash] reflash.scr -> 0x03000000"
dow -data "$pay/reflash.scr" 0x03000000
puts "\[reflash] u-boot ELF"
dow "$pay/u-boot"
con

puts ""
puts "\[reflash] U-Boot is running. Follow progress on the serial console (115200 8N1):"
puts "\[reflash]   tftp sdcard.img -> mmc write -> read-back compare -> boots the new card"
puts "\[reflash] Afterwards set the boot switch back to SD for normal power-ups."
