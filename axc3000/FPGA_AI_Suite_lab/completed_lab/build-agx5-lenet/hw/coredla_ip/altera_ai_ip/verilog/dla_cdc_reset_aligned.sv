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

/// Synchronize a reset to a clock domain. Provide both asynchronous asserting and synchronous asserting reset outputs
/// The output asynchronous reset and the synchronous reset will NOT assert at the same time.
/// Both output resets deassert synchronous to clk and on the same cycle
/// The full delay from i_async_resetn to o_sync_resetn is approximately *8 cycles*
module dla_cdc_reset_aligned #(
  parameter PIPE_STAGES = 2 // Number of addition registers to add to sync (and async) reset to allow retiming on o_sync_resetn
) (
  input  wire  clk,
  input  wire  i_async_resetn,

  output logic o_async_resetn, /// Reset asserts asynchronously with i_async_reset_n, deasserts synchronous to clk on the same cycle as o_sync_resetn
  output logic o_sync_resetn   /// Reset asserts synchronously, and deasserts synchronous to clk on the same cycle as o_async_resetn
);

logic w_resetn;

// We instantiate an internal module for custom constraint matching. (The aclr pin gets the -to constraint)
dla_clock_cross_half_sync_internal  #(
  .METASTABILITY_STAGES ( 3 )
) dla_areset_clock_cross_sync_special_name_for_sdc_wildcard_matching (
  .i_src_data         (1'b1),

  .clk_dst            (clk),
  .i_dst_async_resetn (i_async_resetn),
  .o_dst_data         (w_resetn)
);

localparam META_STAGES = 3;

// w_resetn still asserts asynchronously so we have to clean it again to use it in fully synchronous logic

logic w_fully_sync_resetn;

dla_clock_cross_half_sync  #(
  .METASTABILITY_STAGES ( META_STAGES )
) fully_sync_areset (
  .i_src_data         (w_resetn),

  .clk_dst            (clk),
  .i_dst_async_resetn (1'b1),
  .o_dst_data         (w_fully_sync_resetn)
);

// Match the above half sync de-assertion latency

logic [META_STAGES-1:0] r_async_resetn_match_half_sync; // match the pipelining for synchronous reset so that all logic exits from reset on the same clock cycle

always_ff @(posedge clk or negedge w_resetn) begin
  if (w_resetn == 1'b0) begin
    r_async_resetn_match_half_sync <= {META_STAGES{1'b0}};
  end else begin
    r_async_resetn_match_half_sync <= {r_async_resetn_match_half_sync[META_STAGES-2:0], 1'b1};
  end
end

if (PIPE_STAGES == 0) begin
  assign o_async_resetn = r_async_resetn_match_half_sync[META_STAGES-1];
  assign o_sync_resetn  = w_fully_sync_resetn;
end else begin
  // Add a small pipeline to synchronous reset to allow retiming on these flops

  // No constraints are needed on r_resetn_sync_pipe because w_fully_sync_resetn is already synchronized.
  logic [PIPE_STAGES-1:0] r_resetn_sync_pipe;   // pipelining added to reset which will be consumed synchronously, retiming should still be allowed on that logic

  // reset pipelining on synchronous reset
  always_ff @(posedge clk) begin     //no reset
    r_resetn_sync_pipe <= {r_resetn_sync_pipe[PIPE_STAGES-2:0], w_fully_sync_resetn};
  end

  // Again, match the above latency
  logic [PIPE_STAGES-1:0] r_async_resetn_match_sync_pipe; // match the pipelining for synchronous reset so that all logic exits from reset on the same clock cycle

  always_ff @(posedge clk or negedge w_resetn) begin
    if (w_resetn == 1'b0) begin
      r_async_resetn_match_sync_pipe <= {PIPE_STAGES{1'b0}};
    end else begin
      r_async_resetn_match_sync_pipe <= {r_async_resetn_match_sync_pipe[PIPE_STAGES-2:0], r_async_resetn_match_half_sync[META_STAGES-1]};
    end
  end

  // for registers that consume reset _asynchronous assertion_ with synchronous deassert
  assign o_async_resetn = r_async_resetn_match_sync_pipe [PIPE_STAGES-1];

  // for registers that can take synchronous asserting reset. r_resetn_sync_pipe can be replicated and retimed by synthesis safely
  assign o_sync_resetn  = r_resetn_sync_pipe [PIPE_STAGES-1];
end

endmodule
