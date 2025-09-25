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

/*
   This module pipelines each input signal and replicates the pipeline by the specified amounts.
   The copies of the pipelines are typically used to break up the fanout of the input signals.
   One common use-case for this block is to pipeline and fanout a synchronous reset, for performance.
*/

module dla_acl_fanout_pipeline #(
   parameter   PIPE_DEPTH = 1,   // The number of pipeline stages. A value of 0 is valid and means the input will be passed straight to the output.
   parameter   NUM_COPIES = 1 ,  // The number of copies of the pipeline. Minimum value 1.
   parameter   WIDTH = 1         // The width of the input and output bus (ie. the number of unique inputs to fanout and pipeline). Minimum value 1.
)(
   input wire     clk,
   input wire     [WIDTH-1:0] in,
   output logic   [NUM_COPIES-1:0][WIDTH-1:0] out
);

   logic [WIDTH-1:0] pipe [NUM_COPIES][PIPE_DEPTH:1] /* synthesis dont_merge */;

   genvar j;
   generate
      if (PIPE_DEPTH == 0) begin
         for (j=0;j<NUM_COPIES;j++) begin : GEN_OUTPUT_ASSIGNMENT_PIPE_DEPTH_0
            assign out[j] = in;  // Pass the input straight through
         end
      end else begin
         always @(posedge clk) begin
            for (int k=0;k<NUM_COPIES;k++) begin      // For each copy
               pipe[k][1] <= in;                      // Assign the input to Stage-1 of the pipe
               for (int i=2;i<=PIPE_DEPTH;i++) begin  // Implement the rest of the pipe
                  pipe[k][i] <= pipe[k][i-1];
               end
            end
         end

         for (j=0;j<NUM_COPIES;j++) begin : GEN_OUTPUT_ASSIGNMENT_PIPE_DEPTH_GREATER_THAN_0 // For each copy, assign the pipe output to the output of this module
            assign out[j] = pipe[j][PIPE_DEPTH];
         end
      end
   endgenerate

endmodule
