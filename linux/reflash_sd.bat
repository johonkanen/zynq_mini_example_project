@echo off
rem ---------------------------------------------------------------------------
rem  reflash_sd.bat - reflash the board's microSD over TFTP, driven via JTAG
rem
rem  Once per build (in WSL):  ./linux/reflash-sd.sh <server-ip> [<board-ip>]
rem  and start a TFTP server serving build_tftp\.
rem
rem  Per card: boot switch = JTAG, insert the card, power on, run this.
rem  Watch the serial console at 115200 8N1.
rem
rem  Set XSCT to your Vitis xsct.bat if it is not on PATH, e.g.
rem    set XSCT=C:\Xilinx\Vitis\2024.2\bin\xsct.bat
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"
if "%XSCT%"=="" set XSCT=xsct
call "%XSCT%" reflash_sd.tcl
endlocal
