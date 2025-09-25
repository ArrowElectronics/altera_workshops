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

// The purpose of this module is to provide interfaces that are used across
// multiple modules. If needed, those modules should provide helper functions
// to create param structs from module specific structs that can be used to
// instantiate these interfaces.

`include "dla_common_types.svh"

interface pe_array_result_if #(
  dla_interface_pkg::pe_array_result_param_t param
);
  typedef struct packed {
    logic valid;
    logic [param.NUM_LANES-1:0][param.NUM_RESULTS_PER_CYCLE-1:0]
            [param.NUM_FEATURES-1:0][param.RESULT_WIDTH-1:0] result;
  } Type;
  Type data;
  modport sender(output data);
  modport receiver(input data);
endinterface

interface pe_array_control_if #(
  dla_interface_pkg::pe_array_control_param_t param
);
  typedef struct packed {
    logic valid;
    logic init_accumulator;
    logic flush_accumulator;
    logic [param.ELTWISE_MULT_CMD_WIDTH-1:0] eltwise_mult_cmd;
    logic [param.RESULT_ID_WIDTH-1:0] result_id;
  } Type;
  Type data;
  modport sender(output data);
  modport receiver(input data);
endinterface

interface input_feeder_feature_if #(
  dla_interface_pkg::input_feeder_feature_param_t param
);
  `BLOCK_TYPE(param.DOT_SIZE, param.FEATURE_WIDTH, param.FEATURE_EXPONENT_WIDTH);
  block_t [param.NUM_LANES-1:0][param.NUM_FEATURES-1:0] data;
  modport sender(output data);
  modport receiver(input data);
endinterface

interface scratchpad_write_addr_if #(
  dla_interface_pkg::scratchpad_param_t param
);
  typedef struct packed {
      logic [param.SCRATCHPAD_MEM_ID_WIDTH-1:0] mem_id;
      logic [param.SCRATCHPAD_MEM_ADDR_WIDTH-1:0] mem_addr;
  } Type;
  Type data;
  modport sender (output data);
  modport receiver (input data);
endinterface

interface scratchpad_read_addr_if #(
  dla_interface_pkg::scratchpad_param_t param
);
  typedef struct packed {
    // The base read address full
    // address to read from.
    logic [param.SCRATCHPAD_FILTER_BASE_ADDR_WIDTH-1:0] filter_base_addr;

    // Same as filter_base_addr but for bias_scale. Synchronous to it. Not
    // used when ENABLE_2X_READ is off. ??
    logic [param.SCRATCHPAD_BIAS_SCALE_BASE_ADDR_WIDTH-1:0] bias_scale_base_addr;
  } Type;
  Type data;
  modport sender (output data);
  modport receiver (input data);
endinterface
