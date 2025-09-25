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

/// This is a 'full' synchronizer meaning that there is an input flop in the source domain before
/// a 3-stage register chain in the destination domain.
/// Full synchronizers should be used in place of half synchronizers whenever and wherever possible to
/// eliminate the possibility of combinational logic between the source flop and the destination flops
/// A wrapper module is used so that sdc timing constaints can use wildcard matching on the instantiation name.
/// Normally, you should never changes the default METASTABILITY_STAGES to anything but 3 unless you're absolutely
/// sure you know what you're doing

module dla_clock_cross_full_sync #(
  parameter int METASTABILITY_STAGES = 3,    /// Do not change this parameter unless you're absolutely sure you know what you're doing
  parameter type SRC_FLOP_TYPE       = logic /// Do not change this parameter unless you're absolutely sure you know what you're doing
) (
  input  wire clk_src,
  input  wire i_src_async_resetn = 1'b1, /// Asynchronous reset to the source domain input flop. Ensure it resets synchronous to clk_src
  input  wire i_src_sync_resetn = 1'b1,
  input  wire i_src_clock_enable = 1'b1,
  input  wire i_src_data,
  output wire o_src_data,

  input  wire clk_dst,
  input  wire i_dst_async_resetn = 1'b1, /// Asynchronous reset to the destination metastability flops. Ensure it resets synchronous to clk_dst
  output wire o_dst_data
);

  dla_clock_cross_full_sync_internal
  #(
    .WIDTH                (                    1 ),
    .METASTABILITY_STAGES ( METASTABILITY_STAGES ),
    .SRC_FLOP_TYPE        (        SRC_FLOP_TYPE )
  )
  dla_clock_cross_full_sync_special_name_for_sdc_wildcard_matching     //do NOT change this instance name
  (
    .clk_src            (clk_src),
    .i_src_async_resetn (i_src_async_resetn),
    .i_src_sync_resetn  (i_src_sync_resetn),
    .i_src_clock_enable (i_src_clock_enable),
    .i_src_data         (i_src_data),
    .o_src_data         (o_src_data),

    .clk_dst            (clk_dst),
    .i_dst_async_resetn (i_dst_async_resetn),
    .o_dst_data         (o_dst_data)
  );

endmodule
