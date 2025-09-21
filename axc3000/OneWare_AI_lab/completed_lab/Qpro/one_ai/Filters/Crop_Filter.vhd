
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
use work.CNN_Config_Package.all;

ENTITY Crop_Filter IS
    GENERIC (
        Input_Values   : NATURAL := 1;  --Number of Filters in previous layer or 3 for RGB input
        Input_Images   : NATURAL := 1;  --Number of input images (2 images and RGB: (2 downto 0) for image 1 and (5 downto 3) for image 2)
        En_In_Buffer   : BOOLEAN := TRUE; --Enable input buffer
        En_Out_Buffer  : BOOLEAN := TRUE; --Enable output buffer
        Start_Row      : NATURAL := 0; -- Start row for processing
        End_Row        : NATURAL := 480; -- End row for processing
        Start_Column   : NATURAL := 0; -- Start column for processing
        End_Column     : NATURAL := 640 -- End column for processing
    );
    PORT (
        iStream : IN  CNN_Stream_T;
        iData   : IN  CNN_Values_T((Input_Values*Input_Images)-1 downto 0);
        
        oStream : OUT CNN_Stream_T;
        oData   : OUT CNN_Values_T((Input_Values*Input_Images)-1 downto 0) := (others => 0)
    );
END Crop_Filter;

ARCHITECTURE BEHAVIORAL OF Crop_Filter IS

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

            IF (sel_stream.Row >= Start_Row AND sel_stream.Row < End_Row AND
               sel_stream.Column >= Start_Column AND sel_stream.Column < End_Column) THEN
                sel_stream.Column := sel_stream.Column - Start_Column;
                sel_stream.Row    := sel_stream.Row - Start_Row;
            else
                sel_stream.Data_Valid := '0'; -- Mark as invalid if outside processing area
            END IF;

            IF En_Out_Buffer THEN
                -- Output the processed stream and data
                oStream.Column         <= oStream_Reg.Column;
                oStream.Row            <= oStream_Reg.Row;
                oStream.Filter         <= oStream_Reg.Filter;
                oStream.Data_Valid     <= oStream_Reg.Data_Valid;
                oData                  <= oData_Reg;

                -- Store processed output stream and data in registers
                if sel_stream.Data_Valid = '1' then
                    oStream_Reg.Column     <= sel_stream.Column;
                    oStream_Reg.Row        <= sel_stream.Row;
                end if;
                oStream_Reg.Filter     <= sel_stream.Filter;
                oStream_Reg.Data_Valid <= sel_stream.Data_Valid;
                oData_Reg              <= sel_data;
            ELSE
                if sel_stream.Data_Valid = '1' then
                    oStream_Reg.Column     <= sel_stream.Column;
                    oStream_Reg.Row        <= sel_stream.Row;
                end if;
                oStream.Filter     <= sel_stream.Filter;
                oStream.Data_Valid <= sel_stream.Data_Valid;
                oData              <= sel_data;
            END IF;
        END IF;
    END PROCESS;
    
END BEHAVIORAL;