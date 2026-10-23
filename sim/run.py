#!/usr/bin/env python3
"""
VUnit run script - simulation model of the PS <-> PL AXI communication.

Compiles the hand-written VHDL AXI slave (src/hdl/axi_regs.vhd) plus its
AXI3-master testbench, the SSD1306 OLED driver (src/hdl/ssd1306_text.vhd)
plus its SPI-panel testbench, the oscilloscope, and the PL Ethernet MAC
(hVHDL_gigabit_ethernet's ethernet_mac, submodule src/hVHDL_gigabit_ethernet)
through the Xilinx RGMII I/O cells, and runs them with NVC. The Xilinx primitives come
from Vivado's unisim VHDL models (VIVADO_DIR, default ~/Xilinx/2024.2/Vivado/2024.2).

    python sim/run.py                 # run all cases
    python sim/run.py -v              # verbose (per-check log)
    python sim/run.py --list          # list cases
    python sim/run.py --gui           # waveform
    python sim/run.py "*burst*"       # subset

Requires:  pip install vunit_hdl   and   nvc on PATH
"""

import os
from pathlib import Path
from vunit import VUnit

ROOT = Path(__file__).parent.parent.resolve()

os.environ.setdefault("VUNIT_SIMULATOR", "nvc")

vu = VUnit.from_argv(compile_builtins=False)
vu.add_vhdl_builtins()
vu.add_verification_components()

# Xilinx unisim models for the RGMII I/O cells. Vivado's VCOMPONENTS package
# (45 000+ lines) is more than NVC analyses with its default memory, and VUnit
# can't pass NVC's global -M option - so build a VCOMPONENTS with just the
# components used here, cut out of Vivado's own file (always matches the models).
VIVADO = Path(os.environ.get("VIVADO_DIR", Path.home() / "Xilinx/2024.2/Vivado/2024.2"))
UNISIM = VIVADO / "data/vhdl/src/unisims"
PRIMITIVES = ("IDDR", "ODDR", "BUFG", "BUFIO", "IOBUF", "IDELAYE2", "IDELAYCTRL",
              "MMCME2_ADV", "MMCME2_BASE")


def small_vcomponents(dst):
    text = (UNISIM / "unisim_VCOMP.vhd").read_text().splitlines()
    pkg = text.index("package VCOMPONENTS is")
    first = next(i for i in range(pkg, len(text)) if text[i].startswith("component "))
    body = text[pkg + 1:first]          # the global signals (GSR, GTS, ...) the models use
    for prim in PRIMITIVES:
        start = text.index(f"component {prim}")
        end = text.index("end component;", start)
        body += text[start:end + 1] + [""]
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text("library ieee;\nuse ieee.std_logic_1164.all;\nuse ieee.numeric_std.all;\n\n"
                   "package vcomponents is\n"
                   + "\n".join(body) + "\nend package vcomponents;\n")
    return dst


unisim = vu.add_library("unisim")
unisim.add_source_files(UNISIM / "unisim_VPKG.vhd")
unisim.add_source_files(small_vcomponents(ROOT / "build" / "sim" / "unisim_vcomponents.vhd"))
for prim in PRIMITIVES:
    unisim.add_source_files(UNISIM / "primitive" / f"{prim}.vhd")

lib = vu.add_library("lib")
# The AXI package + slave + testbench. zynq_mini_top.vhd needs the generated
# block design and is not part of the unit sim.
lib.add_source_files(ROOT / "src" / "hdl" / "axi_pkg.vhd")
lib.add_source_files(ROOT / "src" / "hdl" / "scope_pkg.vhd")
lib.add_source_files(ROOT / "src" / "hdl" / "axi_regs.vhd")
lib.add_source_files(ROOT / "src" / "hdl" / "font8x8_pkg.vhd")
lib.add_source_files(ROOT / "src" / "hdl" / "ssd1306_text.vhd")
lib.add_source_files(ROOT / "src" / "hdl" / "scope_siggen.vhd")
lib.add_source_files(ROOT / "src" / "hdl" / "scope_capture.vhd")
lib.add_source_files(ROOT / "sim" / "tb_axi_regs.vhd")
lib.add_source_files(ROOT / "sim" / "tb_ssd1306_text.vhd")
lib.add_source_files(ROOT / "sim" / "tb_scope_capture.vhd")

# hVHDL_gigabit_ethernet's ethernet_mac (submodule, its tip) in a library of its
# own, as its README asks: the same files as its vunit_run_ethernet_mac.py
ETH = ROOT / "src" / "hVHDL_gigabit_ethernet"
eth = vu.add_library("hvhdl_ethernet")
MEMORY = ETH / "submodules" / "hVHDL_memory_library" / "vhdl2008"
eth.add_source_files(MEMORY / "dp_ram_w_configurable_records.vhd")
eth.add_source_files(MEMORY / "sdp_ram_w_configurable_records.vhd")
eth.add_source_files(ETH / "ethernet_mac" / "*.vhd")

lib.add_source_files(ROOT / "src" / "hdl" / "rgmii_rx_xilinx.vhd")
lib.add_source_files(ROOT / "src" / "hdl" / "rgmii_tx_xilinx.vhd")
lib.add_source_files(ROOT / "src" / "hdl" / "eth_mac.vhd")
lib.add_source_files(ROOT / "sim" / "tb_eth_mac.vhd")
# eth_mac sharing its port with GEM1 (PL_ETH=shared): that test alone, in that build
lib.test_bench("tb_eth_mac").test("shared port: GEM1's frames and a stream at the same time").add_config(
    name="share_port", generics=dict(share_port=True))

vu.set_sim_option("nvc.sim_flags", ["--ieee-warnings=off"])

vu.main()
