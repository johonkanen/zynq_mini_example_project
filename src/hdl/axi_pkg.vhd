-------------------------------------------------------------------------------
-- axi_pkg.vhd  (VHDL-2008)
--
-- Record types for the Zynq PS7 M_AXI_GP0 bus (AXI3, 32-bit data / 32-bit
-- address / 12-bit IDs), split by direction:
--
--   axi_mosi_t  - master output / slave input   (everything the PS drives)
--   axi_miso_t  - master input  / slave output  (everything the PL drives)
--
-- The five AXI channels are nested sub-records (aw, w, b, ar, r). A slave port
-- is then just:   s_axi_i : in axi_mosi_t;  s_axi_o : out axi_miso_t;
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

package axi_pkg is

    -- Bus geometry (Zynq-7000 general-purpose AXI3 master port)
    constant AXI_ADDR_WIDTH : natural := 32;
    constant AXI_DATA_WIDTH : natural := 32;
    constant AXI_STRB_WIDTH : natural := AXI_DATA_WIDTH / 8;
    constant AXI_ID_WIDTH   : natural := 12;
    constant AXI_LEN_WIDTH  : natural := 4;   -- AXI3 (AXI4 would be 8)
    constant AXI_LOCK_WIDTH : natural := 2;   -- AXI3 (AXI4 would be 1)

    -- AxBURST encodings
    constant AXI_BURST_FIXED : std_logic_vector(1 downto 0) := "00";
    constant AXI_BURST_INCR  : std_logic_vector(1 downto 0) := "01";
    constant AXI_BURST_WRAP  : std_logic_vector(1 downto 0) := "10";

    -- xRESP encodings
    constant AXI_RESP_OKAY   : std_logic_vector(1 downto 0) := "00";
    constant AXI_RESP_EXOKAY : std_logic_vector(1 downto 0) := "01";
    constant AXI_RESP_SLVERR : std_logic_vector(1 downto 0) := "10";
    constant AXI_RESP_DECERR : std_logic_vector(1 downto 0) := "11";

    subtype axi_addr_t is std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
    subtype axi_data_t is std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
    subtype axi_strb_t is std_logic_vector(AXI_STRB_WIDTH-1 downto 0);
    subtype axi_id_t   is std_logic_vector(AXI_ID_WIDTH-1 downto 0);

    ---------------------------------------------------------------------------
    -- Address channel (write and read use the same shape)
    ---------------------------------------------------------------------------
    type axi_ax_t is record
        id    : axi_id_t;
        addr  : axi_addr_t;
        len   : std_logic_vector(AXI_LEN_WIDTH-1 downto 0);
        size  : std_logic_vector(2 downto 0);
        burst : std_logic_vector(1 downto 0);
        lock  : std_logic_vector(AXI_LOCK_WIDTH-1 downto 0);
        cache : std_logic_vector(3 downto 0);
        prot  : std_logic_vector(2 downto 0);
        qos   : std_logic_vector(3 downto 0);
        valid : std_logic;
    end record;

    -- Write data channel
    type axi_w_t is record
        id    : axi_id_t;               -- AXI3 WID
        data  : axi_data_t;
        strb  : axi_strb_t;
        last  : std_logic;
        valid : std_logic;
    end record;

    -- Write response channel
    type axi_b_t is record
        id    : axi_id_t;
        resp  : std_logic_vector(1 downto 0);
        valid : std_logic;
    end record;

    -- Read data channel
    type axi_r_t is record
        id    : axi_id_t;
        data  : axi_data_t;
        resp  : std_logic_vector(1 downto 0);
        last  : std_logic;
        valid : std_logic;
    end record;

    ---------------------------------------------------------------------------
    -- Direction bundles
    ---------------------------------------------------------------------------
    -- master output -> slave input
    type axi_mosi_t is record
        aw     : axi_ax_t;     -- write address
        w      : axi_w_t;      -- write data
        bready : std_logic;    -- write response ready
        ar     : axi_ax_t;     -- read address
        rready : std_logic;    -- read data ready
    end record;

    -- slave output -> master input
    type axi_miso_t is record
        awready : std_logic;
        wready  : std_logic;
        b       : axi_b_t;
        arready : std_logic;
        r       : axi_r_t;
    end record;

    ---------------------------------------------------------------------------
    -- Idle / reset defaults
    ---------------------------------------------------------------------------
    constant AXI_AX_IDLE : axi_ax_t := (
        id => (others => '0'), addr => (others => '0'), len => (others => '0'),
        size => (others => '0'), burst => AXI_BURST_INCR, lock => (others => '0'),
        cache => (others => '0'), prot => (others => '0'), qos => (others => '0'),
        valid => '0');

    constant AXI_W_IDLE : axi_w_t := (
        id => (others => '0'), data => (others => '0'), strb => (others => '0'),
        last => '0', valid => '0');

    constant AXI_B_IDLE : axi_b_t := (
        id => (others => '0'), resp => AXI_RESP_OKAY, valid => '0');

    constant AXI_R_IDLE : axi_r_t := (
        id => (others => '0'), data => (others => '0'), resp => AXI_RESP_OKAY,
        last => '0', valid => '0');

    constant AXI_MOSI_IDLE : axi_mosi_t := (
        aw => AXI_AX_IDLE, w => AXI_W_IDLE, bready => '0',
        ar => AXI_AX_IDLE, rready => '0');

    constant AXI_MISO_IDLE : axi_miso_t := (
        awready => '0', wready => '0', b => AXI_B_IDLE,
        arready => '0', r => AXI_R_IDLE);

end package axi_pkg;
