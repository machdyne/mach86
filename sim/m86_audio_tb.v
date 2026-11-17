/*
 * Mach86 -- test bench for a board's sound (rtl/soc/m86_audio.v): the
 * speaker and the AdLib into one sample, and the sigma-delta output.
 *
 *   1. Speaker alone at 1 kHz, then an AdLib note with it: the sum
 *      must swing further than either.
 *   2. The one-bit output, averaged over each sample's 1,000 clocks
 *      and scaled, must follow the samples: that is all a resistor
 *      and a capacitor do with it.
 */
`timescale 1ns / 1ps
module m86_audio_tb;
    reg clk = 0, rst = 1, spk = 0, we = 0;
    reg [7:0] wa = 0, wd = 0;
    always #10.416667 clk = ~clk;
    wire tick, frame_req, sd_l, sd_r;
    wire signed [15:0] sample;
    m86_audio #(.OPLROM("../output/opl/opl_rom.hex")) dut (
        .clk(clk), .opl_we(we), .opl_a(wa), .opl_d(wd), .spk(spk),
        .aclk(clk), .arst(rst), .tick(tick), .frame_req(frame_req),
        .sample(sample), .sd_l(sd_l), .sd_r(sd_r));

    integer errors = 0;
    task check(input cond, input [8*48-1:0] what);
        if (!cond) begin errors = errors + 1; $display("FAIL: %0s", what); end
    endtask
    task opl(input [7:0] a, input [7:0] d);
        begin
            @(posedge clk); we <= 1; wa <= a; wd <= d;
            @(posedge clk); we <= 0;
        end
    endtask

    // The speaker, all the time.
    always begin
        spk = 1; repeat (24000) @(posedge clk);
        spk = 0; repeat (24000) @(posedge clk);
    end

    // Samples seen, and the one-bit output averaged over the same time.
    integer hi = -40000, lo = 40000, ones = 0, n = 0, worst = 0, diff;
    integer sd_val, smp_sum = 0, sd_sum = 0, win = 0;
    always @(posedge clk) if (!rst) begin
        ones = ones + (sd_l ? 1 : 0);
        if (frame_req) begin
            if (sample > hi) hi = sample;
            if (sample < lo) lo = sample;
            // The output is worth +-49,152 (Zeitlos's feedback level):
            // its mean over 1,000 clocks, in sample units.
            sd_val = (2 * ones - 1000) * 49152 / 1000;
            ones = 0;
            // Over 48 samples (a millisecond) the two must agree.
            smp_sum = smp_sum + sample;
            sd_sum = sd_sum + sd_val;
            win = win + 1;
            if (win == 48) begin
                diff = (sd_sum - smp_sum) / 48;
                if (diff < 0) diff = -diff;
                if (n > 96 && diff > worst) worst = diff;
                win = 0; smp_sum = 0; sd_sum = 0;
            end
            n = n + 1;
        end
    end

    integer spk_hi, spk_lo;
    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (2400000) @(posedge clk);            // 50 ms of speaker
        spk_hi = hi; spk_lo = lo;
        $display("speaker: %0d to %0d", lo, hi);
        check(hi > 3000 && lo < -3000, "the speaker is heard");
        hi = -40000; lo = 40000;
        opl(8'h20, 8'h01); opl(8'h40, 8'h3F); opl(8'h60, 8'hF0); opl(8'h80, 8'h0F);
        opl(8'h23, 8'h21); opl(8'h43, 8'h00); opl(8'h63, 8'hF0); opl(8'h83, 8'h0F);
        opl(8'hC0, 8'h01); opl(8'hA0, 8'h44); opl(8'hB0, 8'h32);
        repeat (2400000) @(posedge clk);
        $display("speaker and AdLib: %0d to %0d", lo, hi);
        check(hi > spk_hi + 4000 && lo < spk_lo - 4000, "the AdLib is added");
        $display("sigma-delta: worst millisecond mean off by %0d", worst);
        check(worst < 400, "the one-bit output follows the samples");
        if (errors == 0) $display("audio: pass");
        else $display("audio: FAIL");
        $finish;
    end
endmodule
