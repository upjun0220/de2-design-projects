create_clock -name CLOCK_50 -period 20 [get_ports CLOCK_50]
create_clock -name altera_reserved_tck -period 100 [get_ports altera_reserved_tck]
set_clock_groups -asynchronous -group {altera_reserved_tck}
derive_pll_clocks
derive_clock_uncertainty
# Slow human or 400 kHz signals: not timed.
set_false_path -from [get_ports {KEY[*] SW[*] GPIO_0[*] LCD_DATA[*]}]
set_false_path -to [get_ports {LEDR[*] LEDG[*] HEX*[*] LCD_* GPIO_0[*]}]
