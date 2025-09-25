# This design example only supports an AXI Width of 128 bits = 16 bytes
variable AXI_STREAM_DATA_WIDTH_BYTES 16
# This design example has a limit to ingress on-chip memory size in bytes
#variable INGRESS_ON_CHIP_MEMORY_SIZE_BYTES 524288
variable INGRESS_ON_CHIP_MEMORY_SIZE_BYTES 4096
# This design example has a limit to egress on-chip memory size in bytes
#variable EGRESS_ON_CHIP_MEMORY_SIZE_BYTES 131072
variable EGRESS_ON_CHIP_MEMORY_SIZE_BYTES 1024

# DDR-Free ED Address Map Constants
variable DLA_IP_0_CSR_ADDR 0x00038000
variable INGRESS_SGDMA_CSR_ADDR 0x00030000
variable INGRESS_SGDMA_DESCRIPTOR_ADDR 0x00030020
variable EGRESS_SGDMA_CSR_ADDR 0x00030040
variable EGRESS_SGDMA_DESCRIPTOR_ADDR 0x00030060


# Process to validate arguments to script
proc validate_args {input_file num_inferences} {
  global INGRESS_ON_CHIP_MEMORY_SIZE_BYTES
  global AXI_STREAM_DATA_WIDTH_BYTES
  # Make sure user requested number of inferences is valid
  if {$num_inferences < 0} {
    puts "Number of inferences must be greater than 0."
    exit 1
  }

  # Check if the file exists
  if {![file exists $input_file]} {
      puts "Error: The file '$input_file' does not exist."
      exit 1
  }

  # Get the size of the file in bytes
  set file_size [file size $input_file]

  # Make sure the input file is aligned to the mSGDMA/FPGA AI Suite stream width
  if {[expr {$file_size % $AXI_STREAM_DATA_WIDTH_BYTES}] != 0} {
      puts "Error: this design example only supports input sizes aligned to 128 bits. Please pad accordingly."
      exit 1
  }

  # Format input file size into hex representation
  set file_size_hex [format "0x%X" $file_size]

  puts "Input file: $input_file"
  puts "Input size: $file_size_hex bytes"

  return $file_size
}


# Parse the CVECTOR from the architecture file
proc parse_cvec {arch_path} {
  set arch_file [open $arch_path r]
  set arch_data [read $arch_file]
  close $arch_file

  # Extract the CVEC line
  set cvec_value [lindex [regexp -inline {c_vector\s*:\s*([^\n]+)} $arch_data] 1]

  if {$cvec_value eq ""} {
    puts "Error: Unable to find CVEC in architecture file."
    exit 1
  }

  # Return the CVEC value
  return $cvec_value
}


# Process to calculate # of AXI transfers that will be sent out of output streamer
# The output streamer will send out a number of AXI transfers based on the output shape
# H, W, C and AXI stream data width
proc calulate_egress_axi_transfers {C H W CVEC} {
  global EGRESS_ON_CHIP_MEMORY_SIZE_BYTES
  global AXI_STREAM_DATA_WIDTH_BYTES
  set AXI_STREAM_DATA_WIDTH_ELEMENTS [expr {$AXI_STREAM_DATA_WIDTH_BYTES / 2}]

  # Calculation for # of AXI transfers from output streamer
  # int N = H * W;
  # int per_pixel = (C + axi_width - 1) / axi_width;
  # if (C % axi_width == 0 && !($C % $CVEC ==0)) per_pixel += 1;
  # int last_pixel = (C + axi_width - 1) / axi_width;
  # return (N - 1) * per_pixel + last_pixel;
  set N [expr {$H * $W}]
  set per_pixel [expr {($C + $AXI_STREAM_DATA_WIDTH_ELEMENTS - 1) / $AXI_STREAM_DATA_WIDTH_ELEMENTS + ((($C % $AXI_STREAM_DATA_WIDTH_ELEMENTS == 0) && !($C % $CVEC == 0)) ? 1 : 0)}]
  set last_pixel [expr {($C + $AXI_STREAM_DATA_WIDTH_ELEMENTS - 1) / $AXI_STREAM_DATA_WIDTH_ELEMENTS}]
  set total_valid_transfers [expr {($N - 1) * $per_pixel + $last_pixel}]
  set output_streamer_transfers_bytes [expr {$total_valid_transfers * $AXI_STREAM_DATA_WIDTH_BYTES}]

  # Make sure output streamer # of transfer bytes is aligned to AXI_STREAM_DATA_WIDTH
  if {$output_streamer_transfers_bytes <=0 || [expr {$output_streamer_transfers_bytes % $AXI_STREAM_DATA_WIDTH_BYTES}] != 0} {
    puts "Error with egress AXI transfer calculation. Please check your output shape size arguments (C H W)"
    exit 1
  }

  # Ensure output inference result can fit into on-chip memory
  if {$output_streamer_transfers_bytes > $EGRESS_ON_CHIP_MEMORY_SIZE_BYTES} {
      puts "Output inference results is too large to fully fit into on-chip memory of size $EGRESS_ON_CHIP_MEMORY_SIZE_BYTES bytes. Output inference results will be partitioned and transferred partially.\n"
  }
  # Format input file size into hex representation
  set output_streamer_transfers_hex [format "0x%X" $output_streamer_transfers_bytes]
  puts "Expected number of bytes transferred by FPGA AI Suite output streamer: $output_streamer_transfers_hex bytes"

  return $output_streamer_transfers_bytes
}


# Initiate reset via source/probe IP
proc assert_reset {} {
  set issp_index 0
  set issp [lindex [get_service_paths issp] 0]
  set claimed_issp [claim_service issp $issp mylib]
  set source_data 0x0
  issp_write_source_data $claimed_issp $source_data
  set source_data 0x1
  issp_write_source_data $claimed_issp $source_data
}


# Initializing coreDLA (register map: fpga/csr/rtl/inc/dla_csr_constants.svh)
proc initialize_coredla {master_path} {
  global DLA_IP_0_CSR_ADDR
  global INGRESS_SGDMA_CSR_ADDR
  global EGRESS_SGDMA_CSR_ADDR

  set csr_register_addr [expr {$DLA_IP_0_CSR_ADDR + 0x220}]
  master_write_32 $master_path $csr_register_addr 0

  set csr_register_addr [expr {$DLA_IP_0_CSR_ADDR + 0x204}]
  master_write_32 $master_path $csr_register_addr 0

  set csr_register_addr [expr {$DLA_IP_0_CSR_ADDR + 0x200}]
  master_write_32 $master_path $csr_register_addr 3

  # Writing 0x1 to this register will instruct DLA to accept input until register is cleared
  set csr_register_addr [expr {$DLA_IP_0_CSR_ADDR + 0x22c}]
  master_write_32 $master_path $csr_register_addr 1

  # Reset egress SGDMA
  set csr_register_addr [expr {$EGRESS_SGDMA_CSR_ADDR + 0x4}]
  master_write_32 $master_path $csr_register_addr 0x2

  # Reset ingress SGDMA
  set csr_register_addr [expr {$INGRESS_SGDMA_CSR_ADDR + 0x4}]
  master_write_32 $master_path $csr_register_addr 0x2
}


# Stop both ingress/egress SGDMAs by writing 0x20 to CSRs
proc stop_sgdmas {master_path} {
  global INGRESS_SGDMA_CSR_ADDR
  global EGRESS_SGDMA_CSR_ADDR
  # Stop SGDMA
  set csr_register_addr [expr {$EGRESS_SGDMA_CSR_ADDR + 0x4}]
  master_write_32 $master_path $csr_register_addr 0x20

  # Stop ingress SGDMA
  set csr_register_addr [expr {$INGRESS_SGDMA_CSR_ADDR + 0x4}]
  master_write_32 $master_path $csr_register_addr 0x20
}


# Start both ingress/egress SGDMAs by writing 0x0 to CSRs
proc start_sgdmas {master_path} {
  global INGRESS_SGDMA_CSR_ADDR
  global EGRESS_SGDMA_CSR_ADDR
  # Start egress SGDMA
  set csr_register_addr [expr {$EGRESS_SGDMA_CSR_ADDR + 0x4}]
  master_write_32 $master_path $csr_register_addr 0x00

  # Start ingress SGDMA
  set csr_register_addr [expr {$INGRESS_SGDMA_CSR_ADDR + 0x4}]
  master_write_32 $master_path $csr_register_addr 0x00
}


proc stage_input {input_file master_path} {
  # Initializing rom with input image
  master_write_from_file $master_path $input_file 0x00200000
}


# Adding descriptor to egress streaming mSGDMA
proc queue_egress_descriptor {master_path size} {
  global EGRESS_SGDMA_DESCRIPTOR_ADDR

  # Destination addr
  set csr_register_addr [expr {$EGRESS_SGDMA_DESCRIPTOR_ADDR + 0x4}]
  master_write_32 $master_path $csr_register_addr 0x00280000

  # Length should be 128 bit aligned
  set csr_register_addr [expr {$EGRESS_SGDMA_DESCRIPTOR_ADDR + 0x8}]
  master_write_32 $master_path $csr_register_addr $size

  # Queue descriptor (Writing 0x8000_0000)
  set csr_register_addr [expr {$EGRESS_SGDMA_DESCRIPTOR_ADDR + 0xc}]
  master_write_32 $master_path $csr_register_addr 0x80000000
}


# Adding descriptor to ingress streaming mSGDMA
proc queue_ingress_descriptor {master_path size} {
  global INGRESS_SGDMA_DESCRIPTOR_ADDR

  # Source addr
  master_write_32 $master_path $INGRESS_SGDMA_DESCRIPTOR_ADDR 0x00200000

  # Transfer length in bytes (input size)
  set csr_register_addr [expr {$INGRESS_SGDMA_DESCRIPTOR_ADDR + 0x8}]
  master_write_32 $master_path $csr_register_addr $size

  # Queue descriptor
  set csr_register_addr [expr {$INGRESS_SGDMA_DESCRIPTOR_ADDR + 0xc}]
  master_write_32 $master_path $csr_register_addr 0x80000000
}


# Read output from on-chip memory
proc read_output {master_path output_file size} {
  master_read_to_file $master_path $output_file 0x00280000 $size
}


# Read output from on-chip memory
proc check_inference_count {master_path iteration} {
  global DLA_IP_0_CSR_ADDR
  # Completion counter assert from index
  set completion_counter_assert 0x00000000
  set completion_counter_assert [expr {$completion_counter_assert + $iteration}]
  set formatted_counter_assert [format "0x%08X" $completion_counter_assert]

  # Check what completion counter CSR in HW is set to
  set csr_register_addr [expr {$DLA_IP_0_CSR_ADDR + 0x224}]
  set completion_counter_result [master_read_32 $master_path $csr_register_addr 1]
  puts "Completion counter from HW: $completion_counter_result"
  if {$completion_counter_result != $formatted_counter_assert} {
    error "Error: completion counter should be equal to $formatted_counter_assert but instead is $completion_counter_result"
  }
}


# This process handles creating a binary file from input partition data
proc create_input_bin {partition_data index} {
  set temp_file "chunk_$index.bin"
  set temp_fh [open $temp_file "wb"]
  fconfigure $temp_fh -translation binary
  puts -nonewline $temp_fh $partition_data
  close $temp_fh
  return $temp_file
}


# This process polls a register and returns if assertion is true within a timeout window
proc poll_register {master_path register_addr register_val_assert} {
  # Set timeout to be 30 seconds (in centi-seconds)
  set timeout_count 3000
  while {$timeout_count > 0} {
    set register_val [master_read_32 $master_path $register_addr 1]
    if {$register_val == $register_val_assert} {
      break
    }
    set timeout_count [expr {$timeout_count - 1}]
    after 10
  }
  if {$timeout_count == 0} {
    puts "Register polling timeout. CSR addr: $register_addr = $register_val \nRegister should be = $register_val_assert"
    exit 1
  }
}


# Read inference counter values to get performance
# There is an assumption here that the clk_ddr is attached to 100MHz
proc get_performance {master_path num_inferences use_core_clock} {
  global DLA_IP_0_CSR_ADDR

  # Used to measure throughput
  set csr_register_addr [expr {$DLA_IP_0_CSR_ADDR + 0x240}]
  if {$use_core_clock} {
    set csr_register_addr [expr {$DLA_IP_0_CSR_ADDR + 0x27c}]
  }
  set active_clk_lo [master_read_32 $master_path $csr_register_addr 1]

  set csr_register_addr [expr {$DLA_IP_0_CSR_ADDR + 0x244}]
  if {$use_core_clock} {
    set csr_register_addr [expr {$DLA_IP_0_CSR_ADDR + 0x280}]
  }
  set active_clk_hi [master_read_32 $master_path $csr_register_addr 1]

  set total_active_clk_count [expr { $active_clk_lo | ($active_clk_hi << 32) }]
  set active_clk_count_per_inference [expr {$total_active_clk_count / $num_inferences}]

  # Used to measure latency
  set csr_register_addr [expr {$DLA_IP_0_CSR_ADDR + 0x248}]
  set all_active_clk_lo [master_read_32 $master_path $csr_register_addr 1]

  set csr_register_addr [expr {$DLA_IP_0_CSR_ADDR + 0x24c}]
  set all_active_clk_hi [master_read_32 $master_path $csr_register_addr 1]

  set all_active_clk_count [expr { $all_active_clk_lo | ($all_active_clk_hi << 32) }]
  set all_active_clk_count_per_inference [expr {$all_active_clk_count / $num_inferences}]

  # Core only throughput
  set csr_register_addr [expr {$DLA_IP_0_CSR_ADDR + 0x27c}]
  set core_active_clk_lo [master_read_32 $master_path $csr_register_addr 1]

  set csr_register_addr [expr {$DLA_IP_0_CSR_ADDR + 0x280}]
  set core_active_clk_hi [master_read_32 $master_path $csr_register_addr 1]

  set total_core_active_clk_count [expr { $core_active_clk_lo | ($core_active_clk_hi << 32) }]
  set core_active_clk_count_per_inference [expr {$total_core_active_clk_count / $num_inferences}]

  # Calculate and report total and core clk counts and overall throughput
  set clk_period [expr { 1.0 / 100000000.0 }]
  set final_fps [expr { 1 / ($clk_period * $active_clk_count_per_inference) }]
  set final_latency [expr { 1 / ($clk_period * $all_active_clk_count_per_inference) }]

  puts "Total active clk cycles: 0x$total_active_clk_count"
  puts "Total core active clk cycles (without input and output streamer): 0x$total_core_active_clk_count"
  puts "Final Throughput: $final_fps fps assuming 100MHz clk_ddr"
}


# This checks if the descriptor buffers are full
proc check_descriptor_buffer_full {master_path} {
  global INGRESS_SGDMA_CSR_ADDR
  global EGRESS_SGDMA_CSR_ADDR
  set egress_descriptor_status [master_read_32 $master_path $EGRESS_SGDMA_CSR_ADDR 1]
  set ingress_descriptor_status [master_read_32 $master_path $INGRESS_SGDMA_CSR_ADDR 1]

  if {$egress_descriptor_status & 0x4} {
    error "Egress descriptor is full."
  }
  if {$ingress_descriptor_status & 0x4} {
    error "Ingress descriptor is full."
  }
}


# Called by main process for functional run
proc main_functional {num_inferences input_file C H W arch_path} {
  global INGRESS_ON_CHIP_MEMORY_SIZE_BYTES
  global EGRESS_ON_CHIP_MEMORY_SIZE_BYTES
  global AXI_STREAM_DATA_WIDTH_BYTES
  global INGRESS_SGDMA_DESCRIPTOR_ADDR
  global EGRESS_SGDMA_DESCRIPTOR_ADDR
  global INGRESS_SGDMA_CSR_ADDR
  global EGRESS_SGDMA_CSR_ADDR
  global DLA_IP_0_CSR_ADDR


  puts "Running functional inference on DDR-Free Design Example"
  puts "________________________________________________________________________________\n"
  puts "Output shape of graph: \[$C $H $W]"

  set cvec [parse_cvec $arch_path]
  puts "c_vector from $arch_path: $cvec"

  # Validating script arguments. Return input file size in bytes
  set file_size [validate_args $input_file $num_inferences]
  set file_size_hex [format "0x%X" $file_size]

  # Make sure the input file can fit into on-chip memory
  if {$file_size > $INGRESS_ON_CHIP_MEMORY_SIZE_BYTES} {
    puts "Input file '$input_file' is too large to fully fit into on-chip memory of size $INGRESS_ON_CHIP_MEMORY_SIZE_BYTES bytes. Input file will be partitioned and transferred partially.\n"
  }

  # Calculate # of AXI transfers from FPGA AI Suite IP output streamer in bytes
  set output_streamer_transfers [calulate_egress_axi_transfers $C $H $W $cvec]

  puts "Number of inferences: $num_inferences"

  # Claim service path to System Console
  set mpath [lindex [get_service_paths master] 0]
  set master_path [claim_service master $mpath ""]

  puts "\n________________________________________________________________________________"
  puts "                    STARTING FPGA AI SUITE INFERENCE                            "
  puts "________________________________________________________________________________\n"

  # Assert resetn using source/probe IP
  assert_reset
  # Initialize coreDLA's CSR registers
  initialize_coredla $master_path

  # Open the input binary file for reading
  for {set i 1} {$i <= $num_inferences} {incr i} {
    # Open input file per iteration due to the potential partioning in the case where input file > INGRESS_ON_CHIP_MEMORY_SIZE_BYTES.
    set input_fh [open $input_file "rb"]
    fconfigure $input_fh -translation binary

    # Create an output file every iteration of inferences
    set combined_fh [open "output$i.bin" "wb"]
    fconfigure $combined_fh -translation binary

    # Logic to ensure input image can fully fit into ingress on-chip memory
    # If not, must partition input data into chunks at a time. This allows us to queue
    # descriptors for partial input sizes.
    set num_input_partition [expr {int(($file_size + $INGRESS_ON_CHIP_MEMORY_SIZE_BYTES - 1) / $INGRESS_ON_CHIP_MEMORY_SIZE_BYTES)}]
    for {set j 0} {$j < $num_input_partition} {incr j} {
      set offset [expr {$j * $INGRESS_ON_CHIP_MEMORY_SIZE_BYTES}]
      set size [
        expr {($file_size - $offset) < $INGRESS_ON_CHIP_MEMORY_SIZE_BYTES ? ($file_size - $offset) : $INGRESS_ON_CHIP_MEMORY_SIZE_BYTES}
      ]

      # Seek to the offset and read the chunk
      # Need to catch an error if offset > file size
      if {[catch {seek $input_fh $offset} err]} {
        puts "Error seeking to offset $offset: $err"
        close $input_fh
        exit 1
      }

      # Begin partioning the input data to INGRESS_ON_CHIP_MEMORY_SIZE_BYTES chunks
      set partition_data [read $input_fh $size]
      set partition_data_file_name [create_input_bin $partition_data $j]
      stage_input $partition_data_file_name $master_path
      queue_ingress_descriptor $master_path $size
      file delete $partition_data_file_name

      # Poll SGDMA register to check if input data streaming is complete
      set sgdma_csr_assert 0x00000002
      poll_register $master_path $INGRESS_SGDMA_CSR_ADDR $sgdma_csr_assert
    }

    close $input_fh

    # Logic to ensure output inference results can fully fit into egress on-chip memory
    # If not, must partition output data into chunks at a time. This allows us to queue
    # descriptors for partial output sizes.
    set num_output_partition [expr {int(($output_streamer_transfers + $EGRESS_ON_CHIP_MEMORY_SIZE_BYTES - 1) / $EGRESS_ON_CHIP_MEMORY_SIZE_BYTES)}]
    for {set j 0} {$j < $num_output_partition} {incr j} {
      set offset [expr {$j * $EGRESS_ON_CHIP_MEMORY_SIZE_BYTES}]
      set size [
        expr {($output_streamer_transfers - $offset) < $EGRESS_ON_CHIP_MEMORY_SIZE_BYTES ? ($output_streamer_transfers - $offset) : $EGRESS_ON_CHIP_MEMORY_SIZE_BYTES}
      ]
      # Queue chunks of EGRESS_ON_CHIP_MEMORY_SIZE_BYTES at a time to ensure a fit in egress on-chip memory
      queue_egress_descriptor $master_path $size

      # Poll SGDMA register to check if output data streaming is complete
      set sgdma_csr_assert 0x00000002
      poll_register $master_path $EGRESS_SGDMA_CSR_ADDR $sgdma_csr_assert

      # Write a partition of the inference result to the partition file
      set output_file "partition_out_$j.bin"
      read_output $master_path $output_file $size

      # Open partioned output inference result
      set bin_fh [open $output_file "rb"]
      fconfigure $bin_fh -translation binary
      set bin_data [read $bin_fh]

      # Append smaller partition of inference result to larger output$i.bin file for inference iteration
      puts -nonewline $combined_fh $bin_data
      close $bin_fh
      file delete $output_file
    }
    # Ensure inference count has gone up
    check_inference_count $master_path $i
    close $combined_fh
  }

  puts "\n$num_inferences inferences successfully completed"
}


# Called by main process for perfromance testing
proc main_performance {input_file C H W measure_core_ip_throughput arch_path} {
  global INGRESS_ON_CHIP_MEMORY_SIZE_BYTES
  global EGRESS_ON_CHIP_MEMORY_SIZE_BYTES
  global AXI_STREAM_DATA_WIDTH_BYTES
  global INGRESS_SGDMA_DESCRIPTOR_ADDR
  global EGRESS_SGDMA_DESCRIPTOR_ADDR
  global INGRESS_SGDMA_CSR_ADDR
  global EGRESS_SGDMA_CSR_ADDR
  global DLA_IP_0_CSR_ADDR

  puts "            Running performance testing on DDR-Free Design Example                "
  puts "________________________________________________________________________________\n"
  puts "Output shape of graph = \[$C $H $W]"

  set cvec [parse_cvec $arch_path]
  puts "c_vector from $arch_path: $cvec"

  # Used to measure performance
  set num_inferences 32
  if {$measure_core_ip_throughput} {
    # Used to measure core ip performance.
    set num_inferences 1
  }

  # Validating script arguments. Return input file size in bytes
  set file_size [validate_args $input_file $num_inferences]
  set file_size_hex [format "0x%X" $file_size]

  # Make sure the input file can fit into on-chip memory
  if {$file_size > $INGRESS_ON_CHIP_MEMORY_SIZE_BYTES} {
    puts "Input file '$input_file' is too large to fully fit into on-chip memory of size
    $INGRESS_ON_CHIP_MEMORY_SIZE_BYTES bytes.\nThe `system_console_script.tcl` file will
    partition the input file for partial transfers to solve this problem but it should not
    be used for performance testing. Please increase the on-chip memory size for performance
    testing.\n"
    exit 1
  }

  # Calculate # of AXI transfers from FPGA AI Suite IP output streamer in bytes
  set output_streamer_transfers [calulate_egress_axi_transfers $C $H $W $cvec]

  # Claim service path to System Console
  set mpath [lindex [get_service_paths master] 0]
  set master_path [claim_service master $mpath ""]

  puts "\n________________________________________________________________________________"
  puts "                    STARTING FPGA AI SUITE INFERENCE                            "
  puts "________________________________________________________________________________\n"


  # Assert resetn using source/probe IP
  assert_reset
  # Stage input file into on-chip memory
  stage_input $input_file $master_path
  # Initialize coreDLA's CSR registers
  initialize_coredla $master_path
  stop_sgdmas $master_path

  # $num_inferences cannot exceed the descriptor queue FIFO size
  for {set i 1} {$i <= $num_inferences} {incr i} {
    check_descriptor_buffer_full $master_path
    # Queue egress descriptor into mSGDMA
    queue_egress_descriptor $master_path $output_streamer_transfers
    # Queue ingress descriptor into mSGDMA
    queue_ingress_descriptor $master_path $file_size
  }

  set start_core_streaming [expr {$DLA_IP_0_CSR_ADDR + 0x284}]
  if {$measure_core_ip_throughput} {
    # write 0 to DLA_DMA_CSR_OFFSET_START_CORE_STREAMING to block core streaming from starting
    master_write_32 $master_path $start_core_streaming 0
  }
  start_sgdmas $master_path
  if {$measure_core_ip_throughput} {
    # wait for data being piped to dma fifo, then start core streaming
    after 1000
    master_write_32 $master_path $start_core_streaming 1
  }

  # Completion counter should increment to 32 inferences
  set completion_count_reg_addr [expr {$DLA_IP_0_CSR_ADDR + 0x224}]
  set completion_count_reg_assert $num_inferences
  poll_register $master_path $completion_count_reg_addr $completion_count_reg_assert

  # Check to see if egress SGDMA has completed writing to egress on-chip memory
  set sgdma_csr_assert 0x00000002
  poll_register $master_path $EGRESS_SGDMA_CSR_ADDR $sgdma_csr_assert


  get_performance $master_path $num_inferences $measure_core_ip_throughput

  # Read output from on-chip memory
  set output_file "output0.bin"
  read_output $master_path $output_file $output_streamer_transfers

  puts "\n$num_inferences inferences successfully completed"
}
