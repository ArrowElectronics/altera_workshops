# (C) 2001-2025 Altera Corporation. All rights reserved.
# Your use of Altera Corporation's design tools, logic functions and other 
# software and tools, and its AMPP partner logic functions, and any output 
# files from any of the foregoing (including device programming or simulation 
# files), and any associated documentation or information are expressly subject 
# to the terms and conditions of the Altera Program License Subscription 
# Agreement, Altera IP License Agreement, or other applicable 
# license agreement, including, without limitation, that your use is for the 
# sole purpose of programming logic devices manufactured by Altera and sold by 
# Altera or its authorized distributors.  Please refer to the applicable 
# agreement for further details.



# -----------------------------------------------------------------------------
# This procedure constrains the max_delay (not skew) between the status bit regs.
#
# The hierarchy path to the status_bits CDC instance is required as an 
# argument.
# -----------------------------------------------------------------------------
proc constrain_data_bits_max_delay { path } {

    #set the to/from paths for stp_status_bits
    set path_from $path|stp_status_bits_in_reg_acq\[*\]
    set path_to $path|stp_status_bits_out_reg_tck\[*\]

    #check if the paths to be constrained exist or not
    set num_status_paths_from [get_collection_size [get_registers -nowarn $path_from]]
    set num_status_paths_to [get_collection_size [get_registers -nowarn $path_to]]

    #if either "to" or "from" paths donot exist, exit the .sdc gracefully
    if {$num_status_paths_from > 0 && $num_status_paths_to > 0} {
        #call to function to get the tck domain name and period
        ## post_message -type warning "DEBUG: my path = $path|stp_status_bits_out_reg_tck*"
        set max_delay_prd [expr [get_clk_info $path|stp_status_bits_out_reg_tck*]]
        ## post_message -type warning "DEBUG: max delay is 1xclk_prd = $max_delay_prd"

        #set the max delay as function of dst clk period
        #max delay is 1xdsk clk period (because valid bit takes ~3 cycles in dst clk to go from src clk domain)
        set_max_delay -from [ get_registers $path_from ] -to [ get_registers $path_to ] $max_delay_prd
        set_max_skew -to [ get_registers $path_from ] $max_delay_prd
    }  

}

# -----------------------------------------------------------------------------
# This procedure is to find out the tck clk name and period
#
# The hierarchy path to the data_bits CDC instance is required as an 
# argument.
# -----------------------------------------------------------------------------
proc get_clk_info { filter } {
    ## post_message -type warning "DEBUG: Search for $filter"
    set target_path [get_registers -nowarn $filter]
    set my_clk [get_fanins $target_path -clock -stop_at_clocks]
    ## post_message -type warning "DEBUG: my_clk = $my_clk"

    if {[get_collection_size $my_clk] == 0} {
        ## post_message -type warning "DEBUG: Clock source of $filter is not found, setting max delay to 5ns"
        post_message -type warning "In-System Source and Probe synchronous transfer clock is provided in '[get_current_instance]', the JTAG clock source cannot be found. In newer device families, please instantiate the configuration IP in your design. JTAG pins are created by that IP."
        set clk_prd 100
        ## post_message -type warning "DEBUG: tck domain period (default): $clk_prd"
    }

    foreach_in_collection clk $my_clk {
        set clk_node_name [get_node_info -name $clk]
        ## post_message -type warning "DEBUG:$clk_node_name \[get_node_info -name $clk\]"
        set clks [get_clocks -nowarn -of_objects [get_registers $filter]]
        ## post_message -type warning "DEBUG: $clks [llength $clks] get_clocks -of_objects \[get_registers $filter\]"
        if {[get_collection_size $clks] == 0} {
            ## post_message -type warning "DEBUG: clk clk period is not defined, setting max delay to 5ns"
            post_message -type warning "In-System Source and Probe synchronous transfer clock is provided in '[get_current_instance]', but its clock period is not defined on '$clk_node_name'. If the clock period is defined in the project, please change the SDC file order such that the clock definition is evaluated before the In-System Source and Probe .sdc/.ip file. As a fallback, the delay is set based on the 5ns clock period (default 200MHz clock)"
            set clk_prd 5
            ## post_message -type warning "DEBUG: tck domain period (default): $clk_prd"
        } else {
            # In the case of multiple clock definitions, arbitrarily use the first clock in the list
            foreach_in_collection clk $clks {
                set clk_prd [get_clock_info $clk -period]
                post_message -type info "In-System Source and Probe synchronous transfer clock is provided in '[get_current_instance]'. The clock period $clk_prd (ns) is defined on '$clk_node_name'. Data delay constraints are set on the CDC data path to/from the source/probe ports accordingly."
                ## post_message -type warning "DEBUG: tck domain period: $clk_prd"  
                break
            }
        }
    }

    return $clk_prd
}


constrain_data_bits_max_delay "[get_current_instance]|issp_impl|altsource_probe_body_inst|*|cdc_gen.probe_cdc_gen.probe_cdc"
constrain_data_bits_max_delay "[get_current_instance]|issp_impl|altsource_probe_body_inst|*|cdc_gen.src_cdc_gen.src_cdc"
