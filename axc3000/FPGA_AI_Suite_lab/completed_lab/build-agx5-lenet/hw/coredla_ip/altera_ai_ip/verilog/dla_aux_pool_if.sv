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
interface pool_config_to_control_if #(
  dla_aux_pool_pkg::aux_special_params_t special_params,
  dla_interface_pkg::aux_data_pack_params_t data_pack_params,
  int DIM1 = 1,
  int DIM2 = 1
);
// ------------------------------ START EDITING ------------------------------
  localparam TILE_COUNT             = data_pack_params.GROUP_SIZE * data_pack_params.GROUP_NUM;
  localparam CONFIG_ID_BITS         = special_params.CONFIG_ID_WIDTH                  ;
  localparam WINDOW_BITS_VERTICAL   = $clog2(special_params.MAX_WINDOW_HEIGHT     + 1);
  localparam WINDOW_BITS_HORIZONTAL = $clog2(special_params.MAX_WINDOW_WIDTH      + 1);
  localparam STRIDE_BITS_VERTICAL   = $clog2(special_params.MAX_STRIDE_VERTICAL   + 1);
  localparam STRIDE_BITS_HORIZONTAL = $clog2(special_params.MAX_STRIDE_HORIZONTAL + 1);
  localparam TILE_BITS_VERTICAL     = $clog2(special_params.MAX_TILE_HEIGHT       + 1);
  localparam TILE_BITS_HORIZONTAL   = $clog2(special_params.MAX_TILE_WIDTH        + 1);
  localparam TILE_BITS_DEPTHWISE    = $clog2(special_params.MAX_TILE_CHANNELS     + 1);
  localparam ELEMENT_BITS           = data_pack_params.ELEMENT_BITS                   ;
// ------------------------------  END EDITING  ------------------------------

  typedef struct packed {
// ------------------------------ START EDITING ------------------------------
    logic                                               configured           ;
    //
    logic                                               padding_ignore       ;
    logic                  [                       1:0] padding_mode         ;
    logic                  [          ELEMENT_BITS-1:0] padding_constant     ;
    logic [TILE_COUNT-1:0] [  TILE_BITS_HORIZONTAL-1:0] tile_horizontal_end  ;
    logic [TILE_COUNT-1:0] [  TILE_BITS_HORIZONTAL-1:0] tile_horizontal_start;
    logic [TILE_COUNT-1:0] [    TILE_BITS_VERTICAL-1:0] tile_vertical_end    ;
    logic [TILE_COUNT-1:0] [    TILE_BITS_VERTICAL-1:0] tile_vertical_start  ;
    logic                  [   TILE_BITS_DEPTHWISE-1:0] tile_channels        ;
    logic                  [  TILE_BITS_HORIZONTAL-1:0] tile_width           ;
    logic                  [    TILE_BITS_VERTICAL-1:0] tile_height          ;
    logic                  [STRIDE_BITS_HORIZONTAL-1:0] stride_horizontal    ;
    logic                  [  STRIDE_BITS_VERTICAL-1:0] stride_vertical      ;
    logic                  [WINDOW_BITS_HORIZONTAL-1:0] window_width         ;
    logic                  [  WINDOW_BITS_VERTICAL-1:0] window_height        ;
    logic                  [        CONFIG_ID_BITS-1:0] config_id            ;
// ------------------------------  END EDITING  ------------------------------
  } Type;
  Type data [DIM1][DIM2];
  modport sender (output data);
  modport receiver (input data);
endinterface

// Port structure from control to lane(s)
interface pool_control_to_lane_if #(
  dla_aux_pool_pkg::aux_special_params_t special_params,
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
    logic line_buff_flush;
    logic line_buff_wait_fill;
    logic is_padding_zone_vert;
    logic is_padding_zone_horiz;
    logic [TILE_COUNT-1:0] [special_params.MAX_WINDOW_HEIGHT-1:0] en_pad_nan_vert  ;
    logic [TILE_COUNT-1:0] [special_params.MAX_WINDOW_HEIGHT-1:0] en_pad_zero_vert ;
    logic [TILE_COUNT-1:0] [special_params.MAX_WINDOW_WIDTH -1:0] en_pad_nan_horiz ;
    logic [TILE_COUNT-1:0] [special_params.MAX_WINDOW_WIDTH -1:0] en_pad_zero_horiz;
    logic stride_valid;
// ------------------------------  END EDITING  ------------------------------
  } Type;
  Type data [DIM1][DIM2];
  modport sender (output data);
  modport receiver (input data);
endinterface
