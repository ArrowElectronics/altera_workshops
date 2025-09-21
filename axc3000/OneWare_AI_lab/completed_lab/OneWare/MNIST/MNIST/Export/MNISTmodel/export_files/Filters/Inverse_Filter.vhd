
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
use work.CNN_Config_Package.all;

ENTITY Inverse_Filter IS
    GENERIC (
        Input_Values   : NATURAL := 1;  --Number of Filters in previous layer or 3 for RGB input
        Input_Images   : NATURAL := 1;  --Number of input images (2 images and RGB: (2 downto 0) for image 1 and (5 downto 3) for image 2)
        En_In_Buffer   : BOOLEAN := TRUE; --Enable input buffer
        En_Out_Buffer  : BOOLEAN := TRUE; --Enable output buffer
        Max_Value      : CNN_Value_T := 2**(CNN_Value_Resolution-1)-1 -- Calculates: Max - Value as inverse operation
    );
    PORT (
        iStream : IN  CNN_Stream_T;
        iData   : IN  CNN_Values_T((Input_Values*Input_Images)-1 downto 0);
        
        oStream : OUT CNN_Stream_T;
        oData   : OUT CNN_Values_T((Input_Values*Input_Images)-1 downto 0) := (others => 0)
    );
END Inverse_Filter;

ARCHITECTURE BEHAVIORAL OF Inverse_Filter IS

attribute ramstyle : string;
    
    --Input data register
    SIGNAL iStream_Reg : CNN_Stream_T;
    SIGNAL iData_Reg   : CNN_Values_T((Input_Values*Input_Images)-1 downto 0);
    
    --Output data register
    SIGNAL oStream_Reg : CNN_Stream_T;
    SIGNAL oData_Reg   : CNN_Values_T((Input_Values*Input_Images)-1 downto 0);
    
BEGIN
    
    oStream.Data_CLK <= iStream.Data_CLK;
    
    PROCESS (iStream)
        VARIABLE sel_stream : CNN_Stream_T;
        VARIABLE sel_data   : CNN_Values_T((Input_Values*Input_Images)-1 downto 0);
    BEGIN
        IF (rising_edge(iStream.Data_CLK)) THEN
            IF En_In_Buffer THEN
                -- Select input stream for processing
                sel_stream.Column     := iStream_Reg.Column;
                sel_stream.Row        := iStream_Reg.Row;
                sel_stream.Filter     := iStream_Reg.Filter;
                sel_stream.Data_Valid := iStream_Reg.Data_Valid;
                sel_data              := iData_Reg;
                -- Store input stream and data in registers
                iStream_Reg.Column     <= iStream.Column;
                iStream_Reg.Row        <= iStream.Row;
                iStream_Reg.Filter     <= iStream.Filter;
                iStream_Reg.Data_Valid <= iStream.Data_Valid;
                iData_Reg              <= iData;
            ELSE
                sel_stream.Column     := iStream.Column;
                sel_stream.Row        := iStream.Row;
                sel_stream.Filter     := iStream.Filter;
                sel_stream.Data_Valid := iStream.Data_Valid;
                sel_data              := iData;
            END IF;

            -- Process the input data
            For i in 0 to (Input_Values*Input_Images)-1 loop
                sel_data(i) := Max_Value - sel_data(i); -- Inverse operation (1.0 - value)
            end loop;

            IF En_Out_Buffer THEN
                -- Output the processed stream and data
                oStream.Column         <= oStream_Reg.Column;
                oStream.Row            <= oStream_Reg.Row;
                oStream.Filter         <= oStream_Reg.Filter;
                oStream.Data_Valid     <= oStream_Reg.Data_Valid;
                oData                  <= oData_Reg;

                -- Store processed output stream and data in registers
                oStream_Reg.Column     <= sel_stream.Column;
                oStream_Reg.Row        <= sel_stream.Row;
                oStream_Reg.Filter     <= sel_stream.Filter;
                oStream_Reg.Data_Valid <= sel_stream.Data_Valid;
                oData_Reg              <= sel_data;
            ELSE
                oStream.Column     <= sel_stream.Column;
                oStream.Row        <= sel_stream.Row;
                oStream.Filter     <= sel_stream.Filter;
                oStream.Data_Valid <= sel_stream.Data_Valid;
                oData              <= sel_data;
            END IF;
        END IF;
    END PROCESS;
    
END BEHAVIORAL;