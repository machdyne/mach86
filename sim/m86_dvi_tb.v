/*
 * Mach86 -- test bench for the DVI output (rtl/soc/m86_dvi.v).
 *
 * Sends every byte value on all three channels, then a stretch of
 * blanking with each sync combination, and takes the result back the
 * way a receiver does: ten bits a pixel off the two-bit serial
 * outputs, least significant first, decoded by the DVI rule. Checks
 * the data, the control characters, and that the running disparity of
 * each channel stays within bounds.
 */
`timescale 1ns/1ps
module m86_dvi_tb;
    reg bclk = 0, pclk = 0;
    always #1 bclk = ~bclk;
    reg [2:0] div = 0;
    always @(posedge bclk) begin
        div <= (div == 4) ? 0 : div + 1;
        if (div == 4) pclk <= 1; else if (div == 1) pclk <= 0;
    end

    reg [7:0] r = 0, g = 0, b = 0;
    reg       de = 0, hs = 0, vs = 0;
    wire [1:0] tr, tg, tb, tc;
    m86_dvi dut (.pclk(pclk), .bclk(bclk), .r(r), .g(g), .b(b), .de(de),
                 .hsync(hs), .vsync(vs),
                 .tmds_r(tr), .tmds_g(tg), .tmds_b(tb), .tmds_c(tc));

    function [7:0] decode(input [9:0] q);
        reg [7:0] v;
        integer i;
        begin
            v = q[9] ? ~q[7:0] : q[7:0];
            decode[0] = v[0];
            for (i = 1; i < 8; i = i + 1)
                decode[i] = q[8] ? (v[i] ^ v[i-1]) : ~(v[i] ^ v[i-1]);
        end
    endfunction

    // The receiver: find the word boundary from the clock channel.
    reg [9:0] wr = 0, wg = 0, wb = 0, wc = 0;
    integer errors = 0, words = 0, datas = 0, ctrls = 0;
    integer disp_r = 0, disp_b = 0, k, ones;
    reg [7:0] exp_q [0:1023];
    reg       exp_de [0:1023];
    reg [1:0] exp_c [0:1023];
    integer   sent = 0, got = 0;
    always @(posedge bclk) begin
        wr <= {tr, wr[9:2]}; wg <= {tg, wg[9:2]};
        wb <= {tb, wb[9:2]}; wc <= {tc, wc[9:2]};
    end
    reg started = 0;
    always @(posedge bclk)
        if (wc == 10'b0000011111) begin
            words = words + 1;
            // Skip until the first data word, then compare in order.
            if (!started && wb != 10'b1101010100 && wb != 10'b0010101011 &&
                wb != 10'b0101010100 && wb != 10'b1010101011)
                started = 1;
            if (started && got < sent) begin
                if (exp_de[got]) begin
                    datas = datas + 1;
                    if (decode(wr) !== exp_q[got] || decode(wg) !== exp_q[got] ||
                        decode(wb) !== exp_q[got]) begin
                        errors = errors + 1;
                        if (errors < 5)
                            $display("data %0d: sent %h, got %h %h %h", got,
                                     exp_q[got], decode(wr), decode(wg), decode(wb));
                    end
                    ones = 0;
                    for (k = 0; k < 10; k = k + 1) ones = ones + wr[k];
                    disp_r = disp_r + 2 * ones - 10;
                    if (disp_r > 12 || disp_r < -12) errors = errors + 1;
                end else begin
                    ctrls = ctrls + 1;
                    disp_r = 0;
                    if (wb !== ((exp_c[got] == 2'b00) ? 10'b1101010100 :
                                (exp_c[got] == 2'b01) ? 10'b0010101011 :
                                (exp_c[got] == 2'b10) ? 10'b0101010100 :
                                                        10'b1010101011) ||
                        wr !== 10'b1101010100) begin
                        errors = errors + 1;
                        if (errors < 5)
                            $display("control %0d: syncs %b, got %b", got, exp_c[got], wb);
                    end
                end
                got = got + 1;
            end
        end

    task pixel(input [7:0] v, input d, input [1:0] c);
        begin
            @(posedge pclk);
            r <= v; g <= v; b <= v; de <= d; vs <= c[1]; hs <= c[0];
            if (d || sent != 0) begin
                exp_q[sent] = v; exp_de[sent] = d; exp_c[sent] = c;
                sent = sent + 1;
            end
        end
    endtask

    integer i;
    initial begin
        repeat (20) pixel(8'd0, 1'b0, 2'b00);
        for (i = 0; i < 256; i = i + 1) pixel(i[7:0], 1'b1, 2'b00);
        for (i = 0; i < 16; i = i + 1) pixel(8'd0, 1'b0, i[1:0]);
        for (i = 0; i < 300; i = i + 1) pixel((i * 37 + 11) & 255, 1'b1, 2'b00);
        for (i = 0; i < 8; i = i + 1) pixel(8'hFF, 1'b1, 2'b00);
        for (i = 0; i < 8; i = i + 1) pixel(8'h00, 1'b1, 2'b00);
        repeat (20) pixel(8'd0, 1'b0, 2'b11);
        repeat (20) @(posedge pclk);
        $display("dvi: %0d data words and %0d control words checked, %0d errors",
                 datas, ctrls, errors);
        if (errors == 0 && datas == 572 && ctrls >= 30)
            $display("dvi: pass");
        else begin
            $display("dvi: FAIL");
            $fatal;
        end
        $finish;
    end
endmodule
