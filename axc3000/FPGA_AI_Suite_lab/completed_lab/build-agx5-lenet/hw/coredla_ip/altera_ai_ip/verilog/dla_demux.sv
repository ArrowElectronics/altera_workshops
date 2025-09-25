// Copyright 2020-2024 Altera Corporation.
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

// Description of functionality:
// This module acts as a simple demux to steer data to either one of two outputs
// the module receives config data, which is the select signal, and based on the value
// of the sel signal, the module steers input data to either first or second output
// This module could be generalized in the future to have 1 to many (instead of 1:2)

`resetall
`undefineall
`default_nettype none
`include "dla_acl_parameter_assert.svh"

module dla_demux import dla_common_pkg::*, dla_demux_pkg::*; #(
  // DLA (input data) side parameters
  parameter   int CONFIG_WIDTH                  = 32,
  parameter   int DATA_WIDTH                    = 32
) (
  input  wire                                 clk_dla,
  input  wire                                 i_aresetn,

  // config input
  input  wire  [CONFIG_WIDTH-1:0]             i_config_data,
  input  wire                                 i_config_valid,
  output logic                                o_config_ready,

  // Input Data
  output logic                                o_ready,            // backpressure to upstream
  input  wire                                 i_valid,            // valid from upstream
  input  wire [DATA_WIDTH-1:0]                i_data,             // input data from xbar
  input  wire                                 i_transmitter_done, //upstream done

  // Output 1 Data (select = 0)
  input  wire                                i_1_ready,      // backpressure from downstream 1
  output wire                                o_1_valid,      // valid to downstream 1

  // Output 2 Data (select = 1)
  input  wire                                i_2_ready,      // backpressure from downstream 2
  output wire                                o_2_valid,      // valid to downstream 2

  // Output Data
  output logic [DATA_WIDTH-1:0]              o_data          // Output data
);

// Handle Config data
    logic   [CONFIG_WIDTH-1:0] config_offset;
    logic                      config_done;
    demux_sel_config_t         cfg;
    logic                      select;     // select signal

    localparam int NUM_CONFIG_OFFSETS = divCeil($bits(cfg), CONFIG_WIDTH);

    // For now, ensure size of config is exact multiple of CONFIG_WIDTH
    `DLA_ACL_PARAMETER_ASSERT($bits(cfg) == NUM_CONFIG_OFFSETS * CONFIG_WIDTH);

    //reset parameterization
    localparam int RESET_USE_SYNCHRONIZER = 1;
    localparam int RESET_PIPE_DEPTH       = 3;
    localparam int RESET_NUM_COPIES       = 1;

    logic [RESET_NUM_COPIES-1:0] sclrn;

    /////////////////////////////
    //  Reset Synchronization  //
    /////////////////////////////

    dla_reset_handler_simple #(
        .USE_SYNCHRONIZER   (RESET_USE_SYNCHRONIZER),
        .PIPE_DEPTH         (RESET_PIPE_DEPTH),
        .NUM_COPIES         (RESET_NUM_COPIES)
    ) dla_demux_synchronizer (
        .clk                (clk_dla),
        .i_resetn           (i_aresetn),
        .o_sclrn            (sclrn)
    );

    assign select = cfg.select[0];
    assign o_config_ready = ~config_done;

    always_ff @(posedge clk_dla) begin
        // config state machine
        if (i_config_valid & o_config_ready) begin
            // update progress in accepting NUM_CONFIG_OFFSETS transactions
            if (config_offset == NUM_CONFIG_OFFSETS-1) begin
                config_offset    <= '0;
                config_done <= 1'b1;
            end
            else begin
                config_offset  <= config_offset + 1'b1;
            end
            cfg <= (i_config_data[CONFIG_WIDTH-1:0] << ($bits(cfg) - CONFIG_WIDTH)) | (cfg >> CONFIG_WIDTH);
        end else begin
            // Back to configure state
            if (i_transmitter_done) begin
                config_done <= 0;
            end
        end
        // resetn
        if (~sclrn[0]) begin
            config_done <= 1'b0;
            config_offset <= '0;
            cfg.select <= '0;
        end
    end
// steer input data
    logic i_ready_comb, intermediate_out_valid;
    assign i_ready_comb = config_done ? (select ? i_2_ready : i_1_ready) : 1'b0;
    assign o_1_valid = config_done ? (select ? 1'b0 : intermediate_out_valid) : 1'b0;
    assign o_2_valid = config_done ? (select ? intermediate_out_valid : 1'b0) : 1'b0;

    dla_st_pipeline_stage #(
      .DATA_WIDTH  (DATA_WIDTH   )
    ) inp_pipe_inst (
      .clock       (clk_dla               ),
      .i_resetn    (sclrn[0]              ),
      .o_ready     (o_ready               ),
      .i_valid     (i_valid               ),
      .i_data      (i_data                ),
      .i_ready     (i_ready_comb          ),
      .o_valid     (intermediate_out_valid),
      .o_data      (o_data                )
    );

endmodule
