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

//  AvalonMM Burst Splitter
//
//  This module splits AvalonMM bursts. One can configure it to split only write bursts, split only read bursts, or split both. It is legal to configure this module to not
//  split any bursts, Quaurtus should sweep away all the unused logic and this module should become passthrough wires.
//
//  The interfaces are only the command portion of the AvalonMM interface, it is assumed that the timing of the response path is independent of the command. This is certainly
//  the case when the response path includes readdatavalid, as the read response can happen an arbitraty number of clock cycles later than when the read request was accepted.
//  
//  This module has no capacity, it splits bursts on-the-fly. There is no change in control flow when splitting write bursts since a write burst of length N already takes N
//  clock cycles to transfer (it contains N words of data). Splitting a write burst basically involves calculating the address for the words inside the burst. Conversely, if
//  splitting a read burst, one read request of length N (which can be transferred in 1 clock cycle) will result in N read requests of length 1, and those N read requests
//  need N clock cycles to be transferred. Therefore the burst splitter must stall the upstream interface while these read requests are provided to the downstream interface.
//
//  If this module is configured to split read bursts, there must be a zero-cycle handshake with the upstream interface. If only splitting write bursts, then one may
//  optionally use stall latency handshaking with upstream. Any style of handshaking (stall/valid or stall latency) can be used with the downstream interface, if using stall
//  latency then downstream should provide an almost full signal as backpressure.
//
//  By default, the adder used to calculate the address for words inside a burst is the full width of the address. To improve fmax, we can reduce the adder width, however it
//  has to be known that bursts will not cross some boundary. For example, if it is known that bursts cannot cross a 4096 byte boundary, then adder only needs to span the lower
//  12 bits of the address. Shortening a long carry chain helps to improve fmax, and saves area.
//
//  Required files:
//  - dla_acl_burst_splitter.sv
//  - dla_acl_reset_handler.sv
//  - dla_acl_parameter_assert.svh

`default_nettype none
`include "dla_acl_parameter_assert.svh"

module dla_acl_burst_splitter #(
    //signal width -- all must be at least 1
    parameter int unsigned ADDRESS_WIDTH,       // byte address must be word aligned, e.g. if BYTEENABLE_WIDTH = 4, then address must be 4-byte aligned, bottom 2 bits must be 0
    parameter int unsigned BURSTCOUNT_WIDTH,
    parameter int unsigned BYTEENABLE_WIDTH,    // must be a power of 2, specifies word size
    
    //burst splitting configuration
    parameter bit SPLIT_WRITE_BURSTS = 1,       // 0 means leave writes bursts untouched, 1 means split write bursts
    parameter bit SPLIT_READ_BURSTS = 1,        // likewise for read bursts
    
    //special configuration
    parameter int unsigned BURST_BOUNDARY = 0,  // set to nonzero to specify what address size a burst will not cross, e.g. 12 means bursts cannot cross a 4K boundary
    parameter bit USE_STALL_LATENCY = 0,        // for write burst splitting only where there is no change in control flow (address inside the burst is computed on-the-fly),
                                                // 0 means stall/valid (up_write means we MAY accept it), 1 means stall/latency (up_write means we MUST accept it)
    //reset configuration
    parameter bit ASYNC_RESET = 0,              // how do we use reset: 1 means registers are reset asynchronously, 0 means registers are reset synchronously
    parameter bit SYNCHRONIZE_RESET = 1,        // based on how reset gets to us, what do we need to do: 1 means synchronize reset before consumption (if reset arrives asynchronously), 0 means passthrough (managed externally)
    parameter bit BACKPRESSURE_DURING_RESET = 1,// determine whether up_waitrequest will backpressure during reset, safer to do so but adds combinational logic
    
    //derived parameters
    localparam int unsigned DATA_WIDTH = 8*BYTEENABLE_WIDTH,
    localparam int unsigned ADDRESS_BITS_PER_WORD = $clog2(BYTEENABLE_WIDTH)    // how many lower bits of the byte address are stuck at 0 to ensure it is word aligned
) (
    input  wire                         clock,
    input  wire                         resetn,
    
    //upstream interface - avalon slave
    output logic                        up_waitrequest,
    input  wire                         up_read,
    input  wire                         up_write,
    input  wire     [ADDRESS_WIDTH-1:0] up_address,
    input  wire        [DATA_WIDTH-1:0] up_writedata,
    input  wire  [BYTEENABLE_WIDTH-1:0] up_byteenable,
    input  wire  [BURSTCOUNT_WIDTH-1:0] up_burstcount,
    
    //downstream interface - avalon master
    input  wire                         down_waitrequest,
    output logic                        down_read,
    output logic                        down_write,
    output logic    [ADDRESS_WIDTH-1:0] down_address,
    output logic       [DATA_WIDTH-1:0] down_writedata,
    output logic [BYTEENABLE_WIDTH-1:0] down_byteenable,
    output logic [BURSTCOUNT_WIDTH-1:0] down_burstcount
);

    
    
    //////////////////////////////////////
    //                                  //
    //  Sanity check on the parameters  //
    //                                  //
    //////////////////////////////////////
    
    generate
    `DLA_ACL_PARAMETER_ASSERT(ADDRESS_WIDTH >= 1)
    `DLA_ACL_PARAMETER_ASSERT(BURSTCOUNT_WIDTH >= 1)
    `DLA_ACL_PARAMETER_ASSERT(BYTEENABLE_WIDTH >= 1)
    `DLA_ACL_PARAMETER_ASSERT(BYTEENABLE_WIDTH == 2**ADDRESS_BITS_PER_WORD)
    `DLA_ACL_PARAMETER_ASSERT(BURST_BOUNDARY < ADDRESS_WIDTH)
    `DLA_ACL_PARAMETER_ASSERT(BURST_BOUNDARY == 0 || BURST_BOUNDARY >= ADDRESS_BITS_PER_WORD)
    `DLA_ACL_PARAMETER_ASSERT(USE_STALL_LATENCY == 0 || SPLIT_READ_BURSTS == 0)
    endgenerate
    
    
    
    /////////////
    //         //
    //  Reset  //
    //         //
    /////////////
    
    logic aclrn, sclrn;
    dla_acl_reset_handler
    #(
        .ASYNC_RESET            (ASYNC_RESET),
        .USE_SYNCHRONIZER       (SYNCHRONIZE_RESET),
        .SYNCHRONIZE_ACLRN      (SYNCHRONIZE_RESET),
        .PIPE_DEPTH             (2),
        .NUM_COPIES             (1)
    )
    dla_acl_reset_handler_inst
    (
        .clk                    (clock),
        .i_resetn               (resetn),
        .o_aclrn                (aclrn),
        .o_resetn_synchronized  (),
        .o_sclrn                (sclrn)
    );
    
    
    
    //////////////////////
    //                  //
    //  Burst splitter  //
    //                  //
    //////////////////////
    
    logic                        inside_read_burst;                         //inside a read burst
    logic                        inside_burst;                              //inside some burst -- we are inside a write burst if inside_burst & ~inside_read_burst
    logic [ADDRESS_WIDTH-1:0]    internal_address;                          //address for words inside a burst
    logic [BURSTCOUNT_WIDTH-1:0] internal_burstcount;                       //keep track of how many remaining words are in a burst
    logic                        internal_burstcount_eq_two;                //register the check for internal_burstcount == 2 by looking at how we get into that condition
    logic                        backpressure_during_reset;                 //helper signal which sets up_waitrequest = 1 during reset under various reset configurations
    logic                        backpressure_during_read_burst;            //stall upstream while we split read bursts
    logic [ADDRESS_WIDTH-1:0]    up_address_plus_byteenable_width;          //manually split the bits of the adder in the case where the bursts are known to not cross some boundary
    logic [ADDRESS_WIDTH-1:0]    internal_address_plus_byteenable_width;    //same idea as above
    logic                        down_burstcount_mask;                      //under which conditions should we override down_burstcount to 1
    logic [ADDRESS_WIDTH-1:0]    down_address_raw;                          //before outputting down_address, set the bottom ADDRESS_BITS_PER_WORD bits to 0, Quartus will prune any logic that drove these bits
    
    generate
    if (BURST_BOUNDARY) begin : GEN_SHORT_ADDRESS_ADDER     //burst will not cross a boundary of 2**BURST_BOUNDARY
        assign up_address_plus_byteenable_width[BURST_BOUNDARY-1:0] = up_address[BURST_BOUNDARY-1:0] + BYTEENABLE_WIDTH;                    //only the lower address bits within a burst need the adder
        assign up_address_plus_byteenable_width[ADDRESS_WIDTH-1:BURST_BOUNDARY] = up_address[ADDRESS_WIDTH-1:BURST_BOUNDARY];               //upper bits come directly from the input address
        assign internal_address_plus_byteenable_width[BURST_BOUNDARY-1:0] = internal_address[BURST_BOUNDARY-1:0] + BYTEENABLE_WIDTH;
        assign internal_address_plus_byteenable_width[ADDRESS_WIDTH-1:BURST_BOUNDARY] = internal_address[ADDRESS_WIDTH-1:BURST_BOUNDARY];   //reg holds its value
    end
    else begin : GEN_FULL_ADDRESS_ADDER
        assign up_address_plus_byteenable_width = up_address + BYTEENABLE_WIDTH;
        assign internal_address_plus_byteenable_width = internal_address + BYTEENABLE_WIDTH;
    end
    endgenerate
    
    
    always_ff @(posedge clock or negedge aclrn) begin
        if (~aclrn) begin
            inside_read_burst <= 1'b0;
            inside_burst <= 1'b0;
            internal_address <= '0;
            internal_burstcount <= '0;
            internal_burstcount_eq_two <= 1'b0;
        end
        else begin
            if (~inside_burst) begin
                internal_address <= up_address_plus_byteenable_width;
                internal_burstcount <= up_burstcount;
                internal_burstcount_eq_two <= (up_burstcount == 2);
                
                //whether or not we enter inside a burst for splitting depends on the burst splitting configuration
                if (SPLIT_WRITE_BURSTS && SPLIT_READ_BURSTS) begin      //split both read and write bursts
                    if ((up_read | up_write) & ~down_waitrequest & (up_burstcount != 1)) inside_burst <= 1'b1;
                    if ( up_read             & ~down_waitrequest & (up_burstcount != 1)) inside_read_burst <= 1'b1;
                end
                else if (SPLIT_WRITE_BURSTS) begin                      //split write bursts only
                    if (up_write & (~down_waitrequest | USE_STALL_LATENCY) & (up_burstcount != 1)) inside_burst <= 1'b1;
                    //inside_read_burst will be stuck at 0
                end
                else if (SPLIT_READ_BURSTS) begin                       //split read bursts only
                    if (up_read & ~down_waitrequest & (up_burstcount != 1)) begin
                        inside_burst <= 1'b1;
                        inside_read_burst <= 1'b1;
                    end
                end
                //else no burst splitting, inside_burst and inside_read_burst will both be stuck at 0
            end
            else begin
                //note that USE_STALL_LATENCY applies to the upstream interface, but one can only set USE_STALL_LATENCY = 1 when splitting only write bursts
                //in which case the control flow does not change, i.e. up_waitrequest = down_waitrequest
                if ((~down_waitrequest | USE_STALL_LATENCY) & (backpressure_during_read_burst | up_write)) begin
                    internal_address <= internal_address_plus_byteenable_width;
                    internal_burstcount <= internal_burstcount - 1;
                    internal_burstcount_eq_two <= (internal_burstcount == 3);
                    if (internal_burstcount_eq_two) begin
                        inside_read_burst <= 1'b0;
                        inside_burst <= 1'b0;
                    end
                end
            end
            if (~sclrn) begin
                inside_read_burst <= 1'b0;
                inside_burst <= 1'b0;
            end
        end
    end
    
    //backpressure
    assign backpressure_during_reset = (!BACKPRESSURE_DURING_RESET) ? 1'b0 : (~aclrn) ? 1'b1 : (~sclrn) ? 1'b1 : 1'b0;
    assign backpressure_during_read_burst = (SPLIT_READ_BURSTS) ? inside_read_burst : 1'b0;
    assign up_waitrequest = down_waitrequest | backpressure_during_read_burst | backpressure_during_reset;
    
    //write only data path can simply pass through
    assign down_writedata  = up_writedata;
    assign down_byteenable = up_byteenable;
    
    //if we are inside a burst, the read ack has already gone to upstream so the next transaction is being presented
    assign down_read  = (backpressure_during_read_burst) ? 1'b1 : up_read;
    assign down_write = (backpressure_during_read_burst) ? 1'b0 : up_write;
    
    //original address is used at the beginning of a burst (or if burst was not split), we computed the address inside a burst
    assign down_address_raw = (inside_burst) ? internal_address : up_address;
    
    //set lower ADDRESS_BITS_PER_WORD bits to 0, the lower bits will be pruned away from all logic related to address
    assign down_address = down_address_raw[ADDRESS_WIDTH-1:ADDRESS_BITS_PER_WORD] << ADDRESS_BITS_PER_WORD;
    
    //under what conditions are we splitting a burst, and therefore down_burstcount should be set to 1
    assign down_burstcount_mask = (SPLIT_WRITE_BURSTS && SPLIT_READ_BURSTS) ? 1'b1 : (SPLIT_WRITE_BURSTS) ? down_write : (SPLIT_READ_BURSTS) ? down_read : 1'b0;
    assign down_burstcount = (down_burstcount_mask) ? 1'h1 : up_burstcount;
    
endmodule

`default_nettype wire
