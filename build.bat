@echo off
rem ---------------------------------------------------------------------------
rem  build.bat - Windows launcher for the arm_fpga_zynq_mini Vivado build
rem
rem    build.bat            full build (block design -> bitstream -> XSA)
rem    build.bat bd         stop after the block design
rem    build.bat synth      stop after synthesis
rem    build.bat impl       stop after implementation
rem    build.bat gui        create the project and open it in the Vivado GUI
rem
rem    python sim\run.py    AXI communication sim (VUnit + NVC), independent of Vivado
rem
rem  Set VIVADO_BIN to your vivado.bat if it is not on PATH, e.g.
rem    set VIVADO_BIN=C:\Xilinx\Vivado\2024.2\bin\vivado.bat
rem
rem  The build uses every logical CPU by default. To cap it:
rem    set VIVADO_BUILD_JOBS=8       (parallel synth/impl/OOC runs)
rem    set VIVADO_BUILD_THREADS=8    (threads within a run step)
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

if "%VIVADO_BIN%"=="" set VIVADO_BIN=vivado

set STAGE=%1
if "%STAGE%"=="" set STAGE=all

if /I "%STAGE%"=="gui" (
    "%VIVADO_BIN%" -mode gui -source scripts/build.tcl -tclargs bd
    goto :eof
)

"%VIVADO_BIN%" -mode batch -source scripts/build.tcl -tclargs %STAGE%
endlocal
