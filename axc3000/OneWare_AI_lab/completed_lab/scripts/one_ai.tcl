#!/usr/bin/env tclsh

variable mpath
variable one_ai_base_addr

variable vvp_vfw_run_addr		0x0002216C	
variable vvp_vfw_commit_addr	0x00022164
variable pio_2_irq_addr			0x00010400
variable one_ai_base_addr		0x00070000

global rdata

# AI Interface Register Definitions (Universal Interface)

# Basic control registers (0x00-0x0F)

# Address 0: New Image Ready flag
global ONE_AI_NEW_IMAGE_READY      0x00

# Address 1: Number of outputs
global ONE_AI_OUTPUTS_COUNT        0x01

# Address 2: FPS value   
global ONE_AI_FPS                  0x02

# Address 3: Read output data (single value)  
global ONE_AI_OUTPUT_READ          0x03

# Address 4: Read output data (auto-increment)  
global ONE_AI_OUTPUT_READ_AUTO     0x04  

# User position registers (0x10-0x1F)

# Address 16: Current Width & Height position 
global ONE_AI_USER_WIDTH_HEIGHT    0x10

# Address 32: Current Objects & Classes position

# Address 32: Current Objects & Classes position  
global ONE_AI_USER_OBJECTS_CLASSES 0x20

# Output dimensions (0x30-0x3F)

# Address 48: Max Width & Height of outputs
global ONE_AI_OUTPUT_DIMENSIONS    0x30

# Address 64: Max Objects & Classes of outputs
global ONE_AI_OUTPUT_OBJ_CLASSES   0x40  

# CNN Output direct addressing (0x30-0xFF = addresses 48-255)
# Note: No direct addressing available - use write + read or sequential auto-increment

# Address 48: Start of CNN output range (not for direct access)
global ONE_AI_CNN_OUTPUT_BASE      0x30  

# Available addressing methods:
# Method 1: Write offset to 0x20, then read from 0x03
# Method 2: Reset position, then read 0x04 multiple times (each read auto-increments)

#variable reg_addr

get_service_paths master
set mpath [lindex [get_service_paths master] 0]


proc read_ai_register {reg_addr} {
global mpath
global one_ai_base_addr

  set offset [expr {$reg_addr * 4}]
  set rdata [master_read_32 $mpath  [expr {$one_ai_base_addr + $offset}] 1]
}

proc display_ai_status { } {
global mpath
global one_ai_base_addr

#read registers
  set rdata [read_ai_register 0x00]
  puts "New Image Ready: $rdata" 
  set rdata [read_ai_register 0x01]
  puts "Number of outputs: $rdata" 
    set rdata [read_ai_register 0x02]
  puts "FPS value: $rdata" 
 
# Reset position to start from class 0
  master_write_32 $mpath [expr {$one_ai_base_addr + 0x80}] 0x00000000  
  
  after 1
  
  puts "--- CNN Data Values ---" 

  set rdata [read_ai_register 0x04]
  puts "Data 0: $rdata"  
  set rdata [read_ai_register 0x04]
  puts "Data 1: $rdata"  
  set rdata [read_ai_register 0x04]
  puts "Data 2: $rdata"  
  set rdata [read_ai_register 0x04]
  puts "Data 3: $rdata"  
  set rdata [read_ai_register 0x04]
  puts "Data 4: $rdata"  
  set rdata [read_ai_register 0x04]
  puts "Data 5: $rdata"  
  set rdata [read_ai_register 0x04]
  puts "Data 6: $rdata"  
  set rdata [read_ai_register 0x04]
  puts "Data 7: $rdata"  
  set rdata [read_ai_register 0x04]
  puts "Data 8: $rdata"  
  set rdata [read_ai_register 0x04]
  puts "Data 9: $rdata"    
} 

proc read_registers { } {
global mpath
global pio_2_irq_addr

#read registers
  set rdata [master_read_32 $mpath  [expr {$pio_2_irq_addr + 0x00}] 1]
  puts "IRQ Data Register: $rdata"  
  set rdata [master_read_32 $mpath  [expr {$pio_2_irq_addr + 0x04}] 1]
  puts "IRQ Enable Register: $rdata"
  set rdata [master_read_32 $mpath  [expr {$pio_2_irq_addr + 0x08}] 1]
  puts "IRQ Status Register: $rdata" 
}

proc read_status { } {
global mpath

  open_service master $mpath
  read_registers
  close_service master $mpath
}
 
proc disable_vfw { } {
global mpath
global pio_2_irq_addr
global vvp_vfw_run_addr
global vvp_vfw_commit_addr

  # disable pio_2_irq pass thru
  set irq_en_register_addr [expr {$pio_2_irq_addr + 0x04}]
  master_write_32 $mpath $irq_en_register_addr 0x00000000
  
  # disable vfw
  master_write_32 $mpath $vvp_vfw_run_addr 0x00000000
  master_write_32 $mpath $vvp_vfw_commit_addr 0x00000000
  
  # clear irq status
  set irq_status_register_addr [expr {$pio_2_irq_addr + 0x08}]
  master_write_32 $mpath $irq_status_register_addr 0x00000002    
}  

proc vfw_disable {} {
global mpath

  open_service master $mpath
  disable_vfw
  close_service master $mpath
}

proc enable_vfw { } {
global mpath
global pio_2_irq_addr
global vvp_vfw_run_addr
global vvp_vfw_commit_addr

  # enable pio_2_irq pass thru
  set irq_en_register_addr [expr {$pio_2_irq_addr + 0x04}]
  master_write_32 $mpath $irq_en_register_addr 0x00000002

  # enable vfw
  master_write_32 $mpath $vvp_vfw_run_addr 0x00000001
  master_write_32 $mpath $vvp_vfw_commit_addr 0x00000000 
} 

proc vfw_enable {} {
global mpath

  open_service master $mpath
  enable_vfw
  close_service master $mpath
}

proc enable_jfw { } {
global mpath
global pio_2_irq_addr 

  # pio irq source enabled
  set irq_en_register_addr [expr {$pio_2_irq_addr + 0x04}]
  master_write_32 $mpath $irq_en_register_addr 0x00000001
}
 
proc jfw_enable {} {
global mpath

  open_service master $mpath
  enable_jfw
  close_service master $mpath
}

proc disable_jfw { } {
global mpath
global pio_2_irq_addr 

  # pio irq source disabled
  set irq_en_register_addr [expr {$pio_2_irq_addr + 0x04}]
  master_write_32 $mpath $irq_en_register_addr 0x00000000
}
 
proc jfw_disable {} {
global mpath

  open_service master $mpath
  disable_jfw
  close_service master $mpath
}

proc importRGB {chan mpath} {
 
 # write an image from a file to the image buffer memory
  master_write_from_file $mpath $chan 0x00080000
}

proc exportRGB { } {
global mpath

	# export image buffer memory content to a file
	open_service master $mpath
	master_read_to_file $mpath ./vfb_content.rgb 0x00080000 65536
	close_service master $mpath
} 
 
proc paint { } {
global mpath

set chan digit.bin

open_service master $mpath
disable_vfw
enable_jfw
importRGB $chan $mpath
#exportRGB

close_service master $mpath
}

proc camera { } {

vfw_enable
}

