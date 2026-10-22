-------------------------------------------------------------------------------
-- rgmii_rx_xilinx.vhd  (VHDL-2008)
--
-- RGMII receive pins -> the DDIO halves hVHDL_gigabit_ethernet's ethernet_mac
-- takes (rgmii_ddio_record; the library keeps device primitives outside):
-- one IDDR per line, SAME_EDGE_PIPELINED, so both halves arrive together on
-- the rising edge.
--
--   ddio.hi = RX_CTL & RXD(3..0) of the rising edge   (DV, bits 3..0 of the byte)
--   ddio.lo = RX_CTL & RXD(3..0) of the falling edge  (DV xor ER, bits 7..4)
--
-- Clocking as Xilinx's gmii_to_rgmii does it on Zynq (and as it works on this
-- board): RXC -> BUFIO for the IDDRs (little insertion delay) and -> BUFG for
-- the logic after them (rx_clk); every data line through an IDELAYE2, FIXED at
-- IDELAY_TAPS (78 ps each with the 200 MHz IDELAYCTRL reference; the
-- IDELAYCTRL is the instantiating design's). The RTL8211E already delays RXC by
-- ~2 ns (RGMII-ID); pl_eth_hvhdl.xdc has the input delays this is timed against.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

library hvhdl_ethernet;
use hvhdl_ethernet.ethernet_pkg.all;

entity rgmii_rx_xilinx is
    generic (
        IDELAY_TAPS : natural := 16                   -- = gmii_to_rgmii's
    );
    port (
        rxc    : in  std_logic;                       -- a clock-capable pin in the data's bank
        rxd    : in  std_logic_vector(3 downto 0);
        rx_ctl : in  std_logic;
        rx_clk : out std_logic;                       -- RXC through a BUFG
        ddio   : out rgmii_ddio_record                -- rx_clk domain
    );
end entity rgmii_rx_xilinx;

architecture rtl of rgmii_rx_xilinx is
    signal clk_io, clk : std_logic;
    signal pins, delayed : std_logic_vector(4 downto 0);
    signal q_rise, q_fall : std_logic_vector(4 downto 0);
begin

    u_bufio : BUFIO port map (I => rxc, O => clk_io);
    u_bufg  : BUFG  port map (I => rxc, O => clk);
    rx_clk <= clk;

    pins <= rx_ctl & rxd;
    gen_line : for i in 0 to 4 generate
        u_idelay : IDELAYE2
            generic map (IDELAY_TYPE => "FIXED", IDELAY_VALUE => IDELAY_TAPS, DELAY_SRC => "IDATAIN",
                         HIGH_PERFORMANCE_MODE => "TRUE", REFCLK_FREQUENCY => 200.0,
                         SIGNAL_PATTERN => "DATA", CINVCTRL_SEL => "FALSE", PIPE_SEL => "FALSE")
            port map (IDATAIN => pins(i), DATAOUT => delayed(i), DATAIN => '0', C => '0', CE => '0',
                      INC => '0', LD => '0', LDPIPEEN => '0', REGRST => '0', CINVCTRL => '0',
                      CNTVALUEIN => (others => '0'), CNTVALUEOUT => open);

        u_iddr : IDDR
            generic map (DDR_CLK_EDGE => "SAME_EDGE_PIPELINED", INIT_Q1 => '0', INIT_Q2 => '0', SRTYPE => "SYNC")
            port map (Q1 => q_rise(i), Q2 => q_fall(i), C => clk_io, CE => '1', D => delayed(i), R => '0', S => '0');
    end generate;

    ddio <= (hi => q_rise, lo => q_fall);

end architecture rtl;
