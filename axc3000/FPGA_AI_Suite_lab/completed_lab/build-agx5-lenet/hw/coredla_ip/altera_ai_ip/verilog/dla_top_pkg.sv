// Copyright 2015-2020 Altera Corporation.
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

package dla_top_pkg;
  // Width of various axi signals from the axi4 spec
  localparam int AXI_BURST_LENGTH_WIDTH = 8;
  localparam int AXI_BURST_SIZE_WIDTH = 3;
  localparam int AXI_BURST_TYPE_WIDTH = 2;

  // Maximum number of modules connected to the config network
  localparam int CONFIG_NETWORK_MAX_NUM_MODULES = 255;

  // Maximum number of modules connected to the xbar
  localparam int DLA_TOP_XBAR_PARAMETER_ARRAY_SIZE = 17;
endpackage
