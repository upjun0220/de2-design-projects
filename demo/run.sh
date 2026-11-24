#!/bin/sh
# Presentation: puts the demo image on the board, starts the Design 2 program and opens the
# laptop copy of the screen. Run from Git Bash: sh demo/run.sh   (Ctrl+C ends it)
# Keep this window open during the whole presentation: the Nios II is the free
# OpenCore Plus version and stops when quartus_pgm ends.
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ALTERA="${ALTERA:-/c/altera/13.0sp1}"
SOF=demo/build/output_files/demo_time_limited.sof
[ -f "$SOF" ] || { echo "no $SOF: run sh demo/build.sh first"; exit 1; }
export CYGWIN=nodosfilewarning
# Altera's old cygwin goes last: its tail cannot open /dev/null from Git Bash.
export PATH="$ALTERA/quartus/bin:$ALTERA/nios2eds/bin:$PATH:$ALTERA/quartus/bin/cygwin/bin"

# 1. FPGA. quartus_pgm asks "enter i or q" after programming and must keep waiting there:
#    an open, empty stdin keeps it waiting.
LOG=demo/build/pgm.log
tail -f /dev/null | quartus_pgm -m jtag -o "p;$SOF" > "$LOG" 2>&1 &
PGM=$!
trap 'kill $PGM 2>/dev/null; taskkill //F //IM quartus_pgm.exe > /dev/null 2>&1' EXIT
until grep -q "Configuration succeeded\|Error" "$LOG" 2>/dev/null; do sleep 1; done
grep -q "Configuration succeeded" "$LOG" || { cat "$LOG"; exit 1; }
echo "FPGA programmed"

# 2. Design 2 program (same system ID as design2/build/q, see demo/build.sh)
UNIX_ROOT="/cygdrive/$(echo "$ROOT" | sed 's#^/\(.\)/#\1/#')"
UNIX_ALT="/cygdrive/$(echo "$ALTERA" | sed 's#^/\(.\)/#\1/#')"
env SHELLOPTS=igncr "$ALTERA/quartus/bin/cygwin/bin/bash" -c \
    "cd $UNIX_ROOT/design2/build/app && $UNIX_ALT/nios2eds/nios2_command_shell.sh nios2-download -g magic_pen.elf" \
    2>&1 | grep -v "FAST_CWD\|public mailing list"

# 3. Laptop copy of the Design 2 screen (also fine with a VGA monitor connected)
python -u design2/pc/screen.py
