create_clock -name clk50 -period 20.000 [get_ports {MAX10_CLK1_50}]

derive_clock_uncertainty

# Async inputs are synchronized in RTL; outputs only drive LEDs.
set_false_path -from [get_ports {KEY[*] SW[*] GPIO_UART_RX}]
set_false_path -to   [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]
