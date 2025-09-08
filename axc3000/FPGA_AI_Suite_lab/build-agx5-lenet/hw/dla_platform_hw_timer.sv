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

// Host can estimate the CoreDLA IP clock frequency by doing the following:
// 1. send a start signal
// 2. wait for e.g. 1 second
// 3. send a stop signal
// 4. read back the counter

`default_nettype none

module dla_platform_hw_timer #(
    parameter int COUNTER_WIDTH = 32
) (
    input  wire                         clk,
    input  wire                         i_resetn_async,
    input  wire                         i_start,
    input  wire                         i_stop,
    output logic    [COUNTER_WIDTH-1:0] o_counter
);

    //synchronize the reset
    logic sclrn;
    dla_reset_handler_simple
    #(
        .USE_SYNCHRONIZER       (1),
        .PIPE_DEPTH             (0),
        .NUM_COPIES             (1)
    )
    dla_reset_handler_simple_inst
    (
        .clk                    (clk),
        .i_resetn               (i_resetn_async),
        .o_sclrn                (sclrn)
    );


    //host can control whether the counter is running or not
    //counter goes to 0 when it starts running, so it doesn't need a reset
    logic is_counter_running;
    always_ff @(posedge clk) begin
        if (i_start) is_counter_running <= 1'b1;
        if (i_stop) is_counter_running <= 1'b0;

        if (i_start) o_counter <= '0;
        else if (is_counter_running) o_counter <= o_counter + 1'b1;

        if (~sclrn) begin
            is_counter_running <= 1'b0;
        end
    end

endmodule

`default_nettype wire
