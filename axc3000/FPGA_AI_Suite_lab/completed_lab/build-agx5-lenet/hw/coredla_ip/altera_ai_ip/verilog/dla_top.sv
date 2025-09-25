// Copyright 2015-2021 Altera Corporation.
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

//////////////////////////////////////////////////////////////////////////////
// Top-level coreDLA module (shared between testbench and real hardware)
//////////////////////////////////////////////////////////////////////////////

// Not all AXI ports have been implemented. For assumptions and restrictions, refer to dla/fpga/dma/rtl/dla_dma.sv.
// This module simply exposes the same AXI ports provided by the top module of DMA.

`resetall
`undefineall
`default_nettype none
`include "dla_acl_parameter_assert.svh"

module dla_top

import dla_common_pkg::*, dla_input_feeder_pkg::input_feeder_arch_t, dla_pe_array_pkg::*, dla_top_pkg::*, dla_xbar_pkg::*, dla_aux_activation_pkg::*, dla_aux_pool_pkg::*,
  dla_aux_softmax_pkg::*, dla_aux_depthwise_pkg::*, dla_lt_pkg::*;

#(
  string DEVICE,                    // the device to target, legal values are "A10", "C10", "S10", or "AGX7"

  int CSR_ADDR_WIDTH,               // width of the byte address signal, determines CSR address space size, e.g. 11 bit address = 2048 bytes, the largest size that uses only 1 M20K
  int CSR_DATA_BYTES,               // width of the CSR data path, typically 4 bytes
  int CONFIG_DATA_BYTES,            // data width of the config network output port, typically 4 bytes
  int CONFIG_READER_DATA_BYTES,     // data width of the config network input port, typically 8 bytes
  int FILTER_READER_DATA_BYTES,     // data width of the filter reader, typically a whole DDR word (assuming block floating point, C_VECTOR=16 so 4 filter words packed into 1 DDR word)
  int FEATURE_READER_DATA_BYTES,    // data width of the feature reader, typically half of a DDR word for C_VECTOR=16 (assuming FP16 or smaller)
  int FEATURE_WRITER_DATA_BYTES,    // data width of the feature writer, typically half of a DDR word for C_VECTOR=16 (assuming FP16 or smaller)
  int DDR_ADDR_WIDTH,               // width of all byte address signals to global memory, 32 would allow 4 GB of addressable memory
  int DDR_BURST_WIDTH,              // internal width of the axi burst length signal, typically 4, max number of words in a burst = 2**DDR_BURST_WIDTH
  int DDR_DATA_BYTES,               // width of the global memory data path, typically 64 bytes
  int DDR_READ_ID_WIDTH,            // width of the AXI ID signal for DDR reads, must be 2 since there are 3 read masters
  bit ENABLE_ON_CHIP_PARAMETERS,    // whether the configs, filters are saved on-chip

  // stream buffer
  int KVEC_OVER_CVEC,
  int SB_ADDR_WIDTH,
  int STREAM_BUFFER_DEPTH,

  // pe array
  dla_pe_array_pkg::pe_array_arch_bits_t PE_ARRAY_PARAM_BITS,
  int PE_ARRAY_EXIT_FIFO_DEPTH,

  // filter scratchpad
  int SCRATCHPAD_FILTER_DEPTH,
  int SCRATCHPAD_BIAS_SCALE_DEPTH,
  int SCRATCHPAD_NUM_FILTER_PORTS,
  int SCRATCHPAD_NUM_BIAS_SCALE_PORTS,
  int SCRATCHPAD_MEGABLOCK_WIDTH,
  int SCRATCHPAD_NUM_FILTER_BLOCKS_PER_MEGABLOCK,
  int SCRATCHPAD_NUM_BIAS_SCALE_BLOCKS_PER_MEGABLOCK,

  // config network
  int CONFIG_ID_FILTER_READER,
  int CONFIG_CHANNEL_WIDTH,
  int CONFIG_CACHE_DEPTH,
  int CONFIG_ID_INPUT_FEEDER_MUX,
  int CONFIG_ID_INPUT_FEEDER_WRITER,
  int CONFIG_ID_INPUT_FEEDER_IN,
  int CONFIG_ID_INPUT_FEEDER_READER,
  int CONFIG_ID_INPUT_FEEDER_OUT,
  int CONFIG_ID_FEATURE_WRITER,
  int CONFIG_ID_FEATURE_READER,
  int CONFIG_ID_XBAR,
  int CONFIG_ID_OUTPUT_STREAMER,
  int CONFIG_ID_OUTPUT_STREAMER_FLUSH,
  int CONFIG_ID_WRITER_STREAMER_SEL,
  int CONFIG_ID_LAYOUT_TRANSFORM,

  // aux module config ID
  int CONFIG_ID_ACTIVATION,
  int CONFIG_ID_POOL,
  int CONFIG_ID_DEPTHWISE,
  int CONFIG_ID_DEPTHWISE_FILTER_BIAS,
  int CONFIG_ID_SOFTMAX,

  int CONFIG_NUM_MODULES,
  int MODULE_ID_WIDTH,

  int CONFIG_NETWORK_FIFO_MIN_DEPTH [CONFIG_NETWORK_MAX_NUM_MODULES:1],
  int CONFIG_NETWORK_NUM_PIPELINE_STAGES [CONFIG_NETWORK_MAX_NUM_MODULES:1],
  bit CONFIG_NETWORK_CROSS_CLOCK [CONFIG_NETWORK_MAX_NUM_MODULES:1],
  bit CONFIG_NETWORK_CROSS_CLOCK_AXI [CONFIG_NETWORK_MAX_NUM_MODULES:1],
  int CONFIG_NETWORK_QUANTIZE_DEPTHS [255:0],   //real hardware should set this to {32,512} to fully utilize an MLAB or an M20K, testbench may set this to something smaller to test backpressure

  //xbar
  int MAX_XBAR_INPUT_INTERFACES,
  int MAX_XBAR_OUTPUT_INTERFACES,
  int NUMBER_OF_KERNELS,
  int AUX_MODULE_SELECT_ID_WIDTH,
  int AUX_XBAR_INPUT_COUNTER_WIDTH,
  int AUX_XBAR_OUTPUT_COUNTER_WIDTH,
  int AUX_MAX_DATABUS_WIDTH,
  int AUX_XBAR_OUTPUT_WIDTH, // this is unused/not reference. should remove
  int AUX_OUTPUT_DATA_WIDTHS [DLA_TOP_XBAR_PARAMETER_ARRAY_SIZE-1:0],
  int AUX_INPUT_DATA_WIDTHS  [DLA_TOP_XBAR_PARAMETER_ARRAY_SIZE-1:0],
  bit XBAR_KERNEL_BYPASS_FEATURE_ENABLE,
  int AUX_XBAR_MUX_OUTPUT_PIPELINE_STAGES [DLA_TOP_XBAR_PARAMETER_ARRAY_SIZE-1:0],
  int AUX_XBAR_NONSTALLABLE_OUTPUT_PIPELINE_STAGES [DLA_TOP_XBAR_PARAMETER_ARRAY_SIZE-1:0],
  int AUX_XBAR_OUTPUT_BP_FIFO_ENABLE [DLA_TOP_XBAR_PARAMETER_ARRAY_SIZE-1:0],
  bit AUX_KERNEL_BYPASSABLE  [DLA_TOP_XBAR_PARAMETER_ARRAY_SIZE-1:0],
  int AUX_XBAR_OUTPUT_BP_FIFO_DEPTH [DLA_TOP_XBAR_PARAMETER_ARRAY_SIZE-1:0],
  bit XBAR_KERNEL_CV_FEATURE_ENABLE,
  int AUX_KERNEL_CONNECTIVITY_VECTOR [DLA_TOP_XBAR_PARAMETER_ARRAY_SIZE-1:0][DLA_TOP_XBAR_PARAMETER_ARRAY_SIZE-1:0],

  //xbar id
  int XBAR_ID_ACTIVATION,
  int XBAR_ID_POOL,
  int XBAR_ID_DEPTHWISE,
  int XBAR_ID_SOFTMAX,
  int XBAR_ID_PE_ARRAY,
  int XBAR_ID_XBAR_OUT_PORT,
  //aux module enable
  bit ENABLE_ACTIVATION,
  bit ENABLE_POOL,
  bit ENABLE_DEPTHWISE,
  bit ENABLE_SOFTMAX,

  bit ENABLE_INPUT_STREAMING,
  int AXI_ISTREAM_DATA_WIDTH,
  int AXI_ISTREAM_FIFO_DEPTH,

  //config network enable
  bit ENABLE_DEBUG,

  // activation parameters
  int ACTIVATION_K_VECTOR,
  bit ACTIVATION_ENABLE_DSP_MULT,
  bit ACTIVATION_ENABLE_DSP_CONV,
  int ACTIVATION_TYPE,
  int ACTIVATION_GROUP_DELAY,
  int ACTIVATION_PARAM_CACHE_DEPTH,

  //pool parameters
  int POOL_K_VECTOR,
  int POOL_TYPE,
  int POOL_GROUP_DELAY,
  int POOL_CONFIG_ID_WIDTH,
  int POOL_MAX_WINDOW_HEIGHT,
  int POOL_MAX_WINDOW_WIDTH,
  int POOL_MAX_STRIDE_VERTICAL,
  int POOL_MAX_STRIDE_HORIZONTAL,
  int POOL_PIPELINE_REG_NUM,

  // depthwise parameters
  int DEPTHWISE_K_VECTOR,
  int DEPTHWISE_TYPE,
  int DEPTHWISE_GROUP_DELAY,
  int DEPTHWISE_CONFIG_ID_WIDTH,
  int DEPTHWISE_MAX_WINDOW_HEIGHT,
  int DEPTHWISE_MAX_WINDOW_WIDTH,
  int DEPTHWISE_MAX_STRIDE_VERTICAL,
  int DEPTHWISE_MAX_STRIDE_HORIZONTAL,
  int DEPTHWISE_PIPELINE_REG_NUM,
  int DEPTHWISE_MAX_DILATION_VERTICAL,
  int DEPTHWISE_MAX_DILATION_HORIZONTAL,

  // depthwise vector parameters
  int DEPTHWISE_VECTOR_FEATURE_WIDTH,
  int DEPTHWISE_VECTOR_FILTER_WIDTH,
  int DEPTHWISE_VECTOR_BIAS_WIDTH,
  int DEPTHWISE_VECTOR_DOT_SIZE,

  //softmax parameters
  int SOFTMAX_K_VECTOR,
  int SOFTMAX_GROUP_DELAY,
  int SOFTMAX_CONFIG_ID_WIDTH,
  int SOFTMAX_MAX_NUM_CHANNELS,

  // aux parameters
  int AUX_MAX_TILE_HEIGHT,
  int AUX_MAX_TILE_WIDTH,
  int AUX_MAX_TILE_CHANNELS,

  // mixed precision switch
  int ENABLE_MIXED_PRECISION,

  // Layout Transform
  int LAYOUT_TRANSFORM_ENABLE,
  int LAYOUT_TRANSFORM_MAX_FEATURE_CHANNELS,
  int LAYOUT_TRANSFORM_MAX_FEATURE_HEIGHT,
  int LAYOUT_TRANSFORM_MAX_FEATURE_WIDTH,
  int LAYOUT_TRANSFORM_MAX_FEATURE_DEPTH,
  int LAYOUT_TRANSFORM_MAX_STRIDE_WIDTH,
  int LAYOUT_TRANSFORM_MAX_STRIDE_HEIGHT,
  int LAYOUT_TRANSFORM_MAX_STRIDE_DEPTH,
  int LAYOUT_TRANSFORM_MAX_PAD_FRONT,
  int LAYOUT_TRANSFORM_MAX_PAD_LEFT,
  int LAYOUT_TRANSFORM_MAX_PAD_TOP,
  int LAYOUT_TRANSFORM_MAX_FILTER_HEIGHT,
  int LAYOUT_TRANSFORM_MAX_FILTER_WIDTH,
  int LAYOUT_TRANSFORM_MAX_FILTER_DEPTH,
  int LAYOUT_TRANSFORM_MAX_DILATION_WIDTH,
  int LAYOUT_TRANSFORM_MAX_DILATION_HEIGHT,
  int LAYOUT_TRANSFORM_MAX_DILATION_DEPTH,
  int LAYOUT_TRANSFORM_READER_BYTES,
  int LAYOUT_TRANSFORM_CONV_MODE,
  bit LAYOUT_TRANSFORM_ENABLE_IN_BIAS_SCALE,

  // Lightweight (non-folding) layout transform
  int LIGHTWEIGHT_LAYOUT_TRANSFORM_ENABLE,
  int LIGHTWEIGHT_LAYOUT_TRANSFORM_CHANNELS,
  int LIGHTWEIGHT_LAYOUT_TRANSFORM_BUS_WIDTH,
  int LIGHTWEIGHT_LAYOUT_TRANSFORM_ELEMENT_WIDTH,
  int LIGHTWEIGHT_LAYOUT_TRANSFORM_PIXEL_FIFO_DEPTH,
  int LIGHTWEIGHT_LAYOUT_TRANSFORM_CONV_MODE,
  int LIGHTWEIGHT_LAYOUT_TRANSFORM_BIAS_SCALE_ENABLE,
  // output streaming enable and signals
  bit ENABLE_OUTPUT_STREAMER,
  int AXI_OSTREAM_DATA_WIDTH,
  int AXI_OSTREAM_ID_WIDTH,
  int AXI_OSTREAM_DEST_WIDTH,
  int AXI_OSTREAM_FIFO_DEPTH
) (
  //clocks and resets, all resets are not synchronized
  input  wire                                     clk_ddr,
  input  wire                                     clk_axi,
  input  wire                                     clk_dla,
  input  wire                                     clk_pcie,
  input  wire                                     i_resetn_async,     //active low reset that has NOT been synchronized to any clock

  //interrupt request, AXI4 stream master without data, runs on pcie clock
  output logic                                    o_interrupt_level,

  //CSR, AXI4 lite slave, runs on ddr clock
  input  wire                                     i_csr_arvalid,
  input  wire                [CSR_ADDR_WIDTH-1:0] i_csr_araddr,
  output logic                                    o_csr_arready,
  output logic                                    o_csr_rvalid,
  output logic             [8*CSR_DATA_BYTES-1:0] o_csr_rdata,
  input  wire                                     i_csr_rready,
  input  wire                                     i_csr_awvalid,
  input  wire                [CSR_ADDR_WIDTH-1:0] i_csr_awaddr,
  output logic                                    o_csr_awready,
  input  wire                                     i_csr_wvalid,
  input  wire              [8*CSR_DATA_BYTES-1:0] i_csr_wdata,
  output logic                                    o_csr_wready,
  output logic                                    o_csr_bvalid,
  input  wire                                     i_csr_bready,

  //global memory, AXI4 master, runs on ddr clock
  output logic                                    o_ddr_arvalid,
  output logic               [DDR_ADDR_WIDTH-1:0] o_ddr_araddr,
  output logic       [AXI_BURST_LENGTH_WIDTH-1:0] o_ddr_arlen,
  output logic         [AXI_BURST_SIZE_WIDTH-1:0] o_ddr_arsize,
  output logic         [AXI_BURST_TYPE_WIDTH-1:0] o_ddr_arburst,
  output logic            [DDR_READ_ID_WIDTH-1:0] o_ddr_arid,
  input  wire                                     i_ddr_arready,
  input  wire                                     i_ddr_rvalid,
  input  wire              [8*DDR_DATA_BYTES-1:0] i_ddr_rdata,
  input  wire             [DDR_READ_ID_WIDTH-1:0] i_ddr_rid,
  output logic                                    o_ddr_rready,
  output logic                                    o_ddr_awvalid,
  output logic               [DDR_ADDR_WIDTH-1:0] o_ddr_awaddr,
  output logic       [AXI_BURST_LENGTH_WIDTH-1:0] o_ddr_awlen,
  output logic         [AXI_BURST_SIZE_WIDTH-1:0] o_ddr_awsize,
  output logic         [AXI_BURST_TYPE_WIDTH-1:0] o_ddr_awburst,
  input  wire                                     i_ddr_awready,
  output logic                                    o_ddr_wvalid,
  output logic             [8*DDR_DATA_BYTES-1:0] o_ddr_wdata,
  output logic               [DDR_DATA_BYTES-1:0] o_ddr_wstrb,
  output logic                                    o_ddr_wlast,
  input  wire                                     i_ddr_wready,
  input  wire                                     i_ddr_bvalid,
  output logic                                    o_ddr_bready,

  // Input Streamer AXI-S interface signals
  input  wire                                     i_istream_axi_t_valid,
  output logic                                    o_istream_axi_t_ready,
  input  wire         [AXI_ISTREAM_DATA_WIDTH-1:0] i_istream_axi_t_data,

  // Output Streamer AXI-S interface signals
  output wire                                    o_ostream_axi_t_valid,
  input wire                                     i_ostream_axi_t_ready,
  output wire                                    o_ostream_axi_t_last,
  output logic   [AXI_OSTREAM_DATA_WIDTH-1:0]     o_ostream_axi_t_data,
  output logic   [(AXI_OSTREAM_DATA_WIDTH/8)-1:0] o_ostream_axi_t_strb
);
  `include "dla_top_derived_params.svh"

  //////////////////////////////////////
  //  Debug network parameterization  //
  //////////////////////////////////////

  localparam int DEBUG_NETWORK_DATA_WIDTH  = 32;    //width of the read response data
  localparam int DEBUG_NETWORK_ADDR_WIDTH  = 32;    //width of the read request address
  localparam int DEBUG_NETWORK_ADDR_LOWER  = 24;    //how many lower bits of the address are forwarded to external debug-capable module
                                                    //the upper DEBUG_NETWORK_ADDR_WIDTH-DEBUG_NETWORK_ADDR_LOWER bits of address are used to identify the module id
  localparam int DEBUG_NETWORK_NUM_MODULES = 1;     //how many external debug-capable modules are attached, module id goes from 0 to NUM_MODULES-1

  //list of debug-capable modules that attached to debug network
  localparam int DEBUG_NETWORK_ID_PROFILING_COUNTERS = 0;

  // Profiling counters attached to debug network.
  // The ordering of the interfaces must stay consistent with dla/fpga/interface_profiling_counters/util/create_mif.cpp.
  // BEWARE: can only snoop interfaces on clk_dla, e.g. config to DMA readers and writers are excluded, however we can still watch DMA
  // by snooping the ready/valid of the data interface (to input feeder, to filter scratchpad, from xbar before the clock crossing FIFO).
  // Some details to be aware of:
  // - Exit FIFOs are considered part of the preceding module, e.g. PC_ID_INPUT_FEEDER_TO_SEQUENCER is after the input feeder exit FIFO
  // - Width adapters are considered part of the xbar, e.g. if pool kvec < xbar kvec, then we are tapping at the narrower pool interface
  localparam int PC_ID_DMA_TO_CONFIG              = 0;
  localparam int PC_ID_DMA_TO_FILTER              = 1;
  localparam int PC_ID_DMA_TO_INPUT_FEEDER        = 2;
  localparam int PC_ID_CONFIG_TO_INPUT_FEEDER_IN  = 3;
  localparam int PC_ID_CONFIG_TO_INPUT_FEEDER_OUT = 4;
  localparam int PC_ID_CONFIG_TO_XBAR             = 5;
  localparam int PC_ID_CONFIG_TO_ACTIVATION       = 6;
  localparam int PC_ID_CONFIG_TO_POOL             = 7;
  localparam int PC_ID_CONFIG_TO_SOFTMAX          = 8;
  localparam int PC_ID_INPUT_FEEDER_TO_SEQUENCER  = 9;
  localparam int PC_ID_PE_ARRAY_TO_XBAR           = 10;
  localparam int PC_ID_XBAR_TO_ACTIVATION         = 11;
  localparam int PC_ID_ACTIVATION_TO_XBAR         = 12;
  localparam int PC_ID_XBAR_TO_POOL               = 13;
  localparam int PC_ID_POOL_TO_XBAR               = 14;
  localparam int PC_ID_XBAR_TO_SOFTMAX            = 15;
  localparam int PC_ID_SOFTMAX_TO_XBAR            = 16;
  localparam int PC_ID_XBAR_TO_INPUT_FEEDER       = 17;
  localparam int PC_ID_XBAR_TO_DMA                = 18;
  localparam int PC_NUM_INTERFACES                = 19;

  // number of clock cycles to hold the reset signal connected to the dla top and dla platform adapter modules
  localparam int RESET_HOLD_CLOCK_CYCLES = 1024
  //synthesis translate_off
    - 924
  //synthesis translate_on
  ;


  localparam int MAX_XBAR_INTERFACE_PAIRS  = NUMBER_OF_KERNELS+1;
  localparam int XBAR_WA_GROUP_NUM         = PE_ARRAY_ARCH.NUM_LANES;
  localparam int XBAR_WA_GROUP_DELAY       = PE_ARRAY_ARCH.GROUP_DELAY;
  localparam int WA_ELEMENT_WIDTH          = 1;
  localparam int TOTAL_BUS_WIDTH = AUX_MAX_DATABUS_WIDTH * XBAR_WA_GROUP_NUM;

  ///////////////
  //  Signals  //
  ///////////////

  logic                                              config_network_input_valid;
  logic                    [CONFIG_READER_WIDTH-1:0] config_network_input_data;
  logic                                              config_network_input_ready;
  logic                                              config_network_output_valid [CONFIG_NUM_MODULES:1];
  logic                           [CONFIG_WIDTH-1:0] config_network_output_data  [CONFIG_NUM_MODULES:1];
  logic                                              config_network_output_ready [CONFIG_NUM_MODULES:1];
  logic                                              filter_reader_valid;
  logic                    [FILTER_READER_WIDTH-1:0] filter_reader_data;
  logic                                              filter_reader_ready;
  logic                                              feature_reader_valid;
  logic                   [FEATURE_READER_WIDTH-1:0] feature_reader_data;
  logic                                              feature_reader_ready;
  logic                                              pe_array_output_valid;
  logic [PE_ARRAY_LANE_DATA_WIDTH * PE_ARRAY_ARCH.NUM_LANES-1:0] pe_array_output_data;
  logic                                              pe_array_output_ready;
  logic                                              aux_valid;
  logic [INPUT_FEEDER_LANE_DATA_WIDTH * PE_ARRAY_ARCH.NUM_LANES-1:0] aux_data;
  logic                                              aux_ready;
  logic                                              feature_writer_valid;
  logic                   [FEATURE_WRITER_WIDTH-1:0] feature_writer_data;
  logic                                              feature_writer_ready;
  logic                                              debug_network_csr_arvalid;
  logic               [DEBUG_NETWORK_ADDR_WIDTH-1:0] debug_network_csr_araddr;
  logic                                              debug_network_csr_arready;
  logic                                              debug_network_csr_rvalid;
  logic               [DEBUG_NETWORK_DATA_WIDTH-1:0] debug_network_csr_rdata;
  logic                                              debug_network_csr_rready;
  logic                                              debug_network_dbg_arvalid [DEBUG_NETWORK_NUM_MODULES-1:0];
  logic               [DEBUG_NETWORK_ADDR_LOWER-1:0] debug_network_dbg_araddr  [DEBUG_NETWORK_NUM_MODULES-1:0];
  logic                                              debug_network_dbg_arready [DEBUG_NETWORK_NUM_MODULES-1:0];
  logic                                              debug_network_dbg_rvalid  [DEBUG_NETWORK_NUM_MODULES-1:0];
  logic               [DEBUG_NETWORK_DATA_WIDTH-1:0] debug_network_dbg_rdata   [DEBUG_NETWORK_NUM_MODULES-1:0];
  logic                                              debug_network_dbg_rready  [DEBUG_NETWORK_NUM_MODULES-1:0];
  logic                                              pc_snoop_valid [PC_NUM_INTERFACES-1:0];
  logic                                              pc_snoop_ready [PC_NUM_INTERFACES-1:0];
  logic                                              pc_input_feeder_to_sequencer_valid;
  logic                                              pc_input_feeder_to_sequencer_ready;
  logic                                              pc_config_to_activation_valid;
  logic                                              pc_config_to_activation_ready;
  logic                                              pc_xbar_to_activation_valid;
  logic                                              pc_xbar_to_activation_ready;
  logic                                              pc_activation_to_xbar_valid;
  logic                                              pc_activation_to_xbar_ready;
  logic                                              pc_config_to_pool_valid;
  logic                                              pc_config_to_pool_ready;
  logic                                              pc_xbar_to_pool_valid;
  logic                                              pc_xbar_to_pool_ready;
  logic                                              pc_pool_to_xbar_valid;
  logic                                              pc_pool_to_xbar_ready;
  logic                                              pc_config_to_softmax_valid;
  logic                                              pc_config_to_softmax_ready;
  logic                                              pc_xbar_to_softmax_valid;
  logic                                              pc_xbar_to_softmax_ready;
  logic                                              pc_softmax_to_xbar_valid;
  logic                                              pc_softmax_to_xbar_ready;
  logic                                              reset_request_from_csr;
  logic                                              w_resetn_async;
  logic                                              streaming_active;
  logic                                              core_streaming_active;
  logic                                              lt_param_error;

  logic                                              config_lt_ready_ddr, config_lt_valid_ddr;
  logic                           [CONFIG_WIDTH-1:0] config_lt_data_ddr;

  logic                                              config_lt_ready_stream, config_lt_valid_stream;
  logic                           [CONFIG_WIDTH-1:0] config_lt_data_stream;
  logic                                              ostream_tlast_axi_clk, ostream_tlast_ddr_clk;

  assign o_ostream_axi_t_last = ostream_tlast_axi_clk;

  logic unpacked_clk_ddr [1], unpacked_clk_axi [1];
  logic unpacked_resetn_ddr [1], unpacked_resetn_axi [1];

  assign unpacked_clk_ddr = '{clk_ddr};
  assign unpacked_clk_axi = '{clk_axi};

  //the user can request IP reset by writing to a CSR register (runs on clk_ddr)
  //since the dla_platform_reset safely handles async reset, we just need OR this with external reset
  //the signal reset_request_from_csr is active high, so invert it
  assign unpacked_resetn_ddr[0] = i_resetn_async & !reset_request_from_csr;
  assign unpacked_resetn_axi[0] = i_resetn_async & !reset_request_from_csr;
  //NOTE!
  //driving an async reset signal with combinational logic is potentially dangerous, as glitching
  //at the comb output can pose a metastability risk. However, it is safe in this case:
  //  - there are only two ANDed inputs, so no intermediate result glitching
  //  - reset_request_from_csr comes straight from a FF, so will not itself glitch
  //  - if the two inputs change too near each other, a glitch COULD occur -- however, the only possible
  //    AND glitch is 00010000. The resulting reset sequence would resolve any metastability
  //  - reset_request_from_csr is by construction well-behaved with respect to i_resetn_async


  dla_platform_reset #(
    .RESET_HOLD_CLOCK_CYCLES    (RESET_HOLD_CLOCK_CYCLES),
    .MAX_DLA_INSTANCES          (1),
    .ENABLE_AXI                 (ENABLE_INPUT_STREAMING || ENABLE_OUTPUT_STREAMER),
    .ENABLE_DDR                 (1)
  ) dla_platform_reset_inst (
    .clk_dla                    (clk_dla),
    .clk_ddr                    (unpacked_clk_ddr),
    .clk_pcie                   (clk_pcie),
    .clk_axis                   (unpacked_clk_axi),
    .i_resetn_dla               (i_resetn_async),
    .i_resetn_ddr               (unpacked_resetn_ddr),
    .i_resetn_pcie              (i_resetn_async),
    .i_resetn_axis              (unpacked_resetn_axi),
    .o_resetn_async             (w_resetn_async)
  );

  logic [INPUT_FEEDER_LANE_DATA_WIDTH-1:0] istream_data;
  logic istream_ready;
  logic istream_valid;
  logic reading_first_word;
  logic axi_streaming_active;
  logic axi_reading_first_word;
  logic streaming_first_word_received;
  logic streaming_last_word_sent;
  logic dla_core_streaming_active;

  if (ENABLE_INPUT_STREAMING) begin
    // Cross streaming-enable signal from CSR domain (DDR) to AXI
    if (ENABLE_OUTPUT_STREAMER & ENABLE_ON_CHIP_PARAMETERS) begin
      // In this case, CSR doesn't have input/output address to start inference and
      // inference does not wait for a descriptor to be read.
      // So wait for dedicated CSR state; otherwise, inference will be started by
      // writing the IO buffer address.
      dla_clock_cross_full_sync cc_streaming_active (
        .clk_src(clk_ddr),
        .i_src_data(streaming_active),
        .o_src_data(),

        .clk_dst(clk_axi),
        .o_dst_data(axi_streaming_active)
      );
      logic w_dla_core_streaming_active;
      dla_clock_cross_full_sync cc_core_start_streaming (
        .clk_src(clk_ddr),
        .i_src_data(core_streaming_active),
        .o_src_data(),

        .clk_dst(clk_dla),
        .o_dst_data(w_dla_core_streaming_active)
      );

      // Flops to help fanout
      dla_delay #(
        .WIDTH(1),
        .DELAY(2)
      ) u_delay_dla_core_streaming_active (
        .clk(clk_dla),
        .i_data(w_dla_core_streaming_active),
        .o_data(dla_core_streaming_active)
      );
    end else begin
      assign axi_streaming_active = 1;
      assign dla_core_streaming_active = 1'b1;
    end

    dla_input_streamer #(
      .TDATA_WIDTH(AXI_ISTREAM_DATA_WIDTH),
      .FIFO_DEPTH(AXI_ISTREAM_FIFO_DEPTH),
      .TID_WIDTH(0),
      .TDEST_WIDTH(0),
      .TUSER_WIDTH(0),
      .LT_ARCH(LT_ARCH),
      .LW_LT_ARCH(LW_LT_ARCH),
      .OUTPUT_WIDTH(INPUT_FEEDER_LANE_DATA_WIDTH)
    ) dla_input_streamer_inst (
      .clk_dla(clk_dla),
      .clk_ddr(clk_ddr),
      .clk_axi(clk_axi),
      .i_resetn_async(w_resetn_async),
      .i_config_data(config_lt_data_stream),
      .i_config_valid(config_lt_valid_stream),
      .o_config_ready(config_lt_ready_stream),
      .i_streaming_enable(axi_streaming_active),
      .i_tvalid(i_istream_axi_t_valid),
      .o_tready(o_istream_axi_t_ready),
      .i_tdata(i_istream_axi_t_data),
      // unimplemented AXI-S signals:
      .i_tstrb(),
      .i_tkeep(),
      .i_tlast(),
      .i_tid(),
      .i_tdest(),
      .i_tuser(),
      .i_twakeup(),
      // DLA clock signals:
      .o_istream_data(istream_data),
      .i_istream_ready(istream_ready & dla_core_streaming_active),
      .o_istream_valid(istream_valid),
      .o_reading_first_word(axi_reading_first_word),
      .o_param_error(lt_param_error)
    );

    //synthesis translate_off
    always_ff @(posedge clk_axi) begin
      if (w_resetn_async == 1'b1 && axi_reading_first_word == 1'bx) begin
        $error("X passed to CDC module cc_reading_first_word that cannot propagate it");
      end
    end
    //synthesis translate_on

    dla_clock_cross_pulse_handshake #(
      .SRC_FLOP_TYPE(bit) // By using 'bit' type, we do not need to hook up the reset
                          // BUT, this will mean that in simulation, Xs will not propagate
    ) cc_reading_first_word (
      .clk_src            (clk_axi),
      .i_src_data         (axi_reading_first_word),

      .clk_dst            (clk_ddr),
      .o_dst_data         (reading_first_word)
    );

  end else begin
    assign istream_valid = 0;
    assign reading_first_word = 0;
    assign lt_param_error = 0;
  end

  if ((LIGHTWEIGHT_LAYOUT_TRANSFORM_ENABLE | LAYOUT_TRANSFORM_ENABLE) & ~ENABLE_INPUT_STREAMING) begin
    if (~CONFIG_NETWORK_CROSS_CLOCK[CONFIG_ID_LAYOUT_TRANSFORM]) begin
      $fatal(1, "Compiling layout transform design without DDR clock-crossing enabled.");
    end
    // Then the layout transform is in the DMA module...
    assign config_lt_valid_ddr = config_network_output_valid[CONFIG_ID_LAYOUT_TRANSFORM];
    assign config_lt_data_ddr = config_network_output_data [CONFIG_ID_LAYOUT_TRANSFORM];
    assign config_network_output_ready[CONFIG_ID_LAYOUT_TRANSFORM] = config_lt_ready_ddr;

    assign config_lt_valid_stream = 1'b0;
    assign config_lt_data_stream = 'x;
  end else if ((LIGHTWEIGHT_LAYOUT_TRANSFORM_ENABLE | LAYOUT_TRANSFORM_ENABLE) & ENABLE_INPUT_STREAMING) begin
    if (~CONFIG_NETWORK_CROSS_CLOCK_AXI[CONFIG_ID_LAYOUT_TRANSFORM]) begin
      $fatal(1, "Compiling layout transform streaming design without AXI clock-crossing enabled.");
    end
    assign config_lt_valid_stream = config_network_output_valid[CONFIG_ID_LAYOUT_TRANSFORM];
    assign config_lt_data_stream = config_network_output_data [CONFIG_ID_LAYOUT_TRANSFORM];
    assign config_network_output_ready[CONFIG_ID_LAYOUT_TRANSFORM] = config_lt_ready_stream;

    assign config_lt_valid_ddr = 1'b0;
    assign config_lt_data_ddr = 'x;
  end else begin
    assign config_lt_valid_ddr = 1'b0;
    assign config_lt_data_ddr = 'x;
    assign config_lt_valid_stream = 1'b0;
    assign config_lt_data_stream = 'x;
  end

  dla_dma #(
    .CSR_ADDR_WIDTH                 (CSR_ADDR_WIDTH),
    .CSR_DATA_BYTES                 (CSR_DATA_BYTES),
    .CONFIG_DATA_BYTES              (CONFIG_DATA_BYTES),
    .CONFIG_READER_DATA_BYTES       (CONFIG_READER_DATA_BYTES),
    .FILTER_READER_DATA_BYTES       (FILTER_READER_DATA_BYTES),
    .FEATURE_READER_DATA_BYTES      (FEATURE_READER_DATA_BYTES),
    .FEATURE_WRITER_DATA_BYTES      (FEATURE_WRITER_DATA_BYTES),
    .DDR_ADDR_WIDTH                 (DDR_ADDR_WIDTH),
    .DDR_DATA_BYTES                 (DDR_DATA_BYTES),
    .DDR_BURST_WIDTH                (DDR_BURST_WIDTH),
    .DDR_READ_ID_WIDTH              (DDR_READ_ID_WIDTH),
    .DEVICE                         (DEVICE_ENUM),
    .LT_ARCH                        (LT_ARCH),
    .LW_LT_ARCH                     (LW_LT_ARCH),
    .ENABLE_INPUT_STREAMING         (ENABLE_INPUT_STREAMING),
    .ENABLE_OUTPUT_STREAMING        (ENABLE_OUTPUT_STREAMER),
    .ENABLE_ON_CHIP_PARAMETERS      (ENABLE_ON_CHIP_PARAMETERS)
  )
  dma
  (
    .clk_ddr                        (clk_ddr),
    .clk_dla                        (clk_dla),
    .clk_pcie                       (clk_pcie),
    .i_resetn_async                 (w_resetn_async),
    .o_interrupt_level              (o_interrupt_level),
    .i_token_error                  (lt_param_error), //TODO intended for other parts of DLA to communicate to the host that some error has occurred
    .i_stream_started               (reading_first_word), //indicates that the first word of the input stream is being read, synchronized to DDR clock
    .i_stream_done                  (ostream_tlast_ddr_clk), // ostream TLAST signal synchronized to the DDR clock
    .i_stream_received_first_word   (streaming_first_word_received),
    .i_stream_sent_last_word        (streaming_last_word_sent),
    .o_request_ip_reset             (reset_request_from_csr), //enables CSR to request reset of coreDLA IP
    .i_csr_arvalid                  (i_csr_arvalid),
    .i_csr_araddr                   (i_csr_araddr),
    .o_csr_arready                  (o_csr_arready),
    .o_csr_rvalid                   (o_csr_rvalid),
    .o_csr_rdata                    (o_csr_rdata),
    .i_csr_rready                   (i_csr_rready),
    .i_csr_awvalid                  (i_csr_awvalid),
    .i_csr_awaddr                   (i_csr_awaddr),
    .o_csr_awready                  (o_csr_awready),
    .i_csr_wvalid                   (i_csr_wvalid),
    .i_csr_wdata                    (i_csr_wdata),
    .o_csr_wready                   (o_csr_wready),
    .o_csr_bvalid                   (o_csr_bvalid),
    .i_csr_bready                   (i_csr_bready),
    .o_config_reader_valid          (config_network_input_valid),
    .o_config_reader_data           (config_network_input_data),
    .i_config_reader_ready          (config_network_input_ready),
    .i_config_filter_reader_valid   (config_network_output_valid[CONFIG_ID_FILTER_READER]),
    .i_config_filter_reader_data    (config_network_output_data [CONFIG_ID_FILTER_READER]),
    .o_config_filter_reader_ready   (config_network_output_ready[CONFIG_ID_FILTER_READER]),
    .o_filter_reader_valid          (filter_reader_valid),
    .o_filter_reader_data           (filter_reader_data),
    .i_filter_reader_ready          (filter_reader_ready),
    .i_config_feature_reader_valid  (config_network_output_valid[CONFIG_ID_FEATURE_READER]),
    .i_config_feature_reader_data   (config_network_output_data [CONFIG_ID_FEATURE_READER]),
    .o_config_feature_reader_ready  (config_network_output_ready[CONFIG_ID_FEATURE_READER]),
    .i_config_lt_reader_valid       (config_lt_valid_ddr),
    .i_config_lt_reader_data        (config_lt_data_ddr),
    .o_config_lt_reader_ready       (config_lt_ready_ddr),
    .o_feature_reader_valid         (feature_reader_valid),
    .o_feature_reader_data          (feature_reader_data),
    .i_feature_reader_ready         (feature_reader_ready),
    .i_config_feature_writer_valid  (config_network_output_valid[CONFIG_ID_FEATURE_WRITER]),
    .i_config_feature_writer_data   (config_network_output_data [CONFIG_ID_FEATURE_WRITER]),
    .o_config_feature_writer_ready  (config_network_output_ready[CONFIG_ID_FEATURE_WRITER]),
    .i_feature_writer_valid         (feature_writer_valid),
    .i_feature_writer_data          (feature_writer_data),
    .o_feature_writer_ready         (feature_writer_ready),
    .o_debug_network_arvalid        (debug_network_csr_arvalid),
    .o_debug_network_araddr         (debug_network_csr_araddr),
    .i_debug_network_arready        (debug_network_csr_arready),
    .i_debug_network_rvalid         (debug_network_csr_rvalid),
    .i_debug_network_rdata          (debug_network_csr_rdata),
    .o_debug_network_rready         (debug_network_csr_rready),
    .o_ddr_arvalid                  (o_ddr_arvalid),
    .o_ddr_araddr                   (o_ddr_araddr),
    .o_ddr_arlen                    (o_ddr_arlen),
    .o_ddr_arsize                   (o_ddr_arsize),
    .o_ddr_arburst                  (o_ddr_arburst),
    .o_ddr_arid                     (o_ddr_arid),
    .i_ddr_arready                  (i_ddr_arready),
    .i_ddr_rvalid                   (i_ddr_rvalid),
    .i_ddr_rdata                    (i_ddr_rdata),
    .i_ddr_rid                      (i_ddr_rid),
    .o_ddr_rready                   (o_ddr_rready),
    .o_ddr_awvalid                  (o_ddr_awvalid),
    .o_ddr_awaddr                   (o_ddr_awaddr),
    .o_ddr_awlen                    (o_ddr_awlen),
    .o_ddr_awsize                   (o_ddr_awsize),
    .o_ddr_awburst                  (o_ddr_awburst),
    .i_ddr_awready                  (i_ddr_awready),
    .o_ddr_wvalid                   (o_ddr_wvalid),
    .o_ddr_wdata                    (o_ddr_wdata),
    .o_ddr_wstrb                    (o_ddr_wstrb),
    .o_ddr_wlast                    (o_ddr_wlast),
    .i_ddr_wready                   (i_ddr_wready),
    .i_ddr_bvalid                   (i_ddr_bvalid),
    .o_ddr_bready                   (o_ddr_bready),
    .o_core_streaming_active        (core_streaming_active),
    .o_streaming_active             (streaming_active)
  );

  logic                                   raw_feature_writer_valid;
  logic [8*FEATURE_WRITER_DATA_BYTES-1:0] raw_feature_writer_data;
  logic                                   raw_feature_writer_ready;
  logic                                   raw_feature_writer_full;
  logic                                   feature_writer_empty;

  logic                                                   xbar_dout0_valid;
  logic [AUX_OUTPUT_DATA_WIDTHS[0]*XBAR_WA_GROUP_NUM-1:0] xbar_dout0_data;
  logic [AUX_OUTPUT_DATA_WIDTHS[0]*XBAR_WA_GROUP_NUM-1:0] xbar_demuxed_data;
  logic                                                   xbar_dout0_ready;
  logic                                                   xbar_dout0_done;

  logic                                                   xbar_dout1_valid;
  logic [AUX_OUTPUT_DATA_WIDTHS[0]*XBAR_WA_GROUP_NUM-1:0] xbar_dout1_data;
  logic                                                   xbar_dout1_ready;

  dla_pe_array_system #(
    .SEQUENCER_ARCH(SEQUENCER_ARCH),
    .SCRATCHPAD_ARCH(SCRATCHPAD_ARCH),
    .PE_ARRAY_ARCH(PE_ARRAY_ARCH),
    .EXIT_FIFO_ARCH(EXIT_FIFO_ARCH),
    .INPUT_FEEDER_ARCH(INPUT_FEEDER_ARCH),

    .CONFIG_WIDTH(CONFIG_WIDTH),
    .PE_ARRAY_OUTPUT_DATA_WIDTH(PE_ARRAY_LANE_DATA_WIDTH * PE_ARRAY_ARCH.NUM_LANES),
    .INPUT_FEEDER_INPUT_DATA_WIDTH(INPUT_FEEDER_LANE_DATA_WIDTH * PE_ARRAY_ARCH.NUM_LANES),
    .FEATURE_READER_WIDTH(FEATURE_READER_WIDTH),
    .FILTER_READER_WIDTH(FILTER_READER_WIDTH),
    .SCRATCHPAD_LATENCY(SCRATCHPAD_LATENCY)
  ) pe_array_system (
    .clk                         (clk_dla),
    .i_aresetn                   (w_resetn_async),

    .i_feeder_mux_config_data    (config_network_output_data [CONFIG_ID_INPUT_FEEDER_MUX]),
    .o_feeder_mux_config_ready   (config_network_output_ready[CONFIG_ID_INPUT_FEEDER_MUX]),
    .i_feeder_mux_config_valid   (config_network_output_valid[CONFIG_ID_INPUT_FEEDER_MUX]),
    .i_feeder_writer_config_data (config_network_output_data [CONFIG_ID_INPUT_FEEDER_WRITER]),
    .o_feeder_writer_config_ready(config_network_output_ready[CONFIG_ID_INPUT_FEEDER_WRITER]),
    .i_feeder_writer_config_valid(config_network_output_valid[CONFIG_ID_INPUT_FEEDER_WRITER]),
    .i_feeder_in_config_data     (config_network_output_data [CONFIG_ID_INPUT_FEEDER_IN]),
    .o_feeder_in_config_ready    (config_network_output_ready[CONFIG_ID_INPUT_FEEDER_IN]),
    .i_feeder_in_config_valid    (config_network_output_valid[CONFIG_ID_INPUT_FEEDER_IN]),
    .i_feeder_reader_config_data (config_network_output_data [CONFIG_ID_INPUT_FEEDER_READER]),
    .o_feeder_reader_config_ready(config_network_output_ready[CONFIG_ID_INPUT_FEEDER_READER]),
    .i_feeder_reader_config_valid(config_network_output_valid[CONFIG_ID_INPUT_FEEDER_READER]),
    .i_feeder_out_config_data    (config_network_output_data [CONFIG_ID_INPUT_FEEDER_OUT]),
    .o_feeder_out_config_ready   (config_network_output_ready[CONFIG_ID_INPUT_FEEDER_OUT]),
    .i_feeder_out_config_valid   (config_network_output_valid[CONFIG_ID_INPUT_FEEDER_OUT]),

    .i_feature_input_data        (feature_reader_data),
    .o_feature_input_ready       (feature_reader_ready),
    .i_feature_input_valid       (feature_reader_valid),

    .i_istream_data              (istream_data),
    .o_istream_ready             (istream_ready),
    .i_istream_valid             (istream_valid & dla_core_streaming_active),

    .i_filter_data               (filter_reader_data),
    .o_filter_ready              (filter_reader_ready),
    .i_filter_valid              (filter_reader_valid),

    .i_xbar_writeback_input_data (aux_data),
    .o_xbar_writeback_input_ready(aux_ready),
    .i_xbar_writeback_input_valid(aux_valid),

    .o_pe_array_output_data      (pe_array_output_data),
    .i_pe_array_output_ready     (pe_array_output_ready),
    .o_pe_array_output_valid     (pe_array_output_valid),

    .o_pc_input_feeder_to_sequencer_valid (pc_input_feeder_to_sequencer_valid),
    .o_pc_input_feeder_to_sequencer_ready (pc_input_feeder_to_sequencer_ready),

    .o_first_word_received      (streaming_first_word_received)
  );

  logic [MAX_XBAR_INTERFACE_PAIRS-1:0]            din_to_xbar_valid;
  logic [TOTAL_BUS_WIDTH         -1:0]            din_to_xbar_data_w[MAX_XBAR_INTERFACE_PAIRS-1:0];
  logic [MAX_XBAR_INTERFACE_PAIRS-1:0]            din_to_xbar_ready;

  logic [MAX_XBAR_INTERFACE_PAIRS-1:1]            dout_from_xbar_valid_w;
  logic [TOTAL_BUS_WIDTH         -1:0]            dout_from_xbar_data_w [MAX_XBAR_INTERFACE_PAIRS-1:1];
  logic [MAX_XBAR_INTERFACE_PAIRS-1:1]            dout_from_xbar_ready;

  // Width Adapter for the output signal from PE Array
  dla_width_adapter #(
      .GROUP_NUM                     (XBAR_WA_GROUP_NUM         ),
      .GROUP_DELAY                   (XBAR_WA_GROUP_DELAY       ),
      .INPUT_DATA_WIDTH_IN_ELEMENTS  (PE_ARRAY_LANE_DATA_WIDTH  ),
      .OUTPUT_DATA_WIDTH_IN_ELEMENTS (AUX_MAX_DATABUS_WIDTH     ),
      .ELEMENT_WIDTH                 (WA_ELEMENT_WIDTH          )
  ) wa_pe_output_inst (
      .clock            (clk_dla              ),
      .i_aresetn        (w_resetn_async       ),
      .i_flush          (1'b0                 ),
      .o_din_ready      (pe_array_output_ready),
      .i_din_valid      (pe_array_output_valid),
      .i_din_data       (pe_array_output_data ),
      .i_dout_ready     (din_to_xbar_ready[XBAR_ID_PE_ARRAY] ),
      .o_dout_valid     (din_to_xbar_valid[XBAR_ID_PE_ARRAY] ),
      .o_dout_data      (din_to_xbar_data_w[XBAR_ID_PE_ARRAY])
  );

  dla_xbar #(
    .NUMBER_OF_KERNELS                             (NUMBER_OF_KERNELS                           ),
    .GROUP_NUM                                     (XBAR_WA_GROUP_NUM                           ),
    .GROUP_DELAY                                   (XBAR_WA_GROUP_DELAY                         ),
    .CONFIG_BUS_WIDTH                              (CONFIG_WIDTH                                ),
    .DEBUG_BUS_WIDTH                               (DEBUG_NETWORK_DATA_WIDTH                    ),
    .DEBUG_ADDR_WIDTH                              (DEBUG_NETWORK_ADDR_LOWER                    ),
    .AUX_XBAR_MUX_OUTPUT_PIPELINE_STAGES           (AUX_XBAR_MUX_OUTPUT_PIPELINE_STAGES         ),
    .AUX_XBAR_NONSTALLABLE_OUTPUT_PIPELINE_STAGES  (AUX_XBAR_NONSTALLABLE_OUTPUT_PIPELINE_STAGES),
    .AUX_XBAR_OUTPUT_BP_FIFO_DEPTH                 (AUX_XBAR_OUTPUT_BP_FIFO_DEPTH               ),
    .AUX_GROUP_MAX_DATABUS_WIDTH                   (AUX_MAX_DATABUS_WIDTH                       ),
    .AUX_XBAR_INPUT_COUNTER_WIDTH                  (AUX_XBAR_INPUT_COUNTER_WIDTH                ),
    .AUX_XBAR_OUTPUT_COUNTER_WIDTH                 (AUX_XBAR_OUTPUT_COUNTER_WIDTH               ),
    .AUX_INPUT_DATA_WIDTHS                         (AUX_INPUT_DATA_WIDTHS                       ),
    .AUX_OUTPUT_DATA_WIDTHS                        (AUX_OUTPUT_DATA_WIDTHS                      ),
    .XBAR_KERNEL_BYPASS_FEATURE_ENABLE             (XBAR_KERNEL_BYPASS_FEATURE_ENABLE           ),
    .AUX_KERNEL_BYPASSABLE                         (AUX_KERNEL_BYPASSABLE                       ),
    .AUX_KERNEL_CONNECTIVITY_VECTOR                (AUX_KERNEL_CONNECTIVITY_VECTOR              )
  ) xbar_inst (
    .clock                 (clk_dla                                    ), // All aux-kernels (including Xbar) operate on single clock domain
    .i_aresetn             (w_resetn_async                             ), // Async ACTIVE-LOW reset - Will be internally synched using generic-synchronizer
    .i_config_valid        (config_network_output_valid[CONFIG_ID_XBAR]), // Valid signal
    .i_config_data         (config_network_output_data[CONFIG_ID_XBAR] ), // Data bus
    .o_config_ready        (config_network_output_ready[CONFIG_ID_XBAR]), // Ready signal - Prefetches one full set of config to avoid input stalling

    .i_debug_raddr(),       // Debug AXI read-address port
    .i_debug_raddr_valid(),
    .o_debug_raddr(),       // Debug AXI read-address port response
    .i_debug_rdata(),       // Debug AXI read-data port response
    .o_debug_rdata(),       // Debug AXI read-data port
    .o_debug_rdata_valid(),

    //Xbar inputs (includes data coming from the pe array
    .i_din_to_xbar_valid   (din_to_xbar_valid                          ),
    .i_din_to_xbar_data    (din_to_xbar_data_w                         ),
    .o_din_to_xbar_ready   (din_to_xbar_ready                          ),

    //Outputs from the xbar to aux kernels
    .o_dout_from_xbar_valid(dout_from_xbar_valid_w                     ),
    .o_dout_from_xbar_data (dout_from_xbar_data_w                      ),
    .i_dout_from_xbar_ready(dout_from_xbar_ready                       ),

    //Primary outputs from the xbar to the feature writer/pe array system
    .o_xbar_dout0_valid    (xbar_dout0_valid                           ),
    .o_xbar_dout0_data     (xbar_dout0_data                            ),
    .i_xbar_dout0_ready    (xbar_dout0_ready                           ),
    .o_xbar_dout0_done     (xbar_dout0_done                            ),
    .o_xbar_dout1_valid    (xbar_dout1_valid                           ),
    .o_xbar_dout1_data     (xbar_dout1_data                            ),
    .i_xbar_dout1_ready    (xbar_dout1_ready                           )
  );

  // parameter structs shared by all aux modules.

  if (ENABLE_ACTIVATION == 1) begin
    localparam int AUX_ACTIVATION_OUTPUT_BUFFER_FIFO_CUTOFF =
      dla_aux_activation_pkg::dla_aa_activation_core_latency(DEVICE_ENUM, ACTIVATION_TYPE);
    localparam int AUX_ACTIVATION_OUTPUT_BUFFER_FIFO_DEPTH =
      calc_hld_fifo_depth(AUX_ACTIVATION_OUTPUT_BUFFER_FIFO_CUTOFF);

    localparam dla_aux_activation_pkg::stream_params_t  AUX_ACTIVATION_CONFIG_STREAM_PARAMS = '{ // Config stream parameterization
      DATA_WIDTH : CONFIG_WIDTH};

    localparam dla_aux_activation_pkg::debug_axi_params_t     AUX_ACTIVATION_DEBUG_AXI_PARAMS     = '{ // Debug AXI bus parameterization
      DATA_WIDTH : DEBUG_NETWORK_DATA_WIDTH,
      ADDR_WIDTH : DEBUG_NETWORK_ADDR_LOWER};

    // In future, when activation is relu only, the module may not need
    // to be connected to config network and can have a confid = -1
    // But for now still assert that config_id != -1.
    if (XBAR_ID_ACTIVATION < 1 || CONFIG_ID_ACTIVATION == -1) begin
      $fatal(1, "Activation is enabled with invalid ID");
    end

    localparam NATIVE_VECTOR_SIZE = PE_ARRAY_ARCH.NUM_FILTERS * PE_ARRAY_ARCH.NUM_PES * PE_ARRAY_ARCH.NUM_INTERLEAVED_FILTERS;

    localparam dla_interface_pkg::aux_data_pack_params_t AUX_ACTIVATION_DATA_PACK_PARAMS = '{ // Data packing parameterization
      ELEMENT_BITS       :  16, // PE output is always FP16. hardcode this value to 16
      VECTOR_SIZE        :  ACTIVATION_K_VECTOR,
      NATIVE_VECTOR_SIZE :  NATIVE_VECTOR_SIZE, // The original pe_k_vector
      GROUP_SIZE         :  PE_ARRAY_ARCH.NUM_FEATURES,
      GROUP_NUM          :  PE_ARRAY_ARCH.NUM_LANES,
      GROUP_DELAY        :  ACTIVATION_GROUP_DELAY}; // temporarily set to 1 by arch_param.cpp

    // Todo: properly parameterize it
    localparam dla_aux_activation_pkg::aux_generic_params_t   AUX_ACTIVATION_GENERIC_PARAMS   = '{ // Parameterization common among all aux blocks
      INPUT_BUFFER_REG_STAGES   : 1,
      OUTPUT_BUFFER_FIFO_CUTOFF : AUX_ACTIVATION_OUTPUT_BUFFER_FIFO_CUTOFF,
      OUTPUT_BUFFER_FIFO_DEPTH  : AUX_ACTIVATION_OUTPUT_BUFFER_FIFO_DEPTH,
      COMMAND_BUFFER_DEPTH      : 1,
      PER_GROUP_CONTROL         : 0,
      DEBUG_LEVEL               : 0,
      DEBUG_ID                  : 0,
      DEBUG_EVENT_DEPTH         : 0};

    localparam dla_aux_activation_pkg::aux_special_params_t   AUX_ACTIVATION_SPECIAL_PARAMS  = '{ // Parameterization special to this aux blocks
      ENABLE_ACTIVATIONS : ACTIVATION_TYPE,
      MAX_TILE_WIDTH     : AUX_MAX_TILE_WIDTH,
      MAX_TILE_HEIGHT    : AUX_MAX_TILE_HEIGHT,
      MAX_TILE_CHANNELS  : AUX_MAX_TILE_CHANNELS / NATIVE_VECTOR_SIZE, // TODO: commonize this across aux modules
      PARAM_CACHE_DEPTH  : ACTIVATION_PARAM_CACHE_DEPTH,
      ENABLE_DSP_MULT    : ACTIVATION_ENABLE_DSP_MULT,      // temporarily set to 0 by arch_param.cpp
      ENABLE_DSP_CONV    : ACTIVATION_ENABLE_DSP_CONV,      // temporarily set to 0 by arch_param.cpp
      DEVICE             : DEVICE_ENUM};

    // config data
    logic [AUX_ACTIVATION_CONFIG_STREAM_PARAMS.DATA_WIDTH-1:0] config_stream;
    logic config_stream_valid;
    assign config_stream = config_network_output_data[CONFIG_ID_ACTIVATION];
    assign config_stream_valid = config_network_output_valid[CONFIG_ID_ACTIVATION];
    // config response
    dla_aux_activation_pkg::generic_response_t config_response;
    assign config_network_output_ready[CONFIG_ID_ACTIVATION] = config_response.ready;

    // This function aux_params_to_bus_width() resturns the total bus width of AUX data bus based on the different elements of the bus
    localparam dla_aux_activation_pkg::stream_params_t       DATA_STREAM_PARAMS  = '{DATA_WIDTH : dla_aux_activation_pkg::aux_params_to_bus_width(AUX_ACTIVATION_DATA_PACK_PARAMS) };

    // input data
    logic [DATA_STREAM_PARAMS.DATA_WIDTH-1:0] activation_input_stream;
    logic activation_input_stream_valid;
    // input response
    dla_aux_activation_pkg::generic_response_t activation_input_response;

    // output data
    logic [DATA_STREAM_PARAMS.DATA_WIDTH-1:0] activation_output_stream;
    logic activation_output_stream_valid;
    // output response
    dla_aux_activation_pkg::generic_response_t activation_output_response;

    // NOTE:: For aux-kernels, data-bus width of the side of WA facing the Xbar is derived based on the
    //         parameter array containing all input/output bus widths of kernels.
    //        - [0] location of AUX_INPUT_DATA_WIDTHS correspondes to PII/PE-Array-Output
    //        - [0] location of AUX_OUTPUT_DATA_WIDTHS correspondes to POI
    dla_width_adapter #(
      .GROUP_NUM                    (XBAR_WA_GROUP_NUM         ),
      .GROUP_DELAY                  (XBAR_WA_GROUP_DELAY       ),
      .INPUT_DATA_WIDTH_IN_ELEMENTS (AUX_OUTPUT_DATA_WIDTHS[XBAR_ID_ACTIVATION]),
      .OUTPUT_DATA_WIDTH_IN_ELEMENTS(dla_aux_activation_pkg::aux_params_to_group_width(AUX_ACTIVATION_DATA_PACK_PARAMS)),
      .ELEMENT_WIDTH                (WA_ELEMENT_WIDTH          )
    ) wa_relu_input_inst (
      .clock       (clk_dla                                   ),
      .i_aresetn   (w_resetn_async                            ),
      .i_flush     (1'b0                                      ),
      .o_din_ready (dout_from_xbar_ready[XBAR_ID_ACTIVATION]  ),
      .i_din_valid (dout_from_xbar_valid_w[XBAR_ID_ACTIVATION]),
      .i_din_data  (dout_from_xbar_data_w[XBAR_ID_ACTIVATION] ),
      .i_dout_ready(activation_input_response.ready           ),
      .o_dout_valid(activation_input_stream_valid             ),
      .o_dout_data (activation_input_stream                   )
    );

    dla_aux_activation_top #(
      .AUX_DATA_PACK_PARAMS(AUX_ACTIVATION_DATA_PACK_PARAMS),
      .CONFIG_STREAM_PARAMS(AUX_ACTIVATION_CONFIG_STREAM_PARAMS),
      .DEBUG_AXI_PARAMS(AUX_ACTIVATION_DEBUG_AXI_PARAMS),
      .AUX_GENERIC_PARAMS(AUX_ACTIVATION_GENERIC_PARAMS),
      .AUX_SPECIAL_PARAMS(AUX_ACTIVATION_SPECIAL_PARAMS)
    ) aux_activation_inst (
      .clk                (clk_dla), // Clock
      .i_aresetn          (w_resetn_async), // Asynchronous reset, active low
      .i_data             (activation_input_stream), // Data input stream port
      .i_data_valid       (activation_input_stream_valid),
      .o_data             (activation_input_response), // Data input stream port response
      .i_result           (activation_output_response), // Result output stream port response
      .o_result           (activation_output_stream), // Result output stream port
      .o_result_valid     (activation_output_stream_valid),
      .i_config           (config_stream), // Config stream port
      .i_config_valid     (config_stream_valid),
      .o_config           (config_response), // Config stream port response
      .i_debug_raddr      (),
      .i_debug_raddr_valid(),
      .o_debug_raddr      (),
      .i_debug_rdata      (),
      .o_debug_rdata      (),
      .o_debug_rdata_valid()
    );

    dla_width_adapter #(
      .GROUP_NUM                    (XBAR_WA_GROUP_NUM         ),
      .GROUP_DELAY                  (XBAR_WA_GROUP_DELAY       ),
      .INPUT_DATA_WIDTH_IN_ELEMENTS (dla_aux_activation_pkg::aux_params_to_group_width(AUX_ACTIVATION_DATA_PACK_PARAMS)),
      .OUTPUT_DATA_WIDTH_IN_ELEMENTS(AUX_INPUT_DATA_WIDTHS[XBAR_ID_ACTIVATION]),
      .ELEMENT_WIDTH                (WA_ELEMENT_WIDTH          )
    ) wa_relu_output_inst (
      .clock       (clk_dla                               ),
      .i_aresetn   (w_resetn_async                        ),
      .i_flush     (1'b0                                  ),
      .o_din_ready (activation_output_response.ready      ),
      .i_din_valid (activation_output_stream_valid        ),
      .i_din_data  (activation_output_stream              ),
      .i_dout_ready(din_to_xbar_ready[XBAR_ID_ACTIVATION] ),
      .o_dout_valid(din_to_xbar_valid[XBAR_ID_ACTIVATION] ),
      .o_dout_data (din_to_xbar_data_w[XBAR_ID_ACTIVATION])
    );

    // Snoop signals for the profiling counters
    assign pc_config_to_activation_valid = config_stream_valid;
    assign pc_config_to_activation_ready = config_response.ready;
    assign pc_xbar_to_activation_valid   = activation_input_stream_valid;
    assign pc_xbar_to_activation_ready   = activation_input_response.ready;
    assign pc_activation_to_xbar_valid   = activation_output_stream_valid;
    assign pc_activation_to_xbar_ready   = activation_output_response.ready;
  end
  else begin
    if (XBAR_ID_ACTIVATION != -1 || CONFIG_ID_ACTIVATION != -1) begin
      $fatal(1, "Activation has an valid ID but it is disabled");
    end

    // Snoop signals for the profiling counters
    assign pc_config_to_activation_valid = 1'b0;
    assign pc_config_to_activation_ready = 1'b0;
    assign pc_xbar_to_activation_valid   = 1'b0;
    assign pc_xbar_to_activation_ready   = 1'b0;
    assign pc_activation_to_xbar_valid   = 1'b0;
    assign pc_activation_to_xbar_ready   = 1'b0;
  end

  if (ENABLE_POOL == 1) begin

    localparam int AUX_POOL_INPUT_BUFFER_REG_STAGES = 1;

    localparam int AUX_POOL_NATIVE_VECTOR_SIZE =
    PE_ARRAY_ARCH.NUM_FILTERS * PE_ARRAY_ARCH.NUM_PES * PE_ARRAY_ARCH.NUM_INTERLEAVED_FILTERS;

    localparam dla_aux_pool_pkg::stream_params_t  AUX_POOL_CONFIG_STREAM_PARAMS = '{ // Config stream parameterization
      DATA_WIDTH : CONFIG_WIDTH};

    localparam dla_aux_pool_pkg::debug_axi_params_t  AUX_POOL_DEBUG_AXI_PARAMS     = '{ // Debug AXI bus parameterization
      DATA_WIDTH : DEBUG_NETWORK_DATA_WIDTH,
      ADDR_WIDTH : DEBUG_NETWORK_ADDR_LOWER};

    localparam dla_interface_pkg::aux_data_pack_params_t AUX_POOL_DATA_PACK_PARAMS = '{ // Data packing parameterization
      ELEMENT_BITS       :  16, // PE output is always FP16. hardcode this value to 16
      VECTOR_SIZE        :  POOL_K_VECTOR,
      NATIVE_VECTOR_SIZE :  AUX_POOL_NATIVE_VECTOR_SIZE, // The original pe_k_vector
      GROUP_SIZE         :  PE_ARRAY_ARCH.NUM_FEATURES,
      GROUP_NUM          :  PE_ARRAY_ARCH.NUM_LANES,
      GROUP_DELAY        :  POOL_GROUP_DELAY}; // temporarily set to 1 by arch_param.cpp

    localparam dla_aux_pool_pkg::aux_special_params_t   AUX_POOL_SPECIAL_PARAMS  = '{ // Parameterization special to this aux blocks
      POOL_TYPE            : POOL_TYPE,
      MAX_WINDOW_HEIGHT    : POOL_MAX_WINDOW_HEIGHT,
      MAX_WINDOW_WIDTH     : POOL_MAX_WINDOW_WIDTH,
      MAX_STRIDE_VERTICAL  : POOL_MAX_STRIDE_VERTICAL,
      MAX_STRIDE_HORIZONTAL: POOL_MAX_STRIDE_HORIZONTAL,
      MAX_TILE_HEIGHT      : AUX_MAX_TILE_HEIGHT,
      MAX_TILE_WIDTH       : AUX_MAX_TILE_WIDTH,
      MAX_TILE_CHANNELS    : AUX_MAX_TILE_CHANNELS,
      CONFIG_ID_WIDTH      : POOL_CONFIG_ID_WIDTH,
      PIPELINE_REG_NUM     : POOL_PIPELINE_REG_NUM};

    localparam int AUX_POOL_OUTPUT_BUFFER_FIFO_CUTOFF = aux_pool_calc_core_latency(AUX_POOL_SPECIAL_PARAMS, AUX_POOL_DATA_PACK_PARAMS);
    localparam int AUX_POOL_OUTPUT_BUFFER_FIFO_DEPTH = calc_hld_fifo_depth(AUX_POOL_OUTPUT_BUFFER_FIFO_CUTOFF);

    localparam dla_aux_pool_pkg::aux_generic_params_t   AUX_POOL_GENERIC_PARAMS   = '{ // Parameterization common among all aux blocks
      INPUT_BUFFER_REG_STAGES   : AUX_POOL_INPUT_BUFFER_REG_STAGES,
      OUTPUT_BUFFER_FIFO_CUTOFF : AUX_POOL_OUTPUT_BUFFER_FIFO_CUTOFF,
      OUTPUT_BUFFER_FIFO_DEPTH  : AUX_POOL_OUTPUT_BUFFER_FIFO_DEPTH,
      COMMAND_BUFFER_DEPTH      : 1,
      PER_GROUP_CONTROL         : 0,
      DEBUG_LEVEL               : 0,
      DEBUG_ID                  : 0,
      DEBUG_EVENT_DEPTH         : 0};

    // config data
    logic [AUX_POOL_CONFIG_STREAM_PARAMS.DATA_WIDTH-1:0] config_stream;
    logic config_stream_valid;
    assign config_stream = config_network_output_data[CONFIG_ID_POOL];
    assign config_stream_valid = config_network_output_valid[CONFIG_ID_POOL];
    // config response
    dla_aux_pool_pkg::generic_response_t config_response;
    assign config_network_output_ready[CONFIG_ID_POOL] = config_response.ready;

    // This function aux_params_to_bus_width() returns the total bus width of AUX data bus based on the different elements of the bus
    localparam dla_aux_pool_pkg::stream_params_t       DATA_STREAM_PARAMS  = '{DATA_WIDTH : dla_aux_pool_pkg::aux_params_to_bus_width(AUX_POOL_DATA_PACK_PARAMS) };

    // input data
    logic [DATA_STREAM_PARAMS.DATA_WIDTH-1:0] pool_input_stream;
    logic pool_input_stream_valid;
    // input response
    dla_aux_pool_pkg::generic_response_t pool_input_response;

    // output data
    logic [DATA_STREAM_PARAMS.DATA_WIDTH-1:0] pool_output_stream;
    logic pool_output_stream_valid;
    // output response
    dla_aux_pool_pkg::generic_response_t pool_output_response;

    // NOTE:: For aux-kernels, data-bus width of the side of WA facing the Xbar is derived based on the
    //         parameter array containing all input/output bus widths of kernels.
    //        - [0] location of AUX_INPUT_DATA_WIDTHS correspondes to PII/PE-Array-Output
    //        - [0] location of AUX_OUTPUT_DATA_WIDTHS correspondes to POI
    dla_width_adapter #(
      .GROUP_NUM                    (XBAR_WA_GROUP_NUM         ),
      .GROUP_DELAY                  (XBAR_WA_GROUP_DELAY       ),
      .INPUT_DATA_WIDTH_IN_ELEMENTS (AUX_OUTPUT_DATA_WIDTHS[XBAR_ID_POOL]),
      .OUTPUT_DATA_WIDTH_IN_ELEMENTS(dla_aux_pool_pkg::aux_params_to_group_width(AUX_POOL_DATA_PACK_PARAMS)),
      .ELEMENT_WIDTH                (WA_ELEMENT_WIDTH          )
    ) wa_pool_input_inst (
      .clock       (clk_dla                                   ),
      .i_aresetn   (w_resetn_async                            ),
      .i_flush     (1'b0                                      ),
      .o_din_ready (dout_from_xbar_ready[XBAR_ID_POOL]  ),
      .i_din_valid (dout_from_xbar_valid_w[XBAR_ID_POOL]),
      .i_din_data  (dout_from_xbar_data_w[XBAR_ID_POOL] ),
      .i_dout_ready(pool_input_response.ready           ),
      .o_dout_valid(pool_input_stream_valid             ),
      .o_dout_data (pool_input_stream                   )
    );

    dla_aux_pool_top #(
      .AUX_DATA_PACK_PARAMS(AUX_POOL_DATA_PACK_PARAMS),
      .CONFIG_STREAM_PARAMS(AUX_POOL_CONFIG_STREAM_PARAMS),
      .DEBUG_AXI_PARAMS(AUX_POOL_DEBUG_AXI_PARAMS),
      .AUX_GENERIC_PARAMS(AUX_POOL_GENERIC_PARAMS),
      .AUX_SPECIAL_PARAMS(AUX_POOL_SPECIAL_PARAMS)
    ) pool_inst (
      .clk(clk_dla)          , // Clock
      .i_aresetn(w_resetn_async)     , // Active-low sync reset
      //
      .i_data(pool_input_stream)       , // Data input stream port
      .i_data_valid(pool_input_stream_valid),
      .o_data(pool_input_response)       , // Data input stream port response
      //
      .i_result(pool_output_response)     , // Result output stream port response
      .o_result(pool_output_stream)     , // Result output stream port
      .o_result_valid(pool_output_stream_valid),
      //

      .i_config(config_stream)     , // Config stream port
      .i_config_valid(config_stream_valid),
      .o_config(config_response)     , // Config stream port response
      //
      .i_debug_raddr(),
      .i_debug_raddr_valid(),
      .o_debug_raddr(),
      .i_debug_rdata(),
      .o_debug_rdata(),
      .o_debug_rdata_valid()
    );


    dla_width_adapter #(
      .GROUP_NUM                    (XBAR_WA_GROUP_NUM         ),
      .GROUP_DELAY                  (XBAR_WA_GROUP_DELAY       ),
      .INPUT_DATA_WIDTH_IN_ELEMENTS (dla_aux_pool_pkg::aux_params_to_group_width(AUX_POOL_DATA_PACK_PARAMS)),
      .OUTPUT_DATA_WIDTH_IN_ELEMENTS(AUX_INPUT_DATA_WIDTHS[XBAR_ID_POOL]),
      .ELEMENT_WIDTH                (WA_ELEMENT_WIDTH          )
    ) wa_pool_output_inst (
      .clock       (clk_dla                               ),
      .i_aresetn   (w_resetn_async                        ),
      .i_flush     (1'b0                                  ),
      .o_din_ready (pool_output_response.ready      ),
      .i_din_valid (pool_output_stream_valid        ),
      .i_din_data  (pool_output_stream              ),
      .i_dout_ready(din_to_xbar_ready[XBAR_ID_POOL] ),
      .o_dout_valid(din_to_xbar_valid[XBAR_ID_POOL] ),
      .o_dout_data (din_to_xbar_data_w[XBAR_ID_POOL])
    );

    // Snoop signals for the profiling counters
    assign pc_config_to_pool_valid = config_stream_valid;
    assign pc_config_to_pool_ready = config_response.ready;
    assign pc_xbar_to_pool_valid   = pool_input_stream_valid;
    assign pc_xbar_to_pool_ready   = pool_input_response.ready;
    assign pc_pool_to_xbar_valid   = pool_output_stream_valid;
    assign pc_pool_to_xbar_ready   = pool_output_response.ready;
  end
  else begin
    // Snoop signals for the profiling counters
    assign pc_config_to_pool_valid = 1'b0;
    assign pc_config_to_pool_ready = 1'b0;
    assign pc_xbar_to_pool_valid   = 1'b0;
    assign pc_xbar_to_pool_ready   = 1'b0;
    assign pc_pool_to_xbar_valid   = 1'b0;
    assign pc_pool_to_xbar_ready   = 1'b0;
  end

  if (ENABLE_DEPTHWISE == 1) begin

    localparam int AUX_DEPTHWISE_INPUT_BUFFER_REG_STAGES = 1;

    localparam int AUX_DEPTHWISE_NATIVE_VECTOR_SIZE =
      PE_ARRAY_ARCH.NUM_FILTERS * PE_ARRAY_ARCH.NUM_PES * PE_ARRAY_ARCH.NUM_INTERLEAVED_FILTERS;

    localparam dla_aux_depthwise_pkg::stream_params_t  AUX_DEPTHWISE_CONFIG_STREAM_PARAMS = '{ // Config stream parameterization
      DATA_WIDTH : CONFIG_WIDTH};

    localparam dla_aux_depthwise_pkg::debug_axi_params_t  AUX_DEPTHWISE_DEBUG_AXI_PARAMS     = '{ // Debug AXI bus parameterization
      DATA_WIDTH : DEBUG_NETWORK_DATA_WIDTH,
      ADDR_WIDTH : DEBUG_NETWORK_ADDR_LOWER};

    localparam dla_interface_pkg::aux_data_pack_params_t AUX_DEPTHWISE_DATA_PACK_PARAMS = '{ // Data packing parameterization
      ELEMENT_BITS       :  16, // PE output is always FP16. hardcode this value to 16
      VECTOR_SIZE        :  DEPTHWISE_K_VECTOR,
      NATIVE_VECTOR_SIZE :  AUX_DEPTHWISE_NATIVE_VECTOR_SIZE, // The original pe_k_vector
      GROUP_SIZE         :  PE_ARRAY_ARCH.NUM_FEATURES,
      GROUP_NUM          :  PE_ARRAY_ARCH.NUM_LANES,
      GROUP_DELAY        :  DEPTHWISE_GROUP_DELAY}; // temporarily set to 1 by arch_param.cpp

    localparam dla_aux_depthwise_pkg::aux_special_params_t   AUX_DEPTHWISE_SPECIAL_PARAMS  = '{ // Parameterization special to this aux blocks
      DEPTHWISE_TYPE            : DEPTHWISE_TYPE,
      MAX_WINDOW_HEIGHT         : DEPTHWISE_MAX_WINDOW_HEIGHT,
      MAX_WINDOW_WIDTH          : DEPTHWISE_MAX_WINDOW_WIDTH,
      MAX_STRIDE_VERTICAL       : DEPTHWISE_MAX_STRIDE_VERTICAL,
      MAX_STRIDE_HORIZONTAL     : DEPTHWISE_MAX_STRIDE_HORIZONTAL,
      MAX_TILE_HEIGHT           : AUX_MAX_TILE_HEIGHT,
      MAX_TILE_WIDTH            : AUX_MAX_TILE_WIDTH,
      MAX_TILE_CHANNELS         : AUX_MAX_TILE_CHANNELS,
      CONFIG_ID_WIDTH           : DEPTHWISE_CONFIG_ID_WIDTH,
      PIPELINE_REG_NUM          : DEPTHWISE_PIPELINE_REG_NUM,
      MAX_DILATION_VERTICAL     : DEPTHWISE_MAX_DILATION_VERTICAL,
      MAX_DILATION_HORIZONTAL   : DEPTHWISE_MAX_DILATION_HORIZONTAL,
      BIAS_WIDTH                : DEPTHWISE_VECTOR_BIAS_WIDTH};

    localparam int AUX_DEPTHWISE_OUTPUT_BUFFER_FIFO_CUTOFF = aux_depthwise_calc_core_latency(AUX_DEPTHWISE_SPECIAL_PARAMS,
                                                                                             AUX_DEPTHWISE_DATA_PACK_PARAMS,
                                                                                             DEPTHWISE_VECTOR_ARCH_INFO);
    localparam int AUX_DEPTHWISE_OUTPUT_BUFFER_FIFO_DEPTH = calc_hld_fifo_depth(AUX_DEPTHWISE_OUTPUT_BUFFER_FIFO_CUTOFF);

    localparam dla_aux_depthwise_pkg::aux_generic_params_t   AUX_DEPTHWISE_GENERIC_PARAMS   = '{ // Parameterization common among all aux blocks
      INPUT_BUFFER_REG_STAGES   : AUX_DEPTHWISE_INPUT_BUFFER_REG_STAGES,
      OUTPUT_BUFFER_FIFO_CUTOFF : AUX_DEPTHWISE_OUTPUT_BUFFER_FIFO_CUTOFF,
      OUTPUT_BUFFER_FIFO_DEPTH  : AUX_DEPTHWISE_OUTPUT_BUFFER_FIFO_DEPTH,
      COMMAND_BUFFER_DEPTH      : 1,
      PER_GROUP_CONTROL         : 0,
      DEBUG_LEVEL               : 0,
      DEBUG_ID                  : 0,
      DEBUG_EVENT_DEPTH         : 0};

    // config data
    logic [AUX_DEPTHWISE_CONFIG_STREAM_PARAMS.DATA_WIDTH-1:0] config_stream;
    logic config_stream_valid;
    assign config_stream = config_network_output_data[CONFIG_ID_DEPTHWISE];
    assign config_stream_valid = config_network_output_valid[CONFIG_ID_DEPTHWISE];
    // config response
    dla_aux_depthwise_pkg::generic_response_t config_response;
    assign config_network_output_ready[CONFIG_ID_DEPTHWISE] = config_response.ready;

    // This function aux_params_to_bus_width() returns the total bus width of AUX data bus based on the different elements of the bus
    localparam dla_aux_depthwise_pkg::stream_params_t       DATA_STREAM_PARAMS  = '{DATA_WIDTH : dla_aux_depthwise_pkg::aux_params_to_bus_width(AUX_DEPTHWISE_DATA_PACK_PARAMS) };

    // input data
    logic [DATA_STREAM_PARAMS.DATA_WIDTH-1:0] depthwise_input_stream;
    logic depthwise_input_stream_valid;
    // input response
    dla_aux_depthwise_pkg::generic_response_t depthwise_input_response;

    // output data
    logic [DATA_STREAM_PARAMS.DATA_WIDTH-1:0] depthwise_output_stream;
    logic depthwise_output_stream_valid;
    // output response
    dla_aux_depthwise_pkg::generic_response_t depthwise_output_response;

    // NOTE:: For aux-kernels, data-bus width of the side of WA facing the Xbar is derived based on the
    //         parameter array containing all input/output bus widths of kernels.
    //        - [0] location of AUX_INPUT_DATA_WIDTHS correspondes to PII/PE-Array-Output
    //        - [0] location of AUX_OUTPUT_DATA_WIDTHS correspondes to POI
    dla_width_adapter #(
      .GROUP_NUM                    (XBAR_WA_GROUP_NUM         ),
      .GROUP_DELAY                  (XBAR_WA_GROUP_DELAY       ),
      .INPUT_DATA_WIDTH_IN_ELEMENTS (AUX_OUTPUT_DATA_WIDTHS[XBAR_ID_DEPTHWISE]),
      .OUTPUT_DATA_WIDTH_IN_ELEMENTS(dla_aux_depthwise_pkg::aux_params_to_group_width(AUX_DEPTHWISE_DATA_PACK_PARAMS)),
      .ELEMENT_WIDTH                (WA_ELEMENT_WIDTH          )
    ) wa_depthwise_input_inst (
      .clock       (clk_dla                                   ),
      .i_aresetn   (w_resetn_async                            ),
      .i_flush     (1'b0                                      ),
      .o_din_ready (dout_from_xbar_ready[XBAR_ID_DEPTHWISE]  ),
      .i_din_valid (dout_from_xbar_valid_w[XBAR_ID_DEPTHWISE]),
      .i_din_data  (dout_from_xbar_data_w[XBAR_ID_DEPTHWISE] ),
      .i_dout_ready(depthwise_input_response.ready           ),
      .o_dout_valid(depthwise_input_stream_valid             ),
      .o_dout_data (depthwise_input_stream                   )
    );

    dla_aux_depthwise_top #(
      .AUX_DATA_PACK_PARAMS(AUX_DEPTHWISE_DATA_PACK_PARAMS),
      .CONFIG_STREAM_PARAMS(AUX_DEPTHWISE_CONFIG_STREAM_PARAMS),
      .DEBUG_AXI_PARAMS(AUX_DEPTHWISE_DEBUG_AXI_PARAMS),
      .AUX_GENERIC_PARAMS(AUX_DEPTHWISE_GENERIC_PARAMS),
      .AUX_SPECIAL_PARAMS(AUX_DEPTHWISE_SPECIAL_PARAMS),
      .AUX_DEPTHWISE_VECTOR_ARCH(AUX_DEPTHWISE_VECTOR_ARCH),
      .DEPTHWISE_VECTOR_ARCH_INFO(DEPTHWISE_VECTOR_ARCH_INFO)
    ) depthwise_inst (
      .clk(clk_dla)          , // Clock
      .i_aresetn(w_resetn_async)     , // Active-low sync reset
      //
      .i_data(depthwise_input_stream)       , // Data input stream port
      .i_data_valid(depthwise_input_stream_valid),
      .o_data(depthwise_input_response)       , // Data input stream port response
      //
      .i_result(depthwise_output_response)     , // Result output stream port response
      .o_result(depthwise_output_stream)     , // Result output stream port
      .o_result_valid(depthwise_output_stream_valid),
      //

      .i_config(config_stream)     , // Config stream port
      .i_config_valid(config_stream_valid),
      .o_config(config_response)     , // Config stream port response

      .i_config_filter_bias_valid        (config_network_output_valid[CONFIG_ID_DEPTHWISE_FILTER_BIAS]), // Valid signal
      .i_config_filter_bias_data         (config_network_output_data[CONFIG_ID_DEPTHWISE_FILTER_BIAS] ), // Data bus
      .o_config_filter_bias_ready        (config_network_output_ready[CONFIG_ID_DEPTHWISE_FILTER_BIAS]), // Ready signal - Prefetches one full set of config to avoid input stalling

      //
      .i_debug_raddr(),
      .i_debug_raddr_valid(),
      .o_debug_raddr(),
      .i_debug_rdata(),
      .o_debug_rdata(),
      .o_debug_rdata_valid()
    );


    dla_width_adapter #(
      .GROUP_NUM                    (XBAR_WA_GROUP_NUM         ),
      .GROUP_DELAY                  (XBAR_WA_GROUP_DELAY       ),
      .INPUT_DATA_WIDTH_IN_ELEMENTS (dla_aux_depthwise_pkg::aux_params_to_group_width(AUX_DEPTHWISE_DATA_PACK_PARAMS)),
      .OUTPUT_DATA_WIDTH_IN_ELEMENTS(AUX_INPUT_DATA_WIDTHS[XBAR_ID_DEPTHWISE]),
      .ELEMENT_WIDTH                (WA_ELEMENT_WIDTH          )
    ) wa_depthwise_output_inst (
      .clock       (clk_dla                               ),
      .i_aresetn   (w_resetn_async                        ),
      .i_flush     (1'b0                                  ),
      .o_din_ready (depthwise_output_response.ready      ),
      .i_din_valid (depthwise_output_stream_valid        ),
      .i_din_data  (depthwise_output_stream              ),
      .i_dout_ready(din_to_xbar_ready[XBAR_ID_DEPTHWISE] ),
      .o_dout_valid(din_to_xbar_valid[XBAR_ID_DEPTHWISE] ),
      .o_dout_data (din_to_xbar_data_w[XBAR_ID_DEPTHWISE])
    );
  end //ENABLE_DEPTHWISE
  if (ENABLE_SOFTMAX == 1) begin

    localparam int AUX_SOFTMAX_INPUT_BUFFER_REG_STAGES = 1;
    localparam int AUX_SOFTMAX_NATIVE_VECTOR_SIZE = 1;

    localparam dla_aux_softmax_pkg::stream_params_t  AUX_SOFTMAX_CONFIG_STREAM_PARAMS = '{ // Config stream parameterization
      DATA_WIDTH : CONFIG_WIDTH};

    localparam dla_aux_softmax_pkg::debug_axi_params_t  AUX_SOFTMAX_DEBUG_AXI_PARAMS     = '{ // Debug AXI bus parameterization
      DATA_WIDTH : DEBUG_NETWORK_DATA_WIDTH,
      ADDR_WIDTH : DEBUG_NETWORK_ADDR_LOWER};

    localparam dla_interface_pkg::aux_data_pack_params_t AUX_SOFTMAX_DATA_PACK_PARAMS = '{ // Data packing parameterization
      ELEMENT_BITS       :  16, // PE output is always FP16. hardcode this value to 16
      VECTOR_SIZE        :  1,  // always 1 input at a time
      NATIVE_VECTOR_SIZE :  AUX_SOFTMAX_NATIVE_VECTOR_SIZE, // still should be always 1
      GROUP_SIZE         :  PE_ARRAY_ARCH.NUM_FEATURES,
      GROUP_NUM          :  1, // Softmax only supports one group
      GROUP_DELAY        :  SOFTMAX_GROUP_DELAY}; // temporarily set to 1 by arch_param.cpp

    localparam dla_aux_softmax_pkg::aux_special_params_t   AUX_SOFTMAX_SPECIAL_PARAMS  = '{ // Parameterization special to this aux blocks
      MAX_NUM_CHANNELS  : SOFTMAX_MAX_NUM_CHANNELS,
      DEVICE            : DEVICE_ENUM,
      CONFIG_ID_WIDTH   : SOFTMAX_CONFIG_ID_WIDTH};

    localparam int AUX_SOFTMAX_OUTPUT_BUFFER_FIFO_CUTOFF = aux_softmax_calc_core_latency(AUX_SOFTMAX_SPECIAL_PARAMS, AUX_SOFTMAX_DATA_PACK_PARAMS);
    localparam int AUX_SOFTMAX_OUTPUT_BUFFER_FIFO_DEPTH = calc_hld_fifo_depth(AUX_SOFTMAX_OUTPUT_BUFFER_FIFO_CUTOFF);

    localparam dla_aux_softmax_pkg::aux_generic_params_t   AUX_SOFTMAX_GENERIC_PARAMS   = '{ // Parameterization common among all aux blocks
      INPUT_BUFFER_REG_STAGES   : AUX_SOFTMAX_INPUT_BUFFER_REG_STAGES,
      OUTPUT_BUFFER_FIFO_CUTOFF : AUX_SOFTMAX_OUTPUT_BUFFER_FIFO_CUTOFF,
      OUTPUT_BUFFER_FIFO_DEPTH  : AUX_SOFTMAX_OUTPUT_BUFFER_FIFO_DEPTH,
      COMMAND_BUFFER_DEPTH      : 1,
      PER_GROUP_CONTROL         : 0,
      DEBUG_LEVEL               : 0,
      DEBUG_ID                  : 0,
      DEBUG_EVENT_DEPTH         : 0};

    // config data
    logic [AUX_SOFTMAX_CONFIG_STREAM_PARAMS.DATA_WIDTH-1:0] config_stream;
    logic config_stream_valid;
    assign config_stream = config_network_output_data[CONFIG_ID_SOFTMAX];
    assign config_stream_valid = config_network_output_valid[CONFIG_ID_SOFTMAX];
    // config response
    dla_aux_softmax_pkg::generic_response_t config_response;
    assign config_network_output_ready[CONFIG_ID_SOFTMAX] = config_response.ready;

    // This function aux_params_to_bus_width() returns the total bus width of AUX data bus based on the different elements of the bus
    localparam dla_aux_softmax_pkg::stream_params_t       DATA_STREAM_PARAMS  = '{DATA_WIDTH : dla_aux_softmax_pkg::aux_params_to_bus_width(AUX_SOFTMAX_DATA_PACK_PARAMS) };

    // input data
    logic [DATA_STREAM_PARAMS.DATA_WIDTH-1:0] softmax_input_stream;
    logic softmax_input_stream_valid;
    // input response
    dla_aux_softmax_pkg::generic_response_t softmax_input_response;

    // output data
    logic [DATA_STREAM_PARAMS.DATA_WIDTH-1:0] softmax_output_stream;
    logic softmax_output_stream_valid;
    // output response
    dla_aux_softmax_pkg::generic_response_t softmax_output_response;

    // NOTE:: For aux-kernels, data-bus width of the side of WA facing the Xbar is derived based on the
    //         parameter array containing all input/output bus widths of kernels.
    //        - [0] location of AUX_INPUT_DATA_WIDTHS correspondes to PII/PE-Array-Output
    //        - [0] location of AUX_OUTPUT_DATA_WIDTHS correspondes to POI
    dla_width_adapter #(
      .GROUP_NUM                     ( AUX_SOFTMAX_DATA_PACK_PARAMS.GROUP_NUM   ),
      .GROUP_DELAY                   ( AUX_SOFTMAX_DATA_PACK_PARAMS.GROUP_DELAY ),
      .INPUT_DATA_WIDTH_IN_ELEMENTS  ( AUX_OUTPUT_DATA_WIDTHS[XBAR_ID_SOFTMAX]),
      .OUTPUT_DATA_WIDTH_IN_ELEMENTS ( dla_aux_softmax_pkg::aux_params_to_group_width(AUX_SOFTMAX_DATA_PACK_PARAMS)),
      .ELEMENT_WIDTH                 ( WA_ELEMENT_WIDTH          )
    ) wa_softmax_input_inst (
      .clock       (clk_dla                                   ),
      .i_aresetn   (w_resetn_async                            ),
      .i_flush     (1'b0                                      ),
      .o_din_ready (dout_from_xbar_ready[XBAR_ID_SOFTMAX]  ),
      .i_din_valid (dout_from_xbar_valid_w[XBAR_ID_SOFTMAX]),
      .i_din_data  (dout_from_xbar_data_w[XBAR_ID_SOFTMAX][0 +: AUX_MAX_DATABUS_WIDTH]),
      .i_dout_ready(softmax_input_response.ready           ),
      .o_dout_valid(softmax_input_stream_valid             ),
      .o_dout_data (softmax_input_stream                   )
    );

    dla_aux_softmax_top #(
      .AUX_DATA_PACK_PARAMS(AUX_SOFTMAX_DATA_PACK_PARAMS),
      .CONFIG_STREAM_PARAMS(AUX_SOFTMAX_CONFIG_STREAM_PARAMS),
      .DEBUG_AXI_PARAMS(AUX_SOFTMAX_DEBUG_AXI_PARAMS),
      .AUX_GENERIC_PARAMS(AUX_SOFTMAX_GENERIC_PARAMS),
      .AUX_SPECIAL_PARAMS(AUX_SOFTMAX_SPECIAL_PARAMS)
    ) softmax_inst (
      .clk(clk_dla)          , // Clock
      .i_aresetn(w_resetn_async)     , // Active-low sync reset
      //
      .i_data(softmax_input_stream)       , // Data input stream port
      .i_data_valid(softmax_input_stream_valid),
      .o_data(softmax_input_response)       , // Data input stream port response
      //
      .i_result(softmax_output_response)     , // Result output stream port response
      .o_result(softmax_output_stream)     , // Result output stream port
      .o_result_valid(softmax_output_stream_valid),
      //

      .i_config(config_stream)     , // Config stream port
      .i_config_valid(config_stream_valid),
      .o_config(config_response)     , // Config stream port response
      //
      .i_debug_raddr(),
      .i_debug_raddr_valid(),
      .o_debug_raddr(),
      .i_debug_rdata(),
      .o_debug_rdata(),
      .o_debug_rdata_valid()
    );


    dla_width_adapter #(
      .GROUP_NUM                    ( AUX_SOFTMAX_DATA_PACK_PARAMS.GROUP_NUM   ),
      .GROUP_DELAY                  ( AUX_SOFTMAX_DATA_PACK_PARAMS.GROUP_DELAY ),
      .INPUT_DATA_WIDTH_IN_ELEMENTS (dla_aux_softmax_pkg::aux_params_to_group_width(AUX_SOFTMAX_DATA_PACK_PARAMS)),
      .OUTPUT_DATA_WIDTH_IN_ELEMENTS(AUX_INPUT_DATA_WIDTHS[XBAR_ID_SOFTMAX]),
      .ELEMENT_WIDTH                (WA_ELEMENT_WIDTH          )
    ) wa_softmax_output_inst (
      .clock       (clk_dla                               ),
      .i_aresetn   (w_resetn_async                        ),
      .i_flush     (1'b0                                  ),
      .o_din_ready (softmax_output_response.ready      ),
      .i_din_valid (softmax_output_stream_valid        ),
      .i_din_data  (softmax_output_stream              ),
      .i_dout_ready(din_to_xbar_ready[XBAR_ID_SOFTMAX] ),
      .o_dout_valid(din_to_xbar_valid[XBAR_ID_SOFTMAX] ),
      .o_dout_data (din_to_xbar_data_w[XBAR_ID_SOFTMAX][0 +: AUX_MAX_DATABUS_WIDTH])
    );
    if (XBAR_WA_GROUP_NUM > 1) begin : gen_clear_leftover_softmax
      assign din_to_xbar_data_w[XBAR_ID_SOFTMAX][AUX_MAX_DATABUS_WIDTH*XBAR_WA_GROUP_NUM-1:AUX_MAX_DATABUS_WIDTH] = '0;
    end

    // Snoop signals for the profiling counters
    assign pc_config_to_softmax_valid = config_stream_valid;
    assign pc_config_to_softmax_ready = config_response.ready;
    assign pc_xbar_to_softmax_valid   = softmax_input_stream_valid;
    assign pc_xbar_to_softmax_ready   = softmax_input_response.ready;
    assign pc_softmax_to_xbar_valid   = softmax_output_stream_valid;
    assign pc_softmax_to_xbar_ready   = softmax_output_response.ready;
  end
  else begin
    // Snoop signals for the profiling counters
    assign pc_config_to_softmax_valid = 1'b0;
    assign pc_config_to_softmax_ready = 1'b0;
    assign pc_xbar_to_softmax_valid   = 1'b0;
    assign pc_xbar_to_softmax_ready   = 1'b0;
    assign pc_softmax_to_xbar_valid   = 1'b0;
    assign pc_softmax_to_xbar_ready   = 1'b0;
  end

  // output streaming or feature writer selection signals
  // when output streaming is enabled, xbar output could feed
  // either the feature writer or the output streamer
  // in case we have ddr enabled for intermediate layers
  logic feature_writer_wa_ready;
  logic xbar_writer_wa_valid;
  logic [AUX_OUTPUT_DATA_WIDTHS[0]-1:0] w_degrouped_xbar_dout0_data [XBAR_WA_GROUP_NUM-1:0];
  logic w_degrouped_xbar_dout0_valid;
  logic w_degrouped_xbar_dout0_ready;

  logic w_dla_sresetn;
  dla_reset_handler_simple #(
    .USE_SYNCHRONIZER(1),
    .PIPE_DEPTH      (3),
    .NUM_COPIES      (1)
  ) reset_handler (
    .clk     (clk_dla    ),
    .i_resetn(w_resetn_async),
    .o_sclrn (w_dla_sresetn )
  );


  dla_degroup #(
    .GROUP_NUM         ( XBAR_WA_GROUP_NUM            ),
    .GROUP_DELAY       ( XBAR_WA_GROUP_DELAY          ),
    .WIDTH_IN_ELEMENTS ( AUX_OUTPUT_DATA_WIDTHS[0]/16 ),
    .ELEMENT_WIDTH     ( 16                           )
  ) u_degroup_xbar (
    .clk       ( clk_dla                      ),
    .i_sresetn ( w_dla_sresetn                ),
    .o_ready   ( xbar_dout0_ready             ),
    .i_valid   ( xbar_dout0_valid             ),
    .i_data    ( {>>{xbar_dout0_data}}        ),

    .o_data    ( w_degrouped_xbar_dout0_data  ),
    .o_valid   ( w_degrouped_xbar_dout0_valid ),
    .i_ready   ( w_degrouped_xbar_dout0_ready )
  );

  // Feature write has a special group_num of 1 as it converts from group_num -> 1
  dla_width_adapter #(
    .GROUP_NUM                     ( 1                                           ),
    .GROUP_DELAY                   ( XBAR_WA_GROUP_DELAY                         ),
    .INPUT_DATA_WIDTH_IN_ELEMENTS  ( AUX_OUTPUT_DATA_WIDTHS[0]*XBAR_WA_GROUP_NUM ),
    .OUTPUT_DATA_WIDTH_IN_ELEMENTS ( FEATURE_WRITER_WIDTH                        ),
    .ELEMENT_WIDTH                 ( WA_ELEMENT_WIDTH                            )
  ) wa_raw_feature_writer_input_inst (
    .clock        ( clk_dla                  ),
    .i_aresetn    ( w_resetn_async           ),
    .i_flush      ( 1'b0                     ),
    .o_din_ready  ( feature_writer_wa_ready  ),
    .i_din_valid  ( xbar_writer_wa_valid     ),
    .i_din_data   ( xbar_demuxed_data        ),
    .i_dout_ready ( raw_feature_writer_ready ),
    .o_dout_valid ( raw_feature_writer_valid ),
    .o_dout_data  ( raw_feature_writer_data  )
  );

  dla_width_adapter #(
    .GROUP_NUM                    (XBAR_WA_GROUP_NUM            ),
    .GROUP_DELAY                  (XBAR_WA_GROUP_DELAY          ),
    .INPUT_DATA_WIDTH_IN_ELEMENTS (AUX_OUTPUT_DATA_WIDTHS[0]    ),
    .OUTPUT_DATA_WIDTH_IN_ELEMENTS(INPUT_FEEDER_LANE_DATA_WIDTH ),
    .ELEMENT_WIDTH                (WA_ELEMENT_WIDTH             )
  ) wa_aux_input_inst (
    .clock       (clk_dla         ),
    .i_aresetn   (w_resetn_async  ),
    .i_flush     (1'b0            ),
    .o_din_ready (xbar_dout1_ready),
    .i_din_valid (xbar_dout1_valid),
    .i_din_data  (xbar_dout1_data ),
    .i_dout_ready(aux_ready       ),
    .o_dout_valid(aux_valid       ),
    .o_dout_data (aux_data        )
  );

  if (ENABLE_OUTPUT_STREAMER == 1) begin
    logic xbar_streamer_wa_valid;
    logic out_streamer_wa_ready;

    logic xbar_input_done;

    dla_output_streamer # (
      .MAX_TRANSACTIONS     ( STREAM_BUFFER_DEPTH * PE_ARRAY_ARCH.NUM_LANES ),
      .CONFIG_WIDTH         ( CONFIG_WIDTH              ),
      .TDATA_WIDTH          ( AXI_OSTREAM_DATA_WIDTH    ),
      .TID_WIDTH            ( AXI_OSTREAM_ID_WIDTH      ),
      .TDEST_WIDTH          ( AXI_OSTREAM_DEST_WIDTH    ),
      .FIFO_DEPTH           ( AXI_OSTREAM_FIFO_DEPTH    ),
      .INPUT_WIDTH_ELEMENTS ( AUX_OUTPUT_DATA_WIDTHS[0] ),
      .INPUT_ELEMENT_WIDTH  ( WA_ELEMENT_WIDTH          )
    ) output_streamer (
      .clk_dla              ( clk_dla                                                      ),
      .i_aresetn            ( w_resetn_async                                               ),
      .i_config_data        ( config_network_output_data[CONFIG_ID_OUTPUT_STREAMER]        ),
      .i_config_valid       ( config_network_output_valid[CONFIG_ID_OUTPUT_STREAMER]       ),
      .o_config_ready       ( config_network_output_ready[CONFIG_ID_OUTPUT_STREAMER]       ),
      .o_ready              ( out_streamer_wa_ready                                        ),
      .i_valid              ( xbar_streamer_wa_valid                                       ),
      .i_data               ( xbar_demuxed_data[AUX_OUTPUT_DATA_WIDTHS[0]-1:0]             ),
      .i_data_done          ( xbar_dout0_done                                              ),
      .o_last_data_received ( streaming_last_word_sent                                     ),
      .i_config_flush_data  ( config_network_output_data[CONFIG_ID_OUTPUT_STREAMER_FLUSH]  ),
      .i_config_flush_valid ( config_network_output_valid[CONFIG_ID_OUTPUT_STREAMER_FLUSH] ),
      .o_config_flush_ready ( config_network_output_ready[CONFIG_ID_OUTPUT_STREAMER_FLUSH] ),
      .o_input_done         ( xbar_input_done                                              ),
      .clk_axi              ( clk_axi                                                      ),
      .i_axi_aresetn        ( w_resetn_async                                               ),
      .o_axi_t_valid        ( o_ostream_axi_t_valid                                        ),
      .i_axi_t_ready        ( i_ostream_axi_t_ready                                        ),
      .o_axi_t_last         ( ostream_tlast_axi_clk                                        ),
      .o_axi_t_data         ( o_ostream_axi_t_data                                         ),
      .o_axi_t_strb         ( o_ostream_axi_t_strb                                         ),
      .o_axi_t_keep         (                                                              ),
      .o_axi_t_id           (                                                              ),
      .o_axi_t_dest         (                                                              ),
      .o_axi_t_user         (                                                              ),
      .o_axi_t_wakeup       (                                                              )
    );

    // Instantiate Demux to steer data either to feature writer or output streamer
    dla_demux # (
      .CONFIG_WIDTH(CONFIG_WIDTH),
      .DATA_WIDTH(AUX_OUTPUT_DATA_WIDTHS[0] * XBAR_WA_GROUP_NUM)
    ) writer_streamer_demux (
      .clk_dla(clk_dla),
      .i_aresetn(w_resetn_async),
      .i_config_data(config_network_output_data[CONFIG_ID_WRITER_STREAMER_SEL]),
      .i_config_valid(config_network_output_valid[CONFIG_ID_WRITER_STREAMER_SEL]),
      .o_config_ready(config_network_output_ready[CONFIG_ID_WRITER_STREAMER_SEL]),
      .o_ready(w_degrouped_xbar_dout0_ready),
      .i_valid(w_degrouped_xbar_dout0_valid),
      .i_data({>>{w_degrouped_xbar_dout0_data}}),
      .i_transmitter_done(xbar_input_done),
      .i_1_ready(feature_writer_wa_ready),
      .o_1_valid(xbar_writer_wa_valid),
      .i_2_ready(out_streamer_wa_ready),
      .o_2_valid(xbar_streamer_wa_valid),
      .o_data(xbar_demuxed_data)
    );


    //synthesis translate_off
    always_ff @(posedge clk_axi) begin
      if (w_resetn_async == 1'b1 && ostream_tlast_axi_clk == 1'bx) begin
        $error("X passed to CDC module cc_ostream_tlast that cannot propagate it");
      end
    end
    //synthesis translate_on

    dla_clock_cross_pulse_handshake #(
      .SRC_FLOP_TYPE(bit) // By using 'bit' type, we do not need to hook up the reset
                          // BUT, this will mean that in simulation, Xs will not propagate
    ) cc_ostream_tlast (
      .clk_src            (clk_axi),
      .i_src_data         (ostream_tlast_axi_clk),

      .clk_dst            (clk_ddr),
      .o_dst_data         (ostream_tlast_ddr_clk)
    );

  end else begin
    // If output streaming is not enabled, we default the signals
    // back to the feature writer
    assign ostream_tlast_axi_clk = 0;
    assign ostream_tlast_ddr_clk = 0;
    assign streaming_last_word_sent = 0;

    assign w_degrouped_xbar_dout0_ready = feature_writer_wa_ready;
    assign xbar_writer_wa_valid = w_degrouped_xbar_dout0_valid;
    assign xbar_demuxed_data = {>>{w_degrouped_xbar_dout0_data}};
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  //dma expects writer data to already be on the ddr clock
  dla_acl_dcfifo #(
    .WIDTH                      (FEATURE_WRITER_WIDTH),
    .DEPTH                      (32)
  ) feature_writer_clock_crosser (
    .async_resetn               (w_resetn_async),

    //write side
    .wr_clock                   (clk_dla),
    .wr_req                     (raw_feature_writer_valid),
    .wr_data                    (raw_feature_writer_data),
    .wr_full                    (raw_feature_writer_full),

    //read side
    .rd_clock                   (clk_ddr),
    .rd_empty                   (feature_writer_empty),
    .rd_data                    (feature_writer_data),
    .rd_ack                     (feature_writer_ready)
  );
  assign raw_feature_writer_ready = ~raw_feature_writer_full;
  assign feature_writer_valid = ~feature_writer_empty;

  dla_config_network #(
    .NUM_MODULES                    (CONFIG_NUM_MODULES),
    .INPUT_DATA_WIDTH               (CONFIG_READER_WIDTH),
    .MODULE_ID_WIDTH                (MODULE_ID_WIDTH),
    .PAYLOAD_WIDTH                  (CONFIG_WIDTH),
    .CONFIG_CHANNEL_WIDTH           (CONFIG_CHANNEL_WIDTH),
    .FIFO_MIN_DEPTH                 (CONFIG_NETWORK_FIFO_MIN_DEPTH),
    .NUM_PIPELINE_STAGES            (CONFIG_NETWORK_NUM_PIPELINE_STAGES),
    .CROSS_CLOCK                    (CONFIG_NETWORK_CROSS_CLOCK),
    .CROSS_CLOCK_AXI                (CONFIG_NETWORK_CROSS_CLOCK_AXI),
    .QUANTIZE_DEPTHS                (CONFIG_NETWORK_QUANTIZE_DEPTHS),
    .CONFIG_CACHE_DEPTH             (CONFIG_CACHE_DEPTH),
    .ENABLE_DDRFREE_CONFIG          (ENABLE_ON_CHIP_PARAMETERS),
    .ENABLE_INPUT_STREAMING         (ENABLE_INPUT_STREAMING),
    .ENABLE_OUTPUT_STREAMING        (ENABLE_OUTPUT_STREAMER),
    .DEVICE                         (DEVICE_ENUM)
  ) config_network (
    .clk_dla1x                      (clk_dla),
    .clk_ddr                        (clk_ddr),
    .clk_axi                        (clk_axi),
    .i_aresetn                      (w_resetn_async),
    .i_valid_ddr                    (config_network_input_valid),
    .o_ready                        (config_network_input_ready),  // config network is ready to receive config data
    .i_data_ddr                     (config_network_input_data),
    .o_valid                        (config_network_output_valid),
    .i_ready                        (config_network_output_ready), // module is ready to receive config data from config network
    .o_data                         (config_network_output_data)
  );

  if (ENABLE_DEBUG == 1) begin
    dla_debug_network #(
      .DATA_WIDTH         (DEBUG_NETWORK_DATA_WIDTH),
      .ADDR_WIDTH         (DEBUG_NETWORK_ADDR_WIDTH),
      .ADDR_LOWER         (DEBUG_NETWORK_ADDR_LOWER),
      .NUM_MODULES        (DEBUG_NETWORK_NUM_MODULES)
    ) debug_network (
      .clk                (clk_dla),
      .i_resetn_async     (w_resetn_async),
      .i_csr_arvalid      (debug_network_csr_arvalid),
      .i_csr_araddr       (debug_network_csr_araddr),
      .o_csr_arready      (debug_network_csr_arready),
      .o_csr_rvalid       (debug_network_csr_rvalid),
      .o_csr_rdata        (debug_network_csr_rdata),
      .i_csr_rready       (debug_network_csr_rready),
      .o_dbg_arvalid      (debug_network_dbg_arvalid),
      .o_dbg_araddr       (debug_network_dbg_araddr),
      .i_dbg_arready      (debug_network_dbg_arready),
      .i_dbg_rvalid       (debug_network_dbg_rvalid),
      .i_dbg_rdata        (debug_network_dbg_rdata),
      .o_dbg_rready       (debug_network_dbg_rready)
    );

    dla_interface_profiling_counters #(
      .NUM_INTERFACES     (PC_NUM_INTERFACES),
      .ADDR_WIDTH         (DEBUG_NETWORK_ADDR_LOWER),
      .DATA_WIDTH         (DEBUG_NETWORK_DATA_WIDTH)
    ) interface_profiling_counters (
      .clk                (clk_dla),
      .i_resetn_async     (w_resetn_async),
      .i_snoop_valid      (pc_snoop_valid),
      .i_snoop_ready      (pc_snoop_ready),
      .i_dbg_arvalid      (debug_network_dbg_arvalid[DEBUG_NETWORK_ID_PROFILING_COUNTERS]),
      .i_dbg_araddr       (debug_network_dbg_araddr [DEBUG_NETWORK_ID_PROFILING_COUNTERS]),
      .o_dbg_arready      (debug_network_dbg_arready[DEBUG_NETWORK_ID_PROFILING_COUNTERS]),
      .o_dbg_rvalid       (debug_network_dbg_rvalid [DEBUG_NETWORK_ID_PROFILING_COUNTERS]),
      .o_dbg_rdata        (debug_network_dbg_rdata  [DEBUG_NETWORK_ID_PROFILING_COUNTERS]),
      .i_dbg_rready       (debug_network_dbg_rready [DEBUG_NETWORK_ID_PROFILING_COUNTERS])
    );
  end
  else begin
    assign debug_network_csr_arready = 1'b0;
    assign debug_network_csr_rvalid = 1'b0;
  end
  // From DMA to others
  assign pc_snoop_valid[PC_ID_DMA_TO_CONFIG]              = config_network_input_valid;
  assign pc_snoop_ready[PC_ID_DMA_TO_CONFIG]              = config_network_input_ready;
  assign pc_snoop_valid[PC_ID_DMA_TO_FILTER]              = filter_reader_valid;
  assign pc_snoop_ready[PC_ID_DMA_TO_FILTER]              = filter_reader_ready;
  assign pc_snoop_valid[PC_ID_DMA_TO_INPUT_FEEDER]        = feature_reader_valid;
  assign pc_snoop_ready[PC_ID_DMA_TO_INPUT_FEEDER]        = feature_reader_ready;

  // From config network to others
  assign pc_snoop_valid[PC_ID_CONFIG_TO_INPUT_FEEDER_IN]  = config_network_output_valid[CONFIG_ID_INPUT_FEEDER_IN];
  assign pc_snoop_ready[PC_ID_CONFIG_TO_INPUT_FEEDER_IN]  = config_network_output_ready[CONFIG_ID_INPUT_FEEDER_IN];
  assign pc_snoop_valid[PC_ID_CONFIG_TO_INPUT_FEEDER_OUT] = config_network_output_valid[CONFIG_ID_INPUT_FEEDER_OUT];
  assign pc_snoop_ready[PC_ID_CONFIG_TO_INPUT_FEEDER_OUT] = config_network_output_ready[CONFIG_ID_INPUT_FEEDER_OUT];
  assign pc_snoop_valid[PC_ID_CONFIG_TO_XBAR]             = config_network_output_valid[CONFIG_ID_XBAR];
  assign pc_snoop_ready[PC_ID_CONFIG_TO_XBAR]             = config_network_output_ready[CONFIG_ID_XBAR];
  assign pc_snoop_valid[PC_ID_CONFIG_TO_ACTIVATION]       = pc_config_to_activation_valid;
  assign pc_snoop_ready[PC_ID_CONFIG_TO_ACTIVATION]       = pc_config_to_activation_ready;
  assign pc_snoop_valid[PC_ID_CONFIG_TO_POOL]             = pc_config_to_pool_valid;
  assign pc_snoop_ready[PC_ID_CONFIG_TO_POOL]             = pc_config_to_pool_ready;
  assign pc_snoop_valid[PC_ID_CONFIG_TO_SOFTMAX]          = pc_config_to_softmax_valid;
  assign pc_snoop_ready[PC_ID_CONFIG_TO_SOFTMAX]          = pc_config_to_softmax_ready;

  // From input feeder exit FIFO to sequencer
  assign pc_snoop_valid[PC_ID_INPUT_FEEDER_TO_SEQUENCER]  = pc_input_feeder_to_sequencer_valid;
  assign pc_snoop_ready[PC_ID_INPUT_FEEDER_TO_SEQUENCER]  = pc_input_feeder_to_sequencer_ready;

  // From PE array exit FIFO to xbar (before width adapter)
  assign pc_snoop_valid[PC_ID_PE_ARRAY_TO_XBAR]           = pe_array_output_valid;
  assign pc_snoop_ready[PC_ID_PE_ARRAY_TO_XBAR]           = pe_array_output_ready;

  // At the aux kernel interfaces, which connect to and from the xbar
  assign pc_snoop_valid[PC_ID_XBAR_TO_ACTIVATION]         = pc_xbar_to_activation_valid;
  assign pc_snoop_ready[PC_ID_XBAR_TO_ACTIVATION]         = pc_xbar_to_activation_ready;
  assign pc_snoop_valid[PC_ID_ACTIVATION_TO_XBAR]         = pc_activation_to_xbar_valid;
  assign pc_snoop_ready[PC_ID_ACTIVATION_TO_XBAR]         = pc_activation_to_xbar_ready;
  assign pc_snoop_valid[PC_ID_XBAR_TO_POOL]               = pc_xbar_to_pool_valid;
  assign pc_snoop_ready[PC_ID_XBAR_TO_POOL]               = pc_xbar_to_pool_ready;
  assign pc_snoop_valid[PC_ID_POOL_TO_XBAR]               = pc_pool_to_xbar_valid;
  assign pc_snoop_ready[PC_ID_POOL_TO_XBAR]               = pc_pool_to_xbar_ready;
  assign pc_snoop_valid[PC_ID_XBAR_TO_SOFTMAX]            = pc_xbar_to_softmax_valid;
  assign pc_snoop_ready[PC_ID_XBAR_TO_SOFTMAX]            = pc_xbar_to_softmax_ready;
  assign pc_snoop_valid[PC_ID_SOFTMAX_TO_XBAR]            = pc_softmax_to_xbar_valid;
  assign pc_snoop_ready[PC_ID_SOFTMAX_TO_XBAR]            = pc_softmax_to_xbar_ready;

  // From xbar to others (after width adapters, before clock crossing FIFO for DMA)
  assign pc_snoop_valid[PC_ID_XBAR_TO_INPUT_FEEDER]       = aux_valid;
  assign pc_snoop_ready[PC_ID_XBAR_TO_INPUT_FEEDER]       = aux_ready;
  assign pc_snoop_valid[PC_ID_XBAR_TO_DMA]                = raw_feature_writer_valid;
  assign pc_snoop_ready[PC_ID_XBAR_TO_DMA]                = raw_feature_writer_ready;

endmodule
