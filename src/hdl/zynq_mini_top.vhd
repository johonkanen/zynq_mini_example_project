-------------------------------------------------------------------------------
-- zynq_mini_top.vhd  (VHDL-2008)
--
-- Synthesis top. Wires the PS (via zynq_ps_wrapper, which hides the block
-- design and the flat M_AXI_GP0 pins behind the axi_pkg records) to axi_regs,
-- a VHDL AXI slave. The PS <-> PL bus is just two record signals.
--
--   zynq_mini_top
--     +-- u_ps  : zynq_ps_wrapper   (block design + M_AXI_GP0 -> records)
--     +-- u_axi_regs : axi_regs     (AXI slave, VHDL)
--     +-- placeholder PL user logic
--
-- Entity ports = the physical device pins only (DDR_* + FIXED_IO_*), which the
-- PS7 IP constrains automatically. Add a port here + a line in
-- src/constrs/zynq_mini.xdc for any real PL I/O.
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

    signal clk    : std_logic;
    signal resetn : std_logic;

    -- the whole PS <-> PL AXI bus
    signal ps_axi_o : axi_mosi_t;   -- PS master -> slave
    signal ps_axi_i : axi_miso_t;   -- slave -> PS master

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
    -- Processing system (block design + M_AXI_GP0 packed into records)
    ---------------------------------------------------------------------------
    u_ps : entity work.zynq_ps_wrapper
        port map (
            clk               => clk,
            resetn            => resetn,
            m_axi_o           => ps_axi_o,
            m_axi_i           => ps_axi_i,
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
            FIXED_IO_ddr_vrn  => FIXED_IO_ddr_vrn,
            FIXED_IO_ddr_vrp  => FIXED_IO_ddr_vrp,
            FIXED_IO_mio      => FIXED_IO_mio,
            FIXED_IO_ps_clk   => FIXED_IO_ps_clk,
            FIXED_IO_ps_porb  => FIXED_IO_ps_porb,
            FIXED_IO_ps_srstb => FIXED_IO_ps_srstb
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
            s_axi_i       => ps_axi_o,
            s_axi_o       => ps_axi_i
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
