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
set_false_path -from [get_clocks {mipi_u0_CORE_CLK_0}] -to [get_clocks {mipi_top|clock_system_0|iopll|iopll_outclk0}]
set_false_path -from [get_clocks {mipi_top|clock_system_0|iopll|iopll_outclk0}] -to [get_clocks {mipi_u0_MIPI_FWD_CLK_0_BYTE_0}]

set_false_path -from [get_clocks {mipi_top|clock_system_0|iopll|iopll|tennm_ph2_iopll|ref_clk0}] -to [get_clocks {mipi_top|clock_system_0|iopll|iopll_outclk0}]
set_false_path -from [get_clocks {mipi_top|clock_system_0|iopll|iopll|tennm_ph2_iopll|ref_clk0}] -to [get_clocks {mipi_u0_CORE_CLK_0}]

set_false_path -from [get_clocks {mipi_top|clock_system_0|iopll|iopll_outclk0}] -to [get_clocks {mipi_u0_MIPI_FWD_CLK_0_BYTE_0}]
set_false_path -from [get_clocks {mipi_u0_MIPI_FWD_CLK_0_BYTE_0}] -to [get_clocks {mipi_top|clock_system_0|iopll|iopll_outclk0}]



