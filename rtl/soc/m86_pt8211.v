/*
 * Mach86 SoC -- sound out through a PT8211 (or TM8211) DAC, as the
 * Mozart boards have: three wires, BCK, WS and DIN, 16 bits a
 * channel, least-significant-bit justified.
 *
 * A frame is 32 periods of BCK, 16 while WS is low and 16 while it is
 * high. With exactly 16 bits a half, "LSB justified" comes to: the
 * word starts straight after WS changes, most significant bit first.
 * The DAC takes DIN on BCK's rising edge, so DIN changes on the
 * falling one. Both channels get the same sample (the machine's sound
 * is mono), which also makes it not matter which half the DAC calls
 * left.
 *
 * The clock is the sound's 48 MHz, and a frame 1,000 cycles of it
 * (48,000 frames a second): 64 half-periods of BCK, of 15 or 16
 * cycles each, counted off by an accumulator so that there are
 * exactly 64 in every 1,000 cycles.
 *
 * NOT RUN ON A BOARD. The scheme is Zeitlos's (rtl/audio_out.v), which
 * is.
 */
module m86_pt8211 (
    input  wire               aclk,     // 48 MHz
    input  wire               arst,
    input  wire signed [15:0] sample,   // may change at any time; taken once a frame
    output wire               bck,
    output wire               ws,
    output wire               din
);
    reg [9:0]  acc = 10'd0;             // + 64 a cycle, modulo 1,000
    wire [10:0] sum = {1'b0, acc} + 11'd64;
    wire       slot = (sum >= 11'd1000);
    reg [5:0]  phase = 6'd0;            // 64 half-periods a frame
    reg [15:0] hold = 16'd0, sr = 16'd0;
    assign bck = phase[0];
    assign ws  = phase[5];
    assign din = sr[15];
    always @(posedge aclk) begin
        if (arst) begin
            acc <= 10'd0; phase <= 6'd0; hold <= 16'd0; sr <= 16'd0;
        end else begin
            acc <= slot ? sum[9:0] - 10'd1000 : sum[9:0];
            if (slot) begin
                phase <= phase + 6'd1;
                if (phase == 6'd62)
                    hold <= sample;
                // phase[0] set: BCK falls now, and DIN may move.
                if (phase[0]) begin
                    if (phase[4:0] == 5'd31)
                        sr <= hold;                 // a new half: the word again
                    else
                        sr <= {sr[14:0], 1'b0};
                end
            end
        end
    end
endmodule
