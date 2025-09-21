
--Description: -This component calculates the outputs for one dense neural network layer
--Insertion:   -Specify the paramters with the constants in th CNN_Data file
--             -Connect the Cycle_Reg data and stream signal with the Cycle_Reg or previous layer

library IEEE;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.CNN_Config_Package.all;

ENTITY NN_Layer IS
    GENERIC (
        Inputs          : NATURAL := 16;
        Outputs         : NATURAL := 8;
        Activation      : Activation_T := relu; --Activation after dot product
        Input_Cycles    : NATURAL := 1;  --In deeper layers, the clock is faster than the new data. So the operation can be done in seperate cycles. Has to be divisor of inputs
        Calc_Cycles     : NATURAL := 1;  --Second priority after Cycle_Reg Cycles to make use of more cycles for calculation
        Output_Cycles   : NATURAL := 1;  --Output data in multiple cycles, so the next dense layer can calculate the neuron in multiple cycles
        Output_Delay    : NATURAL := 1;  --Cycles between Output Values
        Offset_In       : INTEGER := 0;  --Offset of Cycle_Reg Values
        Offset_Out      : INTEGER := 0;  --Offset of Output Values
        Offset          : INTEGER := 0;
        Weights         : CNN_Weights_T
    );
    PORT (
        iStream : IN  CNN_Stream_T;
        iData   : IN  CNN_Values_T(Inputs/Input_Cycles-1 downto 0);
        iCycle  : IN  NATURAL range 0 to Input_Cycles-1;
        
        oStream : OUT CNN_Stream_T;
        oData   : OUT CNN_Values_T(Outputs/Output_Cycles-1 downto 0) := (others => 0);
        oCycle  : OUT NATURAL range 0 to Output_Cycles-1
    );
END NN_Layer;

ARCHITECTURE BEHAVIORAL OF NN_Layer IS
    CONSTANT Calc_Outputs  : NATURAL := Outputs/Calc_Cycles;   --Outputs that are calculated in one cycle
    CONSTANT Calc_Steps    : NATURAL := Inputs/Input_Cycles;   --Cycle_Reg Values to calculate at once
    CONSTANT Out_Values    : NATURAL := Outputs/Output_Cycles; --Outputs that are sent at once as output data
    CONSTANT Offset_Diff   : INTEGER := Offset_Out-Offset_In;  --Relative output value offset
    
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
        --Bias_Const(i,0) := adjust_offset(weights_in(i,inputs), Offset_In-Offset);
        Bias_Const(i,0) := adjust_offset(weights_in(i,inputs), Bias_Offset_Fixed);
    END LOOP;
    
    return Bias_Const;
END FUNCTION;

CONSTANT Bias_Const    : CNN_Weights_T(0 to Outputs-1, 0 to 0) := Init_Bias(Weights, Outputs, Inputs, Offset_In);

    --Save Weights in a ROM depending on the number of weights that are needed per calculation cycle
type ROM_Array is array (0 to Calc_Cycles*Input_Cycles-1) of STD_LOGIC_VECTOR(Calc_Outputs * Calc_Steps * CNN_Weight_Resolution - 1 downto 0);

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

SIGNAL ROM : ROM_Array := Init_ROM(Weights, Outputs, Inputs, Calc_Cycles*Input_Cycles, Calc_Outputs, Calc_Steps);
SIGNAL ROM_Addr  : NATURAL range 0 to Calc_Cycles*Input_Cycles-1;
SIGNAL ROM_Data  : STD_LOGIC_VECTOR(Calc_Outputs * Calc_Steps * CNN_Weight_Resolution - 1 downto 0);

CONSTANT value_max     : NATURAL := 2**(CNN_Value_Resolution-1)-1;
    --Maximum bits for sum of convolution
CONSTANT bits_max      : NATURAL := CNN_Value_Resolution - 1 + max_val(Offset, 0) + integer(ceil(log2(real(Inputs + 1))));

    --RAM for colvolution sum
type sum_set_t is array (0 to Calc_Outputs-1) of SIGNED(bits_max downto 0);
type sum_ram_t is array (natural range <>) of sum_set_t;
SIGNAL SUM_RAM : sum_ram_t(0 to Calc_Cycles-1) := (others => (others => (others => '0')));
SIGNAL SUM_Rd_Addr  : NATURAL range 0 to Calc_Cycles-1;
SIGNAL SUM_Rd_Data  : sum_set_t;
SIGNAL SUM_Wr_Addr  : NATURAL range 0 to Calc_Cycles-1;
SIGNAL SUM_Wr_Data  : sum_set_t;
SIGNAL SUM_Wr_Ena   : STD_LOGIC := '1';

    --RAM for output values
CONSTANT OUT_RAM_Elements : NATURAL := min_val(Calc_Cycles,Output_Cycles);
type OUT_set_t is array (0 to Outputs/OUT_RAM_Elements-1) of SIGNED(CNN_Value_Resolution-1 downto 0);
type OUT_ram_t is array (natural range <>) of OUT_set_t;
SIGNAL OUT_RAM      : OUT_ram_t(0 to OUT_RAM_Elements-1) := (others => (others => (others => '0')));
SIGNAL OUT_Rd_Addr  : NATURAL range 0 to OUT_RAM_Elements-1;
SIGNAL OUT_Rd_Data  : OUT_set_t;
SIGNAL OUT_Wr_Addr  : NATURAL range 0 to OUT_RAM_Elements-1;
SIGNAL OUT_Wr_Data  : OUT_set_t;
SIGNAL OUT_Wr_Ena   : STD_LOGIC := '1';

SIGNAL Calc_En           : BOOLEAN := false;  --True while neural net is calculated
SIGNAL Calc_En_Sum       : BOOLEAN := false;  --True while sum part of neural net is calculated
SIGNAL Output_Bias_Reg   : NATURAL range 0 to Calc_Cycles := 0; --Current output for the bias calculation
SIGNAL Add_Bias          : BOOLEAN := false;  --True if sum is calculated and bias can be added
SIGNAL Last_Input        : STD_LOGIC;         --True if the calculation is done and the output can be sent to next layer
SIGNAL iData_Reg         : CNN_Values_T(Inputs/Input_Cycles-1 downto 0);
SIGNAL Out_Cycle_Cnt_Reg : NATURAL range 0 to Output_Cycles-1 := Output_Cycles-1;  --Current Output that is one cycle delayed, so the output value can be read from RAM
SIGNAL Out_Delay_Cnt     : NATURAL range 0 to Output_Delay-1 := Output_Delay-1;    --Counter to delay the output values that are sent one after another
SIGNAL Out_Ready         : STD_LOGIC;         --True if the output data can be read from the RAM

CONSTANT Group_Sum_Results    : NATURAL := integer(ceil(real(Calc_Steps)/real(CNN_Mult_Sum_Group)));
CONSTANT Real_Group_Sum_Size  : NATURAL := Calc_Steps/Group_Sum_Results;
CONSTANT Group_Sum_Bits       : NATURAL := integer(ceil(log2(real(Real_Group_Sum_Size)))); -- Additional Bits to calculate sum of first values in group
CONSTANT Group_Sum_Total_Bits : NATURAL := Bool_Select(CNN_Shift_Before_Sum, bits_max+1, CNN_Value_Resolution+CNN_Weight_Resolution-1)+Group_Sum_Bits;
type prod_array_t is array (0 to Calc_Outputs-1, 0 to Group_Sum_Results-1) of SIGNED(Group_Sum_Total_Bits-1 downto 0);
signal Prod_Buf   : prod_array_t := (others => (others => (others =>'0')));
SIGNAL SUM_Rd_Addr_Reg  : NATURAL range 0 to Calc_Cycles-1; -- Delay Addresses by one cycle to have sum in separate cycle

BEGIN
    oStream.Data_CLK <= iStream.Data_CLK;
    
    --Weight ROM RAM
    
    PROCESS (iStream)
    BEGIN
        IF (rising_edge(iStream.Data_CLK)) THEN
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
    
    SUM_Rd_Data      <= SUM_RAM(SUM_Rd_Addr);
    
    --Output RAM to save values after convolution and send them one by one to next convolution
    
    PROCESS (iStream)
    BEGIN
        IF (rising_edge(iStream.Data_CLK)) THEN
            IF (OUT_Wr_Ena = '1') THEN
                OUT_RAM(OUT_Wr_Addr) <= OUT_Wr_Data;
            END IF;
        END IF;
    END PROCESS;
    
    OUT_Rd_Data      <= OUT_RAM(OUT_Rd_Addr);
    
    --Multiply input data with weights and create sum
    
    PROCESS (iStream)
    --Keep track of current calculations of the convolution matrix
    VARIABLE Cycle_Reg     : NATURAL range 0 to Input_Cycles-1;                  --Counter for the current input value calculation
    VARIABLE Cycle_Reg_2   : NATURAL range 0 to Input_Cycles-1;
    VARIABLE Output_Cnt    : NATURAL range 0 to Calc_Cycles := 0;                --Counter for the current output to calculate
    VARIABLE Output_Cnt_2  : NATURAL range 0 to Calc_Cycles := 0;
    VARIABLE Element_Cnt   : NATURAL range 0 to Calc_Cycles*Input_Cycles-1 := 0; --Counter for current calculation step overall
    VARIABLE Element_Reg   : NATURAL range 0 to Calc_Cycles*Input_Cycles-1 := 0;
    
    VARIABLE Weights_Buf : CNN_Weights_T(0 to Calc_Outputs-1, 0 to Calc_Steps-1);
    
    --Variables to write calculated outputs into the Out RAM
    type     Act_sum_t is array (Calc_Outputs-1 downto 0) of SIGNED(CNN_Value_Resolution-1 downto 0);
    VARIABLE Act_sum : Act_sum_t;
    CONSTANT Act_sum_buf_cycles : NATURAL := Calc_Cycles/OUT_RAM_Elements;
    type     Act_sum_buf_t is array (Act_sum_buf_cycles-1 downto 0) of Act_sum_t;
    VARIABLE Act_sum_buf     : Act_sum_buf_t;
    VARIABLE Act_sum_buf_cnt : NATURAL range 0 to Act_sum_buf_cycles-1 := 0;
    
    VARIABLE Out_Cycle_Cnt : NATURAL range 0 to Output_Cycles-1 := Output_Cycles-1;
    
    --Current sum for calculation (part of the sum RAM)
    VARIABLE sum : sum_set_t := (others => (others => '0'));
    VARIABLE Sum_Reg    : sum_set_t := (others => (others => '0'));
    
    VARIABLE Group_Sum_Counter  : NATURAL range 0 to Real_Group_Sum_Size := 0;
    VARIABLE Prod_Sum_Cntr      : NATURAL range 0 to Group_Sum_Results := 0;
    VARIABLE Prod_Sum_Buf       : SIGNED(Group_Sum_Total_Bits-1 downto 0);
    BEGIN
        IF (rising_edge(iStream.Data_CLK)) THEN
            Calc_En_Sum <= Calc_En;
            
            Last_Input <= '0';
            Add_Bias   <= false;
            
            --Save weights from ROM in Variable with CNN_Weight datatype
            FOR s in 0 to Calc_Steps-1 LOOP
                FOR f in 0 to Calc_Outputs-1 LOOP
                    Weights_Buf(f, s) := TO_INTEGER(SIGNED(ROM_Data(CNN_Weight_Resolution*(1+s*Calc_Outputs+f)-1 downto CNN_Weight_Resolution*(s*Calc_Outputs+f))));
                END LOOP;
            END LOOP;
            
            --Add bias to sum after convolution and write to Out RAM
            IF (Add_Bias) THEN
                --Values for multiple outputs can be calculated
                FOR o in 0 to Calc_Outputs-1 LOOP
                    --Add bias with weight offset
                    --Sum_Reg(o) := resize(Sum_Reg(o) + resize(shift_with_rounding(to_signed(Bias_Const(o+Output_Bias_Reg*Calc_Outputs, 0), CNN_Weight_Resolution+Offset), Offset*(-1)),bits_max+1),bits_max+1);
                    --Sum_Reg(o) := resize(Sum_Reg(o) + to_signed(Bias_Const(o+Output_Bias_Reg*Calc_Outputs, 0), bits_max+1),bits_max+1);
                    IF CNN_Rounding(1) = '1' THEN
                        Sum_Reg(o) := resize(shift_with_rounding(Sum_Reg(o), Sum_Offset_Bias) + to_signed(Bias_Const(o+Output_Bias_Reg*Calc_Outputs, 0), bits_max+1),bits_max+1);
                    ELSE
                        Sum_Reg(o) := resize(shift_bits(Sum_Reg(o), Sum_Offset_Bias) + to_signed(Bias_Const(o+Output_Bias_Reg*Calc_Outputs, 0), bits_max+1),bits_max+1);
                    END IF;

                    --Apply output offset with relative offset from this and last layer
                    --Sum_Reg(o) := shift_with_rounding(Sum_Reg(o), Offset_Diff);
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
                        Act_sum(o) := resize(leaky_relu_f(Sum_Reg(o), value_max, CNN_Value_Resolution + max_val(Offset, 0) + integer(ceil(log2(real(Inputs + 1))))), CNN_Value_Resolution);
                    ELSIF (Activation = step_func) THEN
                        Act_sum(o) := resize(step_f(Sum_Reg(o)), CNN_Value_Resolution);
                    ELSIF (Activation = sign_func) THEN
                        Act_sum(o) := resize(sign_f(Sum_Reg(o)), CNN_Value_Resolution);
                    END IF;
                END LOOP;
                
                --The Output RAM has a fixed width for the number of outputs that are sent at once
                IF (Calc_Cycles = OUT_RAM_Elements) THEN
                    --The calculated output values are either written to the RAM directly
                    OUT_Wr_Addr <= Output_Bias_Reg;
                    FOR i in 0 to Calc_Outputs-1 LOOP
                        OUT_Wr_Data(i) <= Act_sum(i);
                    END LOOP;
                ELSE
                    --Or the last outputs are saved and then saved in the RAM at once
                    Act_sum_buf_cnt := Output_Bias_Reg mod Act_sum_buf_cycles;
                    Act_sum_buf(Act_sum_buf_cnt) := Act_sum;
                    IF (Act_sum_buf_cnt = Act_sum_buf_cycles-1) THEN
                        OUT_Wr_Addr <= Output_Bias_Reg/Act_sum_buf_cycles;
                        FOR i in 0 to Act_sum_buf_cycles-1 LOOP
                            FOR j in 0 to Calc_Outputs-1 LOOP
                                OUT_Wr_Data(Calc_Outputs*i + j) <= Act_sum_buf(i)(j);
                            END LOOP;
                        END LOOP;
                    END IF;
                END IF;

                --Send output data after all steps of the neural net are done
                IF (Output_Bias_Reg = Calc_Cycles-1) THEN
                    Last_Input <= '1';
                END IF;
            END IF;
            
            --Calculate the neural net
            IF (Calc_En_Sum) THEN
                --Read last sum from RAM if the calculation for the output is split
                IF (Calc_Cycles > 1) THEN
                    sum := SUM_Rd_Data;
                END IF;
                
                --Set sum to 0 for first calculation
                IF (Cycle_Reg_2 = 0) THEN
                    sum := (others => (others => '0'));
                END IF;
                
                --Calculate the output values
                FOR o in 0 to Calc_Outputs-1 LOOP
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
                
                 --If this is the last data, add the bias
                IF (Cycle_Reg_2 = Input_Cycles-1) THEN
                    --For o in 0 to Calc_Outputs-1 LOOP
                    --    Sum_Reg(o)  := shift_with_rounding(sum(o), CNN_Sum_Offset);
                    --END LOOP;
                    Sum_Reg  := sum;
                    Add_Bias <= true;
                END IF;
                
                --Save result in RAM if the calculation is split
                IF (Calc_Cycles > 1) THEN
                    SUM_Wr_Data <= sum;
                END IF;
                
                --Save current output to add the bias
                Output_Bias_Reg  <= Output_Cnt_2;
            END IF;
            
            --Calculate the neural net
            IF (Calc_En) THEN
                
                --Calculate the output values
                FOR o in 0 to Calc_Outputs-1 LOOP
                    Group_Sum_Counter := 0;
                    Prod_Sum_Cntr     := 0;
                    Prod_Sum_Buf := (others => '0');
                    FOR i in 0 to Calc_Steps-1 LOOP
                        IF CNN_Shift_Before_Sum THEN
                            IF CNN_Rounding(0) = '1' THEN
                                Prod_Sum_Buf := Prod_Sum_Buf + resize(shift_with_rounding(to_signed(iData_Reg(i) * Weights_Buf(o, i), CNN_Value_Resolution+CNN_Weight_Resolution-1), CNN_Weight_Resolution-Offset-1-CNN_Sum_Offset),bits_max+1);
                            ELSE
                                Prod_Sum_Buf := Prod_Sum_Buf + resize(shift_bits(to_signed(iData_Reg(i) * Weights_Buf(o, i), CNN_Value_Resolution+CNN_Weight_Resolution-1), CNN_Weight_Resolution-Offset-1-CNN_Sum_Offset),bits_max+1);
                            END IF;
                        ELSE
                            Prod_Sum_Buf := Prod_Sum_Buf + to_signed(iData_Reg(i) * Weights_Buf(o, i), CNN_Value_Resolution+CNN_Weight_Resolution-1);
                        END IF;
                        
                        IF i = Calc_Steps-1 THEN
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
            
            Cycle_Reg_2 := Cycle_Reg;
            Output_Cnt_2 := Output_Cnt;
            
            --Keep track of the current calculation step while new data for calculation is available
            IF (iStream.Data_Valid = '1') THEN
                Calc_En    <= true;     --Enable Calculation
                iData_Reg  <= iData;    --Save data for calculation in next cycle (first has to load weight)
                Output_Cnt := 0;

                Cycle_Reg := iCycle;
                
                --Count through all calculation steps
                IF (iCycle = 0) THEN
                    Element_Cnt := 0;
                    ELSIF(element_cnt < Calc_Cycles*Input_Cycles-1) THEN
                        Element_Cnt := Element_Cnt + 1;
                    END IF;
                ELSIF (Output_Cnt < Calc_Cycles-1 and element_cnt < Calc_Cycles*Input_Cycles-1) THEN
                --Count through output values that are calculated
                    Output_Cnt  := Output_Cnt + 1;
                    Element_Cnt := Element_Cnt + 1;
                ELSE
                    Calc_En    <= false;
                END IF;
                
            --Load last sum for this filter from the RAM
                SUM_Wr_Addr <= SUM_Rd_Addr;
                SUM_Rd_Addr <= SUM_Rd_Addr_Reg;
                SUM_Rd_Addr_Reg <= Output_Cnt;
                
            --Load Weights from ROM for this output and step of the calculation
                IF (iStream.Data_Valid = '1' OR Calc_En) THEN
                    IF (Element_Cnt < Calc_Cycles*Input_Cycles-1) THEN
                        ROM_Addr <= Element_Cnt + 1;
                    ELSE
                        ROM_Addr <= 0;
                    END IF;
                END IF;

                Out_Ready <= '0';
                
             --Count through results of this neural network
                IF (Last_Input = '1') THEN
                    Out_Cycle_Cnt := 0;
                    Out_Delay_Cnt <= 0;
                    Out_Ready     <= '1';
                ELSIF (Out_Delay_Cnt < Output_Delay-1) THEN      --Add a delay between the output data
                    Out_Delay_Cnt <= Out_Delay_Cnt + 1;
                ELSIF (Out_Cycle_Cnt_Reg < Output_Cycles-1) THEN --Count through Filters for the output
                    Out_Delay_Cnt <= 0;
                    Out_Cycle_Cnt := Out_Cycle_Cnt_Reg + 1;
                    Out_Ready     <= '1';
                END IF;
                
            --Read output value from RAM
                Out_Cycle_Cnt_Reg  <= Out_Cycle_Cnt;
                OUT_Rd_Addr        <= Out_Cycle_Cnt / (Output_Cycles/OUT_RAM_Elements);
                
            --If the output is calculated, read from RAM and set oStream
                IF (Out_Delay_Cnt = 0) THEN
                    FOR i in 0 to Out_Values-1 LOOP
                        IF (Output_Cycles = OUT_RAM_Elements) THEN
                            oData(i) <= to_integer(OUT_Rd_Data(i));
                        ELSE
                            oData(i) <= to_integer(OUT_Rd_Data(i+(Out_Cycle_Cnt_Reg mod (Output_Cycles/OUT_RAM_Elements))*Out_Values));
                        END IF;
                    END LOOP;
                    
                    oCycle             <= Out_Cycle_Cnt_Reg;
                    oStream.Data_Valid <= Out_Ready;
                ELSE
                    oStream.Data_Valid <= '0';
                END IF;
                
            END IF;
        END PROCESS;
        
    END BEHAVIORAL;