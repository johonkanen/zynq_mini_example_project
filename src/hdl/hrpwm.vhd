-------------------------------------------------------------------------------
-- hrpwm.vhd  (VHDL-2008)
--
-- High-resolution PWM with high-resolution frequency control: a 32-bit phase
-- accumulator (NCO) advanced every 1.25 ns tick (800 M ticks/s),
--
--   f    = FTW * 800 MHz / 2^32        (0.186 Hz steps at any frequency)
--   duty = DUTY / 2^32                 (fraction of the period, kept when f changes)
--
-- and four ways of putting the edges on a pin. An output is high while the phase
-- of its slot is below DUTY (sawtooth carrier) or within DUTY/2 of half a period
-- (symmetric carrier). Each output samples the phase on its own grid, so an edge
-- lands on the first grid slot after the ideal crossing: the period jitters by up
-- to one slot from pulse to pulse, but the mean frequency and duty are exact.
--
--   pwm_o(0)  IOB flip-flop at 100 MHz, sawtooth              10   ns grid
--   pwm_o(1)  ODDR at 100 MHz, symmetric                       5   ns grid per edge
--   pwm_o(2)  ODDR at 200 MHz, sawtooth                        2.5  ns grid
--   pwm_o(3)  OSERDESE2 8:1 DDR, CLK 400 / CLKDIV 100 MHz,     1.25 ns grid
--             sawtooth (800 Mb/s)
--
-- All patterns are computed in one 100 MHz domain as 8 slots of 1.25 ns per
-- clock: slot k of a clock has phase phi + k*FTW. The 200 and 400 MHz clocks come
-- from the same MMCM, so the outputs stay phase-locked to each other.
-- pwm_o must go straight to output pads (ODDR / OSERDES outputs).
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity hrpwm is
    port (
        clk    : in  std_logic;                       -- 100 MHz (FCLK_CLK0)
        ftw_i  : in  std_logic_vector(31 downto 0);   -- frequency word, any clock
        duty_i : in  std_logic_vector(31 downto 0);   -- duty fraction, any clock
        pwm_o  : out std_logic_vector(3 downto 0)
    );
end entity hrpwm;

architecture rtl of hrpwm is

    subtype phase_t is unsigned(31 downto 0);
    type phase_array_t is array (natural range <>) of phase_t;
    constant HALF : phase_t := x"80000000";

    signal clkfb, clkfb_buf                : std_logic;
    signal c100_mmcm, c200_mmcm, c400_mmcm : std_logic;
    signal c100, c200, c400                : std_logic;
    signal locked                          : std_logic;

    -- 100 MHz domain
    signal rst_sr : std_logic_vector(7 downto 0) := (others => '1');
    signal rst    : std_logic;
    signal f_meta, f_sync, f_prev : phase_t := (others => '0');
    signal d_meta, d_sync, d_prev : phase_t := (others => '0');
    signal ftw_k  : phase_array_t(0 to 8) := (others => (others => '0'));   -- k * FTW
    signal duty   : phase_t := (others => '0');
    signal sym_off : phase_t := (others => '0');      -- DUTY/2 - 1/2 period
    signal phi    : phase_t := (others => '0');
    signal p1     : std_logic := '0';
    signal p2     : std_logic_vector(1 downto 0) := (others => '0');
    signal p3     : std_logic_vector(3 downto 0) := (others => '0');
    signal p4     : std_logic_vector(7 downto 0) := (others => '0');
    signal tg     : std_logic := '0';

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of f_meta, f_sync, d_meta, d_sync : signal is "TRUE";
    attribute IOB : string;
    attribute IOB of p1 : signal is "TRUE";

    -- 200 MHz domain
    signal tg_r : std_logic := '0';
    signal o3   : std_logic_vector(1 downto 0) := (others => '0');

begin

    ---------------------------------------------------------------------------
    -- Clocks: VCO 800 MHz -> 100 / 200 / 400 MHz, all phase-aligned
    ---------------------------------------------------------------------------
    u_mmcm : MMCME2_BASE
        generic map (
            CLKIN1_PERIOD    => 10.0,
            DIVCLK_DIVIDE    => 1,
            CLKFBOUT_MULT_F  => 8.0,
            CLKOUT0_DIVIDE_F => 8.0,      -- 100 MHz
            CLKOUT1_DIVIDE   => 4,        -- 200 MHz
            CLKOUT2_DIVIDE   => 2         -- 400 MHz
        )
        port map (
            CLKIN1   => clk,
            CLKFBIN  => clkfb_buf,
            CLKFBOUT => clkfb,
            CLKOUT0  => c100_mmcm,
            CLKOUT1  => c200_mmcm,
            CLKOUT2  => c400_mmcm,
            LOCKED   => locked,
            PWRDWN   => '0',
            RST      => '0'
        );
    u_bfb  : BUFG port map (I => clkfb,     O => clkfb_buf);
    u_b100 : BUFG port map (I => c100_mmcm, O => c100);
    u_b200 : BUFG port map (I => c200_mmcm, O => c200);
    u_b400 : BUFG port map (I => c400_mmcm, O => c400);

    ---------------------------------------------------------------------------
    -- 100 MHz: reset, register hand-over, phase accumulator, slot patterns
    ---------------------------------------------------------------------------
    process (c100, locked)
    begin
        if locked = '0' then
            rst_sr <= (others => '1');
        elsif rising_edge(c100) then
            rst_sr <= rst_sr(6 downto 0) & '0';
        end if;
    end process;
    rst <= rst_sr(7);

    process (c100)
        variable ph : phase_t;
    begin
        if rising_edge(c100) then
            -- FTW / DUTY from the AXI clock domain: taken once stable for a clock
            f_meta <= unsigned(ftw_i);  f_sync <= f_meta;  f_prev <= f_sync;
            d_meta <= unsigned(duty_i); d_sync <= d_meta;  d_prev <= d_sync;
            if f_sync = f_prev then
                for k in 0 to 8 loop
                    ftw_k(k) <= resize(f_sync * to_unsigned(k, 4), 32);
                end loop;
            end if;
            if d_sync = d_prev then
                duty    <= d_sync;
                sym_off <= shift_right(d_sync, 1) - HALF;
            end if;

            -- phase continuous: a new FTW changes the slope, not the phase
            if rst = '1' then
                phi <= (others => '0');
            else
                phi <= phi + ftw_k(8);
            end if;
            tg <= not tg;

            -- 1: sawtooth, one slot of 10 ns
            if phi < duty then p1 <= '1'; else p1 <= '0'; end if;
            -- 2: symmetric about half a period, two slots of 5 ns:
            --    high while phase - (1/2 - DUTY/2) < DUTY
            for k in 0 to 1 loop
                ph := phi + ftw_k(4 * k) + sym_off;
                if ph < duty then p2(k) <= '1'; else p2(k) <= '0'; end if;
            end loop;
            -- 3: sawtooth, four slots of 2.5 ns
            for k in 0 to 3 loop
                ph := phi + ftw_k(2 * k);
                if ph < duty then p3(k) <= '1'; else p3(k) <= '0'; end if;
            end loop;
            -- 4: sawtooth, eight slots of 1.25 ns
            for k in 0 to 7 loop
                ph := phi + ftw_k(k);
                if ph < duty then p4(k) <= '1'; else p4(k) <= '0'; end if;
            end loop;
        end if;
    end process;

    -- 1: plain flip-flop, packed into the IOB
    pwm_o(0) <= p1;

    -- 2: ODDR at 100 MHz, D1 = first half of the clock
    u_oddr2 : ODDR
        generic map (DDR_CLK_EDGE => "SAME_EDGE", INIT => '0', SRTYPE => "SYNC")
        port map (Q => pwm_o(1), C => c100, CE => '1', D1 => p2(0), D2 => p2(1), R => '0', S => '0');

    ---------------------------------------------------------------------------
    -- 3: 200 MHz ODDR. Both 200 MHz edges inside one 100 MHz clock see the same
    -- p3; tg tells which of them is the first (it changed since the last edge).
    ---------------------------------------------------------------------------
    process (c200)
    begin
        if rising_edge(c200) then
            tg_r <= tg;
            if tg /= tg_r then
                o3 <= p3(1) & p3(0);
            else
                o3 <= p3(3) & p3(2);
            end if;
        end if;
    end process;

    u_oddr3 : ODDR
        generic map (DDR_CLK_EDGE => "SAME_EDGE", INIT => '0', SRTYPE => "SYNC")
        port map (Q => pwm_o(2), C => c200, CE => '1', D1 => o3(0), D2 => o3(1), R => '0', S => '0');

    ---------------------------------------------------------------------------
    -- 4: OSERDESE2 8:1 DDR, D1 goes out first
    ---------------------------------------------------------------------------
    u_oserdes4 : OSERDESE2
        generic map (
            DATA_RATE_OQ   => "DDR",
            DATA_RATE_TQ   => "SDR",
            DATA_WIDTH     => 8,
            TRISTATE_WIDTH => 1,
            SERDES_MODE    => "MASTER",
            INIT_OQ        => '0'
        )
        port map (
            OQ        => pwm_o(3),
            CLK       => c400,
            CLKDIV    => c100,
            D1 => p4(0), D2 => p4(1), D3 => p4(2), D4 => p4(3),
            D5 => p4(4), D6 => p4(5), D7 => p4(6), D8 => p4(7),
            OCE       => '1',
            RST       => rst,
            T1 => '0', T2 => '0', T3 => '0', T4 => '0',
            TCE       => '0',
            TBYTEIN   => '0',
            SHIFTIN1  => '0',
            SHIFTIN2  => '0',
            OFB       => open,
            TQ        => open,
            TFB       => open,
            TBYTEOUT  => open,
            SHIFTOUT1 => open,
            SHIFTOUT2 => open
        );

end architecture rtl;
