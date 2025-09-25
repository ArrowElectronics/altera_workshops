// Copyright 2020-2020 Altera Corporation.
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



// This is a helper module within dla_platform_reset. For each clock domain, this module synchronizes and
// then pulse extends the reset.

`resetall
`undefineall
`default_nettype none

module dla_platform_reset_internal #(
    parameter int RESET_HOLD_CLOCK_CYCLES   //how many clock cycles to extend how long reset is held for
) (
    input  wire     clk,
    input  wire     i_resetn_combined,
    output logic    o_resetn_pulse_extended
);

    //all registers in this module enter reset asynchronously but exit reset synchronously


    //synchronize the reset
    logic aclrn;

    dla_acl_reset_handler
    #(
        .ASYNC_RESET            (1),
        .SYNCHRONIZE_ACLRN      (1),
        .USE_SYNCHRONIZER       (1),
        .PULSE_EXTENSION        (0),
        .PIPE_DEPTH             (0),
        .NUM_COPIES             (1)
    )
    dla_acl_reset_handler_inst
    (
        .clk                    (clk),
        .i_resetn               (i_resetn_combined),
        .o_aclrn                (aclrn),
        .o_resetn_synchronized  (),
        .o_sclrn                ()
    );


    //pulse extend
    localparam int COUNTER_WIDTH = $clog2(RESET_HOLD_CLOCK_CYCLES) + 1;
    logic [COUNTER_WIDTH-1:0] counter;
    logic dla_ip_sdc_false_path_from_this_resetn;   //don't change this name, used for SDC wildcard naming

    always_ff @(posedge clk or negedge aclrn) begin
        if (~aclrn) begin
            counter <= '0;
            dla_ip_sdc_false_path_from_this_resetn <= 1'b0;
        end
        else begin
            if (counter[COUNTER_WIDTH-1] == 1'b0) begin
                counter <= counter + 1'b1;
            end
            dla_ip_sdc_false_path_from_this_resetn <= counter[COUNTER_WIDTH-1];
        end
    end
    assign o_resetn_pulse_extended = dla_ip_sdc_false_path_from_this_resetn;

endmodule
