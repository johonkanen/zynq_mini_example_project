@echo off
rem ---------------------------------------------------------------------------
rem  uart_test.bat - build the bare-metal UART1 test and load it over JTAG
rem
rem    uart_test.bat          build (if needed) + load + run on the board
rem    uart_test.bat build    build only
rem    uart_test.bat run      load + run only (assumes already built)
rem
rem  No SD card needed. Open a serial terminal on the board's COM port at
rem  115200 8N1 to watch the output.
rem
rem  Set XSCT to your Vitis xsct.bat if it is not on PATH, e.g.
rem    set XSCT=C:\Xilinx\Vitis\2024.2\bin\xsct.bat
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

if "%XSCT%"=="" set XSCT=xsct

if /I "%1"=="run" goto run
call "%XSCT%" build_uart_test.tcl
if errorlevel 1 exit /b 1
if /I "%1"=="build" goto :eof

:run
call "%XSCT%" run_uart_test.tcl
endlocal
