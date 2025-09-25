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

/// This pulse handshake will transfer a posedge or negedge source transition into a pulse on the destination domain

module dla_clock_cross_pulse_handshake #(
  parameter int METASTABILITY_STAGES = 3,     /// Do not change this parameter unless you're absolutely sure you know what you're doing
  parameter type SRC_FLOP_TYPE       = logic, /// Do not change this parameter unless you're absolutely sure you know what you're doing
  parameter bit POSEDGE              = 1      /// 1 for POSEDGE, 0 for NEGEDGE
) (
  input  wire clk_src,
  input  wire i_src_async_resetn = 1'b1, /// Asynchronous reset to the source domain input flop. Ensure it deasserts synchronous to clk_src
  input  wire i_src_sync_resetn = 1'b1, /// Synchronous reset to the source domain input flop. You must not use both async and sync reset.
  input  wire i_src_valid = 1'b1,
  output wire o_src_ready,
  input  wire i_src_data,
  output wire o_src_data,

  input  wire clk_dst,
  input  wire i_dst_async_resetn = 1'b1, /// Asynchronous reset to the destination metastability flops. Ensure it deasserts synchronous to clk_dst
  input  wire i_dst_sync_resetn = 1'b1, /// Synchronous reset to the destination domain reflected input flop. You must not use both async and sync reset.
  output wire o_dst_data
);

  logic w_dst_data;
  logic r_dst_data;

  dla_clock_cross_edge_handshake #(
    .METASTABILITY_STAGES ( METASTABILITY_STAGES ),
    .SRC_FLOP_TYPE        ( SRC_FLOP_TYPE        )
  ) u_edge_handshake (
    .clk_src            (clk_src),
    .i_src_async_resetn (i_src_async_resetn),
    .i_src_sync_resetn  (i_src_sync_resetn),
    .i_src_valid        (i_src_valid),
    .o_src_ready        (o_src_ready),
    .i_src_data         (i_src_data),
    .o_src_data         (o_src_data),

    .clk_dst            (clk_dst),
    .i_dst_async_resetn (i_dst_async_resetn & i_dst_sync_resetn),
    .o_dst_data         (w_dst_data)
  );

  always_ff @(posedge clk_dst or negedge i_dst_async_resetn) begin
    if (i_dst_async_resetn == 1'b0) begin
    end else begin
      r_dst_data <= w_dst_data;
      if (i_dst_sync_resetn == 1'b0) begin
        r_dst_data <= 1'b0;
      end
    end
  end
  assign o_dst_data = {r_dst_data, w_dst_data} == {~POSEDGE, POSEDGE};

endmodule
