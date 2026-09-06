#-----------------------------------------------------------------------------
# build_uart_test.tcl  -  build the bare-metal UART1 test with XSCT (Vitis 2024.2)
#
#   xsct sw/build_uart_test.tcl
#   (or run sw/uart_test.bat, which builds then loads it over JTAG)
#
# 1. XSCT generates a standalone platform (BSP: libxil.a + headers) from
#    output/arm_fpga_zynq_mini.xsa
# 2. arm-none-eabi-gcc compiles+links sw/uart_test/src/main.c against it
#    (the Vitis "app" project generator is skipped - it is unreliable in batch)
#
# Output:  build_sw/uart_test/uart_test.elf
#-----------------------------------------------------------------------------

set here [file normalize [file dirname [info script]]]
set repo [file normalize "$here/.."]
set xsa  [file normalize "$repo/output/arm_fpga_zynq_mini.xsa"]
set ws   [file normalize "$repo/build_sw"]
set out  [file normalize "$ws/uart_test"]

if {![file exists $xsa]} { error "XSA not found: $xsa\n  run build.bat first" }

file mkdir $ws
setws $ws
set PLAT zynq_mini_plat

# generate the platform / BSP only if it is missing or older than the XSA
set bsp "$ws/$PLAT/ps7_cortexa9_0/standalone_domain/bsp/ps7_cortexa9_0"
if {![file exists "$bsp/lib/libxil.a"] ||
    [file mtime $xsa] > [file mtime "$bsp/lib/libxil.a"]} {
    puts "\[build_sw] generating platform from [file tail $xsa] ..."
    catch { platform remove $PLAT }
    platform create -name $PLAT -hw $xsa -proc ps7_cortexa9_0 -os standalone
    platform active $PLAT
    platform generate
} else {
    puts "\[build_sw] reusing platform BSP ($bsp)"
}
if {![file exists "$bsp/lib/libxil.a"]} { error "BSP build failed: no $bsp/lib/libxil.a" }

# locate arm-none-eabi-gcc: env vars, then walk up from the xsct binary
set roots {}
foreach v {XILINX_VITIS XILINX_SDK VITIS_PATH} {
    if {[info exists ::env($v)]} { lappend roots $::env($v) }
}
set p [info nameofexecutable]
for {set i 0} {$i < 7} {incr i} { set p [file dirname $p]; lappend roots $p }
set gcc ""
foreach r $roots {
    set hit [glob -nocomplain \
        "$r/gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe" \
        "$r/gnu/aarch32/*/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe" \
        "$r/gnu/aarch32/*/gcc-arm-none-eabi/bin/arm-none-eabi-gcc"]
    if {[llength $hit]} { set gcc [lindex $hit 0]; break }
}
if {$gcc eq "" || ![file exists $gcc]} {
    error "arm-none-eabi-gcc not found (looked near [info nameofexecutable])"
}
puts "\[build_sw] gcc: $gcc"
set cflags [list -Wall -O2 -g -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard]

file mkdir $out
puts "\[build_sw] compiling main.c ..."
exec $gcc {*}$cflags -c -I"$bsp/include" "$here/uart_test/src/main.c" -o "$out/main.o"

puts "\[build_sw] linking uart_test.elf ..."
exec $gcc -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -Wl,-build-id=none \
    -specs="$here/uart_test/Xilinx.spec" \
    -Wl,-T -Wl,"$here/uart_test/lscript.ld" \
    -L"$bsp/lib" -o "$out/uart_test.elf" "$out/main.o" \
    -Wl,--start-group,-lxil,-lgcc,-lc,--end-group

set sz [lindex [glob -nocomplain "[file dirname $gcc]/arm-none-eabi-size*"] 0]
if {$sz ne ""} { puts [exec $sz "$out/uart_test.elf"] }
puts "\[build_sw] OK -> $out/uart_test.elf"
