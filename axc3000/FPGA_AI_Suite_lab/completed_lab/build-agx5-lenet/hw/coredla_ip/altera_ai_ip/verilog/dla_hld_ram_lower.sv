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

//see dla_hld_ram.sv for a description of the parameters, ports, and general functionality of all the dla_hld_ram layers

//this is the top level for the bottom layers of dla_hld_ram
//the upper layers deal with value-added features like width/depth stitching to minimize physical memory usage
//the lower layers deal with hiding the complexity of Quartus IP and adding soft logic when hardened logic lacks functionality
//this layer selects which of the specific Quartus IP wrappers to use, and it models how much physical memory will be used

`default_nettype none

`include "dla_acl_parameter_assert.svh"

module dla_hld_ram_lower #(
    //geometry configuration
    parameter  int DEPTH,
    parameter  int WIDTH,
    parameter  int BE_WIDTH,
    parameter  int UTILIZED_WIDTH,  //this is for modelling the number of physical memories used, created at the bits per enable layer, adjusted as fewer geometries are allowed as we go down the layers

    //geometry constants
    parameter  bit MINIMIZE_MEMORY_USAGE,
    parameter  int MIN_PHYSICAL_DEPTH,

    //memory initialization
    parameter  bit USE_MEM_INIT_FILE,
    parameter  bit ZERO_INITIALIZE_MEM,
    parameter      MEM_INIT_NAME,

    //memory configuration
    parameter      RAM_BLOCK_TYPE,
    parameter      RAM_OPERATION_MODE,
    parameter      DEVICE_FAMILY,
    parameter      READ_DURING_WRITE,
    parameter  bit REGISTER_A_READDATA,
    parameter  bit REGISTER_B_ADDRESS,
    parameter  bit REGISTER_B_READDATA,

    //try to use memory hardened logic
    parameter  bit USE_ENABLE,
    parameter  bit COMMON_IN_CLOCK_EN,
    parameter  bit COMMON_OUT_CLOCK_EN,

    //derived parameters
    localparam int ADDR = $clog2(DEPTH)
) (
    input  wire                 clock,
    //no reset

    //port a
    input  wire      [ADDR-1:0] a_address,
    input  wire                 a_read_enable,
    input  wire                 a_write,
    input  wire     [WIDTH-1:0] a_writedata,
    input  wire  [BE_WIDTH-1:0] a_byteenable,
    output logic    [WIDTH-1:0] a_readdata,
    input  wire                 a_in_clock_en,
    input  wire                 a_out_clock_en,

    //port b
    input  wire      [ADDR-1:0] b_address,
    input  wire                 b_read_enable,
    input  wire                 b_write,
    input  wire     [WIDTH-1:0] b_writedata,
    input  wire  [BE_WIDTH-1:0] b_byteenable,
    output logic    [WIDTH-1:0] b_readdata,
    input  wire                 b_in_clock_en,
    input  wire                 b_out_clock_en
);

    ///////////////////////
    //  Legality checks  //
    ///////////////////////

    generate
    //check for non-trivial dimensions
    `DLA_ACL_PARAMETER_ASSERT(WIDTH >= 1)
    `DLA_ACL_PARAMETER_ASSERT(DEPTH >= 2)
    `DLA_ACL_PARAMETER_ASSERT(BE_WIDTH >= 1)

    //width / be_width must divide evenly with no remainder
    `DLA_ACL_PARAMETER_ASSERT(WIDTH % BE_WIDTH == 0)

    //if using byte enables, bits per enable must be physically supported
    `DLA_ACL_PARAMETER_ASSERT(BE_WIDTH == 1 || (WIDTH/BE_WIDTH) == 10)

    //depth must be a multiple of min physical depth
    `DLA_ACL_PARAMETER_ASSERT((DEPTH / MIN_PHYSICAL_DEPTH) * MIN_PHYSICAL_DEPTH == DEPTH);

    //check for a legal value of ram block type
    localparam bit RAM_BLOCK_TYPE_IS_M20K = RAM_BLOCK_TYPE == "M20K";
    localparam bit RAM_BLOCK_TYPE_IS_MLAB = RAM_BLOCK_TYPE == "MLAB";
    `DLA_ACL_PARAMETER_ASSERT(RAM_BLOCK_TYPE_IS_M20K || RAM_BLOCK_TYPE_IS_MLAB)

    //check for a legal value of ram operation mode
    localparam bit RAM_OPERATION_MODE_IS_SIMPLE_DUAL_PORT = RAM_OPERATION_MODE == "SIMPLE_DUAL_PORT";
    localparam bit RAM_OPERATION_MODE_IS_TRUE_DUAL_PORT   = RAM_OPERATION_MODE == "TRUE_DUAL_PORT";
    `DLA_ACL_PARAMETER_ASSERT(RAM_OPERATION_MODE_IS_SIMPLE_DUAL_PORT || RAM_OPERATION_MODE_IS_TRUE_DUAL_PORT)

    //check for a legal value of device family
    localparam bit DEVICE_FAMILY_IS_C10 = DEVICE_FAMILY == "Cyclone 10 GX";
    localparam bit DEVICE_FAMILY_IS_A10 = DEVICE_FAMILY == "Arria 10";
    localparam bit DEVICE_FAMILY_IS_S10 = DEVICE_FAMILY == "Stratix 10";
    localparam bit DEVICE_FAMILY_IS_AGX = DEVICE_FAMILY == "Agilex";
    `DLA_ACL_PARAMETER_ASSERT(DEVICE_FAMILY_IS_C10 || DEVICE_FAMILY_IS_A10 || DEVICE_FAMILY_IS_S10 || DEVICE_FAMILY_IS_AGX)

    //check for a legal value of mixed port read during write mode
    localparam bit READ_DURING_WRITE_IS_DONT_CARE = READ_DURING_WRITE == "DONT_CARE";
    localparam bit READ_DURING_WRITE_IS_OLD_DATA  = READ_DURING_WRITE == "OLD_DATA";
    localparam bit READ_DURING_WRITE_IS_NEW_DATA  = READ_DURING_WRITE == "NEW_DATA";
    `DLA_ACL_PARAMETER_ASSERT(READ_DURING_WRITE_IS_DONT_CARE || READ_DURING_WRITE_IS_OLD_DATA || READ_DURING_WRITE_IS_NEW_DATA)

    //mlab and true dual port is illegal
    `DLA_ACL_PARAMETER_ASSERT(!RAM_BLOCK_TYPE_IS_MLAB || !RAM_OPERATION_MODE_IS_TRUE_DUAL_PORT)

    //m20k with unregistered address is illegal
    `DLA_ACL_PARAMETER_ASSERT(!RAM_BLOCK_TYPE_IS_M20K || REGISTER_B_ADDRESS)
    endgenerate



    //////////////////////////
    //  Derived parameters  //
    //////////////////////////

    //finish constructing the memory initialization file name by appending the .mif extension after the name modification done by upper layers
    localparam     MEM_INIT_FILE_NAME = {MEM_INIT_NAME, ".mif"};

    //limit the max physical depth used by altera_syncram, e.g. if we want 8k x 10, better to build it from 4k x 5 (tiled as 2x2) instead of 8k x 2 (tiled as 1x5)
    localparam bit DEVICE_FAMILY_A10_OR_OLDER = (DEVICE_FAMILY == "Cyclone 10 GX") || (DEVICE_FAMILY == "Arria 10");
    localparam int MAXIMUM_DEPTH = (MINIMIZE_MEMORY_USAGE && DEVICE_FAMILY_A10_OR_OLDER) ? 8*MIN_PHYSICAL_DEPTH : 0;  //if trying to minimize memory usage, altera_syncram physical depth should not exceed 4k



    ///////////////////////////////////////////////////
    //  Model how many physical memories are needed  //
    ///////////////////////////////////////////////////

    //determine the physical depth of the underlying hardened memory
    localparam int M20K_MAX_PHYSICAL_DEPTH = (MAXIMUM_DEPTH) ? MAXIMUM_DEPTH : (DEVICE_FAMILY_A10_OR_OLDER) ? 32*MIN_PHYSICAL_DEPTH : 4*MIN_PHYSICAL_DEPTH;
    localparam int MLAB_MAX_PHYSICAL_DEPTH = (DEVICE_FAMILY_A10_OR_OLDER) ? 2*MIN_PHYSICAL_DEPTH : MIN_PHYSICAL_DEPTH;
    localparam int MAX_PHYSICAL_DEPTH = (RAM_BLOCK_TYPE == "M20K") ? M20K_MAX_PHYSICAL_DEPTH : MLAB_MAX_PHYSICAL_DEPTH;
    localparam int DEPTH_ROUNDED_UP_TO_NEAREST_POWER_OF_TWO = 1 << $clog2(DEPTH);
    localparam int PHYSICAL_DEPTH = (DEPTH_ROUNDED_UP_TO_NEAREST_POWER_OF_TWO > MAX_PHYSICAL_DEPTH) ? MAX_PHYSICAL_DEPTH : DEPTH_ROUNDED_UP_TO_NEAREST_POWER_OF_TWO;

    //determine the physical width of the underlying hardened memory
    localparam int M = MIN_PHYSICAL_DEPTH;  //shorten the names to make enumerating the cases more compact, min physical depth is a power of 2 (either 512 or 32 for m20k or mlab, or overriden by simulation)
    localparam int D = PHYSICAL_DEPTH;      //guaranteed this is a power of 2, depth was rounded up to nearest power of 2, and max physical depth must be a power of 2
    localparam int M20K_PHYSICAL_WIDTH = (D==M) ? 40 : (D==2*M) ? 20 : (D==4*M) ? 10 : (D==8*M) ? 5 : (D==16*M)? 2 : 1; //if true dual port, depth was quantized to 2 * min physical depth, so width limited to 20
    localparam int MLAB_PHYSICAL_WIDTH = (D==M) ? 20 : 10;
    localparam int PHYSICAL_WIDTH = (RAM_BLOCK_TYPE == "M20K") ? M20K_PHYSICAL_WIDTH : MLAB_PHYSICAL_WIDTH;

    //how many physical copies are tiled in the x and y directions to cover the width and depth
    //using the raw width can be misleading, for example at depth 4k the physical width is 5, altera_syncram does not allow 5 bits per enable, so pad the data to 10 bits per enable as a workaround
    //if there were 2 byte enable signals (WIDTH=20 whereas UTILIZED_WIDTH=10), the width makes it look like 4 M20K are needed but actually only 2 M20K are synthesized
    localparam int DEPTH_PHYSICAL_TILING = (DEPTH + PHYSICAL_DEPTH - 1) / PHYSICAL_DEPTH;
    localparam int WIDTH_PHYSICAL_TILING = (UTILIZED_WIDTH + PHYSICAL_WIDTH - 1) / PHYSICAL_WIDTH;

    //resource usage
    localparam int NUM_PHYSICAL_M20K = (RAM_BLOCK_TYPE != "M20K") ? 0 : DEPTH_PHYSICAL_TILING * WIDTH_PHYSICAL_TILING;
    localparam int NUM_PHYSICAL_MLAB = (RAM_BLOCK_TYPE != "MLAB") ? 0 : DEPTH_PHYSICAL_TILING * WIDTH_PHYSICAL_TILING;

    //the layers above consume these localparam values by assigning them to an integer, intended for simulation only



    /////////////////////////////////////////////////
    //  Next layer in the instantiation hierarchy  //
    /////////////////////////////////////////////////

    generate
    if (RAM_BLOCK_TYPE_IS_M20K && RAM_OPERATION_MODE_IS_TRUE_DUAL_PORT) begin : M20K_TDP
        dla_hld_ram_lower_m20k_true_dual_port
        #(
            .DEPTH                  (DEPTH),
            .WIDTH                  (WIDTH),
            .BE_WIDTH               (BE_WIDTH),
            .MAXIMUM_DEPTH          (MAXIMUM_DEPTH),
            .DEVICE_FAMILY          (DEVICE_FAMILY),
            .READ_DURING_WRITE      (READ_DURING_WRITE),
            .USE_ENABLE             (USE_ENABLE),
            .COMMON_IN_CLOCK_EN     (COMMON_IN_CLOCK_EN),
            .COMMON_OUT_CLOCK_EN    (COMMON_OUT_CLOCK_EN),
            .REGISTER_A_READDATA    (REGISTER_A_READDATA),
            .REGISTER_B_READDATA    (REGISTER_B_READDATA),
            .USE_MEM_INIT_FILE      (USE_MEM_INIT_FILE),
            .ZERO_INITIALIZE_MEM    (ZERO_INITIALIZE_MEM),
            .MEM_INIT_FILE_NAME     (MEM_INIT_FILE_NAME)
        )
        dla_hld_ram_lower_m20k_true_dual_port_inst
        (
            .clock                  (clock),
            .a_address              (a_address),
            .a_read_enable          (a_read_enable),
            .a_write                (a_write),
            .a_writedata            (a_writedata),
            .a_byteenable           (a_byteenable),
            .a_readdata             (a_readdata),
            .a_in_clock_en          (a_in_clock_en),
            .a_out_clock_en         (a_out_clock_en),
            .b_address              (b_address),
            .b_read_enable          (b_read_enable),
            .b_write                (b_write),
            .b_writedata            (b_writedata),
            .b_byteenable           (b_byteenable),
            .b_readdata             (b_readdata),
            .b_in_clock_en          (b_in_clock_en),
            .b_out_clock_en         (b_out_clock_en)
        );
    end
    if (RAM_BLOCK_TYPE_IS_M20K && RAM_OPERATION_MODE_IS_SIMPLE_DUAL_PORT) begin : M20K_SDP
        dla_hld_ram_lower_m20k_simple_dual_port
        #(
            .DEPTH                  (DEPTH),
            .WIDTH                  (WIDTH),
            .BE_WIDTH               (BE_WIDTH),
            .MAXIMUM_DEPTH          (MAXIMUM_DEPTH),
            .DEVICE_FAMILY          (DEVICE_FAMILY),
            .READ_DURING_WRITE      (READ_DURING_WRITE),
            .USE_ENABLE             (USE_ENABLE),
            .COMMON_IN_CLOCK_EN     (COMMON_IN_CLOCK_EN),
            .REGISTER_B_READDATA    (REGISTER_B_READDATA),
            .USE_MEM_INIT_FILE      (USE_MEM_INIT_FILE),
            .ZERO_INITIALIZE_MEM    (ZERO_INITIALIZE_MEM),
            .MEM_INIT_FILE_NAME     (MEM_INIT_FILE_NAME)
        )
        dla_hld_ram_lower_m20k_simple_dual_port_inst
        (
            .clock                  (clock),
            .a_address              (a_address),
            .a_write                (a_write),
            .a_writedata            (a_writedata),
            .a_byteenable           (a_byteenable),
            .a_in_clock_en          (a_in_clock_en),
            .b_address              (b_address),
            .b_read_enable          (b_read_enable),
            .b_readdata             (b_readdata),
            .b_in_clock_en          (b_in_clock_en),
            .b_out_clock_en         (b_out_clock_en)
        );
    end
    if (RAM_BLOCK_TYPE_IS_MLAB && RAM_OPERATION_MODE_IS_SIMPLE_DUAL_PORT) begin : MLAB
        dla_hld_ram_lower_mlab_simple_dual_port
        #(
            .DEPTH                  (DEPTH),
            .WIDTH                  (WIDTH),
            .BE_WIDTH               (BE_WIDTH),
            .DEVICE_FAMILY          (DEVICE_FAMILY),
            .READ_DURING_WRITE      (READ_DURING_WRITE),
            .REGISTER_B_ADDRESS     (REGISTER_B_ADDRESS),
            .REGISTER_B_READDATA    (REGISTER_B_READDATA),
            .USE_MEM_INIT_FILE      (USE_MEM_INIT_FILE),
            .MEM_INIT_FILE_NAME     (MEM_INIT_FILE_NAME)
        )
        dla_hld_ram_lower_mlab_simple_dual_port_inst
        (
            .clock                  (clock),
            .a_address              (a_address),
            .a_write                (a_write),
            .a_writedata            (a_writedata),
            .a_byteenable           (a_byteenable),
            .a_in_clock_en          (a_in_clock_en),
            .b_address              (b_address),
            .b_read_enable          (b_read_enable),
            .b_readdata             (b_readdata),
            .b_in_clock_en          (b_in_clock_en),
            .b_out_clock_en         (b_out_clock_en)
        );
    end
    endgenerate

endmodule

`default_nettype wire
