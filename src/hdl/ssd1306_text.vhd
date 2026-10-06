-------------------------------------------------------------------------------
-- ssd1306_text.vhd  (VHDL-2008)
--
-- Text-mode driver for the board's 0.96" 128x64 SSD1306 OLED (J4), entirely in
-- the PL. The panel is strapped for 4-wire SPI with CS# tied low (schematic
-- page 12: BS0/BS1/BS2/CS = GND), so the link is just SCLK (D0), SDIN (D1),
-- D/C# and RES#. VBAT is 3.3 V, so the internal charge pump is used (8D 14).
--
-- After reset:  RES# low for RESET_US, high for RESET_US, init sequence once.
-- Then forever, FRAME_HZ times a second:
--   per-frame commands (orientation, contrast, invert, on/off, address window)
--   + 1024 data bytes rendered on the fly from a 16x8 character buffer
--     (char_addr_o -> char_i, one cycle latency) through the 8x8 font ROM.
-- Horizontal addressing mode: data byte n = page n[9:7], column n[6:0]
--   -> character (page*16 + col/8), glyph column col mod 8.
--
-- SPI mode 0, MSB first: SDIN changes while SCLK is low, the panel samples on
-- the rising edge. SSD1306 needs >= 100 ns SCLK period; default is 5 MHz.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.font8x8_pkg.all;

entity ssd1306_text is
    generic (
        CLK_HZ   : positive := 100_000_000;
        SPI_HZ   : positive := 5_000_000;
        FRAME_HZ : positive := 30;
        RESET_US : positive := 1000         -- RES# low time, and wait after it
    );
    port (
        clk         : in  std_logic;
        resetn      : in  std_logic;

        -- control (sampled at the start of every frame)
        display_on  : in  std_logic;
        invert      : in  std_logic;
        flip        : in  std_logic;        -- rotate 180 degrees
        contrast    : in  std_logic_vector(7 downto 0);

        -- character buffer read port: 128 chars, row-major, 16 per row
        char_addr_o : out std_logic_vector(6 downto 0);
        char_i      : in  std_logic_vector(7 downto 0);

        ready_o     : out std_logic;        -- init done, refreshing
        frames_o    : out std_logic_vector(15 downto 0);

        -- panel pins
        oled_sclk   : out std_logic;
        oled_sdin   : out std_logic;
        oled_dc     : out std_logic;        -- 0 = command, 1 = data
        oled_res_n  : out std_logic
    );
end entity ssd1306_text;

architecture rtl of ssd1306_text is

    constant HALF_BIT    : positive := (CLK_HZ + 2*SPI_HZ - 1) / (2*SPI_HZ);  -- clk per SCLK phase
    constant RESET_TICKS : positive := CLK_HZ / 1_000_000 * RESET_US;
    constant FRAME_TICKS : positive := CLK_HZ / FRAME_HZ;

    type byte_array_t is array (natural range <>) of byte_t;

    -- one-time setup (everything that frame_cmd() does not resend)
    constant INIT_CMDS : byte_array_t := (
        x"AE",          -- display off
        x"D5", x"80",   -- clock divide / oscillator: reset default
        x"A8", x"3F",   -- multiplex ratio: 64 rows
        x"D3", x"00",   -- display offset 0
        x"40",          -- start line 0
        x"8D", x"14",   -- charge pump on (VBAT = 3.3 V, no external VCC)
        x"20", x"00",   -- horizontal addressing mode
        x"DA", x"12",   -- COM pins: alternative, no remap (128x64 panels)
        x"D9", x"F1",   -- pre-charge for the internal charge pump
        x"DB", x"40",   -- VCOMH deselect level
        x"2E",          -- scrolling off
        x"A4"           -- display follows RAM
    );

    constant N_FRAME_CMDS : positive := 12;

    -- per-frame commands, so control changes show up on the next frame
    function frame_cmd(i : natural; dsp_on, inv, flp : std_logic; con : byte_t) return byte_t is
    begin
        case i is
            when 0      => return x"A0" or ("0000000" & not flp);   -- segment remap (A1 = normal)
            when 1      => return x"C0" or ("0000" & not flp & "000"); -- COM scan dir (C8 = normal)
            when 2      => return x"81";                             -- contrast
            when 3      => return con;
            when 4      => return x"A6" or ("0000000" & inv);        -- normal / inverse
            when 5      => return x"AE" or ("0000000" & dsp_on);         -- display off / on
            when 6      => return x"21";                             -- column window 0..127
            when 7      => return x"00";
            when 8      => return x"7F";
            when 9      => return x"22";                             -- page window 0..7
            when 10     => return x"00";
            when others => return x"07";
        end case;
    end function;

    type state_t is (S_RESET_LOW, S_RESET_WAIT, S_INIT, S_IDLE, S_FRAME_CMD,
                     S_DATA_ADDR, S_DATA_SEND, S_TX);
    signal state     : state_t := S_RESET_LOW;
    signal ret_state : state_t := S_IDLE;

    signal timer    : natural range 0 to RESET_TICKS := 0;
    signal frame_t  : natural range 0 to FRAME_TICKS-1 := 0;
    signal frame_go : std_logic := '0';
    signal idx      : natural range 0 to 1023 := 0;    -- command / data byte index
    signal char_r   : byte_t := (others => '0');
    signal frames   : unsigned(15 downto 0) := (others => '0');
    signal ready    : std_logic := '0';

    -- frame-start snapshot of the controls
    signal on_r, inv_r, flip_r : std_logic := '0';
    signal con_r : byte_t := (others => '0');

    -- byte shifter
    signal sh      : byte_t := (others => '0');
    signal bit_cnt : natural range 0 to 7 := 0;
    signal div     : natural range 0 to HALF_BIT-1 := 0;
    signal sclk_r, sdin_r, dc_r, res_n_r : std_logic := '0';

begin

    oled_sclk   <= sclk_r;
    oled_sdin   <= sdin_r;
    oled_dc     <= dc_r;
    oled_res_n  <= res_n_r;
    ready_o     <= ready;
    frames_o    <= std_logic_vector(frames);

    -- data byte idx = page idx[9:7], column idx[6:0] -> char page*16 + col/8
    char_addr_o <= std_logic_vector(to_unsigned(idx, 10)(9 downto 3));

    -- frame-rate tick; a frame that is due while one is still running waits
    frame_timer : process (clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                frame_t  <= 0;
                frame_go <= '0';
            else
                if frame_t = FRAME_TICKS-1 then
                    frame_t  <= 0;
                    frame_go <= '1';
                else
                    frame_t <= frame_t + 1;
                end if;
                if state = S_IDLE and frame_go = '1' then
                    frame_go <= '0';
                end if;
            end if;
        end if;
    end process;

    main : process (clk)
        -- load the shifter and continue at 'ret' once the byte is out
        procedure send(b : byte_t; dc : std_logic; ret : state_t) is
        begin
            sh        <= b(6 downto 0) & '0';
            sdin_r    <= b(7);
            dc_r      <= dc;
            sclk_r    <= '0';
            bit_cnt   <= 7;
            div       <= 0;
            ret_state <= ret;
            state     <= S_TX;
        end procedure;
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                state   <= S_RESET_LOW;
                timer   <= 0;
                idx     <= 0;
                ready   <= '0';
                frames  <= (others => '0');
                sclk_r  <= '0';
                sdin_r  <= '0';
                dc_r    <= '0';
                res_n_r <= '0';
            else
                case state is

                    when S_RESET_LOW =>                 -- RES# low >= 3 us
                        res_n_r <= '0';
                        if timer = RESET_TICKS then
                            timer <= 0;
                            state <= S_RESET_WAIT;
                        else
                            timer <= timer + 1;
                        end if;

                    when S_RESET_WAIT =>                -- let the controller come up
                        res_n_r <= '1';
                        if timer = RESET_TICKS then
                            timer <= 0;
                            idx   <= 0;
                            state <= S_INIT;
                        else
                            timer <= timer + 1;
                        end if;

                    when S_INIT =>
                        if idx = INIT_CMDS'length then
                            ready <= '1';
                            state <= S_IDLE;
                        else
                            idx <= idx + 1;
                            send(INIT_CMDS(idx), '0', S_INIT);
                        end if;

                    when S_IDLE =>
                        if frame_go = '1' then
                            on_r   <= display_on;
                            inv_r  <= invert;
                            flip_r <= flip;
                            con_r  <= contrast;
                            idx    <= 0;
                            state  <= S_FRAME_CMD;
                        end if;

                    when S_FRAME_CMD =>
                        if idx = N_FRAME_CMDS then
                            idx   <= 0;
                            state <= S_DATA_ADDR;
                        else
                            idx <= idx + 1;
                            send(frame_cmd(idx, on_r, inv_r, flip_r, con_r), '0', S_FRAME_CMD);
                        end if;

                    when S_DATA_ADDR =>                 -- char_addr_o follows idx
                        char_r <= char_i;
                        state  <= S_DATA_SEND;

                    when S_DATA_SEND =>
                        if idx = 1023 then
                            frames <= frames + 1;
                            send(glyph(char_r, to_unsigned(idx, 3)), '1', S_IDLE);
                        else
                            send(glyph(char_r, to_unsigned(idx, 3)), '1', S_DATA_ADDR);
                        end if;
                        idx <= (idx + 1) mod 1024;

                    when S_TX =>
                        if div = HALF_BIT-1 then
                            div <= 0;
                            if sclk_r = '0' then
                                sclk_r <= '1';          -- panel samples SDIN here
                            else
                                sclk_r <= '0';
                                if bit_cnt = 0 then
                                    state <= ret_state;
                                else
                                    bit_cnt <= bit_cnt - 1;
                                    sdin_r  <= sh(7);
                                    sh      <= sh(6 downto 0) & '0';
                                end if;
                            end if;
                        else
                            div <= div + 1;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
