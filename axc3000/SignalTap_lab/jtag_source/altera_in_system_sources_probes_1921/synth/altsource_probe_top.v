// (C) 2001-2025 Altera Corporation. All rights reserved.
// Your use of Altera Corporation's design tools, logic functions and other 
// software and tools, and its AMPP partner logic functions, and any output 
// files from any of the foregoing (including device programming or simulation 
// files), and any associated documentation or information are expressly subject 
// to the terms and conditions of the Altera Program License Subscription 
// Agreement, Altera IP License Agreement, or other applicable 
// license agreement, including, without limitation, that your use is for the 
// sole purpose of programming logic devices manufactured by Altera and sold by 
// Altera or its authorized distributors.  Please refer to the applicable 
// agreement for further details.


module altsource_probe_top
#(
    parameter lpm_type = "altsource_probe",     // required by the coding standard
    parameter lpm_hint = "UNUSED",              // required by the coding standard 

    parameter sld_auto_instance_index = "YES",  // Yes, if the instance index should be automatically assigned.
    parameter sld_instance_index = 0,           // unique identifier for the altsource_probe instance.
    parameter sld_node_info_parameter = 4746752 + sld_instance_index,   // The NODE ID to uniquely identify this node on the hub.  Type ID: 9 Version: 0 Inst: 0 MFG ID 110 -- ***NOTE*** this parameter cannot be called SLD_NODE_INFO or Quartus Standard will think it's an ISSP impl.
    parameter sld_ir_width = 4,                 
                                        
    parameter instance_id = "UNUSED",           // optional name for the instance.
    parameter probe_width = 1,                  // probe port width
    parameter source_width= 1,                  // source port width
    parameter source_initial_value = "0",       // initial source port value
    parameter enable_metastability = "NO"       // yes to add two register
)
(
    input [probe_width - 1 : 0] probe,       // probe inputs
    output [source_width - 1 : 0] source,    // source outputs
    input source_clk,                        // clock of the registers used to metastabilize the source output
    input tri1 source_ena                    // enable of the registers used to metastabilize the source output
);

    altsource_probe #(
        .lpm_type(lpm_type),
        .lpm_hint(lpm_hint),   
        .sld_auto_instance_index(sld_auto_instance_index),
        .sld_instance_index(sld_instance_index),
        .SLD_NODE_INFO(sld_node_info_parameter),
        .sld_ir_width(sld_ir_width),                          
        .instance_id(instance_id),
        .probe_width(probe_width),
        .source_width(source_width),
        .source_initial_value(source_initial_value),
        .enable_metastability(enable_metastability)
    )issp_impl
    (
        .probe(probe),
        .source(source),
        .source_clk(source_clk),
        .source_ena(source_ena)
    );
    
endmodule
`ifdef QUESTA_INTEL_OEM
`pragma questa_oem_00 "gxUC0uHYGh5iTQS8ia15YhsMdiQ/QO3FIgn/CTziZ81FfcVb1wIu1TUDtUSAlPhrI8sFn2gLVFPYIAWgXa1CDIAxu7+Mu95EspuhkTIiZDKiE84F2bHA++ET8wpXBxIIzmaIhNXoKrqjdVZK86WH9pgYZAAHPFZVidAScxF2oS+ZuawRq7tLosd7KKtmNPpGbid6ZD6+4i3ffC0mporV3iLa8AJf3f5c/wtX4oOh5PpOgc0i+wIfi4btG95Dm5RrQFUeXpAFNqK/EnY4sOfAf0Zo1fHgxvFxc1+p51IbWEY1XKVT7reWsTk51LsbkVXK7p4//GXS0dymo8ay91Wm+QiEBuF86h/pjTCgYWlB0w785q8tfP97IhaPzrqh1nnfXtf0ScsIC7TvtrzOJ5KaIe1VMlVVctxNdWD0LbQvBglosfrNq5UsecUrIyMksSnFucTSf73a/QmFrI5hgSI/pbEW4e1NXgA3/4b3uFaNi7oL518iRaFwpchwiYH+gF383z7VnQMXN+BhGLTVcWkFbvxhFDN7/P02FQ89/+2FfFuB/x5UBsgOFRNScK5hoG9pM3g2x4hpf4MZZevjITDmeY/fnGctdfCaQuQtVVrsT+TzO0X0WHurIEt4TMpbJZfekpF+KwyRArV+VXQIWosuVeXITrSsei8gq1MK3wSfSP8kM173cClntYEV4XO3WkURBceZtdIi4EILbPsrMv+bliFugy40/bQoAG8gkI7MXZB/5tTQjBQNk+LnvPZlIg+DkNrsU0Rx1hz7TEcUHy47uDLVdUaslERs6M/H3m9hx2OzoTz3XohmOMwyZx/j/S8t6z0pEX/IdzK1sUvQvj/DiDrvAiLs9H06qpKnTL0nGNBBgLwZRKSPbcLLuYS9O96W9jP0owiXvhCx9XnsE6jte21yFhBwsl7O8ARZSf/ohM/UkSfXZHozmQfA8CfSvpuSZoXA1cgZWvchHYtk6Dxhge0R+Ibw57xrCNMNRhvKWG1To928DUp7UxSPX0lM4AdC"
`endif