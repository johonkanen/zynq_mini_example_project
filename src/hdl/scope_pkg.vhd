-------------------------------------------------------------------------------
-- scope_pkg.vhd  (VHDL-2008)
--
-- Shared types for the oscilloscope capture (scope_capture.vhd), its test
-- signal generator (scope_siggen.vhd) and the axi_regs registers that drive
-- them: SCOPE_CH channels of 16-bit signed samples, 2**SCOPE_DEPTH_LOG2 deep.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package scope_pkg is

    constant SCOPE_CH         : natural := 4;
    constant SCOPE_DEPTH_LOG2 : natural := 12;             -- 4096 samples per channel
    constant SCOPE_DEPTH      : natural := 2**SCOPE_DEPTH_LOG2;
    constant SCOPE_DIV_BITS   : natural := 24;

    subtype sample_t is signed(15 downto 0);
    type sample_array_t is array (0 to SCOPE_CH-1) of sample_t;
    subtype src_sel_t is unsigned(3 downto 0);
    type src_sel_array_t is array (0 to SCOPE_CH-1) of src_sel_t;
    subtype ptr_t is unsigned(SCOPE_DEPTH_LOG2-1 downto 0);

    -- channel sources (SCOPE_SRC register), see scope_sources in zynq_mini_top
    constant SRC_ZERO       : natural := 0;
    constant SRC_SINE_A     : natural := 1;
    constant SRC_TRIANGLE_A : natural := 2;
    constant SRC_SQUARE_A   : natural := 3;
    constant SRC_SINE_B     : natural := 4;
    constant SRC_NOISE      : natural := 5;
    constant SRC_SINE_NOISE : natural := 6;
    constant SRC_OLED_SPI   : natural := 7;   -- bit0 SDIN, bit1 SCLK, bit2 RES#, bit3 D/C#
    constant SRC_EXT0       : natural := 8;   -- 8..11: ext inputs (an ADC later)
    type source_array_t is array (0 to 15) of sample_t;

    -- configuration, from axi_regs
    type scope_cfg_t is record
        arm          : std_logic;                          -- one-cycle pulses
        force_trig   : std_logic;
        abort        : std_logic;
        trig_ch      : unsigned(1 downto 0);
        trig_falling : std_logic;
        trig_level   : sample_t;
        pre          : ptr_t;                              -- samples kept before the trigger
        div          : unsigned(SCOPE_DIV_BITS-1 downto 0);-- sample every div clocks (0 = 1)
        src          : src_sel_array_t;
        ftw_a        : unsigned(31 downto 0);              -- generator A/B frequency
        ftw_b        : unsigned(31 downto 0);              --   f = ftw * fclk / 2**32
    end record;

    -- capture state, to axi_regs
    constant ST_IDLE  : unsigned(1 downto 0) := "00";       -- idle or done
    constant ST_FILL  : unsigned(1 downto 0) := "01";       -- filling the pre-trigger part
    constant ST_ARMED : unsigned(1 downto 0) := "10";       -- waiting for the trigger
    constant ST_POST  : unsigned(1 downto 0) := "11";       -- filling the post-trigger part

    type scope_stat_t is record
        state     : unsigned(1 downto 0);
        done      : std_logic;                             -- a capture is complete
        trig_cond : std_logic;                             -- trigger condition (0 = forced)
        trig_ptr  : ptr_t;                                 -- RAM index of the trigger sample
    end record;

end package scope_pkg;
