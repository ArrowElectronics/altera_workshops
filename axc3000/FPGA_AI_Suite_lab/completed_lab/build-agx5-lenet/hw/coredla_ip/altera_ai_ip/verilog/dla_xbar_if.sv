// Copyright 2021-2021 Altera Corporation.
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

// Xbar PI ouput specific beat(s)
interface xbar_config_beat_pioutput_if #(
  dla_xbar_pkg::xbar_config_parameter_t config_field_param
);
  typedef struct packed {
    logic [config_field_param.OUTPUT_CONFIG_WORD_ORSEL_WIDTH-1:0]           output_route_select;
    logic [config_field_param.OUTPUT_CONFIG_WORD_RESERVED0_WIDTH-1:0]       reserved;
    // NOTE:: One can't use the MUX-select signals assigned for valid/data for ready
    logic [config_field_param.AUX_KERNEL_SELECT_ID_WIDTH-1:0]               inp_mux_select; // MUX select signal for the ready signal back to PE Array
    logic [config_field_param.AUX_KERNEL_SELECT_ID_WIDTH-1:0]               opt_mux_select; //
  } Type;
  Type data;
  modport sender (output data);
  modport receiver (input data);
endinterface

// Kernel's specific beat(s)
interface xbar_config_beat_kernel_if #(
  dla_xbar_pkg::xbar_config_parameter_t config_field_param
);
  typedef struct packed {
    struct packed {
      logic [config_field_param.KERNEL_CONFIG_WORD_BYF_WIDTH-1:0] bypass_flag       ;
      logic [config_field_param.KERNEL_CONFIG_WORD_NCF_WIDTH-1:0] connection_flag;
      logic [config_field_param.KERNEL_CONFIG_WORD_RESERVED0_WIDTH-1:0]       reserved;
      // NOTE:: One can't use the MUX-select signals assigned for valid/data for ready
      logic [config_field_param.AUX_KERNEL_SELECT_ID_WIDTH-1:0]               inp_mux_select; // MUX select signal for ready signal back to kernels
      logic [config_field_param.AUX_KERNEL_SELECT_ID_WIDTH-1:0]               opt_mux_select; // MUX select signal for valid/data signals to kernels
    } [config_field_param.NUMBER_OF_AUX_KERNELS_ONLY:1] kernels; // Array addressed from 1, because 0 is reserved for output_fields in this case!
  } Type;
  Type data;
  modport sender (output data);
  modport receiver (input data);
endinterface

// Xbar input data count specific beat(s)
interface xbar_config_beat_idatacount_if #(
  dla_xbar_pkg::xbar_config_parameter_t config_field_param
);
  typedef struct packed {
    logic [config_field_param.IDCOUNT_CONFIG_WORD_RESERVED0_WIDTH-1:0]      reserved;
    logic [config_field_param.XBAR_INPUT_COUNTER_WIDTH-1:0]                 count;
  } Type;
  Type data;
  modport sender (output data);
  modport receiver (input data);
endinterface

// Xbar output data count specific beat(s)
interface xbar_config_beat_odatacount_if #(
  dla_xbar_pkg::xbar_config_parameter_t config_field_param
);
  typedef struct packed {
    logic [config_field_param.ODCOUNT_CONFIG_WORD_RESERVED0_WIDTH-1:0]      reserved;
    logic [config_field_param.XBAR_OUTPUT_COUNTER_WIDTH-1:0]                count;
  } Type;
  Type data;
  modport sender (output data);
  modport receiver (input data);
endinterface

// ----------------------- Config Packet -----------------------
interface xbar_config_pkt_if #(
  dla_xbar_pkg::xbar_config_parameter_t config_field_param
);
  typedef struct packed {
    struct packed  {
      logic [config_field_param.ODCOUNT_CONFIG_WORD_RESERVED0_WIDTH-1:0]      reserved;
      logic [config_field_param.XBAR_OUTPUT_COUNTER_WIDTH-1:0]                count;
    } odcount_fields;

    struct packed {
      logic [config_field_param.IDCOUNT_CONFIG_WORD_RESERVED0_WIDTH-1:0]      reserved;
      logic [config_field_param.XBAR_INPUT_COUNTER_WIDTH-1:0]                 count;
    } idcount_fields;
    // Array addressed from 1, because 0 is reserved for output_fields in this case!
    struct packed {
      logic [config_field_param.KERNEL_CONFIG_WORD_BYF_WIDTH-1:0] bypass_flag       ;
      logic [config_field_param.KERNEL_CONFIG_WORD_NCF_WIDTH-1:0] connection_flag;
      logic [config_field_param.KERNEL_CONFIG_WORD_RESERVED0_WIDTH-1:0]       reserved;
      // NOTE:: One can't use the MUX-select signals assigned for valid/data for ready
      logic [config_field_param.AUX_KERNEL_SELECT_ID_WIDTH-1:0]               inp_mux_select; // MUX select signal for ready signal back to kernels
      logic [config_field_param.AUX_KERNEL_SELECT_ID_WIDTH-1:0]               opt_mux_select; // MUX select signal for valid/data signals to kernels
    } [config_field_param.NUMBER_OF_AUX_KERNELS_ONLY:1] kernel_fields;
    struct packed {
      logic [config_field_param.OUTPUT_CONFIG_WORD_ORSEL_WIDTH-1:0]           output_route_select;
      logic [config_field_param.OUTPUT_CONFIG_WORD_RESERVED0_WIDTH-1:0]       reserved;
      // NOTE:: One can't use the MUX-select signals assigned for valid/data for ready
      logic [config_field_param.AUX_KERNEL_SELECT_ID_WIDTH-1:0]               inp_mux_select; // MUX select signal for the ready signal back to PE Array
      logic [config_field_param.AUX_KERNEL_SELECT_ID_WIDTH-1:0]               opt_mux_select; //
    } pi_opt_fields;
  } Type;
  Type data;
  modport sender (output data);
  modport receiver (input data);
endinterface

// ----------------------- Config Handler FSM - State Variable -----------------------
interface config_fsm_state_var_if #(
  dla_xbar_pkg::xbar_config_parameter_t config_field_param
);
  typedef struct packed {
    logic config_ready;
    // Note:: Config is collected in a packed array // (each array element consisting of a beat worth of information) of size equal to total-beat-count
    logic [(config_field_param.CONFIG_DATA_WIDTH * config_field_param.CONFIG_BEAT_COUNT)-1:0]   config_pkt;
    logic config_valid;
    logic [config_field_param.CONFIG_BEAT_COUNTER_WIDTH-1:0]        config_beat_count;
  } Type;
  Type data;
  modport sender (output data);
  modport receiver (input data);
endinterface

interface xbar_ctrl_fsm_state_var_if #(
  dla_xbar_pkg::xbar_config_parameter_t fsm_param
);
  typedef struct packed {
    struct packed {
      struct packed  {
        logic [fsm_param.ODCOUNT_CONFIG_WORD_RESERVED0_WIDTH-1:0]      reserved;
        logic [fsm_param.XBAR_OUTPUT_COUNTER_WIDTH-1:0]                count;
      } odcount_fields;

      struct packed {
        logic [fsm_param.IDCOUNT_CONFIG_WORD_RESERVED0_WIDTH-1:0]      reserved;
        logic [fsm_param.XBAR_INPUT_COUNTER_WIDTH-1:0]                 count;
      } idcount_fields;
      // Array addressed from 1, because 0 is reserved for output_fields in this case!
      struct packed {
        logic [fsm_param.KERNEL_CONFIG_WORD_BYF_WIDTH-1:0] bypass_flag       ;
        logic [fsm_param.KERNEL_CONFIG_WORD_NCF_WIDTH-1:0] connection_flag;
        logic [fsm_param.KERNEL_CONFIG_WORD_RESERVED0_WIDTH-1:0]       reserved;
        // NOTE:: One can't use the MUX-select signals assigned for valid/data for ready
        logic [fsm_param.AUX_KERNEL_SELECT_ID_WIDTH-1:0]               inp_mux_select; // MUX select signal for ready signal back to kernels
        logic [fsm_param.AUX_KERNEL_SELECT_ID_WIDTH-1:0]               opt_mux_select; // MUX select signal for valid/data signals to kernels
      } [fsm_param.NUMBER_OF_AUX_KERNELS_ONLY:1] kernel_fields;
      struct packed {
        logic [fsm_param.OUTPUT_CONFIG_WORD_ORSEL_WIDTH-1:0]           output_route_select;
        logic [fsm_param.OUTPUT_CONFIG_WORD_RESERVED0_WIDTH-1:0]       reserved;
        // NOTE:: One can't use the MUX-select signals assigned for valid/data for ready
        logic [fsm_param.AUX_KERNEL_SELECT_ID_WIDTH-1:0]               inp_mux_select; // MUX select signal for the ready signal back to PE Array
        logic [fsm_param.AUX_KERNEL_SELECT_ID_WIDTH-1:0]               opt_mux_select; //
      } pi_opt_fields;
    } config_copy;
    logic [fsm_param.XBAR_INPUT_COUNTER_WIDTH-1:0]      inp_counter;
    logic [fsm_param.XBAR_OUTPUT_COUNTER_WIDTH-1:0]     opt_counter;
    logic   primary_input_e;    // Enable for PE-Array input
    logic   primary_output_e;   // Enable for the last aux-kernel in the pipeline
    logic   input_counter_done;
    logic   output_counter_done;
    logic   config_serviced;
  } Type;
  Type data;
  modport sender (output data);
  modport receiver (input data);
endinterface
