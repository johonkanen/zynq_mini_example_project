#-----------------------------------------------------------------------------
# uart_poke.tcl  -  instant UART1 smoke test, no build, no SD card
#
#   xsct sw/uart_poke.tcl
#
# Connects over JTAG, brings up the PS (ps7_init), then writes test text
# straight into the UART1 TX FIFO by poking registers. If it appears on your
# serial terminal (115200 8N1) the UART1 controller, MIO 48/49, the CH340
# USB-serial bridge and your cable/terminal settings all work.
#
# For a fuller test (internal loopback self-test + RX echo) build and run the
# bare-metal app: sw/uart_test.bat
#-----------------------------------------------------------------------------

set here [file normalize [file dirname [info script]]]
set repo [file normalize "$here/.."]

set ps7init [lindex [glob -nocomplain \
    "$repo/build_sw/zynq_mini_plat/hw/ps7_init.tcl" \
    "$repo/build_sw/zynq_mini_plat/export/zynq_mini_plat/hw/ps7_init.tcl"] 0]
if {$ps7init eq ""} {
    # pull it straight out of the .xsa (it's a zip)
    set tmp [file join [pwd] _ps7_init_tmp]
    file mkdir $tmp
    exec unzip -o "$repo/output/arm_fpga_zynq_mini.xsa" ps7_init.tcl -d $tmp
    set ps7init [file join $tmp ps7_init.tcl]
}
if {![file exists $ps7init]} { error "ps7_init.tcl not found - run build.bat first" }

# UART1 register map
set UART1_SR   0xE000102C   ;# channel status: TXFULL=bit4, TXEMPTY=bit3
set UART1_FIFO 0xE0001030   ;# TX/RX data

proc uart1_puts {s} {
    global UART1_SR UART1_FIFO
    foreach ch [split $s ""] {
        set g 0
        while {([mrd -force -value $UART1_SR] & 0x10) && [incr g] < 200000} {}
        mwr -force $UART1_FIFO [scan $ch %c]
    }
    set g 0
    while {!([mrd -force -value $UART1_SR] & 0x08) && [incr g] < 400000} {}
}

puts "\[uart_poke] connecting ..."
connect
targets -set -nocase -filter {name =~ "*A9*MPCore #0" || name =~ "*A9*#0" || name =~ "ARM*#0"}
rst -processor
after 400

puts "\[uart_poke] ps7_init ([file tail $ps7init]) ..."
source $ps7init
ps7_init
ps7_post_config

uart1_puts "\r\n\r\n"
uart1_puts "==================================================\r\n"
uart1_puts "  Zynq Mini - UART1 smoke test (JTAG register poke)\r\n"
uart1_puts "  UART1 base 0xE0001000, MIO 48/49, 115200 8N1\r\n"
uart1_puts "==================================================\r\n"
uart1_puts "If you can read this on your serial terminal, UART1\r\n"
uart1_puts "TX + wiring + the CH340 USB-serial bridge all work.\r\n\r\n"

puts "\[uart_poke] test text sent to UART1 - check your serial terminal (115200 8N1)"
