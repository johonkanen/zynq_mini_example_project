#!/usr/bin/env python3
"""
VUnit run script - simulation model of the PS <-> PL AXI communication.

Compiles the hand-written VHDL AXI slave (src/hdl/axi_regs.vhd) plus its
AXI3-master testbench and runs them with NVC.

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

lib = vu.add_library("lib")
# The AXI package + slave + testbench. zynq_mini_top.vhd needs the generated
# block design and is not part of the unit sim.
lib.add_source_files(ROOT / "src" / "hdl" / "axi_pkg.vhd")
lib.add_source_files(ROOT / "src" / "hdl" / "axi_regs.vhd")
lib.add_source_files(ROOT / "sim" / "tb_axi_regs.vhd")

vu.set_sim_option("nvc.sim_flags", ["--ieee-warnings=off"])

vu.main()
