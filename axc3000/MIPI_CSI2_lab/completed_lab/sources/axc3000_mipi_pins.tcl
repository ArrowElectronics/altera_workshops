####################################################################
# AXE5000 Pin Assignment
#
########### Bank 3A (1.2V) #########################################
# 1.3-V LVCMOS is used to fake Quartus since 
set_location_assignment PIN_A7  -to CLK_25M_C
set_instance_assignment -name IO_STANDARD "1.2-V" -to CLK_25M_C

# HyperRAM
#set_location_assignment PIN_A6  -to HR_RWDS
#set_instance_assignment -name IO_STANDARD "1.2-V" -to HR_RWDS
#set_location_assignment PIN_F7  -to HR_HRESETn
#set_instance_assignment -name IO_STANDARD "1.2-V" -to HR_HRESETn
#set_location_assignment PIN_D8  -to HR_CSn
#set_instance_assignment -name IO_STANDARD "1.2-V" -to HR_CSn
#set_location_assignment PIN_C3  -to HR_DQ[0]
#set_instance_assignment -name IO_STANDARD "1.2-V" -to HR_DQ[0]
#set_location_assignment PIN_C2  -to HR_DQ[1]
#set_instance_assignment -name IO_STANDARD "1.2-V" -to HR_DQ[1]
#set_location_assignment PIN_B4  -to HR_DQ[2]
#set_instance_assignment -name IO_STANDARD "1.2-V" -to HR_DQ[2]
#set_location_assignment PIN_B6  -to HR_DQ[3]
#set_instance_assignment -name IO_STANDARD "1.2-V" -to HR_DQ[3]
#set_location_assignment PIN_D3  -to HR_DQ[4]
#set_instance_assignment -name IO_STANDARD "1.2-V" -to HR_DQ[4]
#set_location_assignment PIN_A4  -to HR_DQ[5]
#set_instance_assignment -name IO_STANDARD "1.2-V" -to HR_DQ[5]
#set_location_assignment PIN_B3  -to HR_DQ[6]
#set_instance_assignment -name IO_STANDARD "1.2-V" -to HR_DQ[6]
#set_location_assignment PIN_C6  -to HR_DQ[7]
#set_instance_assignment -name IO_STANDARD "1.2-V" -to HR_DQ[7]
#set_location_assignment PIN_D7  -to HR_CLK
#set_instance_assignment -name IO_STANDARD "1.2-V" -to HR_CLK

# DIP Switches
#set_location_assignment PIN_A14  -to DIP_SW[0]
#set_instance_assignment -name IO_STANDARD "1.2-V" -to DIP_SW[0]
#set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to DIP_SW[0]
#set_location_assignment PIN_A13  -to DIP_SW[1]
#set_instance_assignment -name IO_STANDARD "1.2-V" -to DIP_SW[1]
#set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to DIP_SW[1]

# Push-Button Switches
set_location_assignment PIN_A12  -to USER_BTN
set_instance_assignment -name IO_STANDARD "1.2-V" -to USER_BTN
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to USER_BTN






########### Bank 5A/5B (3.3V) #########################################
set_location_assignment PIN_AJ24  -to VSEL_1V3
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to VSEL_1V3

# Debug UART
# BDBUS0 on FTDI
set_location_assignment PIN_AG23  -to DBG_RX
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to DBG_RX
# BDBUS1 on FTDI
set_location_assignment PIN_AG24  -to DBG_TX
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to DBG_TX

# LEDs
#set_location_assignment PIN_AG21  -to LED1
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to LED1

set_location_assignment PIN_AH22  -to RLED
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to RLED
set_location_assignment PIN_AK21  -to GLED
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to GLED
set_location_assignment PIN_AK20  -to BLED
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to BLED

# Arduino MKR
#set_location_assignment PIN_AF22  -to AREF
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to AREF
#set_location_assignment PIN_AF23  -to AIN0
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to AIN0
#set_location_assignment PIN_AF23  -to AIN[0]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to AIN[0]
#set_location_assignment PIN_AF24  -to AIN[1]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to AIN[1]
#set_location_assignment PIN_AG26  -to AIN[2]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to AIN[2]
#set_location_assignment PIN_AH28  -to AIN[3]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to AIN[3]
#set_location_assignment PIN_AH27  -to AIN[4]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to AIN[4]
#set_location_assignment PIN_AF27  -to AIN[5]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to AIN[5]
#set_location_assignment PIN_AF26  -to AIN[6]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to AIN[6]
#set_location_assignment PIN_AE25  -to D[0]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[0]
#set_location_assignment PIN_AF21  -to D[1]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[1]
#set_location_assignment PIN_AH20  -to D[2]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[2]
#set_location_assignment PIN_AG19  -to D[3]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[3]
#set_location_assignment PIN_AF19  -to D[4]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[4]
#set_location_assignment PIN_AG20  -to D[5]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[5]
#set_location_assignment PIN_AK19  -to D[6]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[6]
#set_location_assignment PIN_AJ19  -to D[7]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[7]
#set_location_assignment PIN_AH21  -to D[8]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[8]
#set_location_assignment PIN_AH18  -to D[9]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[9]
#set_location_assignment PIN_AJ20  -to D[10]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[10]
#set_location_assignment PIN_AJ22  -to D[11]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[11]
#set_location_assignment PIN_AK22  -to D[12]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[12]
#set_location_assignment PIN_AH23  -to D[13]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[13]
#set_location_assignment PIN_AJ23  -to D[14]
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D[14]
#set_location_assignment PIN_AK25  -to D11_R
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D11_R
#set_location_assignment PIN_AK27  -to D12_R
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to D12_R

# Accelerometer
#set_location_assignment PIN_AK24  -to INT1
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to INT1
#set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to INT1
#set_location_assignment PIN_AJ25  -to INT2
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to INT2
#set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to INT2
#set_location_assignment PIN_AH25  -to I2C_SCL
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to I2C_SCL
#set_location_assignment PIN_AK26  -to I2C_SDA
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to I2C_SDA

# CRUVI-HS HVIO pins
set_location_assignment PIN_AH26  -to CAMERA_EN
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to CAMERA_EN
set_location_assignment PIN_AJ29  -to SMB_SDA
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to SMB_SDA
set_location_assignment PIN_AJ27  -to SMB_SCL
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to SMB_SCL
#set_location_assignment PIN_AJ28  -to C_REFCLK
#set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to C_REFCLK


set_location_assignment PIN_U4  -to MIPI_D1P
set_location_assignment PIN_U3  -to MIPI_D1N
set_instance_assignment -name IO_STANDARD "DPHY" -to MIPI_D1P
set_instance_assignment -name IO_STANDARD "DPHY" -to MIPI_D1N

set_location_assignment PIN_V3  -to MIPI_D0P
set_location_assignment PIN_W3  -to MIPI_D0N
set_instance_assignment -name IO_STANDARD "DPHY" -to MIPI_D0P
set_instance_assignment -name IO_STANDARD "DPHY" -to MIPI_D0N

set_location_assignment PIN_U5  -to MIPI_CLKP
set_location_assignment PIN_T4  -to MIPI_CLKN
set_instance_assignment -name IO_STANDARD "DPHY" -to MIPI_CLKP
set_instance_assignment -name IO_STANDARD "DPHY" -to MIPI_CLKN

set_location_assignment PIN_AD3  -to MIPI_RZQ
set_instance_assignment -name IO_STANDARD "1.2-V" -to MIPI_RZQ
set_location_assignment PIN_AD5  -to MIPI_REFCLK
set_instance_assignment -name IO_STANDARD "1.2-V" -to MIPI_REFCLK

set_location_assignment PIN_V1  -to DSI_D1P
set_location_assignment PIN_V2  -to DSI_D1N
set_instance_assignment -name IO_STANDARD "DPHY" -to DSI_D1P
set_instance_assignment -name IO_STANDARD "DPHY" -to DSI_D1N

set_location_assignment PIN_Y1  -to DSI_D0P
set_location_assignment PIN_W2  -to DSI_D0N
set_instance_assignment -name IO_STANDARD "DPHY" -to DSI_D0P
set_instance_assignment -name IO_STANDARD "DPHY" -to DSI_D0N

set_location_assignment PIN_T2  -to DSI_CLKP
set_location_assignment PIN_U1  -to DSI_CLKN
set_instance_assignment -name IO_STANDARD "DPHY" -to DSI_CLKP
set_instance_assignment -name IO_STANDARD "DPHY" -to DSI_CLKN






