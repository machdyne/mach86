/*
 * Mach86 -- test bench for the display output with sound
 * (rtl/soc/m86_hdmi.v): a picture with m86_vga.v's timing goes in,
 * with frames of sound, and the three channels' characters are
 * written to a file, a line a pixel clock, for Zeitlos's receiver
 * model (tools/ddmi.py) to take apart: it rebuilds sync, pixels,
 * every packet with its parity, the InfoFrames and the sound from the
 * characters alone.
 *
 *   +out=FILE  +hdmi=0|1  +frames=N
 *
 * The sound is the receiver's test sequence: L(n) = 1237 n,
 * R(n) = 4813 n + 77, 48,000 times a second.
 */
`timescale 1ns / 1ps
module m86_hdmi_tb;
    reg pclk = 0, aclk = 0;
    always #19.841 pclk = ~pclk;            // 25.2 MHz
    always #10.4167 aclk = ~aclk;           // 48 MHz

    // The picture, as m86_vga.v makes it: pixels first in a line.
    reg [9:0] hc = 0, vc = 0;
    always @(posedge pclk) begin
        if (hc == 799) begin
            hc <= 0;
            vc <= (vc == 524) ? 0 : vc + 1;
        end else
            hc <= hc + 1;
    end
    reg        de, hs, vs;
    reg [7:0]  r, g, b;
    always @(posedge pclk) begin
        de <= (hc < 640) && (vc < 480);
        hs <= !(hc >= 656 && hc < 752);
        vs <= !((vc == 489 && hc >= 640) || vc == 490 || (vc == 491 && hc < 640));
        r  <= hc[7:0] ^ vc[7:0];
        g  <= hc[8:1];
        b  <= vc[7:0];
    end

    // Sound: a frame every 1,000 clocks of 48 MHz.
    integer acnt = 0, n = 0;
    reg        aud_we = 0;
    reg [15:0] al = 0, ar = 0;
    always @(posedge aclk) begin
        aud_we <= 0;
        acnt <= (acnt == 999) ? 0 : acnt + 1;
        if (acnt == 999) begin
            aud_we <= 1;
            al <= 1237 * n;
            ar <= 4813 * n + 77;
            n = n + 1;
        end
    end

    reg hdmi = 0;
    wire [1:0] tr, tg, tb, tc;
    m86_hdmi dut (.pclk(pclk), .bclk(1'b0), .r(r), .g(g), .b(b), .de(de),
                  .hsync(hs), .vsync(vs), .hdmi(hdmi),
                  .aud_clk(aclk), .aud_we(aud_we), .aud_l(al), .aud_r(ar),
                  .tmds_r(tr), .tmds_g(tg), .tmds_b(tb), .tmds_c(tc));

    integer fd, frames, hd, nf = 0;
    reg capturing = 0;
    reg [8*256-1:0] path;
    // The characters come out of the encoders a clock after the
    // counters they were made from; a picture starts at line 0,
    // character 0 of those.
    reg start_d = 0;
    always @(posedge pclk) begin
        start_d <= (dut.hc == 0 && dut.vc == 0);
        if (start_d) begin
            if (capturing) nf = nf + 1;
            if (nf == frames) begin
                $fclose(fd);
                $display("hdmi_tb: %0d frames written", nf);
                $finish;
            end
            capturing = armed;
        end
        if (capturing)
            $fwrite(fd, "%03x %03x %03x\n", dut.q0, dut.q1, dut.q2);
    end
    reg armed = 0;
    initial begin
        if (!$value$plusargs("out=%s", path)) path = "/tmp/hdmi_capture.txt";
        if (!$value$plusargs("frames=%d", frames)) frames = 1;
        if (!$value$plusargs("hdmi=%d", hd)) hd = 0;
        fd = $fopen(path, "w");
        $fwrite(fd, "# m86_hdmi_tb: ch0 ch1 ch2 per pixel clock\n");
        hdmi = hd;
        // Two pictures to settle (the switch is taken at a picture's
        // start, and the sound's queue fills), then capture.
        repeat (2 * 420000 + 1000) @(posedge pclk);
        armed = 1;
    end
endmodule
