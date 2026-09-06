-------------------------------------------------------------------------------
-- tb_axi_regs.vhd  (VHDL-2008, VUnit)
--
-- Simulation model of the PS <-> PL AXI communication: a small AXI3 master
-- bus-functional model drives axi_regs through the axi_pkg direction records
-- exactly the way the Zynq M_AXI_GP0 port would, and the tests check the
-- register behaviour, ID reflection and burst handling.
--
--   Run:  python sim/run.py            (NVC backend, see sim/run.py)
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

use work.axi_pkg.all;

entity tb_axi_regs is
    generic (runner_cfg : string);
end entity;

architecture sim of tb_axi_regs is

    constant TCLK : time := 10 ns;      -- 100 MHz, same as FCLK_CLK0

    signal aclk    : std_logic := '0';
    signal aresetn : std_logic := '0';
    signal running : boolean := true;

    signal m2s : axi_mosi_t := AXI_MOSI_IDLE;   -- master -> slave (driven here)
    signal s2m : axi_miso_t;                    -- slave  -> master

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
        port map (
            reg_ps2pl_o => reg_ps2pl, pl_active_o => pl_active,
            s_axi_aclk => aclk, s_axi_aresetn => aresetn,
            s_axi_i => m2s, s_axi_o => s2m);

    main : process

        procedure tick(n : positive := 1) is
        begin
            for i in 1 to n loop wait until rising_edge(aclk); end loop;
        end procedure;

        -- ---- AXI3 master BFM ------------------------------------------------
        procedure axi_write_burst(constant addr  : natural;
                                  constant data  : slv32_array;
                                  constant id    : natural := 0;
                                  constant burst : std_logic_vector(1 downto 0) := AXI_BURST_INCR) is
        begin
            -- address phase
            m2s.aw.id    <= std_logic_vector(to_unsigned(id, AXI_ID_WIDTH));
            m2s.aw.addr  <= std_logic_vector(to_unsigned(addr, AXI_ADDR_WIDTH));
            m2s.aw.len   <= std_logic_vector(to_unsigned(data'length - 1, AXI_LEN_WIDTH));
            m2s.aw.size  <= "010";                       -- 4 bytes
            m2s.aw.burst <= burst;
            m2s.aw.valid <= '1';
            loop wait until rising_edge(aclk); exit when s2m.awready = '1'; end loop;
            m2s.aw.valid <= '0';
            -- data phase
            m2s.w.id <= std_logic_vector(to_unsigned(id, AXI_ID_WIDTH));
            for i in data'range loop
                m2s.w.data  <= data(i);
                m2s.w.strb  <= (others => '1');
                m2s.w.last  <= '1' when i = data'high else '0';
                m2s.w.valid <= '1';
                loop wait until rising_edge(aclk); exit when s2m.wready = '1'; end loop;
            end loop;
            m2s.w.valid <= '0';
            m2s.w.last  <= '0';
            -- write response
            m2s.bready <= '1';
            loop wait until rising_edge(aclk); exit when s2m.b.valid = '1'; end loop;
            check_equal(s2m.b.resp, AXI_RESP_OKAY, "BRESP OKAY");
            check_equal(s2m.b.id, std_logic_vector(to_unsigned(id, AXI_ID_WIDTH)), "BID reflects AWID");
            m2s.bready <= '0';
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
                                 constant burst : std_logic_vector(1 downto 0) := AXI_BURST_INCR) is
        begin
            m2s.ar.id    <= std_logic_vector(to_unsigned(id, AXI_ID_WIDTH));
            m2s.ar.addr  <= std_logic_vector(to_unsigned(addr, AXI_ADDR_WIDTH));
            m2s.ar.len   <= std_logic_vector(to_unsigned(len - 1, AXI_LEN_WIDTH));
            m2s.ar.size  <= "010";
            m2s.ar.burst <= burst;
            m2s.ar.valid <= '1';
            loop wait until rising_edge(aclk); exit when s2m.arready = '1'; end loop;
            m2s.ar.valid <= '0';
            m2s.rready <= '1';
            for i in 0 to len - 1 loop
                loop wait until rising_edge(aclk); exit when s2m.r.valid = '1'; end loop;
                data(i) := s2m.r.data;
                check_equal(s2m.r.resp, AXI_RESP_OKAY, "RRESP OKAY");
                check_equal(s2m.r.id, std_logic_vector(to_unsigned(id, AXI_ID_WIDTH)), "RID reflects ARID");
                if i = len - 1 then
                    check_equal(s2m.r.last, '1', "RLAST on last beat");
                else
                    check_equal(s2m.r.last, '0', "RLAST low mid-burst");
                end if;
            end loop;
            m2s.rready <= '0';
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
            m2s <= AXI_MOSI_IDLE;
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
                                id => 0, burst => AXI_BURST_FIXED);
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
