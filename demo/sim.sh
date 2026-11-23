#!/bin/sh
# Checks the SW[9] switching of demo/demo_top.v in ModelSim (stubs for both designs).
set -e
cd "$(dirname "$0")"
V="${ALTERA:-/c/altera/13.0sp1}/modelsim_ase/win32aloem"
mkdir -p build/sim && cd build/sim
"$V/vlib" work > /dev/null 2>&1 || true
"$V/vlog" -quiet "$(cygpath -m ../../demo_top.v)" "$(cygpath -m ../../tb_demo_top.v)"
"$V/vsim" -c -quiet tb_demo_top -do "run -all; quit -f" > sim.log 2>&1 || true
grep -E "PASS|FAIL" sim.log
grep -q "# PASS" sim.log
