
--Description: -This component applies normalization to the input data
--Insertion:   -Specify the paramters with the constants in th CNN_Data file
--             -Connect the input data and stream signal with the input or previous layer

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
use IEEE.MATH_REAL.all;
use work.CNN_Config_Package.all;


ENTITY CNN_Normalization IS
    GENERIC (
        Input_Values   : NATURAL := 8;  --Number of Filters in previous layer or 3 for RGB input
        G_Offset       : INTEGER := 0;  --Offset of decimal point of Gamma
        B_Offset       : INTEGER := 0;  --Offset of decimal point of Beta
        M_Offset       : INTEGER := 0;  --Offset of decimal point of Mean
        S_Offset       : INTEGER := 0;  --Offset of decimal point of Std
        Input_Cycles   : NATURAL := 1;  --Filter Cycles of previous convolution
        Parameters     : CNN_Parameters_T --Gamma, Beta, Mean, Std
    );
    PORT (
        iStream : IN  CNN_Stream_T;
        iData   : IN  CNN_Values_T(Input_Values/Input_Cycles-1 downto 0);
        oStream : OUT CNN_Stream_T;
        oData   : OUT CNN_Values_T(Input_Values/Input_Cycles-1 downto 0) := (others => 0)
    );
END CNN_Normalization;

ARCHITECTURE BEHAVIORAL OF CNN_Normalization IS

    type buf1_t is array (natural range <>) of SIGNED(CNN_Value_Resolution downto 0);
    type buf2_t is array (natural range <>) of SIGNED(CNN_Value_Resolution+G_Offset-1 downto 0);
    type buf3_t is array (natural range <>) of SIGNED(CNN_Value_Resolution+G_Offset+S_Offset-1 downto 0);
    SIGNAL buf1  : buf1_t(Input_Values/Input_Cycles-1 downto 0) := (others => (others => '0'));
    SIGNAL buf2  : buf2_t(Input_Values/Input_Cycles-1 downto 0) := (others => (others => '0'));
    SIGNAL buf3  : buf3_t(Input_Values/Input_Cycles-1 downto 0) := (others => (others => '0'));
    
    type Stream_t is array (2 downto 0) of CNN_Stream_t;
    SIGNAL Stream_Reg : Stream_t;
    
BEGIN

    oStream.Data_CLK <= iStream.Data_CLK;
    
    PROCESS (iStream)
    --gamma * (input - moving_mean) / sqrt(moving_var+epsilon) + beta
    VARIABLE gamma : CNN_Parameter_T := 0;
    VARIABLE beta  : CNN_Parameter_T := 0;
    VARIABLE mean  : CNN_Parameter_T := 0;
    VARIABLE var   : CNN_Parameter_T := 0;
    VARIABLE buf : SIGNED(CNN_Value_Resolution+G_Offset+S_Offset-1 downto 0) := (others => '0');
    BEGIN
        IF (rising_edge(iStream.Data_CLK)) THEN
            FOR input in 0 to Input_Values/Input_Cycles-1 LOOP
                --Load values from paramters
                gamma := Parameters(0, input+Stream_Reg(0).Filter);
                beta  := Parameters(1, input+Stream_Reg(2).Filter);
                mean  := Parameters(2, input+iStream.Filter);
                var   := Parameters(3, input+Stream_Reg(1).Filter);
                
                --buf1 = input - moving_mean
                IF (M_Offset >= 0) THEN
                    buf1(input) <= to_signed(iData(input), CNN_Value_Resolution+1) - resize(shift_left(to_signed(mean, CNN_Parameter_Resolution+M_Offset), M_Offset), CNN_Value_Resolution+1);
                ELSE
                    buf1(input) <= to_signed(iData(input), CNN_Value_Resolution+1) - resize(shift_right(to_signed(mean, CNN_Parameter_Resolution), abs(M_Offset)), CNN_Value_Resolution+1);
                END IF;
                
                --buf2 = gamma * buf1
                buf2(input) <= resize(shift_right(to_signed(gamma, CNN_Parameter_Resolution+CNN_Value_Resolution+1) * resize(buf1(input), CNN_Parameter_Resolution+CNN_Value_Resolution+1), CNN_Parameter_Resolution-G_Offset-1), CNN_Value_Resolution+G_Offset);
                
                --buf3 = buf2 * (1/sqrt(moving_var+epsilon))
                buf3(input) <= resize(shift_right(to_signed(var, CNN_Parameter_Resolution+CNN_Value_Resolution+G_Offset) * resize(buf2(input), CNN_Parameter_Resolution+CNN_Value_Resolution+G_Offset), CNN_Parameter_Resolution-S_Offset-1), CNN_Value_Resolution+G_Offset+S_Offset);
                
                --buf4 = buf3 + beta
                IF (B_Offset >= 0) THEN
                    buf := buf3(input) + resize(shift_left (to_signed(beta, CNN_Parameter_Resolution+B_Offset), B_Offset), CNN_Value_Resolution+G_Offset+S_Offset);
                ELSE
                    buf := buf3(input) + resize(shift_right(to_signed(beta, CNN_Parameter_Resolution), abs(B_Offset)), CNN_Value_Resolution+G_Offset+S_Offset);
                END IF;
                
                --limit result
                IF (buf >= 2**(CNN_Value_Resolution-1)) THEN
                    oData(input) <= 2**(CNN_Value_Resolution-1)-1;
                ELSIF (buf <= (-1)*(2**(CNN_Value_Resolution-1))) THEN
                    oData(input) <= (-1)*(2**(CNN_Value_Resolution-1))+1;
                ELSE
                    oData(input) <= to_integer(buf);
                END IF;
            END LOOP;
            
            --Delay output for all calulcation cycles
            oStream.Column     <= Stream_Reg(2).Column;
            oStream.Row        <= Stream_Reg(2).Row;
            oStream.Filter     <= Stream_Reg(2).Filter;
            oStream.Data_Valid <= Stream_Reg(2).Data_Valid;
            Stream_Reg <= Stream_Reg(1 downto 0) & iStream;
        END IF;
    END PROCESS;
    
END BEHAVIORAL;