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

/// This module is an internal module for CDC. External code should NOT be instantiating this directly
/// Constraint matching will not be applied by dla_clock_cross_sync.sdc
/// Different bits of the data bus can cross clock domains on different clock cycles.
/// This skew will not show up in simulation. The intended use for a multi-bit signal is one that has been stable
/// for a long time, e.g. software reading back a hardware performance counter long after all the work has finished.
/// A proper multi-bit CDC should be used instead

module dla_clock_cross_half_sync_internal #(
  parameter int WIDTH                = 1, /// Extrodinary care must be take when WIDTH is >1!
  parameter int METASTABILITY_STAGES = 3  /// Do not change this parameter unless you're absolutely sure you know what you're doing
) (
  input  wire [WIDTH-1:0] i_src_data,

  input  wire             clk_dst,
  input  wire             i_dst_async_resetn,
  output wire [WIDTH-1:0] o_dst_data
);

  `DLA_ACL_PARAMETER_ASSERT_MESSAGE(METASTABILITY_STAGES > 1, $sformatf(" %m : METASTABILITY_STAGES must be > 1 %d \n", METASTABILITY_STAGES))
  localparam BODY_META_STAGES = METASTABILITY_STAGES-1;

  //3-stage register chain to synchronize the signal onto clk_dst
  (* altera_attribute = {"-name ADV_NETLIST_OPT_ALLOWED NEVER_ALLOW; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON; -name SYNCHRONIZER_IDENTIFICATION FORCED"} *) logic [WIDTH-1:0] dla_cdc_sync_head;
  (* altera_attribute = {"-name ADV_NETLIST_OPT_ALLOWED NEVER_ALLOW; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON"} *)                                           logic [WIDTH-1:0] dla_cdc_sync_body [BODY_META_STAGES-1:0];
  always_ff @(posedge clk_dst or negedge i_dst_async_resetn) begin
      if (i_dst_async_resetn == 1'b0) begin
        dla_cdc_sync_head <= {WIDTH{1'b0}};
        for (int i=0; i < BODY_META_STAGES; i++) begin
          dla_cdc_sync_body[i] <= {WIDTH{1'b0}};
        end
      end else begin
        dla_cdc_sync_head    <= i_src_data;
        dla_cdc_sync_body[0] <= dla_cdc_sync_head;
        for (int i=1; i < BODY_META_STAGES; i++) begin
          dla_cdc_sync_body[i] <= dla_cdc_sync_body[i-1];
        end
      end
  end

  assign o_dst_data = dla_cdc_sync_body[BODY_META_STAGES-1];

endmodule
