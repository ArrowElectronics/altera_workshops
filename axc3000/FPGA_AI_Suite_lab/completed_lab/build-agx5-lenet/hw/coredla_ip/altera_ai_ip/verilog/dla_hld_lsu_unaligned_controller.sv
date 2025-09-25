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

// This module tracks the processing of each kernel word as it spans multiple memory words. Up to 3 memory words per kernel word is supported, however if it
// is statically known that kernel words can only span fewer memory words then some logic can be trimmed away.
//
// This is the central controller which reads from the cmd fifo (output of word coalescer) and steers all of the pipelined logic from reading the input fifos
// to aligning the kernel write data to the memory interface. The burst coalescer is also controlled by this.
//
// The read LSU has a second instance of this unaligned controller for the response data. This instance steers all of the pipelined logic from reading the 
// avm_rd_data_fifo to aligning the memory read data to the kernel interface.
//
// For additional info, refer to dla_hld_global_load_store.sv (top module of entire LSU) and dla_hld_lsu.sv (top module of the core LSU).

`default_nettype none

module dla_hld_lsu_unaligned_controller #(
    parameter bit ASYNC_RESET,                  //0 = registers consume reset synchronously, 1 = registers consume reset asynchronously
    parameter int MAX_MEM_WORDS_PER_KER_WORD,   //trim some logic if it is guaranteed that each kernel word can only span 1 or 2 memory words
    parameter bit HIGH_THROUGHPUT_MODE          //0 = use N clock cycles to process a kernel word that spans N memory words, 1 = use minimum amount of time to process kernel words, only matters if N >= 2
) (
    input  wire         clock,
    input  wire         resetn,
    
    //handshaking
    input  wire         i_can_read_fifo,        //can move on to the next section of the kernel word if upstream has stuff and downstream has space
    output logic        o_fifo_rd_ack,          //done with all sections of the kernel word
    
    //information about the kernel word
    input  wire         i_spans_two,            //kernel word spans at least two memory words
    input  wire         i_spans_three,          //kernel word spans three memory words
    input  wire         i_needs_second_cycle,   //need at least two clock cycles to process kernel word
    input  wire         i_needs_third_cycle,    //need at least three clock cycles to process kernel word
    input  wire         i_can_coalesce,         //last section of kernel word is in the same memory word as the first section of next kernel word
    
    //state of processing within kernel word
    output logic        o_at_second_cycle,      //in the second clock cycle of processing current kernel word
    output logic        o_at_third_cycle,       //in the third clock cycle of processing current kernel word
    output logic        o_is_coalescing,        //does the current section of the kernel word coalesce with the next section (next section could be same or next kernel word)
    output logic        o_first_access_in_word  //asserts when the first access to a memory word happens
);

    //reset
    logic aclrn, sclrn, resetn_synchronized;
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
    
    //read from the upstream fifo if done with all sections of the kernel word
    assign o_fifo_rd_ack = i_can_read_fifo & ((i_needs_third_cycle) ? o_at_third_cycle : (i_needs_second_cycle) ? o_at_second_cycle : 1'b1);
    
    generate
    if (MAX_MEM_WORDS_PER_KER_WORD == 3) begin : THREE_MEM_WORDS
        //this is the most general version of the state machine which can progress through up to 3 memory words for each kernel word
        always_ff @(posedge clock or negedge aclrn) begin
            if (~aclrn) begin
                o_at_second_cycle <= 1'b0;
                o_at_third_cycle <= 1'b0;
            end
            else begin
                if (i_can_read_fifo) begin
                    if (o_at_third_cycle) begin
                        o_at_third_cycle <= 1'b0;
                    end
                    else if (o_at_second_cycle) begin
                        o_at_second_cycle <= 1'b0;
                        o_at_third_cycle <= i_needs_third_cycle;
                    end
                    else begin
                        o_at_second_cycle <= i_needs_second_cycle;
                    end
                end
                if (~sclrn) begin
                    o_at_second_cycle <= 1'b0;
                    o_at_third_cycle <= 1'b0;
                end
            end
        end
    end
    else if (MAX_MEM_WORDS_PER_KER_WORD == 2) begin : TWO_MEM_WORDS
        //impossible to get into third section, but not sure if quartus will figure that out
        assign o_at_third_cycle = 1'b0;
        always_ff @(posedge clock or negedge aclrn) begin
            if (~aclrn) begin
                o_at_second_cycle <= 1'b0;
            end
            else begin
                if (i_can_read_fifo) begin
                    if (o_at_second_cycle) begin
                        o_at_second_cycle <= 1'b0;
                    end
                    else begin
                        o_at_second_cycle <= i_needs_second_cycle;
                    end
                end
                if (~sclrn) begin
                    o_at_second_cycle <= 1'b0;
                end
            end
        end
    end
    else begin : ONE_MEM_WORD   //MAX_MEM_WORDS_PER_KER_WORD == 1
        //impossible to get into second or third section, but not sure if quartus will figure that out
        assign o_at_second_cycle = 1'b0;
        assign o_at_third_cycle = 1'b0;
    end
    endgenerate
    
    //i_can_coalesce (from word coalescer) indicates if the last section of a kernel word coalesces with the first section of the next kernel word, where a section is contained within one memory word
    //if a kernel word spans two memory words, obviously we cannot coalesce while we are processing the first memory word of that kernel word
    //based on where we are in processing the kernel word, determine whether or not coalescing actually happens
    generate
    if (HIGH_THROUGHPUT_MODE) begin : IS_COALESCING_HIGH_THROUGHPUT
        always_comb begin
            o_is_coalescing = i_can_coalesce;
            if (i_spans_two) o_is_coalescing = 1'b0;    //either the last section did not coalesce, or when processing the next kernel word it will finish the current kernel word's last section
        end
    end
    else begin : IS_COALESCING_LOW_THROUGHPUT
        always_comb begin
            o_is_coalescing = i_can_coalesce;
            if (i_spans_two & !o_at_second_cycle) o_is_coalescing = 1'b0;   //i_can_coalesce is only valid if we are processing the last section of the kernel word
            if (i_spans_three & !o_at_third_cycle) o_is_coalescing = 1'b0;
        end
    end
    endgenerate
    
    //first access in a memory word happens when the previous word did not coalesce
    always_ff @(posedge clock or negedge aclrn) begin
        if (~aclrn) begin
            o_first_access_in_word <= 1'b1;
        end
        else begin
            if (i_can_read_fifo) o_first_access_in_word <= ~o_is_coalescing;
            if (~sclrn) o_first_access_in_word <= 1'b1;
        end
    end
    

endmodule

`default_nettype wire
