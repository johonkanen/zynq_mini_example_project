-------------------------------------------------------------------------------
-- rgmii_tx_xilinx.vhd  (VHDL-2008)
--
-- The DDIO halves from hVHDL_gigabit_ethernet's ethernet_mac (rgmii_ddio_record,
-- on its 125 MHz clock) -> RGMII transmit pins, with ODDRs:
--
--   TXD/TX_CTL = ddio.hi on the rising edge (TX_EN, bits 3..0),
--                ddio.lo on the falling edge (TX_EN xor TX_ER, bits 7..4)
--   TXC        = tx_clock.hi(0) / tx_clock.lo(0) (1 then 0) through an ODDR:
--                edge-aligned with the data; the RTL8211E adds the ~2 ns TXC
--                delay itself (RGMII-ID), as with gmii_to_rgmii and its TXC skew 0
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

library hvhdl_ethernet;
use hvhdl_ethernet.ethernet_pkg.all;

entity rgmii_tx_xilinx is
    port (
        clk      : in  std_logic;                     -- 125 MHz, the MAC's clock
        ddio     : in  rgmii_ddio_record;
        tx_clock : in  rgmii_ddio_record;
        txc      : out std_logic;
        txd      : out std_logic_vector(3 downto 0);
        tx_ctl   : out std_logic
    );
end entity rgmii_tx_xilinx;

architecture rtl of rgmii_tx_xilinx is
    signal pins : std_logic_vector(4 downto 0);
begin

    gen_oddr : for i in 0 to 4 generate
        u_oddr : ODDR
            generic map (DDR_CLK_EDGE => "SAME_EDGE", INIT => '0', SRTYPE => "SYNC")
            port map (Q => pins(i), C => clk, CE => '1', D1 => ddio.hi(i), D2 => ddio.lo(i), R => '0', S => '0');
    end generate;
    txd    <= pins(3 downto 0);
    tx_ctl <= pins(4);

    u_oddr_txc : ODDR
        generic map (DDR_CLK_EDGE => "SAME_EDGE", INIT => '0', SRTYPE => "SYNC")
        port map (Q => txc, C => clk, CE => '1', D1 => tx_clock.hi(0), D2 => tx_clock.lo(0), R => '0', S => '0');

end architecture rtl;
