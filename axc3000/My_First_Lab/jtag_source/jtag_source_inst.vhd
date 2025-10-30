	component jtag_source is
		port (
			source : out std_logic_vector(1 downto 0)   -- source
		);
	end component jtag_source;

	u0 : component jtag_source
		port map (
			source => CONNECTED_TO_source  -- sources.source
		);

