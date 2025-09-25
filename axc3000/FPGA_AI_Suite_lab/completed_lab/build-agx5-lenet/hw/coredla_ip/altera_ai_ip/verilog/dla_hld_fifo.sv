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

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//                                                                                                                                                                                  //
//  HLD (High Level Design) FIFO                                                                                                                                                    //
//  Designed and optimized by: Jason Thong                                                                                                                                          //
//                                                                                                                                                                                  //
//  DESCRIPTION                                                                                                                                                                     //
//  ===========                                                                                                                                                                     //
//  Wrapper utility that selects which S10-optimized FIFO to use based on STYLE parameter. One can select whether to use the legacy stall/valid interface or the new stall latency  //
//  interface, separate selection for upstream and downstream interfaces.                                                                                                           //
//                                                                                                                                                                                  //
//  REQUIRED FILES                                                                                                                                                                  //
//  ==============                                                                                                                                                                  //
//  - dla_hld_fifo.sv                                                                                                                                                                   //
//  - dla_acl_reset_handler.sv                                                                                                                                                          //
//  - dla_acl_zero_latency_fifo.sv                                                                                                                                                      //
//  - dla_acl_low_latency_fifo.sv                                                                                                                                                       //
//  - dla_acl_high_speed_fifo.sv                                                                                                                                                        //
//  - dla_acl_lfsr.sv                                                                                                                                                                   //
//  - dla_acl_tessellated_incr_decr_threshold.sv                                                                                                                                        //
//  - dla_acl_tessellated_incr_lookahead.sv                                                                                                                                             //
//  - dla_acl_mid_speed_fifo.sv                                                                                                                                                         //
//  - dla_acl_latency_one_ram_fifo.sv                                                                                                                                                   //
//  - dla_acl_latency_zero_ram_fifo.sv                                                                                                                                                  //
//                                                                                                                                                                                  //
//  WRITE TO READ LATENCY                                                                                                                                                           //
//  =====================                                                                                                                                                           //
//  FIFOs are fundamentally designed differently if one wants storage in memory versus in registers. Registers provide simple way to achieve low write to read latency. Adding      //
//  bypass logic to the prefetch of a memory-based FIFO hurts area and fmax. Conceptually, a FIFO will track two types of occupancy:                                                //
//  1. write_used_words:                                                                                                                                                            //
//      - tracks how many words have been written into the FIFO                                                                                                                     //
//      - increments one clock after write (on the next clock edge when write is asserted), decrements one clock after read ack                                                     //
//      - backpressure to upstream (o_stall and o_almost_full) are based on this value                                                                                              //
//  2. read_used_words:                                                                                                                                                             //
//      - tracks how many words are readable from the FIFO                                                                                                                          //
//      - increments WRITE_TO_READ_LATENCY clocks after write, decrements one clock after read ack                                                                                  //
//      - data availability to downstream (valid_out and almost_empty) are based on this value                                                                                      //
//  If WRITE_TO_READ_LATENCY >= 2 then write_used_words increments before read_used_words. The interpretation is that something written into the FIFO takes some time before that   //
//  same item is readable. If WRITE_TO_READ_LATENCY == 1 then write_used_words is the same as read_used_words. If WRITE_TO_READ_LATENCY == 0 then read_used_words increments        //
//  *BEFORE* write_used_words. It may sound like something is readable before it has been written to the FIFO, but the correct interpretation is that data can bypass the storage   //
//  associated with a FIFO. This happens when an empty FIFO is written to and read from on the same clock.                                                                          //
//                                                                                                                                                                                  //
//  SUPPORTED FIFO IMPLEMENTATIONS                                                                                                                                                  //
//  ==============================                                                                                                                                                  //
//  Set the STYLE parameter to choose which underlying FIFO to use. Earliness is discussed below.                                                                                   //
//                                                                                                                                                                                  //
//  STYLE   | Implementation            | Write to     | Storage      | Maximum useful     | Maximum useful     | Intended                                                          //
//          |                           | read latency |              | STALL_IN_EARLINESS | VALID_IN_EARLINESS | usage                                                             //
//  --------+---------------------------+--------------+--------------+--------------------+--------------------+------------------------------------                               //
//  "hs"    | dla_acl_high_speed_fifo       |       5      | M20K or MLAB |         3          |          0         | Highest fmax                                                      //
//  "llreg" | dla_acl_low_latency_fifo      |       1      | Registers    |         1          |          1         | Shallow fifo if low latency needed                                //
//  "zlreg" | dla_acl_zero_latency_fifo     |       0      | Registers    |         1          |          1         | Shallow fifo if zero latency needed                               //
//  "ms"    | dla_acl_mid_speed_fifo        |       3      | M20K or MLAB |         2          |          1         | Lowest area                                                       //
//  "llram" | dla_acl_latency_one_ram_fifo  |       1      | M20K or MLAB |         1          |          1         | Deep fifo if low latency needed                                   //
//  "zlram" | dla_acl_latency_zero_ram_fifo |       0      | M20K or MLAB |         1          |          1         | Deep fifo if zero latency needed                                  //
//                                                                                                                                                                                  //
//  STYLE can also be set to "ll" in which case dla_hld_fifo will make a decision on whether to use "llreg" or "llram" based on the WIDTH and DEPTH in order to minimize area. This is  //
//  the recommended way to ask for a latency one fifo. If you explicitly ask for "llram" or "llreg" you will get what you ask for. Same applies to zero latency with STYLE = "zl".  //
//                                                                                                                                                                                  //
//  LATENCY SPECIFICATION OF ALL FIFO IMPLEMENTATIONS                                                                                                                               //
//  =================================================                                                                                                                               //
//  Category        | Latency               | Example signals    | In plain English                                                                                                 //
//  ----------------+-----------------------+--------------------+----------------------------------------------------------------                                                  //
//  write -> write  | 1                     | i_valid to o_stall | Number of clocks it takes for write request to affect fifo full status                                           //
//  write -> read   | WRITE_TO_READ_LATENCY | i_valid to o_valid | Number of clocks it takes for write request to affect fifo empty status                                          //
//  read -> write   | 1                     | i_stall to o_stall | Number of clocks it takes for read request to affect fifo full status                                            //
//  read -> read    | 1                     | i_stall to o_valid | Number of clocks it takes for read request to affect fifo empty status                                           //
//                                                                                                                                                                                  //
//  ALMOST FULL AND ALMOST EMPTY                                                                                                                                                    //
//  ============================                                                                                                                                                    //
//  The ALMOST_***_CUTOFF parameters refer to how much dead space would be in the fifo if one were to use almost_full as same clock cycle backpressure (dead space in not being     //
//  able to completely fill the fifo), or if one were to almost_empty as same clock cycle underflow prevention (dead space in not being able to empty the fifo). See chart below    //
//  for interpretation of values:                                                                                                                                                   //
//                                                                                                                                                                                  //
//  Scfifo parameter                    | Our parameter             | Interpretation                                                                                                //
//  ------------------------------------+---------------------------+---------------------------------------------------------------                                                //
//  almost_empty_value = 1              | ALMOST_EMPTY_CUTOFF = 0   | almost_empty behaves the same way as empty                                                                    //
//  almost_empty_value = 2              | ALMOST_EMPTY_CUTOFF = 1   | almost_empty asserts when read_used_words is 1 or less                                                        //
//  ------------------------------------+---------------------------+---------------------------------------------------------------                                                //
//  almost_full_value = lpm_numwords    | ALMOST_FULL_CUTOFF = 0    | almost_full behaves the same way as full                                                                      //
//  almost_full_value = lpm_numwords-1  | ALMOST_FULL_CUTOFF = 1    | almost_full asserts when write_used_words is DEPTH-1 or higher                                                //
//                                                                                                                                                                                  //
//  INITIAL OCCUPANCY                                                                                                                                                               //
//  =================                                                                                                                                                               //
//  The parameter INITIAL_OCCUPANCY describes the number of words of garbage data in the fifo as it exits from reset. Typically this is 0, e.g. we have to write into the fifo      //
//  before anything is readable. If INITIAL_OCCUPANCY > 0, then valid_out is 0 during reset, and when it eventually asserts it is then safe for downstream to transact reads from   //
//  the fifo. Exit from reset should be handled separately for upstream and downstream. In particular, the assertion of valid_out (to downstream) and the deassertion of stall_out  //
//  (to upstream) may not happen on the same clock cycle. If INITIAL_OCCUPANCY == DEPTH, one cannot use stall_out to observe reset exit, only when at least one item has been read  //
//  from the fifo will stall_out then deasert.                                                                                                                                      //
//                                                                                                                                                                                  //
//  OPTIMIZATION STRATEGIES                                                                                                                                                         //
//  =======================                                                                                                                                                         //
//  To improve fmax and reduce area, one should provide control signals earlier than the corresponding data. This is controlled by the following parameters:                        //
//  STALL_IN_EARLINESS:                                                                                                                                                             //
//      - how many clock cycles ahead of time does downstream indicate it cannot accept data                                                                                        //
//      - if downstream has capacity, then almost full from downstream can drive the stall port of the fifo                                                                         //
//  VALID_IN_EARLINESS:                                                                                                                                                             //
//      - how many clock cycles ahead of time does upstream indicate it can provide data                                                                                            //
//      - decide on whether to accept data into the fifo ahead of time, then the data arrives later e.g. could hide the latency of upstream reading that data out of a memory       //
//                                                                                                                                                                                  //
//  One can set arbitrarily large values for earliness in dla_hld_fifo, anything in excess of what the underlying fifo can use will be absorbed in pipeline registers inside dla_hld_fifo.  //
//  There is little to be gained beyond the maximum earliness supported by the underlying fifo unless the fifo is extremely wide (thousands of bits in which case excess earliness  //
//  can potentally be retimed into the fifo). See above chart for the maximum useful earliness.                                                                                     //
//                                                                                                                                                                                  //
//  RESET CONFIGURATION                                                                                                                                                             //
//  ===================                                                                                                                                                             //
//  One may consume the reset asynchronously (ASYNC_RESET=1) or synchronously (ASYNC_RESET=0), but not both at the same time. Reset *CONSUMPTION* is separate from *DISTRIBUTION*.  //
//  For example, we could consume reset synchronously but distribute it asynchronously e.g. using a global clock line. Local synchronizers are used before reset is consumed if     //
//  SYNCHRONIZE_RESET=1, otherwise we assume one has externally managed the synchronous release of reset. RESET_EVERYTHING does as the name implies and is intended for partial     //
//  reconfiguration debug. Finally, typically in a pipeline of valids only the first and last are reset, so reset must be held to flush the pipeline. A reset pulse stretcher is    //
//  used, unless RESET_EXTERNALLY_HELD=1 in which case we assume reset will be held for sufficiently long (5 clocks for this module).                                               //
//                                                                                                                                                                                  //
//  RECOMMENDED RESET SETTINGS                                                                                                                                                      //
//  ==========================                                                                                                                                                      //
//  General usage is intended for when one is unsure about the reset. The HLD platform has specific reset properties so that we can e.g. remove the reset pulse stretcher.          //
//  Parameter             | General usage A10 | General usage S10 |   HLD A10   |   HLD S10                                                                                         //
//  ----------------------+-------------------+-------------------+-------------+-------------                                                                                      //
//  ASYNC_RESET           |        1          |         0         |     1       |      0                                                                                            //
//  SYNCHRONIZE_RESET     |        1          |         1         |     0       |      1                                                                                            //
//  RESET_EVERYTHING      |        0          |         0         |     0       |      0                                                                                            //
//  RESET_EXTERNALLY_HELD |        0          |         0         |     1       |      1                                                                                            //
//                                                                                                                                                                                  //
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`include "dla_acl_parameter_assert.svh"

module dla_hld_fifo #(
    //basic fifo configuration
    parameter int WIDTH,                        // width of data path, at least 0
    parameter int DEPTH,                        // capacity of the fifo, at least 1

    //occupancy
    parameter int ALMOST_EMPTY_CUTOFF = 0,      // o_almost_empty asserts if read_used_words <= ALMOST_EMPTY_CUTOFF
    parameter int ALMOST_FULL_CUTOFF = 0,       // o_almost_full/o_stall asserts if write_used_words >= (DEPTH-ALMOST_FULL_CUTOFF), applies to o_almost_full if USE_STALL_LATENCY_UPSTREAM = 0, otherwise applies to o_stall
    parameter int INITIAL_OCCUPANCY = 0,        // number of words in the fifo (write side occupancy) when it comes out of reset, note it still takes WRITE_TO_READ_LATENCY clocks for this to become visible on the read side

    //reset configuration
    parameter bit ASYNC_RESET = 0,              // how do we use reset: 1 means registers are reset asynchronously, 0 means registers are reset synchronously
    parameter bit SYNCHRONIZE_RESET = 1,        // based on how reset gets to us, what do we need to do: 1 means synchronize reset before consumption (if reset arrives asynchronously), 0 means passthrough (managed externally)
    parameter bit RESET_EVERYTHING = 0,         // intended for partial reconfig debug, set to 1 to reset every register (normally async reset excludes data path and sync reset additionally excludes some control signals)
    parameter bit RESET_EXTERNALLY_HELD = 1,    // set to 1 if resetn will be held for at least FIVE clock cycles, otherwise we will internally pulse stretch reset before consumption

    //special configurations for higher fmax / lower area
    parameter int STALL_IN_EARLINESS = 0,       // how many clock cycles ahead i_stall is, enables internal manual retiming
    parameter int VALID_IN_EARLINESS = 0,       // how many clock cycles ahead i_valid is, enables internal manual retiming
    parameter int STALL_IN_OUTSIDE_REGS = 0,    // number of registers on the stall-in path external to this module that will delay the propagation of x values on reset
    parameter int VALID_IN_OUTSIDE_REGS = 0,    // number of registers on the valid-in path external to this module that will delay the propagation of x values on reset
    parameter int REGISTERED_DATA_OUT_COUNT = 0,// how many lower bits of o_data are registered (upper bits are unregistered)
    parameter bit NEVER_OVERFLOWS = 0,          // set to 1 to disable fifo's internal overflow protection, area savings for hs by removing one incr/decr/thresh, stall_out still asserts during reset but won't mask valid_in
    parameter int MAX_SLICE_WIDTH = 0,          // 0 means no slicing, anything higher specifies the maximum width of the sub-FIFOs into which this FIFO will be split, and which will be width-stitched together
                                                // to create the FIFO of the width specified above. Width slicing registers stall-in and valid-in signals to each sub-FIFO to mitigate fanout impact if WIDTH is large

    //special features that typically have an fmax penalty
    parameter bit HOLD_DATA_OUT_WHEN_EMPTY = 0,     // 0 means o_data can be x when fifo is empty, 1 means o_data will hold last value when fifo is empty (scfifo behavior, has fmax penalty)
    parameter bit WRITE_AND_READ_DURING_FULL = 0,   //set to 1 to allow writing and reading while the fifo is full, this may have an fmax penalty, to compensate it is recommended to use this with NEVER_OVERFLOWS = 1

    //interface selection
    parameter bit USE_STALL_LATENCY_UPSTREAM = 0,   // 0 means use legacy stall/valid, 1 means use new stall latency, applies to upstream interface: i_valid, i_data, o_stall, o_almost_full
    parameter bit USE_STALL_LATENCY_DOWNSTREAM = 0, // 0 means use legacy stall/valid, 1 means use new stall latency, applies to downstream interface: o_valid, o_data, i_stall, o_almost_empty, o_empty

    //ram implementation for fifos that use ram for data storage
    parameter string RAM_BLOCK_TYPE = "FIFO_TO_CHOOSE", // "MLAB" | "M20K" | "AUTO" | "FIFO_TO_CHOOSE" -> ram_block_type parameter of altera_syncram, if MLAB or M20K you will get what you ask for, AUTO means Quartus chooses,
                                                        //                                                FIFO_TO_CHOOSE means we choose a value and then tell Quartus (typically based on depth of fifo)

    //fifo selection
    parameter string STYLE = "hs",              // see above table, legal values are "hs", "ms", "ll", "llreg", "llram", "zl", "zlreg", "zlram"
    parameter enable_ecc = "FALSE"              // Enable error correction coding

)
(
    input  wire                 clock,
    input  wire                 resetn,         // reset is ACTIVE LOW, see description above for different reset modes

                                                // Legacy stall/valid behavior                                                  | New stall latency behavior                                     | Reset value
    //upstream interface                        // -----------------------------------------------------------------------------+----------------------------------------------------------------+------------
    input  wire                 i_valid,        // upstream has data, fifo IS ALLOWED to consume it                             | upstream has data, fifo MUST consume it or data will be lost   | N/A
    input  wire     [WIDTH-1:0] i_data,         // data from upstream, synced with i_valid delayed by VALID_IN_EARLINESS clocks | <-- same behavior                                              | N/A
    output logic                o_stall,        // backpressure to upstream, fifo is full                                       | backpressure to upstream, fifo is almost full                  | 1
    output logic                o_almost_full,  // fifo is almost full, hint to upstream of potential future backpressure       | NOT USED, do not consume this output signal                    | 1
                                                //                                                                              |                                                                |
    //downstream interface                      // -----------------------------------------------------------------------------+----------------------------------------------------------------+------------
    output logic                o_valid,        // fifo has data, downstream IS ALLOWED to consume it                           | fifo has data, downstream MUST consume it or data will be lost | 0
    output logic    [WIDTH-1:0] o_data,         // data to downstream, synced with o_valid                                      | <-- same behavior                                              | x
    input  wire                 i_stall,        // backpressure from downstream STALL_IN_EARLINESS clocks ahead of time         | <-- same behavior                                              | N/A
    output logic                o_almost_empty, // fifo is almost empty, hint to downstream of potential future fifo emptiness  | <-- same behavior                                              | 1
    output logic                o_empty,        // fifo is empty right now                                                      | <-- same behavior                                              | 1

    //other
    output logic          [1:0] ecc_err_status
);


    //////////////////////////////////////
    //                                  //
    //  Sanity check on the parameters  //
    //                                  //
    //////////////////////////////////////

    // each underlying fifo enforces a limit on the maximum earliness in order to limit the delay of exiting from reset "safe state"
    // the checks are done in Quartus pro and Modelsim, it is disabled in Quartus standard because it results in a syntax error (parser is based on an older systemverilog standard)
    // the workaround is to use synthesis translate to hide this from Quartus standard, ALTERA_RESERVED_QHD is only defined in Quartus pro, and Modelsim ignores the synthesis comment
    `ifdef ALTERA_RESERVED_QHD
    `else
    //synthesis translate_off
    `endif

    generate
        `DLA_ACL_PARAMETER_ASSERT_MESSAGE((STYLE == "hs" || STYLE == "ms" || STYLE == "ll" || STYLE == "llreg" || STYLE == "llram" || STYLE == "zl" || STYLE == "zlreg" || STYLE == "zlram"), $sformatf("dla_hld_fifo: illegal value of STYLE = %s, legal values are \"hs\", \"ms\", \"ll\", \"llreg\", \"llram\", \"zl\", \"zlreg\", or \"zlram\"\n", STYLE))
        `DLA_ACL_PARAMETER_ASSERT_MESSAGE((MAX_SLICE_WIDTH <= 0) || (VALID_IN_OUTSIDE_REGS <= 0 && STALL_IN_OUTSIDE_REGS <= 0),  $sformatf("dla_hld_fifo: did not expect outside stall/valid regs to be present if width-slicing is enabled"))
    endgenerate


    `ifdef ALTERA_RESERVED_QHD
    `else
    //synthesis translate_on
    `endif



    // for simulation testbench only, these are properties of the fifo which are consumed by the testbench
    // synthesis translate_off
    logic fifo_in_reset;
    int WRITE_TO_READ_LATENCY;
    int RESET_EXT_HELD_LENGTH;
    int MAX_CLOCKS_TO_ENTER_SAFE_STATE;
    int MAX_CLOCKS_TO_EXIT_SAFE_STATE;
    // synthesis translate_on



    // to assist in debug of surrounding logic outside of hld_fifo -- signals of interest are named sim_only_debug_***
    // technically this is synthesizable logic, but it would degrade fmax and it is not hooked up to anything
    // synthesis translate_off
    localparam bit SIM_ONLY_DEBUG_ENABLE_ALL = 1;           //helper to turn on all debug features
    localparam bit SIM_ONLY_DEBUG_TRACK_STATS = 0;          //set to 1 to enable tracking of total writes, total reads, occupancy (write used words), and max occupancy
    localparam bit SIM_ONLY_DEBUG_ERROR_ON_X_INPUT = 0;     //set to 1 to cause simulation to error if i_valid or i_stall is x or z, not allowed once reset has been deasserted
    localparam bit SIM_ONLY_DEBUG_ERROR_ON_OVERFLOW = 0;    //set to 1 to cause simulation to error if overflow happens, which can only happen if NEVER_OVERFLOWS=1
    generate
    if (SIM_ONLY_DEBUG_ENABLE_ALL || SIM_ONLY_DEBUG_TRACK_STATS || SIM_ONLY_DEBUG_ERROR_ON_OVERFLOW) begin
        int sim_only_debug_total_writes, sim_only_debug_total_reads, sim_only_debug_occupancy, sim_only_debug_max_occupancy;
        logic sim_only_debug_write_into_fifo, sim_only_debug_read_from_fifo;

        genvar g;
        logic [STALL_IN_EARLINESS:0] pipe_i_stall;
        logic [VALID_IN_EARLINESS:0] pipe_i_valid;
        logic correct_timing_i_stall, correct_timing_i_valid;
        always_comb begin
            pipe_i_stall[0] = i_stall;
            pipe_i_valid[0] = i_valid;
        end
        for (g=1; g<=STALL_IN_EARLINESS; g++) begin
            always_ff @(posedge clock) begin
                pipe_i_stall[g] <= pipe_i_stall[g-1];
            end
        end
        for (g=1; g<=VALID_IN_EARLINESS; g++) begin
            always_ff @(posedge clock) begin
                pipe_i_valid[g] <= pipe_i_valid[g-1];
            end
        end
        assign correct_timing_i_stall = pipe_i_stall[STALL_IN_EARLINESS];
        assign correct_timing_i_valid = pipe_i_valid[VALID_IN_EARLINESS];

        //tracks whether a fifo write or read is currently happening
        assign sim_only_debug_write_into_fifo = (USE_STALL_LATENCY_UPSTREAM) ? correct_timing_i_valid : correct_timing_i_valid & ~o_stall;
        assign sim_only_debug_read_from_fifo = ~o_empty & ~correct_timing_i_stall;

        //keep track of how many writes and reads have happened since reset
        always_ff @(posedge clock or negedge resetn) begin
            if (~resetn) begin
                sim_only_debug_total_writes <= INITIAL_OCCUPANCY;
                sim_only_debug_total_reads <= '0;
                sim_only_debug_max_occupancy <= '0;
            end
            else begin
                sim_only_debug_total_writes <= sim_only_debug_total_writes + sim_only_debug_write_into_fifo;
                sim_only_debug_total_reads <= sim_only_debug_total_reads + sim_only_debug_read_from_fifo;
                if (sim_only_debug_occupancy > sim_only_debug_max_occupancy) sim_only_debug_max_occupancy <= sim_only_debug_occupancy;
            end
        end

        //how many words have been written to but have no yet been read from the fifo -- this is equivalent to write used words
        assign sim_only_debug_occupancy = sim_only_debug_total_writes - sim_only_debug_total_reads;

        if (SIM_ONLY_DEBUG_ENABLE_ALL || SIM_ONLY_DEBUG_ERROR_ON_OVERFLOW) begin
            always_ff @(posedge clock) begin
                if (sim_only_debug_occupancy > DEPTH) begin
                    $fatal(1, "dla_hld_fifo instance %m : overflow, write used words is %d\n", sim_only_debug_occupancy);
                end
            end
        end
    end
    if (SIM_ONLY_DEBUG_ENABLE_ALL || SIM_ONLY_DEBUG_ERROR_ON_X_INPUT) begin
        logic sim_only_debug_seen_resetn_is_zero;
        initial begin
            sim_only_debug_seen_resetn_is_zero = 1'b0;
            wait (resetn === 1'b0);
            sim_only_debug_seen_resetn_is_zero = 1'b1;
        end
        always_ff @(posedge clock) begin
            if (sim_only_debug_seen_resetn_is_zero && (resetn === 1'b1) && ((i_valid === 1'bx) || (i_valid === 1'hz))) begin
                $fatal(1, "dla_hld_fifo instance %m : i_valid is %x\n", i_valid);
            end
            //technically i_stall=x should be illegal once out of reset, but fifo always protects itself from underflow, so ignore if fifo is empty
            if (sim_only_debug_seen_resetn_is_zero && (resetn === 1'b1) && (~o_empty) && ((i_stall === 1'bx) || (i_stall === 1'hz))) begin
                $fatal(1, "dla_hld_fifo instance %m : i_stall is %x\n", i_stall);
            end
        end
    end
    endgenerate
    // synthesis translate_on



    ////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                                                                                        //
    //  Implement width slicing, if enabled. Otherwise instantiate one FIFO of the style and width requested  //
    //                                                                                                        //
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////

    genvar z;
    generate

    //Width slicing is only enabled if MAX_SLICE_WIDTH > 0. But we also want to avoid slicing if we only get one slice
    //(in which case registers on valid/stall will steal earliness from the underlying module for no reason).
    localparam int SLICE_WIDTH = get_slice_width(MAX_SLICE_WIDTH);
    localparam int NUM_SLICES = (MAX_SLICE_WIDTH > 0) ? ((WIDTH-1)/SLICE_WIDTH)+1 : 1;
    if (NUM_SLICES > 1) begin
      //width-slicing enabled -- break up this FIFO into multiple sub-FIFOs
      localparam int MIN_USEFUL_SLICE_WIDTH = 256;  //TODO make this less arbitrary

      initial begin
        if (MAX_SLICE_WIDTH < MIN_USEFUL_SLICE_WIDTH) begin
          $warning("Specified MAX_SLICE_WIDTH %d, which is smaller than min useful slice width %d.", MAX_SLICE_WIDTH, MIN_USEFUL_SLICE_WIDTH);
        end
      end

      //set number of slices
      localparam int SLICE_REMAINDER = WIDTH % SLICE_WIDTH;
      //slice REGISTERED_DATA_OUT_COUNT as well (lower sub-FIFOs receive registered bits, higher sub-FIFOs do not)
      localparam int NUM_REGDATAOUT_SLICES = ((REGISTERED_DATA_OUT_COUNT-1)/SLICE_WIDTH)+1;
      localparam int REGDATAOUT_REMAINDER = REGISTERED_DATA_OUT_COUNT % SLICE_WIDTH;

      //handle signal assignment
      logic [NUM_SLICES-1:0] i_valid_dups; /* synthesis dont_merge */
      logic [NUM_SLICES-1:0] o_stall_dups;
      logic [NUM_SLICES-1:0] o_almost_full_dups;
      logic [NUM_SLICES-1:0] o_valid_dups;
      logic [NUM_SLICES-1:0] i_stall_dups; /* synthesis dont_merge */
      logic [NUM_SLICES-1:0] o_almost_empty_dups;
      logic [NUM_SLICES-1:0] o_empty_dups;
      logic [NUM_SLICES-1:0] ecc_err_status_dups [1:0];

      assign o_stall = o_stall_dups[0];
      assign o_almost_full = o_almost_full_dups[0];
      assign o_valid = o_valid_dups[0];
      assign o_almost_empty = o_almost_empty_dups[0];
      assign o_empty = o_empty_dups[0];
      assign ecc_err_status = {|ecc_err_status_dups[1], |ecc_err_status_dups[0]};

      //instantiate and stitch dla_hld_fifo's with reduced width and slicing disabled. last sub-FIFO may not have the full SLICE_WIDTH of data, in which case remainder is used
      for (z = 0; z < NUM_SLICES; z++) begin : gen_slices
        localparam SLICE_WIDTH_LOCAL = ((z == NUM_SLICES-1) && (SLICE_REMAINDER !=0)) ? SLICE_REMAINDER : SLICE_WIDTH;
        localparam REG_DATA_OUT_COUNT_LOCAL = (z == NUM_REGDATAOUT_SLICES-1 && REGDATAOUT_REMAINDER != 0) ? REGDATAOUT_REMAINDER : (z < NUM_REGDATAOUT_SLICES) ? SLICE_WIDTH : 0;
        localparam TOT_STALL_IN_OUTSIDE_REGS = STALL_IN_OUTSIDE_REGS + ((STALL_IN_EARLINESS > 0) ? 1 : 0);
        localparam TOT_VALID_IN_OUTSIDE_REGS = VALID_IN_OUTSIDE_REGS + ((VALID_IN_EARLINESS > 0) ? 1 : 0);

        //registering valid/stall mitigates fanout to different slices but decrements earliness
        if (VALID_IN_EARLINESS > 0) begin
          always @(posedge clock) begin
            i_valid_dups[z] <= i_valid;
          end
        end else begin
          assign i_valid_dups[z] = i_valid;
        end
        if (STALL_IN_EARLINESS > 0) begin
          always @(posedge clock) begin
            i_stall_dups[z] <= i_stall;
          end
        end else begin
          assign i_stall_dups[z] = i_stall;
        end

        dla_hld_fifo
        #(
          .WIDTH                      (SLICE_WIDTH_LOCAL),
          .DEPTH                      (DEPTH),

          //occupancy
          .ALMOST_EMPTY_CUTOFF        (ALMOST_EMPTY_CUTOFF),
          .ALMOST_FULL_CUTOFF         (ALMOST_FULL_CUTOFF),
          .INITIAL_OCCUPANCY          (INITIAL_OCCUPANCY),

          //reset configuration
          .ASYNC_RESET                (ASYNC_RESET),
          .SYNCHRONIZE_RESET          (SYNCHRONIZE_RESET),
          .RESET_EVERYTHING           (RESET_EVERYTHING),
          .RESET_EXTERNALLY_HELD      (RESET_EXTERNALLY_HELD),

          //special configurations for higher fmax / lower area
          .STALL_IN_EARLINESS          (STALL_IN_EARLINESS - TOT_STALL_IN_OUTSIDE_REGS),
          .VALID_IN_EARLINESS          (VALID_IN_EARLINESS - TOT_VALID_IN_OUTSIDE_REGS),
          .STALL_IN_OUTSIDE_REGS       (TOT_STALL_IN_OUTSIDE_REGS),
          .VALID_IN_OUTSIDE_REGS       (TOT_VALID_IN_OUTSIDE_REGS),
          .REGISTERED_DATA_OUT_COUNT   (REG_DATA_OUT_COUNT_LOCAL),
          .NEVER_OVERFLOWS             (NEVER_OVERFLOWS),
          .MAX_SLICE_WIDTH             (0), //disable slicing for sub-FIFOs

          //special features that typically have an fmax penalty
          .HOLD_DATA_OUT_WHEN_EMPTY    (HOLD_DATA_OUT_WHEN_EMPTY),
          .WRITE_AND_READ_DURING_FULL  (WRITE_AND_READ_DURING_FULL),

          //interface selection
          .USE_STALL_LATENCY_UPSTREAM    (USE_STALL_LATENCY_UPSTREAM),
          .USE_STALL_LATENCY_DOWNSTREAM  (USE_STALL_LATENCY_DOWNSTREAM),

          //ram implementation for fifos that use ram for data storage
          .RAM_BLOCK_TYPE                (RAM_BLOCK_TYPE),

          //fifo selection
          .STYLE                         (STYLE),
          .enable_ecc                    (enable_ecc)
        )
        dla_hld_fifo_inst
        (
          .clock            (clock),
          .resetn           (resetn),

          //upstream interface
          .i_valid          (i_valid_dups[z]),
          .i_data           (i_data[z*SLICE_WIDTH +: SLICE_WIDTH_LOCAL]),
          .o_stall          (o_stall_dups[z]),
          .o_almost_full    (o_almost_full_dups[z]),

          //downstream interface
          .o_valid          (o_valid_dups[z]),
          .o_data           (o_data[z*SLICE_WIDTH +: SLICE_WIDTH_LOCAL]),
          .i_stall          (i_stall_dups[z]),
          .o_almost_empty   (o_almost_empty_dups[z]),
          .o_empty          (o_empty_dups[z]),

          //other
          .ecc_err_status                 ({ecc_err_status_dups[1][z], ecc_err_status_dups[0][z]})
        );
      end

      //for simulation testbench only
      // synthesis translate_off
      assign fifo_in_reset = gen_slices[0].dla_hld_fifo_inst.fifo_in_reset;
      assign WRITE_TO_READ_LATENCY = gen_slices[0].dla_hld_fifo_inst.WRITE_TO_READ_LATENCY;
      assign RESET_EXT_HELD_LENGTH = gen_slices[0].dla_hld_fifo_inst.RESET_EXT_HELD_LENGTH;
      assign MAX_CLOCKS_TO_ENTER_SAFE_STATE = gen_slices[0].dla_hld_fifo_inst.MAX_CLOCKS_TO_ENTER_SAFE_STATE;
      assign MAX_CLOCKS_TO_EXIT_SAFE_STATE = gen_slices[0].dla_hld_fifo_inst.MAX_CLOCKS_TO_EXIT_SAFE_STATE;
      // synthesis translate_on

    end else begin
      //width-slicing disabled -- instantiate one FIFO of requested type and width

      /////////////////////////////////////////////////////////////////////////////////////////
      //                                                                                     //
      //  Decide whether to use memory or register implementation for low/zero latency fifo  //
      //                                                                                     //
      /////////////////////////////////////////////////////////////////////////////////////////

      // this is based on ALM usage from standalone compiles, if one wants a better method then implement in the compiler by explicitly asking for reg or ram
      // as the fifo gets wider, less depth is needed for it to be favorable to use a ram fifo
      // if (width <= 1) use_ram_fifo if depth >= 24
      // else if (width <= 2) use_ram_fifo if depth >= 12
      // else if (width <= 4) use_ram_fifo if depth >= 10
      // and so on...
      // note that at depth up to 4 we always use reg fifo
      localparam int W = WIDTH;
      localparam int D = DEPTH;
      localparam bit USE_RAM_FIFO = (W<=1) ? (D>=24) : (W<=2) ? (D>=12) : (W<=4) ? (D>=10) : (W<=8) ? (D>=9) : (W<=12) ? (D>=8) : (W<=16) ? (D>=7) : (W<=32) ? (D>=6) : (D>=5);



      /////////////////////////////////////
      //                                 //
      //  Convert to/from stall latency  //
      //                                 //
      /////////////////////////////////////

      // the underlying fifos are implemented with legacy stall/valid semantics, may need to convert to/from stall latency
      // naming convention: "i_" or "o_" can be stall latency or stall valid, "_in" or "_out" must only be stall valid
      logic valid_in, stall_out, almost_full;
      logic [WIDTH-1:0] data_in, data_out;
      logic valid_out, stall_in, almost_empty, forced_read_out;
      logic fifo_almost_empty, fifo_almost_full;

      //upstream interface
      assign valid_in       = i_valid;
      assign data_in        = i_data;
      assign o_stall        = (USE_STALL_LATENCY_UPSTREAM) ? almost_full : stall_out;
      assign o_almost_full  = (USE_STALL_LATENCY_UPSTREAM) ? 1'hx : almost_full;

      //downstream interface
      assign o_valid        = (USE_STALL_LATENCY_DOWNSTREAM) ? forced_read_out : valid_out;
      assign o_data         = data_out;
      assign stall_in       = i_stall;
      assign o_almost_empty = almost_empty;
      assign o_empty        = ~valid_out;



      /////////////////////////////////////////////////////////////
      //                                                         //
      //  Special behavior for out-of-bounds occupancy tracking  //
      //                                                         //
      /////////////////////////////////////////////////////////////

      // in stall latency the almost empty cutoff is set based on round-trip latency starting at an upstream fifo almost empty, through sync (slow read/fast read), and back to that fifo's stall
      // it is legal for this latency to be larger than the upstream fifo's capacity, in which case the sync will always operate in slow read mode
      // the underlying fifos do not allow this (the almost empty threshold would be a negative value), so legalize the ALMOST_EMPTY_CUTOFF parameter to the underlying fifos and assign o_almost_empty = 1
      // likewise this behavior extends to almost full in case we ever need a slow write mode for desync

      localparam FIFO_ALMOST_EMPTY_CUTOFF = (ALMOST_EMPTY_CUTOFF > DEPTH) ? 0 : ALMOST_EMPTY_CUTOFF;
      assign almost_empty = (ALMOST_EMPTY_CUTOFF > DEPTH) ? 1'b1 : fifo_almost_empty;

      localparam FIFO_ALMOST_FULL_CUTOFF = (ALMOST_FULL_CUTOFF > DEPTH) ? 0 : ALMOST_FULL_CUTOFF;
      assign almost_full = (ALMOST_FULL_CUTOFF > DEPTH) ? 1'b1 : fifo_almost_full;



      if (((STYLE == "zl") && !USE_RAM_FIFO) || (STYLE == "zlreg")) begin : zlreg

          dla_acl_zero_latency_fifo
          #(
              //basic config
              .WIDTH                          (WIDTH),
              .DEPTH                          (DEPTH),

              //occupancy
              .ALMOST_EMPTY_CUTOFF            (FIFO_ALMOST_EMPTY_CUTOFF),
              .ALMOST_FULL_CUTOFF             (FIFO_ALMOST_FULL_CUTOFF),
              .INITIAL_OCCUPANCY              (INITIAL_OCCUPANCY),

              //reset
              .ASYNC_RESET                    (ASYNC_RESET),
              .SYNCHRONIZE_RESET              (SYNCHRONIZE_RESET),
              .RESET_EVERYTHING               (RESET_EVERYTHING),
              .RESET_EXTERNALLY_HELD          (RESET_EXTERNALLY_HELD),

              //special config for high fmax / lower area
              .STALL_IN_EARLINESS             (STALL_IN_EARLINESS),
              .VALID_IN_EARLINESS             (VALID_IN_EARLINESS),
              .REGISTERED_DATA_OUT_COUNT      (REGISTERED_DATA_OUT_COUNT),
              .NEVER_OVERFLOWS                (NEVER_OVERFLOWS),
              .STALL_IN_OUTSIDE_REGS          (STALL_IN_OUTSIDE_REGS),
              .VALID_IN_OUTSIDE_REGS          (VALID_IN_OUTSIDE_REGS),

              //special features with fmax penalty
              .HOLD_DATA_OUT_WHEN_EMPTY       (HOLD_DATA_OUT_WHEN_EMPTY),
              .WRITE_AND_READ_DURING_FULL     (WRITE_AND_READ_DURING_FULL)
          )
          dla_acl_zero_latency_fifo_inst
          (
              .clock                          (clock),
              .resetn                         (resetn),

              //write interface
              .valid_in                       (valid_in),
              .data_in                        (data_in),
              .stall_out                      (stall_out),
              .almost_full                    (fifo_almost_full),

              //read interface
              .valid_out                      (valid_out),
              .data_out                       (data_out),
              .stall_in                       (stall_in),
              .almost_empty                   (fifo_almost_empty),
              .forced_read_out                (forced_read_out)
          );
          assign ecc_err_status = 2'h0;

          //for simulation testbench only
          // synthesis translate_off
          assign fifo_in_reset = dla_acl_zero_latency_fifo_inst.fifo_in_reset;
          assign WRITE_TO_READ_LATENCY = dla_acl_zero_latency_fifo_inst.WRITE_TO_READ_LATENCY;
          assign RESET_EXT_HELD_LENGTH = dla_acl_zero_latency_fifo_inst.RESET_EXT_HELD_LENGTH;
          assign MAX_CLOCKS_TO_ENTER_SAFE_STATE = dla_acl_zero_latency_fifo_inst.MAX_CLOCKS_TO_ENTER_SAFE_STATE;
          assign MAX_CLOCKS_TO_EXIT_SAFE_STATE = dla_acl_zero_latency_fifo_inst.MAX_CLOCKS_TO_EXIT_SAFE_STATE;
          // synthesis translate_on

      end
      if (((STYLE == "ll") && !USE_RAM_FIFO) || (STYLE == "llreg")) begin : llreg

          dla_acl_low_latency_fifo
          #(
              //basic config
              .WIDTH                          (WIDTH),
              .DEPTH                          (DEPTH),

              //occupancy
              .ALMOST_EMPTY_CUTOFF            (FIFO_ALMOST_EMPTY_CUTOFF),
              .ALMOST_FULL_CUTOFF             (FIFO_ALMOST_FULL_CUTOFF),
              .INITIAL_OCCUPANCY              (INITIAL_OCCUPANCY),

              //reset
              .ASYNC_RESET                    (ASYNC_RESET),
              .SYNCHRONIZE_RESET              (SYNCHRONIZE_RESET),
              .RESET_EVERYTHING               (RESET_EVERYTHING),
              .RESET_EXTERNALLY_HELD          (RESET_EXTERNALLY_HELD),

              //special config for high fmax / lower area
              .STALL_IN_EARLINESS             (STALL_IN_EARLINESS),
              .VALID_IN_EARLINESS             (VALID_IN_EARLINESS),
              .REGISTERED_DATA_OUT_COUNT      (REGISTERED_DATA_OUT_COUNT),
              .NEVER_OVERFLOWS                (NEVER_OVERFLOWS),
              .STALL_IN_OUTSIDE_REGS          (STALL_IN_OUTSIDE_REGS),
              .VALID_IN_OUTSIDE_REGS          (VALID_IN_OUTSIDE_REGS),

              //special features with fmax penalty
              .HOLD_DATA_OUT_WHEN_EMPTY       (HOLD_DATA_OUT_WHEN_EMPTY),
              .WRITE_AND_READ_DURING_FULL     (WRITE_AND_READ_DURING_FULL)
          )
          dla_acl_low_latency_fifo_inst
          (
              .clock                          (clock),
              .resetn                         (resetn),

              //write interface
              .valid_in                       (valid_in),
              .data_in                        (data_in),
              .stall_out                      (stall_out),
              .almost_full                    (fifo_almost_full),

              //read interface
              .valid_out                      (valid_out),
              .data_out                       (data_out),
              .stall_in                       (stall_in),
              .almost_empty                   (fifo_almost_empty),
              .forced_read_out                (forced_read_out),

              //occupancy
              .occ                            (),
              .occ_low_reset                  (),
              .occ_high_reset                 ()
          );
          assign ecc_err_status = 2'h0;

          //for simulation testbench only
          // synthesis translate_off
          assign fifo_in_reset = dla_acl_low_latency_fifo_inst.fifo_in_reset;
          assign WRITE_TO_READ_LATENCY = dla_acl_low_latency_fifo_inst.WRITE_TO_READ_LATENCY;
          assign RESET_EXT_HELD_LENGTH = dla_acl_low_latency_fifo_inst.RESET_EXT_HELD_LENGTH;
          assign MAX_CLOCKS_TO_ENTER_SAFE_STATE = dla_acl_low_latency_fifo_inst.MAX_CLOCKS_TO_ENTER_SAFE_STATE;
          assign MAX_CLOCKS_TO_EXIT_SAFE_STATE = dla_acl_low_latency_fifo_inst.MAX_CLOCKS_TO_EXIT_SAFE_STATE;
          // synthesis translate_on

      end
      if (((STYLE == "zl") && USE_RAM_FIFO) || (STYLE == "zlram")) begin : zlram

          dla_acl_latency_zero_ram_fifo
          #(
              //basic config
              .WIDTH                          (WIDTH),
              .DEPTH                          (DEPTH),

              //occupancy
              .ALMOST_EMPTY_CUTOFF            (FIFO_ALMOST_EMPTY_CUTOFF),
              .ALMOST_FULL_CUTOFF             (FIFO_ALMOST_FULL_CUTOFF),
              .INITIAL_OCCUPANCY              (INITIAL_OCCUPANCY),

              //reset
              .ASYNC_RESET                    (ASYNC_RESET),
              .SYNCHRONIZE_RESET              (SYNCHRONIZE_RESET),
              .RESET_EVERYTHING               (RESET_EVERYTHING),
              .RESET_EXTERNALLY_HELD          (RESET_EXTERNALLY_HELD),

              //special config for high fmax / lower area
              .STALL_IN_EARLINESS             (STALL_IN_EARLINESS),
              .VALID_IN_EARLINESS             (VALID_IN_EARLINESS),
              .REGISTERED_DATA_OUT_COUNT      (REGISTERED_DATA_OUT_COUNT),
              .NEVER_OVERFLOWS                (NEVER_OVERFLOWS),
              .STALL_IN_OUTSIDE_REGS          (STALL_IN_OUTSIDE_REGS),
              .VALID_IN_OUTSIDE_REGS          (VALID_IN_OUTSIDE_REGS),

              //special features with fmax penalty
              .HOLD_DATA_OUT_WHEN_EMPTY       (HOLD_DATA_OUT_WHEN_EMPTY),
              .WRITE_AND_READ_DURING_FULL     (WRITE_AND_READ_DURING_FULL),

              //ram implementation
              .RAM_BLOCK_TYPE                 (RAM_BLOCK_TYPE),

              //error correction code
              .enable_ecc                     (enable_ecc)
          )
          dla_acl_latency_zero_ram_fifo_inst
          (
              .clock                          (clock),
              .resetn                         (resetn),

              //write interface
              .valid_in                       (valid_in),
              .data_in                        (data_in),
              .stall_out                      (stall_out),
              .almost_full                    (fifo_almost_full),

              //read interface
              .valid_out                      (valid_out),
              .data_out                       (data_out),
              .stall_in                       (stall_in),
              .almost_empty                   (fifo_almost_empty),
              .forced_read_out                (forced_read_out),
              .ecc_err_status                 (ecc_err_status)
          );

          //for simulation testbench only
          // synthesis translate_off
          assign fifo_in_reset = dla_acl_latency_zero_ram_fifo_inst.fifo_in_reset;
          assign WRITE_TO_READ_LATENCY = dla_acl_latency_zero_ram_fifo_inst.WRITE_TO_READ_LATENCY;
          assign RESET_EXT_HELD_LENGTH = dla_acl_latency_zero_ram_fifo_inst.RESET_EXT_HELD_LENGTH;
          assign MAX_CLOCKS_TO_ENTER_SAFE_STATE = dla_acl_latency_zero_ram_fifo_inst.MAX_CLOCKS_TO_ENTER_SAFE_STATE;
          assign MAX_CLOCKS_TO_EXIT_SAFE_STATE = dla_acl_latency_zero_ram_fifo_inst.MAX_CLOCKS_TO_EXIT_SAFE_STATE;
          // synthesis translate_on

      end
      if (((STYLE == "ll") && USE_RAM_FIFO) || (STYLE == "llram")) begin : llram

          dla_acl_latency_one_ram_fifo
          #(
              //basic config
              .WIDTH                          (WIDTH),
              .DEPTH                          (DEPTH),

              //occupancy
              .ALMOST_EMPTY_CUTOFF            (FIFO_ALMOST_EMPTY_CUTOFF),
              .ALMOST_FULL_CUTOFF             (FIFO_ALMOST_FULL_CUTOFF),
              .INITIAL_OCCUPANCY              (INITIAL_OCCUPANCY),

              //reset
              .ASYNC_RESET                    (ASYNC_RESET),
              .SYNCHRONIZE_RESET              (SYNCHRONIZE_RESET),
              .RESET_EVERYTHING               (RESET_EVERYTHING),
              .RESET_EXTERNALLY_HELD          (RESET_EXTERNALLY_HELD),

              //special config for high fmax / lower area
              .STALL_IN_EARLINESS             (STALL_IN_EARLINESS),
              .VALID_IN_EARLINESS             (VALID_IN_EARLINESS),
              .REGISTERED_DATA_OUT_COUNT      (REGISTERED_DATA_OUT_COUNT),
              .NEVER_OVERFLOWS                (NEVER_OVERFLOWS),
              .STALL_IN_OUTSIDE_REGS          (STALL_IN_OUTSIDE_REGS),
              .VALID_IN_OUTSIDE_REGS          (VALID_IN_OUTSIDE_REGS),

              //special features with fmax penalty
              .HOLD_DATA_OUT_WHEN_EMPTY       (HOLD_DATA_OUT_WHEN_EMPTY),
              .WRITE_AND_READ_DURING_FULL     (WRITE_AND_READ_DURING_FULL),

              //ram implementation
              .RAM_BLOCK_TYPE                 (RAM_BLOCK_TYPE),

              //error correction code
              .enable_ecc                     (enable_ecc)
          )
          dla_acl_latency_one_ram_fifo_inst
          (
              .clock                          (clock),
              .resetn                         (resetn),

              //write interface
              .valid_in                       (valid_in),
              .data_in                        (data_in),
              .stall_out                      (stall_out),
              .almost_full                    (fifo_almost_full),

              //read interface
              .valid_out                      (valid_out),
              .data_out                       (data_out),
              .stall_in                       (stall_in),
              .almost_empty                   (fifo_almost_empty),
              .forced_read_out                (forced_read_out),
              .ecc_err_status                 (ecc_err_status)
          );

          //for simulation testbench only
          // synthesis translate_off
          assign fifo_in_reset = dla_acl_latency_one_ram_fifo_inst.fifo_in_reset;
          assign WRITE_TO_READ_LATENCY = dla_acl_latency_one_ram_fifo_inst.WRITE_TO_READ_LATENCY;
          assign RESET_EXT_HELD_LENGTH = dla_acl_latency_one_ram_fifo_inst.RESET_EXT_HELD_LENGTH;
          assign MAX_CLOCKS_TO_ENTER_SAFE_STATE = dla_acl_latency_one_ram_fifo_inst.MAX_CLOCKS_TO_ENTER_SAFE_STATE;
          assign MAX_CLOCKS_TO_EXIT_SAFE_STATE = dla_acl_latency_one_ram_fifo_inst.MAX_CLOCKS_TO_EXIT_SAFE_STATE;
          // synthesis translate_on

      end
      if (STYLE == "ms") begin : ms

          dla_acl_mid_speed_fifo
          #(
              //basic config
              .WIDTH                          (WIDTH),
              .DEPTH                          (DEPTH),

              //occupancy
              .ALMOST_EMPTY_CUTOFF            (FIFO_ALMOST_EMPTY_CUTOFF),
              .ALMOST_FULL_CUTOFF             (FIFO_ALMOST_FULL_CUTOFF),
              .INITIAL_OCCUPANCY              (INITIAL_OCCUPANCY),

              //reset
              .ASYNC_RESET                    (ASYNC_RESET),
              .SYNCHRONIZE_RESET              (SYNCHRONIZE_RESET),
              .RESET_EVERYTHING               (RESET_EVERYTHING),
              .RESET_EXTERNALLY_HELD          (RESET_EXTERNALLY_HELD),

              //special config for high fmax / lower area
              .STALL_IN_EARLINESS             (STALL_IN_EARLINESS),
              .VALID_IN_EARLINESS             (VALID_IN_EARLINESS),
              .NEVER_OVERFLOWS                (NEVER_OVERFLOWS),
              .STALL_IN_OUTSIDE_REGS          (STALL_IN_OUTSIDE_REGS),
              .VALID_IN_OUTSIDE_REGS          (VALID_IN_OUTSIDE_REGS),

              //special features with fmax penalty
              .HOLD_DATA_OUT_WHEN_EMPTY       (HOLD_DATA_OUT_WHEN_EMPTY),
              .WRITE_AND_READ_DURING_FULL     (WRITE_AND_READ_DURING_FULL),

              //ram implementation
              .RAM_BLOCK_TYPE                 (RAM_BLOCK_TYPE),

              //error correction code
              .enable_ecc                     (enable_ecc)
          )
          dla_acl_mid_speed_fifo_inst
          (
              .clock                          (clock),
              .resetn                         (resetn),

              //write interface
              .valid_in                       (valid_in),
              .data_in                        (data_in),
              .stall_out                      (stall_out),
              .almost_full                    (fifo_almost_full),

              //read interface
              .valid_out                      (valid_out),
              .data_out                       (data_out),
              .stall_in                       (stall_in),
              .almost_empty                   (fifo_almost_empty),
              .forced_read_out                (forced_read_out),
              .ecc_err_status                 (ecc_err_status)
          );

          //for simulation testbench only
          // synthesis translate_off
          assign fifo_in_reset = dla_acl_mid_speed_fifo_inst.fifo_in_reset;
          assign WRITE_TO_READ_LATENCY = dla_acl_mid_speed_fifo_inst.WRITE_TO_READ_LATENCY;
          assign RESET_EXT_HELD_LENGTH = dla_acl_mid_speed_fifo_inst.RESET_EXT_HELD_LENGTH;
          assign MAX_CLOCKS_TO_ENTER_SAFE_STATE = dla_acl_mid_speed_fifo_inst.MAX_CLOCKS_TO_ENTER_SAFE_STATE;
          assign MAX_CLOCKS_TO_EXIT_SAFE_STATE = dla_acl_mid_speed_fifo_inst.MAX_CLOCKS_TO_EXIT_SAFE_STATE;
          // synthesis translate_on

      end
      if (STYLE == "hs") begin : hs

          dla_acl_high_speed_fifo
          #(
              //basic config
              .WIDTH                          (WIDTH),
              .DEPTH                          (DEPTH),

              //occupancy
              .ALMOST_EMPTY_CUTOFF            (FIFO_ALMOST_EMPTY_CUTOFF),
              .ALMOST_FULL_CUTOFF             (FIFO_ALMOST_FULL_CUTOFF),
              .INITIAL_OCCUPANCY              (INITIAL_OCCUPANCY),

              //reset
              .ASYNC_RESET                    (ASYNC_RESET),
              .SYNCHRONIZE_RESET              (SYNCHRONIZE_RESET),
              .RESET_EVERYTHING               (RESET_EVERYTHING),
              .RESET_EXTERNALLY_HELD          (RESET_EXTERNALLY_HELD),

              //special config for high fmax / lower area
              .STALL_IN_EARLINESS             (STALL_IN_EARLINESS),
              .VALID_IN_EARLINESS             (VALID_IN_EARLINESS),
              .REGISTERED_DATA_OUT_COUNT      (REGISTERED_DATA_OUT_COUNT),
              .NEVER_OVERFLOWS                (NEVER_OVERFLOWS),
              .STALL_IN_OUTSIDE_REGS          (STALL_IN_OUTSIDE_REGS),
              .VALID_IN_OUTSIDE_REGS          (VALID_IN_OUTSIDE_REGS),

              //special features with fmax penalty
              .HOLD_DATA_OUT_WHEN_EMPTY       (HOLD_DATA_OUT_WHEN_EMPTY),
              .WRITE_AND_READ_DURING_FULL     (WRITE_AND_READ_DURING_FULL),

              //ram implementation
              .RAM_BLOCK_TYPE                 (RAM_BLOCK_TYPE),

              .enable_ecc(enable_ecc)
          )
          dla_acl_high_speed_fifo_inst
          (
              .clock                          (clock),
              .resetn                         (resetn),

              //write interface
              .valid_in                       (valid_in),
              .data_in                        (data_in),
              .stall_out                      (stall_out),
              .almost_full                    (fifo_almost_full),

              //read interface
              .valid_out                      (valid_out),
              .data_out                       (data_out),
              .stall_in                       (stall_in),
              .almost_empty                   (fifo_almost_empty),
              .forced_read_out                (forced_read_out),
              .ecc_err_status                 (ecc_err_status)
          );

          //for simulation testbench only
          // synthesis translate_off
          assign fifo_in_reset = dla_acl_high_speed_fifo_inst.fifo_in_reset;
          assign WRITE_TO_READ_LATENCY = dla_acl_high_speed_fifo_inst.WRITE_TO_READ_LATENCY;
          assign RESET_EXT_HELD_LENGTH = dla_acl_high_speed_fifo_inst.RESET_EXT_HELD_LENGTH;
          assign MAX_CLOCKS_TO_ENTER_SAFE_STATE = dla_acl_high_speed_fifo_inst.MAX_CLOCKS_TO_ENTER_SAFE_STATE;
          assign MAX_CLOCKS_TO_EXIT_SAFE_STATE = dla_acl_high_speed_fifo_inst.MAX_CLOCKS_TO_EXIT_SAFE_STATE;
          // synthesis translate_on

      end
    end
    endgenerate

    //get width of each individual slice if width-slicing is used
    //TODO: need to determine slice width to reflect device BRAMs, but for now just use max_slice_width
    //tracked by Case:578435
    function int get_slice_width(int max_slice_width);
        automatic int slice_width = max_slice_width;
        return slice_width;
    endfunction

endmodule

`default_nettype wire
