#!/bin/sh
# Runs every check that does not need the board. Run from anywhere: sh design2/run_checks.sh
# Needs: python (numpy, scipy), Quartus 13.0 SP1 at $ALTERA (ModelSim, Cygwin gcc).
# Last line is "ALL CHECKS PASSED" when everything holds.
set -e
cd "$(dirname "$0")"
ROOT="$(pwd)"
export PYTHONIOENCODING=utf-8
ALTERA="${ALTERA:-/c/altera/13.0sp1}"
VSIM_DIR="$ALTERA/modelsim_ase/win32aloem"
CYG="$ALTERA/quartus/bin/cygwin/bin"
win() { cygpath -m "$1"; }
mkdir -p build/ms

echo "--- 1. Python reference models"
python hw/dtw_ref.py
python hw/dtw_ref.py --vectors
(cd pc && python parse_log.py && python position_lm.py --check && python evaluate.py --check && python gate1.py --check && python sim_e2e.py --check)

echo "--- 2. C code on the PC against Python, bit by bit"
(cd pc && python gen_golden.py ../build/golden.txt)
gcc_cyg() { ( PATH="$CYG:$PATH"; cd nios && "$CYG/gcc" -std=gnu99 -O1 -Wall -Wextra "$@" ) > build/gcc.log 2>&1 || { cat build/gcc.log; exit 1; }; grep -E "warning|error" build/gcc.log || true; }
run_cyg() { ( PATH="$CYG:$PATH"; "$@" ) 2>/dev/null; }
gcc_cyg -o ../build/test_host.exe test_host.c position.c signature.c dtw.c decide.c display.c
gcc_cyg -DTEST_MOUNT -o ../build/test_mount.exe test_host.c position.c signature.c dtw.c decide.c display.c
run_cyg ./build/test_host.exe build/golden.txt | tee build/c.log
grep -q "C core OK" build/c.log
run_cyg ./build/test_mount.exe | tee build/c2.log
grep -q "mount OK" build/c2.log

echo "--- 3. Verilog in ModelSim"
cd build/ms
"$VSIM_DIR/vlib" work > /dev/null 2>&1 || true
H="$ROOT/hdl"
"$VSIM_DIR/vlog" -quiet "$(win "$H/i2c_master.v")" "$(win "$H/mlx_reader.v")" "$(win "$H/dtw_array.v")" "$(win "$H/dtw_accel.v")" \
    "$(win "$H/vga_trace.v")" "$(win "$H/tb/mlx90393_model.v")" "$(win "$H/tb/tb_mlx_reader.v")"
"$VSIM_DIR/vlog" -quiet -sv "$(win "$H/tb/tb_dtw_accel.v")" "$(win "$H/tb/tb_vga_trace.v")"
"$VSIM_DIR/vsim" -c -quiet tb_mlx_reader -do "run -all; quit -f" > mlx.log 2>&1 || true
grep -E "PASS|FAIL" mlx.log
grep -q "# PASS" mlx.log
"$VSIM_DIR/vsim" -c -quiet tb_dtw_accel "+VEC=$(win "$ROOT/hw/vectors")" -do "run -all; quit -f" > dtw.log 2>&1 || true
grep -E "PASS|FAIL|clocks" dtw.log
grep -q "# PASS 100/100" dtw.log

"$VSIM_DIR/vsim" -c -quiet tb_vga_trace -do "run -all; quit -f" > vga.log 2>&1 || true
grep -E "PASS|FAIL" vga.log
grep -q "# PASS" vga.log

echo "ALL CHECKS PASSED"
