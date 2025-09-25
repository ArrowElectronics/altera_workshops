// Copyright 2015-2020 Altera Corporation.
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

/////////////////////////////////////////////////////////////////////////////////////
//                                                                                 //
//  dla_reset_handler_simple                                                       //
//                                                                                 //
//  This module is a wrapper around dla_acl_reset_handler.  It hard codes many of the  //
//  parameters to that module to align with the reset strategy to be used in the   //
//  coreDLA project.                                                               //
//                                                                                 //
/////////////////////////////////////////////////////////////////////////////////////


`default_nettype none

module dla_reset_handler_simple #(
    parameter bit USE_SYNCHRONIZER,         // set to 1 to enable a clock domain crossing synchronizer, 0 to use i_resetn directly without a synchronizer
    parameter int PIPE_DEPTH,               // number of pipeline stages for synchronous reset outputs (pipeline stages are added AFTER the synchronizer)
                                            // A value of 0 is valid and means the input will be passed straight to the output after the synchronizer chain
    parameter int NUM_COPIES                // number of copies of the synchronous reset output. Minimum value 1.
)(
    input  wire                   clk,
    input  wire                   i_resetn, // this MUST be an active-low reset signal
    output logic [NUM_COPIES-1:0] o_sclrn   // multiple copies of synchronous reset output, with 'dont_merge' constraints applied to the registers that feed them to help with fanout
);

    ///////////////////////////////////////
    // Parameter checking
    //
    // Generate an error if any illegal parameter settings or combinations are used
    ///////////////////////////////////////
    initial /* synthesis enable_verilog_initial_construct */
    begin
        if (PIPE_DEPTH < 0)
            $fatal(1, "Illegal parameterization, requre PIPE_DEPTH >= 0");
        if (NUM_COPIES < 1)
            $fatal(1, "Illegal parameterization, requre NUM_COPIES >= 1");
    end

    dla_acl_reset_handler #(
        .ASYNC_RESET            (0),
        .USE_SYNCHRONIZER       (USE_SYNCHRONIZER),
        .SYNCHRONIZE_ACLRN      (0),
        .PULSE_EXTENSION        (0),
        .PIPE_DEPTH             (PIPE_DEPTH),
        .NUM_COPIES             (NUM_COPIES)
    ) dla_acl_reset_handler_inst (
        .clk                    (clk),
        .i_resetn               (i_resetn),
        .o_aclrn                (),
        .o_sclrn                (o_sclrn),
        .o_resetn_synchronized  ()
    );

endmodule

`default_nettype wire
