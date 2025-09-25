// Copyright 2020 Altera Corporation.
//
// This software and the related documents are Altera copyrighted materials,
// and your use of them is governed by the express license under which they
// were provided to you ("License"). Unless the License provides otherwise,
// you may not use, modify, copy, publish, distribute, disclose or transmit
// this software or the related documents without Altera's prior written
// permission.
//
// This software and the related documents are provided as is, with no express
// or implied warranties, other than those that are expressly stated in the
// License.

//see dla_hld_ram.sv for a description of the parameters, ports, and general functionality of all the dla_hld_ram layers

//this module provides a unified interface for MLAB in simple dual port mode, it instantiates altdpram and adds soft logic to support old data mode

`default_nettype none

`include "dla_acl_parameter_assert.svh"

module dla_hld_ram_lower_mlab_simple_dual_port #(
    //geometry of the memory
    parameter  int DEPTH,                   //number of words of memory
    parameter  int WIDTH,                   //width of the data bus, both read and write data
    parameter  int BE_WIDTH,                //width of the byte enable signal, note that WIDTH / BE_WIDTH must divide evenly

    //operation of memory
    parameter      DEVICE_FAMILY,           //"Cyclone 10 GX" | "Arria 10" | "Stratix 10" | "Agilex"
    parameter      READ_DURING_WRITE,       //"DONT_CARE" | "OLD_DATA" | "NEW_DATA"

    //specify whether to register or unregister the read address and the read data
    parameter  bit REGISTER_B_ADDRESS,      //latency from b_address to b_readdata is REGISTER_B_ADDRESS + REGISTER_B_READDATA, can be from 0 to 2 inclusive
    parameter  bit REGISTER_B_READDATA,

    //memory initialization
    parameter  bit USE_MEM_INIT_FILE,       //0 = do not use memory initialization file, 1 = use memory initialization file
    //ZERO_INITIALIZE_MEM is not used since without a memory initialization file, altdpram memory contents always power up to 0
    parameter      MEM_INIT_FILE_NAME,      //if USE_MEM_INIT_FILE = 1, then specify the name of the file that contains the initial memory contents

    //derived parameters that affect the module interface
    localparam int ADDR = $clog2(DEPTH)
) (
    input  wire                 clock,
    //no reset

    //port a
    input  wire      [ADDR-1:0] a_address,          //address for write
    input  wire                 a_write,            //write enable
    input  wire     [WIDTH-1:0] a_writedata,        //data to write to memory
    input  wire  [BE_WIDTH-1:0] a_byteenable,       //which bytes of write data to commit to memory
    input  wire                 a_in_clock_en,      //applies to all inputs of port a: address, write enable, write data, byte enable

    //port b
    input  wire      [ADDR-1:0] b_address,          //address for read
    input  wire                 b_read_enable,
    output logic    [WIDTH-1:0] b_readdata,         //data read from memory
    input  wire                 b_in_clock_en,      //applies to all inputs of port b: address
    input  wire                 b_out_clock_en      //applies to all outputs of port b: read data
);

    //legality checks would be no stricter than what dla_hld_ram_lower already checked for


    //////////////////////////
    //  Derived parameters  //
    //////////////////////////

    localparam int BITS_PER_ENABLE = WIDTH / BE_WIDTH;



    //////////////////////
    //  altdpram ports  //
    //////////////////////

    //add soft logic when hardened logic lacks functionality
    //if byte enables are not used, then altdpram can be used with arbitrary width
    //if mixed port read during write is old data mode, can emulate this by using new data mode and delaying all writes by 1 clock cycle

    logic     [ADDR-1:0] wraddress, rdaddress;
    logic                wren;
    logic [BE_WIDTH-1:0] byteena;
    logic    [WIDTH-1:0] data;
    logic                inclock, outclock;
    logic                outclocken;

    //write enable, byte enable, and write data
    generate
    if (READ_DURING_WRITE == "OLD_DATA") begin  //old data mode is achieved by delaying all writes by 1 clock cycle
        always_ff @(posedge clock) begin
            data      <= a_writedata;
            wraddress <= a_address;
        end
        if (BE_WIDTH == 1) begin    //1 byte enable for the entire data width, don't need to use physical byte enable, combine it with write enable
            always_ff @(posedge clock) begin
                wren <= a_write & a_in_clock_en & a_byteenable;
            end
            assign byteena = 1'b1;
        end
        else begin
            always_ff @(posedge clock) begin
                wren    <= a_write & a_in_clock_en;
                byteena <= a_byteenable;
            end
        end
    end
    else begin  //new data or don't care
        assign data      = a_writedata;
        assign wraddress = a_address;
        if (BE_WIDTH == 1) begin    //1 byte enable for the entire data width, don't need to use physical byte enable, combine it with write enable
            assign wren    = a_write & a_in_clock_en & a_byteenable;
            assign byteena = 1'b1;
        end
        else begin
            assign wren    = a_write & a_in_clock_en;
            assign byteena = a_byteenable;
        end
    end
    endgenerate

    //read address is always implemented in ALM logic in some LAB other than the ones used for data storage, no penalty for using soft logic
    generate
    if (REGISTER_B_ADDRESS) begin
        always_ff @(posedge clock) begin
            if (b_in_clock_en) rdaddress <= b_address;
        end
    end
    else begin
        assign rdaddress = b_address;
    end
    endgenerate


    //////////////<FORCE_TO_ZERO>///////////////
    localparam bit ENABLE_FORCE_TO_ZERO_SOFT_LOGIC = (DEVICE_FAMILY == "Cyclone 10 GX") || (DEVICE_FAMILY == "Arria 10");
    localparam string ENABLE_FORCE_TO_ZERO = ENABLE_FORCE_TO_ZERO_SOFT_LOGIC ? "FALSE" : "TRUE";
    logic b_read_valid;
    logic read_enable_d1;
    if (REGISTER_B_ADDRESS) begin : gen_in_read_enable_flop
      always_ff @(posedge clock) begin
        if (b_in_clock_en) begin
          read_enable_d1 <= b_read_enable;
        end
      end
    end else begin : gen_in_read_enable_wire
      assign read_enable_d1 = b_read_enable;
    end

    if (REGISTER_B_READDATA) begin : gen_out_read_valid_flop
      always_ff @(posedge clock) begin
        if (b_out_clock_en) begin
          b_read_valid <= read_enable_d1;
        end
      end
    end else begin : gen_out_read_valid_wire
      assign b_read_valid = read_enable_d1;
    end
    //////////////</FORCE_TO_ZERO>///////////////

    //clock enable for input: always use soft logic for write port (by masking the write enable), always use soft logic for read port (no penalty for read address to use soft logic)
    assign inclock = clock;

    //clock enable for output: always use hard logic
    generate
    if (!REGISTER_B_READDATA) begin
        assign outclock   = clock;  //ip catalog still connects this even though it is unused, unlike altera_syncram which complains if a clock is unused
        assign outclocken = 1'b1;
    end
    else begin
        assign outclock   = clock;
        assign outclocken = b_out_clock_en;
    end
    endgenerate

    logic [WIDTH-1:0] q;

    ///////////////////////////
    //  altdpram parameters  //
    ///////////////////////////

    localparam int BYTE_SIZE                    = (BE_WIDTH == 1) ? 0 : BITS_PER_ENABLE;
    localparam     INTENDED_DEVICE_FAMILY       = DEVICE_FAMILY;
    localparam     OUTDATA_REG                  = (REGISTER_B_READDATA) ? "OUTCLOCK" : "UNREGISTERED";
    localparam     MIXED_PORT_READ_DURING_WRITE = (READ_DURING_WRITE == "DONT_CARE") ? "DONT_CARE" : "NEW_DATA";
    localparam     MEM_INIT_FILE                = (USE_MEM_INIT_FILE) ? MEM_INIT_FILE_NAME : "UNUSED";



    /////////////////////////
    //  altdpram instance  //
    /////////////////////////

    altdpram
    #(
        //fundamentals
        .lpm_type                           ("altdpram"),
        .ram_block_type                     ("MLAB"),
        .intended_device_family             (INTENDED_DEVICE_FAMILY),

        //clocking
        .indata_reg                         ("INCLOCK"),
        .outdata_reg                        (OUTDATA_REG),
        .rdaddress_reg                      ("UNREGISTERED"),
        .rdcontrol_reg                      ("UNREGISTERED"),
        .wraddress_reg                      ("INCLOCK"),
        .wrcontrol_reg                      ("INCLOCK"),

        //reset is not used
        .indata_aclr                        ("OFF"),
        .rdcontrol_aclr                     ("OFF"),
        .rdaddress_aclr                     ("OFF"),
        .wraddress_aclr                     ("OFF"),
        .wrcontrol_aclr                     ("OFF"),
        .outdata_aclr                       ("OFF"),
        .outdata_sclr                       ("OFF"),

        //size of the memory
        .width                              (WIDTH),
        .widthad                            (ADDR),
        .width_byteena                      (BE_WIDTH),
        .byte_size                          (BYTE_SIZE),

        //mixed port read during write
        .read_during_write_mode_mixed_ports (MIXED_PORT_READ_DURING_WRITE),

        //memory initialization
        .lpm_file                           (MEM_INIT_FILE)
    )
    altdpram_inst
    (
        //write port
        .inclock                            (inclock),
        .inclocken                          (1'b1),
        .data                               (data),
        .wraddress                          (wraddress),
        .wraddressstall                     (1'b0),
        .wren                               (wren),
        .byteena                            (byteena),

        //read port
        .outclock                           (outclock),
        .outclocken                         (outclocken),
        .rdaddress                          (rdaddress),
        .rdaddressstall                     (1'b0),
        .rden                               (1'b1),
        .q                                  (q),

        //no reset
        .aclr                               (1'b0),
        .sclr                               (1'b0)
    );

    assign b_readdata = (b_read_valid ? q : {WIDTH{1'b0}});

endmodule

`default_nettype wire
