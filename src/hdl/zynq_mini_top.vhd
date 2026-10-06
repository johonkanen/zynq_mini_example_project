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
--     +-- u_oled : ssd1306_text     (128x64 OLED, text from axi_regs OLED_TEXT)
--     +-- u_siggen : scope_siggen   (oscilloscope test signals)
--     +-- u_scope : scope_capture   (4-channel triggered capture, read via axi_regs)
--     +-- placeholder PL user logic
--
-- Entity ports = the physical device pins: DDR_* + FIXED_IO_* (constrained
-- automatically by the PS7 IP) and the OLED pins (src/constrs/zynq_mini.xdc).
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.axi_pkg.all;
use work.scope_pkg.all;

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
        FIXED_IO_ps_srstb : inout std_logic;

        -- 0.96" SSD1306 OLED, 4-wire SPI (J4)
        oled_sclk         : out std_logic;
        oled_sdin         : out std_logic;
        oled_dc           : out std_logic;
        oled_res_n        : out std_logic
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

    -- OLED driver <-> axi_regs
    signal oled_ctrl      : std_logic_vector(31 downto 0);
    signal oled_stat      : std_logic_vector(31 downto 0);
    signal oled_char_addr : std_logic_vector(6 downto 0);
    signal oled_char      : std_logic_vector(7 downto 0);
    signal oled_ready     : std_logic;
    signal oled_frames    : std_logic_vector(15 downto 0);
    signal oled_pins      : std_logic_vector(3 downto 0);   -- SDIN, SCLK, RES#, D/C#

    -- oscilloscope
    signal scope_cfg      : scope_cfg_t;
    signal scope_stat     : scope_stat_t;
    signal scope_rd_addr  : unsigned(SCOPE_DEPTH_LOG2 downto 0);
    signal scope_rd_data  : std_logic_vector(31 downto 0);
    signal sources        : source_array_t := (others => (others => '0'));
    signal scope_in       : sample_array_t := (others => (others => '0'));
    signal ext_in         : sample_array_t := (others => (others => '0'));  -- for an ADC later

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
            oled_ctrl_o      => oled_ctrl,
            oled_stat_i      => oled_stat,
            oled_char_addr_i => oled_char_addr,
            oled_char_o      => oled_char,
            scope_cfg_o      => scope_cfg,
            scope_stat_i     => scope_stat,
            scope_rd_addr_o  => scope_rd_addr,
            scope_rd_data_i  => scope_rd_data,
            s_axi_aclk    => clk,
            s_axi_aresetn => resetn,
            s_axi_i       => ps_axi_o,
            s_axi_o       => ps_axi_i
        );

    ---------------------------------------------------------------------------
    -- SSD1306 OLED: shows the axi_regs text buffer ("Hello, Zynq Mini" at reset)
    ---------------------------------------------------------------------------
    u_oled : entity work.ssd1306_text
        generic map (CLK_HZ => 100_000_000)        -- FCLK_CLK0 (scripts/config.tcl)
        port map (
            clk         => clk,
            resetn      => resetn,
            display_on  => oled_ctrl(0),
            invert      => oled_ctrl(1),
            flip        => oled_ctrl(2),
            contrast    => oled_ctrl(15 downto 8),
            char_addr_o => oled_char_addr,
            char_i      => oled_char,
            ready_o     => oled_ready,
            frames_o    => oled_frames,
            oled_sclk   => oled_pins(1),
            oled_sdin   => oled_pins(0),
            oled_dc     => oled_pins(3),
            oled_res_n  => oled_pins(2)
        );

    oled_sdin  <= oled_pins(0);
    oled_sclk  <= oled_pins(1);
    oled_res_n <= oled_pins(2);
    oled_dc    <= oled_pins(3);
    oled_stat  <= oled_frames & x"000" & "000" & oled_ready;

    ---------------------------------------------------------------------------
    -- Oscilloscope: test signals + the OLED's SPI pins -> 4 channels -> capture
    ---------------------------------------------------------------------------
    u_siggen : entity work.scope_siggen
        port map (
            clk        => clk,
            resetn     => resetn,
            ftw_a      => scope_cfg.ftw_a,
            ftw_b      => scope_cfg.ftw_b,
            sine_a     => sources(SRC_SINE_A),
            triangle_a => sources(SRC_TRIANGLE_A),
            square_a   => sources(SRC_SQUARE_A),
            sine_b     => sources(SRC_SINE_B),
            noise      => sources(SRC_NOISE),
            sine_noise => sources(SRC_SINE_NOISE)
        );

    -- the real SPI lines, as a 4-bit logic value: D/C# high <=> value >= 8
    sources(SRC_OLED_SPI) <= resize(signed('0' & oled_pins), 16);
    ext_src : for i in 0 to SCOPE_CH-1 generate
        sources(SRC_EXT0 + i) <= ext_in(i);
    end generate;
    sources(SRC_ZERO) <= (others => '0');
    unused_src : for i in SRC_EXT0 + SCOPE_CH to 15 generate
        sources(i) <= (others => '0');
    end generate;

    source_mux : process (clk)
    begin
        if rising_edge(clk) then
            for i in 0 to SCOPE_CH-1 loop
                scope_in(i) <= sources(to_integer(scope_cfg.src(i)));
            end loop;
        end if;
    end process;

    u_scope : entity work.scope_capture
        port map (
            clk     => clk,
            resetn  => resetn,
            cfg     => scope_cfg,
            ch_i    => scope_in,
            stat_o  => scope_stat,
            rd_addr => scope_rd_addr,
            rd_data => scope_rd_data
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
