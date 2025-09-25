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



// This module is a wrapper around dla top and dla platform adapter modules

`resetall
`undefineall
`default_nettype none

module dla_platform_wrapper #(
  parameter int C_CSR_AXI_ADDR_WIDTH,         //width of the byte address signal, determines CSR address space size, e.g. 11 bit address = 2048 bytes, the largest size that uses only 1 M20K
  parameter int C_CSR_AXI_DATA_WIDTH,         //width of the CSR data path, typically 4 bytes
  parameter int C_DDR_AXI_ADDR_WIDTH,         //width of all byte address signals to global memory, 32 would allow 4 GB of addressable memory
  parameter int C_DDR_AXI_BURST_WIDTH,        //internal width of the axi burst length signal, typically 4, max number of words in a burst = 2**DDR_BURST_WIDTH
  parameter int C_DDR_AXI_DATA_WIDTH,         //width of the global memory data path, typically 64 bytes
  parameter int C_DDR_AXI_THREAD_ID_WIDTH,    //width of the axi id signal for reads, need enough bits to uniquely identify which master a request came from
  parameter int MAX_DLA_INSTANCES,            //maximum number of DLA instances defined by the number of CSR and DDR interfaces provided by the BSP
  parameter int HW_TIMER_WIDTH,               //width of the hw timer counter, for inferring CoreDLA clock frequency from host
  parameter int ENABLE_INPUT_STREAMING,       //AXI-s input-enable toggle
  parameter int AXI_ISTREAM_DATA_WIDTH,       //width of input AXI-S streamer data bus
  parameter int AXI_ISTREAM_FIFO_DEPTH,       //depth of the dcfifo in the input streamer
  parameter int ENABLE_OUTPUT_STREAMER,       //AXI-s output-enable toggle
  parameter int AXI_OSTREAM_DATA_WIDTH,       //width of output AXI-S streamer data bus
  parameter int AXI_OSTREAM_FIFO_DEPTH,       //depth of the dcfifo in the output streamer

  //derived parameters and constants
  localparam int AXI_BURST_LENGTH_WIDTH = 8,     //width of the axi burst length signal as per the axi4 spec
  localparam int AXI_BURST_SIZE_WIDTH = 3,       //width of the axi burst size signal as per the axi4 spec
  localparam int AXI_BURST_TYPE_WIDTH = 2,       //width of the axi burst type signal as per the axi4 spec
  localparam int RESET_HOLD_CLOCK_CYCLES = 1024  //number of clock cycles to hold the reset signal connected to the dla top and dla platform adapter modules
) (
  //clocks and resets
  input wire                                    clk_dla,
  input wire                                    clk_ddr       [MAX_DLA_INSTANCES],  //one ddr clock for each ddr bank
  input wire                                    clk_axi       [MAX_DLA_INSTANCES],  //one AXI-s clock for each instance
  input wire                                    clk_pcie,
  input wire                                    i_resetn_dla,                       //active low reset synchronized to clk_dla
  input wire                                    i_resetn_ddr  [MAX_DLA_INSTANCES],  //active low reset synchronized to each clk_ddr
  input wire                                    i_resetn_axi  [MAX_DLA_INSTANCES],  //active low reset synchronized to each AXI-s clock
  input wire                                    i_resetn_pcie,                      //active low reset synchronized to clk_pcie

  //interrupt request, AXI4 stream master without data, runs on pcie clock
  output logic                                  o_interrupt_level,

  //AXI interfaces for CSR
  input  wire        [C_CSR_AXI_ADDR_WIDTH-1:0] i_csr_awaddr  [MAX_DLA_INSTANCES],
  input  wire                                   i_csr_awvalid [MAX_DLA_INSTANCES],
  output logic                                  o_csr_awready [MAX_DLA_INSTANCES],
  input  wire        [C_CSR_AXI_DATA_WIDTH-1:0] i_csr_wdata   [MAX_DLA_INSTANCES],
  input  wire                                   i_csr_wvalid  [MAX_DLA_INSTANCES],
  output logic                                  o_csr_wready  [MAX_DLA_INSTANCES],
  output logic                                  o_csr_bvalid  [MAX_DLA_INSTANCES],
  input  wire                                   i_csr_bready  [MAX_DLA_INSTANCES],
  input  wire        [C_CSR_AXI_ADDR_WIDTH-1:0] i_csr_araddr  [MAX_DLA_INSTANCES],
  input  wire                                   i_csr_arvalid [MAX_DLA_INSTANCES],
  output logic                                  o_csr_arready [MAX_DLA_INSTANCES],
  output logic       [C_CSR_AXI_DATA_WIDTH-1:0] o_csr_rdata   [MAX_DLA_INSTANCES],
  output logic                                  o_csr_rvalid  [MAX_DLA_INSTANCES],
  input  wire                                   i_csr_rready  [MAX_DLA_INSTANCES],

  //AXI interfaces for DDR
  output logic                                  o_ddr_arvalid [MAX_DLA_INSTANCES],
  output logic       [C_DDR_AXI_ADDR_WIDTH-1:0] o_ddr_araddr  [MAX_DLA_INSTANCES],
  output logic     [AXI_BURST_LENGTH_WIDTH-1:0] o_ddr_arlen   [MAX_DLA_INSTANCES],
  output logic       [AXI_BURST_SIZE_WIDTH-1:0] o_ddr_arsize  [MAX_DLA_INSTANCES],
  output logic       [AXI_BURST_TYPE_WIDTH-1:0] o_ddr_arburst [MAX_DLA_INSTANCES],
  output logic  [C_DDR_AXI_THREAD_ID_WIDTH-1:0] o_ddr_arid    [MAX_DLA_INSTANCES],
  input  wire                                   i_ddr_arready [MAX_DLA_INSTANCES],
  input  wire                                   i_ddr_rvalid  [MAX_DLA_INSTANCES],
  input  wire        [C_DDR_AXI_DATA_WIDTH-1:0] i_ddr_rdata   [MAX_DLA_INSTANCES],
  input  wire   [C_DDR_AXI_THREAD_ID_WIDTH-1:0] i_ddr_rid     [MAX_DLA_INSTANCES],
  output logic                                  o_ddr_rready  [MAX_DLA_INSTANCES],
  output logic                                  o_ddr_awvalid [MAX_DLA_INSTANCES],
  output logic       [C_DDR_AXI_ADDR_WIDTH-1:0] o_ddr_awaddr  [MAX_DLA_INSTANCES],
  output logic     [AXI_BURST_LENGTH_WIDTH-1:0] o_ddr_awlen   [MAX_DLA_INSTANCES],
  output logic       [AXI_BURST_SIZE_WIDTH-1:0] o_ddr_awsize  [MAX_DLA_INSTANCES],
  output logic       [AXI_BURST_TYPE_WIDTH-1:0] o_ddr_awburst [MAX_DLA_INSTANCES],
  input  wire                                   i_ddr_awready [MAX_DLA_INSTANCES],
  output logic                                  o_ddr_wvalid  [MAX_DLA_INSTANCES],
  output logic       [C_DDR_AXI_DATA_WIDTH-1:0] o_ddr_wdata   [MAX_DLA_INSTANCES],
  output logic   [(C_DDR_AXI_DATA_WIDTH/8)-1:0] o_ddr_wstrb   [MAX_DLA_INSTANCES],
  output logic                                  o_ddr_wlast   [MAX_DLA_INSTANCES],
  input  wire                                   i_ddr_wready  [MAX_DLA_INSTANCES],
  input  wire                                   i_ddr_bvalid  [MAX_DLA_INSTANCES],
  output logic                                  o_ddr_bready  [MAX_DLA_INSTANCES],

  input  wire                                   i_istream_axi_t_valid[MAX_DLA_INSTANCES],
  output logic                                  o_istream_axi_t_ready[MAX_DLA_INSTANCES],
  input  wire      [AXI_ISTREAM_DATA_WIDTH-1:0] i_istream_axi_t_data [MAX_DLA_INSTANCES],

  output logic                                  o_ostream_axi_t_valid [MAX_DLA_INSTANCES],
  input wire                                    i_ostream_axi_t_ready [MAX_DLA_INSTANCES],
  output wire                                   o_ostream_axi_t_last  [MAX_DLA_INSTANCES],
  output logic [AXI_OSTREAM_DATA_WIDTH-1:0]     o_ostream_axi_t_data  [MAX_DLA_INSTANCES],
  output logic [(AXI_OSTREAM_DATA_WIDTH/8)-1:0] o_ostream_axi_t_strb  [MAX_DLA_INSTANCES],

  //hw timer, for inferring CoreDLA clock frequency from host
  input  wire                                   i_hw_timer_start,
  input  wire                                   i_hw_timer_stop,
  output logic             [HW_TIMER_WIDTH-1:0] o_hw_timer_counter
);

  /////////////////////////////////////////////////////////////
  //  Auto-generated parameters for the PCIe example design  //
  /////////////////////////////////////////////////////////////

  localparam int    NUM_DLA_INSTANCES = 1;

  //////////////////////////////////////////////////////////////////////////////////////
  //  Ensure reset is held for at least RESET_HOLD_CLOCK_CYCLES on each clock domain  //
  //////////////////////////////////////////////////////////////////////////////////////

  logic resetn_async;     //for distribution to DLA IP

  dla_platform_reset #(
    .RESET_HOLD_CLOCK_CYCLES    (RESET_HOLD_CLOCK_CYCLES),
    .MAX_DLA_INSTANCES          (MAX_DLA_INSTANCES),
    .ENABLE_AXI                 (ENABLE_INPUT_STREAMING || ENABLE_OUTPUT_STREAMER)
  ) dla_platform_reset_inst (
    .clk_dla                    (clk_dla),
    .clk_ddr                    (clk_ddr),
    .clk_pcie                   (clk_pcie),
    .clk_axis                   (clk_axi),
    .i_resetn_dla               (i_resetn_dla),
    .i_resetn_ddr               (i_resetn_ddr),
    .i_resetn_pcie              (i_resetn_pcie),
    .i_resetn_axis              (i_resetn_axi),
    .o_resetn_async             (resetn_async)
  );

  //////////////////////////////////////////////////////////////////////
  //  Multiplex between interrupts coming from all coreDLA instances  //
  //////////////////////////////////////////////////////////////////////

  logic [NUM_DLA_INSTANCES-1:0] dla_dma_interrupt_level;

  // robustness: ensure an edge triggered interrupt keeps getting sent until the ISR handshake turns it off
  dla_platform_interrupt_retry dla_platform_interrupt_retry_inst (
    .clk                            (clk_pcie),
    .i_resetn_async                 (resetn_async),
    .i_interrupt_level_from_dla     (|dla_dma_interrupt_level),
    .o_interrupt_level_to_platform  (o_interrupt_level)
  );

  // host can estimate clk_dla frequency by starting and stopping a counter with a known wait in between
  dla_platform_hw_timer #(
    .COUNTER_WIDTH (HW_TIMER_WIDTH)
  ) dla_platform_hw_timer_inst (
    .clk                            (clk_dla),
    .i_resetn_async                 (resetn_async),
    .i_start                        (i_hw_timer_start),
    .i_stop                         (i_hw_timer_stop),
    .o_counter                      (o_hw_timer_counter)
  );

  //If coreDLA instance doesn't exist, tie off it's output ports
  for (genvar i = NUM_DLA_INSTANCES; i < MAX_DLA_INSTANCES; i++) begin : GEN_TIE_OFFS
      //DDR control tie off
      assign o_ddr_arvalid[i] = 1'b0;
      assign o_ddr_rready[i] = 1'b1;
      assign o_ddr_awvalid[i] = 1'b0;
      assign o_ddr_wvalid[i] = 1'b0;
      assign o_ddr_bready[i] = 1'b1;

      //DDR data tie off -- technically not necessary, but better to avoid warnings
      assign o_ddr_araddr[i] = '0;
      assign o_ddr_arlen[i] = '0;
      assign o_ddr_arsize[i] = '0;
      assign o_ddr_arburst[i] = '0;
      assign o_ddr_arid[i] = '0;
      assign o_ddr_awaddr[i] = '0;
      assign o_ddr_awlen[i] = '0;
      assign o_ddr_awsize[i] = '0;
      assign o_ddr_awburst[i] = '0;
      assign o_ddr_wdata[i] = '0;
      assign o_ddr_wstrb[i] = '0;
      assign o_ddr_wlast[i] = '0;

      // streaming ingress/egress interface tie off
      assign o_ostream_axi_t_valid[i] = '0;
      assign o_istream_axi_t_ready[i] = '0;

      //CSR tie off
      dla_platform_csr_axi_tie_off
      #(
        .CSR_DATA_WIDTH (C_CSR_AXI_DATA_WIDTH)
      )
      dla_platform_csr_axi_tie_off_inst
      (
        .clk                            (clk_ddr[i]),
        .i_resetn_async                 (resetn_async),

        //axi read channels
        .i_arvalid                      (i_csr_arvalid[i]),
        .o_arready                      (o_csr_arready[i]),
        .o_rvalid                       (o_csr_rvalid[i]),
        .o_rdata                        (o_csr_rdata[i]),
        .i_rready                       (i_csr_rready[i]),

        //axi write channels
        .i_awvalid                      (i_csr_awvalid[i]),
        .o_awready                      (o_csr_awready[i]),
        .i_wvalid                       (i_csr_wvalid[i]),
        .o_wready                       (o_csr_wready[i]),
        .o_bvalid                       (o_csr_bvalid[i]),
        .i_bready                       (i_csr_bready[i])
      );
  end

  ////////////////////////////////////////////////////
  //  Auto-generated coreDLA module instantiations  //
  ////////////////////////////////////////////////////

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

  dla_top_wrapper_AGX5_Streaming_Ddrfree_Softmax_AGX5 dla_top_inst_0 (
    // Clock and reset ports
    .ddr_clk                        (clk_ddr[0]),
    .axi_clk                        (clk_axi[0]),
    .dla_clk                        (clk_dla),
    .irq_clk                        (clk_pcie),
    .dla_resetn                     (resetn_async),

    // Interrupt stream interface without data port
    .o_interrupt_level              (dla_dma_interrupt_level[0]),

    // AXI slave interface connected to PCIE
    .i_csr_arvalid                  (i_csr_arvalid[0]),
    .i_csr_araddr                   (i_csr_araddr[0]),
    .o_csr_arready                  (o_csr_arready[0]),
    .o_csr_rvalid                   (o_csr_rvalid[0]),
    .o_csr_rdata                    (o_csr_rdata[0]),
    .i_csr_rready                   (i_csr_rready[0]),
    .i_csr_awvalid                  (i_csr_awvalid[0]),
    .i_csr_awaddr                   (i_csr_awaddr[0]),
    .o_csr_awready                  (o_csr_awready[0]),
    .i_csr_wvalid                   (i_csr_wvalid[0]),
    .i_csr_wdata                    (i_csr_wdata[0]),
    .o_csr_wready                   (o_csr_wready[0]),
    .o_csr_bvalid                   (o_csr_bvalid[0]),
    .i_csr_bready                   (i_csr_bready[0]),

    // AXI Master interface connected to DDR
    .o_ddr_arvalid                  (o_ddr_arvalid[0]),
    .o_ddr_araddr                   (o_ddr_araddr[0]),
    .o_ddr_arlen                    (o_ddr_arlen[0]),
    .o_ddr_arsize                   (o_ddr_arsize[0]),
    .o_ddr_arburst                  (o_ddr_arburst[0]),
    .o_ddr_arid                     (o_ddr_arid[0]),
    .i_ddr_arready                  (i_ddr_arready[0]),
    .i_ddr_rvalid                   (i_ddr_rvalid[0]),
    .i_ddr_rdata                    (i_ddr_rdata[0]),
    .i_ddr_rid                      (i_ddr_rid[0]),
    .o_ddr_rready                   (o_ddr_rready[0]),
    .o_ddr_awvalid                  (o_ddr_awvalid[0]),
    .o_ddr_awaddr                   (o_ddr_awaddr[0]),
    .o_ddr_awlen                    (o_ddr_awlen[0]),
    .o_ddr_awsize                   (o_ddr_awsize[0]),
    .o_ddr_awburst                  (o_ddr_awburst[0]),
    .i_ddr_awready                  (i_ddr_awready[0]),
    .o_ddr_wvalid                   (o_ddr_wvalid[0]),
    .o_ddr_wdata                    (o_ddr_wdata[0]),
    .o_ddr_wstrb                    (o_ddr_wstrb[0]),
    .o_ddr_wlast                    (o_ddr_wlast[0]),
    .i_ddr_wready                   (i_ddr_wready[0]),
    .i_ddr_bvalid                   (i_ddr_bvalid[0]),
    .o_ddr_bready                   (o_ddr_bready[0]),

    // AXI-s input signals
    .i_istream_axi_t_valid          (i_istream_axi_t_valid[0]),
    .o_istream_axi_t_ready          (o_istream_axi_t_ready[0]),
    .i_istream_axi_t_data           (i_istream_axi_t_data[0]), 

    // AXI-s output signals
    .o_ostream_axi_t_valid          (o_ostream_axi_t_valid[0]),
    .i_ostream_axi_t_ready          (i_ostream_axi_t_ready[0]),
    .o_ostream_axi_t_last           (o_ostream_axi_t_last[0]),
    .o_ostream_axi_t_data           (o_ostream_axi_t_data[0]), 
    .o_ostream_axi_t_strb           (o_ostream_axi_t_strb[0])
  );


endmodule
