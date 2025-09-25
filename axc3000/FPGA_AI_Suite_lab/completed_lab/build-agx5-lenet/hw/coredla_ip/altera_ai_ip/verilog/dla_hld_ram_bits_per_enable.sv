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

//this layer resizes the data and byte enable signals to match what the physical implementation supports

`default_nettype none

`include "dla_acl_parameter_assert.svh"

module dla_hld_ram_bits_per_enable #(
    //geometry configuration
    parameter  int DEPTH,
    parameter  int WIDTH,
    parameter  int BE_WIDTH,

    //geometry constants
    parameter  bit MINIMIZE_MEMORY_USAGE,
    parameter  int MIN_PHYSICAL_DEPTH,

    //memory initialization
    parameter  bit USE_MEM_INIT_FILE,
    parameter  bit ZERO_INITIALIZE_MEM,
    parameter      MEM_INIT_NAME,

    //memory configuration
    parameter      RAM_BLOCK_TYPE,
    parameter      RAM_OPERATION_MODE,
    parameter      DEVICE_FAMILY,
    parameter      READ_DURING_WRITE,
    parameter  bit REGISTER_A_READDATA,
    parameter  bit REGISTER_B_ADDRESS,
    parameter  bit REGISTER_B_READDATA,

    //try to use memory hardened logic
    parameter  bit USE_ENABLE,
    parameter  bit COMMON_IN_CLOCK_EN,
    parameter  bit COMMON_OUT_CLOCK_EN,

    //derived parameters
    localparam int ADDR = $clog2(DEPTH)
) (
    input  wire                 clock,
    //no reset

    //port a
    input  wire      [ADDR-1:0] a_address,
    input  wire                 a_read_enable,
    input  wire                 a_write,
    input  wire     [WIDTH-1:0] a_writedata,
    input  wire  [BE_WIDTH-1:0] a_byteenable,
    output logic    [WIDTH-1:0] a_readdata,
    input  wire                 a_in_clock_en,
    input  wire                 a_out_clock_en,

    //port b
    input  wire      [ADDR-1:0] b_address,
    input  wire                 b_read_enable,
    input  wire                 b_write,
    input  wire     [WIDTH-1:0] b_writedata,
    input  wire  [BE_WIDTH-1:0] b_byteenable,
    output logic    [WIDTH-1:0] b_readdata,
    input  wire                 b_in_clock_en,
    input  wire                 b_out_clock_en
);


    //legality checks
    generate
    //width / be_width must divide evenly with no remainder
    `DLA_ACL_PARAMETER_ASSERT(WIDTH % BE_WIDTH == 0)
    endgenerate



    //this is the physical bits per enable supported by both M20K and MLAB
    //although may instantiate altdpram with bits per enable = 5, it uses twice the number of MLABs, which suggests that only 5 out of every 10 physical bits of storage are actually used
    localparam int PHYSICAL_BITS_PER_ENABLE = 10;

    //for every logical byte enable signal, determine how many physical byte enable signals it drives and how many bits of physical storage it controls
    //for example, if LOGICAL_BITS_PER_ENABLE = 32, the fewest number of 10 bit sections we need is 4, so each logical enable drives 4 physical byte enable signals, and we use 40 bits of physical storage
    localparam int LOGICAL_BITS_PER_ENABLE = WIDTH / BE_WIDTH;
    localparam int PHYSICAL_ENABLES_PER_LOGICAL_ENABLE = (LOGICAL_BITS_PER_ENABLE + PHYSICAL_BITS_PER_ENABLE - 1) / PHYSICAL_BITS_PER_ENABLE;   //this is the 4 in the above example
    localparam int PHYSICAL_STORAGE_PER_LOGICAL_ENABLE = PHYSICAL_ENABLES_PER_LOGICAL_ENABLE * PHYSICAL_BITS_PER_ENABLE;                        //this is the 40 in the above example

    //width of the physical byte enable and data signals
    localparam int PHYSICAL_BE_WIDTH = PHYSICAL_ENABLES_PER_LOGICAL_ENABLE * BE_WIDTH;
    localparam int PHYSICAL_WIDTH = PHYSICAL_STORAGE_PER_LOGICAL_ENABLE * BE_WIDTH;

    //decide the next instantiation layer to use
    localparam bit USE_SHORT_DEPTH_STITCH = MINIMIZE_MEMORY_USAGE && (RAM_BLOCK_TYPE == "M20K");

    //model how much of the physical width is actually used
    localparam bit USE_16K_BY_1 = (DEPTH > 16*MIN_PHYSICAL_DEPTH) && !MINIMIZE_MEMORY_USAGE;    //depth strictly larger than 8k, note if MINIMIZE_MEMORY_USAGE=1 then depth 16k is implemented with MAXIMUM_DEPTH=4096
    localparam bit USE_8K_BY_2  = (DEPTH > 8*MIN_PHYSICAL_DEPTH) && !MINIMIZE_MEMORY_USAGE;     //depth strictly larger than 4k, note if bits per enable is odd then we are going to waste one bit of storage per enable
    //else use 4k x 5 or shorter/wider, in which case bits per enable needs to be rounded up to the nearest multiple of 5 to model how much RAM is physically used
    localparam int BITS_PER_ENABLE_ROUNDED_UP_TO_NEAREST_MULTIPLE_OF_TWO = ((LOGICAL_BITS_PER_ENABLE+1)/2) * 2;
    localparam int BITS_PER_ENABLE_ROUNDED_UP_TO_NEAREST_MULTIPLE_OF_FIVE = ((LOGICAL_BITS_PER_ENABLE+4)/5) * 5;
    localparam int QUANTIZED_LOGICAL_BITS_PER_ENABLE = (USE_16K_BY_1) ? LOGICAL_BITS_PER_ENABLE : (USE_8K_BY_2) ? BITS_PER_ENABLE_ROUNDED_UP_TO_NEAREST_MULTIPLE_OF_TWO : BITS_PER_ENABLE_ROUNDED_UP_TO_NEAREST_MULTIPLE_OF_FIVE;
    localparam int UTILIZED_WIDTH = QUANTIZED_LOGICAL_BITS_PER_ENABLE * BE_WIDTH;



    logic [PHYSICAL_WIDTH-1:0] physical_a_writedata, physical_b_writedata;
    logic [PHYSICAL_BE_WIDTH-1:0] physical_a_byteenable, physical_b_byteenable;
    logic [PHYSICAL_WIDTH-1:0] physical_a_readdata, physical_b_readdata;

    always_comb begin
        for (int i=0; i<BE_WIDTH; i++) begin
            physical_a_byteenable[PHYSICAL_ENABLES_PER_LOGICAL_ENABLE*i +: PHYSICAL_ENABLES_PER_LOGICAL_ENABLE] = {PHYSICAL_ENABLES_PER_LOGICAL_ENABLE{a_byteenable[i]}};
            physical_b_byteenable[PHYSICAL_ENABLES_PER_LOGICAL_ENABLE*i +: PHYSICAL_ENABLES_PER_LOGICAL_ENABLE] = {PHYSICAL_ENABLES_PER_LOGICAL_ENABLE{b_byteenable[i]}};

            physical_a_writedata[PHYSICAL_STORAGE_PER_LOGICAL_ENABLE*i +: PHYSICAL_STORAGE_PER_LOGICAL_ENABLE] = a_writedata[LOGICAL_BITS_PER_ENABLE*i +: LOGICAL_BITS_PER_ENABLE];
            physical_b_writedata[PHYSICAL_STORAGE_PER_LOGICAL_ENABLE*i +: PHYSICAL_STORAGE_PER_LOGICAL_ENABLE] = b_writedata[LOGICAL_BITS_PER_ENABLE*i +: LOGICAL_BITS_PER_ENABLE];

            a_readdata[LOGICAL_BITS_PER_ENABLE*i +: LOGICAL_BITS_PER_ENABLE] = physical_a_readdata[PHYSICAL_STORAGE_PER_LOGICAL_ENABLE*i +: PHYSICAL_STORAGE_PER_LOGICAL_ENABLE];
            b_readdata[LOGICAL_BITS_PER_ENABLE*i +: LOGICAL_BITS_PER_ENABLE] = physical_b_readdata[PHYSICAL_STORAGE_PER_LOGICAL_ENABLE*i +: PHYSICAL_STORAGE_PER_LOGICAL_ENABLE];
        end
    end



    //imitate the query functions in the software model
    // synthesis translate_off
    int NUM_PHYSICAL_M20K, NUM_PHYSICAL_MLAB;
    // synthesis translate_on


    generate
    if (USE_SHORT_DEPTH_STITCH) begin : GEN_SHORT_DEPTH_STITCH
        dla_hld_ram_short_depth_stitch
        #(
            .DEPTH                  (DEPTH),
            .WIDTH                  (PHYSICAL_WIDTH),           //changed
            .BE_WIDTH               (PHYSICAL_BE_WIDTH),        //changed
            .UTILIZED_WIDTH         (UTILIZED_WIDTH),           //created at this layer
            .MINIMIZE_MEMORY_USAGE  (MINIMIZE_MEMORY_USAGE),
            .MIN_PHYSICAL_DEPTH     (MIN_PHYSICAL_DEPTH),
            .USE_MEM_INIT_FILE      (USE_MEM_INIT_FILE),
            .ZERO_INITIALIZE_MEM    (ZERO_INITIALIZE_MEM),
            .MEM_INIT_NAME          (MEM_INIT_NAME),
            .RAM_BLOCK_TYPE         (RAM_BLOCK_TYPE),
            .RAM_OPERATION_MODE     (RAM_OPERATION_MODE),
            .DEVICE_FAMILY          (DEVICE_FAMILY),
            .READ_DURING_WRITE      (READ_DURING_WRITE),
            .REGISTER_A_READDATA    (REGISTER_A_READDATA),
            .REGISTER_B_ADDRESS     (REGISTER_B_ADDRESS),
            .REGISTER_B_READDATA    (REGISTER_B_READDATA),
            .USE_ENABLE             (USE_ENABLE),
            .COMMON_IN_CLOCK_EN     (COMMON_IN_CLOCK_EN),
            .COMMON_OUT_CLOCK_EN    (COMMON_OUT_CLOCK_EN)
        )
        dla_hld_ram_short_depth_stitch_inst
        (
            .clock                  (clock),
            .a_address              (a_address),
            .a_read_enable          (a_read_enable),
            .a_write                (a_write),
            .a_writedata            (physical_a_writedata),     //changed
            .a_byteenable           (physical_a_byteenable),    //changed
            .a_readdata             (physical_a_readdata),      //changed
            .a_in_clock_en          (a_in_clock_en),
            .a_out_clock_en         (a_out_clock_en),
            .b_address              (b_address),
            .b_read_enable          (b_read_enable),
            .b_write                (b_write),
            .b_writedata            (physical_b_writedata),     //changed
            .b_byteenable           (physical_b_byteenable),    //changed
            .b_readdata             (physical_b_readdata),      //changed
            .b_in_clock_en          (b_in_clock_en),
            .b_out_clock_en         (b_out_clock_en)
        );

        // synthesis translate_off
        assign NUM_PHYSICAL_M20K = dla_hld_ram_short_depth_stitch_inst.NUM_PHYSICAL_M20K;
        assign NUM_PHYSICAL_MLAB = dla_hld_ram_short_depth_stitch_inst.NUM_PHYSICAL_MLAB;
        // synthesis translate_on
    end
    else begin : GEN_LOWER
        dla_hld_ram_lower
        #(
            .DEPTH                  (DEPTH),
            .WIDTH                  (PHYSICAL_WIDTH),           //changed
            .BE_WIDTH               (PHYSICAL_BE_WIDTH),        //changed
            .UTILIZED_WIDTH         (UTILIZED_WIDTH),           //created at this layer
            .MINIMIZE_MEMORY_USAGE  (MINIMIZE_MEMORY_USAGE),
            .MIN_PHYSICAL_DEPTH     (MIN_PHYSICAL_DEPTH),
            .USE_MEM_INIT_FILE      (USE_MEM_INIT_FILE),
            .ZERO_INITIALIZE_MEM    (ZERO_INITIALIZE_MEM),
            .MEM_INIT_NAME          (MEM_INIT_NAME),
            .RAM_BLOCK_TYPE         (RAM_BLOCK_TYPE),
            .RAM_OPERATION_MODE     (RAM_OPERATION_MODE),
            .DEVICE_FAMILY          (DEVICE_FAMILY),
            .READ_DURING_WRITE      (READ_DURING_WRITE),
            .REGISTER_A_READDATA    (REGISTER_A_READDATA),
            .REGISTER_B_ADDRESS     (REGISTER_B_ADDRESS),
            .REGISTER_B_READDATA    (REGISTER_B_READDATA),
            .USE_ENABLE             (USE_ENABLE),
            .COMMON_IN_CLOCK_EN     (COMMON_IN_CLOCK_EN),
            .COMMON_OUT_CLOCK_EN    (COMMON_OUT_CLOCK_EN)
        )
        dla_hld_ram_lower_inst
        (
            .clock                  (clock),
            .a_address              (a_address),
            .a_read_enable          (a_read_enable),
            .a_write                (a_write),
            .a_writedata            (physical_a_writedata),     //changed
            .a_byteenable           (physical_a_byteenable),    //changed
            .a_readdata             (physical_a_readdata),      //changed
            .a_in_clock_en          (a_in_clock_en),
            .a_out_clock_en         (a_out_clock_en),
            .b_address              (b_address),
            .b_read_enable          (b_read_enable),
            .b_write                (b_write),
            .b_writedata            (physical_b_writedata),     //changed
            .b_byteenable           (physical_b_byteenable),    //changed
            .b_readdata             (physical_b_readdata),      //changed
            .b_in_clock_en          (b_in_clock_en),
            .b_out_clock_en         (b_out_clock_en)
        );

        // synthesis translate_off
        assign NUM_PHYSICAL_M20K = dla_hld_ram_lower_inst.NUM_PHYSICAL_M20K;
        assign NUM_PHYSICAL_MLAB = dla_hld_ram_lower_inst.NUM_PHYSICAL_MLAB;
        // synthesis translate_on
    end
    endgenerate


endmodule

`default_nettype wire
