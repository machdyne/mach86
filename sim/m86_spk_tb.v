/*
 * Mach86 -- test bench for the PC speaker's path to S/PDIF:
 * rtl/soc/m86_spk.v into Zeitlos's transmitter, and a receiver here
 * that knows only the format: it finds the preambles on the line,
 * decodes biphase-mark, checks parity and takes the samples out.
 *
 *   1. A 1 kHz square wave on the speaker bit: the samples must
 *      repeat every 48, swing about +-4,000 around nothing, and be
 *      the same left and right.
 *   2. The bit held high: the samples must die away to (nearly) zero.
 *   3. The bit switched at 16 kHz with its width changing slowly (the
 *      recorded-sound trick): the samples must follow the width.
 */
`timescale 1ns / 1ps
module m86_spk_tb;
    reg clk = 0, rst = 1, spk = 0;
    always #10.416667 clk = ~clk;           // 48 MHz

    wire tick, frame_req, spdif;
    wire signed [15:0] sample;
    m86_spk dut (.aclk(clk), .arst(rst), .spk(spk), .tick(tick),
                 .frame_req(frame_req), .sample(sample));
    audio_spdif tx (.clk(clk), .rst(rst), .enable(1'b1), .tick(tick),
                    .frame_req(frame_req), .sample_l(sample), .sample_r(sample),
                    .fs_code(4'd2), .spdif(spdif));

    // ---- the receiver ----
    integer errors = 0;
    reg [7:0]  pre = 0;
    integer    state = 0, bitn = 0, nsub = 0, nz = 0, hunt = 0, locked = 0;
    reg        last = 0;
    reg [27:0] payload = 0;
    reg signed [15:0] rx [0:65535];         // left samples, in order
    integer    nrx = 0;
    reg signed [15:0] left = 0;

    function [1:0] kind(input [7:0] p);
        kind = (p == 8'b11101000 || p == 8'b00010111) ? 2'd1 :      // Z
               (p == 8'b11100010 || p == 8'b00011101) ? 2'd2 :      // X
               (p == 8'b11100100 || p == 8'b00011011) ? 2'd3 : 2'd0; // Y
    endfunction

    reg tick_d = 0;
    always @(posedge clk) begin
        tick_d <= tick;
        if (tick_d && !rst) begin               // a half-cell is on the line
            if (state == 0) begin
                // Once a preamble has been found the next is exactly
                // eight half-cells after a subframe's end: look only
                // there, or zeros left in the window match early.
                pre = {pre[6:0], spdif};
                hunt = hunt + 1;
                if (kind(pre) != 0 && (!locked || hunt == 8)) begin
                    if (kind(pre) == 1) nz = nz + 1;
                    state = kind(pre); bitn = 0; last = spdif;
                    locked = 1;
                end
            end else begin
                if (!bitn[0]) begin
                    if (spdif == last) begin
                        errors = errors + 1;
                        if (errors < 5) $display("no transition at a bit boundary");
                    end
                end else
                    payload[bitn >> 1] = (spdif != last);
                last = spdif;
                bitn = bitn + 1;
                if (bitn == 56) begin
                    if (^payload) begin
                        errors = errors + 1;
                        if (errors < 5) $display("parity");
                    end
                    if (state == 3) begin       // right: must be the left again
                        if ($signed(payload[23:8]) !== left) begin
                            errors = errors + 1;
                            if (errors < 5) $display("left and right differ");
                        end
                    end else begin
                        left = payload[23:8];
                        rx[nrx] = left;
                        nrx = nrx + 1;
                    end
                    nsub = nsub + 1;
                    state = 0; hunt = 0;
                end
            end
        end
    end

    // ---- the tests ----
    integer i, n0, hi, lo, bad, w;
    task check(input cond, input [8*40-1:0] what);
        if (!cond) begin errors = errors + 1; $display("FAIL: %0s", what); end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        rst = 0;

        // 1. 1 kHz for 0.1 s.
        repeat (100) begin
            spk = 1; repeat (24000) @(posedge clk);
            spk = 0; repeat (24000) @(posedge clk);
        end
        n0 = nrx - 1000;                        // the last 1,000 samples
        hi = -40000; lo = 40000; bad = 0;
        for (i = n0; i < n0 + 952; i = i + 1) begin
            if (rx[i] > hi) hi = rx[i];
            if (rx[i] < lo) lo = rx[i];
            if (rx[i] - rx[i + 48] > 120 || rx[i + 48] - rx[i] > 120) bad = bad + 1;
        end
        $display("1 kHz: %0d samples, %0d to %0d", nrx, lo, hi);
        check(nrx > 4700 && nrx < 4810, "48,000 samples a second");
        check(hi > 3000 && hi < 5500 && lo < -3000 && lo > -5500, "the swing");
        check(bad == 0, "repeats every 48 samples");
        check(nz >= 24, "block starts");

        // 2. Held high for 0.15 s.
        spk = 1;
        repeat (7200000) @(posedge clk);
        $display("held high: the last sample is %0d", rx[nrx - 1]);
        check(rx[nrx - 1] < 20 && rx[nrx - 1] > -20, "silence when held");

        // 3. 16 kHz pulses (3,000 clocks), the width going 500 -> 2,500 -> 500
        //    over 0.02 s.
        n0 = nrx;
        for (i = 0; i < 320; i = i + 1) begin
            w = (i < 160) ? 500 + i * 2000 / 160 : 2500 - (i - 160) * 2000 / 160;
            spk = 1; repeat (w) @(posedge clk);
            spk = 0; repeat (3000 - w) @(posedge clk);
        end
        // The middle of the ramp is above its start by about
        // 2,000/3,000 of 8,000, and somewhat more, because the level
        // it started from is leaking away meanwhile.
        hi = (rx[n0 + 480] + rx[n0 + 481] + rx[n0 + 482]) / 3;
        lo = (rx[n0 + 30] + rx[n0 + 31] + rx[n0 + 32]) / 3;
        $display("pulse width: early %0d, middle %0d", lo, hi);
        check(hi - lo > 4500 && hi - lo < 7500, "follows the pulse width");

        check(errors == 0, "the line");
        if (errors == 0) $display("spk: pass");
        else $display("spk: FAIL, %0d errors", errors);
        $finish;
    end
endmodule
