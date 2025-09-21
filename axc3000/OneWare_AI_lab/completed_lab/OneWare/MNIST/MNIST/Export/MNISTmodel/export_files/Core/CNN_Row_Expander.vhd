
--Description: -This component buffers a row and creates an oStream that has more space between the new data
--             -The Convolution layer can then take more time to calculate the output
--             -Input:  -_-_-_-_________
--             -Output: -___-___-___-___

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
use work.CNN_Config_Package.all;

ENTITY CNN_Row_Expander IS
    GENERIC (
        Input_Columns  : NATURAL := 28; --Size in x direction of input
        Input_Rows     : NATURAL := 28; --Size in y direction of input
        Input_Values   : NATURAL := 1;  --Number of Filters in previous layer or 3 for RGB input
        Input_Cycles   : NATURAL := 1;  --Filter Cycles of previous convolution
        Output_Cycles  : NATURAL := 2   --2 = new data for every second clock edge
    );
    PORT (
        iStream : IN  CNN_Stream_T;
        iData   : IN  CNN_Values_T(Input_Values/Input_Cycles-1 downto 0);
        
        oStream : OUT CNN_Stream_T;
        oData   : OUT CNN_Values_T(Input_Values/Input_Cycles-1 downto 0)
    );
END CNN_Row_Expander;

ARCHITECTURE BEHAVIORAL OF CNN_Row_Expander IS

attribute ramstyle : string;

    --RAM to buffer last row
    type RAM_T is array (0 to Input_Columns*Input_Cycles-1) of STD_LOGIC_VECTOR((CNN_Value_Resolution+CNN_Value_Negative-1)*(Input_Values/Input_Cycles)-1 downto 0);
    SIGNAL Buffer_RAM    : RAM_T;
    SIGNAL RAM_Addr_In   : NATURAL range 0 to Input_Columns*Input_Cycles-1;
    SIGNAL RAM_Addr_Out  : NATURAL range 0 to Input_Columns*Input_Cycles-1;
    SIGNAL RAM_Data_In   : STD_LOGIC_VECTOR((CNN_Value_Resolution+CNN_Value_Negative-1)*(Input_Values/Input_Cycles)-1 downto 0);
    SIGNAL RAM_Data_Out  : STD_LOGIC_VECTOR((CNN_Value_Resolution+CNN_Value_Negative-1)*(Input_Values/Input_Cycles)-1 downto 0);
    
    SIGNAL Delay_Cnt     : NATURAL range 0 to Output_Cycles-1 := 0;
    SIGNAL Reset_Col     : STD_LOGIC := '0';
    SIGNAL oStream_Reg   : CNN_Stream_T;
	 
	--attribute ramstyle of BEHAVIORAL : architecture is "MLAB, no_rw_check";
    
BEGIN
    oStream.Data_CLK <= iStream.Data_CLK;
    
    PROCESS (iStream)
    BEGIN
        IF (rising_edge(iStream.Data_CLK)) THEN
            Buffer_RAM(RAM_Addr_In) <= RAM_Data_In;
        END IF;
    END PROCESS;
    
    RAM_Data_Out <= Buffer_RAM(RAM_Addr_Out);
    
    PROCESS (iStream)
    VARIABLE iData_Reg  : CNN_Values_T(Input_Values/Input_Cycles-1 downto 0); --Input data that is saved if the data is valid
    VARIABLE Valid_Reg  : STD_LOGIC := '0';
    VARIABLE Column_Cnt : NATURAL range 0 to Input_Columns-1;
    VARIABLE Filter_Cnt : NATURAL range 0 to Input_Values-1;
    BEGIN
        IF (rising_edge(iStream.Data_CLK)) THEN
            --Save data if data is valid
            IF (iStream.Data_Valid = '1') THEN
                iData_Reg := iData;
            END IF;
            
            --Save data in RAM as bit vector
            FOR i in 0 to Input_Values/Input_Cycles-1 LOOP
                IF (CNN_Value_Negative = 0) THEN
                    RAM_Data_In((CNN_Value_Resolution-1)*(i+1)-1 downto (CNN_Value_Resolution-1)*i) <= STD_LOGIC_VECTOR(TO_UNSIGNED(iData_Reg(i), (CNN_Value_Resolution-1)));
                ELSE
                    RAM_Data_In((CNN_Value_Resolution)*(i+1)-1 downto (CNN_Value_Resolution)*i) <= STD_LOGIC_VECTOR(TO_SIGNED(iData_Reg(i), CNN_Value_Resolution));
                END IF;
            END LOOP;
            
            --Calculate RAM address for new data input
            RAM_Addr_In <= iStream.Column*Input_Cycles+iStream.Filter;
            
            Reset_Col <= '0';
            
            --Calculate delay between output data
            IF (iStream.Data_Valid = '1' AND Valid_Reg = '0' and iStream.Column = 0) THEN
                --Reset counter if new data is available and a new row starts
                Delay_Cnt <= 0;
                Reset_Col <= '1';
            ELSIF (Delay_Cnt < Output_Cycles-1) THEN
                --Count delay between outputs
                Delay_Cnt <= Delay_Cnt + 1;
            ELSIF (iStream.Column > Column_Cnt) THEN
                --Reset counter if delay counter is finished and new input data is available
                Delay_Cnt <= 0;
            END IF;
            
            Valid_Reg := iStream.Data_Valid;
            
            --Set valiables to output data
            IF (Reset_Col = '1') THEN
                --Reset data two cycles after the input data was received
                Column_Cnt             := 0;
                Filter_Cnt             := 0;
                oStream_Reg.Row        <= iStream.Row;
                oStream_Reg.Data_Valid <= '1';
            ELSIF (Delay_Cnt = 0 AND Column_Cnt < Input_Columns-1) THEN
                --Count the output column when the delay counter is set back to 0
                Column_Cnt             := Column_Cnt + 1;
                Filter_Cnt             := 0;
                oStream_Reg.Data_Valid <= '1';
            ELSIF (Filter_Cnt < (Input_Cycles-1)) THEN
                --Count the filter output for the input filter cycles
                Filter_Cnt             := Filter_Cnt + 1;
            ELSE
                oStream_Reg.Data_Valid <= '0';
            END IF;
            
            oStream_Reg.Column <= Column_Cnt;
            oStream_Reg.Filter <= Filter_Cnt;
            
            --Set address to read data from RAM
            RAM_Addr_Out       <= Column_Cnt*Input_Cycles+Filter_Cnt;
            
            --Set output column, row and filter after data is read from RAM
            oStream.Column     <= oStream_Reg.Column;
            oStream.Row        <= oStream_Reg.Row;
            oStream.Filter     <= oStream_Reg.Filter;
            oStream.Data_Valid <= oStream_Reg.Data_Valid;
            
            --Set output data with values from RAM
            FOR i in 0 to Input_Values/Input_Cycles-1 LOOP
                IF (CNN_Value_Negative = 0) THEN
                    oData(i) <= TO_INTEGER(UNSIGNED(RAM_Data_Out((CNN_Value_Resolution-1)*(i+1)-1 downto (CNN_Value_Resolution-1)*i)));
                ELSE
                    oData(i) <= TO_INTEGER(SIGNED(RAM_Data_Out((CNN_Value_Resolution)*(i+1)-1 downto (CNN_Value_Resolution)*i)));
                END IF;
            END LOOP;
        END IF;
    END PROCESS;
    
END BEHAVIORAL;