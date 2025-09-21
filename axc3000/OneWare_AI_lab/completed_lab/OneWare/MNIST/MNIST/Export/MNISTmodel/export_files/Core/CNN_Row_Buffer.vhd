
--Description: -This component buffers rows to output a matrix
--             -Output: For Columns and Rows lower number = older data
--              00, 01, 02
--              10, 11, 12
--              20, 21, 22

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
use work.CNN_Config_Package.all;

ENTITY CNN_Row_Buffer IS
    GENERIC (
        Input_Columns  : NATURAL := 28; --Size in x direction of input
        Input_Rows     : NATURAL := 28; --Size in y direction of input
        Input_Values   : NATURAL := 1;  --Number of Filters in previous layer or 3 for RGB input
        Filter_Columns : NATURAL := 3;  --Size in x direction of filters
        Filter_Rows    : NATURAL := 3;  --Size in y direction of filters
        Input_Cycles   : NATURAL := 1;  --Filter Cycles of previous convolution
        Value_Cycles   : NATURAL := 1;  --Send Values of part of matrix in multiple cycles (Has to be >= Input Cycles and a multiple of the input cycles)
        Calc_Cycles    : NATURAL := 1;  --Cycles between values for calculation in convolution
        Strides        : NATURAL := 1;  --1 = Output every value, 2 = Skip every second value
        Padding        : Padding_T := valid --valid = use available data, same = add padding to use data on the edge
    );
    PORT (
        iStream : IN  CNN_Stream_T;
        iData   : IN  CNN_Values_T(Input_Values/Input_Cycles-1 downto 0);
        oStream : OUT CNN_Stream_T;
        oData   : OUT CNN_Values_T(Input_Values/Value_Cycles-1 downto 0) := (others => 0);
        oRow    : BUFFER NATURAL range 0 to Filter_Rows-1;
        oColumn : BUFFER NATURAL range 0 to Filter_Columns-1;
        oInput  : BUFFER NATURAL range 0 to Value_Cycles-1
    );
END CNN_Row_Buffer;

ARCHITECTURE BEHAVIORAL OF CNN_Row_Buffer IS

attribute ramstyle : string;
    
    --If the input values only have 2 columns, the row buffer needs one more row to always have the needed data saved
    FUNCTION RAM_Rows_F ( Filter_Rows : NATURAL; Input_Columns : NATURAL) RETURN  NATURAL IS
BEGIN
    IF (Input_Columns = 2) THEN
        return Filter_Rows + 1;
    ELSE
        return Filter_Rows;
    END IF;
END FUNCTION;

--RAM dimensions
CONSTANT RAM_Rows  : NATURAL := RAM_Rows_F(Filter_Rows, Input_Columns);
CONSTANT RAM_Bits  : NATURAL := (CNN_Value_Resolution+CNN_Value_Negative-1)*(Input_Values/Value_Cycles);
CONSTANT RAM_Width : NATURAL := Input_Columns*RAM_Rows*Value_Cycles;

--RAM to save last rows
type RAM_T is array (RAM_Width-1 downto 0) of STD_LOGIC_VECTOR(RAM_Bits-1 downto 0);
SIGNAL Buffer_RAM : RAM_T := (others => (others => '0'));
SIGNAL RAM_Addr_Out : natural range 0 to RAM_Width - 1;
SIGNAL RAM_Addr_In : natural range 0 to RAM_Width - 1;
SIGNAL RAM_Data_In : std_logic_vector(RAM_Bits - 1 downto 0);
SIGNAL RAM_Data_Out : std_logic_vector(RAM_Bits - 1 downto 0);
SIGNAL RAM_Enable  : STD_LOGIC := '0';

--Output row, column and filter is calculated before the data is read from the RAM
SIGNAL oStream_Reg    : CNN_Stream_T;
SIGNAL oRow_Reg       : NATURAL range 0 to RAM_Rows-1;
SIGNAL oColumn_Reg    : NATURAL range 0 to Filter_Columns-1;
SIGNAL oInput_Reg     : NATURAL range 0 to Value_Cycles-1;

SIGNAL Out_Row_Center       : NATURAL range 0 to Input_Rows-1 := 0;
SIGNAL Out_Column_Center    : NATURAL range 0 to Input_Columns-1 := 0;

SIGNAL oData_En_Reg : STD_LOGIC := '0';
SIGNAL RAM_Out_Row_Center : NATURAL range 0 to RAM_Rows-1;

--Delay Output by one cycle for address calculation
SIGNAL oStream_Buf  : CNN_Stream_T;
SIGNAL oRow_Buf     : NATURAL range 0 to Filter_Rows-1;
SIGNAL oColumn_Buf  : NATURAL range 0 to Filter_Columns-1;
SIGNAL oInput_Buf   : NATURAL range 0 to Value_Cycles-1;
SIGNAL oData_En_Buf : STD_LOGIC := '0';

SIGNAL Row_Calc_Buf       : INTEGER range (-1)*(Filter_Rows)/2 to RAM_Rows+(Filter_Rows-1)/2-1;
SIGNAL Column_Calc_Buf    : INTEGER range (-1)*(Filter_Columns)/2 to Input_Columns+(Filter_Columns-1)/2-1 := 0;
SIGNAL Value_Calc_Buf     : NATURAL range 0 to Value_Cycles-1 := 0;

CONSTANT Strides_Offset   : NATURAL := Bool_Select(Padding = same and Strides > 1, 1, 0);

--attribute ramstyle of BEHAVIORAL : architecture is "MLAB, no_rw_check";

BEGIN
    
    oStream.Data_CLK <= iStream.Data_CLK;
    
    PROCESS (iStream)
    BEGIN
        IF (rising_edge(iStream.Data_CLK)) THEN
            IF (RAM_Enable = '1') THEN
                --Save data in RAM
                Buffer_RAM(RAM_Addr_In) <= RAM_Data_In;
            END IF;
        END IF;
    END PROCESS;
    
    --Outputs one set of values in matrix
    RAM_Data_Out <= Buffer_RAM(RAM_Addr_Out);
    
    PROCESS (iStream)
    VARIABLE RAM_In_Row            : NATURAL range 0 to RAM_Rows-1 := 0;  --Current Row in RAM that is now set
    
    --Variables to set the RAM input data and address
    VARIABLE RAM_In_Addr_Offset    : NATURAL range 0 to Value_Cycles-1 := 0;
    VARIABLE RAM_In_Data_Part      : NATURAL range 0 to Input_Values-1 := 0;
    
    --Variable to detect changing input values
    VARIABLE iStream_Row_Reg       : NATURAL range 0 to Input_Rows-1 := 0;
    VARIABLE iStream_Value_Reg     : NATURAL range 0 to Input_Values-1 := 0;
    VARIABLE iStream_Column_Reg    : NATURAL range 0 to Input_Columns-1 := 0;
    
    VARIABLE Out_Column_Center_Reg : NATURAL range 0 to Input_Columns-1 := 0;  --Helps to calculate the center column position
    VARIABLE Valid_Reg             : STD_LOGIC;  --True while data is read from RAM and sent out
    --Variables to count through all steps in the data out process/the convolution calculation
    VARIABLE Row_Cntr              : INTEGER range (-1)*(Filter_Rows)/2 to (Filter_Rows-1)/2 := (-1)*(Filter_Rows)/2;
    VARIABLE Column_Cntr           : INTEGER range (-1)*(Filter_Columns)/2 to (Filter_Columns-1)/2 := (-1)*(Filter_Columns)/2;
    VARIABLE Value_Cntr            : NATURAL range 0 to Value_Cycles-1 := 0;
    VARIABLE Calc_Cntr             : NATURAL range 0 to Calc_Cycles-1 := 0;
    
    BEGIN
        IF (rising_edge(iStream.Data_CLK)) THEN
            
            --Count through rows in RAM for current row to be saved
            IF (iStream_Row_Reg /= iStream.Row) THEN
                IF (RAM_In_Row < RAM_Rows-1) THEN
                    RAM_In_Row := RAM_In_Row + 1;
                ELSE
                    RAM_In_Row := 0;
                END IF;
            END IF;
            
            --RAM Input address has to be calculated differently dependant on Value_Cycles and Input_Cycles
            IF (Input_Cycles = 1) THEN
                --All values from input come at once
                IF ((Input_Columns > 1 AND iStream_Column_Reg /= iStream.Column) OR (Input_Columns <= 1 AND iStream_Row_Reg /= iStream.Row)) THEN
                    RAM_In_Addr_Offset := 0;
                ELSIF (RAM_In_Addr_Offset < Value_Cycles-1) THEN
                    RAM_In_Addr_Offset := RAM_In_Addr_Offset + 1;
                END IF;
                RAM_In_Data_Part := RAM_In_Addr_Offset;
            ELSIF (Input_Cycles <= Value_Cycles) THEN
                --The input values come in less or equal cycles than the cycles to output the values
                IF (iStream_Value_Reg /= iStream.Filter) THEN
                    RAM_In_Addr_Offset := iStream.Filter*(Value_Cycles/Input_Cycles);
                    RAM_In_Data_Part   := 0;
                ELSIF (RAM_In_Addr_Offset < (iStream.Filter+1)*(Value_Cycles/Input_Cycles)-1) THEN
                    RAM_In_Addr_Offset := RAM_In_Addr_Offset + 1;
                    RAM_In_Data_Part   := RAM_In_Data_Part + 1;
                END IF;
            ELSE
                --The input values come in more cycles than the cycles to output the values
                IF (iStream_Value_Reg /= iStream.Filter) THEN
                    RAM_In_Addr_Offset := iStream.Filter/(Input_Cycles/Value_Cycles);
                    RAM_In_Data_Part   := iStream.Filter mod (Input_Cycles/Value_Cycles);
                END IF;
            END IF;
            
            --Calculate the current RAM position to write the current input data
            RAM_Addr_In   <= RAM_In_Addr_Offset+(iStream.Column+RAM_In_Row*Input_Columns)*Value_Cycles;
            
            --RAM Data In is dependant on Input_Cycles and Value_Cycles
            IF (Input_Cycles = Value_Cycles) THEN
                --Same values at a time come in as values that are sent out
                FOR i in 0 to Input_Values/Input_Cycles-1 LOOP
                    RAM_Data_In((i+1)*(CNN_Value_Resolution+CNN_Value_Negative-1)-1 downto i*(CNN_Value_Resolution+CNN_Value_Negative-1)) <= STD_LOGIC_VECTOR(TO_UNSIGNED(iData(i), (CNN_Value_Resolution+CNN_Value_Negative-1)));
                END LOOP;
            ELSIF (Input_Cycles < Value_Cycles) THEN
                --More values at a time come in as values that are sent out
                FOR i in 0 to Input_Values/Value_Cycles-1 LOOP
                    RAM_Data_In((i+1)*(CNN_Value_Resolution+CNN_Value_Negative-1)-1 downto i*(CNN_Value_Resolution+CNN_Value_Negative-1)) <= STD_LOGIC_VECTOR(TO_UNSIGNED(iData(i+RAM_In_Data_Part*(Input_Values/Value_Cycles)), (CNN_Value_Resolution+CNN_Value_Negative-1)));
                END LOOP;
            ELSE
                --Less values at a time come in as values that are sent out
                FOR i in 0 to Input_Values/Input_Cycles-1 LOOP
                    RAM_Data_In((i+1+RAM_In_Data_Part*(Input_Values/Input_Cycles))*(CNN_Value_Resolution+CNN_Value_Negative-1)-1 downto (i+RAM_In_Data_Part*(Input_Values/Input_Cycles))*(CNN_Value_Resolution+CNN_Value_Negative-1)) <= STD_LOGIC_VECTOR(TO_UNSIGNED(iData(i), (CNN_Value_Resolution+CNN_Value_Negative-1)));
                END LOOP;
            END IF;
            
            --Write to RAM if there is new input data
            RAM_Enable <= iStream.Data_Valid;
            
            --Calculate output row and column center (current row and column - (Filter Size-1)/2)
            IF (Input_Columns > 1) THEN
                Out_Column_Center_Reg  := (iStream.Column - (Filter_Columns-1)/2) mod Input_Columns;
                IF (Out_Column_Center > Out_Column_Center_Reg) THEN
                    Out_Row_Center     <= (iStream.Row - (Filter_Rows-1)/2) mod Input_Rows;
                    RAM_Out_Row_Center <= (RAM_In_Row - (Filter_Rows-1)/2) mod RAM_Rows;
                END IF;
                Out_Column_Center      <= Out_Column_Center_Reg;
            ELSE
                Out_Column_Center      <= 0;
                Out_Row_Center         <= (iStream.Row - (Filter_Rows-1)/2) mod Input_Rows;
                RAM_Out_Row_Center     <= (RAM_In_Row - (Filter_Rows-1)/2) mod RAM_Rows;
            END IF;
            
            --Count through all steps in the data out process/the convolution calculation
            IF ((Input_Columns > 1 AND Out_Column_Center /= oStream_Reg.Column) OR (Input_Columns <= 1 AND Out_Row_Center /= oStream_Reg.Row)) THEN
                --Start in the upper left corner at value 0 and with the filter calculation cycle 0
                Row_Cntr    := (-1)*(Filter_Rows)/2;
                Column_Cntr := (-1)*(Filter_Columns)/2;
                Value_Cntr  := 0;
                Calc_Cntr   := 0;
                Valid_Reg   := '1';
            ELSIF (Calc_Cntr < Calc_Cycles-1) THEN
                --Wait for the cycles that are needed to calculate the convolution for each filter
                Calc_Cntr   := Calc_Cntr + 1;
            ELSE
                Calc_Cntr   := 0;
                IF (Value_Cntr < Value_Cycles-1) THEN
                    --Then count through all cycles to calculate the output values
                    Value_Cntr  := Value_Cntr + 1;
                ELSE
                    Value_Cntr  := 0;
                    --Then count through all coumns and rows in the convolution matrix
                    IF (Column_Cntr < (Filter_Columns-1)/2) THEN
                        Column_Cntr := Column_Cntr + 1;
                    ELSIF (Row_Cntr < (Filter_Rows-1)/2) THEN
                        Column_Cntr := (-1)*(Filter_Columns)/2;
                        Row_Cntr    := Row_Cntr + 1;
                    ELSE
                        Valid_Reg   := '0';
                    END IF;
                END IF;
            END IF;
            
            --Calculate the address from that the data has to be read
            Row_Calc_Buf    <= RAM_Out_Row_Center+Row_Cntr;
            Column_Calc_Buf <= Out_Column_Center+Column_Cntr;
            Value_Calc_Buf  <= Value_Cntr;
            
            RAM_Addr_Out <= ((Row_Calc_Buf mod RAM_Rows) * Input_Columns + (Column_Calc_Buf mod Input_Columns)) * Value_Cycles + Value_Calc_Buf;
            
            --Set center position as column and row for the output stream
            oStream_Reg.Column <= Out_Column_Center;
            oStream_Reg.Row    <= Out_Row_Center;
            oStream_Reg.Filter <= 0;
            
            --Set Current Row, Column and Value with the Counters
            oRow_Reg           <= Row_Cntr + Filter_Rows/2;
            oColumn_Reg        <= Column_Cntr + Filter_Columns/2;
            oInput_Reg         <= Value_Cntr;
            
            --Check if the position in the matrix is outside of the image and padding is needed
            IF (Out_Column_Center+Column_Cntr < 0 OR Out_Column_Center+Column_Cntr > Input_Columns-1 OR Out_Row_Center+Row_Cntr < 0 OR Out_Row_Center+Row_Cntr > Input_Rows-1) THEN
                oData_En_Reg <= '0';
            ELSE
                oData_En_Reg <= '1';
            END IF;
            
            oData_En_Buf <= oData_En_Reg;
            
            --Set the output data dependant on the padding setting
            IF (Padding = valid) THEN  --No padding
                --Check if the matrix is inside of the image and skip rows and columns depending on the strides
                IF (Valid_Reg = '1'
                    AND Out_Column_Center >= Filter_Columns/2 AND Out_Column_Center < Input_Columns-(Filter_Columns-1)/2
                    AND Out_Row_Center >= Filter_Rows/2 AND Out_Row_Center < Input_Rows-(Filter_Rows-1)/2
                    AND (Out_Column_Center - Filter_Columns/2) MOD Strides = Strides_Offset AND (Out_Row_Center - Filter_Rows/2) MOD Strides = Strides_Offset) THEN
                    oStream_Reg.Data_Valid <= '1';
                ELSE
                    oStream_Reg.Data_Valid <= '0';
                END IF;
                
                --Set output stream and data
                IF (oStream_Reg.Data_Valid = '1') THEN
                    --Correct column and row by rows and columns that are ignored with the missing padding
                    oStream_Buf.Column     <= (oStream_Reg.Column - Filter_Columns/2);
                    oStream_Buf.Row        <= (oStream_Reg.Row - Filter_Rows/2);
                    oStream_Buf.Filter     <= oStream_Reg.Filter;
                    oStream_Buf.Data_Valid <= '1';
                    
                    oRow_Buf               <= oRow_Reg;
                    oColumn_Buf            <= oColumn_Reg;
                    oInput_Buf             <= oInput_Reg;
                    
                ELSE
                    oStream_Buf.Data_Valid <= '0';
                END IF;
            ELSE                    --Add zero padding
                --skip rows and columns depending on the strides
                IF (Valid_Reg = '1' AND Out_Column_Center MOD Strides = Strides_Offset AND Out_Row_Center MOD Strides = Strides_Offset) THEN
                    oStream_Reg.Data_Valid <= '1';
                ELSE
                    oStream_Reg.Data_Valid <= '0';
                END IF;
                
                --Set output stream and data
                IF (oStream_Reg.Data_Valid = '1') THEN
                    oStream_Buf.Column     <= oStream_Reg.Column;
                    oStream_Buf.Row        <= oStream_Reg.Row;
                    oStream_Buf.Filter     <= oStream_Reg.Filter;
                    oStream_Buf.Data_Valid <= '1';
                    
                    oRow_Buf               <= oRow_Reg;
                    oColumn_Buf            <= oColumn_Reg;
                    oInput_Buf             <= oInput_Reg;
                    
                ELSE
                    oStream_Buf.Data_Valid <= '0';
                END IF;
                
            END IF;
            
            iStream_Row_Reg     := iStream.Row;
            iStream_Column_Reg  := iStream.Column;
            iStream_Value_Reg   := iStream.Filter;
            
            oStream.Column     <= oStream_Buf.Column/Strides;
            oStream.Row        <= oStream_Buf.Row/Strides;
            oStream.Filter     <= oStream_Buf.Filter;
            oStream.Data_Valid <= oStream_Buf.Data_Valid;
            
            oRow    <= oRow_Buf;
            oColumn <= oColumn_Buf;
            oInput  <= oInput_Buf;
            
            IF oStream_Buf.Data_Valid = '1' THEN
                FOR i in 0 to Input_Values/Value_Cycles-1 LOOP
                    oData(i) <= TO_INTEGER(UNSIGNED(RAM_Data_Out((i+1)*(CNN_Value_Resolution+CNN_Value_Negative-1)-1 downto i*(CNN_Value_Resolution+CNN_Value_Negative-1))));
                END LOOP;
            END IF;
            
            IF (Padding /= valid AND oData_En_Buf = '0') THEN
                oData <= (others => 0);
            END IF;
        END IF;
    END PROCESS;
    
END BEHAVIORAL;