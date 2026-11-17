/*
 * Mach86 SoC -- the PC speaker as digital audio.
 *
 * The speaker of a PC is one bit: the timer's channel 2 output and a
 * bit of port 61h, into a small cone that cannot follow anything fast.
 * Here the bit becomes 48,000 samples a second for a digital output
 * (S/PDIF on Sergei, through Zeitlos's transmitter):
 *
 *   - a sample is the part of its 1/48000 s the bit was high: exactly
 *     1,000 cycles of the 48 MHz clock, counted. That averages away
 *     what is too fast to hear, as the cone does, and it is what makes
 *     the trick of playing recorded sound through the speaker (the
 *     bit switched at 16 kHz and up with varying width) come out as
 *     sound;
 *   - the level that does not change is taken out (a speaker held high
 *     is silent): y = x - x' + y' - y'/256, which passes everything
 *     above 30 Hz;
 *   - a full-scale square wave comes out at a quarter of full scale.
 *
 * It also makes the two strobes Zeitlos's S/PDIF transmitter wants:
 * tick, 128 times a sample (7 or 8 clocks apart: 48 MHz * 128 / 1000),
 * and frame_req once a sample.
 *
 * All on aclk, which must be 48 MHz; spk comes from the CPU's clock
 * and is synchronised here.
 */
module m86_spk (
    input  wire        aclk,
    input  wire        arst,
    input  wire        spk,
    output wire        tick,
    output reg         frame_req,
    output reg  signed [15:0] sample
);
    // 128 ticks in 1,000 clocks.
    reg  [9:0]  acc;
    wire [10:0] sum = {1'b0, acc} + 11'd128;
    assign tick = (sum >= 11'd1000);
    reg  [6:0]  tcount;

    reg  [2:0]  s;                  // spk, synchronised
    reg  [9:0]  high;               // clocks high in this sample, to 1,000
    reg  signed [17:0] y;
    reg  [13:0] x1;

    wire [13:0] x = {1'b0, high, 3'b000};       // 0 to 8,000
    // x - x1 + y - y/256, kept within 18 bits (it cannot leave +-16,000).
    wire signed [17:0] dx = $signed({4'b0000, x}) - $signed({4'b0000, x1});
    // (The leak is never nothing, so that y ends at zero.)
    wire signed [17:0] leak = (y >>> 8) + ((y > 18'sd0) ? 18'sd1 : 18'sd0);
    wire signed [17:0] yn = dx + y - leak;

    always @(posedge aclk) begin
        s <= {s[1:0], spk};
        frame_req <= 1'b0;
        acc <= tick ? sum[9:0] - 10'd1000 : sum[9:0];
        if (s[2] && high != 10'd1000)
            high <= high + 10'd1;
        if (tick) begin
            tcount <= tcount + 7'd1;
            if (tcount == 7'd127) begin
                x1 <= x;
                y  <= yn;
                sample <= yn[15:0];
                frame_req <= 1'b1;
                high <= {9'd0, s[2]};
            end
        end
        if (arst) begin
            acc <= 10'd0; tcount <= 7'd0; high <= 10'd0;
            y <= 18'sd0; x1 <= 14'd0; sample <= 16'sd0; frame_req <= 1'b0;
        end
    end
endmodule
