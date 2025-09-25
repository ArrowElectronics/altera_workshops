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

// This module implements burst coalescing as a bump-in-the-wire architecture. It accepts word addresses and tries to form avalon bursts by looking for sequential word addresses. To play
// nicely with HLD global interconnect, this module also does not allow bursts to cross a burst boundary. That means if the max burst size is 16, bursts cannot cross a boundary of 16 words.
// Note this module only operates on word addresses whereas most of the LSU operates on byte addresses.
//
// The result of burst coalescing is one request for each burst. This is fine for read requests, but a write burst of length B is transferred over B clock cycles. To simply the fifo read
// control inside the write LSU, every read from the avm_ctrl_fifo results in one read from the avm_wr_data_fifo. The avm_ctrl_fifo is the output from the burst coalescer and ultimately
// drives avm_address and o_avm_burstcount. The avm_wr_data_fifo is the output from the write data aligner and ultimately drives avm_writedata and avm_byteenable. To make the read count from
// these fifos match, there is a repeater inside this module which receives one burst of length B from the burst coalescer and write B copies of this into the avm_ctrl_fifo.
//
// The input to this module may also seem a bit strange, the actual word address that burst coalesce operates on is i_base_addr + i_add_to_base_addr. Why not do the add outside this module?
// Because the adder is tessellated, and we can start comparing if the addresses are sequential on the lower bits while the upper bits are still being added. This is why the adder lives
// inside this module. The purpose of i_add_to_base_addr is for when a kernel word spans more than one memory word, since i_base_addr is the word address of the first memory word, we need
// to compute i_base_addr+1 for the second memory word, and i_base_addr+2 for the third memory word that this kernel word touches. If i_add_to_base_addr is known to be 0 e.g. the LSU is
// aligned, one pipeline stage can be removed to save area.
//
// If one is using read cache, burst coalescing inside the LSU is disabled, and there is a burst coalescer inside the cache to make bursts for cache misses. Additionally, the read LSU has
// throttle logic to not request more reads than it has space for. The cache capacity is at least as large as the throttle threshold, therefore the cache will never backpressure the burst
// coalescer inside the LSU, and so avm_ctrl_fifo can be bypassed.
//
// Even if burst coalescing as a feature is not used, one still needs to pass signals through this module for the adder (i_base_addr + i_add_to_base_addr) and the fifo (the unaligned
// controller operates with stall latency, must have enough downstream space available to catch things in flight).
//
// For additional info, refer to dla_hld_global_load_store.sv (top module of entire LSU) and dla_hld_lsu.sv (top module of the core LSU).

`default_nettype none

module dla_hld_lsu_burst_coalescer #(
    //parameters that are different from dla_hld_lsu.sv
    parameter bit USE_REPEATER,                 //set to 0 for read LSU, set to 1 for write LSU, using a repeater means one burst of length B will be written B times into avm_ctrl_fifo
    parameter int UPSTREAM_STALL_LATENCY,       //latency from o_almost_full to i_valid
    parameter bit NO_AVM_WAITREQUEST,           //set to 1 if read cache is being used, guaranteed that cache can accept the transaction immediately since cache capacity is larger than throttle threshold
    parameter bit ADD_TO_ADDR_IS_ZERO,          //set to 1 if i_add_to_base_addr is 0 (LSU is aligned, or burst coal used in read cache), no adder is needed so one pipeline stage is removed
    parameter int EXTRA_WRITE_LATENCY,          //to prevent avm_write from deasserting partway through a burst, ensure burst coalescer finishes with a memory word no sooner than the data aligner

    //parameters that are the same as dla_hld_lsu.sv
    parameter bit ASYNC_RESET,                  //0 = registers consume reset synchronously, 1 = registers consume reset asynchronously
    parameter int WORD_ADDR_WIDTH,              //how many most significant bits of the byte address represent which memory word is being accessed
    parameter int BURSTCOUNT_WIDTH,             //width of avalon burst count signal, max burst size is 2**(BURSTCOUNT_WIDTH-1)
    parameter bit ENABLE_BURST_COALESCE,        //whether to coalesce sequential memory words together to make a burst, feature will be disabled (parameter value ignored) if width adaption on the memory interface is used
    parameter int MLAB_FIFO_DEPTH,              //use a shallow fifo if handshaking is expected to take a few clocks (or if capacity can be borrowed from a nearby deep fifo), if we need an MLAB may as well use all of it
    parameter int M20K_WIDE_FIFO_DEPTH,         //use a deep fifo if handshaking is expected to take hundreds of clocks e.g. going off chip, for wide data path use M20K in shallowest mode, but may as well use all depth available
    parameter int M20K_NARROW_FIFO_DEPTH,       //if we need a deep fifo but the data path is narrow e.g. up to 10 bits which is the narrowest M20K on S10, can get additional depth for without needing more M20K
    parameter int BURST_COAL_MAX_TIMEOUT_BIT,   //limit how large the dynamic timeout threshold can get inside burst coalescer
    parameter bit USE_AXI,                      //0 = use AvalonMM, 1 = use AXI, this affects how the burstcount is constructed
    parameter int ADDR_ADAPT_WIDTH              //if width adaption is done on the global memory interface, how many word address LSBs are needed in AXI write data channel to indicate how to width adapt
) (
    input  wire                         clock,
    input  wire                         resetn,

    //input to burst coalescing
    input  wire                         i_valid,                        //one memory word has been released from the unaligned controller, this will eventually result in one word on avm
    input  wire   [WORD_ADDR_WIDTH-1:0] i_base_addr,                    //the input word address to burst coal is i_base_addr + i_add_to_base_addr, where i_base_addr is the first memory word that a kernel word touches
    input  wire                   [1:0] i_add_to_base_addr,             //if a kernel word spans several memory words, need to adjust which word address it is targeting
    output logic                        o_almost_full,                  //the fifo inside this module that immediately follows the burst coalescing logic is getting full
    output logic                        o_disable_coalescer_timeout,    //ignore the coalescer timeout if avm_ctrl_fifo is far away from being empty

    //writeack needs to know how many words were in a burst, snoop on what is written into avm_ctrl_fifo
    output logic                        o_burstcoal_snoop_valid,
    output logic [BURSTCOUNT_WIDTH-1:0] o_burstcoal_snoop_burstsize,

    //axi last fifo
    output logic   [ADDR_ADAPT_WIDTH:0] o_axi_last_fifo_rd_data,        //MSBs = some bits of address for width adaptation, LSB = axi last which indicates this word is the last in a burst
    input  wire                         i_axi_last_fifo_rd_ack,
    output logic                        o_axi_last_fifo_empty,

    //avm request interface -- avm_ctrl_fifo contains avm_address and o_avm_burstcount, can't hook up avalon to here since writedata and byteenable are managed separately, only assert avm_write once all are available
    output logic                        o_avm_ctrl_fifo_empty,          //fifo is empty
    input  wire                         i_avm_ctrl_fifo_rd_ack,         //read from fifo
    output logic  [WORD_ADDR_WIDTH-1:0] o_avm_word_address,             //still need to convert from this word address to avm_address which is a byte address
    output logic [BURSTCOUNT_WIDTH-1:0] o_avm_burstcount                //this is the actual o_avm_burstcount signal to goes to the memory interface
);


    //a tessellated adder is used to calculate the word address for burst coal, this specifies the index where the adder carry-chain is cut for a pipeline stage
    //ideally this is done in the middle of the adder, but the logic is easier if the upper bits should be the same for coalescing to happen (crossing a burst boundary is not allowed)
    //BURSTCOUNT_WIDTH specifies where the burst boundary is, by chossing the tessellation index to be at or above this, the upper bits must be constant for all words in a burst
    localparam int TESS_INDEX = ((WORD_ADDR_WIDTH/2) < BURSTCOUNT_WIDTH) ? BURSTCOUNT_WIDTH : (WORD_ADDR_WIDTH/2);

    //UPSTREAM_STALL_LATENCY is the latency from o_almost_full to i_valid, and then there are up to four pipeline stages:
    //i_valid -> input_valid -> late_captured_done_with_word -> coal_done_with_word -> repeat_fifo_wr_req
    //need to catch one more thing in case of timeout happens after almost full has asserted and stays asserted
    localparam int REPEAT_FIFO_ALMOST_FULL_CUTOFF = UPSTREAM_STALL_LATENCY + 5;

    //if burst coalescing is not enabled, still need 2 clocks to add to base address before writing into fifo
    //if using burst coalescing for writes, need a repeater and there is a zero cycle handshake between the repeater circuit and avm_ctrl_fifo
    //if using burst coalescing for reads, there is no repeater and the result of burst coalescing goes straight to avm_ctrl_fifo
    localparam int AVM_CTRL_FIFO_ALMOST_FULL_CUTOFF = (!ENABLE_BURST_COALESCE) ? (UPSTREAM_STALL_LATENCY+2) : (USE_REPEATER) ? 0 : REPEAT_FIFO_ALMOST_FULL_CUTOFF;



    ///////////////
    //  Signals  //
    ///////////////

    //reset
    logic aclrn, sclrn, resetn_synchronized;

    //adder
    logic input_valid;
    logic [TESS_INDEX:0] input_addr_lo;
    logic [TESS_INDEX-1:0] late_input_addr_lo;
    logic [WORD_ADDR_WIDTH-1:TESS_INDEX] input_base_addr_hi;
    logic [WORD_ADDR_WIDTH-1:TESS_INDEX] late_input_addr_hi;

    //avm_ctrl_fifo write side
    logic axi_last_fifo_wr_req;
    logic [ADDR_ADAPT_WIDTH:0] axi_last_fifo_wr_data;
    logic avm_ctrl_fifo_wr_req, avm_ctrl_fifo_almost_full;
    logic [WORD_ADDR_WIDTH-1:0] avm_ctrl_fifo_wr_addr;
    logic [BURSTCOUNT_WIDTH-1:0] avm_ctrl_fifo_wr_burstcount;



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
    //  Tessellated Adder  //
    /////////////////////////

    // compute i_base_addr + i_add_to_base_addr, which is the input address that the burst coalescer will use
    // The following naming convention is used:
    // - lo means this the bottom half of the tessellated add, hi means this is the top half of the tessellated add
    // - base_addr means this is the input to the module, addr means that i_add_to_base_addr has already been added
    // - late means it is one clock cycle after the corresponding non-late version

    //ADD_TO_ADDR_IS_ZERO indicates that i_add_to_base_addr is known to be zero, which is the case for an aligned lsu, and also for burstcoal inside cache
    //since we don't need to add, remove one pipeline stage
    generate
    if (ADD_TO_ADDR_IS_ZERO) begin : NO_ADDER
        assign input_valid = i_valid;
        assign input_addr_lo = i_base_addr[TESS_INDEX-1:0];
        assign input_base_addr_hi = i_base_addr[WORD_ADDR_WIDTH-1:TESS_INDEX];
        always_ff @(posedge clock) begin
            late_input_addr_lo <= input_addr_lo[TESS_INDEX-1:0];
            late_input_addr_hi <= input_base_addr_hi;
        end
    end
    else begin : GEN_ADDER
        always_ff @(posedge clock) begin
            input_valid <= i_valid;
            input_addr_lo <= i_base_addr[TESS_INDEX-1:0] + i_add_to_base_addr;
            input_base_addr_hi <= i_base_addr[WORD_ADDR_WIDTH-1:TESS_INDEX];
            late_input_addr_lo <= input_addr_lo[TESS_INDEX-1:0];
            late_input_addr_hi <= input_base_addr_hi + input_addr_lo[TESS_INDEX];
        end
    end
    endgenerate
    //note: input_valid in this module has the same meaning as i_valid in the word coalescer



    ////////////////////////////////////
    //  Burst Coalescer and Repeater  //
    ////////////////////////////////////

    //the output if the generate block below is the avm_ctrl_fifo write side signals

    generate
    if (!ENABLE_BURST_COALESCE) begin : NO_BURST_COAL
        if (ADD_TO_ADDR_IS_ZERO) begin : NO_ADDER   //no adder and no burst coalesce, this is becomes purely a pass through
            assign avm_ctrl_fifo_wr_req = i_valid;
            assign avm_ctrl_fifo_wr_addr = i_base_addr;
        end
        else begin : GEN_ADDER      //still need the tessellated adder even though there is no burst coalescer
            logic late_i_valid;
            always_ff @(posedge clock) begin
                late_i_valid <= i_valid;
                avm_ctrl_fifo_wr_req <= late_i_valid;
            end
            assign avm_ctrl_fifo_wr_addr = {late_input_addr_hi, late_input_addr_lo};
        end
        assign avm_ctrl_fifo_wr_burstcount = 'x;    //o_avm_burstcount will be set to a constant instead of being read from the fifo
        assign o_almost_full = avm_ctrl_fifo_almost_full;
        assign axi_last_fifo_wr_req = avm_ctrl_fifo_wr_req;
        assign axi_last_fifo_wr_data = {avm_ctrl_fifo_wr_addr, 1'b1};
    end
    else begin : GEN_BURST_COAL

        //capture the current word
        logic                           late_input_valid;       //delayed version of input_valid
        logic                           captured_valid;         //is what we captured valid, turns on when an incoming transaction arrives, turns off if we time out
        logic    [BURSTCOUNT_WIDTH-2:0] captured_next_addr_lo_inside_burst;         //capture what the next address should be within the burst if coalescing is going to happen
        logic                           captured_next_addr_in_same_burst;           //do not allow bursts to cross the burst boundary
        logic          [TESS_INDEX-1:0] captured_addr_lo, captured_next_addr_lo;    //bottom half of the captured address
        logic [WORD_ADDR_WIDTH-1:TESS_INDEX] late_captured_addr_hi;                 //top half of the captured address

        //timeout
        logic                           timeout;                //waited too long for the next word to arrive, going to release the captured address to downstream and report that it cannot coalesce

        //coalescer
        logic                           continue_in_same_burst_valid, late_continue_in_same_burst_valid;  //word N+1 has arrived, can coalesce if word N did not time out and did not cross burst boundary
        logic                           addr_match_lo, late_addr_match;                                   //captured address matches incoming address, comparison is split over 2 clocks since adder is tessellated
        logic                           coal_continue_in_same_burst;                                      //word N can coalesce with word N+1

        //keep the captured data live
        logic [TESS_INDEX-1:0] late_captured_addr_lo;
        logic late_captured_done_with_word;
        logic coal_done_with_word;
        logic [WORD_ADDR_WIDTH-1:0] coal_addr;


        //captured the current word, check for coalescing when the next word arrives
        always_ff @(posedge clock or negedge aclrn) begin
            if (~aclrn) captured_valid <= 1'b0;
            else begin
                if (input_valid) captured_valid <= 1'b1;
                else if (timeout) captured_valid <= 1'b0;
                if (~sclrn) captured_valid <= 1'b0;
            end
        end

        //addr and next_addr are the same for bits [WORD_ADDR_WIDTH-1:BURSTCOUNT_WIDTH-1]
        //addr and next_addr are different for bits [BURSTCOUNT_WIDTH-2:0], for these lower bits we have next_addr = addr+1
        //the split between hi and lo is defined by TESS_BITS, and TESS_BITS >= BURSTCOUNT_WIDTH, therefore for the hi range addr and next_addr are the same
        always_ff @(posedge clock) begin
            //one clock after input_valid
            if (input_valid) begin
                captured_next_addr_lo_inside_burst <= input_addr_lo[BURSTCOUNT_WIDTH-2:0] + 1'b1;
                captured_addr_lo <= input_addr_lo[TESS_INDEX-1:0];
                captured_next_addr_in_same_burst <= ~&input_addr_lo[BURSTCOUNT_WIDTH-2:0];  //cannot continue burst if at end of boundary, prevent case where next address is start of burst boundary
            end
            late_input_valid <= input_valid;

            //two clocks after input_valid
            if (late_input_valid) begin
                late_captured_addr_hi <= late_input_addr_hi;
            end
        end

        //one clock after input_valid
        assign captured_next_addr_lo = {captured_addr_lo[TESS_INDEX-1:BURSTCOUNT_WIDTH-1], captured_next_addr_lo_inside_burst};


        //coalescer -- assuming the previous word has been capturedd, check if the previous word can coalesce with the incoming word
        always_ff @(posedge clock) begin
            //one clock after input_valid
            continue_in_same_burst_valid <= input_valid & captured_valid & captured_next_addr_in_same_burst;    //word N+1 has arrived, can coalesce if word N did not time out and did not cross burst boundary
            addr_match_lo <= (input_addr_lo[TESS_INDEX-1:0] == captured_next_addr_lo[TESS_INDEX-1:0]);          //bottom half of the address check

            //two clocks after input_valid
            late_continue_in_same_burst_valid <= continue_in_same_burst_valid;
            late_addr_match <= (late_input_addr_hi[WORD_ADDR_WIDTH-1:TESS_INDEX] == late_captured_addr_hi[WORD_ADDR_WIDTH-1:TESS_INDEX]) & addr_match_lo;   //top half of the address check + result from bottom half
        end
        assign coal_continue_in_same_burst = late_addr_match & late_continue_in_same_burst_valid;   //word N can coalesce with word N+1


        //timeout
        dla_hld_lsu_coalescer_dynamic_timeout #(
            .ASYNC_RESET            (ASYNC_RESET),
            .MAX_TIMEOUT_BIT        (BURST_COAL_MAX_TIMEOUT_BIT)
        )
        dla_hld_lsu_coalescer_dynamic_timeout_inst
        (
            .clock                  (clock),
            .resetn                 (resetn),
            .i_valid                (input_valid),
            .i_disable_timeout      (o_disable_coalescer_timeout),
            .o_timeout              (timeout),
            .i_coal_if_addr_match   (captured_valid & captured_next_addr_in_same_burst),
            .i_late_addr_match      (late_addr_match)
        );


        //keep the captured data live
        always_ff @(posedge clock) begin
            //one clock after captured_valid
            late_captured_done_with_word <= timeout | (input_valid & captured_valid);   //done with word N if it timed-out or the word N+1 shows up
            late_captured_addr_lo <= captured_addr_lo;

            //two clocks after captured_valid
            coal_done_with_word <= late_captured_done_with_word;
            coal_addr <= {late_captured_addr_hi, late_captured_addr_lo};
        end


        //build up the burst, increment burstcount for every successful coalesce, flush the burst (write to the repeat fifo) upon timeout, address is not the next sequential address, or reached burst boundary
        logic                           add_one_to_burstcount;              //successful coalesce means increase size of the burst
        logic                           done_burst_load_addr_next_time;     //when to capture the first address of each burst
        logic                           repeat_fifo_wr_req;                 //flush the burst
        logic     [WORD_ADDR_WIDTH-1:0] repeat_fifo_wr_addr;                //capture the first address of each burst, as this is what is held on avalon address as the write burst goes out over several clocks
        logic    [BURSTCOUNT_WIDTH-1:0] repeat_fifo_wr_burstcount;          //this is the burst count, the size of the burst
        logic                           repeat_fifo_wr_burstcount_eq_one;   //manually retimed logic across the repeat fifo to reduce combinational logic on repeat_fifo_rd_ack, repeater circuit needs to check burstcount == 1

        always_ff @(posedge clock or negedge aclrn) begin
            if (~aclrn) begin
                add_one_to_burstcount <= 1'b0;
                done_burst_load_addr_next_time <= 1'b1;
                repeat_fifo_wr_req <= 1'b0;
                repeat_fifo_wr_addr <= '0;  //not needed by not expected to cost extra logic on fpga
                repeat_fifo_wr_burstcount <= (USE_AXI) ? 'h0 : 'h1; //axi burst length is one less than avalon
                repeat_fifo_wr_burstcount_eq_one <= 1'b1;
            end
            else begin
                //write to the fifo when the burst is done, otherwise the burst is not done so increment burst count
                repeat_fifo_wr_req <= coal_done_with_word & ~coal_continue_in_same_burst;
                add_one_to_burstcount <= coal_done_with_word & coal_continue_in_same_burst;

                //if we wrote to fifo the burst is done, capture the address of the next word that arrives since that will be the start of a new burst
                //done_burst_load_addr_next_time must reset to 1 to ensure we capture the very first address
                if (coal_done_with_word) done_burst_load_addr_next_time <= ~coal_continue_in_same_burst;
                if (coal_done_with_word & done_burst_load_addr_next_time) repeat_fifo_wr_addr <= coal_addr;

                //update burstcount for the next word
                //if repeat_fifo_wr_req = 1 on clock cycle N, these values update as of clock cycle N+1, so the old values on clock cycle N are written into the fifo
                if (repeat_fifo_wr_req) begin
                    repeat_fifo_wr_burstcount <= (USE_AXI) ? 'h0 : 'h1;
                    repeat_fifo_wr_burstcount_eq_one <= 1'b1;
                end
                if (add_one_to_burstcount) begin
                    repeat_fifo_wr_burstcount <= repeat_fifo_wr_burstcount + 1'b1;
                    repeat_fifo_wr_burstcount_eq_one <= 1'b0;
                end

                if (~sclrn) begin
                    add_one_to_burstcount <= 1'b0;
                    done_burst_load_addr_next_time <= 1'b1;
                    repeat_fifo_wr_req <= 1'b0;
                    //repeat_fifo_wr_addr <= '0; //this is not needed
                    repeat_fifo_wr_burstcount <= (USE_AXI) ? 'h0 : 'h1;
                    repeat_fifo_wr_burstcount_eq_one <= 1'b1;
                end
            end
        end


        if (!USE_REPEATER) begin : NO_REPEATER  //read LSU does not need a repeater, bypass the repeat fifo and instead write the contents to the avm_ctrl_fifo
            assign avm_ctrl_fifo_wr_req = repeat_fifo_wr_req;
            assign avm_ctrl_fifo_wr_addr = repeat_fifo_wr_addr;
            assign avm_ctrl_fifo_wr_burstcount = repeat_fifo_wr_burstcount;
            assign o_almost_full = avm_ctrl_fifo_almost_full;
        end
        else begin : GEN_REPEATER
            //read side of the repeat fifo
            logic                           repeat_fifo_empty_raw, repeat_fifo_empty, repeat_fifo_rd_ack, repeat_burst_is_last;
            logic     [WORD_ADDR_WIDTH-1:0] repeat_fifo_rd_addr;
            logic    [BURSTCOUNT_WIDTH-1:0] repeat_fifo_rd_burstcount;
            logic                           repeat_fifo_burstcount_eq_one;

            //repeater
            logic inside_a_burst, first_in_current_burst;
            logic [BURSTCOUNT_WIDTH-1:0] remaining_burst;
            logic remaining_burst_eq_two;

            ///////////////////
            //  Repeat FIFO  //
            ///////////////////

            // one write into this fifo corresponds to one burst, after this fifo is repeat logic which copies 1 entry in this fifo into N entries where N is the burst count
            // the reason this fifo is needed is the burst coalescers may have released a big burst, and before the N copies can be written into the repeat fifo, the burst coalescer finishes another burst

            dla_hld_fifo #(
                .WIDTH              (1 + BURSTCOUNT_WIDTH + WORD_ADDR_WIDTH),
                .DEPTH              (MLAB_FIFO_DEPTH),
                .NEVER_OVERFLOWS    (1),
                .ALMOST_FULL_CUTOFF (REPEAT_FIFO_ALMOST_FULL_CUTOFF),
                .ASYNC_RESET        (ASYNC_RESET),
                .SYNCHRONIZE_RESET  (0),
                .STYLE              ("ms")
            )
            repeat_fifo_inst
            (
                .clock              (clock),
                .resetn             (resetn_synchronized),
                .i_valid            (repeat_fifo_wr_req),
                .i_data             ({repeat_fifo_wr_burstcount_eq_one, repeat_fifo_wr_burstcount, repeat_fifo_wr_addr}),
                .o_stall            (),
                .o_almost_full      (o_almost_full),
                .o_valid            (),
                .o_data             ({repeat_fifo_burstcount_eq_one, repeat_fifo_rd_burstcount, repeat_fifo_rd_addr}),
                .i_stall            (~repeat_fifo_rd_ack),
                .o_almost_empty     (),
                .o_empty            (repeat_fifo_empty_raw),
                .ecc_err_status     ()
            );

            //to prevent avm_write from deasserting partway through a burst, ensure burst coalescer finishes with a memory word no sooner than the data aligner
            //normally the latency through the burst coalescer is longer than the write data alignment, so it would be sufficient to release a memory word to the burst coalescer upon the last access to that memory word
            //in case the write data alignment has a longer latency, add some latency here by masking the empty signal for the repeat fifo
            if (EXTRA_WRITE_LATENCY) begin : GEN_EXTRA_WRITE_LATENCY
                logic repeat_fifo_not_empty;
                logic repeat_fifo_wr_req_delayed;

                //normally the increment for the fifo empty signal is the fifo write request delayed by WRITE_TO_READ_LATENCY-1 clocks (since the occ tracker has latency 1), this value is 2 since mid speed fifo has latency 3
                //then we need to add some more latency to ensure the burst coalescer finishes with a memory word no sooner than the data aligner
                dla_acl_shift_register_no_reset #(
                    .WIDTH  (1),
                    .STAGES (EXTRA_WRITE_LATENCY+2)
                )
                repeat_fifo_extra_latency_inst
                (
                    .clock  (clock),
                    .D      (repeat_fifo_wr_req),
                    .Q      (repeat_fifo_wr_req_delayed)
                );

                dla_acl_tessellated_incr_decr_threshold #(
                    .CAPACITY                   (MLAB_FIFO_DEPTH),
                    .THRESHOLD                  (1),
                    .INITIAL_OCCUPANCY          (0),
                    .THRESHOLD_REACHED_AT_RESET (0),
                    .ASYNC_RESET                (ASYNC_RESET),
                    .SYNCHRONIZE_RESET          (0)
                )
                repeat_fifo_empty_inst
                (
                    .clock                      (clock),
                    .resetn                     (resetn_synchronized),
                    .incr_no_overflow           (repeat_fifo_wr_req_delayed),
                    .incr_raw                   (repeat_fifo_wr_req_delayed),
                    .decr_no_underflow          (repeat_fifo_rd_ack),
                    .decr_raw                   (repeat_fifo_rd_ack),
                    .threshold_reached          (repeat_fifo_not_empty)
                );
                assign repeat_fifo_empty = ~repeat_fifo_not_empty;
            end
            else begin : NO_EXTRA_WRITE_LATENCY
                assign repeat_fifo_empty = repeat_fifo_empty_raw;
            end



            ////////////////
            //  Repeater  //
            ////////////////

            //to simplify the handshake at the avm interface, one burst of length B which is one word inside repeat_fifo is converted into B words inside avm_ctrl_fifo
            //this way each read from avm_wr_data_fifo corresponds to one read from avm_ctrl_fifo

            assign repeat_burst_is_last = (inside_a_burst) ? remaining_burst_eq_two : repeat_fifo_burstcount_eq_one;
            assign repeat_fifo_rd_ack = ~repeat_fifo_empty & ~avm_ctrl_fifo_almost_full & repeat_burst_is_last;

            always_ff @(posedge clock or negedge aclrn) begin
                if (~aclrn) begin
                    inside_a_burst <= 1'b0; //track whether we are inside a burst, this is stateful logic so to get inside a burst it needs to be at least length 2
                    first_in_current_burst <= 1'b1;
                end
                else begin
                    if (~repeat_fifo_empty & ~avm_ctrl_fifo_almost_full) begin
                        if (~inside_a_burst) begin
                            if (~repeat_fifo_burstcount_eq_one) inside_a_burst <= 1'b1;
                        end
                        else begin
                            if (remaining_burst_eq_two) inside_a_burst <= 1'b0;
                        end
                        first_in_current_burst <= repeat_burst_is_last;
                    end
                    if (~sclrn) begin
                        inside_a_burst <= 1'b0;
                        first_in_current_burst <= 1'b1;
                    end
                end
            end

            always_ff @(posedge clock) begin
                if (~repeat_fifo_empty & ~avm_ctrl_fifo_almost_full) begin
                    if (~inside_a_burst) begin
                        remaining_burst <= repeat_fifo_rd_burstcount;
                        remaining_burst_eq_two <= (USE_AXI) ? (repeat_fifo_rd_burstcount == 1) : (repeat_fifo_rd_burstcount == 2);  //axi burst length is one less than avalon
                    end
                    else begin
                        remaining_burst <= remaining_burst - 1'b1;
                        remaining_burst_eq_two <= (USE_AXI) ? (remaining_burst == 2) : (remaining_burst == 3);      //axi burst length is one less than avalon
                    end
                end
            end

            //same clock cycle handshaking is used to write to avm_ctrl_fifo and to update the repeater circuit (which will read repeat_fifo on the same clock cycle if at the end of a burst)
            assign avm_ctrl_fifo_wr_req = ~repeat_fifo_empty & ~avm_ctrl_fifo_almost_full & ((USE_AXI) ? first_in_current_burst : 1'b1);
            assign avm_ctrl_fifo_wr_addr = repeat_fifo_rd_addr;
            assign avm_ctrl_fifo_wr_burstcount = repeat_fifo_rd_burstcount;

            //axi last fifo
            assign axi_last_fifo_wr_req = ~repeat_fifo_empty & ~avm_ctrl_fifo_almost_full;
            assign axi_last_fifo_wr_data = {repeat_fifo_rd_addr, repeat_burst_is_last};

            //snoop for writeack
            assign o_burstcoal_snoop_valid = avm_ctrl_fifo_wr_req;
            assign o_burstcoal_snoop_burstsize = avm_ctrl_fifo_wr_burstcount;
        end
    end
    endgenerate



    /////////////////////
    //  Avm Ctrl FIFO  //
    /////////////////////

    generate
    if (NO_AVM_WAITREQUEST) begin : NO_AVM_CTRL_FIFO
        assign o_avm_ctrl_fifo_empty = ~avm_ctrl_fifo_wr_req; //empty from burstcoal means read cache must accept it
        assign o_avm_word_address = avm_ctrl_fifo_wr_addr;
        assign o_avm_burstcount = (USE_AXI) ? 0 : 1;  //burstcoal inside lsu should be disabled, cache has its own burstcoal before releasing to avm transactions to global mem interconnect
        //i_avm_ctrl_fifo_rd_ack is ignored
        assign avm_ctrl_fifo_almost_full = 1'b0;    //never need to backpressure cmd fifo read side state machine, cache will always have space to accept transactions
        assign o_disable_coalescer_timeout = 1'b0;
    end
    else begin : GEN_AVM_CTRL_FIFO
        logic [BURSTCOUNT_WIDTH-1:0] avm_burstcount_raw;
        logic avm_ctrl_fifo_almost_full_raw, axi_last_fifo_almost_full;
        assign avm_ctrl_fifo_almost_full = avm_ctrl_fifo_almost_full_raw | axi_last_fifo_almost_full;

        //AXI write data channel
        //- data and byte enable come from the write data aligner
        //- last signal depends on the number of words in the burst and therefore has to come from the burst coalescer
        //- control flow: dla_hld_lsu waits until both the write data aligner and burst coalescer last fifo have stuff before asserting valid on the axi write data channel

        //when do we need the axi last signal?
        //- obviously need to be using AXI instead of Avalon
        //- write LSU has USE_REPEATER = 1
        //- don't need axi last if burst coalescer is disabled
        //- if width adaption is done on the global memory interface, need the lower bits of the address to be present in every word of data to indicate how to width adapt (that was the case for Avalon, not so for AXI)
        if (USE_AXI && USE_REPEATER && (ENABLE_BURST_COALESCE || ADDR_ADAPT_WIDTH)) begin
            dla_hld_fifo #(
                .WIDTH              (ADDR_ADAPT_WIDTH + 1),
                .DEPTH              (M20K_NARROW_FIFO_DEPTH),
                .NEVER_OVERFLOWS    (1),
                .ALMOST_FULL_CUTOFF (AVM_CTRL_FIFO_ALMOST_FULL_CUTOFF),
                .ASYNC_RESET        (ASYNC_RESET),
                .SYNCHRONIZE_RESET  (0),
                .STYLE              ("ms")
            )
            axi_last_fifo_inst
            (
                .clock              (clock),
                .resetn             (resetn_synchronized),
                .i_valid            (axi_last_fifo_wr_req),
                .i_data             (axi_last_fifo_wr_data),
                .o_stall            (),
                .o_almost_full      (axi_last_fifo_almost_full),
                .o_valid            (),
                .o_data             (o_axi_last_fifo_rd_data),
                .i_stall            (~i_axi_last_fifo_rd_ack),
                .o_almost_empty     (),
                .o_empty            (o_axi_last_fifo_empty),
                .ecc_err_status     ()
            );
        end
        else begin
            assign axi_last_fifo_almost_full = 1'b0;
            assign o_axi_last_fifo_rd_data = 'h1;
            assign o_axi_last_fifo_empty = 1'b0;
        end

        dla_hld_fifo #(
            .WIDTH              (BURSTCOUNT_WIDTH + WORD_ADDR_WIDTH),
            .DEPTH              (M20K_WIDE_FIFO_DEPTH),
            .NEVER_OVERFLOWS    (1),
            .ALMOST_FULL_CUTOFF (AVM_CTRL_FIFO_ALMOST_FULL_CUTOFF),
            .ASYNC_RESET        (ASYNC_RESET),
            .SYNCHRONIZE_RESET  (0),
            .STYLE              ("ms")
        )
        avm_ctrl_fifo_inst
        (
            .clock              (clock),
            .resetn             (resetn_synchronized),
            .i_valid            (avm_ctrl_fifo_wr_req),
            .i_data             ({avm_ctrl_fifo_wr_burstcount, avm_ctrl_fifo_wr_addr}),
            .o_stall            (),
            .o_almost_full      (avm_ctrl_fifo_almost_full_raw),
            .o_valid            (),
            .o_data             ({avm_burstcount_raw, o_avm_word_address}),
            .i_stall            (~i_avm_ctrl_fifo_rd_ack),
            .o_almost_empty     (),
            .o_empty            (o_avm_ctrl_fifo_empty),
            .ecc_err_status     ()
        );
        assign o_avm_burstcount = (ENABLE_BURST_COALESCE) ? avm_burstcount_raw : (USE_AXI) ? 0 : 1;


        //if downstream of the coalescers is sufficiently far away from being empty e.g. lots of avm requests have been queued, then don't let the coalescers time out

        //M20K_WIDE_FIFO_DEPTH is typically 512, so avm_ctrl_fifo_occ is 9 bits, this means we can't tell occupancy 0 and 512 apart
        //the somewhat full signal is used to disable the timeout on the coalecers, both word coalesing and burst coalescing, this happens when the occ reaches 256 or higher
        //in the rare case that the avm ctrl fifo is able to completely fill to 512 items, avm_ctrl_fifo_occ will look like 0 so it won't disable the coalescer timeouts
        //but this doesn't matter since the fifo is full and therefore no forward progress can be made anyways
        //somewhat full operates on occupancy that is two clocks stale, but this is just a loose guideline for being full enough that we can disable the coalescer timeouts
        localparam int AVM_CTRL_FIFO_OCC_BITS = $clog2(M20K_WIDE_FIFO_DEPTH);
        localparam int BURSTCOAL_SOMEWHAT_FULL_THRESHOLD = M20K_WIDE_FIFO_DEPTH / 2;    //make this divisible by a large power of 2 to minimize logic

        logic                         [1:0] avm_ctrl_fifo_occ_update;       //can take values +1, 0, or -1
        logic  [AVM_CTRL_FIFO_OCC_BITS-1:0] avm_ctrl_fifo_occ_update_ext;   //sign extend the update
        logic  [AVM_CTRL_FIFO_OCC_BITS-1:0] avm_ctrl_fifo_occ;              //track the occupancy with a binary counter, no tessellation

        always_ff @(posedge clock) begin
            //increment (2'h1 means +1) if only avm_ctrl_fifo_wr_req, decrement (2'h3 means -1) if only i_avm_ctrl_fifo_rd_ack, no update (2'h0) if both or neither
            avm_ctrl_fifo_occ_update <= (avm_ctrl_fifo_wr_req & ~i_avm_ctrl_fifo_rd_ack) ? 2'h1 : (~avm_ctrl_fifo_wr_req & i_avm_ctrl_fifo_rd_ack) ? 2'h3 : 2'h0;
        end

        assign avm_ctrl_fifo_occ_update_ext = { {(AVM_CTRL_FIFO_OCC_BITS-1){avm_ctrl_fifo_occ_update[1]}}, avm_ctrl_fifo_occ_update[0] }; //sign extend

        always_ff @(posedge clock or negedge aclrn) begin
            if (~aclrn) avm_ctrl_fifo_occ <= '0;
            else begin
                avm_ctrl_fifo_occ <= avm_ctrl_fifo_occ + avm_ctrl_fifo_occ_update_ext;  //occupancy of avm_ctrl_fifo that is late by one clock cycle
                if (~sclrn) avm_ctrl_fifo_occ <= '0;
            end
        end

        always_ff @(posedge clock) begin
            o_disable_coalescer_timeout <= avm_ctrl_fifo_occ >= BURSTCOAL_SOMEWHAT_FULL_THRESHOLD;
        end
    end
    endgenerate

endmodule

`default_nettype wire
