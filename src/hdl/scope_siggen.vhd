-------------------------------------------------------------------------------
-- scope_siggen.vhd  (VHDL-2008)
--
-- Test signals for the oscilloscope, so it has something to look at without an
-- ADC: two DDS generators (32-bit phase accumulators, f = ftw * fclk / 2**32)
-- and a 16-bit LFSR. All outputs are 16-bit signed, registered.
--
--   sine_a, triangle_a, square_a   generator A (amplitude +-30000)
--   sine_b                         generator B
--   noise                          LFSR, full scale
--   sine_noise                     sine_a / 2 + noise / 8
--
-- The 1024-entry sine table is computed at elaboration with ieee.math_real.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.scope_pkg.all;

entity scope_siggen is
    port (
        clk        : in  std_logic;
        resetn     : in  std_logic;
        ftw_a      : in  unsigned(31 downto 0);
        ftw_b      : in  unsigned(31 downto 0);
        sine_a     : out sample_t;
        triangle_a : out sample_t;
        square_a   : out sample_t;
        sine_b     : out sample_t;
        noise      : out sample_t;
        sine_noise : out sample_t
    );
end entity scope_siggen;

architecture rtl of scope_siggen is

    constant AMPL : real := 30000.0;

    type sine_rom_t is array (0 to 1023) of sample_t;

    function make_sine return sine_rom_t is
        variable r : sine_rom_t;
    begin
        for i in r'range loop
            r(i) := to_signed(integer(round(AMPL * sin(MATH_2_PI * real(i) / 1024.0))), 16);
        end loop;
        return r;
    end function;

    constant SINE : sine_rom_t := make_sine;

    signal phase_a, phase_b : unsigned(31 downto 0) := (others => '0');
    signal lfsr             : std_logic_vector(15 downto 0) := x"ACE1";
    signal sine_a_r         : sample_t := (others => '0');

begin

    sine_a <= sine_a_r;

    process (clk)
        variable p   : unsigned(15 downto 0);
        variable tri : unsigned(15 downto 0);
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                phase_a <= (others => '0');
                phase_b <= (others => '0');
                lfsr    <= x"ACE1";
            else
                phase_a <= phase_a + ftw_a;
                phase_b <= phase_b + ftw_b;
                -- Galois LFSR x^16 + x^14 + x^13 + x^11 + 1
                if lfsr(0) = '1' then
                    lfsr <= ('0' & lfsr(15 downto 1)) xor x"B400";
                else
                    lfsr <= '0' & lfsr(15 downto 1);
                end if;
            end if;

            sine_a_r <= SINE(to_integer(phase_a(31 downto 22)));
            sine_b   <= SINE(to_integer(phase_b(31 downto 22)));

            -- triangle: up over the first half period, down over the second
            p := phase_a(31 downto 16);
            if p(15) = '0' then
                tri := p(14 downto 0) & '0';
            else
                tri := not (p(14 downto 0) & '0');
            end if;
            -- 0..65535 -> -30000..+29999 (x 60000/65536 = 1875/2048, fits an integer)
            triangle_a <= to_signed(to_integer(tri) * 1875 / 2048 - integer(AMPL), 16);

            if phase_a(31) = '0' then
                square_a <= to_signed(integer(AMPL), 16);
            else
                square_a <= to_signed(-integer(AMPL), 16);
            end if;

            noise      <= signed(lfsr);
            sine_noise <= shift_right(sine_a_r, 1) + shift_right(signed(lfsr), 3);
        end if;
    end process;

end architecture rtl;
