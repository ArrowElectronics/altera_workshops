library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;
use work.CNN_Config_Package.ALL;
use work.CNN_Data_Package.ALL;
use work.Test_Data_Package.all;

ENTITY ONEAI_Simulation IS
END ONEAI_Simulation;

ARCHITECTURE behavior OF ONEAI_Simulation IS
    COMPONENT CNN
        PORT (
        iStream       : IN CNN_Stream_T;
        iData_1       : IN CNN_Values_T(2 downto 0);

        oStream_1     : OUT CNN_Stream_T;
        oData_1       : OUT CNN_Values_T(0 downto 0);
        oCycle_1      : OUT NATURAL
        );
    END COMPONENT;

    -- Clock Signal
    SIGNAL CLK : STD_LOGIC;

    --Signals for the CNN component
    SIGNAL iStream : CNN_Stream_T;
    SIGNAL iData_1 : CNN_Values_T(2 downto 0);

    SIGNAL oStream_1 : CNN_Stream_T;
    SIGNAL oData_1 : CNN_Values_T(0 downto 0);
    SIGNAL oCycle_1 : NATURAL;

    -- Clock period definition
    CONSTANT clk_period : time := 8 ns;

BEGIN

    -- Instantiate the CNN component
    uut: CNN
    PORT MAP (
        iStream => iStream,
        iData_1 => iData_1,
        oStream_1 => oStream_1,
        oData_1 => oData_1,
        oCycle_1 => oCycle_1
    );

    -- Clock process definitions
    clk_process :process
    begin
        CLK <= '0';
        wait for clk_period/2;
        CLK <= '1';
        wait for clk_period/2;
    end process;
    
    iStream.Data_CLK <= CLK;

    -- Stimulus process
    stim_proc: process
    begin
        for i in 0 to 3 loop
            -- Initialize inputs
            iStream.Data_Valid <= '0';
            iStream.Row <= 0;
            iStream.Column <= 0;
            iStream.Filter <= 0;
            iData_1(2 downto 0) <= (others => 0);
            
            -- Wait for global reset
            wait for 1000 ns;
            
            -- Apply test stimulus
            for row in 0 to 127 loop
                for col in 0 to 127 loop
                    
                    iStream.Data_Valid <= '1';
                    iStream.Row <= row;
                    iStream.Column <= col;
                    iStream.Filter <= 0;
                    iData_1(2 downto 0) <= Image_Example(row, col); -- Example data
                    wait for clk_period;
                    iStream.Data_Valid <= '0';
                    wait for clk_period;
                    
                    for j in 0 to 109 loop
                        wait for clk_period;
                    end loop;
                end loop;
            end loop;
            
        end loop;

        -- End simulation
        wait;
    end process;

END behavior;