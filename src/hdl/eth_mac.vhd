-------------------------------------------------------------------------------
-- eth_mac.vhd  (VHDL-2008)
--
-- A MAC in the PL: hVHDL_gigabit_ethernet's ethernet_mac (submodule
-- src/hVHDL_gigabit_ethernet, compiled into library hvhdl_ethernet) on the
-- PL-side RTL8211E, through the Xilinx RGMII I/O cells (rgmii_rx_xilinx /
-- rgmii_tx_xilinx). Gigabit only. doc/hvhdl_ethernet.md.
--
-- On it, hVHDL_gigabit_ethernet's network_responder gives the FPGA an address
-- on the network: it answers ARP and ping for our IP, echoes UDP to our port and
-- sends frames with EtherType ETHERTYPE back (the phase 1 test) - between the
-- MAC's receive and transmit streams, with no Linux in the path.
--
-- And a UDP application on its user port (UDP_USER_PORT, 5000), commands in a
-- datagram's first bytes:
--   0x01 count(4) size(2)   stream: count datagrams of size payload bytes (18..1472)
--                           back to the sender, back to back - a 32-bit sequence
--                           number, then byte i = (sequence + i) mod 256; the time
--                           on the wire is kept in clocks (0x220) for the rate
--   0x02 addr(2)            read an axi_regs register (0x00..0xFF): reply
--                           02 00 addr(2) value(4)
--   0x03 addr(2) value(4)   write one: reply 03 00 addr(2) value(4)
--   0x04                    the oscilloscope's capture: 32 datagrams of 1028 bytes,
--                           offset(2) 4096(2) then 128 samples of ch0..ch3 (int16,
--                           little-endian) from the trigger's pre-history on; if no
--                           capture is done, the reply 04 FF 00 00 00000000
-- numbers big-endian unless said; every reply goes to the command's sender.
-- The datagrams go out through the library's udp_sender, sharing the MAC's
-- transmit stream with the responder's replies through its frame_mux.
--
--   registers: ethernet_mac's (APB) are set after reset (address, mask, RX/TX
--   on); the PS reaches them and ours through bus_* (axi_regs' ETH window):
--     0x000..0x1FF  ethernet_mac's APB registers (Efinix TSEMAC offsets)
--     0x200  raw frames echoed     0x204  frames ignored     (RO)
--     0x208  our IPv4 address      0x20C  UDP echo port       (RW)
--     0x210  ARP replies    0x214  ICMP echo replies    0x218  UDP replies (RO)
--     0x21C  UDP user port (RW)   0x220  last stream's clocks, 8 ns   0x224  its datagrams
--     0x228  datagrams to the user port
--   MDIO: the MAC's, on the PHY's pins (the PHY keeps its power-on settings)
--
-- SHARE_PORT (PL_ETH = shared, doc/hvhdl_ethernet.md phase 5): the port is shared
-- with GEM1 = Linux eth1 at the GMII level - ethernet_mac's g_shared_port: GEM1
-- gets every received frame (gem_rx_*, on the receive clock) and its frames go
-- onto the line between ours through a FIFO (gem_tx_*, on our 125 MHz clock,
-- which is GEM1's transmit clock). Each MAC filters for its own address. MDIO
-- is then GEM1's (Linux phylib), on the same pins.
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
        IP_ADDR   : std_logic_vector(31 downto 0) := x"C0A8140A";       -- 192.168.20.10 after reset
        UDP_PORT  : std_logic_vector(15 downto 0) := x"0007";           -- the echo port after reset
        UDP_USER_PORT : std_logic_vector(15 downto 0) := x"1388";       -- 5000: the application
        ETHERTYPE : std_logic_vector(15 downto 0) := x"88B5";           -- IEEE local experimental
        SHARE_PORT : boolean := false                                       -- the port shared with GEM1
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
        -- GEM1's GMII and MDIO (SHARE_PORT)
        gem_tx_clk   : out   std_logic;
        gem_txd      : in    std_logic_vector(7 downto 0) := (others => '0');
        gem_tx_en    : in    std_logic := '0';
        gem_tx_er    : in    std_logic := '0';
        gem_rx_clk   : out   std_logic;
        gem_rxd      : out   std_logic_vector(7 downto 0);
        gem_rx_dv    : out   std_logic;
        gem_rx_er    : out   std_logic;
        gem_mdc      : in    std_logic := '0';
        gem_mdio_o   : in    std_logic := '0';
        gem_mdio_t   : in    std_logic := '1';
        gem_mdio_i   : out   std_logic;
        -- the PS's access (axi_regs ETH window): address, write and data are held
        -- from the request toggle until the acknowledge toggle
        bus_req      : in    std_logic;
        bus_write    : in    std_logic;
        bus_addr     : in    std_logic_vector(10 downto 0);
        bus_wdata    : in    std_logic_vector(31 downto 0);
        bus_rdata    : out   std_logic_vector(31 downto 0);
        bus_ack      : out   std_logic;
        -- register access for the UDP commands (axi_regs udp_*), handshake with toggles
        reg_req      : out   std_logic;
        reg_write    : out   std_logic;
        reg_addr     : out   std_logic_vector(15 downto 0);
        reg_wdata    : out   std_logic_vector(31 downto 0);
        reg_rdata    : in    std_logic_vector(31 downto 0);
        reg_ack      : in    std_logic;
        -- the oscilloscope's capture: a second read port in our clock, its state from axi_regs' clock
        scope_clk    : out   std_logic;
        scope_addr   : out   unsigned(11 downto 0);
        scope_data   : in    std_logic_vector(63 downto 0);   -- ch3:ch2:ch1:ch0, a clock after scope_addr
        scope_done   : in    std_logic;
        scope_start  : in    unsigned(11 downto 0);           -- RAM index of the capture's first sample
        -- counters, tx_clk domain (also at 0x200 / 0x204)
        echoed       : out   unsigned(31 downto 0);
        ignored      : out   unsigned(31 downto 0)
    );
end entity eth_mac;

architecture rtl of eth_mac is

    attribute ASYNC_REG : string;

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

    -- the PS's bus and our registers, in tx_clk
    signal bus_req_meta, bus_req_sync, bus_req_seen : std_logic := '0';
    signal bus_ack_r   : std_logic := '0';
    signal bus_rdata_r : std_logic_vector(31 downto 0) := (others => '0');
    attribute ASYNC_REG of bus_req_meta, bus_req_sync : signal is "TRUE";
    signal my_ip       : std_logic_vector(31 downto 0) := IP_ADDR;
    signal udp_port_r  : std_logic_vector(15 downto 0) := UDP_PORT;
    signal user_port_r : std_logic_vector(15 downto 0) := UDP_USER_PORT;
    signal n_arp, n_icmp, n_udp, n_echoed, n_ignored, n_user : unsigned(31 downto 0) := (others => '0');
    signal arp_replied, icmp_replied, udp_replied, raw_echoed, user_received, frame_ignored : boolean;

    -- the responder's replies and the application's datagrams, onto the MAC's transmit stream
    signal r_tvalid, r_tready, r_tlast : std_logic;
    signal r_tdata : std_logic_vector(7 downto 0);
    signal d_tvalid, d_tready, d_tlast : std_logic;
    signal d_tdata : std_logic_vector(7 downto 0);

    -- datagrams to the user port (tx_clk)
    signal user_tvalid, user_tlast : std_logic;
    signal user_tdata : std_logic_vector(7 downto 0);
    signal user_length : natural range 0 to 2047;
    signal user_source_address : std_logic_vector(47 downto 0);
    signal user_source_ip : std_logic_vector(31 downto 0);
    signal user_source_port : std_logic_vector(15 downto 0);
    signal cmd_index : natural range 0 to 7 := 0;
    type cmd_array is array (0 to 6) of std_logic_vector(7 downto 0);
    signal cmd : cmd_array := (others => (others => '0'));

    -- the application's jobs and their payloads into udp_sender
    type job_t is (no_job, register_access, reply, stream, scope);
    signal job         : job_t := no_job;
    signal dst_address : std_logic_vector(47 downto 0) := (others => '0');
    signal dst_ip      : std_logic_vector(31 downto 0) := (others => '0');
    signal dst_port    : std_logic_vector(15 downto 0) := (others => '0');
    signal size        : natural range 1 to 1472 := 18;    -- this datagram's payload
    signal byte_index  : natural range 0 to 1471 := 0;
    signal datagrams   : unsigned(31 downto 0) := (others => '0');   -- still to send
    signal stream_seq  : unsigned(31 downto 0) := (others => '0');
    signal stream_clocks, stream_sent : unsigned(31 downto 0) := (others => '0');
    signal reply_bytes : cmd_array := (others => (others => '0'));
    signal reply_last  : std_logic_vector(7 downto 0) := (others => '0');   -- the 8th byte
    signal reg_req_r, reg_write_r : std_logic := '0';
    signal reg_addr_r  : std_logic_vector(15 downto 0) := (others => '0');
    signal reg_wdata_r : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_ack_meta, reg_ack_sync, reg_ack_seen : std_logic := '0';
    attribute ASYNC_REG of reg_ack_meta, reg_ack_sync : signal is "TRUE";
    signal scope_state : std_logic_vector(12 downto 0);           -- done & start, in tx_clk
    signal scope_first : unsigned(11 downto 0) := (others => '0');
    signal scope_n     : natural range 0 to 31 := 0;              -- datagram of the capture
    signal sample_addr : unsigned(11 downto 0) := (others => '0');
    signal sample_word : std_logic_vector(63 downto 0) := (others => '0');
    signal p_tvalid, p_tready, p_tlast : std_logic := '0';
    signal p_tdata : std_logic_vector(7 downto 0);
    signal datagram_sent : boolean;

    -- MAC streams and pins
    signal s_tvalid, s_tready, s_tlast : std_logic := '0';
    signal s_tdata  : std_logic_vector(7 downto 0) := (others => '0');
    signal m_tvalid, m_tready, m_tlast : std_logic;
    signal m_tdata  : std_logic_vector(7 downto 0);
    signal rgmii_rx_in, rgmii_tx_out, tx_clock_out : rgmii_ddio_record;
    signal mdio_out, mdio_oe, mdio_in, mdio_t : std_logic;
    signal mac_mdc, pin_mdio_o, pin_mdio_t : std_logic;
    signal gem_tx, gem_rx : gmii_record := gmii_idle;

    -- an address with its first byte (on the wire) in bits 7:0, as hVHDL_gigabit_ethernet takes it
    function byte_0_low(v : std_logic_vector) return std_logic_vector is
        constant n : natural := v'length / 8;
        variable w : std_logic_vector(v'length - 1 downto 0) := v;
        variable r : std_logic_vector(v'length - 1 downto 0);
    begin
        for i in 0 to n - 1 loop
            r(8 * i + 7 downto 8 * i) := w(8 * (n - i) - 1 downto 8 * (n - i - 1));
        end loop;
        return r;
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
        generic map (g_shared_port => SHARE_PORT)
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
            mdc          => mac_mdc,
            mdio_out     => mdio_out,
            mdio_oe      => mdio_oe,
            mdio_in      => mdio_in,
            share_tx_in  => gem_tx,
            share_rx_out => gem_rx
        );

    -- GEM1's GMII: its transmit registered once on the way in (the PS's EMIO
    -- outputs on our clock), its receive straight from rgmii_rx's registers
    gem_tx_clk <= tx_clk;
    gem_rx_clk <= rx_clk;
    gem_rxd    <= gem_rx.data;
    gem_rx_dv  <= '1' when gem_rx.is_valid else '0';
    gem_rx_er  <= '1' when gem_rx.is_error else '0';

    process (tx_clk)
    begin
        if rising_edge(tx_clk) then
            gem_tx <= (data => gem_txd, is_valid => gem_tx_en = '1', is_error => gem_tx_er = '1');
        end if;
    end process;

    u_rx_io : entity work.rgmii_rx_xilinx
        port map (rxc => rgmii_rxc, rxd => rgmii_rd, rx_ctl => rgmii_rx_ctl, rx_clk => rx_clk,
                  ddio => rgmii_rx_in);

    u_tx_io : entity work.rgmii_tx_xilinx
        port map (clk => tx_clk, ddio => rgmii_tx_out, tx_clock => tx_clock_out, txc => rgmii_txc,
                  txd => rgmii_td, tx_ctl => rgmii_tx_ctl);

    -- MDIO on the pins: ours, or GEM1's when the port is shared
    mdio_t     <= not mdio_oe;
    mdc        <= gem_mdc when SHARE_PORT else mac_mdc;
    pin_mdio_o <= gem_mdio_o when SHARE_PORT else mdio_out;
    pin_mdio_t <= gem_mdio_t when SHARE_PORT else mdio_t;
    u_mdio_buf : IOBUF port map (I => pin_mdio_o, O => mdio_in, T => pin_mdio_t, IO => mdio);
    gem_mdio_i <= mdio_in;

    -- APB master: the set-up after reset first, then the PS's accesses (setup
    -- clock, then access until pready - which ethernet_mac always gives)
    bus_rdata <= bus_rdata_r;
    bus_ack   <= bus_ack_r;

    apb_master : process (tx_clk)
        variable a : natural range 0 to 2047;
    begin
        if rising_edge(tx_clk) then
            bus_req_meta <= bus_req;
            bus_req_sync <= bus_req_meta;

            if reset = '1' then
                setup_idx    <= 0;
                psel         <= '0';
                penable      <= '0';
                pwrite       <= '0';
                bus_req_seen <= bus_req_sync;
            elsif psel = '1' then                       -- a transfer is on
                if penable = '0' then
                    penable <= '1';
                elsif pready = '1' then
                    psel    <= '0';
                    penable <= '0';
                    pwrite  <= '0';
                    if setup_idx < SETUP'length then
                        setup_idx <= setup_idx + 1;
                    else                                -- the PS's: answer it
                        bus_rdata_r <= prdata;
                        bus_ack_r   <= not bus_ack_r;
                    end if;
                end if;
            elsif setup_idx < SETUP'length then
                paddr  <= std_logic_vector(to_unsigned(SETUP(setup_idx).addr, 9));
                pwdata <= SETUP(setup_idx).data;
                pwrite <= '1';
                psel   <= '1';
            elsif bus_req_sync /= bus_req_seen then
                bus_req_seen <= bus_req_sync;
                a := to_integer(unsigned(bus_addr));
                if a < 16#200# then                     -- ethernet_mac's registers
                    paddr  <= bus_addr(8 downto 0);
                    pwdata <= bus_wdata;
                    pwrite <= bus_write;
                    psel   <= '1';
                else                                    -- ours
                    if bus_write = '1' then
                        case a is
                            when 16#208# => my_ip      <= bus_wdata;
                            when 16#20C# => udp_port_r <= bus_wdata(15 downto 0);
                            when 16#21C# => user_port_r <= bus_wdata(15 downto 0);
                            when others  => null;
                        end case;
                    end if;
                    case a is
                        when 16#200# => bus_rdata_r <= std_logic_vector(n_echoed);
                        when 16#204# => bus_rdata_r <= std_logic_vector(n_ignored);
                        when 16#208# => bus_rdata_r <= my_ip;
                        when 16#20C# => bus_rdata_r <= x"0000" & udp_port_r;
                        when 16#210# => bus_rdata_r <= std_logic_vector(n_arp);
                        when 16#214# => bus_rdata_r <= std_logic_vector(n_icmp);
                        when 16#218# => bus_rdata_r <= std_logic_vector(n_udp);
                        when 16#21C# => bus_rdata_r <= x"0000" & user_port_r;
                        when 16#220# => bus_rdata_r <= std_logic_vector(stream_clocks);
                        when 16#224# => bus_rdata_r <= std_logic_vector(stream_sent);
                        when 16#228# => bus_rdata_r <= std_logic_vector(n_user);
                        when others  => bus_rdata_r <= (others => '0');
                    end case;
                    bus_ack_r <= not bus_ack_r;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- the responder (ARP, ping, UDP echo, raw echo) between the MAC's streams
    ---------------------------------------------------------------------------
    u_responder : entity hvhdl_ethernet.network_responder
        generic map (g_raw_ethertype => ETHERTYPE)
        port map (
            rx_clock      => rx_clk,
            s_tvalid      => m_tvalid,
            s_tready      => m_tready,
            s_tdata       => m_tdata,
            s_tlast       => m_tlast,
            clock         => tx_clk,
            m_tvalid      => r_tvalid,
            m_tready      => r_tready,
            m_tdata       => r_tdata,
            m_tlast       => r_tlast,
            own_address   => byte_0_low(MAC_ADDR),
            own_ip        => byte_0_low(my_ip),
            udp_echo_port => udp_port_r,
            udp_user_port => user_port_r,
            user_tvalid   => user_tvalid,
            user_tready   => '1',
            user_tdata    => user_tdata,
            user_tlast    => user_tlast,
            user_length   => user_length,
            user_source_address => user_source_address,
            user_source_ip      => user_source_ip,
            user_source_port    => user_source_port,
            arp_replied   => arp_replied,
            icmp_replied  => icmp_replied,
            udp_replied   => udp_replied,
            raw_echoed    => raw_echoed,
            user_received => user_received,
            ignored       => frame_ignored
        );

    u_sender : entity hvhdl_ethernet.udp_sender
        port map (
            clock               => tx_clk,
            source_address      => byte_0_low(MAC_ADDR),
            source_ip           => byte_0_low(my_ip),
            source_port         => user_port_r,
            destination_address => dst_address,
            destination_ip      => dst_ip,
            destination_port    => dst_port,
            payload_length      => size,
            s_tvalid            => p_tvalid,
            s_tready            => p_tready,
            s_tdata             => p_tdata,
            s_tlast             => p_tlast,
            m_tvalid            => d_tvalid,
            m_tready            => d_tready,
            m_tdata             => d_tdata,
            m_tlast             => d_tlast,
            sent                => datagram_sent
        );

    -- the responder's replies first, then the application's datagrams
    u_tx_mux : entity hvhdl_ethernet.frame_mux
        port map (
            clock    => tx_clk,
            a_tvalid => r_tvalid,
            a_tready => r_tready,
            a_tdata  => r_tdata,
            a_tlast  => r_tlast,
            b_tvalid => d_tvalid,
            b_tready => d_tready,
            b_tdata  => d_tdata,
            b_tlast  => d_tlast,
            m_tvalid => s_tvalid,
            m_tready => s_tready,
            m_tdata  => s_tdata,
            m_tlast  => s_tlast
        );

    ---------------------------------------------------------------------------
    -- the application: commands from datagrams to the user port, one job at a time
    ---------------------------------------------------------------------------
    reg_req   <= reg_req_r;
    reg_write <= reg_write_r;
    reg_addr  <= reg_addr_r;
    reg_wdata <= reg_wdata_r;
    scope_clk <= tx_clk;
    scope_addr <= sample_addr;

    u_scope_state_cdc : entity hvhdl_ethernet.cdc_snapshot
        generic map (g_width => 13)
        port map (source_clock => clk, source_data => scope_done & std_logic_vector(scope_start),
                  destination_clock => tx_clk, destination_data => scope_state);

    application : process (tx_clk)
        variable c    : cmd_array;
        variable n    : natural range 0 to 65535;
        variable last : boolean;
    begin
        if rising_edge(tx_clk) then
            reg_ack_meta <= reg_ack;
            reg_ack_sync <= reg_ack_meta;

            if user_tvalid = '1' then
                if cmd_index < 7 then
                    cmd(cmd_index) <= user_tdata;
                    cmd_index <= cmd_index + 1;
                end if;
                if user_tlast = '1' then
                    cmd_index <= 0;
                    c := cmd;                               -- with this, the last byte
                    if cmd_index < 7 then
                        c(cmd_index) := user_tdata;
                    end if;
                    if job = no_job then
                        dst_address <= user_source_address;
                        dst_ip      <= user_source_ip;
                        dst_port    <= user_source_port;
                        reply_bytes <= (c(0), x"00", c(1), c(2), x"00", x"00", x"00");
                        reply_last  <= x"00";
                        byte_index  <= 0;
                        if c(0) = x"01" and user_length = 7 then             -- stream
                            n := to_integer(unsigned(std_logic_vector'(c(5) & c(6))));
                            if n < 18 then n := 18; elsif n > 1472 then n := 1472; end if;
                            datagrams     <= unsigned(std_logic_vector'(c(1) & c(2) & c(3) & c(4)));
                            size          <= n;
                            stream_seq    <= (others => '0');
                            stream_clocks <= (others => '0');
                            stream_sent   <= (others => '0');
                            if unsigned(std_logic_vector'(c(1) & c(2) & c(3) & c(4))) /= 0 then
                                job <= stream;
                            end if;
                        elsif (c(0) = x"02" and user_length = 3) or (c(0) = x"03" and user_length = 7) then
                            reg_addr_r  <= c(1) & c(2);
                            reg_write_r <= '1' when c(0) = x"03" else '0';
                            reg_wdata_r <= c(3) & c(4) & c(5) & c(6);
                            reg_req_r   <= not reg_req_r;
                            job         <= register_access;
                        elsif c(0) = x"04" and user_length = 1 then           -- the capture
                            if scope_state(12) = '1' then
                                scope_first <= unsigned(scope_state(11 downto 0));
                                sample_addr <= unsigned(scope_state(11 downto 0));
                                scope_n     <= 0;
                                datagrams   <= to_unsigned(32, 32);
                                size        <= 1028;
                                job         <= scope;
                            else
                                reply_bytes <= (x"04", x"FF", x"00", x"00", x"00", x"00", x"00");   -- no capture
                                size <= 8;
                                job  <= reply;
                            end if;
                        end if;
                    end if;
                end if;
            end if;

            CASE job is
                WHEN register_access =>
                    if reg_ack_sync /= reg_ack_seen then
                        reg_ack_seen   <= reg_ack_sync;
                        if reg_write_r = '1' then           -- the value written
                            reply_bytes(4) <= reg_wdata_r(31 downto 24);
                            reply_bytes(5) <= reg_wdata_r(23 downto 16);
                            reply_bytes(6) <= reg_wdata_r(15 downto 8);
                            reply_last     <= reg_wdata_r(7 downto 0);
                        else
                            reply_bytes(4) <= reg_rdata(31 downto 24);
                            reply_bytes(5) <= reg_rdata(23 downto 16);
                            reply_bytes(6) <= reg_rdata(15 downto 8);
                            reply_last     <= reg_rdata(7 downto 0);
                        end if;
                        size           <= 8;
                        job            <= reply;
                    end if;

                WHEN reply =>
                    if p_tvalid = '1' and p_tready = '1' then
                        if byte_index = size - 1 then
                            job <= no_job;
                        else
                            byte_index <= byte_index + 1;
                        end if;
                    end if;

                WHEN stream =>
                    stream_clocks <= stream_clocks + 1;
                    if p_tvalid = '1' and p_tready = '1' then
                        if byte_index = size - 1 then
                            byte_index  <= 0;
                            stream_seq  <= stream_seq + 1;
                            stream_sent <= stream_sent + 1;
                            if datagrams = 1 then
                                job <= no_job;
                            end if;
                            datagrams <= datagrams - 1;
                        else
                            byte_index <= byte_index + 1;
                        end if;
                    end if;

                WHEN scope =>
                    -- 4 header bytes, then 8 bytes a sample: the next sample is read while one
                    -- goes out (scope_data comes a clock after sample_addr)
                    if p_tvalid = '1' and p_tready = '1' then
                        -- (not at a datagram's last byte: the next one fetches at its byte 3)
                        if byte_index = 3 or (byte_index >= 4 and (byte_index - 4) mod 8 = 7
                                              and byte_index /= size - 1) then
                            sample_word <= scope_data;              -- the sample for the next 8 bytes
                            sample_addr <= sample_addr + 1;
                        end if;
                        if byte_index = size - 1 then
                            byte_index <= 0;
                            scope_n    <= scope_n + 1 when scope_n < 31 else 0;
                            if datagrams = 1 then
                                job <= no_job;
                            end if;
                            datagrams <= datagrams - 1;
                        else
                            byte_index <= byte_index + 1;
                        end if;
                    end if;

                WHEN no_job =>
                    null;
            end CASE;
        end if;
    end process;

    p_tvalid <= '1' when job = reply or job = stream or job = scope else '0';
    p_tlast  <= '1' when p_tvalid = '1' and byte_index = size - 1 else '0';

    payload_byte : process (all)
        variable k : natural range 0 to 7;
        variable offset : unsigned(15 downto 0);
    begin
        p_tdata <= (others => '0');
        CASE job is
            WHEN reply =>
                if byte_index < 7 then
                    p_tdata <= reply_bytes(byte_index);
                else
                    p_tdata <= reply_last;
                end if;
            WHEN stream =>
                case byte_index is
                    when 0      => p_tdata <= std_logic_vector(stream_seq(31 downto 24));
                    when 1      => p_tdata <= std_logic_vector(stream_seq(23 downto 16));
                    when 2      => p_tdata <= std_logic_vector(stream_seq(15 downto 8));
                    when 3      => p_tdata <= std_logic_vector(stream_seq(7 downto 0));
                    when others => p_tdata <= std_logic_vector(stream_seq(7 downto 0) + to_unsigned(byte_index mod 256, 8));
                end case;
            WHEN scope =>
                offset := to_unsigned(scope_n * 128, 16);
                case byte_index is
                    when 0      => p_tdata <= std_logic_vector(offset(15 downto 8));
                    when 1      => p_tdata <= std_logic_vector(offset(7 downto 0));
                    when 2      => p_tdata <= x"10";        -- 4096 samples
                    when 3      => p_tdata <= x"00";
                    when others =>
                        k := (byte_index - 4) mod 8;        -- byte k of ch3:ch2:ch1:ch0, little-endian
                        p_tdata <= sample_word(8 * k + 7 downto 8 * k);
                end case;
            WHEN others =>
                null;
        end CASE;
    end process;

    counters : process (tx_clk)
    begin
        if rising_edge(tx_clk) then
            if arp_replied   then n_arp     <= n_arp + 1;     end if;
            if icmp_replied  then n_icmp    <= n_icmp + 1;    end if;
            if udp_replied   then n_udp     <= n_udp + 1;     end if;
            if raw_echoed    then n_echoed  <= n_echoed + 1;  end if;
            if frame_ignored then n_ignored <= n_ignored + 1; end if;
            if user_received then n_user    <= n_user + 1;    end if;
        end if;
    end process;

    echoed  <= n_echoed;
    ignored <= n_ignored;

end architecture rtl;
