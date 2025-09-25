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

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Objective:
//  The width of a data path signal should be parameter of type "int unsigned", however this causes some complications for width = 0. 
//  When the width parameter is of type "int", the bit indexing is actually [-1:0] which is confusing but legal.
//  However for "int unsigned", verilog spec say mixing signed and unsigned results in unsigned, so -1 unsigned is interpreted as a large number.
//  We provide a macro to clip the width when 0.
//
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

`ifndef DLA_ACL_WIDTH_CLIP_SVH
`define DLA_ACL_WIDTH_CLIP_SVH

`define DLA_ACL_WIDTH_CLIP(WIDTH) (((WIDTH)==0)?0:((WIDTH)-1)):0

`endif

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Example usage:
//
//  `include "dla_acl_width_clip.svh"
//  module my_module #(
//      parameter int unsigned MY_WIDTH
//  ) (
//      output logic [`DLA_ACL_WIDTH_CLIP(MY_WIDTH)] my_signal
//  );
//  localparam int unsigned BYTEENABLE_WIDTH = MY_WIDTH/8;
//  logic [`DLA_ACL_WIDTH_CLIP(BYTEENABLE_WIDTH)] my_byteenable;
//
//  Notes:
//  - if MY_WIDTH == 0, my_signal is declared as [0:0]
//  - if MY_WIDTH >= 1, my_signal is declared as [WIDTH-1:0]
//  - do not include the :0 to select the lower bit range, the macro already includes it
//
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
