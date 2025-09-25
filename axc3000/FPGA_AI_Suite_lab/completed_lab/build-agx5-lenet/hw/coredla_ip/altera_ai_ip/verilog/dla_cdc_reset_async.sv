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

/// Synchronize a reset to a clock domain. Provide both asynchronous asserting reset output
/// Both output resets deassert synchronous to clk
module dla_cdc_reset_async (
  input  wire  clk,
  input  wire  i_async_resetn,

  output logic o_async_resetn /// Reset asserts asynchronously with i_async_reset_n, deasserts synchronous to clk
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

assign o_async_resetn = w_resetn;

endmodule
