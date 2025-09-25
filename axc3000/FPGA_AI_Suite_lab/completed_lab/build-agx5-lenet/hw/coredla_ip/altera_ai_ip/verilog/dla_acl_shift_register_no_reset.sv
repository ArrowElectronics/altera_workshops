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

`default_nettype none

module dla_acl_shift_register_no_reset #(
    parameter int unsigned WIDTH,
    parameter int unsigned STAGES
) (
    input  wire              clock,
    input  wire  [WIDTH-1:0] D,
    output logic [WIDTH-1:0] Q
);
    genvar g;
    generate
    if (STAGES == 0) begin : NO_STAGES
        assign Q = D;
    end
    else begin : GEN_STAGES
        logic [WIDTH-1:0] pipe [STAGES-1:0];
        always_ff @(posedge clock) begin
            pipe[0] <= D;
        end
        for (g=1; g<STAGES; g++) begin : GEN_PIPE
            always_ff @(posedge clock) begin
                pipe[g] <= pipe[g-1];
            end
        end
        assign Q = pipe[STAGES-1];
    end
    endgenerate
    
endmodule

`default_nettype wire
