create_clock -name CLK -period 40.0 [get_ports {CLK}]
create_generated_clock -name iCLK -source [get_ports {CLK}] 
create_generated_clock -name baudrate -source [get_pins {clock|iopll_0|tennm_ph2_iopll|out_clk[0]}] -divide_by 217 
derive_clock_uncertainty

# for enhancing USB BlasterII to be reliable, 25MHz
create_clock -name {altera_reserved_tck} -period 40 {altera_reserved_tck}
set_input_delay -clock altera_reserved_tck -clock_fall 3 [get_ports altera_reserved_tdi]
set_input_delay -clock altera_reserved_tck -clock_fall 3 [get_ports altera_reserved_tms]
set_output_delay -clock altera_reserved_tck -clock_fall 3 [get_ports altera_reserved_tdo]