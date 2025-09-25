package require -exact qsys 19.2
package require altera_terp

set_module_property NAME altera_ai_ip
set_module_property VERSION 0.6
set_module_property ICON_PATH logo.jpg
set_module_property EDITABLE false
set_module_property AUTHOR "Altera Corporation"
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property INTERNAL false

add_fileset synthesis_files QUARTUS_SYNTH my_generate

set_fileset_property synthesis_files TOP_LEVEL altera_ai_ip
proc render_top_level {} {
  # get template
  set template_path "./verilog/altera_ai_ip.sv.terp"
  set template_fd [open $template_path]
  set template   [read $template_fd]
  close $template_fd
  set existing_arch [glob -directory "./verilog/" -tails -type d *]
  set params(archs) $existing_arch
  set contents [altera_terp $template params]
  return $contents
}
add_fileset_file altera_ai_ip/altera_ai_ip.sv SYSTEM_VERILOG TEXT [render_top_level]

source ./static_files.tcl

proc my_generate { entity } {
    set architecture [get_parameter_value ARCH_OPTION]
    source ./verilog/$architecture/generated_files.tcl
}

#DLA ARCHITECTURE
set existing_arch [glob -directory "./verilog/" -tails -type d *]
add_display_item "" "AI IP Core Architecture" GROUP tab
set arch_option_param ARCH_OPTION
add_parameter           $arch_option_param  STRING [lindex $existing_arch 0]
set_parameter_property  $arch_option_param  ALLOWED_RANGES  $existing_arch
set_parameter_property  $arch_option_param  DISPLAY_NAME    "Architecture"
set_parameter_property  $arch_option_param  DESCRIPTION     "Architecture"
set_parameter_property  $arch_option_param  AFFECTS_GENERATION true
set_parameter_property  $arch_option_param  HDL_PARAMETER   true
add_display_item "AI IP Core Architecture" $arch_option_param  parameter


set_module_property DESCRIPTION "The FPGA AI Suite is an AI Engine."
set_module_property DISPLAY_NAME "FPGA AI Suite"

source ./dla_helper.tcl

add_clk                dla_clk
add_clk                ddr_clk
add_clk                irq_clk
# the reset must be associated to a clock
add_rstn               dla_resetn   dla_clk

# CSR Parameters
add_display_item "" "CSR Parameters" GROUP tab

set param C_CSR_AXI_ADDR_WIDTH
add_parameter           $param  INTEGER         0
set_parameter_property  $param  DISPLAY_NAME    "Address Width"
set_parameter_property  $param  DISPLAY_UNITS   "bits"
set_parameter_property  $param  HDL_PARAMETER   true
set_parameter_property  $param  DESCRIPTION     "AXI4-Lite Address Width."
set_parameter_property  $param  VISIBLE         true
set_parameter_property  $param  DERIVED         true
add_display_item "CSR Parameters" $param  parameter

set param C_CSR_AXI_DATA_WIDTH
add_parameter           $param  INTEGER         0
set_parameter_property  $param  DISPLAY_NAME    "Data Width"
set_parameter_property  $param  DISPLAY_UNITS   "bits"
set_parameter_property  $param  HDL_PARAMETER   true
set_parameter_property  $param  DESCRIPTION     "AXI4-Lite Data Width."
set_parameter_property  $param  VISIBLE         true
set_parameter_property  $param  DERIVED         true
add_display_item "CSR Parameters" $param  parameter


# DDR Parameters
add_display_item "" "DDR Parameters" GROUP tab

set param C_DDR_AXI_ADDR_WIDTH
add_parameter           $param  INTEGER         0
set_parameter_property  $param  DISPLAY_NAME    "Address Width"
set_parameter_property  $param  DISPLAY_UNITS   "bits"
set_parameter_property  $param  HDL_PARAMETER   true
set_parameter_property  $param  DESCRIPTION     "AXI4 Address Width."
set_parameter_property  $param  VISIBLE         true
set_parameter_property  $param  DERIVED         true
add_display_item "DDR Parameters" $param  parameter

set param C_DDR_AXI_DATA_WIDTH
add_parameter           $param  INTEGER         0
set_parameter_property  $param  DISPLAY_NAME    "Data Width"
set_parameter_property  $param  DISPLAY_UNITS   "bits"
set_parameter_property  $param  HDL_PARAMETER   true
set_parameter_property  $param  DESCRIPTION     "AXI4 Data Width."
set_parameter_property  $param  VISIBLE         true
set_parameter_property  $param  DERIVED         true
add_display_item "DDR Parameters" $param  parameter

set param C_DDR_AXI_BURST_WIDTH
# Warning: omni_add_axi4_interface uses a constant of 2, but the rtl's default value is 4.
add_parameter           $param  INTEGER         0
set_parameter_property  $param  DISPLAY_NAME    "Burst Width"
set_parameter_property  $param  DISPLAY_UNITS   "bits"
set_parameter_property  $param  HDL_PARAMETER   false
set_parameter_property  $param  DESCRIPTION     "AXI4 Burst Width. Length = 2**Width."
set_parameter_property  $param  VISIBLE         true
set_parameter_property  $param  DERIVED         true
add_display_item "DDR Parameters" $param  parameter

set param C_DDR_AXI_THREAD_ID_WIDTH
add_parameter           $param  INTEGER         0
set_parameter_property  $param  DISPLAY_NAME    "ID"
set_parameter_property  $param  DISPLAY_UNITS   "bits"
set_parameter_property  $param  HDL_PARAMETER   true
set_parameter_property  $param  DESCRIPTION     "AXI4 ID Width."
set_parameter_property  $param  VISIBLE         true
set_parameter_property  $param  DERIVED         true
add_display_item "DDR Parameters" $param  parameter

# DLA Parameters
# todo: either enable this or remove it before release
add_display_item "" "DLA Parameters" GROUP tab
set_display_item_property "DLA Parameters" VISIBLE false
# the parameters need to be defined first, and modified in elaboration
set param C_CONFIG_READER_DATA_BYTES
add_parameter           $param  INTEGER         8
set_parameter_property  $param  DISPLAY_NAME    "Config Input Width"
set_parameter_property  $param  DISPLAY_UNITS   "bytes"
set_parameter_property  $param  DESCRIPTION     "Config network input port width"
set_parameter_property  $param  VISIBLE         false
set_parameter_property  $param  DERIVED         true
add_display_item "DLA Parameters" $param  parameter

omni_add_capability 949 1 2048 0 0

add_elab_callback my_elab
add_validation_callback check_family
# check if an INI is set to display capability tab
add_validation_callback check_ocs_ini

proc my_elab {} {

  set architecture [get_parameter_value ARCH_OPTION]
  source ./verilog/$architecture/interface_param.tcl

  dla_add_axi4lite_slave_interface  csr_axi       ddr_clk     dla_resetn
  dla_add_axi4_master_interface     ddr_axi       ddr_clk     dla_resetn

  omni_add_interrupt_port           irq_level     irq_clk     csr_axi output

}

# return the family string used by quartus
proc get_arch_family { arch_name } {
  set splitted_name [split $arch_name "_"]
  set family [lindex $splitted_name end]
  if { $family eq "A10" } {
    return "Arria 10"
  } elseif { $family eq "C10"} {
    return "Cyclone 10 GX"
  } elseif { $family eq "S10"} {
    return "Stratix 10"
  } elseif { $family eq "AGX7"} {
    return "Agilex 7"
  } elseif { $family eq "AGX5"} {
    return "Agilex 5"
  } else {
    send_message ERROR "Invalid Family: $family"
    return "Unknown Family"
  }
}

proc check_family {} {
  set family [get_parameter_value device_family]
  set architecture [get_parameter_value ARCH_OPTION]

  set arch_family [get_arch_family $architecture]

  if { $family ne $arch_family } {
    send_message ERROR "Design uses $family but architecture is built for $arch_family"
  }
}
