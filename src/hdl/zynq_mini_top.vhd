-------------------------------------------------------------------------------
-- zynq_mini_top.vhd  (VHDL-2008)
--
-- Hand-written top level. It instantiates the "zynq_mini" block design (just the
-- PS7 - DDR3 / Ethernet / QSPI / eMMC / microSD / UART1, with M_AXI_GP0 and the
-- PL clock/reset routed straight to the boundary) and connects the raw AXI3
-- master to axi_regs, a VHDL AXI slave. No AXI interconnect IP anywhere.
--
--   zynq_mini_top
--     |
--     +-- u_bd : zynq_mini    (PS7; M_AXI_GP0_* + FCLK_CLK0/FCLK_RESET0_N)
--     |
--     +-- u_axi_regs : axi_regs   <- AXI slave, written in VHDL
--     |
--     +-- placeholder PL user logic
--
-- Entity ports = the physical device pins only (DDR_* + FIXED_IO_*), which the
-- PS7 IP constrains automatically. Add a port here + a line in
-- src/constrs/zynq_mini.xdc for any real PL I/O.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity zynq_mini_top is
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
        FIXED_IO_ddr_vrn  : inout std_logic;
        FIXED_IO_ddr_vrp  : inout std_logic;
        FIXED_IO_mio      : inout std_logic_vector(53 downto 0);
        FIXED_IO_ps_clk   : inout std_logic;
        FIXED_IO_ps_porb  : inout std_logic;
        FIXED_IO_ps_srstb : inout std_logic
    );
end entity zynq_mini_top;

architecture rtl of zynq_mini_top is

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

    -- PS <-> PL
    signal clk     : std_logic;
    signal resetn  : std_logic;

    -- M_AXI_GP0 (AXI3) - PS master side
    signal m_awid    : std_logic_vector(11 downto 0);
    signal m_awaddr  : std_logic_vector(31 downto 0);
    signal m_awlen   : std_logic_vector(3 downto 0);
    signal m_awsize  : std_logic_vector(2 downto 0);
    signal m_awburst : std_logic_vector(1 downto 0);
    signal m_awlock  : std_logic_vector(1 downto 0);
    signal m_awcache : std_logic_vector(3 downto 0);
    signal m_awprot  : std_logic_vector(2 downto 0);
    signal m_awqos   : std_logic_vector(3 downto 0);
    signal m_awvalid : std_logic;
    signal m_awready : std_logic;
    signal m_wid     : std_logic_vector(11 downto 0);
    signal m_wdata   : std_logic_vector(31 downto 0);
    signal m_wstrb   : std_logic_vector(3 downto 0);
    signal m_wlast   : std_logic;
    signal m_wvalid  : std_logic;
    signal m_wready  : std_logic;
    signal m_bid     : std_logic_vector(11 downto 0);
    signal m_bresp   : std_logic_vector(1 downto 0);
    signal m_bvalid  : std_logic;
    signal m_bready  : std_logic;
    signal m_arid    : std_logic_vector(11 downto 0);
    signal m_araddr  : std_logic_vector(31 downto 0);
    signal m_arlen   : std_logic_vector(3 downto 0);
    signal m_arsize  : std_logic_vector(2 downto 0);
    signal m_arburst : std_logic_vector(1 downto 0);
    signal m_arlock  : std_logic_vector(1 downto 0);
    signal m_arcache : std_logic_vector(3 downto 0);
    signal m_arprot  : std_logic_vector(2 downto 0);
    signal m_arqos   : std_logic_vector(3 downto 0);
    signal m_arvalid : std_logic;
    signal m_arready : std_logic;
    signal m_rid     : std_logic_vector(11 downto 0);
    signal m_rdata   : std_logic_vector(31 downto 0);
    signal m_rresp   : std_logic_vector(1 downto 0);
    signal m_rlast   : std_logic;
    signal m_rvalid  : std_logic;
    signal m_rready  : std_logic;

    -- register view from the AXI slave
    signal reg_ps2pl : std_logic_vector(127 downto 0);
    signal pl_active : std_logic;

    -- ===== placeholder PL user logic =====================================
    signal heartbeat  : unsigned(27 downto 0) := (others => '0');
    signal user_probe : std_logic_vector(31 downto 0);
    attribute keep : string;
    attribute keep of user_probe : signal is "true";

begin

    ---------------------------------------------------------------------------
    -- Block design (PS7)
    ---------------------------------------------------------------------------
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
            M_AXI_GP0_araddr  => m_araddr,
            M_AXI_GP0_arburst => m_arburst,
            M_AXI_GP0_arcache => m_arcache,
            M_AXI_GP0_arid    => m_arid,
            M_AXI_GP0_arlen   => m_arlen,
            M_AXI_GP0_arlock  => m_arlock,
            M_AXI_GP0_arprot  => m_arprot,
            M_AXI_GP0_arqos   => m_arqos,
            M_AXI_GP0_arready => m_arready,
            M_AXI_GP0_arsize  => m_arsize,
            M_AXI_GP0_arvalid => m_arvalid,
            M_AXI_GP0_awaddr  => m_awaddr,
            M_AXI_GP0_awburst => m_awburst,
            M_AXI_GP0_awcache => m_awcache,
            M_AXI_GP0_awid    => m_awid,
            M_AXI_GP0_awlen   => m_awlen,
            M_AXI_GP0_awlock  => m_awlock,
            M_AXI_GP0_awprot  => m_awprot,
            M_AXI_GP0_awqos   => m_awqos,
            M_AXI_GP0_awready => m_awready,
            M_AXI_GP0_awsize  => m_awsize,
            M_AXI_GP0_awvalid => m_awvalid,
            M_AXI_GP0_bid     => m_bid,
            M_AXI_GP0_bready  => m_bready,
            M_AXI_GP0_bresp   => m_bresp,
            M_AXI_GP0_bvalid  => m_bvalid,
            M_AXI_GP0_rdata   => m_rdata,
            M_AXI_GP0_rid     => m_rid,
            M_AXI_GP0_rlast   => m_rlast,
            M_AXI_GP0_rready  => m_rready,
            M_AXI_GP0_rresp   => m_rresp,
            M_AXI_GP0_rvalid  => m_rvalid,
            M_AXI_GP0_wdata   => m_wdata,
            M_AXI_GP0_wid     => m_wid,
            M_AXI_GP0_wlast   => m_wlast,
            M_AXI_GP0_wready  => m_wready,
            M_AXI_GP0_wstrb   => m_wstrb,
            M_AXI_GP0_wvalid  => m_wvalid
        );

    ---------------------------------------------------------------------------
    -- VHDL AXI slave, wired straight to the PS master
    ---------------------------------------------------------------------------
    u_axi_regs : entity work.axi_regs
        generic map (
            C_DATA_WIDTH => 32,
            C_ADDR_WIDTH => 32,
            C_ID_WIDTH   => 12
        )
        port map (
            reg_ps2pl_o   => reg_ps2pl,
            pl_active_o   => pl_active,
            s_axi_aclk    => clk,
            s_axi_aresetn => resetn,
            s_axi_awid    => m_awid,
            s_axi_awaddr  => m_awaddr,
            s_axi_awlen   => m_awlen,
            s_axi_awsize  => m_awsize,
            s_axi_awburst => m_awburst,
            s_axi_awlock  => m_awlock,
            s_axi_awcache => m_awcache,
            s_axi_awprot  => m_awprot,
            s_axi_awqos   => m_awqos,
            s_axi_awvalid => m_awvalid,
            s_axi_awready => m_awready,
            s_axi_wid     => m_wid,
            s_axi_wdata   => m_wdata,
            s_axi_wstrb   => m_wstrb,
            s_axi_wlast   => m_wlast,
            s_axi_wvalid  => m_wvalid,
            s_axi_wready  => m_wready,
            s_axi_bid     => m_bid,
            s_axi_bresp   => m_bresp,
            s_axi_bvalid  => m_bvalid,
            s_axi_bready  => m_bready,
            s_axi_arid    => m_arid,
            s_axi_araddr  => m_araddr,
            s_axi_arlen   => m_arlen,
            s_axi_arsize  => m_arsize,
            s_axi_arburst => m_arburst,
            s_axi_arlock  => m_arlock,
            s_axi_arcache => m_arcache,
            s_axi_arprot  => m_arprot,
            s_axi_arqos   => m_arqos,
            s_axi_arvalid => m_arvalid,
            s_axi_arready => m_arready,
            s_axi_rid     => m_rid,
            s_axi_rdata   => m_rdata,
            s_axi_rresp   => m_rresp,
            s_axi_rlast   => m_rlast,
            s_axi_rvalid  => m_rvalid,
            s_axi_rready  => m_rready
        );

    ---------------------------------------------------------------------------
    -- placeholder PL user logic (see axi_ps2pl earlier notes) - replace it
    ---------------------------------------------------------------------------
    heartbeat_proc : process (clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                heartbeat <= (others => '0');
            else
                heartbeat <= heartbeat + 1;
            end if;
        end if;
    end process;

    user_probe <= ("0000" & std_logic_vector(heartbeat)) xor reg_ps2pl(31 downto 0)
                  when pl_active = '1'
                  else reg_ps2pl(31 downto 0);

end architecture rtl;
