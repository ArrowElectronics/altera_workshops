// image_source.v
// Avalon-MM subordinate: 1-bit software PIO with IRQ; IRQ can be triggered by PIO or external interrupt receiver.
// Address map (word-aligned, 32-bit):
//   0x0 DATA        [bit0] RW  — software PIO bit
//   0x1 IRQ_EN      [bit1:0] RW  — enable bits: [0]=PIO source, [1]=EXT source
//   0x2 IRQ_STATUS  [bit1:0] W1C — pending bits: [0]=PIO edge, [1]=EXT edge; write 1 to clear
//
// IRQ output = (IRQ_EN[0] & IRQ_STATUS[0]) | (IRQ_EN[1] & IRQ_STATUS[1])
// PIO source: rising edge of DATA write 0->1 latches STATUS[0].
// EXT source: rising edge detected on irq_in (synchronized) latches STATUS[1].

`timescale 1ns/1ps
module image_source
(
    input  wire        clk,
    input  wire        reset_n,

    // Avalon-MM subordinate
    input  wire  [1:0] s0_address,
    input  wire        s0_write,
    input  wire        s0_read,
    input  wire        s0_chipselect,
    input  wire [31:0] s0_writedata,
    input  wire  [3:0] s0_byteenable,
    output reg  [31:0] s0_readdata,

    // Interrupt sender (to CPU/irq_mapper)
    output wire        irq,

    // Interrupt receiver (external interrupt into this block)
    input  wire        irq_in
);

    // Registers
    reg        pio_bit, pio_bit_q;
    reg  [1:0] irq_en;       // [0]=PIO, [1]=EXT
    reg  [1:0] irq_status;   // [0]=PIO pending, [1]=EXT pending
	
	wire pg;

    // Avalon helpers
    wire cs_w = s0_chipselect & s0_write;
    wire cs_r = s0_chipselect & s0_read;

    // Readback
    always @(*) begin
        case (s0_address)
            2'd0: s0_readdata = {31'd0, pio_bit};
            2'd1: s0_readdata = {30'd0, irq_en};
            2'd2: s0_readdata = {30'd0, irq_status};
            default: s0_readdata = 32'd0;
        endcase
    end

    // irq_in synchronizer + edge detect
    reg ext_meta, ext_sync, ext_q;
    wire ext_rise = (~ext_q) & ext_sync;

    // Write + IRQ generation
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            pio_bit     <= 1'b0;
            pio_bit_q   <= 1'b0;
            irq_en      <= 2'b00;
            irq_status  <= 2'b00;
            ext_meta    <= 1'b0;
            ext_sync    <= 1'b0;
            ext_q       <= 1'b0;
        end else begin
            // Synchronize external interrupt input
            ext_meta <= irq_in;
            ext_sync <= ext_meta;
            ext_q    <= ext_sync;

            // History for PIO edge
            pio_bit_q <= pg;

            // Writes
            if (cs_w) begin
                case (s0_address)
                    2'd0: if (s0_byteenable[0]) pio_bit <= s0_writedata[0];
                    2'd1: if (s0_byteenable[0]) irq_en  <= s0_writedata[1:0];
                    2'd2: if (s0_byteenable[0]) irq_status <= irq_status & ~s0_writedata[1:0]; // W1C for bits 1:0
                    default: ;
                endcase
            end

            // Set status on rising edges (independent of enables)
            if ((!pio_bit_q) && pg)        		 irq_status[0] <= 1'b1; // PIO 0->1
            if (ext_rise)                        irq_status[1] <= 1'b1; // EXT 0->1
        end
    end
	
    pulse_gen #(
        .PERIOD_CYCLES(2000000),
        .PULSE_CYCLES (1000000)
    ) u_pg_a (
        .clk(clk),
        .rst_n(reset_n),
        .enable(1'b1),
        .pulse_out(pg)
    );	

    // IRQ output: OR of enabled pending sources
    assign irq = (irq_en[0] & pg) | (irq_en[1] & irq_in);
	

endmodule
