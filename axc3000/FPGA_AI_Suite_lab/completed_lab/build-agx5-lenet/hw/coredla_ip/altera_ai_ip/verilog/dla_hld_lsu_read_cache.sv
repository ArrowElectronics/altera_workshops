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

// This is the cache module for the read LSU. The cache lives outside of the core LSU. It is a bump-in-the-wire architecture which sits between the LSU avalon interface and
// the actual memory interface. There is no snoop on writes to memory, so to be functionally correct the read LSU can only access data that is not being modified during the
// read access. Two scenarios (among others) that satisfy this are:
// 1. read-only access to some region of global memory
// 2. all reads finish before any writes start to this region of global memory
//
// The contents of memory can change between different runs of the same hardware, therefore one must drive the i_flush_cache signal any time the contents of memory have changed
// (more specifically the contents in the region memory that this read LSU may access). Typically the i_flush_cache signal is asserted high for one clock cycle at the beginning
// of each opencl kernel execution. The valid marker for each cache line is stored in memory (not registers), so the cache must walk through all memory addresses in order to
// flush the cache. During this time the cache is still operational, e.g. backpressure is not applied to the LSU, however all cache lookups are treated as a cache miss, and
// the cache does not update with data read from global memory.
//
// Currently there is no hash function to map byte address in global memory to cache lines (although the cache architecture certainly supports such future enhancements).
// Instead the address is sliced up. Let's use some real numbers to make the explanation easier. Suppose global memory is 64 bytes wide, so the bottom 6 bits of the byte address
// indicate a location within a memory word. Suppose the cache depth is 1024 memory words, so bits [15:6] of the byte address indicate the cache line number. This means byte
// address 0 and byte address 65536 both map to cache line 0. To tell them apart, inside each cache line, the upper bits of the byte address (bits 16+) are stored so that we
// can infer which byte address the data is for.
//
// The operation of the cache is as follows:
// 1. (Optional) Split avalon read bursts coming from the LSU, but really the LSU should disable burst coalescing
// 2. Read from the cache to check for hit or miss, keep track of the result in the hit fifo
// 3a. If there is a cache hit, push the data into the hit fifo, skip to step 5
// 3b. Otherwise it was a cache miss, request data from global memory (there is an optional bump-in-the-wire burst coalescer here)
// 4b. When data is returned from memory, push it into the rsp fifo and update the cache (but don't read from the cache again)
// 5. The hit fifo indicates whether the read data returned to the LSU should come from the hit fifo or the rsp fifo
//
// Some important observations:
// - each LSU read request (assume no bursts) results in exactly one read from the cache
// - if cache hit need to grab the data now, may be stalled from returning read data to LSU due to an earlier miss, and if we read the cache later the contents could have changed
// - not required to update cache with read data from global memory, it doesn't help the current cache miss, it may only help a future request to the same address
//
// Joint optimization with the read LSU:
// 1. Inside the LSU's burst coalescer, can bypass avm_ctrl_fifo
//    - read LSU has a throttle to not ask for more data that it has space for
//    - all fifos inside the cache are sized at least this deep, therefore cache will never backpressure the LSU, throttle will engage first to stop sending to the cache
//    - therefore there is no backpressure, e.g. avm_waitrequest from the cache to LSU would always be 0
// 2. Inside the LSU's read data alignment, can bypass avm_rd_data_fifo
//    - this fifo was only needed because avm_readdatavalid has no backpressure mechanism
//    - the read data returned from cache to LSU comes from either the hit fifo or rsp fifo, and the selection is gated by the order fifo, therefore read data is backpressureable
//
// Future extension: enable snoop on writes to invalidate cache
// - currently the cache is implemented with 1 write and 1 read port
// - if we had a memory with 2 write and 2 read ports, we could enable snoop on write without changing anything else in the cache
// - the extra read port would check if a snooped write was in the cache
// - the extra write port would update or invalidate that cache line if the snooped write was in the cache
// - notice the if snooped writes results in cache line invalidation, then we only need the quad port memory for the valid and upper address bits, this is a narrow memory so
//   replicating memory for extra ports is not so expensive
//
// For additional info, refer to dla_hld_global_load_store.sv (top module of entire LSU) and dla_hld_lsu.sv (top module of the core LSU).

`default_nettype none

module dla_hld_lsu_read_cache #(
    //parameters that are different from dla_hld_lsu.sv
    parameter bit CACHE_NEVER_OVERFLOWS,        //if cache capacity is no less than lsu throttle threshold and lsu does not produce bursts, then eliminate backpressure to lsu
    parameter bit BYPASS_BURST_SPLITTER,        //if burst coalescing inside the LSU is disabled, then cache does not need to split read request avalon bursts
    parameter bit BYPASS_LSU_DATA_FIFO,         //read data returned to the LSU from the cache is backpressurable, don't need another fifo inside LSU's read data alignment to catch non-backpressurable data
    parameter bit PIPELINE_UPDATE_TO_CACHE,     //optional pipeline stage can be inserted when updating the cache, allows more time for routing when the cache is large and therefore physically spread apart on the FPGA
    parameter bit PIPELINE_READ_FROM_CACHE,     //optional pipeline stage can be inserted before consuming read data from the cache, allows more time for routing when the cache is large
    
    //parameters that are the same as dla_hld_lsu.sv
    parameter bit ASYNC_RESET,                  //0 = registers consume reset synchronously, 1 = registers consume reset asynchronously
    parameter int ADDR_WIDTH,                   //width of address bus, for addresses that are byte addresses
    parameter int INTRA_ADDR_WIDTH,             //how many least significant bits of the byte address represent the location inside a memory word
    parameter int WORD_ADDR_WIDTH,              //how many most significant bits of the byte address represent which memory word is being accessed
    parameter int MEM_DATA_BYTES,               //width of memory data path in bytes, must be a power of 2
    parameter int BURSTCOUNT_WIDTH,             //width of avalon burst count signal, max burst size is 2**(BURSTCOUNT_WIDTH-1)
    parameter bit ENABLE_BURST_COALESCE,        //whether to coalesce sequential memory words together to make a burst, feature will be disabled (parameter value ignored) if width adaption on the memory interface is used
    parameter int CACHE_SIZE_BYTES,             //the cache size in bytes which must be a power of 2, this can only be used with the read LSU
    parameter int MLAB_FIFO_DEPTH,              //use a shallow fifo if handshaking is expected to take a few clocks (or if capacity can be borrowed from a nearby deep fifo), if we need an MLAB may as well use all of it
    parameter int M20K_WIDE_FIFO_DEPTH,         //use a deep fifo if handshaking is expected to take hundreds of clocks e.g. going off chip, for wide data path use M20K in shallowest mode, but may as well use all depth available
    parameter int M20K_NARROW_FIFO_DEPTH,       //if we need a deep fifo but the data path is narrow e.g. up to 10 bits which is the narrowest M20K on S10, can get additional depth for without needing more M20K
    parameter int BURST_COAL_MAX_TIMEOUT_BIT,   //limit how large the dynamic timeout threshold can get inside burst coalescer
    parameter bit USE_AXI                       //0 = use AvalonMM, 1 = use AXI, this affects how the burstcount is constructed
) (
    input  wire                         clock,
    input  wire                         resetn,
    input  wire                         i_flush_cache,          //a positive edge must be provided every time the contents change inside the region of memory accessible by the read LSU
    
    //kernel avm interface
    input  wire                         k_read,
    input  wire        [ADDR_WIDTH-1:0] k_address,
    input  wire  [BURSTCOUNT_WIDTH-1:0] k_burstcount,
    output logic                        k_waitrequest,
    output logic                        k_readdatavalid,        //if BYPASS_LSU_DATA_FIFO=1 this means cache has data that LSU may or may not consume, if BYPASS_LSU_DATA_FIFO=0 this means LSU must consume data
    output logic [8*MEM_DATA_BYTES-1:0] k_readdata,
    input  wire                         k_readdata_accepted,    //if BYPASS_LSU_DATA_FIFO=1 this is how LSU indicates it consumed data, otherwise ignore this signal
    
    //memory avm interface
    output logic                        m_read,
    output logic       [ADDR_WIDTH-1:0] m_address,
    output logic [BURSTCOUNT_WIDTH-1:0] m_burstcount,
    input  wire                         m_waitrequest,
    input  wire                         m_readdatavalid,
    input  wire  [8*MEM_DATA_BYTES-1:0] m_readdata
);
    
    //derived parameters
    localparam int CACHE_ADDR_BITS = $clog2(CACHE_SIZE_BYTES/MEM_DATA_BYTES);   //number of address bits for the cache memory
    localparam int UPPER_ADDR_BITS = WORD_ADDR_WIDTH - CACHE_ADDR_BITS;         //number of upper bits of the byte address need to be stored in the cache line
    
    
    
    ///////////////
    //  Signals  //
    ///////////////
    
    //reset
    logic aclrn, sclrn, resetn_synchronized;
    
    //burst splitter
    logic                           in_read, in_waitrequest;
    logic          [ADDR_WIDTH-1:0] in_address;
    logic     [WORD_ADDR_WIDTH-1:0] in_word_addr;
    
    //check for cache hit or miss
    logic                           tag_cache_was_read, tag_cache_read_data_is_valid;
    logic     [WORD_ADDR_WIDTH-1:0] late_in_word_addr, late_two_in_word_addr, late_three_in_word_addr;
    logic                           mixed_port_read_during_write, read_during_write_invalidate_read_data;
    logic                           can_write_to_order_fifo, data_for_writing_to_order_fifo;
    
    //order fifo
    logic                           order_fifo_wr_req, order_fifo_almost_full, order_fifo_empty, order_fifo_rd_ack, order_fifo_temp_valid, order_fifo_temp_stall;
    logic                           order_fifo_wr_data, order_fifo_rd_data, order_fifo_temp_data;
    
    //hit fifo
    logic                           hit_fifo_wr_req, read_from_hit_fifo, hit_fifo_not_empty, hit_fifo_rd_ack;
    logic    [8*MEM_DATA_BYTES-1:0] hit_fifo_wr_data, hit_fifo_rd_data;
    
    //burst coalescer to avalon request interface
    logic                           burstcoal_valid;
    logic     [WORD_ADDR_WIDTH-1:0] burstcoal_word_addr;
    logic                           avm_ctrl_fifo_empty, avm_ctrl_fifo_rd_ack;
    logic     [WORD_ADDR_WIDTH-1:0] avm_word_address;
    logic    [BURSTCOUNT_WIDTH-1:0] avm_burstcount;
    
    //rsp fifo
    logic                           rsp_fifo_wr_req, read_from_rsp_fifo, rsp_fifo_not_empty, rsp_fifo_rd_ack;
    logic    [8*MEM_DATA_BYTES-1:0] rsp_fifo_wr_data, rsp_fifo_rd_data;
    logic                           late_rsp_fifo_wr_req, late_two_rsp_fifo_wr_req;
    
    //return read data to LSU
    logic                           can_read_order_fifo;
    logic                           late_order_fifo_rd_data;
    logic                           late_order_fifo_rd_ack, late_two_order_fifo_rd_ack;
    
    //addr fifo
    logic                           addr_fifo_wr_req, addr_fifo_empty, addr_fifo_rd_ack;
    logic     [WORD_ADDR_WIDTH-1:0] addr_fifo_wr_data, addr_fifo_rd_data;
    
    //flush
    logic       [CACHE_ADDR_BITS:0] flush_counter;
    logic                           is_flushing, late_flush_cache, flush_cache_posedge;
    logic                           flush_writing_done, late_flush_writing_done, flush_reading_done;
    
    //tag cache memory
    logic                           tag_cache_wr_en;
    logic     [CACHE_ADDR_BITS-1:0] tag_cache_wr_addr, tag_cache_rd_addr;
    logic       [UPPER_ADDR_BITS:0] tag_cache_wr_data, tag_cache_rd_data;
    logic                           valid_read_from_cache;
    logic     [UPPER_ADDR_BITS-1:0] upper_addr_read_from_cache;
    
    //data cache memory
    logic                           data_cache_wr_en;
    logic     [CACHE_ADDR_BITS-1:0] data_cache_wr_addr, data_cache_rd_addr;
    logic    [8*MEM_DATA_BYTES-1:0] data_cache_wr_data, data_cache_rd_data;
    
    
    
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
    
    
    
    //////////////////////
    //  Burst Splitter  //
    //////////////////////
    
    // the cache needs one read request per memory word, ideally the LSU should disable burst coalescing so that we are not just undoing it here
    generate
    if (BYPASS_BURST_SPLITTER) begin : NO_BURST_SPLIT
        assign in_read = k_read;
        assign in_address = k_address;
        assign k_waitrequest = in_waitrequest;
    end
    else begin : GEN_BURST_SPLIT
        dla_acl_burst_splitter #(
            .ADDRESS_WIDTH              (ADDR_WIDTH),
            .BYTEENABLE_WIDTH           (MEM_DATA_BYTES),
            .BURSTCOUNT_WIDTH           (BURSTCOUNT_WIDTH),
            .SPLIT_WRITE_BURSTS         (0),
            .SPLIT_READ_BURSTS          (1),
            .BURST_BOUNDARY             (0),
            .USE_STALL_LATENCY          (0),
            .ASYNC_RESET                (ASYNC_RESET),
            .SYNCHRONIZE_RESET          (0),
            .BACKPRESSURE_DURING_RESET  (1)
        )
        dla_acl_burst_splitter_inst
        (
            .clock                      (clock),
            .resetn                     (resetn_synchronized),
            
            .up_waitrequest             (k_waitrequest),
            .up_read                    (k_read),
            .up_write                   (1'b0),
            .up_address                 (k_address),
            .up_writedata               (),
            .up_byteenable              (),
            .up_burstcount              (k_burstcount),
            
            .down_waitrequest           (in_waitrequest),
            .down_read                  (in_read),
            .down_write                 (),
            .down_address               (in_address),
            .down_writedata             (),
            .down_byteenable            (),
            .down_burstcount            ()
        );
    end
    endgenerate
    
    
    
    ///////////////////////////////////
    //  Check for cache hit or miss  //
    ///////////////////////////////////
    
    // each cache line needs to store 3 things:
    // 1. valid -- this is set to 0 during flush, set to 1 when snooping on read data returned from memory
    // 2. upper address -- multiple addresses map to the same cache line, this is stored to indicate which address this cache line had stored
    // 3. data -- the actual data itself, this is the same width as the memory data width
    // in terms of implementation, 1 and 2 together are called the "tag" of the cache, and the tag is stored separately from the data
    // tag cache is always accessed one clock cycle before the same cache line in the data cache
    // this allows 1 clock cycle to check if the upper address bits match, if we read the tag cache and data cache on the same clock cycle we'd have to keep the data live for an extra clock cycle
    // for consistency, the snoop on read data returned from memory also updates cache with the same timing -- when the tag cache is updated, the same cache line in the data cache updates one clock cycle later
    
    assign in_word_addr = in_address[ADDR_WIDTH-1:INTRA_ADDR_WIDTH];    //remove the lower bits which specify a location inside the memory word
    assign tag_cache_rd_addr = in_word_addr[CACHE_ADDR_BITS-1:0];       //which cache line to read from in the tag cache
    
    //write the result into order fifo
    always_ff @(posedge clock) begin
        //one clock after burst splitter
        tag_cache_was_read <= in_read & ~in_waitrequest;
        late_in_word_addr <= in_word_addr;
        mixed_port_read_during_write <= (tag_cache_wr_addr == tag_cache_rd_addr) & tag_cache_wr_en; //ram will return x read data, treat as cache miss
        
        //two clocks after
        tag_cache_read_data_is_valid <= tag_cache_was_read;
        late_two_in_word_addr <= late_in_word_addr;
        read_during_write_invalidate_read_data <= mixed_port_read_during_write;
        
        //three clocks after
        can_write_to_order_fifo <= tag_cache_read_data_is_valid;
        //order fifo data: 1 means cache hit, 0 means cache miss, miss if anything funny happens (flushing, x read from ram) or if it is a real miss (invalid or upper addr mismatch)
        data_for_writing_to_order_fifo <= flush_reading_done & ~read_during_write_invalidate_read_data & valid_read_from_cache & (upper_addr_read_from_cache == late_two_in_word_addr[WORD_ADDR_WIDTH-1:CACHE_ADDR_BITS]);
        late_three_in_word_addr <= late_two_in_word_addr;   //if cache miss, what address should we request from global mem
    end
    
    
    
    //////////////////
    //  Order FIFO  //
    //////////////////
    
    // need to return data to the LSU in the correct order, order_fifo tracks whether the next word to return to the LSU should come from the hit fifo or rsp fifo
    // capacity of order_fifo limits the total number of outstanding transactions, if all other fifos in the cache are at least this deep then backpressure only from order_fifo is sufficient
    
    assign in_waitrequest = (CACHE_NEVER_OVERFLOWS) ? 1'b0 : order_fifo_almost_full;
    
    generate
    if (PIPELINE_READ_FROM_CACHE) begin : GEN_PIPE_ORDER_FIFO_WRITE
        always_ff @(posedge clock) begin
            order_fifo_wr_req <= can_write_to_order_fifo;
            order_fifo_wr_data <= data_for_writing_to_order_fifo;
        end
    end
    else begin : NO_PIPE_ORDER_FIFO_WRITE
        assign order_fifo_wr_req = can_write_to_order_fifo;
        assign order_fifo_wr_data = data_for_writing_to_order_fifo;
    end
    endgenerate
    
    dla_hld_fifo #(
        .WIDTH              (1),
        .DEPTH              (M20K_WIDE_FIFO_DEPTH),
        .NEVER_OVERFLOWS    (1),
        .ALMOST_FULL_CUTOFF ((PIPELINE_READ_FROM_CACHE) ? 4 : 3),    //3 or 4 pipeline stages from order_fifo_almost_full to order_fifo_wr_req
        .ASYNC_RESET        (ASYNC_RESET),
        .SYNCHRONIZE_RESET  (0),
        .STYLE              ("ms")
    )
    order_fifo_ms_inst
    (
        .clock              (clock),
        .resetn             (resetn_synchronized),
        .i_valid            (order_fifo_wr_req),
        .i_data             (order_fifo_wr_data),
        .o_stall            (),
        .o_almost_full      (order_fifo_almost_full),
        .o_valid            (order_fifo_temp_valid),
        .o_data             (order_fifo_temp_data),
        .i_stall            (order_fifo_temp_stall),
        .o_almost_empty     (),
        .o_empty            (),
        .ecc_err_status     ()
    );
    
    //prefetch into a 2-deep register based fifo, this eases placement since data now comes from an ALM register rather than M20K hardened read data register
    dla_hld_fifo #(
        .REGISTERED_DATA_OUT_COUNT (1),
        .WIDTH              (1),
        .DEPTH              (2),
        .ASYNC_RESET        (ASYNC_RESET),
        .SYNCHRONIZE_RESET  (0),
        .STYLE              ("llreg")
    )
    order_fifo_ll_inst
    (
        .clock              (clock),
        .resetn             (resetn_synchronized),
        .i_valid            (order_fifo_temp_valid),
        .i_data             (order_fifo_temp_data),
        .o_stall            (order_fifo_temp_stall),
        .o_almost_full      (),
        .o_valid            (),
        .o_data             (order_fifo_rd_data),
        .i_stall            (~order_fifo_rd_ack),
        .o_almost_empty     (),
        .o_empty            (order_fifo_empty),
        .ecc_err_status     ()
    );
    
    
    
    ////////////////
    //  Hit FIFO  //
    ////////////////
    
    //if there is a cache hit, store that data in the hit fifo, cannot read it from the cache later on (e.g. if waiting due to an earlier cache miss) since the cache line could be modified before that later read
    
    generate
    if (PIPELINE_READ_FROM_CACHE) begin : GEN_PIPE_HIT_FIFO_WRITE
        always_ff @(posedge clock) begin
            hit_fifo_wr_req <= can_write_to_order_fifo & data_for_writing_to_order_fifo;
            hit_fifo_wr_data <= data_cache_rd_data;
        end
    end
    else begin : NO_PIPE_HIT_FIFO_WRITE
        assign hit_fifo_wr_req = can_write_to_order_fifo & data_for_writing_to_order_fifo;
        assign hit_fifo_wr_data = data_cache_rd_data;
    end
    endgenerate
    
    dla_hld_fifo #(
        .WIDTH              (8*MEM_DATA_BYTES),
        .DEPTH              (M20K_WIDE_FIFO_DEPTH),
        .NEVER_OVERFLOWS    (1),
        .ASYNC_RESET        (ASYNC_RESET),
        .SYNCHRONIZE_RESET  (0),
        .STYLE              ("ms")
    )
    hit_fifo_inst
    (
        .clock              (clock),
        .resetn             (resetn_synchronized),
        .i_valid            (hit_fifo_wr_req),
        .i_data             (hit_fifo_wr_data),
        .o_stall            (),
        .o_almost_full      (),
        .o_valid            (),
        .o_data             (hit_fifo_rd_data),
        .i_stall            (~hit_fifo_rd_ack),
        .o_almost_empty     (),
        .o_empty            (), //guaranteed to not underflow
        .ecc_err_status     ()
    );
    
    //order fifo and hit fifo are written to at the same time
    //by the time we can read from the order fifo and it says this was a hit, guaranteed that the hit fifo won't be empty
    assign hit_fifo_not_empty = 1'b1;
    
    
    
    ///////////////////////////////////////////////////
    //  Burst Coalescer to Avalon Request Interface  //
    ///////////////////////////////////////////////////
    
    //if there is a cache miss, request data from global mem
    
    
    generate
    if (PIPELINE_READ_FROM_CACHE) begin : GEN_PIPE_INTO_BURST_COAL
        always_ff @(posedge clock) begin
            burstcoal_valid <= can_write_to_order_fifo & ~data_for_writing_to_order_fifo;
            burstcoal_word_addr <= late_three_in_word_addr;
        end
    end
    else begin : NO_PIPE_INTO_BURST_COAL
        assign burstcoal_valid = can_write_to_order_fifo & ~data_for_writing_to_order_fifo;
        assign burstcoal_word_addr = late_three_in_word_addr;
    end
    endgenerate
    
    dla_hld_lsu_burst_coalescer
    #(
        .ASYNC_RESET                    (ASYNC_RESET),
        .BURST_COAL_MAX_TIMEOUT_BIT     (BURST_COAL_MAX_TIMEOUT_BIT),
        .ENABLE_BURST_COALESCE          (ENABLE_BURST_COALESCE),
        .USE_REPEATER                   (0),    //read lsu does not repeater, cache is only used with read lsu
        .WORD_ADDR_WIDTH                (WORD_ADDR_WIDTH),
        .BURSTCOUNT_WIDTH               (BURSTCOUNT_WIDTH),
        .UPSTREAM_STALL_LATENCY         (0),
        .MLAB_FIFO_DEPTH                (MLAB_FIFO_DEPTH),
        .M20K_WIDE_FIFO_DEPTH           (M20K_WIDE_FIFO_DEPTH),
        .M20K_NARROW_FIFO_DEPTH         (M20K_NARROW_FIFO_DEPTH),
        .NO_AVM_WAITREQUEST             (0),    //this is a feature intended for burstcoal inside the lsu
        .ADD_TO_ADDR_IS_ZERO            (1),    //i_add_to_base_addr is tied to 0, no adder is needed inside burstcoal which also means some pipeline stages can be removed
        .EXTRA_WRITE_LATENCY            (0),
        .USE_AXI                        (USE_AXI),
        .ADDR_ADAPT_WIDTH               (0)
    )
    dla_hld_lsu_burst_coalescer_inst
    (
        .clock                          (clock),
        .resetn                         (resetn_synchronized),
        
        //input to burst coalescing
        .i_valid                        (burstcoal_valid),
        .i_base_addr                    (burstcoal_word_addr),
        .i_add_to_base_addr             ('0),   //there is no unalignment which causes the access to go into the next mem word
        .o_almost_full                  (),     //the order fifo bounds the size of all other fifos, by construction the avm_ctrl_fifo inside here cannot overflow
        .o_disable_coalescer_timeout    (),
    
        //output to avm addr
        .o_avm_ctrl_fifo_empty          (avm_ctrl_fifo_empty),
        .i_avm_ctrl_fifo_rd_ack         (avm_ctrl_fifo_rd_ack),
        .o_avm_word_address             (avm_word_address),
        .o_avm_burstcount               (avm_burstcount)
    );
    
    //convert to avalon
    assign m_read = ~avm_ctrl_fifo_empty;
    assign m_burstcount = avm_burstcount;
    assign m_address = {avm_word_address, {INTRA_ADDR_WIDTH{1'h0}}};
    assign avm_ctrl_fifo_rd_ack = m_read & ~m_waitrequest;
    
    
    
    ////////////////
    //  Rsp FIFO  //
    ////////////////
    
    //capture the response from global memory
    assign rsp_fifo_wr_req = m_readdatavalid;
    assign rsp_fifo_wr_data = m_readdata;

    dla_hld_fifo #(
        .WIDTH              (8*MEM_DATA_BYTES),
        .DEPTH              (M20K_WIDE_FIFO_DEPTH),
        .NEVER_OVERFLOWS    (1),
        .ASYNC_RESET        (ASYNC_RESET),
        .SYNCHRONIZE_RESET  (0),
        .STYLE              ("ms")  //write to read latency of 3
    )
    rsp_fifo_inst
    (
        .clock              (clock),
        .resetn             (resetn_synchronized),
        .i_valid            (rsp_fifo_wr_req),
        .i_data             (rsp_fifo_wr_data),
        .o_stall            (),
        .o_almost_full      (),
        .o_valid            (),
        .o_data             (rsp_fifo_rd_data),
        .i_stall            (~rsp_fifo_rd_ack),
        .o_almost_empty     (),
        .o_empty            (), //this is tracked externally
        .ecc_err_status     ()
    );
    
    //track empty separately so that we can reserve a read before the read itself actually happens
    //if fifo write to read latency is N, need to delay write request by N-1 clock cycle to track empty, the pipelining below assumes write to read latency of 3
    always_ff @(posedge clock) begin
        late_rsp_fifo_wr_req <= rsp_fifo_wr_req;
        late_two_rsp_fifo_wr_req <= late_rsp_fifo_wr_req;
    end
    
    dla_acl_tessellated_incr_decr_threshold #(
        .CAPACITY                   (M20K_WIDE_FIFO_DEPTH),
        .THRESHOLD                  (1),
        .INITIAL_OCCUPANCY          (0),
        .THRESHOLD_REACHED_AT_RESET (0),
        .ASYNC_RESET                (ASYNC_RESET),
        .SYNCHRONIZE_RESET          (0)
    )
    rsp_fifo_empty_inst
    (
        .clock                      (clock),
        .resetn                     (resetn_synchronized),
        .incr_no_overflow           (late_two_rsp_fifo_wr_req),
        .incr_raw                   (late_two_rsp_fifo_wr_req),
        .decr_no_underflow          (read_from_rsp_fifo),
        .decr_raw                   (read_from_rsp_fifo),
        .threshold_reached          (rsp_fifo_not_empty)
    );
    
    
    
    ///////////////////////////////
    //  Return read data to LSU  //
    ///////////////////////////////
    
    //naming convention:
    //- ***_rd_ack is the drives the i_stall port of that fifo
    //- read_from_*** reserves a read from that fifo before the read actually happens, fifo empty must be tracked externally
    
    //use the order fifo to determine whether to read from the hit fifo or the response fifo
    assign can_read_order_fifo = ~order_fifo_empty & ((order_fifo_rd_data) ? hit_fifo_not_empty : rsp_fifo_not_empty);
    
    generate
    if (BYPASS_LSU_DATA_FIFO) begin : READ_DATA_BACKPRESSURE    //mimic the read interface of avm_rd_data_fifo inside the read LSU
        assign k_readdatavalid = can_read_order_fifo;           //readdatavalid means data is available, if the LSU accepts it data will be available two clocks later, which is the same latency to read from avm_rd_data_fifo
        assign order_fifo_rd_ack = k_readdata_accepted;         //LSU indicates that it accepted that data
        assign read_from_hit_fifo = order_fifo_rd_ack &  order_fifo_rd_data;    //data read from the order fifo indicates which fifo to pop from
        assign read_from_rsp_fifo = order_fifo_rd_ack & ~order_fifo_rd_data;
    end
    else begin : READ_DATA_NO_BACKPRESSURE                      //this is an avalon conformant read response interface, where read data cannot be backpressured
        assign k_readdatavalid = late_two_order_fifo_rd_ack;
        assign order_fifo_rd_ack = can_read_order_fifo;
        assign read_from_hit_fifo = ~order_fifo_empty &  order_fifo_rd_data & hit_fifo_not_empty;
        assign read_from_rsp_fifo = ~order_fifo_empty & ~order_fifo_rd_data & rsp_fifo_not_empty;
    end
    endgenerate
    
    always_ff @(posedge clock) begin
        //one clock after read from order fifo
        late_order_fifo_rd_ack <= order_fifo_rd_ack;
        late_order_fifo_rd_data <= order_fifo_rd_data;
        hit_fifo_rd_ack <= read_from_hit_fifo;
        rsp_fifo_rd_ack <= read_from_rsp_fifo;
        
        //two clocks after -- return data to kernel
        late_two_order_fifo_rd_ack <= late_order_fifo_rd_ack;
        k_readdata <= (late_order_fifo_rd_data) ? hit_fifo_rd_data : rsp_fifo_rd_data;
    end
    
    
    
    /////////////////
    //  Addr FIFO  //
    /////////////////
    
    //to update the cache, we need to know the address for each word of data returned from global memory
    assign addr_fifo_wr_req = burstcoal_valid;
    assign addr_fifo_wr_data = burstcoal_word_addr;
    
    dla_hld_fifo #(
        .WIDTH              (WORD_ADDR_WIDTH),
        .DEPTH              (M20K_WIDE_FIFO_DEPTH),
        .NEVER_OVERFLOWS    (1),
        .ASYNC_RESET        (ASYNC_RESET),
        .SYNCHRONIZE_RESET  (0),
        .STYLE              ("ms")
    )
    addr_fifo_inst
    (
        .clock              (clock),
        .resetn             (resetn_synchronized),
        .i_valid            (addr_fifo_wr_req),
        .i_data             (addr_fifo_wr_data),
        .o_stall            (),
        .o_almost_full      (),
        .o_valid            (),
        .o_data             (addr_fifo_rd_data),
        .i_stall            (~addr_fifo_rd_ack),
        .o_almost_empty     (),
        .o_empty            (),
        .ecc_err_status     ()
    );
    
    assign addr_fifo_rd_ack = read_from_rsp_fifo;
    
    
    
    /////////////
    //  Flush  //
    /////////////
    
    //the cache must be flushed every time the contents could have changed in the region of memory accessible by this read LSU
    //every LSU inside an opencl kernel is flushed each time that kernel starts (flush has no effect for LSUs without read cache)
    always_ff @(posedge clock) begin
        late_flush_cache <= i_flush_cache;
        flush_cache_posedge <= i_flush_cache & ~late_flush_cache;
    end
    
    //as an example, if CACHE_ADDR_BITS is 5, flush_counter is 6 bits, it starts the flush at 63, counts down to 31 and then gets stuck there
    //if we look at the bottom 5 of flush_counter, it sweeps the entire address space (from 31 down to 0, then 31 is where it rests)
    always_ff @(posedge clock or negedge aclrn) begin
        if (~aclrn) flush_counter <= '0;
        else begin
            if (flush_cache_posedge) flush_counter <= '1;
            else if (is_flushing) flush_counter <= flush_counter - 1'b1;
            if (~sclrn) flush_counter <= '0;
        end
    end
    assign is_flushing = flush_counter[CACHE_ADDR_BITS];
    
    //after the flush is done, keep the flush status live for another 2 clocks since cache memory has 2 clocks of read latency, still need to filter read data if the read request was issued before flush had finished
    always_ff @(posedge clock) begin
        //timing of flush_writing_done depends on PIPELINE_UPDATE_TO_CACHE, see the "update the cache" section below
        //after flush_writing_done asserts, any reads issued do not need to be masked because of flushing
        //after flush_reading_done asserts, any read data received from cache does not need to be masked because of flushing
        late_flush_writing_done <= flush_writing_done;
        flush_reading_done <= late_flush_writing_done;
    end
    
    
    
    ////////////////////////
    //  Update the Cache  //
    ////////////////////////
    
    // the cache only has one write port but it can be updated by two things:
    // 1. flush -- invalidate all cache lines
    // 2. snoop on read data returned from global memory -- this does not help the cache miss itself, it only may help a future read request to the same address
    // While flush is running, the cache does not update with data read from global memory
    
    //whatever cache line was accessed in the tag cache (valid and upper address), that same cache line is accessed in the data cache one clock cycle later
    //the upper address read from the tag cache needs to be compared against the byte address of the read request, as a part of checking whether the cache line is valid
    //one pipeline stage is used for this comparison, so only 1 clock cycle after the tag cache is read do we know if the cache line was valid
    //if we read the data cache at the same time as the tag cache, would need to keep the data live for one clock cycle before potentially writing it to the hit fifo
    //the choice to read the tag cache one clock ahead of the data cache is purely to save area
    
    //unfornately this slightly complicates things for the cache update, it must follow the same convention of update the tag cache one clock before the data cache for data consistency
    //if we updated the cache directly from the data returned from memory, we'd want to know one clock cycle ahead of time when readdatavalid is going to be 1 so we can update the tag
    //in reality that means we would have to delay readata by 1 clock, which means we are spending the register that we saved earlier
    //to solve this problem, the cache is updated by snooping on the data read from the rsp fifo
    //there is some lookahead circuitry which reserves a read from rsp_fifo one clock cycle before the fifo itself is actually read, this is the time when we update the tag cache
    
    generate
    if (!PIPELINE_UPDATE_TO_CACHE) begin : NO_PIPELINE_CACHE_UPDATE
        //the write enable and the write address to the m20k are being driven by combinational logic, but this is a narrow m20k and will probably only be a single physical m20k
        assign tag_cache_wr_en = is_flushing | addr_fifo_rd_ack;
        assign tag_cache_wr_addr = (is_flushing) ? flush_counter : addr_fifo_rd_data[CACHE_ADDR_BITS-1:0];
        assign tag_cache_wr_data = {~is_flushing, addr_fifo_rd_data[WORD_ADDR_WIDTH-1:CACHE_ADDR_BITS]};
        assign data_cache_wr_data = rsp_fifo_rd_data;
        assign flush_writing_done = ~is_flushing;
    end
    else begin : GEN_PIPELINE_CACHE_UPDATE  //if the cache is large and therefore physically spread far apart across the FPGA, this pipeline stage allows more time for routing
        always_ff @(posedge clock) begin
            tag_cache_wr_en <= is_flushing | addr_fifo_rd_ack;
            tag_cache_wr_addr <= (is_flushing) ? flush_counter : addr_fifo_rd_data[CACHE_ADDR_BITS-1:0];
            tag_cache_wr_data <= {~is_flushing, addr_fifo_rd_data[WORD_ADDR_WIDTH-1:CACHE_ADDR_BITS]};
            data_cache_wr_data <= rsp_fifo_rd_data;
            flush_writing_done <= ~is_flushing;
        end
    end
    endgenerate
    
    //tag contains both valid and upper_addr, split the read data into its components
    assign {valid_read_from_cache, upper_addr_read_from_cache} = tag_cache_rd_data;
    
    //access the same cache line in the data cache one clock after it was accessed in the tag cache
    always_ff @(posedge clock) begin
        data_cache_wr_en <= tag_cache_wr_en;
        data_cache_wr_addr <= tag_cache_wr_addr;
        data_cache_rd_addr <= tag_cache_rd_addr;
    end
    
    
    
    
    ////////////////////
    //  Cache Memory  //
    ////////////////////
    
    dla_hld_lsu_read_cache_simple_dual_port_ram #(
        .WIDTH      (UPPER_ADDR_BITS+1),
        .ADDR       (CACHE_ADDR_BITS)
    )
    tag_cache_inst
    (
        .clock      (clock),
        .wr_en      (tag_cache_wr_en),
        .wr_addr    (tag_cache_wr_addr),
        .wr_data    (tag_cache_wr_data),
        .rd_addr    (tag_cache_rd_addr),
        .rd_data    (tag_cache_rd_data)
    );
    
    dla_hld_lsu_read_cache_simple_dual_port_ram #(
        .WIDTH      (8*MEM_DATA_BYTES),
        .ADDR       (CACHE_ADDR_BITS)
    )
    data_cache_inst
    (
        .clock      (clock),
        .wr_en      (data_cache_wr_en),
        .wr_addr    (data_cache_wr_addr),
        .wr_data    (data_cache_wr_data),
        .rd_addr    (data_cache_rd_addr),
        .rd_data    (data_cache_rd_data)
    );
    
endmodule




module dla_hld_lsu_read_cache_simple_dual_port_ram #(
    parameter int WIDTH,
    parameter int ADDR      //depth is 2**ADDR
) (
    input  wire                 clock,
    //no reset
    
    //write port, no byteenable
    input  wire                 wr_en,
    input  wire      [ADDR-1:0] wr_addr,
    input  wire     [WIDTH-1:0] wr_data,
    
    //read port, read latency is 2 clocks (both input and output of altera_syncram is registered)
    input  wire      [ADDR-1:0] rd_addr,
    output logic    [WIDTH-1:0] rd_data
);

    //todo replace with new m20k/mlab wrapper when it becomes available
    altera_syncram #(   //modelsim library: altera_lnsim
        .numwords_a (2**ADDR),
        .numwords_b (2**ADDR),
        .address_aclr_b ("NONE"),
        .address_reg_b ("CLOCK0"),
        .rdcontrol_reg_b ("CLOCK0"),
        .byteena_reg_b ("CLOCK0"),
        .indata_reg_b ("CLOCK0"),
        .clock_enable_input_a ("BYPASS"),
        .clock_enable_input_b ("BYPASS"),
        .clock_enable_output_b ("BYPASS"),
        .intended_device_family ("Stratix 10"), //quartus will correct this automatically to whatever your project actually uses
        .lpm_type ("altera_syncram"),
        .operation_mode ("DUAL_PORT"),
        .outdata_aclr_b ("NONE"),
        .outdata_sclr_b ("NONE"),
        .outdata_reg_b ("CLOCK0"),
        .power_up_uninitialized ("TRUE"),
        .ram_block_type ("M20K"),
        .read_during_write_mode_mixed_ports ("DONT_CARE"),
        .widthad_a (ADDR),
        .widthad_b (ADDR),
        .width_a (WIDTH),
        .width_b (WIDTH),
        .width_byteena_a (1),
        .enable_ecc ("FALSE")
    )
    altera_syncram_inst
    (
        //clock, no reset
        .clock0     (clock),
        
        //write port
        .wren_a     (wr_en),
        .address_a  (wr_addr),
        .data_a     (wr_data),
        
        //read port
        .address_b  (rd_addr),
        .q_b        (rd_data),
        
        //unused
        .aclr0 (1'b0),
        .aclr1 (1'b0),
        .address2_a (1'b1),
        .address2_b (1'b1),
        .addressstall_a (1'b0),
        .addressstall_b (1'b0),
        .byteena_a (1'b1),
        .byteena_b (1'b1),
        .clock1 (1'b1),
        .clocken0 (1'b1),
        .clocken1 (1'b1),
        .clocken2 (1'b1),
        .clocken3 (1'b1),
        .data_b ({WIDTH{1'h1}}),
        .eccencbypass (1'b0),
        .eccencparity (8'b0),
        .eccstatus (),
        .q_a (),
        .rden_a (1'b1),
        .rden_b (1'b1),
        .sclr (1'b0),
        .wren_b (1'b0)
    );
    
endmodule


`default_nettype wire
