-------------------------------------------------------------------------------
-- tb_eth_mac.vhd  (VHDL-2008, VUnit)
--
-- eth_mac (hVHDL_gigabit_ethernet's ethernet_mac + the Xilinx RGMII I/O cells,
-- echo test) against a "PC": a second ethernet_mac behind the same I/O cells,
-- set up over APB here, on a clock 500 ppm off 125 MHz (so nothing is
-- accidentally synchronous). PHY models: data through, RXC 2 ns late (RTL8211E,
-- RGMII-ID); an optional bit flip on the wire spoils a frame's FCS.
-- share_port (a config of its own test in sim/run.py): eth_mac shares the port
-- with a GEM1 model on its GMII side, which sends frames with their FCS and
-- counts the frames it is given.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library hvhdl_ethernet;
use hvhdl_ethernet.ethernet_pkg.all;

entity tb_eth_mac is
    generic (runner_cfg : string; share_port : boolean := false);
end entity;

architecture sim of tb_eth_mac is

    constant MAC     : std_logic_vector(47 downto 0) := x"025A4D000010";   -- the DUT's
    constant PC_MAC  : std_logic_vector(47 downto 0) := x"001122334455";
    constant OTHER   : std_logic_vector(47 downto 0) := x"025A4D000099";
    constant GEM_MAC : std_logic_vector(47 downto 0) := x"025A4D000002";   -- GEM1 = eth1's
    constant IP      : std_logic_vector(31 downto 0) := x"C0A8140A";       -- the DUT's, 192.168.20.10
    constant PC_IP   : std_logic_vector(31 downto 0) := x"C0A81419";       -- 192.168.20.25
    constant T_PC    : time := 8.004 ns;

    type bytes_t is array (natural range <>) of std_logic_vector(7 downto 0);

    signal clk100, pc_clk : std_logic := '0';

    -- the PC's MAC
    signal paddr   : std_logic_vector(8 downto 0) := (others => '0');
    signal psel, penable, pwrite : std_logic := '0';
    signal pwdata  : std_logic_vector(31 downto 0) := (others => '0');
    signal pready, pslverror : std_logic;
    signal prdata  : std_logic_vector(31 downto 0);
    signal s_tvalid, s_tlast : std_logic := '0';
    signal s_tready : std_logic;
    signal s_tdata  : std_logic_vector(7 downto 0) := (others => '0');
    signal m_tvalid, m_tlast : std_logic;
    signal m_tdata  : std_logic_vector(7 downto 0);
    signal pc_rx_clk : std_logic;
    signal pc_rgmii_rx, pc_rgmii_tx, pc_tx_clock : rgmii_ddio_record;
    signal pc_mdc, pc_mdio_out, pc_mdio_oe : std_logic;

    -- wires / PHYs
    signal flip : boolean := false;
    signal pc_txc, pc_tx_ctl, mac_txc, mac_tx_ctl : std_logic;
    signal pc_txd, mac_txd : std_logic_vector(3 downto 0);
    signal mac_rxc, mac_rx_ctl, pc_rxc, pc_rx_ctl : std_logic := '0';
    signal mac_rxd, pc_rxd : std_logic_vector(3 downto 0) := (others => '0');
    signal mac_mdc : std_logic;
    signal mdio    : std_logic := 'H';

    signal echoed, ignored : unsigned(31 downto 0);

    -- the PS's bus (axi_regs' ETH window), driven here
    signal bus_req, bus_write, bus_ack : std_logic := '0';
    signal bus_addr  : std_logic_vector(10 downto 0) := (others => '0');
    signal bus_wdata, bus_rdata : std_logic_vector(31 downto 0) := (others => '0');

    -- the register file behind reg_* and the scope RAM behind scope_*
    signal reg_clk : std_logic := '0';
    signal reg_req, reg_write, reg_ack : std_logic := '0';
    signal reg_addr : std_logic_vector(15 downto 0);
    signal reg_wdata, reg_rdata : std_logic_vector(31 downto 0) := (others => '0');
    signal scope_clk : std_logic;
    signal scope_addr : unsigned(11 downto 0);
    signal scope_data : std_logic_vector(63 downto 0) := (others => '0');
    signal scope_done : std_logic := '1';
    constant SCOPE_START : natural := 4000;                -- the capture wraps the RAM's end

    -- GEM1's GMII (share_port)
    signal gem_tx_clk, gem_rx_clk, gem_rx_dv : std_logic;
    signal gem_txd : std_logic_vector(7 downto 0) := (others => '0');
    signal gem_tx_en : std_logic := '0';
    signal gem_rxd : std_logic_vector(7 downto 0);
    signal gem_frames, gem_length : natural := 0;    -- frames to send, their length without FCS
    signal gem_received : natural := 0;              -- frames given to it, with preamble and SFD

    -- what the PC received
    signal rx_bytes  : bytes_t(0 to 65535);
    signal rx_count  : natural := 0;
    signal rx_frames : natural := 0;
    type ends_t is array (0 to 63) of natural;
    signal rx_ends   : ends_t := (others => 0);

begin

    clk100 <= not clk100 after 5 ns;
    pc_clk <= not pc_clk after T_PC / 2;

    ---------------------------------------------------------------------------
    -- DUT
    ---------------------------------------------------------------------------
    dut : entity work.eth_mac
        generic map (MAC_ADDR => MAC, SHARE_PORT => share_port)
        port map (clk => clk100, rgmii_rxc => mac_rxc, rgmii_rd => mac_rxd, rgmii_rx_ctl => mac_rx_ctl,
                  rgmii_txc => mac_txc, rgmii_td => mac_txd, rgmii_tx_ctl => mac_tx_ctl,
                  mdc => mac_mdc, mdio => mdio, bus_req => bus_req, bus_write => bus_write,
                  bus_addr => bus_addr, bus_wdata => bus_wdata, bus_rdata => bus_rdata, bus_ack => bus_ack,
                  reg_req => reg_req, reg_write => reg_write, reg_addr => reg_addr, reg_wdata => reg_wdata,
                  reg_rdata => reg_rdata, reg_ack => reg_ack, scope_clk => scope_clk, scope_addr => scope_addr,
                  scope_data => scope_data, scope_done => scope_done,
                  scope_start => to_unsigned(SCOPE_START, 12),
                  echoed => echoed, ignored => ignored,
                  gem_tx_clk => gem_tx_clk, gem_txd => gem_txd, gem_tx_en => gem_tx_en,
                  gem_rx_clk => gem_rx_clk, gem_rxd => gem_rxd, gem_rx_dv => gem_rx_dv);
    mdio <= 'H';

    -- GEM1: gem_frames frames from GEM_MAC to the PC, EtherType 0x88B6, byte i of
    -- frame k = (k + i) mod 256 after the header, back to back on its clock
    gem_tx : process
        variable crc : std_logic_vector(31 downto 0);
        variable b   : std_logic_vector(7 downto 0);
    begin
        wait until gem_frames > 0;
        for k in 0 to gem_frames - 1 loop
            for i in 0 to 7 loop
                wait until rising_edge(gem_tx_clk);
                gem_tx_en <= '1';
                gem_txd   <= preamble_byte when i < 7 else start_of_frame_byte;
            end loop;
            crc := crc32_init;
            for i in 0 to gem_length - 1 loop
                if i < 6 then
                    b := PC_MAC(47 - 8 * i downto 40 - 8 * i);
                elsif i < 12 then
                    b := GEM_MAC(47 - 8 * (i - 6) downto 40 - 8 * (i - 6));
                elsif i = 12 then
                    b := x"88";
                elsif i = 13 then
                    b := x"B6";
                else
                    b := std_logic_vector(to_unsigned((k + i) mod 256, 8));
                end if;
                wait until rising_edge(gem_tx_clk);
                gem_txd <= b;
                crc := next_crc32(crc, b);
            end loop;
            for i in 0 to 3 loop
                wait until rising_edge(gem_tx_clk);
                gem_txd <= fcs_byte(crc, i);
            end loop;
            wait until rising_edge(gem_tx_clk);
            gem_tx_en <= '0';
            for i in 1 to 11 loop
                wait until rising_edge(gem_tx_clk);
            end loop;
        end loop;
        wait;
    end process;

    gem_rx : process (gem_rx_clk)
        variable n : natural := 0;
        variable ok : boolean := true;
    begin
        if rising_edge(gem_rx_clk) then
            if gem_rx_dv = '1' then
                if n < 7 then
                    ok := ok and gem_rxd = preamble_byte;
                elsif n = 7 then
                    ok := ok and gem_rxd = start_of_frame_byte;
                end if;
                n := n + 1;
            elsif n > 0 then
                if ok then
                    gem_received <= gem_received + 1;
                end if;
                n  := 0;
                ok := true;
            end if;
        end if;
    end process;

    -- the register file (as axi_regs' udp_* port, in its own clock)
    reg_clk <= not reg_clk after 5 ns;
    registers : process (reg_clk)
        type regfile_t is array (0 to 255) of std_logic_vector(31 downto 0);
        variable regfile : regfile_t := (others => (others => '0'));
        variable meta, sync, seen : std_logic := '0';
    begin
        if rising_edge(reg_clk) then
            if sync /= seen then
                seen := sync;
                if reg_write = '1' then
                    regfile(to_integer(unsigned(reg_addr(7 downto 0)))) := reg_wdata;
                end if;
                reg_rdata <= regfile(to_integer(unsigned(reg_addr(7 downto 0))));
                if reg_addr = x"001C" then
                    reg_rdata <= x"5A5A1234";
                end if;
                reg_ack <= not reg_ack;
            end if;
            sync := meta;
            meta := reg_req;
        end if;
    end process;

    -- the scope RAM: channel k of index a holds 4a + k (16 bits), a clock after the address
    scope_ram : process (scope_clk)
        variable a : natural;
    begin
        if rising_edge(scope_clk) then
            a := to_integer(scope_addr);
            for k in 0 to 3 loop
                scope_data(16 * k + 15 downto 16 * k) <= std_logic_vector(to_unsigned((4 * a + k) mod 65536, 16));
            end loop;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- PHY models
    ---------------------------------------------------------------------------
    process (pc_txd, flip, pc_tx_ctl)
    begin
        mac_rxd <= pc_txd;
        if flip and pc_tx_ctl = '1' then
            mac_rxd(0) <= not pc_txd(0);
        end if;
    end process;
    mac_rx_ctl <= pc_tx_ctl;
    mac_rxc    <= transport pc_txc after 2 ns;

    pc_rxd    <= mac_txd;
    pc_rx_ctl <= mac_tx_ctl;
    pc_rxc    <= transport mac_txc after 2 ns;

    ---------------------------------------------------------------------------
    -- the PC
    ---------------------------------------------------------------------------
    u_pc_mac : entity hvhdl_ethernet.ethernet_mac
        generic map (g_clocks_per_half_mdc => 4)
        port map (clock => pc_clk, reset => '0', paddr => paddr, psel => psel, penable => penable,
                  pwrite => pwrite, pwdata => pwdata, pready => pready, prdata => prdata,
                  pslverror => pslverror, s_tvalid => s_tvalid, s_tready => s_tready, s_tdata => s_tdata,
                  s_tlast => s_tlast, rx_clock => pc_rx_clk, m_tvalid => m_tvalid, m_tready => '1',
                  m_tdata => m_tdata, m_tlast => m_tlast, rgmii_rx_in => pc_rgmii_rx,
                  rgmii_tx_out => pc_rgmii_tx, tx_clock_out => pc_tx_clock, mdc => pc_mdc,
                  mdio_out => pc_mdio_out, mdio_oe => pc_mdio_oe, mdio_in => '1');

    u_pc_tx_io : entity work.rgmii_tx_xilinx
        port map (clk => pc_clk, ddio => pc_rgmii_tx, tx_clock => pc_tx_clock, txc => pc_txc, txd => pc_txd,
                  tx_ctl => pc_tx_ctl);
    u_pc_rx_io : entity work.rgmii_rx_xilinx
        port map (rxc => pc_rxc, rxd => pc_rxd, rx_ctl => pc_rx_ctl, rx_clk => pc_rx_clk, ddio => pc_rgmii_rx);

    sink : process (pc_rx_clk)
    begin
        if rising_edge(pc_rx_clk) and m_tvalid = '1' then
            rx_bytes(rx_count) <= m_tdata;
            rx_count <= rx_count + 1;
            if m_tlast = '1' then
                rx_ends(rx_frames) <= rx_count + 1;
                rx_frames <= rx_frames + 1;
            end if;
        end if;
    end process;

    main : process

        function frame(dst : std_logic_vector(47 downto 0); etype : std_logic_vector(15 downto 0);
                       seed, n : natural) return bytes_t is
            variable f : bytes_t(0 to n - 1);
        begin
            for i in 0 to 5 loop
                f(i)     := dst(47 - 8 * i downto 40 - 8 * i);
                f(6 + i) := PC_MAC(47 - 8 * i downto 40 - 8 * i);
            end loop;
            f(12) := etype(15 downto 8);
            f(13) := etype(7 downto 0);
            for i in 14 to n - 1 loop
                f(i) := std_logic_vector(to_unsigned((i * 7 + seed) mod 256, 8));
            end loop;
            return f;
        end function;

        -- ones' complement sum of the 16-bit words of f(lo..hi), folded; hi - lo + 1 even
        function csum16(f : bytes_t; lo, hi : natural) return unsigned is
            variable acc : unsigned(31 downto 0) := (others => '0');
        begin
            for i in 0 to (hi - lo + 1) / 2 - 1 loop
                acc := acc + unsigned(std_logic_vector'(f(lo + 2 * i) & f(lo + 2 * i + 1)));
            end loop;
            acc := resize(acc(15 downto 0), 32) + acc(31 downto 16);
            acc := resize(acc(15 downto 0), 32) + acc(31 downto 16);
            return acc(15 downto 0);
        end function;

        function put(f : bytes_t; at : natural; v : std_logic_vector) return bytes_t is
            variable r : bytes_t(f'range) := f;
            constant n : natural := v'length / 8;
            variable w : std_logic_vector(v'length - 1 downto 0) := v;
        begin
            for i in 0 to n - 1 loop
                r(at + i) := w(8 * (n - i) - 1 downto 8 * (n - i - 1));
            end loop;
            return r;
        end function;

        function get(f : bytes_t; at, n : natural) return std_logic_vector is
            variable v : std_logic_vector(8 * n - 1 downto 0);
        begin
            for i in 0 to n - 1 loop
                v(8 * (n - i) - 1 downto 8 * (n - i - 1)) := f(at + i);
            end loop;
            return v;
        end function;

        -- an ARP request from the PC for ip
        function arp_request(ip_wanted : std_logic_vector(31 downto 0)) return bytes_t is
            variable f : bytes_t(0 to 41) := (others => x"00");
        begin
            f := put(f, 0, x"FFFFFFFFFFFF");
            f := put(f, 6, PC_MAC);
            f := put(f, 12, x"0806");
            f := put(f, 14, x"0001080006040001");
            f := put(f, 22, PC_MAC);
            f := put(f, 28, PC_IP);
            f := put(f, 38, ip_wanted);
            return f;
        end function;

        -- Ethernet + IPv4 (no options, checksum filled in) + l4 bytes
        function ip_frame(dst_ip : std_logic_vector(31 downto 0); proto : std_logic_vector(7 downto 0);
                          l4 : bytes_t) return bytes_t is
            variable f : bytes_t(0 to 33 + l4'length) := (others => x"00");
        begin
            f := put(f, 0, MAC);
            f := put(f, 6, PC_MAC);
            f := put(f, 12, x"0800");
            f := put(f, 14, x"45");
            f := put(f, 16, std_logic_vector(to_unsigned(20 + l4'length, 16)));
            f := put(f, 18, x"1234");                      -- identification
            f := put(f, 20, x"4000");                      -- don't fragment
            f := put(f, 22, x"40");                        -- TTL 64
            f(23) := proto;
            f := put(f, 26, PC_IP);
            f := put(f, 30, dst_ip);
            f := put(f, 24, std_logic_vector(not csum16(f, 14, 33)));
            for i in l4'range loop
                f(34 + i - l4'low) := l4(i);
            end loop;
            return f;
        end function;

        -- ICMP echo request: id, sequence, n payload bytes, checksum filled in
        function icmp_echo(n : natural) return bytes_t is
            variable m : bytes_t(0 to 7 + n) := (others => x"00");
        begin
            m := put(m, 0, x"0800");
            m := put(m, 4, x"BEEF0001");
            for i in 0 to n - 1 loop
                m(8 + i) := std_logic_vector(to_unsigned((i * 13 + 5) mod 256, 8));
            end loop;
            m := put(m, 2, std_logic_vector(not csum16(m, 0, m'high)));
            return m;
        end function;

        -- UDP datagram (checksum with the pseudo header) inside its IP frame; n even
        function udp_frame(dst_ip : std_logic_vector(31 downto 0); dport : std_logic_vector(15 downto 0);
                           n : natural) return bytes_t is
            variable u  : bytes_t(0 to 7 + n) := (others => x"00");
            variable ph : bytes_t(0 to 11 + 8 + n) := (others => x"00");
        begin
            u := put(u, 0, x"D431");                       -- source port 54321
            u := put(u, 2, dport);
            u := put(u, 4, std_logic_vector(to_unsigned(8 + n, 16)));
            for i in 0 to n - 1 loop
                u(8 + i) := std_logic_vector(to_unsigned((i * 7 + 3) mod 256, 8));
            end loop;
            ph := put(ph, 0, PC_IP);
            ph := put(ph, 4, dst_ip);
            ph := put(ph, 8, x"0011");
            ph := put(ph, 10, std_logic_vector(to_unsigned(8 + n, 16)));
            for i in u'range loop
                ph(12 + i) := u(i);
            end loop;
            u := put(u, 6, std_logic_vector(not csum16(ph, 0, ph'high)));
            return ip_frame(dst_ip, x"11", u);
        end function;

        -- a UDP datagram with the given payload (from the PC's port 54321), checksum filled in
        function udp_payload_frame(dst_ip : std_logic_vector(31 downto 0); dport : std_logic_vector(15 downto 0);
                                   payload : bytes_t) return bytes_t is
            variable u  : bytes_t(0 to 7 + payload'length) := (others => x"00");
            variable ph : bytes_t(0 to 19 + payload'length + payload'length mod 2) := (others => x"00");
        begin
            u := put(u, 0, x"D431");
            u := put(u, 2, dport);
            u := put(u, 4, std_logic_vector(to_unsigned(u'length, 16)));
            for i in payload'range loop
                u(8 + i - payload'low) := payload(i);
            end loop;
            ph := put(ph, 0, PC_IP);
            ph := put(ph, 4, dst_ip);
            ph := put(ph, 8, x"0011");
            ph := put(ph, 10, std_logic_vector(to_unsigned(u'length, 16)));
            for i in u'range loop
                ph(12 + i) := u(i);
            end loop;
            u := put(u, 6, std_logic_vector(not csum16(ph, 0, ph'high)));
            return ip_frame(dst_ip, x"11", u);
        end function;

        -- the PC's n-th received frame, as bytes
        impure function received(n, len : natural) return bytes_t is
            variable r : bytes_t(0 to len - 1);
            variable first : natural := 0;
        begin
            if n > 0 then
                first := rx_ends(n - 1);
            end if;
            for i in r'range loop
                r(i) := rx_bytes(first + i);
            end loop;
            return r;
        end function;

        procedure apb_write(address : natural; data : std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(pc_clk);
            paddr  <= std_logic_vector(to_unsigned(address, 9));
            pwdata <= data;
            pwrite <= '1';
            psel   <= '1';
            wait until rising_edge(pc_clk);
            penable <= '1';
            wait until rising_edge(pc_clk) and pready = '1';
            psel    <= '0';
            penable <= '0';
            pwrite  <= '0';
        end procedure;

        -- a frame onto the PC MAC's stream: gapless once its first byte is taken
        procedure send(f : bytes_t) is
        begin
            for i in f'range loop
                s_tvalid <= '1';
                s_tdata  <= f(i);
                s_tlast  <= '1' when i = f'high else '0';
                wait until rising_edge(pc_clk) and s_tready = '1';
            end loop;
            s_tvalid <= '0';
            s_tlast  <= '0';
        end procedure;

        -- the PC's n-th received frame is the echo of f
        procedure check_echo(f : bytes_t; n : natural) is
            variable first : natural;
            variable want  : std_logic_vector(7 downto 0);
        begin
            first := 0;
            if n > 0 then
                first := rx_ends(n - 1);
            end if;
            check_equal(rx_ends(n) - first, f'length, "echo length");
            for i in f'range loop
                if i < 6 then
                    want := PC_MAC(47 - 8 * i downto 40 - 8 * i);
                elsif i < 12 then
                    want := MAC(47 - 8 * (i - 6) downto 40 - 8 * (i - 6));
                else
                    want := f(i);
                end if;
                check_equal(rx_bytes(first + i), want, "echo byte " & integer'image(i));
            end loop;
        end procedure;

        -- one access on the PS's bus, as axi_regs makes it
        procedure bus_access(address : natural; write : std_logic; wdata : std_logic_vector(31 downto 0);
                             variable rdata : out std_logic_vector(31 downto 0)) is
            variable ack0 : std_logic;
        begin
            ack0      := bus_ack;
            bus_addr  <= std_logic_vector(to_unsigned(address, 11));
            bus_write <= write;
            bus_wdata <= wdata;
            wait for 10 ns;
            bus_req   <= not bus_req;
            wait until bus_ack /= ack0 for 2 us;
            check(bus_ack /= ack0, "bus access answered");
            wait for 30 ns;                                -- as axi_regs: sample after its synchroniser
            rdata := bus_rdata;
        end procedure;

        variable r  : std_logic_vector(31 downto 0);
        variable fa : bytes_t(0 to 41);
        variable fi : bytes_t(0 to 73);                    -- 14 + 20 + 8 + 32
        variable fu : bytes_t(0 to 63);                    -- 14 + 20 + 8 + 22
        variable g  : bytes_t(0 to 73);
        variable prev_end : natural;
        variable n_fpga, n_gem : natural;
        variable f1 : bytes_t(0 to 59);
        variable f2 : bytes_t(0 to 99);
        variable fl : bytes_t(0 to 1513);
    begin
        test_runner_setup(runner, runner_cfg);
        -- the PC's MAC: its address, compare all bits, RX + TX on
        apb_write(16#00c#, PC_MAC(23 downto 16) & PC_MAC(31 downto 24) & PC_MAC(39 downto 32) & PC_MAC(47 downto 40));
        apb_write(16#010#, x"0000" & PC_MAC(7 downto 0) & PC_MAC(15 downto 8));
        apb_write(16#144#, x"FFFFFFFF");
        apb_write(16#148#, x"0000FFFF");
        apb_write(16#008#, x"00000003");
        wait for 3 us;                                     -- the DUT's MMCM locks, its MAC is set up

        while test_suite loop
            if run("frame to our MAC is echoed") then
                f1 := frame(MAC, x"88B5", 1, 60);
                send(f1);
                wait until rx_frames = 1 for 30 us;
                check_equal(rx_frames, 1, "echo arrived");
                check_echo(f1, 0);
                check_equal(echoed, 1, "echoed counter");

            elsif run("broadcast is echoed") then
                f1 := frame(x"FFFFFFFFFFFF", x"88B5", 2, 60);
                send(f1);
                wait until rx_frames = 1 for 30 us;
                check_equal(rx_frames, 1, "echo arrived");
                check_echo(f1, 0);

            elsif run("other EtherType is ignored") then
                send(frame(MAC, x"0800", 3, 60));
                wait for 30 us;
                check_equal(rx_frames, 0, "no echo");
                check_equal(ignored, 1, "ignored counter");

            elsif run("other destination is dropped by the MAC") then
                send(frame(OTHER, x"88B5", 4, 60));
                wait for 30 us;
                check_equal(rx_frames, 0, "no echo");
                check_equal(ignored, 0, "never reached the echo");

            elsif run("corrupted frame is dropped") then
                flip <= true;
                send(frame(MAC, x"88B5", 5, 60));
                wait for 1 us;
                flip <= false;
                wait for 30 us;
                check_equal(rx_frames, 0, "no echo");

            elsif run("two frames back to back are both echoed") then
                f1 := frame(MAC, x"88B5", 6, 60);
                f2 := frame(MAC, x"88B5", 7, 100);
                send(f1);
                send(f2);                                  -- waits in the MAC's FIFO meanwhile
                wait until rx_frames = 2 for 40 us;
                check_equal(rx_frames, 2, "both echoes arrived");
                check_echo(f1, 0);
                check_echo(f2, 1);

            elsif run("registers through the bus") then
                bus_access(16#00c#, '0', x"00000000", r);
                check_equal(r, MAC(23 downto 16) & MAC(31 downto 24) & MAC(39 downto 32) & MAC(47 downto 40),
                            "MAC_ADDR_LO as set after reset");
                bus_access(16#008#, '0', x"00000000", r);
                check_equal(r(1 downto 0), std_logic_vector'("11"), "COMMAND_CONFIG: RX + TX on");
                f1 := frame(MAC, x"88B5", 9, 60);
                send(f1);
                wait until rx_frames = 1 for 30 us;
                bus_access(16#06c#, '0', x"00000000", r);
                check_equal(to_integer(unsigned(r)), 1, "MAC: frames received");
                bus_access(16#068#, '0', x"00000000", r);
                check_equal(to_integer(unsigned(r)), 1, "MAC: frames transmitted");
                bus_access(16#200#, '0', x"00000000", r);
                check_equal(to_integer(unsigned(r)), 1, "echoed at 0x200");
                send(frame(MAC, x"0800", 10, 60));
                wait for 20 us;
                bus_access(16#204#, '0', x"00000000", r);
                check_equal(to_integer(unsigned(r)), 1, "ignored at 0x204");
                -- a write: receiving off, then a frame is not echoed
                bus_access(16#008#, '1', x"00000001", r);
                send(frame(MAC, x"88B5", 11, 60));
                wait for 20 us;
                check_equal(rx_frames, 1, "no echo with RX off");

            elsif run("ARP request for our IP is answered") then
                send(arp_request(IP));
                wait until rx_frames = 1 for 30 us;
                check_equal(rx_frames, 1, "ARP reply arrived");
                check_equal(rx_ends(0), 60, "reply padded like the request");
                fa := received(0, 42);
                check_equal(get(fa, 0, 6), PC_MAC, "to the PC");
                check_equal(get(fa, 6, 6), MAC, "from us");
                check_equal(get(fa, 12, 2), std_logic_vector'(x"0806"), "ARP");
                check_equal(get(fa, 14, 8), std_logic_vector'(x"0001080006040002"), "ARP reply header");
                check_equal(get(fa, 22, 6), MAC, "sender MAC = ours");
                check_equal(get(fa, 28, 4), IP, "sender IP = ours");
                check_equal(get(fa, 32, 6), PC_MAC, "target MAC = the PC");
                check_equal(get(fa, 38, 4), PC_IP, "target IP = the PC");

            elsif run("ARP request for another IP is ignored") then
                send(arp_request(x"C0A81463"));
                wait for 30 us;
                check_equal(rx_frames, 0, "no reply");

            elsif run("ping is answered") then
                fi := ip_frame(IP, x"01", icmp_echo(32));
                send(fi);
                wait until rx_frames = 1 for 30 us;
                check_equal(rx_frames, 1, "echo reply arrived");
                check_equal(rx_ends(0), fi'length, "same length");
                g := received(0, fi'length);
                check_equal(get(g, 0, 6), PC_MAC, "to the PC");
                check_equal(get(g, 26, 4), IP, "IP source = ours");
                check_equal(get(g, 30, 4), PC_IP, "IP destination = the PC");
                check_equal(csum16(g, 14, 33), unsigned'(x"FFFF"), "IP header checksum");
                check_equal(g(34), std_logic_vector'(x"00"), "ICMP echo reply");
                check_equal(csum16(g, 34, g'high), unsigned'(x"FFFF"), "ICMP checksum");
                check_equal(get(g, 38, 4), std_logic_vector'(x"BEEF0001"), "id and sequence kept");
                for i in 42 to g'high loop
                    check_equal(g(i), fi(i), "payload byte " & integer'image(i));
                end loop;

            elsif run("UDP to the echo port is echoed") then
                fu := udp_frame(IP, x"0007", 22);
                send(fu);
                wait until rx_frames = 1 for 30 us;
                check_equal(rx_frames, 1, "UDP reply arrived");
                g(0 to 63) := received(0, 64);
                check_equal(get(g, 26, 4), IP, "IP source = ours");
                check_equal(get(g, 30, 4), PC_IP, "IP destination = the PC");
                check_equal(csum16(g(0 to 63), 14, 33), unsigned'(x"FFFF"), "IP header checksum");
                check_equal(get(g, 34, 2), std_logic_vector'(x"0007"), "source port = 7");
                check_equal(get(g, 36, 2), std_logic_vector'(x"D431"), "destination port = the PC's");
                check_equal(get(g, 40, 2), get(fu, 40, 2), "UDP checksum unchanged (still valid)");
                for i in 42 to 63 loop
                    check_equal(g(i), fu(i), "payload byte " & integer'image(i));
                end loop;

            elsif run("UDP to another port is ignored") then
                send(udp_frame(IP, x"1234", 22));
                wait for 30 us;
                check_equal(rx_frames, 0, "no reply");

            elsif run("bad IP header checksum is ignored") then
                fi := ip_frame(IP, x"01", icmp_echo(32));
                fi(25) := fi(25) xor x"01";
                send(fi);
                wait for 30 us;
                check_equal(rx_frames, 0, "no reply");

            elsif run("IP address set through the bus") then
                bus_access(16#208#, '0', x"00000000", r);
                check_equal(r, IP, "IP after reset");
                bus_access(16#208#, '1', x"C0A81464", r);  -- 192.168.20.100
                wait for 1 us;
                send(ip_frame(IP, x"01", icmp_echo(32)));
                wait for 20 us;
                check_equal(rx_frames, 0, "the old IP gets no reply");
                send(ip_frame(x"C0A81464", x"01", icmp_echo(32)));
                wait until rx_frames = 1 for 30 us;
                check_equal(rx_frames, 1, "the new IP answers");
                send(arp_request(IP));
                wait until rx_frames = 2 for 30 us;
                send(udp_frame(x"C0A81464", x"0007", 22));
                wait until rx_frames = 2 for 30 us;
                bus_access(16#214#, '0', x"00000000", r);
                check_equal(to_integer(unsigned(r)), 1, "ICMP replies");
                bus_access(16#218#, '0', x"00000000", r);
                check_equal(to_integer(unsigned(r)), 1, "UDP replies");
                bus_access(16#210#, '0', x"00000000", r);
                check_equal(to_integer(unsigned(r)), 0, "no ARP reply for the old IP");

            elsif run("a stream comes back to the sender") then
                -- 0x01, 5 datagrams, 100 bytes each, to port 5000
                send(udp_payload_frame(IP, x"1388", (x"01", x"00", x"00", x"00", x"05", x"00", x"64")));
                wait until rx_frames = 5 for 60 us;
                check_equal(rx_frames, 5, "five datagrams");
                for n in 0 to 4 loop
                    prev_end := 0;
                    if n > 0 then
                        prev_end := rx_ends(n - 1);
                    end if;
                    check_equal(rx_ends(n) - prev_end, 142, "42 + 100 bytes");
                    fi := received(n, 74);              -- headers and the first 32 payload bytes
                    check_equal(get(fi, 12, 2), std_logic_vector'(x"0800"), "IPv4");
                    check_equal(csum16(fi, 14, 33), unsigned'(x"FFFF"), "IP header checksum");
                    check_equal(get(fi, 26, 4), IP, "from the FPGA");
                    check_equal(get(fi, 30, 4), PC_IP, "to the PC");
                    check_equal(get(fi, 34, 4), std_logic_vector'(x"1388D431"), "ports 5000 -> the PC's");
                    check_equal(get(fi, 38, 2), std_logic_vector'(x"006C"), "UDP length 108");
                    check_equal(get(fi, 42, 4), std_logic_vector(to_unsigned(n, 32)), "sequence number");
                    for i in 4 to 31 loop
                        check_equal(fi(42 + i), std_logic_vector(to_unsigned((n + i) mod 256, 8)), "pattern byte " & integer'image(i));
                    end loop;
                end loop;
                bus_access(16#224#, '0', x"00000000", r);
                check_equal(to_integer(unsigned(r)), 5, "datagrams sent (0x224)");
                bus_access(16#220#, '0', x"00000000", r);
                info("stream of 5 x 100 bytes took " & integer'image(to_integer(unsigned(r))) & " clocks");

            elsif run("registers over UDP") then
                -- write 0x08 = 0xDEADBEEF, then read it back, and the signature
                send(udp_payload_frame(IP, x"1388", (x"03", x"00", x"08", x"DE", x"AD", x"BE", x"EF")));
                wait until rx_frames = 1 for 30 us;
                check_equal(rx_frames, 1, "write reply");
                g(0 to 59) := received(0, 60);
                check_equal(get(g, 42, 8), std_logic_vector'(x"03000008DEADBEEF"), "write reply: the value written");
                send(udp_payload_frame(IP, x"1388", (x"02", x"00", x"08")));
                wait until rx_frames = 2 for 30 us;
                g(0 to 59) := received(1, 60);
                check_equal(get(g, 42, 8), std_logic_vector'(x"02000008DEADBEEF"), "read back");
                send(udp_payload_frame(IP, x"1388", (x"02", x"00", x"1C")));
                wait until rx_frames = 3 for 30 us;
                g(0 to 59) := received(2, 60);
                check_equal(get(g, 42, 8), std_logic_vector'(x"0200001C5A5A1234"), "the signature");

            elsif run("the scope capture over UDP") then
                send(udp_payload_frame(IP, x"1388", (0 => x"04")));
                wait until rx_frames = 32 for 400 us;
                check_equal(rx_frames, 32, "32 datagrams");
                for n in 0 to 31 loop
                    prev_end := 0;
                    if n > 0 then
                        prev_end := rx_ends(n - 1);
                    end if;
                    check_equal(rx_ends(n) - prev_end, 42 + 1028, "1028 payload bytes");
                    check_equal(get(rx_bytes, prev_end + 42, 4),
                                std_logic_vector(to_unsigned(n * 128, 16)) & x"1000", "offset, 4096");
                    for smp in 0 to 127 loop
                        for k in 0 to 3 loop
                            check_equal(rx_bytes(prev_end + 46 + 8 * smp + 2 * k + 1) & rx_bytes(prev_end + 46 + 8 * smp + 2 * k),
                                        std_logic_vector(to_unsigned((4 * ((SCOPE_START + n * 128 + smp) mod 4096) + k) mod 65536, 16)),
                                        "sample " & integer'image(n * 128 + smp) & " ch" & integer'image(k));
                        end loop;
                    end loop;
                end loop;

            elsif run("no capture, an error reply") then
                scope_done <= '0';
                wait for 1 us;
                send(udp_payload_frame(IP, x"1388", (0 => x"04")));
                wait until rx_frames = 1 for 30 us;
                g(0 to 59) := received(0, 60);
                check_equal(get(g, 42, 8), std_logic_vector'(x"04FF000000000000"), "error reply");

            elsif run("shared port: GEM1's frames and a stream at the same time") then
                -- the FPGA streams 20 x 1000 bytes while GEM1 sends 20 frames back to back:
                -- the PC gets all 40, whole
                send(udp_payload_frame(IP, x"1388", (x"01", x"00", x"00", x"00", x"14", x"03", x"E8")));
                gem_length <= 300;
                gem_frames <= 20;
                wait until rx_frames = 40 for 600 us;
                check_equal(rx_frames, 40, "frames at the PC");
                check(gem_received >= 1, "GEM1 was given the PC's frame");
                n_fpga := 0;
                n_gem  := 0;
                prev_end := 0;
                for n in 0 to rx_frames - 1 loop
                    fi := received(n, 74);
                    if get(fi, 6, 6) = GEM_MAC then
                        check_equal(rx_ends(n) - prev_end, 300, "GEM1's frame length");
                        for i in 14 to 73 loop
                            check_equal(fi(i), std_logic_vector(to_unsigned((n_gem + i) mod 256, 8)),
                                        "GEM1's frame " & integer'image(n_gem) & " byte " & integer'image(i));
                        end loop;
                        n_gem := n_gem + 1;
                    else
                        check_equal(get(fi, 6, 6), MAC, "from the FPGA");
                        check_equal(rx_ends(n) - prev_end, 1042, "42 + 1000 bytes");
                        check_equal(get(fi, 42, 4), std_logic_vector(to_unsigned(n_fpga, 32)), "sequence number");
                        n_fpga := n_fpga + 1;
                    end if;
                    prev_end := rx_ends(n);
                end loop;
                check_equal(n_gem, 20, "GEM1's frames");
                check_equal(n_fpga, 20, "the FPGA's datagrams");
                bus_access(16#180#, '0', x"00000000", r);
                check_equal(to_integer(unsigned(r)), 20, "GEM1's frames sent (0x180)");
                bus_access(16#184#, '0', x"00000000", r);
                check_equal(to_integer(unsigned(r)), 0, "GEM1's frames dropped (0x184)");

            elsif run("a full size frame is echoed") then
                fl := frame(MAC, x"88B5", 8, 1514);
                send(fl);
                wait until rx_frames = 1 for 60 us;
                check_equal(rx_frames, 1, "echo arrived");
                check_echo(fl, 0);
            end if;
        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture sim;
