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

// This module performs two things for the LSU:
// 1. (Required) Generate information for the unaligned controller such as how many memory words each kernel word spans,
// 2. (Optional) Detect whether many kernel words can be coalesced into the same memory word, or more accurately is last address of kernel word N inside the same memory address as the first address of kernel word N+1
//
// For additional info, refer to dla_hld_global_load_store.sv (top module of entire LSU) and dla_hld_lsu.sv (top module of the core LSU).

`default_nettype none

module dla_hld_lsu_word_coalescer #(
    parameter bit ASYNC_RESET,                  //0 = registers consume reset synchronously, 1 = registers consume reset asynchronously
    parameter int ADDR_WIDTH,                   //width of address bus, for addresses that are byte addresses
    parameter int ADDR_ALIGNMENT_BITS,          //indicates how many least significant bits of i_address are known to be 0, e.g. set this parameter to 3 if kernel accesses are 8-byte aligned
    parameter int INTRA_ADDR_WIDTH,             //how many least significant bits of the byte address represent the location inside a memory word
    parameter int KER_DATA_BYTES,               //width of kernel data path in bytes, does not need to be a power of 2
    parameter int KER_DATA_BYTES_LAST,          //in case width adaption is used in dla_hld_global_load_store, the last slice of the kernel data path may be smaller
    parameter bit ENABLE_WORD_COALESCE,         //whether to coalesce kernel words together within the same memory word
    parameter bit HIGH_THROUGHPUT_MODE,         //0 = use N clock cycles to process a kernel word that spans N memory words, 1 = use minimum amount of time to process kernel words, only matters if N >= 2
    parameter int MAX_MEM_WORDS_PER_KER_WORD,   //trim some logic if it is guaranteed that each kernel word can only span 1 or 2 memory words
    parameter int MLAB_FIFO_DEPTH,              //use a shallow fifo if handshaking is expected to take a few clocks (or if capacity can be borrowed from a nearby deep fifo), if we need an MLAB may as well use all of it
    parameter int WRITEACK_WIDTH,               //writeack fifo indicate how many valids to release upon writeack, it uses narrow m20k, word coalescer stops to ensure value doesn't overflow narrow m20k width
    parameter int WORD_COAL_MAX_TIMEOUT_BIT     //limit how large the dynamic timeout threshold can get inside word coalescer
) (
    input  wire                         clock,
    input  wire                         resetn,
    
    //kernel upstream
    input  wire                         i_valid,                    //this is stall latency valid, transaction must be accepted, also only non-predicated transactions arrive here
    input  wire                         i_more_wide_sections,       //if using kernel width adaptation, this indicates there are more sections of the same kernel word still to come
    input  wire        [ADDR_WIDTH-1:0] i_addr,                     //byte address of incoming transaction
    
    //ignore coalescer timeout if downstream is sufficiently far away from being empty
    input  wire                         i_disable_coalescer_timeout,
    
    //read side of cmd fifo
    input  wire                         i_cmd_fifo_rd_ack,          //read from the cmd fifo
    output logic                        o_cmd_fifo_empty,           //cmd fifo is empty
    output logic                        o_cmd_can_coalesce,         //indicates the last memory word that kernel word N touches is the same as the first memory word that kernel N+1 touches
    output logic                        o_cmd_spans_two,            //kernel word N spans at least 2 memory words
    output logic                        o_cmd_spans_three,          //kernel word N spans 3 memory words
    output logic                        o_cmd_needs_second_cycle,   //kernel word N needs at least 2 clock cycles to process
    output logic                        o_cmd_needs_third_cycle,    //kernel word N needs 3 clock cycles to process
    output logic                        o_cmd_more_wide_sections,   //this is just i_more_wide_sections kept live
    output logic [INTRA_ADDR_WIDTH-1:0] o_cmd_addr,                 //within a memory word, what is the address of the first byte that kernel word N touches
    output logic [INTRA_ADDR_WIDTH-1:0] o_cmd_addr_modulo           //the above modulo KER_DATA_BYTES, this is used by the write data aligner when the kernel width is much narrower than the memory width
);
    
    //total width of the cmd fifo, but some output bits are masked or ignored so quartus may trim things
    localparam int CMD_FIFO_WIDTH = 2*INTRA_ADDR_WIDTH + 6;
    
    //a tessellated adder is used to calculate the last byte address, this specifies the index where the adder carry-chain is cut for a pipeline stage
    //ideally this is done in the middle of the adder, but in order to guarantee a single carry-out from the lower bits, tessellation index must be above the max range of the adder on the lower bits
    localparam int TESS_INDEX = ((ADDR_WIDTH/2) < (INTRA_ADDR_WIDTH+2)) ? (INTRA_ADDR_WIDTH+2) : (ADDR_WIDTH/2);
    
    
    
    ///////////////
    //  Signals  //
    ///////////////
    
    //reset
    logic                           aclrn, sclrn, resetn_synchronized;
    
    //word coalescer and address range analysis
    logic                           coal_done_with_word;        //done with word N if it timed out or word N+1 shows up
    logic                           coal_can_coalesce;          //word N can coalesce with word N+1 if the last byte address of word N is in the same memory word as the first byte address of word N+1
    logic                           coal_more_wide_sections;    //i_more_wide_sections kept live
    logic    [INTRA_ADDR_WIDTH-1:0] coal_addr;                  //i_addr kept live
    logic                     [1:0] coal_last_addr_hi, coal_last_addr_hi_masked;    //0 means kernel word spans 1 memory word, 1 means it spans 2 memory words, 2 means it spans 3 memory words
    
    //cmd fifo write side
    logic      [CMD_FIFO_WIDTH-1:0] cmd_fifo_wr_all_data;       //package up all the data before writing to the fifo, the individual signals below have the same meaning as the corresponding output signals
    logic                           cmd_fifo_wr_req;
    logic                           cmd_fifo_wr_needs_second_cycle, cmd_fifo_wr_needs_third_cycle, cmd_fifo_wr_spans_two, cmd_fifo_wr_spans_three, cmd_fifo_wr_can_coalesce, cmd_fifo_wr_more_wide_sections;
    logic    [INTRA_ADDR_WIDTH-1:0] cmd_fifo_wr_addr, cmd_fifo_wr_addr_modulo;
    
    //cmd fifo read side
    logic      [CMD_FIFO_WIDTH-1:0] cmd_fifo_rd_all_data;
    logic                           cmd_spans_two_raw, cmd_spans_three_raw;
    
    
    
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
    
    
    
    /////////////////////////////////////////////////
    //  Word Coalescer and Address Range Analysis  //
    /////////////////////////////////////////////////
    
    //calculate whether each kernel word will span 1, 2, or 3 memory words
    //if word coalescing is enabled, then for kernel word N determine whether kernel word N+1 shares the same memory word
    //the output if the generate block below is the coal_*** signals
    
    generate
    if (!ENABLE_WORD_COALESCE) begin : NO_WORD_COAL
        logic [INTRA_ADDR_WIDTH+1:0] input_last_addr;
        assign input_last_addr = i_addr[INTRA_ADDR_WIDTH-1:0] + ((i_more_wide_sections) ? (KER_DATA_BYTES-1) : (KER_DATA_BYTES_LAST-1));
        
        assign coal_done_with_word = i_valid;
        assign coal_can_coalesce = 1'b0;  //no coalescing
        assign coal_more_wide_sections = i_more_wide_sections;
        assign coal_addr = i_addr[INTRA_ADDR_WIDTH-1:0];
        assign coal_last_addr_hi = input_last_addr[INTRA_ADDR_WIDTH+1:INTRA_ADDR_WIDTH];
    end
    else begin : GEN_WORD_COAL
        //word coalescing: for kernel word N determine whether kernel word N+1 shares the same memory word
        //this means we must capture kernel word N in registers, we can release it to downstream only once kernel word N+1 arrives or we time out
        //assuming kernel word N+1 arrives before the timeout, we coalesce if the last byte address of kernel word N is in the same memory word as the first byte address of kernel word N+1
        //kernel upstream provides the first byte address that each kernel word touches, the last address is simply first address + kernel word size - 1
        //there is lots of pipelining, the adder to compute the last address is tessellated, and we will know the result of the above address check two clocks after kernel word N+1 arrives
        
        // The following naming convention is used:
        // - lo means this the bottom half of the tessellated add, hi means this is the top half of the tessellated add
        // - first_addr is the first byte address that the kernel word touches, last_addr is the last (inclusive) byte address that the kernel word touches
        // - late means it is one clock cycle after the corresponding non-late version
        
        // Beware there are two variants of last_addr:
        // - i_addr + KERNEL_WORD_SIZE is stored in captured_last_addr_lo (the lower bits) and late_captured_last_addr_hi (the upper bits), this used the entire i_addr
        // - i_addr[INTRA_ADDR_WIDTH-1:0] + KERNEL_WORD_SIZE is stored in late_captured_last_addr, this only uses the bottom bits of i_addr, if it goes past 2**INTRA_ADDR_WIDTH then this kernel word spans multiple memory word
        
        //capture the current word
        logic                           captured_valid;         //is what we captured valid, turns on when an incoming transaction arrives, turns off if we time out
        logic [TESS_INDEX:0]            captured_last_addr_lo;  //bottom half of the captured address
        logic [ADDR_WIDTH-1:TESS_INDEX] captured_first_addr_hi, late_captured_last_addr_hi; //top half of the captured address
        
        //coalescer
        logic                           continue_in_same_word_valid, late_continue_in_same_word_valid;  //word N+1 has arrived, can coalesce if word N did not time out and not too many words have coalesced
        logic                           addr_match_lo, late_addr_match;                                 //captured address matches incoming address, comparison is split over 2 clocks since adder is tessellated
        
        //timeout
        logic                           timeout;                //waited too long for the next word to arrive, going to release the captured address to downstream and report that it cannot coalesce
        
        //limit how many kernel words can coalesce into one memory word
        logic      [WRITEACK_WIDTH-1:0] limiter_counter;        //count how many kernel words have been coalesced into the current memory word
        logic                           limiter_throttle;       //too many kernel words have coalesced, stop coalescing in the current memory word so that writeack fifo value doesn't overflow
        
        //keep the captured data live
        logic                           captured_more_wide_sections, late_captured_more_wide_sections, late_captured_done_with_word;
        logic    [INTRA_ADDR_WIDTH-1:0] captured_addr, late_captured_addr;
        logic    [INTRA_ADDR_WIDTH+1:0] late_captured_last_addr;
        
        
        //capture the current word so that we can check for coalescing when the next word arrives
        always_ff @(posedge clock or negedge aclrn) begin
            if (~aclrn) captured_valid <= 1'b0;
            else begin
                if (i_valid) captured_valid <= 1'b1;
                else if (timeout) captured_valid <= 1'b0;
                if (~sclrn) captured_valid <= 1'b0;
            end
        end
        always_ff @(posedge clock) begin
            //one clock after i_valid
            if (i_valid) begin
                captured_last_addr_lo <= i_addr[TESS_INDEX-1:0] + ((i_more_wide_sections) ? (KER_DATA_BYTES-1) : (KER_DATA_BYTES_LAST-1)); //bottom half of tessellated adder, msb is the carry-out
                captured_first_addr_hi <= i_addr[ADDR_WIDTH-1:TESS_INDEX];    //this has two purposes: 1. keep upper bits live so tessellated adder can finish on next clock cycle, 2. late version of i_addr to check against
            end
            
            //two clocks after i_valid
            late_captured_last_addr_hi <= captured_first_addr_hi + captured_last_addr_lo[TESS_INDEX];  //top half of tessellated adder, add the carry-out from the bottom half to delayed version of upper bits of i_addr
        end
        
        
        //coalescer -- assuming the previous word has been captured, check if the previous word can coalesce with the incoming word
        always_ff @(posedge clock) begin
            //one clock after i_valid
            continue_in_same_word_valid <= i_valid & captured_valid & ~limiter_throttle;    //word N+1 has arrived, can coalesce if word N did not time out and not too many words have coalesced
            addr_match_lo <= (i_addr[TESS_INDEX-1:INTRA_ADDR_WIDTH] == captured_last_addr_lo[TESS_INDEX-1:INTRA_ADDR_WIDTH]);   //bottom half of the address check
            
            //two clocks after i_valid
            late_continue_in_same_word_valid <= continue_in_same_word_valid;
            late_addr_match <= (captured_first_addr_hi[ADDR_WIDTH-1:TESS_INDEX] == late_captured_last_addr_hi[ADDR_WIDTH-1:TESS_INDEX]) & addr_match_lo;    //top half of the address check + result from bottom half
        end
        assign coal_can_coalesce = late_addr_match & late_continue_in_same_word_valid;  //word N can coalesce with word N+1
        
        
        //timeout
        dla_hld_lsu_coalescer_dynamic_timeout #(
            .ASYNC_RESET            (ASYNC_RESET),
            .MAX_TIMEOUT_BIT        (WORD_COAL_MAX_TIMEOUT_BIT)
        )
        dla_hld_lsu_coalescer_dynamic_timeout_inst
        (
            .clock                  (clock),
            .resetn                 (resetn),
            .i_valid                (i_valid),
            .i_disable_timeout      (i_disable_coalescer_timeout),
            .o_timeout              (timeout),
            .i_coal_if_addr_match   (captured_valid & ~limiter_throttle),
            .i_late_addr_match      (late_addr_match)
        );
        
        
        //limiter -- ensure we don't have too many kernel words coalescing into the same memory word, this bounds the width of the writeack fifo
        //typically WRITEACK_WIDTH is 10, this allows for up to 516 or so threads to get coalesced into the same word (it is larger than 2**9 since there is some delay before it takes effect)
        always_ff @(posedge clock or negedge aclrn) begin
            if (~aclrn) limiter_counter <= '0;
            else begin
                if (cmd_fifo_wr_req) begin
                    if (cmd_fifo_wr_can_coalesce) limiter_counter <= limiter_counter + 1'b1;
                    else limiter_counter <= '0;
                end
                if (~sclrn) limiter_counter <= '0;
            end
        end
        assign limiter_throttle = limiter_counter[WRITEACK_WIDTH-1];   //msb
        
        
        //since there is 2 clock cycles of pipelining to determine whether coalescing can happen, we need the captured data live for another 2 clocks
        always_ff @(posedge clock) begin
            //same clock cycle as captured_valid
            if (i_valid) begin
                captured_addr <= i_addr[INTRA_ADDR_WIDTH-1:0];
                captured_more_wide_sections <= i_more_wide_sections;
            end
            
            //one clock after captured_valid
            late_captured_done_with_word <= timeout | (i_valid & captured_valid);    //done with word N if it timed-out or word N+1 shows up
            late_captured_addr <= captured_addr;
            late_captured_more_wide_sections <= captured_more_wide_sections;
            
            //two clocks after captured_valid
            coal_done_with_word <= late_captured_done_with_word;
            coal_addr <= late_captured_addr;
            coal_last_addr_hi <= late_captured_last_addr[INTRA_ADDR_WIDTH+1:INTRA_ADDR_WIDTH];
            coal_more_wide_sections <= late_captured_more_wide_sections;
        end
        
        //one clock after captured_valid
        assign late_captured_last_addr = late_captured_addr + ((late_captured_more_wide_sections) ? (KER_DATA_BYTES-1) : (KER_DATA_BYTES_LAST-1));
    end
    endgenerate
    
    
    
    ///////////////////////////
    //  Cmd FIFO Write Data  //
    ///////////////////////////
    
    //coalescing information is stored in the coal_*** signals, now convert this into the write data for the cmd fifo
    //the interpretation of each signal is exactly the same as the corresponding output signal
    
    always_ff @(posedge clock or negedge aclrn) begin
        if (~aclrn) cmd_fifo_wr_req <= 1'b0;
        else begin
            cmd_fifo_wr_req <= coal_done_with_word;
            if (~sclrn) cmd_fifo_wr_req <= 1'b0;
        end
    end
    
    always_ff @(posedge clock) begin
        cmd_fifo_wr_can_coalesce <= coal_can_coalesce;
        cmd_fifo_wr_addr <= coal_addr;
        cmd_fifo_wr_more_wide_sections <= coal_more_wide_sections;
        cmd_fifo_wr_addr_modulo <= coal_addr % KER_DATA_BYTES;  //INTRA_ADDR_WIDTH should be small enough that this is just a single level of logic lookup table
    end
    
    assign coal_last_addr_hi_masked = (MAX_MEM_WORDS_PER_KER_WORD == 1) ? 2'h0 : (MAX_MEM_WORDS_PER_KER_WORD == 2) ? {1'h0, coal_last_addr_hi[0]} : coal_last_addr_hi;
    always_ff @(posedge clock) begin
        cmd_fifo_wr_spans_two <= |coal_last_addr_hi_masked;
        cmd_fifo_wr_spans_three <= coal_last_addr_hi_masked[1];
        cmd_fifo_wr_needs_second_cycle <= (HIGH_THROUGHPUT_MODE) ? coal_last_addr_hi_masked[1] | (coal_last_addr_hi_masked[0] & ~coal_can_coalesce) : |coal_last_addr_hi_masked;
        cmd_fifo_wr_needs_third_cycle <= (HIGH_THROUGHPUT_MODE) ? coal_last_addr_hi_masked[1] & ~coal_can_coalesce : coal_last_addr_hi_masked[1];
    end
    
    assign cmd_fifo_wr_all_data[0]                                      = (MAX_MEM_WORDS_PER_KER_WORD >= 2)     ? cmd_fifo_wr_spans_two          : 1'b0;
    assign cmd_fifo_wr_all_data[1]                                      = (MAX_MEM_WORDS_PER_KER_WORD == 3)     ? cmd_fifo_wr_spans_three        : 1'b0;
    assign cmd_fifo_wr_all_data[2]                                      = (MAX_MEM_WORDS_PER_KER_WORD >= 2)     ? cmd_fifo_wr_needs_second_cycle : 1'b0;
    assign cmd_fifo_wr_all_data[3]                                      = (MAX_MEM_WORDS_PER_KER_WORD == 3)     ? cmd_fifo_wr_needs_third_cycle  : 1'b0;
    assign cmd_fifo_wr_all_data[4]                                      = (ENABLE_WORD_COALESCE)                ? cmd_fifo_wr_can_coalesce       : 1'b0;
    assign cmd_fifo_wr_all_data[5]                                      = (KER_DATA_BYTES!=KER_DATA_BYTES_LAST) ? cmd_fifo_wr_more_wide_sections : 1'b0;
    assign cmd_fifo_wr_all_data[6 +: INTRA_ADDR_WIDTH]                  = ~((1<<ADDR_ALIGNMENT_BITS)-1)         & cmd_fifo_wr_addr;
    assign cmd_fifo_wr_all_data[6+INTRA_ADDR_WIDTH +: INTRA_ADDR_WIDTH] = ~((1<<ADDR_ALIGNMENT_BITS)-1)         & cmd_fifo_wr_addr_modulo;
    
    
    
    ////////////////
    //  Cmd FIFO  //
    ////////////////
    
    //every write into the input fifos and will eventually result in one write into the cmd fifo at some later time
    //every read from the cmd fifo will eventually result in one read from the input fifos at some later time
    //therefore the occupancy in some input fifo is always larger than the cmd fifo, and that is used to backpressure kernel upstream
    
    dla_hld_fifo #(
        .WIDTH              (CMD_FIFO_WIDTH),
        .DEPTH              (MLAB_FIFO_DEPTH),
        .NEVER_OVERFLOWS    (1),
        .ASYNC_RESET        (ASYNC_RESET),
        .SYNCHRONIZE_RESET  (0),
        .STYLE              ("ms")
    )
    cmd_fifo_inst
    (
        .clock              (clock),
        .resetn             (resetn_synchronized),
        .i_valid            (cmd_fifo_wr_req),
        .i_data             (cmd_fifo_wr_all_data),
        .o_stall            (),
        .o_almost_full      (),
        .o_valid            (),
        .o_data             (cmd_fifo_rd_all_data),
        .i_stall            (~i_cmd_fifo_rd_ack),
        .o_almost_empty     (),
        .o_empty            (o_cmd_fifo_empty),
        .ecc_err_status     ()
    );
    
    //quartus does not propagate constants across the ram inside the fifo, so do it again here
    assign cmd_spans_two_raw        = (MAX_MEM_WORDS_PER_KER_WORD >= 2)     ? cmd_fifo_rd_all_data[0] : 1'b0;
    assign cmd_spans_three_raw      = (MAX_MEM_WORDS_PER_KER_WORD == 3)     ? cmd_fifo_rd_all_data[1] : 1'b0;
    assign o_cmd_needs_second_cycle = (MAX_MEM_WORDS_PER_KER_WORD >= 2)     ? cmd_fifo_rd_all_data[2] : 1'b0;
    assign o_cmd_needs_third_cycle  = (MAX_MEM_WORDS_PER_KER_WORD == 3)     ? cmd_fifo_rd_all_data[3] : 1'b0;
    assign o_cmd_can_coalesce       = (ENABLE_WORD_COALESCE)                ? cmd_fifo_rd_all_data[4] : 1'b0;
    assign o_cmd_more_wide_sections = (KER_DATA_BYTES!=KER_DATA_BYTES_LAST) ? cmd_fifo_rd_all_data[5] : 1'b0;
    assign o_cmd_addr               = ~((1<<ADDR_ALIGNMENT_BITS)-1)         & cmd_fifo_rd_all_data[6 +: INTRA_ADDR_WIDTH];
    assign o_cmd_addr_modulo        = ~((1<<ADDR_ALIGNMENT_BITS)-1)         & cmd_fifo_rd_all_data[6+INTRA_ADDR_WIDTH +: INTRA_ADDR_WIDTH];
    
    //in low throughput mode, if a kernel word spans N memory words it will take N clock cycles to process it regardless of coalescing
    assign o_cmd_spans_two   = (HIGH_THROUGHPUT_MODE) ? cmd_spans_two_raw   : o_cmd_needs_second_cycle;
    assign o_cmd_spans_three = (HIGH_THROUGHPUT_MODE) ? cmd_spans_three_raw : o_cmd_needs_third_cycle;

endmodule

`default_nettype wire
