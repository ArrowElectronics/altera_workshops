-- 
-- SPDX-FileCopyrightText: Copyright (C) 2025 Arrow Electronics, Inc. 
-- SPDX-License-Identifier: MIT-0 
--

library ieee;
use IEEE.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_signed.all;


entity AXC3_My_First_Lab is 
port (
clk: in std_logic;
reset : in std_logic;
updown: in std_logic;
LED : out std_logic_vector(2 downto 0)
);
end entity;

architecture rtl of AXC3_My_First_Lab  is

component pll is
		port (
			refclk   : in  std_logic := 'X'; -- clk
			rst      : in  std_logic := 'X'; -- reset
			outclk_0 : out std_logic         -- clk
		);
end component pll;

component counter is
	port (
		clock  : in  std_logic;                    
		updown : in  std_logic;                    
		q      : out std_logic_vector(23 downto 0)        
	);
end component counter;

component resetip is
	port (
		ninit_done : out std_logic   -- ninit_done.reset
	);
end component resetip;

--***** uncomment the next five lines of code if using board farm hardware
--component jtag_source is
--	port (
--		source : out std_logic_vector(1 downto 0)
--	);
end component jtag_source;
	
signal tempclk : std_logic;

signal count : std_logic_vector(23 downto 0);

signal ninit_done : std_logic;

signal system_reset : std_logic;
signal up_down : std_logic;	

--***** uncomment the next line of code if using board farm hardware
--signal jtag_src : std_logic_vector(1 downto 0);
				 
begin

LED(2 downto 0) <= count(23 downto 21);

u0: PLL port map
	(
	 refclk => clk,
	 rst => system_reset,
	 outclk_0 => tempclk
	);

u1: counter port map
	(
	 clock => tempclk,
	  updown => up_down,
	  q => count
	);
	
u3: resetip port map
	( 
	 ninit_done => ninit_done
	);

--***** uncomment the next two lines of code if using local hardware	
--system_reset <= ninit_done or (not reset);
--up_down <= updown;	

--***** uncomment the next six lines of code if using board farm hardware
--system_reset <= ninit_done or jtag_src(0);
--up_down <= jtag_src(1);	

--u4 : jtag_source	port map 
--	(
--	 source => jtag_src
--	);	  

end rtl;




		