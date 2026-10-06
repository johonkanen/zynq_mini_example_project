-------------------------------------------------------------------------------
-- tb_ssd1306_text.vhd  (VHDL-2008, VUnit)
--
-- ssd1306_text against a model of the panel's 4-wire SPI input: every byte
-- clocked in on SCLK rising edges is logged with its D/C# level, then the
-- tests check the reset/init sequence, the per-frame commands and that the
-- 1024 display bytes are the character buffer rendered through the font.
--
--   Run:  python sim/run.py            (NVC backend, see sim/run.py)
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

use work.font8x8_pkg.glyph;

entity tb_ssd1306_text is
    generic (runner_cfg : string);
end entity;

architecture sim of tb_ssd1306_text is

    subtype oled_byte_t is std_logic_vector(7 downto 0);

    constant TCLK   : time := 10 ns;    -- 100 MHz
    constant N_INIT : natural := 20;
    constant N_CMD  : natural := 12;
    constant N_FRAME: natural := N_CMD + 1024;

    signal clk     : std_logic := '0';
    signal resetn  : std_logic := '0';
    signal running : boolean := true;

    signal display_on : std_logic := '1';
    signal invert     : std_logic := '0';
    signal flip       : std_logic := '0';
    signal contrast   : std_logic_vector(7 downto 0) := x"7F";

    signal char_addr : std_logic_vector(6 downto 0);
    signal char      : std_logic_vector(7 downto 0);
    signal ready     : std_logic;
    signal frames    : std_logic_vector(15 downto 0);

    signal sclk, sdin, dc, res_n : std_logic;

    -- character buffer: 8 rows x 16
    constant TEXT : string(1 to 128) :=
        "Hello, Zynq Mini" & "0123456789ABCDEF" & "abcdefghijklmnop" & "  !""#$%&'()*+,-." &
        "row 4           " & "row 5           " & "row 6           " & "last row ~~~~~~~";

    -- what the panel received: bit 8 = D/C#, bits 7..0 = byte
    type rx_array_t is array (0 to 4095) of std_logic_vector(8 downto 0);
    signal rx     : rx_array_t;
    signal rx_n   : natural := 0;
    signal res_seen_low : boolean := false;

    type byte_array_t is array (natural range <>) of oled_byte_t;
    constant INIT_EXPECT : byte_array_t(0 to N_INIT-1) := (
        x"AE", x"D5", x"80", x"A8", x"3F", x"D3", x"00", x"40", x"8D", x"14", x"20",
        x"00", x"DA", x"12", x"D9", x"F1", x"DB", x"40", x"2E", x"A4");
    constant GLYPH_H : byte_array_t(0 to 7) :=
        (x"7F", x"7F", x"08", x"08", x"7F", x"7F", x"00", x"00");

begin

    clk_gen : process
    begin
        while running loop
            clk <= '0'; wait for TCLK/2;
            clk <= '1'; wait for TCLK/2;
        end loop;
        wait;
    end process;

    dut : entity work.ssd1306_text
        generic map (CLK_HZ => 100_000_000, SPI_HZ => 25_000_000,   -- 2 clk per SCLK phase
                     FRAME_HZ => 10_000, RESET_US => 1)            -- frames back to back
        port map (
            clk => clk, resetn => resetn,
            display_on => display_on, invert => invert, flip => flip, contrast => contrast,
            char_addr_o => char_addr, char_i => char,
            ready_o => ready, frames_o => frames,
            oled_sclk => sclk, oled_sdin => sdin, oled_dc => dc, oled_res_n => res_n);

    char <= std_logic_vector(to_unsigned(character'pos(TEXT(to_integer(unsigned(char_addr)) + 1)), 8));

    -- panel model: SPI mode 0 receiver
    panel : process
        variable sh : std_logic_vector(7 downto 0);
        variable nb : natural;
    begin
        rx_n <= 0;
        res_seen_low <= false;
        nb := 0;
        wait until resetn = '1';
        res_seen_low <= res_n = '0';            -- the driver holds RES# low out of reset
        loop
            wait until rising_edge(sclk) or res_n = '0' or resetn = '0';
            exit when resetn = '0';
            if res_n = '0' then
                res_seen_low <= true;
            end if;
            if rising_edge(sclk) then
                check(res_seen_low and res_n = '1', "SCLK only after a RES# pulse");
                check(sdin'last_event >= 15 ns, "SDIN setup before SCLK rise");
                check(dc'last_event   >= 15 ns, "D/C# setup before SCLK rise");
                sh := sh(6 downto 0) & sdin;
                nb := nb + 1;
                if nb = 8 then
                    rx(rx_n) <= dc & sh;
                    rx_n <= rx_n + 1;
                    nb := 0;
                end if;
            end if;
        end loop;
    end process;

    main : process

        procedure wait_rx(n : natural) is
        begin
            while rx_n < n loop wait until rx_n'event; end loop;
        end procedure;

        procedure check_cmd(i : natural; b : oled_byte_t; msg : string) is
        begin
            check_equal(rx(i)(8), '0', msg & ": D/C# low (command)");
            check_equal(rx(i)(7 downto 0), b, msg);
        end procedure;

        -- frame starting at rx index f: per-frame commands, then the text
        procedure check_frame(f : natural; dsp_on, inv, flp : std_logic; con : oled_byte_t) is
            variable c  : oled_byte_t;
            variable ch : natural;
        begin
            wait_rx(f + N_FRAME);
            check_cmd(f + 0, x"A0" or ("0000000" & not flp), "segment remap");
            check_cmd(f + 1, x"C0" or ("0000" & not flp & "000"), "COM scan direction");
            check_cmd(f + 2, x"81", "contrast cmd");
            check_cmd(f + 3, con, "contrast value");
            check_cmd(f + 4, x"A6" or ("0000000" & inv), "normal/inverse");
            check_cmd(f + 5, x"AE" or ("0000000" & dsp_on), "display on/off");
            check_cmd(f + 6, x"21", "column window");
            check_cmd(f + 7, x"00", "column start");
            check_cmd(f + 8, x"7F", "column end");
            check_cmd(f + 9, x"22", "page window");
            check_cmd(f + 10, x"00", "page start");
            check_cmd(f + 11, x"07", "page end");
            for n in 0 to 1023 loop
                ch := (n / 128) * 16 + (n mod 128) / 8;
                c  := glyph(std_logic_vector(to_unsigned(character'pos(TEXT(ch + 1)), 8)),
                            to_unsigned(n mod 8, 3));
                check_equal(rx(f + N_CMD + n)(8), '1', "data byte " & integer'image(n) & " D/C# high");
                check_equal(rx(f + N_CMD + n)(7 downto 0), c, "data byte " & integer'image(n));
            end loop;
        end procedure;

    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop
            resetn <= '0';
            display_on <= '1'; invert <= '0'; flip <= '0'; contrast <= x"7F";
            wait for 100 ns;
            wait until rising_edge(clk);
            resetn <= '1';

            if run("init_sequence") then
                wait_rx(N_INIT);
                check(res_seen_low, "RES# pulsed low before init");
                for i in 0 to N_INIT-1 loop
                    check_cmd(i, INIT_EXPECT(i), "init byte " & integer'image(i));
                end loop;
                if ready /= '1' then                -- set once the last bit's low phase ends
                    wait until ready = '1' for 200 ns;
                end if;
                check_equal(ready, '1', "ready after init");

            elsif run("first_frame_renders_text") then
                check_frame(N_INIT, '1', '0', '0', x"7F");
                -- independent of the ROM: 'H' is two bars joined in row 3
                for x in 0 to 7 loop
                    check_equal(rx(N_INIT + N_CMD + x)(7 downto 0), GLYPH_H(x),
                                "'H' column " & integer'image(x));
                end loop;
                wait until rising_edge(clk);
                wait until rising_edge(clk);
                check(unsigned(frames) >= 1, "frame counter advanced");

            elsif run("controls_apply_next_frame") then
                wait_rx(N_INIT + 100);              -- frame 1 is running
                display_on <= '0'; invert <= '1'; flip <= '1'; contrast <= x"10";
                check_frame(N_INIT, '1', '0', '0', x"7F");           -- frame 1 unchanged
                check_frame(N_INIT + N_FRAME, '0', '1', '1', x"10"); -- frame 2 has them

            elsif run("reset_restarts") then
                wait_rx(N_INIT + 50);
                resetn <= '0';
                wait for 100 ns;
                wait until rising_edge(clk);
                resetn <= '1';
                wait_rx(N_INIT);
                check(res_seen_low, "RES# pulsed again");
                check_cmd(0, x"AE", "init starts over");
            end if;
        end loop;

        running <= false;
        test_runner_cleanup(runner);
        wait;
    end process;

    test_runner_watchdog(runner, 5 ms);

end architecture sim;
