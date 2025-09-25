// Copyright 2020-2021 Altera Corporation.
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

`include "dla_common_types.svh"
`include "dla_pe_array_constants.svh"

interface pe_array_feature_if #(
  dla_pe_array_pkg::pe_array_arch_t arch
);
  `BLOCK_TYPE(arch.DOT_SIZE, arch.FEATURE_WIDTH, arch.FEATURE_EXPONENT_WIDTH);
  block_t [arch.NUM_LANES-1:0][arch.NUM_FEATURES-1:0] data;
  modport sender (output data);
  modport receiver (input data);
endinterface

interface pe_array_filter_if #(
  dla_pe_array_pkg::pe_array_arch_t arch
);
  `BLOCK_TYPE_VALID(arch.DOT_SIZE, arch.FILTER_WIDTH, arch.FILTER_EXPONENT_WIDTH);
  block_t [arch.NUM_PES-1:0][arch.NUM_FILTERS-1:0] data;
  modport sender (output data);
  modport receiver (input data);
endinterface

interface pe_array_bias_if #(
  dla_pe_array_pkg::pe_array_arch_t arch
);
  logic [arch.NUM_PES-1:0][arch.NUM_FILTERS-1:0][BIAS_WIDTH-1:0] data;
  modport sender (output data);
  modport receiver (input data);
endinterface

interface pe_array_scale_if #(
  dla_pe_array_pkg::pe_array_arch_t arch
);
  logic [arch.NUM_PES-1:0][arch.NUM_FILTERS-1:0][SCALE_WIDTH-1:0] data;
  modport sender (output data);
  modport receiver (input data);
endinterface

interface pe_feature_if #(
  dla_pe_array_pkg::pe_array_arch_t arch,
  int DIM1 = 1,
  int DIM2 = 1
);
  `BLOCK_TYPE(arch.DOT_SIZE, arch.FEATURE_WIDTH, arch.FEATURE_EXPONENT_WIDTH);
  block_t [arch.NUM_FEATURES-1:0] data [DIM1][DIM2];
  modport sender(output data);
  modport receiver(input data);
endinterface

interface pe_filter_if #(
  dla_pe_array_pkg::pe_array_arch_t arch,
  int DIM1 = 1,
  int DIM2 = 1
);
  `BLOCK_TYPE_VALID(arch.DOT_SIZE, arch.FILTER_WIDTH, arch.FILTER_EXPONENT_WIDTH);
  block_t [arch.NUM_FILTERS-1:0] data [DIM1][DIM2];
  modport sender(output data);
  modport receiver(input data);
endinterface

interface pe_bias_if #(
  dla_pe_array_pkg::pe_array_arch_t arch,
  int DIM1 = 1,
  int DIM2 = 1
);
  logic [arch.NUM_FILTERS-1:0][BIAS_WIDTH-1:0] data [DIM1][DIM2];
  modport sender(output data);
  modport receiver(input data);
endinterface

interface pe_scale_if #(
  dla_pe_array_pkg::pe_array_arch_t arch,
  int DIM1 = 1,
  int DIM2 = 1
);
  logic [arch.NUM_FILTERS-1:0][SCALE_WIDTH-1:0] data [DIM1][DIM2];
  modport sender(output data);
  modport receiver(input data);
endinterface

interface pe_request_if #(
  dla_pe_array_pkg::pe_array_arch_t arch,
  int DIM1 = 1,
  int DIM2 = 1
);
  typedef struct packed {
    logic valid;
    logic init_accumulator;
    logic flush_accumulator;
    logic [arch.ELTWISE_MULT_CMD_WIDTH-1:0] eltwise_mult_cmd;
    logic [arch.RESULT_ID_WIDTH-1:0] result_id;
  } Type;
  Type data [DIM1][DIM2];
  modport sender(output data);
  modport receiver(input data);
endinterface

interface pe_result_if #(
  dla_pe_array_pkg::pe_array_arch_t arch,
  int DIM1 = 1,
  int DIM2 = 1
);
  typedef struct packed {
    logic valid;
    logic [arch.NUM_RESULTS_PER_CYCLE-1:0][arch.NUM_FEATURES-1:0][RESULT_WIDTH-1:0] result;
  } Type;
  Type data [DIM1][DIM2];
  modport sender(output data);
  modport receiver(input data);
endinterface
