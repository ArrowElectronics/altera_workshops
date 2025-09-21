
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
use work.CNN_Config_Package.all;
use IEEE.math_real.all;

ENTITY Threshold_Filter IS
    GENERIC (
        Input_Values       : NATURAL := 1;  --Number of Filters in previous layer or 3 for RGB input
        Input_Images       : NATURAL := 1;  --Number of input images (2 images and RGB: (2 downto 0) for image 1 and (5 downto 3) for image 2)
        En_In_Buffer       : BOOLEAN := TRUE; --Enable input buffer
        En_Out_Buffer      : BOOLEAN := TRUE; --Enable output buffer
        Max_Value          : CNN_Value_T := 2**(CNN_Value_Resolution-1)-1; -- Max value for normalization
        Threshold_Value    : CNN_Value_T := 2**(CNN_Value_Resolution-2); -- Threshold value (default: half of max value)
        Threshold_Value_2  : INTEGER range -1 to 2**(CNN_Value_Resolution-1)-1 := -1; -- Second threshold value for range checking (default: -1 = disabled)
        Threshold_Type     : Threshold_T := binary; -- Type of threshold operation
        Channel            : INTEGER := -1; -- Channel to apply threshold to (0-based) or -1 to use average across all channels
        Apply_All_Channels : BOOLEAN := FALSE -- Apply threshold result to all channels
    );
    PORT (
        iStream : IN  CNN_Stream_T;
        iData   : IN  CNN_Values_T((Input_Values*Input_Images)-1 downto 0);
        
        oStream : OUT CNN_Stream_T;
        oData   : OUT CNN_Values_T((Input_Values*Input_Images)-1 downto 0) := (others => 0)
    );
END Threshold_Filter;

ARCHITECTURE BEHAVIORAL OF Threshold_Filter IS

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
        VARIABLE channel_index : NATURAL range 0 to (Input_Values*Input_Images)-1;
        VARIABLE threshold_met : BOOLEAN;
        VARIABLE threshold_channel_value : CNN_Value_T;
        VARIABLE current_index : NATURAL range 0 to (Input_Values*Input_Images)-1;
        VARIABLE average_value : NATURAL range 0 to (2**(CNN_Value_Resolution)-1)*Input_Values;
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
            For img in 0 to Input_Images-1 loop
                -- Calculate threshold value for comparison
                if Channel = -1 then
                    -- Calculate average across all channels for this image
                    average_value := 0;
                    For c in 0 to Input_Values-1 loop
                        average_value := average_value + sel_data(img * Input_Values + c);
                    end loop;
                    -- Finalize average calculation using the same method as Reduce_To_Brightness Calc_Type = 1
                    average_value := unsigned_multiply_efficient(average_value, 1.0/real(Input_Values), CNN_Value_Resolution+integer(ceil(log2(real(Input_Values))))-1, CNN_Value_Resolution-1);
                    threshold_channel_value := average_value;
                else
                    -- Use specified channel
                    threshold_channel_value := sel_data(img * Input_Values + Channel);
                end if;

                -- Check if threshold is met
                if Threshold_Value_2 > -1 then
                    -- Range threshold: logical_and(value > threshold, value < threshold_2)
                    threshold_met := threshold_channel_value > Threshold_Value and 
                                    threshold_channel_value < CNN_Value_T(Threshold_Value_2);
                else
                    -- Single threshold: value > threshold
                    threshold_met := threshold_channel_value > Threshold_Value;
                end if;

                For ch in 0 to Input_Values-1 loop
                    -- Calculate the current data index
                    current_index := img * Input_Values + ch;
 
                    -- Apply threshold operation based on type
                    CASE Threshold_Type IS
                        WHEN binary =>
                            if threshold_met then
                                if Apply_All_Channels or Channel = -1 then
                                    sel_data(current_index) := Max_Value;
                                else
                                    -- Only apply to the threshold channel
                                    if ch = Channel then
                                        sel_data(current_index) := Max_Value;
                                    end if;
                                end if;
                            else
                                if Apply_All_Channels or Channel = -1 then
                                    sel_data(current_index) := 0;
                                else
                                    -- Only apply to the threshold channel
                                    if ch = Channel then
                                        sel_data(current_index) := 0;
                                    end if;
                                end if;
                            end if;
                            
                        WHEN tozero =>
                            if not threshold_met then
                                if Apply_All_Channels or Channel = -1 then
                                    sel_data(current_index) := 0;
                                else
                                    if ch = Channel then
                                        sel_data(current_index) := 0;
                                    end if;
                                end if;
                            end if;
                            -- If threshold is met, keep original value (no change needed)
                            
                        WHEN toone =>
                            if threshold_met then
                                if Apply_All_Channels or Channel = -1 then
                                    sel_data(current_index) := Max_Value;
                                else
                                    if ch = Channel then
                                        sel_data(current_index) := Max_Value;
                                    end if;
                                end if;
                            end if;
                            -- If threshold is not met, keep original value (no change needed)
                            
                        WHEN tozero_inv =>
                            if threshold_met then
                                if Apply_All_Channels or Channel = -1 then
                                    sel_data(current_index) := 0;
                                else
                                    if ch = Channel then
                                        sel_data(current_index) := 0;
                                    end if;
                                end if;
                            end if;
                            -- If threshold is not met, keep original value (no change needed)
                            
                        WHEN toone_inv =>
                            if not threshold_met then
                                if Apply_All_Channels or Channel = -1 then
                                    sel_data(current_index) := Max_Value;
                                else
                                    if ch = Channel then
                                        sel_data(current_index) := Max_Value;
                                    end if;
                                end if;
                            end if;
                            -- If threshold is met, keep original value (no change needed)
                            
                    END CASE;
                end loop;
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