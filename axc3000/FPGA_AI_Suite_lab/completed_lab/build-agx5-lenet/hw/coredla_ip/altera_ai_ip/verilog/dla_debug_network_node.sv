// Copyright 2021 Altera Corporation.
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

// This module implements one node in the ring architecture of the debug network. There is shared bus for address and
// data which is passed from node to node around the ring. If everything behaves properly, there would only be one
// outstanding transaction at a time, so address and data will not collide.

// The debug network is fault tolerant to external debug-capable modules not accepting a valid or not producing a response.
// A misbehaving external debug-capable module cannot starve another properly behaving external module of addresses or
// responses. To support this, requests are never backpressured by the debug network. If there is already an outstanding
// request to a misbehaving module, then clobber the address being advertised to the misbehaving module.

// Technically this breaks the AXI-4 spec (data cannot change once valid is asserted), but this only happens if a module
// didn't respond to the read request (either because it never accepted the request or never produced a response). This will
// cause the runtime to treats this as a time out, and it will then move on to issue another read request to some different
// address. If all modules respond within a reasonable amount of time, then the handshaking with the debug network is AXI-4
// conformant. A reasonable amount of time is defined by the runtime, runtime can query CSR for whether it has yet cached
// read response data, runtime may poll this status register a few times before giving up.

// The debug network is also fault tolerant to external debug-capable modules producing spurious read responses. A read
// response is only accepted if a prior read request was accepted.

`resetall
`undefineall
`default_nettype none

module dla_debug_network_node #(
    parameter int DATA_WIDTH,   //width of the read response data, typicall 32
    parameter int ADDR_WIDTH,   //width of the read request address, typically 32
    parameter int ADDR_LOWER,   //how many lower bits of the address are forwarded to external debug-capable module, typically 24
                                //the upper ADDR_WIDTH-ADDR_LOWER bits of address are used to identify the module id
    parameter int MODULE_ID,    //id of this node, if upper addr bits match then forward request to external debug-capable module

    //derived values
    localparam int BUS_WIDTH = (ADDR_WIDTH > DATA_WIDTH) ? ADDR_WIDTH : DATA_WIDTH  //shared bus for address and data, use the larger width
) (
    input  wire                     clk,
    input  wire                     i_sclrn,

    //debug network ring, upstream (connection from previous node in the ring)
    input  wire                     i_up_forced_valid,  //non-backpressurable valid
    input  wire     [BUS_WIDTH-1:0] i_up_shared_bus,    //shared bus for addr/data
    input  wire                     i_up_is_addr,

    //debug network ring, downstream (connection to next node in the ring)
    output logic                    o_down_forced_valid,
    output logic    [BUS_WIDTH-1:0] o_down_shared_bus,
    output logic                    o_down_is_addr,

    //request to external debug-capable module, AXI-4 lite read address channel
    output logic                    o_req_valid,
    output logic   [ADDR_LOWER-1:0] o_req_addr,
    input  wire                     i_req_ready,

    //response from external debug-capable module, AXI-4 lite read response channel
    input  wire                     i_resp_valid,
    input  wire    [DATA_WIDTH-1:0] i_resp_data,
    output logic                    o_resp_ready
);

    // Parameter legality checks already performed in dla_debug_network.sv.

    always_ff @(posedge clk) begin
        //forward shared bus to the next node in the debug network ring
        //response from external debug-capable module overrides this (see below)
        o_down_forced_valid <= 1'b0;
        if (i_up_forced_valid) begin
            o_down_forced_valid <= 1'b1;
            o_down_shared_bus <= i_up_shared_bus;
            o_down_is_addr <= i_up_is_addr;
        end

        //incoming address is for this node, forward it to external debug-capable module
        //note if external module did not accept previous request, the address gets clobbered by new request
        if (i_up_forced_valid & i_up_is_addr & (i_up_shared_bus[ADDR_WIDTH-1:ADDR_LOWER] == MODULE_ID)) begin
            o_req_valid <= 1'b1;
            o_req_addr <= i_up_shared_bus[ADDR_LOWER-1:0];
        end

        //o_req_valid is held high until request accepted by external debug-capable module
        if (o_req_valid & i_req_ready) begin
            o_req_valid <= 1'b0;
            o_resp_ready <= 1'b1;   //read response is only accepted once read request accepted
        end

        //o_resp_ready is held high until response produced by external debug-capable module
        //send the response to next node in the debug network ring
        //yes this may clobber an address, but only happens if exercising the fault tolerance of debug network
        //if everything behaves properly, there would only be one outstanding transaction at a time
        if (i_resp_valid & o_resp_ready) begin
            o_resp_ready <= 1'b0;
            o_down_forced_valid <= 1'b1;
            o_down_shared_bus <= i_resp_data;
            o_down_is_addr <= 1'b0;
        end

        if (~i_sclrn) begin
            o_req_valid <= 1'b0;
            o_resp_ready <= 1'b0;
            o_down_forced_valid <= 1'b0;
        end
    end

endmodule
