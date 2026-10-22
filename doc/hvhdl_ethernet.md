# A PL Ethernet MAC from hVHDL_gigabit_ethernet

The library is a submodule at `src/hVHDL_gigabit_ethernet`
([hVHDL/hVHDL_gigabit_ethernet](https://github.com/hVHDL/hVHDL_gigabit_ethernet)), kept at the
**tip of its `main`** (`.gitmodules`: `branch = main`) because it is developed together with this
project: work on it happens in the submodule (on branch `main`), and `git submodule update
--remote --recursive` brings this project up to its newest commit.

The goal is a MAC in the PL itself, next to the PS's GEM1, so FPGA logic can send and receive
Ethernet frames without Linux in the data path: line-rate streaming (oscilloscope captures,
later ADC data), fixed-latency register access, and traffic that keeps flowing while Linux is
busy or rebooting.

**Status:** phases 1 and 2 done (2026-10-22): the MAC echoes frames on the board at 1 Gb/s,
and its registers are reachable from Linux (fpgad `eth`, the web page).

## 1. What the library gives: `ethernet_mac/`

Since `fc5ac0b` the library has `ethernet_mac`, a self-contained gigabit MAC (the older sources
next to it are no longer used here):

- **receive** (`ethernet_mac_rx`): a store-and-forward FIFO (4 KB by default) in the receive clock;
  a frame is kept only if its CRC is good, it is 64–1522 bytes with the FCS, it fitted, receiving
  is on and it is for the own address (with a mask), broadcast, or anything in promiscuous mode.
  Out as an 8-bit AXI stream with `tlast`, FCS stripped, with back-pressure.
- **transmit** (`ethernet_mac_tx`): frames from an 8-bit AXI stream; adds preamble, SFD, padding to
  60 bytes, FCS and the interframe gap. The stream must not pause once a frame has started.
- **registers**: an APB3 slave at the offsets of Efinix's Triple Speed Ethernet MAC
  (`COMMAND_CONFIG`, MAC address and mask, frame/error counters, MDIO), so the Zephyr drivers for it
  work unchanged. Registers reset to RX/TX off.
- **MDIO** (`mdio_driver`); **CDC** helpers (`cdc_pulse`, `cdc_snapshot`).
- **RGMII**: `rgmii_rx` / `rgmii_tx` work on the two DDR halves (`rgmii_ddio_record`: `hi` = rising
  edge, `lo` = falling edge, bit 4 = CTL); the device's DDR primitives stay outside. `rgmii_rx` finds
  the nibble pairing from the SFD itself.
- **1000 Mb/s full duplex only**; no pause frames.
- Its own tests: `vunit_run_ethernet_mac.py`, **23 of 23 pass** here (NVC).
- It needs `hVHDL_memory_library` (a submodule of it) and is compiled into a library of its own
  (`hvhdl_ethernet` here) because some file names clash with the older sources.

## 2. Where it sits on this board

Both RTL8211E PHYs are in use: the PS one is wired to MIO pins (not reachable from the PL), the PL
one carries GEM1 = Linux `eth1` (`doc/linux_build.md` §14). So the PL MAC uses the PL PHY:

| option | how | for | against |
|---|---|---|---|
| **A. own the PL port** | a design without GEM1's converter: the PL PHY's RGMII goes to `ethernet_mac` | simplest; the FPGA gets the full line rate | Linux loses `eth1` (the board stays reachable on `eth0`); fpgad's "eth1 must relink" rule refuses such a design while someone is connected through the PL port - as it should |
| **B. share the PL port** | a switch at the GMII level between GEM1, `ethernet_mac` and the PHY: RX to both (each filters), TX arbitrated at frame boundaries with a frame FIFO for GEM1 (GMII has no back-pressure) | one cable: Linux keeps `eth1` *and* the FPGA has its own address | the most logic |
| C. PS ↔ PL inside the chip | GEM1's GMII straight into `ethernet_mac`, no PHY | Linux talks to FPGA logic with plain sockets | no external port |

**A** for bring-up (phase 1–4), **B** as the end state (phase 5).

## 3. Phase 1: what was built

The board design builds in two variants, selected with `PL_ETH` (`scripts/config.tcl`):

```sh
./build.sh                    # PL_ETH=gem1 (default): GEM1 -> gmii_to_rgmii -> PHY = Linux eth1
PL_ETH=hvhdl ./build.sh       # ethernet_mac owns the PL PHY (echo test, below)
./linux/make-pl-bundle.sh     # picks the matching overlay from output/<project>.pl_eth
```

The **PS configuration is the same in both** (GEM1 and FCLK1 stay enabled), so `ps7_init` and the
boot loader don't change between them: the `hvhdl` block design just leaves out the converter.
`zynq_ps_wrapper.vhd` declares the block design per variant (their ports differ), and
`zynq_mini_top.vhd` connects the PL Ethernet pins either to the converter or to `eth_mac`. The
`hvhdl` overlay (`linux/pl/zynq-mini-pl-hvhdl.dtso`) has no `gem1`.

| file | what |
|---|---|
| `src/hdl/rgmii_rx_xilinx.vhd` | RGMII RX for 7-series: RXC → **BUFIO** for the IDDRs and → BUFG for the logic, each data line through an **IDELAYE2 (FIXED, 16 taps)**, IDDR `SAME_EDGE_PIPELINED` → `rgmii_ddio_record` |
| `src/hdl/rgmii_tx_xilinx.vhd` | RGMII TX: ODDR `SAME_EDGE` per line, TXC forwarded through an ODDR (edge-aligned; the PHY adds the TXC delay) |
| `src/hdl/eth_mac.vhd` | `ethernet_mac` + the I/O + an MMCM (125 MHz MAC clock, 200 MHz IDELAYCTRL reference) + an APB sequencer that sets address, mask and RX/TX enable after reset + MDIO on the pins + the **echo**: frames with EtherType `0x88B5` for its address or broadcast go back to the sender (addresses swapped), through a 2 KB block-RAM frame buffer between the receive (RXC) and transmit (125 MHz) clocks |
| `src/constrs/pl_eth_hvhdl.xdc` | RGMII timing (only in the `hvhdl` build): the converter's model - virtual RX clock with the PHY's delay in the input delays, same-edge capture, forwarded TXC as a generated clock with output delays; the RX and TX clocks asynchronous |
| `sim/tb_eth_mac.vhd` | `eth_mac` against a second `ethernet_mac` (the "PC") behind the same I/O cells, 500 ppm off, through PHY models |

**The RX clocking is copied from Xilinx's converter** after looking into its routed design: with
RXC only through a BUFG (≈5.5 ns insertion delay against ≈1.3 ns on the data) the IDDRs sampled
half a clock late - **hold −3.15 ns**. BUFIO + 16 IDELAY taps is what the converter uses and what
works on this board at 1 Gb/s with 0 FCS errors.

**Simulation** runs the real Xilinx primitives: `sim/run.py` compiles Vivado's unisim models
(IDDR, ODDR, BUFG, BUFIO, IOBUF, IDELAYE2, IDELAYCTRL, MMCM) with a `VCOMPONENTS` trimmed to those
(the full package is more than NVC analyses by default, and VUnit can't pass NVC's `-M`). The
`eth_mac` tests:

| test | |
|---|---|
| frame to our MAC is echoed | addresses swapped, payload unchanged |
| broadcast is echoed | |
| other EtherType is ignored | counted |
| other destination is dropped by the MAC | never reaches the echo |
| corrupted frame is dropped | one bit flipped on the wire |
| two frames back to back are both echoed | the second waits in the MAC's FIFO |
| a full size frame is echoed | 1514 bytes |

All 7 pass, with the project's other tests: **33 of 33**.

**Build** (`PL_ETH=hvhdl`, xc7z020-2): timing met, WNS 0.326 ns, WHS 0.059 ns.

| path | setup slack | hold slack |
|---|---|---|
| 125 MHz MAC clock (internal) | 1.70 ns | 0.12 ns |
| RXC domain (internal) | 2.84 ns | 0.06 ns |
| RGMII RX inputs | 0.33 ns | 0.64 ns |
| RGMII TX outputs | 0.69 ns | 0.91 ns |

The RGMII slacks match the converter's in the default build (RX 0.25 / 0.55 ns) - same clocking,
same constraints. The echo's frame buffer has to be written as a plain simple-dual-port RAM
(registered write port, separate read process): the first version landed in 896 LUTs of
distributed RAM and missed timing by 0.29 ns.

## 4. Phase 2: on the board

**Setup:** the PL port cabled straight to a PC adapter (Windows, scapy + Npcap - raw frames don't
leave WSL2's NAT), the PS port to the LAN, so the board stays reachable while the `hvhdl` design
owns the PL port. fpgad's `eth1` rule (`doc/linux_build.md` §14) now applies only when `eth1` was
the board's only link, so such a design can be installed while `eth0` is up.

**Registers from the PS** (register map **2**, `src/hdl/axi_regs.vhd`):

| offset | |
|---|---|
| `0x30` FEATURES | bit0: the PL Ethernet MAC is in this design |
| `0x4000..0x41FF` | `ethernet_mac`'s APB registers (+ its own offset: `COMMAND_CONFIG` 0x008, MAC address 0x00c/0x010, counters 0x068.., MDIO 0x104..) |
| `0x4200` / `0x4204` | frames echoed / ignored (other EtherType), `eth_mac`'s |

An access to the window is a request/acknowledge handshake into the MAC's 125 MHz clock
(`axi_regs` `ext_*` ↔ `eth_mac` `bus_*`), one at a time for both AXI channels; without the MAC
(`FEATURES` bit0 = 0) it completes at once and reads 0, and a silent device times out after 10 µs
with `0xDEADBEEF` instead of hanging the SoC. `pl_eth_hvhdl.xdc` bounds the crossing to one
clock (datapath only). Software: `fpgactl eth` / fpgad `eth` (counters, settings, the PHY's link
through the MAC's MDIO), `GET /api/eth`, a card on the main page.

**Results** (`PL_ETH=hvhdl`, timing met: WNS 0.326 ns, WHS 0.019 ns):

| test (from Windows on the PL port) | result |
|---|---|
| 7 sizes, 60 .. 1514 bytes | 7/7 echoed, byte-exact, addresses swapped |
| broadcast | echoed |
| other EtherType / other destination | no echo (ignored / dropped by the MAC's filter) |
| burst of 200 × 1514 bytes | 200/200 echoed byte-exact (scapy offers only 50–90 Mbit/s) |
| counters after the test | received +209, transmitted +208, echoed +208, ignored +1, 0 CRC / length / cut-short errors - exactly what was sent |
| PHY through the MAC's MDIO | link up, 1000 Mb/s, full duplex |

Found and fixed on the way: RAUC's post-install handler activated the artifact links even when
the bundle didn't carry that artifact, so an app bundle re-loaded an FPGA design rejected earlier
(`doc/network_update.md` §2.4); and the PL bundle's REGMAP came from the source, not from the
build (`build.tcl` now records it as `output/<project>.regmap`).

Not measured yet: the echo at line rate - it needs a faster frame generator than scapy, and the
echo itself moves one frame at a time through its buffer (about half of line rate for long frames).

## 5. Protocols: what a PC can reach

The PC here runs the tools in **WSL2 behind NAT**: raw Ethernet frames from WSL never reach the
LAN, only routed IP traffic does. So:

- **raw frames, EtherType 0x88B5** (the echo) - from Windows (scapy + Npcap), or from Linux on the
  board itself (`eth0` → switch → PL port);
- **IPv4 + UDP** - needs ARP, an IPv4 header check/generation, UDP, and ICMP echo for `ping`; then
  any program, also in WSL, talks to the FPGA with an ordinary UDP socket. The library has none of
  this yet; it fits naturally as a stream stage between `m_t*` and `s_t*`.

## 6. Phases

| phase | content | done when |
|---|---|---|
| 0 | submodule, library tests run here | **done** |
| 1 | Xilinx DDR I/O + clocks + constraints; simulation through them; the `hvhdl` design variant (option A) with an echo | **done**: 33/33 in simulation, the variant builds (see §3) |
| 2 | on the board: the echo at 1 Gb/s from a peer; the MAC's APB registers bridged to the PS, counters in fpgad / the web page | **done** (§4) |
| 3 | ARP + IPv4 + UDP (+ ICMP echo) as stream stages, FPGA IP/MAC from registers | `ping <fpga ip>` and a UDP echo from WSL |
| 4 | use it: UDP register access and streaming oscilloscope captures at line rate | throughput against Linux's 474–553 Mbit/s on the same port |
| 5 | option B: GMII switch so `eth1` and the FPGA share the PL port | Linux on `eth1` and FPGA UDP traffic at the same time; fpgad's relink rule still holds |

## 7. Notes and open questions

- The Xilinx I/O wrappers (`rgmii_rx_xilinx`, `rgmii_tx_xilinx`) could live in the library next to
  its RGMII code, as the 7-series counterpart of the device primitives it keeps outside.
- Vivado 2024.2 synthesises the memory library's VHDL-2008 records (unconstrained record elements,
  a record-typed generic, `'subtype`) - the receive FIFO maps to one RAMB36.
- The PHY keeps its power-on settings (autonegotiation, RGMII-ID); with the MAC owning MDIO, phase 2
  can restrict advertising to 1000BASE-T, since the MAC is gigabit only.
- Does the FPGA need its own IP on the shared port (B), or is a dedicated port (A) enough?
