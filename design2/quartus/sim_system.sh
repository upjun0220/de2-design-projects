#!/bin/sh
# Full-system simulation: Nios II running nios/sim/sim_main.c in ModelSim.
# Takes a while (minutes). Last line is "SYSTEM PASS" when everything holds.
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ALTERA="${ALTERA:-/c/altera/13.0sp1}"
Q="$ALTERA/quartus"
V="$ALTERA/modelsim_ase/win32aloem"
CYG="$Q/bin/cygwin/bin"
export CYGWIN=nodosfilewarning
export PYTHONIOENCODING=utf-8

mkdir -p build/simq build/app_sim/ build/bsp_sim
SEARCH="$(cygpath -m "$ROOT/hdl"),\$"
(
  cd build/simq
  cp "$ROOT/quartus/create_sys.tcl" .
  "$Q/sopc_builder/bin/qsys-script" --script=create_sys.tcl --search-path="$SEARCH" > s.log 2>&1
  "$Q/sopc_builder/bin/qsys-generate" magic_pen_sys.qsys --simulation=VERILOG --search-path="$SEARCH" --output-directory=sys > g.log 2>&1
)

# Test data from the Python reference
(cd pc && python gen_sim_vec.py ../build/app_sim/sim_vec.h)

# Firmware. Sim optimise skips the BSS clear and slow start-up waits.
UNIX_ROOT="/cygdrive/$(echo "$ROOT" | sed 's#^/\(.\)/#\1/#')"
UNIX_ALT="/cygdrive/$(echo "$ALTERA" | sed 's#^/\(.\)/#\1/#')"
env SHELLOPTS=igncr "$CYG/bash" -c "
  cd $UNIX_ROOT/build &&
  cp ../nios/position.c ../nios/signature.c ../nios/dtw.c ../nios/decide.c ../nios/display.c ../nios/core.h ../nios/config.h ../nios/mlp_weights.h ../nios/sim/sim_main.c app_sim/ &&
  $UNIX_ALT/nios2eds/nios2_command_shell.sh nios2-bsp hal bsp_sim simq/magic_pen_sys.sopcinfo --cpu-name cpu --set hal.enable_sim_optimize true --set hal.make.bsp_cflags_optimization -O2 &&
  cd app_sim &&
  $UNIX_ALT/nios2eds/nios2_command_shell.sh nios2-app-generate-makefile --bsp-dir ../bsp_sim --elf-name sim.elf --src-dir . --set APP_CFLAGS_OPTIMIZATION -O2 &&
  $UNIX_ALT/nios2eds/nios2_command_shell.sh make &&
  $UNIX_ALT/nios2eds/nios2_command_shell.sh elf2dat --infile=RUN_ON_HDL_SIMULATOR_ONLY_sim.elf --outfile=../simq/magic_pen_sys_sdram_test_component.dat --base=0x800000 --end=0xFFFFFF --width=16 --little-endian-mem
" > build/sim_fw.log 2>&1 || { tail -20 build/sim_fw.log; exit 1; }

cd build/simq
SIMDIR="$(cygpath -m "$(pwd)/sys/simulation")"
H="$(cygpath -m "$ROOT/hdl")"
cat > run.do <<E2
set QSYS_SIMDIR $SIMDIR
source \$QSYS_SIMDIR/mentor/msim_setup.tcl
set TOP_LEVEL_NAME tb_system
file_copy
dev_com
com
vlog -quiet $H/tb/mlx90393_model.v $H/tb/tb_system.v
elab
run -all
quit -f
E2
"$V/vsim" -c -do run.do > sim.log 2>&1 || true
grep -E "report|FAIL|SYSTEM|Error" sim.log | grep -v "Errors: 0" | tail -40
grep -q "SYSTEM PASS" sim.log
