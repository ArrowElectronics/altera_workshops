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

//when dla_hld_ram needs to perform a depth stitch, this module is used to decode whether the address targets the top, middle or bottom sections of memory
//a 3:1 depth stitch is decomposed into two 2:1 depth stitches, see comments inside dla_hld_ram_generic_two_way_depth_stitch for the inner workings

`default_nettype none

module dla_hld_ram_generic_three_way_depth_stitch #(
    parameter int TOP_DEPTH,                            //the depth of the top section of memory, this can be zero but the total depth cannot be zero
    parameter int MID_DEPTH,                            //the depth of the middle section of memory, this can be zero but the total depth cannot be zero
    parameter int BOT_DEPTH,                            //the depth of the bottom section of memory, this can be zero but the total depth cannot be zero
    parameter int WIDTH,                                //width of the readdata signals
    parameter bit REGISTER_A_ADDRESS,                   //these 4 parameters controls the read latency, see comments inside dla_hld_ram_generic_two_way_depth_stitch
    parameter bit REGISTER_B_ADDRESS,
    parameter bit REGISTER_A_READDATA,
    parameter bit REGISTER_B_READDATA,

    localparam int DEPTH = TOP_DEPTH + MID_DEPTH + BOT_DEPTH,   //total depth
    localparam int ADDR = (DEPTH <= 1) ? 1 : $clog2(DEPTH), //avoid zero width signals
    localparam int TOP_ADDR = (TOP_DEPTH <= 1) ? 1 : $clog2(TOP_DEPTH),
    localparam int MID_ADDR = (MID_DEPTH <= 1) ? 1 : $clog2(MID_DEPTH),
    localparam int BOT_ADDR = (BOT_DEPTH <= 1) ? 1 : $clog2(BOT_DEPTH)
) (
    input  wire                     clock,

    //port a
    input  wire          [ADDR-1:0] a_address,          //logical address
    input  wire                     a_read_enable,
    input  wire                     a_write,            //logical write enable
    input  wire                     a_in_clock_en,      //logical input clock enable
    input  wire                     a_out_clock_en,     //logical output clock enable
    output logic     [TOP_ADDR-1:0] top_a_address,      //physical address for top memory
    output logic     [MID_ADDR-1:0] mid_a_address,      //physical address for middle memory
    output logic     [BOT_ADDR-1:0] bot_a_address,      //physical address for bottom memory
    output wire                     top_a_read_enable,
    output wire                     mid_a_read_enable,
    output wire                     bot_a_read_enable,
    output logic                    top_a_write,        //physical write enable for top memory
    output logic                    mid_a_write,        //physical write enable for middle memory
    output logic                    bot_a_write,        //physical write enable for bottom memory
    input  wire         [WIDTH-1:0] top_a_readdata,     //physical read data from the top memory
    input  wire         [WIDTH-1:0] mid_a_readdata,     //physical read data from the middle memory
    input  wire         [WIDTH-1:0] bot_a_readdata,     //physical read data from the bottom memory
    output logic        [WIDTH-1:0] a_readdata,         //logical read data

    //port b
    input  wire          [ADDR-1:0] b_address,
    input  wire                     b_read_enable,
    input  wire                     b_write,
    input  wire                     b_in_clock_en,
    input  wire                     b_out_clock_en,
    output logic     [TOP_ADDR-1:0] top_b_address,
    output logic     [MID_ADDR-1:0] mid_b_address,
    output logic     [BOT_ADDR-1:0] bot_b_address,
    output wire                     top_b_read_enable,
    output wire                     mid_b_read_enable,
    output wire                     bot_b_read_enable,
    output logic                    top_b_write,
    output logic                    mid_b_write,
    output logic                    bot_b_write,
    input  wire         [WIDTH-1:0] top_b_readdata,
    input  wire         [WIDTH-1:0] mid_b_readdata,
    input  wire         [WIDTH-1:0] bot_b_readdata,
    output logic        [WIDTH-1:0] b_readdata
);

    localparam MB_DEPTH = MID_DEPTH + BOT_DEPTH;                    //depth of the middle and bottom combined
    localparam MB_ADDR = (MB_DEPTH <= 1) ? 1 : $clog2(MB_DEPTH);    //avoid zero width signals

    logic [MB_ADDR-1:0] mb_a_address, mb_b_address;
    logic mb_a_write, mb_b_write;
    logic [WIDTH-1:0] mb_a_readdata, mb_b_readdata;
    logic mb_a_read_enable;
    logic mb_b_read_enable;



    dla_hld_ram_generic_two_way_depth_stitch #(
        .TOP_DEPTH              (TOP_DEPTH),
        .BOT_DEPTH              (MB_DEPTH),
        .WIDTH                  (WIDTH),
        .REGISTER_A_ADDRESS     (REGISTER_A_ADDRESS),
        .REGISTER_B_ADDRESS     (REGISTER_B_ADDRESS),
        .REGISTER_A_READDATA    (REGISTER_A_READDATA),
        .REGISTER_B_READDATA    (REGISTER_B_READDATA)
    )
    top_inst
    (
        .clock                  (clock),
        .a_address              (a_address),
        .a_read_enable          (a_read_enable),
        .a_write                (a_write),
        .a_in_clock_en          (a_in_clock_en),
        .a_out_clock_en         (a_out_clock_en),
        .top_a_address          (top_a_address),
        .bot_a_address          (mb_a_address),
        .top_a_read_enable      (top_a_read_enable),
        .bot_a_read_enable      (mb_a_read_enable),
        .top_a_write            (top_a_write),
        .bot_a_write            (mb_a_write),
        .top_a_readdata         (top_a_readdata),
        .bot_a_readdata         (mb_a_readdata),
        .a_readdata             (a_readdata),
        .b_address              (b_address),
        .b_read_enable          (b_read_enable),
        .b_write                (b_write),
        .b_in_clock_en          (b_in_clock_en),
        .b_out_clock_en         (b_out_clock_en),
        .top_b_address          (top_b_address),
        .bot_b_address          (mb_b_address),
        .top_b_read_enable      (top_b_read_enable),
        .bot_b_read_enable      (mb_b_read_enable),
        .top_b_write            (top_b_write),
        .bot_b_write            (mb_b_write),
        .top_b_readdata         (top_b_readdata),
        .bot_b_readdata         (mb_b_readdata),
        .b_readdata             (b_readdata)
    );

    dla_hld_ram_generic_two_way_depth_stitch #(
        .TOP_DEPTH              (MID_DEPTH),
        .BOT_DEPTH              (BOT_DEPTH),
        .WIDTH                  (WIDTH),
        .REGISTER_A_ADDRESS     (REGISTER_A_ADDRESS),
        .REGISTER_B_ADDRESS     (REGISTER_B_ADDRESS),
        .REGISTER_A_READDATA    (REGISTER_A_READDATA),
        .REGISTER_B_READDATA    (REGISTER_B_READDATA)
    )
    bottom_inst
    (
        .clock                  (clock),
        .a_address              (mb_a_address),
        .a_read_enable          (mb_a_read_enable),
        .a_write                (mb_a_write),
        .a_in_clock_en          (a_in_clock_en),
        .a_out_clock_en         (a_out_clock_en),
        .top_a_address          (mid_a_address),
        .bot_a_address          (bot_a_address),
        .top_a_read_enable      (mid_a_read_enable),
        .bot_a_read_enable      (bot_a_read_enable),
        .top_a_write            (mid_a_write),
        .bot_a_write            (bot_a_write),
        .top_a_readdata         (mid_a_readdata),
        .bot_a_readdata         (bot_a_readdata),
        .a_readdata             (mb_a_readdata),
        .b_address              (mb_b_address),
        .b_read_enable          (mb_b_read_enable),
        .b_write                (mb_b_write),
        .b_in_clock_en          (b_in_clock_en),
        .b_out_clock_en         (b_out_clock_en),
        .top_b_address          (mid_b_address),
        .bot_b_address          (bot_b_address),
        .top_b_read_enable      (mid_b_read_enable),
        .bot_b_read_enable      (bot_b_read_enable),
        .top_b_write            (mid_b_write),
        .bot_b_write            (bot_b_write),
        .top_b_readdata         (mid_b_readdata),
        .bot_b_readdata         (bot_b_readdata),
        .b_readdata             (mb_b_readdata)
    );

endmodule

`default_nettype wire
