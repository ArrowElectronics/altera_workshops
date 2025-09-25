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

//this module provides a unified interface for M20K in true dual port mode, it instantiates altera_syncram and adds soft logic to support new data mode
//beware that old data mode in stratrix 10 and newer is not possible to support even with soft logic

`default_nettype none

`include "dla_acl_parameter_assert.svh"

module dla_hld_ram_lower_m20k_true_dual_port #(
    //geometry of the memory
    parameter  int DEPTH,                   //number of words of memory
    parameter  int WIDTH,                   //width of the data bus, both read and write data
    parameter  int BE_WIDTH,                //width of the byte enable signal, note that WIDTH / BE_WIDTH must divide evenly
    parameter  int MAXIMUM_DEPTH,           //ensure access to all 20k bits of memory by limiting how narrow the physical width can get, implemented by limiting the max physical depth, 0 = no limit

    //operation of memory
    parameter      DEVICE_FAMILY,           //"Cyclone 10 GX" | "Arria 10" | "Stratix 10" | "Agilex"
    parameter      READ_DURING_WRITE,       //"DONT_CARE" | "OLD_DATA" | "NEW_DATA"

    //simplified use-cases that lead to more use of hardened logic
    parameter  bit USE_ENABLE,              //set to 0 if all clock enables are unused
    parameter  bit COMMON_IN_CLOCK_EN,      //set to 1 if a_in_clock_en and b_in_clock_en are driven by the same source
    parameter  bit COMMON_OUT_CLOCK_EN,     //set to 1 if a_out_clock_en and b_out_clock_en are driven by the same source

    //specify whether to register or unregister the read data
    parameter  bit REGISTER_A_READDATA,     //latency from a_address to a_readdata is 1 (if unregistered) or 2 (if registered)
    parameter  bit REGISTER_B_READDATA,     //latency from b_address to b_readdata is 1 (if unregistered) or 2 (if registered)

    //memory initialization
    parameter  bit USE_MEM_INIT_FILE,       //0 = do not use memory initialization file, 1 = use memory initialization file
    parameter  bit ZERO_INITIALIZE_MEM,     //if USE_MEM_INIT_FILE = 0, then choose whether the memory contents initialize to zero or don't care
    parameter      MEM_INIT_FILE_NAME,      //if USE_MEM_INIT_FILE = 1, then specify the name of the file that contains the initial memory contents

    //derived parameters that affect the module interface
    localparam int ADDR = $clog2(DEPTH)
) (
    input  wire                 clock,
    //no reset

    //port a
    input  wire      [ADDR-1:0] a_address,          //address for read or write
    input  wire                 a_read_enable,
    input  wire                 a_write,            //write enable, 1 = write, 0 = read
    input  wire     [WIDTH-1:0] a_writedata,        //data to write to memory
    input  wire  [BE_WIDTH-1:0] a_byteenable,       //which bytes of write data to commit to memory
    output logic    [WIDTH-1:0] a_readdata,         //data read from memory
    input  wire                 a_in_clock_en,      //applies to all inputs: address, write enable, write data, byte enable
    input  wire                 a_out_clock_en,     //applies to all outputs: read data

    //port b
    input  wire      [ADDR-1:0] b_address,          //signals have the same meaning as port a
    input  wire                 b_read_enable,
    input  wire                 b_write,
    input  wire     [WIDTH-1:0] b_writedata,
    input  wire  [BE_WIDTH-1:0] b_byteenable,
    output logic    [WIDTH-1:0] b_readdata,
    input  wire                 b_in_clock_en,
    input  wire                 b_out_clock_en
);

    //different logic is needed for a10 or older versus s10 or newer
    localparam bit DEVICE_FAMILY_A10_OR_OLDER = (DEVICE_FAMILY == "Cyclone 10 GX") || (DEVICE_FAMILY == "Arria 10");



    ///////////////////////
    //  Legality checks  //
    ///////////////////////

    //in addition to what was already checked by dla_hld_ram_lower
    generate
    //if s10 or newer, impossible to use soft logic to construct old data mode for mixed port read during write
    localparam bit READ_DURING_WRITE_IS_OLD_DATA = READ_DURING_WRITE == "OLD_DATA";
    `DLA_ACL_PARAMETER_ASSERT(DEVICE_FAMILY_A10_OR_OLDER || !READ_DURING_WRITE_IS_OLD_DATA)
    endgenerate



    //////////////////////////
    //  Derived parameters  //
    //////////////////////////

    localparam int BITS_PER_ENABLE = WIDTH / BE_WIDTH;

    //determine when hardened logic can be used, in all other cases use soft logic to implement the functionality
    localparam bit USE_HARD_LOGIC_FOR_ADDR_STALL = DEVICE_FAMILY_A10_OR_OLDER && COMMON_IN_CLOCK_EN;
    //S10 and newer families do not support hardend output registers with clock enables
    localparam bit USE_HARD_LOGIC_FOR_OUT_REGISTER = USE_ENABLE ? COMMON_OUT_CLOCK_EN && REGISTER_A_READDATA && REGISTER_B_READDATA && DEVICE_FAMILY_A10_OR_OLDER : REGISTER_A_READDATA && REGISTER_B_READDATA;

    //altera_syncram output only has 2 configurations: either both outputs are registered with a common output clock enable, or both outputs are unregistered and soft logic is used
    //the parameters below indicate whether to add a register after the output of altera_syncram
    localparam bit REGISTER_Q_A = !USE_HARD_LOGIC_FOR_OUT_REGISTER && REGISTER_A_READDATA;
    localparam bit REGISTER_Q_B = !USE_HARD_LOGIC_FOR_OUT_REGISTER && REGISTER_B_READDATA;



    //////////////////////////////////////////////////////////////////////
    //  Model the hardened address and input registers inside the m20k  //
    //////////////////////////////////////////////////////////////////////

    logic     [ADDR-1:0] a_internal_address    , b_internal_address    ;
    logic                a_internal_write      , b_internal_write      ;
    logic [BE_WIDTH-1:0] a_internal_byteenable , b_internal_byteenable ;
    logic    [WIDTH-1:0] a_internal_writedata  , b_internal_writedata  ;
    logic     [ADDR-1:0] a_mux_address         , b_mux_address         ;
    logic a_internal_read_enable;
    logic b_internal_read_enable;
    logic a_mux_read_enable;
    logic b_mux_read_enable;

    //in many cases these registers have no fanout so they will just get swept away
    always_ff @(posedge clock) begin
        if (a_in_clock_en) begin
            a_internal_address    <= a_address;
            a_internal_read_enable<= a_read_enable;
            a_internal_write      <= a_write;
            a_internal_byteenable <= a_byteenable;
            a_internal_writedata  <= a_writedata;
        end
        if (b_in_clock_en) begin
            b_internal_address    <= b_address;
            b_internal_read_enable<= b_read_enable;
            b_internal_write      <= b_write;
            b_internal_byteenable <= b_byteenable;
            b_internal_writedata  <= b_writedata;
        end
    end

    //this is what drives the address port if soft logic is used for address stall
    assign a_mux_address = (a_in_clock_en) ? a_address : a_internal_address;
    assign b_mux_address = (b_in_clock_en) ? b_address : b_internal_address;
    assign a_mux_read_enable = (a_in_clock_en) ? a_read_enable : a_internal_read_enable;
    assign b_mux_read_enable = (b_in_clock_en) ? b_read_enable : b_internal_read_enable;



    ///////////////////////////////////////
    //  altera_syncram write side ports  //
    ///////////////////////////////////////

    //add soft logic when hardened logic lacks functionality
    //if byte enables are not used, then altera_syncram can be used with arbitrary width
    //if mixed port read during write is new data mode, can emulate this by adding a data bypass
    //address stall is no longer present in s10 or newer, use a shadow register in ALM logic to ensure the hardened address registers inside the m20k stay frozen

    logic                clock0;
    logic     [ADDR-1:0] address_a      , address_b      ;
    logic                rden_a;
    logic                rden_b;
    logic                addressstall_a , addressstall_b ;
    logic                wren_a         , wren_b         ;
    logic [BE_WIDTH-1:0] byteena_a      , byteena_b      ;
    logic    [WIDTH-1:0] data_a         , data_b         ;

    //clock enable for address: use hard logic only if a10 or older and there is a common input clock enable for both ports
    assign clock0 = clock;
    generate
    if (USE_HARD_LOGIC_FOR_ADDR_STALL) begin : GEN_HARD_ADDR_STALL
        assign address_a      = a_address;
        assign address_b      = b_address;
        assign addressstall_a = ~a_in_clock_en;
        assign addressstall_b = ~b_in_clock_en;
    end
    else begin : GEN_SOFT_ADDR_STALL
        assign address_a      = a_mux_address;
        assign address_b      = b_mux_address;
        assign addressstall_a = 1'b0;
        assign addressstall_b = 1'b0;
    end
    endgenerate

    //write enable and byte enable
    generate
    if (BE_WIDTH == 1) begin : NO_BYTEENABLE    //1 byte enable for the entire data width, don't need to use physical byte enable, combine it with write enable
        assign wren_a    = a_write & a_in_clock_en & a_byteenable;
        assign byteena_a = 1'b1;
        assign wren_b    = b_write & b_in_clock_en & b_byteenable;
        assign byteena_b = 1'b1;
    end
    else begin : GEN_BYTEENABLE
        assign wren_a    = a_write & a_in_clock_en;
        assign byteena_a = a_byteenable;
        assign wren_b    = b_write & b_in_clock_en;
        assign byteena_b = b_byteenable;
    end
    endgenerate

    //write data
    assign data_a = a_writedata;
    assign data_b = b_writedata;



    ///////////////////////////////////////
    //  altera_syncram read side ports  //
    ///////////////////////////////////////

    logic                clock1;
    logic                clocken1;
    logic    [WIDTH-1:0] q_a          , q_b          ;
    logic    [WIDTH-1:0] adjusted_q_a , adjusted_q_b ;

    //output clock enable: use hard logic only if both read data are registered and there is a common output clock enable
    generate
    if (!USE_ENABLE) begin : GEN_NO_CLOCK_EN
        assign clock1   = 1'b1;
        assign clocken1 = 1'b1;
    end
    else if (USE_HARD_LOGIC_FOR_OUT_REGISTER) begin : GEN_HARD_OUT_CLOCK_EN
        assign clock1   = clock;
        assign clocken1 = a_out_clock_en;
    end
    else begin : GEN_SOFT_OUT_CLOCK_EN
        assign clock1   = 1'b1;
        assign clocken1 = 1'b1;
    end
    endgenerate

    //////////////<FORCE_TO_ZERO>///////////////
    localparam bit ENABLE_FORCE_TO_ZERO_SOFT_LOGIC = (DEVICE_FAMILY == "Cyclone 10 GX") || (DEVICE_FAMILY == "Arria 10");
    localparam string ENABLE_FORCE_TO_ZERO = ENABLE_FORCE_TO_ZERO_SOFT_LOGIC ? "FALSE" : "TRUE";
    logic a_read_valid;
    logic b_read_valid;
    if (ENABLE_FORCE_TO_ZERO_SOFT_LOGIC) begin : GEN_SOFT_FORCE_TO_ZERO
      assign rden_a         = 1'b1;
      assign rden_b         = 1'b1;

      logic a_read_enable_d1;
      logic b_read_enable_d1;
      always_ff @(posedge clock) begin
        if (!USE_ENABLE || a_in_clock_en) begin
          a_read_enable_d1 <= a_read_enable;
        end
        if (!USE_ENABLE || (COMMON_IN_CLOCK_EN ? a_in_clock_en : b_in_clock_en)) begin
          b_read_enable_d1 <= b_read_enable;
        end
      end

      if (REGISTER_B_READDATA) begin : gen_out_read_valid_flop
        always_ff @(posedge clock) begin
          if (!USE_ENABLE || a_out_clock_en) begin
            a_read_valid <= a_read_enable_d1;
          end
          if (!USE_ENABLE || b_out_clock_en) begin
            b_read_valid <= b_read_enable_d1;
          end
        end
      end else begin : gen_out_read_valid_wire
        assign a_read_valid = a_read_enable_d1;
        assign b_read_valid = b_read_enable_d1;
      end
    end else begin : GEN_HARD_FORCE_TO_ZERO
      assign rden_a         = USE_HARD_LOGIC_FOR_ADDR_STALL ? a_read_enable : a_mux_read_enable;
      assign a_read_valid   = 1'b1;
      assign rden_b         = USE_HARD_LOGIC_FOR_ADDR_STALL ? b_read_enable : b_mux_read_enable;
      assign b_read_valid   = 1'b1;
    end
    //////////////</FORCE_TO_ZERO>///////////////

    //register q_a and/or q_b if altera_syncram has unregistered output but dla_hld_ram has registered output
    generate
    if (REGISTER_Q_A) begin
        always_ff @(posedge clock) begin
            if (a_out_clock_en) adjusted_q_a <= (a_read_valid ? q_a : {WIDTH{1'b0}});
        end
    end
    else begin
        assign adjusted_q_a = (a_read_valid ? q_a : {WIDTH{1'b0}});
    end
    if (REGISTER_Q_B) begin
        always_ff @(posedge clock) begin
            if (b_out_clock_en) adjusted_q_b <= (b_read_valid ? q_b : {WIDTH{1'b0}});
        end
    end
    else begin
        assign adjusted_q_b = (b_read_valid ? q_b : {WIDTH{1'b0}});
    end
    endgenerate

    //output the read data
    generate
    if (READ_DURING_WRITE == "NEW_DATA") begin  //new data mode is achieved by using a data bypass
        logic                addr_match;
        logic [BE_WIDTH-1:0] common_internal_byteenable;
        logic    [WIDTH-1:0] common_internal_writedata;
        logic [BE_WIDTH-1:0] a_bypass_enable_unreg, a_bypass_enable_reg, a_bypass_enable;
        logic    [WIDTH-1:0] a_bypass_data_unreg  , a_bypass_data_reg,   a_bypass_data;
        logic [BE_WIDTH-1:0] b_bypass_enable_unreg, b_bypass_enable_reg, b_bypass_enable;
        logic    [WIDTH-1:0] b_bypass_data_unreg  , b_bypass_data_reg,   b_bypass_data;

        //detect when the addresses match, less logic is needed if the effective addresses can only change at the same time (due to a common input clock enable)
        if (COMMON_IN_CLOCK_EN) begin
            always_ff @(posedge clock) begin
                if (a_in_clock_en) addr_match <= (a_address == b_address);
            end
        end
        else begin
            always_ff @(posedge clock) begin
                addr_match <= (a_mux_address == b_mux_address);
            end
        end

        //if a_in_clock_en and b_in_clock_en are driven from the same source, then we don't need to keep the writedata live from both port a and b
        //in addition to the above, if a_out_clock_en and b_out_clock_en are driven from the same source (but not necessarily the same source as the input clock enables), quartus should merge a_bypass_data and b_bypass_data
        //the same analysis also applies to byte enables
        always_ff @(posedge clock) begin
            if (b_in_clock_en) begin
                common_internal_byteenable <= (b_write) ? b_byteenable : a_byteenable;
                common_internal_writedata  <= (b_write) ? b_writedata  : a_writedata;
            end
        end

        //if the output data is unregistered, determine whether to use bypass and what the bypass data should be
        assign a_bypass_enable_unreg = (~a_internal_write &
                                        a_internal_read_enable &
                                        b_internal_write &
                                        addr_match) ? ((COMMON_IN_CLOCK_EN) ? common_internal_byteenable : b_internal_byteenable) : '0;
        assign a_bypass_data_unreg   =                 (COMMON_IN_CLOCK_EN) ? common_internal_writedata  : b_internal_writedata;
        assign b_bypass_enable_unreg = (~b_internal_write &
                                        b_internal_read_enable &
                                        a_internal_write &
                                        addr_match) ? ((COMMON_IN_CLOCK_EN) ? common_internal_byteenable : a_internal_byteenable) : '0;
        assign b_bypass_data_unreg   =                 (COMMON_IN_CLOCK_EN) ? common_internal_writedata  : a_internal_writedata;

        //if the output data is registered, the logic above serves as next state logic for the registered version, but now also need to factor in the output clock enable
        always_ff @(posedge clock) begin
            if (a_out_clock_en) begin
                a_bypass_enable_reg <= a_bypass_enable_unreg;
                a_bypass_data_reg   <= a_bypass_data_unreg;
            end
            if (b_out_clock_en) begin
                b_bypass_enable_reg <= b_bypass_enable_unreg;
                b_bypass_data_reg   <= b_bypass_data_unreg;
            end
        end

        //select between registered or unregistered output
        assign a_bypass_enable = (REGISTER_A_READDATA) ? a_bypass_enable_reg : a_bypass_enable_unreg;
        assign a_bypass_data   = (REGISTER_A_READDATA) ? a_bypass_data_reg   : a_bypass_data_unreg;
        assign b_bypass_enable = (REGISTER_B_READDATA) ? b_bypass_enable_reg : b_bypass_enable_unreg;
        assign b_bypass_data   = (REGISTER_B_READDATA) ? b_bypass_data_reg   : b_bypass_data_unreg;

        //adjust the read data if we have a mixed port read during write
        always_comb begin
            for (int i=0; i<BE_WIDTH; i++) begin
                a_readdata[i*BITS_PER_ENABLE+:BITS_PER_ENABLE] = (a_bypass_enable[i]) ? a_bypass_data[i*BITS_PER_ENABLE+:BITS_PER_ENABLE] : adjusted_q_a[i*BITS_PER_ENABLE+:BITS_PER_ENABLE];
                b_readdata[i*BITS_PER_ENABLE+:BITS_PER_ENABLE] = (b_bypass_enable[i]) ? b_bypass_data[i*BITS_PER_ENABLE+:BITS_PER_ENABLE] : adjusted_q_b[i*BITS_PER_ENABLE+:BITS_PER_ENABLE];
            end
        end
    end
    else begin
        assign a_readdata = adjusted_q_a;
        assign b_readdata = adjusted_q_b;
    end
    endgenerate



    /////////////////////////////////
    //  altera_syncram parameters  //
    /////////////////////////////////

    localparam int BYTE_SIZE                    = (BE_WIDTH == 1) ? 0 : BITS_PER_ENABLE;
    localparam     INTENDED_DEVICE_FAMILY       = DEVICE_FAMILY;
    localparam     OUTDATA_REG                  = (USE_HARD_LOGIC_FOR_OUT_REGISTER) ? ((USE_ENABLE) ? "CLOCK1" : "CLOCK0") : "UNREGISTERED";
    localparam     CLOCK_ENABLE_OUTPUT          = (USE_ENABLE && USE_HARD_LOGIC_FOR_OUT_REGISTER) ? "NORMAL" : "BYPASS";
    localparam     MIXED_PORT_READ_DURING_WRITE = (READ_DURING_WRITE == "DONT_CARE" || !DEVICE_FAMILY_A10_OR_OLDER) ? "DONT_CARE" : "OLD_DATA";
    localparam     POWER_UP_UNINITIALIZED       = (USE_MEM_INIT_FILE || ZERO_INITIALIZE_MEM) ? "FALSE" : "TRUE";
    localparam     MEM_INIT_FILE                = (USE_MEM_INIT_FILE) ? MEM_INIT_FILE_NAME : "UNUSED";



    ///////////////////////////////
    //  altera_syncram instance  //
    ///////////////////////////////

    altera_syncram
    #(
        //fundamentals
        .lpm_type                           ("altera_syncram"),
        .ram_block_type                     ("M20K"),
        .operation_mode                     ("BIDIR_DUAL_PORT"),
        .intended_device_family             (INTENDED_DEVICE_FAMILY),

        //clocking -- all inputs on clock0, all outputs on clock1 (or no clock if outputs are unregistered)
        .address_reg_b                      ("CLOCK0"),
        .byteena_reg_b                      ("CLOCK0"),
        .indata_reg_b                       ("CLOCK0"),
        .outdata_reg_a                      (OUTDATA_REG),
        .outdata_reg_b                      (OUTDATA_REG),

        //clock enables
        .clock_enable_input_a               ("BYPASS"),
        .clock_enable_input_b               ("BYPASS"),
        .clock_enable_output_a              (CLOCK_ENABLE_OUTPUT),
        .clock_enable_output_b              (CLOCK_ENABLE_OUTPUT),

        //reset is not used
        .outdata_aclr_a                     ("NONE"),
        .outdata_aclr_b                     ("NONE"),
        .outdata_sclr_a                     ("NONE"),
        .outdata_sclr_b                     ("NONE"),

        //size of the memory
        .widthad_a                          (ADDR),             //bit width of the address
        .widthad_b                          (ADDR),
        .numwords_a                         (DEPTH),            //number of words
        .numwords_b                         (DEPTH),
        .width_a                            (WIDTH),            //width of the write data and read data signals
        .width_b                            (WIDTH),
        .width_byteena_a                    (BE_WIDTH),         //width of the byte enable signal
        .width_byteena_b                    (BE_WIDTH),
        .byte_size                          (BYTE_SIZE),

        //force to zero
        .enable_force_to_zero               (ENABLE_FORCE_TO_ZERO),

        //limit the depth of the memory to ensure access to all 20k bits
        .maximum_depth                      (MAXIMUM_DEPTH),

        //mixed port read during write
        .read_during_write_mode_mixed_ports (MIXED_PORT_READ_DURING_WRITE),

        //same port read during write -- dla_hld_ram does not allow configuration of this
        .read_during_write_mode_port_a      ("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b      ("NEW_DATA_NO_NBE_READ"),

        //hardened error correction code
        .enable_ecc                         ("FALSE"),

        //memory initialization
        .power_up_uninitialized             (POWER_UP_UNINITIALIZED),
        .init_file                          (MEM_INIT_FILE)
    )
    altera_syncram_inst
    (
        //clock
        .clock0                             (clock0),
        .clock1                             (clock1),

        //no reset
        .aclr0                              (1'b0),
        .aclr1                              (1'b0),
        .sclr                               (1'b0),

        //port a
        .address_a                          (address_a),
        .addressstall_a                     (addressstall_a),
        .byteena_a                          (byteena_a),
        .data_a                             (data_a),
        .wren_a                             (wren_a),
        .q_a                                (q_a),
        .rden_a                             (rden_a),

        //port b
        .address_b                          (address_b),
        .addressstall_b                     (addressstall_b),
        .byteena_b                          (byteena_b),
        .data_b                             (data_b),
        .wren_b                             (wren_b),
        .q_b                                (q_b),
        .rden_b                             (rden_b),

        //shared
        .clocken0                           (1'b1),
        .clocken1                           (clocken1),

        //unused stuff which was intended for quad port ram
        .address2_a                         (1'b1),
        .address2_b                         (1'b1),
        .clocken2                           (1'b1),
        .clocken3                           (1'b1),

        //error correction codes
        .eccencbypass                       (1'b0),
        .eccencparity                       (8'b0),
        .eccstatus                          ()
    );

endmodule

`default_nettype wire
