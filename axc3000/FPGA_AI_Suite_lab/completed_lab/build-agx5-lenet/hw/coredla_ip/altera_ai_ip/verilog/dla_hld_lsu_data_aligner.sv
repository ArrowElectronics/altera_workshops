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

// This module is used to align kernel write data to the memory interface, and align memory read data to the kernel interface. Typically a barrel shifter is
// used to rotate i_data (the input data) by the amount specified by i_shift. One may choose whether to shift left or right, as well as whether the shift should
// be a wrap-around or linear. The input data is aligned by perserving the input data width. Once alignment is finished, the aligned data is replicated as many
// times as necessary to cover the width of the output data.
//
// For example, suppose a write LSU has kernel width = 4 and memory width = 64. There are 4 possible rotations of the kernel write data. After replicating the
// aligned data 16 times to widen it to the memory width, we can now enable any byte of the memory interface to source from any byte of the kernel write data.
// Byteenables would need to mask off everything but the 4 bytes we want to write, but that is a separate problem handled outside of the data aligner.
//
// The total latency through the data aligner can be chosen (0 is allowed), and pipeline registers are spaced equally among all of the 2:1 muxes that make up
// the shifter. If there is a pipeline stage every third 2:1 mux, this is equivalent to pipelining between every 8:1 mux.
//
// As future work, may want to support an 8:1 mux with latency 2 being decomposed as two stages of 3:1 mux, currently this decomposes into 4:1 followed by 2:1.
//
// For additional info, refer to dla_hld_global_load_store.sv (top module of entire LSU) and dla_hld_lsu.sv (top module of the core LSU).

`default_nettype none

module dla_hld_lsu_data_aligner #(
    parameter int LATENCY,          //number of clock cycles from i_data to o_data, value must be 0 or larger
    parameter bit DIRECTION,        //0 = shift right, 1 = shift left
    parameter int SECTION_WIDTH,    //how many bits of data are shifted together, for a completely unaligned LSU use 8 for data and 1 for byteenable
    parameter bit WRAP_AROUND,      //0 = linear shift, 1 = shift with wrap-around
    parameter int I_DATA_WIDTH,     //bit width of the i_data signal
    parameter int I_SHIFT_WIDTH,    //bit width of the i_shift signal
    parameter int O_DATA_WIDTH      //bit width of the o_data signal
) (
    input  wire                      clock,
    input  wire   [I_DATA_WIDTH-1:0] i_data,    //input data
    input  wire  [I_SHIFT_WIDTH-1:0] i_shift,   //how much to shift the input data
    output logic  [O_DATA_WIDTH-1:0] o_data     //output data, for write lsu this is a kernel upstream word aligned for memory, for read lsu this is memory word aligned for kernel downstream
);
    
    localparam int WIDTH_RATIO = (O_DATA_WIDTH+I_DATA_WIDTH-1) / I_DATA_WIDTH;   //ceiling( output width / input width ), how many times we need to replicate input data to cover all bits of output data
    
    genvar g;
    logic             [I_DATA_WIDTH-1:0] aligned_data;          //output data from barrel shifter
    logic [WIDTH_RATIO*I_DATA_WIDTH-1:0] aligned_data_expanded; //replicated version of aligned_data to cover all bits of o_data
    
    generate
    if (I_SHIFT_WIDTH == 0) begin : NO_ALIGN  //no muxing, but still need latency
        dla_acl_shift_register_no_reset #(
            .WIDTH  (I_DATA_WIDTH),
            .STAGES (LATENCY)
        )
        delay_inst
        (
            .clock  (clock),
            .D      (i_data),
            .Q      (aligned_data)
        );
    end
    else begin : GEN_ALIGN
        logic  [I_DATA_WIDTH-1:0] pipe_data  [I_SHIFT_WIDTH:0];
        logic [I_SHIFT_WIDTH-1:0] pipe_shift [I_SHIFT_WIDTH:0];
        
        always_comb begin
            pipe_data[I_SHIFT_WIDTH] = i_data;
            pipe_shift[I_SHIFT_WIDTH] = i_shift;
        end
        
        for (g=0; g<I_SHIFT_WIDTH; g++) begin : GEN_MUX
            localparam LATENCY_START_OF_STAGE = (I_SHIFT_WIDTH-1-g)*LATENCY / I_SHIFT_WIDTH;
            localparam LATENCY_END_OF_STAGE = (I_SHIFT_WIDTH-g)*LATENCY / I_SHIFT_WIDTH;
            localparam LATENCY_THIS_STAGE = LATENCY_END_OF_STAGE - LATENCY_START_OF_STAGE;
            
            //this is some statically determined permutation of pipe_data[g+1] since the number of wraparound shifts is the genvar
            logic [I_DATA_WIDTH-1:0] shifted_data;
            if (WRAP_AROUND) begin : GEN_WRAP_AROUND_SHIFT
                if (DIRECTION) begin : SHIFT_LEFT
                    always_comb begin
                        shifted_data = pipe_data[g+1];
                        for (int i=0; i<(1<<g); i++) begin
                            shifted_data = {shifted_data[SECTION_WIDTH-1:0], shifted_data[I_DATA_WIDTH-1:SECTION_WIDTH]};
                        end
                    end
                end
                else begin : SHIFT_RIGHT
                    always_comb begin
                        shifted_data = pipe_data[g+1];
                        for (int i=0; i<(1<<g); i++) begin
                            shifted_data = {shifted_data[I_DATA_WIDTH-SECTION_WIDTH-1:0], shifted_data[I_DATA_WIDTH-1:I_DATA_WIDTH-SECTION_WIDTH]};
                        end
                    end
                end
            end
            else begin : GEN_LINEAR_SHIFT
                if (DIRECTION) begin : SHIFT_LEFT
                    assign shifted_data = pipe_data[g+1] >> (SECTION_WIDTH*(1<<g));
                end
                else begin : SHIFT_RIGHT
                    assign shifted_data = pipe_data[g+1] << (SECTION_WIDTH*(1<<g));
                end
            end
            
            //the actual mux itself, although this is coded as a 2:1 mux, it is possible some stages have no pipelining in which case there would be a N:1 mux between registers where N >= 4
            logic [I_DATA_WIDTH-1:0] muxed_data;
            assign muxed_data = pipe_shift[g+1][g] ? shifted_data : pipe_data[g+1];
            
            //add pipelining before next mux stage, latency 0 means passthrough
            dla_acl_shift_register_no_reset #(
                .WIDTH  (I_SHIFT_WIDTH + I_DATA_WIDTH),
                .STAGES (LATENCY_THIS_STAGE)
            )
            delay_inst
            (
                .clock  (clock),
                .D      ({pipe_shift[g+1], muxed_data}),
                .Q      ({pipe_shift[g], pipe_data[g]})
            );
        end
        
        assign aligned_data = pipe_data[0];
    end
    endgenerate
    
    assign aligned_data_expanded = {WIDTH_RATIO{aligned_data}};
    assign o_data = aligned_data_expanded[O_DATA_WIDTH-1:0];
    
endmodule

`default_nettype wire
