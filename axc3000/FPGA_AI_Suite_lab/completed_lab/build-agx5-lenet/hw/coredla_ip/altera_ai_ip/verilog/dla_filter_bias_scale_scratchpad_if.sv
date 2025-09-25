// Copyright 2021-2021 Altera Corporation.
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

`include "dla_common_types.svh"

interface scratchpad_write_data_if #(
  dla_filter_bias_scale_scratchpad_pkg::filter_bias_scale_scratchpad_arch_t arch
);
  localparam MAX_DATA_WIDTH = dla_filter_bias_scale_scratchpad_pkg::calc_max_data_width(
    .NUM_FILTER_PORTS(arch.NUM_FILTER_PORTS),
    .NUM_FILTER_BLOCKS_PER_MEGABLOCK(arch.NUM_FILTER_BLOCKS_PER_MEGABLOCK),
    .NUM_BIAS_SCALE_PORTS(arch.NUM_BIAS_SCALE_PORTS),
    .NUM_BIAS_SCALE_BLOCKS_PER_MEGABLOCK(arch.NUM_BIAS_SCALE_BLOCKS_PER_MEGABLOCK),
    .MEGABLOCK_WIDTH(arch.MEGABLOCK_WIDTH));
  typedef struct packed {
    logic is_filter; // indicates whether the write data is filter data or bias data
    logic [MAX_DATA_WIDTH-1:0] data;
  } Type;
  Type data;
  modport sender (output data);
  modport receiver (input data);
endinterface

interface scratchpad_read_data_if #(
  dla_filter_bias_scale_scratchpad_pkg::filter_bias_scale_scratchpad_arch_t arch
);
  `BLOCK_TYPE(arch.BLOCK_SIZE, arch.FILTER_WIDTH, arch.FILTER_EXPONENT_WIDTH);
  typedef struct packed {
    struct packed {
      logic valid;
      block_t filter;

      logic  [arch.BIAS_WIDTH-1:0] bias;
      logic [arch.SCALE_WIDTH-1:0] scale;
    } [arch.NUM_PE_PORTS-1:0] ports;
  } Type;
  Type data;
  modport sender (output data);
  modport receiver (input data);
endinterface
