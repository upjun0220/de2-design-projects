# Qsys component: VGA pen trace display. See vga_trace.v.
package require -exact qsys 13.0

set_module_property NAME vga_trace
set_module_property DISPLAY_NAME "VGA pen trace"
set_module_property VERSION 1.0
set_module_property GROUP "Magic Pen"
set_module_property EDITABLE true

add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL vga_trace
add_fileset_file vga_trace.v VERILOG PATH vga_trace.v TOP_LEVEL_FILE

add_fileset SIM_VERILOG SIM_VERILOG "" ""
set_fileset_property SIM_VERILOG TOP_LEVEL vga_trace
add_fileset_file vga_trace.v VERILOG PATH vga_trace.v

add_interface clock clock end
set_interface_property clock clockRate 0
add_interface_port clock clk clk Input 1

add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset reset reset Input 1

add_interface s0 avalon end
set_interface_property s0 addressUnits WORDS
set_interface_property s0 associatedClock clock
set_interface_property s0 associatedReset reset
set_interface_property s0 readLatency 1
set_interface_property s0 readWaitTime 0
set_interface_property s0 writeWaitTime 0
add_interface_port s0 avs_address address Input 2
add_interface_port s0 avs_read read Input 1
add_interface_port s0 avs_write write Input 1
add_interface_port s0 avs_writedata writedata Input 32
add_interface_port s0 avs_readdata readdata Output 32

add_interface vga conduit end
set_interface_property vga associatedClock clock
add_interface_port vga vga_clk clk Output 1
add_interface_port vga vga_hs hs Output 1
add_interface_port vga vga_vs vs Output 1
add_interface_port vga vga_blank_n blank_n Output 1
add_interface_port vga vga_r r Output 10
add_interface_port vga vga_g g Output 10
add_interface_port vga vga_b b Output 10
