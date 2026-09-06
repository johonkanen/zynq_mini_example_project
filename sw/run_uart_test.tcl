#-----------------------------------------------------------------------------
# run_uart_test.tcl  -  load the board bring-up test over JTAG (no SD card)
#
#   xsct sw/run_uart_test.tcl
#   (or run sw/uart_test.bat, which builds first)
#
# Loads the PL bitstream, brings up the PS (ps7_init), downloads the ELF, runs
# it, then reads the phase-1 (UART1) and phase-2 (PS<->PL) self-test results
# back over JTAG. Open a serial terminal at 115200 8N1 for the full report +
# phase-3 echo.
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

set bit    [file normalize "$repo/output/arm_fpga_zynq_mini.bit"]
set ps7init [lindex [glob -nocomplain \
    "$ws/zynq_mini_plat/hw/ps7_init.tcl" \
    "$ws/zynq_mini_plat/export/zynq_mini_plat/hw/ps7_init.tcl"] 0]

puts "\[run] connecting ..."
connect

# 1. configure the PL so the PS<->PL (M_AXI_GP0 -> axi_regs) test can run
if {[file exists $bit]} {
    targets -set -nocase -filter {name =~ "xc7z*" || name =~ "*PL*" || name =~ "*7z020*"}
    puts "\[run] fpga: [file tail $bit]"
    fpga -file $bit
} else {
    puts "\[run] WARNING: [file tail $bit] not found - PS<->PL phase will report SKIP"
}

# 2. bring up the PS
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

# 3. run
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
proc _is {v magic} { expr {[catch {expr {$v == $magic}} r] == 0 && $r} }

set u_st [_val uart_selftest_status]
set u_nb [_val uart_selftest_bytes]
set a_st [_val axi_selftest_status]
set a_fm [_val axi_fail_mask]

puts ""
puts "\[run] ============================================================"
if {[_is $u_st 0xC0DE600D]} {
    puts "\[run]   UART1 controller  : PASS   ($u_nb/256 bytes looped back)"
} else {
    puts "\[run]   UART1 controller  : FAIL   (status=$u_st bytes=$u_nb)"
}
if {[_is $a_st 0xC0DE600D]} {
    puts "\[run]   PS <-> PL (AXI)   : PASS   (SIGNATURE / loopback / SUM / HEARTBEAT / STATUS)"
} elseif {[_is $a_st 0x5C1FF00D]} {
    puts "\[run]   PS <-> PL (AXI)   : SKIP   (PL not configured - no bitstream)"
} else {
    puts "\[run]   PS <-> PL (AXI)   : FAIL   (status=$a_st fail_mask=$a_fm)"
    puts "\[run]                       bits: 0 plcfg 1 sig 2 loopback 3 sum 4 heartbeat 5 status"
}
puts "\[run] ============================================================"

con
puts ""
puts "\[run] app running. On the board's serial terminal (115200 8N1) you should"
puts "\[run] see the full report + \[tick\] lines, and typed characters echo back."
