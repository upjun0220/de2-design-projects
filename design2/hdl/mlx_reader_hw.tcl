# Qsys component: MLX90393 reader. See mlx_reader.v.
package require -exact qsys 13.0

set_module_property NAME mlx_reader
set_module_property DISPLAY_NAME "MLX90393 reader"
set_module_property VERSION 1.0
set_module_property GROUP "Magic Pen"
set_module_property EDITABLE true

add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL mlx_reader
add_fileset_file i2c_master.v VERILOG PATH i2c_master.v
add_fileset_file mlx_reader.v VERILOG PATH mlx_reader.v TOP_LEVEL_FILE

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
add_interface_port s0 avs_address address Input 5
add_interface_port s0 avs_read read Input 1
add_interface_port s0 avs_write write Input 1
add_interface_port s0 avs_writedata writedata Input 32
add_interface_port s0 avs_readdata readdata Output 32

add_interface i2c conduit end
set_interface_property i2c associatedClock clock
add_interface_port i2c sda_oe sda_oe Output 4
add_interface_port i2c scl_oe scl_oe Output 4
add_interface_port i2c sda_in sda_in Input 4
add_interface_port i2c scl_in scl_in Input 4
