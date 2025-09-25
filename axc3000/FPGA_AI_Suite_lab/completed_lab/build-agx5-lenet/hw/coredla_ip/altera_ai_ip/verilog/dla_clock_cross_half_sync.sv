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

`include "dla_acl_parameter_assert.svh"

// A 3-stage register chain is used to synchronize each bit of a signal into another clock domain.
// A wrapper module is used so that sdc timing constaints can use wildcard matching on the instantiation name.

module dla_clock_cross_half_sync #(
  parameter METASTABILITY_STAGES = 3
) (
  input  wire i_src_data,

  input  wire clk_dst,
  input  wire i_dst_async_resetn,  /// Asynchronous reset to the destination metastability flops. Ensure it resets synchronous to clk_dst
  output wire o_dst_data
);

  dla_clock_cross_half_sync_internal #(
    .WIDTH                (                   1),
    .METASTABILITY_STAGES (METASTABILITY_STAGES)
  )
  dla_clock_cross_half_sync_special_name_for_sdc_wildcard_matching     //do NOT change this instance name
  (
    .i_src_data         (i_src_data),

    .clk_dst            (clk_dst),
    .i_dst_async_resetn (i_dst_async_resetn),
    .o_dst_data         (o_dst_data)
  );

endmodule
