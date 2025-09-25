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

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//                                                                                                                                                                                      //
//  ACL DCFIFO                                                                                                                                                                          //
//  Designed and optimized by: Jason Thong                                                                                                                                              //
//                                                                                                                                                                                      //
//  DESCRIPTION                                                                                                                                                                         //
//  ===========                                                                                                                                                                         //
//  This dual clock fifo is intended to be a high fmax replacement for Altera's dcfifo, which is primarily used to transfer data from one clock domain to another. The read side of     //
//  this fifo is show-ahead and the read data is registered. This fifo is loosely based on dla_acl_mid_speed_fifo, for example the read prefetch has the same structure, including all  //
//  the caveats for dealing with MLAB vs M20K. Obviously there are adaptions for dealing with the clock crossing.                                                                       //
//                                                                                                                                                                                      //
//  REQUIRED FILES                                                                                                                                                                      //
//  ==============                                                                                                                                                                      //
//  - dla_acl_dcfifo.sv                                                                                                                                                                 //
//  - dla_acl_parameter_assert.svh                                                                                                                                                      //
//  - dla_acl_width_clip.svh                                                                                                                                                            //
//                                                                                                                                                                                      //
//  KEY DIFFERENCES FROM HLD_FIFO                                                                                                                                                       //
//  =============================                                                                                                                                                       //
//  - reset configuration cannot be chosen                                                                                                                                              //
//  - addresses are tessellated counters instead of LFSR                                                                                                                                //
//  - no support for earliness, just add registers outside of the fifo and let Quartus retime them                                                                                      //
//  - no special features like initial occupancy, write and read during full, etc.                                                                                                      //
//                                                                                                                                                                                      //
//  READ-SIDE HANDSHAKING                                                                                                                                                               //
//  =====================                                                                                                                                                               //
//  This fifo operates in showahead mode. When data written into the fifo eventually becomes readable, the fifo presents this to downstream by outputting rd_empty = 0. During this     //
//  time downstream may consume rd_data. When downstream wants the next read data, it sets rd_ack = 1 which will cause rd_empty and rd_data to update as of the next clock cycle. If    //
//  the fifo has still has readable data then rd_empty will stay 0 and rd_data will update, otherwise rd_empty will become 1 and rd_data will have arbitrary data. Note that rd_ack     //
//  is ignored when rd_empty = 0, so read acknowledge can be thought of as an active low backpressure from downstream.                                                                  //
//                                                                                                                                                                                      //
//  RESET                                                                                                                                                                               //
//  =====                                                                                                                                                                               //
//  Reset is incredibly difficult to get correct when dealing with multiple clocks. For instance, the reset associated with one clock may deassert before the other clock starts        //
//  running. To insulate the user from the subtleties of reset, the fifo has only 1 reset input which is assumed to be asynchronous. If one has a reset associated with each of the     //
//  clocks, merge them together when driving the fifo's input port (fifo expects reset active low, so AND your two resetn signals).                                                     //
//                                                                                                                                                                                      //
//  Internally, we produce several resets. On each clock domain, we produce an asynchronous reset that enters reset asynchronously but exits from reset synchronously (both clocks      //
//  must be running to exit reset). These are used to ensure the fifo never produces any spurious outputs, and will not be affected by receiving any spurious inputs. On each clock     //
//  domain, we produce synchronous resets for the internal logic, which should still enable hyper-retiming. During reset, the fifo appears as both full and empty (refuses to           //
//  transact with upstream or downstream).                                                                                                                                              //
//                                                                                                                                                                                      //
//  MEMORY ADDRESSING                                                                                                                                                                   //
//  =================                                                                                                                                                                   //
//  Unlike mid speed fifo which uses LFSRs to address the MLAB/M20K, this fifo uses tessellated counters. With 5 address bits for example, an LFSR can utilize 31 addresses, and the    //
//  prefetch adds one to the capacity, bringing the fifo capacity to 32. However, with independent read and write clocks, one can no longer guarantee that the prefetch will be         //
//  populated before the write address wraps around. To avoid this dependency, the addresses are implemented with counters so that all 32 memory locations can be accessed. One stage   //
//  of tessellation is used to limit the carry chain length, so the address sequence is not sequential. All that matters is the read address follows the same sequence that the write   //
//  address took. For example, a 4 bit address tessellated as 2+2 bits will have a sequence like this: 0 5 6 7 4 9 10 11 8 13 14 15 12 1 2 3.                                           //
//                                                                                                                                                                                      //
//  TIMING CONSTRAINTS AND CLOCK CROSSING INTERNALS                                                                                                                                     //
//  ===============================================                                                                                                                                     //
//  Unlike dcfifo, we do not need to supply an SDC file. Many clock crossing fifos gray code the read and write addresses before sending them to the other clock domain, the idea       //
//  being that only 1 bit should change at a time. To enforce that, a max skew timing contraint is needed. For details, refer to the SDC file that comes along with dcfifo.             //
//                                                                                                                                                                                      //
//  This fifo has totally different internals. Only the *updates* to the read and write addresses are sent across. In each direction, an update of +1, +2, and +4 can be sent. Each     //
//  of these updates are independent, and an update is sent by toggling a 1-bit register. All toggle signals are sent across to the other clock domain, and then they are synchronized  //
//  back to the original clock domain. The sender knows when the receiver has seen it, and thus when it is safe to send another update. Because each toggle signal crosses clock        //
//  domains independent from all the other toggle signals, there are no timing constraints needed. All paths between the write and read clocks can be treated as asynchronous.          //
//                                                                                                                                                                                      //
//  ALMOST FULL, ALMOST EMPTY, AND NEVER_OVERFLOWS                                                                                                                                      //
//  ==============================================                                                                                                                                      //
//  This fifo implements almost full and almost empty with exact timing. There is one clock of latency from wr_req to wr_almost_full, and from rd_ack to rd_almost_empty. Thresholds    //
//  are specified in terms of distance away from full and empty. For example, ALMOST_FULL_CUTOFF = 3 means wr_almost_full asserts when the write side occupancy is at least DEPTH-3.    //
//  If one ignores wr_full since wr_almost_full is being consumed as early backpressure to upstream, set NEVER_OVERFLOWS = 1 to remove the logic for wr_full. This will also make       //
//  wr_req no longer a request but it will now be a forced write.                                                                                                                       //
//                                                                                                                                                                                      //
//  RAM_BLOCK_TYPE                                                                                                                                                                      //
//  ==============                                                                                                                                                                      //
//  There are different implementations based on whether an M20K or MLAB is used. MLABs have a favorable feature of the read address not needing to be registered inside the memory     //
//  itself. Although we still drive the read address with a register, we now have access to the output of that register. For M20K this register is inside the M20K itself and thus      //
//  we have no access to its output. For M20K we have our own address register in ALM registers which always stays 1 ahead of the read address inside the M20K. Every time we update    //
//  our own read adddress, the clock enable for the M20K read address is asserted so that it captures the old value just before the update of own read address. The consequence of      //
//  this is we cannot let Quartus decide the RAM implementation, the FIFO needs to choose if the ram block type has not been explicitly set to M20K or MLAB by the user.                //
//                                                                                                                                                                                      //
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`include "dla_acl_parameter_assert.svh"
`include "dla_acl_width_clip.svh"

//this only exists to create a unique instance name for sdc wildcard matching
module dla_acl_dcfifo #(
    parameter int unsigned WIDTH,                             // width of the data path, 0 is allowed in which case no RAM is used
    parameter int unsigned DEPTH,                             // capacity of the fifo, at least 1
    parameter int unsigned ALMOST_FULL_CUTOFF = 0,            // rd_almost_empty asserts if read_used_words <= ALMOST_EMPTY_CUTOFF, fifo requires ALMOST_EMPTY_CUTOFF < DEPTH
    parameter int unsigned ALMOST_EMPTY_CUTOFF = 0,           // wr_almost_full asserts if write_used_words >= (DEPTH-ALMOST_FULL_CUTOFF), fifo requires ALMOST_FULL_CUTOFF < DEPTH
    parameter bit          NEVER_OVERFLOWS = 0,               // set to 1 to disable fifo's internal overflow protection, saves area by not generating logic for wr_full, and wr_req not predicated by wr_full
    parameter string       RAM_BLOCK_TYPE = "FIFO_TO_CHOOSE", // "MLAB" | "M20K" | "FIFO_TO_CHOOSE" -> if MLAB or M20K you will get what you ask for, otherwise the fifo will decide
    parameter bit          PIPELINE_AFTER_CLOCK_CROSS = 0,    // fmax optimization, add an extra pipeline stage after the clock crossers but before the counters, adds 1 wr and 1 rd clock cycle of latency
    parameter bit          HOLD_READ_DATA_WHEN_EMPTY = 0      // 0 means rd_data can be x when fifo is empty, 1 means rd_data will hold last value when fifo is empty (dcfifo behavior, may have fmax penalty)
) (
    input  wire                               async_resetn,             // asynchronous reset, internally we synchronize it to both clocks, if you have a resetn from each clock domain then AND them together

    //write interface
    input  wire                               wr_clock,                 // clock used by upstream logic
    input  wire                               wr_req,                   // upstream advertises it has data, a write only occurs when wr_req & (~wr_full | NEVER_OVERFLOWS)
    input  wire  [`DLA_ACL_WIDTH_CLIP(WIDTH)] wr_data,                  // data from upstream, must be synchronized with wr_req
    output logic                              wr_full,                  // inform upstream that we cannot accept data
    output logic                              wr_almost_full,           // early indication to upstream that soon fifo may no longer be able to accept data, threshold controlled by ALMOST_FULL_CUTOFF

    //read interface
    input  wire                               rd_clock,                 // clock used by downstream logic
    output logic                              rd_empty,                 // advertise to downstream that fifo is empty, a read only occurs when ~rd_empty & rd_ack
    output logic [`DLA_ACL_WIDTH_CLIP(WIDTH)] rd_data,                  // data to downstream, valid when rd_empty == 0
    input  wire                               rd_ack,                   // read acknowledge from downstream, ignored when fifo is empty -- this is like an active low backpressure from downstream
    output logic                              rd_almost_empty,          // early indication to downstream that soon fifo may no longer be able to supply data, threshold controlled by ALMOST_EMPTY_CUTOFF

    //specifically for use with dla_acl_clock_crossing_bridge, not to be used by anyone else
    output logic                    [2:0]     wr_read_update_for_ccb    // dla_acl_clock_crossing_bridge only: reads decrease the number of outstanding transactions but throttle logic is on write clock
);
    //////////////////////////
    //                      //
    //  Parameter settings  //
    //                      //
    //////////////////////////

    localparam int ADDR       = (DEPTH <= 8) ? 3 : $clog2(DEPTH);       //internals of fifo assume ADDR >= 3 and DEPTH being a power of 2 ...
    localparam int FULL_SLACK = 2**ADDR - DEPTH;                        //... for smaller or non-power-of-2 size fifos, simply reduce the threshold for full/almost_full
    localparam bit USE_MLAB   = (RAM_BLOCK_TYPE == "MLAB") ? 1 : (RAM_BLOCK_TYPE == "M20K") ? 0 : (ADDR <= 5) ? 1 : 0;    //0 = mlab, 1 = m20k



    //////////////////////////////////////
    //                                  //
    //  Sanity check on the parameters  //
    //                                  //
    //////////////////////////////////////

    generate
    `DLA_ACL_PARAMETER_ASSERT(DEPTH >= 1)
    `DLA_ACL_PARAMETER_ASSERT(ALMOST_FULL_CUTOFF < DEPTH)
    `DLA_ACL_PARAMETER_ASSERT(ALMOST_EMPTY_CUTOFF < DEPTH)
    localparam bit RAM_BLOCK_TYPE_IS_MLAB = RAM_BLOCK_TYPE == "MLAB";   //can't parse strings inside DLA_ACL_PARAMETER_ASSERT
    localparam bit RAM_BLOCK_TYPE_IS_M20K = RAM_BLOCK_TYPE == "M20K";
    localparam bit RAM_BLOCK_TYPE_IS_FIFO_TO_CHOOSE = RAM_BLOCK_TYPE == "FIFO_TO_CHOOSE";
    `DLA_ACL_PARAMETER_ASSERT(RAM_BLOCK_TYPE_IS_MLAB || RAM_BLOCK_TYPE_IS_M20K || RAM_BLOCK_TYPE_IS_FIFO_TO_CHOOSE)
    endgenerate



    ///////////////////////////
    //                       //
    //  Signal declarations  //
    //                       //
    ///////////////////////////

    // naming convention: all signal names begin with rd_ or wr_ and that indicates which clock domain it is on

    // reset
    logic wr_aclrn, rd_aclrn;                               //async resets are for masking output signals to ensure we don't generate anything spurious before both clocks are stable
    logic wr_sclrn, rd_sclrn;                               //sync resets are for internal registers, there is pipelining on the reset to enable retiming

    // write used words
    logic [ADDR:0] wr_used_words;                           //write side occupancy of fifo
    logic wr_write_into_fifo, wr_full_raw;                  //helpers

    // outstanding writes that have not yet been communicated to read side
    logic [ADDR-1:0] wr_leftover;                           //track the outstanding writes
    logic wr_leftover_hi_incr, wr_leftover_hi_decr;         //for tessellation of wr_leftover
    logic [2:0] wr_to_send, wr_toggle;                      //the update to send, which is actually sent by toggling
    logic [2:0] rd_toggle_from_wr, wr_toggle_readback;      //send update to other clock and then read it back so that we know the other side has seen it

    // process write update on rd_clock
    logic [2:0] rd_toggle_from_wr_prev;                     //keep the old value around...
    logic [2:0] rd_update_from_wr_raw, rd_update_from_wr;   //...to convert toggle into update, optionally register that update

    // reads available
    logic [ADDR:0] rd_available_negative;                   //how far the write address has advanced past the read address
    logic rd_wr_addr_ahead_of_rd_addr;                      //is the above nonzero

    // read prefetch
    logic rd_try_feed_prefetch, rd_feed_prefetch;           //prefetch helpers
    logic rd_prefetch_enable;                               //load enable for the prefetch
    logic rd_read_from_fifo, rd_valid_raw;                  //other helpers

    // outstanding reads that have not yet been communicated to write side
    logic [ADDR-1:0] rd_leftover;                           //same idea as on the other clock domain
    logic rd_leftover_hi_incr, rd_leftover_hi_decr;
    logic [2:0] rd_to_send, rd_toggle;
    logic [2:0] wr_toggle_from_rd, rd_toggle_readback;

    // process read update on wr_clock
    logic [2:0] wr_toggle_from_rd_prev;                     //same idea as on the other clock domain
    logic [2:0] wr_update_from_rd_raw, wr_update_from_rd;

    // memory block
    logic [ADDR-1:0] wr_addr, rd_addr;                      //write and read addresses for the MLAB or M20K
    logic rd_sclrn_prev;                                    //delayed reset - for incrementing the M20K read address at reset exit
    logic rd_addr_incr;                                     //increment for read address
    logic rd_m20k_addr_b_clock_en;                          //clock enable for the hardened read address register inside the M20K



    /////////////
    //         //
    //  Reset  //
    //         //
    /////////////

    dla_acl_dcfifo_reset_synchronizer dla_acl_dcfifo_reset_synchronizer_inst (
        .wr_clock       (wr_clock),
        .rd_clock       (rd_clock),
        .i_async_resetn (async_resetn),
        .o_wr_aclrn     (wr_aclrn),
        .o_rd_aclrn     (rd_aclrn),
        .o_wr_sclrn     (wr_sclrn),
        .o_rd_sclrn     (rd_sclrn)
    );



    ////////////////////////
    //                    //
    //  Write used words  //
    //                    //
    ////////////////////////

    // Track the number of words that have been written into the fifo. Increase by 1 when a write happens, decrease update is synchronized from rd_clock domain.
    assign wr_write_into_fifo = (NEVER_OVERFLOWS) ? wr_req : (wr_req & ~wr_full_raw);
    always_ff @(posedge wr_clock) begin
        wr_used_words <= wr_used_words + wr_write_into_fifo - wr_update_from_rd;
        if (~wr_sclrn) wr_used_words <= FULL_SLACK;
    end
    assign wr_full_raw = wr_used_words[ADDR];           //msb of counter
    assign wr_full = (~wr_aclrn) ? 1'b1 : wr_full_raw;  //backpressure during reset before the clocks are running



    ///////////////////////////////////////////////////////////////////////////
    //                                                                       //
    //  Outstanding writes that have not yet been communicated to read side  //
    //                                                                       //
    ///////////////////////////////////////////////////////////////////////////

    // The signal "wr_leftover" tracks the number of writes that have not yet been communicated to the read side. The update is communicated to the read side by toggling, and that toggle is
    // read back to know when the other side has seen it and therefore we can use it again. There are three completely independent toggle signals, which communicate an update of +1, +2, and
    // +4. We basically use bit slicing of wr_leftover to determine which updates can be sent:
    // -- if bit 0 of wr_leftover is 1, the +1 update can be sent (assuming the read back indicates the other side has seen a previous update),
    // -- if bit 1 of wr_leftover is 1, the +2 update can be sent,
    // -- if bits 2+ of wr_leftover are nonzero, the +4 update can be sent.
    // We don't try to be too smart about it, e.g. if wr_leftover is 2 and the +2 update is not ready for reuse, we will not sent a +1 update.

    // To increase fmax, wr_leftover has been tessellated, bits 2+ update one clock late. This means we can send a +4 update, and instead of bits 2+ of wr_leftover updating as of the next
    // clock, it updates one clock later. Since bits 2+ of wr_leftover are stale, we would want to send another +4 update, but the toggle read back logic will prevent this.

    // If wr_clock and rd_clock have similar frequency, then a toggle can be reused after roughly 6 clocks due to two 3-stage synchronizers. We can communicate an update of 7 every 6 clocks,
    // so there is little value in having a +8 update for example. If rd_clock is much faster than wr_clock, the toggle will be reusable in less than 6 wr_clock clocks, e.g. the update happens
    // faster. If wr_clock is much faster than rd_clock, the update happens slower, e.g. we cannot communicate the updates as fast as writes may come into the fifo. But this is not really a
    // problem since the read side wouldn't be able to drain the fifo that fast anyways. From the rd_clock perspective, updates are happening in fewer than 6 rd_clock clocks, e.g. the write
    // updates arrive on rd_clock faster than data can be read from the fifo.

    always_ff @(posedge wr_clock) begin
        wr_leftover[1:0] <= (wr_leftover[1:0] & ~wr_to_send[1:0]) + wr_write_into_fifo;
        //functionally equivalent to this:
        // wr_leftover[1:0] <= (wr_leftover[1:0] - wr_to_send[1:0]) + wr_write_into_fifo;
        //wr_to_send[0] can only be 1 when wr_leftover[0] is also 1, therefore the subtraction acts as a mask, likewise for bit 1
        wr_leftover_hi_incr <= (wr_leftover[1:0]==2'h3) & (wr_to_send[1:0]==2'h0) & wr_write_into_fifo; //upper bits increment if wr_write_into_fifo causes wraparound from 3 to 0
        wr_leftover_hi_decr <= wr_to_send[2];                                                           //upper bits decrement only when +4 update is sent
        if (wr_leftover_hi_incr & ~wr_leftover_hi_decr) wr_leftover[ADDR-1:2] <= wr_leftover[ADDR-1:2] + 1'b1;
        if (~wr_leftover_hi_incr & wr_leftover_hi_decr) wr_leftover[ADDR-1:2] <= wr_leftover[ADDR-1:2] - 1'b1;
        if (~wr_sclrn) wr_leftover <= '0;
    end

    // Based on wr_leftover and availability of toggle updates, determine what updates to send to the other clock domain.
    assign wr_to_send[0] = wr_leftover[0] & (wr_toggle[0] == wr_toggle_readback[0]);
    assign wr_to_send[1] = wr_leftover[1] & (wr_toggle[1] == wr_toggle_readback[1]);
    assign wr_to_send[2] = (|wr_leftover[ADDR-1:2]) & (wr_toggle[2] == wr_toggle_readback[2]);

    // Updates are communicated by toggling. Because of the feedback, we are guaranteed the signal will be stable for at least 3 clocks on the other clock domain.
    // Async resets are used since the registers have a dedicated port for async reset and no retiming is allowed at clock crossing boundaries.
    // Also note: The CDC here is not multi-bit. Each bit is considered separately and skew is handled/expected.

    logic[2:0] rd_toggle_from_wr_not_stable;

    // The nominally 3 meta stability flop chain is actually split across two separate modules.
    // The first is a 2-stage full sync module, the 3rd stage is provided by the input flop of the loopback 3-stage full synchronizer
    //
    // * The input flop of the full synchronizer has properties that restrict it from being retimed (which will impact MTBF).
    // * By placing the input flop inside the synchronizer module, we have control over its instance name and can match it against
    // constraints in order to provide a flop to flop constraint. (As opposed to half synchronizer which has only a -to constraint)
    // * We use a common CDC module, which will allow for a single constraint to match synchronizers throughout the design
    dla_clock_cross_full_sync #(
      .METASTABILITY_STAGES ( 2 )
    ) wr_toggle_inst [2:0] ( //send update to rd_clock
      .clk_src            ({3{wr_clock}}),
      .i_src_async_resetn ({3{wr_aclrn}}),
      .i_src_data         (wr_toggle ^ wr_to_send),
      .o_src_data         (wr_toggle),

      .clk_dst            ({3{rd_clock}}),
      .i_dst_async_resetn ({3{rd_aclrn}}),
      .o_dst_data         (rd_toggle_from_wr_not_stable)
    );

    dla_clock_cross_full_sync #(
      .METASTABILITY_STAGES ( 3 )
    ) wr_toggle_readback_inst [2:0] ( //sync that update back to wr_clock
      .clk_src            ({3{rd_clock}}),
      .i_src_async_resetn ({3{rd_aclrn}}),
      .i_src_data         (rd_toggle_from_wr_not_stable),
      .o_src_data         (rd_toggle_from_wr),

      .clk_dst            ({3{wr_clock}}),
      .i_dst_async_resetn ({3{wr_aclrn}}),
      .o_dst_data         (wr_toggle_readback)
    );

    ////////////////////////////////////////
    //                                    //
    //  Process write update on rd_clock  //
    //                                    //
    ////////////////////////////////////////

    // Convert toggle into update and add an optional pipeline stage before the update is consumed.

    always_ff @(posedge rd_clock or negedge rd_aclrn) begin
        if (~rd_aclrn) rd_toggle_from_wr_prev <= '0;
        else rd_toggle_from_wr_prev <= rd_toggle_from_wr;
    end
    assign rd_update_from_wr_raw = rd_toggle_from_wr ^ rd_toggle_from_wr_prev;

    generate
    if (PIPELINE_AFTER_CLOCK_CROSS) begin : GEN_RD_PIPELINE_AFTER_CLOCK_CROSS
        always_ff @(posedge rd_clock) begin
            rd_update_from_wr <= rd_update_from_wr_raw;
        end
    end
    else begin : NO_RD_PIPELINE_AFTER_CLOCK_CROSS
        assign rd_update_from_wr = rd_update_from_wr_raw;
    end
    endgenerate



    ///////////////////////
    //                   //
    //  Reads available  //
    //                   //
    ///////////////////////

    // The number of reads available is basically how far the write address has advanced past the read address. It is not the same as read used words, which indicates the number of words
    // readable from the fifo. To illustrate this, when reads available transitions from 0 to 1, the write has committed, but we have yet to read the data, so read used words is still 0,
    // and it will become 1 on the next clock cycle.

    // Natually, reads available would start at 0, and write into the fifo will increase it, and a read from the fifo will decrease it. To allow a read into the read prefetch, we are
    // interested in when reads available is at least 1, which is equivalent to it being nonzero. The implementation is actually the negative of reads available, e.g. writes into the fifo
    // decrease it. It still starts at 0, but then any nonzero value will be negative which has an MSB of 1.

    always_ff @(posedge rd_clock) begin
        rd_available_negative <= rd_available_negative + rd_feed_prefetch - rd_update_from_wr;
        if (~rd_sclrn) rd_available_negative <= '0;
    end
    assign rd_wr_addr_ahead_of_rd_addr = rd_available_negative[ADDR];   //this indicates we have data in memory for supplying to the read prefetch



    /////////////////////
    //                 //
    //  Read prefetch  //
    //                 //
    /////////////////////

    // The fifo is empty if and only if the prefetch is empty.

    assign rd_try_feed_prefetch = ~rd_valid_raw | rd_ack;                                               //is the prefetch empty or will be empty due to a read ...
    assign rd_feed_prefetch = rd_wr_addr_ahead_of_rd_addr & rd_try_feed_prefetch;                       //... and does the memory have data available for the prefetch
    assign rd_prefetch_enable = (!HOLD_READ_DATA_WHEN_EMPTY) ? rd_try_feed_prefetch : rd_feed_prefetch; //load enable for prefetch, simpler logic if rd_data = x when fifo is empty

    always_ff @(posedge rd_clock) begin
        if (rd_wr_addr_ahead_of_rd_addr) rd_valid_raw <= 1'b1;  //there is data to load into prefetch, getting populated or new data overriding old data, either way fifo is not empty
        else if (rd_ack) rd_valid_raw <= 1'b0;                  //there is no data to load into prefetch, and reading, fifo will become empty
        if (~rd_sclrn) rd_valid_raw <= 1'b0;
    end
    assign rd_empty = (~rd_aclrn) ? 1'b1 : ~rd_valid_raw;       //suppress during reset before the clocks are running
    assign rd_read_from_fifo = rd_valid_raw & rd_ack;



    ///////////////////////////////////////////////////////////////////////////
    //                                                                       //
    //  Outstanding reads that have not yet been communicated to write side  //
    //                                                                       //
    ///////////////////////////////////////////////////////////////////////////

    // Same idea as the other one. Outstanding reads increases when fifo is read, and decreases when that is communicated to the write side. Communication to
    // write side happens with toggles for +1, +2, and +4 updates.

    always_ff @(posedge rd_clock) begin
        rd_leftover[1:0] <= (rd_leftover[1:0] & ~rd_to_send[1:0]) + rd_read_from_fifo;
        rd_leftover_hi_incr <= (rd_leftover[1:0]==2'h3) & (rd_to_send[1:0]==2'h0) & rd_read_from_fifo;
        rd_leftover_hi_decr <= rd_to_send[2];
        if (rd_leftover_hi_incr & ~rd_leftover_hi_decr) rd_leftover[ADDR-1:2] <= rd_leftover[ADDR-1:2] + 1'b1;
        if (~rd_leftover_hi_incr & rd_leftover_hi_decr) rd_leftover[ADDR-1:2] <= rd_leftover[ADDR-1:2] - 1'b1;
        if (~rd_sclrn) rd_leftover <= '0;
    end

    //updates to send
    assign rd_to_send[0] = rd_leftover[0] & (rd_toggle[0] == rd_toggle_readback[0]);
    assign rd_to_send[1] = rd_leftover[1] & (rd_toggle[1] == rd_toggle_readback[1]);
    assign rd_to_send[2] = (|rd_leftover[ADDR-1:2]) & (rd_toggle[2] == rd_toggle_readback[2]);

    // See comments on CDC in the wr to rd section

    logic [2:0] wr_toggle_from_rd_not_stable;

    //which are actually sent by toggling
    dla_clock_cross_full_sync #(
      .METASTABILITY_STAGES ( 2 )
    ) rd_toggle_inst [2:0] ( //send to wr_clock
      .clk_src            ({3{rd_clock}}),
      .i_src_async_resetn ({3{rd_aclrn}}),
      .i_src_data         (rd_toggle ^ rd_to_send),
      .o_src_data         (rd_toggle),

      .clk_dst            ({3{wr_clock}}),
      .i_dst_async_resetn ({3{wr_aclrn}}),
      .o_dst_data         (wr_toggle_from_rd_not_stable)
    );

    dla_clock_cross_full_sync #(
      .METASTABILITY_STAGES ( 3 )
    ) rd_toggle_readback_inst [2:0] ( //sync that update back to rd_clock
      .clk_src            ({3{wr_clock}}),
      .i_src_async_resetn ({3{wr_aclrn}}),
      .i_src_data         (wr_toggle_from_rd_not_stable),
      .o_src_data         (wr_toggle_from_rd),

      .clk_dst            ({3{rd_clock}}),
      .i_dst_async_resetn ({3{rd_aclrn}}),
      .o_dst_data         (rd_toggle_readback)
    );

    ///////////////////////////////////////
    //                                   //
    //  Process read update on wr_clock  //
    //                                   //
    ///////////////////////////////////////

    // Convert toggle into update and add an optional pipeline stage before the update is consumed.

    always_ff @(posedge wr_clock) begin
        wr_toggle_from_rd_prev <= wr_toggle_from_rd;
    end
    assign wr_update_from_rd_raw = wr_toggle_from_rd ^ wr_toggle_from_rd_prev;

    generate
    if (PIPELINE_AFTER_CLOCK_CROSS) begin : GEN_WR_PIPELINE_AFTER_CLOCK_CROSS
        always_ff @(posedge wr_clock) begin
            wr_update_from_rd <= wr_update_from_rd_raw;
        end
    end
    else begin : NO_WR_PIPELINE_AFTER_CLOCK_CROSS
        assign wr_update_from_rd = wr_update_from_rd_raw;
    end
    endgenerate

    always_ff @(posedge wr_clock) begin
        wr_read_update_for_ccb <= wr_update_from_rd;    //export to ccb
    end



    ////////////////////
    //                //
    //  Memory block  //
    //                //
    ////////////////////

    // Usage of altdpram - unlike the M20K in which it is impossible to bypass the input registers (addresses, write data, write enable), for the MLAB it is possible to bypass the input
    // register for the read address. There is no parameterization of altera_syncram that supports this, hence the use of altdpram.

    // It is desirable to have access to the output of read address address. In the case of MLAB, the read address is driven by ALM registers. For M20K, we have no visibility on the output
    // of the read address register because this is a hardened register inside the M20K itself. For M20K we have our own read address in ALM registers which is always 1 ahead of the hardened
    // read address inside the M20K. Only when we update our read address, we assert the clock enable for the hardened read address inside the M20K, this way it always captures 1 value behind
    // what our ALM register read address is. The M20K read address clock enable is active during reset so that we can clock in the value of our ALM register read address, upon reset exit
    // the M20K clock enable is shut off and our read address advances 1 step forward.

    generate
    if (WIDTH > 0) begin : GEN_RAM
        if (USE_MLAB) begin : GEN_MLAB
            altdpram #(     //modelsim library: altera_mf
                .indata_aclr ("OFF"),
                .indata_reg ("INCLOCK"),
                .lpm_type ("altdpram"),
                .ram_block_type ("MLAB"),
                .outdata_aclr ("OFF"),
                .outdata_sclr ("OFF"),
                .outdata_reg ("OUTCLOCK"),          //output data is registered, clock enable for this is controlled by outclocken
                .rdaddress_aclr ("OFF"),
                .rdaddress_reg ("UNREGISTERED"),    //we own the read address, bypass the equivalent of the internal address_b from m20k
                .rdcontrol_aclr ("OFF"),
                .rdcontrol_reg ("UNREGISTERED"),
                .width (WIDTH),
                .widthad (ADDR),
                .width_byteena (1),
                .wraddress_aclr ("OFF"),
                .wraddress_reg ("INCLOCK"),
                .wrcontrol_aclr ("OFF"),
                .wrcontrol_reg ("INCLOCK")
            )
            altdpram_component (
                //write
                .inclock (wr_clock),
                .wren (wr_write_into_fifo),
                .data (wr_data),
                .wraddress (wr_addr),

                //read
                .outclock (rd_clock),
                .rdaddress (rd_addr),
                .outclocken (rd_prefetch_enable),
                .q (rd_data),

                //other
                .aclr (1'b0),
                .sclr (1'b0),
                .byteena (1'b1),
                .inclocken (1'b1),
                .rdaddressstall (1'b0),
                .rden (1'b1),
                .wraddressstall (1'b0)
            );
        end
        else begin : GEN_M20K
            altera_syncram #(   //modelsim library: altera_lnsim
                .numwords_a (2**ADDR),
                .numwords_b (2**ADDR),
                .address_aclr_b ("NONE"),
                .address_reg_b ("CLOCK1"),
                .clock_enable_input_a ("BYPASS"),
                .clock_enable_input_b ("BYPASS"),
                .clock_enable_output_b ("NORMAL"),      //clock enable for output data register is controlled by clocken1
                .enable_ecc ("FALSE"),
                .lpm_type ("altera_syncram"),
                .operation_mode ("DUAL_PORT"),
                .outdata_aclr_b ("NONE"),
                .outdata_sclr_b ("NONE"),
                .outdata_reg_b ("CLOCK1"),              //output data is registered
                .power_up_uninitialized ("TRUE"),
                .ram_block_type ("M20K"),
                .widthad_a (ADDR),
                .widthad_b (ADDR),
                .width_a (WIDTH),
                .width_b (WIDTH),
                .width_byteena_a (1)
            )
            altera_syncram
            (
                //write
                .clock0 (wr_clock),
                .wren_a (wr_write_into_fifo),
                .address_a (wr_addr),
                .data_a (wr_data),

                //read
                .clock1 (rd_clock),
                .address_b (rd_addr),
                .addressstall_b (~rd_m20k_addr_b_clock_en),
                .clocken1 (rd_prefetch_enable),
                .q_b (rd_data),

                //unused
                .aclr0 (1'b0),
                .aclr1 (1'b0),
                .address2_a (1'b1),
                .address2_b (1'b1),
                .addressstall_a (1'b0),
                .byteena_a (1'b1),
                .byteena_b (1'b1),
                .clocken0 (1'b1),
                .clocken2 (1'b1),
                .clocken3 (1'b1),
                .data_b ({WIDTH{1'b1}}),
                .eccencbypass (1'b0),
                .eccencparity (8'b0),
                .eccstatus (),
                .q_a (),
                .rden_a (1'b1),
                .rden_b (1'b1),
                .sclr (1'b0),
                .wren_b (1'b0)
            );
        end
    end
    endgenerate



    ////////////////////////////////
    //                            //
    //  Write and read addresses  //
    //                            //
    ////////////////////////////////

    dla_acl_dcfifo_addr_incr #(
        .ADDR   (ADDR)
    )
    wr_addr_inst
    (
        .clock  (wr_clock),
        .sclrn  (wr_sclrn),
        .incr   (wr_write_into_fifo),
        .addr   (wr_addr)
    );

    dla_acl_dcfifo_addr_incr #(
        .ADDR   (ADDR)
    )
    rd_addr_inst
    (
        .clock  (rd_clock),
        .sclrn  (rd_sclrn),
        .incr   (rd_addr_incr),
        .addr   (rd_addr)
    );

    // For M20K, during reset the clock enables are on so that the hardened read address inside the M20K captures our rd_addr. At the exit of reset, the clock enable is shut off and rd_addr
    // moves forward by 1. This ensure that rd_addr will always be 1 ahead of the hardened read address inside the M20K, as the clock enable logic is the same after the exit from reset.
    always_ff @(posedge rd_clock) begin
        rd_sclrn_prev <= rd_sclrn;
    end
    assign rd_addr_incr = (USE_MLAB) ? rd_feed_prefetch : (rd_feed_prefetch | ~rd_sclrn_prev);  //whether to advance rd_addr, which is implemented in ALM registers
    assign rd_m20k_addr_b_clock_en = rd_feed_prefetch | ~rd_sclrn;                              //clock enable for the hardened read address register inside the M20K



    ///////////////////
    //               //
    //  Almost full  //
    //               //
    ///////////////////


    generate
    if (ALMOST_FULL_CUTOFF == 0) begin : NO_ALMOST_FULL
        assign wr_almost_full = wr_full;
    end
    else begin : GEN_ALMOST_FULL
        // This basically is wr_used_words offset by ALMOST_FULL_CUTOFF. For example, when DEPTH = 32, we use a 6-bit counter. To generate the full signal, the counter would reset to 0 and
        // when it counts up to 32 (the MSB is 1) then full would assert. To generate almost_full with ALMOST_FULL_CUTOFF = 3 (e.g. almost full asserts when write used words is 29 or larger),
        // then simply start the counter at 3, and when it counts up to 32, 33, 34, or 35 (all cases where the MSB is 1) then almost_full asserts.
        logic [ADDR:0] wr_almost_full_counter;
        always_ff @(posedge wr_clock) begin
            wr_almost_full_counter <= wr_almost_full_counter + wr_write_into_fifo - wr_update_from_rd;
            if (~wr_sclrn) wr_almost_full_counter <= ALMOST_FULL_CUTOFF + FULL_SLACK;
        end
        assign wr_almost_full = (~wr_aclrn) ? 1'b1 : wr_almost_full_counter[ADDR];  //backpressure during reset before the clocks are running
    end
    endgenerate



    ////////////////////
    //                //
    //  Almost empty  //
    //                //
    ////////////////////

    generate
    if (ALMOST_EMPTY_CUTOFF == 0) begin : NO_ALMOST_EMPTY
        assign rd_almost_empty = rd_empty;
    end
    else begin : GEN_ALMOST_EMPTY
        // Think of rd_almost_empty_counter as an offset and negated version of read_used_words. Normally read_used_words would increase when a write becomes readable, and decrease when the
        // fifo is read. We invert this, e.g. writes cause a decrease, reads cause an increase. The idea is that enough writes will cause the value of rd_almost_empty_counter to go negative
        // (MSB = 1) which will shut off rd_almost_empty. How many writes are needed? When ALMOST_EMPTY_CUTOFF = 0, rd_almost_empty behaves the same way as empty. Only 1 write is needed for
        // empty to shut off, so rd_almost_empty_counter should start at 0, as 1 write would make it -1 (which has a MSB of 1). When ALMOST_EMPTY_CUTOFF = 1, 2 writes are needed, therefore
        // rd_almost_empty_counter starts at 1, as 2 writes make it negative.
        logic [2:0] rd_update_from_wr_prev;
        logic [ADDR:0] rd_almost_empty_counter;
        always_ff @(posedge rd_clock) begin
            rd_update_from_wr_prev <= rd_update_from_wr;
            rd_almost_empty_counter <= rd_almost_empty_counter + rd_read_from_fifo - rd_update_from_wr_prev;
            if (~rd_sclrn) begin
                rd_update_from_wr_prev <= '0;
                rd_almost_empty_counter <= ALMOST_EMPTY_CUTOFF;
            end
        end
        assign rd_almost_empty = (~rd_aclrn) ? 1'b1 : ~rd_almost_empty_counter[ADDR];   //backpressure during reset before the clocks are running
    end
    endgenerate



    //////////////////////////////
    //                          //
    //  Simulation only checks  //
    //                          //
    //////////////////////////////

    //synthesis translate_off
    int SIM_ONLY_wr_usedw;
    logic SIM_ONLY_wr_almost_full;
    always_ff @(posedge wr_clock) begin
        SIM_ONLY_wr_usedw <= SIM_ONLY_wr_usedw + wr_write_into_fifo - wr_update_from_rd;
        if (~wr_sclrn) SIM_ONLY_wr_usedw <= 0;
    end
    assign SIM_ONLY_wr_almost_full = (~wr_aclrn) ? 1'b1 : (SIM_ONLY_wr_usedw >= (DEPTH - ALMOST_FULL_CUTOFF));
    always_ff @(negedge wr_clock) begin
        if (wr_almost_full != SIM_ONLY_wr_almost_full) begin
            $display("wr almost full mismatch, time %t, instance %m\n", $realtime);
            $finish;
        end
        if (NEVER_OVERFLOWS && SIM_ONLY_wr_usedw > DEPTH) begin
            $display("dla_acl_dcfifo overflow, time %t, instance %m\n", $realtime);
            $finish;
        end
    end

    int SIM_ONLY_rd_usedw;
    logic [2:0] SIM_ONLY_rd_update_from_wr_prev;
    logic SIM_ONLY_rd_almost_empty;
    always_ff @(posedge rd_clock) begin
        SIM_ONLY_rd_update_from_wr_prev <= rd_update_from_wr;
        SIM_ONLY_rd_usedw <= SIM_ONLY_rd_usedw + SIM_ONLY_rd_update_from_wr_prev - rd_read_from_fifo;
        if (~rd_sclrn) begin
            SIM_ONLY_rd_update_from_wr_prev <= '0;
            SIM_ONLY_rd_usedw <= '0;
        end
    end
    assign SIM_ONLY_rd_almost_empty = (~rd_aclrn) ? 1'b1 : (SIM_ONLY_rd_usedw <= ALMOST_EMPTY_CUTOFF);
    always_ff @(negedge rd_clock) begin
        if (rd_almost_empty != SIM_ONLY_rd_almost_empty) begin
            $display("rd almost empty mismatch, time %t, instance %m\n", $realtime);
            $finish;
        end
    end
    //synthesis translate_on

endmodule
//end dla_acl_dcfifo



module dla_acl_dcfifo_addr_incr #(
    parameter int ADDR      //will be at least 3, enforced by dla_acl_dcfifo
) (
    input  wire             clock,
    input  wire             sclrn,
    input  wire             incr,
    output logic [ADDR-1:0] addr
);
    localparam ADDR_LO = ADDR / 2;
    localparam ADDR_HI = ADDR - ADDR_LO;
    logic [ADDR_LO-1:0] addr_lo;
    logic [ADDR_HI-1:0] addr_hi;
    logic addr_lo_wrap_n;
    always_ff @(posedge clock) begin
        if (incr) begin
            addr_lo <= addr_lo + 1'b1;
            addr_lo_wrap_n <= ~(&addr_lo);
            if (~addr_lo_wrap_n) addr_hi <= addr_hi + 1'b1;
        end
        if (~sclrn) begin
            addr_lo <= '0;
            addr_lo_wrap_n <= 1'b0;
            addr_hi <= '0;
        end
    end
    assign addr = {addr_hi, addr_lo};

endmodule

module dla_acl_dcfifo_reset_synchronizer (
    input  wire wr_clock,
    input  wire rd_clock,
    input  wire i_async_resetn,    //assumed to be asynchronous, if you have a resetn for each clock you should AND them together to drive this input port
    output wire o_wr_aclrn,        //for masking outputs on wr_clock
    output wire o_rd_aclrn,        //for masking outputs on rd_clock
    output wire o_wr_sclrn,        //for internal registers on wr_clock
    output wire o_rd_sclrn         //for internal registers on rd_clock
);
  //we must exit from reset on the read clock before exiting from reset on the write clock
  //the first ever cross-clock handshaking starts from the write side sending a toggle due to an incoming write into the fifo
  //it is simpler to reason about correctness if the read logic is already running e.g. not in reset

  //synchronize i_async_resetn to wr_clock -- enter reset asynchonously, but exit reset synchronously
  wire wr_resetn;

  dla_cdc_reset_async u_sync_wr_resetn (
    .clk            (wr_clock),
    .i_async_resetn (i_async_resetn),
    .o_async_resetn (wr_resetn)
  );

  //synchronize wr_resetn to rd_clock -- enter reset asynchonously, but exit reset synchronously
  //when i_async_resetn enters reset, o_rd_aclrn enters reset without any clocks running, but both clocks must be running for o_rd_aclrn AND o_rd_sclrn to exit reset
  dla_cdc_reset_aligned u_sync_rd_resetn (
    .clk            (rd_clock),
    .i_async_resetn (wr_resetn),
    .o_async_resetn (o_rd_aclrn),
    .o_sync_resetn  (o_rd_sclrn)
  );

  //synchronize o_rd_aclrn to wr_clock -- enter reset asynchonously, but exit reset synchronously
  dla_cdc_reset_aligned u_resync_wr_resetn (
    .clk            (wr_clock),
    .i_async_resetn (o_rd_aclrn),
    .o_async_resetn (o_wr_aclrn),
    .o_sync_resetn  (o_wr_sclrn)
  );

endmodule

`default_nettype wire
