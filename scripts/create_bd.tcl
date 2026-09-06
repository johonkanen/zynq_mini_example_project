#-----------------------------------------------------------------------------
# create_bd.tcl - build the "zynq_mini" block design
#
#   PS7 (DDR3 + Ethernet + QSPI + eMMC + microSD + UART1)
#     |
#     +-- M_AXI_GP0 ------------------> exposed on the BD boundary (raw AXI3)
#     +-- FCLK_CLK0 / FCLK_RESET0_N --> exposed on the BD boundary
#
# There is NO AXI interconnect and NO packaged slave in the block design. The
# M_AXI_GP0 AXI master is routed straight out to the fabric; src/hdl/axi_regs.vhd
# is a hand-written VHDL AXI slave that the VHDL top wires to it directly.
#
# The block design is generated as the plain entity "$BD_NAME" (no make_wrapper);
# src/hdl/${TOP_MODULE}.vhd is the hand-written VHDL top that instantiates it.
#
# Sourced by build.tcl with an open project; expects config.tcl already sourced.
#-----------------------------------------------------------------------------

source [file join [file dirname [info script]] ps7_base_config.tcl]

puts "\[create_bd] creating block design '$BD_NAME'"
create_bd_design $BD_NAME
current_bd_design $BD_NAME

#-----------------------------------------------------------------------------
# 1. Processing System
#-----------------------------------------------------------------------------
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]

# Base configuration (DDR3 / GEM0 / UART1 / clocks), captured from the board.
set_property -dict $PS7_BASE_CONFIG $ps

# Overrides: boot/storage peripherals + PL AXI master + PL clock.
set_property -dict [list \
    CONFIG.PCW_QSPI_PERIPHERAL_ENABLE      {1} \
    CONFIG.PCW_QSPI_GRP_SINGLE_SS_ENABLE   {1} \
    CONFIG.PCW_QSPI_GRP_SINGLE_SS_IO       {MIO 1 .. 6} \
    CONFIG.PCW_QSPI_GRP_FBCLK_ENABLE       {0} \
    CONFIG.PCW_QSPI_GRP_IO1_ENABLE         {0} \
    CONFIG.PCW_QSPI_GRP_SS1_ENABLE         {0} \
    CONFIG.PCW_QSPI_PERIPHERAL_FREQMHZ     {200} \
    CONFIG.PCW_SINGLE_QSPI_DATA_MODE       {x4} \
    CONFIG.PCW_SD0_PERIPHERAL_ENABLE       {1} \
    CONFIG.PCW_SD0_SD0_IO                  {MIO 40 .. 45} \
    CONFIG.PCW_SD0_GRP_CD_ENABLE           {0} \
    CONFIG.PCW_SD0_GRP_WP_ENABLE           {0} \
    CONFIG.PCW_SD0_GRP_POW_ENABLE          {0} \
    CONFIG.PCW_SD1_PERIPHERAL_ENABLE       {1} \
    CONFIG.PCW_SD1_SD1_IO                  {MIO 10 .. 15} \
    CONFIG.PCW_SD1_GRP_CD_ENABLE           {0} \
    CONFIG.PCW_SD1_GRP_WP_ENABLE           {0} \
    CONFIG.PCW_SD1_GRP_POW_ENABLE          {0} \
    CONFIG.PCW_USE_M_AXI_GP0               {1} \
    CONFIG.PCW_USE_M_AXI_GP1               {0} \
    CONFIG.PCW_EN_CLK0_PORT                {1} \
    CONFIG.PCW_EN_RST0_PORT                {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ    $FCLK0_MHZ \
] $ps

# Make the fixed-IO / DDR pins external (they map to dedicated package balls).
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config { make_external "FIXED_IO, DDR" apply_board_preset "0" Master "Disable" Slave "Disable" } \
    $ps

#-----------------------------------------------------------------------------
# 2. Route M_AXI_GP0 straight to the fabric
#    - clock the GP0 master port from FCLK_CLK0 (inside the BD)
#    - export the whole AXI interface on the BD boundary
#-----------------------------------------------------------------------------
connect_bd_net [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
               [get_bd_pins processing_system7_0/FCLK_CLK0]

make_bd_intf_pins_external -name M_AXI_GP0 [get_bd_intf_pins processing_system7_0/M_AXI_GP0]

#-----------------------------------------------------------------------------
# 3. Expose the PL clock and reset on the BD boundary
#-----------------------------------------------------------------------------
proc _expose {srcpin args} {
    set pin [get_bd_pins $srcpin]
    set net [get_bd_nets -quiet -of_objects $pin]
    set port [eval create_bd_port -dir O $args]
    if {$net ne ""} {
        connect_bd_net -net $net $port
    } else {
        connect_bd_net $pin $port
    }
}
_expose processing_system7_0/FCLK_CLK0     -type clk FCLK_CLK0
_expose processing_system7_0/FCLK_RESET0_N -type rst FCLK_RESET0_N

# The external AXI port is clocked by the external FCLK_CLK0 port.
set_property CONFIG.FREQ_HZ        [expr {$FCLK0_MHZ * 1000000}] [get_bd_ports FCLK_CLK0]
set_property CONFIG.ASSOCIATED_BUSIF {M_AXI_GP0}                 [get_bd_ports FCLK_CLK0]
set_property CONFIG.POLARITY       ACTIVE_LOW                    [get_bd_ports FCLK_RESET0_N]

#-----------------------------------------------------------------------------
# 4. Record the M_AXI_GP0 window (0x4000_0000, 1 GB) in the address map so the
#    exported .xsa / .hwh describe where the PL AXI slave lives, even though the
#    slave itself is hand-written VHDL outside the block design.
#-----------------------------------------------------------------------------
set gp0_seg [get_bd_addr_segs -quiet M_AXI_GP0/Reg]
if {$gp0_seg ne ""} {
    assign_bd_address -target_address_space /processing_system7_0/Data \
        $gp0_seg -range 1G -offset 0x40000000
}

#-----------------------------------------------------------------------------
# 5. Validate + save + generate the block-design HDL (entity "$BD_NAME").
#    NO make_wrapper - src/hdl/${TOP_MODULE}.vhd is the hand-written top and
#    instantiates this block design.
#-----------------------------------------------------------------------------
regenerate_bd_layout
validate_bd_design
save_bd_design

set bd_file [get_files "$BD_NAME.bd"]
# synthesis + simulation targets only - no 'hdl' target, so no competing
# auto-generated wrapper; src/hdl/${TOP_MODULE}.vhd is the top.
generate_target {synthesis simulation} $bd_file
export_ip_user_files -of_objects $bd_file -no_script -sync -force -quiet

puts "\[create_bd] done - block design entity '$BD_NAME' generated"
