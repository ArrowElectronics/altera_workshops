#!/usr/bin/env tclsh

variable mpath

variable vvp_vfw_run_addr		0x000c2000 + 0x016C	
variable vvp_vfw_commit_addr	0x000c2000 + 0x0164

global rdata

# AI Interface Register Definitions (Universal Interface)

# Basic control registers (0x00-0x0F)


#variable reg_addr

get_service_paths master
set mpath [lindex [get_service_paths master] 0]

proc read_status { } {
global mpath

  open_service master $mpath
  read_registers
  close_service master $mpath
}
 
proc disable_vfw { } {
global mpath
global vvp_vfw_run_addr
global vvp_vfw_commit_addr
  
  # disable vfw
  master_write_32 $mpath $vvp_vfw_run_addr 0x00000000
  master_write_32 $mpath $vvp_vfw_commit_addr 0x00000000
  
}  

proc vfw_disable {} {
global mpath

  open_service master $mpath
  disable_vfw
  close_service master $mpath
}

proc enable_vfw { } {
global mpath
global vvp_vfw_run_addr
global vvp_vfw_commit_addr


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


proc exportRGB { } {
global mpath

	# export image buffer memory content to a file
	open_service master $mpath
	master_read_to_file $mpath ./vfb_content.rgb 0x80000 196608
	close_service master $mpath
} 
 

