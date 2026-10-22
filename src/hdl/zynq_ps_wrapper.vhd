-------------------------------------------------------------------------------
-- zynq_ps_wrapper.vhd  (VHDL-2008)
--
-- Thin wrapper around the "zynq_mini" block design. It instantiates the BD and
-- packs the flat M_AXI_GP0 pins into the axi_pkg direction records, so the top
-- level only deals with:
--
--     m_axi_o : out axi_mosi_t   -- PS master output  (AW/W/AR + B/R ready)
--     m_axi_i : in  axi_miso_t   -- PS master input   (ready + B/R channels)
--
-- plus the PL clock/reset, the physical DDR / FIXED_IO pins, and the GMII-to-
-- RGMII converter's side of the second Ethernet (GEM1 -> gmii_to_rgmii inside
-- the BD), which zynq_mini_top routes to the PL Ethernet pins.
--
-- PL_ETH selects the block design build (scripts/create_bd.tcl, PL_ETH env):
--   0  "gem1"  : with gmii_to_rgmii - the RGMII / MDIO ports carry eth1
--   1  "hvhdl" : without it (the PL MAC owns the pins); the ports are idle
-- The two block designs have different ports, so each branch declares its own.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

use work.axi_pkg.all;

entity zynq_ps_wrapper is
    generic (
        PL_ETH            : natural := 0     -- 0 = GEM1 via gmii_to_rgmii, 1 = no converter
    );
    port (
        -- PL clock and reset from the PS
        clk               : out   std_logic;   -- FCLK_CLK0 (100 MHz)
        resetn            : out   std_logic;   -- FCLK_RESET0_N (active low)

        -- M_AXI_GP0 as direction records
        m_axi_o           : out   axi_mosi_t;  -- master -> fabric
        m_axi_i           : in    axi_miso_t;  -- fabric -> master

        -- second Ethernet: RTL8211E on PL pins (RGMII + MDIO)
        rgmii_td          : out   std_logic_vector(3 downto 0);
        rgmii_tx_ctl      : out   std_logic;
        rgmii_txc         : out   std_logic;
        rgmii_rd          : in    std_logic_vector(3 downto 0);
        rgmii_rx_ctl      : in    std_logic;
        rgmii_rxc         : in    std_logic;
        mdio_mdc          : out   std_logic;
        mdio_i            : in    std_logic;    -- MDIO pad buffer: zynq_mini_top
        mdio_o            : out   std_logic;
        mdio_t            : out   std_logic;

        -- physical device pins (constrained automatically by the PS7 IP)
        DDR_addr          : inout std_logic_vector(14 downto 0);
        DDR_ba            : inout std_logic_vector(2 downto 0);
        DDR_cas_n         : inout std_logic;
        DDR_ck_n          : inout std_logic;
        DDR_ck_p          : inout std_logic;
        DDR_cke           : inout std_logic;
        DDR_cs_n          : inout std_logic;
        DDR_dm            : inout std_logic_vector(3 downto 0);
        DDR_dq            : inout std_logic_vector(31 downto 0);
        DDR_dqs_n         : inout std_logic_vector(3 downto 0);
        DDR_dqs_p         : inout std_logic_vector(3 downto 0);
        DDR_odt           : inout std_logic;
        DDR_ras_n         : inout std_logic;
        DDR_reset_n       : inout std_logic;
        DDR_we_n          : inout std_logic;
        FIXED_IO_ddr_vrn  : inout std_logic;
        FIXED_IO_ddr_vrp  : inout std_logic;
        FIXED_IO_mio      : inout std_logic_vector(53 downto 0);
        FIXED_IO_ps_clk   : inout std_logic;
        FIXED_IO_ps_porb  : inout std_logic;
        FIXED_IO_ps_srstb : inout std_logic
    );
end entity zynq_ps_wrapper;

architecture rtl of zynq_ps_wrapper is
begin

    gen_gem1 : if PL_ETH = 0 generate
        component zynq_mini is
            port (
                DDR_addr          : inout std_logic_vector(14 downto 0);
                DDR_ba            : inout std_logic_vector(2 downto 0);
                DDR_cas_n         : inout std_logic;
                DDR_ck_n          : inout std_logic;
                DDR_ck_p          : inout std_logic;
                DDR_cke           : inout std_logic;
                DDR_cs_n          : inout std_logic;
                DDR_dm            : inout std_logic_vector(3 downto 0);
                DDR_dq            : inout std_logic_vector(31 downto 0);
                DDR_dqs_n         : inout std_logic_vector(3 downto 0);
                DDR_dqs_p         : inout std_logic_vector(3 downto 0);
                DDR_odt           : inout std_logic;
                DDR_ras_n         : inout std_logic;
                DDR_reset_n       : inout std_logic;
                DDR_we_n          : inout std_logic;
                FCLK_CLK0         : out   std_logic;
                FCLK_RESET0_N     : out   std_logic;
                FIXED_IO_ddr_vrn  : inout std_logic;
                FIXED_IO_ddr_vrp  : inout std_logic;
                FIXED_IO_mio      : inout std_logic_vector(53 downto 0);
                FIXED_IO_ps_clk   : inout std_logic;
                FIXED_IO_ps_porb  : inout std_logic;
                FIXED_IO_ps_srstb : inout std_logic;
                MDIO_PHY_mdc      : out   std_logic;
                MDIO_PHY_mdio_i   : in    std_logic;
                MDIO_PHY_mdio_o   : out   std_logic;
                MDIO_PHY_mdio_t   : out   std_logic;
                RGMII_rd          : in    std_logic_vector(3 downto 0);
                RGMII_rx_ctl      : in    std_logic;
                RGMII_rxc         : in    std_logic;
                RGMII_td          : out   std_logic_vector(3 downto 0);
                RGMII_tx_ctl      : out   std_logic;
                RGMII_txc         : out   std_logic;
                M_AXI_GP0_araddr  : out   std_logic_vector(31 downto 0);
                M_AXI_GP0_arburst : out   std_logic_vector(1 downto 0);
                M_AXI_GP0_arcache : out   std_logic_vector(3 downto 0);
                M_AXI_GP0_arid    : out   std_logic_vector(11 downto 0);
                M_AXI_GP0_arlen   : out   std_logic_vector(3 downto 0);
                M_AXI_GP0_arlock  : out   std_logic_vector(1 downto 0);
                M_AXI_GP0_arprot  : out   std_logic_vector(2 downto 0);
                M_AXI_GP0_arqos   : out   std_logic_vector(3 downto 0);
                M_AXI_GP0_arready : in    std_logic;
                M_AXI_GP0_arsize  : out   std_logic_vector(2 downto 0);
                M_AXI_GP0_arvalid : out   std_logic;
                M_AXI_GP0_awaddr  : out   std_logic_vector(31 downto 0);
                M_AXI_GP0_awburst : out   std_logic_vector(1 downto 0);
                M_AXI_GP0_awcache : out   std_logic_vector(3 downto 0);
                M_AXI_GP0_awid    : out   std_logic_vector(11 downto 0);
                M_AXI_GP0_awlen   : out   std_logic_vector(3 downto 0);
                M_AXI_GP0_awlock  : out   std_logic_vector(1 downto 0);
                M_AXI_GP0_awprot  : out   std_logic_vector(2 downto 0);
                M_AXI_GP0_awqos   : out   std_logic_vector(3 downto 0);
                M_AXI_GP0_awready : in    std_logic;
                M_AXI_GP0_awsize  : out   std_logic_vector(2 downto 0);
                M_AXI_GP0_awvalid : out   std_logic;
                M_AXI_GP0_bid     : in    std_logic_vector(11 downto 0);
                M_AXI_GP0_bready  : out   std_logic;
                M_AXI_GP0_bresp   : in    std_logic_vector(1 downto 0);
                M_AXI_GP0_bvalid  : in    std_logic;
                M_AXI_GP0_rdata   : in    std_logic_vector(31 downto 0);
                M_AXI_GP0_rid     : in    std_logic_vector(11 downto 0);
                M_AXI_GP0_rlast   : in    std_logic;
                M_AXI_GP0_rready  : out   std_logic;
                M_AXI_GP0_rresp   : in    std_logic_vector(1 downto 0);
                M_AXI_GP0_rvalid  : in    std_logic;
                M_AXI_GP0_wdata   : out   std_logic_vector(31 downto 0);
                M_AXI_GP0_wid     : out   std_logic_vector(11 downto 0);
                M_AXI_GP0_wlast   : out   std_logic;
                M_AXI_GP0_wready  : in    std_logic;
                M_AXI_GP0_wstrb   : out   std_logic_vector(3 downto 0);
                M_AXI_GP0_wvalid  : out   std_logic
            );
        end component zynq_mini;
    begin
        u_bd : component zynq_mini
            port map (
                DDR_addr          => DDR_addr,
                DDR_ba            => DDR_ba,
                DDR_cas_n         => DDR_cas_n,
                DDR_ck_n          => DDR_ck_n,
                DDR_ck_p          => DDR_ck_p,
                DDR_cke           => DDR_cke,
                DDR_cs_n          => DDR_cs_n,
                DDR_dm            => DDR_dm,
                DDR_dq            => DDR_dq,
                DDR_dqs_n         => DDR_dqs_n,
                DDR_dqs_p         => DDR_dqs_p,
                DDR_odt           => DDR_odt,
                DDR_ras_n         => DDR_ras_n,
                DDR_reset_n       => DDR_reset_n,
                DDR_we_n          => DDR_we_n,
                FCLK_CLK0         => clk,
                FCLK_RESET0_N     => resetn,
                FIXED_IO_ddr_vrn  => FIXED_IO_ddr_vrn,
                FIXED_IO_ddr_vrp  => FIXED_IO_ddr_vrp,
                FIXED_IO_mio      => FIXED_IO_mio,
                FIXED_IO_ps_clk   => FIXED_IO_ps_clk,
                FIXED_IO_ps_porb  => FIXED_IO_ps_porb,
                FIXED_IO_ps_srstb => FIXED_IO_ps_srstb,
                MDIO_PHY_mdc      => mdio_mdc,
                MDIO_PHY_mdio_i   => mdio_i,
                MDIO_PHY_mdio_o   => mdio_o,
                MDIO_PHY_mdio_t   => mdio_t,
                RGMII_rd          => rgmii_rd,
                RGMII_rx_ctl      => rgmii_rx_ctl,
                RGMII_rxc         => rgmii_rxc,
                RGMII_td          => rgmii_td,
                RGMII_tx_ctl      => rgmii_tx_ctl,
                RGMII_txc         => rgmii_txc,
                -- master outputs  -> m_axi_o
                M_AXI_GP0_araddr  => m_axi_o.ar.addr,
                M_AXI_GP0_arburst => m_axi_o.ar.burst,
                M_AXI_GP0_arcache => m_axi_o.ar.cache,
                M_AXI_GP0_arid    => m_axi_o.ar.id,
                M_AXI_GP0_arlen   => m_axi_o.ar.len,
                M_AXI_GP0_arlock  => m_axi_o.ar.lock,
                M_AXI_GP0_arprot  => m_axi_o.ar.prot,
                M_AXI_GP0_arqos   => m_axi_o.ar.qos,
                M_AXI_GP0_arsize  => m_axi_o.ar.size,
                M_AXI_GP0_arvalid => m_axi_o.ar.valid,
                M_AXI_GP0_awaddr  => m_axi_o.aw.addr,
                M_AXI_GP0_awburst => m_axi_o.aw.burst,
                M_AXI_GP0_awcache => m_axi_o.aw.cache,
                M_AXI_GP0_awid    => m_axi_o.aw.id,
                M_AXI_GP0_awlen   => m_axi_o.aw.len,
                M_AXI_GP0_awlock  => m_axi_o.aw.lock,
                M_AXI_GP0_awprot  => m_axi_o.aw.prot,
                M_AXI_GP0_awqos   => m_axi_o.aw.qos,
                M_AXI_GP0_awsize  => m_axi_o.aw.size,
                M_AXI_GP0_awvalid => m_axi_o.aw.valid,
                M_AXI_GP0_bready  => m_axi_o.bready,
                M_AXI_GP0_rready  => m_axi_o.rready,
                M_AXI_GP0_wdata   => m_axi_o.w.data,
                M_AXI_GP0_wid     => m_axi_o.w.id,
                M_AXI_GP0_wlast   => m_axi_o.w.last,
                M_AXI_GP0_wstrb   => m_axi_o.w.strb,
                M_AXI_GP0_wvalid  => m_axi_o.w.valid,
                -- master inputs   <- m_axi_i
                M_AXI_GP0_arready => m_axi_i.arready,
                M_AXI_GP0_awready => m_axi_i.awready,
                M_AXI_GP0_bid     => m_axi_i.b.id,
                M_AXI_GP0_bresp   => m_axi_i.b.resp,
                M_AXI_GP0_bvalid  => m_axi_i.b.valid,
                M_AXI_GP0_rdata   => m_axi_i.r.data,
                M_AXI_GP0_rid     => m_axi_i.r.id,
                M_AXI_GP0_rlast   => m_axi_i.r.last,
                M_AXI_GP0_rresp   => m_axi_i.r.resp,
                M_AXI_GP0_rvalid  => m_axi_i.r.valid,
                M_AXI_GP0_wready  => m_axi_i.wready
            );
    end generate;

    gen_hvhdl : if PL_ETH /= 0 generate
        component zynq_mini is
            port (
                DDR_addr          : inout std_logic_vector(14 downto 0);
                DDR_ba            : inout std_logic_vector(2 downto 0);
                DDR_cas_n         : inout std_logic;
                DDR_ck_n          : inout std_logic;
                DDR_ck_p          : inout std_logic;
                DDR_cke           : inout std_logic;
                DDR_cs_n          : inout std_logic;
                DDR_dm            : inout std_logic_vector(3 downto 0);
                DDR_dq            : inout std_logic_vector(31 downto 0);
                DDR_dqs_n         : inout std_logic_vector(3 downto 0);
                DDR_dqs_p         : inout std_logic_vector(3 downto 0);
                DDR_odt           : inout std_logic;
                DDR_ras_n         : inout std_logic;
                DDR_reset_n       : inout std_logic;
                DDR_we_n          : inout std_logic;
                FCLK_CLK0         : out   std_logic;
                FCLK_RESET0_N     : out   std_logic;
                FIXED_IO_ddr_vrn  : inout std_logic;
                FIXED_IO_ddr_vrp  : inout std_logic;
                FIXED_IO_mio      : inout std_logic_vector(53 downto 0);
                FIXED_IO_ps_clk   : inout std_logic;
                FIXED_IO_ps_porb  : inout std_logic;
                FIXED_IO_ps_srstb : inout std_logic;
                M_AXI_GP0_araddr  : out   std_logic_vector(31 downto 0);
                M_AXI_GP0_arburst : out   std_logic_vector(1 downto 0);
                M_AXI_GP0_arcache : out   std_logic_vector(3 downto 0);
                M_AXI_GP0_arid    : out   std_logic_vector(11 downto 0);
                M_AXI_GP0_arlen   : out   std_logic_vector(3 downto 0);
                M_AXI_GP0_arlock  : out   std_logic_vector(1 downto 0);
                M_AXI_GP0_arprot  : out   std_logic_vector(2 downto 0);
                M_AXI_GP0_arqos   : out   std_logic_vector(3 downto 0);
                M_AXI_GP0_arready : in    std_logic;
                M_AXI_GP0_arsize  : out   std_logic_vector(2 downto 0);
                M_AXI_GP0_arvalid : out   std_logic;
                M_AXI_GP0_awaddr  : out   std_logic_vector(31 downto 0);
                M_AXI_GP0_awburst : out   std_logic_vector(1 downto 0);
                M_AXI_GP0_awcache : out   std_logic_vector(3 downto 0);
                M_AXI_GP0_awid    : out   std_logic_vector(11 downto 0);
                M_AXI_GP0_awlen   : out   std_logic_vector(3 downto 0);
                M_AXI_GP0_awlock  : out   std_logic_vector(1 downto 0);
                M_AXI_GP0_awprot  : out   std_logic_vector(2 downto 0);
                M_AXI_GP0_awqos   : out   std_logic_vector(3 downto 0);
                M_AXI_GP0_awready : in    std_logic;
                M_AXI_GP0_awsize  : out   std_logic_vector(2 downto 0);
                M_AXI_GP0_awvalid : out   std_logic;
                M_AXI_GP0_bid     : in    std_logic_vector(11 downto 0);
                M_AXI_GP0_bready  : out   std_logic;
                M_AXI_GP0_bresp   : in    std_logic_vector(1 downto 0);
                M_AXI_GP0_bvalid  : in    std_logic;
                M_AXI_GP0_rdata   : in    std_logic_vector(31 downto 0);
                M_AXI_GP0_rid     : in    std_logic_vector(11 downto 0);
                M_AXI_GP0_rlast   : in    std_logic;
                M_AXI_GP0_rready  : out   std_logic;
                M_AXI_GP0_rresp   : in    std_logic_vector(1 downto 0);
                M_AXI_GP0_rvalid  : in    std_logic;
                M_AXI_GP0_wdata   : out   std_logic_vector(31 downto 0);
                M_AXI_GP0_wid     : out   std_logic_vector(11 downto 0);
                M_AXI_GP0_wlast   : out   std_logic;
                M_AXI_GP0_wready  : in    std_logic;
                M_AXI_GP0_wstrb   : out   std_logic_vector(3 downto 0);
                M_AXI_GP0_wvalid  : out   std_logic
            );
        end component zynq_mini;
    begin
        u_bd : component zynq_mini
            port map (
                DDR_addr          => DDR_addr,
                DDR_ba            => DDR_ba,
                DDR_cas_n         => DDR_cas_n,
                DDR_ck_n          => DDR_ck_n,
                DDR_ck_p          => DDR_ck_p,
                DDR_cke           => DDR_cke,
                DDR_cs_n          => DDR_cs_n,
                DDR_dm            => DDR_dm,
                DDR_dq            => DDR_dq,
                DDR_dqs_n         => DDR_dqs_n,
                DDR_dqs_p         => DDR_dqs_p,
                DDR_odt           => DDR_odt,
                DDR_ras_n         => DDR_ras_n,
                DDR_reset_n       => DDR_reset_n,
                DDR_we_n          => DDR_we_n,
                FCLK_CLK0         => clk,
                FCLK_RESET0_N     => resetn,
                FIXED_IO_ddr_vrn  => FIXED_IO_ddr_vrn,
                FIXED_IO_ddr_vrp  => FIXED_IO_ddr_vrp,
                FIXED_IO_mio      => FIXED_IO_mio,
                FIXED_IO_ps_clk   => FIXED_IO_ps_clk,
                FIXED_IO_ps_porb  => FIXED_IO_ps_porb,
                FIXED_IO_ps_srstb => FIXED_IO_ps_srstb,
                -- master outputs  -> m_axi_o
                M_AXI_GP0_araddr  => m_axi_o.ar.addr,
                M_AXI_GP0_arburst => m_axi_o.ar.burst,
                M_AXI_GP0_arcache => m_axi_o.ar.cache,
                M_AXI_GP0_arid    => m_axi_o.ar.id,
                M_AXI_GP0_arlen   => m_axi_o.ar.len,
                M_AXI_GP0_arlock  => m_axi_o.ar.lock,
                M_AXI_GP0_arprot  => m_axi_o.ar.prot,
                M_AXI_GP0_arqos   => m_axi_o.ar.qos,
                M_AXI_GP0_arsize  => m_axi_o.ar.size,
                M_AXI_GP0_arvalid => m_axi_o.ar.valid,
                M_AXI_GP0_awaddr  => m_axi_o.aw.addr,
                M_AXI_GP0_awburst => m_axi_o.aw.burst,
                M_AXI_GP0_awcache => m_axi_o.aw.cache,
                M_AXI_GP0_awid    => m_axi_o.aw.id,
                M_AXI_GP0_awlen   => m_axi_o.aw.len,
                M_AXI_GP0_awlock  => m_axi_o.aw.lock,
                M_AXI_GP0_awprot  => m_axi_o.aw.prot,
                M_AXI_GP0_awqos   => m_axi_o.aw.qos,
                M_AXI_GP0_awsize  => m_axi_o.aw.size,
                M_AXI_GP0_awvalid => m_axi_o.aw.valid,
                M_AXI_GP0_bready  => m_axi_o.bready,
                M_AXI_GP0_rready  => m_axi_o.rready,
                M_AXI_GP0_wdata   => m_axi_o.w.data,
                M_AXI_GP0_wid     => m_axi_o.w.id,
                M_AXI_GP0_wlast   => m_axi_o.w.last,
                M_AXI_GP0_wstrb   => m_axi_o.w.strb,
                M_AXI_GP0_wvalid  => m_axi_o.w.valid,
                -- master inputs   <- m_axi_i
                M_AXI_GP0_arready => m_axi_i.arready,
                M_AXI_GP0_awready => m_axi_i.awready,
                M_AXI_GP0_bid     => m_axi_i.b.id,
                M_AXI_GP0_bresp   => m_axi_i.b.resp,
                M_AXI_GP0_bvalid  => m_axi_i.b.valid,
                M_AXI_GP0_rdata   => m_axi_i.r.data,
                M_AXI_GP0_rid     => m_axi_i.r.id,
                M_AXI_GP0_rlast   => m_axi_i.r.last,
                M_AXI_GP0_rresp   => m_axi_i.r.resp,
                M_AXI_GP0_rvalid  => m_axi_i.r.valid,
                M_AXI_GP0_wready  => m_axi_i.wready
            );
        rgmii_td     <= (others => '0');
        rgmii_tx_ctl <= '0';
        rgmii_txc    <= '0';
        mdio_mdc     <= '0';
        mdio_o       <= '0';
        mdio_t       <= '1';
    end generate;

end architecture rtl;
