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

`include "dla_aux_activation_constants.svh"

interface control_to_param_cache_if #(
  dla_aux_activation_pkg::aux_special_params_t special_params,
  dla_aux_activation_pkg::aux_data_pack_params_t data_pack_params
);
  localparam PARAM_CACHE_DEPTH    = special_params.PARAM_CACHE_DEPTH;
  localparam PARAM_CACHE_ADDR_RAW = $clog2(PARAM_CACHE_DEPTH);                              // number of address bits for m20k
  localparam PARAM_CACHE_ADDR     = (PARAM_CACHE_ADDR_RAW < 2) ? 2 : PARAM_CACHE_ADDR_RAW;  // minimum size of lfsr
  typedef struct packed {
      logic wr_valid;
      logic [PARAM_CACHE_ADDR-1:0] wr_addr;
      logic [data_pack_params.VECTOR_SIZE-1:0][PARAM_WIDTH-1:0]  wr_data;

      logic rd_ready;
      logic [PARAM_CACHE_ADDR-1:0] rd_addr;
  } Type;
  Type data;
  modport sender (output data);
  modport receiver (input data);
endinterface

interface param_cache_to_control_if #(
  dla_aux_activation_pkg::aux_special_params_t special_params,
  dla_aux_activation_pkg::aux_data_pack_params_t data_pack_params
);
  typedef struct packed {
    logic wr_ready;

    logic rd_valid;
    logic [data_pack_params.VECTOR_SIZE-1:0][PARAM_WIDTH-1:0]  rd_data;
  } Type;
  Type data;
  modport sender (output data);
  modport receiver (input data);
endinterface

// Port structure from config to control
interface activation_config_to_control_if #(
  dla_aux_activation_pkg::aux_special_params_t special_params,
  dla_interface_pkg::aux_data_pack_params_t data_pack_params,
  int DIM1 = 1,
  int DIM2 = 1
);
  typedef struct packed {
// ------------------------------ START EDITING ------------------------------
    logic [data_pack_params.VECTOR_SIZE-1:0][PARAM_WIDTH-1:0]  param;
    logic param_valid;

    logic cmd_valid;
    logic [$clog2(special_params.MAX_TILE_CHANNELS  +1)-1:0]  tile_channels;
    logic [$clog2(special_params.MAX_TILE_HEIGHT +1)-1:0]     tile_height;
    logic [$clog2(special_params.MAX_TILE_WIDTH  +1)-1:0]     tile_width;
    logic [OPERAND_WIDTH-1:0] operand;
// ------------------------------  END EDITING  ------------------------------
  } Type;
  Type data [DIM1][DIM2];
  modport sender (output data);
  modport receiver (input data);
endinterface

// Port structure from control to lane(s)
interface activation_control_to_lane_if #(
  dla_aux_activation_pkg::aux_special_params_t special_params,
  dla_interface_pkg::aux_data_pack_params_t data_pack_params,
  int DIM1 = 1,
  int DIM2 = 1
);
  typedef struct packed {
// ------------------------------ START EDITING ------------------------------
    logic [data_pack_params.VECTOR_SIZE-1:0][PARAM_WIDTH-1:0]  param;
    logic bypass_clamp;                    // bypass the CLAMP block if present
    logic bypass_round_clamp;              // bypass the ROUND_CLAMP block if present
    logic bypass_prelu;                    // bypass the PReLU block if present
    logic bypass_continuous_activations;   // bypass the ContinuousActivations block if present
    logic lrelu_mode;                      // use the PReLU hardware block in LReLU mode (duplicate single parameter)
    logic ready;                           // signal provided to the input buffer to stall
// ------------------------------  END EDITING  ------------------------------
  } Type;
  Type data [DIM1][DIM2];
  modport sender (output data);
  modport receiver (input data);
endinterface
