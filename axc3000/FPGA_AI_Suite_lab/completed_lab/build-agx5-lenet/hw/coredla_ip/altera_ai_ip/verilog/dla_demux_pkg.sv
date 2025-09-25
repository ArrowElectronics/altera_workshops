// Copyright 2024 Altera Corporation.
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

// This package keeps all of the arch parameters related to the demux module
// For now it only includes the config struct

`resetall
`undefineall
package dla_demux_pkg;
  import dla_common_pkg::*;
  `include "dla_demux_config.svh"
endpackage
