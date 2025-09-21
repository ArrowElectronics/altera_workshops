-- ==============================================================================
-- Place ONE_AI_Interface_hw.tcl next to qpf file and move other generated files
-- and folders in folder "one_ai" so the paths in the tcl file like 
-- "one_ai/Quartus_IP/ONE_AI_Interface.vhd" are correct
-- ==============================================================================
--
-- AI Interface: Reads 128x128 RGB pixels from fixed buffer
-- Pixel packing: 3 bytes per pixel (RGB), packed in 32-bit words
-- Word pattern: Word0: R0 G0 B0 R1, Word1: G1 B1 R2 G2, Word2: B2 R3 G3 B3, repeat...
--
-- ==============================================================================
-- UNIVERSAL AI INTERFACE DOCUMENTATION
-- ==============================================================================
--
-- OVERVIEW:
-- This module provides a universal interface for AI/CNN inference systems. It reads
-- 128x128 RGB image data from memory, processes it through a CNN component, and
-- provides results via a flexible Avalon-MM slave interface.
--
-- MAIN FEATURES:
-- - Image reading from fixed buffer with automatic pixel unpacking
-- - CNN integration with configurable dimensions (height, width, objects, classes)
-- - Universal register interface supporting multiple addressing methods
-- - Frame synchronization with interrupt-driven processing
-- - Hardware-optimized pixel format conversion (8-bit to 7-bit)
--
-- REGISTER MAP:
-- Address Range | Description                    | Access | Format
-- --------------|--------------------------------|--------|------------------
-- 0x00          | New Image Ready Flag           | R      | [0] = ready flag
-- 0x01          | Number of Outputs              | R/W    | 32-bit count
-- 0x02          | FPS (Frames Per Second)        | R      | 32-bit value
-- 0x03          | Single Output Read             | R      | 32-bit CNN value
-- 0x04          | Auto-Increment Output Read     | R      | 32-bit CNN value
-- 0x10-0x1F     | Width & Height Control         | R/W    | [31:16]=H, [15:0]=W
-- 0x20-0x2F     | Objects & Classes Control      | R/W    | [31:16]=C, [15:0]=O
-- 0x30-0x3F     | Output Dimensions (Width/Height)| R     | [31:16]=H, [15:0]=W
-- 0x40-0x4F     | Output Dimensions (Obj/Classes)| R      | [31:16]=C, [15:0]=O
--
-- CNN OUTPUT READING METHODS:
-- Method 1 - Targeted Read:
--   1. Write class offset to 0x20: IOWR(base+0x20, (class_index << 16))
--   2. Read single value from 0x03: value = IORD(base+0x03)
--
-- Method 2 - Sequential Auto-Increment:
--   1. Reset position to 0x20: IOWR(base+0x20, 0)
--   2. Read multiple times from 0x04: for(i=0; i<10; i++) values[i] = IORD(base+0x04)
--
-- INTERFACE TIMING:
-- - Clock Domain: Single clock domain (clk)
-- - Reset: Active-low asynchronous reset (reset_n)
-- - Frame IRQ: Rising edge detection on frame_writer_irq
-- - CNN Processing: Pipelined with automatic result storage
--
-- DEPENDENCIES:
-- - CNN_Config_Package: Defines CNN_Stream_T, CNN_Values_T types
-- - CNN_Data_Package: Defines CNN_Value_T and related constants
-- - CNN Component: Actual neural network implementation
--
-- ==============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.CNN_Config_Package.all;
use work.CNN_Data_Package.all;

entity ONE_AI_Interface is
  generic (
    BUFFER_BASE_ADDR : std_logic_vector(31 downto 0) := x"00080000"  -- Default 0x80000, configurable in Platform Designer
  );
  port (
    clk              : in  std_logic;
    reset_n          : in  std_logic;

    -- Avalon-MM Master (read from On-Chip RAM)
    avm_address      : out std_logic_vector(31 downto 0) := (others => '0');
    avm_read         : buffer std_logic := '0';
    avm_readdata     : in  std_logic_vector(31 downto 0);
    avm_waitrequest  : in  std_logic;

    -- Avalon-MM Slave (Universal interface)
    avs_address      : in  std_logic_vector(7 downto 0);
    avs_read         : in  std_logic;
    avs_write        : in  std_logic;
    avs_writedata    : in  std_logic_vector(31 downto 0);
    avs_readdata     : out std_logic_vector(31 downto 0) := (others => '0');

    -- Interrupt from Frame Writer (new frame available)
    frame_writer_irq : in std_logic
  );
end ONE_AI_Interface;

architecture rtl of ONE_AI_Interface is

  -- Buffer address from generic (configurable in Platform Designer)
  constant BUFFER_ADDR : unsigned(31 downto 0) := unsigned(BUFFER_BASE_ADDR);

  -- Image constants (128x128 RGB)
  constant FRAME_WIDTH : integer := 128;
  constant FRAME_HEIGHT : integer := 128;
  constant FRAME_SIZE : integer := FRAME_WIDTH * FRAME_HEIGHT; 

  -- counter for slower pixel output
  signal cycle_counter : natural range 0 to 112-5 := 0;
  constant PIXEL_DELAY_CYCLES : natural := 112-5;  -- 112 cycles in total per pixel

  -- Universal interface configuration  
  constant OUTPUTS     : natural := 1;  -- Number of different outputs
  constant MAX_HEIGHT  : natural := 1;  -- Maximum height per output
  constant MAX_WIDTH   : natural := 1;  -- Maximum width per output
  constant MAX_OBJECTS : natural := 1;  -- Maximum objects per cell
  constant MAX_CLASSES : natural := 10; -- Maximum classes per object 

  type output_range_t is record
    Max_Height  : natural range 0 to MAX_HEIGHT;
    Max_Width   : natural range 0 to MAX_WIDTH;
    Max_Objects : natural range 0 to MAX_OBJECTS;
    Max_Classes : natural range 0 to MAX_CLASSES;
  end record;

  type output_dimensions_array is array (natural range <>) of output_range_t;
  constant OUTPUT_DIMENSIONS : output_dimensions_array(0 to OUTPUTS-1) := (0 => (1, 1, 1, 10));

  constant FPS : natural := 62;        -- Frames per second read from RAM

  constant LAST_PIXEL : unsigned(13 downto 0) := to_unsigned(FRAME_SIZE - 1, 14);
  
  -- FSM States
  type state_type is (idle_state, read_word_state, extract_pixel_state, pixel_delay_state);
  signal state : state_type := idle_state;

  -- Pixel and address counters
  signal pixel_addr    : unsigned(13 downto 0) := (others => '0');
  signal frame_counter : unsigned(23 downto 0) := (others => '0');
  signal word_addr     : unsigned(31 downto 0) := (others => '0');
  
  -- Current word and cached bytes
  signal current_word : std_logic_vector(31 downto 0) := (others => '0');
  signal cached_r : std_logic_vector(7 downto 0) := (others => '0');
  signal cached_g : std_logic_vector(7 downto 0) := (others => '0');
  signal cached_b : std_logic_vector(7 downto 0) := (others => '0');
  
  -- Cache state: 0=none, 1=have_r, 2=have_rg, 3=have_rgb
  signal cache_state : unsigned(1 downto 0) := (others => '0');
  
  -- Pixel data (internal signals for image processing)
  signal pixel_r_reg, pixel_g_reg, pixel_b_reg : std_logic_vector(7 downto 0) := (others => '0');

  -- Pixel position and output (internal signals for image processing)
  signal pixel_column : natural range 0 to FRAME_WIDTH-1 := 0;
  signal pixel_row    : natural range 0 to FRAME_HEIGHT-1 := 0;
  signal pixel_r      : natural range 0 to 127 := 0;  -- 7-bit values (0-127)
  signal pixel_g      : natural range 0 to 127 := 0;  -- 7-bit values (0-127)
  signal pixel_b      : natural range 0 to 127 := 0;  -- 7-bit values (0-127)
  signal pixel_valid  : std_logic := '0';

  -- Interrupt handling
  signal frame_writer_irq_d  : std_logic := '0';
  signal new_frame_available : std_logic := '0';

  COMPONENT CNN IS
    PORT (
                iStream       : IN CNN_Stream_T;
        iData_1       : IN CNN_Values_T(2 downto 0);
        
        oStream_1     : OUT CNN_Stream_T;
        oData_1       : OUT CNN_Values_T(0 downto 0);
        oCycle_1      : OUT NATURAL
    );
  END COMPONENT;
  
      SIGNAL iStream : CNN_Stream_T;
    SIGNAL iData_1 : CNN_Values_T(2 downto 0);

      SIGNAL oStream_1 : CNN_Stream_T;
    SIGNAL oData_1 : CNN_Values_T(0 downto 0);
    SIGNAL oCycle_1 : NATURAL;


  type output_position_t is record
    Current_Height  : natural range 0 to MAX_HEIGHT-1;
    Current_Width   : natural range 0 to MAX_WIDTH-1;
    Current_Objects : natural range 0 to MAX_OBJECTS-1;
    Current_Classes : natural range 0 to MAX_CLASSES-1;
  end record;

  signal current_output          : natural range 0 to OUTPUTS-1 := 0;   -- Current output index
  signal current_output_position : output_position_t := (others => 0);  -- Current position to read from
  signal current_user_position   : output_position_t := (others => 0);  -- Current user defined offset

  -- Storage array for outputs (4D structure for universal addressing)
  type output_data_array is array (natural range <>, natural range <>, natural range <>, natural range <>) of CNN_Value_T;
  signal output_data : output_data_array(0 to OUTPUT_DIMENSIONS(0).Max_Height-1, 0 to OUTPUT_DIMENSIONS(0).Max_Width-1, 0 to OUTPUT_DIMENSIONS(0).Max_Objects-1, 0 to OUTPUT_DIMENSIONS(0).Max_Classes-1) := (others => (others => (others => (others => 0))));
  
  -- Sequential read offset for 0x30-0xFF range (208 values)
  signal read_offset : integer range 0 to 207 := 0;
  
  -- Status signals
  signal new_image_ready : std_logic := '0';
  signal new_image_read  : std_logic := '0';

begin

    CNN_1: CNN
    PORT MAP (
        iStream => iStream,
        iData_1 => iData_1,
        oStream_1 => oStream_1,
        oData_1 => oData_1,
        oCycle_1 => oCycle_1
    );
	 
  iStream.Data_CLK   <= clk;
  iStream.Data_Valid <= pixel_valid;
  iStream.Column     <= pixel_column;
  iStream.Row        <= pixel_row;
  iStream.Filter     <= 0;
  iData_1(0)           <= pixel_r;  -- Already 7-bit values (0-127)
  iData_1(1)           <= pixel_g;  -- Already 7-bit values (0-127)
  iData_1(2)           <= pixel_b;  -- Already 7-bit values (0-127)
  
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        -- Initialize output data
        output_data <= (others => (others => (others => (others => 0))));
        new_image_ready <= '0';
      else
        if new_image_read = '1' then
          -- Reset new image ready flag after reading
          new_image_ready <= '0';
        end if;

        if oStream_1.Data_Valid = '1' then
          -- Store CNN output data in 4D array (height=0, width=0, objects=0, classes=oCycle_1)
          if oCycle_1 < OUTPUT_DIMENSIONS(0).Max_Classes then
            output_data(0, 0, 0, oCycle_1) <= oData_1(0);
          end if;

          if oCycle_1 = OUTPUT_DIMENSIONS(0).Max_Classes - 1 then
            -- Signal that new image is ready for processing
            new_image_ready <= '1';
          end if;
        end if;
      end if;
    end if;
  end process;
  
  -- Interrupt detection (Frame Writer IRQ)
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        frame_counter <= (others => '0');
        frame_writer_irq_d <= '0';
        new_frame_available <= '0';
      else
        frame_writer_irq_d <= frame_writer_irq;
        
        -- Rising edge of Frame Writer IRQ
        if frame_writer_irq = '1' and frame_writer_irq_d = '0' then
          if frame_counter < x"FFFFFF" then
            -- Increment frame counter, wrap around at max value
            frame_counter <= frame_counter + 1;
          else
            frame_counter <= (others => '0');  -- Reset on overflow
          end if;
          new_frame_available <= '1';
        end if;
        
        -- Clear flag when frame reading starts
        if state = read_word_state and pixel_addr = 0 then
          new_frame_available <= '0';
        end if;
      end if;
    end if;
  end process;

  -- Main FSM for pixel reading with proper packing logic
  process(clk)
    variable current_column : natural range 0 to FRAME_WIDTH-1;
    variable current_row    : natural range 0 to FRAME_HEIGHT-1;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        avm_read     <= '0';
        avm_address  <= (others => '0');
        pixel_addr   <= (others => '0');
        word_addr    <= (others => '0');
        current_word <= (others => '0');
        cached_r     <= (others => '0');
        cached_g     <= (others => '0');
        cached_b     <= (others => '0');
        cache_state  <= (others => '0');
        pixel_r_reg  <= (others => '0');
        pixel_g_reg  <= (others => '0');
        pixel_b_reg  <= (others => '0');
        cycle_counter <= 0;
        pixel_r      <= 0;
        pixel_g      <= 0;
        pixel_b      <= 0;
        pixel_column <= 0;
        pixel_row    <= 0;
        pixel_valid  <= '0';
        state        <= idle_state;
      else
        -- Default: pixel_valid stays 0, unless explicitly set
        pixel_valid <= '0';
        
        case state is
          when idle_state =>
            -- Wait for new frame
            if new_frame_available = '1' then
              pixel_addr <= (others => '0');
              cycle_counter <= 0;
              cache_state <= (others => '0');
              
              -- Start with first word
              word_addr <= BUFFER_ADDR;
              avm_address <= std_logic_vector(BUFFER_ADDR);
              avm_read <= '1';
              state <= read_word_state;
            end if;

          when read_word_state =>
            if avm_waitrequest = '0' then
              avm_read      <= '0';
              current_word  <= avm_readdata;
            end if;
            if avm_read = '0' then
              state <= extract_pixel_state;
            end if;

          when extract_pixel_state =>
            -- Extract current pixel based on cache state
            case to_integer(cache_state) is
              when 0 =>
                -- No cache: extract RGB from current word and cache R for next
                pixel_r_reg <= current_word(7 downto 0);   -- R0
                pixel_g_reg <= current_word(15 downto 8);  -- G0  
                pixel_b_reg <= current_word(23 downto 16); -- B0
                cached_r <= current_word(31 downto 24);    -- R1 for next pixel
                cache_state <= "01";  -- Have R
              when 1 =>
                -- Have cached R: use it, extract GB from current word, cache RG for next
                pixel_r_reg <= cached_r;                   -- R1 (cached)
                pixel_g_reg <= current_word(7 downto 0);   -- G1
                pixel_b_reg <= current_word(15 downto 8);  -- B1
                cached_r <= current_word(23 downto 16);    -- R2 for next pixel
                cached_g <= current_word(31 downto 24);    -- G2 for next pixel
                cache_state <= "10";  -- Have RG
              when 2 =>
                -- Have cached RG: use them, extract B from current word, cache RGB for next
                pixel_r_reg <= cached_r;                   -- R2 (cached)
                pixel_g_reg <= cached_g;                   -- G2 (cached)
                pixel_b_reg <= current_word(7 downto 0);   -- B2
                cached_r <= current_word(15 downto 8);     -- R3 for next pixel
                cached_g <= current_word(23 downto 16);    -- G3 for next pixel
                cached_b <= current_word(31 downto 24);    -- B3 for next pixel
                cache_state <= "11";  -- Have RGB
              when 3 =>
                -- Have cached RGB: use them, no read needed, reset cache
                pixel_r_reg <= cached_r;                   -- R3 (cached)
                pixel_g_reg <= cached_g;                   -- G3 (cached)
                pixel_b_reg <= cached_b;                   -- B3 (cached)
                cache_state <= "00";  -- No cache
              when others =>
                cache_state <= "00";
            end case;
            
            -- Calculate pixel position
            current_column := to_integer(pixel_addr mod FRAME_WIDTH);
            current_row := to_integer(pixel_addr / FRAME_WIDTH);
            pixel_column <= current_column;
            pixel_row <= current_row;
            
            cycle_counter <= 0;
            state <= pixel_delay_state;

          when pixel_delay_state =>
            -- Wait 112 cycles, then output pixel data
            if cycle_counter >= PIXEL_DELAY_CYCLES then
              -- Transfer pixel data to output signals after 112 cycles (convert to 7-bit)
              pixel_r <= to_integer(unsigned(pixel_r_reg(7 downto 1)));  -- Convert 8-bit to 7-bit via bit shift
              pixel_g <= to_integer(unsigned(pixel_g_reg(7 downto 1)));  -- Convert 8-bit to 7-bit via bit shift
              pixel_b <= to_integer(unsigned(pixel_b_reg(7 downto 1)));  -- Convert 8-bit to 7-bit via bit shift
              pixel_valid <= '1';
              
              -- Check if frame complete
              if pixel_addr = LAST_PIXEL then
                state <= idle_state;
                -- Frame completed - no need to increment fps_counter as FPS is now constant
              else
                pixel_addr <= pixel_addr + 1;
                
                -- Decide if we need to read next word
                if cache_state = "11" then
                  -- We have cached RGB, no read needed
                  state <= extract_pixel_state;
                else
                  -- Need to read next word
                  word_addr <= word_addr + 4;
                  avm_address <= std_logic_vector(word_addr + 4);
                  avm_read <= '1';
                  state <= read_word_state;
                end if;
              end if;
            else
              -- Increment cycle counter
              cycle_counter <= cycle_counter + 1;
            end if;

          when others =>
            state <= idle_state;
        end case;
      end if;
    end if;
  end process;

   -- Universal Avalon-MM Slave interface
  process(clk)
    variable addr_int : integer range 0 to 255 := 0;
    variable total_values : integer range 0 to MAX_HEIGHT * MAX_WIDTH * MAX_OBJECTS * MAX_CLASSES := 0;
    variable h : integer range 0 to MAX_HEIGHT-1 := 0;
    variable w : integer range 0 to MAX_WIDTH-1 := 0;
    variable o : integer range 0 to MAX_OBJECTS-1 := 0;
    variable c : integer range 0 to MAX_CLASSES-1 := 0;
    variable linear_index : integer range 0 to MAX_HEIGHT * MAX_WIDTH * MAX_OBJECTS * MAX_CLASSES := 0;
    variable avs_read_reg : std_logic := '0';
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        avs_readdata <= (others => '0');
        read_offset <= 0;
        current_output <= 0;
        current_output_position <= (others => 0);
        current_user_position <= (others => 0);
      else
        -- Default readdata to prevent X values
        avs_readdata <= (others => '0');
        
        -- Handle writes
        if avs_write = '1' then
          addr_int := to_integer(unsigned(avs_address));
          case addr_int is
            when 1 =>
              -- Write: Output to read from
              if to_integer(unsigned(avs_writedata)) < OUTPUTS then
                current_output <= to_integer(unsigned(avs_writedata));
              end if;
            when 16 to 31 =>
              -- Write: Width & Height of Value to read from (0x10-0x1F)
              current_user_position.Current_Width <= to_integer(unsigned(avs_writedata(15 downto 0)));
              current_user_position.Current_Height <= to_integer(unsigned(avs_writedata(31 downto 16)));
            when 32 to 47 =>
              -- Write: Objects & Classes to read from (0x20-0x2F)
              current_user_position.Current_Objects <= to_integer(unsigned(avs_writedata(15 downto 0)));
              current_user_position.Current_Classes <= to_integer(unsigned(avs_writedata(31 downto 16)));
            when others =>
              null;
          end case;
        end if;

        new_image_read <= '0';  -- Reset read flag
        
        -- Handle reads
        if avs_read = '1' then
          addr_int := to_integer(unsigned(avs_address));
          case addr_int is
            when 0 =>
              -- Read: New Image Ready
              avs_readdata <= (31 downto 1 => '0') & new_image_ready;
              new_image_read <= '1';  -- Clear flag after reading
            when 1 =>
              -- Read: Outputs count
              avs_readdata <= std_logic_vector(to_unsigned(OUTPUTS, 32));
            when 2 =>
              -- Read: FPS
              avs_readdata <= std_logic_vector(to_unsigned(FPS, 32));
            when 3 =>
              if current_output = 0 then
                -- Read from output_data array
                avs_readdata <= std_logic_vector(to_unsigned(output_data(current_user_position.Current_Height, current_user_position.Current_Width, current_user_position.Current_Objects, current_user_position.Current_Classes), 32));
              else
                -- For other outputs, return zero (or handle differently if needed)
                avs_readdata <= (others => '0');
              end if;
            when 4 =>
              if current_output = 0 then
                -- Read from output_data array
                avs_readdata <= std_logic_vector(to_unsigned(output_data(current_user_position.Current_Height, current_user_position.Current_Width, current_user_position.Current_Objects, current_user_position.Current_Classes), 32));
              else
                -- For other outputs, return zero (or handle differently if needed)
                avs_readdata <= (others => '0');
              end if;

              if avs_read_reg = '0' then
                if current_user_position.Current_Classes < OUTPUT_DIMENSIONS(current_output).Max_Classes - 1 then
                  -- Increment class index for next read
                  current_user_position.Current_Classes <= current_user_position.Current_Classes + 1;
                else
                  -- Reset to first class and increment object index
                  current_user_position.Current_Classes <= 0;
                  if current_user_position.Current_Objects < OUTPUT_DIMENSIONS(current_output).Max_Objects - 1 then
                    current_user_position.Current_Objects <= current_user_position.Current_Objects + 1;
                  else
                    -- Reset objects and increment width
                    current_user_position.Current_Objects <= 0;
                    if current_user_position.Current_Width < OUTPUT_DIMENSIONS(current_output).Max_Width - 1 then
                      current_user_position.Current_Width <= current_user_position.Current_Width + 1;
                    else
                      -- Reset width and increment height
                      current_user_position.Current_Width <= 0;
                      if current_user_position.Current_Height < OUTPUT_DIMENSIONS(current_output).Max_Height - 1 then
                        current_user_position.Current_Height <= current_user_position.Current_Height + 1;
                      else
                        -- Reset height to zero (end of read cycle)
                        current_user_position.Current_Height <= 0;
                      end if;
                    end if;
                  end if;
                end if;

                avs_read_reg := '1';  -- Set read flag to prevent immediate re-read
              end if;

            when 16 to 31 =>
              -- Read: Width & Height of Value to read from (0x10-0x1F)
              addr_int := addr_int - 16;
              if addr_int < OUTPUTS then
                avs_readdata <= std_logic_vector(to_unsigned(current_user_position.Current_Width, 16)) & 
                               std_logic_vector(to_unsigned(current_user_position.Current_Height, 16));
              end if;
            when 32 to 47 =>
              -- Read: Objects & Classes to read from (0x20-0x2F)
              addr_int := addr_int - 32;
              if addr_int < OUTPUTS then
                avs_readdata <= std_logic_vector(to_unsigned(current_user_position.Current_Objects, 16)) & 
                               std_logic_vector(to_unsigned(current_user_position.Current_Classes, 16));
              end if;
            when 48 to 63 =>
              -- Read: Widths & Heights (of Outputs 1-16) (2x 16bit) (0x10-0x1F)
              addr_int := addr_int - 48;
              if addr_int < OUTPUTS then
                avs_readdata <= std_logic_vector(to_unsigned(OUTPUT_DIMENSIONS(addr_int).Max_Height, 16)) & 
                               std_logic_vector(to_unsigned(OUTPUT_DIMENSIONS(addr_int).Max_Width, 16));
              end if;
            when 64 to 79 =>
              -- Read: Objects & Classes (of Outputs 1-16) (2x 16bit) (0x20-0x2F)
              addr_int := addr_int - 64;
              if addr_int < OUTPUTS then
                avs_readdata <= std_logic_vector(to_unsigned(OUTPUT_DIMENSIONS(addr_int).Max_Classes, 16)) & 
                               std_logic_vector(to_unsigned(OUTPUT_DIMENSIONS(addr_int).Max_Objects, 16));
              end if;
            when others =>
              avs_readdata <= (others => '0');
          end case;
        else
          avs_read_reg := '0';  -- Reset read flag when not reading
        end if;
      end if;
    end if;
  end process;

end rtl;
