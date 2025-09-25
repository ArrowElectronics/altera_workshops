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

/**
dla_hld_ram is a project to simplify the usage of on-chip FPGA memory. Firstly, a lot of complexities are from Quartus IP such as altera_syncram and altdpram are hidden from the user.
Secondly, there are many value-added features such as using depth/width stitching to minimize the number of physical RAMs needed to create one logical RAM, which Quartus IP does
not handle well for non-power-of-2 sizes.

A very detailed powerpoint slide deck describing the internals can be found at: //depot/docs/hld/ip/dla_hld_ram introduction algorithm convergence.pptx

Here is a summary of the responsibility of each layer, note that the functionality in each layer can be optionally bypassed:

Level | Layer                                     | Description summary                               | Description details
------+-------------------------------------------+---------------------------------------------------+------------------------------------------------------------------------------------
  1   | dla_hld_ram                                   | choose M20K/MLAB if user did not specify it
------+-------------------------------------------+----------------------------------------------------------------------------------------------------------------------------------------
  2   | dla_hld_ram_ecc                               | adds error correction codes
------+-------------------------------------------+---------------------------------------------------+------------------------------------------------------------------------------------
  3   | dla_hld_ram_tall_depth_stitch                 | minimize the number physical memories needed to   | - depth stitch a multiple of 16k depth, 8k depth, and leftover depth
  4   | dla_hld_ram_remaining_width                   | construct one logical memory where the width and  | - extract remaining width, e.g. if width=32 may want to handle 2 bits separately
  5   | dla_hld_ram_bits_per_enable                   | depth are not "nice" values (e.g. depth not a     | - logical to physical mapping of byte enables and data
  6   | dla_hld_ram_short_depth_stitch                | power of two), among configurations of minimal    | - split depth into top/bottom, top depth is multiple of max physical depth
  7   | dla_hld_ram_bottom_width_stitch               | memory try to minimize glue logic (e.g. size of   | - split bottom width into left/right, large width will depth stitch in next layer
  8   | dla_hld_ram_bottom_depth_stitch               | read data mux)                                    | - implement the depth stitch for large width groups extracted in previous layer
------+-------------------------------------------+---------------------------------------------------+------------------------------------------------------------------------------------
  9   | dla_hld_ram_lower                             | unified interface for M20K and MLAB, also models the number of physical memories used
------+-------------------------------------------+---------------------------------------------------+------------------------------------------------------------------------------------
 10   | dla_hld_ram_lower_m20k_simple_dual_port,      | wrappers around altera_syncram or altdpram,
      | dla_hld_ram_lower_m20k_true_dual_port,        | add soft logic when hardened logic lacks functionality
      | dla_hld_ram_lower_mlab_simple_dual_port       |
*/

`default_nettype none

`include "dla_acl_parameter_assert.svh"

module dla_hld_ram import dla_common_pkg::*; #(
    //geometry configuration
    parameter  int DEPTH,                           //number of words of memory
    parameter  int WIDTH,                           //width of the data bus, both read and write data
    parameter  int BE_WIDTH,                        //width of the byte enable signal, beware that WIDTH / BE_WIDTH must divide evenly

    //geometry constants
    parameter  bit MINIMIZE_MEMORY_USAGE,           //0 = minimize glue logic between memories (may require more physical memories), 1 = minimize number of physical memories needed (may require more glue logic)
    parameter  int SIM_ONLY_MIN_PHYSICAL_DEPTH,     //set to 0 to use real physical values, set to nonzero to allow simulation to use shallower memories to better test mixed port read during write

    //memory initialization
    parameter  bit USE_MEM_INIT_FILE,               //0 = do not use memory initialization file, 1 = use memory initialization file
    parameter  bit ZERO_INITIALIZE_MEM,             //only when USE_MEM_INIT_FILE = 0, choose whether the memory contents power up to zero or don't care (MLAB can only power up to zero)
    parameter      MEM_INIT_NAME,                   //only when USE_MEM_INIT_FILE = 1, specify the original file name including the .mif extension, this file name is modified as memory contents are sliced

    //error correction codes
    parameter  bit ENABLE_ECC,                      //whether to enable error correction codes
    parameter  bit ECC_STATUS_TIME_STRETCH,         //0 = report the instantaneous ecc status, 1 = pulse stretch any single error corrected and latch (until reset) any double error detected
    parameter  bit ASYNC_RESET,                     //how do ecc status registers CONSUME reset, 1 = asynchronously, 0 = synchronously, no other registers consume reset
    parameter  bit SYNCHRONIZE_RESET,               //should reset be synchronized BEFORE it is consumed by the ecc status registers, 1 = synchronize it, 0 = no change to reset before consumption

    //memory configuration
    parameter      RAM_BLOCK_TYPE,                  //legal values are: "M20K", "MLAB", "DLA_HLD_RAM_TO_CHOOSE"
    parameter      RAM_OPERATION_MODE,              //legal values are: "SIMPLE_DUAL_PORT", "TRUE_DUAL_PORT"
    parameter device_family_t DEVICE_FAMILY,        //legal values are: "Cyclone 10 GX", "Arria 10", "Stratix 10", "Agilex"
    parameter      READ_DURING_WRITE,               //legal values are: "DONT_CARE", "OLD_DATA", "NEW_DATA"
    parameter  bit REGISTER_A_READDATA,             //latency from a_address to a_readdata is 1 (if unregistered) or 2 (if registered)
    parameter  bit REGISTER_B_ADDRESS,              //for mlab only choose whether to register or unregister the read address, for m20k this parameter is ignored since all inputs must be registered
    parameter  bit REGISTER_B_READDATA,             //latency from b_address to b_readdata is REGISTER_B_ADDRESS + REGISTER_B_READDATA, can be from 0 to 2 inclusive for mlab, can be from 1 to 2 for m20k

    //try to use memory hardened logic
    parameter  bit USE_ENABLE,                      // set to 0 if no clock enables are used
    parameter  bit COMMON_IN_CLOCK_EN,              //set to 1 if a_in_clock_en and b_in_clock_en are driven by the same source
    parameter  bit COMMON_OUT_CLOCK_EN,             //set to 1 if a_out_clock_en and b_out_clock_en are driven by the same source

    //derived parameters that affect the module interface
    localparam int ADDR = $clog2(DEPTH)
) (
    input  wire                 clock,

    //port a
    input  wire      [ADDR-1:0] a_address,          //address for read or write
    input  wire                 a_read_enable,      //read enable signal
    input  wire                 a_write,            //write enable, 1 = write, 0 = read
    input  wire     [WIDTH-1:0] a_writedata,        //data to write to memory
    input  wire  [BE_WIDTH-1:0] a_byteenable,       //which bytes of write data to commit to memory
    output logic    [WIDTH-1:0] a_readdata,         //data read from memory
    output wire                 a_read_valid,       //latency matched read enable
    input  wire                 a_in_clock_en,      //applies to all inputs: address, write enable, write data, byte enable
    input  wire                 a_out_clock_en,     //applies to all outputs: read data

    //port b
    input  wire      [ADDR-1:0] b_address,          //signals have the same meaning as port a
    input  wire                 b_read_enable,
    input  wire                 b_write,
    input  wire     [WIDTH-1:0] b_writedata,
    input  wire  [BE_WIDTH-1:0] b_byteenable,
    output logic    [WIDTH-1:0] b_readdata,
    output wire                 b_read_valid,
    input  wire                 b_in_clock_en,
    input  wire                 b_out_clock_en,

    //error correction code
    input  wire                 resetn,             //reset is only used if ENABLE_ECC = 1 and ECC_STATUS_TIME_STRETCH = 1, and it is only used by the ecc status not the ram itself
    output logic          [1:0] ecc_err_status      //bit 0 = double bit error detected (uncorrectable), bit 1 = single bit error corrected
);

    ///////////////////////
    //  Legality checks  //
    ///////////////////////

    generate
    //check for non-trivial dimensions
    `DLA_ACL_PARAMETER_ASSERT(DEPTH >= 2)
    `DLA_ACL_PARAMETER_ASSERT(WIDTH >= 1)
    `DLA_ACL_PARAMETER_ASSERT(BE_WIDTH >= 1)

    //width / be_width must divide evenly with no remainder
    `DLA_ACL_PARAMETER_ASSERT(WIDTH % BE_WIDTH == 0)

    //check for a legal value of ram block type
    localparam bit RAM_BLOCK_TYPE_IS_M20K = RAM_BLOCK_TYPE == "M20K";
    localparam bit RAM_BLOCK_TYPE_IS_MLAB = RAM_BLOCK_TYPE == "MLAB";
    localparam bit RAM_BLOCK_TYPE_IS_HLD_RAM_TO_CHOOSE = RAM_BLOCK_TYPE == "DLA_HLD_RAM_TO_CHOOSE";
    `DLA_ACL_PARAMETER_ASSERT(RAM_BLOCK_TYPE_IS_M20K || RAM_BLOCK_TYPE_IS_MLAB || RAM_BLOCK_TYPE_IS_HLD_RAM_TO_CHOOSE)

    //check for a legal value of ram operation mode
    localparam bit RAM_OPERATION_MODE_IS_SIMPLE_DUAL_PORT = RAM_OPERATION_MODE == "SIMPLE_DUAL_PORT";
    localparam bit RAM_OPERATION_MODE_IS_TRUE_DUAL_PORT   = RAM_OPERATION_MODE == "TRUE_DUAL_PORT";
    `DLA_ACL_PARAMETER_ASSERT(RAM_OPERATION_MODE_IS_SIMPLE_DUAL_PORT || RAM_OPERATION_MODE_IS_TRUE_DUAL_PORT)

    //check for a legal value of device family
    localparam     DEVICE_FAMILY_STR =
      (DEVICE_FAMILY == DEVICE_C10) ? "Cyclone 10 GX" :
      (DEVICE_FAMILY == DEVICE_A10) ? "Arria 10" :
      (DEVICE_FAMILY == DEVICE_S10) ? "Stratix 10" :
      (DEVICE_FAMILY == DEVICE_AGX7) ? "Agilex" :
      (DEVICE_FAMILY == DEVICE_AGX5) ? "Agilex" :
      "Unknown";
    localparam bit DEVICE_FAMILY_IS_C10 = DEVICE_FAMILY_STR == "Cyclone 10 GX";
    localparam bit DEVICE_FAMILY_IS_A10 = DEVICE_FAMILY_STR == "Arria 10";
    localparam bit DEVICE_FAMILY_IS_S10 = DEVICE_FAMILY_STR == "Stratix 10";
    localparam bit DEVICE_FAMILY_IS_AGX = DEVICE_FAMILY_STR == "Agilex";
    `DLA_ACL_PARAMETER_ASSERT(DEVICE_FAMILY_IS_C10 || DEVICE_FAMILY_IS_A10 || DEVICE_FAMILY_IS_S10 || DEVICE_FAMILY_IS_AGX)

    //check for a legal value of mixed port read during write mode
    localparam bit READ_DURING_WRITE_IS_DONT_CARE = READ_DURING_WRITE == "DONT_CARE";
    localparam bit READ_DURING_WRITE_IS_OLD_DATA  = READ_DURING_WRITE == "OLD_DATA";
    localparam bit READ_DURING_WRITE_IS_NEW_DATA  = READ_DURING_WRITE == "NEW_DATA";
    `DLA_ACL_PARAMETER_ASSERT(READ_DURING_WRITE_IS_DONT_CARE || READ_DURING_WRITE_IS_OLD_DATA || READ_DURING_WRITE_IS_NEW_DATA)

    //mlab and true dual port is illegal
    `DLA_ACL_PARAMETER_ASSERT(!RAM_BLOCK_TYPE_IS_MLAB || !RAM_OPERATION_MODE_IS_TRUE_DUAL_PORT)

    //unregistered address and true dual port is illegal
    `DLA_ACL_PARAMETER_ASSERT(REGISTER_B_ADDRESS || !RAM_OPERATION_MODE_IS_TRUE_DUAL_PORT)

    //m20k with unregistered address is illegal
    `DLA_ACL_PARAMETER_ASSERT(!RAM_BLOCK_TYPE_IS_M20K || REGISTER_B_ADDRESS)
    endgenerate



    //////////////////////////
    //  Derived parameters  //
    //////////////////////////

    //choose ram block type if user did not explicitly set it
    localparam bit MUST_CHOOSE_M20K           = (RAM_OPERATION_MODE == "TRUE_DUAL_PORT");
    localparam bit MUST_CHOOSE_MLAB           = (REGISTER_B_ADDRESS == 0);
    localparam bit DEVICE_FAMILY_A10_OR_OLDER = (DEVICE_FAMILY_STR == "Cyclone 10 GX") || (DEVICE_FAMILY_STR == "Arria 10");
    localparam int MLAB_MAX_PHYSICAL_DEPTH    = (DEVICE_FAMILY_A10_OR_OLDER) ? 64 : 32;
    localparam bit FAVOR_M20K                 = (DEPTH > MLAB_MAX_PHYSICAL_DEPTH) || USE_MEM_INIT_FILE; //m20k natively supports mem init inside a partial reconfig region
    localparam     HEURISTIC_RAM_BLOCK_TYPE   = (MUST_CHOOSE_M20K) ? "M20K" : (MUST_CHOOSE_MLAB) ? "MLAB" : (FAVOR_M20K) ? "M20K" : "MLAB";
    localparam     CHOSEN_RAM_BLOCK_TYPE      = (RAM_BLOCK_TYPE == "DLA_HLD_RAM_TO_CHOOSE") ? HEURISTIC_RAM_BLOCK_TYPE : RAM_BLOCK_TYPE;

    //depth quantization - round up the depth to the nearest multiple of the minimum physical depth
    //simulation may reduce the minimum physical depth to gain more test coverage of read-during-write behavior and depth stitching
    localparam int MIN_PHYSICAL_DEPTH = (SIM_ONLY_MIN_PHYSICAL_DEPTH) ? SIM_ONLY_MIN_PHYSICAL_DEPTH : (CHOSEN_RAM_BLOCK_TYPE=="MLAB") ? 32 : 512;
    localparam int MIN_USABLE_DEPTH   = (RAM_OPERATION_MODE == "TRUE_DUAL_PORT") ? 2*MIN_PHYSICAL_DEPTH : MIN_PHYSICAL_DEPTH;
    localparam int QUANTIZED_DEPTH    = ((DEPTH + MIN_USABLE_DEPTH - 1) / MIN_USABLE_DEPTH) * MIN_USABLE_DEPTH;

    //sanity check that the hardware is using the memory initialization files produced by the software model
    localparam     DLA_HLD_RAM_MEM_INIT_NAME = {MEM_INIT_NAME, ".hldram"};

    //optionally skip all the upper layers of dla_hld_ram, intended to reduce the module count for Modelsim AE
    //this can only be done when no features are used: no ECC, do whatever altera_syncram is going to do in terms of width/depth stitching, and no byte enables (therefore no bits per enable resizing)
    localparam bit BYPASS_ALL_UPPER_LAYERS = !ENABLE_ECC && !MINIMIZE_MEMORY_USAGE && (BE_WIDTH == 1);



    ////////////////////////
    //  Address resizing  //
    ////////////////////////

    //if the address signal in this module is narrower than the port width of the instance, modelsim puts Z on the upper bits which is ambigious in terms of what address to access
    localparam int QUANTIZED_ADDR = $clog2(QUANTIZED_DEPTH);
    logic [QUANTIZED_ADDR-1:0] quantized_a_address, quantized_b_address;
    generate
    if (QUANTIZED_ADDR > ADDR) begin : ZERO_EXTEND_ADDRESS
        assign quantized_a_address = {'0, a_address};
        assign quantized_b_address = {'0, b_address};
    end
    else begin : ORIGINAL_ADDRESS   //since QUANTIZED_DEPTH >= DEPTH therefore QUANTIZED_ADDR >= ADDR, strictly greater than was handled above, so this must be QUANTIZED_ADDR == ADDR
        assign quantized_a_address = a_address;
        assign quantized_b_address = b_address;
    end
    endgenerate



    /////////////////////////////////////////////////
    //  Next layer in the instantiation hierarchy  //
    /////////////////////////////////////////////////

    //imitate the query functions in the software model
    // synthesis translate_off
    int NUM_PHYSICAL_M20K, NUM_PHYSICAL_MLAB;
    // synthesis translate_on

    generate
    if (BYPASS_ALL_UPPER_LAYERS) begin : GEN_LOWER
        dla_hld_ram_lower
        #(
            .DEPTH                  (QUANTIZED_DEPTH),          //changed
            .WIDTH                  (WIDTH),
            .BE_WIDTH               (BE_WIDTH),
            .UTILIZED_WIDTH         (WIDTH),                    //assuming all bits of the data are used -- this is only for modelling the number of physical memories needed
            .MINIMIZE_MEMORY_USAGE  (MINIMIZE_MEMORY_USAGE),
            .MIN_PHYSICAL_DEPTH     (MIN_PHYSICAL_DEPTH),
            .USE_MEM_INIT_FILE      (USE_MEM_INIT_FILE),
            .ZERO_INITIALIZE_MEM    (ZERO_INITIALIZE_MEM),
            .MEM_INIT_NAME          (DLA_HLD_RAM_MEM_INIT_NAME),    //changed
            .RAM_BLOCK_TYPE         (CHOSEN_RAM_BLOCK_TYPE),    //changed
            .RAM_OPERATION_MODE     (RAM_OPERATION_MODE),
            .DEVICE_FAMILY          (DEVICE_FAMILY_STR),
            .READ_DURING_WRITE      (READ_DURING_WRITE),
            .REGISTER_A_READDATA    (REGISTER_A_READDATA),
            .REGISTER_B_ADDRESS     (REGISTER_B_ADDRESS),
            .REGISTER_B_READDATA    (REGISTER_B_READDATA),
            .USE_ENABLE             (USE_ENABLE),
            .COMMON_IN_CLOCK_EN     (COMMON_IN_CLOCK_EN),
            .COMMON_OUT_CLOCK_EN    (COMMON_OUT_CLOCK_EN)
        )
        dla_hld_ram_lower_inst
        (

            .clock                  (clock),
            .a_address              (quantized_a_address),      //changed
            .a_read_enable          (a_read_enable),
            .a_write                (a_write),
            .a_writedata            (a_writedata),
            .a_byteenable           (a_byteenable),
            .a_readdata             (a_readdata),
            .a_in_clock_en          (a_in_clock_en),
            .a_out_clock_en         (a_out_clock_en),
            .b_address              (quantized_b_address),      //changed
            .b_read_enable          (b_read_enable),
            .b_write                (b_write),
            .b_writedata            (b_writedata),
            .b_byteenable           (b_byteenable),
            .b_readdata             (b_readdata),
            .b_in_clock_en          (b_in_clock_en),
            .b_out_clock_en         (b_out_clock_en)
        );

        // synthesis translate_off
        assign NUM_PHYSICAL_M20K = dla_hld_ram_lower_inst.NUM_PHYSICAL_M20K;
        assign NUM_PHYSICAL_MLAB = dla_hld_ram_lower_inst.NUM_PHYSICAL_MLAB;
        // synthesis translate_on
    end
    else begin : GEN_ECC
        dla_hld_ram_ecc
        #(
            .DEPTH                  (QUANTIZED_DEPTH),          //changed
            .WIDTH                  (WIDTH),
            .BE_WIDTH               (BE_WIDTH),
            .MINIMIZE_MEMORY_USAGE  (MINIMIZE_MEMORY_USAGE),
            .MIN_PHYSICAL_DEPTH     (MIN_PHYSICAL_DEPTH),
            .USE_MEM_INIT_FILE      (USE_MEM_INIT_FILE),
            .ZERO_INITIALIZE_MEM    (ZERO_INITIALIZE_MEM),
            .MEM_INIT_NAME          (DLA_HLD_RAM_MEM_INIT_NAME),    //changed
            .ENABLE_ECC             (ENABLE_ECC),
            .ECC_STATUS_TIME_STRETCH(ECC_STATUS_TIME_STRETCH),
            .ASYNC_RESET            (ASYNC_RESET),
            .SYNCHRONIZE_RESET      (SYNCHRONIZE_RESET),
            .RAM_BLOCK_TYPE         (CHOSEN_RAM_BLOCK_TYPE),    //changed
            .RAM_OPERATION_MODE     (RAM_OPERATION_MODE),
            .DEVICE_FAMILY          (DEVICE_FAMILY_STR),
            .READ_DURING_WRITE      (READ_DURING_WRITE),
            .REGISTER_A_READDATA    (REGISTER_A_READDATA),
            .REGISTER_B_ADDRESS     (REGISTER_B_ADDRESS),
            .REGISTER_B_READDATA    (REGISTER_B_READDATA),
            .USE_ENABLE             (USE_ENABLE),
            .COMMON_IN_CLOCK_EN     (COMMON_IN_CLOCK_EN),
            .COMMON_OUT_CLOCK_EN    (COMMON_OUT_CLOCK_EN)
        )
        dla_hld_ram_ecc_inst
        (

            .clock                  (clock),
            .a_address              (quantized_a_address),      //changed
            .a_write                (a_write),
            .a_writedata            (a_writedata),
            .a_byteenable           (a_byteenable),
            .a_readdata             (a_readdata),
            .a_in_clock_en          (a_in_clock_en),
            .a_out_clock_en         (a_out_clock_en),
            .a_read_enable          (a_read_enable),
            .b_address              (quantized_b_address),      //changed
            .b_write                (b_write),
            .b_writedata            (b_writedata),
            .b_byteenable           (b_byteenable),
            .b_readdata             (b_readdata),
            .b_in_clock_en          (b_in_clock_en),
            .b_out_clock_en         (b_out_clock_en),
            .b_read_enable          (b_read_enable),
            .resetn                 (resetn),
            .ecc_err_status         (ecc_err_status)
        );

        // synthesis translate_off
        assign NUM_PHYSICAL_M20K = dla_hld_ram_ecc_inst.NUM_PHYSICAL_M20K;
        assign NUM_PHYSICAL_MLAB = dla_hld_ram_ecc_inst.NUM_PHYSICAL_MLAB;
        // synthesis translate_on
    end
    endgenerate

    logic a_read_enable_d1;
    dla_delay #(
      .WIDTH  (1),
      .DELAY  (1),
      .DEVICE (DEVICE_FAMILY)
    ) a_delay_read_enable (
      .clk    (clock),
      .clk_en (USE_ENABLE ? a_in_clock_en : 1'b1),
      .i_data (a_read_enable),
      .o_data (a_read_enable_d1)
    );
    dla_delay #(
      .WIDTH  (1),
      .DELAY  (REGISTER_A_READDATA),
      .DEVICE (DEVICE_FAMILY)
    ) a_delay_read_valid (
      .clk    (clock),
      .clk_en (USE_ENABLE ? a_out_clock_en : 1'b1),
      .i_data (a_read_enable_d1),
      .o_data (a_read_valid)
    );

    logic b_read_enable_d1;
    dla_delay #(
      .WIDTH  (1),
      .DELAY  (1),
      .DEVICE (DEVICE_FAMILY)
    ) b_delay_read_enable (
      .clk    (clock),
      .clk_en (USE_ENABLE ? (COMMON_IN_CLOCK_EN ? a_in_clock_en : b_in_clock_en) : 1'b1),
      .i_data (b_read_enable),
      .o_data (b_read_enable_d1)
    );
    dla_delay #(
      .WIDTH  (1),
      .DELAY  (REGISTER_A_READDATA),
      .DEVICE (DEVICE_FAMILY)
    ) b_delay_read_valid (
      .clk    (clock),
      .clk_en (USE_ENABLE ? (COMMON_OUT_CLOCK_EN ? a_out_clock_en : b_out_clock_en) : 1'b1),
      .i_data (b_read_enable_d1),
      .o_data (b_read_valid)
    );

endmodule

`default_nettype wire
