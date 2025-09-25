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

//this layer depth stitches a multiple of 16k depth, 8k depth, and leftover depth
//there are special rules for handling depth 16k and depth 8k, and by extracting these the general purpose width/depth stitch only needs to consider depth up to 7.5k

`default_nettype none

`include "dla_acl_parameter_assert.svh"

module dla_hld_ram_tall_depth_stitch #(
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
    input  wire                 a_write,
    input  wire     [WIDTH-1:0] a_writedata,
    input  wire  [BE_WIDTH-1:0] a_byteenable,
    output logic    [WIDTH-1:0] a_readdata,
    input  wire                 a_in_clock_en,
    input  wire                 a_out_clock_en,
    input  wire                 a_read_enable,
    output wire                 a_read_valid,

    //port b
    input  wire      [ADDR-1:0] b_address,
    input  wire                 b_write,
    input  wire     [WIDTH-1:0] b_writedata,
    input  wire  [BE_WIDTH-1:0] b_byteenable,
    output logic    [WIDTH-1:0] b_readdata,
    input  wire                 b_in_clock_en,
    input  wire                 b_out_clock_en,
    input  wire                 b_read_enable,
    output wire                 b_read_valid
);

    //no legality checks


    //////////////////////////
    //  Derived parameters  //
    //////////////////////////

    //determine whether to bypass the functionality in this layer
    localparam bit DEVICE_FAMILY_A10_OR_OLDER = (DEVICE_FAMILY == "Cyclone 10 GX") || (DEVICE_FAMILY == "Arria 10");
    localparam bit CAN_DEPTH_STITCH = MINIMIZE_MEMORY_USAGE & (RAM_BLOCK_TYPE == "M20K") & DEVICE_FAMILY_A10_OR_OLDER;

    //rules for depth stitching, if no depth stitching is allowed then all depth goes to the bottom
    localparam int TOP_DEPTH = (!CAN_DEPTH_STITCH) ? 0 : (DEPTH / (32*MIN_PHYSICAL_DEPTH)) * (32*MIN_PHYSICAL_DEPTH);       //extract as many multiples of 16k depth as possible
    localparam int MB_DEPTH  = DEPTH - TOP_DEPTH;                                                                           //leftover depth for middle and bottom
    localparam int MID_DEPTH = (!CAN_DEPTH_STITCH) ? 0 : (MB_DEPTH >= 16*MIN_PHYSICAL_DEPTH) ? 16*MIN_PHYSICAL_DEPTH : 0;   //extract one 8k depth if available
    localparam int BOT_DEPTH = MB_DEPTH - MID_DEPTH;                                                                        //leftover depth for bottom, up to 7.5k

    //memory initialization file name modification
    localparam     TOP_MEM_INIT_NAME = {MEM_INIT_NAME, "_16"};
    localparam     MID_MEM_INIT_NAME = {MEM_INIT_NAME, "_8"};
    localparam     BOT_MEM_INIT_NAME = {MEM_INIT_NAME, "_"};

    //avoid zero width signals
    localparam int TOP_ADDR = (TOP_DEPTH <= 1) ? 1 : $clog2(TOP_DEPTH);
    localparam int MID_ADDR = (MID_DEPTH <= 1) ? 1 : $clog2(MID_DEPTH);
    localparam int BOT_ADDR = (BOT_DEPTH <= 1) ? 1 : $clog2(BOT_DEPTH);



    ////////////////////
    //  Depth stitch  //
    ////////////////////

    //based the depths of the sections (some depths can be 0), determine which section the address targets
    //mask the write enable for all sections that the address does not target
    //keep this decoding information live so that later when the read data arrives, know which section to consume read data from

    logic top_a_write, top_b_write;
    logic mid_a_write, mid_b_write;
    logic bot_a_write, bot_b_write;
    logic [TOP_ADDR-1:0] top_a_address, top_b_address;
    logic [MID_ADDR-1:0] mid_a_address, mid_b_address;
    logic [BOT_ADDR-1:0] bot_a_address, bot_b_address;
    logic top_a_read_enable;
    logic mid_a_read_enable;
    logic bot_a_read_enable;
    logic top_b_read_enable;
    logic mid_b_read_enable;
    logic bot_b_read_enable;
    logic [WIDTH-1:0] top_a_readdata, top_b_readdata;
    logic [WIDTH-1:0] mid_a_readdata, mid_b_readdata;
    logic [WIDTH-1:0] bot_a_readdata, bot_b_readdata;

    dla_hld_ram_generic_three_way_depth_stitch #(
        .TOP_DEPTH              (TOP_DEPTH),
        .MID_DEPTH              (MID_DEPTH),
        .BOT_DEPTH              (BOT_DEPTH),
        .WIDTH                  (WIDTH),
        .REGISTER_A_ADDRESS     (1),
        .REGISTER_B_ADDRESS     (REGISTER_B_ADDRESS),
        .REGISTER_A_READDATA    (REGISTER_A_READDATA),
        .REGISTER_B_READDATA    (REGISTER_B_READDATA)
    )
    dla_hld_ram_generic_three_way_depth_stitch_inst
    (
        .clock                  (clock),
        .a_address              (a_address),
        .a_read_enable          (a_read_enable),
        .a_write                (a_write),
        .a_in_clock_en          (a_in_clock_en),
        .a_out_clock_en         (a_out_clock_en),
        .top_a_address          (top_a_address),
        .mid_a_address          (mid_a_address),
        .bot_a_address          (bot_a_address),
        .top_a_read_enable      (top_a_read_enable),
        .mid_a_read_enable      (mid_a_read_enable),
        .bot_a_read_enable      (bot_a_read_enable),
        .top_a_write            (top_a_write),
        .mid_a_write            (mid_a_write),
        .bot_a_write            (bot_a_write),
        .top_a_readdata         (top_a_readdata),
        .mid_a_readdata         (mid_a_readdata),
        .bot_a_readdata         (bot_a_readdata),
        .a_readdata             (a_readdata),
        .b_address              (b_address),
        .b_read_enable          (b_read_enable),
        .b_write                (b_write),
        .b_in_clock_en          (b_in_clock_en),
        .b_out_clock_en         (b_out_clock_en),
        .top_b_address          (top_b_address),
        .mid_b_address          (mid_b_address),
        .bot_b_address          (bot_b_address),
        .top_b_read_enable      (top_b_read_enable),
        .mid_b_read_enable      (mid_b_read_enable),
        .bot_b_read_enable      (bot_b_read_enable),
        .top_b_write            (top_b_write),
        .mid_b_write            (mid_b_write),
        .bot_b_write            (bot_b_write),
        .top_b_readdata         (top_b_readdata),
        .mid_b_readdata         (mid_b_readdata),
        .bot_b_readdata         (bot_b_readdata),
        .b_readdata             (b_readdata)
    );



    /////////////////////////////////////////////////
    //  Next layer in the instantiation hierarchy  //
    /////////////////////////////////////////////////

    //imitate the query functions in the software model
    // synthesis translate_off
    int NUM_PHYSICAL_M20K, NUM_PHYSICAL_MLAB;
    int TOP_NUM_PHYSICAL_M20K, TOP_NUM_PHYSICAL_MLAB;
    int MID_NUM_PHYSICAL_M20K, MID_NUM_PHYSICAL_MLAB;
    int BOT_NUM_PHYSICAL_M20K, BOT_NUM_PHYSICAL_MLAB;
    assign NUM_PHYSICAL_M20K = TOP_NUM_PHYSICAL_M20K + MID_NUM_PHYSICAL_M20K + BOT_NUM_PHYSICAL_M20K;
    assign NUM_PHYSICAL_MLAB = TOP_NUM_PHYSICAL_MLAB + MID_NUM_PHYSICAL_MLAB + BOT_NUM_PHYSICAL_MLAB;
    // synthesis translate_on

    generate
    if (TOP_DEPTH) begin : GEN_TOP
        dla_hld_ram_remaining_width
        #(
            .DEPTH                  (TOP_DEPTH),                //changed
            .WIDTH                  (WIDTH),
            .BE_WIDTH               (BE_WIDTH),
            .MINIMIZE_MEMORY_USAGE  (MINIMIZE_MEMORY_USAGE),
            .MIN_PHYSICAL_DEPTH     (MIN_PHYSICAL_DEPTH),
            .USE_MEM_INIT_FILE      (USE_MEM_INIT_FILE),
            .ZERO_INITIALIZE_MEM    (ZERO_INITIALIZE_MEM),
            .MEM_INIT_NAME          (TOP_MEM_INIT_NAME),        //changed
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
        dla_hld_ram_remaining_width_inst
        (
            .clock                  (clock),
            .a_address              (top_a_address),            //changed
            .a_read_enable          (top_a_read_enable),
            .a_write                (top_a_write),              //changed
            .a_writedata            (a_writedata),
            .a_byteenable           (a_byteenable),
            .a_readdata             (top_a_readdata),           //changed
            .a_in_clock_en          (a_in_clock_en),
            .a_out_clock_en         (a_out_clock_en),
            .b_address              (top_b_address),            //changed
            .b_read_enable          (top_b_read_enable),
            .b_write                (top_b_write),              //changed
            .b_writedata            (b_writedata),
            .b_byteenable           (b_byteenable),
            .b_readdata             (top_b_readdata),           //changed
            .b_in_clock_en          (b_in_clock_en),
            .b_out_clock_en         (b_out_clock_en)
        );

        // synthesis translate_off
        assign TOP_NUM_PHYSICAL_M20K = dla_hld_ram_remaining_width_inst.NUM_PHYSICAL_M20K;
        assign TOP_NUM_PHYSICAL_MLAB = dla_hld_ram_remaining_width_inst.NUM_PHYSICAL_MLAB;
        // synthesis translate_on
    end
    else begin : NO_TOP
        // synthesis translate_off
        assign TOP_NUM_PHYSICAL_M20K = 0;
        assign TOP_NUM_PHYSICAL_MLAB = 0;
        // synthesis translate_on
    end
    endgenerate


    generate
    if (MID_DEPTH) begin : GEN_MID
        dla_hld_ram_remaining_width
        #(
            .DEPTH                  (MID_DEPTH),                //changed
            .WIDTH                  (WIDTH),
            .BE_WIDTH               (BE_WIDTH),
            .MINIMIZE_MEMORY_USAGE  (MINIMIZE_MEMORY_USAGE),
            .MIN_PHYSICAL_DEPTH     (MIN_PHYSICAL_DEPTH),
            .USE_MEM_INIT_FILE      (USE_MEM_INIT_FILE),
            .ZERO_INITIALIZE_MEM    (ZERO_INITIALIZE_MEM),
            .MEM_INIT_NAME          (MID_MEM_INIT_NAME),        //changed
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
        dla_hld_ram_remaining_width_inst
        (
            .clock                  (clock),
            .a_address              (mid_a_address),            //changed
            .a_read_enable          (mid_a_read_enable),
            .a_write                (mid_a_write),              //changed
            .a_writedata            (a_writedata),
            .a_byteenable           (a_byteenable),
            .a_readdata             (mid_a_readdata),           //changed
            .a_in_clock_en          (a_in_clock_en),
            .a_out_clock_en         (a_out_clock_en),
            .b_address              (mid_b_address),            //changed
            .b_read_enable          (mid_b_read_enable),
            .b_write                (mid_b_write),              //changed
            .b_writedata            (b_writedata),
            .b_byteenable           (b_byteenable),
            .b_readdata             (mid_b_readdata),           //changed
            .b_in_clock_en          (b_in_clock_en),
            .b_out_clock_en         (b_out_clock_en)
        );

        // synthesis translate_off
        assign MID_NUM_PHYSICAL_M20K = dla_hld_ram_remaining_width_inst.NUM_PHYSICAL_M20K;
        assign MID_NUM_PHYSICAL_MLAB = dla_hld_ram_remaining_width_inst.NUM_PHYSICAL_MLAB;
        // synthesis translate_on
    end
    else begin : NO_MID
        // synthesis translate_off
        assign MID_NUM_PHYSICAL_M20K = 0;
        assign MID_NUM_PHYSICAL_MLAB = 0;
        // synthesis translate_on
    end
    endgenerate


    generate
    if (BOT_DEPTH) begin : GEN_BOT
        dla_hld_ram_remaining_width
        #(
            .DEPTH                  (BOT_DEPTH),                //changed
            .WIDTH                  (WIDTH),
            .BE_WIDTH               (BE_WIDTH),
            .MINIMIZE_MEMORY_USAGE  (MINIMIZE_MEMORY_USAGE),
            .MIN_PHYSICAL_DEPTH     (MIN_PHYSICAL_DEPTH),
            .USE_MEM_INIT_FILE      (USE_MEM_INIT_FILE),
            .ZERO_INITIALIZE_MEM    (ZERO_INITIALIZE_MEM),
            .MEM_INIT_NAME          (BOT_MEM_INIT_NAME),        //changed
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
        dla_hld_ram_remaining_width_inst
        (
            .clock                  (clock),
            .a_address              (bot_a_address),            //changed
            .a_read_enable          (bot_a_read_enable),
            .a_write                (bot_a_write),              //changed
            .a_writedata            (a_writedata),
            .a_byteenable           (a_byteenable),
            .a_readdata             (bot_a_readdata),           //changed
            .a_in_clock_en          (a_in_clock_en),
            .a_out_clock_en         (a_out_clock_en),
            .b_address              (bot_b_address),            //changed
            .b_read_enable          (bot_b_read_enable),
            .b_write                (bot_b_write),              //changed
            .b_writedata            (b_writedata),
            .b_byteenable           (b_byteenable),
            .b_readdata             (bot_b_readdata),           //changed
            .b_in_clock_en          (b_in_clock_en),
            .b_out_clock_en         (b_out_clock_en)
        );

        // synthesis translate_off
        assign BOT_NUM_PHYSICAL_M20K = dla_hld_ram_remaining_width_inst.NUM_PHYSICAL_M20K;
        assign BOT_NUM_PHYSICAL_MLAB = dla_hld_ram_remaining_width_inst.NUM_PHYSICAL_MLAB;
        // synthesis translate_on
    end
    else begin : NO_BOT
        // synthesis translate_off
        assign BOT_NUM_PHYSICAL_M20K = 0;
        assign BOT_NUM_PHYSICAL_MLAB = 0;
        // synthesis translate_on
    end
    endgenerate

endmodule

`default_nettype wire
