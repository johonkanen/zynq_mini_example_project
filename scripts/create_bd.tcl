#-----------------------------------------------------------------------------
# create_bd.tcl - build the "zynq_mini" block design
#
#   PS7 (DDR3 + Ethernet + QSPI + eMMC + microSD + UART1)
#     |
#     +-- M_AXI_GP0 ------------------> exposed on the BD boundary (raw AXI3)
#     +-- FCLK_CLK0 / FCLK_RESET0_N --> exposed on the BD boundary
#     +-- GEM1 (EMIO GMII + MDIO) ----> gmii_to_rgmii --> RGMII + MDIO_PHY on the
#                                       BD boundary: the PL-side RTL8211E (eth1)
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
    CONFIG.PCW_ENET1_PERIPHERAL_ENABLE     {1} \
    CONFIG.PCW_ENET1_ENET1_IO              {EMIO} \
    CONFIG.PCW_ENET1_GRP_MDIO_ENABLE       {1} \
    CONFIG.PCW_ENET1_GRP_MDIO_IO           {EMIO} \
    CONFIG.PCW_ENET1_PERIPHERAL_CLKSRC     {IO PLL} \
    CONFIG.PCW_ENET1_PERIPHERAL_FREQMHZ    {1000 Mbps} \
    CONFIG.PCW_EN_CLK1_PORT                {1} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ    {200} \
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
# 3b. Second Ethernet: GEM1 over EMIO -> Xilinx GMII-to-RGMII -> the RTL8211E
#     on the PL pins (doc/notes.md). The converter makes its own 125/25/2.5 MHz
#     clocks and its IDELAYCTRL from the 200 MHz FCLK_CLK1, and answers MDIO at
#     address 8 (speed register) next to the PHY at address 1. Linux:
#     linux/pl/zynq-mini-pl.dtso (gem1 + xlnx,gmii-to-rgmii-1.0).
#-----------------------------------------------------------------------------
set g2r [create_bd_cell -type ip -vlnv xilinx.com:ip:gmii_to_rgmii:4.1 gmii_to_rgmii_0]
set_property -dict [list \
    CONFIG.SupportLevel      {Include_Shared_Logic_in_Core} \
    CONFIG.C_EXTERNAL_CLOCK  {false} \
    CONFIG.C_USE_IDELAY_CTRL {true} \
    CONFIG.C_PHYADDR         {8} \
    CONFIG.RGMII_TXC_SKEW    {0} \
] $g2r
set g2r_rst [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 gmii_to_rgmii_rst]
set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] $g2r_rst

connect_bd_intf_net [get_bd_intf_pins processing_system7_0/GMII_ETHERNET_1] [get_bd_intf_pins gmii_to_rgmii_0/GMII]
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/MDIO_ETHERNET_1] [get_bd_intf_pins gmii_to_rgmii_0/MDIO_GEM]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK1] [get_bd_pins gmii_to_rgmii_0/clkin]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins gmii_to_rgmii_rst/Op1]
connect_bd_net [get_bd_pins gmii_to_rgmii_rst/Res] [get_bd_pins gmii_to_rgmii_0/tx_reset] \
               [get_bd_pins gmii_to_rgmii_0/rx_reset]
make_bd_intf_pins_external -name RGMII    [get_bd_intf_pins gmii_to_rgmii_0/RGMII]
make_bd_intf_pins_external -name MDIO_PHY [get_bd_intf_pins gmii_to_rgmii_0/MDIO_PHY]

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
