# not sure why we need this
add_parameter device_family STRING
set_parameter_property device_family VISIBLE false
set_parameter_property device_family SYSTEM_INFO {DEVICE_FAMILY}
set_parameter_property device_family AFFECTS_GENERATION true

# those are useful hooks so keep them here
set_module_property ELABORATION_CALLBACK elaboration_callback
set elaboration_callback_hooks [list]

set_module_property VALIDATION_CALLBACK validation_callback
set validation_callback_hooks [list]

###################################################################################
# Master Elaboration Callback Hook.
# 
#
###################################################################################
proc elaboration_callback {} {
  upvar elaboration_callback_hooks hooks

  foreach hook $hooks {
    $hook
  }
}

###################################################################################
# Master Validation Callback Hook.
# 
#
###################################################################################
proc validation_callback {} {
  upvar validation_callback_hooks hooks

  foreach hook $hooks {
    $hook
  }
}

###################################################################################
# Register core level validate call back
# 
#
###################################################################################
proc add_validation_callback { func } {
  upvar validation_callback_hooks hooks
  lappend hooks $func
}

###################################################################################
# Register core level elab call back
# 
#
###################################################################################
proc add_elab_callback { func } {
  upvar elaboration_callback_hooks hooks
  lappend hooks $func
}


# capability related 
###################################################################################
#
# Create the Fake Generics (These dont exist in RTL) But can be probed by Qsys
#
###################################################################################
proc omni_add_fake_generic {gui_grp desc generic default lower higher } {

  add_display_item       $gui_grp $generic parameter
  add_parameter          $generic INTEGER $lower
  set_parameter_property $generic DEFAULT_VALUE $default
  set_parameter_property $generic DISPLAY_NAME $desc
  set_parameter_property $generic ALLOWED_RANGES $lower:$higher
  set_parameter_property $generic ENABLED true
  set_parameter_property $generic UNITS None
  set_parameter_property $generic VISIBLE true
  set_parameter_property $generic HDL_PARAMETER false

}

# Need to understand how customer will use this
###################################################################################
#
# Add the Offset Capability Info to a core.
#
###################################################################################
proc omni_add_capability { value version size {en 0 } { st 0} } {

  add_display_item "" "Capability Info" GROUP tab
  # hide the capability tab by default.
  set_display_item_property  "Capability Info" VISIBLE false

  add_display_item "Capability Info" "CapInfo" GROUP
  omni_add_fake_generic  "CapInfo" "Type"                      C_OMNI_CAP_TYPE $value 0 1024
  omni_add_fake_generic  "CapInfo" "Version "                  C_OMNI_CAP_VERSION $version 1 255
  omni_add_fake_generic  "CapInfo" "Size (32bit Words)"        C_OMNI_CAP_SIZE $size 0 1073741824
  omni_add_fake_generic  "CapInfo" "Associated ID"             C_OMNI_CAP_ID_ASSOCIATED 0 0 255
  omni_add_fake_generic  "CapInfo" "Component ID"              C_OMNI_CAP_ID_COMPONENT 0 0 255
  omni_add_fake_generic  "CapInfo" "IRQ Vector (255:disabled)" C_OMNI_CAP_IRQ 255 0 255
  omni_add_fake_generic  "CapInfo" "Tag"                       C_OMNI_CAP_TAG 0 0 255
  if {$en} {
    omni_add_fake_generic  "CapInfo" "IRQ Enable Exists"         C_OMNI_CAP_IRQ_ENABLE_EN 1 0 1
  } else {
    omni_add_fake_generic  "CapInfo" "IRQ Enable Exists"         C_OMNI_CAP_IRQ_ENABLE_EN 0 0 1
  }
  omni_add_fake_generic  "CapInfo" "IRQ Enable Register"       C_OMNI_CAP_IRQ_ENABLE $en 0 32767
  if {$en} {
    set_parameter_property C_OMNI_CAP_IRQ_ENABLE_EN    ENABLED false
    set_parameter_property C_OMNI_CAP_IRQ_ENABLE       ENABLED false
  }


  if {$st} {
    omni_add_fake_generic  "CapInfo" "IRQ Status Exists"         C_OMNI_CAP_IRQ_STATUS_EN 1 0 1
  } else {
    omni_add_fake_generic  "CapInfo" "IRQ Status Exists"         C_OMNI_CAP_IRQ_STATUS_EN 0 0 1
  }
  omni_add_fake_generic  "CapInfo" "IRQ Status Register"       C_OMNI_CAP_IRQ_STATUS $st 0 32767
  if {$st} {
    set_parameter_property C_OMNI_CAP_IRQ_STATUS_EN    ENABLED false
    set_parameter_property C_OMNI_CAP_IRQ_STATUS       ENABLED false
  }
  set_parameter_property C_OMNI_CAP_IRQ_ENABLE_EN DISPLAY_HINT boolean--
  set_parameter_property C_OMNI_CAP_IRQ_STATUS_EN DISPLAY_HINT boolean--

  set_parameter_property C_OMNI_CAP_TYPE    ENABLED false
  set_parameter_property C_OMNI_CAP_VERSION ENABLED false
  set_parameter_property C_OMNI_CAP_SIZE    ENABLED false

}

# The QUARTUS_INI SYSTEM_INFO parameter used to display/hide the capability tab on GUI
add_parameter          CAP_ENABLED_INI  BOOLEAN          false
set_parameter_property CAP_ENABLED_INI  DESCRIPTION      "Whether the dla_ocs_enabled ini is enabled"
set_parameter_property CAP_ENABLED_INI  SYSTEM_INFO      QUARTUS_INI
set_parameter_property CAP_ENABLED_INI  SYSTEM_INFO_ARG  "dla_ocs_enabled"
set_parameter_property CAP_ENABLED_INI  VISIBLE false

proc check_ocs_ini {} {
  set ocs_enabled_ini [get_parameter_value CAP_ENABLED_INI]
  set_display_item_property  "Capability Info" VISIBLE $ocs_enabled_ini
}

# Interface

###################################################################################
#
#
#
###################################################################################
proc add_clk { name } {
  add_interface ${name} clock end
  set_interface_property ${name} clockRate 0
  set_interface_property ${name} ENABLED true
  add_interface_port ${name} ${name} clk Input 1
}

###################################################################################
#
#
#
###################################################################################
proc add_rstn { name clk } {

  add_interface ${name} reset end
  set_interface_property ${name} associatedClock $clk
  set_interface_property ${name} synchronousEdges DEASSERT
  set_interface_property ${name} ENABLED true
  add_interface_port ${name} ${name} reset_n Input 1
}

###################################################################################
#
#
#
###################################################################################
proc dla_add_axi4lite_slave_interface { prefix clk rst }  {

  set master_out "Input"
  set master_in  "Output"
  set direction "end"

  # align with Omnitek naming standard
  set parameter_prefix "C_[string toupper $prefix]"

  # refer to parameters set in core_hw.tcl
  set data_width ${parameter_prefix}_DATA_WIDTH
  set addr_width ${parameter_prefix}_ADDR_WIDTH
  
  ######################################################################################
  add_interface $prefix axi4lite $direction
  set_interface_property $prefix associatedClock $clk
  set_interface_property $prefix associatedReset $rst

  # copied this from qsys standard axi4lite slave interface template
  set_interface_property $prefix readAcceptanceCapability 1
  set_interface_property $prefix writeAcceptanceCapability 1
  set_interface_property $prefix combinedAcceptanceCapability 1
  set_interface_property $prefix bridgesToMaster ""
  set_interface_property $prefix ENABLED true
  set_interface_property $prefix EXPORT_OF ""
  set_interface_property $prefix PORT_NAME_MAP ""
  set_interface_property $prefix CMSIS_SVD_VARIABLES ""
  set_interface_property $prefix SVD_ADDRESS_GROUP ""
  set_interface_property $prefix IPXACT_REGISTER_MAP_VARIABLES ""

  add_interface_port $prefix ${prefix}_awaddr awaddr $master_out $addr_width
  add_interface_port $prefix ${prefix}_awvalid awvalid $master_out 1
  add_interface_port $prefix ${prefix}_awready awready $master_in 1
  add_interface_port $prefix ${prefix}_wdata wdata $master_out $data_width
  add_interface_port $prefix ${prefix}_wready wready $master_in 1
  add_interface_port $prefix ${prefix}_wvalid wvalid $master_out 1
  add_interface_port $prefix ${prefix}_wstrb wstrb $master_out ($data_width/8)
  add_interface_port $prefix ${prefix}_bresp bresp $master_in 2
  add_interface_port $prefix ${prefix}_bvalid bvalid $master_in 1
  add_interface_port $prefix ${prefix}_bready bready $master_out 1
  add_interface_port $prefix ${prefix}_rdata rdata $master_in $data_width
  add_interface_port $prefix ${prefix}_rresp rresp $master_in 2
  add_interface_port $prefix ${prefix}_rvalid rvalid $master_in 1
  add_interface_port $prefix ${prefix}_rready rready $master_out 1
  add_interface_port $prefix ${prefix}_araddr araddr $master_out $addr_width
  add_interface_port $prefix ${prefix}_arvalid arvalid $master_out 1
  add_interface_port $prefix ${prefix}_arready arready $master_in 1
  add_interface_port $prefix ${prefix}_awprot awprot $master_out 3
  add_interface_port $prefix ${prefix}_arprot arprot $master_out 3

}

###################################################################################
#
#
#
###################################################################################
proc dla_add_axi4_master_interface { prefix clk rst }  {

  set master_out "Output"
  set master_in  "Input"
  set direction "start"
  
  # align with Omnitek naming standard
  # also aligns with how parameters are declared in core_hw.tcl
  set parameter_prefix "C_[string toupper $prefix]"

  # refer to parameters set in core_hw.tcl
  set addr_width      ${parameter_prefix}_ADDR_WIDTH
  set read_id_width   ${parameter_prefix}_THREAD_ID_WIDTH
  set data_width      ${parameter_prefix}_DATA_WIDTH
  ######################################################################################
  add_interface $prefix axi4 $direction
  set_interface_property $prefix associatedClock $clk
  set_interface_property $prefix associatedReset $rst
  
  # copied this from qsys standard axi4 master interface template
  set_interface_property $prefix readIssuingCapability 16
  set_interface_property $prefix writeIssuingCapability 16
  set_interface_property $prefix combinedIssuingCapability 16
  set_interface_property $prefix issuesINCRBursts true
  set_interface_property $prefix issuesWRAPBursts false
  set_interface_property $prefix issuesFIXEDBursts false
  set_interface_property $prefix ENABLED true
  set_interface_property $prefix EXPORT_OF ""
  set_interface_property $prefix PORT_NAME_MAP ""
  set_interface_property $prefix CMSIS_SVD_VARIABLES ""
  set_interface_property $prefix SVD_ADDRESS_GROUP ""
  set_interface_property $prefix IPXACT_REGISTER_MAP_VARIABLES ""

  add_interface_port $prefix ${prefix}_awvalid awvalid $master_out 1
  add_interface_port $prefix ${prefix}_awprot awprot $master_out 3
  add_interface_port $prefix ${prefix}_awlen awlen $master_out 8
  add_interface_port $prefix ${prefix}_awready awready $master_in 1
  add_interface_port $prefix ${prefix}_awsize awsize $master_out 3
  add_interface_port $prefix ${prefix}_awburst awburst $master_out 2
  add_interface_port $prefix ${prefix}_arvalid arvalid $master_out 1
  add_interface_port $prefix ${prefix}_arprot arprot $master_out 3
  add_interface_port $prefix ${prefix}_arlen arlen $master_out 8
  add_interface_port $prefix ${prefix}_arready arready $master_in 1
  add_interface_port $prefix ${prefix}_arsize arsize $master_out 3
  add_interface_port $prefix ${prefix}_arburst arburst $master_out 2  
  add_interface_port $prefix ${prefix}_rvalid rvalid $master_in 1
  add_interface_port $prefix ${prefix}_rready rready $master_out 1
  add_interface_port $prefix ${prefix}_wvalid wvalid $master_out 1
  add_interface_port $prefix ${prefix}_wlast wlast $master_out 1
  add_interface_port $prefix ${prefix}_wready wready $master_in 1
  add_interface_port $prefix ${prefix}_bvalid bvalid $master_in 1
  add_interface_port $prefix ${prefix}_bready bready $master_out 1
  add_interface_port $prefix ${prefix}_awaddr awaddr $master_out $addr_width
  add_interface_port $prefix ${prefix}_awid awid $master_out $read_id_width
  add_interface_port $prefix ${prefix}_araddr araddr $master_out $addr_width
  add_interface_port $prefix ${prefix}_arid arid $master_out $read_id_width
  add_interface_port $prefix ${prefix}_rdata rdata $master_in $data_width
  add_interface_port $prefix ${prefix}_rid rid $master_in $read_id_width
  add_interface_port $prefix ${prefix}_wdata wdata $master_out $data_width
  add_interface_port $prefix ${prefix}_wstrb wstrb $master_out ($data_width/8)
  add_interface_port $prefix ${prefix}_bid bid $master_in $read_id_width
}

###################################################################################
#
#
#
###################################################################################
# Todo: this function doesn't attach a reset to the interrupt
proc omni_add_interrupt_port { name clk ctrl dir { size 1 } }  {

  if {$dir == "input"} {
    set direction "start"
  } else {
    set direction "end"
  }

  add_interface $name interrupt $direction
  set_interface_property $name associatedClock $clk
  set_interface_property $name irqScheme INDIVIDUAL_REQUESTS
  add_interface_port $name $name irq $dir $size

  if {$dir == "input"} {
  } else {
    set_interface_property $name associatedAddressablePoint $ctrl
  }

}