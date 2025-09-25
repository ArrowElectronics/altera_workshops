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

// This module is used by the write LSU to release valids to kernel downstream when writeack arrives. It monitors the outputs from the unaligned controller to
// determine how many completed kernel words have been packed into each memory word. Once the memory word is finished, the corresponding number of kernel words
// this memory word contains is written to a fifo. Upon receiving writeack, read from this fifo, the read data indicates how many non-predicated valids are
// allowed to be released to kernel downstream. This module also controls the read side of the predicate fifo, a predicated transaction has no corresponding
// writeack and is allowed to be released to kernel downstream if there are no valids ahead of it.
//
// To add support for AXI, which has one writeack per burst, an additional translation needs to happen:
// 1. (New for AXI support) For each writeack, how many memory words can be released downstream
// 2. (Existing for Avalon) For each memory word, how many kernel words can be released downstream
//
// In theory, it is possible to do both translations for AXI in one step, e.g. for each writeack (one per burst), how many kernel words can be released. However,
// the architecture of the LSU does not allow it easily since that information does not exist anywhere. When the word coalescer is done and releases a memory word
// to the burst coalescer, that is the point in time when the number of kernel words per memory word is written to the writeack fifo. It will be many clock cycles
// later until the burst coalescer finishes, and only at that time point in time would we know the number of memory words in a burst (and therefore could compute
// the number of kernel words in a burst).
//
// For additional info, refer to dla_hld_global_load_store.sv (top module of entire LSU) and dla_hld_lsu.sv (top module of the core LSU).

`default_nettype none

module dla_hld_lsu_write_kernel_downstream #(
    parameter bit ASYNC_RESET,                  //0 = registers consume reset synchronously, 1 = registers consume reset asynchronously
    parameter int KER_DOWN_STALL_LATENCY,       //0 = use stall/valid, 1 or larger = use stall latency and the value indicates the downstream roundtrip latency (from i_stall to o_valid)
    parameter bit HIGH_THROUGHPUT_MODE,         //0 = use N clock cycles to process a kernel word that spans N memory words, 1 = use minimum amount of time to process kernel words, only matters if N >= 2
    parameter int MAX_MEM_WORDS_PER_KER_WORD,   //trim some logic if it is guaranteed that each kernel word can only span 1 or 2 memory words
    parameter int MLAB_FIFO_DEPTH,              //use a shallow fifo if handshaking is expected to take a few clocks (or if capacity can be borrowed from a nearby deep fifo), if we need an MLAB may as well use all of it
    parameter int M20K_NARROW_FIFO_DEPTH,       //if we need a deep fifo but the data path is narrow e.g. up to 10 bits which is the narrowest M20K on S10, can get additional depth for without needing more M20K
    parameter int TOTAL_OCC_LIMIT,              //loose upper bound on the maximum number of threads allowed inside the LSU at any time, this bounds the counter width for o_active
    parameter int WRITEACK_WIDTH,               //writeack fifo indicate how many valids to release upon writeack, it uses narrow m20k, word coalescer stops to ensure value doesn't overflow narrow m20k width
    parameter int BURSTCOUNT_WIDTH,             //width of avalon burst count signal, max burst size is 2**(BURSTCOUNT_WIDTH-1)
    parameter bit ENABLE_BURST_COALESCE,        //whether to coalesce sequential memory words together to make a burst
    parameter bit USE_AXI                       //0 = use AvalonMM, 1 = use AXI
) (
    input  wire         clock,
    input  wire         resetn,
    
    //kernel word info from word coalescer
    input  wire         i_cmd_spans_two,            //kernel word spans at least two memory words
    input  wire         i_cmd_spans_three,          //kernel word spans three memory words
    
    //unaligned controller
    input  wire         i_can_read_cmd_fifo,        //can make forward progress in processing this kernel word
    input  wire         i_cmd_fifo_rd_ack,          //done with all sections of kernel word
    input  wire         i_cmd_at_second_cycle,      //in the second clock cycle of processing current kernel word
    input  wire         i_cmd_at_third_cycle,       //in the third clock cycle of processing current kernel word
    input  wire         i_cmd_is_coalescing,        //does the current section of the kernel word coalesce with the next section (next section could be same or next kernel word)
    
    //burst coalescer
    input  wire                         i_burstcoal_snoop_valid,        //watch when the output fifo from the burst coalescer is read
    input  wire  [BURSTCOUNT_WIDTH-1:0] i_burstcoal_snoop_burstsize,    //if ack is for an entire burst this indicates how many memory words are done, note there is still a conversion to kernel words
    
    //write ack fifo
    input  wire         i_avm_writeack,             //from memory interface, write has committed to memory
    output logic        o_writeack_fifo_almost_full,//stop sending more writes if no more space to track how many kernel words have finished inside each memory word
    
    //read side of predicate fifo
    input  wire         i_predicate_fifo_empty,     //fifo is empty
    input  wire         i_predicate_fifo_rd_data,   //0 = normal transaction, 1 = predicated (still need to release a valid to kernel downstream, but no memory transaction)
    output logic        o_predicate_fifo_rd_ack,    //read from fifo
    
    //kernel downstream
    output logic        o_valid,                    //LSU has a transaction available, kernel downstream can but does not need to accept it if using stall valid, must accept it if using stall latency
    output logic        o_empty,                    //LSU does not have a transaction available for kernel downstream, meant to be used with stall latency
    output logic        o_almost_empty,             //LSU downstream interface does not have at least KER_DOWN_STALL_LATENCY transactions ready to be released
    input  wire         i_stall                     //backpressure from kernel downstream
);
    
    localparam int TOTAL_OCC_BITS = $clog2(TOTAL_OCC_LIMIT);    //how many bits are needed for an occupancy counter in the worst case that all threads inside the LSU are tracked by that counter
    
    ///////////////
    //  Signals  //
    ///////////////
    
    //reset
    logic                       aclrn, sclrn, resetn_synchronized;
    
    //track when memory words and kernel words have finished
    logic                       done_with_mem_word;
    logic                 [1:0] done_with_ker_word;             //up to 2 kernel words can finish on the same clock cycle, see comments below
    
    //writeack fifo
    logic                       writeack_fifo_wr_req, writeack_fifo_empty, writeack_fifo_rd_ack;
    logic  [WRITEACK_WIDTH-1:0] writeack_fifo_wr_data, writeack_fifo_rd_data;   //writeack_fifo data tracks how many valids can be released to kernel downstream upon receiving writeack
    
    //kernel downstream
    logic  [WRITEACK_WIDTH-1:0] writeack_count_incr;            //transfer from writeack_fifo into writeack_count
    logic  [TOTAL_OCC_BITS-1:0] writeack_count;                 //in kernel downstream stalls for a long time, nearly all writes could accumulate here, size this counter the same width as o_active
    logic                       writeack_count_was_two_or_more; //lookahead logic for writeack_count_nonzero
    logic                       writeack_count_nonzero;         //use the lookahead logic to reduce the combinational logic for detecting when writeack_count != 0
    logic                       writeack_count_decr;            //transfer from writeack_count into mini_writeack_count if writeack_count has stuff and mini_writeack_count has space available
    logic                 [3:0] mini_writeack_count;            //narrow bit width offset counter can integrate predicate logic without huge amounts of serial combinational logic
    logic                       mini_writeack_incr;             //pipelined version of writeack_count_decr
    logic                       mini_writeack_decr;             //transfer from mini_writeack_count into output_count
    logic                       mini_writeack_almost_full;      //backpressure to stop transfer from writeack_count
    logic                       output_count_incr;              //pipelined version of mini_writeack_decr
    logic                       output_count_decr;              //kernel downstream accepted a transaction
    logic                       output_count_almost_full;       //backpressure to stop transfer from mini_writeack_count
    logic                       not_empty;                      //occ tracker produces an inverted o_valid
    
    
    
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
    
    
    
    //////////////////////////////////////////////////////////////
    //  Track when memory words and kernel words have finished  //
    //////////////////////////////////////////////////////////////
    
    always_ff @(posedge clock) begin
        done_with_mem_word <= i_can_read_cmd_fifo & ~i_cmd_is_coalescing;
    end
    
    generate
    if (HIGH_THROUGHPUT_MODE && MAX_MEM_WORDS_PER_KER_WORD >= 2) begin : TWO_DONE_WITH_KER_WORD
        //in high throughput mode, if the last section of kernel word N is in the same memory word as the first section of kernel word N+1, then the unaligned controller
        //allocates no time for the last section of kernel word N, this data is kept live in registers and is processed on the same clock cycle as the first section of kernel word N+1
        //until the first section of kernel word N+1 is processed, we cannot claim the write has finished for kernel word N
        //it is also possible that kernel word N+1 fits within one memory word, so we need to say two writes have finished on the same clock cycle
        
        logic has_leftover;             //last section of kernel word N is in same memory word as first section of kernel word N+1, there will be some leftover data that kernel word N+1 will deal with at the same time
        logic done_with_ker_word_a;     //kernel word N+1 has finished using the above example
        logic done_with_ker_word_b;     //kernel word N has finished, this is only delayed by one clock since it can happen any time after done_with_mem_word, look at how writeack_fifo_wr_data accumulates and clears
        
        assign has_leftover = (i_cmd_spans_three) ? ~i_cmd_at_third_cycle : (i_cmd_spans_two) ? ~i_cmd_at_second_cycle : 1'b0;
        assign done_with_ker_word_a = i_cmd_fifo_rd_ack & ~has_leftover;
        always_ff @(posedge clock) begin
            done_with_ker_word_b <= i_cmd_fifo_rd_ack & has_leftover;
            done_with_ker_word[0] <= done_with_ker_word_a ^ done_with_ker_word_b;   //convert from two separate one bit signals into a single two bit value to add
            done_with_ker_word[1] <= done_with_ker_word_a & done_with_ker_word_b;
        end
    end
    else begin : ONE_DONE_WITH_KER_WORD
        always_ff @(posedge clock) begin
            done_with_ker_word[0] <= i_cmd_fifo_rd_ack;
        end
        assign done_with_ker_word[1] = 1'h0;
    end
    endgenerate
    
    
    
    /////////////////////
    //  Writeack FIFO  //
    /////////////////////
    
    //accumulate how many kernel words have finished in the current memory word, when the memory word is done write to the fifo and clear the counter
    //writeack_fifo data tracks how many valids can be released to kernel downstream upon receiving writeack
    always_ff @(posedge clock or negedge aclrn) begin
        if (~aclrn) begin
            writeack_fifo_wr_req <= 1'b0;
            writeack_fifo_wr_data <= 0;
        end
        else begin
            writeack_fifo_wr_req <= done_with_mem_word;
            if (writeack_fifo_wr_req) begin
                writeack_fifo_wr_data <= done_with_ker_word;
            end
            else begin
                writeack_fifo_wr_data <= writeack_fifo_wr_data + done_with_ker_word;
            end
            if (~sclrn) begin
                writeack_fifo_wr_req <= 1'b0;
                writeack_fifo_wr_data <= 0;
            end
        end
    end
    
    dla_hld_fifo #(
        .WIDTH              (WRITEACK_WIDTH),
        .DEPTH              (M20K_NARROW_FIFO_DEPTH),
        .NEVER_OVERFLOWS    (1),
        .ALMOST_FULL_CUTOFF (3), //1 clock from almost full to cmd fifo read, 1 clock to done_with_mem_word, 1 clock to writeack_fifo_wr_req
        .ASYNC_RESET        (ASYNC_RESET),
        .SYNCHRONIZE_RESET  (0),
        .STYLE              ("ms")
    )
    writeack_fifo_inst
    (
        .clock              (clock),
        .resetn             (resetn_synchronized),
        .i_valid            (writeack_fifo_wr_req),
        .i_data             (writeack_fifo_wr_data),
        .o_stall            (),
        .o_almost_full      (o_writeack_fifo_almost_full),
        .o_valid            (),
        .o_data             (writeack_fifo_rd_data),
        .i_stall            (~writeack_fifo_rd_ack),
        .o_almost_empty     (),
        .o_empty            (writeack_fifo_empty),
        .ecc_err_status     ()
    );
    
    
    
    //////////////////////////////////////////////
    // Writeack burst to memory word conversion //
    //////////////////////////////////////////////
    
    // AXI provides one writeack for the entire burst, translate that to how many memory words can be released downstream.
    // For Avalon, already had to translate how many kernel words can be released per memory word.
    // Once AXI has translated burst to memory words, will also need to reuse the Avalon translation of memory words to kernel words.
    
    generate
    if (ENABLE_BURST_COALESCE && USE_AXI) begin : GEN_BURST_TO_MEM_WORD
        //upon receiving a writeack for the entire burst, pop from the fifo below to determine how many memory words this burst contained (this information was originally provided by the burst coalescer)
        //there is a counter that tracks outstanding memory words (words that have been popped from the fifo but not yet accepted by the second translator or memory to kernel words)
        localparam int BURST_TO_MEM_WORD_BITS = $clog2(M20K_NARROW_FIFO_DEPTH) + 1;

        logic burst_to_mem_word_fifo_rd_ack;
        logic [BURSTCOUNT_WIDTH-1:0] burst_to_mem_word_fifo_rd_data, burst_to_mem_word_neg_counter_update;
        logic [BURST_TO_MEM_WORD_BITS-1:0] burst_to_mem_word_neg_counter;

        dla_hld_fifo #(
            .WIDTH              (BURSTCOUNT_WIDTH),
            .DEPTH              (M20K_NARROW_FIFO_DEPTH),   //if at least as deep as writeack fifo, then by construction this cannot overflow
            .NEVER_OVERFLOWS    (1),
            .ASYNC_RESET        (ASYNC_RESET),
            .SYNCHRONIZE_RESET  (0),
            .STYLE              ("ms")
        )
        burst_to_mem_word_fifo_inst
        (
            .clock              (clock),
            .resetn             (resetn_synchronized),
            .i_valid            (i_burstcoal_snoop_valid),
            .i_data             (i_burstcoal_snoop_burstsize),
            .o_stall            (),
            .o_almost_full      (),
            .o_valid            (),
            .o_data             (burst_to_mem_word_fifo_rd_data),
            .i_stall            (~burst_to_mem_word_fifo_rd_ack),
            .o_almost_empty     (),
            .o_empty            (),
            .ecc_err_status     ()
        );

        assign burst_to_mem_word_fifo_rd_ack = i_avm_writeack;

        //number of words in a burst = axi burst length + 1
        always_ff @(posedge clock) begin
            burst_to_mem_word_neg_counter_update <= (burst_to_mem_word_fifo_rd_ack) ? (burst_to_mem_word_fifo_rd_data + 1'b1) : '0;
        end

        //if a burst has been writeack, then decrease the counter by that the burst size
        //if a word within that burst has been processed, then increase the counter by 1
        //since a writeack happens before processing of words within that burst, the value of burst_to_mem_word_neg_counter is 0 or negative
        
        //the value of burst_to_mem_word_neg_counter is 0 or negative
        //a negative value means there are some outstanding memory words that have been popped from the burst_to_mem_word_fifo_inst fifo but not yet accepted by the second translator
        //the second translator does memory words to kernel words, it can only receive one memory word per clock cycle because it needs to pop from a different fifo
        //if a burst has two or more memory words, this counter is necessary to track outstanding memory words
        always_ff @(posedge clock or negedge aclrn) begin
            if (~aclrn) burst_to_mem_word_neg_counter <= '0;
            else begin
                burst_to_mem_word_neg_counter <= burst_to_mem_word_neg_counter - burst_to_mem_word_neg_counter_update + writeack_fifo_rd_ack;
                if (~sclrn) burst_to_mem_word_neg_counter <= '0;
            end
        end
        assign writeack_fifo_rd_ack = burst_to_mem_word_neg_counter[BURST_TO_MEM_WORD_BITS-1];  //msb = is value negative, max value is 0 so really this checks for a nonzero value
    end
    else begin : NO_BURST_TO_MEM_WORD
        //upon receiving writeack, read from writeack_fifo, data indicates how many non-predicated transactions can be released to kernel downstream
        assign writeack_fifo_rd_ack = i_avm_writeack;
    end
    endgenerate
    
    
    
    /////////////////////////
    //  Kernel Downstream  //
    /////////////////////////
    
    //accumulate the data read from writeack_fifo into writeack_count
    always_ff @(posedge clock) begin
        writeack_count_incr <= (writeack_fifo_rd_ack) ? writeack_fifo_rd_data : '0; //transfer to writeack_count
        writeack_count_was_two_or_more <= (writeack_count >= 2);
    end
    always_ff @(posedge clock or negedge aclrn) begin
        if (~aclrn) writeack_count <= '0;
        else begin
            writeack_count <= writeack_count + writeack_count_incr - writeack_count_decr;
            if (~sclrn) writeack_count <= '0;
        end
    end
    
    //use lookahead logic to determine when writeack_count is nonzero, if so then we can transfer a value of 1 from writeack_count into mini_writeack_count
    //the purpose of using mini_writeack_count is that the bit width is much smaller
    //need to integrate predicate logic with counter being nonzero in order to transfer to output_count, it is too much combinational logic when using a large bit with counter
    assign writeack_count_decr = (writeack_count_was_two_or_more | writeack_count[0]) & ~mini_writeack_almost_full;
    
    always_ff @(posedge clock) begin
        mini_writeack_incr <= writeack_count_decr;  //transfer to mini_writeack_count
    end
    always_ff @(posedge clock or negedge aclrn) begin
        if (~aclrn) mini_writeack_count <= '1;  //4 bits can represent -8 to +7, we use -1 to +6, msb is sign bit which indiates empty, second msb means almost full
        else begin
            mini_writeack_count <= mini_writeack_count + mini_writeack_incr - mini_writeack_decr;
            if (~sclrn) mini_writeack_count <= '1;
        end
    end
    assign writeack_count_nonzero = ~mini_writeack_count[3];
    always_ff @(posedge clock) begin
        mini_writeack_almost_full <= ~mini_writeack_count[3] & mini_writeack_count[2];    //detect +4 or more, count can be up to 5 by the time almost full asserts
    end
    
    //transfer from mini_writeack_count to output_count if there is space available, next transaction to kernel downstream is not predicated, and mini_writeack_count has stuff
    assign mini_writeack_decr = ~output_count_almost_full & ~i_predicate_fifo_empty & ~i_predicate_fifo_rd_data & writeack_count_nonzero;
    
    //drain the predicate fifo into output_count, which tracks how many valids can be released to kernel downstream
    //only need to check if mini_writeack_count has stuff if the next transaction to kernel downstream is not predicated
    assign o_predicate_fifo_rd_ack = ~output_count_almost_full & ~i_predicate_fifo_empty & (i_predicate_fifo_rd_data | writeack_count_nonzero);
    
    always_ff @(posedge clock) begin
        output_count_incr <= o_predicate_fifo_rd_ack;     //transfer to output_count
    end
    assign output_count_decr = (not_empty & ~i_stall);  //transaction accepted by kernel downstream
    
    //output count is not implemented with a counter, only care about being empty (~o_valid) or almost full (backpressure) or almost empty (for stall latency), each of which can be implemented with an occ tracker
    
    dla_acl_tessellated_incr_decr_threshold #(
        .CAPACITY                   (MLAB_FIFO_DEPTH),
        .THRESHOLD                  (1),
        .INITIAL_OCCUPANCY          (0),
        .THRESHOLD_REACHED_AT_RESET (0),
        .ASYNC_RESET                (ASYNC_RESET),
        .SYNCHRONIZE_RESET          (0)
    )
    o_valid_inst
    (
        .clock                      (clock),
        .resetn                     (resetn_synchronized),
        .incr_no_overflow           (output_count_incr),
        .incr_raw                   (output_count_incr),
        .decr_no_underflow          (output_count_decr),
        .decr_raw                   (output_count_decr),
        .threshold_reached          (not_empty)
    );
    
    dla_acl_tessellated_incr_decr_threshold #(
        .CAPACITY                   (MLAB_FIFO_DEPTH),
        .THRESHOLD                  (MLAB_FIFO_DEPTH-1),
        .INITIAL_OCCUPANCY          (0),
        .THRESHOLD_REACHED_AT_RESET (1),
        .ASYNC_RESET                (ASYNC_RESET),
        .SYNCHRONIZE_RESET          (0)
    )
    output_count_almost_full_inst
    (
        .clock                      (clock),
        .resetn                     (resetn_synchronized),
        .incr_no_overflow           (output_count_incr),
        .incr_raw                   (output_count_incr),
        .decr_no_underflow          (output_count_decr),
        .decr_raw                   (output_count_decr),
        .threshold_reached          (output_count_almost_full)
    );
    
    assign o_empty = ~not_empty;
    assign o_valid = (KER_DOWN_STALL_LATENCY) ? output_count_decr : not_empty;
    
    generate
    if (KER_DOWN_STALL_LATENCY) begin
        logic not_almost_empty;
        dla_acl_tessellated_incr_decr_threshold #(
            .CAPACITY                   (MLAB_FIFO_DEPTH),
            .THRESHOLD                  (KER_DOWN_STALL_LATENCY+1), //convert from cutoff to threshold semantics
            .INITIAL_OCCUPANCY          (0),
            .THRESHOLD_REACHED_AT_RESET (0),
            .ASYNC_RESET                (ASYNC_RESET),
            .SYNCHRONIZE_RESET          (0)
        )
        o_almost_empty_inst
        (
            .clock                      (clock),
            .resetn                     (resetn_synchronized),
            .incr_no_overflow           (output_count_incr),
            .incr_raw                   (output_count_incr),
            .decr_no_underflow          (output_count_decr),
            .decr_raw                   (output_count_decr),
            .threshold_reached          (not_almost_empty)
        );
        assign o_almost_empty = ~not_almost_empty;
    end
    else begin
        assign o_almost_empty = 1'b1;
    end
    endgenerate
    
endmodule

`default_nettype wire
