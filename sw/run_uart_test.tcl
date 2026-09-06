#-----------------------------------------------------------------------------
# run_uart_test.tcl  -  load the UART1 test onto the board over JTAG (no SD card)
#
#   xsct sw/run_uart_test.tcl
#   (or run sw/uart_test.bat, which builds first)
#
# Connects, brings up the PS (ps7_init), downloads uart_test.elf, runs it,
# then reads the controller self-test result back over JTAG and prints PASS/FAIL.
# Open a serial terminal at 115200 8N1 on the board's COM port to see phase 2.
#-----------------------------------------------------------------------------

set here [file normalize [file dirname [info script]]]
set repo [file normalize "$here/.."]
set ws   [file normalize "$repo/build_sw"]

set elf [lindex [glob -nocomplain \
    "$ws/uart_test/uart_test.elf" \
    "$ws/uart_test/*/uart_test.elf"] 0]
if {$elf eq "" || ![file exists $elf]} {
    error "no uart_test.elf under $ws - run  xsct sw/build_uart_test.tcl  first"
}

set ps7init [lindex [glob -nocomplain \
    "$ws/zynq_mini_plat/hw/ps7_init.tcl" \
    "$ws/zynq_mini_plat/export/zynq_mini_plat/hw/ps7_init.tcl"] 0]

puts "\[run] connecting ..."
connect

# optional: load the PL bitstream too (not needed for the PS UART test)
# targets -set -nocase -filter {name =~ "xc7z*" || name =~ "*PL*"}
# fpga -file "$repo/output/arm_fpga_zynq_mini.bit"

targets -set -nocase -filter {name =~ "*A9*MPCore #0" || name =~ "*A9*#0" || name =~ "ARM*#0"}
rst -processor
after 300

if {$ps7init ne "" && [file exists $ps7init]} {
    puts "\[run] ps7_init: [file tail $ps7init]"
    source $ps7init
    ps7_init
    ps7_post_config
} else {
    puts "\[run] WARNING: ps7_init.tcl not found - assuming the PS is already configured"
}

puts "\[run] downloading [file tail $elf] ..."
dow $elf
con
after 1500
stop

proc _val {sym} {
    if {[catch {print $sym} out]} { return "?" }
    if {[regexp {(0x[0-9a-fA-F]+|-?\d+)\s*$} $out -> v]} { return $v }
    return $out
}
set st [_val uart_selftest_status]
set nb [_val uart_selftest_bytes]
puts "\[run] uart_selftest_status = $st"
puts "\[run] uart_selftest_bytes  = $nb"

if {[catch {expr {$st == 0xC0DE600D}} eq] == 0 && $eq} {
    puts "\[run] ================================================"
    puts "\[run]   UART1 CONTROLLER SELF-TEST : PASS  ($nb/256)"
    puts "\[run] ================================================"
} else {
    puts "\[run] ================================================"
    puts "\[run]   UART1 CONTROLLER SELF-TEST : FAIL"
    puts "\[run] ================================================"
}

con
puts ""
puts "\[run] app running. On the board's USB-serial COM port (115200 8N1) you"
puts "\[run] should now see the banner + 'loopback test: PASS' + \[tick\] lines,"
puts "\[run] and characters you type get echoed back."
