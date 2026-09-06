-------------------------------------------------------------------------------
-- tb_axi_regs.vhd  (VHDL-2008, VUnit)
--
-- Simulation model of the PS <-> PL AXI communication: a small AXI3 master
-- bus-functional model drives axi_regs exactly the way the Zynq M_AXI_GP0
-- port would, and the tests check the register behaviour, ID reflection and
-- burst handling.
--
--   Run:  python sim/run.py            (NVC backend, see sim/run.py)
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

entity tb_axi_regs is
    generic (runner_cfg : string);
end entity;

architecture sim of tb_axi_regs is

    constant ID_W : integer := 12;
    constant TCLK : time := 10 ns;      -- 100 MHz, same as FCLK_CLK0

    signal aclk    : std_logic := '0';
    signal aresetn : std_logic := '0';
    signal running : boolean := true;

    -- AXI3 wires (master drives the *_m signals; slave drives *_ready / read data)
    signal awid    : std_logic_vector(ID_W-1 downto 0) := (others => '0');
    signal awaddr  : std_logic_vector(31 downto 0) := (others => '0');
    signal awlen   : std_logic_vector(3 downto 0) := (others => '0');
    signal awsize  : std_logic_vector(2 downto 0) := "010";      -- 4 bytes
    signal awburst : std_logic_vector(1 downto 0) := "01";       -- INCR
    signal awlock  : std_logic_vector(1 downto 0) := "00";
    signal awcache : std_logic_vector(3 downto 0) := "0000";
    signal awprot  : std_logic_vector(2 downto 0) := "000";
    signal awqos   : std_logic_vector(3 downto 0) := "0000";
    signal awvalid : std_logic := '0';
    signal awready : std_logic;
    signal wid     : std_logic_vector(ID_W-1 downto 0) := (others => '0');
    signal wdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal wstrb   : std_logic_vector(3 downto 0) := "1111";
    signal wlast   : std_logic := '0';
    signal wvalid  : std_logic := '0';
    signal wready  : std_logic;
    signal bid     : std_logic_vector(ID_W-1 downto 0);
    signal bresp   : std_logic_vector(1 downto 0);
    signal bvalid  : std_logic;
    signal bready  : std_logic := '0';
    signal arid    : std_logic_vector(ID_W-1 downto 0) := (others => '0');
    signal araddr  : std_logic_vector(31 downto 0) := (others => '0');
    signal arlen   : std_logic_vector(3 downto 0) := (others => '0');
    signal arsize  : std_logic_vector(2 downto 0) := "010";
    signal arburst : std_logic_vector(1 downto 0) := "01";
    signal arlock  : std_logic_vector(1 downto 0) := "00";
    signal arcache : std_logic_vector(3 downto 0) := "0000";
    signal arprot  : std_logic_vector(2 downto 0) := "000";
    signal arqos   : std_logic_vector(3 downto 0) := "0000";
    signal arvalid : std_logic := '0';
    signal arready : std_logic;
    signal rid     : std_logic_vector(ID_W-1 downto 0);
    signal rdata   : std_logic_vector(31 downto 0);
    signal rresp   : std_logic_vector(1 downto 0);
    signal rlast   : std_logic;
    signal rvalid  : std_logic;
    signal rready  : std_logic := '0';

    signal reg_ps2pl : std_logic_vector(127 downto 0);
    signal pl_active : std_logic;

    type slv32_array is array (natural range <>) of std_logic_vector(31 downto 0);

begin

    clk_gen : process
    begin
        while running loop
            aclk <= '0'; wait for TCLK/2;
            aclk <= '1'; wait for TCLK/2;
        end loop;
        wait;
    end process;

    dut : entity work.axi_regs
        generic map (C_DATA_WIDTH => 32, C_ADDR_WIDTH => 32, C_ID_WIDTH => ID_W)
        port map (
            reg_ps2pl_o => reg_ps2pl, pl_active_o => pl_active,
            s_axi_aclk => aclk, s_axi_aresetn => aresetn,
            s_axi_awid => awid, s_axi_awaddr => awaddr, s_axi_awlen => awlen,
            s_axi_awsize => awsize, s_axi_awburst => awburst, s_axi_awlock => awlock,
            s_axi_awcache => awcache, s_axi_awprot => awprot, s_axi_awqos => awqos,
            s_axi_awvalid => awvalid, s_axi_awready => awready,
            s_axi_wid => wid, s_axi_wdata => wdata, s_axi_wstrb => wstrb,
            s_axi_wlast => wlast, s_axi_wvalid => wvalid, s_axi_wready => wready,
            s_axi_bid => bid, s_axi_bresp => bresp, s_axi_bvalid => bvalid, s_axi_bready => bready,
            s_axi_arid => arid, s_axi_araddr => araddr, s_axi_arlen => arlen,
            s_axi_arsize => arsize, s_axi_arburst => arburst, s_axi_arlock => arlock,
            s_axi_arcache => arcache, s_axi_arprot => arprot, s_axi_arqos => arqos,
            s_axi_arvalid => arvalid, s_axi_arready => arready,
            s_axi_rid => rid, s_axi_rdata => rdata, s_axi_rresp => rresp,
            s_axi_rlast => rlast, s_axi_rvalid => rvalid, s_axi_rready => rready);

    main : process

        procedure tick(n : positive := 1) is
        begin
            for i in 1 to n loop wait until rising_edge(aclk); end loop;
        end procedure;

        -- ---- AXI3 master BFM ------------------------------------------------
        procedure axi_write_burst(constant addr  : natural;
                                  constant data  : slv32_array;
                                  constant id    : natural := 0;
                                  constant burst : std_logic_vector(1 downto 0) := "01") is
        begin
            -- address phase
            awid    <= std_logic_vector(to_unsigned(id, ID_W));
            awaddr  <= std_logic_vector(to_unsigned(addr, 32));
            awlen   <= std_logic_vector(to_unsigned(data'length - 1, 4));
            awburst <= burst;
            awvalid <= '1';
            loop wait until rising_edge(aclk); exit when awready = '1'; end loop;
            awvalid <= '0';
            -- data phase
            wid <= std_logic_vector(to_unsigned(id, ID_W));
            for i in data'range loop
                wdata  <= data(i);
                wstrb  <= "1111";
                wlast  <= '1' when i = data'high else '0';
                wvalid <= '1';
                loop wait until rising_edge(aclk); exit when wready = '1'; end loop;
            end loop;
            wvalid <= '0';
            wlast  <= '0';
            -- write response
            bready <= '1';
            loop wait until rising_edge(aclk); exit when bvalid = '1'; end loop;
            check_equal(bresp, std_logic_vector'("00"), "BRESP OKAY");
            check_equal(bid, std_logic_vector(to_unsigned(id, ID_W)), "BID reflects AWID");
            bready <= '0';
        end procedure;

        procedure axi_write(constant addr : natural; constant d : std_logic_vector(31 downto 0);
                            constant id : natural := 0) is
            variable a : slv32_array(0 to 0);
        begin
            a(0) := d;
            axi_write_burst(addr, a, id);
        end procedure;

        procedure axi_read_burst(constant addr  : natural;
                                 constant len   : positive;
                                 variable data  : out slv32_array;
                                 constant id    : natural := 0;
                                 constant burst : std_logic_vector(1 downto 0) := "01") is
        begin
            arid    <= std_logic_vector(to_unsigned(id, ID_W));
            araddr  <= std_logic_vector(to_unsigned(addr, 32));
            arlen   <= std_logic_vector(to_unsigned(len - 1, 4));
            arburst <= burst;
            arvalid <= '1';
            loop wait until rising_edge(aclk); exit when arready = '1'; end loop;
            arvalid <= '0';
            rready <= '1';
            for i in 0 to len - 1 loop
                loop wait until rising_edge(aclk); exit when rvalid = '1'; end loop;
                data(i) := rdata;
                check_equal(rresp, std_logic_vector'("00"), "RRESP OKAY");
                check_equal(rid, std_logic_vector(to_unsigned(id, ID_W)), "RID reflects ARID");
                if i = len - 1 then
                    check_equal(rlast, '1', "RLAST on last beat");
                else
                    check_equal(rlast, '0', "RLAST low mid-burst");
                end if;
            end loop;
            rready <= '0';
        end procedure;

        procedure axi_read(constant addr : natural; variable d : out std_logic_vector(31 downto 0);
                           constant id : natural := 0) is
            variable a : slv32_array(0 to 0);
        begin
            axi_read_burst(addr, 1, a, id);
            d := a(0);
        end procedure;

        procedure do_reset is
        begin
            aresetn <= '0';
            awvalid <= '0'; wvalid <= '0'; bready <= '0'; arvalid <= '0'; rready <= '0';
            tick(5);
            aresetn <= '1';
            tick(2);
        end procedure;

        variable r  : std_logic_vector(31 downto 0);
        variable r2 : std_logic_vector(31 downto 0);
        variable v4 : slv32_array(0 to 3);
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop
            do_reset;

            if run("signature") then
                axi_read(16#1C#, r);
                check_equal(r, std_logic_vector'(x"5A5A1234"), "SIGNATURE");

            elsif run("single_write_read") then
                axi_write(16#00#, x"CAFEF00D");
                axi_write(16#04#, x"0000ABCD");
                axi_read(16#00#, r);  check_equal(r, std_logic_vector'(x"CAFEF00D"), "SCRATCH0");
                axi_read(16#04#, r);  check_equal(r, std_logic_vector'(x"0000ABCD"), "SCRATCH1");
                check_equal(reg_ps2pl(31 downto 0), std_logic_vector'(x"CAFEF00D"), "reg_ps2pl(0)");

            elsif run("id_reflection") then
                axi_write(16#08#, x"11112222", id => 16#5#);   -- BID checked in BFM
                axi_read(16#08#, r, id => 16#A#);              -- RID checked in BFM
                check_equal(r, std_logic_vector'(x"11112222"), "SCRATCH2 via id=A");

            elsif run("incr_burst_write_then_read") then
                v4 := (x"00000001", x"00000002", x"00000003", x"00000004");
                axi_write_burst(16#00#, v4, id => 16#3#);       -- writes 0x00,0x04,0x08,0x0C
                axi_read_burst(16#00#, 4, v4, id => 16#7#);
                check_equal(v4(0), std_logic_vector'(x"00000001"), "burst rd SCRATCH0");
                check_equal(v4(1), std_logic_vector'(x"00000002"), "burst rd SCRATCH1");
                check_equal(v4(2), std_logic_vector'(x"00000003"), "burst rd SCRATCH2");
                check_equal(v4(3), std_logic_vector'(x"00000004"), "burst rd CONTROL");

            elsif run("fixed_burst_write") then
                -- FIXED burst: 3 beats all to SCRATCH0, last one wins
                axi_write_burst(16#00#, (x"AAAAAAAA", x"BBBBBBBB", x"12345678"),
                                id => 0, burst => "00");
                axi_read(16#00#, r);
                check_equal(r, std_logic_vector'(x"12345678"), "FIXED burst last beat wins");

            elsif run("pl_computes_sum") then
                axi_write(16#00#, x"12340000");
                axi_write(16#04#, x"0000ABCD");
                axi_read(16#14#, r);
                check_equal(r, std_logic_vector'(x"1234ABCD"), "SUM computed in PL");

            elsif run("status_word") then
                axi_write(16#00#, x"00000001");   -- or  -> 1
                axi_write(16#04#, x"FFFFFFFF");   -- and -> 1
                axi_write(16#08#, x"0000000F");   -- popcount -> 4
                tick(2);
                axi_read(16#18#, r);
                check_equal(r(0), '1', "STATUS or(SCRATCH0)");
                check_equal(r(1), '1', "STATUS and(SCRATCH1)");
                check_equal(r(2), '0', "STATUS equal");
                check_equal(unsigned(r(15 downto 8)), to_unsigned(4, 8), "STATUS popcount");

            elsif run("control_and_heartbeat") then
                axi_write(16#0C#, x"00000001");
                tick(2);
                check_equal(pl_active, '1', "CONTROL(0) -> pl_active");
                axi_read(16#10#, r);
                tick(40);
                axi_read(16#10#, r2);
                check(unsigned(r2) > unsigned(r), "HEARTBEAT advances");
                axi_write(16#0C#, x"00000002");   -- bit1 = clear
                tick(3);
                axi_write(16#0C#, x"00000000");
                axi_read(16#10#, r);
                check(unsigned(r) < 40, "HEARTBEAT cleared by CONTROL(1)");
            end if;
        end loop;

        running <= false;
        test_runner_cleanup(runner);
        wait;
    end process;

    test_runner_watchdog(runner, 1 ms);

end architecture sim;
