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

// This module accepts memory words (read from global memory) and produces kernel words (to be released to kernel downstream). It supports arbitary address alignment
// and arbitrary latency through the data aligner barrel shifter. One kernel word can span up to three memory words, and the word coalescer has already figured out
// how the kernel word has been split in order to send the read requests. This module reuses that information and has its own unaligned controller to track the various
// stages of assembling data for each kernel word.
//
// For additional info, refer to dla_hld_global_load_store.sv (top module of entire LSU) and dla_hld_lsu.sv (top module of the core LSU).

`default_nettype none

module dla_hld_lsu_read_data_alignment #(
    //parameters that are different from dla_hld_lsu.sv
    parameter bit CACHE_BYPASS_DATA_FIFO,       //if using cache, bypass avm data fifo
    
    //parameters that are the same as dla_hld_lsu.sv
    parameter bit ASYNC_RESET,                  //0 = registers consume reset synchronously, 1 = registers consume reset asynchronously
    parameter int ADDR_ALIGNMENT_BITS,          //indicates how many least significant bits of i_address are known to be 0, e.g. set this parameter to 3 if kernel accesses are 8-byte aligned
    parameter int INTRA_ADDR_WIDTH,             //how many least significant bits of the byte address represent the location inside a memory word
    parameter int KER_DATA_BYTES,               //width of kernel data path in bytes, does not need to be a power of 2
    parameter int MEM_DATA_BYTES,               //width of memory data path in bytes, must be a power of 2
    parameter int KER_DOWN_STALL_LATENCY,       //0 = use stall/valid, 1 or larger = use stall latency and the value indicates the downstream roundtrip latency (from i_stall to o_valid)
    parameter int DATA_ALIGNER_MUX_PER_PIPE,    //0 = use comb logic for data alignment mux, 1 or more = max number of 2:1 muxes before a pipeline stage is added, e.g. 2 means up to 4:1 mux between reg
    parameter bit ENABLE_WORD_COALESCE,         //whether to coalesce kernel words together within the same memory word
    parameter bit HIGH_THROUGHPUT_MODE,         //0 = use N clock cycles to process a kernel word that spans N memory words, 1 = use minimum amount of time to process kernel words, only matters if N >= 2
    parameter int MAX_MEM_WORDS_PER_KER_WORD,   //trim some logic if it is guaranteed that each kernel word can only span 1 or 2 memory words
    parameter int MLAB_FIFO_DEPTH,              //use a shallow fifo if handshaking is expected to take a few clocks (or if capacity can be borrowed from a nearby deep fifo), if we need an MLAB may as well use all of it
    parameter int M20K_WIDE_FIFO_DEPTH          //use a deep fifo if handshaking is expected to take hundreds of clocks e.g. going off chip, for wide data path use M20K in shallowest mode, but may as well use all depth available
) (
    input  wire                         clock,
    input  wire                         resetn,
    
    //write side of avm data fifo
    input  wire                         i_burstcoal_valid,              //for read request throttle (don't ask for more data than there is space for), a memory word is considered outstanding once it enters burst coal
    output logic                        o_avm_rd_data_fifo_almost_full, //this is the read request throttle, not the fifo's almost full
    input  wire                         i_avm_readdatavalid,            //if CACHE_BYPASS_DATA_FIFO=0 this is avalon readdatavalid (no backpressure), else cache says there is data that LSU may accept but does not have to
    input  wire  [8*MEM_DATA_BYTES-1:0] i_avm_readdata,                 //data read from memory
    output logic                        o_avm_readdata_accepted,        //only used if CACHE_BYPASS_DATA_FIFO=1, this is how LSU tells the cache whether it accepted the read data
    
    //read side of cmd fifo
    output logic                        o_rsp_fifo_almost_full,         //backpressure to unaligned controller for the read request address
    input  wire                         i_cmd_fifo_rd_ack,              //read request is done with kernel word
    input  wire                         i_cmd_can_coalesce,             //from word coalescer, last section of kernel word is in the same memory word as the first section of next kernel word
    input  wire  [INTRA_ADDR_WIDTH-1:0] i_cmd_addr,                     //from word coalescer, within a memory word, the address of the first byte that this kernel word touches
    input  wire                         i_cmd_spans_two,                //from word coalescer, kernel word spans at least two memory words
    input  wire                         i_cmd_spans_three,              //from word coalescer, kernel word spans three memory words
    
    //read side of predicate fifo
    input  wire                         i_predicate_fifo_empty,         //fifo is empty
    input  wire                         i_predicate_fifo_rd_data,       //0 = normal transaction, 1 = predicated (still need to release a valid to kernel downstream, but no memory transaction)
    output logic                        o_predicate_fifo_rd_ack,        //read from fifo
    
    //kernel downstream
    output logic [8*KER_DATA_BYTES-1:0] o_readdata,                     //data for kernel downstream
    output logic                        o_valid,                        //LSU has a transaction available, kernel downstream can but does not need to accept it if using stall valid, must accept it if using stall latency
    output logic                        o_empty,                        //LSU does not have a transaction available for kernel downstream, meant to be used with stall latency
    output logic                        o_almost_empty,                 //LSU downstream interface does not have at least KER_DOWN_STALL_LATENCY transactions ready to be released
    input  wire                         i_stall                         //backpressure from kernel downstream
);
    
    //total width of the rsp fifo, but some output bits are masked or ignored so quartus may trim things
    localparam int RSP_FIFO_WIDTH = INTRA_ADDR_WIDTH + 7;
    
    //this is how many 2:1 mux stages the data aligner will need
    localparam int SHIFT_TO_ALIGN_WIDTH = INTRA_ADDR_WIDTH - ADDR_ALIGNMENT_BITS;  

    //latency = ceiling(mux stages needed / max mux stages per pipe), but 0 means use combinational logic
    localparam int DATA_ALIGNER_LATENCY = (DATA_ALIGNER_MUX_PER_PIPE == 0) ? 0 : ((SHIFT_TO_ALIGN_WIDTH + DATA_ALIGNER_MUX_PER_PIPE - 1) / DATA_ALIGNER_MUX_PER_PIPE);   
    
    //2 clock cycles from rsp fifo read until start of data alignment, DATA_ALIGNER_LATENCY to do alignment, 1 clock for the register stage that accumulates the write data for output fifo
    localparam int OUTPUT_FIFO_ALMOST_FULL_CUTOFF = DATA_ALIGNER_LATENCY + 3;
    
    
    
    ///////////////
    //  Signals  //
    ///////////////
    
    //reset
    logic                               aclrn, sclrn, resetn_synchronized;
    
    //avm rd data fifo
    logic                               avm_rd_data_fifo_not_empty, avm_rd_data_fifo_rd_ack, late_avm_rd_data_fifo_rd_ack;
    logic        [8*MEM_DATA_BYTES-1:0] avm_rd_data_fifo_rd_data;
    
    //convert cmd to rsp
    logic                               cmd_first_preloaded;
    logic                               rsp_fifo_wr_first_preloaded, rsp_fifo_wr_can_coalesce, rsp_fifo_wr_dont_read_data;
    logic                               rsp_fifo_wr_spans_two, rsp_fifo_wr_spans_three, rsp_fifo_wr_needs_second_cycle, rsp_fifo_wr_needs_third_cycle;
    logic        [INTRA_ADDR_WIDTH-1:0] rsp_fifo_wr_addr;
    
    //rsp fifo
    logic                               rsp_fifo_wr_req, rsp_fifo_empty, rsp_fifo_rd_ack;
    logic          [RSP_FIFO_WIDTH-1:0] rsp_fifo_wr_all_data, rsp_fifo_rd_all_data;
    
    //unpack rsp fifo read data
    logic                               rsp_first_preloaded, rsp_can_coalesce, rsp_dont_read_data;
    logic                               rsp_spans_two, rsp_spans_three, rsp_needs_second_cycle, rsp_needs_third_cycle;
    logic        [INTRA_ADDR_WIDTH-1:0] rsp_addr;
    logic                               rsp_spans_two_raw, rsp_spans_three_raw;
    
    //unaligned controller
    logic                               can_read_rsp_fifo;
    logic                               rsp_at_second_cycle, rsp_at_third_cycle, rsp_is_coalescing;
    
    //address range analysis
    logic          [KER_DATA_BYTES-1:0] address_decode;
    
    //data alignment
    logic    [SHIFT_TO_ALIGN_WIDTH-1:0] shift_to_align_readdata;
    logic        [8*KER_DATA_BYTES-1:0] readdata_aligned;
    
    //output fifo
    logic                               output_fifo_wr_req, output_fifo_almost_full;
    logic        [8*KER_DATA_BYTES-1:0] output_fifo_wr_data;
    
    
    
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
    
    
    
    ////////////////////////
    //  Avm Rd Data FIFO  //
    ////////////////////////
    
    //read data from global memory cannot be backpressured, capture it in a fifo
    //if using read cache, the read data can be backpressured due to the fifos inside the read cache, so avm_rd_data_fifo can be bypassed
    
    //reads are reserved from avm_rd_data_fifo before the fifo itself is read, there is 2 clocks of latency from the read until the data is available
    //this means fifo empty has to be tracked externally to the fifo to ensure no underflow
    //those 2 clocks of read latency are implemented as a registered read ack, and stall in earliness of 1 in the fifo
    always_ff @(posedge clock) begin
        late_avm_rd_data_fifo_rd_ack <= avm_rd_data_fifo_rd_ack;
    end
    
    assign o_avm_readdata_accepted = avm_rd_data_fifo_rd_ack;   //if using cache, this is the LSU indicating that it has accepted the read data from cache
    
    generate
    if (CACHE_BYPASS_DATA_FIFO) begin : NO_AVM_RD_DATA_FIFO
        assign avm_rd_data_fifo_rd_data = i_avm_readdata;
        assign avm_rd_data_fifo_not_empty = i_avm_readdatavalid;    //if using cache, readdatavalid means the cache has data available, LSU may accept it but does not have to
    end
    else begin : GEN_AVM_RD_DATA_FIFO
        dla_hld_fifo #(
            .STALL_IN_EARLINESS (1),
            .WIDTH              (8*MEM_DATA_BYTES),
            .DEPTH              (M20K_WIDE_FIFO_DEPTH),
            .NEVER_OVERFLOWS    (1),
            .ASYNC_RESET        (ASYNC_RESET),
            .SYNCHRONIZE_RESET  (0),
            .STYLE              ("ms")
        )
        avm_rd_data_fifo_inst
        (
            .clock              (clock),
            .resetn             (resetn_synchronized),
            .i_valid            (i_avm_readdatavalid),
            .i_data             (i_avm_readdata),
            .o_stall            (),
            .o_almost_full      (),
            .o_valid            (),
            .o_data             (avm_rd_data_fifo_rd_data),
            .i_stall            (~late_avm_rd_data_fifo_rd_ack),
            .o_almost_empty     (),
            .o_empty            (), //this is tracked separately outside the fifo so that we can reserve space for a read before that read actually happens
            .ecc_err_status     ()
        );
        
        //reserve reads from the fifo before the read itself actually happens
        logic late_i_avm_readdatavalid, late_two_i_avm_readdatavalid;   //this assumes avm_rd_data_fifo has a write to read latency of 3
        always_ff @(posedge clock) begin
            late_i_avm_readdatavalid <= i_avm_readdatavalid;
            late_two_i_avm_readdatavalid <= late_i_avm_readdatavalid;
        end
        
        dla_acl_tessellated_incr_decr_threshold #(
            .CAPACITY                   (M20K_WIDE_FIFO_DEPTH),
            .THRESHOLD                  (1),
            .INITIAL_OCCUPANCY          (0),
            .THRESHOLD_REACHED_AT_RESET (0),
            .ASYNC_RESET                (ASYNC_RESET),
            .SYNCHRONIZE_RESET          (0)
        )
        avm_rd_data_fifo_empty_inst
        (
            .clock                      (clock),
            .resetn                     (resetn_synchronized),
            .incr_no_overflow           (late_two_i_avm_readdatavalid),
            .incr_raw                   (late_two_i_avm_readdatavalid),
            .decr_no_underflow          (avm_rd_data_fifo_rd_ack),
            .decr_raw                   (avm_rd_data_fifo_rd_ack),
            .threshold_reached          (avm_rd_data_fifo_not_empty)
        );
    end
    endgenerate
    
    
    
    /////////////////////////////
    //  Read Request Throttle  //
    /////////////////////////////
    
    //never request more reads than there is space for capturing the response data
    //there is 2 clocks of latency from o_avm_rd_data_fifo_almost_full to i_burstcoal_valid
    //once a memory word enters the burst coalescer, that memory word is considered an outstanding transaction in terms of the throttle
    //easier to add one when something enters burst coalescer rather than add burstcount when the read request leaves the LSU
    //one clock after read data arrives from global memory, that transaction is no longer considered outstanding
    dla_acl_tessellated_incr_decr_threshold #(
        .CAPACITY                   (M20K_WIDE_FIFO_DEPTH),
        .THRESHOLD                  (M20K_WIDE_FIFO_DEPTH-2),
        .INITIAL_OCCUPANCY          (0),
        .THRESHOLD_REACHED_AT_RESET (1),
        .ASYNC_RESET                (ASYNC_RESET),
        .SYNCHRONIZE_RESET          (0)
    )
    avm_rd_data_fifo_almost_full_inst
    (
        .clock                      (clock),
        .resetn                     (resetn_synchronized),
        .incr_no_overflow           (i_burstcoal_valid),
        .incr_raw                   (i_burstcoal_valid),
        .decr_no_underflow          (late_avm_rd_data_fifo_rd_ack), //okay to use a delayed version of read ack since, backpressure to upstream would be released one clock later
        .decr_raw                   (late_avm_rd_data_fifo_rd_ack),
        .threshold_reached          (o_avm_rd_data_fifo_almost_full)
    );
    
    
    
    //////////////////////////
    //  Convert Cmd to Rsp  //
    //////////////////////////
    
    //convert the processing of each kernel word from request to response, this is not a trivial translation
    //for example, suppose kernel word N and kernel word N+1 each span two memory words, and these kernel words can coalesce
    //this means the second memory that kernel word N touches is the same memory word where kernel word N+1 starts
    //in high throughput mode, on the request side no time is allocated for the second memory word of kernel word N, it will be dealt with at the same time as the first memory word of kernel word N+1
    //on the response side, no time is allocated for the first memory word of kernel word N+1, we already read that memory word in the second part of kernel word N so keep the data live
    //there is only one clock cycle to generate the response for kernel word N+1, there is data kept live from kernel word N, and data read from the second memory word of kernel word N+1
    
    generate
    if (HIGH_THROUGHPUT_MODE && ENABLE_WORD_COALESCE) begin : GEN_CMD_FIRST_PRELOADED
        always_ff @(posedge clock or negedge aclrn) begin
            if (~aclrn) cmd_first_preloaded <= 1'b0;
            else begin
                if (i_cmd_fifo_rd_ack) cmd_first_preloaded <= i_cmd_can_coalesce;   //if kernel word N-1 can coalesce, then the first memory word of kernel word N has already been read
                if (~sclrn) cmd_first_preloaded <= 1'b0;
            end
        end
    end
    else begin : NO_CMD_FIRST_PRELOADED
        assign cmd_first_preloaded = 1'b0;
    end
    endgenerate
    
    always_ff @(posedge clock) begin
        rsp_fifo_wr_first_preloaded <= cmd_first_preloaded;
        rsp_fifo_wr_can_coalesce <= i_cmd_can_coalesce;
        rsp_fifo_wr_dont_read_data <= ~i_cmd_spans_two & cmd_first_preloaded;
        rsp_fifo_wr_spans_two <= i_cmd_spans_two;
        rsp_fifo_wr_spans_three <= i_cmd_spans_three;
        rsp_fifo_wr_needs_second_cycle <= i_cmd_spans_three | (i_cmd_spans_two & ~cmd_first_preloaded); //beware this logic is different than the word coalescer
        rsp_fifo_wr_needs_third_cycle <= i_cmd_spans_three & ~cmd_first_preloaded;                      //beware this logic is different than the word coalescer
        rsp_fifo_wr_addr <= i_cmd_addr;
    end
    
    
    
    ////////////////
    //  Rsp FIFO  //
    ////////////////
    
    always_ff @(posedge clock) begin
        rsp_fifo_wr_req <= i_cmd_fifo_rd_ack;
    end
    
    assign rsp_fifo_wr_all_data[0]                     = (MAX_MEM_WORDS_PER_KER_WORD >= 2) ? rsp_fifo_wr_spans_two          : 1'b0;     //see comments on the corresponding read data for an interpretation of each signal
    assign rsp_fifo_wr_all_data[1]                     = (MAX_MEM_WORDS_PER_KER_WORD == 3) ? rsp_fifo_wr_spans_three        : 1'b0;
    assign rsp_fifo_wr_all_data[2]                     = (MAX_MEM_WORDS_PER_KER_WORD >= 2) ? rsp_fifo_wr_needs_second_cycle : 1'b0;
    assign rsp_fifo_wr_all_data[3]                     = (MAX_MEM_WORDS_PER_KER_WORD == 3) ? rsp_fifo_wr_needs_third_cycle  : 1'b0;
    assign rsp_fifo_wr_all_data[4]                     = (ENABLE_WORD_COALESCE)            ? rsp_fifo_wr_can_coalesce       : 1'b0;
    assign rsp_fifo_wr_all_data[5]                     = (ENABLE_WORD_COALESCE)            ? rsp_fifo_wr_first_preloaded    : 1'b0;
    assign rsp_fifo_wr_all_data[6]                     = (HIGH_THROUGHPUT_MODE)            ? rsp_fifo_wr_dont_read_data     : 1'b0;
    assign rsp_fifo_wr_all_data[7 +: INTRA_ADDR_WIDTH] = ~((1<<ADDR_ALIGNMENT_BITS)-1)     & rsp_fifo_wr_addr;
    
    dla_hld_fifo #(
        .WIDTH              (RSP_FIFO_WIDTH),
        .DEPTH              (M20K_WIDE_FIFO_DEPTH),
        .NEVER_OVERFLOWS    (1),
        .ALMOST_FULL_CUTOFF (2),    //1 clock from almost full to cmd fifo read, 1 clock to rsp_fifo_wr_req
        .ASYNC_RESET        (ASYNC_RESET),
        .SYNCHRONIZE_RESET  (0),
        .STYLE              ("ms")
    )
    rsp_fifo_inst
    (
        .clock              (clock),
        .resetn             (resetn_synchronized),
        .i_valid            (rsp_fifo_wr_req),
        .i_data             (rsp_fifo_wr_all_data),
        .o_stall            (),
        .o_almost_full      (o_rsp_fifo_almost_full),
        .o_valid            (),
        .o_data             (rsp_fifo_rd_all_data),
        .i_stall            (~rsp_fifo_rd_ack),
        .o_almost_empty     (),
        .o_empty            (rsp_fifo_empty),
        .ecc_err_status     ()
    );
    
    //quartus does not propagate constants across the ram inside the fifo, so do it again here
    assign rsp_spans_two_raw      = (MAX_MEM_WORDS_PER_KER_WORD >= 2) ? rsp_fifo_rd_all_data[0] : 1'b0;                 //kernel word spans at least two memory words
    assign rsp_spans_three_raw    = (MAX_MEM_WORDS_PER_KER_WORD == 3) ? rsp_fifo_rd_all_data[1] : 1'b0;                 //kernel word spans three memory words
    assign rsp_needs_second_cycle = (MAX_MEM_WORDS_PER_KER_WORD >= 2) ? rsp_fifo_rd_all_data[2] : 1'b0;                 //need at least two clock cycles to process kernel word
    assign rsp_needs_third_cycle  = (MAX_MEM_WORDS_PER_KER_WORD == 3) ? rsp_fifo_rd_all_data[3] : 1'b0;                 //need at least three clock cycles to process kernel word
    assign rsp_can_coalesce       = (ENABLE_WORD_COALESCE)            ? rsp_fifo_rd_all_data[4] : 1'b0;                 //last section of kernel word is in the same memory word as the first section of next kernel word
    assign rsp_first_preloaded    = (ENABLE_WORD_COALESCE)            ? rsp_fifo_rd_all_data[5] : 1'b0;                 //first memory word has already been loaded by the previous kernel word
    assign rsp_dont_read_data     = (HIGH_THROUGHPUT_MODE)            ? rsp_fifo_rd_all_data[6] : 1'b0;                 //if the first memory word has already been loaded, don't try to read it again
    assign rsp_addr               = ~((1<<ADDR_ALIGNMENT_BITS)-1)     & rsp_fifo_rd_all_data[7 +: INTRA_ADDR_WIDTH];    //within a memory word, the address of the first byte that this kernel word touches
    
    //in low throughput mode, if a kernel word spans N memory words it will take N clock cycles to process it regardless of coalescing
    assign rsp_spans_two   = (HIGH_THROUGHPUT_MODE) ? rsp_spans_two_raw   : rsp_needs_second_cycle;
    assign rsp_spans_three = (HIGH_THROUGHPUT_MODE) ? rsp_spans_three_raw : rsp_needs_third_cycle;
    
    
    
    ////////////////////////////
    //  Unaligned Controller  //
    ////////////////////////////
    
    // based on how many memory words a kernel word spans and other info, track the progress of processing one kernel word
    
    // make forward progress in processing a non-predicated kernel word if kernel word info is available in rsp fifo, avm_rd_data_fifo has data (or we already preloaded it) and downstream has space
    assign can_read_rsp_fifo = ~rsp_fifo_empty & (avm_rd_data_fifo_not_empty | rsp_dont_read_data) & ~output_fifo_almost_full & ~i_predicate_fifo_empty & ~i_predicate_fifo_rd_data;
    
    // done with a kernel word if it was predicated, or done processing its last memory word
    assign o_predicate_fifo_rd_ack = rsp_fifo_rd_ack | (~output_fifo_almost_full & ~i_predicate_fifo_empty & i_predicate_fifo_rd_data);
    
    // in high throughput mode, done with a memory word as soon as the first kernel word who needs it reads it, anything needed by a later kernel word will be kept live
    // in low throughput mode, done with a memory word when the last kernel word who needs it reads it
    assign avm_rd_data_fifo_rd_ack = can_read_rsp_fifo & ((HIGH_THROUGHPUT_MODE) ? ~rsp_dont_read_data : ~rsp_is_coalescing);
    
    dla_hld_lsu_unaligned_controller #(
        .ASYNC_RESET                (ASYNC_RESET),
        .MAX_MEM_WORDS_PER_KER_WORD (MAX_MEM_WORDS_PER_KER_WORD),
        .HIGH_THROUGHPUT_MODE       (HIGH_THROUGHPUT_MODE)
    )
    dla_hld_lsu_unaligned_controller_inst
    (
        .clock                      (clock),
        .resetn                     (resetn_synchronized),
    
        //handshaking
        .i_can_read_fifo            (can_read_rsp_fifo),
        .o_fifo_rd_ack              (rsp_fifo_rd_ack),
        
        //information about the kernel word
        .i_spans_two                (rsp_spans_two),
        .i_spans_three              (rsp_spans_three),
        .i_needs_second_cycle       (rsp_needs_second_cycle),
        .i_needs_third_cycle        (rsp_needs_third_cycle),
        .i_can_coalesce             (rsp_can_coalesce),
        
        //state of processing within kernel word
        .o_at_second_cycle          (rsp_at_second_cycle),  //in the second clock cycle of processing current kernel word
        .o_at_third_cycle           (rsp_at_third_cycle),   //in the third clock cycle of processing current kernel word
        .o_is_coalescing            (rsp_is_coalescing),    //does the current section of the kernel word coalesce with the next section (next section could be same or next kernel word)
        .o_first_access_in_word     ()
    );
    
    
    
    //////////////////////////////
    //  Address Range Analysis  //
    //////////////////////////////
    
    //determine which bytes of the kernel word to update once the data read from memory is aligned
    //kernel word is always constructed from lowest byte to high byte, need to ensure the lower bytes which are constructed first do not get clobbered, but okay to write whatever to upper bytes
    
    generate
    if (HIGH_THROUGHPUT_MODE) begin : NO_ADDRESS_DECODE
        assign address_decode = '1; //high throughput mode writes to all bytes of output data at once
    end
    else begin : GEN_ADDRESS_DECODE
        logic [INTRA_ADDR_WIDTH:0] prep_address_decode_lo_limit, address_decode_lo_limit;
        
        //one clock cycle after can_read_rsp_fifo
        always_ff @(posedge clock) begin
            if (rsp_at_third_cycle) prep_address_decode_lo_limit <= (INTRA_ADDR_WIDTH+1)'(2*MEM_DATA_BYTES - rsp_addr);
            else if (rsp_at_second_cycle) prep_address_decode_lo_limit <= MEM_DATA_BYTES - rsp_addr;
            else prep_address_decode_lo_limit <= '0;
        end
        
        dla_acl_shift_register_no_reset #(
            .WIDTH  (INTRA_ADDR_WIDTH+1),
            .STAGES (DATA_ALIGNER_LATENCY)
        )
        address_decode_lo_limit_inst
        (
            .clock  (clock),
            .D      (prep_address_decode_lo_limit),
            .Q      (address_decode_lo_limit)           //DATA_ALIGNER_LATENCY+1 clocks after can_read_rsp_fifo
        );
        
        //DATA_ALIGNER_LATENCY+2 clocks after can_read_rsp_fifo
        always_ff @(posedge clock) begin
            for (int i=0; i<KER_DATA_BYTES; i++) begin
                address_decode[i] <= ((i & ~((1<<ADDR_ALIGNMENT_BITS)-1)) >= address_decode_lo_limit);
            end
        end
    end
    endgenerate
    
    
    
    //////////////////////
    //  Data Alignment  //
    //////////////////////
    
    //in high throughput mode, accumulate all of the data that is needed for the entire kernel word before aligning
    //in low throughput mode, avm_rd_data_fifo_rd_data always feeds the aligner, how much to shift is varied as different memory words make their way through and accumulate in the write data for the output fifo
    
    generate
    if (SHIFT_TO_ALIGN_WIDTH > 0) begin : GEN_SHIFT_TO_ALIGN
        logic [SHIFT_TO_ALIGN_WIDTH-1:0] late_rsp_addr_intra_aligned;
        always_ff @(posedge clock) begin
            late_rsp_addr_intra_aligned <= rsp_addr[INTRA_ADDR_WIDTH-1:ADDR_ALIGNMENT_BITS];    //one clock after can_read_rsp_fifo
            shift_to_align_readdata <= late_rsp_addr_intra_aligned;                             //two clocks after can_read_rsp_fifo
        end
    end
    else begin : NO_SHIFT_TO_ALIGN  //trivial alignment
        assign shift_to_align_readdata = 'x;
    end
    endgenerate
    
    generate
    if (HIGH_THROUGHPUT_MODE) begin : GEN_READDATA_BUFFERS
        //based on the kernel width, memory width, and address alignment, determine how far the kernel word can go into the second or third memory word
        //anything past this does not need a buffer, those bits can be assigned x so that quartus can trim it away
        //it is highly unlikely that quartus can figure out the range analysis to trim away the upper bits of the buffer which are unreachable
        localparam int WIDE_LIMIT = MEM_DATA_BYTES + KER_DATA_BYTES - (2**ADDR_ALIGNMENT_BITS);
        
        //assemble up to three memory words before sending it to the data aligner
        //if kernel word spans one memory word:
        // - data_lo should have the data, it can come from data_lo_buf if this memory word was preloaded by an earlier kernel word
        //if kernel word spans two memory words:
        // - data_lo should have the first memory word -- would have been the previous data read from the fifo, must be captured in data_lo_buf
        // - data_mid should have the second memory word -- would be sourced directly from the fifo read data
        //if kernel word spans three memory words:
        // - data_lo should have the first memory word -- must capture what was read two words ago from the fifo in data_lo_buf
        // - data_mid should have the second memory word -- would have been the previous data read from the fifo, must be captured in data_mid_buf
        // - data_hi should have the third memory word -- would be sourced directly from the fifo read data
        
        genvar g;
        logic [8*MEM_DATA_BYTES-1:0] data_lo, data_mid, data_hi;    //these three memory words feed the data aligner
        logic [8*MEM_DATA_BYTES-1:0] data_lo_buf, data_mid_buf;     //may need to capture previous words read from fifo
        
        //there is 2 clocks of latency from avm_rd_data_fifo_rd_ack until the corresponding data arrives, figure out how to steer the data once it arrives
        logic data_lo_choose_buf, data_lo_choose_buf_early;         //should data_lo come from buffer or directly from fifo read data
        logic data_mid_choose_buf, data_mid_choose_buf_early;       //should data_mid come from buffer or directly from fifo read data
        logic data_lo_buf_enable, data_lo_buf_enable_early_filter;  //should data_lo_buf load from the fifo read data
        logic data_mid_buf_enable;                                  //should data_mid_buf load from the fifo read data
        
        always_ff @(posedge clock) begin
            //one clock after avm_rd_data_fifo_rd_ack
            data_lo_choose_buf_early <= rsp_first_preloaded | rsp_needs_second_cycle;
            data_lo_buf_enable_early_filter <= ~(rsp_needs_third_cycle & rsp_at_second_cycle) & ~(rsp_needs_second_cycle & rsp_first_preloaded & ~rsp_at_second_cycle);
            
            //two clocks after
            data_lo_choose_buf <= data_lo_choose_buf_early;
            data_lo_buf_enable <= late_avm_rd_data_fifo_rd_ack & data_lo_buf_enable_early_filter;
            
            //three clocks after
            if (data_lo_buf_enable) data_lo_buf <= avm_rd_data_fifo_rd_data;
        end
        
        if (MAX_MEM_WORDS_PER_KER_WORD <= 2) begin
            assign data_mid_choose_buf = 1'b0;  //data_mid_buf is only needed if the kernel word spans three memory words
        end
        else begin  //MAX_MEM_WORDS_PER_KER_WORD == 3
            always_ff @(posedge clock) begin
                //one clock after avm_rd_data_fifo_rd_ack
                data_mid_choose_buf_early <= rsp_needs_third_cycle | (rsp_needs_second_cycle & rsp_first_preloaded);
                
                //two clocks after
                data_mid_choose_buf <= data_mid_choose_buf_early;
                data_mid_buf_enable <= late_avm_rd_data_fifo_rd_ack;
                
                //three clocks after
                if (data_mid_buf_enable) data_mid_buf <= avm_rd_data_fifo_rd_data;
            end
        end
        
        assign data_lo = (data_lo_choose_buf) ? data_lo_buf : avm_rd_data_fifo_rd_data;
        for (g=0; g<MEM_DATA_BYTES; g++) begin : GEN_UPPER_BUFFERS
            if (g+MEM_DATA_BYTES < WIDE_LIMIT) begin
                assign data_mid[8*g+:8] = (data_mid_choose_buf) ? data_mid_buf[8*g+:8] : avm_rd_data_fifo_rd_data[8*g+:8];
            end
            else begin
                assign data_mid[8*g+:8] = 'x;   //kernel word can never reach this far in the second memory word
            end
            
            if (g+2*MEM_DATA_BYTES < WIDE_LIMIT) begin
                assign data_hi[8*g+:8] = avm_rd_data_fifo_rd_data[8*g+:8];
            end
            else begin
                assign data_hi[8*g+:8] = 'x;    //kernel word can never reach this far in the third memory word
            end
        end
        
        dla_hld_lsu_data_aligner #(
            .LATENCY        (DATA_ALIGNER_LATENCY),
            .DIRECTION      (1),    //shift left
            .SECTION_WIDTH  (8 * (2**ADDR_ALIGNMENT_BITS)),
            .WRAP_AROUND    (0),    //linear shift
            .I_DATA_WIDTH   (3*8*MEM_DATA_BYTES),
            .I_SHIFT_WIDTH  (SHIFT_TO_ALIGN_WIDTH),
            .O_DATA_WIDTH   (8*KER_DATA_BYTES)
        )
        readdata_aligned_inst
        (
            .clock          (clock),
            .i_data         ({data_hi, data_mid, data_lo}),
            .i_shift        (shift_to_align_readdata),
            .o_data         (readdata_aligned)
        );
    end
    else begin : NO_READDATA_BUFFERS
        dla_hld_lsu_data_aligner #(
            .LATENCY        (DATA_ALIGNER_LATENCY),
            .DIRECTION      (1),    //shift left
            .SECTION_WIDTH  (8 * (2**ADDR_ALIGNMENT_BITS)),
            .WRAP_AROUND    (1),    //wrap-around shift
            .I_DATA_WIDTH   (8*MEM_DATA_BYTES),
            .I_SHIFT_WIDTH  (SHIFT_TO_ALIGN_WIDTH),
            .O_DATA_WIDTH   (8*KER_DATA_BYTES)
        )
        readdata_aligned_inst
        (
            .clock          (clock),
            .i_data         (avm_rd_data_fifo_rd_data),
            .i_shift        (shift_to_align_readdata),
            .o_data         (readdata_aligned)
        );
    end
    endgenerate
    
    
    
    ///////////////////
    //  Output FIFO  //
    ///////////////////
    
    dla_acl_shift_register_no_reset #(
        .WIDTH  (1),
        .STAGES (DATA_ALIGNER_LATENCY + 3)
    )
    output_fifo_wr_req_inst
    (
        .clock  (clock),
        .D      (o_predicate_fifo_rd_ack),
        .Q      (output_fifo_wr_req)
    );
    
    always_ff @(posedge clock) begin
        for (int i=0; i<KER_DATA_BYTES; i++) begin
            //low throughput mode will assemble the aligned data from up to 3 memory words over up to 3 clock cycles, high throughput mode does not do any accumulation here (address_decode is all ones)
            if (address_decode[i]) begin
                output_fifo_wr_data[8*i +: 8] <= readdata_aligned[8*i +: 8];
            end
        end
    end
    
    dla_hld_fifo #(
        .WIDTH                          (8*KER_DATA_BYTES),
        .DEPTH                          (MLAB_FIFO_DEPTH),
        .NEVER_OVERFLOWS                (1),
        .ALMOST_FULL_CUTOFF             (OUTPUT_FIFO_ALMOST_FULL_CUTOFF),
        .USE_STALL_LATENCY_DOWNSTREAM   ((KER_DOWN_STALL_LATENCY) ? 1 : 0),
        .ALMOST_EMPTY_CUTOFF            (KER_DOWN_STALL_LATENCY),
        .ASYNC_RESET                    (ASYNC_RESET),
        .SYNCHRONIZE_RESET              (0),
        .STYLE                          ("ms")
    )
    output_fifo_inst
    (
        .clock                          (clock),
        .resetn                         (resetn_synchronized),
        .i_valid                        (output_fifo_wr_req),
        .i_data                         (output_fifo_wr_data),
        .o_stall                        (),
        .o_almost_full                  (output_fifo_almost_full),
        .o_valid                        (o_valid),
        .o_data                         (o_readdata),
        .i_stall                        (i_stall),
        .o_almost_empty                 (o_almost_empty),
        .o_empty                        (o_empty),
        .ecc_err_status                 ()
    );
    
    
endmodule


`default_nettype wire
