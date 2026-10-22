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
--     +-- u_hrpwm : hrpwm           (high-resolution PWM on the EXT IO header)
--     +-- PL Ethernet: PL_ETH = 0 -> GEM1 through the BD's gmii_to_rgmii (Linux eth1)
--                      PL_ETH = 1 -> u_eth_mac: hVHDL_gigabit_ethernet's MAC in the PL (echo test)
--       + the PHY reset (both)
--     +-- placeholder PL user logic
--
-- Entity ports = the physical device pins: DDR_* + FIXED_IO_* (constrained
-- automatically by the PS7 IP), the OLED, EXT IO header and PL Ethernet pins
-- (src/constrs/zynq_mini.xdc).
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

use work.axi_pkg.all;
use work.scope_pkg.all;

entity zynq_mini_top is
    generic (
        BUILD_ID : std_logic_vector(31 downto 0) := x"00000000";  -- scripts/build.tcl: Unix time
        PL_ETH   : natural := 0         -- scripts/build.tcl (PL_ETH env): 0 = GEM1/eth1, 1 = hVHDL MAC
    );
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
        oled_res_n        : out std_logic;

        -- 40-pin EXT IO header (CAM1), indexed by header pin number; pins 1, 19-22
        -- and 40 are power. Pins 17/15/14/18 (scope CH1..CH4) carry the high-resolution
        -- PWM test (hrpwm); the others the identification test: pin n toggles at n*10 kHz.
        ext_lo            : out std_logic_vector(18 downto 2);
        ext_hi            : out std_logic_vector(39 downto 23);

        -- second Ethernet: RTL8211E on PL pins (GEM1 -> eth1, or the hVHDL MAC: PL_ETH)
        eth_rgmii_td      : out   std_logic_vector(3 downto 0);
        eth_rgmii_tx_ctl  : out   std_logic;
        eth_rgmii_txc     : out   std_logic;
        eth_rgmii_rd      : in    std_logic_vector(3 downto 0);
        eth_rgmii_rx_ctl  : in    std_logic;
        eth_rgmii_rxc     : in    std_logic;
        eth_mdc           : out   std_logic;
        eth_mdio          : inout std_logic;
        eth_phy_rst_n     : out   std_logic
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

    -- PL Ethernet PHY reset: held after configuration, then released
    constant PHY_RESET_CLKS : natural := 2_000_000;           -- 20 ms at 100 MHz (>= 10 ms)
    signal phy_rst_cnt : natural range 0 to PHY_RESET_CLKS := 0;

    -- the GMII-to-RGMII converter's side (PL_ETH = 0)
    signal ps_rgmii_td                : std_logic_vector(3 downto 0);
    signal ps_rgmii_tx_ctl, ps_rgmii_txc : std_logic;
    signal ps_rgmii_rd                : std_logic_vector(3 downto 0) := (others => '0');
    signal ps_rgmii_rx_ctl, ps_rgmii_rxc : std_logic := '0';
    signal ps_mdc, ps_mdio_i, ps_mdio_o, ps_mdio_t : std_logic;

    -- axi_regs FEATURES and its ETH window (the PL MAC's registers, PL_ETH = 1)
    function features_word(pl_eth : natural) return std_logic_vector is
        variable f : std_logic_vector(31 downto 0) := (others => '0');
    begin
        if pl_eth /= 0 then
            f(0) := '1';                                -- the PL Ethernet MAC is there
        end if;
        return f;
    end function;
    constant FEATURES : std_logic_vector(31 downto 0) := features_word(PL_ETH);
    signal eth_bus_req, eth_bus_write : std_logic;
    signal eth_bus_addr  : std_logic_vector(10 downto 0);
    signal eth_bus_wdata : std_logic_vector(31 downto 0);
    signal eth_bus_rdata : std_logic_vector(31 downto 0) := (others => '0');
    signal eth_bus_ack   : std_logic := '0';
    -- the PL MAC's UDP commands: register access (axi_regs udp_*) and the scope's capture
    signal eth_reg_req, eth_reg_write : std_logic := '0';
    signal eth_reg_addr  : std_logic_vector(15 downto 0) := (others => '0');
    signal eth_reg_wdata : std_logic_vector(31 downto 0) := (others => '0');
    signal eth_reg_rdata : std_logic_vector(31 downto 0);
    signal eth_reg_ack   : std_logic;
    signal eth_scope_clk : std_logic := '0';
    signal eth_scope_addr  : ptr_t := (others => '0');
    signal eth_scope_data  : std_logic_vector(63 downto 0);
    signal eth_scope_start : ptr_t;

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
        generic map (PL_ETH => PL_ETH)
        port map (
            clk               => clk,
            resetn            => resetn,
            m_axi_o           => ps_axi_o,
            m_axi_i           => ps_axi_i,
            rgmii_td          => ps_rgmii_td,
            rgmii_tx_ctl      => ps_rgmii_tx_ctl,
            rgmii_txc         => ps_rgmii_txc,
            rgmii_rd          => ps_rgmii_rd,
            rgmii_rx_ctl      => ps_rgmii_rx_ctl,
            rgmii_rxc         => ps_rgmii_rxc,
            mdio_mdc          => ps_mdc,
            mdio_i            => ps_mdio_i,
            mdio_o            => ps_mdio_o,
            mdio_t            => ps_mdio_t,
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
        generic map (BUILD_ID => BUILD_ID)
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
            features_i       => FEATURES,
            ext_req_o        => eth_bus_req,
            ext_write_o      => eth_bus_write,
            ext_addr_o       => eth_bus_addr,
            ext_wdata_o      => eth_bus_wdata,
            ext_rdata_i      => eth_bus_rdata,
            ext_ack_i        => eth_bus_ack,
            udp_req_i        => eth_reg_req,
            udp_write_i      => eth_reg_write,
            udp_addr_i       => eth_reg_addr,
            udp_wdata_i      => eth_reg_wdata,
            udp_rdata_o      => eth_reg_rdata,
            udp_ack_o        => eth_reg_ack,
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
            rd_data => scope_rd_data,
            rd2_clk  => eth_scope_clk,
            rd2_addr => eth_scope_addr,
            rd2_data => eth_scope_data
        );
    -- the capture's first sample in the RAM (scope_capture.vhd), for the PL MAC's stream
    eth_scope_start <= scope_stat.trig_ptr - scope_cfg.pre;

    ---------------------------------------------------------------------------
    -- PL Ethernet PHY: the RTL8211E's reset pin is wired to the PL (G17); keep it
    -- in reset for 20 ms after the design starts, then let it run. Not tied to
    -- FCLK_RESET0_N, so a PS-side PL reset doesn't drop the link.
    ---------------------------------------------------------------------------
    phy_reset_proc : process (clk)
    begin
        if rising_edge(clk) then
            if phy_rst_cnt /= PHY_RESET_CLKS then
                phy_rst_cnt <= phy_rst_cnt + 1;
            end if;
        end if;
    end process;
    eth_phy_rst_n <= '1' when phy_rst_cnt = PHY_RESET_CLKS else '0';

    ---------------------------------------------------------------------------
    -- PL Ethernet pins: GEM1's converter (Linux eth1) or the hVHDL MAC
    ---------------------------------------------------------------------------
    gen_eth_gem1 : if PL_ETH = 0 generate
        eth_rgmii_td     <= ps_rgmii_td;
        eth_rgmii_tx_ctl <= ps_rgmii_tx_ctl;
        eth_rgmii_txc    <= ps_rgmii_txc;
        ps_rgmii_rd      <= eth_rgmii_rd;
        ps_rgmii_rx_ctl  <= eth_rgmii_rx_ctl;
        ps_rgmii_rxc     <= eth_rgmii_rxc;
        eth_mdc          <= ps_mdc;
        u_mdio_buf : IOBUF
            port map (I => ps_mdio_o, O => ps_mdio_i, T => ps_mdio_t, IO => eth_mdio);
    end generate;

    -- hVHDL_gigabit_ethernet's ethernet_mac in the PL (doc/hvhdl_ethernet.md): the
    -- echo test. It owns the PHY, MDIO included.
    gen_eth_hvhdl : if PL_ETH /= 0 generate
        u_eth_mac : entity work.eth_mac
            port map (
                clk          => clk,
                rgmii_rxc    => eth_rgmii_rxc,
                rgmii_rd     => eth_rgmii_rd,
                rgmii_rx_ctl => eth_rgmii_rx_ctl,
                rgmii_txc    => eth_rgmii_txc,
                rgmii_td     => eth_rgmii_td,
                rgmii_tx_ctl => eth_rgmii_tx_ctl,
                mdc          => eth_mdc,
                mdio         => eth_mdio,
                bus_req      => eth_bus_req,
                bus_write    => eth_bus_write,
                bus_addr     => eth_bus_addr,
                bus_wdata    => eth_bus_wdata,
                bus_rdata    => eth_bus_rdata,
                bus_ack      => eth_bus_ack,
                reg_req      => eth_reg_req,
                reg_write    => eth_reg_write,
                reg_addr     => eth_reg_addr,
                reg_wdata    => eth_reg_wdata,
                reg_rdata    => eth_reg_rdata,
                reg_ack      => eth_reg_ack,
                scope_clk    => eth_scope_clk,
                scope_addr   => eth_scope_addr,
                scope_data   => eth_scope_data,
                scope_done   => scope_stat.done,
                scope_start  => eth_scope_start,
                echoed       => open,
                ignored      => open
            );
        ps_mdio_i <= '1';
    end generate;

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

    ---------------------------------------------------------------------------
    -- EXT IO pin identification: header pin n -> square wave at n * 10 kHz
    ---------------------------------------------------------------------------
    ext_id : for n in 2 to 39 generate
        constant HALF : positive := (5_000 + n / 2) / n;   -- 100 MHz / (2 * n * 10 kHz)
        signal cnt : natural range 0 to HALF - 1 := 0;
        signal q   : std_logic := '0';
    begin
        sig : if (n <= 18 or n >= 23) and n /= 14 and n /= 15 and n /= 17 and n /= 18 generate
            process (clk)
            begin
                if rising_edge(clk) then
                    if cnt = HALF - 1 then
                        cnt <= 0;
                        q   <= not q;
                    else
                        cnt <= cnt + 1;
                    end if;
                end if;
            end process;
            lo : if n <= 18 generate ext_lo(n) <= q; end generate;
            hi : if n >= 23 generate ext_hi(n) <= q; end generate;
        end generate;
    end generate;

    ---------------------------------------------------------------------------
    -- High-resolution PWM test: f = SCRATCH0 * 800 MHz / 2^32, duty = SCRATCH1 / 2^32
    ---------------------------------------------------------------------------
    u_hrpwm : entity work.hrpwm
        port map (
            clk      => clk,
            ftw_i    => reg_ps2pl(31 downto 0),
            duty_i   => reg_ps2pl(63 downto 32),
            pwm_o(0) => ext_lo(17),     -- CH1: 100 MHz flip-flop, sawtooth
            pwm_o(1) => ext_lo(15),     -- CH2: 100 MHz ODDR, symmetric
            pwm_o(2) => ext_lo(14),     -- CH3: 200 MHz ODDR
            pwm_o(3) => ext_lo(18)      -- CH4: OSERDES, 400 MHz DDR
        );

    user_probe <= ("0000" & std_logic_vector(heartbeat)) xor reg_ps2pl(31 downto 0)
                  when pl_active = '1'
                  else reg_ps2pl(31 downto 0);

end architecture rtl;
