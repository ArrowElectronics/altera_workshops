#**************************************************************
# Time Information
#**************************************************************

set_time_format -unit ns -decimal_places 3



#**************************************************************
# Create Clock
#**************************************************************

create_clock -name {ClkIn} -period 40.000 -waveform { 0.000 20.000 } [get_ports {CLK_25M_C}]

derive_pll_clocks -create_base_clocks
derive_clock_uncertainty

#**************************************************************
# Create Generated Clock
#**************************************************************


#**************************************************************
# Set False Path
#**************************************************************

set_false_path -through [get_pins {niosv_sys|iopll|iopll|tennm_ph2_iopll|reset}]  
set_false_path -from [get_clocks {ClkIn}] -to [get_clocks {niosv_sys|iopll|iopll_outclk0}]
set_false_path -from [get_clocks {niosv_sys|iopll|iopll_outclk0}] -to [get_clocks {ClkIn}]



