#-----------------------------------------------------------------------------
# zynq_mini.xdc  -  "Zynq Mini" board (xc7z020clg400-2)
#
# The only external PL I/O in use is the SSD1306 OLED (ssd1306_text); every
# other block below is commented out.
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

## --- OLED 0.96" SSD1306, 4-wire SPI (J4) ---------------------------------
# Net names from the schematic (page 12); CS#/BS0..2 are tied to GND on the board.
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports oled_sclk]   ;# OLED_D0
set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33} [get_ports oled_sdin]   ;# OLED_D1
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports oled_dc]     ;# OLED_DC
set_property -dict {PACKAGE_PIN F17 IOSTANDARD LVCMOS33} [get_ports oled_res_n]  ;# OLED_RST
# Slow (5 MHz) registered outputs, no timing relationship to an external clock.
set_false_path -to [get_ports {oled_sclk oled_sdin oled_dc oled_res_n}]

## --- 40-pin EXT IO header (CAM1, schematic page 9), by header pin number ---
# Pins 1/19/22 GND, 20/21 VCC_3V3, 40 VCC5.0. Net FPGA_GPIO_<pair>_34.
set_property -dict {PACKAGE_PIN U15 IOSTANDARD LVCMOS33} [get_ports {ext_lo[2]}]   ;# pin  2  GPIO_11N
set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS33} [get_ports {ext_lo[3]}]   ;# pin  3  GPIO_10N
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {ext_lo[4]}]   ;# pin  4  GPIO_9N
set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS33} [get_ports {ext_lo[5]}]   ;# pin  5  GPIO_21N
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports {ext_lo[6]}]   ;# pin  6  GPIO_22P
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {ext_lo[7]}]   ;# pin  7  GPIO_12N
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {ext_lo[8]}]   ;# pin  8  GPIO_11P
set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} [get_ports {ext_lo[9]}]   ;# pin  9  GPIO_8N
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {ext_lo[10]}]   ;# pin 10  GPIO_18P
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports {ext_lo[11]}]   ;# pin 11  GPIO_12P
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports {ext_lo[12]}]   ;# pin 12  GPIO_20P
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports {ext_lo[13]}]   ;# pin 13  GPIO_19N
set_property -dict {PACKAGE_PIN W20 IOSTANDARD LVCMOS33} [get_ports {ext_lo[14]}]   ;# pin 14  GPIO_16N
set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVCMOS33} [get_ports {ext_lo[15]}]   ;# pin 15  GPIO_16P
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS33} [get_ports {ext_lo[16]}]   ;# pin 16  GPIO_15N
set_property -dict {PACKAGE_PIN T20 IOSTANDARD LVCMOS33} [get_ports {ext_lo[17]}]   ;# pin 17  GPIO_15P
set_property -dict {PACKAGE_PIN P20 IOSTANDARD LVCMOS33} [get_ports {ext_lo[18]}]   ;# pin 18  GPIO_14N
set_property -dict {PACKAGE_PIN N20 IOSTANDARD LVCMOS33} [get_ports {ext_hi[23]}]   ;# pin 23  GPIO_14P
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports {ext_hi[24]}]   ;# pin 24  GPIO_13P
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {ext_hi[25]}]   ;# pin 25  GPIO_23N
set_property -dict {PACKAGE_PIN P19 IOSTANDARD LVCMOS33} [get_ports {ext_hi[26]}]   ;# pin 26  GPIO_13N
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {ext_hi[27]}]   ;# pin 27  GPIO_20N
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {ext_hi[28]}]   ;# pin 28  GPIO_18N
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports {ext_hi[29]}]   ;# pin 29  GPIO_9P
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} [get_ports {ext_hi[30]}]   ;# pin 30  GPIO_19P
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33} [get_ports {ext_hi[31]}]   ;# pin 31  GPIO_24N
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports {ext_hi[32]}]   ;# pin 32  GPIO_8P
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {ext_hi[33]}]   ;# pin 33  GPIO_23P
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports {ext_hi[34]}]   ;# pin 34  GPIO_22N
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} [get_ports {ext_hi[35]}]   ;# pin 35  GPIO_17N
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports {ext_hi[36]}]   ;# pin 36  GPIO_17P
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {ext_hi[37]}]   ;# pin 37  GPIO_21P
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports {ext_hi[38]}]   ;# pin 38  GPIO_10P
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33} [get_ports {ext_hi[39]}]   ;# pin 39  GPIO_24P
set_false_path -to [get_ports {ext_lo[*] ext_hi[*]}]
# high-resolution PWM pins (hrpwm): fastest edges
set_property -dict {SLEW FAST DRIVE 16} [get_ports {ext_lo[14] ext_lo[15] ext_lo[17] ext_lo[18]}]
# hrpwm FTW / duty: quasi-static values from the AXI clock, re-synchronised in the MMCM's 100 MHz
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *u_hrpwm/f_meta_reg* || NAME =~ *u_hrpwm/d_meta_reg*}]

## --- HDMI out (TMDS straight from PL) -------------------------------------
# set_property -dict {PACKAGE_PIN H16 IOSTANDARD TMDS_33} [get_ports tmds_clk_p]
# set_property -dict {PACKAGE_PIN D19 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[0]}]
# set_property -dict {PACKAGE_PIN C20 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[1]}]
# set_property -dict {PACKAGE_PIN B19 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[2]}]
# set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS33} [get_ports hdmi_en]
# set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports hdmi_hpd]   ;# E18 = OLED_D0 too

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
