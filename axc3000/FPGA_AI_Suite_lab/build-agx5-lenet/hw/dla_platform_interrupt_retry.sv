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

// This module adds some fault tolerance to the system handling of interrupts.
// In some rare and exotic circumstances, software runtime appears to hang
// waiting for an inference job to finish yet hardware has finished and sent an
// interrupt. CoreDLA was designed with a level interrupt which assumes the
// runtime will be repeatedly interrupted until it services the interrupt. The
// ED1 platform however uses edge interrupts (PCIe MSI), so to imitate the
// assumed level interrupt behavior, keep sending edge interrupts every so often
// as long as the level interrupt is still asserted. The conversion from level
// to edge is downstream from this module, so this module simply masks the level
// interrupt every so often so that it looks like a new interrupt is being sent.
// Note the runtime is already fault tolerant to receiving spurious interrupts
// since the ISR reads the CSR to determine if any new inferences have finished.

`default_nettype none

module dla_platform_interrupt_retry #(
    //TIMEOUT is how many clock cycles until o_interrupt_level_to_platform
    //toggles, starting from the time i_interrupt_level_from_dla asserts.
    parameter int TIMEOUT = 100000  // this is half a millisecond at 200 MHz
) (
    input  wire         clk,
    input  wire         i_resetn_async,

    input  wire         i_interrupt_level_from_dla,
    output logic        o_interrupt_level_to_platform
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



    //timeout_counter counts down from TIMEOUT-2 to -1 inclusive, MSB is the sign bit
    localparam int TIMEOUT_BITS = $clog2(TIMEOUT-1) + 1;
    logic [TIMEOUT_BITS-1:0] timeout_counter;

    //register the incoming interrupt first, then do posedge detection
    logic interrupt_input, interrupt_input_previous;

    //track whether to allow the interrupt through or not
    logic interrupt_mask;

    always_ff @(posedge clk) begin
        interrupt_input <= i_interrupt_level_from_dla;
        interrupt_input_previous <= interrupt_input;

        if (interrupt_input & ~interrupt_input_previous) begin //interrupt just asserted
            timeout_counter <= TIMEOUT - 2;
            interrupt_mask <= 1'b1;
        end
        else if (timeout_counter[TIMEOUT_BITS-1]) begin //down counter has reached ending value of -1
            timeout_counter <= TIMEOUT - 2;
            interrupt_mask <= ~interrupt_mask;
        end
        else begin //free running counter means interrupt_mask keeps flipping, but doesn't matter if interrupt_input == 1'b0
            timeout_counter <= timeout_counter - 1'b1;
        end

        //assumption: once i_interrupt_level_from_dla asserts, it stays asserted for quite some time
        //ultimately it is handshaking with software runtime that will cause it deassert
        o_interrupt_level_to_platform <= interrupt_mask & interrupt_input;

        if (~sclrn) begin
            interrupt_input <= 1'b0;
            interrupt_mask <= 1'b0;
            o_interrupt_level_to_platform <= 1'b0;
        end
    end

endmodule

`default_nettype wire
