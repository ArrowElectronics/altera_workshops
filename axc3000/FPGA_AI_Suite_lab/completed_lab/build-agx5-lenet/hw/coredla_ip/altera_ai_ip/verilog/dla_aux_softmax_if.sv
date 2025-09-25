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

// Port structure from config to control
interface softmax_config_to_control_if #(
  dla_aux_softmax_pkg::aux_special_params_t special_params,
  dla_interface_pkg::aux_data_pack_params_t data_pack_params,
  int DIM1 = 1,
  int DIM2 = 1
);
// ------------------------------ START EDITING ------------------------------
  // localparam TILE_COUNT             = data_pack_params.GROUP_SIZE * data_pack_params.GROUP_NUM;
  localparam CONFIG_ID_BITS         = special_params.CONFIG_ID_WIDTH                ;
  localparam FRAME_SIZE_BITS        = $clog2(special_params.MAX_NUM_CHANNELS     + 1) ;
  localparam DATA_SIZE_BITS         = $clog2(special_params.MAX_NUM_CHANNELS     + 1) ;
  localparam ELEMENT_BITS           = data_pack_params.ELEMENT_BITS                 ;
// ------------------------------  END EDITING  ------------------------------

  typedef struct packed {
// ------------------------------ START EDITING ------------------------------
  logic                                               configured           ;
  //
  logic                  [       FRAME_SIZE_BITS-1:0] frame_size           ;
  logic                  [        DATA_SIZE_BITS-1:0] data_size            ;
  logic                  [        CONFIG_ID_BITS-1:0] config_id            ;
// ------------------------------  END EDITING  ------------------------------
  } Type;
  Type data [DIM1][DIM2];
  modport sender (output data);
  modport receiver (input data);
endinterface

// Port structure from control to lane(s)
interface softmax_control_to_lane_if #(
  dla_aux_softmax_pkg::aux_special_params_t special_params,
  dla_interface_pkg::aux_data_pack_params_t data_pack_params,
  int DIM1 = 1,
  int DIM2 = 1
);
  localparam TILE_COUNT = data_pack_params.GROUP_SIZE * data_pack_params.GROUP_NUM;
  typedef struct packed {
    // only the handshake signal 'ready' is fixed in this structure, which is used by control to
    // signal that the core is not stalled
    logic ready;
// ------------------------------ START EDITING ------------------------------
      logic sum_mode;
      logic sum_init;
      logic sum_last;
      logic output_enable;
// ------------------------------  END EDITING  ------------------------------
  } Type;
  Type data [DIM1][DIM2];
  modport sender (output data);
  modport receiver (input data);
endinterface
