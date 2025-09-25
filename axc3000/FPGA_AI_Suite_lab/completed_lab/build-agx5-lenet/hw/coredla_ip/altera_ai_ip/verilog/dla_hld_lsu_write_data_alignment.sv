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

// This module accepts kernel words and produces memory words, specifically the avalon writedata and byteenable. An avalon write can only be released to memory once
// the address and burstcount are also available (this comes from the burst coalescer). Both this module and the burst coalescer output a fifo read interface for avalon,
// when both fifos are not empty then an avalon write is released.
//
// The writedata and byteenable inputs to the this module is the read side of the input fifos within dla_hld_lsu. Data is temporarily stored there to give time for the
// word coalescer to do its thing. The unaligned controller tracks the progress of processing each kernel word, this is used to steer the pipelined data alignment logic
// inside this module. Arbitrary address alignment is supported, and the data aligner barrel shifter can have an arbitrary amount of latency for pipelining.
//
// For additional info, refer to dla_hld_global_load_store.sv (top module of entire LSU) and dla_hld_lsu.sv (top module of the core LSU).

`default_nettype none

module dla_hld_lsu_write_data_alignment #(
    parameter bit ASYNC_RESET,                  //0 = registers consume reset synchronously, 1 = registers consume reset asynchronously
    parameter int ADDR_ALIGNMENT_BITS,          //indicates how many least significant bits of i_address are known to be 0, e.g. set this parameter to 3 if kernel accesses are 8-byte aligned
    parameter int INTRA_ADDR_WIDTH,             //how many least significant bits of the byte address represent the location inside a memory word
    parameter int KER_DATA_BYTES,               //width of kernel data path in bytes, does not need to be a power of 2
    parameter int KER_DATA_BYTES_LAST,          //in case width adaption is used in dla_hld_global_load_store, the last slice of the kernel data path may be smaller
    parameter int MEM_DATA_BYTES,               //width of memory data path in bytes, must be a power of 2
    parameter int DATA_ALIGNER_MUX_PER_PIPE,    //0 = use comb logic for data alignment mux, 1 or more = max number of 2:1 muxes before a pipeline stage is added, e.g. 2 means up to 4:1 mux between reg
    parameter bit USE_BYTE_ENABLE,              //set to 0 if i_byteenable is always all ones, this will save some area, only write LSU consumes this parameter
    parameter bit HIGH_THROUGHPUT_MODE,         //0 = use N clock cycles to process a kernel word that spans N memory words, 1 = use minimum amount of time to process kernel words, only matters if N >= 2
    parameter int MAX_MEM_WORDS_PER_KER_WORD,   //trim some logic if it is guaranteed that each kernel word can only span 1 or 2 memory words
    parameter int M20K_WIDE_FIFO_DEPTH          //use a deep fifo if handshaking is expected to take hundreds of clocks e.g. going off chip, for wide data path use M20K in shallowest mode, but may as well use all depth available
) (
    input  wire                         clock,
    input  wire                         resetn,
    
    //from word coalescer
    input  wire                         i_cmd_more_wide_sections,
    input  wire                         i_cmd_spans_two,
    input  wire                         i_cmd_spans_three,
    input  wire  [INTRA_ADDR_WIDTH-1:0] i_cmd_addr_modulo,
    input  wire  [INTRA_ADDR_WIDTH-1:0] i_cmd_addr,
    
    //from unaligned controller
    input  wire                         i_can_read_cmd_fifo,
    input  wire                         i_cmd_fifo_rd_ack,
    input  wire                         i_cmd_at_second_cycle,
    input  wire                         i_cmd_at_third_cycle,
    input  wire                         i_cmd_is_coalescing,
    input  wire                         i_cmd_first_access_in_word,
    
    //read side of input fifos -- guaranteed to not underflow
    input  wire    [KER_DATA_BYTES-1:0] i_input_byteenable_fifo_rd_data,
    output logic                        o_input_byteenable_fifo_rd_ack,
    input  wire  [8*KER_DATA_BYTES-1:0] i_input_writedata_fifo_rd_data,
    output logic                        o_input_writedata_fifo_rd_ack,
    
    //avm wr data fifo -- this will combine with addr and burst count from burst coalescer to make the full avalon transaction
    output logic                        o_avm_wr_data_fifo_almost_full,
    output logic                        o_avm_wr_data_fifo_empty,
    input  wire                         i_avm_wr_data_fifo_rd_ack,
    output logic [8*MEM_DATA_BYTES-1:0] o_avm_writedata,
    output logic   [MEM_DATA_BYTES-1:0] o_avm_byteenable
);
    
    
    //disregarding address alignment, this is how many 2:1 mux stages the data aligner would have needed
    localparam int RAW_SHIFT_TO_ALIGN_WIDTH = (HIGH_THROUGHPUT_MODE) ? (($clog2(KER_DATA_BYTES) > INTRA_ADDR_WIDTH) ? INTRA_ADDR_WIDTH : $clog2(KER_DATA_BYTES)) : $clog2(KER_DATA_BYTES);
    
    //this is how many 2:1 mux stages the data aligner will need
    localparam int SHIFT_TO_ALIGN_WIDTH = RAW_SHIFT_TO_ALIGN_WIDTH - ADDR_ALIGNMENT_BITS;
    
    //latency = ceiling(mux stages needed / max mux stages per pipe), but 0 means use combinational logic
    localparam int DATA_ALIGNER_LATENCY = (DATA_ALIGNER_MUX_PER_PIPE == 0) ? 0 : ((SHIFT_TO_ALIGN_WIDTH + DATA_ALIGNER_MUX_PER_PIPE - 1) / DATA_ALIGNER_MUX_PER_PIPE);
    
    //1 clock from almost full to unaligned controller, 2 clock cycles until start of data alignment, DATA_ALIGNER_LATENCY to do alignment, 1 clock for the register stage that accumulates the write data for avm data fifo
    localparam int AVM_WR_DATA_FIFO_ALMOST_FULL_CUTOFF = DATA_ALIGNER_LATENCY + 4;
    
    //based on the kernel width, memory width, and address alignment, determine how far the kernel word can go into the second or third memory word
    //anything past this does not need a buffer, those bits can be assigned x so that quartus can trim it away
    //it is highly unlikely that quartus can figure out the range analysis to trim away the upper bits of the buffer which are unreachable
    localparam int WIDE_LIMIT = (HIGH_THROUGHPUT_MODE) ? (MEM_DATA_BYTES + KER_DATA_BYTES - (2**ADDR_ALIGNMENT_BITS)) : MEM_DATA_BYTES;
    
    
    
    ///////////////
    //  Signals  //
    ///////////////
    
    genvar g;
    
    //reset
    logic                               aclrn, sclrn, resetn_synchronized;
    
    //address range analysis
    logic        [INTRA_ADDR_WIDTH-1:0] prep_master_lo_limit, prep_master_hi_limit;
    logic        [INTRA_ADDR_WIDTH-1:0] addr_master_lo_limit, addr_master_hi_limit;
    logic          [MEM_DATA_BYTES-1:0] late_addr_master_mask_lo, late_addr_master_mask_hi;
    logic                               late_prep_not_in_first, late_prep_not_in_last, late_prep_spans_two, late_prep_spans_three;
    logic                               late_addr_not_in_first, late_addr_not_in_last, late_addr_spans_two, late_addr_spans_three;
    logic        [3*MEM_DATA_BYTES-1:0] late_addr_decode_lo, late_addr_decode_hi, late_addr_decode;
    
    //byteenable alignment
    logic    [SHIFT_TO_ALIGN_WIDTH-1:0] shift_to_align_byteenable;
    logic        [3*MEM_DATA_BYTES-1:0] aligned_byteenable;
    
    //data alignment
    logic    [SHIFT_TO_ALIGN_WIDTH-1:0] shift_to_align_writedata;
    logic      [3*8*MEM_DATA_BYTES-1:0] aligned_writedata;
    
    //which bytes of kernel word to accumulate into memory word
    logic                               aligned_byteenable_valid, aligned_writedata_valid;
    logic        [3*MEM_DATA_BYTES-1:0] load_enable;
    
    //aligned byteenable and writedata capture
    logic          [MEM_DATA_BYTES-1:0] captured_load_enable;       //only used by high throughput mode
    logic        [8*MEM_DATA_BYTES-1:0] captured_aligned_writedata; //only used by high throughput mode
    logic                               captured_kernel_word_valid, current_kernel_word_valid;
    
    //avm wr data fifo
    logic                               prep_clear_byteenables, clear_byteenables;
    logic                               prep_write_to_fifo, write_to_fifo;
    logic                               avm_wr_data_fifo_wr_req;
    logic        [8*MEM_DATA_BYTES-1:0] avm_wr_data_fifo_wr_writedata;
    logic          [MEM_DATA_BYTES-1:0] avm_wr_data_fifo_wr_byteenable;
    
    
    
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
    
    
    
    //////////////////////////////
    //  Address Range Analysis  //
    //////////////////////////////
    
    //based on the address and size of the kernel word, determine which bytes of memory will be affected
    //we have DATA_ALIGNER_LATENCY+1 clock cycles to produce a mask that will integrate with the aligned byteenables, and that becomes the load enable for assembling the write data for the avm_wr_data_fifo
    //one kernel word can span up to 3 memory words, for example suppose the memory width is 4, kernel width is 8, and address is 3
    //in this example, the first byte of memory affected is address 3, and the last byte (inclusive) is address 10
    //it touches address 3 in the first memory word, addresses 4 through 7 in the second, and addresses 8 through 10 in the third
    //the way address decoding is implemented, we will produce one master mask (which is the width of one memory word), then derive an individual masks for each of the up to 3 memory words
    //the master mask is defined by the lowest and highest (inclusive) bytes of memory affected, modulo the memory width, so lo=3 and hi=2 in this example, the mask has ones in the indexes between lo and hi inclusive
    //if the kernel word only spans one memory word, then hi>lo and the mask can be used without modification
    //if the kernel word spans two memory words, then hi is ignored when constructing the mask for the first memory word, and lo is ignored when constructing the mask for the second memory word
    //if the kernel word spans three memory words, then hi is ignored in the first memory word, both hi and lo are ignored in the second word, and lo is ignored in the third memory word
    //in this example, we would end up with these masks: first = 1000 (lo=3, ignore hi), second = 1111 (ignore lo and hi), third = 0111 (ignored lo, hi=2)
    
    //determine the high and low limits for the master mask
    //same clock cycle as i_can_read_cmd_fifo
    assign prep_master_lo_limit = i_cmd_addr;
    assign prep_master_hi_limit = (INTRA_ADDR_WIDTH)'(i_cmd_addr + ((i_cmd_more_wide_sections) ? (KER_DATA_BYTES-1) : (KER_DATA_BYTES_LAST-1)));
    
    dla_acl_shift_register_no_reset #(
        .WIDTH  (2*INTRA_ADDR_WIDTH),
        .STAGES (DATA_ALIGNER_LATENCY)
    )
    addr_master_limits_inst
    (
        .clock  (clock),
        .D      ({prep_master_hi_limit, prep_master_lo_limit}),
        .Q      ({addr_master_hi_limit, addr_master_lo_limit})      //DATA_ALIGNER_LATENCY clocks after i_can_read_cmd_fifo
    );
    
    //convert the high and low limits into a mask
    //DATA_ALIGNER_LATENCY+1 clocks after i_can_read_cmd_fifo
    generate
    if (MAX_MEM_WORDS_PER_KER_WORD == 1) begin : NO_MASTER_MASK_HI  //LSU is aligned, use equality to do the decode, need to figure out which half, quarter, eighth, etc. of the memory word to update
        always_ff @(posedge clock) begin
            for (int i=0; i<MEM_DATA_BYTES; i++) begin
                late_addr_master_mask_lo[i] <= ((i & ~((1<<ADDR_ALIGNMENT_BITS)-1)) == addr_master_lo_limit);
            end
        end
        //late_addr_master_mask_hi not needed
    end
    else begin : GEN_MASTER_MASK_HI                                 //LSU is unaligned, no special tricks to decode the high and low limits into a mask
        always_ff @(posedge clock) begin
            for (int i=0; i<MEM_DATA_BYTES; i++) begin
                late_addr_master_mask_lo[i] <= ((i & ~((1<<ADDR_ALIGNMENT_BITS)-1)) >= addr_master_lo_limit);   //if ADDR_ALIGNMENT_BITS=2, then indexes 0, 1, 2, and 3 produce the same result, quartus should remove duplicates
                late_addr_master_mask_hi[i] <= ((i & ~((1<<ADDR_ALIGNMENT_BITS)-1)) <= addr_master_hi_limit);   //the idea is that if we are 4 byte aligned, only every 4th index of the master mask actually needs to be computed
            end
        end
    end
    endgenerate
    
    //determine the filters to convert the master mask into the masks for each of the three memory words
    //one clock cycle after i_can_read_cmd_fifo
    always_ff @(posedge clock) begin
        late_prep_not_in_first <= i_cmd_at_second_cycle | i_cmd_at_third_cycle;                                             //ignore master mask lo when not in the first memory word
        late_prep_not_in_last <= ~i_cmd_at_third_cycle & ((i_cmd_at_second_cycle) ? i_cmd_spans_three : i_cmd_spans_two);   //ignore master mask hi when not in the last memory word
        late_prep_spans_two <= i_cmd_spans_two;         //in high throughput mode, ignore master mask hi when in the first memory word if kernel word spans at least 2 memory words
        late_prep_spans_three <= i_cmd_spans_three;     //in high throughput mode, ignreo master mask hi when in the second memory word if kernel word spans 3 memory words
    end
    
    dla_acl_shift_register_no_reset #(
        .WIDTH  (4),
        .STAGES (DATA_ALIGNER_LATENCY)
    )
    late_addr_filters_inst
    (
        .clock  (clock),
        .D      ({late_prep_spans_three, late_prep_spans_two, late_prep_not_in_last, late_prep_not_in_first}),
        .Q      ({late_addr_spans_three, late_addr_spans_two, late_addr_not_in_last, late_addr_not_in_first})   //DATA_ALIGNER_LATENCY+1 clocks after i_can_read_cmd_fifo
    );
    
    //apply the filters, DATA_ALIGNER_LATENCY+1 clocks after i_can_read_cmd_fifo
    
    //in high throughput mode this is for the first memory word, in low throughput mode all memory words time-share this
    assign late_addr_decode_lo[MEM_DATA_BYTES-1:0] = (late_addr_not_in_first) ? '1 : late_addr_master_mask_lo;
    assign late_addr_decode_hi[MEM_DATA_BYTES-1:0] = ((HIGH_THROUGHPUT_MODE) ? late_addr_spans_two : late_addr_not_in_last) ? '1 : late_addr_master_mask_hi;
    
    //second memory word for high throughput mode only (low throughput mode doesn't use this)
    assign late_addr_decode_lo[2*MEM_DATA_BYTES-1:MEM_DATA_BYTES] = '1;
    assign late_addr_decode_hi[2*MEM_DATA_BYTES-1:MEM_DATA_BYTES] = (late_addr_spans_three) ? '1 : late_addr_master_mask_hi;
    
    //third memory word for high throughput mode only (low throughput mode doesn't use this)
    assign late_addr_decode_lo[3*MEM_DATA_BYTES-1:2*MEM_DATA_BYTES] = '1;
    assign late_addr_decode_hi[3*MEM_DATA_BYTES-1:2*MEM_DATA_BYTES] = late_addr_master_mask_hi;
    
    //combine low and high masks
    generate
    if (ADDR_ALIGNMENT_BITS == INTRA_ADDR_WIDTH) begin : TRIVIAL_ADDR_DECODE    //kernel word is same size as memory word and exactly aligns, trivial address decode
        assign late_addr_decode = '1;
    end
    else if (MAX_MEM_WORDS_PER_KER_WORD == 1) begin : ALIGNED_ADDR_DECODE       //LSU is aligned, ignore late_addr_decode_hi since late_addr_master_mask_lo was decoded using equality and therefore contains high and low limits
        assign late_addr_decode = late_addr_decode_lo;
    end
    else begin : UNALIGNED_ADDR_DECODE                                          //LSU is unaligned
        assign late_addr_decode = late_addr_decode_lo & late_addr_decode_hi;
    end
    endgenerate
    
    
    
    ////////////////////////////
    //  Byteenable Alignment  //
    ////////////////////////////
    
    //the state of the unaligned controller indicates how far along we currently are in processing a kernel word
    //there is one clock cycle of pipelining from this state to the steering logic for the byteenables
    //for example, if the unaligned controller is in the second memory word of kernel word N at time T, then how much to shift the byteenables for the second memory word of kernel word N must be known at time T+1
    //if the unaligned controller is completely done with kernel word N at time X, send a read ack to input byteenable fifo at time X+1
    
    always_ff @(posedge clock) begin
        o_input_byteenable_fifo_rd_ack <= i_cmd_fifo_rd_ack;
    end
    
    generate
    if (SHIFT_TO_ALIGN_WIDTH > 0) begin : GEN_SHIFT_TO_ALIGN
        logic [SHIFT_TO_ALIGN_WIDTH+ADDR_ALIGNMENT_BITS-1:0] shift_to_align_raw;     //this is how much to shift if we disregard address alignment info
        
        if ($clog2(KER_DATA_BYTES) < INTRA_ADDR_WIDTH) begin : NARROW   //kernel width is no more than half the memory width (impossible to get into third memory word), use modulo which has a narrower bit width
            if (HIGH_THROUGHPUT_MODE) begin : HI
                always_ff @(posedge clock) begin
                    shift_to_align_raw <= i_cmd_addr_modulo;
                end
            end
            else begin : LO
                always_ff @(posedge clock) begin
                    if (i_cmd_at_second_cycle) shift_to_align_raw <= i_cmd_addr + (KER_DATA_BYTES - MEM_DATA_BYTES);
                    else shift_to_align_raw <= i_cmd_addr_modulo;
                end
            end
        end
        else begin : WIDE   //kernel width is more than half the memory width, shift width is at least as wide as the intra addr so no advantage to using modulo
            if (HIGH_THROUGHPUT_MODE) begin : HI
                always_ff @(posedge clock) begin
                    shift_to_align_raw <= i_cmd_addr;
                end
            end
            else begin : LO
                always_ff @(posedge clock) begin
                    if (i_cmd_at_third_cycle) shift_to_align_raw <= i_cmd_addr + (KER_DATA_BYTES - 2*MEM_DATA_BYTES);
                    else if (i_cmd_at_second_cycle) shift_to_align_raw <= i_cmd_addr + (KER_DATA_BYTES - MEM_DATA_BYTES);
                    else shift_to_align_raw <= i_cmd_addr;
                end
            end
        end
        
        //if ADDR_ALIGNMENT_BITS=1 then shift_to_align_raw is even, instead of shifting each 8 bit section of data by using shift_to_align_raw, we should shift each 16 bit section of data by shift_to_align_raw/2
        assign shift_to_align_byteenable = shift_to_align_raw[SHIFT_TO_ALIGN_WIDTH+ADDR_ALIGNMENT_BITS-1:ADDR_ALIGNMENT_BITS];
    end
    else begin : NO_SHIFT_TO_ALIGN  //trivial alignment
        assign shift_to_align_byteenable = 'x;
    end
    endgenerate
    
    //now that we know how much to shift the byteenables, actually do it
    generate
    if (!USE_BYTE_ENABLE) begin : NO_ALIGN_BYTEENABLE
        assign aligned_byteenable = '1;
    end
    else begin : GEN_ALIGN_BYTEENABLE
        dla_hld_lsu_data_aligner #(
            .LATENCY        (DATA_ALIGNER_LATENCY),
            .DIRECTION      (0), //shift right
            .SECTION_WIDTH  (1 * (2**ADDR_ALIGNMENT_BITS)),
            .WRAP_AROUND    (1),
            .I_DATA_WIDTH   (KER_DATA_BYTES),
            .I_SHIFT_WIDTH  (SHIFT_TO_ALIGN_WIDTH),
            .O_DATA_WIDTH   (3*MEM_DATA_BYTES)
        )
        aligned_byteenable_inst
        (
            .clock          (clock),
            .i_data         (i_input_byteenable_fifo_rd_data),
            .i_shift        (shift_to_align_byteenable),
            .o_data         (aligned_byteenable)
        );
    end
    endgenerate
    
    
    
    //////////////////////
    //  Data Alignment  //
    //////////////////////
    
    //byteenable is one clock later than unaligned controller, writedata is two clocks later than unaligned controller
    
    //input byteenable fifo has no stall in earliness, but input writedata fifo has stall in earliness of 1, so writedata will arrive one clock later than byteenable
    assign o_input_writedata_fifo_rd_ack = o_input_byteenable_fifo_rd_ack;
    
    always_ff @(posedge clock) begin
        shift_to_align_writedata <= shift_to_align_byteenable;
    end
    
    dla_hld_lsu_data_aligner #(
        .LATENCY        (DATA_ALIGNER_LATENCY),
        .DIRECTION      (0), //shift right
        .SECTION_WIDTH  (8 * (2**ADDR_ALIGNMENT_BITS)),
        .WRAP_AROUND    (1),
        .I_DATA_WIDTH   (8*KER_DATA_BYTES),
        .I_SHIFT_WIDTH  (SHIFT_TO_ALIGN_WIDTH),
        .O_DATA_WIDTH   (3*8*MEM_DATA_BYTES)
    )
    aligned_writedata_inst
    (
        .clock          (clock),
        .i_data         (i_input_writedata_fifo_rd_data),
        .i_shift        (shift_to_align_writedata),
        .o_data         (aligned_writedata)
    );
    
    
    
    /////////////////////////////////////////////////////////////////
    //  Which Bytes of Kernel Word to Accumulate into Memory Word  //
    /////////////////////////////////////////////////////////////////
    
    //byteenable is scheduled one clock earlier than writedata in the pipeline so that we have one clock cycle to combine address range analysis and the aligned byteenables
    
    dla_acl_shift_register_no_reset #(
        .WIDTH  (1),
        .STAGES (DATA_ALIGNER_LATENCY+1)
    )
    aligned_byteenable_valid_inst
    (
        .clock  (clock),
        .D      (i_can_read_cmd_fifo),
        .Q      (aligned_byteenable_valid)
    );
    
    generate
    for (g=0; g<3*MEM_DATA_BYTES; g++) begin : LOAD_ENABLE
        if (g < WIDE_LIMIT) begin : GEN_LOAD_ENABLE
            always_ff @(posedge clock) begin
                load_enable[g] <= late_addr_decode[g] & aligned_byteenable[g] & aligned_byteenable_valid;   //DATA_ALIGNER_LATENCY+2 clocks after i_can_read_cmd_fifo
            end
        end
        else begin : NO_LOAD_ENABLE
            assign load_enable[g] = 1'b0;
        end
    end
    endgenerate
    always_ff @(posedge clock) begin
        aligned_writedata_valid <= aligned_byteenable_valid;    //output of the writedata aligner is valid one clock after the output of the byteenable aligner
    end
    
    
    
    ////////////////////////////////////////////////
    //  Aligned Byteenable and Writedata Capture  //
    ////////////////////////////////////////////////
    
    //in high throughput mode, the data aligner is used once per kernel word no matter how many memory words it spans
    //can only write one memory word at a time to avm_wr_data_fifo, so need to keep up to 2 other memory words live for writing to the fifo later on
    
    generate
    if (HIGH_THROUGHPUT_MODE && MAX_MEM_WORDS_PER_KER_WORD >= 2) begin : GEN_WRITEDATA_BUFFERS
        
        //write data for avm_wr_data_fifo can come from both aligned_writedata and captured_aligned_writedata, control when to load from each
        logic prep_captured_kernel_word_valid;  //in DATA_ALIGNER_LATENCY+2 clocks from now, should the write data for avm_wr_data_fifo accumulate from captured_aligned_writedata
        logic prep_current_kernel_word_valid;   //in DATA_ALIGNER_LATENCY+2 clocks from now, should the write data for avm_wr_data_fifo accumulate from aligned_writedata
        logic prep_capture_to_load_from_hi;     //in DATA_ALIGNER_LATENCY+2 clocks from now, should captured_aligned_writedata load from captured_aligned_writedata_hi instead of aligned_writedata
        logic capture_to_load_from_hi;
        
        always_ff @(posedge clock or negedge aclrn) begin
            if (~aclrn) prep_captured_kernel_word_valid <= 1'b0;
            else begin
                if (i_can_read_cmd_fifo) prep_captured_kernel_word_valid <= (~i_cmd_at_second_cycle & ~i_cmd_at_third_cycle & i_cmd_spans_two) | (i_cmd_at_second_cycle & i_cmd_spans_three);
                if (~sclrn) prep_captured_kernel_word_valid <= 1'b0;
            end
        end
        assign prep_current_kernel_word_valid = ~i_cmd_at_second_cycle & ~i_cmd_at_third_cycle;
        assign prep_capture_to_load_from_hi = i_cmd_at_second_cycle;
        
        dla_acl_shift_register_no_reset #(
            .WIDTH  (3),
            .STAGES (DATA_ALIGNER_LATENCY+2)
        )
        kernel_word_valids_inst
        (
            .clock  (clock),
            .D      ({prep_captured_kernel_word_valid, prep_current_kernel_word_valid, prep_capture_to_load_from_hi}),
            .Q      ({     captured_kernel_word_valid,      current_kernel_word_valid,      capture_to_load_from_hi})
        );
        
        //capture the second and third memory words of the kernel word so that it can written into avm_wr_data_fifo later on
        if (MAX_MEM_WORDS_PER_KER_WORD == 2) begin : TWO_MEM_WORDS
            for (g=0; g<MEM_DATA_BYTES; g++) begin : CAPTURE
                if (g+MEM_DATA_BYTES < WIDE_LIMIT) begin : GEN_CAPTURE  //limit the size of the buffer based on how far into the second memory word the kernel word can go
                    always_ff @(posedge clock) begin
                        if (aligned_writedata_valid) begin
                            captured_load_enable[g] <= load_enable[g+MEM_DATA_BYTES];
                            captured_aligned_writedata[8*g+:8] <= aligned_writedata[8*(g+MEM_DATA_BYTES)+:8];
                        end
                    end
                end
                else begin : NO_CAPTURE     //this should get trimmed away by quartus
                    assign captured_load_enable[g] = 1'h0;
                    assign captured_aligned_writedata[8*g+:8] = 'x;
                end
            end
        end
        else begin : THREE_MEM_WORDS    //MAX_MEM_WORDS_PER_KER_WORD == 3
            logic [MEM_DATA_BYTES-1:0] captured_load_enable_hi;
            logic [8*MEM_DATA_BYTES-1:0] captured_aligned_writedata_hi;
            for (g=0; g<MEM_DATA_BYTES; g++) begin : CAPTURE
                if (g+MEM_DATA_BYTES < WIDE_LIMIT) begin : GEN_CAPTURE  //limit the size of the buffer based on how far into the third memory word the kernel word can go
                    always_ff @(posedge clock) begin
                        if (aligned_writedata_valid) begin
                            captured_load_enable_hi[g] <= load_enable[g+2*MEM_DATA_BYTES];
                            captured_aligned_writedata_hi[8*g+:8] <= aligned_writedata[8*(g+2*MEM_DATA_BYTES)+:8];
                        end
                    end
                end
                else begin : NO_CAPTURE     //this should get trimmed away by quartus
                    assign captured_load_enable_hi[g] = 1'h0;
                    assign captured_aligned_writedata_hi[8*g+:8] = 'x;
                end
            end
            always_ff @(posedge clock) begin    //if the kernel word can go into the third memory word, there is no size trimming possible for the buffer that stores the second memory word
                if (aligned_writedata_valid) begin
                    if (capture_to_load_from_hi) begin
                        captured_load_enable <= captured_load_enable_hi;
                        captured_aligned_writedata <= captured_aligned_writedata_hi;    //some bits of captured_aligned_writedata_hi may be x, 2:1 mux for captured_aligned_writedata may not span full memory word width
                    end
                    else begin
                        captured_load_enable <= load_enable[2*MEM_DATA_BYTES-1:MEM_DATA_BYTES];
                        captured_aligned_writedata <= aligned_writedata[2*8*MEM_DATA_BYTES-1:8*MEM_DATA_BYTES];
                    end
                end
            end
        end
    end
    else begin : NO_WRITEDATA_BUFFERS
        assign captured_kernel_word_valid = 1'b0;   //low throughput mode does not have the buffers to keep data live like high throughput mode
        assign current_kernel_word_valid = 1'b1;    //low throughput mode always sources from aligned_writedata
    end
    endgenerate
    
    
    
    /////////////////////
    //  Avm Data FIFO  //
    /////////////////////
    
    always_ff @(posedge clock) begin
        //1 clock after i_can_read_cmd_fifo
        prep_clear_byteenables <= i_can_read_cmd_fifo & i_cmd_first_access_in_word;     //first access in this memory word, clear out whatever the byteenables have accumulated from the previous memory word
        prep_write_to_fifo <= i_can_read_cmd_fifo & ~i_cmd_is_coalescing;               //done accumulating kernel words into this memory word
    end
    
    dla_acl_shift_register_no_reset #(
        .WIDTH  (2),
        .STAGES (DATA_ALIGNER_LATENCY+1)
    )
    avm_wr_data_fifo_write_control_inst
    (
        .clock  (clock),
        .D      ({prep_write_to_fifo, prep_clear_byteenables}),
        .Q      ({     write_to_fifo,      clear_byteenables})
    );
    
    always_ff @(posedge clock) begin
        //write when we have finished consuming kernel words to fully construct this memory word
        avm_wr_data_fifo_wr_req <= write_to_fifo;
        
        //clear byteenables if first write
        if (clear_byteenables) avm_wr_data_fifo_wr_byteenable <= '0;
        
        //only high throughput mode can integrate in previous captured data
        if (captured_kernel_word_valid) begin
            for (int i=0; i<MEM_DATA_BYTES; i++) begin
                if (captured_load_enable[i]) begin
                    avm_wr_data_fifo_wr_writedata[8*i +: 8] <= captured_aligned_writedata[8*i +: 8];
                    avm_wr_data_fifo_wr_byteenable[i] <= 1'b1;
                end
            end
        end
        
        //integrate in aligned_writedata
        //low throughput mode gets all of the data through aligned_writedata by shifting the kernel word by different amounts over different clock cycles
        //in high throughput mode, only the first memory word comes in through here, later memory words from the same kernel word are captured for writing later (possibly together with first memory word of next kernel word)
        if (current_kernel_word_valid) begin
            for (int i=0; i<MEM_DATA_BYTES; i++) begin
                if (load_enable[i]) begin
                    avm_wr_data_fifo_wr_writedata[8*i +: 8] <= aligned_writedata[8*i +: 8];
                    avm_wr_data_fifo_wr_byteenable[i] <= 1'b1;
                end
            end
        end
    end
    
    dla_hld_fifo #(
        .WIDTH              (MEM_DATA_BYTES + 8*MEM_DATA_BYTES),
        .DEPTH              (M20K_WIDE_FIFO_DEPTH),
        .NEVER_OVERFLOWS    (1),
        .ALMOST_FULL_CUTOFF (AVM_WR_DATA_FIFO_ALMOST_FULL_CUTOFF),
        .ASYNC_RESET        (ASYNC_RESET),
        .SYNCHRONIZE_RESET  (0),
        .STYLE              ("ms")
    )
    avm_wr_data_fifo_inst
    (
        .clock              (clock),
        .resetn             (resetn_synchronized),
        .i_valid            (avm_wr_data_fifo_wr_req),
        .i_data             ({avm_wr_data_fifo_wr_byteenable, avm_wr_data_fifo_wr_writedata}),
        .o_stall            (),
        .o_almost_full      (o_avm_wr_data_fifo_almost_full),
        .o_valid            (),
        .o_data             ({o_avm_byteenable, o_avm_writedata}),
        .i_stall            (~i_avm_wr_data_fifo_rd_ack),
        .o_almost_empty     (),
        .o_empty            (o_avm_wr_data_fifo_empty),
        .ecc_err_status     ()
    );
    
endmodule

`default_nettype wire

    
    