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


// This module implements the CSR for DMA. It also includes the descriptor queue
// and interrupt request generator. The CSR is implemented with a RAM. Certain
// values are kept live in registers, such the interrupt control and mask. This
// makes it easier to detect when a change has happened (instead of trying to a
// read-modify-write with the RAM).
//
// The AXI4 lite slave interface is usually going to backpressure PCIe. There is
// a state machine which allows one outstanding read request and one outstanding
// write request at a time (write requests can be outstanding if the writeack is
// backpressured which AXI allows). There is a register which tracks whether the
// last request was a read or write, this enables round robin arbitration. Each
// request takes a few clock cycles to process, as the address needs to be decoded
// to determine if a write is allowed to commit to the RAM, or if we need to use
// read data from one of the registers instead of the RAM.
//
// Special offsets are defined as localparams below. Writing to DLA_DMA_CSR_OFFSET_INPUT_OUTPUT_BASE_ADDR/4
// will cause one unit of work to be enqueued in the descriptor queue. Currently
// this involves writing 8 values to a fifo, which are then consumed by the config
// reader. Internal to the config reader, 4 values go to the config reader address
// generator, the other 4 go to the config reader intercept.
//
// Beware the following assumptions about how the host issues requests to this CSR:
// - no bursts (required by AXI4 lite)
// - byte enables are assumed to be all 1 (no partial word access)
// - all addresses must be word aligned (e.g. if CSR_DATA_BYTES=4 then the bottom 2 bits of address must be 0)

`resetall
`undefineall
`default_nettype none
`include "dla_acl_parameter_assert.svh"

module dla_dma_csr #(
    parameter int CSR_ADDR_WIDTH,           //width of the byte address signal, determines CSR address space size, e.g. 11 bit address = 2048 bytes, the largest size that uses only 1 M20K
    parameter int CSR_DATA_BYTES,           //width of the CSR data path, typically 4 bytes
    parameter int CONFIG_DATA_BYTES,        //data width of the config network output port, typically 4 bytes, the descriptor queue matches this so that config decode can be reused
    parameter int CONFIG_READER_DATA_BYTES, //data width of the config network input port, needed by config reader address generator for loop update

    parameter int ENABLE_INPUT_STREAMING,
    parameter int ENABLE_OUTPUT_STREAMING,
    parameter int ENABLE_ON_CHIP_PARAMETERS

    ) (
    input  wire                             clk_ddr,
    input  wire                             clk_pcie,
    input  wire                             clk_dla,
    input  wire                             i_sclrn_ddr,        //active low reset that has already been synchronized to clk_ddr
    input  wire                             i_resetn_async,     //active low reset that has NOT been synchronized to any clock, only to be consumed by dcfifo

    //updates for interrupt, runs on ddr clock
    input  wire                             i_token_done,       //feature writer reports it is done
    input  wire                             i_token_stream_started, //input streamer is reading the first word
    input  wire                             i_stream_received_first_word,
    input  wire                             i_stream_sent_last_word,
    input  wire                             i_token_error,      //dla has encountered some error, assert high for one clock cycle to report it to host (assuming mask bit is 1)
    input  wire                             i_license_flag,
    input  wire                             i_token_out_of_inferences,

    //snoop signals for the input feature, output featuer, and filter LSU's core <--> fabric traffic
    //run on clk_ddr
    input  wire                             i_input_feature_rvalid,
    input  wire                             i_input_feature_rready,
    input  wire                             i_input_filter_rvalid,
    input  wire                             i_input_filter_rready,
    input  wire                             i_output_feature_wvalid,
    input  wire                             i_output_feature_wready,

    //interrupt request to pcie, runs on pcie clock
    output logic                            o_interrupt_level,  //level sensitive interrupt

    //read side of descriptor queue goes to config reader, runs on ddr clock
    output logic                            o_config_valid,
    output logic  [8*CONFIG_DATA_BYTES-1:0] o_config_data,
    output logic                            o_config_for_intercept, //0 = goes to config reader addr gen, 1 = goes to config reader intercept
    input  wire                             i_config_ready,

    //debug network AXI-4 lite interface, read request and read response channels, runs on dla_clock
    output logic                            o_debug_network_arvalid,
    output logic     [8*CSR_DATA_BYTES-1:0] o_debug_network_araddr,
    input  wire                             i_debug_network_arready,
    input  wire                             i_debug_network_rvalid,
    input  wire      [8*CSR_DATA_BYTES-1:0] i_debug_network_rdata,
    output logic                            o_debug_network_rready,

    //AXI4-lite slave interface for host control, runs on ddr clock
    //no bursts, byte enables are assumed to be all 1, all addresses must be word aligned (e.g. if CSR_DATA_BYTES=4 then the bottom 2 bits of address must be 0)
    input  wire                             i_csr_arvalid,
    input  wire        [CSR_ADDR_WIDTH-1:0] i_csr_araddr,
    output logic                            o_csr_arready,
    output logic                            o_csr_rvalid,
    output logic     [8*CSR_DATA_BYTES-1:0] o_csr_rdata,
    input  wire                             i_csr_rready,
    input  wire                             i_csr_awvalid,
    input  wire        [CSR_ADDR_WIDTH-1:0] i_csr_awaddr,
    output logic                            o_csr_awready,
    input  wire                             i_csr_wvalid,
    input  wire      [8*CSR_DATA_BYTES-1:0] i_csr_wdata,
    output logic                            o_csr_wready,
    output logic                            o_csr_bvalid,
    input  wire                             i_csr_bready,

    //reset request for the whole ip, runs on ddr clock
    output logic                            o_request_ip_reset,

    output logic                            o_core_streaming_active,

    //output bit to start/stop streaming interface
    output logic                            o_streaming_active
);


    /////////////////////////////////
    //  Parameter legality checks  //
    /////////////////////////////////

    //signal widths cannot be trivial
    `DLA_ACL_PARAMETER_ASSERT(CSR_DATA_BYTES >= 1)
    `DLA_ACL_PARAMETER_ASSERT(CONFIG_DATA_BYTES >= 1)

    //csr address space cannot be trivial
    `DLA_ACL_PARAMETER_ASSERT(2**CSR_ADDR_WIDTH > CONFIG_DATA_BYTES)

    //offsets must be within address space
    localparam int CSR_LO_ADDR = $clog2(CSR_DATA_BYTES);    //number of LSBs that must be 0 in order for byte address to be word aligned
    localparam int CSR_WORD_ADDR_WIDTH = CSR_ADDR_WIDTH - CSR_LO_ADDR;



    /////////////////
    //  Constants  //
    /////////////////
    `include "dla_dma_constants.svh"
    //special offsets -- these values are defined in one place and shared between hardware and software
    //the constants from the dla_dma_constants.svh header file that CSR cares about are named DLA_DMA_CSR_OFFSET_**** and DLA_DMA_CSR_INTERRUPT_****

    //state machine
    enum {
        STATE_GET_READY_BIT,
        STATE_READY_BIT,
        STATE_READ_ADDR_BIT,
        STATE_READ_INTERNAL_BIT,
        STATE_READ_DATA_BIT,
        STATE_WRITE_COMMIT_BIT,
        STATE_DESCRIPTOR_BIT,
        STATE_AWAIT_RESET_BIT
    } index;

    enum logic [index.num()-1:0] {
        //1-hot encodings
        STATE_GET_READY     = 1 << STATE_GET_READY_BIT,
        STATE_READY         = 1 << STATE_READY_BIT,
        STATE_READ_ADDR     = 1 << STATE_READ_ADDR_BIT,
        STATE_READ_INTERNAL = 1 << STATE_READ_INTERNAL_BIT,
        STATE_READ_DATA     = 1 << STATE_READ_DATA_BIT,
        STATE_WRITE_COMMIT  = 1 << STATE_WRITE_COMMIT_BIT,
        STATE_DESCRIPTOR    = 1 << STATE_DESCRIPTOR_BIT,
        STATE_AWAIT_RESET   = 1 << STATE_AWAIT_RESET_BIT,
        XXX = 'x
    } state;

    localparam int MAX_JOBS_ACTIVE   = 64;  //upper bounded by how many descriptors the queue can hold
    localparam int JOBS_ACTIVE_WIDTH = $clog2(MAX_JOBS_ACTIVE+1);



    ///////////////
    //  Signals  //
    ///////////////

    //ram
    logic                           ram_wr_en;
    logic [CSR_WORD_ADDR_WIDTH-1:0] ram_wr_addr, ram_rd_addr, csr_read_addr;
    logic    [8*CSR_DATA_BYTES-1:0] ram_wr_data, ram_rd_data;

    //descriptor queue
    logic                           descriptor_queue_forced_write, descriptor_queue_full, descriptor_diagnostics_almost_full;
    logic   [8*CONFIG_DATA_BYTES:0] descriptor_queue_data;
    logic                     [2:0] descriptor_words_read;
    logic                           first_word_of_descriptor_being_read, jobs_active_is_nonzero, core_jobs_active_is_nonzero;
    logic   [JOBS_ACTIVE_WIDTH-1:0] jobs_active, core_jobs_active;

    //Perfomance counters connections
    logic                    [31:0] total_clocks_active_lo, total_clocks_active_hi;
    logic                    [31:0] total_core_clocks_active_lo, total_core_clocks_active_hi;
    logic                    [31:0] total_clocks_for_all_jobs_lo, total_clocks_for_all_jobs_hi;
    logic                    [31:0] number_of_input_feature_reads_lo, number_of_input_feature_reads_hi;
    logic                    [31:0] number_of_input_filter_reads_lo, number_of_input_filter_reads_hi;
    logic                    [31:0] number_of_output_feature_writes_lo, number_of_output_feature_writes_hi;

    //state machine
    logic                           previous_was_write; // ensures fairness between read/write handling

    logic                           pending_read;
    logic                           pending_write_address;
    logic                           pending_write_data;
    logic                           pending_reset;
    logic                     [3:0] descriptor_count;

    //specific offsets are implemented in registers instead of RAM
    logic                           interrupt_control_error, interrupt_control_done, interrupt_mask_error, interrupt_mask_done;
    logic    [8*CSR_DATA_BYTES-1:0] completion_count;
    logic                           descriptor_diagnostics_overflow;

    //address decode for specific offsets that are implemented in registers or require some action to be taken
    logic                           write_to_interrupt_control, read_from_interrupt_control, write_to_interrupt_mask, read_from_interrupt_mask;
    logic                           write_to_ram, read_from_desc_diagnostics, read_from_completion_count, enqueue_descriptor;
    logic                           read_from_clocks_active_lo, read_from_clocks_active_hi, read_from_clocks_all_jobs_lo, read_from_clocks_all_jobs_hi;
    logic                           read_from_core_clocks_active_lo, read_from_core_clocks_active_hi;
    logic                           read_from_input_feature_reads_lo, read_from_input_feature_reads_hi;
    logic                           read_from_input_filter_reads_lo, read_from_input_filter_reads_hi;
    logic                           read_from_output_feature_writes_lo, read_from_output_feature_writes_hi;
    logic                           write_to_debug_network_addr, read_from_debug_network_valid, read_from_debug_network_data;
    logic                           read_from_license_flag;
    logic                           read_from_ip_reset, write_to_ip_reset;

    //clock crosser for interrupt
    logic                           ddr_interrupt_level;

    //debug network read request address
    logic                           debug_network_arvalid, not_o_debug_network_arvalid;
    logic    [8*CSR_DATA_BYTES-1:0] debug_network_araddr;

    //debug network read response data
    logic                           not_o_debug_network_rready, debug_network_dcfifo_empty, debug_network_rvalid, debug_network_rready;
    logic    [8*CSR_DATA_BYTES-1:0] debug_network_dcfifo_data, debug_network_rdata;

    //streaming states
    logic                           write_ready_streaming_interface;
    logic                           write_core_streaming_active;
    logic                           read_ready_streaming_interface;

    logic dla_sclrn;

    //reset parameterization
    localparam int RESET_USE_SYNCHRONIZER = 1;
    localparam int RESET_PIPE_DEPTH       = 3;
    localparam int RESET_NUM_COPIES       = 1;
    dla_reset_handler_simple #(
        .USE_SYNCHRONIZER   (RESET_USE_SYNCHRONIZER),
        .PIPE_DEPTH         (RESET_PIPE_DEPTH),
        .NUM_COPIES         (RESET_NUM_COPIES)
    )
    ddr_reset_synchronizer
    (
        .clk                (clk_dla),
        .i_resetn           (i_resetn_async),
        .o_sclrn            (dla_sclrn)
    );

    ///////////
    //  RAM  //
    ///////////

    //could use hld_ram, but this simple ram doesn't need the depth stitching or clock enable magic that hld_ram provides

    altera_syncram
    #(
        .address_aclr_b                     ("NONE"),
        .address_reg_b                      ("CLOCK0"),
        .clock_enable_input_a               ("BYPASS"),
        .clock_enable_input_b               ("BYPASS"),
        .clock_enable_output_b              ("BYPASS"),
        .enable_ecc                         ("FALSE"),
        .init_file                          ("dla_dma_csr_discovery_rom.mif"),
        .intended_device_family             ("Arria 10"),       //Quartus will fix this automatically
        .lpm_type                           ("altera_syncram"),
        .numwords_a                         (2**CSR_WORD_ADDR_WIDTH),
        .numwords_b                         (2**CSR_WORD_ADDR_WIDTH),
        .operation_mode                     ("DUAL_PORT"),
        .outdata_aclr_b                     ("NONE"),
        .outdata_sclr_b                     ("NONE"),
        .outdata_reg_b                      ("CLOCK0"),
        .power_up_uninitialized             ("FALSE"),
        .ram_block_type                     ("M20K"),
        .read_during_write_mode_mixed_ports ("DONT_CARE"),
        .widthad_a                          (CSR_WORD_ADDR_WIDTH),
        .widthad_b                          (CSR_WORD_ADDR_WIDTH),
        .width_a                            (8*CSR_DATA_BYTES),
        .width_b                            (8*CSR_DATA_BYTES),
        .width_byteena_a                    (1)
    )
    csr_ram
    (
        .address_a                          (ram_wr_addr),
        .address_b                          (ram_rd_addr),
        .clock0                             (clk_ddr),
        .data_a                             (ram_wr_data),
        .wren_a                             (ram_wr_en),
        .q_b                                (ram_rd_data),
        .address2_a                         (1'b1),
        .address2_b                         (1'b1),
        .addressstall_a                     (1'b0),
        .addressstall_b                     (1'b0),
        .byteena_a                          (1'b1),
        .byteena_b                          (1'b1),
        .clock1                             (1'b1),
        .clocken0                           (1'b1),
        .clocken1                           (1'b1),
        .clocken2                           (1'b1),
        .clocken3                           (1'b1),
        .data_b                             ({(8*CSR_DATA_BYTES){1'b1}}),
        .eccencbypass                       (1'b0),
        .eccencparity                       (8'b0),
        .eccstatus                          (),
        .q_a                                (),
        .rden_a                             (1'b1),
        .rden_b                             (1'b1),
        .wren_b                             (1'b0)
    );



    ////////////////////////
    //  Descriptor Queue  //
    ////////////////////////

    //runtime knows how many jobs it has enqueued and how many jobs have finished
    //runtime is responsible for not overflowing the descriptor queue, it must limit the number of outstanding jobs queued in hardware

    localparam int DESCRIPTOR_QUEUE_ALMOST_FULL_CUTOFF = DLA_DMA_CSR_DESCRIPTOR_QUEUE_WORDS_PER_JOB;    //almost full asserts when queue only has space for 1 more job

    dla_hld_fifo #(
        .WIDTH                      (8*CONFIG_DATA_BYTES + 1),
        .DEPTH                      (DLA_DMA_CSR_DESCRIPTOR_QUEUE_PHYSICAL_SIZE),   //this is set to 512 in dla_dma_constants.svh, may as well use up full depth of M20K
        .ALMOST_FULL_CUTOFF         (DESCRIPTOR_QUEUE_ALMOST_FULL_CUTOFF),
        .ASYNC_RESET                (0),    //consume reset synchronously
        .SYNCHRONIZE_RESET          (0),    //reset is already synchronized
        .STYLE                      ("ms")
    )
    descriptor_queue
    (
        .clock                      (clk_ddr),
        .resetn                     (i_sclrn_ddr),

        .i_valid                    (descriptor_queue_forced_write),
        .i_data                     (descriptor_queue_data),
        .o_stall                    (descriptor_queue_full),    //software is responsible for not overflowing this fifo
        .o_almost_full              (descriptor_diagnostics_almost_full),

        .o_valid                    (o_config_valid),
        .o_data                     ({o_config_for_intercept, o_config_data}),
        .i_stall                    (~i_config_ready | i_token_out_of_inferences)
    );



    ////////////////////////////
    //  Performance counters  //
    ////////////////////////////

    //Auxillary logic that controls the jobs active counters
    assign first_word_of_descriptor_being_read = o_config_valid & i_config_ready & (descriptor_words_read==3'h0);   //desc words read was 0, going to be 1
    always_ff @(posedge clk_ddr) begin
        if (o_config_valid & i_config_ready) descriptor_words_read <= descriptor_words_read + 1'b1;

        if (ENABLE_INPUT_STREAMING & ENABLE_OUTPUT_STREAMING & ENABLE_ON_CHIP_PARAMETERS) begin
            // In this case, we should only track the cycles between the feature data being read, and
            // results being streamed out, since we continually read the on-chip config params
            if (i_token_stream_started & ~i_token_done) jobs_active <= jobs_active + 1'b1;
            if (~i_token_stream_started & i_token_done) jobs_active <= jobs_active - 1'b1;
        end else begin
            if (first_word_of_descriptor_being_read & ~i_token_done) jobs_active <= jobs_active + 1'b1;
            if (~first_word_of_descriptor_being_read & i_token_done) jobs_active <= jobs_active - 1'b1;
        end

        if (~i_sclrn_ddr) begin
            descriptor_words_read <= 3'h0;
            jobs_active <= '0;
            jobs_active_is_nonzero <= 1'b0;
        end
    end

    logic core_jobs_active_is_nonzero_ddr_clk;

    always_ff @(posedge clk_dla) begin
        if (ENABLE_INPUT_STREAMING & ENABLE_OUTPUT_STREAMING & ENABLE_ON_CHIP_PARAMETERS) begin
            // In this case, we also track the cycles between the first feature data being sent by input streamer
            // and last result received by the output streamer.
            if (i_stream_received_first_word & ~i_stream_sent_last_word) core_jobs_active <= core_jobs_active + 1'b1;
            if (~i_stream_received_first_word & i_stream_sent_last_word) core_jobs_active <= core_jobs_active - 1'b1;
            core_jobs_active_is_nonzero <= core_jobs_active != 0;
        end
        if (~dla_sclrn) begin
            core_jobs_active <= '0;
            core_jobs_active_is_nonzero <= 1'b0;
        end
    end

    // crossover core_jobs_active_is_nonzero from dla to ddr clk
    dla_clock_cross_full_sync dla_to_ddr_clock_cross_sync
    (
        .clk_src            (clk_dla),
        .i_src_async_resetn (1'b1),
        .i_src_data         (core_jobs_active_is_nonzero),
        .o_src_data         (),

        .clk_dst            (clk_ddr),
        .i_dst_async_resetn (1'b1),
        .o_dst_data         (core_jobs_active_is_nonzero_ddr_clk)
    );


    //track the number of active jobs
    dla_dma_counter_64 count_total_core_clocks_active (
        .i_clk                      (clk_ddr),
        .i_sclrn                    (i_sclrn_ddr),
        .i_increment_en             (core_jobs_active_is_nonzero_ddr_clk),
        .i_increment_val            (32'b1),
        .i_read_counter_low_bits    (read_from_core_clocks_active_lo),
        .o_counter_low_bits         (total_core_clocks_active_lo),
        .o_counter_high_bits_latch  (total_core_clocks_active_hi)
    );
    //a job is active once the first word of its descriptor is read from the queue
    //a job is finished once the feature writer sends a done token
    dla_dma_counter_64 count_total_clocks_active (
        .i_clk                      (clk_ddr),
        .i_sclrn                    (i_sclrn_ddr),
        .i_increment_en             (jobs_active != 0),
        .i_increment_val            (32'b1),
        .i_read_counter_low_bits    (read_from_clocks_active_lo),
        .o_counter_low_bits         (total_clocks_active_lo),
        .o_counter_high_bits_latch  (total_clocks_active_hi)
    );

    dla_dma_counter_64 count_total_clocks_for_all_jobs (
        .i_clk                      (clk_ddr),
        .i_sclrn                    (i_sclrn_ddr),
        .i_increment_en             (1'b1),
        .i_increment_val            (jobs_active),
        .i_read_counter_low_bits    (read_from_clocks_all_jobs_lo),
        .o_counter_low_bits         (total_clocks_for_all_jobs_lo),
        .o_counter_high_bits_latch  (total_clocks_for_all_jobs_hi)
    );

    //tracks the number of input feature reads in terms of memory words transfers.
    dla_dma_counter_64 count_input_feature_reads (
        .i_clk                      (clk_ddr),
        .i_sclrn                    (i_sclrn_ddr),
        .i_increment_en             (i_input_feature_rready & i_input_feature_rvalid),
        .i_increment_val            (32'b1),
        .i_read_counter_low_bits    (read_from_input_feature_reads_lo),
        .o_counter_low_bits         (number_of_input_feature_reads_lo),
        .o_counter_high_bits_latch  (number_of_input_feature_reads_hi)
    );

    //tracks the number of output feature writes in terms of memory words transfers.
    dla_dma_counter_64 count_output_feature_writes (
        .i_clk                      (clk_ddr),
        .i_sclrn                    (i_sclrn_ddr),
        .i_increment_en             (i_output_feature_wready & i_output_feature_wvalid),
        .i_increment_val            (32'b1),
        .i_read_counter_low_bits    (read_from_output_feature_writes_lo),
        .o_counter_low_bits         (number_of_output_feature_writes_lo),
        .o_counter_high_bits_latch  (number_of_output_feature_writes_hi)
    );

    //tracks the number of input filter reads in terms of memory words transfers.
    dla_dma_counter_64 count_input_filter_reads (
        .i_clk                      (clk_ddr),
        .i_sclrn                    (i_sclrn_ddr),
        .i_increment_en             (i_input_filter_rready & i_input_filter_rvalid),
        .i_increment_val            (32'b1),
        .i_read_counter_low_bits    (read_from_input_filter_reads_lo),
        .o_counter_low_bits         (number_of_input_filter_reads_lo),
        .o_counter_high_bits_latch  (number_of_input_filter_reads_hi)
    );


    //////////////////////
    //  Address decode  //
    //////////////////////

    always_ff @(posedge clk_ddr) begin
        //the csr address space is mostly read only, except for a few specific offsets listed below
        write_to_ram <= 1'b0;
        if (ram_wr_addr == DLA_DMA_CSR_OFFSET_CONFIG_BASE_ADDR/4)       write_to_ram <= 1'b1;
        if (ram_wr_addr == DLA_DMA_CSR_OFFSET_CONFIG_RANGE_MINUS_TWO/4) write_to_ram <= 1'b1;
        if (ram_wr_addr == DLA_DMA_CSR_OFFSET_INPUT_OUTPUT_BASE_ADDR/4) write_to_ram <= 1'b1;
        if (ram_wr_addr == DLA_DMA_CSR_OFFSET_INTERMEDIATE_BASE_ADDR/4) write_to_ram <= 1'b1;
        if (ram_wr_addr == DLA_DMA_CSR_OFFSET_DEBUG_NETWORK_ADDR/4)     write_to_ram <= 1'b1;
        if (ram_wr_addr == DLA_CSR_OFFSET_READY_STREAMING_IFACE/4)      write_to_ram <= 1'b1;
        if (ram_wr_addr == DLA_DMA_CSR_OFFSET_START_CORE_STREAMING/4)   write_to_ram <= 1'b1;

        //decode specific addresses in which the storage lives in registers
        write_to_interrupt_control    <= (ram_wr_addr == DLA_DMA_CSR_OFFSET_INTERRUPT_CONTROL/4);
        read_from_interrupt_control   <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_INTERRUPT_CONTROL/4);
        write_to_interrupt_mask       <= (ram_wr_addr == DLA_DMA_CSR_OFFSET_INTERRUPT_MASK/4);
        read_from_interrupt_mask      <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_INTERRUPT_MASK/4);
        read_from_desc_diagnostics    <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_DESC_DIAGNOSTICS/4);
        read_from_completion_count    <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_COMPLETION_COUNT/4);
        read_from_clocks_active_lo    <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_CLOCKS_ACTIVE_LO/4);
        read_from_clocks_active_hi    <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_CLOCKS_ACTIVE_HI/4);
        read_from_core_clocks_active_lo    <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_CORE_CLOCKS_ACTIVE_LO/4);
        read_from_core_clocks_active_hi    <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_CORE_CLOCKS_ACTIVE_HI/4);
        read_from_clocks_all_jobs_lo  <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_CLOCKS_ALL_JOBS_LO/4);
        read_from_clocks_all_jobs_hi  <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_CLOCKS_ALL_JOBS_HI/4);
        write_to_debug_network_addr   <= (ram_wr_addr == DLA_DMA_CSR_OFFSET_DEBUG_NETWORK_ADDR/4);
        read_from_debug_network_valid <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_DEBUG_NETWORK_VALID/4);
        read_from_debug_network_data  <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_DEBUG_NETWORK_DATA/4);
        read_from_license_flag        <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_LICENSE_FLAG /4);
        read_from_ip_reset            <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_IP_RESET/4);
        read_from_input_filter_reads_lo <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_INPUT_FILTER_READ_COUNT_LO/4);
        read_from_input_filter_reads_hi <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_INPUT_FILTER_READ_COUNT_HI/4);
        read_from_input_feature_reads_lo <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_INPUT_FEATURE_READ_COUNT_LO/4);
        read_from_input_feature_reads_hi <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_INPUT_FEATURE_READ_COUNT_HI/4);
        read_from_output_feature_writes_lo <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_OUTPUT_FEATURE_WRITE_COUNT_LO/4);
        read_from_output_feature_writes_hi <= (ram_rd_addr == DLA_DMA_CSR_OFFSET_OUTPUT_FEATURE_WRITE_COUNT_HI/4);
        read_ready_streaming_interface <= (ram_rd_addr == DLA_CSR_OFFSET_READY_STREAMING_IFACE/4);

        //decode specific addresses in which an action must be taken
        enqueue_descriptor <= (ram_wr_addr == DLA_DMA_CSR_OFFSET_INPUT_OUTPUT_BASE_ADDR/4);
        write_to_ip_reset  <= (ram_wr_addr == DLA_DMA_CSR_OFFSET_IP_RESET/4);
        if (ENABLE_INPUT_STREAMING) begin
            write_ready_streaming_interface <= (ram_wr_addr == DLA_CSR_OFFSET_READY_STREAMING_IFACE/4);
            write_core_streaming_active <= (ram_wr_addr == DLA_DMA_CSR_OFFSET_START_CORE_STREAMING/4);
        end
    end



    /////////////////////
    //  State machine  //
    /////////////////////

    always_ff @(posedge clk_ddr) begin
        //default behavior
        o_csr_rvalid  <= 1'b0;
        o_csr_bvalid  <= 1'b0;
        ram_wr_en     <= 1'b0;
        descriptor_queue_forced_write <= 1'b0;
        descriptor_queue_data         <= 'x;
        debug_network_arvalid <= 1'b0;
        debug_network_rready  <= 1'b0;
        o_request_ip_reset    <= 1'b0;
        o_streaming_active <= o_streaming_active;

        unique case (1'b1)
        state[STATE_GET_READY_BIT]: begin
            o_csr_awready <= ~pending_write_address && (~pending_reset || (pending_reset && pending_write_data));
            o_csr_wready  <= ~pending_write_data    && (~pending_reset || (pending_reset && pending_write_address));
            o_csr_arready <= ~pending_read          && ~pending_reset;
            state <= STATE_READY;
        end

        state[STATE_READY_BIT]: begin
          state <= STATE_READY;
          if (i_csr_arvalid && o_csr_arready) begin
            csr_read_addr <= i_csr_araddr[CSR_ADDR_WIDTH-1:CSR_LO_ADDR];
            o_csr_arready <= 1'b0;
            pending_read <= 1'b1;
            // Also stop listening to writes
            o_csr_awready <= 1'b0;
            o_csr_wready <= 1'b0;
          end
          if (pending_read) begin
            state <= STATE_READ_ADDR;
            o_csr_arready <= 1'b0;
            o_csr_wready  <= 1'b0;
            o_csr_awready <= 1'b0;
            previous_was_write <= 1'b0;
            pending_read <= 1'b0;
            ram_rd_addr <= csr_read_addr;
          end

          if (i_csr_awvalid && o_csr_awready) begin
            ram_wr_addr <= i_csr_awaddr[CSR_ADDR_WIDTH-1:CSR_LO_ADDR];
            o_csr_awready <= 1'b0;
            pending_write_address <= 1'b1;
            // Also stop listening to reads
            o_csr_arready <= 1'b0;
          end
          if (i_csr_wvalid && o_csr_wready) begin
            ram_wr_data <= i_csr_wdata;
            o_csr_wready <= 1'b0;
            pending_write_data <= 1'b1;
            // Also stop listening to reads
            o_csr_arready <= 1'b0;
          end
          if (pending_write_address && pending_write_data) begin
            // This previous_was_write check ensures fairness when servicing simultaneous / queued requests
            if (!previous_was_write || !pending_read) begin
              state <= STATE_WRITE_COMMIT;
              previous_was_write <= 1'b1;
              o_csr_arready <= 1'b0;
              o_csr_wready  <= 1'b0;
              o_csr_awready <= 1'b0;
              pending_write_address <= 1'b0;
              pending_write_data <= 1'b0;

              // This write is overwriting the pending read
              if (pending_read) begin
                pending_read <= pending_read;
              end
            end
          end
        end

        state[STATE_READ_ADDR_BIT]: begin
            state <= STATE_READ_INTERNAL;
            ram_rd_addr <= csr_read_addr;
        end
        state[STATE_READ_INTERNAL_BIT]: begin
            // hardened input register inside m20k valid now
            state <= STATE_READ_DATA;
            ram_rd_addr <= csr_read_addr;
        end
        state[STATE_READ_DATA_BIT]: begin
            // hardened output register inside m20k valid now
            o_csr_rvalid <= 1'b1;
            o_csr_rdata <= ram_rd_data;
            if (read_from_interrupt_control) begin
                o_csr_rdata <= '0;
                o_csr_rdata[DLA_DMA_CSR_INTERRUPT_ERROR_BIT] <= interrupt_control_error;
                o_csr_rdata[DLA_DMA_CSR_INTERRUPT_DONE_BIT]  <= interrupt_control_done;
            end
            if (read_from_interrupt_mask) begin
                o_csr_rdata <= '0;
                o_csr_rdata[DLA_DMA_CSR_INTERRUPT_ERROR_BIT] <= interrupt_mask_error;
                o_csr_rdata[DLA_DMA_CSR_INTERRUPT_DONE_BIT]  <= interrupt_mask_done;
            end
            if (read_from_desc_diagnostics) begin
                o_csr_rdata <= '0;
                o_csr_rdata[DLA_DMA_CSR_DESC_DIAGNOSTICS_OVERFLOW_BIT]    <= descriptor_diagnostics_overflow;
                o_csr_rdata[DLA_DMA_CSR_DESC_DIAGNOSTICS_ALMOST_FULL_BIT] <= descriptor_diagnostics_almost_full;
                o_csr_rdata[DLA_DMA_CSR_DESC_DIAGNOSTICS_OUT_OF_INFERENCES_BIT] <= i_token_out_of_inferences;
            end
            if (read_from_completion_count) o_csr_rdata <= completion_count;
            if (read_from_clocks_active_lo) o_csr_rdata <= total_clocks_active_lo;
            if (read_from_clocks_active_hi) o_csr_rdata <= total_clocks_active_hi;
            if (read_from_core_clocks_active_lo) o_csr_rdata <= total_core_clocks_active_lo;
            if (read_from_core_clocks_active_hi) o_csr_rdata <= total_core_clocks_active_hi;
            if (read_from_clocks_all_jobs_lo) o_csr_rdata <= total_clocks_for_all_jobs_lo;
            if (read_from_clocks_all_jobs_hi) o_csr_rdata <= total_clocks_for_all_jobs_hi;
            if (read_from_input_feature_reads_lo) o_csr_rdata <= number_of_input_feature_reads_lo;
            if (read_from_input_feature_reads_hi) o_csr_rdata <= number_of_input_feature_reads_hi;
            if (read_from_input_filter_reads_lo) o_csr_rdata <= number_of_input_filter_reads_lo;
            if (read_from_input_filter_reads_hi) o_csr_rdata <= number_of_input_filter_reads_hi;
            if (read_from_output_feature_writes_lo) o_csr_rdata <= number_of_output_feature_writes_lo;
            if (read_from_output_feature_writes_hi) o_csr_rdata <= number_of_output_feature_writes_hi;
            if (read_from_debug_network_valid) o_csr_rdata <= debug_network_rvalid; //read prefetch after dcfifo has valid data
            if (read_from_debug_network_data) begin
                o_csr_rdata <= debug_network_rdata; //read prefetch after dcfifo
                debug_network_rready <= 1'b1;       //rdack the read prefetch
            end
            if (read_from_license_flag) o_csr_rdata <= i_license_flag;
            if (read_from_ip_reset)     o_csr_rdata <= '0; //this read will always return 0
            if (read_ready_streaming_interface) o_csr_rdata <= o_streaming_active;

            if (o_csr_rvalid && i_csr_rready) begin
                o_csr_rvalid <= 1'b0;
                state <= STATE_GET_READY;
                if (pending_reset && !(pending_write_address || pending_write_data || pending_read)) begin
                  state <= STATE_AWAIT_RESET;
                end
            end
        end
        state[STATE_WRITE_COMMIT_BIT]: begin
            //write_to_ram valid now
            ram_wr_en <= write_to_ram;
            if (write_to_interrupt_control) begin   //write 1 to clear
                if (ram_wr_data[DLA_DMA_CSR_INTERRUPT_ERROR_BIT]) interrupt_control_error <= 1'b0;
                if (ram_wr_data[DLA_DMA_CSR_INTERRUPT_DONE_BIT])  interrupt_control_done  <= 1'b0;
            end
            if (write_to_interrupt_mask) begin
                interrupt_mask_error <= ram_wr_data[DLA_DMA_CSR_INTERRUPT_ERROR_BIT];
                interrupt_mask_done  <= ram_wr_data[DLA_DMA_CSR_INTERRUPT_DONE_BIT];
            end
            if (write_to_debug_network_addr) begin
                //don't care if dcfifo is full, handshaking scheme is already tolerant to debug network not responding to requests
                debug_network_arvalid <= 1'b1;
                debug_network_araddr  <= ram_wr_data;
            end
            if (write_core_streaming_active) begin
                if (ram_wr_data == '0) o_core_streaming_active <= 1'b0;
                else o_core_streaming_active <= 1'b1;
            end
            if (write_to_ip_reset) begin
              pending_reset <= (ram_wr_data != '0);
            end
            o_csr_bvalid <= 1'b1;
            if (o_csr_bvalid && i_csr_bready) begin
                o_csr_bvalid <= 1'b0;
                state <= STATE_GET_READY;
                if (enqueue_descriptor) begin
                  state <= STATE_DESCRIPTOR;
                end else if (pending_reset && !(pending_read || pending_write_data || pending_write_address)) begin
                  state <= STATE_AWAIT_RESET;
                end else if (write_ready_streaming_interface) begin
                    if (ram_wr_data == 1) begin
                        if (~ENABLE_ON_CHIP_PARAMETERS) state <= STATE_DESCRIPTOR;
                        o_streaming_active <= 1'b1;
                    end else begin
                        o_streaming_active <= 1'b0;
                    end
                end
            end
            descriptor_count <= 0;
        end

        state[STATE_DESCRIPTOR_BIT]: begin
            descriptor_count <= descriptor_count + 1'b1;
            case (descriptor_count)
            4'h0: ram_rd_addr <= DLA_DMA_CSR_OFFSET_CONFIG_BASE_ADDR/4;         //addr gen 0: config reader base addr
            4'h1: ram_rd_addr <= 'x;                                            //addr gen 1: token
            4'h2: ram_rd_addr <= DLA_DMA_CSR_OFFSET_CONFIG_RANGE_MINUS_TWO/4;   //addr gen 2: config reader num words minus two
            4'h3: ram_rd_addr <= 'x;                                            //addr gen 3: addr update
            4'h4: ram_rd_addr <= DLA_DMA_CSR_OFFSET_CONFIG_RANGE_MINUS_TWO/4;   //intercept 0: config reader num words minus two
            4'h5: ram_rd_addr <= DLA_DMA_CSR_OFFSET_CONFIG_BASE_ADDR/4;         //intercept 1: filter reader offset correction
            4'h6: ram_rd_addr <= DLA_DMA_CSR_OFFSET_INPUT_OUTPUT_BASE_ADDR/4;   //intercept 2: feature input/output offset
            4'h7: ram_rd_addr <= DLA_DMA_CSR_OFFSET_INTERMEDIATE_BASE_ADDR/4;   //intercept 3: feature intermediate offset
            default: ram_rd_addr <= 'x;
            endcase

            //there are 3 clocks of latency from the time ram_rd_addr is set until ram_rd_data is valid
            //This is why the config_reader struct in the dma/dual_inc folder has to be laid out in that order
            case (descriptor_count)
            4'h3: descriptor_queue_data <= {1'b0, ram_rd_data};         //addr gen 0: config reader base addr
            4'h4: descriptor_queue_data <= '0;                          //addr gen 1: token
            4'h5: descriptor_queue_data <= {1'b0, ram_rd_data};         //addr gen 2: config reader num words minus two
            4'h6: descriptor_queue_data <= CONFIG_READER_DATA_BYTES;    //addr gen 3: addr update
            4'h7: descriptor_queue_data <= {1'b1, ram_rd_data};         //intercept 0: config reader num words minus two
            4'h8: descriptor_queue_data <= {1'b1, ram_rd_data};         //intercept 1: filter reader offset correction
            4'h9: descriptor_queue_data <= {1'b1, ram_rd_data};         //intercept 2: feature input/output offset
            4'ha: descriptor_queue_data <= {1'b1, ram_rd_data};         //intercept 3: feature intermediate offset
            default: descriptor_queue_data <= 'x;
            endcase

            descriptor_queue_forced_write <= (descriptor_count >= 4'h3);
            if (descriptor_count == 4'ha) state <= STATE_GET_READY;
        end

        state[STATE_AWAIT_RESET_BIT]: begin
            //reset request was triggered by a CSR write
            // -we completed the axi4-lite write response handshake in STATE_WRITE_COMMIT
            // -we don't want to return to STATE_GET_READY, since a new transaction might get initiated and then interrupted when reset hits
            // -we should assert o_request_ip_reset for multiple cycles to ensure the async signal is synchronized into all clock domains
            //so, just hang out here and wait for reset
            o_request_ip_reset <= 1'b1;
            state <= STATE_AWAIT_RESET;
        end

        default: begin
            state <= STATE_GET_READY;
        end
        endcase

        //completion tracking
        completion_count <= completion_count + i_token_done;

        //interrupt tracking
        if (i_token_error) interrupt_control_error <= 1'b1;
        if (i_token_done)  interrupt_control_done  <= 1'b1;

        //sticky bit for detecting if descriptor queue has overflowed
        if (descriptor_queue_forced_write & descriptor_queue_full) descriptor_diagnostics_overflow <= 1'b1;

        if (~i_sclrn_ddr) begin
            //state
            state                 <= STATE_GET_READY;
            previous_was_write    <= 1'b0;
            pending_read          <= 1'b0;
            pending_write_address <= 1'b0;
            pending_write_data    <= 1'b0;
            pending_reset         <= 1'b0;


            //AXI4-lite outputs to host control
            o_csr_arready <= 1'b0;
            o_csr_rvalid  <= 1'b0;
            o_csr_awready <= 1'b0;
            o_csr_wready  <= 1'b0;
            o_csr_bvalid  <= 1'b0;

            //ram
            ram_wr_en   <= 1'b0;

            //specific offsets implemented in registers
            interrupt_control_error <= 1'b0;
            interrupt_control_done  <= 1'b0;
            interrupt_mask_error    <= 1'b0;
            interrupt_mask_done     <= 1'b0;
            completion_count        <= '0;
            descriptor_diagnostics_overflow <= 1'b0;

            //descriptor queue
            descriptor_queue_forced_write <= 1'b0;

            //debug network
            debug_network_arvalid <= 1'b0;
            debug_network_rready  <= 1'b0;

            // stops streaming reload
            o_streaming_active <= 1'b0;

            // set dla core to stream unless 0 is written
            o_core_streaming_active <= 1'b1;
        end
    end



    //////////////////////////////////////////////////////////
    //  Bring the level interrupt to the host clock domain  //
    //////////////////////////////////////////////////////////

    always_ff @(posedge clk_ddr) begin
        ddr_interrupt_level <= 1'b0;
        if (interrupt_mask_error & interrupt_control_error) ddr_interrupt_level <= 1'b1;
        if (interrupt_mask_done  & interrupt_control_done ) ddr_interrupt_level <= 1'b1;
    end

    //this is a 3-stage register-based synchonizer
    dla_clock_cross_full_sync dla_clock_cross_sync
    (
        .clk_src            (clk_ddr),
        .i_src_async_resetn (1'b1),
        .i_src_data         (ddr_interrupt_level),
        .o_src_data         (),

        .clk_dst            (clk_pcie),
        .i_dst_async_resetn (1'b1),
        .o_dst_data         (o_interrupt_level)
    );



    ///////////////////////////
    //  Clock crossing FIFOS //
    ///////////////////////////

    localparam int DCFIFO_DEPTH = 32;   //dcfifo is RAM-based, may as well use an entire MLAB

    dla_acl_dcfifo #(
        .WIDTH                      (8*CSR_DATA_BYTES),
        .DEPTH                      (DCFIFO_DEPTH)
    )
    clock_cross_debug_network_request
    (
        .async_resetn               (i_resetn_async),   //reset synchronization is handled internally

        //write side -- write is ignored if fifo is full, this is okay since debug network handshaking is fault tolerant
        .wr_clock                   (clk_ddr),
        .wr_req                     (debug_network_arvalid),
        .wr_data                    (debug_network_araddr),

        //read side
        .rd_clock                   (clk_dla),
        .rd_empty                   (not_o_debug_network_arvalid),
        .rd_data                    (o_debug_network_araddr),
        .rd_ack                     (i_debug_network_arready)
    );
    assign o_debug_network_arvalid = ~not_o_debug_network_arvalid;

    dla_acl_dcfifo #(
        .WIDTH                      (8*CSR_DATA_BYTES),
        .DEPTH                      (DCFIFO_DEPTH)
    )
    clock_cross_debug_network_response
    (
        .async_resetn               (i_resetn_async),   //reset synchronization is handled internally

        //write side
        .wr_clock                   (clk_dla),
        .wr_req                     (i_debug_network_rvalid),
        .wr_data                    (i_debug_network_rdata),
        .wr_full                    (not_o_debug_network_rready),

        //read side
        .rd_clock                   (clk_ddr),
        .rd_empty                   (debug_network_dcfifo_empty),
        .rd_data                    (debug_network_dcfifo_data),
        .rd_ack                     (~debug_network_dcfifo_empty)    //consume read data immediately, cached in a read prefetch
    );
    assign o_debug_network_rready = ~not_o_debug_network_rready;

    //cache the most recent value returned from the debug network
    always_ff @(posedge clk_ddr) begin
        if (~debug_network_dcfifo_empty) begin
            debug_network_rdata <= debug_network_dcfifo_data;
            debug_network_rvalid <= 1'b1;
        end
        if (debug_network_rready) begin
            debug_network_rvalid <= 1'b0;
        end
        if (~i_sclrn_ddr) begin
            debug_network_rvalid <= 1'b0;
        end
    end

endmodule
