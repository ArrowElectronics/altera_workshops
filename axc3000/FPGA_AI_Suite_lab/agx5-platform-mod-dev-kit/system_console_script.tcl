# Source the library
source include/system_console_lib.tcl


# Printing usage process
proc print_usage {} {
  puts "system_console --script=system_console_script.tcl \[OPTION]\n
  Options:

    help, -help                 Print a usage message
    --num_inferences            Number of inferences
    --input                     Input file path 
    --output_shape              Output shape of graph in format: \[C H W]
    --system_performance        System Performance testing
    --core_ip_performance       Core IP Performance testing
    --functional                Functional inference
    --arch                      Path to architecture file"
  exit 1
}


# This process handles parsing of the arguments to the script
proc parse_args {argc argv} {

  # Initialize variables with default values
  set system_performance 0
  set core_ip_performance 0
  set functional 0
  set num_inferences 0
  set output_shape ""
  set input_file_name ""
  set arch_path ""

  # Parse command-line arguments
  for {set i 0} {$i < $argc} {incr i} {
    set arg [lindex $argv $i]
    
    if {[string match --*=* $arg]} {
      # Handle --key=value format
      set key [string range $arg 2 [expr {[string first "=" $arg] - 1}]]
      set value [string range $arg [expr {[string first "=" $arg] + 1}] end]
      
      switch -- $key {
        system_performance {
            set system_performance 1
        }
        core_ip_performance {
            set core_ip_performance 1
        }
        functional {
            set functional 1
        }
        num_inferences {
            set num_inferences $value
        }
        input {
            set input_file_name $value
        }
        arch {
            set arch_path $value
        }
        output_shape {
          # Capture the entire output_shape argument
          if {[string match {\[*} $value]} {
            while {![string match {*\]} $value]} {
              incr i
              append value " [lindex $argv $i]"
            }
            set output_shape $value
          } else {
            print_usage
            exit 1
          }
        }
        default {
            print_usage
            exit 1
        }
      }
    } else {
      # Handle --flag format
      switch -- $arg {
        --system_performance {
          set system_performance 1
        }
        --core_ip_performance {
          set core_ip_performance 1
        }
        --functional {
          set functional 1
        }
        --num_inferences {
          incr i
          set num_inferences [lindex $argv $i]
        }
        --input {
          incr i
          set input_file_name [lindex $argv $i]
        }
        --arch {
          incr i
          set arch_path [lindex $argv $i]
        }
        --output_shape {
          incr i
          set output_shape [lindex $argv $i]
          # Capture the entire output_shape argument
          if {[string match {\[*} $output_shape]} {
            while {![string match {*\]} $output_shape]} {
              incr i
              append output_shape " [lindex $argv $i]"
            }
          } else {
            print_usage
            exit 1
          }
        }
        default {
          print_usage
          exit 1
        }
      }
    }
  }

  # Remove brackets and split the output_shape into components
  if {$output_shape eq ""} {
    print_usage
    exit 1
  } else {
    set output_shape [string trim $output_shape {\[\]}]
    set output_shape [string map {, " "} $output_shape]
    set components [split $output_shape " "]
    if {[llength $components] == 3} {
      set C [lindex $components 0]
      set H [lindex $components 1]
      set W [lindex $components 2]
      if {$C eq "" || $H eq "" || $W eq ""} {
        print_usage
        exit 1
      }
    } else {
      print_usage
      exit 1
    }
  }

  if {$input_file_name eq ""} {
    print_usage
    exit 1
  }

  # Ensure arch file path exists
  if {$arch_path eq ""} {
    print_usage
    exit 1
  }

  return [list $system_performance $core_ip_performance $functional $num_inferences $C $H $W $input_file_name $arch_path]
}


# Main Function
proc main {argc argv} {
  # Check if the script should display help information
  if {$argc > 0} {
    set firstArg [lindex $argv 0]
    if {[string equal $firstArg "help"] || [string equal $firstArg "-help"]} {
      print_usage
    }
  }

  # Parse script arguments
  set parsed_args [parse_args $argc $argv]
  lassign $parsed_args system_performance core_ip_performance functional num_inferences C H W input_file_name arch_path

  # Perfromance and functional testing calls 
  if {$system_performance && $core_ip_performance} {
      puts "ERROR: --system_performance or --core_ip_performance cannot be set at the same time."
      exit 1
  }
  if {($system_performance || $core_ip_performance) && $functional} {
      puts "ERROR: --system_performance or --core_ip_performance cannot be set with --functional at the same time."
      exit 1
  } elseif {$functional} {
      if {$num_inferences == 0} {
          puts "Number of inferences must be greater than 0."
          exit 1
      }
      # Functional script logic contained within "main_functional" process in library
      main_functional $num_inferences $input_file_name $C $H $W $arch_path
  } elseif {$system_performance || $core_ip_performance} {
      if {$system_performance} {
        puts "Number of inferences is always set to 32 in system performance testing for optimal results\n"
      } else {
        puts "Number of inferences is always set to 1 in core IP performance testing for optimal results\n"
      }

      # Perfromance script logic contained within "main_functional" process in library
      main_performance $input_file_name $C $H $W $core_ip_performance $arch_path
  } else {
    # Neither performance nor functional test was passed as an argument
    print_usage
  }

}

main $argc $argv