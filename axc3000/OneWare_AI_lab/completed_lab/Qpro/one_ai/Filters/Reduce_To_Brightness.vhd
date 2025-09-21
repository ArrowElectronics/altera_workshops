
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
use work.CNN_Config_Package.all;
use IEEE.math_real.all;

ENTITY Reduce_To_Brightness IS
    GENERIC (
        Input_Values   : NATURAL := 3;    --Number of Filters in previous layer or 3 for RGB input
        Input_Images   : NATURAL := 1;    --Number of input images (2 images and RGB: (2 downto 0) for image 1 and (5 downto 3) for image 2)
        En_In_Buffer   : BOOLEAN := TRUE; --Enable input buffer
        En_Out_Buffer  : BOOLEAN := TRUE; --Enable output buffer
        Calc_Type      : NATURAL := 0;    -- 0: Max, 1: Average, 2: Weighted Average, 3: Verry Efficient Average, 4: Efficient Weighted Average
        Factor_Res     : NATURAL := 4 -- Bit resolution for weight factors
    );
    PORT (
        iStream : IN  CNN_Stream_T;
        iData   : IN  CNN_Values_T((Input_Values*Input_Images)-1 downto 0);
        
        oStream : OUT CNN_Stream_T;
        oData   : OUT CNN_Values_T((Input_Values*Input_Images)-1 downto 0) := (others => 0)
    );
END Reduce_To_Brightness;

ARCHITECTURE BEHAVIORAL OF Reduce_To_Brightness IS

attribute ramstyle : string;
    
    --Input data register
    SIGNAL iStream_Reg : CNN_Stream_T;
    SIGNAL iData_Reg   : CNN_Values_T((Input_Values*Input_Images)-1 downto 0);
    
    --Output data register
    SIGNAL oStream_Reg : CNN_Stream_T;
    SIGNAL oData_Reg   : CNN_Values_T(Input_Images-1 downto 0);

    type real_arr is array (natural range <>) of real range 0.0 to 1.0;
    type int_arr is array (natural range <>) of integer range 0 to 4;

    CONSTANT Weight_Factors : real_arr(Input_Values-1 downto 0) := (
        0 => 38.0/127.0, -- Factor for R value 0,30
        1 => 75.0/127.0, -- Factor for G value 0,59
        2 => 14.0/127.0  -- Factor for B value 0,11
    );

    CONSTANT Shift_Factors : int_arr(Input_Values-1 downto 0) := (
        0 => 2, -- Factor for R value 0,25
        1 => 1, -- Factor for G value 0,5
        2 => 2  -- Factor for B value 0,25
    );

    CONSTANT Cooler_Shift_Factors : int_arr(Input_Values downto 0) := (
        0 => 2, -- Factor for R value 0,25
        1 => 1, -- Factor for G value 0,625 (together with second factor: 0,5+0,125)
        2 => 3,  -- Factor for B value 0,125
        3 => 3 -- Second Factor for G value
    );

    type val_arr is array (0 to Input_Images-1) of NATURAL range 0 to (2**(CNN_Value_Resolution-1)-1)*Input_Values;
    
BEGIN
    
    oStream.Data_CLK <= iStream.Data_CLK;
    
    PROCESS (iStream)
        VARIABLE sel_stream : CNN_Stream_T;
        VARIABLE sel_data   : CNN_Values_T((Input_Values*Input_Images)-1 downto 0);
        VARIABLE sel_o_data : val_arr;
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
            For i in 0 to Input_Images-1 loop
                sel_o_data(i) := 0; -- Initialize output data for each image
                For c in 0 to Input_Values-1 loop
                    IF Calc_Type = 0 THEN
                        IF sel_data(c + i*Input_Values) > sel_o_data(i) THEN
                            sel_o_data(i) := sel_data(c + i*Input_Values); -- Max operation
                        END IF;
                    ELSIF Calc_Type = 1 THEN
                        sel_o_data(i) := sel_o_data(i) + sel_data(c + i*Input_Values); -- Average operation
                    ELSIF Calc_Type = 2 THEN
                        sel_o_data(i) := sel_o_data(i) + unsigned_multiply_efficient(sel_data(c + i*Input_Values),Weight_Factors(c)); -- Weighted Average operation
                    ELSIF Calc_Type = 3 THEN
                        sel_o_data(i) := sel_o_data(i) + to_integer(shift_right(to_unsigned(sel_data(c + i*Input_Values),integer(CNN_Value_Resolution)),Shift_Factors(c))); -- Cooler Weighted Average operation
                    ELSIF Calc_Type = 4 THEN
                        sel_o_data(i) := sel_o_data(i) + to_integer(shift_right(to_unsigned(sel_data(c + i*Input_Values),integer(CNN_Value_Resolution)),Cooler_Shift_Factors(c))); -- Even Cooler Weighted Average operation
                        if c = 1 then
                            sel_o_data(i) := sel_o_data(i) + to_integer(shift_right(to_unsigned(sel_data(c + i*Input_Values),integer(CNN_Value_Resolution)),Cooler_Shift_Factors(c+2))); -- Even Cooler Weighted Average spezial case for green
                        end if;
                    END IF;
                end loop;
                
                IF Calc_Type = 1 THEN
                    sel_o_data(i) := unsigned_multiply_efficient(sel_o_data(i), 1.0/real(Input_Values),CNN_Value_Resolution+integer(ceil(log2(real(Input_Values))))-1,CNN_Value_Resolution-1); -- Finalize average operation
                END IF;
            end loop;

            IF En_Out_Buffer THEN
                -- Output the processed stream and data
                oStream.Column         <= oStream_Reg.Column;
                oStream.Row            <= oStream_Reg.Row;
                oStream.Filter         <= oStream_Reg.Filter;
                oStream.Data_Valid     <= oStream_Reg.Data_Valid;
                For i in 0 to Input_Images-1 loop
                    For c in 0 to Input_Values-1 loop
                        oData(c + i*Input_Values) <= oData_Reg(i);
                    end loop;
                end loop;
                

                -- Store processed output stream and data in registers
                oStream_Reg.Column     <= sel_stream.Column;
                oStream_Reg.Row        <= sel_stream.Row;
                oStream_Reg.Filter     <= sel_stream.Filter;
                oStream_Reg.Data_Valid <= sel_stream.Data_Valid;
                For i in 0 to Input_Images-1 loop
                    oData_Reg(i) <= sel_o_data(i);
                end loop;
            ELSE
                oStream.Column     <= sel_stream.Column;
                oStream.Row        <= sel_stream.Row;
                oStream.Filter     <= sel_stream.Filter;
                oStream.Data_Valid <= sel_stream.Data_Valid;
                For i in 0 to Input_Images-1 loop
                    For c in 0 to Input_Values-1 loop
                        oData(c + i*Input_Values) <= sel_o_data(i);
                    end loop;
                end loop;
            END IF;
        END IF;
    END PROCESS;
    
END BEHAVIORAL;