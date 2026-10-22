#-----------------------------------------------------------------------------
# pl_eth_hvhdl.xdc - RGMII timing for the PL MAC (PL_ETH = hvhdl, src/hdl/eth_mac.vhd)
#
# Only in that build (scripts/config.tcl); with PL_ETH = gem1 the gmii_to_rgmii
# IP brings the same constraints for the same pins. The model is the IP's: the
# RTL8211E delays both clocks by ~2 ns itself (RGMII-ID), the data is launched
# on both edges, and each edge is captured by the same edge.
# The pins and the RX clock itself (eth_rgmii_rxc, 8 ns) are in zynq_mini.xdc.
#-----------------------------------------------------------------------------

## RX: IDDR SAME_EDGE_PIPELINED on the BUFG'd RXC (rgmii_rx_xilinx)
create_clock -name eth_rgmii_rx_virt -period 8.000
set_input_delay -clock eth_rgmii_rx_virt -max -1.5 [get_ports {eth_rgmii_rd[*] eth_rgmii_rx_ctl}]
set_input_delay -clock eth_rgmii_rx_virt -min -2.8 [get_ports {eth_rgmii_rd[*] eth_rgmii_rx_ctl}]
set_input_delay -clock eth_rgmii_rx_virt -clock_fall -max -1.5 -add_delay [get_ports {eth_rgmii_rd[*] eth_rgmii_rx_ctl}]
set_input_delay -clock eth_rgmii_rx_virt -clock_fall -min -2.8 -add_delay [get_ports {eth_rgmii_rd[*] eth_rgmii_rx_ctl}]
# rising edge captures the rising-edge data, falling the falling
set_false_path -rise_from [get_clocks eth_rgmii_rx_virt] -fall_to [get_clocks eth_rgmii_rxc] -setup
set_false_path -fall_from [get_clocks eth_rgmii_rx_virt] -rise_to [get_clocks eth_rgmii_rxc] -setup
set_false_path -rise_from [get_clocks eth_rgmii_rx_virt] -rise_to [get_clocks eth_rgmii_rxc] -hold
set_false_path -fall_from [get_clocks eth_rgmii_rx_virt] -fall_to [get_clocks eth_rgmii_rxc] -hold
set_multicycle_path -from [get_clocks eth_rgmii_rx_virt] -to [get_clocks eth_rgmii_rxc] -setup 0
set_multicycle_path -from [get_clocks eth_rgmii_rx_virt] -to [get_clocks eth_rgmii_rxc] -hold -1

## TX: ODDRs on the MMCM's 125 MHz; TXC forwarded by an ODDR (rgmii_tx_xilinx)
set eth_txc_oddr [get_pins -hierarchical -filter {NAME =~ *u_eth_mac/u_tx_io/u_oddr_txc/C}]
create_generated_clock -name eth_rgmii_tx_clk -source $eth_txc_oddr -divide_by 1 [get_ports eth_rgmii_txc]
set eth_tx_src [get_clocks -of_objects $eth_txc_oddr]
set_output_delay -clock eth_rgmii_tx_clk -max -1.0 [get_ports {eth_rgmii_td[*] eth_rgmii_tx_ctl}]
set_output_delay -clock eth_rgmii_tx_clk -min -2.6 -add_delay [get_ports {eth_rgmii_td[*] eth_rgmii_tx_ctl}]
set_output_delay -clock eth_rgmii_tx_clk -clock_fall -max -1.0 -add_delay [get_ports {eth_rgmii_td[*] eth_rgmii_tx_ctl}]
set_output_delay -clock eth_rgmii_tx_clk -clock_fall -min -2.6 -add_delay [get_ports {eth_rgmii_td[*] eth_rgmii_tx_ctl}]
set_false_path -fall_from $eth_tx_src -rise_to [get_clocks eth_rgmii_tx_clk] -setup
set_false_path -rise_from $eth_tx_src -fall_to [get_clocks eth_rgmii_tx_clk] -setup
set_false_path -fall_from $eth_tx_src -fall_to [get_clocks eth_rgmii_tx_clk] -hold
set_false_path -rise_from $eth_tx_src -rise_to [get_clocks eth_rgmii_tx_clk] -hold
set_multicycle_path 0 -setup -end -rise_from $eth_tx_src -rise_to [get_clocks eth_rgmii_tx_clk]
set_multicycle_path 0 -setup -end -fall_from $eth_tx_src -fall_to [get_clocks eth_rgmii_tx_clk]

## The MAC's two 125 MHz domains (PHY's RXC, MMCM TX clock) are unrelated: the
## frame RAM is dual-clock, the hand-over is toggles + a held length
set_clock_groups -asynchronous \
    -group [get_clocks eth_rgmii_rxc] \
    -group [get_clocks -include_generated_clocks $eth_tx_src]
