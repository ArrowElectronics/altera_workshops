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

//this layer is adds error correction codes, specifically single error correct double error detect hamming codes

`default_nettype none

`include "dla_acl_parameter_assert.svh"

module dla_hld_ram_ecc
import dla_acl_ecc_pkg::*;
#(
    //geometry configuration
    parameter  int DEPTH,
    parameter  int WIDTH,
    parameter  int BE_WIDTH,

    //geometry constants
    parameter  bit MINIMIZE_MEMORY_USAGE,
    parameter  int MIN_PHYSICAL_DEPTH,

    //memory initialization
    parameter  bit USE_MEM_INIT_FILE,
    parameter  bit ZERO_INITIALIZE_MEM,
    parameter      MEM_INIT_NAME,

    //error correction codes -- these parameters are consumed at this layer, layers below do not have them
    parameter  bit ENABLE_ECC,
    parameter  bit ECC_STATUS_TIME_STRETCH,
    parameter  bit ASYNC_RESET,
    parameter  bit SYNCHRONIZE_RESET,

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

    //port a
    input  wire      [ADDR-1:0] a_address,
    input  wire                 a_write,
    input  wire     [WIDTH-1:0] a_writedata,
    input  wire  [BE_WIDTH-1:0] a_byteenable,
    output logic    [WIDTH-1:0] a_readdata,
    input  wire                 a_in_clock_en,
    input  wire                 a_out_clock_en,
    input  wire                 a_read_enable,

    //port b
    input  wire      [ADDR-1:0] b_address,
    input  wire                 b_write,
    input  wire     [WIDTH-1:0] b_writedata,
    input  wire  [BE_WIDTH-1:0] b_byteenable,
    output logic    [WIDTH-1:0] b_readdata,
    input  wire                 b_in_clock_en,
    input  wire                 b_out_clock_en,
    input  wire                 b_read_enable,

    //error correction code -- these signals are consumed at this layer, layers below do not have them
    input  wire                 resetn,
    output logic          [1:0] ecc_err_status
);

    ///////////////////////
    //  Legality checks  //
    ///////////////////////

    generate
    //width / be_width must divide evenly with no remainder
    `DLA_ACL_PARAMETER_ASSERT(WIDTH % BE_WIDTH == 0)
    endgenerate



    //////////////////////////
    //  Derived parameters  //
    //////////////////////////

    //note: the max group size of 32 has been deliberately chosen, after encoding this expands to 39 bits which maps nicely to the physical width of m20k and mlab

    localparam int BITS_PER_ENABLE = WIDTH / BE_WIDTH;      //how many bits of data are controlled by each byte enable signal, typically we think of this as 8 but really can be any value
    localparam int MAX_ECC_GROUP_SIZE = 32;                 //if data is wide, slice into smaller sections and encode each section independently, limit the xor network size to maintain high fmax
    localparam int ECC_GROUP_SIZE = (BITS_PER_ENABLE > MAX_ECC_GROUP_SIZE) ? MAX_ECC_GROUP_SIZE : BITS_PER_ENABLE;                      //cannot jointly encode data from different byte enable groups
    localparam int ENCODED_BITS_PER_ENABLE = (ENABLE_ECC) ? getEncodedBitsEccGroup(BITS_PER_ENABLE, ECC_GROUP_SIZE) : BITS_PER_ENABLE;  //how many encoded bits of data are controlled by each byte enable signal
    localparam int ENCODED_WIDTH = ENCODED_BITS_PER_ENABLE * BE_WIDTH;                                                                  //total data width after encoding



    ////////////////////////////////////////////////////////////////
    //  Encode the write data, respecting byte enable boundaries  //
    ////////////////////////////////////////////////////////////////

    genvar g;
    logic [ENCODED_WIDTH-1:0] encoded_a_writedata, encoded_b_writedata;
    logic [ENCODED_WIDTH-1:0] encoded_a_readdata, encoded_b_readdata;
    logic [ENCODED_WIDTH-1:0] encoded_a_readdata_raw, encoded_b_readdata_raw;

    generate
    if (ENABLE_ECC) begin : ECC_ENCODE
        //each byte enable signal controls BITS_PER_ENABLE bits of the data path, to respect this boundary never ecc encode across different groups
        //it is possible that the group could be large, so we would want multiple ecc encoders within that group to limit the size of the xor network
        //dla_acl_ecc_encoder already does that for us, however we may need non-uniform slicing, so we still have to deal with that here

        //example scenario, suppose WIDTH = 98 and BE_WIDTH = 2, therefore BITS_PER_ENABLE = 49
        //given that MAX_ECC_GROUP_SIZE = 32, this is how the data should be sliced up:
        //dla_acl_ecc_encoder instance 0 -- ecc instance 0 handles bits 31:0, ecc instance 1 handles bits 48:32
        //dla_acl_ecc_encoder instance 1 -- ecc instance 0 handles bits 80:49, ecc instance 1 handles bits 97:81

        //the above layout cannot be achieved with only one instance of dla_acl_ecc_encoder, there is no way to alternate between slicing 32 and 17 bits

        for (g=0; g<BE_WIDTH; g++) begin
            dla_acl_ecc_encoder
            #(
                .DATA_WIDTH                 (BITS_PER_ENABLE),
                .ECC_GROUP_SIZE             (ECC_GROUP_SIZE),
                .INPUT_PIPELINE_STAGES      (0),        //must use zero latency to maintain the conceptual clock enable model of dla_hld_ram
                .OUTPUT_PIPELINE_STAGES     (0)         //likewise as above
            )
            dla_acl_ecc_encoder_inst_a
            (
                .clock                      (clock),    //this currently has no effect since the number of pipeline stages is 0
                .clock_enable               (1'b1),     //this currently has no effect since the number of pipeline stages is 0
                .i_data                     (a_writedata[g*BITS_PER_ENABLE +: BITS_PER_ENABLE]),
                .o_encoded                  (encoded_a_writedata[g*ENCODED_BITS_PER_ENABLE +: ENCODED_BITS_PER_ENABLE])
            );

            dla_acl_ecc_encoder
            #(
                .DATA_WIDTH                 (BITS_PER_ENABLE),
                .ECC_GROUP_SIZE             (ECC_GROUP_SIZE),
                .INPUT_PIPELINE_STAGES      (0),
                .OUTPUT_PIPELINE_STAGES     (0)
            )
            dla_acl_ecc_encoder_inst_b
            (
                .clock                      (clock),
                .clock_enable               (1'b1),
                .i_data                     (b_writedata[g*BITS_PER_ENABLE +: BITS_PER_ENABLE]),
                .o_encoded                  (encoded_b_writedata[g*ENCODED_BITS_PER_ENABLE +: ENCODED_BITS_PER_ENABLE])
            );
        end
    end
    else begin : NO_ENCODE
        assign encoded_a_writedata = a_writedata;
        assign encoded_b_writedata = b_writedata;
    end
    endgenerate



    /////////////////////////////////////////////////
    //  Next layer in the instantiation hierarchy  //
    /////////////////////////////////////////////////

    dla_hld_ram_tall_depth_stitch
    #(
        .DEPTH                  (DEPTH),
        .WIDTH                  (ENCODED_WIDTH),            //changed
        .BE_WIDTH               (BE_WIDTH),
        .MINIMIZE_MEMORY_USAGE  (MINIMIZE_MEMORY_USAGE),
        .MIN_PHYSICAL_DEPTH     (MIN_PHYSICAL_DEPTH),
        .USE_MEM_INIT_FILE      (USE_MEM_INIT_FILE),
        .ZERO_INITIALIZE_MEM    (ZERO_INITIALIZE_MEM),
        .MEM_INIT_NAME          (MEM_INIT_NAME),
        .RAM_BLOCK_TYPE         (RAM_BLOCK_TYPE),
        .RAM_OPERATION_MODE     (RAM_OPERATION_MODE),
        .DEVICE_FAMILY          (DEVICE_FAMILY),
        .READ_DURING_WRITE      (READ_DURING_WRITE),
        .REGISTER_A_READDATA    (REGISTER_A_READDATA),
        .REGISTER_B_ADDRESS     (REGISTER_B_ADDRESS),
        .REGISTER_B_READDATA    (REGISTER_B_READDATA),
        .USE_ENABLE             (USE_ENABLE),
        .COMMON_IN_CLOCK_EN     (COMMON_IN_CLOCK_EN),
        .COMMON_OUT_CLOCK_EN    (COMMON_OUT_CLOCK_EN)
    )
    dla_hld_ram_tall_depth_stitch_inst
    (
        .clock                  (clock),
        .a_address              (a_address),
        .a_write                (a_write),
        .a_writedata            (encoded_a_writedata),      //changed
        .a_byteenable           (a_byteenable),
        .a_readdata             (encoded_a_readdata_raw),   //changed
        .a_in_clock_en          (a_in_clock_en),
        .a_out_clock_en         (a_out_clock_en),
        .a_read_enable          (a_read_enable),
        .b_address              (b_address),
        .b_write                (b_write),
        .b_writedata            (encoded_b_writedata),      //changed
        .b_byteenable           (b_byteenable),
        .b_readdata             (encoded_b_readdata_raw),   //changed
        .b_in_clock_en          (b_in_clock_en),
        .b_out_clock_en         (b_out_clock_en),
        .b_read_enable          (b_read_enable)
    );

    //imitate the query functions in the software model
    // synthesis translate_off
    int NUM_PHYSICAL_M20K, NUM_PHYSICAL_MLAB;
    assign NUM_PHYSICAL_M20K = dla_hld_ram_tall_depth_stitch_inst.NUM_PHYSICAL_M20K;
    assign NUM_PHYSICAL_MLAB = dla_hld_ram_tall_depth_stitch_inst.NUM_PHYSICAL_MLAB;
    // synthesis translate_on



    ////////////////////////////////
    //  Sim-only error injection  //
    ////////////////////////////////

    //leave a hook for injecting errors into the read data, intended for simulation only
    logic [ENCODED_WIDTH-1:0] SIM_ONLY_a_inject_error, SIM_ONLY_b_inject_error;
    assign SIM_ONLY_a_inject_error = 0;     //these signals are forced by the testbench
    assign SIM_ONLY_b_inject_error = 0;
    assign encoded_a_readdata = encoded_a_readdata_raw ^ SIM_ONLY_a_inject_error;
    assign encoded_b_readdata = encoded_b_readdata_raw ^ SIM_ONLY_b_inject_error;



    ///////////////////////////////////////////////////////////
    //  Decode the read data and produce ECC status signals  //
    ///////////////////////////////////////////////////////////

    localparam bit CONNECT_A_READDATA_TO_ECC = RAM_OPERATION_MODE == "TRUE_DUAL_PORT";  //ignore port a read data if simple dual port

    generate
    if (ENABLE_ECC) begin : ECC_DECODE
        logic [BE_WIDTH-1:0] a_single_error, a_double_error;
        logic [BE_WIDTH-1:0] b_single_error, b_double_error;
        logic any_single_error, any_double_error;

        for (g=0; g<BE_WIDTH; g++) begin
            if (CONNECT_A_READDATA_TO_ECC) begin
                dla_acl_ecc_decoder
                #(
                    .DATA_WIDTH                 (BITS_PER_ENABLE),
                    .ECC_GROUP_SIZE             (ECC_GROUP_SIZE),
                    .INPUT_PIPELINE_STAGES      (0),        //must use zero latency to maintain the conceptual clock enable model of dla_hld_ram
                    .OUTPUT_PIPELINE_STAGES     (0),        //likewise as above
                    .STATUS_PIPELINE_STAGES     (0)         //likewise as above
                )
                dla_acl_ecc_decoder_inst_a
                (
                    .clock                      (clock),    //this currently has no effect since the number of pipeline stages is 0
                    .clock_enable               (1'b1),     //this currently has no effect since the number of pipeline stages is 0
                    .i_encoded                  (encoded_a_readdata[g*ENCODED_BITS_PER_ENABLE +: ENCODED_BITS_PER_ENABLE]),
                    .o_data                     (a_readdata[g*BITS_PER_ENABLE +: BITS_PER_ENABLE]),
                    .o_single_error_corrected   (a_single_error[g]),
                    .o_double_error_detected    (a_double_error[g])
                );
            end
            else begin
                assign a_readdata[g*BITS_PER_ENABLE +: BITS_PER_ENABLE] = 'x;
                assign a_single_error[g] = '0;
                assign a_double_error[g] = '0;
            end

            dla_acl_ecc_decoder
            #(
                .DATA_WIDTH                 (BITS_PER_ENABLE),
                .ECC_GROUP_SIZE             (ECC_GROUP_SIZE),
                .INPUT_PIPELINE_STAGES      (0),
                .OUTPUT_PIPELINE_STAGES     (0),
                .STATUS_PIPELINE_STAGES     (0)
            )
            dla_acl_ecc_decoder_inst_b
            (
                .clock                      (clock),
                .clock_enable               (1'b1),
                .i_encoded                  (encoded_b_readdata[g*ENCODED_BITS_PER_ENABLE +: ENCODED_BITS_PER_ENABLE]),
                .o_data                     (b_readdata[g*BITS_PER_ENABLE +: BITS_PER_ENABLE]),
                .o_single_error_corrected   (b_single_error[g]),
                .o_double_error_detected    (b_double_error[g])
            );
        end

        assign any_single_error = (|a_single_error) | (|b_single_error);
        assign any_double_error = (|a_double_error) | (|b_double_error);

        if (ECC_STATUS_TIME_STRETCH) begin
            dla_hld_ram_ecc_pulse_stretch_and_sticky #(
                .ASYNC_RESET                (ASYNC_RESET),
                .SYNCHRONIZE_RESET          (SYNCHRONIZE_RESET),
                .SINGLE_ERROR_PULSE_STRETCH (3)     //this is existing behavior from dla_acl_altera_syncram_wrapped
            )
            dla_hld_ram_ecc_pulse_stretch_and_sticky_inst
            (
                .clock                      (clock),
                .resetn                     (resetn),
                .i_single_error_corrected   (any_single_error),
                .i_double_error_detected    (any_double_error),
                .o_ecc_err_status           (ecc_err_status)
            );
        end
        else begin
            assign ecc_err_status = {any_single_error, any_double_error};
        end
    end
    else begin : NO_DECODE
        if (CONNECT_A_READDATA_TO_ECC) begin
            assign a_readdata = encoded_a_readdata;
        end
        else begin
            assign a_readdata = 'x;
        end
        assign b_readdata = encoded_b_readdata;
        assign ecc_err_status = 2'h0;
    end
    endgenerate

endmodule




//this is a helper module to convert the raw signals from the ECC decoder into something suitable for lazy collection
//assuming bit errors are rare, one way to monitor the ECC status signals from all memories is to simply OR the status signals from all instances
//these may be physically spread across the FPGA, so pulse stretch them so that they can be collected on a slower clock (or by using a multicycle clock constraint)

module dla_hld_ram_ecc_pulse_stretch_and_sticky #(
    parameter  bit ASYNC_RESET,                 //how do registers CONSUME reset, 1 = asynchronously, 0 = synchronously
    parameter  bit SYNCHRONIZE_RESET,           //should be reset be synchronized BEFORE it is consumed, 1 = synchronize it, 0 = no change to reset before consumption
    parameter  int SINGLE_ERROR_PULSE_STRETCH   //at least 1, how many clock cycles to pulse stretch any single bit error, a value of 3 means an input high for one clock cycle results in an output high for four clocks
) (
    input  wire         clock,
    input  wire         resetn,
    input  wire         i_single_error_corrected,
    input  wire         i_double_error_detected,
    output logic  [1:0] o_ecc_err_status
);

    //the double error detected status is a sticky bit, only reset can clear it, the intent being one should probably restart the system if an uncorrectable error is seen
    logic aclrn, sclrn;
    dla_acl_reset_handler
    #(
        .ASYNC_RESET            (ASYNC_RESET),
        .USE_SYNCHRONIZER       (SYNCHRONIZE_RESET),
        .SYNCHRONIZE_ACLRN      (SYNCHRONIZE_RESET),
        .PULSE_EXTENSION        (0),
        .PIPE_DEPTH             (1),
        .NUM_COPIES             (1)
    )
    dla_acl_reset_handler_inst
    (
        .clk                    (clock),
        .i_resetn               (resetn),
        .o_aclrn                (aclrn),
        .o_resetn_synchronized  (),
        .o_sclrn                (sclrn)
    );

    logic [SINGLE_ERROR_PULSE_STRETCH-1:0] single_error_history;
    logic single_error_pulse_stretched;
    logic double_error_latched;

    always_ff @(posedge clock or negedge aclrn) begin
        if (~aclrn) begin
            single_error_history <= '0;
            single_error_pulse_stretched <= 1'b0;
            double_error_latched <= 1'b0;
        end
        else begin
            single_error_history[0] <= i_single_error_corrected;
            for (int i=1; i<SINGLE_ERROR_PULSE_STRETCH; i++) single_error_history[i] <= single_error_history[i-1];
            single_error_pulse_stretched <= i_single_error_corrected | (|single_error_history);
            double_error_latched <= double_error_latched | i_double_error_detected;
            if (~sclrn) begin
                single_error_history <= '0;
                single_error_pulse_stretched <= 1'b0;
                double_error_latched <= 1'b0;
            end
        end
    end

    assign o_ecc_err_status = {single_error_pulse_stretched, double_error_latched};

endmodule

`default_nettype wire
