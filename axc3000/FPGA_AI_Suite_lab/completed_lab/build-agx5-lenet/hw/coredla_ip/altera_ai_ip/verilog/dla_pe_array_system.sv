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
`default_nettype none

module dla_pe_array_system import dla_common_pkg::*; #(
  dla_sequencer_pkg::sequencer_arch_t                                       SEQUENCER_ARCH,
  dla_filter_bias_scale_scratchpad_pkg::filter_bias_scale_scratchpad_arch_t SCRATCHPAD_ARCH,
  dla_pe_array_pkg::pe_array_arch_t                                         PE_ARRAY_ARCH,
  dla_exit_fifo_pkg::exit_fifo_arch_t                                       EXIT_FIFO_ARCH,
  dla_input_feeder_pkg::input_feeder_arch_t                                 INPUT_FEEDER_ARCH,

  int CONFIG_WIDTH,
  int PE_ARRAY_OUTPUT_DATA_WIDTH,
  int INPUT_FEEDER_INPUT_DATA_WIDTH,
  int FEATURE_READER_WIDTH,
  int FILTER_READER_WIDTH,
  int SCRATCHPAD_LATENCY
) (
  input wire clk,
  input wire i_aresetn,

  // Config bus
  input  wire [CONFIG_WIDTH-1:0]  i_feeder_mux_config_data,
  output wire                     o_feeder_mux_config_ready,
  input  wire                     i_feeder_mux_config_valid,
  input  wire [CONFIG_WIDTH-1:0]  i_feeder_writer_config_data,
  output wire                     o_feeder_writer_config_ready,
  input  wire                     i_feeder_writer_config_valid,
  input  wire [CONFIG_WIDTH-1:0]  i_feeder_in_config_data,
  output wire                     o_feeder_in_config_ready,
  input  wire                     i_feeder_in_config_valid,
  input  wire [CONFIG_WIDTH-1:0]  i_feeder_reader_config_data,
  output wire                     o_feeder_reader_config_ready,
  input  wire                     i_feeder_reader_config_valid,
  input  wire [CONFIG_WIDTH-1:0]  i_feeder_out_config_data,
  output wire                     o_feeder_out_config_ready,
  input  wire                     i_feeder_out_config_valid,

  // Feature data from DDR
  input  wire [FEATURE_READER_WIDTH-1:0] i_feature_input_data,
  output wire                            o_feature_input_ready,
  input  wire                            i_feature_input_valid,

  // Feature data from streaming interface
  input wire [FEATURE_READER_WIDTH-1:0] i_istream_data,
  output wire                           o_istream_ready,
  input wire                            i_istream_valid,

  // Filter data from DDR or on-chip memory
  input  wire [FILTER_READER_WIDTH-1:0] i_filter_data,
  output logic                          o_filter_ready,
  input  wire                           i_filter_valid,

  // Feature data from output of aux kernels
  input  wire [INPUT_FEEDER_INPUT_DATA_WIDTH-1:0] i_xbar_writeback_input_data,
  output wire                                     o_xbar_writeback_input_ready,
  input  wire                                     i_xbar_writeback_input_valid,

  // Output data from the PE array exit FIFO going to aux kernels
  output wire [PE_ARRAY_OUTPUT_DATA_WIDTH-1:0] o_pe_array_output_data,
  input  wire                                  i_pe_array_output_ready,
  output logic                                 o_pe_array_output_valid,

  // Snoop signals for the profiling counters
  output logic o_pc_input_feeder_to_sequencer_valid,
  output logic o_pc_input_feeder_to_sequencer_ready,

  output wire  o_first_word_received
);

  // input feeder output signals
  logic                                     input_feeder_valid;
  dla_interface_pkg::input_feeder_control_t input_feeder_control;
  input_feeder_feature_if#(dla_input_feeder_pkg::input_feeder_feature_if_from_arch(INPUT_FEEDER_ARCH))   input_feeder_data();
  logic                                     input_feeder_ready;

  localparam result_param = dla_pe_array_pkg::pe_array_result_param_from_pe_array_arch(PE_ARRAY_ARCH);
  localparam control_param = dla_pe_array_pkg::pe_array_control_param_from_pe_array_arch(PE_ARRAY_ARCH);
  localparam scratchpad_param = dla_filter_bias_scale_scratchpad_pkg::scratchpad_param_from_scratchpad_arch(SCRATCHPAD_ARCH);
  localparam GROUP_DELAY = PE_ARRAY_ARCH.GROUP_DELAY;

  // pe_array interfaces
  pe_array_feature_if#(PE_ARRAY_ARCH) pe_array_feature();
  pe_array_filter_if#(PE_ARRAY_ARCH)  pe_array_filter();
  pe_array_bias_if#(PE_ARRAY_ARCH)    pe_array_bias();
  pe_array_scale_if#(PE_ARRAY_ARCH)   pe_array_scale();
  pe_array_control_if#(control_param) pe_array_control();
  pe_array_result_if#(result_param)   pe_array_result();

  // filter scratchpad interfaces
  logic                                       scratchpad_write_enable;
  logic                                       scratchpad_read;
  scratchpad_write_addr_if#(scratchpad_param) scratchpad_write_addr();
  scratchpad_write_data_if#(SCRATCHPAD_ARCH)  scratchpad_filter_data();
  scratchpad_read_addr_if#(scratchpad_param)  scratchpad_read_addr();
  scratchpad_read_data_if#(SCRATCHPAD_ARCH)   scratchpad_read_data();

  // exit fifo output interfaces
  logic                                                   exit_fifo_almost_full;
  pe_array_result_if#(result_param)                       exit_fifo_output_data();
  dla_exit_fifo_pkg::exit_fifo_debug_t                    exit_fifo_debug;

  // Convert scratchpad_read_data_t to pe_array_*_t
  for (genvar pe_port = 0; pe_port < SCRATCHPAD_ARCH.NUM_PE_PORTS; pe_port++) begin
    localparam int pe_idx     = pe_port / PE_ARRAY_ARCH.NUM_FILTERS;
    localparam int filter_idx = pe_port % PE_ARRAY_ARCH.NUM_FILTERS;
    assign pe_array_filter.data[pe_idx][filter_idx].valid    = scratchpad_read_data.data.ports[pe_port].valid;
    assign pe_array_filter.data[pe_idx][filter_idx].mantissa = scratchpad_read_data.data.ports[pe_port].filter.mantissa;
    assign pe_array_filter.data[pe_idx][filter_idx].exponent = scratchpad_read_data.data.ports[pe_port].filter.exponent;

    // TODO: [shaneoco] save the area from dla_delay on the bias by delaying
    // the bias read address on the scratchpad instead

    assign pe_array_scale.data[pe_idx][filter_idx] = scratchpad_read_data.data.ports[pe_port].scale;
    assign pe_array_bias.data[pe_idx][filter_idx]  = scratchpad_read_data.data.ports[pe_port].bias;
  end

  dla_sequencer #(SEQUENCER_ARCH) sequencer (
    .clk                      (clk),
    .i_aresetn                (i_aresetn),

    // input_feeder control signals
    .i_input_feeder_valid     (input_feeder_valid),
    .i_input_feeder_control   (input_feeder_control),
    .o_input_feeder_ready     (input_feeder_ready),

    // filter_reader control signals
    .i_filter_reader_valid    (i_filter_valid),
    .i_filter_reader_is_bias  (!scratchpad_filter_data.data.is_filter),
    .o_filter_reader_ready    (o_filter_ready),

    // scratchpad control signals
    .o_scratchpad_write_enable(scratchpad_write_enable),
    .o_scratchpad_write_addr  (scratchpad_write_addr),
    .o_scratchpad_read_addr   (scratchpad_read_addr),
    .o_scratchpad_read        (scratchpad_read),

    // pe_array control signals
    .o_pe_array_control       (pe_array_control),

    // exit_fifo control signals
    .i_exit_fifo_almost_full  (exit_fifo_almost_full)
  );

  // TODO(kimjinhe): for now I'm using unpacked xbar input data for lane but everywhere else it's
  // packed so I need to make it consistent.
  logic [FEATURE_READER_WIDTH-1:0] xbar_input_data [PE_ARRAY_ARCH.NUM_LANES-1:0];
  for (genvar lane_idx = 0; lane_idx < PE_ARRAY_ARCH.NUM_LANES; lane_idx++) begin : GEN_XBAR_ASSIGN
    assign xbar_input_data[lane_idx] = i_xbar_writeback_input_data[(lane_idx+1)*FEATURE_READER_WIDTH-1:lane_idx*FEATURE_READER_WIDTH];
  end

  dla_input_feeder #(INPUT_FEEDER_ARCH) input_feeder (
    .clk                        (clk),
    .i_resetn_async             (i_aresetn),

    .i_config_feeder_in_data    (i_feeder_in_config_data),
    .i_config_feeder_in_valid   (i_feeder_in_config_valid),
    .o_config_feeder_in_ready   (o_feeder_in_config_ready),

    .i_config_writer_mux_data   (i_feeder_mux_config_data),
    .i_config_writer_mux_valid  (i_feeder_mux_config_valid),
    .o_config_writer_mux_ready  (o_feeder_mux_config_ready),

    .i_config_writer_addr_data  (i_feeder_writer_config_data),
    .i_config_writer_addr_valid (i_feeder_writer_config_valid),
    .o_config_writer_addr_ready (o_feeder_writer_config_ready),

    .i_config_feeder_out_data   (i_feeder_out_config_data),
    .i_config_feeder_out_valid  (i_feeder_out_config_valid),
    .o_config_feeder_out_ready  (o_feeder_out_config_ready),

    .i_config_reader_data       (i_feeder_reader_config_data),
    .i_config_reader_valid      (i_feeder_reader_config_valid),
    .o_config_reader_ready      (o_feeder_reader_config_ready),

    .i_ddr_data                 (i_feature_input_data),
    .i_ddr_valid                (i_feature_input_valid),
    .o_ddr_ready                (o_feature_input_ready),

    .i_istream_data             (i_istream_data),
    .o_istream_ready            (o_istream_ready),
    .i_istream_valid            (i_istream_valid),

    .i_xbar_data                (xbar_input_data),
    .i_xbar_valid               (i_xbar_writeback_input_valid),
    .o_xbar_ready               (o_xbar_writeback_input_ready),

    .i_input_feeder_ready       (input_feeder_ready),
    .o_input_feeder_valid       (input_feeder_valid),
    .o_input_feeder_control     (input_feeder_control),
    .o_input_feeder_data        (input_feeder_data),

    .o_first_word_received      (o_first_word_received)
  );


  dla_filter_ddr_unpack #(
    .SCRATCHPAD_ARCH(SCRATCHPAD_ARCH),
    .DDR_WIDTH(FILTER_READER_WIDTH)
  ) filter_ddr_unpack (
    .i_ddr_data              (i_filter_data),
    .o_scratchpad_filter_data(scratchpad_filter_data)
  );

  dla_filter_bias_scale_scratchpad #(SCRATCHPAD_ARCH) scratchpad (
    .clk           (clk),

    .i_write_enable(scratchpad_write_enable),
    .i_write_addr  (scratchpad_write_addr),
    .i_write_data  (scratchpad_filter_data),

    .i_read        (scratchpad_read),
    .i_read_addr   (scratchpad_read_addr),
    .o_read_data   (scratchpad_read_data)
  );

  for (genvar lane_idx = 0; lane_idx < PE_ARRAY_ARCH.NUM_LANES; lane_idx++) begin : GEN_LANE_ASSIGN
    // TODO: [shaneoco] move this calculation to a central place
    localparam int PE_FEATURE_WIDTH =
      ((PE_ARRAY_ARCH.DOT_SIZE * PE_ARRAY_ARCH.FEATURE_WIDTH)
        + PE_ARRAY_ARCH.FEATURE_EXPONENT_WIDTH) * PE_ARRAY_ARCH.NUM_FEATURES;
    dla_delay #(
      .WIDTH(PE_FEATURE_WIDTH),
      .DELAY(SCRATCHPAD_LATENCY),
      .DEVICE(PE_ARRAY_ARCH.DEVICE)
    ) feature_data_reg (
      .clk(clk),
      .i_data(input_feeder_data.data[lane_idx]),
      .o_data(pe_array_feature.data[lane_idx])
    );
  end

  dla_pe_array #(.arch(PE_ARRAY_ARCH)) pe_array (
    .clk      (clk),
    .i_aresetn(i_aresetn),
    .i_feature(pe_array_feature),
    .i_filter (pe_array_filter),
    .i_bias   (pe_array_bias),
    .i_scale  (pe_array_scale),
    .i_control(pe_array_control),
    .o_result (pe_array_result)
  );

  dla_exit_fifo #(EXIT_FIFO_ARCH) exit_fifo (
    .clk          (clk),
    .i_aresetn    (i_aresetn),
    .i_data       (pe_array_result),
    .i_ready      (i_pe_array_output_ready),
    .o_data       (exit_fifo_output_data),
    .o_almost_full(exit_fifo_almost_full),
    .o_debug      (exit_fifo_debug)
  );

  assign o_pe_array_output_data = exit_fifo_output_data.data.result;
  assign o_pe_array_output_valid = exit_fifo_output_data.data.valid;

  // Snoop signals for the profiling counters
  assign o_pc_input_feeder_to_sequencer_valid = input_feeder_valid & input_feeder_control.feature_valid;
  assign o_pc_input_feeder_to_sequencer_ready = input_feeder_ready;

endmodule
