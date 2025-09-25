// Copyright 2020-2020 Altera Corporation.
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

`resetall
`undefineall
`default_nettype none

module dla_degroup import dla_common_pkg::*; #(
  parameter   int GROUP_NUM                    , // Total number of groups
  parameter   int GROUP_DELAY                  , // Delay between each consecutive groups
  parameter   int WIDTH_IN_ELEMENTS            ,
  parameter   int ELEMENT_WIDTH                ,
  parameter   int OUTPUT_GROUP_DELAY = 0       ,
  localparam  int BUS_WIDTH = WIDTH_IN_ELEMENTS  * ELEMENT_WIDTH
) (
  input  wire   clk,
  input  wire   i_sresetn,

  input  wire  [BUS_WIDTH-1:0] i_data [GROUP_NUM-1:0],
  input  wire                  i_valid,
  output logic                 o_ready,

  output logic [BUS_WIDTH-1:0] o_data [GROUP_NUM-1:0],
  output logic                 o_valid,
  input  wire                  i_ready
);


if (((GROUP_DELAY == 0) && (OUTPUT_GROUP_DELAY == 0)) || (GROUP_NUM == 1)) begin : gen_single

  for (genvar gi=0; gi < GROUP_NUM; gi++) begin : gen_group
    assign o_data[gi] = i_data[gi];
  end
  assign o_ready = i_ready;
  assign o_valid = i_valid;

end else begin : gen_multi
  logic w_input_accept [GROUP_NUM-1:0];
  logic [GROUP_NUM-1:0] w_stall;
  logic [GROUP_NUM-1:0] w_valid;

  assign w_input_accept[0] = i_valid && o_ready;
  logic w_read [GROUP_NUM-1:0];

  for (genvar gi=0; gi < GROUP_NUM; gi++) begin : gen_group
    if (gi < GROUP_NUM-1) begin : gen_forward_input
      dla_delay #(
        .WIDTH (1),
        .DELAY (GROUP_DELAY)
      ) u_delay (
        .clk    ( clk                  ),
        .i_data ( w_input_accept[gi]   ),
        .o_data ( w_input_accept[gi+1] )
      );
      dla_delay #(
        .WIDTH (1),
        .DELAY (OUTPUT_GROUP_DELAY)
      ) u_delay_read (
        .clk    ( clk          ),
        .i_data ( w_read[gi]   ),
        .o_data ( w_read[gi+1] )
      );
    end
    dla_hld_fifo #(
        //basic fifo configuration
        .WIDTH                       ( ELEMENT_WIDTH * WIDTH_IN_ELEMENTS ),
        .DEPTH                       ( GROUP_NUM*GROUP_DELAY+3           ),
        //reset configuration
        .ASYNC_RESET                 ( 0                                 ),
        .SYNCHRONIZE_RESET           ( 0                                 ),

        .USE_STALL_LATENCY_UPSTREAM  ( 0                                 ),
        .USE_STALL_LATENCY_DOWNSTREAM( 0                                 ),

        .RAM_BLOCK_TYPE              ( "MLAB"                            ),

        //fifo selection
        .STYLE                       ( "ms"                              )
    ) u_fifo (
        .clock   ( clk                ),
        .resetn  ( i_sresetn          ),
        .i_valid ( w_input_accept[gi] ),
        .i_data  ( i_data[gi]         ),
        .o_stall ( w_stall[gi]        ),
        .o_valid ( w_valid[gi]        ),
        .o_data  ( o_data[gi]         ),
        .i_stall ( ~w_read[gi]        ),
        .o_empty (                    )
    );
  end

  assign w_read[0] = o_valid & i_ready;
  assign o_ready = ~|w_stall;
  assign o_valid = &w_valid;
end

endmodule
