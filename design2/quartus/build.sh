#!/bin/sh
# Builds the FPGA image from scratch in design2/build/q. Needs Quartus 13.0 SP1 at $ALTERA.
# Output: build/q/output_files/magic_pen*.sof and the reports next to it.
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ALTERA="${ALTERA:-/c/altera/13.0sp1}"
Q="$ALTERA/quartus"
mkdir -p build/q
cd build/q
cp "$ROOT"/quartus/create_sys.tcl "$ROOT"/quartus/de2_top.v "$ROOT"/quartus/magic_pen.qsf "$ROOT"/quartus/magic_pen.qpf "$ROOT"/quartus/magic_pen.sdc .
SEARCH="$(cygpath -m "$ROOT/hdl"),\$"
"$Q/sopc_builder/bin/qsys-script" --script=create_sys.tcl --search-path="$SEARCH" > qsys_script.log 2>&1
"$Q/sopc_builder/bin/qsys-generate" magic_pen_sys.qsys --synthesis=VERILOG --search-path="$SEARCH" --output-directory=magic_pen_sys > qsys_gen.log 2>&1
"$Q/bin/quartus_sh" --flow compile magic_pen > compile.log 2>&1
grep -E "Full Compilation was|Total logic elements|Total memory bits|Embedded Multiplier|Fmax" output_files/magic_pen.flow.rpt compile.log || true
