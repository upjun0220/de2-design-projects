#!/bin/sh
# Builds the Nios II program: BSP from the Qsys system, then the application.
# Run after quartus/build.sh. Output: build/app/magic_pen.elf
# Program the board: quartus_pgm then nios2-download (see docs/BRINGUP.md).
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ALTERA="${ALTERA:-/c/altera/13.0sp1}"
export CYGWIN=nodosfilewarning
CYG="$ALTERA/quartus/bin/cygwin/bin"
UNIX_ROOT="/cygdrive/$(echo "$ROOT" | sed 's#^/\(.\)/#\1/#')"
UNIX_ALT="/cygdrive/$(echo "$ALTERA" | sed 's#^/\(.\)/#\1/#')"
env SHELLOPTS=igncr "$CYG/bash" -c "
  cd $UNIX_ROOT/build &&
  mkdir -p app bsp &&
  cp ../nios/*.c ../nios/*.h app/ && rm -f app/test_host.c &&
  $UNIX_ALT/nios2eds/nios2_command_shell.sh nios2-bsp hal bsp q/magic_pen_sys.sopcinfo --cpu-name cpu \
      --set hal.make.bsp_cflags_optimization -O2 --set hal.enable_small_c_library false --set hal.sys_clk_timer sys_timer &&
  cd app &&
  $UNIX_ALT/nios2eds/nios2_command_shell.sh nios2-app-generate-makefile --bsp-dir ../bsp --elf-name magic_pen.elf --src-dir . --set APP_CFLAGS_OPTIMIZATION -O2 &&
  $UNIX_ALT/nios2eds/nios2_command_shell.sh make
" 2>&1 | grep -v "FAST_CWD\|public mailing list"
