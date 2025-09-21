
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
use work.CNN_Config_Package.all;

ENTITY CNN_Pooling_Efficient IS
    GENERIC (
        Input_Columns  : NATURAL := 28; --Size in x direction of input
        Input_Rows     : NATURAL := 28; --Size in y direction of input
        Input_Values   : NATURAL := 1;  --Number of Filters in previous layer or 3 for RGB input
        Filter_Columns : NATURAL := 3;  --Size in x direction of filters
        Filter_Rows    : NATURAL := 3;  --Size in y direction of filters
        Input_Cycles   : NATURAL := 1;  --Filter Cycles of previous convolution
        Filter_Delay   : NATURAL := 1   --Cycles between Filters
        --Strides = Filter size
        --Padding = valid
    );
    PORT (
        iStream : IN  CNN_Stream_T;
        iData   : IN  CNN_Values_T(Input_Values/Input_Cycles-1 downto 0);
        
        oStream : OUT CNN_Stream_T;
        oData   : OUT CNN_Values_T(Input_Values/Input_Cycles-1 downto 0) := (others => 0)
    );
END CNN_Pooling_Efficient;

ARCHITECTURE BEHAVIORAL OF CNN_Pooling_Efficient IS

attribute ramstyle : string;
    
    CONSTANT Calc_Steps   : NATURAL := Input_Values/Input_Cycles;    --Values to calculate at once for each pixel in pooling matrix

    --RAM for max values of current pooling matrix
    CONSTANT RAM_Bits  : NATURAL := (CNN_Value_Resolution+CNN_Value_Negative-1)*Calc_Steps;
    CONSTANT RAM_Width : NATURAL := (Input_Columns/Filter_Columns)*Input_Cycles;
    type RAM_T is array (RAM_Width-1 downto 0) of STD_LOGIC_VECTOR(RAM_Bits-1 downto 0);
    SIGNAL Buffer_RAM : RAM_T := (others => (others => '0'));
    SIGNAL RAM_Addr_Out : natural range 0 to RAM_Width - 1;
    SIGNAL RAM_Addr_In  : natural range 0 to RAM_Width - 1;
    SIGNAL RAM_Data_In  : std_logic_vector(RAM_Bits - 1 downto 0);
    SIGNAL RAM_Data_Out : std_logic_vector(RAM_Bits - 1 downto 0);
    SIGNAL RAM_Enable   : STD_LOGIC := '1';
    
    --Input data register
    SIGNAL iStream_Reg : CNN_Stream_T;
    SIGNAL iData_Reg   : CNN_Values_T(Calc_Steps-1 downto 0);
    
     --RAM for output values
    CONSTANT OUT_RAM_Elements : NATURAL := Input_Cycles;
    type OUT_set_t is array (0 to Input_Values/OUT_RAM_Elements-1) of SIGNED(CNN_Value_Resolution-1 downto 0);
    type OUT_ram_t is array (natural range <>) of OUT_set_t;
    SIGNAL OUT_RAM      : OUT_ram_t(0 to OUT_RAM_Elements-1);
    SIGNAL OUT_Rd_Addr  : NATURAL range 0 to OUT_RAM_Elements-1;
    SIGNAL OUT_Rd_Data  : OUT_set_t;
    SIGNAL OUT_Wr_Addr  : NATURAL range 0 to OUT_RAM_Elements-1;
    SIGNAL OUT_Wr_Data  : OUT_set_t;
    SIGNAL OUT_Wr_Ena   : STD_LOGIC := '1';

    --Signals to output data with delay
    SIGNAL Out_Value_Cnt_Reg  : NATURAL range 0 to Input_Cycles-1;
    SIGNAL Out_Delay_Cnt      : NATURAL range 0 to Filter_Delay-1 := Filter_Delay-1;
	 
--attribute ramstyle of BEHAVIORAL : architecture is "MLAB, no_rw_check";
    
BEGIN
    
    oStream.Data_CLK <= iStream.Data_CLK;
    
    --RAM for maximum in pooling matrix for different input values
    
    PROCESS (iStream)
    BEGIN
        IF (rising_edge(iStream.Data_CLK)) THEN
            IF (RAM_Enable = '1') THEN
                Buffer_RAM(RAM_Addr_In) <= RAM_Data_In;
            END IF;
        END IF;
    END PROCESS;
    
    RAM_Data_Out <= Buffer_RAM(RAM_Addr_Out);
    
    --Output RAM to save values after pooling and send them one by one to next layer
    
    PROCESS (iStream)
    BEGIN
        IF (rising_edge(iStream.Data_CLK)) THEN
            IF (OUT_Wr_Ena = '1') THEN
                OUT_RAM(OUT_Wr_Addr) <= OUT_Wr_Data;
            END IF;
        END IF;
    END PROCESS;
    
    OUT_Rd_Data <= OUT_RAM(OUT_Rd_Addr);
    
    PROCESS (iStream)
    VARIABLE RAM_MAX : CNN_Values_T(Calc_Steps-1 downto 0); --Maximum value from RAM
    --Counter for current position in pooling matrix
    VARIABLE Filter_Column_Cnt : NATURAL range 0 to Filter_Columns-1 := Filter_Columns-1;
    VARIABLE Filter_Row_Cnt    : NATURAL range 0 to Filter_Rows-1    := Filter_Rows-1;
    
    VARIABLE last_input    : STD_LOGIC;      --True if pooling is done and
    
    --Variables to output values from output RAM  
    VARIABLE Out_Value_Cnt : NATURAL range 0 to Input_Cycles-1;
    VARIABLE OUT_Wr_Calc   : NATURAL range 0 to OUT_RAM_Elements-1;
    BEGIN
        IF (rising_edge(iStream.Data_CLK)) THEN
            --Save data in buffer if the data is needed for the pooling and read last maximum value from RAM
            if iStream.Data_Valid = '1' AND iStream.Column < (Input_Columns/Filter_Columns)*Filter_Columns then
                iData_Reg              <= iData;
                iStream_Reg.Column     <= iStream.Column;
                iStream_Reg.Row        <= iStream.Row;
                iStream_Reg.Filter     <= iStream.Filter;
                iStream_Reg.Data_Valid <= '1';
                
                RAM_Addr_Out           <= (iStream.Column/Filter_Columns)*Input_Cycles+iStream.Filter;
            else
                iStream_Reg.Data_Valid <= '0';
            end if;
            
            oStream.Data_Valid <= '0';
            last_input         := '0';
            
            IF (iStream_Reg.Data_Valid = '1') THEN
                
                --Read data from RAM
                for i in 0 to Calc_Steps-1 loop
                    if CNN_Value_Negative = 0 then
                        RAM_MAX(i) := TO_INTEGER(UNSIGNED(RAM_Data_Out(((CNN_Value_Resolution-1)*(i+1))-1 downto (CNN_Value_Resolution-1)*i)));
                    else
                        RAM_MAX(i) := TO_INTEGER(SIGNED(RAM_Data_Out(((CNN_Value_Resolution)*(i+1))-1 downto (CNN_Value_Resolution)*i)));
                    end if;
                end loop;
                
                --Calculate current position in pooling matrix
                Filter_Column_Cnt := iStream_Reg.Column mod Filter_Columns;
                Filter_Row_Cnt    := iStream_Reg.Row mod Filter_Rows;
                
                --Set maximum to current value if this is the first value or if the value is bigger than the last ones
                IF (Filter_Column_Cnt = 0 AND Filter_Row_Cnt = 0) THEN
                    for i in 0 to Calc_Steps-1 loop
                        RAM_MAX(i) := iData_Reg(i);
                    end loop;
                ELSE
                    for i in 0 to Calc_Steps-1 loop
                        IF (iData_Reg(i) > RAM_MAX(i)) THEN
                            RAM_MAX(i) := iData_Reg(i);
                        END IF;
                    end loop;
                END IF;
                
                --Output data if this is the last position in the matrix or save maximum value in RAM
                if Filter_Column_Cnt = Filter_Columns-1 AND Filter_Row_Cnt = Filter_Rows-1 then
                    oStream.Column     <= iStream_Reg.Column/Filter_Columns;
                    oStream.Row        <= iStream_Reg.Row/Filter_Rows;
                    
                    --Save data in output RAM if there should be a delay between the output values
                    if Filter_Delay = 1 then
                        oStream.Filter     <= iStream_Reg.Filter;
                        oStream.Data_Valid <= '1';
                        oData              <= RAM_MAX;
                    else
                        OUT_Wr_Calc := RAM_Addr_Out mod Input_Cycles;
                        
                        if OUT_Wr_Calc = Input_Cycles-1 then
                            last_input  := '1';
                        end if;
                        
                        OUT_Wr_Addr <= OUT_Wr_Calc;
                        FOR i in 0 to Calc_Steps-1 LOOP
                            OUT_Wr_Data(i) <= TO_SIGNED(RAM_MAX(i), CNN_Value_Resolution);
                        END LOOP;
                    end if;
                else
                    --Save current maximum value in RAM
                    RAM_Addr_In        <= RAM_Addr_Out;
                    for i in 0 to Calc_Steps-1 loop
                        if CNN_Value_Negative = 0 then
                            RAM_Data_In(((CNN_Value_Resolution-1)*(i+1))-1 downto (CNN_Value_Resolution-1)*i) <= STD_LOGIC_VECTOR(TO_UNSIGNED(RAM_MAX(i), CNN_Value_Resolution-1));
                        else
                            RAM_Data_In(((CNN_Value_Resolution)*(i+1))-1 downto (CNN_Value_Resolution)*i) <= STD_LOGIC_VECTOR(TO_SIGNED(RAM_MAX(i), CNN_Value_Resolution));
                        end if;
                    end loop;
                end if;
            END IF;
            
            --Count through results for values of this pooling
            if last_input = '1' then
                Out_Value_Cnt     := 0;
                Out_Delay_Cnt     <= 0;
            ELSIF (Out_Delay_Cnt < Filter_Delay-1) THEN       --Add a delay between the output data
                Out_Delay_Cnt     <= Out_Delay_Cnt + 1;
            ELSIF (Out_Value_Cnt_Reg < Input_Cycles-1) THEN  --Count through Filters for the output
                Out_Delay_Cnt     <= 0;
                Out_Value_Cnt     := Out_Value_Cnt_Reg + 1;
            end if;
            
            --Read output value from RAM
            Out_Value_Cnt_Reg  <= Out_Value_Cnt;
            OUT_Rd_Addr <= Out_Value_Cnt / (Input_Cycles/OUT_RAM_Elements);
            
            if Filter_Delay > 1 then
                IF (Out_Delay_Cnt = 0) THEN
                    FOR i in 0 to Calc_Steps-1 LOOP
                        oData(i) <= to_integer(OUT_Rd_Data(i));
                    END LOOP;
                    
                    oStream.Filter     <= Out_Value_Cnt_Reg;
                    oStream.Data_Valid <= '1';
                ELSE
                    oStream.Data_Valid <= '0';
                END IF;
            end if;
        END IF;
    END PROCESS;
    
END BEHAVIORAL;