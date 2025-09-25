// Copyright 2022 Altera Corporation.
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

/// Synchronize a reset to a clock domain. Provide synchronous reset output.
module dla_cdc_reset_sync #(
  parameter int PIPE_STAGES = 0 /// Optional pipe stages to allow retiming
) (
  input  wire  clk,
  input  wire  i_async_resetn,

  output logic o_sync_resetn   /// Reset asserts synchronously, and deasserts synchronous to clk
);

logic w_fully_sync_resetn;

dla_clock_cross_half_sync fully_sync_areset (
  .i_src_data         (i_async_resetn),

  .clk_dst            (clk),
  .i_dst_async_resetn (1'b1),
  .o_dst_data         (w_fully_sync_resetn)
);

if (PIPE_STAGES == 0) begin
  assign o_sync_resetn  = w_fully_sync_resetn;
end else begin
  // Add a small pipeline to synchronous reset to allow retiming on these flops

  // No constraints are needed on r_resetn_sync_pipe because w_fully_sync_resetn is already synchronized.
  logic [PIPE_STAGES-1:0] r_resetn_sync_pipe;   // pipelining added to reset which will be consumed synchronously, retiming should still be allowed on that logic

  // reset pipelining on synchronous reset
  always_ff @(posedge clk) begin     //no reset
    r_resetn_sync_pipe <= {r_resetn_sync_pipe[PIPE_STAGES-2:0], w_fully_sync_resetn};
  end

  assign o_sync_resetn  = r_resetn_sync_pipe [PIPE_STAGES-1];
end

endmodule
