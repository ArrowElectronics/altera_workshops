## Generated SDC file "top.out.sdc"

## Copyright (C) 2024  Intel Corporation. All rights reserved.
## Your use of Intel Corporation's design tools, logic functions 
## and other software and tools, and any partner logic 
## functions, and any output files from any of the foregoing 
## (including device programming or simulation files), and any 
## associated documentation or information are expressly subject 
## to the terms and conditions of the Intel Program License 
## Subscription Agreement, the Intel Quartus Prime License Agreement,
## the Intel FPGA IP License Agreement, or other applicable license
## agreement, including, without limitation, that your use is for
## the sole purpose of programming logic devices manufactured by
## Intel and sold by Intel or its authorized distributors.  Please
## refer to the Intel FPGA Software License Subscription Agreements 
## on the Quartus Prime software download page.


## VENDOR  "Intel Corporation"
## PROGRAM "Quartus Prime"
## VERSION "Version 24.2.0 Build 40 06/27/2024 SC Pro Edition"

## DATE    "Sat Aug 10 12:01:22 2024"

##
## DEVICE  "A5ED065BB32AE4SR0"
##


#**************************************************************
# Time Information
#**************************************************************

set_time_format -unit ns -decimal_places 3



#**************************************************************
# Create Clock
#**************************************************************

#create_clock -name {clock1~derived} -period 1.000 -waveform { 0.000 0.500 } [get_ports {clock1}] -add
#create_clock -name {clock0~derived} -period 1.000 -waveform { 0.000 0.500 } [get_ports {clock0}] -add
create_clock -name {clock0} -period 4.000 -waveform { 0.000 2.000 } [get_ports {clock0}] -add
create_clock -name {clk1} -period 4.000 -waveform { 0.200 2.200 } [get_ports {clock1}] -add
set_clock_groups -asynchronous -group [get_clocks {clk1}] -group [get_clocks {clock0}]

#**************************************************************
# Create Generated Clock
#**************************************************************



#**************************************************************
# Set Clock Latency
#**************************************************************



#**************************************************************
# Set Clock Uncertainty
#**************************************************************



#**************************************************************
# Set Input Delay
#**************************************************************



#**************************************************************
# Set Output Delay
#**************************************************************



#**************************************************************
# Set Clock Groups
#**************************************************************



#**************************************************************
# Set False Path
#**************************************************************



#**************************************************************
# Set Multicycle Path
#**************************************************************



#**************************************************************
# Set Maximum Delay
#**************************************************************



#**************************************************************
# Set Minimum Delay
#**************************************************************



#**************************************************************
# Set Input Transition
#**************************************************************

