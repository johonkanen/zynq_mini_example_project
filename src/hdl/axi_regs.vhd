-------------------------------------------------------------------------------
-- axi_regs.vhd  (VHDL-2008)
--
-- Hand-written AXI slave for the Zynq PS7 M_AXI_GP0 master, wired DIRECTLY to
-- the PS in the block design (no AXI interconnect / protocol converter IP).
--
-- The bus is carried on the direction records from axi_pkg:
--     s_axi_i : in  axi_mosi_t    (master out / slave in)
--     s_axi_o : out axi_miso_t    (slave out / master in)
--
-- It speaks raw AXI3 GP: 32-bit data/address, 12-bit IDs, 4-bit AWLEN/ARLEN,
-- single- and multi-beat INCR / FIXED bursts (WRAP handled as INCR - fine for
-- a register file). BID / RID reflect the request IDs.
--
-- Register map (byte offset within the M_AXI_GP0 window, base 0x4000_0000):
--
--   0x00  SCRATCH0   R/W   PS -> PL   free storage, exported on reg_ps2pl_o(0)
--   0x04  SCRATCH1   R/W   PS -> PL   exported on reg_ps2pl_o(1)
--   0x08  SCRATCH2   R/W   PS -> PL   exported on reg_ps2pl_o(2)
--   0x0C  CONTROL    R/W   PS -> PL   bit0 -> pl_active_o ; bit1 clears HEARTBEAT
--   0x10  HEARTBEAT  RO    PL -> PS   free-running counter
--   0x14  SUM        RO    PL -> PS   SCRATCH0 + SCRATCH1 (added in the PL)
--   0x18  STATUS     RO    PL -> PS   reductions / popcount (see below)
--   0x1C  SIGNATURE  RO    PL -> PS   constant 0x5A5A_1234
--   0x20  OLED_CTRL  R/W   PS -> PL   SSD1306 controls (reset 0x0000_7F01)
--   0x24  OLED_STAT  RO    PL -> PS   SSD1306 driver status
--   0x40  SCOPE_CMD  W     PS -> PL   bit0 arm, bit1 force trigger, bit2 abort (pulses)
--   0x44  SCOPE_STAT RO    PL -> PS   capture state (see below)
--   0x48  SCOPE_TRIG R/W   PS -> PL   [1:0] channel, bit4 falling, [31:16] level (signed)
--   0x4C  SCOPE_PRE  R/W   PS -> PL   pre-trigger samples, 0..4095 (reset 2048)
--   0x50  SCOPE_DIV  R/W   PS -> PL   sample every DIV clocks, [23:0], 0 = 1 (reset 1)
--   0x54  SCOPE_SRC  R/W   PS -> PL   source of channel n in bits [4n+3:4n] (reset 0x7421)
--   0x58  SCOPE_INFO RO    PL -> PS   [7:0] channels, [15:8] log2 depth, [31:16] fclk MHz
--   0x60  GEN_FTW_A  R/W   PS -> PL   test generator A frequency word (reset 1 MHz)
--   0x64  GEN_FTW_B  R/W   PS -> PL   test generator B frequency word (reset 250 kHz)
--   0x80..0xFC OLED_TEXT R/W          16x8 character buffer, 4 chars per word
--   anything else in 0x00..0xFF reads 0; the map repeats every 256 bytes up to
--   0x7FFF
--   0x8000..0xFFFF SCOPE_RAM RO       capture buffer: word 2*i = ch1:ch0, word
--                                     2*i+1 = ch3:ch2 of RAM sample i (16-bit
--                                     signed, high:low)
--
--   STATUS: bit0=or SCRATCH0, bit1=and SCRATCH1, bit2=(SCRATCH0=SCRATCH1),
--           bit3=CONTROL(0), bits[15:8]=popcount(SCRATCH2),
--           bits[31:16]=HEARTBEAT[15:0]
--   OLED_CTRL: bit0=display on, bit1=invert, bit2=flip 180, bits[15:8]=contrast
--   OLED_STAT: bit0=ready (init done), bits[31:16]=frames sent
--   OLED_TEXT: char n (row n/16, column n mod 16) is byte n mod 4 of word
--              n/4, little-endian - so a string memcpy'd to 0x80 reads left to
--              right. Reset text: OLED_TEXT_RESET below ("Hello, Zynq Mini").
--   SCOPE_STAT: [1:0] state (0 idle, 1 pre-trigger fill, 2 armed, 3 post-
--              trigger fill), bit2 done, bit3 triggered by the condition (0 =
--              forced), [27:16] RAM index of the trigger sample.
--              The capture is the 4096 samples from RAM index trig - PRE (mod
--              4096); see scope_capture.vhd.
--   GEN_FTW_x: f = FTW * 100 MHz / 2**32.
--
-- Reads take one extra clock (registers and the capture RAM alike): the
-- address is registered, then RVALID comes with the data one clock later.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.axi_pkg.all;
use work.scope_pkg.all;

entity axi_regs is
    port (
        -- exported register view (for PL user logic)
        reg_ps2pl_o   : out std_logic_vector(4*AXI_DATA_WIDTH-1 downto 0);
        pl_active_o   : out std_logic;

        -- SSD1306 text display (ssd1306_text)
        oled_ctrl_o      : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        oled_stat_i      : in  std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        oled_char_addr_i : in  std_logic_vector(6 downto 0);
        oled_char_o      : out std_logic_vector(7 downto 0);

        -- oscilloscope (scope_capture + scope_siggen)
        scope_cfg_o      : out scope_cfg_t;
        scope_stat_i     : in  scope_stat_t;
        scope_rd_addr_o  : out unsigned(SCOPE_DEPTH_LOG2 downto 0);
        scope_rd_data_i  : in  std_logic_vector(AXI_DATA_WIDTH-1 downto 0);

        -- AXI3 slave interface (connect straight to M_AXI_GP0)
        s_axi_aclk    : in  std_logic;
        s_axi_aresetn : in  std_logic;
        s_axi_i       : in  axi_mosi_t;
        s_axi_o       : out axi_miso_t
    );
end entity axi_regs;

architecture rtl of axi_regs is

    constant DW      : integer := AXI_DATA_WIDTH;
    constant REG_LSB : integer := 2;                       -- 32-bit word addressing
    constant N_REGS  : integer := 64;                      -- 0x00..0xFF
    constant IDX_OLED_CTRL : integer := 8;                 -- 0x20
    constant IDX_OLED_STAT : integer := 9;                 -- 0x24
    constant IDX_TEXT      : integer := 32;                -- 0x80..0xFC
    constant IDX_SCOPE_CMD  : integer := 16;               -- 0x40
    constant IDX_SCOPE_STAT : integer := 17;               -- 0x44
    constant IDX_SCOPE_CFG  : integer := 18;               -- 0x48..0x54: TRIG PRE DIV SRC
    constant IDX_SCOPE_INFO : integer := 22;               -- 0x58
    constant IDX_GEN_FTW    : integer := 24;               -- 0x60, 0x64
    constant FCLK_MHZ       : integer := 100;

    subtype word_t is std_logic_vector(DW-1 downto 0);
    type    word_array_t is array (natural range <>) of word_t;

    constant OLED_CTRL_RESET : word_t := x"00007F01";      -- on, contrast 0x7F

    -- 16 characters per row, packed little-endian into 4 words
    function text_row(s : string) return word_array_t is
        variable r : word_array_t(0 to 3) := (others => x"20202020");
    begin
        for i in 0 to s'length-1 loop
            r(i/4)(8*(i mod 4)+7 downto 8*(i mod 4)) :=
                std_logic_vector(to_unsigned(character'pos(s(s'low+i)), 8));
        end loop;
        return r;
    end function;

    constant OLED_TEXT_RESET : word_array_t(0 to 31) :=
        text_row("Hello, Zynq Mini") & text_row("") &
        text_row("SSD1306 driven") & text_row("from the PL") &
        text_row("") & text_row("") &
        text_row("") & text_row("fpgactl oled ...");

    -- SCOPE_TRIG, PRE, DIV, SRC, then GEN_FTW_A, B
    constant SCOPE_CFG_RESET : word_array_t(0 to 5) := (
        x"00000000",                                       -- ch0, rising, level 0
        std_logic_vector(to_unsigned(SCOPE_DEPTH / 2, 32)),-- pre-trigger: half
        x"00000001",                                       -- 100 MSa/s
        x"00007421",                                       -- sine A, triangle A, sine B, OLED SPI
        x"028F5C29",                                       -- 1 MHz
        x"00A3D70A");                                      -- 250 kHz

    signal regs      : word_array_t(0 to 3) := (others => (others => '0'));   -- writable
    signal scope_cfg : word_array_t(0 to 5) := SCOPE_CFG_RESET;
    signal scope_cmd : std_logic_vector(2 downto 0) := (others => '0');       -- one-clock pulses
    signal oled_ctrl : word_t := OLED_CTRL_RESET;
    signal text      : word_array_t(0 to 31) := OLED_TEXT_RESET;

    -- PL-side status sources
    signal heartbeat : unsigned(DW-1 downto 0) := (others => '0');
    signal sum_w     : word_t;
    signal status_w  : word_t;
    signal rd_word   : word_t;

    -- write channel
    type wr_state_t is (W_IDLE, W_DATA, W_RESP);
    signal wr_state : wr_state_t := W_IDLE;
    signal wr_addr  : unsigned(AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal wr_id    : axi_id_t := (others => '0');
    signal wr_size  : std_logic_vector(2 downto 0) := (others => '0');
    signal wr_burst : std_logic_vector(1 downto 0) := (others => '0');
    signal wr_beats : unsigned(4 downto 0) := (others => '0');
    signal awready_r, wready_r, bvalid_r : std_logic := '0';

    -- read channel
    type rd_state_t is (R_IDLE, R_FETCH, R_DATA);
    signal rd_state : rd_state_t := R_IDLE;
    signal rd_addr  : unsigned(AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal rd_id    : axi_id_t := (others => '0');
    signal rd_size  : std_logic_vector(2 downto 0) := (others => '0');
    signal rd_burst : std_logic_vector(1 downto 0) := (others => '0');
    signal rd_beats : unsigned(4 downto 0) := (others => '0');
    signal arready_r, rvalid_r, rlast_r : std_logic := '0';

    -- helpers ---------------------------------------------------------------
    function reg_index(a : unsigned) return integer is
    begin
        return to_integer(a(REG_LSB+5 downto REG_LSB));    -- 6 bits -> 0..63
    end function;

    function is_ram(a : unsigned) return boolean is        -- 0x8000..0xFFFF
    begin
        return a(15) = '1';
    end function;

    function next_addr(a : unsigned; size : std_logic_vector; burst : std_logic_vector)
        return unsigned is
    begin
        if burst = AXI_BURST_FIXED then
            return a;
        else                                              -- INCR / WRAP
            return a + shift_left(to_unsigned(1, a'length), to_integer(unsigned(size)));
        end if;
    end function;

    function popcount(v : std_logic_vector) return natural is
        variable n : natural := 0;
    begin
        for i in v'range loop
            if v(i) = '1' then n := n + 1; end if;
        end loop;
        return n;
    end function;

begin

    ---------------------------------------------------------------------------
    -- exported view + combinational PL status words
    ---------------------------------------------------------------------------
    reg_ps2pl_o <= regs(3) & regs(2) & regs(1) & regs(0);
    pl_active_o <= regs(3)(0);
    oled_ctrl_o <= oled_ctrl;

    scope_cfg_o <= (
        arm          => scope_cmd(0),
        force_trig   => scope_cmd(1),
        abort        => scope_cmd(2),
        trig_ch      => unsigned(scope_cfg(0)(1 downto 0)),
        trig_falling => scope_cfg(0)(4),
        trig_level   => signed(scope_cfg(0)(31 downto 16)),
        pre          => unsigned(scope_cfg(1)(SCOPE_DEPTH_LOG2-1 downto 0)),
        div          => unsigned(scope_cfg(2)(SCOPE_DIV_BITS-1 downto 0)),
        src          => (unsigned(scope_cfg(3)(3 downto 0)),  unsigned(scope_cfg(3)(7 downto 4)),
                         unsigned(scope_cfg(3)(11 downto 8)), unsigned(scope_cfg(3)(15 downto 12))),
        ftw_a        => unsigned(scope_cfg(4)),
        ftw_b        => unsigned(scope_cfg(5)));

    -- capture RAM word index; the RAM is read every clock, so the word for
    -- rd_addr is there in R_DATA
    scope_rd_addr_o <= rd_addr(SCOPE_DEPTH_LOG2+REG_LSB downto REG_LSB);

    oled_char_proc : process (all)
        variable n : integer range 0 to 127;
    begin
        n := to_integer(unsigned(oled_char_addr_i));
        oled_char_o <= text(n / 4)(8*(n mod 4)+7 downto 8*(n mod 4));
    end process;

    sum_w <= std_logic_vector(unsigned(regs(0)) + unsigned(regs(1)));

    status_comb : process (all)
    begin
        status_w              <= (others => '0');
        status_w(0)           <= or  regs(0);
        status_w(1)           <= and regs(1);
        status_w(2)           <= '1' when regs(0) = regs(1) else '0';
        status_w(3)           <= regs(3)(0);
        status_w(15 downto 8) <= std_logic_vector(to_unsigned(popcount(regs(2)), 8));
        status_w(31 downto 16)<= std_logic_vector(heartbeat(15 downto 0));
    end process;

    ---------------------------------------------------------------------------
    -- HEARTBEAT counter
    ---------------------------------------------------------------------------
    heartbeat_proc : process (s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                heartbeat <= (others => '0');
            elsif regs(3)(1) = '1' then
                heartbeat <= (others => '0');
            else
                heartbeat <= heartbeat + 1;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Slave -> master outputs (one driver per record field)
    ---------------------------------------------------------------------------
    s_axi_o.awready <= awready_r;
    s_axi_o.wready  <= wready_r;
    s_axi_o.b.id    <= wr_id;
    s_axi_o.b.resp  <= AXI_RESP_OKAY;
    s_axi_o.b.valid <= bvalid_r;
    s_axi_o.arready <= arready_r;
    s_axi_o.r.id    <= rd_id;
    s_axi_o.r.data  <= rd_word;
    s_axi_o.r.resp  <= AXI_RESP_OKAY;
    s_axi_o.r.last  <= rlast_r;
    s_axi_o.r.valid <= rvalid_r;

    rd_mux : process (all)
        variable idx : integer range 0 to N_REGS-1;
    begin
        idx := reg_index(rd_addr);
        if is_ram(rd_addr) then
            rd_word <= scope_rd_data_i;
        else
            case idx is
                when 0 to 3        => rd_word <= regs(idx);
                when 4             => rd_word <= std_logic_vector(heartbeat);
                when 5             => rd_word <= sum_w;
                when 6             => rd_word <= status_w;
                when 7             => rd_word <= x"5A5A1234";
                when IDX_OLED_CTRL => rd_word <= oled_ctrl;
                when IDX_OLED_STAT => rd_word <= oled_stat_i;
                when IDX_SCOPE_CMD => rd_word <= (others => '0');
                when IDX_SCOPE_STAT =>
                    rd_word <= (others => '0');
                    rd_word(1 downto 0) <= std_logic_vector(scope_stat_i.state);
                    rd_word(2) <= scope_stat_i.done;
                    rd_word(3) <= scope_stat_i.trig_cond;
                    rd_word(16+SCOPE_DEPTH_LOG2-1 downto 16) <= std_logic_vector(scope_stat_i.trig_ptr);
                when IDX_SCOPE_CFG to IDX_SCOPE_CFG+3 => rd_word <= scope_cfg(idx - IDX_SCOPE_CFG);
                when IDX_SCOPE_INFO =>
                    rd_word <= std_logic_vector(to_unsigned(FCLK_MHZ, 16)) &
                               std_logic_vector(to_unsigned(SCOPE_DEPTH_LOG2, 8)) &
                               std_logic_vector(to_unsigned(SCOPE_CH, 8));
                when IDX_GEN_FTW to IDX_GEN_FTW+1 => rd_word <= scope_cfg(4 + idx - IDX_GEN_FTW);
                when IDX_TEXT to N_REGS-1 => rd_word <= text(idx - IDX_TEXT);
                when others        => rd_word <= (others => '0');
            end case;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- AXI write channel
    ---------------------------------------------------------------------------
    write_proc : process (s_axi_aclk)
        variable idx : integer range 0 to N_REGS-1;
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                wr_state  <= W_IDLE;
                awready_r <= '0';
                wready_r  <= '0';
                bvalid_r  <= '0';
                regs      <= (others => (others => '0'));
                oled_ctrl <= OLED_CTRL_RESET;
                text      <= OLED_TEXT_RESET;
                scope_cfg <= SCOPE_CFG_RESET;
                scope_cmd <= (others => '0');
            else
                scope_cmd <= (others => '0');
                case wr_state is

                    when W_IDLE =>
                        bvalid_r  <= '0';
                        awready_r <= '1';
                        if s_axi_i.aw.valid = '1' and awready_r = '1' then
                            wr_addr   <= unsigned(s_axi_i.aw.addr);
                            wr_id     <= s_axi_i.aw.id;
                            wr_size   <= s_axi_i.aw.size;
                            wr_burst  <= s_axi_i.aw.burst;
                            wr_beats  <= resize(unsigned(s_axi_i.aw.len), 5) + 1;
                            awready_r <= '0';
                            wready_r  <= '1';
                            wr_state  <= W_DATA;
                        end if;

                    when W_DATA =>
                        if s_axi_i.w.valid = '1' and wready_r = '1' then
                            idx := reg_index(wr_addr);
                            if not is_ram(wr_addr) and idx = IDX_SCOPE_CMD and s_axi_i.w.strb(0) = '1' then
                                scope_cmd <= s_axi_i.w.data(2 downto 0);
                            end if;
                            for b in s_axi_i.w.strb'range loop
                                if s_axi_i.w.strb(b) = '1' and not is_ram(wr_addr) then
                                    if idx <= 3 then
                                        regs(idx)(8*b+7 downto 8*b) <= s_axi_i.w.data(8*b+7 downto 8*b);
                                    elsif idx = IDX_OLED_CTRL then
                                        oled_ctrl(8*b+7 downto 8*b) <= s_axi_i.w.data(8*b+7 downto 8*b);
                                    elsif idx >= IDX_SCOPE_CFG and idx <= IDX_SCOPE_CFG+3 then
                                        scope_cfg(idx - IDX_SCOPE_CFG)(8*b+7 downto 8*b) <= s_axi_i.w.data(8*b+7 downto 8*b);
                                    elsif idx = IDX_GEN_FTW or idx = IDX_GEN_FTW+1 then
                                        scope_cfg(4 + idx - IDX_GEN_FTW)(8*b+7 downto 8*b) <= s_axi_i.w.data(8*b+7 downto 8*b);
                                    elsif idx >= IDX_TEXT then
                                        text(idx - IDX_TEXT)(8*b+7 downto 8*b) <= s_axi_i.w.data(8*b+7 downto 8*b);
                                    end if;
                                end if;
                            end loop;
                            wr_addr <= next_addr(wr_addr, wr_size, wr_burst);
                            if wr_beats = 1 or s_axi_i.w.last = '1' then
                                wready_r <= '0';
                                bvalid_r <= '1';
                                wr_state <= W_RESP;
                            else
                                wr_beats <= wr_beats - 1;
                            end if;
                        end if;

                    when W_RESP =>
                        if s_axi_i.bready = '1' then
                            bvalid_r <= '0';
                            wr_state <= W_IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- AXI read channel
    ---------------------------------------------------------------------------
    read_proc : process (s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                rd_state  <= R_IDLE;
                arready_r <= '0';
                rvalid_r  <= '0';
                rlast_r   <= '0';
            else
                case rd_state is

                    when R_IDLE =>
                        rvalid_r  <= '0';
                        rlast_r   <= '0';
                        arready_r <= '1';
                        if s_axi_i.ar.valid = '1' and arready_r = '1' then
                            rd_addr   <= unsigned(s_axi_i.ar.addr);
                            rd_id     <= s_axi_i.ar.id;
                            rd_size   <= s_axi_i.ar.size;
                            rd_burst  <= s_axi_i.ar.burst;
                            rd_beats  <= resize(unsigned(s_axi_i.ar.len), 5) + 1;
                            arready_r <= '0';
                            rd_state  <= R_FETCH;
                        end if;

                    when R_FETCH =>                     -- capture RAM reads rd_addr this clock
                        rvalid_r <= '1';
                        rlast_r  <= '1' when rd_beats = 1 else '0';
                        rd_state <= R_DATA;

                    when R_DATA =>
                        if s_axi_i.rready = '1' and rvalid_r = '1' then
                            rvalid_r <= '0';
                            rlast_r  <= '0';
                            if rd_beats = 1 then
                                rd_state <= R_IDLE;
                            else
                                rd_addr  <= next_addr(rd_addr, rd_size, rd_burst);
                                rd_beats <= rd_beats - 1;
                                rd_state <= R_FETCH;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
