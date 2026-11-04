#!/bin/sh
# GHDL로 src/DE2_Project1.vhd를 시뮬레이션한다.
# 마지막 줄에 "TOTAL checks=... errors=0" 이 나오면 통과.
set -e
cd "$(dirname "$0")"
mkdir -p build
ghdl -a --std=08 --workdir=build ../src/DE2_Project1.vhd tb.vhd
ghdl -e --std=08 --workdir=build tb
ghdl -r --std=08 --workdir=build tb
