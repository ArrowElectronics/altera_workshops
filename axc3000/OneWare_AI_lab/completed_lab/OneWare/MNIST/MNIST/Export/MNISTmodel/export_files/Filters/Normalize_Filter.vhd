
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
use work.CNN_Config_Package.all;
use IEEE.MATH_REAL.ALL;

ENTITY Normalize_Filter IS
    GENERIC (
        Input_Values   : NATURAL := 3;    --Number of Filters in previous layer or 3 for RGB input
        Input_Images   : NATURAL := 1;    --Number of input images (2 images and RGB: (2 downto 0) for image 1 and (5 downto 3) for image 2)
        En_In_Buffer   : BOOLEAN := TRUE; --Enable input buffer
        En_Out_Buffer  : BOOLEAN := TRUE; --Enable output buffer
        Calc_Type      : NATURAL := 0;    -- 0: By Division, 1: By Shift Approximation
        Approx_Res     : NATURAL := 3;    -- If Calc_Type=1, Number of Shift-Additions to approximate the division [1...(CNN_Value_Resolution-2)]. If Calc_Type=0 and not 0, number of bits of difference value to be used for division [0...CNN_Value_Resolution-1]
        Use_Par_Bounds : BOOLEAN := FALSE; --Enable parameter bounds
        Par_Max        : NATURAL := 2**(CNN_Value_Resolution-1)-1;  -- Max to use, if Use_Par_Bounds is set
        Par_Min        : NATURAL := 0;     -- Min to use, if Use_Par_Bounds is set
        GLOBAL_MAX_VALUE : NATURAL := 2**(CNN_Value_Resolution-1)-1
    );
    PORT (
        iStream : IN  CNN_Stream_T;
        iData   : IN  CNN_Values_T((Input_Values*Input_Images)-1 downto 0);
        
        oStream : OUT CNN_Stream_T;
        oData   : OUT CNN_Values_T((Input_Values*Input_Images)-1 downto 0) := (others => 0)
    );
END Normalize_Filter;

ARCHITECTURE BEHAVIORAL OF Normalize_Filter IS

attribute ramstyle : string;
    
    --Input data register
    SIGNAL iStream_Reg : CNN_Stream_T;
    SIGNAL iData_Reg   : CNN_Values_T((Input_Values*Input_Images)-1 downto 0);
    
    --Output data register
    SIGNAL oStream_Reg : CNN_Stream_T;
    SIGNAL oData_Reg   : CNN_Values_T((Input_Values*Input_Images)-1 downto 0);


    -- max, min and difference from last image
    SIGNAL max_value : NATURAL range 0 to (2**CNN_Value_Resolution-1) := Par_Max;
    SIGNAL min_value : NATURAL range 0 to (2**CNN_Value_Resolution-1) := Par_Min;
    SIGNAL difference : NATURAL range 0 to (2**CNN_Value_Resolution-1) := Par_Max - Par_Min;

    type val_arr is array (0 to Input_Values*Input_Images-1) of NATURAL range 0 to (2**(2*CNN_Value_Resolution-1)-1);

    type Shift_L_LookUp_T is array (1 to GLOBAL_MAX_VALUE) of NATURAL range 0 to (CNN_Value_Resolution-1);
    
    -- generate lookup table. the table stores for each difference value the inverse log2 of the difference value to use as a shift to approximate the normalization as a shift_letf
    function init_L_lookup return Shift_L_LookUp_T is
        variable result : Shift_L_LookUp_T;
    begin
        for i in 1 to GLOBAL_MAX_VALUE loop
            result(i) := integer(floor(log2(real(GLOBAL_MAX_VALUE)/real(i))));
        end loop;
        return result;
    end function;

    constant Shift_L_LookUp : Shift_L_LookUp_T := init_L_lookup;
    
    -- TODO what if Approx_Res==0?
    type Shift_R_LookUp_T is array (1 to GLOBAL_MAX_VALUE, 0 to Approx_Res-1) of BOOLEAN;

    -- generate lookup table. the table stores for each difference value and number of bits shifted to the right if this shift should be added to the result.
    function init_R_lookup return Shift_R_LookUp_T is
        variable result : Shift_R_LookUp_T;
        variable floored_power : natural range 0 to (2**CNN_Value_Resolution-1);
        variable current_factor : real;
        variable default_factor : real;
    begin
        for i in 1 to GLOBAL_MAX_VALUE loop --mighty logic
            floored_power := integer(2**floor(log2(real(GLOBAL_MAX_VALUE)/real(i)))) * i;
			default_factor := 1.0;
            current_factor := 1.0;
            for j in 0 to Approx_Res-1 loop
				default_factor := default_factor + (0.5/real(2**j)); -- +0.5....+0.25....+0.125.....+0.0625.....
				if (real(floored_power)*current_factor) < ((default_factor)*0.5*real(GLOBAL_MAX_VALUE)) then
					result(i,j) := true; -- First shift is  true if floored_power is less than 0.75*127. next < 0.875*127,...
					current_factor := current_factor + (0.5/real(2**j)); -- +0.5....+0.25....+0.125.....+0.0625.....
				else
					result(i,j) := false; -- Otherwise, it is false
				end if;
            end loop;
        end loop;
        return result;
    end function;

    constant Shift_R_LookUp : Shift_R_LookUp_T := init_R_lookup;

BEGIN
    
    oStream.Data_CLK <= iStream.Data_CLK;
    
    PROCESS (iStream)
        VARIABLE sel_stream : CNN_Stream_T;
        VARIABLE sel_data   : CNN_Values_T((Input_Values*Input_Images)-1 downto 0);
        VARIABLE sel_o_data : CNN_Values_T((Input_Values*Input_Images)-1 downto 0);
        VARIABLE o_data_reg : val_arr;
        VARIABLE temp_max   : NATURAL range 0 to (2**CNN_Value_Resolution-1) := GLOBAL_MAX_VALUE; -- initiallized to max, so max_value is set correctly for first image. Later reset to 0.
        VARIABLE temp_min   : NATURAL range 0 to (2**CNN_Value_Resolution-1) := 0; -- initiallized to 0, so min_value is set correctly for first image. Later reset to GLOBAL_MAX_VALUE.
        VARIABLE this_difference  : NATURAL range 0 to (2**CNN_Value_Resolution-1);
        VARIABLE shift_difference : NATURAL range 0 to (2**Approx_Res-1);
        VARIABLE normalized_val : integer range -(2**CNN_Value_Resolution-1) to (2**CNN_Value_Resolution-1);
        VARIABLE normalized_shi : integer range -(2**CNN_Value_Resolution-1) to (2**CNN_Value_Resolution-1);
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

            this_difference := difference;

            -- Process the input data
            if sel_stream.Data_Valid = '1' then
                For i in 0 to Input_Images-1 loop
                    sel_o_data(i) := 0; -- Initialize output data for each image
                    o_data_reg(i) := 0; -- Initialize output data for each image
                    For c in 0 to Input_Values-1 loop
                        
                        -- determine next min and max values
                        IF sel_data(c + i*Input_Values) > temp_max THEN
                            temp_max := sel_data(c + i*Input_Values); -- Max 
                        END IF;
                        IF sel_data(c + i*Input_Values) < temp_min THEN
                            temp_min := sel_data(c + i*Input_Values); -- Min 
                        END IF;

                        normalized_val := (sel_data(c + i*Input_Values) - min_value);

                        if normalized_val < 0 then
                            sel_o_data(c + i*Input_Values) := 0; -- Ensure no negative values
                        else
                        
                            -- avoid division by zero
                            if this_difference = 0 then
                                this_difference := 1; -- setting to 1, in case the current image has deviation in pixel values, then at least we get a binary image
                            end if;

                            IF Calc_Type = 0 THEN
                                if Use_Par_Bounds then
                                    o_data_reg(c + i*Input_Values) := unsigned_multiply_efficient(normalized_val, real(GLOBAL_MAX_VALUE)/real(Par_Max - Par_Min)); -- multiply by constant: 127/(MAX-MIN)
                                else
                                    if Approx_Res = 0 then
                                        o_data_reg(c + i*Input_Values) := unsigned_multiply_efficient(normalized_val, real(GLOBAL_MAX_VALUE)) / this_difference; -- the hard way, full resolution -- (val-min)*127/(max-min)
                                    else
                                        shift_difference :=  to_integer(shift_right(to_unsigned(this_difference,CNN_Value_Resolution), CNN_Value_Resolution-Approx_Res));
                                        o_data_reg(c + i*Input_Values) := unsigned_multiply_efficient(normalized_val, real(GLOBAL_MAX_VALUE)) / shift_difference; -- the hard way, Approx_Res resolution -- (val-min)*127/(max-min)
                                        o_data_reg(c + i*Input_Values) := to_integer(shift_right(to_unsigned(o_data_reg(c + i*Input_Values),2*CNN_Value_Resolution), CNN_Value_Resolution-Approx_Res));
                                        end if;
                                end if;
                            ELSIF Calc_Type = 1 THEN

                                -- shift left according to the log2 of the difference
                                o_data_reg(c + i*Input_Values) := to_integer(shift_left(to_unsigned(normalized_val,CNN_Value_Resolution), Shift_L_LookUp(this_difference)));
                                normalized_shi :=  o_data_reg(c + i*Input_Values);

                                -- shift-right-add according to approximation resolution and difference
                                for a in 0 to Approx_Res-1 loop
                                    if Shift_R_LookUp(this_difference, a) then
                                        o_data_reg(c + i*Input_Values) := o_data_reg(c + i*Input_Values) + to_integer(shift_right(to_unsigned(normalized_shi,2*CNN_Value_Resolution), a+1)); -- +1 because indexes start at 0
                                    end if;
                                end loop;
                                
                            END IF;
                            if o_data_reg(c + i*Input_Values) > GLOBAL_MAX_VALUE then
                                sel_o_data(c + i*Input_Values) := GLOBAL_MAX_VALUE; -- Ensure no overflow
                            else
                                sel_o_data(c + i*Input_Values) := o_data_reg(c + i*Input_Values); -- Store the normalized value
                            end if;
                        end if;

                    end loop;
                end loop;
            end if;

            
            if Use_Par_Bounds then
                max_value <= Par_Max;
                min_value <= Par_Min;
            else
                -- new image, so update max, min and difference
                if sel_stream.Column = 0 and sel_stream.Row = 0 and sel_stream.Data_Valid = '1' then
                    max_value <= temp_max;
                    min_value <= temp_min;
                    difference <= temp_max - temp_min;
                    temp_max := 0; -- Reset for next image
                    temp_min := GLOBAL_MAX_VALUE; -- Reset for next image
                end if;
            end if;

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
                oData_Reg              <= sel_o_data;
            ELSE
                oStream.Column     <= sel_stream.Column;
                oStream.Row        <= sel_stream.Row;
                oStream.Filter     <= sel_stream.Filter;
                oStream.Data_Valid <= sel_stream.Data_Valid;
                oData              <= sel_o_data;
            END IF;
        END IF;
    END PROCESS;
    
END BEHAVIORAL;