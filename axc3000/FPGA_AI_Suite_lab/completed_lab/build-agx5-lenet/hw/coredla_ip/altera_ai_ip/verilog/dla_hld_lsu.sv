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

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//                                                                                                                                                                        //
//  HLD LSU                                                                                                                                                               //
//  Architected and implemented by: Jason Thong                                                                                                                           //
//                                                                                                                                                                        //
//  This is the top-level module for the core LSU. While dla_hld_global_load_store is a wrapper that deals with width adaption and cache, dla_hld_lsu implements the core LSU     //
//  itself. There is almost no logic in this module, the LSU has been split up into components and dla_hld_lsu must just connects those components together.                  //
//                                                                                                                                                                        //
//  A brief descrption of the major components:                                                                                                                           //
//                                                                                                                                                                        //
//  Input fifo:                                                                                                                                                           //
//    - kernel upstream data (including address, byte enable, etc.) is store here until we can figure out how this will get converted into avalon                         //
//    - there are separate fifos for word address (which feeds the burst coalescer), data and byte enable (these two feed the write data alignment)                       //
//  Word coalescer:                                                                                                                                                       //
//    - looks at the bottom bits of the kernel upstream address to determine if coalescing within a memory word can happen                                                //
//    - also determines a bunch of information like how many memory words each kernel word spans, this feeds the unaligned controller                                     //
//    - can optionally be bypassed, e.g. to save area if one knows the access pattern is going to be random access                                                        //
//  Unaligned controller:                                                                                                                                                 //
//    - given info from the word coalescer, report which section of the kernel word is being processed, among other state information                                     //
//  Burst coaleser:                                                                                                                                                       //
//    - after the unaligned controller but before the avalon memory interface, look for consecutive word addresses and form a burst                                       //
//    - can optionally be bypassed                                                                                                                                        //
//  Write data aligner (write LSU only):                                                                                                                                  //
//    - the unaligned controller indicates how to transform kernel upstream data into avalon write data, apply this to the data path in a pipelined manner                //
//    - one can adjust the amount of pipelining in the barrel shifter for data alignment                                                                                  //
//  Write kernel downstream (write LSU only):                                                                                                                             //
//    - for each writeack that arrives, determine how many valids can be released to kernel downstream                                                                    //
//  Read data alignment (read LSU only):                                                                                                                                  //
//    - the output from the word coalescer is put into a fifo so that when a memory arrives, we will know how to transform it into kernel downstream data                 //
//    - one kernel word may span multiple memory words, so another instance of the unaligned controller is used to track the progress of assembling one kernel word       //
//                                                                                                                                                                        //
//  Key features of the LSU:                                                                                                                                              //
//                                                                                                                                                                        //
//  Support for arbitrary alignment when accessing memory:                                                                                                                //
//    - the core LSU allows up one kernel word to span up to 3 memory words, this is enforced by ensuring the kernel width is no more than twice the memory width,        //
//        beyond this one must use kernel width adaption in the wrapper (note that kernel width adaption can be used at any width, even narrow widths)                    //
//    - based on kernel width, memory width, and address alignment, there is some static analysis to determine the max number of memory words that a kernel word can      //
//        span, some logic is trimmed away if we are guaranteed that a kernel word can only span 1 or 2 memory words                                                      //
//  Configurable amount of pipelining in data aligner barrel shifter                                                                                                      //
//    - controlled by the DATA_ALIGNER_MUX_PER_PIPE parameter, if this is 0 then use combinational logic                                                                  //
//    - otherwise this indicates how many 2:1 muxes per pipeline stage, e.g. if the value is 3 then will have up to 8:1 mux between pipeline registers                    //
//    - the amount of shifting is based on the kernel width, memory width, and address alignment, it is not exposed to since the LSU was designed for arbitrary delay     //
//        through the data aligner, one can only control how often to pipeline, but not the total amount of pipelining                                                    //
//  Optional coalescing with dynamic timeout:                                                                                                                             //
//    - word coalescing and burst coalescing are two independent and optional features                                                                                    //
//    - when used, each coalescer has its own timeout, cannot wait forever for the next transaction in the hope that it will coalesce with the current transaction        //
//    - the timeout threshold is dynamic, it increases if coalescing could have happened but timed out, it decreases if lots of random access                             //
//  High throughput mode:                                                                                                                                                 //
//    - if a kernel word spans N memory words where N >= 2, the kernel word can be processed over N clock cycles (low throughput mode) or the minimum number of clock     //
//        cycles (high throughput mode), note that high throughput mode uses more area because it has to keep more data live in registers                                 //
//    - this feature only matters if a kernel word uses unaligned access, the LSU will never waste time if a kernel word happens to fit inside one memory word            //
//    - as an example to illustrate the performance of high throughput mode, suppose the kernel width and memory width are the same but there is an address offset, even  //
//        for sequential access low throughput mode will take 2 clocks per kernel word, but high throughput mode will take M+1 clocks for a total of M words              //
//    - if kernel width is significantly smaller than memory width, probably best to use low throughput mode since few kernel words will span many memory words           //
//                                                                                                                                                                        //
//  Non-configurable properties:                                                                                                                                          //
//    - for write LSU, writeack support is forced on in the core LSU, but there is a no writeack shortcut in the wrapper dla_hld_global_load_store.sv for legacy support      //
//    - capacity of the LSU is fixed, compiler cannot choose fifo depths, usually obvious whether a fifo should be MLAB or M20K, may as well use all the memory           //
//                                                                                                                                                                        //
//  Not yet implemented:                                                                                                                                                  //
//    - ECC memory (fifos and cache)                                                                                                                                      //
//    - profiler                                                                                                                                                          //
//                                                                                                                                                                        //
//  Required files:                                                                                                                                                       //
//  - LSU:   dla_hld_global_load_store.sv dla_hld_lsu.sv dla_hld_lsu_burst_coalescer.sv dla_hld_lsu_coalescer_dynamic_timeout.sv dla_hld_lsu_data_aligner.sv dla_hld_lsu_read_cache.sv            //
//           dla_hld_lsu_read_data_alignment.sv dla_hld_lsu_unaligned_controller.sv dla_hld_lsu_word_coalescer.sv dla_hld_lsu_write_data_alignment.sv dla_hld_lsu_write_kernel_downstream.sv  //
//  - fifo:  dla_hld_fifo.sv dla_acl_low_latency_fifo.sv dla_acl_mid_speed_fifo.sv dla_acl_lfsr.sv dla_acl_tessellated_incr_decr_threshold.sv                                                 //
//  - other: dla_acl_parameter_assert.svh dla_acl_reset_handler.sv dla_acl_burst_splitter.sv dla_acl_shift_register_no_reset.sv                                                           //
//                                                                                                                                                                        //
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module dla_hld_lsu #(
    //LSU type
    parameter bit READ,                         //0 = write lsu, 1 = read lsu

    //reset configuration, the reset is always synchronized before consumption (no option to disable this), but once synchronized one may choose how registers consume that synchronized reset
    parameter bit ASYNC_RESET,                  //0 = registers consume reset synchronously, 1 = registers consume reset asynchronously

    //address, shared between kernel interface and memory interface
    parameter int ADDR_WIDTH,                   //width of address bus, for addresses that are byte addresses
    parameter int ADDR_ALIGNMENT_BITS,          //indicates how many least significant bits of i_address are known to be 0, e.g. set this parameter to 3 if kernel accesses are 8-byte aligned
    parameter int INTRA_ADDR_WIDTH,             //how many least significant bits of the byte address represent the location inside a memory word
    parameter int WORD_ADDR_WIDTH,              //how many most significant bits of the byte address represent which memory word is being accessed

    //kernel interface
    parameter int KER_DATA_BYTES,               //width of kernel data path in bytes, does not need to be a power of 2
    parameter int KER_DATA_BYTES_LAST,          //in case width adaption is used in dla_hld_global_load_store, the last slice of the kernel data path may be smaller

    //memory interface
    parameter int MEM_DATA_BYTES,               //width of memory data path in bytes, must be a power of 2
    parameter int BURSTCOUNT_WIDTH,             //width of avalon burst count signal, max burst size is 2**(BURSTCOUNT_WIDTH-1)

    //stall latency
    parameter int KER_UP_STALL_LATENCY,         //0 = use stall/valid, 1 or larger = use stall latency and the value indicates the upstream roundtrip latency (from o_stall to i_valid)
    parameter int KER_DOWN_STALL_LATENCY,       //0 = use stall/valid, 1 or larger = use stall latency and the value indicates the downstream roundtrip latency (from i_stall to o_valid)

    //amount of pipelining in data aligner
    parameter int DATA_ALIGNER_MUX_PER_PIPE,    //0 = use comb logic for data alignment mux, 1 or more = max number of 2:1 muxes before a pipeline stage is added, e.g. 2 means up to 4:1 mux between reg

    //coalescing
    parameter bit ENABLE_WORD_COALESCE,         //whether to coalesce kernel words together within the same memory word
    parameter bit ENABLE_BURST_COALESCE,        //whether to coalesce sequential memory words together to make a burst, feature will be disabled (parameter value ignored) if width adaption on the memory interface is used

    //reduce area if certain functionality is not needed
    parameter bit USE_PREDICATE,                //set to 0 if i_predicate is always 0, this will save some area
    parameter bit USE_BYTE_ENABLE,              //set to 0 if i_byteenable is always all ones, this will save some area, only write LSU consumes this parameter

    //throughput features
    parameter bit HIGH_THROUGHPUT_MODE,         //0 = use N clock cycles to process a kernel word that spans N memory words, 1 = use minimum amount of time to process kernel words, only matters if N >= 2
    parameter int CACHE_SIZE_BYTES,             //0 = no cache, otherwise this specifies the cache size in bytes which must be a power of 2, this can only be used with the read LSU

    //global memory interface selection
    parameter bit USE_AXI,                      //0 = use AvalonMM, 1 = use AXI
    parameter int ADDR_ADAPT_WIDTH,             //if width adaption is done on the global memory interface, how many word address LSBs are needed in AXI write data channel to indicate how to width adapt

    //static analysis from dla_hld_global_load_store
    parameter int MAX_MEM_WORDS_PER_KER_WORD,   //trim some logic if it is guaranteed that each kernel word can only span 1 or 2 memory words

    //special constants -- these are chosen in dla_hld_global_load_store.sv
    parameter int MLAB_FIFO_DEPTH,              //use a shallow fifo if handshaking is expected to take a few clocks (or if capacity can be borrowed from a nearby deep fifo), if we need an MLAB may as well use all of it
    parameter int M20K_WIDE_FIFO_DEPTH,         //use a deep fifo if handshaking is expected to take hundreds of clocks e.g. going off chip, for wide data path use M20K in shallowest mode, but may as well use all depth available
    parameter int M20K_NARROW_FIFO_DEPTH,       //if we need a deep fifo but the data path is narrow e.g. up to 10 bits which is the narrowest M20K on S10, can get additional depth for without needing more M20K
    parameter int TOTAL_OCC_LIMIT,              //loose upper bound on the maximum number of threads allowed inside the LSU at any time, this bounds the counter width for o_active
    parameter int WRITEACK_WIDTH,               //writeack fifo indicate how many valids to release upon writeack, it uses narrow m20k, word coalescer stops to ensure value doesn't overflow narrow m20k width
    parameter int WORD_COAL_MAX_TIMEOUT_BIT,    //limit how large the dynamic timeout threshold can get inside word coalescer
    parameter int BURST_COAL_MAX_TIMEOUT_BIT    //limit how large the dynamic timeout threshold can get inside burst coalescer
) (
    input  wire                             clock,
    input  wire                             resetn,

    //o_active and i_flush_cache are handled by dla_hld_global_load_store

    //kernel upstream
    input  wire                             i_valid,                //kernel upstream has a transaction available, LSU can but does not need to accept it if using stall valid, must accept it if using stall latency
    output logic                            o_stall,                //backpressure to kernel upstream
    input  wire            [ADDR_WIDTH-1:0] i_address,              //byte address, where should data be written to or read from in memory
    input  wire      [8*KER_DATA_BYTES-1:0] i_writedata,            //data to write to memory, only used by write LSU
    input  wire        [KER_DATA_BYTES-1:0] i_byteenable,           //byte enable for the write data, only used by write LSU
    input  wire                             i_predicate,            //if 1 then don't perform the read or write, but still need to release this thread later on o_valid
    input  wire                             i_more_wide_sections,   //if using kernel width adaptation, this indicates there are more sections of the same kernel word still to come

    //kernel downstream
    output logic                            o_valid,                //LSU has a transaction available, kernel downstream can but does not need to accept it if using stall valid, must accept it if using stall latency
    input  wire                             i_stall,                //backpressure from kernel downstream
    output logic     [8*KER_DATA_BYTES-1:0] o_readdata,             //data read from memory, only used by read LSU
    output logic                            o_empty,                //LSU does not have a transaction available for kernel downstream, meant to be used with stall latency
    output logic                            o_almost_empty,         //LSU downstream interface does not have at least KER_DOWN_STALL_LATENCY transactions ready to be released

    //memory interface, shared with axi and avalon
    //for read LSU, axi and avalon have a natural mapping
    //for write LSU, avalon only has a single stall/valid control flow which maps to the axi write data channel, the axi write address channel control flow uses the other set of signals in the group below
    output logic                            avm_write,              //avalon write request, accepted only if ~avm_waitrequest
    output logic                            avm_read,               //avalon read request, accepted only if ~avm_waitrequest
    output logic           [ADDR_WIDTH-1:0] avm_address,            //byte address, avalon spec says this must be word aligned (the bottom bits for within a memory word must be 0)
    output logic     [BURSTCOUNT_WIDTH-1:0] avm_burstcount,         //how large is the burst, tied to 1 if burst coalescing is not used
    output logic     [8*MEM_DATA_BYTES-1:0] avm_writedata,          //data to write to memory, only used by write LSU
    output logic       [MEM_DATA_BYTES-1:0] avm_byteenable,         //byte enable for the write data, only used by write LSU
    input  wire                             avm_waitrequest,        //avalon backpressure
    input  wire                             avm_writeack,           //write has commited to memory, this must assert once per memory word (not one per burst like the avalon spec), only used by write LSU
    input  wire                             avm_readdatavalid,      //if using read cache LSU can backpressure the read data so this means cache has data available, else not using read cache so LSU must accept read data
    input  wire      [8*MEM_DATA_BYTES-1:0] avm_readdata,           //data read from memory, only used by read LSU
    output logic                            avm_readdata_accepted,  //if using read cache, this is how the LSU indicates to the cache that it consumed the read data

    //additional signals needed for write LSU using AXI, need control flow for axi write address channel, also need the axi last signal
    output logic                            axi_awvalid,            //write request for the axi write address channel
    input  wire                             axi_awready,            //no backpressure for the axi write address channel
    output logic       [ADDR_ADAPT_WIDTH:0] axi_last                //MSBs = some bits of address for width adaptation, LSB = axi last which indicates this word is the last in a burst
);


    ///////////////
    //  Signals  //
    ///////////////

    //reset
    logic                           aclrn, sclrn, resetn_synchronized;

    //predication
    logic                           valid_in_not_predicated;
    logic                           predicate_fifo_wr_req, predicate_fifo_almost_full, predicate_fifo_empty, predicate_fifo_rd_ack;
    logic                           predicate_fifo_wr_data, predicate_fifo_rd_data;

    //input fifos
    logic                           input_wordaddr_fifo_almost_full, input_writedata_fifo_almost_full, input_fifo_almost_full;
    logic                           input_wordaddr_fifo_rd_ack, input_writedata_fifo_rd_ack, input_byteenable_fifo_rd_ack;
    logic    [8*KER_DATA_BYTES-1:0] input_writedata_fifo_rd_data;
    logic      [KER_DATA_BYTES-1:0] input_byteenable_fifo_rd_data;
    logic     [WORD_ADDR_WIDTH-1:0] input_wordaddr_fifo_rd_data;

    //word coalescer
    logic                           cmd_fifo_empty;
    logic                           cmd_more_wide_sections, cmd_needs_second_cycle, cmd_needs_third_cycle, cmd_spans_two, cmd_spans_three, cmd_can_coalesce;
    logic    [INTRA_ADDR_WIDTH-1:0] cmd_addr, cmd_addr_modulo;

    //unaligned controller
    logic                           downstream_of_cmd_almost_full, can_read_cmd_fifo, cmd_fifo_rd_ack;
    logic                           cmd_at_second_cycle, cmd_at_third_cycle, cmd_is_coalescing, cmd_first_access_in_word;

    //burst coalescer
    logic                           burstcoal_valid;
    logic                     [1:0] burstcoal_add_to_base_addr;
    logic     [WORD_ADDR_WIDTH-1:0] burstcoal_word_addr;
    logic                           burstcoal_almost_full, disable_coalescer_timeout;
    logic                           avm_ctrl_fifo_empty, avm_ctrl_fifo_rd_ack;
    logic     [WORD_ADDR_WIDTH-1:0] avm_word_address;
    logic                           burstcoal_snoop_valid;
    logic    [BURSTCOUNT_WIDTH-1:0] burstcoal_snoop_burstsize;
    logic                           axi_last_fifo_empty, axi_last_fifo_rd_ack;
    logic      [ADDR_ADAPT_WIDTH:0] axi_last_fifo_rd_data;

    //avm request interface
    logic                           avm_wr_data_fifo_almost_full, avm_wr_data_fifo_empty, avm_wr_data_fifo_rd_ack;

    //avm response interface
    logic                           writeack_fifo_almost_full, avm_rd_data_fifo_almost_full, rsp_fifo_almost_full;



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



    ///////////////////
    //  Predicattion //
    ///////////////////

    // predicated transactions bypass the word coalescer and the input fifos (and therefore will never make it to the memory interface)
    // for the write LSU, predication is added back in after writeack and just before the kernel downstream interface, look inside dla_hld_lsu_write_kernel_downstream
    // for the read LSU, predication is added back after the avm_rd_data_fifo but before the output fifo (garbage data is written into the output fifo for a predicated transaction)

    assign valid_in_not_predicated = i_valid & ~i_predicate;
    assign predicate_fifo_wr_req = i_valid;
    assign predicate_fifo_wr_data = i_predicate;

    assign o_stall = input_fifo_almost_full | predicate_fifo_almost_full;

    generate
    if (USE_PREDICATE) begin : GEN_PREDICATE
        logic temp_data, temp_valid, temp_stall;

        dla_hld_fifo #(
            .WIDTH                      (1),
            .DEPTH                      (M20K_NARROW_FIFO_DEPTH),
            .NEVER_OVERFLOWS            (1),
            .ALMOST_FULL_CUTOFF         (KER_UP_STALL_LATENCY),
            .ASYNC_RESET                (ASYNC_RESET),
            .SYNCHRONIZE_RESET          (0),
            .STYLE                      ("ms")
        )
        predicate_fifo_ms_inst
        (
            .clock                      (clock),
            .resetn                     (resetn_synchronized),
            .i_valid                    (predicate_fifo_wr_req),
            .i_data                     (predicate_fifo_wr_data),
            .o_stall                    (),
            .o_almost_full              (predicate_fifo_almost_full),
            .o_valid                    (temp_valid),
            .o_data                     (temp_data),
            .i_stall                    (temp_stall),
            .o_almost_empty             (),
            .o_empty                    (),
            .ecc_err_status             ()
        );

        //prefetch into a 2-deep register based fifo, this eases placement since data now comes from an ALM register rather than M20K hardened read data register
        //also the rd ack going to the m20k based fifo will be registered since it is now driven by o_stall of the llreg fifo
        dla_hld_fifo #(
            .REGISTERED_DATA_OUT_COUNT  (1),
            .WIDTH                      (1),
            .DEPTH                      (2),
            .ASYNC_RESET                (ASYNC_RESET),
            .SYNCHRONIZE_RESET          (0),
            .STYLE                      ("llreg")
        )
        predicate_fifo_ll_inst
        (
            .clock                      (clock),
            .resetn                     (resetn_synchronized),
            .i_valid                    (temp_valid),
            .i_data                     (temp_data),
            .o_stall                    (temp_stall),
            .o_almost_full              (),
            .o_valid                    (),
            .o_data                     (predicate_fifo_rd_data),
            .i_stall                    (~predicate_fifo_rd_ack),
            .o_almost_empty             (),
            .o_empty                    (predicate_fifo_empty),
            .ecc_err_status             ()
        );
    end
    else begin : NO_PREDICATE
        //this is necessary to limit the total occupancy through the lsu so that the counter for o_active doesn't overflow
        dla_acl_tessellated_incr_decr_threshold #(
            .CAPACITY                   (M20K_NARROW_FIFO_DEPTH),
            .THRESHOLD                  (M20K_NARROW_FIFO_DEPTH-KER_UP_STALL_LATENCY),
            .INITIAL_OCCUPANCY          (0),
            .THRESHOLD_REACHED_AT_RESET (1),
            .ASYNC_RESET                (ASYNC_RESET),
            .SYNCHRONIZE_RESET          (0)
        )
        predicate_fifo_almost_full_inst
        (
            .clock                      (clock),
            .resetn                     (resetn_synchronized),
            .incr_no_overflow           (predicate_fifo_wr_req),
            .incr_raw                   (predicate_fifo_wr_req),
            .decr_no_underflow          (predicate_fifo_rd_ack),
            .decr_raw                   (predicate_fifo_rd_ack),
            .threshold_reached          (predicate_fifo_almost_full)
        );

        //downstream doesn't try to read from predicate fifo unless there is also stuff in the writeack or rsp fifo
        //guaranteed that the corresponding thread will be readable from the predicate fifo before being readable from write or rsp fifo
        assign predicate_fifo_empty = 1'b0;
        assign predicate_fifo_rd_data = 1'b0;
    end
    endgenerate



    ///////////////////
    //  Input FIFOs  //
    ///////////////////

    //this is temporary storage while we figure out which kernel words can coalesce into the same memory word
    //these exist as separate fifos because they are read at different times, minimize area by minimizing the number of pipeline stages that data needs to be kept live

    dla_hld_fifo #(
        .WIDTH                  (WORD_ADDR_WIDTH),
        .DEPTH                  (MLAB_FIFO_DEPTH),
        .NEVER_OVERFLOWS        (1),
        .ALMOST_FULL_CUTOFF     (KER_UP_STALL_LATENCY),
        .ASYNC_RESET            (ASYNC_RESET),
        .SYNCHRONIZE_RESET      (0),
        .STYLE                  ("ms")
    )
    input_wordaddr_fifo_inst
    (
        .clock                  (clock),
        .resetn                 (resetn_synchronized),
        .i_valid                (valid_in_not_predicated),
        .i_data                 (i_address[ADDR_WIDTH-1:INTRA_ADDR_WIDTH]),
        .o_stall                (),
        .o_almost_full          (input_wordaddr_fifo_almost_full),
        .o_valid                (),
        .o_data                 (input_wordaddr_fifo_rd_data),
        .i_stall                (~input_wordaddr_fifo_rd_ack),
        .o_almost_empty         (),
        .o_empty                (),
        .ecc_err_status         ()
    );

    //the inputs fifos are all written to at the same time, the last fifo that is read will upper bound the occupancy of all the fifos, so almost full comes from this one
    //for the read LSU, there is only the wordaddr input fifo
    //for the write LSU, the data input fifo is read last
    assign input_fifo_almost_full = (READ) ? input_wordaddr_fifo_almost_full : input_writedata_fifo_almost_full;

    generate
    if (READ == 0) begin : GEN_INPUT_WRITEDATA_FIFO
        dla_hld_fifo #(
            .STALL_IN_EARLINESS     (1),
            .WIDTH                  (8*KER_DATA_BYTES),
            .DEPTH                  (MLAB_FIFO_DEPTH),
            .NEVER_OVERFLOWS        (1),
            .ALMOST_FULL_CUTOFF     (KER_UP_STALL_LATENCY),
            .ASYNC_RESET            (ASYNC_RESET),
            .SYNCHRONIZE_RESET      (0),
            .STYLE                  ("ms")
        )
        input_writedata_fifo_inst
        (
            .clock                  (clock),
            .resetn                 (resetn_synchronized),
            .i_valid                (valid_in_not_predicated),
            .i_data                 (i_writedata),
            .o_stall                (),
            .o_almost_full          (input_writedata_fifo_almost_full),
            .o_valid                (),
            .o_data                 (input_writedata_fifo_rd_data),
            .i_stall                (~input_writedata_fifo_rd_ack),
            .o_almost_empty         (),
            .o_empty                (),
            .ecc_err_status         ()
        );

        if (USE_BYTE_ENABLE) begin : GEN_INPUT_BYTEENABLE_FIFO
            dla_hld_fifo #(
                .WIDTH                  (KER_DATA_BYTES),
                .DEPTH                  (MLAB_FIFO_DEPTH),
                .NEVER_OVERFLOWS        (1),
                .ASYNC_RESET            (ASYNC_RESET),
                .SYNCHRONIZE_RESET      (0),
                .STYLE                  ("ms")
            )
            input_byteenable_fifo_inst
            (
                .clock                  (clock),
                .resetn                 (resetn_synchronized),
                .i_valid                (valid_in_not_predicated),
                .i_data                 (i_byteenable),
                .o_stall                (),
                .o_almost_full          (),
                .o_valid                (),
                .o_data                 (input_byteenable_fifo_rd_data),
                .i_stall                (~input_byteenable_fifo_rd_ack),
                .o_almost_empty         (),
                .o_empty                (),
                .ecc_err_status         ()
            );
        end
    end
    endgenerate



    //////////////////////
    //  Word Coalescer  //
    //////////////////////

    // determine if many kernel words can coalesce within the same memory word
    // produce the information needed by the unaligned controller, e.g. how many memory words does each kernel word span

    dla_hld_lsu_word_coalescer #(
        .ASYNC_RESET                    (ASYNC_RESET),
        .ADDR_WIDTH                     (ADDR_WIDTH),
        .ADDR_ALIGNMENT_BITS            (ADDR_ALIGNMENT_BITS),
        .INTRA_ADDR_WIDTH               (INTRA_ADDR_WIDTH),
        .KER_DATA_BYTES                 (KER_DATA_BYTES),
        .KER_DATA_BYTES_LAST            (KER_DATA_BYTES_LAST),
        .ENABLE_WORD_COALESCE           (ENABLE_WORD_COALESCE),
        .HIGH_THROUGHPUT_MODE           (HIGH_THROUGHPUT_MODE),
        .MAX_MEM_WORDS_PER_KER_WORD     (MAX_MEM_WORDS_PER_KER_WORD),
        .MLAB_FIFO_DEPTH                (MLAB_FIFO_DEPTH),
        .WRITEACK_WIDTH                 (WRITEACK_WIDTH),
        .WORD_COAL_MAX_TIMEOUT_BIT      (WORD_COAL_MAX_TIMEOUT_BIT)
    )
    dla_hld_lsu_word_coalescer_inst
    (
        .clock                          (clock),
        .resetn                         (resetn_synchronized),

        //kernel upstream
        .i_valid                        (valid_in_not_predicated),
        .i_more_wide_sections           (i_more_wide_sections),
        .i_addr                         (i_address),

        //disable timeout on coalescing if there is enough backlog
        .i_disable_coalescer_timeout    (disable_coalescer_timeout),

        //read side of cmd fifo -- this provides information about the kernel word, unaligned controller uses this info to walk through the many states of processing each kernel work
        .i_cmd_fifo_rd_ack              (cmd_fifo_rd_ack),
        .o_cmd_fifo_empty               (cmd_fifo_empty),
        .o_cmd_can_coalesce             (cmd_can_coalesce),
        .o_cmd_spans_two                (cmd_spans_two),
        .o_cmd_spans_three              (cmd_spans_three),
        .o_cmd_needs_second_cycle       (cmd_needs_second_cycle),
        .o_cmd_needs_third_cycle        (cmd_needs_third_cycle),
        .o_cmd_more_wide_sections       (cmd_more_wide_sections),
        .o_cmd_addr                     (cmd_addr),
        .o_cmd_addr_modulo              (cmd_addr_modulo)
    );



    ////////////////////////////
    //  Unaligned Controller  //
    ////////////////////////////

    // based on how many memory words a kernel word spans and other info, track the progress of processing one kernel word

    always_ff @(posedge clock) begin
        //some of these almost full signals are tied off to 0 if they are needed for write LSU only or for read LSU only
        downstream_of_cmd_almost_full <= burstcoal_almost_full | avm_wr_data_fifo_almost_full | avm_rd_data_fifo_almost_full | rsp_fifo_almost_full | writeack_fifo_almost_full;
    end
    assign can_read_cmd_fifo = ~cmd_fifo_empty & ~downstream_of_cmd_almost_full;

    dla_hld_lsu_unaligned_controller #(
        .ASYNC_RESET                    (ASYNC_RESET),
        .MAX_MEM_WORDS_PER_KER_WORD     (MAX_MEM_WORDS_PER_KER_WORD),
        .HIGH_THROUGHPUT_MODE           (HIGH_THROUGHPUT_MODE)
    )
    dla_hld_lsu_unaligned_controller_inst
    (
        .clock                          (clock),
        .resetn                         (resetn_synchronized),

        //handshaking
        .i_can_read_fifo                (can_read_cmd_fifo),
        .o_fifo_rd_ack                  (cmd_fifo_rd_ack),

        //information about the kernel word
        .i_spans_two                    (cmd_spans_two),
        .i_spans_three                  (cmd_spans_three),
        .i_needs_second_cycle           (cmd_needs_second_cycle),
        .i_needs_third_cycle            (cmd_needs_third_cycle),
        .i_can_coalesce                 (cmd_can_coalesce),

        //state of processing within kernel word
        .o_at_second_cycle              (cmd_at_second_cycle),
        .o_at_third_cycle               (cmd_at_third_cycle),
        .o_is_coalescing                (cmd_is_coalescing),
        .o_first_access_in_word         (cmd_first_access_in_word)
    );



    ///////////////////////
    //  Burst Coalescer  //
    ///////////////////////

    //localparams from dla_hld_lsu_write_data_alignment.sv -- this models how much latency the data aligner itself takes
    localparam int RAW_SHIFT_TO_ALIGN_WIDTH = (HIGH_THROUGHPUT_MODE) ? (($clog2(KER_DATA_BYTES) > INTRA_ADDR_WIDTH) ? INTRA_ADDR_WIDTH : $clog2(KER_DATA_BYTES)) : $clog2(KER_DATA_BYTES);
    localparam int SHIFT_TO_ALIGN_WIDTH = RAW_SHIFT_TO_ALIGN_WIDTH - ADDR_ALIGNMENT_BITS;
    localparam int DATA_ALIGNER_LATENCY = (DATA_ALIGNER_MUX_PER_PIPE == 0) ? 0 : ((SHIFT_TO_ALIGN_WIDTH + DATA_ALIGNER_MUX_PER_PIPE - 1) / DATA_ALIGNER_MUX_PER_PIPE);

    //compute the total latency of the write data alignment
    localparam int CMD_FIFO_TO_INPUT_FIFO_DATA_LATENCY = 2; //1 pipeline stage on read ack, stall in earliness = 1
    localparam int ALIGNER_TO_AVM_DATA_FIFO_LATENCY = 1;    //1 pipeline stage, a register is needed to accumulate write data
    localparam int AVM_DATA_FIFO_WRITE_TO_READ_LATENCY = 3; //assuming dla_acl_mid_speed_fifo
    localparam int TOTAL_WRITE_ALIGNMENT_LATENCY = CMD_FIFO_TO_INPUT_FIFO_DATA_LATENCY + DATA_ALIGNER_LATENCY + ALIGNER_TO_AVM_DATA_FIFO_LATENCY + AVM_DATA_FIFO_WRITE_TO_READ_LATENCY;

    //compute the minimum total latency of the burst coalescer
    localparam int CMD_FIFO_TO_BURST_COAL_INPUT_LATENCY = 1;    //1 pipeline stage for burstcoal_valid
    localparam int BURST_COAL_INPUT_TO_REPEAT_FIFO_LATENCY = 4; //inside burst coal: i_valid -> input_valid -> late_captured_done_with_word -> coal_done_with_word -> repeat_fifo_wr_req
    localparam int REPEAT_FIFO_WRITE_TO_READ_LATENCY = 3;       //assuming dla_acl_mid_speed_fifo
    localparam int REPEATER_LATENCY = 0;                        //same clock cycle handshaking
    localparam int AVM_CTRL_FIFO_WRITE_TO_READ_LATENCY = 3;     //assuming dla_acl_mid_speed_fifo
    localparam int TOTAL_BURST_COALESCER_LATENCY = CMD_FIFO_TO_BURST_COAL_INPUT_LATENCY + BURST_COAL_INPUT_TO_REPEAT_FIFO_LATENCY + REPEAT_FIFO_WRITE_TO_READ_LATENCY + REPEATER_LATENCY + AVM_CTRL_FIFO_WRITE_TO_READ_LATENCY;

    //to prevent avm_write from deasserting partway through a burst, ensure the burst coalescer has the longer latency, this is implemented with a separate occ tracker for repeat fifo empty inside burst coal to add latency
    localparam int BURST_COAL_EXTRA_WRITE_LATENCY = (TOTAL_WRITE_ALIGNMENT_LATENCY > TOTAL_BURST_COALESCER_LATENCY) ? (TOTAL_WRITE_ALIGNMENT_LATENCY - TOTAL_BURST_COALESCER_LATENCY) : 0;

    generate
    if (READ || !ENABLE_BURST_COALESCE) begin : BURST_COAL_EARLY_AS_POSSIBLE
        //for the read lsu, send a memory word to the burst coalescer the first time that this memory word accessed
        //even for the write lsu, avm_write deasserting partway through a burst cannot happen if the maximum burst length is 1
        always_ff @(posedge clock) begin
            burstcoal_valid <= can_read_cmd_fifo & cmd_first_access_in_word;
        end
    end
    else begin : BURST_COAL_LATE_AS_POSSIBLE
        //for the write lsu, send a memory word to the burst coalescer the last time that this memory word accessed
        //the ring global interconnect requires that one cannot deassert avm_write partway through a burst
        //avm_write deassertion partway through the burst can happen if the burst coalescer sees this address and then times out before the word coalescer is done assembling the corresponding memory word
        //having the data ready before the corresponding address is released to the burst coalescer ensures the word coalescer finishes first, any burst up to this memory word cannot stall partway through
        always_ff @(posedge clock) begin
            burstcoal_valid <= can_read_cmd_fifo & ~cmd_is_coalescing;
        end
    end
    endgenerate

    always_ff @(posedge clock) begin
        burstcoal_add_to_base_addr <= {cmd_at_third_cycle, cmd_at_second_cycle};
        input_wordaddr_fifo_rd_ack <= cmd_fifo_rd_ack;
    end

    dla_hld_lsu_burst_coalescer
    #(
        .ASYNC_RESET                    (ASYNC_RESET),
        .ENABLE_BURST_COALESCE          (ENABLE_BURST_COALESCE),
        .USE_REPEATER                   ((READ) ? 0 : 1),   //read burst is just one word for the request, write burst has to send data over burstcount clocks and therefore takes burstcount words
        .WORD_ADDR_WIDTH                (WORD_ADDR_WIDTH),
        .BURSTCOUNT_WIDTH               (BURSTCOUNT_WIDTH),
        .UPSTREAM_STALL_LATENCY         (2),                //latency from burstcoal_almost_full to burstcoal_valid
        .MLAB_FIFO_DEPTH                (MLAB_FIFO_DEPTH),
        .M20K_WIDE_FIFO_DEPTH           (M20K_WIDE_FIFO_DEPTH),
        .M20K_NARROW_FIFO_DEPTH         (M20K_NARROW_FIFO_DEPTH),
        .NO_AVM_WAITREQUEST             ((CACHE_SIZE_BYTES==0) ? 0 : 1),    //if read cache is being used, guaranteed that cache can accept the transaction immediately since cache capacity is larger than throttle threshold
        .BURST_COAL_MAX_TIMEOUT_BIT     (BURST_COAL_MAX_TIMEOUT_BIT),
        .ADD_TO_ADDR_IS_ZERO            ((MAX_MEM_WORDS_PER_KER_WORD==1) ? 1 : 0),  //if lsu is aligned then burstcoal_add_to_base_addr will be 0, don't need adder inside burstcoal so some pipeline stages can be removed
        .EXTRA_WRITE_LATENCY            (BURST_COAL_EXTRA_WRITE_LATENCY),
        .USE_AXI                        (USE_AXI),
        .ADDR_ADAPT_WIDTH               (ADDR_ADAPT_WIDTH)
    )
    dla_hld_lsu_burst_coalescer_inst
    (
        .clock                          (clock),
        .resetn                         (resetn_synchronized),

        //input to burst coalescing
        .i_valid                        (burstcoal_valid),
        .i_base_addr                    (input_wordaddr_fifo_rd_data),
        .i_add_to_base_addr             (burstcoal_add_to_base_addr),
        .o_almost_full                  (burstcoal_almost_full),
        .o_disable_coalescer_timeout    (disable_coalescer_timeout),

        //for writeack
        .o_burstcoal_snoop_valid        (burstcoal_snoop_valid),
        .o_burstcoal_snoop_burstsize    (burstcoal_snoop_burstsize),

        //axi last fifo
        .o_axi_last_fifo_rd_data        (axi_last_fifo_rd_data),
        .i_axi_last_fifo_rd_ack         (axi_last_fifo_rd_ack),
        .o_axi_last_fifo_empty          (axi_last_fifo_empty),

        //output to avm addr and burstcount
        .o_avm_ctrl_fifo_empty          (avm_ctrl_fifo_empty),
        .i_avm_ctrl_fifo_rd_ack         (avm_ctrl_fifo_rd_ack),
        .o_avm_word_address             (avm_word_address),
        .o_avm_burstcount               (avm_burstcount)
    );
    assign avm_address = {avm_word_address, {INTRA_ADDR_WIDTH{1'h0}}};



    /////////////////////////////
    //  AVM Request Interface  //
    /////////////////////////////

    generate
    if (READ == 0) begin : GEN_WRITE_DATA_ALIGNMENT
        dla_hld_lsu_write_data_alignment #(
            .INTRA_ADDR_WIDTH               (INTRA_ADDR_WIDTH),
            .MAX_MEM_WORDS_PER_KER_WORD     (MAX_MEM_WORDS_PER_KER_WORD),
            .ASYNC_RESET                    (ASYNC_RESET),
            .ADDR_ALIGNMENT_BITS            (ADDR_ALIGNMENT_BITS),
            .USE_BYTE_ENABLE                (USE_BYTE_ENABLE),
            .HIGH_THROUGHPUT_MODE           (HIGH_THROUGHPUT_MODE),
            .MEM_DATA_BYTES                 (MEM_DATA_BYTES),
            .KER_DATA_BYTES                 (KER_DATA_BYTES),
            .KER_DATA_BYTES_LAST            (KER_DATA_BYTES_LAST),
            .DATA_ALIGNER_MUX_PER_PIPE      (DATA_ALIGNER_MUX_PER_PIPE),
            .M20K_WIDE_FIFO_DEPTH           (M20K_WIDE_FIFO_DEPTH)
        )
        dla_hld_lsu_write_data_alignment_inst
        (
            .clock                          (clock),
            .resetn                         (resetn_synchronized),

            //cmd fifo kernel word info
            .i_cmd_more_wide_sections       (cmd_more_wide_sections),
            .i_cmd_spans_two                (cmd_spans_two),
            .i_cmd_spans_three              (cmd_spans_three),
            .i_cmd_addr_modulo              (cmd_addr_modulo),
            .i_cmd_addr                     (cmd_addr),

            //cmd fifo read control
            .i_can_read_cmd_fifo            (can_read_cmd_fifo),
            .i_cmd_fifo_rd_ack              (cmd_fifo_rd_ack),
            .i_cmd_at_second_cycle          (cmd_at_second_cycle),
            .i_cmd_at_third_cycle           (cmd_at_third_cycle),
            .i_cmd_is_coalescing            (cmd_is_coalescing),
            .i_cmd_first_access_in_word     (cmd_first_access_in_word),

            //input fifos
            .i_input_byteenable_fifo_rd_data(input_byteenable_fifo_rd_data),
            .o_input_byteenable_fifo_rd_ack (input_byteenable_fifo_rd_ack),
            .i_input_writedata_fifo_rd_data (input_writedata_fifo_rd_data),
            .o_input_writedata_fifo_rd_ack  (input_writedata_fifo_rd_ack),

            //avm data fifo
            .o_avm_wr_data_fifo_almost_full (avm_wr_data_fifo_almost_full),
            .o_avm_wr_data_fifo_empty       (avm_wr_data_fifo_empty),
            .i_avm_wr_data_fifo_rd_ack      (avm_wr_data_fifo_rd_ack),
            .o_avm_writedata                (avm_writedata),
            .o_avm_byteenable               (avm_byteenable)
        );

        assign avm_read = 1'b0;
        if (USE_AXI) begin
            //maps to axi write address channel
            assign axi_awvalid = ~avm_ctrl_fifo_empty;
            assign avm_ctrl_fifo_rd_ack = axi_awvalid & axi_awready;

            //maps to axi write data channel
            assign avm_write = ~axi_last_fifo_empty & ~avm_wr_data_fifo_empty;
            assign axi_last = axi_last_fifo_rd_data;
            assign avm_wr_data_fifo_rd_ack = avm_write & ~avm_waitrequest;
            assign axi_last_fifo_rd_ack = avm_write & ~avm_waitrequest;
        end
        else begin
            assign avm_write = ~avm_ctrl_fifo_empty & ~avm_wr_data_fifo_empty;
            assign avm_ctrl_fifo_rd_ack = ~avm_waitrequest & avm_write;
            assign avm_wr_data_fifo_rd_ack = avm_ctrl_fifo_rd_ack;

            //avalon does not use these write signals
            assign axi_awvalid = 1'b0;
            assign axi_last = '0;
        end
    end
    else begin : NO_WRITE_DATA_ALIGNMENT
        assign avm_wr_data_fifo_almost_full = 1'b0;
        assign avm_write = 1'b0;
        assign avm_read = ~avm_ctrl_fifo_empty;
        assign avm_byteenable = '1;
        assign avm_ctrl_fifo_rd_ack = ~avm_waitrequest & avm_read;
        assign axi_awvalid = 1'b0;
        assign axi_last = '0;
    end
    endgenerate



    //////////////////////////////
    //  AVM Response Interface  //
    //////////////////////////////

    generate
    if (READ == 0) begin : GEN_WRITE_DOWNSTREAM
        dla_hld_lsu_write_kernel_downstream #(
            .ASYNC_RESET                    (ASYNC_RESET),
            .HIGH_THROUGHPUT_MODE           (HIGH_THROUGHPUT_MODE),
            .MAX_MEM_WORDS_PER_KER_WORD     (MAX_MEM_WORDS_PER_KER_WORD),
            .MLAB_FIFO_DEPTH                (MLAB_FIFO_DEPTH),
            .M20K_NARROW_FIFO_DEPTH         (M20K_NARROW_FIFO_DEPTH),
            .WRITEACK_WIDTH                 (WRITEACK_WIDTH),
            .KER_DOWN_STALL_LATENCY         (KER_DOWN_STALL_LATENCY),
            .TOTAL_OCC_LIMIT                (TOTAL_OCC_LIMIT),
            .BURSTCOUNT_WIDTH               (BURSTCOUNT_WIDTH),
            .ENABLE_BURST_COALESCE          (ENABLE_BURST_COALESCE),
            .USE_AXI                        (USE_AXI)
        )
        dla_hld_lsu_write_kernel_downstream_inst
        (
            .clock                          (clock),
            .resetn                         (resetn_synchronized),

            //cmd fifo kernel word info
            .i_cmd_spans_two                (cmd_spans_two),
            .i_cmd_spans_three              (cmd_spans_three),

            //cmd unaligned controller
            .i_can_read_cmd_fifo            (can_read_cmd_fifo),
            .i_cmd_fifo_rd_ack              (cmd_fifo_rd_ack),
            .i_cmd_at_second_cycle          (cmd_at_second_cycle),
            .i_cmd_at_third_cycle           (cmd_at_third_cycle),
            .i_cmd_is_coalescing            (cmd_is_coalescing),

            //burst coalescer
            .i_burstcoal_snoop_valid        (burstcoal_snoop_valid),
            .i_burstcoal_snoop_burstsize    (burstcoal_snoop_burstsize),

            //write ack fifo
            .o_writeack_fifo_almost_full    (writeack_fifo_almost_full),
            .i_avm_writeack                 (avm_writeack),

            //read side of predicate fifo
            .i_predicate_fifo_empty         (predicate_fifo_empty),
            .i_predicate_fifo_rd_data       (predicate_fifo_rd_data),
            .o_predicate_fifo_rd_ack        (predicate_fifo_rd_ack),

            //kernel downstream
            .o_valid                        (o_valid),
            .o_empty                        (o_empty),
            .o_almost_empty                 (o_almost_empty),
            .i_stall                        (i_stall)
        );
        assign o_readdata = 'x;
        assign rsp_fifo_almost_full = 1'b0;
        assign avm_rd_data_fifo_almost_full = 1'b0;
    end
    else begin : GEN_READ_DATA_ALIGNMENT
        dla_hld_lsu_read_data_alignment #(
            .INTRA_ADDR_WIDTH               (INTRA_ADDR_WIDTH),
            .KER_DOWN_STALL_LATENCY         (KER_DOWN_STALL_LATENCY),
            .MAX_MEM_WORDS_PER_KER_WORD     (MAX_MEM_WORDS_PER_KER_WORD),
            .ENABLE_WORD_COALESCE           (ENABLE_WORD_COALESCE),
            .ASYNC_RESET                    (ASYNC_RESET),
            .ADDR_ALIGNMENT_BITS            (ADDR_ALIGNMENT_BITS),
            .HIGH_THROUGHPUT_MODE           (HIGH_THROUGHPUT_MODE),
            .MEM_DATA_BYTES                 (MEM_DATA_BYTES),
            .KER_DATA_BYTES                 (KER_DATA_BYTES),
            .CACHE_BYPASS_DATA_FIFO         ((CACHE_SIZE_BYTES==0) ? 0 : 1),
            .MLAB_FIFO_DEPTH                (MLAB_FIFO_DEPTH),
            .DATA_ALIGNER_MUX_PER_PIPE      (DATA_ALIGNER_MUX_PER_PIPE),
            .M20K_WIDE_FIFO_DEPTH           (M20K_WIDE_FIFO_DEPTH)
        )
        read_data_alignment_inst
        (
            .clock                          (clock),
            .resetn                         (resetn_synchronized),

            //write side of avm data fifo
            .i_burstcoal_valid              (burstcoal_valid),
            .o_avm_rd_data_fifo_almost_full (avm_rd_data_fifo_almost_full),
            .i_avm_readdatavalid            (avm_readdatavalid),
            .i_avm_readdata                 (avm_readdata),
            .o_avm_readdata_accepted        (avm_readdata_accepted),

            //write side of response fifo
            .o_rsp_fifo_almost_full         (rsp_fifo_almost_full),
            .i_cmd_fifo_rd_ack              (cmd_fifo_rd_ack),
            .i_cmd_can_coalesce             (cmd_can_coalesce),
            .i_cmd_addr                     (cmd_addr),
            .i_cmd_spans_two                (cmd_spans_two),
            .i_cmd_spans_three              (cmd_spans_three),

            //read side of predicate fifo
            .i_predicate_fifo_empty         (predicate_fifo_empty),
            .i_predicate_fifo_rd_data       (predicate_fifo_rd_data),
            .o_predicate_fifo_rd_ack        (predicate_fifo_rd_ack),

            //kernel downstream
            .o_readdata                     (o_readdata),
            .o_valid                        (o_valid),
            .o_empty                        (o_empty),
            .o_almost_empty                 (o_almost_empty),
            .i_stall                        (i_stall)
        );
        assign writeack_fifo_almost_full = 1'b0;
    end
    endgenerate


endmodule

`default_nettype wire
