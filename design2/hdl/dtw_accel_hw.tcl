# Qsys component: DTW accelerator. See dtw_accel.v.
package require -exact qsys 13.0

set_module_property NAME dtw_accel
set_module_property DISPLAY_NAME "DTW accelerator"
set_module_property VERSION 1.0
set_module_property GROUP "Magic Pen"
set_module_property EDITABLE true

add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL dtw_accel
add_fileset_file dtw_array.v VERILOG PATH dtw_array.v
add_fileset_file dtw_accel.v VERILOG PATH dtw_accel.v TOP_LEVEL_FILE

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
add_interface_port s0 avs_address address Input 15
add_interface_port s0 avs_read read Input 1
add_interface_port s0 avs_write write Input 1
add_interface_port s0 avs_writedata writedata Input 32
add_interface_port s0 avs_readdata readdata Output 32
