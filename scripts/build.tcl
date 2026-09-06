#-----------------------------------------------------------------------------
# build.tcl - top-level build script for the arm_fpga_zynq_mini example
#
# Usage:
#   vivado -mode batch -source scripts/build.tcl                 ;# full build -> bitstream + XSA
#   vivado -mode batch -source scripts/build.tcl -tclargs bd     ;# stop after block design
#   vivado -mode batch -source scripts/build.tcl -tclargs synth  ;# stop after synthesis
#   vivado -mode batch -source scripts/build.tcl -tclargs impl   ;# stop after implementation
#   vivado -mode gui   -source scripts/build.tcl -tclargs bd     ;# open the project in the GUI
#
# The Windows helper  build.bat  wraps this.
#-----------------------------------------------------------------------------

set _stage "all"
if {$argc >= 1} { set _stage [lindex $argv 0] }

set SCRIPT_DIR [file normalize [file dirname [info script]]]
source [file join $SCRIPT_DIR config.tcl]

#-----------------------------------------------------------------------------
# Parallelism: use every logical CPU (see config.tcl for env overrides).
# maxThreads governs synth_design / place / route / phys_opt / write_bitstream
# and is inherited by the launch_runs subprocesses; -jobs governs parallel runs.
#-----------------------------------------------------------------------------
set_param general.maxThreads $BUILD_THREADS
puts "\[build] parallelism: maxThreads = $BUILD_THREADS , launch_runs -jobs = $BUILD_JOBS"

file mkdir $BUILD_DIR
file mkdir $OUTPUT_DIR

#-----------------------------------------------------------------------------
# Fresh project (in-tree build/ dir; safe to delete)
#-----------------------------------------------------------------------------
set xpr [file join $BUILD_DIR "$PROJECT_NAME.xpr"]
if {[file exists $xpr]} {
    puts "\[build] removing previous project $xpr"
    close_project -quiet
    file delete -force [file join $BUILD_DIR "$PROJECT_NAME.xpr"]
    file delete -force [file join $BUILD_DIR "$PROJECT_NAME.srcs"]
    file delete -force [file join $BUILD_DIR "$PROJECT_NAME.gen"]
    file delete -force [file join $BUILD_DIR "$PROJECT_NAME.runs"]
    file delete -force [file join $BUILD_DIR "$PROJECT_NAME.cache"]
    file delete -force [file join $BUILD_DIR "$PROJECT_NAME.hw"]
    file delete -force [file join $BUILD_DIR "$PROJECT_NAME.ip_user_files"]
}

create_project $PROJECT_NAME $BUILD_DIR -part $PART -force
set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]

#-----------------------------------------------------------------------------
# Constraints
#-----------------------------------------------------------------------------
foreach x $XDC_SOURCES {
    if {[file exists $x]} { add_files -norecurse -fileset constrs_1 $x }
}

#-----------------------------------------------------------------------------
# Block design
#-----------------------------------------------------------------------------
source [file join $SCRIPT_DIR create_bd.tcl]

# Keep a regenerable Tcl copy of the BD next to the scripts.
write_bd_tcl -force [file join $SCRIPT_DIR "${BD_NAME}_bd.tcl"]

#-----------------------------------------------------------------------------
# Hand-written VHDL top level - instantiates the block design
#-----------------------------------------------------------------------------
add_files -norecurse -fileset sources_1 $TOP_SOURCES
foreach f $TOP_SOURCES {
    set_property file_type "VHDL 2008" [get_files [file tail $f]]
}
set_property top $TOP_MODULE [current_fileset]
update_compile_order -fileset sources_1
puts "\[build] top module = $TOP_MODULE ([file tail [lindex $TOP_SOURCES end]])"

if {$_stage eq "bd"} {
    puts "\[build] stage 'bd' complete (project left open for GUI use)."
    return
}

#-----------------------------------------------------------------------------
# Synthesis
#-----------------------------------------------------------------------------
launch_runs synth_1 -jobs $BUILD_JOBS
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "\[build] synthesis failed - see [get_property DIRECTORY [get_runs synth_1]]"
}
open_run synth_1 -name synth_1
report_utilization -file [file join $OUTPUT_DIR utilization_synth.rpt]
close_design -quiet

if {$_stage eq "synth"} { puts "\[build] stage 'synth' complete."; return }

#-----------------------------------------------------------------------------
# Implementation (+ bitstream unless the stage stops earlier)
#-----------------------------------------------------------------------------
set _impl_to_step [expr {$_stage eq "impl" ? "route_design" : "write_bitstream"}]
launch_runs impl_1 -to_step $_impl_to_step -jobs $BUILD_JOBS
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "\[build] implementation failed - see [get_property DIRECTORY [get_runs impl_1]]"
}
open_run impl_1
report_timing_summary -file [file join $OUTPUT_DIR timing_summary.rpt]
report_utilization     -file [file join $OUTPUT_DIR utilization_impl.rpt]
set wns [get_property SLACK [get_timing_paths -delay_type max -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -nworst 1]]
puts "\[build] post-implementation setup WNS = $wns ns , hold WHS = $whs ns"
if {$wns < 0 || $whs < 0} {
    puts "\[build] WARNING: timing not met - see output/timing_summary.rpt"
}
close_design -quiet

if {$_stage eq "impl"} { puts "\[build] stage 'impl' complete."; return }

#-----------------------------------------------------------------------------
# Hardware handoff (XSA for Vitis)
#-----------------------------------------------------------------------------

set bit [file join $OUTPUT_DIR "$PROJECT_NAME.bit"]
file copy -force \
    [file join $BUILD_DIR "$PROJECT_NAME.runs" impl_1 "${TOP_MODULE}.bit"] $bit
puts "\[build] bitstream  -> $bit"

set xsa [file join $OUTPUT_DIR "$PROJECT_NAME.xsa"]
write_hw_platform -fixed -include_bit -force -file $xsa
puts "\[build] hw platform -> $xsa"

puts "\[build] FULL BUILD COMPLETE"
