-------------------------------------------------------------------------------
-- tb_eth_mac.vhd  (VHDL-2008, VUnit)
--
-- eth_mac (hVHDL_gigabit_ethernet's ethernet_mac + the Xilinx RGMII I/O cells,
-- echo test) against a "PC": a second ethernet_mac behind the same I/O cells,
-- set up over APB here, on a clock 500 ppm off 125 MHz (so nothing is
-- accidentally synchronous). PHY models: data through, RXC 2 ns late (RTL8211E,
-- RGMII-ID); an optional bit flip on the wire spoils a frame's FCS.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library hvhdl_ethernet;
use hvhdl_ethernet.ethernet_pkg.all;

entity tb_eth_mac is
    generic (runner_cfg : string);
end entity;

architecture sim of tb_eth_mac is

    constant MAC     : std_logic_vector(47 downto 0) := x"025A4D000010";   -- the DUT's
    constant PC_MAC  : std_logic_vector(47 downto 0) := x"001122334455";
    constant OTHER   : std_logic_vector(47 downto 0) := x"025A4D000099";
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

    signal echoed, ignored : unsigned(15 downto 0);

    -- what the PC received
    signal rx_bytes  : bytes_t(0 to 8191);
    signal rx_count  : natural := 0;
    signal rx_frames : natural := 0;
    type ends_t is array (0 to 15) of natural;
    signal rx_ends   : ends_t := (others => 0);

begin

    clk100 <= not clk100 after 5 ns;
    pc_clk <= not pc_clk after T_PC / 2;

    ---------------------------------------------------------------------------
    -- DUT
    ---------------------------------------------------------------------------
    dut : entity work.eth_mac
        generic map (MAC_ADDR => MAC)
        port map (clk => clk100, rgmii_rxc => mac_rxc, rgmii_rd => mac_rxd, rgmii_rx_ctl => mac_rx_ctl,
                  rgmii_txc => mac_txc, rgmii_td => mac_txd, rgmii_tx_ctl => mac_tx_ctl,
                  mdc => mac_mdc, mdio => mdio, echoed => echoed, ignored => ignored);
    mdio <= 'H';

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
