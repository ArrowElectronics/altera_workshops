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

//when dla_hld_ram needs to perform a depth stitch, this module is used to decode whether the address targets the top or bottom sections of memory
//this module requires the logical address as the input (which can address the combined depth of the top and bottom)
//this module will output the physical address for the top memory section and the physical address for the bottom memory section
//for the write enable, when doing a depth stitch, the physical write enable needs to be masked if the address does not target that section of memory
//the top/bottom decoding information is kept live so that later when the read data arrives from the top and bottom sections, we know which read data should drive the logical interface

//the implementation assumes two ports (to support true dual port, if simple dual port then Quartus will prune the dangling wires)
//the read data latency (which affects how long to keep the top/bottom decode information live) is per port, for port a the latency is REGISTER_A_ADDRESS + REGISTER_A_READDATA, so 0 to 2 inclusive

`default_nettype none

module dla_hld_ram_generic_two_way_depth_stitch #(
    parameter int TOP_DEPTH,                            //the depth of the top section of memory, this can be zero but the total depth cannot be zero
    parameter int BOT_DEPTH,                            //the depth of the bottom section of memory, this can be zero but the total depth cannot be zero
    parameter int WIDTH,                                //width of the readdata signals
    parameter bit REGISTER_A_ADDRESS,                   //these 4 parameters controls the read latency, see header comment
    parameter bit REGISTER_B_ADDRESS,
    parameter bit REGISTER_A_READDATA,
    parameter bit REGISTER_B_READDATA,

    localparam int DEPTH = TOP_DEPTH + BOT_DEPTH,       //total depth
    localparam int ADDR = (DEPTH <= 1) ? 1 : $clog2(DEPTH), //avoid zero width signals
    localparam int TOP_ADDR = (TOP_DEPTH <= 1) ? 1 : $clog2(TOP_DEPTH),
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
    output logic     [BOT_ADDR-1:0] bot_a_address,      //physical address for bottom memory
    output logic                    top_a_read_enable,
    output logic                    bot_a_read_enable,
    output logic                    top_a_write,        //physical write enable for top memory
    output logic                    bot_a_write,        //physical write enable for bottom memory
    input  wire         [WIDTH-1:0] top_a_readdata,     //physical read data from the top memory
    input  wire         [WIDTH-1:0] bot_a_readdata,     //physical read data from the bottom memory
    output logic        [WIDTH-1:0] a_readdata,         //logical read data

    //port b
    input  wire          [ADDR-1:0] b_address,
    input  wire                     b_read_enable,
    input  wire                     b_write,
    input  wire                     b_in_clock_en,
    input  wire                     b_out_clock_en,
    output logic     [TOP_ADDR-1:0] top_b_address,
    output logic     [BOT_ADDR-1:0] bot_b_address,
    output logic                    top_b_read_enable,
    output logic                    bot_b_read_enable,
    output logic                    top_b_write,
    output logic                    bot_b_write,
    input  wire         [WIDTH-1:0] top_b_readdata,
    input  wire         [WIDTH-1:0] bot_b_readdata,
    output logic        [WIDTH-1:0] b_readdata
);

    //decode top or bottom
    logic a_is_bottom, b_is_bottom;
    assign a_is_bottom = (TOP_DEPTH==0) ? 1'b1 : (BOT_DEPTH==0) ? 1'b0 : (a_address >= TOP_DEPTH);
    assign b_is_bottom = (TOP_DEPTH==0) ? 1'b1 : (BOT_DEPTH==0) ? 1'b0 : (b_address >= TOP_DEPTH);
    assign top_a_read_enable = a_read_enable && (!a_is_bottom);
    assign bot_a_read_enable = a_read_enable && ( a_is_bottom);
    assign top_b_read_enable = b_read_enable && (!b_is_bottom);
    assign bot_b_read_enable = b_read_enable && ( b_is_bottom);

    //determine whether to write to top or bottom
    assign top_a_write = a_write & ~a_is_bottom;
    assign bot_a_write = a_write & a_is_bottom;
    assign top_b_write = b_write & ~b_is_bottom;
    assign bot_b_write = b_write & b_is_bottom;

    //determine the address to provide for top and bottom
    logic [ADDR-1:0] a_address_subtract, b_address_subtract;
    assign a_address_subtract = a_address - TOP_DEPTH;
    assign b_address_subtract = b_address - TOP_DEPTH;
    assign top_a_address = a_address[TOP_ADDR-1:0];
    assign bot_a_address = a_address_subtract[BOT_ADDR-1:0];
    assign top_b_address = b_address[TOP_ADDR-1:0];
    assign bot_b_address = b_address_subtract[BOT_ADDR-1:0];

    //select the read data
    //because we enable force_to_zero, the read_enable bit will zero out RAMs that are not selected
    //Thus, we simply OR the data to get the read data from the chosen RAM
    assign a_readdata = (TOP_DEPTH==0) ? bot_a_readdata : (BOT_DEPTH==0) ? top_a_readdata : (bot_a_readdata | top_a_readdata);
    assign b_readdata = (TOP_DEPTH==0) ? bot_b_readdata : (BOT_DEPTH==0) ? top_b_readdata : (bot_b_readdata | top_b_readdata);

endmodule

`default_nettype wire
