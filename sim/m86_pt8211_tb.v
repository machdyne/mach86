/*
 * Mach86 -- test bench for the PT8211 output (rtl/soc/m86_pt8211.v).
 * A receiver that knows only the DAC's rule -- DIN is taken on BCK's
 * rising edge, and the 16 bits before WS changes are a word -- must
 * get back the samples put in, one in each half of every frame, at
 * 48,000 frames a second of a 48 MHz clock, and BCK must never be
 * shorter than 15 cycles a half.
 */
`timescale 1ns / 1ps
module m86_pt8211_tb;
    reg aclk = 0, arst = 1;
    always #10.4167 aclk = ~aclk;
    reg signed [15:0] sample = 16'sh1234;
    wire bck, ws, din;
    m86_pt8211 dut (.aclk(aclk), .arst(arst), .sample(sample),
                    .bck(bck), .ws(ws), .din(din));

    integer cycles = 0, words = 0, bad = 0, frames = 0, run = 0, minrun = 1000;
    reg bck_d = 0, ws_d = 0;
    reg [15:0] rx = 0, sent = 16'h1234, sent_d = 16'h1234;
    integer nbits = 0;
    always @(posedge aclk) if (!arst) begin
        cycles = cycles + 1;
        bck_d <= bck; ws_d <= ws;
        if (bck != bck_d) begin
            if (run < minrun && cycles > 40) minrun = run;
            run = 1;
        end else
            run = run + 1;
        if (bck && !bck_d) begin            // rising: a bit
            rx = {rx[14:0], din};
            nbits = nbits + 1;
        end
        if (ws != ws_d) begin               // the word before this edge
            if (frames >= 2) begin
                words = words + 1;
                if (nbits != 16 || (rx !== sent && rx !== sent_d)) begin
                    bad = bad + 1;
                    if (bad < 5) $display("word %0d: %h after %0d bits, want %h or %h",
                                          words, rx, nbits, sent, sent_d);
                end
            end
            nbits = 0;
            if (!ws) begin                  // a frame done: a new sample
                frames = frames + 1;
                sent_d = sent;
                sent = sent * 16'd5 + 16'd12345;
                sample <= sent;
            end
        end
    end
    initial begin
        repeat (4) @(posedge aclk);
        arst = 0;
        repeat (100000) @(posedge aclk);
        $display("pt8211: %0d words, %0d bad, %0d frames in 100000 cycles, shortest half-BCK %0d cycles",
                 words, bad, frames, minrun);
        if (bad == 0 && words > 180 && frames >= 99 && frames <= 100 && minrun >= 15)
            $display("pt8211: pass");
        else
            $display("pt8211: FAIL");
        $finish;
    end
endmodule
