# Creates the Qsys system. Run through quartus/build.sh (qsys-script).
package require -exact qsys 13.0

create_system magic_pen_sys
set_project_property DEVICE_FAMILY {Cyclone II}
set_project_property DEVICE {EP2C35F672C6}

add_instance clk_0 clock_source
set_instance_parameter_value clk_0 clockFrequency 50000000
set_instance_parameter_value clk_0 clockFrequencyKnown true
set_interface_property clk EXPORT_OF clk_0.clk_in
set_interface_property reset EXPORT_OF clk_0.clk_in_reset

add_instance cpu altera_nios2_qsys
set_instance_parameter_value cpu impl Fast
set_instance_parameter_value cpu icache_size 4096
set_instance_parameter_value cpu dcache_size 2048
set_instance_parameter_value cpu muldiv_multiplierType EmbeddedMulFast
set_instance_parameter_value cpu debug_level Level1
set_instance_parameter_value cpu resetSlave sdram.s1
set_instance_parameter_value cpu resetOffset 0
set_instance_parameter_value cpu exceptionSlave sdram.s1
set_instance_parameter_value cpu exceptionOffset 32

add_instance sdram altera_avalon_new_sdram_controller
foreach {p v} {
    model custom dataWidth 16 rowWidth 12 columnWidth 8 numberOfBanks 4 numberOfChipSelects 1
    casLatency 3 initRefreshCommands 2 powerUpDelay 100 refreshPeriod 15.625 initNOPDelay 0
    TRCD 20 TRFC 70 TRP 20 TWR 14 TAC 5.5 TMRD 3 registerDataIn true pinsSharedViaTriState false
} { set_instance_parameter_value sdram $p $v }
set_interface_property sdram_wire EXPORT_OF sdram.wire

add_instance jtag_uart altera_avalon_jtag_uart
set_instance_parameter_value jtag_uart writeBufferDepth 512
set_instance_parameter_value jtag_uart readBufferDepth 64

add_instance sysid altera_avalon_sysid_qsys
set_instance_parameter_value sysid id 0x4D50454E

add_instance lcd_0 altera_avalon_lcd_16207
set_interface_property lcd EXPORT_OF lcd_0.external

add_instance pio_in altera_avalon_pio
set_instance_parameter_value pio_in width 22
set_instance_parameter_value pio_in direction Input
set_interface_property pio_in EXPORT_OF pio_in.external_connection

add_instance pio_led altera_avalon_pio
set_instance_parameter_value pio_led width 27
set_instance_parameter_value pio_led direction Output
set_interface_property pio_led EXPORT_OF pio_led.external_connection

add_instance pio_hex altera_avalon_pio
set_instance_parameter_value pio_hex width 32
set_instance_parameter_value pio_hex direction Output
set_interface_property pio_hex EXPORT_OF pio_hex.external_connection

add_instance mlx_reader_0 mlx_reader
set_interface_property i2c EXPORT_OF mlx_reader_0.i2c

add_instance dtw_accel_0 dtw_accel

add_connection clk_0.clk cpu.clk
add_connection clk_0.clk_reset cpu.reset_n
add_connection cpu.jtag_debug_module_reset cpu.reset_n
foreach c {sdram jtag_uart sysid lcd_0 pio_in pio_led pio_hex} {
    add_connection clk_0.clk $c.clk
    add_connection clk_0.clk_reset $c.reset
    add_connection cpu.jtag_debug_module_reset $c.reset
}
foreach c {mlx_reader_0 dtw_accel_0} {
    add_connection clk_0.clk $c.clock
    add_connection clk_0.clk_reset $c.reset
    add_connection cpu.jtag_debug_module_reset $c.reset
}

proc data_slave {s base} {
    add_connection cpu.data_master $s
    set_connection_parameter_value cpu.data_master/$s baseAddress $base
}
add_connection cpu.instruction_master sdram.s1
set_connection_parameter_value cpu.instruction_master/sdram.s1 baseAddress 0x00800000
add_connection cpu.instruction_master cpu.jtag_debug_module
set_connection_parameter_value cpu.instruction_master/cpu.jtag_debug_module baseAddress 0x01000000

data_slave sdram.s1 0x00800000
data_slave cpu.jtag_debug_module 0x01000000
data_slave jtag_uart.avalon_jtag_slave 0x01001000
data_slave sysid.control_slave 0x01001010
data_slave lcd_0.control_slave 0x01001020
data_slave pio_in.s1 0x01001030
data_slave pio_led.s1 0x01001040
data_slave pio_hex.s1 0x01001050
data_slave mlx_reader_0.s0 0x01002000
data_slave dtw_accel_0.s0 0x01100000

add_connection cpu.d_irq jtag_uart.irq
set_connection_parameter_value cpu.d_irq/jtag_uart.irq irqNumber 0

save_system magic_pen_sys.qsys
