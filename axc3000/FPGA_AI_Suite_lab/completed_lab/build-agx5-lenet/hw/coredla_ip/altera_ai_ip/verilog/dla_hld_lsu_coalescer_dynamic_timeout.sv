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

// This is implements the timeout counter for the coalescer. The threshold (how long to wait until timeout) is dynamic, and it turns out that most of the
// information that this module needs for adjusting the timeout threshold occurs naturally as a result of performing coalescing.
//
// For additional info, refer to dla_hld_global_load_store.sv (top module of entire LSU) and dla_hld_lsu.sv (top module of the core LSU).

`default_nettype none

module dla_hld_lsu_coalescer_dynamic_timeout #(
    parameter bit ASYNC_RESET,                  //0 = registers consume reset synchronously, 1 = registers consume reset asynchronously
    parameter int MAX_TIMEOUT_BIT               //limit how large the dynamic timeout threshold can get, max value = (2**MAX_TIMEOUT_BIT)-1
) (
    input  wire     clock,
    input  wire     resetn,
    
    //controls for the timeout itself
    input  wire     i_valid,                    //a new word has been accepted by the coalescer, reset timeout counter
    input  wire     i_disable_timeout,          //downstream is somewhat full, but reset the timeout counter only if timeout has not yet occurred
    output logic    o_timeout,                  //timeout has occurred
    
    //dynamic updates to the timeout threshold
    input  wire     i_coal_if_addr_match,       //would we coalesce if the incoming address is compatible with the captured address (address check is known two clocks later), this signal is on the same pipeline stage as i_valid
    input  wire     i_late_addr_match           //two clocks after i_valid the address compatibility check would have finished, this is that result (whether the incoming address is compatible with the captured address)
);
    
    //this is the bit width of the counter which counts how many consecutive times the coalescing has failed
    //using a 3 bit counter, the 8th coalescing fail will be interpreted as too much random access and therefore the timeout threshold needs to decrease
    //if this counter is made wider, then more consecutive coalescing fails would be needed before the timeout threshold can start decreasing
    //note that the counter clips at the max value, so 9 consecutive coalescing fails will result in 2 decrements to the timeout threshold, 10 consecutive fails results in 3 decrements, etc.
    localparam int NO_COALESCE_COUNT_BITS = 3;
    
    
    
    ///////////////
    //  Signals  //
    ///////////////
    
    //reset
    logic                       aclrn, sclrn, resetn_synchronized;
    
    //coalescer timeout
    logic   [MAX_TIMEOUT_BIT:0] counter;                                    //counter for the coalescer timeout, this is an offset counter and the extra bit allows the msb to be used to detect the timeout
    logic                       counter_msb, late_counter_msb;              //coalescer timeout is detected by negedge msb
    
    //update timeout threshold
    logic                       seen_i_valid;                               //ignore the very first i_valid since there is no previous address to check whether coalescing could have happened
    logic                       late_coal_if_addr_match;                    //delayed version of i_coal_if_addr_match
    logic                       late_i_valid_excluding_first_ever_valid;    //delayed version of i_valid factoring in seen_i_valid
    logic                       previous_timed_out;                         //two clocks after i_valid, did the previous kernel time out (or something else prevented coalescing)
    logic                       addr_match_valid;                           //two clocks after i_valid, result of coalescing is known
    logic                       incr_threshold;                             //increase the timeout threshold if coalescing could have happened (addr match) but previously it timed out
    logic                       decr_threshold;                             //decrease the timeout threshold if lots of random access is detected
    logic [NO_COALESCE_COUNT_BITS-1:0] cannot_coalesce;                     //count how many random access events were seen, don't decrease timeout threshold unless there are many consecutive random accesses
    logic                       threshold_full;                             //look ahead logic to detect when threshold is all ones
    logic                       threshold_empty;                            //look ahead logic to detect when threshold is all zeros
    logic [MAX_TIMEOUT_BIT-1:0] threshold;                                  //the timeout threshold itself
    
    
    
    /////////////
    //  Reset  //
    /////////////

    dla_acl_reset_handler
    #(
        .ASYNC_RESET            (ASYNC_RESET),
        .USE_SYNCHRONIZER       (0),
        .SYNCHRONIZE_ACLRN      (0),
        .PIPE_DEPTH             (0),
        .NUM_COPIES             (1)
    )
    dla_acl_reset_handler_inst
    (
        .clk                    (clock),
        .i_resetn               (resetn),
        .o_aclrn                (aclrn),
        .o_resetn_synchronized  (resetn_synchronized),
        .o_sclrn                (sclrn)
    );
    
    
    
    /////////////////////////
    //  Coalescer Timeout  //
    /////////////////////////
    
    //if MAX_TIMEOUT_BIT = 5, then counter is 6 bits and counts from X down to 31 and then stays there, where X can be as high as 63 and as low as 32
    always_ff @(posedge clock or negedge aclrn) begin
        if (~aclrn) counter <= '0;
        else begin
            if (counter_msb) counter <= counter - 1'b1;
            if (i_valid | (counter_msb & i_disable_timeout)) counter <= {1'b1, threshold};
            if (~sclrn) counter <= '0;
        end
    end
    assign counter_msb = counter[MAX_TIMEOUT_BIT];
    always_ff @(posedge clock) begin
        late_counter_msb <= counter_msb;
    end
    assign o_timeout = ~counter_msb & late_counter_msb; //negedge msb, using the MAX_TIMEOUT_BIT = 5 example above, counter has just gotten to 31
    
    
    
    ////////////////////////////////
    //  Update Timeout Threshold  //
    ////////////////////////////////
    
    always_ff @(posedge clock or negedge aclrn) begin
        if (~aclrn) seen_i_valid <= 1'b0;
        else begin
            if (i_valid) seen_i_valid <= 1'b1;
            if (~sclrn) seen_i_valid <= 1'b0;
        end
    end
    
    always_ff @(posedge clock) begin
        //one clock after i_valid
        late_coal_if_addr_match <= i_coal_if_addr_match;
        late_i_valid_excluding_first_ever_valid <= i_valid & seen_i_valid;
        
        //two clocks after i_valid
        previous_timed_out <= ~late_coal_if_addr_match;
        addr_match_valid <= late_i_valid_excluding_first_ever_valid;
    end
    
    always_ff @(posedge clock or negedge aclrn) begin
        if (~aclrn) begin
            incr_threshold <= 1'b0;
            decr_threshold <= 1'b0;
            cannot_coalesce <= '0;
            threshold_full <= 1'b0;
            threshold_empty <= 1'b1;
            threshold <= '0;
        end
        else begin
            //determine when to increase or decrease the threshold, three clocks after i_valid
            incr_threshold <= 1'b0;
            decr_threshold <= 1'b0;
            if (addr_match_valid) begin         //two clocks after i_valid, result of address check is known, also exclude first ever valid since there is no previous to compare against
                if (i_late_addr_match) begin    //disregarding timeout, this word could have coalesced with previous kernel word
                    if (previous_timed_out) incr_threshold <= 1'b1;     //previous timed out, so increase threshold
                    cannot_coalesce <= '0;
                end
                else begin                      //disregarding timeout, this word cannot have coalesced with previous kernel word
                    if (&cannot_coalesce) decr_threshold <= 1'b1;       //8th consective kernel word that could not coalesce, probably it's random access so decrease threshold
                    else cannot_coalesce <= cannot_coalesce + 1'b1;
                end
            end
            
            //look ahead logic: for threshold to become all ones, decr_threshold cannot be asserted, and either threshold==11111 or threshold=11110 and increasing
            threshold_full <= ~decr_threshold && (&threshold[MAX_TIMEOUT_BIT-1:1]) && (threshold[0] || incr_threshold);
            
            //look ahead logic: for threshold to become all zeros, incr_threshold cannot be asserted, and either threshold=00000 or threshold=00001 and decreasing
            threshold_empty <= ~incr_threshold && (~|threshold[MAX_TIMEOUT_BIT-1:1]) && (~threshold[0] || decr_threshold);
            
            //update the threshold itself, four clocks after i_valid
            if (incr_threshold & ~threshold_full) threshold <= threshold + 1'b1;
            if (decr_threshold & ~threshold_empty) threshold <= threshold - 1'b1;
            
            if (~sclrn) begin
                incr_threshold <= 1'b0;
                decr_threshold <= 1'b0;
                cannot_coalesce <= '0;
                //no reset needed for threshold_full or threshold_empty
                threshold <= '0;
            end
        end
    end

endmodule

`default_nettype wire
