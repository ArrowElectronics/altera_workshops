// Copyright 2020 Altera Corporation.
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

// this is a wrapper around dla_hld_fifo using WIDTH=0 and without i_data and o_data ports so that backend doesn't complain about unused ports
// for a description of the parameters and ports, refer to dla_hld_fifo.sv
// beware if this is used for occupancy tracking with STYLE = "ll" or "zl", occupancy tracking is 1-hot, not ideal for large DEPTH
// setting the STYLE parameter will affect write-to-read latency, and this affects e.g. how soon almost empty deasserts due to a write


`default_nettype none

module dla_hld_fifo_zero_width #(
    parameter int DEPTH,
    parameter int ALMOST_EMPTY_CUTOFF = 0,
    parameter int ALMOST_FULL_CUTOFF = 0,
    parameter int INITIAL_OCCUPANCY = 0,
    parameter bit ASYNC_RESET = 0,
    parameter bit SYNCHRONIZE_RESET = 1,
    parameter bit RESET_EVERYTHING = 0,
    parameter bit RESET_EXTERNALLY_HELD = 1,
    parameter int STALL_IN_EARLINESS = 0,
    parameter int VALID_IN_EARLINESS = 0,
    parameter int REGISTERED_DATA_OUT_COUNT = 0,
    parameter bit NEVER_OVERFLOWS = 0,
    parameter bit HOLD_DATA_OUT_WHEN_EMPTY = 0,
    parameter bit WRITE_AND_READ_DURING_FULL = 0,
    parameter bit USE_STALL_LATENCY_UPSTREAM = 0,
    parameter bit USE_STALL_LATENCY_DOWNSTREAM = 0,
    parameter string RAM_BLOCK_TYPE = "AUTO",
    parameter string STYLE = "hs",
    // Enable error correction coding. This module doesn't really have storage, so it doesn't 
    // really need ecc, but to avoid the coverage tests to flag it, ecc param and port is added.
    parameter enable_ecc = "FALSE"
)
(
    input  wire                 clock,          
    input  wire                 resetn, 
    input  wire                 i_valid,
    output logic                o_stall,
    output logic                o_almost_full,
    output logic                o_valid,
    input  wire                 i_stall,
    output logic                o_almost_empty,
    output logic                o_empty,
    output logic          [1:0] ecc_err_status  // ecc status signals
);
    
    // for simulation testbench only, these are properties of the fifo which are consumed by the testbench
    // synthesis translate_off
    logic fifo_in_reset;
    int WRITE_TO_READ_LATENCY;
    int RESET_EXT_HELD_LENGTH;
    int MAX_CLOCKS_TO_ENTER_SAFE_STATE;
    int MAX_CLOCKS_TO_EXIT_SAFE_STATE;
    assign fifo_in_reset = dla_hld_fifo_inst.fifo_in_reset;
    assign WRITE_TO_READ_LATENCY = dla_hld_fifo_inst.WRITE_TO_READ_LATENCY;
    assign RESET_EXT_HELD_LENGTH = dla_hld_fifo_inst.RESET_EXT_HELD_LENGTH;
    assign MAX_CLOCKS_TO_ENTER_SAFE_STATE = dla_hld_fifo_inst.MAX_CLOCKS_TO_ENTER_SAFE_STATE;
    assign MAX_CLOCKS_TO_EXIT_SAFE_STATE = dla_hld_fifo_inst.MAX_CLOCKS_TO_EXIT_SAFE_STATE;
    // synthesis translate_on
    
    dla_hld_fifo
    #(
        .WIDTH                          (0),
        .DEPTH                          (DEPTH),
        .ALMOST_EMPTY_CUTOFF            (ALMOST_EMPTY_CUTOFF),
        .ALMOST_FULL_CUTOFF             (ALMOST_FULL_CUTOFF),
        .INITIAL_OCCUPANCY              (INITIAL_OCCUPANCY),
        .ASYNC_RESET                    (ASYNC_RESET),
        .SYNCHRONIZE_RESET              (SYNCHRONIZE_RESET),
        .RESET_EVERYTHING               (RESET_EVERYTHING),
        .RESET_EXTERNALLY_HELD          (RESET_EXTERNALLY_HELD),
        .REGISTERED_DATA_OUT_COUNT      (REGISTERED_DATA_OUT_COUNT),
        .NEVER_OVERFLOWS                (NEVER_OVERFLOWS),
        .STALL_IN_EARLINESS             (STALL_IN_EARLINESS),
        .VALID_IN_EARLINESS             (VALID_IN_EARLINESS),
        .HOLD_DATA_OUT_WHEN_EMPTY       (HOLD_DATA_OUT_WHEN_EMPTY),
        .WRITE_AND_READ_DURING_FULL     (WRITE_AND_READ_DURING_FULL),
        .USE_STALL_LATENCY_UPSTREAM     (USE_STALL_LATENCY_UPSTREAM),
        .USE_STALL_LATENCY_DOWNSTREAM   (USE_STALL_LATENCY_DOWNSTREAM),
        .RAM_BLOCK_TYPE                 (RAM_BLOCK_TYPE),
        .STYLE                          (STYLE),
        .enable_ecc                     (enable_ecc)
    )
    dla_hld_fifo_inst
    (
        .clock                          (clock),
        .resetn                         (resetn),
        .i_valid                        (i_valid),
        .i_data                         (),                 //unused
        .o_stall                        (o_stall),
        .o_almost_full                  (o_almost_full),
        .o_valid                        (o_valid),
        .o_data                         (),                 //unused
        .i_stall                        (i_stall),
        .o_almost_empty                 (o_almost_empty),
        .o_empty                        (o_empty),
        .ecc_err_status                 (ecc_err_status)
    );
    
endmodule

`default_nettype wire
