-------------------------------------------------------------------------------
-- scope_capture.vhd  (VHDL-2008)
--
-- Triggered capture of SCOPE_CH x 16-bit channels into a ring buffer in block
-- RAM, SCOPE_DEPTH samples deep: the oscilloscope's acquisition.
--
--   sample clock : one sample every cfg.div clocks (0 counts as 1)
--   arm          : FILL   - write cfg.pre samples (the pre-trigger history)
--                  ARMED  - keep writing; the trigger sample is the first one
--                           where ch(trig_ch) crosses trig_level (rising:
--                           prev < level <= cur, falling: prev > level >= cur)
--                           or any sample after a force
--                  POST   - write until SCOPE_DEPTH - pre samples starting at
--                           the trigger are in, then done
--   abort        : back to idle
--
-- The capture is then the SCOPE_DEPTH samples starting at RAM index
-- trig_ptr - pre (mod SCOPE_DEPTH); the trigger sample is sample number pre.
--
-- Read port: word index rd_addr = 2*sample + half, half 0 = ch1:ch0, half 1 =
-- ch3:ch2 (high:low 16 bits). Data is valid one clock after rd_addr.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.scope_pkg.all;

entity scope_capture is
    port (
        clk     : in  std_logic;
        resetn  : in  std_logic;
        cfg     : in  scope_cfg_t;
        ch_i    : in  sample_array_t;
        stat_o  : out scope_stat_t;
        rd_addr : in  unsigned(SCOPE_DEPTH_LOG2 downto 0);
        rd_data : out std_logic_vector(31 downto 0)
    );
end entity scope_capture;

architecture rtl of scope_capture is

    type ram_t is array (0 to SCOPE_DEPTH-1) of std_logic_vector(63 downto 0);
    signal ram : ram_t;
    attribute ram_style : string;
    attribute ram_style of ram : signal is "block";

    signal rd_q    : std_logic_vector(63 downto 0);
    signal rd_half : std_logic := '0';

    signal div_cnt   : unsigned(SCOPE_DIV_BITS-1 downto 0) := (others => '0');
    signal tick      : std_logic := '0';               -- take a sample this clock

    signal state     : unsigned(1 downto 0) := ST_IDLE;
    signal done      : std_logic := '0';
    signal wp        : ptr_t := (others => '0');
    signal cnt       : ptr_t := (others => '0');      -- samples still to write in FILL / POST
    signal prev      : sample_t := (others => '0');   -- trigger channel, previous sample
    signal prev_ok   : std_logic := '0';
    signal force_req : std_logic := '0';
    signal trig_cond : std_logic := '0';
    signal trig_ptr  : ptr_t := (others => '0');

begin

    stat_o <= (state => state, done => done, trig_cond => trig_cond, trig_ptr => trig_ptr);

    ---------------------------------------------------------------------------
    -- sample clock
    ---------------------------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' or cfg.arm = '1' then
                div_cnt <= (others => '0');
                tick    <= '0';
            elsif div_cnt + 1 >= cfg.div then             -- div 0 and 1: every clock
                div_cnt <= (others => '0');
                tick    <= '1';
            else
                div_cnt <= div_cnt + 1;
                tick    <= '0';
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- RAM: one write port (capture), one read port (AXI)
    ---------------------------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            if tick = '1' and state /= ST_IDLE then
                ram(to_integer(wp)) <= std_logic_vector(ch_i(3)) & std_logic_vector(ch_i(2)) &
                                       std_logic_vector(ch_i(1)) & std_logic_vector(ch_i(0));
            end if;
            rd_q    <= ram(to_integer(rd_addr(SCOPE_DEPTH_LOG2 downto 1)));
            rd_half <= rd_addr(0);
        end if;
    end process;

    rd_data <= rd_q(63 downto 32) when rd_half = '1' else rd_q(31 downto 0);

    ---------------------------------------------------------------------------
    -- capture state machine
    ---------------------------------------------------------------------------
    process (clk)
        variable cur  : sample_t;
        variable hit  : boolean;
        variable post : ptr_t;
    begin
        if rising_edge(clk) then
            if resetn = '0' or cfg.abort = '1' then
                state     <= ST_IDLE;
                done      <= '0';
                force_req <= '0';
                prev_ok   <= '0';
            elsif cfg.arm = '1' then
                done      <= '0';
                force_req <= '0';
                prev_ok   <= '0';
                trig_cond <= '0';
                cnt       <= cfg.pre;
                state     <= ST_FILL when cfg.pre /= 0 else ST_ARMED;
            else
                if cfg.force_trig = '1' and state /= ST_IDLE then
                    force_req <= '1';
                end if;

                if tick = '1' and state /= ST_IDLE then
                    cur     := ch_i(to_integer(cfg.trig_ch));
                    prev    <= cur;
                    prev_ok <= '1';
                    wp      <= wp + 1;

                    case state is
                        when ST_FILL =>
                            if cnt = 1 then
                                state <= ST_ARMED;
                            end if;
                            cnt <= cnt - 1;

                        when ST_ARMED =>
                            if cfg.trig_falling = '0' then
                                hit := prev_ok = '1' and prev < cfg.trig_level and cur >= cfg.trig_level;
                            else
                                hit := prev_ok = '1' and prev > cfg.trig_level and cur <= cfg.trig_level;
                            end if;
                            if hit or force_req = '1' or cfg.force_trig = '1' then
                                trig_ptr  <= wp;
                                trig_cond <= '1' when hit else '0';
                                -- SCOPE_DEPTH - pre samples from the trigger on;
                                -- this one is the first
                                post := to_unsigned(SCOPE_DEPTH - 1, SCOPE_DEPTH_LOG2) - cfg.pre;
                                if post = 0 then
                                    state <= ST_IDLE;
                                    done  <= '1';
                                else
                                    cnt   <= post;
                                    state <= ST_POST;
                                end if;
                            end if;

                        when ST_POST =>
                            if cnt = 1 then
                                state <= ST_IDLE;
                                done  <= '1';
                            end if;
                            cnt <= cnt - 1;

                        when others =>
                            null;
                    end case;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
