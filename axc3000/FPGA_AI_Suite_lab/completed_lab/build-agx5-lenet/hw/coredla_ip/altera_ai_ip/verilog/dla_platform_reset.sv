// Copyright 2020-2020 Altera Corporation.
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



// This is top level reset module that is responsible for ensuring reset is held for a long time
// on each clock domain. All resets from each clock domain (which typically come from PLL locked,
// DDR calibrated, or an external pin) are combined asynchronously. The idea is that if any reset
// is asserted, everything goes into reset. After including all reset sources, for each clock domain
// this all-inclusive reset is synchronized to that clock domain and then pulse extended (to ensure
// reset is held for a long time). Finally, all the pulse extended resets are combined asynchronously.
// This commonize reset is distributed to all modules within the DLA IP, each module is responsible
// for synchronizing the reset before consumption.

`resetall
`undefineall
`default_nettype none

module dla_platform_reset #(
    parameter int RESET_HOLD_CLOCK_CYCLES,  //how many clock cycles to extend how long reset is held for
    parameter int MAX_DLA_INSTANCES,        //maximum number of DLA instances defined by the number of CSR and DDR interfaces provided by the BSP
    parameter int ENABLE_DDR=1,             //whether the DDR resets passed to this instance are valid, resets are ignored when disabled
    parameter int ENABLE_AXI=0              //Whether the AXI resets passed to this instance are valid, resets are ignored when disabled
) (
    //clocks
    input wire     clk_dla,
    input wire     clk_ddr       [MAX_DLA_INSTANCES],  //one ddr clock for each ddr bank
    input wire     clk_pcie,
    input wire     clk_axis      [MAX_DLA_INSTANCES],

    //resets from each clock domain, if you don't have a resetn signal then tie that inport port to 1'b1
    input wire     i_resetn_dla,
    input wire     i_resetn_ddr  [MAX_DLA_INSTANCES],  //one ddr reset for each ddr bank
    input wire     i_resetn_pcie,
    input wire     i_resetn_axis [MAX_DLA_INSTANCES],

    //after combining the resets from all clock domains, this output reset has been held for at RESET_HOLD_CLOCK_CYCLES on each clock domain
    //this reset is NOT synchronized to any clock, it is meant for distribution to the DLA IP
    //unfortunately inside a PR region one has no access to a global clock line, which would be ideal for distribution
    output logic    o_resetn_async
);

    //convert unpacked to packed
    logic [MAX_DLA_INSTANCES-1:0] resetn_ddr_reindex;
    logic [MAX_DLA_INSTANCES-1:0] resetn_axis_reindex;
    always_comb begin
        for (int i=0; i<MAX_DLA_INSTANCES; i++) begin
            resetn_ddr_reindex[i] = i_resetn_ddr[i];
            resetn_axis_reindex[i] = i_resetn_axis[i];
        end
    end

    logic resetn_ddr_combined, resetn_axi_combined, resetn_inputs_combined;
    logic resetn_pulse_extended_dla, resetn_pulse_extended_pcie;
    logic [MAX_DLA_INSTANCES-1:0] resetn_pulse_extended_ddr;
    logic [MAX_DLA_INSTANCES-1:0] resetn_pulse_extended_axis;

    assign resetn_inputs_combined = i_resetn_dla & i_resetn_pcie & resetn_ddr_combined & resetn_axi_combined;

    dla_platform_reset_internal #(
        .RESET_HOLD_CLOCK_CYCLES    (RESET_HOLD_CLOCK_CYCLES)
    )
    dla_resetn_inst
    (
        .clk                        (clk_dla),
        .i_resetn_combined          (resetn_inputs_combined),
        .o_resetn_pulse_extended    (resetn_pulse_extended_dla)
    );

    if (ENABLE_DDR) begin
        assign resetn_ddr_combined = &resetn_ddr_reindex;

        for (genvar g = 0; g < MAX_DLA_INSTANCES; g++) begin : GEN_DDR_RESET
            dla_platform_reset_internal #(
                .RESET_HOLD_CLOCK_CYCLES    (RESET_HOLD_CLOCK_CYCLES)
            )
            ddr_resetn_inst
            (
                .clk                        (clk_ddr[g]),
                .i_resetn_combined          (resetn_inputs_combined),
                .o_resetn_pulse_extended    (resetn_pulse_extended_ddr[g])
            );
        end
    end else begin
        assign resetn_ddr_combined = 1'b1;
        assign resetn_pulse_extended_ddr = '{default: 1'b1};
    end

    dla_platform_reset_internal #(
        .RESET_HOLD_CLOCK_CYCLES    (RESET_HOLD_CLOCK_CYCLES)
    )
    pcie_resetn_inst
    (
        .clk                        (clk_pcie),
        .i_resetn_combined          (resetn_inputs_combined),
        .o_resetn_pulse_extended    (resetn_pulse_extended_pcie)
    );

    if (ENABLE_AXI) begin
        assign resetn_axi_combined = &resetn_axis_reindex;

        for (genvar g = 0; g < MAX_DLA_INSTANCES; g++) begin: GEN_AXI_RESET
            dla_platform_reset_internal #(
                .RESET_HOLD_CLOCK_CYCLES    (RESET_HOLD_CLOCK_CYCLES)
            )
            axis_resetn_inst
            (
                .clk                        (clk_axis[g]),
                .i_resetn_combined          (resetn_inputs_combined),
                .o_resetn_pulse_extended    (resetn_pulse_extended_axis[g])
            );
        end
    end else begin
        assign resetn_axi_combined = 1'b1;
        assign resetn_pulse_extended_axis = '{default: 1'b1};
    end

    dla_cdc_reset_async recombine_resets
    (
      .clk            (clk_pcie),
      .i_async_resetn (
        resetn_pulse_extended_dla &
        (&resetn_pulse_extended_ddr) &
        resetn_pulse_extended_pcie &
        (&resetn_pulse_extended_axis)
      ),

      .o_async_resetn (o_resetn_async)
    );

endmodule
