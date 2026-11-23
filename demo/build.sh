#!/bin/sh
# Builds the presentation image (Design 1 + Design 2, SW[9] picks one) in demo/build.
# Needs Quartus 13.0 SP1 at $ALTERA and the Design 2 build (design2/quartus/build.sh) done
# first: the Qsys system is taken from design2/build/q as it is, so the Nios program
# design2/build/app/magic_pen.elf (same system ID) runs on this image without a rebuild.
# Pins and settings: design2/quartus/magic_pen.qsf with the top level changed.
# Output: demo/build/output_files/demo_time_limited.sof
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ALTERA="${ALTERA:-/c/altera/13.0sp1}"
QIP="$ROOT/design2/build/q/magic_pen_sys/synthesis/magic_pen_sys.qip"
[ -f "$QIP" ] || { echo "run design2/quartus/build.sh first"; exit 1; }
mkdir -p demo/build
cd demo/build
cp "$ROOT/design2/quartus/magic_pen.sdc" demo.sdc
echo 'PROJECT_REVISION = "demo"' > demo.qpf
sed -e 's/TOP_LEVEL_ENTITY de2_top/TOP_LEVEL_ENTITY demo_top/' \
    -e "s#VERILOG_FILE de2_top.v#VERILOG_FILE $(cygpath -m "$ROOT/design2/quartus/de2_top.v")#" \
    -e "s#QIP_FILE .*#QIP_FILE $(cygpath -m "$QIP")#" \
    -e 's/SDC_FILE magic_pen.sdc/SDC_FILE demo.sdc/' \
    "$ROOT/design2/quartus/magic_pen.qsf" > demo.qsf
cat >> demo.qsf <<EOF
set_global_assignment -name VERILOG_FILE $(cygpath -m "$ROOT/demo/demo_top.v")
set_global_assignment -name VHDL_FILE $(cygpath -m "$ROOT/design1/src/DE2_Project1.vhd")
EOF
"$ALTERA/quartus/bin/quartus_sh" --flow compile demo > compile.log 2>&1 || { tail -30 compile.log; exit 1; }
grep -E "Full Compilation was|Total logic elements|Total memory bits" output_files/demo.flow.rpt compile.log || true
grep -E "Worst-case|Slack" output_files/demo.sta.summary | head -8 || true
