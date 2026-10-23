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

**Status:** phases 1–5 done (2026-10-23): the FPGA has its own IP address on the PL port and a UDP
application - register access, the oscilloscope's capture, a stream at line rate (956 Mbit/s) -
with no Linux in the path; the protocol logic is in the library (`network_responder`,
`udp_sender`, `frame_mux`). Phase 5 (2026-10-23): one PL port shared by Linux's eth1 and the FPGA,
both at once at the full line between them - §5c.

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

## 5. Phase 3: ARP, ping and UDP

The PC here runs the tools in **WSL2 behind NAT**: raw Ethernet frames from WSL never reach the
LAN, only routed IP traffic does - so the FPGA needs ARP and IPv4 to be reachable from ordinary
programs. `eth_mac.vhd`'s echo became a small **responder**:

| request | reply |
|---|---|
| ARP request for our IP (broadcast) | ARP reply: opcode 2, sender = our MAC / IP, target = the requester |
| ICMP echo request to our MAC + IP | echo reply: IPs swapped, type 0, ICMP checksum updated (RFC 1624: HC' = ~(~HC + ~m + m')) |
| UDP to our MAC + IP and echo port | the datagram back: IPs and ports swapped |
| EtherType 0x88B5 | the raw echo of phase 1 |

IPv4 is accepted with version 4 and no options, not fragmented, a good header checksum (summed on
the fly), for our MAC and IP; everything else is ignored (counted). The receive side writes the frame
into the buffer as it is and picks the header fields up by byte position on the way; the decision
falls at the last byte. Each reply is its request with a few fields substituted while it streams
out of the buffer - and swapping two fields of a ones' complement sum doesn't change it, so the IP
header checksum and the UDP checksum of the request stay valid without being recomputed.

Registers (ETH window): `0x4208` our IPv4 address (RW, 192.168.20.10 after reset), `0x420C` the UDP
echo port (RW, 7), `0x4210` / `0x4214` / `0x4218` ARP / ICMP / UDP replies. The IP and port reach
the receive clock through the library's `cdc_snapshot`. `fpgactl eth` and the web card show them;
`fpgactl write 0x4208 0xC0A8140A` sets the IP.

**Simulation:** 8 more `tb_eth_mac` cases - ARP for our / another IP, ping (the testbench recomputes
the reply's IP and ICMP checksums), UDP to the echo port / another port, a bad IP header checksum,
a new IP through the bus, the counters: 15 MAC cases, **44 of 44** in all.

**On the board** (PC on the PL port, its adapter at 192.168.20.25; timing met, WNS 0.326 ns,
WHS 0.064 ns):

| test | result |
|---|---|
| `ping 192.168.20.10` from WSL / from Windows | 5/5 / 4/4; under 1 ms from Windows |
| `ping -s 1472 -M do` (1500-byte IP, no fragmenting) | 3/3, 0.54 ms |
| 200 pings, 5 ms apart | 200/200, 0.34 ms average |
| ARP | Windows resolved 192.168.20.10 to 02-5a-4d-00-00-10 |
| UDP echo from WSL (Python socket, port 7) | 30/30 datagrams of 1..1472 bytes back byte-exact, round trip median 0.36 ms |
| UDP to another port | no reply |
| counters | ARP / ICMP / UDP replies = what was sent, 0 errors |

The protocol logic has since moved into the library as `ethernet_mac/network_responder.vhd` (with
its own testbench there); `eth_mac.vhd` keeps the board's part - I/O, clocks, registers.

## 5b. Phase 4: a UDP application

**In the library** (`ethernet_mac/`, VUnit tests there - 38 of 38):

| entity | |
|---|---|
| `network_responder` | + a **user port**: datagrams to `udp_user_port` are handed over (payload on `user_t*`, its sender and length held), so it is a UDP endpoint |
| `udp_sender` | FPGA-originated datagrams: Ethernet + IPv4 (checksum, three clocks while the header goes out) + UDP headers in front of a gapless payload |
| `frame_mux` | two frame streams onto ethernet_mac's transmit stream, a whole frame at a time |

**In the project:** `eth_mac.vhd` runs a command processor on UDP port 5000 (replies to the sender):

| command | request | reply |
|---|---|---|
| `0x01` stream | count(4) size(2) | count datagrams of size bytes, back to back: sequence number + pattern; the time on the wire in clocks (`0x4220`) |
| `0x02` read | addr(2) | `02 00 addr value` - an axi_regs register (0x00..0xFF) |
| `0x03` write | addr(2) value(4) | `03 00 addr value` |
| `0x04` scope | - | the capture: 32 × (offset(2) 4096(2) + 128 samples × ch0..ch3 int16 LE) - or `04 FF ...` without one |

- `axi_regs` has a **second way in** (`udp_*`, a handshake from the MAC clock) beside AXI; the read mux
  and the byte writes are one function / procedure for both.
- `scope_capture` has a **second read port** in its own clock (a copy of the RAM, 8 more RAMB36).
- `tools/pl_udp.py` - `read`, `write`, `stream`, `scope [--arm] [--csv]`: the PC side, standard Python.
- Simulation: `tb_axi_regs` + the PL register access, `tb_eth_mac` + stream, registers and the capture
  over UDP (every sample checked, across the RAM's wrap): **49 of 49**.

**On the board** (timing met, WNS 0.326 ns, WHS 0.035 ns):

| test | result |
|---|---|
| stream 10 000 × 1472 bytes, on the wire (FPGA clocks) | **956 Mbit/s payload** (theory 957), 999 Mbit/s with preamble / FCS / gap |
| the same, received - Windows / WSL through its NAT | 10000/10000, 0 lost, 0 out of order, 0 bad / 10000/10000 at 958 Mbit/s |
| 10 000 × 512 / × 64 bytes on the wire | 884 / 489 Mbit/s payload (998 / 992 with framing); all received |
| registers over UDP | SIGNATURE, REGMAP, FEATURES read; a UDP write is seen by Linux and a Linux write by UDP |
| the scope's capture over UDP | 4 × 4096 samples in **1.0 ms** (1.8 ms with arming), waveforms continuous across the 32 datagrams |
| ping while streaming / alongside | answered (replies have priority in `frame_mux`) |

The FPGA path is about **twice** what Linux reached on the same port (474–553 Mbit/s, CPU-bound) and
doesn't depend on Linux running at all.

## 5c. Phase 5: one port for eth1 and the FPGA

`PL_ETH=shared ./build.sh` - option B: GEM1 (Linux `eth1`) and `ethernet_mac` share the PL PHY at
the GMII level, each with its own MAC address (eth1 `02:5a:4d:00:00:02`, the FPGA
`02:5a:4d:00:00:10`).

**In the library** (`ethernet_mac/`, VUnit 44 of 44):

| change | |
|---|---|
| `gmii_share` (new) | GEM1's GMII transmit into a 4 KB store-and-forward FIFO (a frame kept at its end, dropped whole on TX_ER or if it doesn't fit), played out between `ethernet_mac_tx`'s frames. **The FIFO has priority**: GMII has no back-pressure, the MAC's stream has; as GEM1 sends no faster than the line, the FIFO never holds more than one MAC frame's worth and never drops. (Taking turns frame by frame was tried first: a full-size FPGA stream then throttles small GEM1 frames until the FIFO overflows.) |
| `ethernet_mac_tx` | `hold` (no frame starts while high) and `busy` (frame start to end of the gap) |
| `rgmii_rx` | `line_out`: the received frame as on the line (preamble, SFD, FCS) for the other MAC; with the "rising nibble a clock early" pairing the preamble is 8 bytes |
| `ethernet_mac` | `g_shared_port`, `share_tx_in` / `share_rx_out`; counters 0x180 GEM1 frames sent, 0x184 dropped |

**In the project:**

- block design (`create_bd.tcl`, `shared`): no converter; GEM1's GMII and MDIO are BD ports
  (`GMII1_*`, `MDIO1_*`); `zynq_ps_wrapper` branch `PL_ETH = 2`.
- `eth_mac` (`SHARE_PORT`): GEM1's TX clock = our 125 MHz MMCM clock, its RX clock = the RXC BUFG;
  its TX registered once; MDIO on the pins is GEM1's (Linux phylib). FEATURES bit1 = shared.
- `linux/pl/zynq-mini-pl-shared.dtso`: gem1 without `gmii-to-rgmii`, PHY at 1, and
  `zynq-mini,gigabit-only` → `linux/net/bridge` runs `ethtool -s eth1 advertise 0x020` (the PL MAC is
  gigabit only). `make-pl-bundle.sh` picks the overlay.
- fpgad `eth`: with FEATURES bit1 `"shared":true`, `eth1_frames_sent/dropped`, and the link from
  eth1's sysfs (MDIO isn't the PL MAC's then).
- Simulation 50 of 50: `tb_eth_mac` has a `share_port` config for its test "shared port: GEM1's
  frames and a stream at the same time" (20 × 1000-byte datagrams from the FPGA while a GEM1 model
  sends 20 frames back to back: all 40 reach the PC whole, 0x180 = 20, 0x184 = 0).
- Timing met: WNS 0.316 ns, WHS 0.021 ns; no unconstrained endpoints.

**On the board so far** (2026-10-22): apps bundle with the new fpgad installed; `bridge` copied
onto the board by hand (it is in the rootfs - the next image has it); the shared PL bundle loaded
and kept. eth1 came up in br0 at **1000/Full, advertising 1000BASE-T only**; `fpgactl eth`:
`shared:true`, eth1_frames_sent 48, dropped 0, the FPGA MAC received 17 frames, 0 CRC errors.

**Both at once** (2026-10-23; PC on the PL port, br0 given `192.168.20.1/24` for the test so the PC
reaches Linux through eth1):

| test | result |
|---|---|
| ARP from the PC | 192.168.20.1 → br0's MAC (through eth1), 192.168.20.10 → the FPGA's MAC |
| eth1 alone, iperf3 PC→board / board→PC | 564 / 550 Mbit/s (with the Xilinx converter: 553 / 474) |
| FPGA alone, `pl_udp.py stream 10000 1472` | 954 Mbit/s, 10000/10000 |
| **board→PC iperf3 + FPGA stream 200 000 × 1472 together** | Linux **621 Mbit/s, 0 retransmits**; FPGA **311 Mbit/s, 200000/200000**: the line full (~930 Mbit/s payload); eth1 frames through the FIFO 673 439, **dropped 0**, 0 CRC errors |
| PC→board iperf3 + FPGA stream 100 000 × 1472 + `read`/`write`/`scope --arm` + ping 192.168.20.10 | Linux 572 Mbit/s; FPGA 957 Mbit/s, 100000/100000; registers and capture right; ping 20/20 |

GEM1's priority shows: Linux keeps its rate, the FPGA's stream takes what is left and loses
nothing (its MAC waits, `udp_sender` paces). The PC→board retransmits (26–49 in 10 s) are the
same without FPGA traffic: GEM1's own `rx_overruns` / `rx_resource_errors` (Linux CPU-bound on
receive, as before).

**Limits:**

- the shared port is **gigabit only** (the PL MAC is); eth1 advertises 1000BASE-T alone.
- the bridge never learns the FPGA's MAC (the FPGA's frames don't pass GEM1), so unicast for the
  FPGA that arrives on eth1 is also flooded to eth0 - small (requests, not the stream).
- Linux can't reach the FPGA's IP over eth1 from inside the board: GEM1's frames go only to the
  PHY, not into the PL MAC's receive.

**Not tested yet:** fpgad's relink rule with the cable in the PL port only (needs eth0 unplugged:
the shared design keeps eth1, so it must pass).

## 6. Phases

| phase | content | done when |
|---|---|---|
| 0 | submodule, library tests run here | **done** |
| 1 | Xilinx DDR I/O + clocks + constraints; simulation through them; the `hvhdl` design variant (option A) with an echo | **done**: 33/33 in simulation, the variant builds (see §3) |
| 2 | on the board: the echo at 1 Gb/s from a peer; the MAC's APB registers bridged to the PS, counters in fpgad / the web page | **done** (§4) |
| 3 | ARP + IPv4 + UDP (+ ICMP echo), FPGA IP from a register | **done** (§5) |
| 4 | UDP register access, the oscilloscope's capture over UDP, a stream at line rate | **done** (§5b): 956 Mbit/s against Linux's 474–553 |
| 5 | option B: GMII switch so `eth1` and the FPGA share the PL port | Linux on `eth1` and FPGA UDP traffic at the same time; fpgad's relink rule still holds - **done** (§5c): 621 + 311 Mbit/s together, nothing lost |

## 7. Notes and open questions

- The Xilinx I/O wrappers (`rgmii_rx_xilinx`, `rgmii_tx_xilinx`) could live in the library next to
  its RGMII code, as the 7-series counterpart of the device primitives it keeps outside.
- Vivado 2024.2 synthesises the memory library's VHDL-2008 records (unconstrained record elements,
  a record-typed generic, `'subtype`) - the receive FIFO maps to one RAMB36.
- The PHY keeps its power-on settings (autonegotiation, RGMII-ID); with the MAC owning MDIO, phase 2
  can restrict advertising to 1000BASE-T, since the MAC is gigabit only.
- Does the FPGA need its own IP on the shared port (B), or is a dedicated port (A) enough?
