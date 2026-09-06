#-----------------------------------------------------------------------------
# zynq_mini.xdc  -  "Zynq Mini" board (xc7z020clg400-2)
#
# This example has NO external PL I/O - the AXI slave talks only to the PS over
# M_AXI_GP0 - so nothing here is active.
#
#   * DDR3 and the MIO peripherals (GEM0 RGMII, QSPI, eMMC/SD1, microSD/SD0,
#     UART1) use dedicated Zynq balls and are constrained automatically by the
#     processing_system7 IP - do not add pin constraints for them.
#   * FCLK_CLK0 (PL clock from the PS) is constrained automatically from the
#     PS7 configuration (PCW_FPGA0_PERIPHERAL_FREQMHZ).
#
# The blocks below are the board's PL pinout, from the vendor example projects
# (see ../../doc/board_pinout.md). Uncomment the pins you wire to real ports on
# the zynq_mini_top entity. All PL I/O on this board is LVCMOS33.
#-----------------------------------------------------------------------------

## --- PL clock + user LEDs / button ------------------------------------------
# set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33} [get_ports clk50]
# create_clock -period 20.000 -name clk50 [get_ports clk50]
# set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS33} [get_ports key_n]
# set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
# set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
# set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
# set_property -dict {PACKAGE_PIN T12 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

## --- OLED 0.96" SSD1306 (bit-banged 4-wire) -------------------------------
# set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33} [get_ports oled_1]
# set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports oled_2]
# set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports oled_3]
# set_property -dict {PACKAGE_PIN F17 IOSTANDARD LVCMOS33} [get_ports oled_4]

## --- HDMI out (TMDS straight from PL) -------------------------------------
# set_property -dict {PACKAGE_PIN H16 IOSTANDARD TMDS_33} [get_ports tmds_clk_p]
# set_property -dict {PACKAGE_PIN D19 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[0]}]
# set_property -dict {PACKAGE_PIN C20 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[1]}]
# set_property -dict {PACKAGE_PIN B19 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[2]}]
# set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS33} [get_ports hdmi_en]
# set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports hdmi_hpd]

## --- 2nd Gigabit Ethernet: RTL8211E on the PL (RGMII) --------------------
# set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports pl_eth_mdc]
# set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS33} [get_ports pl_eth_mdio]
# set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports pl_eth_rst_n]
# set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports pl_eth_txc]
# set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS33} [get_ports pl_eth_tx_ctl]
# set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {pl_eth_td[0]}]
# set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVCMOS33} [get_ports {pl_eth_td[1]}]
# set_property -dict {PACKAGE_PIN H20 IOSTANDARD LVCMOS33} [get_ports {pl_eth_td[2]}]
# set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports {pl_eth_td[3]}]
# set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS33} [get_ports pl_eth_rxc]
# set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} [get_ports pl_eth_rx_ctl]
# set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS33} [get_ports {pl_eth_rd[0]}]
# set_property -dict {PACKAGE_PIN K19 IOSTANDARD LVCMOS33} [get_ports {pl_eth_rd[1]}]
# set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} [get_ports {pl_eth_rd[2]}]
# set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVCMOS33} [get_ports {pl_eth_rd[3]}]

# OV5640 camera pins: see ../../doc/board_pinout.md
