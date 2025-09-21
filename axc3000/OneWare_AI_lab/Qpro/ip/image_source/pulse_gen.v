// -----------------------------------------------------------------------------
// Periodic pulse generator
// Generates a high pulse of PULSE_CYCLES clock cycles every PERIOD_CYCLES.
// Synthesizable Verilog-2001.
// -----------------------------------------------------------------------------
module pulse_gen #
(
    parameter integer PERIOD_CYCLES = 100, // total period in clk cycles
    parameter integer PULSE_CYCLES  = 1    // high time in clk cycles (<= PERIOD_CYCLES)
)
(
    input  wire clk,
    input  wire rst_n,     // async active-low reset
    input  wire enable,    // when low, output stays low and counter halts
    output reg  pulse_out  // periodic pulse
);

    // ceil(log2(N))
    function integer clog2;
        input integer value;
        integer i;
        begin
            value = value - 1;
            for (i = 0; value > 0; i = i + 1)
                value = value >> 1;
            clog2 = i;
        end
    endfunction

    localparam integer CNT_W = (PERIOD_CYCLES > 1) ? clog2(PERIOD_CYCLES) : 1;

    reg [CNT_W-1:0] cnt;

    // simple guard at elaboration time
    initial begin
        if (PULSE_CYCLES > PERIOD_CYCLES) begin
            $error("PULSE_CYCLES must be <= PERIOD_CYCLES");
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt       <= {CNT_W{1'b0}};
            pulse_out <= 1'b0;
        end else if (enable) begin
            if (cnt == PERIOD_CYCLES-1) begin
                cnt <= {CNT_W{1'b0}};
            end else begin
                cnt <= cnt + {{(CNT_W-1){1'b0}}, 1'b1};
            end
            pulse_out <= (cnt < PULSE_CYCLES);
        end else begin
            pulse_out <= 1'b0;
        end
    end
endmodule