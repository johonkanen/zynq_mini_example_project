#-----------------------------------------------------------------------------
# config.tcl - shared settings for the arm_fpga_zynq_mini build scripts
#-----------------------------------------------------------------------------

# Target device: Zynq-7020 mini board
set PART            "xc7z020clg400-2"

# Names
set PROJECT_NAME    "arm_fpga_zynq_mini"
set BD_NAME         "zynq_mini"
set TOP_MODULE      "zynq_mini_top"    ;# hand-written VHDL top (src/hdl/zynq_mini_top.vhd)

# PL clock that drives the AXI slave (MHz)
set FCLK0_MHZ       100

# Directory layout (all paths resolved relative to the repo root = one level
# above this script directory)
set SCRIPT_DIR      [file normalize [file dirname [info script]]]
set REPO_ROOT       [file normalize "$SCRIPT_DIR/.."]
set SRC_DIR         "$REPO_ROOT/src"
set HDL_DIR         "$SRC_DIR/hdl"
set CONSTR_DIR      "$SRC_DIR/constrs"
set BUILD_DIR       "$REPO_ROOT/build"
set OUTPUT_DIR      "$REPO_ROOT/output"
# Hand-written VHDL, added to the project after the block design is generated.
#   axi_pkg.vhd          - AXI bus direction records (axi_mosi_t / axi_miso_t)
#   axi_regs.vhd         - VHDL AXI slave (records on the port)
#   zynq_ps_wrapper.vhd  - wraps the block design; M_AXI_GP0 -> records
#   zynq_mini_top.vhd    - synthesis top; just u_ps + u_axi_regs + user logic
# All VHDL-2008, listed in dependency order.
set TOP_SOURCES [list \
    "$HDL_DIR/axi_pkg.vhd" \
    "$HDL_DIR/axi_regs.vhd" \
    "$HDL_DIR/zynq_ps_wrapper.vhd" \
    "$HDL_DIR/zynq_mini_top.vhd" \
]

# Constraints
set XDC_SOURCES [list \
    "$CONSTR_DIR/zynq_mini.xdc" \
]

#-----------------------------------------------------------------------------
# Parallelism
#
# BUILD_JOBS    = value passed to `launch_runs -jobs` (parallel synth/impl/OOC runs)
# BUILD_THREADS = value for `set_param general.maxThreads` (threads *within*
#                 synth_design / place / route / phys_opt / write_bitstream)
#
# Both default to "max" -> the machine's logical-CPU count, detected below.
# Override with an env var before launching Vivado, e.g.
#   set VIVADO_BUILD_JOBS=8   /   export VIVADO_BUILD_JOBS=8
#-----------------------------------------------------------------------------
proc _cpu_count {} {
    if {[info exists ::env(NUMBER_OF_PROCESSORS)]} { return $::env(NUMBER_OF_PROCESSORS) }
    if {![catch {exec nproc} n]}                   { return [string trim $n] }
    if {![catch {exec getconf _NPROCESSORS_ONLN} n]} { return [string trim $n] }
    return 4
}
proc _resolve_par {envvar hi} {
    set v "max"
    if {[info exists ::env($envvar)] && $::env($envvar) ne ""} { set v $::env($envvar) }
    if {$v eq "max" || ![string is integer -strict $v]} { set v [_cpu_count] }
    if {$v < 1}   { set v 1 }
    if {$v > $hi} { set v $hi }
    return $v
}

# Vivado caps: launch_runs -jobs and general.maxThreads both top out at 32.
set BUILD_JOBS    [_resolve_par VIVADO_BUILD_JOBS    32]
set BUILD_THREADS [_resolve_par VIVADO_BUILD_THREADS 32]

# Back-compat aliases (older references)
set RUN_SYNTH_JOBS $BUILD_JOBS
set RUN_IMPL_JOBS  $BUILD_JOBS
