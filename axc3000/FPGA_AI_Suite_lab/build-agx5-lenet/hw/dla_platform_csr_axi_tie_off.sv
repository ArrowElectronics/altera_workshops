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



// The platform currently has 2 CSR and DDR interfaces, which is intended for 2 instances of CoreDLA.
// It is possible to compile the platform with only 1 CoreDLA instance, either to save compile time
// or because the instance is so large that 2 copies no longer fits on the FPGA. In this case, need
// to tie off the CSR AXI interface, respond to read and write requests.

// This tie off has always existed, however it was much simpler with Avalon because Avalon does not
// expect a write response, and Avalon read data cannot be backpressured. To implement an AXI tie off,
// use a similar state machine to the CoreDLA DMA CSR.

// A similar tie off also exists for the DDR interface, however tying off a master is much simpler
// since that basically involves not sending any requests.


`resetall
`undefineall
`default_nettype none

module dla_platform_csr_axi_tie_off #(
    parameter int CSR_DATA_WIDTH
) (
    input  wire                         clk,
    input  wire                         i_resetn_async,

    //axi read channels
    input  wire                         i_arvalid,
    output logic                        o_arready,
    output logic                        o_rvalid,
    output logic   [CSR_DATA_WIDTH-1:0] o_rdata,
    input  wire                         i_rready,

    //axi write channels
    input  wire                         i_awvalid,
    output logic                        o_awready,
    input  wire                         i_wvalid,
    output logic                        o_wready,
    output logic                        o_bvalid,
    input  wire                         i_bready
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


    //axi read tie off
    logic outstanding_read;
    assign o_rdata = '0;
    always_ff @(posedge clk) begin
        if (outstanding_read == 1'b0) begin
            //backpressure until read request is seen
            o_arready <= 1'b0;
            o_rvalid <= 1'b0;
            if (i_arvalid) begin
                outstanding_read <= 1'b1;
                o_arready <= 1'b1;
            end
        end
        else begin  //outstanding_read == 1'b1
            //assert response until accepted
            o_arready <= 1'b0;
            o_rvalid <= 1'b1;
            if (o_rvalid & i_rready) begin
                outstanding_read <= 1'b0;
                o_rvalid <= 1'b0;
            end
        end

        if (~sclrn) begin
            outstanding_read <= 1'b0;
            o_arready <= 1'b0;
            o_rvalid <= 1'b0;
        end
    end



    //axi write tie off
    logic outstanding_write;
    always_ff @(posedge clk) begin
        if (outstanding_write == 1'b0) begin
            //backpressure until write request is seen
            o_awready <= 1'b0;
            o_wready <= 1'b0;
            o_bvalid <= 1'b0;
            if (i_awvalid & i_wvalid) begin
                outstanding_write <= 1'b1;
                o_awready <= 1'b1;
                o_wready <= 1'b1;
            end
        end
        else begin  //outstanding_write == 1'b1
            //assert response until accepted
            o_awready <= 1'b0;
            o_wready <= 1'b0;
            o_bvalid <= 1'b1;
            if (o_bvalid & i_bready) begin
                outstanding_write <= 1'b0;
                o_bvalid <= 1'b0;
            end
        end

        if (~sclrn) begin
            outstanding_write <= 1'b0;
            o_awready <= 1'b0;
            o_wready <= 1'b0;
            o_bvalid <= 1'b0;
        end
    end

endmodule
