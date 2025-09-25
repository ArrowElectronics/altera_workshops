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

/// This is a full edge handshake that is guaranteed to transition an edge transition to another clock domain regardless of clock ratio.
/// When an edge transition in the source is detected, this module will deassert ready and start the transfer of the edge to the destination domain
/// The destination domain will acknowledge the edge, and when the source domain receives that acknowledgement it will assert ready.
/// The user is not required to hold the edge, but any requests that occur faster than 4x the clock ratio will not be passed.
/// If you require faster throughput to transfer information between domains, consider a dcfifo
/// NOTE: do not use both async and sync resets at the same time

module dla_clock_cross_edge_handshake #(
  parameter int METASTABILITY_STAGES = 3,    /// Do not change this parameter unless you're absolutely sure you know what you're doing
  parameter type SRC_FLOP_TYPE       = logic /// Do not change this parameter unless you're absolutely sure you know what you're doing
) (
  input  wire clk_src,
  input  wire i_src_async_resetn = 1'b1, /// Asynchronous reset to the source domain input flop. Ensure it deasserts synchronous to clk_src
  input  wire i_src_sync_resetn = 1'b1,  /// Synchronous reset to the source domain input flop. You must not use both async and sync reset.
  input  wire i_src_valid = 1'b1,
  output wire o_src_ready,
  input  wire i_src_data,
  output wire o_src_data,                /// This is a single cycle flop of i_src_data

  input  wire clk_dst,
  input  wire i_dst_async_resetn = 1'b1, /// Asynchronous reset to the destination metastability flops. Ensure it deasserts synchronous to clk_dst
  output wire o_dst_data
);

  logic w_src_data;
  logic w_dst_data;
  logic w_fully_reflected_in_src;

  assign o_dst_data = w_dst_data;
  assign o_src_ready = (w_fully_reflected_in_src == w_src_data);
  assign o_src_data = w_src_data;

  dla_clock_cross_full_sync #(
    .METASTABILITY_STAGES ( METASTABILITY_STAGES ),
    .SRC_FLOP_TYPE        (        SRC_FLOP_TYPE )
  ) u_src_to_dst (
    .clk_src            (clk_src),
    .i_src_async_resetn (i_src_async_resetn),
    .i_src_sync_resetn  (i_src_sync_resetn),
    .i_src_data         (i_src_data),
    .i_src_clock_enable (o_src_ready && i_src_valid),
    .o_src_data         (w_src_data),

    .clk_dst            (clk_dst),
    .i_dst_async_resetn (i_dst_async_resetn),
    .o_dst_data         (w_dst_data)
  );

  dla_clock_cross_half_sync #(
    .METASTABILITY_STAGES ( METASTABILITY_STAGES )
  ) u_dst_to_src (
    .i_src_data         (w_dst_data),

    .clk_dst            (clk_src),
    .i_dst_async_resetn (i_src_async_resetn & i_src_sync_resetn),
    .o_dst_data         (w_fully_reflected_in_src)
  );

endmodule
