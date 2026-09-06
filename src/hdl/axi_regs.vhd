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
--
--   STATUS: bit0=or SCRATCH0, bit1=and SCRATCH1, bit2=(SCRATCH0=SCRATCH1),
--           bit3=CONTROL(0), bits[15:8]=popcount(SCRATCH2),
--           bits[31:16]=HEARTBEAT[15:0]
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.axi_pkg.all;

entity axi_regs is
    port (
        -- exported register view (for PL user logic)
        reg_ps2pl_o   : out std_logic_vector(4*AXI_DATA_WIDTH-1 downto 0);
        pl_active_o   : out std_logic;

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
    constant N_REGS  : integer := 8;

    subtype word_t is std_logic_vector(DW-1 downto 0);
    type    word_array_t is array (natural range <>) of word_t;

    signal regs : word_array_t(0 to 3) := (others => (others => '0'));   -- writable

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
    type rd_state_t is (R_IDLE, R_DATA);
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
        return to_integer(a(REG_LSB+2 downto REG_LSB));    -- 3 bits -> 0..7
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

    with reg_index(rd_addr) select rd_word <=
        regs(0)                        when 0,
        regs(1)                        when 1,
        regs(2)                        when 2,
        regs(3)                        when 3,
        std_logic_vector(heartbeat)    when 4,
        sum_w                          when 5,
        status_w                       when 6,
        x"5A5A1234"                    when 7,
        (others => '0')                when others;

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
            else
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
                            if idx <= 3 then
                                for b in s_axi_i.w.strb'range loop
                                    if s_axi_i.w.strb(b) = '1' then
                                        regs(idx)(8*b+7 downto 8*b) <= s_axi_i.w.data(8*b+7 downto 8*b);
                                    end if;
                                end loop;
                            end if;
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
                            rvalid_r  <= '1';
                            rlast_r   <= '1' when s_axi_i.ar.len = (s_axi_i.ar.len'range => '0') else '0';
                            rd_state  <= R_DATA;
                        end if;

                    when R_DATA =>
                        if s_axi_i.rready = '1' and rvalid_r = '1' then
                            if rd_beats = 1 then
                                rvalid_r <= '0';
                                rlast_r  <= '0';
                                rd_state <= R_IDLE;
                            else
                                rd_addr  <= next_addr(rd_addr, rd_size, rd_burst);
                                rd_beats <= rd_beats - 1;
                                rlast_r  <= '1' when rd_beats = 2 else '0';
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
