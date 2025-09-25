// Copyright 2025 Altera Corporation.
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

// This is the top level module for the streaming example design on the 
// I-series dev-kit.  

`default_nettype none

module top (
    //input  wire        cpu_1v2_resetn, // Reset, low active
    input  wire        clk_sys_100m_p //System clock, 100MHz
    //output   wire [3:0]  fpga_led_pio 
    );

    `include "dla_dma_param.svh"
    `include "dla_acl_parameter_assert.svh"

    // Assert statments to ensure architecture file has input/output streaming enabled
    localparam int IS_STREAMING_SUPPORTED = 1;
    `DLA_ACL_PARAMETER_ASSERT_MESSAGE(((ENABLE_OUTPUT_STREAMER == IS_STREAMING_SUPPORTED) && (ENABLE_INPUT_STREAMING == IS_STREAMING_SUPPORTED)), "This example design only supports input/output streaming")
    
    // Assert statments to ensure architecture file has DDR disbled
    localparam int IS_DDR_DISABLED = 1;
    `DLA_ACL_PARAMETER_ASSERT_MESSAGE((IS_DDR_DISABLED == DISABLE_DDR), "This example design does not contain a EMIF subsystem and is considered ddrfree.")

    // Assert statments to ensure architecture file uses 128 bit streaming data width
    localparam int ED_STREAMING_DATA_WIDTH = 128;
    `DLA_ACL_PARAMETER_ASSERT_MESSAGE(((ED_STREAMING_DATA_WIDTH == AXI_ISTREAM_DATA_WIDTH) && (ED_STREAMING_DATA_WIDTH == AXI_OSTREAM_DATA_WIDTH)), "This example design only supports streaming data width of 128 bits")
    
    // Maximum coreDLA instances. Traditional ED's set this to # of 
    // DDR banks. This ED is ddrfree and is currently capped at 1 in the dla_build_example_design.py
    localparam int MAX_DLA_INSTANCES = 4;

    // Assuming a few hundred MHz, a free running 32-bit counter won't overflow within 1 second
    localparam int HW_TIMER_WIDTH = 32;

    // Global resetn signal from System Sources IP
    // More information regarding reset can be found in documentation
    logic global_resetn;
    logic global_pll_resetn;

    logic resetn_ddr    [MAX_DLA_INSTANCES];
    logic i_resetn_axi  [MAX_DLA_INSTANCES];
    
    // Using a system probe IP for resets
    // Instantiated in board.qsys
    logic system_source;

    // Reset release instantaited in board.qsys
    logic done_reset_n;

    // PLL clocking signals
    logic iopll_lock;
    // 550 MHz PLL generated clk
    logic kernel_clk;
    // 100MHz PLL generated clk
    logic sys_pll_clk;

    // Active low global resets
    assign global_resetn = system_source & ~done_reset_n;
    assign global_pll_resetn = global_resetn & iopll_lock;

    //dla csr axi interfaces
    logic        [C_CSR_AXI_ADDR_WIDTH-1:0] dla_csr_awaddr              [MAX_DLA_INSTANCES];
    logic                                   dla_csr_awvalid             [MAX_DLA_INSTANCES];
    logic                                   dla_csr_awready             [MAX_DLA_INSTANCES];
    logic        [C_CSR_AXI_DATA_WIDTH-1:0] dla_csr_wdata               [MAX_DLA_INSTANCES];
    logic                                   dla_csr_wvalid              [MAX_DLA_INSTANCES];
    logic                                   dla_csr_wready              [MAX_DLA_INSTANCES];
    logic                                   dla_csr_bvalid              [MAX_DLA_INSTANCES];
    logic                                   dla_csr_bready              [MAX_DLA_INSTANCES];
    logic        [C_CSR_AXI_ADDR_WIDTH-1:0] dla_csr_araddr              [MAX_DLA_INSTANCES];
    logic                                   dla_csr_arvalid             [MAX_DLA_INSTANCES];
    logic                                   dla_csr_arready             [MAX_DLA_INSTANCES];
    logic        [C_CSR_AXI_DATA_WIDTH-1:0] dla_csr_rdata               [MAX_DLA_INSTANCES];
    logic                                   dla_csr_rvalid              [MAX_DLA_INSTANCES];
    logic                                   dla_csr_rready              [MAX_DLA_INSTANCES];

    // Ingress Streaming interface
    logic   [AXI_ISTREAM_DATA_WIDTH-1:0]    ingress_st_data_big_endian  [MAX_DLA_INSTANCES];
    logic   [AXI_ISTREAM_DATA_WIDTH-1:0]    dla_ingress_st_data         [MAX_DLA_INSTANCES];
    logic                                   dla_ingress_st_valid        [MAX_DLA_INSTANCES];  
    logic                                   dla_ingress_st_ready        [MAX_DLA_INSTANCES];

    // Egress Streaming interface
    logic   [AXI_OSTREAM_DATA_WIDTH-1:0]    dla_egress_axi_st_data      [MAX_DLA_INSTANCES];
    logic   [AXI_OSTREAM_DATA_WIDTH-1:0]    dla_egress_avalon_st_data   [MAX_DLA_INSTANCES];
    logic                                   dla_egress_st_valid         [MAX_DLA_INSTANCES];
    logic                                   dla_egress_st_ready         [MAX_DLA_INSTANCES];
    logic   [AXI_OSTREAM_DATA_WIDTH/8-1:0]  dla_egress_axi_st_strb      [MAX_DLA_INSTANCES];

    //hw timer, for inferring CoreDLA clock frequency from host
    // Avalon interface from system console
    logic                                   dla_hw_timer_write;
    logic                                   dla_hw_timer_read;
    logic             [HW_TIMER_WIDTH-1:0]  dla_hw_timer_readdata;
    logic             [HW_TIMER_WIDTH-1:0]  dla_hw_timer_writedata;
    logic                                   dla_hw_timer_start;
    logic                                   dla_hw_timer_stop;
    logic              [HW_TIMER_WIDTH-1:0] dla_hw_timer_counter;

    //mapping of avalon interface to the hw timer signals
    assign dla_hw_timer_start = dla_hw_timer_write & dla_hw_timer_writedata[0];
    assign dla_hw_timer_stop = dla_hw_timer_write & dla_hw_timer_writedata[1];
    assign dla_hw_timer_readdata = dla_hw_timer_counter;

    // Heartbeat counter for sanity check
    logic [6:0] heartbeat_counter;
    //assign fpga_led_pio = heartbeat_counter[6:3];

    always_ff @ (posedge sys_pll_clk) begin
        heartbeat_counter <= heartbeat_counter + 4'b1;
        if (~global_pll_resetn) begin 
            heartbeat_counter <= 4'b0;
        end
    end

    // Ingress side: system console reads/writes in little endian. mSGDMA reads/writes in big endian. 
    // Performing big endian -> little endian conversion on the ingress streaming side. 
    // Egress side: Need to convert axi streaming to avalon streaming for the mSGDMA IP in board.qsys.
    // This involves some extra logic to ensure the axi strobe signal is implemented
    always_comb begin
        for (int i = 0; i < AXI_OSTREAM_DATA_WIDTH; i = i + 8) begin 
            dla_ingress_st_data[0][i +: 8] = ingress_st_data_big_endian[0][AXI_OSTREAM_DATA_WIDTH-1-i -: 8];
            if (dla_egress_axi_st_strb[0][i >> 3] == 1'b1) begin 
                dla_egress_avalon_st_data[0][i+: 8] =  dla_egress_axi_st_data[0][i+: 8];
            end 
            else begin 
                // Set the byte to FF to catch in post processing
                // FF is nan in FP16
                dla_egress_avalon_st_data[0][i+: 8] = '1;
            end  
        end 
    end

	 
	 
    // This qsys system is where ingress/egress streaming takes place.
    // Also contains system console avalon manager and additionally has some 
    // PLL and reset logic.
    board board_inst (
        .clk_clk                        ( clk_sys_100m_p               ),
        
        // Avalon master for hw timer, for inferring CoreDLA clock frequency from host
        .dla_hw_timer_waitrequest       ( 1'b0                         ),  // no backpressure
        .dla_hw_timer_readdata          ( dla_hw_timer_readdata        ),
        .dla_hw_timer_readdatavalid     ( dla_hw_timer_read            ),  //respond immediately
        .dla_hw_timer_burstcount        (                              ),  //output ignored             
        .dla_hw_timer_writedata         ( dla_hw_timer_writedata       ),
        .dla_hw_timer_address           (                              ),  //output ignored
        .dla_hw_timer_write             ( dla_hw_timer_write           ),
        .dla_hw_timer_read              ( dla_hw_timer_read            ),
        .dla_hw_timer_byteenable        (                              ),  //output ignored
        .dla_hw_timer_debugaccess       (                              ),  //output ignored
        
        // JTAG CSR master for IP0
        .csr_axi_bridge_0_m0_awaddr     ( dla_csr_awaddr           [0] ),
        .csr_axi_bridge_0_m0_awprot     (                              ),  // this output is ignored
        .csr_axi_bridge_0_m0_awvalid    ( dla_csr_awvalid          [0] ),
        .csr_axi_bridge_0_m0_awready    ( dla_csr_awready          [0] ),
        .csr_axi_bridge_0_m0_wdata      ( dla_csr_wdata            [0] ),
        .csr_axi_bridge_0_m0_wstrb      (                              ),  // this output is ignored
        .csr_axi_bridge_0_m0_wlast      (                              ),  // this output is ignored
        .csr_axi_bridge_0_m0_wvalid     ( dla_csr_wvalid           [0] ),
        .csr_axi_bridge_0_m0_wready     ( dla_csr_wready           [0] ),
        .csr_axi_bridge_0_m0_bvalid     ( dla_csr_bvalid           [0] ),
        .csr_axi_bridge_0_m0_bready     ( dla_csr_bready           [0] ),
        .csr_axi_bridge_0_m0_araddr     ( dla_csr_araddr           [0] ),
        .csr_axi_bridge_0_m0_arprot     (                              ),  // this output is ignored
        .csr_axi_bridge_0_m0_arvalid    ( dla_csr_arvalid          [0] ),
        .csr_axi_bridge_0_m0_arready    ( dla_csr_arready          [0] ),
        .csr_axi_bridge_0_m0_rdata      ( dla_csr_rdata            [0] ),
        .csr_axi_bridge_0_m0_rvalid     ( dla_csr_rvalid           [0] ),
        .csr_axi_bridge_0_m0_rready     ( dla_csr_rready           [0] ),
        
        // JTAG CSR master for IP1
        .csr_axi_bridge_1_m0_awaddr     ( dla_csr_awaddr           [1] ),
        .csr_axi_bridge_1_m0_awprot     (                              ),  // this output is ignored
        .csr_axi_bridge_1_m0_awvalid    ( dla_csr_awvalid          [1] ),
        .csr_axi_bridge_1_m0_awready    ( dla_csr_awready          [1] ),
        .csr_axi_bridge_1_m0_wdata      ( dla_csr_wdata            [1] ),
        .csr_axi_bridge_1_m0_wstrb      (                              ),  // this output is ignored
        .csr_axi_bridge_1_m0_wlast      (                              ),  // this output is ignored
        .csr_axi_bridge_1_m0_wvalid     ( dla_csr_wvalid           [1] ),
        .csr_axi_bridge_1_m0_wready     ( dla_csr_wready           [1] ),
        .csr_axi_bridge_1_m0_bvalid     ( dla_csr_bvalid           [1] ),
        .csr_axi_bridge_1_m0_bready     ( dla_csr_bready           [1] ),
        .csr_axi_bridge_1_m0_araddr     ( dla_csr_araddr           [1] ),
        .csr_axi_bridge_1_m0_arprot     (                              ),  // this output is ignored
        .csr_axi_bridge_1_m0_arvalid    ( dla_csr_arvalid          [1] ),
        .csr_axi_bridge_1_m0_arready    ( dla_csr_arready          [1] ),
        .csr_axi_bridge_1_m0_rdata      ( dla_csr_rdata            [1] ),
        .csr_axi_bridge_1_m0_rvalid     ( dla_csr_rvalid           [1] ),
        .csr_axi_bridge_1_m0_rready     ( dla_csr_rready           [1] ),

        // JTAG CSR master for IP2
        .csr_axi_bridge_2_m0_awaddr     ( dla_csr_awaddr           [2] ),
        .csr_axi_bridge_2_m0_awprot     (                              ),  // this output is ignored
        .csr_axi_bridge_2_m0_awvalid    ( dla_csr_awvalid          [2] ),
        .csr_axi_bridge_2_m0_awready    ( dla_csr_awready          [2] ),
        .csr_axi_bridge_2_m0_wdata      ( dla_csr_wdata            [2] ),
        .csr_axi_bridge_2_m0_wstrb      (                              ),  // this output is ignored
        .csr_axi_bridge_2_m0_wlast      (                              ),  // this output is ignored
        .csr_axi_bridge_2_m0_wvalid     ( dla_csr_wvalid           [2] ),
        .csr_axi_bridge_2_m0_wready     ( dla_csr_wready           [2] ),
        .csr_axi_bridge_2_m0_bvalid     ( dla_csr_bvalid           [2] ),
        .csr_axi_bridge_2_m0_bready     ( dla_csr_bready           [2] ),
        .csr_axi_bridge_2_m0_araddr     ( dla_csr_araddr           [2] ),
        .csr_axi_bridge_2_m0_arprot     (                              ),  // this output is ignored
        .csr_axi_bridge_2_m0_arvalid    ( dla_csr_arvalid          [2] ),
        .csr_axi_bridge_2_m0_arready    ( dla_csr_arready          [2] ),
        .csr_axi_bridge_2_m0_rdata      ( dla_csr_rdata            [2] ),
        .csr_axi_bridge_2_m0_rvalid     ( dla_csr_rvalid           [2] ),
        .csr_axi_bridge_2_m0_rready     ( dla_csr_rready           [2] ),

        // JTAG CSR master for IP3
        .csr_axi_bridge_3_m0_awaddr     ( dla_csr_awaddr           [3] ),
        .csr_axi_bridge_3_m0_awprot     (                              ),  // this output is ignored
        .csr_axi_bridge_3_m0_awvalid    ( dla_csr_awvalid          [3] ),
        .csr_axi_bridge_3_m0_awready    ( dla_csr_awready          [3] ),
        .csr_axi_bridge_3_m0_wdata      ( dla_csr_wdata            [3] ),
        .csr_axi_bridge_3_m0_wstrb      (                              ),  // this output is ignored
        .csr_axi_bridge_3_m0_wlast      (                              ),  // this output is ignored
        .csr_axi_bridge_3_m0_wvalid     ( dla_csr_wvalid           [3] ),
        .csr_axi_bridge_3_m0_wready     ( dla_csr_wready           [3] ),
        .csr_axi_bridge_3_m0_bvalid     ( dla_csr_bvalid           [3] ),
        .csr_axi_bridge_3_m0_bready     ( dla_csr_bready           [3] ),
        .csr_axi_bridge_3_m0_araddr     ( dla_csr_araddr           [3] ),
        .csr_axi_bridge_3_m0_arprot     (                              ),  // this output is ignored
        .csr_axi_bridge_3_m0_arvalid    ( dla_csr_arvalid          [3] ),
        .csr_axi_bridge_3_m0_arready    ( dla_csr_arready          [3] ),
        .csr_axi_bridge_3_m0_rdata      ( dla_csr_rdata            [3] ),
        .csr_axi_bridge_3_m0_rvalid     ( dla_csr_rvalid           [3] ),
        .csr_axi_bridge_3_m0_rready     ( dla_csr_rready           [3] ),

        // Streaming interface
        .egress_st_data                 ( dla_egress_avalon_st_data[0] ),
        .egress_st_valid                ( dla_egress_st_valid      [0] ),
        .egress_st_ready                ( dla_egress_st_ready      [0] ),
        .ingress_st_data                ( ingress_st_data_big_endian[0]),
        .ingress_st_valid               ( dla_ingress_st_valid     [0] ),
        .ingress_st_ready               ( dla_ingress_st_ready     [0] ),
        
        // PLL lock and clk
        .iopll_locked_export            ( iopll_lock                   ),
        .kernel_clk_clk                 ( kernel_clk                   ),
        .sys_pll_clk_clk                ( sys_pll_clk                  ),
        
        // Resets
        .resetn_reset_n                 ( global_resetn                ),
        .pll_resetn_in_reset_n          ( global_pll_resetn            ), 
        .done_resetn_ninit_done         ( done_reset_n                 ),
        .source_source                  ( system_source                )
    );

    // Reset of hostless design is conducted through global_pll_resetn (system_source)
    assign resetn_ddr[0] = 1'b1;
    assign resetn_ddr[1] = 1'b1;
    assign resetn_ddr[2] = 1'b1;
    assign resetn_ddr[3] = 1'b1;

    assign i_resetn_axi[0] = 1'b1;
    assign i_resetn_axi[1] = 1'b1;
    assign i_resetn_axi[2] = 1'b1;
    assign i_resetn_axi[3] = 1'b1;

    // wrapper around dla_top + dla_platform_adaptor
    dla_platform_wrapper #(
        .C_CSR_AXI_ADDR_WIDTH           (C_CSR_AXI_ADDR_WIDTH),
        .C_CSR_AXI_DATA_WIDTH           (C_CSR_AXI_DATA_WIDTH),
        .C_DDR_AXI_ADDR_WIDTH           (C_DDR_AXI_ADDR_WIDTH),
        .C_DDR_AXI_DATA_WIDTH           (C_DDR_AXI_DATA_WIDTH),
        .C_DDR_AXI_BURST_WIDTH          (C_DDR_AXI_BURST_WIDTH),
        .C_DDR_AXI_THREAD_ID_WIDTH      (C_DDR_AXI_THREAD_ID_WIDTH),
        .MAX_DLA_INSTANCES              (MAX_DLA_INSTANCES),
        .HW_TIMER_WIDTH                 (HW_TIMER_WIDTH), 
        .ENABLE_INPUT_STREAMING         (ENABLE_INPUT_STREAMING),
        .AXI_ISTREAM_DATA_WIDTH         (AXI_ISTREAM_DATA_WIDTH),
        .AXI_ISTREAM_FIFO_DEPTH         (AXI_ISTREAM_FIFO_DEPTH),
        .ENABLE_OUTPUT_STREAMER         (ENABLE_OUTPUT_STREAMER),
        .AXI_OSTREAM_DATA_WIDTH         (AXI_OSTREAM_DATA_WIDTH),
        .AXI_OSTREAM_FIFO_DEPTH         (AXI_OSTREAM_FIFO_DEPTH)
    )
    dla_platform_inst
    (
        // clocks and resets
        .clk_dla                        (kernel_clk),
        .clk_ddr                        ({sys_pll_clk, sys_pll_clk, sys_pll_clk, sys_pll_clk}),
        .clk_pcie                       (sys_pll_clk),
        .clk_axi                        ({sys_pll_clk, sys_pll_clk, sys_pll_clk, sys_pll_clk}),
        .i_resetn_dla                   (global_pll_resetn),
        .i_resetn_ddr                   (resetn_ddr),
        .i_resetn_axi                   (i_resetn_axi),
        .i_resetn_pcie                  ('1),

        //interrupt request, AXI4 stream master without data, runs on pcie clock
        .o_interrupt_level              (),

        // AXI-Streaming
        .i_istream_axi_t_valid          (dla_ingress_st_valid),
        .o_istream_axi_t_ready          (dla_ingress_st_ready),
        .i_istream_axi_t_data           (dla_ingress_st_data),

        // Egress Streaming
        .o_ostream_axi_t_valid          (dla_egress_st_valid),
        .i_ostream_axi_t_ready          (dla_egress_st_ready),
        .o_ostream_axi_t_data           (dla_egress_axi_st_data), 
        .o_ostream_axi_t_strb           (dla_egress_axi_st_strb),

        //AXI slave interfaces for CSR
        .i_csr_arvalid                  (dla_csr_arvalid),
        .i_csr_araddr                   (dla_csr_araddr),
        .o_csr_arready                  (dla_csr_arready),
        .o_csr_rvalid                   (dla_csr_rvalid),
        .o_csr_rdata                    (dla_csr_rdata),
        .i_csr_rready                   (dla_csr_rready),
        .i_csr_awvalid                  (dla_csr_awvalid),
        .i_csr_awaddr                   (dla_csr_awaddr),
        .o_csr_awready                  (dla_csr_awready),
        .i_csr_wvalid                   (dla_csr_wvalid),
        .i_csr_wdata                    (dla_csr_wdata),
        .o_csr_wready                   (dla_csr_wready),
        .o_csr_bvalid                   (dla_csr_bvalid),
        .i_csr_bready                   (dla_csr_bready),
        
        //hw timer, for inferring CoreDLA clock frequency from host
        .i_hw_timer_start               (dla_hw_timer_start),
        .i_hw_timer_stop                (dla_hw_timer_stop),
        .o_hw_timer_counter             (dla_hw_timer_counter)
    );

endmodule

`default_nettype wire
