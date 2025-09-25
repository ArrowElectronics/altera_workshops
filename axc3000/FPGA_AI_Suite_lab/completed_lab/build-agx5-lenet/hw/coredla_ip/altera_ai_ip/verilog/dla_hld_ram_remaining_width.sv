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

//this layer deals with "remaining width"
//every width of 10 will fully utilize the physical storage controlled by one physical byte enable signal
//if bits per enable = 32, then 30 bits will fully utilize the storage, and it may be beneficial to special case the 2 remaining bits instead of simply rounding it up to use 10 bits of storage
//this layer also handles the special rules for depth 16k, which is implemented with some mix of 4k x 5 (best memory utilization) and 16k x 1 (special case remaining width that minimize read mux glue logic)
//likewise this layer also handles the special rules for depth 8k, some mix of 4k x 5 and 8k x 2

`default_nettype none

`include "dla_acl_parameter_assert.svh"

module dla_hld_ram_remaining_width #(
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

    ///////////////////////
    //  Legality checks  //
    ///////////////////////

    generate
    //width / be_width must divide evenly with no remainder
    `DLA_ACL_PARAMETER_ASSERT(WIDTH % BE_WIDTH == 0)
    endgenerate


    ////////////////////////////////////////////
    //  Summary of the remaining width rules  //
    ////////////////////////////////////////////

    //to understand how these rules were created, refer to: //depot/docs/hld/ip/dla_hld_ram introduction algorithm convergence.pptx
    //if true dual port, then depth has been quantized to 1K, so TYPE will be even

    // DEPTH              | TYPE            | strategy
    // -------------------+-----------------+--------------------------------------------------------------------------------
    // 2.5K, 3K, 3.5K     | 5, 6, 7         | if (bits per enable % 10) is nonzero and up to 5, then extract up to width 5 for use in 4k x 5
    // -------------------+-----------------+--------------------------------------------------------------------------------
    // 4.5K, 5K, 5.5K, 6K | 9, 10, 11, 12   | if (bits per enable % 10) is nonzero and up to 2, then extract up to width 2 for use in 8k x 2
    // -------------------+-----------------+--------------------------------------------------------------------------------
    // 6.5K, 7K, 7.5K     | 13, 14, 15      | if (bits per enable % 10) is nonzero and up to 6, then extract up to width 6 for use in 8k x 2
    //                    |                 | exception: if (bits per enable % 10) == 5, then use 4k x 5 instead, implemented by using altera_syncram MAXIMUM_DEPTH
    // -------------------+-----------------+--------------------------------------------------------------------------------
    // 8K                 | 16              | if (bits per enable % 5) is 1, then extract width 6 (or 1) for use in 8k x 2
    //                    |                 | if (bits per enable % 5) is 2, then extract width 2 for use in 8k x 2
    //                    |                 | if (bits per enable % 5) is 3, then extract width 8 (or 3) for use in 8k x 2
    //                    |                 | if (bits per enable % 5) is 4, then extract width 4 for use in 8k x 2
    // -------------------+-----------------+--------------------------------------------------------------------------------
    // multiple of 16K    | multiple of 32  | extract width (bits per enable % 5) for use in 16k x 1
    // -------------------+-----------------+--------------------------------------------------------------------------------
    // any other value    | any other value | do nothing, depth is less than 2K or is a power of 2
    //                    |                 | the layer above separates depth into multiples of 16K, 8K, and leftover



    //////////////////////////
    //  Derived parameters  //
    //////////////////////////

    //determine whether to bypass the functionality in this layer
    localparam bit DEVICE_FAMILY_A10_OR_OLDER = (DEVICE_FAMILY == "Cyclone 10 GX") || (DEVICE_FAMILY == "Arria 10");
    localparam bit CAN_WIDTH_SPLICE = MINIMIZE_MEMORY_USAGE & (RAM_BLOCK_TYPE == "M20K") & DEVICE_FAMILY_A10_OR_OLDER;

    //some math
    localparam int BITS_PER_ENABLE = WIDTH / BE_WIDTH;
    localparam int TYPE = DEPTH / MIN_PHYSICAL_DEPTH;
    localparam int BPE_MOD_TEN = BITS_PER_ENABLE % 10;
    localparam int BPE_MOD_FIVE = BITS_PER_ENABLE % 5;

    //for each depth category, calculate how many bits of remaining width would be extracted
    localparam int EXTRACT_TYPE_5_TO_7   = (BPE_MOD_TEN == 0) ? 0 : (BPE_MOD_TEN <= 5) ? 5 : 0;
    localparam int EXTRACT_TYPE_9_TO_12  = (BPE_MOD_TEN == 0) ? 0 : (BPE_MOD_TEN <= 2) ? 2 : 0;
    localparam int EXTRACT_TYPE_13_TO_15 = (BPE_MOD_TEN == 0) ? 0 : (BPE_MOD_TEN <= 2) ? 2 : (BPE_MOD_TEN <= 4) ? 4 : (BPE_MOD_TEN == 5) ? 5 : (BPE_MOD_TEN == 6) ? 6 : 0;
    localparam int EXTRACT_TYPE_16       = (BPE_MOD_FIVE == 0) ? 0 : (BPE_MOD_FIVE == 1) ? 6 : (BPE_MOD_FIVE == 2) ? 2 : (BPE_MOD_FIVE == 3) ? 8 : 4;
    localparam int EXTRACT_TYPE_MULTI_32 = BPE_MOD_FIVE;

    //given the depth category, determine how many bits of remaining width to extract
    localparam int EXTRACT = (TYPE >= 5 && TYPE <= 7) ? EXTRACT_TYPE_5_TO_7 : (TYPE >= 9 && TYPE <= 12) ? EXTRACT_TYPE_9_TO_12 : (TYPE >= 13 && TYPE <= 15) ? EXTRACT_TYPE_13_TO_15 :
        (TYPE == 16) ? EXTRACT_TYPE_16 : ((TYPE/32)*32 == TYPE) ? EXTRACT_TYPE_MULTI_32 : 0;

    //extraction goes to right side, remaining bits per enable goes to left side
    localparam int RIGHT_BITS_PER_ENABLE = (!CAN_WIDTH_SPLICE) ? 0 : (BITS_PER_ENABLE < EXTRACT) ? BITS_PER_ENABLE : EXTRACT;
    localparam int LEFT_BITS_PER_ENABLE  = BITS_PER_ENABLE - RIGHT_BITS_PER_ENABLE;

    //for next layer in the instantiation hierarchy
    localparam int RIGHT_WIDTH = RIGHT_BITS_PER_ENABLE * BE_WIDTH;
    localparam int LEFT_WIDTH  = LEFT_BITS_PER_ENABLE  * BE_WIDTH;
    localparam int RIGHT_DEPTH = 1 << $clog2(DEPTH);    //round up to nearest power of 2
    localparam bit RIGHT_MINIMIZE_MEMORY_USAGE = (RIGHT_DEPTH == 16*MIN_PHYSICAL_DEPTH) && (RIGHT_BITS_PER_ENABLE == 5);    //only for depth=8k and width=5, need dla_hld_ram_lower to set altera_syncram MAXIMUM_DEPTH=4096
    localparam     RIGHT_MEM_INIT_NAME = {MEM_INIT_NAME, "r"};
    localparam     LEFT_MEM_INIT_NAME = {MEM_INIT_NAME, "l"};



    /////////////////////////////
    //  Width splice the data  //
    /////////////////////////////

    // note this is a width SPLICE, not a width stitch
    // within each bits per enable group, separate the left and right parts
    // then for all groups, stitch all the left parts together, and stitch all the right parts together

    logic [RIGHT_WIDTH-1:0] right_a_writedata, right_b_writedata, right_a_readdata, right_b_readdata;
    logic [LEFT_WIDTH-1:0]  left_a_writedata,  left_b_writedata,  left_a_readdata,  left_b_readdata;

    generate
    if (RIGHT_BITS_PER_ENABLE == 0) begin : DATA_LEFT_ONLY
        assign left_a_writedata = a_writedata;
        assign left_b_writedata = b_writedata;
        assign a_readdata = left_a_readdata;
        assign b_readdata = left_b_readdata;
    end
    else if (LEFT_BITS_PER_ENABLE == 0) begin : DATA_RIGHT_ONLY
        assign right_a_writedata = a_writedata;
        assign right_b_writedata = b_writedata;
        assign a_readdata = right_a_readdata;
        assign b_readdata = right_b_readdata;
    end
    else begin : DATA_LEFT_AND_RIGHT
        always_comb begin
            for (int i=0; i<BE_WIDTH; i++) begin
                {left_a_writedata[LEFT_BITS_PER_ENABLE*i +: LEFT_BITS_PER_ENABLE], right_a_writedata[RIGHT_BITS_PER_ENABLE*i +: RIGHT_BITS_PER_ENABLE]} = a_writedata[BITS_PER_ENABLE*i +: BITS_PER_ENABLE];
                {left_b_writedata[LEFT_BITS_PER_ENABLE*i +: LEFT_BITS_PER_ENABLE], right_b_writedata[RIGHT_BITS_PER_ENABLE*i +: RIGHT_BITS_PER_ENABLE]} = b_writedata[BITS_PER_ENABLE*i +: BITS_PER_ENABLE];
                a_readdata[BITS_PER_ENABLE*i +: BITS_PER_ENABLE] = {left_a_readdata[LEFT_BITS_PER_ENABLE*i +: LEFT_BITS_PER_ENABLE], right_a_readdata[RIGHT_BITS_PER_ENABLE*i +: RIGHT_BITS_PER_ENABLE]};
                b_readdata[BITS_PER_ENABLE*i +: BITS_PER_ENABLE] = {left_b_readdata[LEFT_BITS_PER_ENABLE*i +: LEFT_BITS_PER_ENABLE], right_b_readdata[RIGHT_BITS_PER_ENABLE*i +: RIGHT_BITS_PER_ENABLE]};
            end
        end
    end
    endgenerate



    /////////////////////////////////////////////////
    //  Next layer in the instantiation hierarchy  //
    /////////////////////////////////////////////////

    //imitate the query functions in the software model
    // synthesis translate_off
    int NUM_PHYSICAL_M20K, NUM_PHYSICAL_MLAB;
    int RIGHT_NUM_PHYSICAL_M20K, RIGHT_NUM_PHYSICAL_MLAB;
    int LEFT_NUM_PHYSICAL_M20K, LEFT_NUM_PHYSICAL_MLAB;
    assign NUM_PHYSICAL_M20K = RIGHT_NUM_PHYSICAL_M20K + LEFT_NUM_PHYSICAL_M20K;
    assign NUM_PHYSICAL_MLAB = RIGHT_NUM_PHYSICAL_MLAB + LEFT_NUM_PHYSICAL_MLAB;
    // synthesis translate_on

    generate
    if (RIGHT_BITS_PER_ENABLE) begin : GEN_RIGHT
        dla_hld_ram_bits_per_enable
        #(
            .DEPTH                  (RIGHT_DEPTH),                  //changed
            .WIDTH                  (RIGHT_WIDTH),                  //changed
            .BE_WIDTH               (BE_WIDTH),
            .MINIMIZE_MEMORY_USAGE  (RIGHT_MINIMIZE_MEMORY_USAGE),  //changed
            .MIN_PHYSICAL_DEPTH     (MIN_PHYSICAL_DEPTH),
            .USE_MEM_INIT_FILE      (USE_MEM_INIT_FILE),
            .ZERO_INITIALIZE_MEM    (ZERO_INITIALIZE_MEM),
            .MEM_INIT_NAME          (RIGHT_MEM_INIT_NAME),          //changed
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
        dla_hld_ram_bits_per_enable_inst
        (
            .clock                  (clock),
            .a_address              (a_address),
            .a_read_enable          (a_read_enable),
            .a_write                (a_write),
            .a_writedata            (right_a_writedata),            //changed
            .a_byteenable           (a_byteenable),
            .a_readdata             (right_a_readdata),             //changed
            .a_in_clock_en          (a_in_clock_en),
            .a_out_clock_en         (a_out_clock_en),
            .b_address              (b_address),
            .b_read_enable          (b_read_enable),
            .b_write                (b_write),
            .b_writedata            (right_b_writedata),            //changed
            .b_byteenable           (b_byteenable),
            .b_readdata             (right_b_readdata),             //changed
            .b_in_clock_en          (b_in_clock_en),
            .b_out_clock_en         (b_out_clock_en)
        );

        // synthesis translate_off
        assign RIGHT_NUM_PHYSICAL_M20K = dla_hld_ram_bits_per_enable_inst.NUM_PHYSICAL_M20K;
        assign RIGHT_NUM_PHYSICAL_MLAB = dla_hld_ram_bits_per_enable_inst.NUM_PHYSICAL_MLAB;
        // synthesis translate_on
    end
    else begin : NO_RIGHT
        // synthesis translate_off
        assign RIGHT_NUM_PHYSICAL_M20K = 0;
        assign RIGHT_NUM_PHYSICAL_MLAB = 0;
        // synthesis translate_on
    end
    endgenerate


    generate
    if (LEFT_BITS_PER_ENABLE) begin : GEN_LEFT
        dla_hld_ram_bits_per_enable
        #(
            .DEPTH                  (DEPTH),                        //unlike right this does not change
            .WIDTH                  (LEFT_WIDTH),                   //changed
            .BE_WIDTH               (BE_WIDTH),
            .MINIMIZE_MEMORY_USAGE  (MINIMIZE_MEMORY_USAGE),        //unlike right this does not change
            .MIN_PHYSICAL_DEPTH     (MIN_PHYSICAL_DEPTH),
            .USE_MEM_INIT_FILE      (USE_MEM_INIT_FILE),
            .ZERO_INITIALIZE_MEM    (ZERO_INITIALIZE_MEM),
            .MEM_INIT_NAME          (LEFT_MEM_INIT_NAME),           //changed
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
        dla_hld_ram_bits_per_enable_inst
        (
            .clock                  (clock),
            .a_address              (a_address),
            .a_read_enable          (a_read_enable),
            .a_write                (a_write),
            .a_writedata            (left_a_writedata),             //changed
            .a_byteenable           (a_byteenable),
            .a_readdata             (left_a_readdata),              //changed
            .a_in_clock_en          (a_in_clock_en),
            .a_out_clock_en         (a_out_clock_en),
            .b_address              (b_address),
            .b_read_enable          (b_read_enable),
            .b_write                (b_write),
            .b_writedata            (left_b_writedata),             //changed
            .b_byteenable           (b_byteenable),
            .b_readdata             (left_b_readdata),              //changed
            .b_in_clock_en          (b_in_clock_en),
            .b_out_clock_en         (b_out_clock_en)
        );

        // synthesis translate_off
        assign LEFT_NUM_PHYSICAL_M20K = dla_hld_ram_bits_per_enable_inst.NUM_PHYSICAL_M20K;
        assign LEFT_NUM_PHYSICAL_MLAB = dla_hld_ram_bits_per_enable_inst.NUM_PHYSICAL_MLAB;
        // synthesis translate_on
    end
    else begin : NO_LEFT
        // synthesis translate_off
        assign LEFT_NUM_PHYSICAL_M20K = 0;
        assign LEFT_NUM_PHYSICAL_MLAB = 0;
        // synthesis translate_on
    end
    endgenerate

endmodule

`default_nettype wire
