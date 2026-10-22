# Plan: a PL Ethernet MAC from hVHDL_gigabit_ethernet

Status: **plan** (2026-10-22). The library is a submodule at
`src/hVHDL_gigabit_ethernet` (upstream `hVHDL/hVHDL_gigabit_ethernet`, `5d6319b`); nothing
in the FPGA design uses it yet.

The goal is a MAC in the PL itself, next to the PS's GEM1, so FPGA logic can send and
receive Ethernet frames without Linux in the data path: line-rate streaming (oscilloscope
captures, later ADC data), fixed-latency register access, and traffic that keeps flowing
while Linux is busy or rebooting.

## 1. What the library gives us

| part | files | state |
|---|---|---|
| RGMII RX → frame RAM | `ethernet_rx/` (+ `ethernet_frame_receiver/` packages, `PCK_CRC_32_D8`, `dpram`) | preamble/SFD detection, writes the frame into a 2 KB dual-port RAM, `frame_is_received` + length + start address, FCS check |
| byte stream → RGMII TX | `ethernet_tx/` (+ `frame_transmitter/`, `fifo/`) | load bytes into a FIFO, `request_ethernet_frame`; adds preamble/SFD and the CRC32 |
| DDR I/O adapters | `ethernet_rx_ddio/`, `ethernet_frame_transmitter/ethernet_tx_ddio/` | **Efinix** (`efinix_rx_ddio`: the I/O cell delivers HI/LO bits) and **Cyclone 10** (`arch_cl10_*`); no Xilinx version |
| MDIO | `mdio_driver/` | clause-22 read/write, three-state pin driver |
| protocol stack | `network_protocol_stack/`, `ethernet_communication*` | older, not in the compile list: a skeleton for walking a frame in RAM; **no ARP, IPv4, ICMP or UDP yet** |

- **1 Gb/s only**: RX and TX run on 125 MHz DDR nibbles; 10/100 (25/2.5 MHz SDR) are not handled.
- **No address filtering**: every frame lands in the frame RAM.
- **Tests**: `vunit_run_ethernet.py` runs here (GHDL, the project's VUnit venv): **15 of 17
  pass**. The two failures are both in `loopback_tb` (TX → RX through the DDIO byte
  format, then the CRC read back from RAM) — upstream's newest commits are "start
  debugging loopback simulation", so this is work in progress, not our setup.

## 2. Where it can sit on this board

Both RTL8211E PHYs are in use: the PS one is wired to the MIO pins (not reachable from the
PL), and the PL one now carries GEM1 = Linux `eth1` (`doc/linux_build.md` §14). So the hVHDL
MAC has to use the PL PHY, and the question is how it coexists with GEM1:

| option | how | for | against |
|---|---|---|---|
| **A. own the PL port** | a design without GEM1: the PL PHY's RGMII goes to the hVHDL MAC only | simplest; full line rate for the FPGA; bring-up | Linux loses `eth1` (the board stays reachable on `eth0`) — fpgad's "eth1 must relink" rule refuses such a design while someone is connected through the PL port, which is the right behaviour |
| **B. share the PL port** | a small switch at the GMII level between GEM1, the hVHDL MAC and the PHY: RX goes to both (the MAC keeps frames for its own MAC address / EtherType / UDP port), TX is arbitrated at frame boundaries with a one-frame FIFO for GEM1 (GMII has no back-pressure) | one cable: Linux keeps `eth1` *and* the FPGA has its own address on it | the most logic; the FIFO, the arbitration and the filters need careful tests |
| C. PS ↔ PL link inside the chip | GEM1's GMII wired straight to the hVHDL MAC, no PHY | Linux can talk to FPGA logic with plain sockets | uses up GEM1 and gives no external port — a curiosity |

**Recommendation:** A for bring-up, B as the end state.

## 3. Integration work

1. **Xilinx DDR I/O.** A `xilinx_rx_ddio` architecture: `IDDR` (`SAME_EDGE_PIPELINED`) per
   RXD/RX_CTL, optionally behind `IDELAYE2` (the IDELAYCTRL already exists for the GMII-to-
   RGMII converter), giving the library's `ddio_input(9..0)` format (HI = CTL & D3..0 on the
   rising edge, LO on the falling edge). TX: `ODDR` per TXD/TX_CTL and a forwarded TXC.
   The converter running today proves the timing model: the RTL8211E adds the RGMII delays
   itself (RGMII-ID), so TXC can be edge-aligned and RX sampled as the converter's
   constraints assume (`-1.5/-2.8 ns`). Reuse those constraints, including the receive clock
   on `eth_rgmii_rxc` (see `zynq_mini.xdc`).
2. **Clocks.** RX in the RXC domain (BUFG, as the converter does); TX at 125 MHz from an
   MMCM off FCLK1 (200 MHz) or the converter's own 125 MHz; frame RAM / FIFO as the
   crossing into the 100 MHz `axi_regs` domain.
3. **MDIO.** In option A the hVHDL MDIO driver owns the PHY (reset, force/advertise 1 Gb/s
   only, read link state). In option B Linux keeps the MDIO bus (phylib/autoneg on `eth1`)
   and the PL only reads link/speed — two masters on one MDIO bus are not an option.
4. **Simulation.** Add the library to `sim/` (VUnit, as the scope modules are), with a
   behavioural model of the Xilinx DDIO, so `loopback_tb` runs through *our* I/O path;
   look at the two failing loopback tests together with upstream.
5. **Software view.** Counters and status in `axi_regs` (frames in/out, FCS errors, link),
   readable through fpgad / `fpgactl` / the web page — the register map version goes up.

## 4. Protocols: what a PC can actually reach

The PC here runs the tools in **WSL2 behind NAT**: raw Ethernet frames from WSL never reach
the LAN, only routed IP traffic does. The library's own tests send raw frames with scapy
from Windows. Two ways:

- **raw frames, custom EtherType** — the smallest FPGA side; the PC needs a raw socket on
  Windows (scapy + Npcap), or Linux on the board as the peer (`eth0` → switch → PL port).
- **IPv4 + UDP** — needs ARP (answer "who has <FPGA IP>"), IPv4 header check/generation
  and UDP; ICMP echo is a nice extra for `ping`. Then any program, including one in WSL,
  talks to the FPGA with an ordinary UDP socket.

**Recommendation:** do raw frames first (echo test from the board itself), then a minimal
ARP + IPv4 + UDP responder in VHDL — that is the part the library lacks, and it fits its
"process the frame in RAM" structure (`network_protocol_stack/`).

## 5. Phases

| phase | content | done when |
|---|---|---|
| 0 | submodule, library tests run here | **done**: 15/17 pass, the 2 failures are upstream WIP |
| 1 | Xilinx DDIO + clocks + constraints; VUnit loopback through it; a PL design variant with option A | sim passes; design meets timing |
| 2 | HW echo: the MAC receives a frame and sends it back with swapped addresses; counters in `axi_regs`; PC/board peer via `eth0` → switch → PL port | frames echo at 1 Gb/s, no FCS errors; counters visible in the web page |
| 3 | ARP + IPv4 + UDP (+ ICMP echo) in VHDL, FPGA IP/MAC from registers | `ping <fpga ip>` and a UDP echo from WSL work |
| 4 | use it: UDP register access (axi_regs or the hVHDL `fpga_interconnect` bus) and streaming scope captures at line rate | throughput measured against Linux's 474–553 Mbit/s on the same port |
| 5 | option B: GMII switch so `eth1` and the FPGA share the PL port | Linux on `eth1` and FPGA UDP traffic at the same time; fpgad's relink rule still holds |

## 6. Open questions

- How far is upstream with the loopback/CRC work, and should fixes go upstream first?
- Frame RAM is 2 KB (one frame): enough for an echo; streaming wants double buffering.
- Does the FPGA need its own IP (option B), or is a dedicated port (option A) enough for
  the intended use?
- Gigabit only: is a 100 Mb/s link ever expected on the PL port?
