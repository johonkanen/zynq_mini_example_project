#-----------------------------------------------------------------------------
# zynq_mini.xdc  -  Zynq-7020 mini board (xc7z020clg400-2)
#
# This example has NO external PL I/O: the custom AXI slave lives entirely
# inside the fabric and talks only to the PS over M_AXI_GP0. Therefore there
# are no PACKAGE_PIN / IOSTANDARD constraints here.
#
#   * DDR3 and the MIO peripherals (Ethernet RGMII, QSPI, eMMC/SD1,
#     microSD/SD0, UART1) use dedicated Zynq balls and are constrained
#     automatically by the processing_system7 IP - do not add pin
#     constraints for them.
#   * FCLK_CLK0 (PL clock from the PS) is constrained automatically from the
#     PS7 configuration (PCW_FPGA0_PERIPHERAL_FREQMHZ).
#
# Add PL pin constraints below only when you extend the design with real
# fabric I/O (LEDs, buttons, OLED, HDMI, ...). See ../../doc/mio_map.md and
# the per-example *.xdc files under the sibling projects for pin numbers.
#-----------------------------------------------------------------------------

# (intentionally empty)
