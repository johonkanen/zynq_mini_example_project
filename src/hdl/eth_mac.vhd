-------------------------------------------------------------------------------
-- eth_mac.vhd  (VHDL-2008)
--
-- A MAC in the PL: hVHDL_gigabit_ethernet's ethernet_mac (submodule
-- src/hVHDL_gigabit_ethernet, compiled into library hvhdl_ethernet) on the
-- PL-side RTL8211E, through the Xilinx RGMII I/O cells (rgmii_rx_xilinx /
-- rgmii_tx_xilinx). Gigabit only. doc/hvhdl_ethernet.md, phase 1.
--
-- For now an echo test: ethernet_mac passes on frames for MAC_ADDR or
-- broadcast with a good CRC and length; those with EtherType ETHERTYPE go back
-- to their sender (destination = the old source, source = MAC_ADDR, payload as
-- received). Others are ignored.
--
--   receive  ethernet_mac m_t* (rx_clk) -> frame buffer, addresses swapped
--   transmit frame buffer -> s_t* (tx_clk), gapless as ethernet_mac_tx needs
--   the MAC's registers (APB) are set once after reset: address, address mask,
--   RX/TX enable - phase 2 hands them to the PS
--   MDIO: the MAC's, on the PHY's pins (the PHY keeps its power-on settings)
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

library hvhdl_ethernet;
use hvhdl_ethernet.ethernet_pkg.all;

entity eth_mac is
    generic (
        MAC_ADDR  : std_logic_vector(47 downto 0) := x"025A4D000010";   -- first byte on the wire in 47:40
        ETHERTYPE : std_logic_vector(15 downto 0) := x"88B5"            -- IEEE local experimental
    );
    port (
        clk          : in    std_logic;                     -- 100 MHz, makes the 125 MHz MAC clock
        rgmii_rxc    : in    std_logic;
        rgmii_rd     : in    std_logic_vector(3 downto 0);
        rgmii_rx_ctl : in    std_logic;
        rgmii_txc    : out   std_logic;
        rgmii_td     : out   std_logic_vector(3 downto 0);
        rgmii_tx_ctl : out   std_logic;
        mdc          : out   std_logic;
        mdio         : inout std_logic;
        -- counters (registers come in phase 2)
        echoed       : out   unsigned(15 downto 0);         -- tx_clk domain
        ignored      : out   unsigned(15 downto 0)          -- rx_clk domain: other EtherTypes
    );
end entity eth_mac;

architecture rtl of eth_mac is

    constant BUF_BYTES : natural := 2048;                   -- a frame without FCS: 1514 (1518 tagged)

    -- clocks and resets
    signal clkfb, clkfb_buf, clk125_mmcm, tx_clk, tx_locked : std_logic;
    signal clk200_mmcm, clk200 : std_logic;
    signal rx_clk : std_logic;
    signal reset_sr : std_logic_vector(7 downto 0) := (others => '1');
    signal reset    : std_logic;

    -- APB set-up of the MAC
    signal paddr  : std_logic_vector(8 downto 0) := (others => '0');
    signal psel, penable, pwrite : std_logic := '0';
    signal pwdata : std_logic_vector(31 downto 0) := (others => '0');
    signal pready, pslverror : std_logic;
    signal prdata : std_logic_vector(31 downto 0);
    type apb_write_t is record
        addr : natural;
        data : std_logic_vector(31 downto 0);
    end record;
    type apb_list_t is array (natural range <>) of apb_write_t;
    constant SETUP : apb_list_t := (
        (16#00c#, MAC_ADDR(23 downto 16) & MAC_ADDR(31 downto 24) & MAC_ADDR(39 downto 32) & MAC_ADDR(47 downto 40)),
        (16#010#, x"0000" & MAC_ADDR(7 downto 0) & MAC_ADDR(15 downto 8)),
        (16#144#, x"FFFFFFFF"),                             -- address mask: compare all 48 bits
        (16#148#, x"0000FFFF"),
        (16#008#, x"00000003"));                            -- COMMAND_CONFIG: TX_ENA, RX_ENA
    signal setup_idx : natural range 0 to SETUP'length := 0;

    -- MAC streams and pins
    signal s_tvalid, s_tready, s_tlast : std_logic := '0';
    signal s_tdata  : std_logic_vector(7 downto 0) := (others => '0');
    signal m_tvalid, m_tready, m_tlast : std_logic;
    signal m_tdata  : std_logic_vector(7 downto 0);
    signal rgmii_rx_in, rgmii_tx_out, tx_clock_out : rgmii_ddio_record;
    signal mdio_out, mdio_oe, mdio_in, mdio_t : std_logic;

    -- frame buffer: written in rx_clk, read in tx_clk (one block RAM)
    type buf_t is array (0 to BUF_BYTES - 1) of std_logic_vector(7 downto 0);
    signal buf : buf_t;
    attribute ram_style : string;
    attribute ram_style of buf : signal is "block";
    signal buf_we    : std_logic := '0';
    signal buf_waddr : natural range 0 to BUF_BYTES - 1 := 0;
    signal buf_wdata : std_logic_vector(7 downto 0) := (others => '0');
    signal buf_raddr : natural range 0 to BUF_BYTES - 1;

    -- receive side (rx_clk)
    type rx_state_t is (rx_recv, rx_wait);
    signal rx_state   : rx_state_t := rx_recv;
    signal widx       : natural range 0 to BUF_BYTES := 0;
    signal etype      : std_logic_vector(15 downto 0) := (others => '0');
    signal frame_len  : natural range 0 to BUF_BYTES := 0;    -- held for the transmit side
    signal req_tg     : std_logic := '0';
    signal done_meta, done_sync, done_seen : std_logic := '0';
    signal n_ignored  : unsigned(15 downto 0) := (others => '0');

    -- transmit side (tx_clk)
    type tx_state_t is (tx_idle, tx_send, tx_done);
    signal tx_state   : tx_state_t := tx_idle;
    signal req_meta, req_sync, req_seen : std_logic := '0';
    signal done_tg    : std_logic := '0';
    signal len_m1     : natural range 0 to BUF_BYTES := 0;   -- index of the last byte
    signal ra         : natural range 0 to BUF_BYTES - 1 := 0;  -- byte shown on s_tdata
    signal q          : std_logic_vector(7 downto 0) := (others => '0');
    signal n_echoed   : unsigned(15 downto 0) := (others => '0');

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of done_meta, done_sync, req_meta, req_sync : signal is "TRUE";

    function mac_byte(i : natural) return std_logic_vector is
    begin
        return MAC_ADDR(47 - 8 * i downto 40 - 8 * i);
    end function;

begin

    ---------------------------------------------------------------------------
    -- 125 MHz MAC clock (registers, transmit) and the 200 MHz IDELAYCTRL
    -- reference: 100 MHz x 10 = 1 GHz VCO, / 8 and / 5
    ---------------------------------------------------------------------------
    u_mmcm : MMCME2_BASE
        generic map (CLKIN1_PERIOD => 10.0, DIVCLK_DIVIDE => 1, CLKFBOUT_MULT_F => 10.0,
                     CLKOUT0_DIVIDE_F => 8.0, CLKOUT1_DIVIDE => 5)
        port map (CLKIN1 => clk, CLKFBIN => clkfb_buf, CLKFBOUT => clkfb, CLKOUT0 => clk125_mmcm,
                  CLKOUT1 => clk200_mmcm, LOCKED => tx_locked, PWRDWN => '0', RST => '0');
    u_bfb  : BUFG port map (I => clkfb, O => clkfb_buf);
    u_b125 : BUFG port map (I => clk125_mmcm, O => tx_clk);
    u_b200 : BUFG port map (I => clk200_mmcm, O => clk200);

    -- the receive IDELAYs' calibration (rgmii_rx_xilinx), reset until the MMCM locks
    u_idelayctrl : IDELAYCTRL port map (REFCLK => clk200, RST => reset, RDY => open);

    process (tx_clk, tx_locked)
    begin
        if tx_locked = '0' then
            reset_sr <= (others => '1');
        elsif rising_edge(tx_clk) then
            reset_sr <= reset_sr(6 downto 0) & '0';
        end if;
    end process;
    reset    <= reset_sr(7);

    ---------------------------------------------------------------------------
    -- the MAC
    ---------------------------------------------------------------------------
    u_mac : entity hvhdl_ethernet.ethernet_mac
        port map (
            clock        => tx_clk,
            reset        => reset,
            paddr        => paddr,
            psel         => psel,
            penable      => penable,
            pwrite       => pwrite,
            pwdata       => pwdata,
            pready       => pready,
            prdata       => prdata,
            pslverror    => pslverror,
            s_tvalid     => s_tvalid,
            s_tready     => s_tready,
            s_tdata      => s_tdata,
            s_tlast      => s_tlast,
            rx_clock     => rx_clk,
            rx_reset     => '0',
            m_tvalid     => m_tvalid,
            m_tready     => m_tready,
            m_tdata      => m_tdata,
            m_tlast      => m_tlast,
            rgmii_rx_in  => rgmii_rx_in,
            rgmii_tx_out => rgmii_tx_out,
            tx_clock_out => tx_clock_out,
            mdc          => mdc,
            mdio_out     => mdio_out,
            mdio_oe      => mdio_oe,
            mdio_in      => mdio_in
        );

    u_rx_io : entity work.rgmii_rx_xilinx
        port map (rxc => rgmii_rxc, rxd => rgmii_rd, rx_ctl => rgmii_rx_ctl, rx_clk => rx_clk,
                  ddio => rgmii_rx_in);

    u_tx_io : entity work.rgmii_tx_xilinx
        port map (clk => tx_clk, ddio => rgmii_tx_out, tx_clock => tx_clock_out, txc => rgmii_txc,
                  txd => rgmii_td, tx_ctl => rgmii_tx_ctl);

    mdio_t <= not mdio_oe;
    u_mdio_buf : IOBUF port map (I => mdio_out, O => mdio_in, T => mdio_t, IO => mdio);

    -- set the registers once after reset (APB: setup clock, then access; pready is always 1)
    apb_setup : process (tx_clk)
    begin
        if rising_edge(tx_clk) then
            if reset = '1' then
                setup_idx <= 0;
                psel      <= '0';
                penable   <= '0';
                pwrite    <= '0';
            elsif setup_idx < SETUP'length then
                if psel = '0' then
                    paddr  <= std_logic_vector(to_unsigned(SETUP(setup_idx).addr, 9));
                    pwdata <= SETUP(setup_idx).data;
                    pwrite <= '1';
                    psel   <= '1';
                elsif penable = '0' then
                    penable <= '1';
                elsif pready = '1' then
                    psel      <= '0';
                    penable   <= '0';
                    pwrite    <= '0';
                    setup_idx <= setup_idx + 1;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- echo, receive side: frames into the buffer with the addresses swapped:
    -- bytes 6..11 (the sender) go to 0..5, bytes 0..5 are dropped (6..11 are
    -- filled with MAC_ADDR when sent), the rest stays where it is
    ---------------------------------------------------------------------------
    m_tready <= '1' when rx_state = rx_recv else '0';

    echo_rx : process (rx_clk)
    begin
        if rising_edge(rx_clk) then
            done_meta <= done_tg;
            done_sync <= done_meta;
            buf_we    <= '0';

            case rx_state is
                when rx_recv =>
                    if m_tvalid = '1' then
                        -- the write lands a clock later (buf_write)
                        buf_wdata <= m_tdata;
                        if widx >= 6 and widx < 12 then
                            buf_we    <= '1';
                            buf_waddr <= widx - 6;
                        elsif widx >= 12 and widx < BUF_BYTES then
                            buf_we    <= '1';
                            buf_waddr <= widx;
                        end if;
                        if widx = 12 then
                            etype(15 downto 8) <= m_tdata;
                        elsif widx = 13 then
                            etype(7 downto 0) <= m_tdata;
                        end if;

                        if m_tlast = '1' then
                            widx <= 0;
                            -- ethernet_mac passes 60..1518 bytes: the EtherType is in
                            if etype = ETHERTYPE and widx < BUF_BYTES then
                                frame_len <= widx + 1;
                                req_tg    <= not req_tg;
                                rx_state  <= rx_wait;
                            else
                                n_ignored <= n_ignored + 1;
                            end if;
                        elsif widx < BUF_BYTES then
                            widx <= widx + 1;
                        end if;
                    end if;

                when rx_wait =>                             -- the MAC's FIFO holds new frames meanwhile
                    -- (the last byte's write lands in the first clock here, long before
                    -- the transmit side sees the request)
                    if done_sync /= done_seen then
                        done_seen <= done_sync;
                        rx_state  <= rx_recv;
                    end if;
            end case;
        end if;
    end process;

    buf_write : process (rx_clk)
    begin
        if rising_edge(rx_clk) then
            if buf_we = '1' then
                buf(buf_waddr) <= buf_wdata;
            end if;
        end if;
    end process;

    buf_read : process (tx_clk)
    begin
        if rising_edge(tx_clk) then
            q <= buf(buf_raddr);
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- echo, transmit side: the buffer onto s_t*, one byte a clock without gaps.
    -- q always holds buf(ra): the next address (buf_raddr) is chosen before the clock.
    ---------------------------------------------------------------------------
    s_tvalid <= '1' when tx_state = tx_send else '0';
    s_tdata  <= mac_byte(ra - 6) when ra >= 6 and ra < 12 else q;
    s_tlast  <= '1' when tx_state = tx_send and ra = len_m1 else '0';

    -- the byte to show next clock: 0 while idle, the next one when this one is taken
    buf_raddr <= 0      when tx_state = tx_idle else
                 ra + 1 when tx_state = tx_send and s_tready = '1' and ra /= len_m1 else
                 ra;

    echo_tx : process (tx_clk)
    begin
        if rising_edge(tx_clk) then
            req_meta <= req_tg;
            req_sync <= req_meta;
            ra       <= buf_raddr;

            case tx_state is
                when tx_idle =>
                    if req_sync /= req_seen then
                        req_seen <= req_sync;
                        len_m1   <= frame_len - 1;          -- stable since before the toggle
                        tx_state <= tx_send;
                    end if;
                when tx_send =>
                    if s_tready = '1' and ra = len_m1 then
                        n_echoed <= n_echoed + 1;
                        tx_state <= tx_done;
                    end if;
                when tx_done =>
                    done_tg  <= not done_tg;
                    tx_state <= tx_idle;
            end case;
        end if;
    end process;

    echoed  <= n_echoed;
    ignored <= n_ignored;

end architecture rtl;
