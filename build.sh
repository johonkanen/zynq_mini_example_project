#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  build.sh - Linux/WSL launcher for the arm_fpga_zynq_mini Vivado build
#
#    ./build.sh           full build (block design -> bitstream -> XSA)
#    ./build.sh bd        stop after the block design
#    ./build.sh synth     stop after synthesis
#    ./build.sh impl      stop after implementation
#    ./build.sh gui       create the project and open it in the Vivado GUI
#
#  Set VIVADO_BIN if 'vivado' is not on PATH.
#
#  The build uses every logical CPU by default. To cap it:
#    export VIVADO_BUILD_JOBS=8      # parallel synth/impl/OOC runs
#    export VIVADO_BUILD_THREADS=8   # threads within a run step
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

VIVADO_BIN="${VIVADO_BIN:-vivado}"
STAGE="${1:-all}"

if [[ "$STAGE" == "gui" ]]; then
    exec "$VIVADO_BIN" -mode gui -source scripts/build.tcl -tclargs bd
fi

exec "$VIVADO_BIN" -mode batch -source scripts/build.tcl -tclargs "$STAGE"
