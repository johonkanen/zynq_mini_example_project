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

# What drives the PL-side Ethernet PHY (env PL_ETH):
#   gem1  (default) GEM1 over EMIO -> gmii_to_rgmii in the block design = Linux eth1
#   hvhdl           hVHDL_gigabit_ethernet in the PL (src/hdl/eth_mac.vhd, echo test);
#                   no converter in the block design - the PS configuration (and so
#                   ps7_init / the boot loader) is the same in all three
#   shared          both on one port: GEM1's GMII over EMIO into eth_mac, which puts
#                   its frames on the line between its own (doc/hvhdl_ethernet.md
#                   phase 5); MDIO is GEM1's
set PL_ETH "gem1"
if {[info exists ::env(PL_ETH)] && $::env(PL_ETH) ne ""} { set PL_ETH $::env(PL_ETH) }
if {$PL_ETH ni {gem1 hvhdl shared}} { error "PL_ETH must be gem1, hvhdl or shared, not '$PL_ETH'" }

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
#   scope_pkg.vhd        - oscilloscope types (axi_regs <-> scope_capture)
#   axi_regs.vhd         - VHDL AXI slave (records on the port)
#   font8x8_pkg.vhd      - 8x8 font ROM for the OLED
#   ssd1306_text.vhd     - SSD1306 OLED text-mode driver
#   scope_siggen.vhd     - oscilloscope test signal generator
#   scope_capture.vhd    - oscilloscope triggered capture (BRAM ring buffer)
#   rgmii_rx/tx_xilinx.vhd - RGMII I/O for 7-series (IDDR / ODDR) for ethernet_mac
#   eth_mac.vhd          - ethernet_mac on the PL PHY: echo test (PL_ETH = hvhdl)
#   zynq_ps_wrapper.vhd  - wraps the block design; M_AXI_GP0 -> records
#   zynq_mini_top.vhd    - synthesis top; just u_ps + u_axi_regs + user logic
# All VHDL-2008, listed in dependency order.
set TOP_SOURCES [list \
    "$HDL_DIR/axi_pkg.vhd" \
    "$HDL_DIR/scope_pkg.vhd" \
    "$HDL_DIR/axi_regs.vhd" \
    "$HDL_DIR/font8x8_pkg.vhd" \
    "$HDL_DIR/ssd1306_text.vhd" \
    "$HDL_DIR/scope_siggen.vhd" \
    "$HDL_DIR/scope_capture.vhd" \
    "$HDL_DIR/hrpwm.vhd" \
]
lappend TOP_SOURCES \
    "$HDL_DIR/rgmii_rx_xilinx.vhd" \
    "$HDL_DIR/rgmii_tx_xilinx.vhd" \
    "$HDL_DIR/eth_mac.vhd" \
    "$HDL_DIR/zynq_ps_wrapper.vhd" \
    "$HDL_DIR/zynq_mini_top.vhd"

# hVHDL_gigabit_ethernet's ethernet_mac (git submodule, kept at its tip), compiled
# into a VHDL library of its own (some file names clash with the repository's
# older sources): the files its vunit_run_ethernet_mac.py uses, minus the tests.
set ETH_LIB         "hvhdl_ethernet"
set ETH_DIR         "$SRC_DIR/hVHDL_gigabit_ethernet"
set ETH_SOURCES [concat \
    [list "$ETH_DIR/submodules/hVHDL_memory_library/vhdl2008/dp_ram_w_configurable_records.vhd" \
          "$ETH_DIR/submodules/hVHDL_memory_library/vhdl2008/sdp_ram_w_configurable_records.vhd"] \
    [lsort [glob -nocomplain "$ETH_DIR/ethernet_mac/*.vhd"]]]

# Constraints
set XDC_SOURCES [list \
    "$CONSTR_DIR/zynq_mini.xdc" \
]
if {$PL_ETH ne "gem1"} { lappend XDC_SOURCES "$CONSTR_DIR/pl_eth_hvhdl.xdc" }

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
