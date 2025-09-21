
--Description: -This component calculates the outputs for one convolution layer
--Insertion:   -Specify the paramters with the constants in the CNN Data Package file
--             -Connect the input data and stream signal with the input or previous layer

library IEEE;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.CNN_Config_Package.all;


ENTITY CNN_Convolution IS
    GENERIC (
        Input_Columns  : NATURAL := 28; --Size in x direction of input
        Input_Rows     : NATURAL := 28; --Size in y direction of input
        Input_Values   : NATURAL := 1;  --Number of Filters in previous layer or 3 for RGB input
        Filter_Columns : NATURAL := 3;  --Size in x direction of filters
        Filter_Rows    : NATURAL := 3;  --Size in y direction of filters
        Filters        : NATURAL := 4;  --Number of filters in this layer
        Strides        : NATURAL := 1;  --1 = Output every value, 2 = Skip every second value
        Activation     : Activation_T := relu; --Activation after dot product
        Padding        : Padding_T := valid;   --valid = use available data, same = add padding to use data on the edge
        Input_Cycles   : NATURAL := 1;  --[1 to Input_Values] Filter Cycles of previous convolution
        Value_Cycles   : NATURAL := 1;  --[1 to Input_Values] Second priority
        Calc_Cycles    : NATURAL := 1;  --[1 to Filters] First priority
        Filter_Cycles  : NATURAL := 1;  --[1 to Filters] Cycles for output values (Can help to reduce the normalization DSP usage)
        Filter_Delay   : NATURAL := 1;  --Cycles between Filters
        Expand         : BOOLEAN := true;  --Spreads Row data to maximize cycles per value (needs more RAM)
        Expand_Cycles  : NATURAL := 0;     --If Expand true: Sets Cycles for each pixel when expaned
        Offset_In       : INTEGER := 0;  --Offset of Input Values
        Offset_Out      : INTEGER := 0;  --Offset of Output Values
        Offset         : INTEGER := 0;  --Offset for Weight values
        Weights        : CNN_Weights_T
    );
    PORT (
        iStream : IN  CNN_Stream_T;
        iData   : IN  CNN_Values_T(Input_Values/Input_Cycles-1 downto 0);
        
        oStream : OUT CNN_Stream_T;
        oData   : OUT CNN_Values_T(Filters/Filter_Cycles-1 downto 0) := (others => 0)
    );
END CNN_Convolution;

ARCHITECTURE BEHAVIORAL OF CNN_Convolution IS

    attribute ramstyle : string;

    CONSTANT matrix_values        : NATURAL := Filter_Columns * Filter_Rows;  --Pixels in Convolution
    CONSTANT Matrix_Value_Cycles  : NATURAL := matrix_values*Value_Cycles;    --Needed Cycles for all pixels in convolution and values that are calculated in individual cycles
    CONSTANT Calc_Filters         : NATURAL := Filters/Calc_Cycles;           --Filters that are calculated in one cycle
    CONSTANT Out_Filters          : NATURAL := Filters/Filter_Cycles;         --Filters that are sent at once as output data
    CONSTANT Calc_Steps           : NATURAL := Input_Values/Value_Cycles;     --Values to calculate at once for each pixel in convolution matrix
    CONSTANT Offset_Diff          : INTEGER := Offset_Out-Offset_In;          --Relative output value offset
    CONSTANT Sum_Input_Values     : NATURAL := (Input_Values*matrix_values/Matrix_Value_Cycles);
    
    SIGNAL Expand_Stream : CNN_Stream_T;
    SIGNAL Expand_Data   : CNN_Values_T(Input_Values/Input_Cycles-1 downto 0) := (others => 0);
    
    SIGNAL Matrix_Stream : CNN_Stream_T;
    SIGNAL Matrix_Data   : CNN_Values_T(Calc_Steps-1 downto 0) := (others => 0);
    SIGNAL Matrix_Column : NATURAL range 0 to Filter_Columns-1;
    SIGNAL Matrix_Row    : NATURAL range 0 to Filter_Rows-1;
    SIGNAL Matrix_Input  : NATURAL range 0 to Value_Cycles-1;
    
    COMPONENT CNN_Row_Expander IS
        GENERIC (
            Input_Columns  : NATURAL := 28;
            Input_Rows     : NATURAL := 28;
            Input_Values   : NATURAL := 1;
            Input_Cycles   : NATURAL := 1;
            Output_Cycles  : NATURAL := 2
        );
        PORT (
            iStream : IN  CNN_Stream_T;
            iData   : IN  CNN_Values_T(Input_Values/Input_Cycles-1 downto 0);
            oStream : OUT CNN_Stream_T;
            oData   : OUT CNN_Values_T(Input_Values/Input_Cycles-1 downto 0)

        );
    END COMPONENT;
    
    COMPONENT CNN_Row_Buffer IS
        GENERIC (
            Input_Columns  : NATURAL := 28;
            Input_Rows     : NATURAL := 28;
            Input_Values   : NATURAL := 1;
            Filter_Columns : NATURAL := 3;
            Filter_Rows    : NATURAL := 3;
            Input_Cycles   : NATURAL := 1;
            Value_Cycles   : NATURAL := 1;
            Calc_Cycles    : NATURAL := 1;
            Strides        : NATURAL := 1;
            Padding        : Padding_T := valid
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
    END COMPONENT;

    CONSTANT Bias_Offset            : INTEGER := Offset_In-Offset-CNN_Sum_Offset;  --General Offset for sum
    --CONSTANT Bias_Offset            : INTEGER := Offset_In-Offset;  --Test Bias without offset
    CONSTANT Bias_Offset_Fixed      : INTEGER := max_val(Bias_Offset, 0);          --Offset, with max weight bits in mind
    CONSTANT Sum_Offset_Bias        : INTEGER := Bias_Offset_Fixed-Bias_Offset; --Offset for sum for bias addition
    --CONSTANT Sum_Offset_Bias        : INTEGER := CNN_Sum_Offset;   --Test Bias without offset
    CONSTANT Bias_Offset_Correction : INTEGER := CNN_Sum_Offset - Sum_Offset_Bias; --Offset to correct after sum
    
    --Save Bias seperately in one constant -----
    FUNCTION Init_Bias ( weights_in : CNN_Weights_T; filters : NATURAL; inputs : NATURAL; Offset_In : INTEGER) RETURN  CNN_Weights_T IS
    VARIABLE Bias_Const    : CNN_Weights_T(0 to filters-1, 0 to 0);

BEGIN
    FOR i in 0 to filters-1 LOOP
        Bias_Const(i,0) := adjust_offset(weights_in(i,inputs), Bias_Offset_Fixed);
    END LOOP;
    
    return Bias_Const;
END FUNCTION;

CONSTANT Bias_Const    : CNN_Weights_T(0 to Filters-1, 0 to 0) := Init_Bias(Weights, Filters, matrix_values*Input_Values, Offset_In);

    --Save Weights in a ROM depending on the number of weights that are needed per calculation cycle
type ROM_Array is array (0 to Calc_Cycles*Matrix_Value_Cycles-1) of STD_LOGIC_VECTOR(Calc_Filters * Calc_Steps * CNN_Weight_Resolution - 1 downto 0);

FUNCTION Init_ROM ( weights_in : CNN_Weights_T; filters : NATURAL; inputs : NATURAL; elements : NATURAL; calc_filters : NATURAL; calc_steps : NATURAL) RETURN  ROM_Array IS
VARIABLE rom_reg : ROM_Array;
VARIABLE filters_cnt : NATURAL range 0 to filters := 0;
VARIABLE inputs_cnt  : NATURAL range 0 to inputs := 0;
VARIABLE element_cnt : NATURAL range 0 to elements := 0;
VARIABLE this_weight : STD_LOGIC_VECTOR(CNN_Weight_Resolution-1 downto 0);
BEGIN
    filters_cnt := 0;
    inputs_cnt  := 0;
    element_cnt := 0;
    WHILE inputs_cnt < inputs LOOP
        filters_cnt := 0;
        WHILE filters_cnt < filters LOOP
            FOR s in 0 to calc_steps-1 LOOP
                FOR f in 0 to calc_filters-1 LOOP
                    this_weight :=  STD_LOGIC_VECTOR(TO_SIGNED(weights_in(filters_cnt+f, inputs_cnt+s), CNN_Weight_Resolution));
                    rom_reg(element_cnt)(CNN_Weight_Resolution*(1+s*calc_filters+f)-1 downto CNN_Weight_Resolution*(s*calc_filters+f)) := this_weight;
                END LOOP;
            END LOOP;
            filters_cnt := filters_cnt + calc_filters;
            element_cnt := element_cnt + 1;
        END LOOP;
        inputs_cnt  := inputs_cnt + calc_steps;
    END LOOP;
    
    return rom_reg;
END FUNCTION;

SIGNAL ROM : ROM_Array := Init_ROM(Weights, Filters, Input_Values*matrix_values, Calc_Cycles*Matrix_Value_Cycles, Calc_Filters, Calc_Steps);
SIGNAL ROM_Addr  : NATURAL range 0 to Calc_Cycles*Matrix_Value_Cycles-1;
SIGNAL ROM_Data  : STD_LOGIC_VECTOR(Calc_Filters * Calc_Steps * CNN_Weight_Resolution - 1 downto 0);

CONSTANT value_max     : NATURAL := 2**(CNN_Value_Resolution-1)-1;
    --Maximum bits for sum of convolution
CONSTANT bits_max      : NATURAL := CNN_Value_Resolution - 1 + max_val(Offset, 0) + integer(ceil(log2(real(matrix_values * Input_Values + 1)))) + CNN_Sum_Offset;

    --RAM for colvolution sum
type sum_set_t is array (0 to Calc_Filters-1) of SIGNED(bits_max downto 0);
type sum_ram_t is array (natural range <>) of sum_set_t;
SIGNAL SUM_RAM      : sum_ram_t(0 to Calc_Cycles-1);
SIGNAL SUM_Rd_Addr  : NATURAL range 0 to Calc_Cycles-1;
SIGNAL SUM_Rd_Data  : sum_set_t;
SIGNAL SUM_Wr_Addr  : NATURAL range 0 to Calc_Cycles-1;
SIGNAL SUM_Wr_Data  : sum_set_t;
SIGNAL SUM_Wr_Ena   : STD_LOGIC := '1';

    --RAM for output values
CONSTANT OUT_RAM_Elements : NATURAL := min_val(Calc_Cycles,Filter_Cycles);
type OUT_set_t is array (0 to Filters/OUT_RAM_Elements-1) of SIGNED(CNN_Value_Resolution-1 downto 0);
type OUT_ram_t is array (natural range <>) of OUT_set_t;
SIGNAL OUT_RAM      : OUT_ram_t(0 to OUT_RAM_Elements-1);
SIGNAL OUT_Rd_Addr  : NATURAL range 0 to OUT_RAM_Elements-1;
SIGNAL OUT_Rd_Data  : OUT_set_t;
SIGNAL OUT_Wr_Addr  : NATURAL range 0 to OUT_RAM_Elements-1;
SIGNAL OUT_Wr_Data  : OUT_set_t;
SIGNAL OUT_Wr_Ena   : STD_LOGIC := '1';

SIGNAL Calc_En            : BOOLEAN := false; --True while convolution is calculated
SIGNAL Calc_En_Sum        : BOOLEAN := false; --True while sum part of convolution is calculated
SIGNAL Filter_Bias_Reg    : NATURAL range 0 to Calc_Cycles-1 := 0; --Current filter for the bias calculation
SIGNAL Add_Bias           : BOOLEAN := false; --True if convolution is calculated and bias can be added
SIGNAL Last_Input         : STD_LOGIC;        --True if the convolution is done and the output can be sent to next layer
SIGNAL Last_Reg           : STD_LOGIC := '0';
SIGNAL Matrix_Data_Reg    : CNN_Values_T(Sum_Input_Values-1 downto 0);
SIGNAL Out_Filter_Cnt_Reg : NATURAL range 0 to Filter_Cycles-1 := Filter_Cycles-1;  --Current Filter to Output that is one cycle delayed, so the output value can be read from RAM
SIGNAL Out_Delay_Cnt      : NATURAL range 0 to Filter_Delay-1 := Filter_Delay-1;    --Counter to delay the output values for one convolution that are sent one after another
SIGNAL Out_Ready          : STD_LOGIC;        --True if the output data can be read from the RAM

-- Buffer for multiplication results
CONSTANT Group_Sum_Results    : NATURAL := integer(ceil(real(Sum_Input_Values)/real(CNN_Mult_Sum_Group)));
CONSTANT Real_Group_Sum_Size  : NATURAL := Sum_Input_Values/Group_Sum_Results;
CONSTANT Group_Sum_Bits       : NATURAL := integer(ceil(log2(real(Real_Group_Sum_Size)))); -- Additional Bits to calculate sum of first values in group
CONSTANT Group_Sum_Total_Bits : NATURAL := Bool_Select(CNN_Shift_Before_Sum, bits_max+1, CNN_Value_Resolution+CNN_Weight_Resolution-1)+Group_Sum_Bits;
type prod_array_t is array (0 to Calc_Filters-1, 0 to Group_Sum_Results-1) of SIGNED(Group_Sum_Total_Bits-1 downto 0);
signal Prod_Buf   : prod_array_t := (others => (others => (others =>'0')));
SIGNAL SUM_Rd_Addr_Reg  : NATURAL range 0 to Calc_Cycles-1; -- Delay Addresses by one cycle to have sum in separate cycle

SIGNAL Out_Column         : NATURAL range 0 to CNN_Input_Columns-1;
SIGNAL Out_Row            : NATURAL range 0 to CNN_Input_Rows-1;
SIGNAL Out_Column_Reg     : NATURAL range 0 to CNN_Input_Columns-1;
SIGNAL Out_Row_Reg        : NATURAL range 0 to CNN_Input_Rows-1;
SIGNAL Hold_Out_Position  : NATURAL range 0 to 2 := 0; -- 0 = Waiting for new data, 1 = Out Info Loaded, 2 = Out Info Loaded for this and next operation

--attribute ramstyle of BEHAVIORAL : architecture is "MLAB, no_rw_check";

BEGIN
    
    --Select if input data is spread eavenly to create enought cycles for calculation
    
    Generate1 : If Expand GENERATE
        CNN_Row_Expander1 : CNN_Row_Expander
        GENERIC MAP (
            Input_Columns => Input_Columns,
            Input_Rows    => Input_Rows,
            Input_Values  => Input_Values,
            Input_Cycles  => Input_Cycles,
            Output_Cycles => max_val(Matrix_Value_Cycles*Calc_Cycles+1, Expand_Cycles)
        ) PORT MAP (
            iStream       => iStream,
            iData         => iData,
            oStream       => Expand_Stream,
            oData         => Expand_Data
        );
    END GENERATE Generate1;
    
    Generate2 : If NOT Expand GENERATE
        Expand_Data   <= iData;
        Expand_Stream <= iStream;
    END GENERATE Generate2;
    
    --Save the last image rows and return the data to calculate the convolution maxtrix
    
    CNN_Row_Buffer1 : CNN_Row_Buffer
    GENERIC MAP (
        Input_Columns  => Input_Columns,
        Input_Rows     => Input_Rows,
        Input_Values   => Input_Values,
        Filter_Columns => Filter_Columns,
        Filter_Rows    => Filter_Rows,
        Input_Cycles   => Input_Cycles,
        Value_Cycles   => Value_Cycles,
        Calc_Cycles    => Calc_Cycles,
        Strides        => Strides,
        Padding        => Padding
    ) PORT MAP (
        iStream        => Expand_Stream,
        iData          => Expand_Data,
        oStream        => Matrix_Stream,
        oData          => Matrix_Data,
        oRow           => Matrix_Row,
        oColumn        => Matrix_Column,
        oInput         => Matrix_Input
    );
    
    oStream.Data_CLK <= Matrix_Stream.Data_CLK;
    
    --Weight ROM RAM
    
    PROCESS (Matrix_Stream)
    BEGIN
        IF (rising_edge(Matrix_Stream.Data_CLK)) THEN
            ROM_Data <= ROM(ROM_Addr);
        END IF;
    END PROCESS;
    
    --Sum RAM to save last calculated output values
    
    PROCESS (iStream)
    BEGIN
        IF (rising_edge(iStream.Data_CLK)) THEN
            IF (SUM_Wr_Ena = '1') THEN
                SUM_RAM(SUM_Wr_Addr) <= SUM_Wr_Data;
            END IF;
        END IF;
    END PROCESS;
    
    SUM_Rd_Data <= SUM_RAM(SUM_Rd_Addr);
    
    --Output RAM to save values after convolution and send them one by one to next convolution
    
    PROCESS (iStream)
    BEGIN
        IF (rising_edge(iStream.Data_CLK)) THEN
            IF (OUT_Wr_Ena = '1') THEN
                OUT_RAM(OUT_Wr_Addr) <= OUT_Wr_Data;
            END IF;
        END IF;
    END PROCESS;
    
    OUT_Rd_Data <= OUT_RAM(OUT_Rd_Addr);
    
    --multiply matrix data with weights and create sum
    
    PROCESS (Matrix_Stream)
    --Keep track of current calculations of the convolution matrix
    VARIABLE Cycle_Cnt          : NATURAL range 0 to Matrix_Value_Cycles-1;             --Counter for the current calculation step of the convolution with rows, columns and values
    VARIABLE Cycle_Reg          : NATURAL range 0 to Matrix_Value_Cycles-1;
    VARIABLE Filter_Cnt         : NATURAL range 0 to Calc_Cycles-1 := Calc_Cycles-1;    --Counter for the current filter to calculate
    VARIABLE Filter_Reg         : NATURAL range 0 to Calc_Cycles-1;
    VARIABLE Element_Cnt        : NATURAL range 0 to Calc_Cycles*Matrix_Value_Cycles-1; --Counter for current calculation step overall
    VARIABLE Element_Reg        : NATURAL range 0 to Calc_Cycles*Matrix_Value_Cycles-1;
    VARIABLE Cycle_Reg_2        : NATURAL range 0 to Matrix_Value_Cycles-1;
    VARIABLE Filter_Reg_2       : NATURAL range 0 to Calc_Cycles-1;

    VARIABLE Matrix_Valid_Reg   : STD_LOGIC; --Save last value of Matrix_Stream.Data_CLK to detect a rising edge
    VARIABLE Weights_Buf        : CNN_Weights_T(0 to Calc_Filters-1, 0 to matrix_values*Input_Values/Matrix_Value_Cycles-1);
    type Test_Array        is array (NATURAL range <>, NATURAL range <>) of INTEGER;

    --Variables to write calculated outputs into the Out RAM
    type     Act_sum_t is array (Calc_Filters-1 downto 0) of SIGNED(CNN_Value_Resolution-1 downto 0);
    VARIABLE Act_sum            : Act_sum_t;
    CONSTANT Act_sum_buf_cycles : NATURAL := Calc_Cycles/OUT_RAM_Elements;
    type     Act_sum_buf_t is array (Act_sum_buf_cycles-1 downto 0) of Act_sum_t;
    VARIABLE Act_sum_buf        : Act_sum_buf_t;
    VARIABLE Act_sum_buf_cnt    : NATURAL range 0 to Act_sum_buf_cycles-1 := 0;
    
    VARIABLE Out_Filter_Cnt     : NATURAL range 0 to Filter_Cycles-1 := Filter_Cycles-1;

    --Current sum for calculation (part of the sum RAM)
    VARIABLE sum                : sum_set_t := (others => (others => '0'));
    VARIABLE Sum_Reg            : sum_set_t := (others => (others => '0'));
    
    VARIABLE Valid_Reg          : STD_LOGIC := '0';
    
    VARIABLE Group_Sum_Counter  : NATURAL range 0 to Real_Group_Sum_Size := 0;
    VARIABLE Prod_Sum_Cntr      : NATURAL range 0 to Group_Sum_Results := 0;
    VARIABLE Prod_Sum_Buf       : SIGNED(Group_Sum_Total_Bits-1 downto 0);
    BEGIN
        IF (rising_edge(Matrix_Stream.Data_CLK)) THEN
            Filter_Reg_2 := Filter_Reg;
            Filter_Reg   := Filter_Cnt;
            Cycle_Reg_2  := Cycle_Reg;
            Cycle_Reg    := Cycle_Cnt;
            Element_Reg  := Element_Cnt;
            
            Calc_En_Sum <= Calc_En;
            
            --Keep track of the current calculation step while new data for calculation is available
            IF (Matrix_Stream.Data_Valid = '1') THEN
                Calc_En           <= true;        --Enable Calculation
                Matrix_Data_Reg   <= Matrix_Data; --Save data for calculation in next cycle (first has to load weight)
                
                IF Valid_Reg = '0' THEN
                    IF (Hold_Out_Position = 0) THEN
                        Out_Column        <= Matrix_Stream.Column;
                        Out_Row           <= Matrix_Stream.Row;
                        Hold_Out_Position <= 1;
                    ELSE
                        Out_Column_Reg    <= Matrix_Stream.Column;
                        Out_Row_Reg       <= Matrix_Stream.Row;
                        Hold_Out_Position <= 2;
                    END IF;
                END IF;
                
                --Count through all calculation steps for one convolution with all filters when the matrix data gets valid
                IF (Matrix_Valid_Reg = '0') THEN
                    Element_Cnt := 0;
                ELSIF (Element_Cnt < Calc_Cycles*Matrix_Value_Cycles-1) THEN
                    Element_Cnt := Element_Cnt + 1;
                END IF;
                
                --Count through all cycles to calculate the output and all filters to calculate
                IF (Matrix_Valid_Reg = '0') THEN
                    Cycle_Cnt := 0;
                    Filter_Cnt  := 0;
                ELSIF (Filter_Cnt < Calc_Cycles-1) THEN  --First count through filters with same data and different weight
                    Filter_Cnt := Filter_Cnt + 1;
                ELSIF (Cycle_Cnt < Matrix_Value_Cycles-1) THEN  --Then count through the different steps for one convolution with different rows, columns and values
                    Filter_Cnt  := 0;
                    Cycle_Cnt := Cycle_Cnt + 1;
                END IF;
            ELSE
                Calc_En    <= false;
            END IF;
            
            Valid_Reg := Matrix_Stream.Data_Valid;
            
            Matrix_Valid_Reg := Matrix_Stream.Data_Valid;
            
            --Load last sum for this filter from the RAM
            SUM_Wr_Addr <= SUM_Rd_Addr;
            SUM_Rd_Addr <= SUM_Rd_Addr_Reg;
            SUM_Rd_Addr_Reg <= Filter_Cnt;
            
            --Load Weights from ROM for this filter and step of the convolution
            IF (Matrix_Stream.Data_Valid = '1') THEN
                IF (Element_Cnt < Calc_Cycles*Matrix_Value_Cycles-1) THEN
                    ROM_Addr <= Element_Cnt + 1;
                ELSE
                    ROM_Addr <= 0;
                END IF;
            END IF;
            
            --Save weights from ROM in Variable with CNN_Weight datatype
            FOR s in 0 to Calc_Steps-1 LOOP
                FOR f in 0 to Calc_Filters-1 LOOP
                    Weights_Buf(f, s) := TO_INTEGER(SIGNED(ROM_Data(CNN_Weight_Resolution*(1+s*Calc_Filters+f)-1 downto CNN_Weight_Resolution*(s*Calc_Filters+f))));
                END LOOP;
            END LOOP;
            
            Last_Reg   <= '0';
            Last_Input <= '0';
            Add_Bias   <= false;
            
            --Add bias to convolution sum after convolution and write to Out RAM
            IF (Add_Bias) THEN
                --Output values for multiple filters can be calculated
                FOR o in 0 to Calc_Filters-1 LOOP
                    --Add bias with weight offset
                    --Sum_Reg(o) := resize(Sum_Reg(o) + resize(shift_with_rounding(to_signed(Bias_Const(o+Filter_Bias_Reg*Calc_Filters, 0), CNN_Weight_Resolution+Offset), Offset*(-1)),bits_max+1),bits_max+1);
                    IF CNN_Rounding(1) = '1' THEN
                        Sum_Reg(o) := resize(shift_with_rounding(Sum_Reg(o), Sum_Offset_Bias) + to_signed(Bias_Const(o+Filter_Bias_Reg*Calc_Filters, 0), bits_max+1),bits_max+1);
                    ELSE
                        Sum_Reg(o) := resize(shift_bits(Sum_Reg(o), Sum_Offset_Bias) + to_signed(Bias_Const(o+Filter_Bias_Reg*Calc_Filters, 0), bits_max+1),bits_max+1);
                    END IF;
                    
                    --Apply output offset with relative offset from this and last layer
                    IF CNN_Rounding(2) = '1' THEN
                        Sum_Reg(o) := shift_with_rounding(Sum_Reg(o), Offset_Diff+Bias_Offset_Correction);
                    ELSE
                        Sum_Reg(o) := shift_bits(Sum_Reg(o), Offset_Diff+Bias_Offset_Correction);
                    END IF;
                    
                    --Apply Activation function
                    IF (Activation = relu) THEN
                        Act_sum(o) := resize(relu_f(Sum_Reg(o), value_max), CNN_Value_Resolution);
                    ELSIF (Activation = linear) THEN
                        Act_sum(o) := resize(linear_f(Sum_Reg(o), value_max), CNN_Value_Resolution);
                    ELSIF (Activation = leaky_relu) THEN
                        Act_sum(o) := resize(leaky_relu_f(Sum_Reg(o), value_max, CNN_Value_Resolution - 1 + max_val(Offset, 0) + integer(ceil(log2(real(matrix_values * Input_Values + 1))))), CNN_Value_Resolution);
                    ELSIF (Activation = step_func) THEN
                        Act_sum(o) := resize(step_f(Sum_Reg(o)), CNN_Value_Resolution);
                    ELSIF (Activation = sign_func) THEN
                        Act_sum(o) := resize(sign_f(Sum_Reg(o)), CNN_Value_Resolution);
                    END IF;
                END LOOP;
                
                --The Output RAM has a fixed width for the number of outputs that are sent at once
                IF (Calc_Cycles = OUT_RAM_Elements) THEN
                    --The calculated output values are either written to the RAM directly
                    OUT_Wr_Addr <= Filter_Bias_Reg;
                    FOR i in 0 to Calc_Filters-1 LOOP
                        OUT_Wr_Data(i) <= Act_sum(i);
                    END LOOP;
                ELSE
                    --Or the last outputs are saved and then saved in the RAM at once
                    Act_sum_buf_cnt := Filter_Bias_Reg mod Act_sum_buf_cycles;
                    Act_sum_buf(Act_sum_buf_cnt) := Act_sum;
                    IF (Act_sum_buf_cnt = Act_sum_buf_cycles-1) THEN
                        OUT_Wr_Addr <= Filter_Bias_Reg/Act_sum_buf_cycles;
                        FOR i in 0 to Act_sum_buf_cycles-1 LOOP
                            FOR j in 0 to Calc_Filters-1 LOOP
                                OUT_Wr_Data(Calc_Filters*i + j) <= Act_sum_buf(i)(j);
                            END LOOP;
                        END LOOP;
                    END IF;
                END IF;
            END IF;
            
            IF (Calc_En_Sum) THEN
                --Read last sum from RAM if the calculation for the filters is split
                IF (Calc_Cycles > 1) THEN
                    sum := SUM_Rd_Data;
                END IF;
                
                --Set sum to 0 for first calculation
                IF (Cycle_Reg_2 = 0) THEN
                    sum := (others => (others => '0'));
                END IF;
                
                FOR o in 0 to Calc_Filters-1 LOOP
                    FOR i in 0 to Group_Sum_Results-1 LOOP
                        IF CNN_Shift_Before_Sum THEN
                            sum(o) := resize(sum(o) + Prod_Buf(o, i), bits_max+1);
                        ELSE
                            IF CNN_Rounding(0) = '1' THEN
                                sum(o) := resize(sum(o) + resize(shift_with_rounding(Prod_Buf(o, i), CNN_Weight_Resolution-Offset-1-CNN_Sum_Offset),bits_max+1),bits_max+1);
                            ELSE
                                sum(o) := resize(sum(o) + resize(shift_bits(Prod_Buf(o, i), CNN_Weight_Resolution-Offset-1-CNN_Sum_Offset),bits_max+1),bits_max+1);
                            END IF;
                        END IF;
                    END LOOP;
                END LOOP;
                
                --Save result of convolution in RAM if the calculation for the filters is split
                IF (Calc_Cycles > 1) THEN
                    SUM_Wr_Data <= sum;
                END IF;
                
                --If this is the last data for this convolution, add the bias
                IF (Cycle_Reg_2 = Matrix_Value_Cycles-1) THEN
                    --Send output data after all filters and all steps of the convolution are done
                    IF (Filter_Reg_2 = Calc_Cycles-1) THEN
                        IF Last_Reg = '0' THEN
                            Last_Input <= '1';
                        END IF;
                        Last_Reg   <= '1';
                    END IF;
                    Sum_Reg := sum;
                    Add_Bias <= true;
                END IF;
                
                --Save current filter to add the bias
                Filter_Bias_Reg <= Filter_Reg_2;
            END IF;
            
            --Calculate the convolution
            IF (Calc_En) THEN
                FOR o in 0 to Calc_Filters-1 LOOP
                    Group_Sum_Counter := 0;
                    Prod_Sum_Cntr     := 0;
                    Prod_Sum_Buf := (others => '0');
                    FOR i in 0 to Sum_Input_Values-1 LOOP
                        IF CNN_Shift_Before_Sum THEN
                            IF CNN_Rounding(0) = '1' THEN
                                Prod_Sum_Buf := Prod_Sum_Buf + resize(shift_with_rounding(to_signed(Matrix_Data_Reg(i) * Weights_Buf(o, i), CNN_Value_Resolution+CNN_Weight_Resolution-1), CNN_Weight_Resolution-Offset-1-CNN_Sum_Offset),bits_max+1);
                            ELSE
                                Prod_Sum_Buf := Prod_Sum_Buf + resize(shift_bits(to_signed(Matrix_Data_Reg(i) * Weights_Buf(o, i), CNN_Value_Resolution+CNN_Weight_Resolution-1), CNN_Weight_Resolution-Offset-1-CNN_Sum_Offset),bits_max+1);
                            END IF;
                        ELSE
                            Prod_Sum_Buf := Prod_Sum_Buf + to_signed(Matrix_Data_Reg(i) * Weights_Buf(o, i), CNN_Value_Resolution+CNN_Weight_Resolution-1);
                        END IF;
                        
                        IF i = Sum_Input_Values-1 THEN
                            Prod_Buf(o, Prod_Sum_Cntr) <= Prod_Sum_Buf;
                        ELSIF Group_Sum_Counter < Real_Group_Sum_Size-1 THEN
                            Group_Sum_Counter := Group_Sum_Counter + 1;
                        else
                            Group_Sum_Counter := 0;
                            
                            Prod_Buf(o, Prod_Sum_Cntr) <= Prod_Sum_Buf;
                            Prod_Sum_Buf := (others => '0');
                            
                            Prod_Sum_Cntr := Prod_Sum_Cntr + 1;
                        END IF;
                    END LOOP;
                END LOOP;
            END IF;

            Out_Ready <= '0';
            
            --Set current column and row for output and count through results for filters of this convolution
            IF (Last_Input = '1') THEN
                Out_Filter_Cnt := 0;
                Out_Delay_Cnt  <= 0;
                Out_Ready      <= '1';
            ELSIF (Out_Delay_Cnt < Filter_Delay-1) THEN       --Add a delay between the output data
                Out_Delay_Cnt  <= Out_Delay_Cnt + 1;
            ELSIF (Out_Filter_Cnt_Reg < Filter_Cycles-1) THEN --Count through Filters for the output
                Out_Delay_Cnt  <= 0;
                Out_Filter_Cnt := Out_Filter_Cnt_Reg + 1;
                Out_Ready      <= '1';
            END IF;
            
            --Read output value from RAM
            Out_Filter_Cnt_Reg  <= Out_Filter_Cnt;
            OUT_Rd_Addr         <= Out_Filter_Cnt / (Filter_Cycles/OUT_RAM_Elements);
            
            --If the output is calculated, read from RAM and set oStream
            IF (Out_Ready = '1') THEN
                FOR i in 0 to Out_Filters-1 LOOP
                    IF (Filter_Cycles = OUT_RAM_Elements) THEN
                        oData(i) <= to_integer(OUT_Rd_Data(i));
                    ELSE
                        oData(i) <= to_integer(OUT_Rd_Data(i+(Out_Filter_Cnt_Reg mod (Filter_Cycles/OUT_RAM_Elements))*Out_Filters));
                    END IF;
                END LOOP;
                
                oStream.Filter     <= Out_Filter_Cnt_Reg;
                oStream.Data_Valid <= '1';
                oStream.Row        <= Out_Row;
                oStream.Column     <= Out_Column;
                
                IF Out_Filter_Cnt_Reg = Filter_Cycles-1 THEN
                    IF Hold_Out_Position = 2 THEN
                        Out_Column        <= Out_Column_Reg;
                        Out_Row           <= Out_Row_Reg;
                        Hold_Out_Position <= 1;
                    else
                        Hold_Out_Position <= 0;
                    END IF;
                END IF;
            ELSE
                oStream.Data_Valid <= '0';
            END IF;
            
        END IF;
    END PROCESS;
    
END BEHAVIORAL;