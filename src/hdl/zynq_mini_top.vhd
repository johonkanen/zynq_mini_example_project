-------------------------------------------------------------------------------
-- zynq_mini_top.vhd  (VHDL-2008)
--
-- Hand-written top level. It instantiates the "zynq_mini" block design (just the
-- PS7 - DDR3 / Ethernet / QSPI / eMMC / microSD / UART1, with M_AXI_GP0 and the
-- PL clock/reset routed straight to the boundary), packs the flat M_AXI_GP0
-- signals into the axi_pkg direction records and hands them to axi_regs, an
-- AXI slave written in VHDL. No AXI interconnect IP anywhere.
--
--   zynq_mini_top
--     +-- u_bd : zynq_mini    (PS7; M_AXI_GP0_* + FCLK_CLK0/FCLK_RESET0_N)
--     +-- u_axi_regs : axi_regs   <- AXI slave, records from axi_pkg
--     +-- placeholder PL user logic
--
-- Entity ports = the physical device pins only (DDR_* + FIXED_IO_*), which the
-- PS7 IP constrains automatically.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.axi_pkg.all;

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

    signal clk    : std_logic;
    signal resetn : std_logic;

    -- M_AXI_GP0 as direction records (axi_pkg)
    signal ps_i : axi_mosi_t;   -- PS master -> slave
    signal ps_o : axi_miso_t;   -- slave -> PS master

    -- register view from the AXI slave
    signal reg_ps2pl : std_logic_vector(127 downto 0);
    signal pl_active : std_logic;

    -- ===== placeholder PL user logic ====================================
    signal heartbeat  : unsigned(27 downto 0) := (others => '0');
    signal user_probe : std_logic_vector(31 downto 0);
    attribute keep : string;
    attribute keep of user_probe : signal is "true";

begin

    ---------------------------------------------------------------------------
    -- Block design (PS7). The flat M_AXI_GP0 pins map straight onto the record
    -- fields - master outputs into ps_i, slave outputs (from us) into ps_o.
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
            M_AXI_GP0_araddr  => ps_i.ar.addr,
            M_AXI_GP0_arburst => ps_i.ar.burst,
            M_AXI_GP0_arcache => ps_i.ar.cache,
            M_AXI_GP0_arid    => ps_i.ar.id,
            M_AXI_GP0_arlen   => ps_i.ar.len,
            M_AXI_GP0_arlock  => ps_i.ar.lock,
            M_AXI_GP0_arprot  => ps_i.ar.prot,
            M_AXI_GP0_arqos   => ps_i.ar.qos,
            M_AXI_GP0_arready => ps_o.arready,
            M_AXI_GP0_arsize  => ps_i.ar.size,
            M_AXI_GP0_arvalid => ps_i.ar.valid,
            M_AXI_GP0_awaddr  => ps_i.aw.addr,
            M_AXI_GP0_awburst => ps_i.aw.burst,
            M_AXI_GP0_awcache => ps_i.aw.cache,
            M_AXI_GP0_awid    => ps_i.aw.id,
            M_AXI_GP0_awlen   => ps_i.aw.len,
            M_AXI_GP0_awlock  => ps_i.aw.lock,
            M_AXI_GP0_awprot  => ps_i.aw.prot,
            M_AXI_GP0_awqos   => ps_i.aw.qos,
            M_AXI_GP0_awready => ps_o.awready,
            M_AXI_GP0_awsize  => ps_i.aw.size,
            M_AXI_GP0_awvalid => ps_i.aw.valid,
            M_AXI_GP0_bid     => ps_o.b.id,
            M_AXI_GP0_bready  => ps_i.bready,
            M_AXI_GP0_bresp   => ps_o.b.resp,
            M_AXI_GP0_bvalid  => ps_o.b.valid,
            M_AXI_GP0_rdata   => ps_o.r.data,
            M_AXI_GP0_rid     => ps_o.r.id,
            M_AXI_GP0_rlast   => ps_o.r.last,
            M_AXI_GP0_rready  => ps_i.rready,
            M_AXI_GP0_rresp   => ps_o.r.resp,
            M_AXI_GP0_rvalid  => ps_o.r.valid,
            M_AXI_GP0_wdata   => ps_i.w.data,
            M_AXI_GP0_wid     => ps_i.w.id,
            M_AXI_GP0_wlast   => ps_i.w.last,
            M_AXI_GP0_wready  => ps_o.wready,
            M_AXI_GP0_wstrb   => ps_i.w.strb,
            M_AXI_GP0_wvalid  => ps_i.w.valid
        );

    ---------------------------------------------------------------------------
    -- VHDL AXI slave, wired straight to the PS master (records)
    ---------------------------------------------------------------------------
    u_axi_regs : entity work.axi_regs
        port map (
            reg_ps2pl_o   => reg_ps2pl,
            pl_active_o   => pl_active,
            s_axi_aclk    => clk,
            s_axi_aresetn => resetn,
            s_axi_i       => ps_i,
            s_axi_o       => ps_o
        );

    ---------------------------------------------------------------------------
    -- placeholder PL user logic - replace it
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
