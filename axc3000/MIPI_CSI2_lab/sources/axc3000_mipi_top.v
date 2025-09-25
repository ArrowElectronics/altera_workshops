/***********************************************************************
* 
************************************************************************/

module axc3000_mipi_top (

// Global Signals
output        VSEL_1V3,		// VADJ selector between 1.2V and 1.3V
input         CLK_25M_C,

// Push Button
input         USER_BTN,

// UART pin
input         DBG_RX,
output        DBG_TX,

// LED
output        RLED, GLED, BLED,

// MIPI signas
input         MIPI_D1P, MIPI_D0P, MIPI_CLKP,
input         MIPI_D1N, MIPI_D0N, MIPI_CLKN,
//output        DSI_D1P, DSI_D0P, DSI_CLKP,
//output        DSI_D1N, DSI_D0N, DSI_CLKN,
input         MIPI_RZQ,
input         MIPI_REFCLK, 
inout         SMB_SDA, SMB_SCL,
output        CAMERA_EN

);


// I2C bidi buffers
wire     camera_i2c_sda_in, camera_i2c_sda_oe , camera_i2c_scl_in, camera_i2c_scl_oe;
assign   SMB_SCL    = camera_i2c_scl_oe ? 1'b0 : 1'bz;
assign   camera_i2c_scl_in = SMB_SCL;
assign   SMB_SDA    = camera_i2c_sda_oe ? 1'b0 : 1'bz;
assign   camera_i2c_sda_in     = SMB_SDA;


// Select 1.3V for HSIO
assign VSEL_1V3 = 1'b1;



/******************************************************************************/

    top_system mipi_top (
        .clk25mhz_clk              (CLK_25M_C),  
        .mipi_dphy_rzq_rzq         (MIPI_RZQ),  
        .mipi_dphy_refclk_clk      (MIPI_REFCLK),  
        .mipi_csi2_io_dphy_link_dp ({MIPI_D1P, MIPI_D0P}), 
        .mipi_csi2_io_dphy_link_dn ({MIPI_D1N, MIPI_D0N}),
        .mipi_csi2_io_dphy_link_cp (MIPI_CLKP),
        .mipi_csi2_io_dphy_link_cn (MIPI_CLKN), 
        .camera_i2c_sda_in         (camera_i2c_sda_in), 
        .camera_i2c_scl_in         (camera_i2c_scl_in),
        .camera_i2c_sda_oe         (camera_i2c_sda_oe),
        .camera_i2c_scl_oe         (camera_i2c_scl_oe),  
        .dbg_uart_rxd              (DBG_RX), 
        .dbg_uart_txd              (DBG_TX),
        .led_export                ({RLED,GLED,BLED}), 
        .camera_en_export          (CAMERA_EN), 
        .pb_export                 (USER_BTN) 
	);

/******************************************************************************/




endmodule
