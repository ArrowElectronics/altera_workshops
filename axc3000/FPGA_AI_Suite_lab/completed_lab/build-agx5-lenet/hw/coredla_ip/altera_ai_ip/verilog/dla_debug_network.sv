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

// This is the top module for the debug network. At a high level, it forwards read requests from the CSR to one of many
// externally-attached debug-capable modules. This can be used to make hardware profiling counters readable over the CSR,
// for example. The upper bits of the address (typically 8 bits) are used to decide which debug-capable module to forward
// the read request to). The lower bits of the address (typically 24 bits) are forwarded to the debug-capable module.

// To perform one debug network read, the runtime must follow the scheme below:
// 1. Send the debug network read address to hardware
//    - write to the CSR, this will trigger a read request to debug network
//    - the value written to CSR is the read address sent to debug network
// 2. Wait for CSR to cache the response data from debug network
//    - runtime can poll a status register
//    - in case something has gone wrong, runtime may give up after a few tries i.e. transaction timed out
// 3. Collect the debug network read data from hardware
//    - read the cached value from the CSR

// The handshaking above was developed so that no matter what happens in the debug network, the CSR will never get stuck
// in some bad state. Furthermore, the debug network itself is fault tolerant to externally-attached debug-capable modules
// not accepting requests or not producing responses.

// Under normal operation (no utilization of fault tolerance), there should only be at most one outstanding transaction at
// any time on the debug network. The architecture of the debug network is a ring with a shared data path between address and
// data. Each node on the ring interfaces with one external debug-capable module. For one transaction, the following happens:
// 1. address is sent around the debug network ring until one node decodes it for itself
// 2. this node forwards the read request to that external debug-capable module
// 3. this node collects the read response
// 4. response data is sent around the debug network ring

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
`include "dla_acl_parameter_assert.svh"

module dla_debug_network #(
    parameter int DATA_WIDTH,   //width of the read response data, typically 32
    parameter int ADDR_WIDTH,   //width of the read request address, typically 32
    parameter int ADDR_LOWER,   //how many lower bits of the address are forwarded to external debug-capable module, typically 24
                                //the upper ADDR_WIDTH-ADDR_LOWER bits of address are used to identify the module id
    parameter int NUM_MODULES   //how many external debug-capable modules are attached, module id goes from 0 to NUM_MODULES-1
) (
    input  wire                     clk,
    input  wire                     i_resetn_async,     //active low reset that has NOT been synchronized to any clock

    //read request from csr, AXI-4 lite read address channel
    input  wire                     i_csr_arvalid,
    input  wire    [ADDR_WIDTH-1:0] i_csr_araddr,
    output logic                    o_csr_arready,

    //read response to csr, AXI-4 lite read response channel
    output logic                    o_csr_rvalid,
    output logic   [DATA_WIDTH-1:0] o_csr_rdata,
    input  wire                     i_csr_rready,

    //read request forwarded to external debug-capable modules, AXI-4 lite read address channels
    output logic                    o_dbg_arvalid [NUM_MODULES-1:0],
    output logic   [ADDR_LOWER-1:0] o_dbg_araddr  [NUM_MODULES-1:0],
    input  wire                     i_dbg_arready [NUM_MODULES-1:0],

    //read responses collected from external debug-capable modules, AXI-4 lite read response channels
    input  wire                     i_dbg_rvalid  [NUM_MODULES-1:0],
    input  wire    [DATA_WIDTH-1:0] i_dbg_rdata   [NUM_MODULES-1:0],
    output logic                    o_dbg_rready  [NUM_MODULES-1:0]
);

    // Parameter legality checks
    // Non-trivial data widths
    `DLA_ACL_PARAMETER_ASSERT(DATA_WIDTH >= 1)
    `DLA_ACL_PARAMETER_ASSERT(ADDR_WIDTH >= 1)
    `DLA_ACL_PARAMETER_ASSERT(ADDR_LOWER >= 1)
    `DLA_ACL_PARAMETER_ASSERT(NUM_MODULES >= 1)

    // Must have some upper address bits for the module id
    `DLA_ACL_PARAMETER_ASSERT(ADDR_WIDTH > ADDR_LOWER)

    // Module id must be representable on the ADDR_WIDTH-ADDR_LOWER upper bits of the address
    `DLA_ACL_PARAMETER_ASSERT(NUM_MODULES <= 2**(ADDR_WIDTH-ADDR_LOWER))



    // Reset synchronizer
    logic sclrn;
    dla_reset_handler_simple #(
        .USE_SYNCHRONIZER   (1),
        .PIPE_DEPTH         (1),
        .NUM_COPIES         (1)
    )
    reset_synchronizer
    (
        .clk                (clk),
        .i_resetn           (i_resetn_async),
        .o_sclrn            (sclrn)
    );



    // Shared bus for address and data, use the larger width
    localparam int BUS_WIDTH = (ADDR_WIDTH > DATA_WIDTH) ? ADDR_WIDTH : DATA_WIDTH;

    logic                   ring_forced_valid [NUM_MODULES:0];
    logic   [BUS_WIDTH-1:0] ring_shared_bus   [NUM_MODULES:0];
    logic                   ring_is_addr      [NUM_MODULES:0];



    // Generate the ring, each node decodes the address and interfaces with one external debug-capable module
    genvar g;
    for (g=0; g<NUM_MODULES; g++) begin : GEN_RING
        dla_debug_network_node
        #(
            .DATA_WIDTH             (DATA_WIDTH),
            .ADDR_WIDTH             (ADDR_WIDTH),
            .ADDR_LOWER             (ADDR_LOWER),
            .MODULE_ID              (g)
        )
        dla_debug_network_node_inst
        (
            .clk                    (clk),
            .i_sclrn                (sclrn),

            //debug network ring, upstream (connection from previous node in the ring)
            .i_up_forced_valid      (ring_forced_valid[g]),
            .i_up_shared_bus        (ring_shared_bus  [g]),
            .i_up_is_addr           (ring_is_addr     [g]),

            //debug network ring, downstream (connection to next node in the ring)
            .o_down_forced_valid    (ring_forced_valid[g+1]),
            .o_down_shared_bus      (ring_shared_bus  [g+1]),
            .o_down_is_addr         (ring_is_addr     [g+1]),

            //request to external debug-capable module, AXI-4 lite read address channel
            .o_req_valid            (o_dbg_arvalid[g]),
            .o_req_addr             (o_dbg_araddr [g]),
            .i_req_ready            (i_dbg_arready[g]),

            //response from external debug-capable module, AXI-4 lite read response channel
            .i_resp_valid           (i_dbg_rvalid[g]),
            .i_resp_data            (i_dbg_rdata [g]),
            .o_resp_ready           (o_dbg_rready[g])
        );
    end



    // Debug network ring does not support backpressure. Under normal operation, there would only be one outstanding
    // transaction at any time. If fault tolernace is needed, the scheme is to clobber the address if a node in the
    // debug network ring is already asserting read request valid to its external debug-capable module.
    assign o_csr_arready = 1'b1;

    // Start of ring is the address from CSR
    assign ring_forced_valid[0] = i_csr_arvalid;
    assign ring_shared_bus  [0] = i_csr_araddr;
    assign ring_is_addr     [0] = 1'b1;



    // Cache the most recent read response data from the exit of the ring, in case CSR read response is backpressuring
    always_ff @(posedge clk) begin
        if (ring_forced_valid[NUM_MODULES] & !ring_is_addr[NUM_MODULES]) begin
            o_csr_rvalid <= 1'b1;
            o_csr_rdata  <= ring_shared_bus[NUM_MODULES];
        end
        if (o_csr_rvalid & i_csr_rready) begin
            o_csr_rvalid <= 1'b0;
        end
        if (~sclrn) begin
            o_csr_rvalid <= 1'b0;
        end
    end

endmodule
