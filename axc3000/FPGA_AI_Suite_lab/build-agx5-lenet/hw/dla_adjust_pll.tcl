# (c) Copyright (C) 2025  Altera Corporation.
# Altera, the Altera logo, Altera, MegaCore, NIOS II, Quartus and TalkBack words
# and logos are trademarks of Altera Corporation or its subsidiaries in the U.S.
# and/or other countries. Other marks and brands may be claimed as the property
# of others. See Trademarks on altera.com for full list of Altera trademarks or
# See www.Intel.com/legal (if Altera)
# Your use of Altera Corporation's design tools, logic functions and other
# software and tools, and its AMPP partner logic functions, and any output
# files any of the foregoing (including device programming or simulation
# files), and any associated documentation or information are expressly subject
# to the terms and conditions of the Altera Program License Subscription
# Agreement, Altera MegaCore Function License Agreement, or other applicable
# license agreement, including, without limitation, that your use is for the
# sole purpose of programming logic devices manufactured by Altera and sold by
# Altera or its authorized distributors.  Please refer to the applicable
# agreement for further details.
post_message "Running adjust PLLs script"

# Required packages
package require ::quartus::project
package require ::quartus::report
package require ::quartus::flow
package require ::quartus::atoms
package ifneeded ::altera::pll_legality 1.0 {
  switch $tcl_platform(platform) {
    windows {
      load [file join $::quartus(binpath) qcl_pll_legality_tcl.dll] pll_legality
    }
    unix {
      load [file join $::quartus(binpath) libqcl_pll_legality_tcl[info sharedlibextension]] pll_legality
    }
  }
}
package require ::quartus::qcl_pll
package require ::quartus::pll::legality

# Definitions
if {![info exists k_clk_name]} {
    set k_clk_name "*kernel_pll*outclk0"
}
if {![info exists k_clk2x_name]} {
    set k_clk2x_name "*kernel_pll*outclk1"
}

set iteration 1
set setup_timing_violation 1

# When a clock is unused, set its FMAX to this (very high) number so it doesn't impact settings of other clocks
set unused_clk_fmax 10000

# Quartus Environment
set project_name top
set revision_name top
set acds_version 24.3
set fast_compile 0


# Utility functions

# ------------------------------------------------------------------------------------------
proc get_nearest_achievable_frequency { desired_kernel_clk  \
                                        refclk_freq \
                                        device_family \
                                        device_speedgrade \
                                        kernel2x_clk_unused } {
#
# Description :  Returns the closest achievable IOPLL frequency less than or
#                equal to desired_kernel_clk.
#
# Parameters :
#    desired_kernel_clk  - The desired frequency in MHz (floating point)
#    refclk_freq         - The IOPLL's reference clock frequency in MHz (floating point)
#    device_family       - The device family ("Arria 10" or "Stratix 10")
#    device_speedgrade   - The device speedgrade (1, 2 or 3)
#    kernel2x_clk_unused - 0->kernel2x_clk is used, 1->kernel2x_clk is not used
#
# Assumptions :
#    - There are two desired output clocks, the kernel_clk and a kernel_clk_2x
#    - Both clocks have zero phase shift
#    - The desired_kernel_clk frequency is > 10 MHz
#
# -------------------------------------------------------------------------------------------

  if { $kernel2x_clk_unused == 1 } {
    # In case the kernel2x_clk is not used in our design we can simplify and just
    # compute the nearest achievable frequency for the kernel_clk.
    set desired_clk $desired_kernel_clk
  } else {
    # If the kernel2x_clk frequency is achievable from a given VCO frequency,
    # then so must be the kernel_clk (assuming that it is not absurdly low).
    # So, we can simply and compute for an IOPLL with a single clock output of kernel2x_clk.
    set desired_clk [expr $desired_kernel_clk * 2]
  }

  # Use array get to ensure correct input formatting (and avoid curly braces)
  set desired_output(0) [list -type c -index 0 -freq $desired_clk -phase 0.0 -is_degrees false -duty 50.0]
  set desired_counter [array get desired_output]

  # Prepare the arguments for a call to the PLL legality package.
  # The non-obvious parameters here are all effectively don't cares.
  set ref_list [list  -family                       $device_family \
                      -speedgrade                   $device_speedgrade \
                      -refclk_freq                  $refclk_freq \
                      -is_fractional                false \
                      -compensation_mode            direct \
                      -is_counter_cascading_enabled false \
                      -x                            32 \
                      -validated_counter_values     {} \
                      -desired_counter_values       $desired_counter]

  if {[catch {::quartus::pll::legality::retrieve_output_clock_frequency_list $ref_list} result]} {
    post_message "Call to retrieve_output_clock_frequency_list failed because:"
    post_message $result
    return TCL_ERROR
    # ERROR
  }

  # We get a list of six legal frequencies for kernel_clk_2x
  array set result_array $result
  set freq_list $result_array(freq)

  # Pick the closest frequency that's still less than the desired frequency
  # Recover the legal kernel_clk frequencies as we go
  set best_freq 0
  set possible_kernel_freqs {}

  foreach freq_temp $freq_list {
    if { $kernel2x_clk_unused == 1 } {
      # We are looking for the closest possible frequency that
      # is just below the desired kernel clock
      set freq $freq_temp
    } else {
      # We are looking for the closest possible frequency just
      # below the desired kernel clock being half the frequency
      # of the kernel2x clock
      set freq [expr double($freq_temp) / 2]
    }
    lappend possible_kernel_freqs $freq
    if { $freq > $desired_kernel_clk } {
      # The frequency exceeds fmax -- no good.
    } elseif { $freq > $best_freq } {
      set best_freq $freq
    }
  }

  if {$best_freq == 0} {
    post_message "All of the frequencies were too high!"
    return TCL_ERROR
    # ERROR
  } else {
    return $best_freq
    # SUCCESS!
  }

}

# ------------------------------------------------------------------------------------------
proc adjust_iopll_frequency_in_postfit_netlist { design_name \
                                                 pll_name \
                                                 device_family \
                                                 device_speedgrade \
                                                 legalized_kernel_clk \
                         kernel2x_clk_unused \
                                                 {pll_refclk ""} } {
#
# Description :  Configures IOPLL "pll_name" parameter settings to produce a new output frequency
#                of legalized_kernel_clk.  This must be a legal setting for success.
#
# Parameters :
#    design_name          - Design name (i.e. <design_name>.qpf)
#    pll_name             - The full hierarchical name of the target IOPLL in the design
#    device_family    - The device family ("Arria 10" or "Stratix 10")
#    device_speedgrade    - The device speedgrade (1, 2 or 3)
#    legalized_kernel_clk - The new kernel_clk frequency (legalized by get_nearest_achievable_frequency)
#    kernel2x_clk_unused  - 0->kernel2x_clk is used, 1->kernel2x_clk is not used
#
# Assumptions :
#    - The legalized_kernel_clk frequency is, in fact, legal
#    - There are two desired output clocks, the kernel_clk and a kernel_clk_2x
#    - Both clocks have zero phase shift
#    - The PLL is set to low (auto) bandwidth
#
# -------------------------------------------------------------------------------------------
  # Get the IOPLL node
  if {$pll_refclk eq ""} {
    if { [catch {set node [get_atom_node_by_name -name $pll_name]} ] } {
      post_message "IOPLL not found: $pll_name"
      list_plls_in_design
      return TCL_ERROR
      # ERROR
    }

    # Get the refclk frequency from the IOPLL node
    # Using the netlist's refclk frequency gives us a santity check.
    #set refclk_MHz  [get_atom_node_info -key TIME_REFERENCE_CLOCK_FREQUENCY -node $node]
    set refclk_MHz  [get_atom_node_info -key TIME_IOPLL_REFCLK_TIME -node $node]
    regexp {([0-9.]+)} $refclk_MHz refclk
  } else {
    set refclk $pll_refclk
  }
  # Desired output frequencies (kernel_clk and kernel_clk_2x)
  set outclk0 $legalized_kernel_clk
  if { $kernel2x_clk_unused == 1 } {
    # kernel2x_clk is unused, in this case we set the IOPLL output to be
    # the same frequency as the kernel1x_clk
    set outclk1 $outclk0
  } else {
    # kernel2x_clk is used, it is double the frequency of kernel1x_clk
    set outclk1 [expr $outclk0 * 2]
  }

  set desired_output(0) [list -type c -index 0 -freq $outclk0 -phase 0.0 -is_degrees false -duty 50.0]
  set desired_output(1) [list -type c -index 0 -freq $outclk1 -phase 0.0 -is_degrees false -duty 50.0]
  set desired_counters  [array get desired_output]

  # Compute the new IOPLL settings
  set result 0
  post_message "Calling ::quartus::pll::legality::get_physical_parameters_for_generation"
  post_message "device_family = $device_family"
  post_message "device_speedgrade = $device_speedgrade"
  post_message "refclk = $refclk"

  set arg_list [list -prot_mode "BASIC" \
                     -using_adv_mode false \
                     -family $device_family \
                     -speedgrade $device_speedgrade \
                     -compensation_mode direct \
                     -refclk_freq $refclk \
                     -is_fractional false \
                     -x 32 \
                     -m 1 \
                     -n 1 \
                     -k 1 \
                     -bw_preset Low \
                     -is_counter_cascading_enabled false \
                     -validated_counter_settings [array get desired_output] ]

  set error [catch {::quartus::pll::legality::get_physical_parameters_for_generation $arg_list} result]

  if {$error} {
    post_message "Failed to generate new IOPLL settings.  The requested output frequency might have been illegal."
    post_message $result
    return TCL_ERROR
    # ERROR
  }

  # Extract the new IOPLL settings
  array set result_array $result

  # M counter settings
  array set m_array $result_array(m)
  set m_hi_div      $m_array(m_high)
  set m_lo_div      $m_array(m_low)
  set m_bypass      $m_array(m_bypass_en)
  set m_duty_tweak  $m_array(m_tweak)

  # N counter settings
  array set n_array $result_array(n)
  set n_hi_div      $n_array(n_high)
  set n_lo_div      $n_array(n_low)
  set n_bypass      $n_array(n_bypass_en)
  set n_duty_tweak  $n_array(n_tweak)

  # VCO frequency
  set vco_freq      "[round_to_atom_precision $result_array(vco_freq)] MHz"

  # BW & CP current settings
  set mif_pll_bwctrl $result_array(bw)

  ## ADD by pxx
  set mif_pll_bw_mode  "low_bw"

  set mif_pll_bwctrl_old $mif_pll_bwctrl
  switch $mif_pll_bwctrl {
    pll_bw_res_setting0  {set mif_pll_bwctrl 0}
    pll_bw_res_setting1  {set mif_pll_bwctrl 1}
    pll_bw_res_setting2  {set mif_pll_bwctrl 2}
    pll_bw_res_setting3  {set mif_pll_bwctrl 3}
    pll_bw_res_setting4  {set mif_pll_bwctrl 4}
    pll_bw_res_setting5  {set mif_pll_bwctrl 5}
    pll_bw_res_setting6  {set mif_pll_bwctrl 6}
    pll_bw_res_setting7  {set mif_pll_bwctrl 7}
    pll_bw_res_setting8  {set mif_pll_bwctrl 8}
    pll_bw_res_setting9  {set mif_pll_bwctrl 9}
    pll_bw_res_setting10 {set mif_pll_bwctrl 10}
    default {pll_send_message error "Unknown Bandwidth Setting value $mif_pll_bwctrl"}
  }

  if { $device_family == "Stratix 10" || $device_family == "Arria 10"} {
      set mif_pll_cp_current $result_array(cp)
      set mif_pll_cp_current_old $mif_pll_cp_current
      switch $mif_pll_cp_current {
        pll_cp_setting0   {set mif_pll_cp_current 0}
        pll_cp_setting1   {set mif_pll_cp_current 1}
        pll_cp_setting2   {set mif_pll_cp_current 2}
        pll_cp_setting3   {set mif_pll_cp_current 3}
        pll_cp_setting4   {set mif_pll_cp_current 4}
        pll_cp_setting5   {set mif_pll_cp_current 5}
        pll_cp_setting6   {set mif_pll_cp_current 6}
        pll_cp_setting7   {set mif_pll_cp_current 8}
        pll_cp_setting8   {set mif_pll_cp_current 9}
        pll_cp_setting9   {set mif_pll_cp_current 10}
        pll_cp_setting10  {set mif_pll_cp_current 11}
        pll_cp_setting11  {set mif_pll_cp_current 12}
        pll_cp_setting12  {set mif_pll_cp_current 13}
        pll_cp_setting13  {set mif_pll_cp_current 14}
        pll_cp_setting14  {set mif_pll_cp_current 16}
        pll_cp_setting15  {set mif_pll_cp_current 17}
        pll_cp_setting16  {set mif_pll_cp_current 18}
        pll_cp_setting17  {set mif_pll_cp_current 19}
        pll_cp_setting18  {set mif_pll_cp_current 20}
        pll_cp_setting19  {set mif_pll_cp_current 21}
        pll_cp_setting20  {set mif_pll_cp_current 22}
        pll_cp_setting21  {set mif_pll_cp_current 24}
        pll_cp_setting22  {set mif_pll_cp_current 25}
        pll_cp_setting23  {set mif_pll_cp_current 26}
        pll_cp_setting24  {set mif_pll_cp_current 27}
        pll_cp_setting25  {set mif_pll_cp_current 28}
        pll_cp_setting26  {set mif_pll_cp_current 29}
        pll_cp_setting27  {set mif_pll_cp_current 30}
        pll_cp_setting28  {set mif_pll_cp_current 32}
        pll_cp_setting29  {set mif_pll_cp_current 33}
        pll_cp_setting30  {set mif_pll_cp_current 34}
        pll_cp_setting31  {set mif_pll_cp_current 35}
        pll_cp_setting32  {set mif_pll_cp_current 36}
        pll_cp_setting33  {set mif_pll_cp_current 37}
        pll_cp_setting34  {set mif_pll_cp_current 38}
        pll_cp_setting35  {set mif_pll_cp_current 40}
        default {pll_send_message error "Unknown Charge Pump value $mif_pll_cp_current"}
      }
    }

  if { $device_family == "Stratix 10" } {
    set mif_pll_ripplecap $result_array(ripplecap)
    set mif_pll_ripplecap_old $mif_pll_ripplecap
    switch $mif_pll_ripplecap {
      pll_ripplecap_setting0   {set mif_pll_ripplecap 0}
      pll_ripplecap_setting1   {set mif_pll_ripplecap 1}
      pll_ripplecap_setting2   {set mif_pll_ripplecap 2}
      pll_ripplecap_setting3   {set mif_pll_ripplecap 3}
      default {pll_send_message error "Unknown Ripplecap value $mif_pll_ripplecap"}
    }
  }

  # C counter settings
  array set c_array $result_array(c)

  # C0 counter settings
  array set c0_array $c_array(0)
  set outclk_freq0  "[round_to_atom_precision $c0_array(freq)] MHz"
  set c0_hi_div     $c0_array(c_high)
  set c0_lo_div     $c0_array(c_low)
  set c0_bypass     $c0_array(c_bypass_en)
  set c0_duty_tweak $c0_array(c_tweak)

  # C1 counter settings
  array set c1_array $c_array(1)
  set outclk_freq1  "[round_to_atom_precision $c1_array(freq)] MHz"
  set c1_hi_div     $c1_array(c_high)
  set c1_lo_div     $c1_array(c_low)
  set c1_bypass     $c1_array(c_bypass_en)
  set c1_duty_tweak $c1_array(c_tweak)

  # M COUNTER
  set m_value [expr (($m_duty_tweak & 1)<<17)+(($m_bypass & 1)<<16)+(($m_hi_div & 0xFF)<<8)+($m_lo_div & 0xFF)]

  # N COUNTER
  set n_value [expr (($n_duty_tweak & 1)<<17)+(($n_bypass & 1)<<16)+(($n_hi_div & 0xFF)<<8)+($n_lo_div & 0xFF)]

  # C0 COUNTER
  set c0_value [expr (($c0_duty_tweak & 1)<<17)+(($c0_bypass & 1)<<16)+(($c0_hi_div & 0xFF)<<8)+($c0_lo_div & 0xFF)]

  # C1 COUNTER
  set c1_value [expr (($c1_duty_tweak & 1)<<17)+(($c1_bypass & 1)<<16)+(($c1_hi_div & 0xFF)<<8)+($c1_lo_div & 0xFF)]

  # LOOP FILTER SETTING
  set mif_pll_bwctrl_value [expr (($mif_pll_bwctrl & 0xF)<<6)]

  # Write out pll_config.bin file
  set pll_config_file "pll_config.bin"
  set pll_config [open $pll_config_file w]

  set freq_kHz [expr int($legalized_kernel_clk * 1000)]

  if { $device_family == "Arria 10" } {
    puts $pll_config "$freq_kHz $m_value $n_value $c0_value $c1_value $mif_pll_bwctrl_value $mif_pll_cp_current"
  }
  if { $device_family == "Stratix 10"} {
    puts $pll_config "$freq_kHz $m_value $n_value $c0_value $c1_value $mif_pll_bwctrl_value $mif_pll_cp_current $mif_pll_ripplecap"
  }
  if { $device_family == "Agilex" || $device_family == "Agilex 7" || $device_family == "Agilex 5" } { # Modify by pxx
    puts $pll_config "$freq_kHz $m_value $n_value $c0_value $c1_value"
  }

  close $pll_config

    # Apply the new settings:
    global fast_compile
    if {!$fast_compile} {
        # Modify by pxx
        if {$device_family == "Agilex" || $device_family == "Agilex 7" || $device_family == "Agilex 5" } {
            set_atom_node_info -key TIME_IOPLL_OUTCLK1 -node $node $outclk_freq0
            set_atom_node_info -key TIME_IOPLL_OUTCLK2 -node $node $outclk_freq1
            set_atom_node_info -key TIME_IOPLL_VCO -node $node $vco_freq

            set_atom_node_info -key INT_IOPLL_M_COUNTER_HIGH            -node $node    $m_hi_div
            set_atom_node_info -key INT_IOPLL_M_COUNTER_LOW            -node $node    $m_lo_div
            set_atom_node_info -key BOOL_IOPLL_M_COUNTER_BYPASS_EN        -node $node    $m_bypass
            set_atom_node_info -key BOOL_IOPLL_M_COUNTER_EVEN_DUTY_EN     -node $node    $m_duty_tweak

            set_atom_node_info -key INT_IOPLL_N_COUNTER_HIGH            -node $node    $n_hi_div
            set_atom_node_info -key INT_IOPLL_N_COUNTER_LOW            -node $node    $n_lo_div
            set_atom_node_info -key BOOL_IOPLL_N_COUNTER_BYPASS_EN        -node $node    $n_bypass
            set_atom_node_info -key BOOL_IOPLL_N_COUNTER_ODD_DIV_DUTY_EN  -node $node    $n_duty_tweak

            set_atom_node_info -key INT_IOPLL_C1_HIGH          -node $node    $c0_hi_div
            set_atom_node_info -key INT_IOPLL_C1_LOW          -node $node    $c0_lo_div
            set_atom_node_info -key BOOL_IOPLL_C1_BYPASS_EN      -node $node    $c0_bypass
            set_atom_node_info -key BOOL_IOPLL_C1_EVEN_DUTY_EN   -node $node    $c0_duty_tweak

            set_atom_node_info -key INT_IOPLL_C2_HIGH          -node $node    $c1_hi_div
            set_atom_node_info -key INT_IOPLL_C2_LOW          -node $node    $c1_lo_div
            set_atom_node_info -key BOOL_IOPLL_C2_BYPASS_EN      -node $node    $c1_bypass
            set_atom_node_info -key BOOL_IOPLL_C2_EVEN_DUTY_EN   -node $node    $c1_duty_tweak

            set_atom_node_info -key ENUM_IOPLL_BW_MODE             -node $node    $mif_pll_bw_mode

        } else {
            post_message "set_atom_node_info -key TIME_OUTPUT_CLOCK_FREQUENCY_0 -node $node $outclk_freq0"
            set_atom_node_info -key TIME_OUTPUT_CLOCK_FREQUENCY_0     -node $node    $outclk_freq0
            set_atom_node_info -key TIME_OUTPUT_CLOCK_FREQUENCY_1     -node $node    $outclk_freq1
            set_atom_node_info -key TIME_VCO_FREQUENCY                -node $node    $vco_freq

            set_atom_node_info -key INT_IOPLL_M_CNT_HI_DIV            -node $node    $m_hi_div
            set_atom_node_info -key INT_IOPLL_M_CNT_LO_DIV            -node $node    $m_lo_div
            set_atom_node_info -key BOOL_IOPLL_M_CNT_BYPASS_EN        -node $node    $m_bypass
            set_atom_node_info -key BOOL_IOPLL_M_CNT_EVEN_DUTY_EN     -node $node    $m_duty_tweak

            set_atom_node_info -key INT_IOPLL_N_CNT_HI_DIV            -node $node    $n_hi_div
            set_atom_node_info -key INT_IOPLL_N_CNT_LO_DIV            -node $node    $n_lo_div
            set_atom_node_info -key BOOL_IOPLL_N_CNT_BYPASS_EN        -node $node    $n_bypass
            set_atom_node_info -key BOOL_IOPLL_N_CNT_ODD_DIV_DUTY_EN  -node $node    $n_duty_tweak

            set_atom_node_info -key INT_IOPLL_C_CNT_0_HI_DIV          -node $node    $c0_hi_div
            set_atom_node_info -key INT_IOPLL_C_CNT_0_LO_DIV          -node $node    $c0_lo_div
            set_atom_node_info -key BOOL_IOPLL_C_CNT_0_BYPASS_EN      -node $node    $c0_bypass
            set_atom_node_info -key BOOL_IOPLL_C_CNT_0_EVEN_DUTY_EN   -node $node    $c0_duty_tweak

            set_atom_node_info -key INT_IOPLL_C_CNT_1_HI_DIV          -node $node    $c1_hi_div
            set_atom_node_info -key INT_IOPLL_C_CNT_1_LO_DIV          -node $node    $c1_lo_div
            set_atom_node_info -key BOOL_IOPLL_C_CNT_1_BYPASS_EN      -node $node    $c1_bypass
            set_atom_node_info -key BOOL_IOPLL_C_CNT_1_EVEN_DUTY_EN   -node $node    $c1_duty_tweak

            set_atom_node_info -key ENUM_IOPLL_PLL_BWCTRL             -node $node    $mif_pll_bwctrl_old
            set_atom_node_info -key ENUM_IOPLL_PLL_CP_CURRENT         -node $node    $mif_pll_cp_current_old
            }

        if { $device_family == "Stratix 10"} {
            set_atom_node_info -key ENUM_IOPLL_PLL_RIPPLECAP_CTRL     -node $node    $mif_pll_ripplecap_old
        }

    }

  # Success!
  return TCL_OK
}


proc round_to_atom_precision { value } {

  # Round to 6 decimal points
  set n 6
  set rounded_num [format "%.${n}f" $value]
  set double_version [expr {double($rounded_num)} ]

  if {[string length $double_version] <= [string length $rounded_num]} {
    return $double_version
  } else  {
    return $rounded_num
  }
}


proc list_plls_in_design { } {
  post_message "Found the following IOPLLs in design:"
  foreach_in_collection node [get_atom_nodes -type IOPLL] {
    set name [get_atom_node_info -key NAME -node $node]
    post_message "   $name"
  }
}


proc find_kernel_pll_in_design {pll_search_string} {
  foreach_in_collection node [get_atom_nodes -type IOPLL] {
    set node_name [ get_atom_node_info -key NAME -node $node]
    set name [get_atom_node_info -key NAME -node $node]
    if { [ string match $pll_search_string $node_name ] == 1} {
      post_message "Found kernel_pll: $node_name"
      set kernel_pll_name $node_name
      return $kernel_pll_name
    }
  }
}


# Return values: [retval panel_id row_index]
#   panel_id and row_index are only valid if the query is successful
# retval:
#    0: success
#   -1: not found
#   -2: panel not found (could be report not loaded)
#   -3: no rows found in panel
#   -4: multiple matches found
proc find_report_panel_row { panel_name col_index string_op string_pattern } {
    if {[catch {get_report_panel_id $panel_name} panel_id] || $panel_id == -1} {
        return -2;
    }

    if {[catch {get_number_of_rows -id $panel_id} num_rows] || $num_rows == -1} {
        return -3;
    }

    # Search for row match.
    set found 0
    set row_index -1;

    for {set r 1} {$r < $num_rows} {incr r} {
        if {[catch {get_report_panel_data -id $panel_id -row $r -col $col_index} value] == 0} {
            if {[string $string_op $string_pattern $value]} {
                if {$found == 0} {
                    # If multiple rows match, return the first
                    set row_index $r
                }
                incr found
            }

        }
    }

    if {$found > 1} {return [list -4 $panel_id $row_index]}
    if {$row_index == -1} {return -1}

    return [list 0 $panel_id $row_index]
}


# get_fmax_from_report: Determines the fmax for the given clock. The fmax value returned
# will meet all timing requirements (setup, hold, recovery, removal, minimum pulse width)
# across all corners.  The return value is a 2-element list consisting of the
# fmax and clk name
proc get_fmax_from_report { clkname required recovery_multicycle iteration } {
    global fast_compile
    global revision_name
    global unused_clk_fmax
    # Find the clock period.
    set result [list]
    if {$fast_compile} {
      set result [fetch_clock "$revision_name.fit.rpt" $clkname]
    } else {
      set result [find_report_panel_row "*Timing Analyzer||Clocks" 0 match $clkname]
    }
    set retval [lindex $result 0]

    if {$retval == -1} {
        if {$required == 1} {
           error "Error: Could not find clock: $clkname"
        } else {
           post_message -type warning "Could not find clock: $clkname.  Clock is not required assuming 10 GHz and proceeding."
           return [list $unused_clk_fmax $clkname]
        }
    } elseif {$retval < 0} {
        error "Error: Failed search for clock $clkname (error $retval)"
    }

    # Update clock name to full clock name ($clkname as passed in may contain wildcards).
    if {$fast_compile} {
      set clkname [lindex $result 0]
      set clk_period [lindex $result 1]
    } else {
      set panel_id [lindex $result 1]
      set row_index [lindex $result 2]
      set clkname [get_report_panel_data -id $panel_id -row $row_index -col 0]
      set clk_period [get_report_panel_data -id $panel_id -row $row_index -col 2]
    }

    post_message "Clock $clkname"
    post_message "  Period: $clk_period"

    # Determine the most negative slack across all relevant timing metrics (setup, recovery, minimum pulse width)
    # and across all timing corners. Hold and removal metrics are not taken into account
    # because their slack values are independent on the clock period (for kernel clocks at least).
    #
    # Paths that involve both a posedge and negedge of the kernel clocks are not handled properly (slack
    # adjustment needs to be doubled).
    if {!$fast_compile} {
      set timing_metrics [list "Setup" "Recovery" "Minimum Pulse Width"]
      set timing_metric_colindex [list 1 3 5 ]
      set timing_metric_required [list 1 0 0]
      set wc_slack $clk_period
      set has_slack 0
      set fmax_from_summary 5000.0

      set panel_name "*Timing Analyzer||Multicorner Timing Analysis Summary"
      set panel_id [get_report_panel_id $panel_name]
      set result [find_report_panel_row $panel_name 0 equal " $clkname"]
      set retval [lindex $result 0]
      set single off
      if {$retval == -2} {
        post_message -type critical_warning "Multicorner Analysis is off. No analysis has been done for other corners!"
        set single on
      }

      # Find the "Fmax Summary" numbers reported in Quartus.  This may not
      # account for clock transfers but it does account for pos-to-neg edge same
      # clock transfers.  Whatever we calculate should be less than this.
      set fmax_panel_name UNKNOWN
      if {[string match $single "off"]} {
        set fmax_panel_name "*Timing Analyzer||* Model||*Fmax Summary"
      } else {
        set fmax_panel_name "*Timing Analyzer||Fmax Summary"
      }
      foreach panel_name [get_report_panel_names] {
        if {[string match $fmax_panel_name $panel_name] == 1} {
          set result [find_report_panel_row $panel_name 2 equal $clkname]
          set retval [lindex $result 0]
          if {$retval == 0} {
            set restricted_fmax_field [get_report_panel_data -id [lindex $result 1] -row [lindex $result 2] -col 1]
            regexp {([0-9\.]+)} $restricted_fmax_field restricted_fmax
            if {$restricted_fmax < $fmax_from_summary} {
              set fmax_from_summary $restricted_fmax
            }
          }
        }
      }
      post_message "  Restricted Fmax from STA: $fmax_from_summary"

      # Find the worst case slack across all corners and metrics
      foreach metric $timing_metrics metric_required $timing_metric_required col_ndx $timing_metric_colindex {
        if {[string match $single "on"]} {
          set panel_name "*Timing Analyzer||$metric Summary"
          set result [find_report_panel_row $panel_name 0 equal "$clkname"]
          set col_ndx 1
        } else {
          set panel_name "*Timing Analyzer||Multicorner Timing Analysis Summary"
          set result [find_report_panel_row $panel_name 0 equal " $clkname"]
          set single off
        }
        set panel_id [get_report_panel_id $panel_name]
        set retval [lindex $result 0]

        if {$retval == -1} {
          if {$required == 1 && $metric_required == 1} {
            error "Error: Could not find clock: $clkname"
          }
        } elseif {$retval < 0 && $retval != -4 } {
          error "Error: Failed search for clock $clkname (error $retval)"
        }

        if {$retval == 0 || $retval == -4} {
          set slack [get_report_panel_data -id [lindex $result 1] -row [lindex $result 2] -col $col_ndx ]
          post_message "    $metric slack: $slack"
          if {$slack != "N/A"} {
            if {$metric == "Setup" || $metric == "Recovery"} {
              set has_slack 1
              if {$metric == "Recovery"} {
              set normalized_slack [ expr $slack / $recovery_multicycle ]
                post_message "    normalized $metric slack: $normalized_slack"
                set slack $normalized_slack
              }
            }
          }
          # Keep track of the most negative slack.
          if {$slack < $wc_slack} {
            set wc_slack $slack
            set wc_metric $metric
          }
        }
      }
    } else {
      post_message -type critical_warning "Fast-compile enabled. Parsing results based on Fitter timing models."
      set timing_metrics [list "setup" "recovery" "minimum pulse width"]
      set timing_metric_required [list 1 0 0]
      set wc_slack $clk_period
      set has_slack 0
      set fmax_from_summary 5000.0

      # Find the worst case slack across all corners and metrics
      foreach metric $timing_metrics metric_required $timing_metric_required {
        # will fail if clock is not found
        set slack [fetch_timing "$revision_name.fit.rpt" $metric $clkname $required]

        post_message "    $metric slack: $slack"
        if {$slack != "N/A"} {
          if {$metric == "setup" || $metric == "recovery"} {
            set has_slack 1
            if {$metric == "recovery"} {
            set normalized_slack [ expr $slack / $recovery_multicycle ]
              post_message "    normalized $metric slack: $normalized_slack"
              set slack $normalized_slack
            }
          }
          # Keep track of the most negative slack.
          if {$slack < $wc_slack} {
            set wc_slack $slack
            set wc_metric $metric
          }
        }
      }

    }

    if {$has_slack == 1} {
        # IOPLL jitter compensation convergence aid
        # for iterations 3, 4, 5 add 50ps, 100ps, 200ps of extra IOPLL period adjustment
        set jitter_compensation 0.0;
        if {$iteration > 2} {
          set jitter_compensation [expr 0.05*(2**($iteration-3))]
        }

        if {$fast_compile} {
          #jitter guardband for fast compile
          set jitter_compensation [expr 0.025]
          post_message "Fast compile added $jitter_compensation ns to clock period as jitter compensation"
        }

        # Adjust the clock period to meet the worst-case slack requirement.
        set clk_period [expr $clk_period - $wc_slack + $jitter_compensation]
        post_message "  Adjusted period: $clk_period ([format %+0.3f [expr -$wc_slack]], $wc_metric)"

        # Compute fmax from clock period. Clock period is in nanoseconds and the
        # fmax number should be in MHz.
        set fmax [expr 1000 / $clk_period]

        if {$fmax_from_summary < $fmax} {
            post_message "  Restricted Fmax from STA is lower than $fmax, using it instead."
            set fmax $fmax_from_summary
        }

        # Truncate to two decimal places. Truncate (not round to nearest) to avoid the
        # very small chance of going over the clock period when doing the computation.
        set fmax [expr floor($fmax * 100) / 100]
        post_message "  Fmax: $fmax"
    } else {
        post_message -type warning "No slack found for clock $clkname - assuming 10 GHz."
        set fmax $unused_clk_fmax
    }

    return [list $fmax $clkname]
}

# Returns [k_fmax fmax1 k_clk_name fmax2 k_clk2x_name]
proc get_kernel_clks_and_fmax { k_clk_name k_clk2x_name recovery_multicycle iteration} {
    set result [list]
    # Read in the achieved fmax
    post_message "Calculating maximum fmax..."
    set x [ get_fmax_from_report $k_clk_name 1 $recovery_multicycle $iteration]
    set fmax1 [ lindex $x 0 ]
    set k_clk_name [ lindex $x 1 ]
    set x [ get_fmax_from_report $k_clk2x_name 0 $recovery_multicycle $iteration]
    set fmax2 [ lindex $x 0 ]
    set k_clk2x_name [ lindex $x 1 ]

    # The maximum is determined by both the kernel-clock and the double-pumped clock
    set k_fmax $fmax1
    if { [expr 2 * $fmax1] > $fmax2 } {
       set k_fmax [expr $fmax2 / 2.0]
    }
    return [list $k_fmax $fmax1 $k_clk_name $fmax2 $k_clk2x_name]
}


##############################################################################
##############################       MAIN        #############################
##############################################################################

post_message "Project name: $project_name"
post_message "Revision name: $revision_name"

load_package design

##### LOOP START #####
while {$setup_timing_violation == 1 && $iteration <= 5} {
    post_message "Adjusting PLL iteration: $iteration"

  # Open Quartus project
  project_open $project_name -revision $revision_name
  if {!$fast_compile} {
    design::load_design -writeable -snapshot final
    load_report $revision_name
  }

  # adjust PLL settings
  set k_clk_name_full   $k_clk_name
  set k_clk2x_name_full $k_clk2x_name

  # Process arguments.
  set fmax1 unknown
  set fmax2 unknown
  set k_fmax -1
  set pll_search_string  "*kernel_pll*"

  # get device speedgrade
  set device_family [get_global_assignment -name FAMILY]
  post_message "Device family name is $device_family"
  set part_name [get_global_assignment -name DEVICE]
  post_message "Device part name is $part_name"
  set report [report_part_info $part_name]
  regexp {Speed Grade.*$} $report speedgradeline
  regexp {(\d+)} $speedgradeline speedgrade
  if { $speedgrade < 1 || $speedgrade > 8 } {
    post_message "Speedgrade is $speedgrade and not in the range of 1 to 8"
    post_message "Terminating post-flow script"
    return TCL_ERROR
  }
  post_message "Speedgrade is $speedgrade"

  if {![info exists recovery_multicycle] } {
    # set up family specific parameters
    if { $device_family == "Arria 10" || $device_family == "Cyclone 10 GX"} {
      # changes made to the multicycle path here need to also be reflected in the multicycle value in top_post.sdc
      set recovery_multicycle 4.0
    }
    if { $device_family == "Stratix 10" } {
      # changes made to the multicycle path here need to also be reflected in the multicycle value in top_post.sdc
      set recovery_multicycle 15.0
    }
    if { $device_family == "Agilex" || $device_family == "Agilex 7" || $device_family == "Agilex 5" } {
      # changes made to the multicycle path here need to also be reflected in the multicycle value in top_post.sdc
      set recovery_multicycle 16.0
    }
  }

  # Logic to find Fmax
  if {$k_fmax == -1} {
      set x [get_kernel_clks_and_fmax $k_clk_name $k_clk2x_name $recovery_multicycle $iteration]
      set k_fmax       [ lindex $x 0 ]
      set fmax1        [ lindex $x 1 ]
      set k_clk_name_full   [ lindex $x 2 ]
      set fmax2        [ lindex $x 3 ]
      set k_clk2x_name_full [ lindex $x 4 ]
  }

  post_message "Kernel Fmax determined to be $k_fmax";

  if {$fmax2 == $unused_clk_fmax} {
    set kernel2x_clk_unused 1
  } else {
    set kernel2x_clk_unused 0
  }

  if {!$fast_compile} {
    design::unload_design
  }
  # Load post-fit atom netlist
  # can skip this step of loading atom netlist if file for frequency exists - only fast-compile
  set refclk_cache "kernel_pll_refclk_freq.txt"
  if {[file exists $refclk_cache] && [string match $revision_name "top"] && $fast_compile} {
    set fh [open $refclk_cache]
    set lines [split [read $fh] "\n"]
    close $fh
    foreach l $lines {
      if {[regexp {([0-9.]+)} $l -> refclk]} {
        break
      }
    }
    set kernel_pll_name ""
  } else {
    if { [catch {read_atom_netlist -type cmp} bummer] } {
      post_message "Post-fit netlist not found. Please run quartus_fit."
      post_message $bummer
      return TCL_ERROR
    # ERROR
    }

    set kernel_pll_name [find_kernel_pll_in_design $pll_search_string]

    # Get the IOPLL node
    if { [catch {set node [get_atom_node_by_name -name $kernel_pll_name]} ] } {
      post_message "IOPLL not found: $kernel_pll_name"
      list_plls_in_design
      return TCL_ERROR
      # ERROR
    }

    # Get the refclk frequency from the IOPLL node
    # Using the netlist's refclk frequency gives us a santity check.
    # modify by pxx
    #set refclk_MHz  [get_atom_node_info -key TIME_REFERENCE_CLOCK_FREQUENCY -node $node]
    set refclk_MHz  [get_atom_node_info -key TIME_IOPLL_REFCLK_TIME -node $node]
    regexp {([0-9.]+)} $refclk_MHz refclk
    #regexp {([0-9.]+)} 100.0 refclk
    # storing it in the cache file
    set fh [open $refclk_cache "w"]
    puts $fh $refclk
    close $fh
  }
  post_message "PLL reference clock frequency:"
  post_message "  $refclk MHz"

  set actual_kernel_clk [get_nearest_achievable_frequency $k_fmax $refclk $device_family $speedgrade $kernel2x_clk_unused]
  post_message "Desired kernel_clk frequency:"
  post_message "  $k_fmax MHz"
  if {$actual_kernel_clk != "TCL_ERROR"} {
    post_message "Actual kernel_clk frequency:"
    post_message "  $actual_kernel_clk MHz"
  } else {
    error "Error! Could not dial PLL back enough to meet the kernel frequency $k_fmax"
  }

  # Do changes for current revision (either base or import revision)
  if {!$fast_compile} {
    set success [adjust_iopll_frequency_in_postfit_netlist $revision_name $kernel_pll_name $device_family $speedgrade $actual_kernel_clk $kernel2x_clk_unused]
  } else {
    set success [adjust_iopll_frequency_in_postfit_netlist $revision_name $kernel_pll_name $device_family $speedgrade $actual_kernel_clk $kernel2x_clk_unused $refclk]
  }
  if {$success == "TCL_OK"} {
    post_message "IOPLL settings adjusted successfully for current revision"
  }
  post_message "000"
  if {!$fast_compile} {
    write_atom_netlist -file abc
    design::unload_design
    project_close
  }

  if {!$fast_compile} {
    # A little report
    project_open $project_name -revision $revision_name
    load_report $revision_name
  }

  post_message "Generating acl_quartus_report.txt"
  set outfile   [open "acl_quartus_report.txt" w]
  if {$fast_compile} {
    # override function for fast-compile to get fitter resource usage
    proc get_fitter_resource_usage {args} {
      global revision_name
      array set acceptable_args {-reg "Dedicated logic registers" -utilization "Logic utilization*" -io_pin "I/O pins" -resource "" -mem_bit "Total block memory bits" -alut "Combinational ALUT usage for logic"}

      # returns only the first arg
      set k [lindex $args 0]
      set v [lindex $args 1]
      if {![info exists acceptable_args($k)]} { error "Passed unacceptable args: $args." }
      set match_val ""

      # resource fetches custom resource
      if {$k eq {-resource}} {
        set match_val $v
      # all other have specific headers
      } else {
        set match_val $acceptable_args($k)
      }
      # get results in a list
      set resource_usage [fetch_from_report "$revision_name.fit.rpt" -panel "Fitter Resource Usage Summary" -column "Resource" -match $match_val]

      # format it conditionally based on whether percentage is available
      if {[string length [lindex $resource_usage 2]] != 0} {
        set return_string "[lindex $resource_usage 1] ( [lindex $resource_usage 2] )"
      } else {
        set return_string "[lindex $resource_usage 1]"
      }
      return $return_string
    }
  }
  set aluts_l   [regsub -all "," [get_fitter_resource_usage -alut] "" ]
  if {[catch {set aluts_m [regsub -all "," [get_fitter_resource_usage -resource "Memory ALUT usage"] "" ]} result]} {
    set aluts_m 0
  }
  if { [string length $aluts_m] < 1 || ! [string is integer $aluts_m] } {
    set aluts_m 0
  }
  set aluts     [expr $aluts_l + $aluts_m]
  set registers [get_fitter_resource_usage -reg]
  set logicutil [get_fitter_resource_usage -utilization]
  set io_pin    [get_fitter_resource_usage -io_pin]
  set dsp       [get_fitter_resource_usage -resource "*DSP*"]
  set mem_bit   [get_fitter_resource_usage -mem_bit]
  set m9k       [get_fitter_resource_usage -resource "M?0K*"]

  puts $outfile "ALUTs: $aluts"
  puts $outfile "Registers: $registers"
  puts $outfile "Logic utilization: $logicutil"
  puts $outfile "I/O pins: $io_pin"
  puts $outfile "DSP blocks: $dsp"
  puts $outfile "Memory bits: $mem_bit"
  puts $outfile "RAM blocks: $m9k"
  puts $outfile "Actual clock freq: $actual_kernel_clk"
  puts $outfile "Kernel fmax: $k_fmax"
  puts $outfile "1x clock fmax: $fmax1"
  if {$fmax2 == $unused_clk_fmax} {
    puts $outfile "2x clock fmax: Unused"
  } else {
    puts $outfile "2x clock fmax: $fmax2"
  }

  if {!$fast_compile} {
    # Highest non-global fanout signal
    set result [find_report_panel_row "Fitter||Place Stage||Fitter Resource Usage Summary" 0 equal "Highest non-global fan-out"]
    if {[lindex $result 0] < 0} {error "Error: Could not find highest non-global fan-out (error $retval)"}
    set high_fanout_signal_fanout_count [get_report_panel_data -id [lindex $result 1] -row [lindex $result 2] -col 1]
  } else {
    set high_fanout_signal_fanout_count [get_fitter_resource_usage -resource "Highest non-global fan-out"]
  }
  puts $outfile "Highest non-global fanout: $high_fanout_signal_fanout_count"

  close $outfile
  # End little report
  if {!$fast_compile} {
    # Preserve original sta report (only for first adjust PLL iteration)

    if {!$fast_compile} {
      if { $iteration == 1 } {file copy -force output_files/$revision_name.sta.rpt output_files/$revision_name.sta-orig.rpt}
    }

    # delete STA violation report files from previous iterations
    file delete {*}[glob -nocomplain $revision_name.failing_clocks.rpt]
    file delete {*}[glob -nocomplain $revision_name.failing_paths.rpt]

    # Re-run STA
    post_message "Launching STA"
    if {[catch {execute_module -tool sta -args "--report_script=dla_failing_clocks.tcl --force_dat"} result]} {
      post_message -type error "Error! $result"
      exit 2
    }
    
    set setup_timing_violation 0
    set filename "$revision_name.failing_clocks.rpt"
    if {[catch {open $filename r} fid]} {
      post_message "No timing violations found"
    } else {
      while {[gets $fid line] != -1} {
        regexp {.* Setup .*$} $line setupline
        if {![info exists setupline]} {
          regexp {.* Recovery .*$} $line setupline
        }
        if {[info exists setupline]} {
          if { $device_family == "Arria 10" } {
            regexp {.*kernel_pll\|outclk.*$} $setupline outclkline
          }
          if { $device_family == "Stratix 10" || $device_family == "Agilex" || $device_family == "Agilex 7" || $device_family == "Agilex 5" } {
            regexp {.*kernel_pll_outclk.*$} $setupline outclkline
          }
          if {[info exists outclkline]} {
            post_message "Timing violation on kernel clock found"
            set setup_timing_violation 1
            unset outclkline
          }
          unset setupline
        }
      }
    close $fid
    }
    incr iteration
  } else {
    post_message -type warning "Adjusted timing for worst-case slack, but did not re-run timing analysis because you are running fast_compile - assuming timing requirements have been met"
    set setup_timing_violation 0
  }
  project_close
}

##### LOOP END #####
