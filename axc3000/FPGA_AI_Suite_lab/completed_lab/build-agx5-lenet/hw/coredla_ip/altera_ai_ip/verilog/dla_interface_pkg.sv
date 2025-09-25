// Copyright 2020-2021 Altera Corporation.
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

// --- dla_interface_pkg ---
// This package contains types which are used as interface types between
// subsystems. They are kept separate from the types in `dla_common_pkg`
// because the names in this package sometimes conflict with names in other
// packages, which cannot happen in `dla_common_pkg`. These name conflicts can
// happen because some subsystems create a typedef alias of a type in
// `dla_interface_pkg` with the same name except it is parameterized by an
// "arch" struct from the subsystem for convenience.
package dla_interface_pkg;
  import dla_common_pkg::*;

  virtual class vector_t #(int VECTOR_SIZE, int DATA_WIDTH);
    typedef struct packed {
      logic [VECTOR_SIZE-1:0][DATA_WIDTH-1:0] v;
    } t;
  endclass

  virtual class block_t #(int BLOCK_SIZE, int MANTISSA_WIDTH, int EXPONENT_WIDTH);
    typedef struct packed {
      logic [EXPONENT_WIDTH-1:0] exponent;
      logic [BLOCK_SIZE-1:0][MANTISSA_WIDTH-1:0] mantissa;
    } t;
  endclass

  virtual class pe_array_control_t #(int ELTWISE_MULT_CMD_WIDTH, int RESULT_ID_WIDTH);
    typedef struct packed {
      logic valid;
      logic init_accumulator;
      logic flush_accumulator;
      logic [ELTWISE_MULT_CMD_WIDTH-1:0] eltwise_mult_cmd;
      logic [RESULT_ID_WIDTH-1:0] result_id;
    } t;
  endclass

  virtual class pe_array_feature_t #(
    int BLOCK_SIZE,
    int FEATURE_WIDTH,
    int FEATURE_EXPONENT_WIDTH,
    int NUM_LANES,
    int NUM_FEATURES
  );
    typedef block_t#(
      .BLOCK_SIZE(BLOCK_SIZE),
      .MANTISSA_WIDTH(FEATURE_WIDTH),
      .EXPONENT_WIDTH(FEATURE_EXPONENT_WIDTH))::t [NUM_LANES-1:0][NUM_FEATURES-1:0] t;
  endclass

  virtual class pe_array_filter_t #(
    int BLOCK_SIZE,
    int FILTER_WIDTH,
    int FILTER_EXPONENT_WIDTH,
    int NUM_PES,
    int NUM_FILTERS
  );
    typedef block_t#(
      .BLOCK_SIZE(BLOCK_SIZE),
      .MANTISSA_WIDTH(FILTER_WIDTH),
      .EXPONENT_WIDTH(FILTER_EXPONENT_WIDTH))::t [NUM_PES-1:0][NUM_FILTERS-1:0] t;
  endclass

  virtual class pe_array_bias_t #(
    int BIAS_WIDTH,
    int NUM_PES,
    int NUM_FILTERS
  );
    typedef logic [NUM_PES-1:0][NUM_FILTERS-1:0][BIAS_WIDTH-1:0] t;
  endclass

  virtual class pe_array_scale_t #(
    int SCALE_WIDTH,
    int NUM_PES,
    int NUM_FILTERS
  );
    typedef logic [NUM_PES-1:0][NUM_FILTERS-1:0][SCALE_WIDTH-1:0] t;
  endclass

  virtual class pe_array_result_t #(
    int RESULT_WIDTH,
    int NUM_FEATURES,
    int NUM_RESULTS_PER_CYCLE,
    int NUM_LANES
  );
    typedef struct packed {
      logic valid;
      logic [NUM_LANES-1:0][NUM_RESULTS_PER_CYCLE-1:0][NUM_FEATURES-1:0][RESULT_WIDTH-1:0] result;
    } t;
  endclass

  virtual class scratchpad_write_addr_t #(int MEM_ID_WIDTH, int MEM_ADDR_WIDTH);
    typedef struct packed {
      logic [MEM_ID_WIDTH-1:0] mem_id;
      logic [MEM_ADDR_WIDTH-1:0] mem_addr;
    } t;
  endclass

  virtual class scratchpad_write_data_t #(
    int MAX_DATA_WIDTH
  );
    typedef struct packed {
      logic is_filter; // indicates whether the write data is filter data or bias data
      logic [MAX_DATA_WIDTH-1:0] data;
    } t;
  endclass

  virtual class scratchpad_read_addr_t #(
      int FILTER_BASE_ADDR_WIDTH,
      int BIAS_SCALE_BASE_ADDR_WIDTH
  );
    typedef struct packed {
      // The base read address (address without the last bit) for filter
      // reading when 2x clock is enabled. Otherwise this represents full
      // address to read from.
      logic [FILTER_BASE_ADDR_WIDTH-1:0] filter_base_addr;

      // Same as filter_base_addr but for bias_scale. Synchronous to it. Not
      // used when ENABLE_2X_READ is off. ??
      logic [BIAS_SCALE_BASE_ADDR_WIDTH-1:0] bias_scale_base_addr;
    } t;
  endclass

  virtual class scratchpad_read_data_t#(
      int NUM_PE_PORTS,
      int BLOCK_SIZE,
      int FILTER_WIDTH,
      int FILTER_EXPONENT_WIDTH,
      int BIAS_WIDTH,
      int SCALE_WIDTH);
    typedef struct packed {
      struct packed {
        logic valid;
        block_t#(
          .BLOCK_SIZE(BLOCK_SIZE),
          .MANTISSA_WIDTH(FILTER_WIDTH),
          .EXPONENT_WIDTH(FILTER_EXPONENT_WIDTH))::t filter;

        logic  [BIAS_WIDTH-1:0] bias;
        logic [SCALE_WIDTH-1:0] scale;
      } [NUM_PE_PORTS-1:0] ports;
    } t;
  endclass

  typedef struct packed {
    logic init_accumulator;
    logic flush_accumulator;

    logic [31:0] filter_read_addr;
    logic [31:0] filter_read_base_addr;

    logic [31:0] bias_read_addr;
    logic [31:0] bias_read_base_addr;

    logic layer_first_valids;
    logic feature_valid;

    logic [31:0] eltwise_mult_cmd;

    logic filter_read;
    logic all_done;
  } input_feeder_control_t;

  function automatic int get_input_feeder_control_width();
    return $bits(input_feeder_control_t);
  endfunction

  function automatic input_feeder_control_t get_input_feeder_control(
     logic [get_input_feeder_control_width()-1:0] input_feeder_raw_data
  );
      input_feeder_control_t control = input_feeder_control_t'(input_feeder_raw_data);

      return control;
  endfunction

  typedef struct {
    int NUM_LANES;
    int NUM_RESULTS_PER_CYCLE;
    int NUM_FEATURES;
    int RESULT_WIDTH;
  } pe_array_result_param_t;

  typedef struct {
    int ELTWISE_MULT_CMD_WIDTH;
    int RESULT_ID_WIDTH;
  } pe_array_control_param_t;

  typedef struct {
    int NUM_FEATURES;
    int NUM_LANES;
    int DOT_SIZE;
    int FEATURE_WIDTH;
    int FEATURE_EXPONENT_WIDTH;
  } input_feeder_feature_param_t;

  function automatic int calc_mem_id_width(int NUM_PE_PORTS, int NUM_FILTER_PORTS, int NUM_BIAS_SCALE_PORTS);
    // Max number of filter memories per filter write group.
    automatic int NUM_FILTER_MEM_PER_GROUP = divceil(NUM_PE_PORTS, NUM_FILTER_PORTS);
    // Max number of bias_scale memories per filter write group.
    automatic int NUM_BIAS_SCALE_MEM_PER_GROUP = divceil(NUM_PE_PORTS, NUM_BIAS_SCALE_PORTS);
    return $clog2(max(NUM_FILTER_MEM_PER_GROUP, NUM_BIAS_SCALE_MEM_PER_GROUP));
  endfunction

  function automatic int calc_mem_addr_width(int FILTER_DEPTH, int BIAS_SCALE_DEPTH);
    return $clog2(max(FILTER_DEPTH, BIAS_SCALE_DEPTH));
  endfunction

  function automatic int calc_filter_base_addr_width(int FILTER_DEPTH);
    return $clog2(FILTER_DEPTH);
  endfunction

  function automatic int calc_bias_scale_base_addr_width(int BIAS_SCALE_DEPTH);
    return $clog2(BIAS_SCALE_DEPTH);
  endfunction

  typedef struct {
    int SCRATCHPAD_MEM_ID_WIDTH;
    int SCRATCHPAD_MEM_ADDR_WIDTH;
    int SCRATCHPAD_FILTER_BASE_ADDR_WIDTH;
    int SCRATCHPAD_BIAS_SCALE_BASE_ADDR_WIDTH;
  } scratchpad_param_t;

  // Data stream parameters defined as a struct type
  typedef struct {
    int ELEMENT_BITS      ; // Bit width of each tensor element (e.g., 16 for float16)
    int VECTOR_SIZE       ; // Vector depth of each transaction per-lane (former k drain)
    int NATIVE_VECTOR_SIZE; // Vector depth of multiple transactions per-lane (former k depth)
    int GROUP_SIZE        ; // Number of lanes within a phase-aligned group
    int GROUP_NUM         ; // Number of phase-aligned groups
    int GROUP_DELAY       ; // Number of clocks of delay between phases
  } aux_data_pack_params_t;
endpackage
