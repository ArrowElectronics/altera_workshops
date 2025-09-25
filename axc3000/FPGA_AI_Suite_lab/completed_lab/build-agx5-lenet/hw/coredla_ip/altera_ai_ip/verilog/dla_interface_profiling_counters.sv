// Copyright 2021 Altera Corporation.
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

`resetall
`undefineall
`default_nettype none
`include "dla_acl_parameter_assert.svh"

// This module snoops on the control signals of several stallable interfaces throughout CoreDLA. It uses each valid and
// ready pair to produce several counters which are useful for debug purposes. These counters as well as the steady state
// values of valid and ready are readable by the debug network.

// It is expected that a human (and not some automated script) will examine the data dumped by the debug network. To assist
// the parsing of this information, this module also contains a ROM that describes which offsets the profiling counters
// are available at as well as a human readable string to describe what each profiling counter is. As a contingency plan
// in case the FPGA runs low on M20K memory blocks, the ROM functionality could be moved entirely into software, however
// this would then require strict versions between hardware and runtime.

// Future optimizations:
// 1. Not all interfaces runs on clk_dla, probably the easiest way to deal with this is to have one instantiation of this
//    module per clock domain (use clock crossers to connect to the debug network which runs on clk_dla). Would need to
//    expose RAM depth, mem init file name, etc. as parameters. In case there are lots of stallable interfaces, probably
//    better to use multiple instantiations so that the ROM and read data mux won't grow super large.
// 2. Upper 32 bits of each 64-bit counter can probably be implemented with RAM instead of registers. Each time the bottom
//    32 bits overflows, assert some flag. Enhance the state machine to check and clear such flags, and upon doing so
//    perform a read-modify-write to the RAM to add 1 to the upper 32 bits of the corresponding counter.

module dla_interface_profiling_counters #(
    parameter int NUM_INTERFACES,   //number of stallable interfaces to snoop on valid and ready
    parameter int ADDR_WIDTH,       //width of the read request address, typically 24
    parameter int DATA_WIDTH        //width of the read response data, typically 32
) (
    input  wire                         clk,
    input  wire                         i_resetn_async,     //active low reset that has NOT been synchronized to any clock

    //snoop on valid and ready from various stallable interfaces
    input  wire                         i_snoop_valid [NUM_INTERFACES-1:0],
    input  wire                         i_snoop_ready [NUM_INTERFACES-1:0],

    //debug network interfaces
    input  wire                         i_dbg_arvalid,
    input  wire        [ADDR_WIDTH-1:0] i_dbg_araddr,
    output logic                        o_dbg_arready,
    output logic                        o_dbg_rvalid,
    output logic       [DATA_WIDTH-1:0] o_dbg_rdata,
    input  wire                         i_dbg_rready
);

    /////////////////////////////////
    //  Parameter legality checks  //
    /////////////////////////////////

    //signal widths cannot be trivial
    `DLA_ACL_PARAMETER_ASSERT(NUM_INTERFACES >= 1)
    `DLA_ACL_PARAMETER_ASSERT(ADDR_WIDTH == 24) //this is the only configuration ever tested
    `DLA_ACL_PARAMETER_ASSERT(DATA_WIDTH == 32) //this is the only configuration ever tested



    /////////////////
    //  Constants  //
    /////////////////

    //ROM sizing
    localparam int RAM_DEPTH = 2048;             //BEWARE: make sure this is at least as deep as the MIF file
    localparam int RAM_ADDR = $clog2(RAM_DEPTH);

    //state machine
    localparam int STATE_IDLE           = 0;
    localparam int STATE_ROM_ACCEPT     = 1;
    localparam int STATE_ROM_ADDR       = 2;
    localparam int STATE_ROM_DATA       = 3;
    localparam int STATE_COUNT_ACCEPT   = 4;
    localparam int STATE_COUNT_ADDR     = 5;
    localparam int STATE_COUNT_DATA     = 6;
    localparam int STATE_FREEZE_DATA    = 7;
    localparam int NUM_STATES           = 8;



    ///////////////
    //  Signals  //
    ///////////////

    //reset
    logic                   sclrn;

    //rom - implemented as ram for now
    //future optimization: upper bits of profiling counters change slowly, can probably move these inside the ram
    logic                   ram_wr_en;
    logic    [RAM_ADDR-1:0] ram_wr_addr, ram_rd_addr;
    logic  [DATA_WIDTH-1:0] ram_wr_data, ram_rd_data;

    //profiling counters
    genvar                  g;
    logic                   freeze;
    logic  [DATA_WIDTH-1:0] profiling_counter_per_interface [NUM_INTERFACES-1:0];
    logic  [DATA_WIDTH-1:0] profiling_counter_final;

    //state machine
    logic [$clog2(NUM_STATES)-1:0] state;
    logic  [ADDR_WIDTH-1:0] captured_addr;



    /////////////////////////////
    //  Reset Synchronization  //
    /////////////////////////////

    dla_reset_handler_simple #(
        .USE_SYNCHRONIZER   (1),
        .PIPE_DEPTH         (1),
        .NUM_COPIES         (1)
    )
    reset_synchronizer
    (
        .clk                (clk),
        .i_resetn           (i_resetn_async),
        .o_sclrn            (sclrn)
    );



    ///////////
    //  ROM  //
    ///////////

    // See create_mif.cpp for a description of the offset/string encoding that the runtime expects and that
    // the memory initialization file needs to implement.

    altera_syncram
    #(
        .address_aclr_b                     ("NONE"),
        .address_reg_b                      ("CLOCK0"),
        .clock_enable_input_a               ("BYPASS"),
        .clock_enable_input_b               ("BYPASS"),
        .clock_enable_output_b              ("BYPASS"),
        .enable_ecc                         ("FALSE"),
        .init_file                          ("dla_interface_profiling_counters.mif"),
        .intended_device_family             ("Arria 10"),       //Quartus will fix this automatically
        .lpm_type                           ("altera_syncram"),
        .numwords_a                         (RAM_DEPTH),
        .numwords_b                         (RAM_DEPTH),
        .operation_mode                     ("DUAL_PORT"),
        .outdata_aclr_b                     ("NONE"),
        .outdata_sclr_b                     ("NONE"),
        .outdata_reg_b                      ("CLOCK0"),
        .power_up_uninitialized             ("FALSE"),
        .ram_block_type                     ("M20K"),
        .read_during_write_mode_mixed_ports ("DONT_CARE"),
        .widthad_a                          (RAM_ADDR),
        .widthad_b                          (RAM_ADDR),
        .width_a                            (DATA_WIDTH),
        .width_b                            (DATA_WIDTH),
        .width_byteena_a                    (1)
    )
    ram
    (
        .address_a                          (ram_wr_addr),
        .address_b                          (ram_rd_addr),
        .clock0                             (clk),
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
        .data_b                             ({DATA_WIDTH{1'b1}}),
        .eccencbypass                       (1'b0),
        .eccencparity                       (8'b0),
        .eccstatus                          (),
        .q_a                                (),
        .rden_a                             (1'b1),
        .rden_b                             (1'b1),
        .wren_b                             (1'b0)
    );
    assign ram_wr_en = 1'b0;
    assign ram_wr_addr = '0;
    assign ram_wr_data = '0;
    assign ram_rd_addr = captured_addr[RAM_ADDR+1:2];



    //////////////////////////
    //  Profiling Counters  //
    //////////////////////////

    // Each stallable interface has a set of profiling counters which occupies a 32 byte chunk of the address space.
    //
    // Byte offset | Interpretation
    // ------------+----------------------------------------------------------------------------------------------
    //      0      | Steady state value of valid
    //      4      | Steady state value of ready
    //      8      | Lower 32-bits of 64-bit counter for number of transactions accepted (valid & ready)
    //     12      | Upper 32-bits of the above counter
    //     16      | Lower 32-bits of 64-bit counter for number of clock cycles of backpressure (valid & ~ready)
    //     20      | Upper 32-bits of the above counter
    //     24      | Lower 32-bits of 64-bit counter for number of clock cycles of data starvation (~valid & ready)
    //     28      | Upper 32-bits of the above counter
    //
    // There is some special handling for data starvation. It is a bit trickier to profile since "~valid & ready" will be
    // true before any work has begun as well as after all the work has finished. To resolve this, only start counting
    // after the first item of work has been seen, and every time a new item of work is seen capture the value in a
    // shadow register (avoid observing any increment in the raw counter after the last item of work).
    //
    // Since it takes multiple 32-bit reads to access the entire 64-bit value, there is the ability to freeze the counter
    // values. This is implemented by masking ready and valid i.e. the increment to the counter is set to 0. Note the freeze
    // does not affect the reading of the steady state value of valid and ready.

    for (g=0; g<NUM_INTERFACES; g++) begin : GEN_PROFILING_COUNTERS
        //add pipelining for routability to decouple the physical location of the interface from the
        //physical location of the profiling counters
        localparam int INPUT_PIPE_STAGES = 4;
        logic valid, ready;
        logic [INPUT_PIPE_STAGES-2:0] pipe_valid, pipe_ready;
        always_ff @(posedge clk) begin
            {valid, pipe_valid} <= {pipe_valid, i_snoop_valid[g]};
            {ready, pipe_ready} <= {pipe_ready, i_snoop_ready[g]};
        end

        //decode which profiling counter should increment based on valid and ready
        logic incr_transaction, incr_backpressure, incr_starvation;
        logic transaction_seen, incr_transaction_previous;
        always_ff @(posedge clk) begin
            incr_transaction  <= ~freeze &  valid &  ready;
            incr_backpressure <= ~freeze &  valid & ~ready;
            incr_starvation   <= ~freeze & ~valid &  ready & transaction_seen;

            if (~freeze & valid & ready) transaction_seen <= 1'b1;
            incr_transaction_previous <= incr_transaction;

            if (~sclrn) begin
                incr_transaction  <= 1'b0;
                incr_backpressure <= 1'b0;
                incr_starvation   <= 1'b0;
                transaction_seen  <= 1'b0;
            end
        end

        //update the profiling counters
        //64-bit counter is tessellated into two 32-bit counters, use the carry out from the
        //lower 32 bits to determine whether to increment upper 32 bits
        logic [DATA_WIDTH-1:0] count_transaction_lo, count_transaction_hi;
        logic count_transaction_carry;
        logic [DATA_WIDTH-1:0] count_backpressure_lo, count_backpressure_hi;
        logic count_backpressure_carry;
        logic [DATA_WIDTH-1:0] raw_starvation_lo, raw_starvation_hi;
        logic raw_starvation_carry;
        logic [DATA_WIDTH-1:0] count_starvation_lo, count_starvation_hi;

        always_ff @(posedge clk) begin
            //how many items of work have passed through this stallable interface
            {count_transaction_carry, count_transaction_lo} <= {1'b0, count_transaction_lo} + incr_transaction;
            count_transaction_hi <= count_transaction_hi + count_transaction_carry;

            //how many clock cycles of backpressure have been observed
            {count_backpressure_carry, count_backpressure_lo} <= {1'b0, count_backpressure_lo} + incr_backpressure;
            count_backpressure_hi <= count_backpressure_hi + count_backpressure_carry;

            //data starvation raw counter -- start counting "~valid & ready" only after the first item of work
            {raw_starvation_carry, raw_starvation_lo} <= {1'b0, raw_starvation_lo} + incr_starvation;
            raw_starvation_hi <= raw_starvation_hi + raw_starvation_carry;

            //data starvation shadow register -- don't observe increases in raw counter after the last item of work
            if (incr_transaction) count_starvation_lo <= raw_starvation_lo;
            if (incr_transaction_previous) count_starvation_hi <= raw_starvation_hi;

            if (~sclrn) begin
                count_transaction_lo <= '0;
                count_transaction_hi <= '0;
                count_transaction_carry <= 1'b0;
                count_backpressure_lo <= '0;
                count_backpressure_hi <= '0;
                count_backpressure_carry <= 1'b0;
                raw_starvation_lo <= '0;
                raw_starvation_hi <= '0;
                raw_starvation_carry <= 1'b0;
                count_starvation_lo <= '0;
                count_starvation_hi <= '0;
            end
        end

        //decode which offset to observe
        always_ff @(posedge clk) begin
            case (captured_addr[4:2])
            3'h0:    profiling_counter_per_interface[g] <= valid;
            3'h1:    profiling_counter_per_interface[g] <= ready;
            3'h2:    profiling_counter_per_interface[g] <= count_transaction_lo;
            3'h3:    profiling_counter_per_interface[g] <= count_transaction_hi;
            3'h4:    profiling_counter_per_interface[g] <= count_backpressure_lo;
            3'h5:    profiling_counter_per_interface[g] <= count_backpressure_hi;
            3'h6:    profiling_counter_per_interface[g] <= count_starvation_lo;
            3'h7:    profiling_counter_per_interface[g] <= count_starvation_hi;
            default: profiling_counter_per_interface[g] <= 'x;
            endcase
        end
    end

    //mux for choosing a profiling counter has two pipeline stages
    //first pipeline stage chooses one of 8 values associated with one stallable interface
    //second pipeline stage chooses which stallable interface
    always_ff @(posedge clk) begin
        profiling_counter_final <= '0;
        for (int i=0; i<NUM_INTERFACES; i++) begin
            if (captured_addr[ADDR_WIDTH-3:5] == i) begin
                profiling_counter_final <= profiling_counter_per_interface[i];
            end
        end
    end



    /////////////////////
    //  State machine  //
    /////////////////////

    // This is the same approach used by the CSR: backpressure by default, several pipeline stages to process one read request.
    // Here is the address map:
    // - ROM:
    //   - consumes the bottom half of the address space, only some of which is backed by the ROM
    //   - runtime has no idea how big the ROM is, it walks the list of offsets/descriptions until it sees the next offset = 0
    // - Profiling counters:
    //   - consumes the third quarter of the address space
    //   - each stallable interface has its own block of 32 bytes in the address space
    //   - address space is allocated starting from the bottom and increasing
    // - Freeze logic:
    //   - consumes the fourth quarter of the address space
    //   - assume all incoming read requests are 4-byte aligned i.e. bottom 2 bits of address are 0
    //   - if the incoming read request has bit 2 of the byte address asserted (odd index in terms of 4-byte words), then assert freeze
    //   - if the incoming read request has bit 2 of the byte address deasserted (even index), then deassert freeze
    //   - read value returned is the updated value of freeze

    always_ff @(posedge clk) begin
        //default behavior
        o_dbg_arready <= 1'b0;
        o_dbg_rvalid <= 1'b0;

        case (state)
        STATE_IDLE: begin
            if (i_dbg_arvalid) begin
                o_dbg_arready <= 1'b1;
                captured_addr <= i_dbg_araddr;
                if (!i_dbg_araddr[ADDR_WIDTH-1]) begin  //bottom half of address space is for ROM
                    state <= STATE_ROM_ACCEPT;
                end
                else begin  //top half of address space is for profiling counters
                    if (!i_dbg_araddr[ADDR_WIDTH-2]) begin  //3rd quarter of address space is for profiling counters
                        state <= STATE_COUNT_ACCEPT;
                    end
                    else begin  //4th quarter of address space is for freeze logic
                        state <= STATE_FREEZE_DATA;
                        freeze <= i_dbg_araddr[2];
                    end
                end
            end
        end
        STATE_ROM_ACCEPT: begin
            //ram_rd_addr valid now
            state <= STATE_ROM_ADDR;
        end
        STATE_ROM_ADDR: begin
            //hardened input register inside m20k valid now
            state <= STATE_ROM_DATA;
        end
        STATE_ROM_DATA: begin
            //hardened output register inside m20k valid now
            o_dbg_rvalid <= 1'b1;
            o_dbg_rdata <= ram_rd_data;
            if (o_dbg_rvalid && i_dbg_rready) begin
                o_dbg_rvalid <= 1'b0;
                state <= STATE_IDLE;
            end
        end

        STATE_COUNT_ACCEPT: begin
            //captured_addr valid now
            state <= STATE_COUNT_ADDR;
        end
        STATE_COUNT_ADDR: begin
            //all indexes of profiling_counter_per_interface valid now
            state <= STATE_COUNT_DATA;
        end
        STATE_COUNT_DATA: begin
            //profiling_counter_final valid now
            o_dbg_rvalid <= 1'b1;
            o_dbg_rdata <= profiling_counter_final;
            if (o_dbg_rvalid && i_dbg_rready) begin
                o_dbg_rvalid <= 1'b0;
                state <= STATE_IDLE;
            end
        end

        STATE_FREEZE_DATA: begin
            //freeze valid now
            o_dbg_rvalid <= 1'b1;
            o_dbg_rdata <= freeze;
            if (o_dbg_rvalid && i_dbg_rready) begin
                o_dbg_rvalid <= 1'b0;
                state <= STATE_IDLE;
            end
        end

        default: begin
            state <= STATE_IDLE;
        end
        endcase

        if (~sclrn) begin
            state <= STATE_IDLE;
            o_dbg_arready <= 1'b0;
            o_dbg_rvalid <= 1'b0;
            freeze <= 1'b0;
        end
    end

endmodule
