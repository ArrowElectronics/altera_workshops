
#################################################################################################################
#Update these Global Variables to match your system
#################################################################################################################
set onchip_sram	        0x00000000
set onchip_video_buffer 0x00040000
set cruvi_hs_cx_io      0x000501f0
set sysid 		        0x00024060
set rgb_led             0x00024050
set pio_mipi            0x00024040

#################################################################################################################


#################################################################################################################
# Procedures defined below
#################################################################################################################
set all_sp [get_service_paths master]
puts "Found [ llength $all_sp ] masters"
for {set i 0} {$i<[llength $all_sp]} {incr i} {
  set sp($i) [lindex [get_service_paths master] $i]
  puts $sp($i)
  
  if {[ regexp {/phy_.+/jtag} "$sp($i)" ]} {
    set mp "$sp($i)"
    puts "NIOS-V peripheral and SRAM jtag master : $mp"
    open_service master $mp
  }  
}


 
proc h {} {
   #procedure to print help menu
   puts "osm                                - open service"
   puts "csm                                - close service"
   puts "read_sysid                         - read system ID register"
   puts "rgb_led <R|G|B|W|O>                - RGB_LED0 Red|Green|Blue|White|Off"
}

proc csm { } {   
	#procedure to close service master (JTAG master) 
	global mp
	close_service master $mp
}


proc read_sysid { } {
	#quick command to return the system id variable
	global mp sysid
	return [master_read_32 $mp $sysid 1]
}

proc regwr {addr char} {
  global mp
  master_write_32 $mp $addr $char
  #puts "wrote to address: 0x[ format %x [ expr $addr ] ]"
}

proc regrd {addr} {
  global mp
  set rdata [master_read_32 $mp $addr 1]
  puts "readdata: $rdata, from addr: $addr"
  return $rdata
}

# procedure that light on RGB_LED0 HPS GPIO LED base on 3-bit hexadecimal value written
proc rgb_led { color } {
  global mp
  global rgb_led
  if { $color == "R" } {
	master_write_32 $mp $rgb_led 0xFB
    puts "Lit RGB_LED Red"
  } elseif { $color == "G" } {
	master_write_32 $mp $rgb_led 0xFD
    puts "Lit RGB_LED Green"
  } elseif { $color == "B" } {
	master_write_32 $mp $rgb_led 0xFE
    puts "Lit RGB_LED Blue"
  } elseif { $color == "W" } {
	master_write_32 $mp $rgb_led 0xF8
    puts "Lit RGB_LED White"
  } elseif { $color == "O" } {
	master_write_32 $mp $rgb_led 0xFF
    puts "RGB_LED OFF"
  } 
}


# procedure to write random data to incremental address of onchip memory and read back for comparison
proc ram_incr_test {startaddr {count 1}} {
  global mp
  global onchip_sram
  set mm_count 0
  set mt_count 0
  for {set oc 0} {$oc<$count} {incr oc} {
    set dataarray($oc) [ expr {int(rand()*4294967296)} ]
    set addrarray($oc) [ expr $startaddr + [ expr $oc*4 ]]
    master_write_32 $mp [ expr $onchip_sram+$addrarray($oc) ] $dataarray($oc)
  }
  puts "Done writting [expr $oc] set of data into Onchip Memory\n"
  puts "Start reading back for comparison"
  for {set oc 0} {$oc<$count} {incr oc} {
    set data [ master_read_32 $mp  0x[ format %x [ expr $onchip_sram+$addrarray($oc) ] ] 1 ]
    if { $data != "0x[format %8.8x $dataarray($oc)]" } {
      puts "Data mismatch!\nwritten:0x[format %8.8x $dataarray($oc)], read:$data, at address:0x[format %8.8x $addrarray($oc)]\n"
      set mm_count [ expr $mm_count+1 ]
    } else {
      puts "Data($oc) matched: $data\n"
      set mt_count [ expr $mt_count+1 ]
    }
  }
  puts "Total word transferred: $count"
  puts "Data missmatched: $mm_count"
  puts "Data matched    : $mt_count" 
}


# Tests

#set mp [lindex [get_service_paths master] $master_offset]
h
