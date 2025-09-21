/***********************************************************************
* 
************************************************************************/

module AXC3000_MIPI (

// Push Button
input         USER_BTN,

// UART pin
input         UART_RXD,
output        UART_TXD,

// DIP switches
//input [1:0]   DIP_SW,

// LEDs
output        RLED, GLED, BLED,
output reg    LED1,

// Arduino MKR
//inout [14:0]  D,
//inout         D11_R, D12_R,
//inout [6:0]   AIN,
//output        AIN0,
//inout         AREF,
//output        AREF,

// Accelerometer
//input         INT1, INT2,			// Need internal pull-up?
//inout         I2C_SCL, I2C_SDA,
// CRUVI pins (MIPI)
//input         C_B5P,  C_B1P, C_B0P,
input         MIPI_D1P, MIPI_D0P, MIPI_CLKP,
input         MIPI_D1N, MIPI_D0N, MIPI_CLKN,
//output        C_A5P, C_A4P, C_A3P, C_A2P, C_A1P, C_A0P,
input         MIPI_RZQ,
input         MIPI_REFCLK, 
inout           CAMERA_SDA, CAMERA_SCL,
output          CAMERA_EN,
//inout         C_HSMIO,
//inout         C_HSO, C_HSRST, C_HSI,
//inout         C_REFCLK,

// HyperRAM
//inout [7:0]   HR_DQ,
//output        HR_CLK,
//output        HR_RWDS, HR_HRESETn, HR_CSn,

// Global Signals
output        VSEL_1V3,		// VADJ selector between 1.2V and 1.3V
input         CLK_25M_C


);


// Global signals
wire clk_150MHz;

// Sign of Life Counter 
reg [23:0] counter4led;		// 6.4ns led_clk
wire       counter_expired;
assign counter_expired = (counter4led[23:22] == 2'b11);

// I2C bidi buffers
wire     camera_i2c_sda_in, camera_i2c_sda_oe , camera_i2c_scl_in, camera_i2c_scl_oe;
assign   CAMERA_SCL    = camera_i2c_scl_oe ? 1'b0 : 1'bz;
assign   camera_i2c_scl_in = CAMERA_SCL;
assign   CAMERA_SDA    = camera_i2c_sda_oe ? 1'b0 : 1'bz;
assign   camera_i2c_sda_in     = CAMERA_SDA;

// Select 1.3V for HSIO
assign VSEL_1V3 = 1'b1;


/******************************************************************************/

   niosv_system niosv_sys (
      .clk_25m_clk     (CLK_25M_C),          //   input,  width = 1,       clk.clk
      .camera_i2c_sda_in (camera_i2c_sda_in), //   input,  width = 1, niosv_i2c.sda_in
      .camera_i2c_scl_in (camera_i2c_scl_in), //   input,  width = 1,          .scl_in
      .camera_i2c_sda_oe (camera_i2c_sda_oe), //  output,  width = 1,          .sda_oe
      .camera_i2c_scl_oe (camera_i2c_scl_oe),  //  output,  width = 1,          .scl_oe
      .rgb_pio_export  ({RLED,GLED,BLED}),  //  output,  width = 3,   pwm_out.conduit
      .reset_n_reset_n  (USER_BTN),   //   input,  width = 1,   reset_n.reset_n
      .dbg_uart_rxd              (UART_RXD),              //   input,  width = 1,         dbg_uart.rxd
      .dbg_uart_txd              (UART_TXD),              //  output,  width = 1,                 .txd
      .mipi_pio_export           (CAMERA_EN),    //   input,  width = 2,    dip_sw.export
      .mipi_dphy_rzq_rzq         (MIPI_RZQ),         //   input,  width = 1,    mipi_dphy_rzq.rzq
      .mipi_dphy_refclk_clk      (MIPI_REFCLK),      //   input,  width = 1, mipi_dphy_refclk.clk
      .mipi_dphy_io_dphy_link_dp ({MIPI_D1P, MIPI_D0P}), //   input,  width = 2,     mipi_dphy_io.dphy_link_dp
      .mipi_dphy_io_dphy_link_dn ({MIPI_D1N, MIPI_D0N}), //   input,  width = 2,                 .dphy_link_dn
      .mipi_dphy_io_dphy_link_cp (MIPI_CLKP), //   input,  width = 1,                 .dphy_link_cp
      .mipi_dphy_io_dphy_link_cn (MIPI_CLKN),  //   input,  width = 1,                 .dphy_link_cn
      .sysclk_out_clk            (clk_150MHz)             //  output,  width = 1,       sysclk_out.clk
	);


/******************************************************************************/


// LED counter 
always @ (posedge clk_150MHz) begin
	 if (counter_expired) begin
	   counter4led <= 24'h0;
		LED1 <= !LED1;
	 end
	 else begin
	   counter4led <= counter4led + 24'h01;
		LED1 <= LED1;
	 end
end


endmodule
