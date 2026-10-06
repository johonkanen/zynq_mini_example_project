-------------------------------------------------------------------------------
-- tb_scope_capture.vhd  (VHDL-2008, VUnit)
--
-- scope_capture with known inputs: channel n = (n+1) * clock counter, so every
-- sample says when it was taken. Each test arms a capture, reads the whole RAM
-- back through the read port, unrolls it from trig_ptr - pre the way fpgad
-- does, and checks sample spacing (= div), the trigger position and the
-- trigger condition. Also checks the scope_siggen test signals.
--
--   Run:  python sim/run.py            (NVC backend, see sim/run.py)
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

use work.scope_pkg.all;

entity tb_scope_capture is
    generic (runner_cfg : string);
end entity;

architecture sim of tb_scope_capture is

    constant TCLK : time := 10 ns;

    signal clk     : std_logic := '0';
    signal resetn  : std_logic := '0';
    signal running : boolean := true;

    signal cfg  : scope_cfg_t := (arm => '0', force_trig => '0', abort => '0',
                                  trig_ch => "00", trig_falling => '0', trig_level => (others => '0'),
                                  pre => (others => '0'), div => to_unsigned(1, SCOPE_DIV_BITS),
                                  src => (others => (others => '0')),
                                  ftw_a => (others => '0'), ftw_b => (others => '0'));
    signal stat : scope_stat_t;
    signal ch   : sample_array_t := (others => (others => '0'));
    signal rd_addr : unsigned(SCOPE_DEPTH_LOG2 downto 0) := (others => '0');
    signal rd_data : std_logic_vector(31 downto 0);

    signal counter : unsigned(15 downto 0) := (others => '0');
    signal wave    : sample_t := (others => '0');      -- for trigger tests: triangle, period 400 clk
    signal use_wave : boolean := false;

    signal sine_a, tri_a, sq_a, sine_b, noise, sine_noise : sample_t;

    type capture_t is array (0 to SCOPE_CH-1, 0 to SCOPE_DEPTH-1) of integer;

begin

    clk_gen : process
    begin
        while running loop
            clk <= '0'; wait for TCLK/2;
            clk <= '1'; wait for TCLK/2;
        end loop;
        wait;
    end process;

    -- channel n = (n+1) * counter (mod 2**16), or the triangle on channel 0
    inputs : process (clk)
        variable ph : integer range 0 to 399 := 0;
    begin
        if rising_edge(clk) then
            counter <= counter + 1;
            ph := (ph + 1) mod 400;
            wave <= to_signed(abs (ph - 200) * 200 - 20000, 16);   -- -20000..+20000
        end if;
    end process;
    ch(0) <= wave when use_wave else signed(counter);
    ch(1) <= signed(resize(counter * 2, 16));
    ch(2) <= signed(resize(counter * 3, 16));
    ch(3) <= signed(resize(counter * 4, 16));

    dut : entity work.scope_capture
        port map (clk => clk, resetn => resetn, cfg => cfg, ch_i => ch, stat_o => stat,
                  rd_addr => rd_addr, rd_data => rd_data);

    gen : entity work.scope_siggen
        port map (clk => clk, resetn => resetn,
                  ftw_a => to_unsigned(42949673, 32),        -- 1 MHz: period 100 clk
                  ftw_b => to_unsigned(10737418, 32),        -- 250 kHz
                  sine_a => sine_a, triangle_a => tri_a, square_a => sq_a,
                  sine_b => sine_b, noise => noise, sine_noise => sine_noise);

    main : process

        procedure pulse(signal s : out std_logic) is
        begin
            s <= '1';
            wait until rising_edge(clk);
            s <= '0';
        end procedure;

        procedure wait_done(max_clk : natural) is
        begin
            for i in 1 to max_clk loop
                wait until rising_edge(clk);
                exit when stat.done = '1';
            end loop;
            check_equal(stat.done, '1', "capture done");
        end procedure;

        -- read the RAM and unroll from trig_ptr - pre, like fpgad
        procedure read_capture(variable c : out capture_t) is
            variable start, idx : natural;
        begin
            start := (to_integer(stat.trig_ptr) - to_integer(cfg.pre)) mod SCOPE_DEPTH;
            for i in 0 to SCOPE_DEPTH-1 loop
                idx := (start + i) mod SCOPE_DEPTH;
                for half in 0 to 1 loop
                    rd_addr <= to_unsigned(2 * idx + half, SCOPE_DEPTH_LOG2 + 1);
                    wait until rising_edge(clk);
                    wait until rising_edge(clk);            -- one clock read latency
                    c(2 * half, i)     := to_integer(signed(rd_data(15 downto 0)));
                    c(2 * half + 1, i) := to_integer(signed(rd_data(31 downto 16)));
                end loop;
            end loop;
        end procedure;

        -- every channel's samples are div clocks apart (mod 2**16)
        procedure check_spacing(c : capture_t; div : natural) is
            variable d : integer;
        begin
            for n in 0 to SCOPE_CH-1 loop
                if n = 0 and use_wave then
                    next;
                end if;
                for i in 1 to SCOPE_DEPTH-1 loop
                    d := (c(n, i) - c(n, i-1)) mod 65536;
                    if d /= ((n + 1) * div) mod 65536 then
                        check_equal(d, (n + 1) * div, "ch" & integer'image(n) & " spacing at " & integer'image(i));
                        return;
                    end if;
                end loop;
            end loop;
        end procedure;

        variable c : capture_t;
        variable lvl, mn, mx, last_sq, edges, first_edge, period : integer;
        variable tmn, tmx : integer := 0;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop
            resetn <= '0';
            use_wave <= false;
            wait for 50 ns;
            wait until rising_edge(clk);
            resetn <= '1';
            wait until rising_edge(clk);

            if run("forced_trigger_full_depth") then
                cfg.pre <= to_unsigned(100, SCOPE_DEPTH_LOG2);
                cfg.div <= to_unsigned(1, SCOPE_DIV_BITS);
                pulse(cfg.arm);
                for i in 1 to 300 loop wait until rising_edge(clk); end loop;
                check_equal(stat.state, ST_ARMED, "armed after the pre-trigger fill");
                pulse(cfg.force_trig);
                wait_done(SCOPE_DEPTH + 50);
                check_equal(stat.trig_cond, '0', "forced, not by condition");
                read_capture(c);
                check_spacing(c, 1);

            elsif run("decimation") then
                cfg.pre <= to_unsigned(1000, SCOPE_DEPTH_LOG2);
                cfg.div <= to_unsigned(7, SCOPE_DIV_BITS);
                pulse(cfg.arm);
                for i in 1 to 7 * 1000 + 20 loop wait until rising_edge(clk); end loop;
                pulse(cfg.force_trig);
                wait_done(7 * SCOPE_DEPTH + 50);
                read_capture(c);
                check_spacing(c, 7);

            elsif run("rising_edge_trigger") then
                use_wave <= true;
                lvl := 5000;
                cfg.trig_level <= to_signed(lvl, 16);
                cfg.trig_falling <= '0';
                cfg.pre <= to_unsigned(2048, SCOPE_DEPTH_LOG2);
                cfg.div <= to_unsigned(1, SCOPE_DIV_BITS);
                pulse(cfg.arm);
                wait_done(2048 + 400 + SCOPE_DEPTH);
                check_equal(stat.trig_cond, '1', "triggered by the condition");
                read_capture(c);
                check(c(0, 2047) < lvl and c(0, 2048) >= lvl,
                      "rising crossing at sample pre: " & integer'image(c(0, 2047)) & " -> " & integer'image(c(0, 2048)));
                check_spacing(c, 1);

            elsif run("falling_edge_trigger") then
                use_wave <= true;
                lvl := -3000;
                cfg.trig_level <= to_signed(lvl, 16);
                cfg.trig_falling <= '1';
                cfg.pre <= to_unsigned(10, SCOPE_DEPTH_LOG2);
                pulse(cfg.arm);
                wait_done(10 + 400 + SCOPE_DEPTH);
                read_capture(c);
                check(c(0, 9) > lvl and c(0, 10) <= lvl,
                      "falling crossing at sample pre: " & integer'image(c(0, 9)) & " -> " & integer'image(c(0, 10)));

            elsif run("trigger_on_other_channel") then
                -- ch2 = 3 * counter: crosses 0 upwards right after it wraps
                cfg.trig_ch <= "10";
                cfg.trig_level <= to_signed(0, 16);
                cfg.trig_falling <= '0';
                cfg.pre <= to_unsigned(500, SCOPE_DEPTH_LOG2);
                pulse(cfg.arm);
                wait_done(70000 + SCOPE_DEPTH);
                read_capture(c);
                check(c(2, 499) < 0 and c(2, 500) >= 0, "ch2 rising through 0 at sample pre");

            elsif run("pre_zero_and_max") then
                cfg.pre <= to_unsigned(0, SCOPE_DEPTH_LOG2);
                pulse(cfg.arm);
                pulse(cfg.force_trig);
                wait_done(SCOPE_DEPTH + 50);
                read_capture(c);
                check_spacing(c, 1);
                cfg.pre <= to_unsigned(SCOPE_DEPTH - 1, SCOPE_DEPTH_LOG2);
                pulse(cfg.arm);
                for i in 1 to SCOPE_DEPTH + 10 loop wait until rising_edge(clk); end loop;
                pulse(cfg.force_trig);
                wait_done(20);
                read_capture(c);
                check_spacing(c, 1);

            elsif run("abort_and_rearm") then
                cfg.trig_level <= to_signed(32767, 16);      -- above the triangle: never crossed
                cfg.trig_ch <= "00";
                use_wave <= true;                            -- +-20000
                cfg.pre <= to_unsigned(16, SCOPE_DEPTH_LOG2);
                pulse(cfg.arm);
                for i in 1 to 2000 loop wait until rising_edge(clk); end loop;
                check_equal(stat.state, ST_ARMED, "still waiting for a trigger");
                pulse(cfg.abort);
                wait until rising_edge(clk);
                check_equal(stat.state, ST_IDLE, "abort -> idle");
                check_equal(stat.done, '0', "abort -> not done");
                pulse(cfg.arm);
                pulse(cfg.force_trig);
                wait_done(SCOPE_DEPTH + 50);

            elsif run("siggen_signals") then
                mn := 0; mx := 0; edges := 0; first_edge := 0; period := 0;
                last_sq := to_integer(sq_a);
                for i in 1 to 1050 loop           -- edges at ~100, 200 ... 1000 (+ pipeline)
                    wait until rising_edge(clk);
                    if to_integer(sine_a) < mn then mn := to_integer(sine_a); end if;
                    if to_integer(sine_a) > mx then mx := to_integer(sine_a); end if;
                    if to_integer(sq_a) > 0 and last_sq < 0 then
                        edges := edges + 1;
                        if edges = 1 then first_edge := i; end if;
                        period := i - first_edge;
                    end if;
                    last_sq := to_integer(sq_a);
                    if to_integer(tri_a) < tmn then tmn := to_integer(tri_a); end if;
                    if to_integer(tri_a) > tmx then tmx := to_integer(tri_a); end if;
                end loop;
                check(mx > 29900 and mn < -29900, "sine amplitude +-30000: " & integer'image(mn) & ".." & integer'image(mx));
                check(tmx <= 30000 and tmx > 29900 and tmn >= -30000 and tmn < -29900,
                      "triangle +-30000, symmetric: " & integer'image(tmn) & ".." & integer'image(tmx));
                check_equal(edges, 10, "square A: 10 rising edges in 1050 clk (1 MHz)");
                check_equal(period, 900, "9 periods of 100 clk between first and last edge");
            end if;
        end loop;

        running <= false;
        test_runner_cleanup(runner);
        wait;
    end process;

    test_runner_watchdog(runner, 20 ms);

end architecture sim;
