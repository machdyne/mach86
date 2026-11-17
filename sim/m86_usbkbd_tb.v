/*
 * Mach86 -- test bench for the USB keyboard translation
 * (rtl/soc/m86_usbkbd.v): HID boot keyboard reports in, on a 12 MHz
 * clock, set-1 scancodes out, compared with what a PC keyboard sends
 * for the same key strokes. The consumer is sometimes not ready.
 */
`timescale 1ns/1ps
module m86_usbkbd_tb;
    reg clk = 0, hclk = 0, rst = 1;
    always #16 clk = ~clk;                  // about 31 MHz
    always #41.6 hclk = ~hclk;              // 12 MHz

    reg        rep = 0;
    reg [1:0]  typ = 0;
    reg [7:0]  mod = 0, k1 = 0, k2 = 0, k3 = 0, k4 = 0;
    wire       sc_valid;
    wire [7:0] sc_data;
    reg        sc_ready = 0;
    // A millisecond is 100 cycles here, so that repeats come quickly.
    m86_usbkbd #(.CLK_HZ(100000), .DELAY_MS(500), .RATE_MS(92)) dut (
        .clk(clk), .rst(rst), .hid_clk(hclk), .hid_report(rep), .hid_typ(typ),
        .hid_mod(mod), .hid_k1(k1), .hid_k2(k2), .hid_k3(k3), .hid_k4(k4),
        .sc_valid(sc_valid), .sc_data(sc_data), .sc_ready(sc_ready),
        .present());

    // What came out.
    reg [7:0] got [0:255];
    integer   n = 0, errors = 0, i;
    always @(posedge clk) begin
        sc_ready <= ($random & 3) != 0;
        if (sc_valid && sc_ready) begin
            got[n] = sc_data;
            n = n + 1;
        end
    end

    task report(input [7:0] m, input [7:0] a, input [7:0] b, input [7:0] c,
                input [7:0] d);
    begin
        @(posedge hclk);
        mod <= m; k1 <= a; k2 <= b; k3 <= c; k4 <= d;
        @(posedge hclk) rep <= 1;
        @(posedge hclk) rep <= 0;
        repeat (400) @(posedge clk);        // reports are milliseconds apart
    end
    endtask

    task want(input [8*24:1] what, input integer count, input [63:0] bytes);
    begin
        if (n != count) begin
            errors = errors + 1;
            $display("FAIL %0s: %0d bytes, want %0d", what, n, count);
        end
        for (i = 0; i < count && i < n; i = i + 1)
            if (got[i] !== bytes[8*(count-1-i) +: 8]) begin
                errors = errors + 1;
                $display("FAIL %0s: byte %0d is %h, want %h", what, i, got[i],
                         bytes[8*(count-1-i) +: 8]);
            end
        n = 0;
    end
    endtask

    initial begin
        repeat (8) @(posedge clk);
        rst <= 0;
        // Not a keyboard: reports are not for us.
        typ <= 2; report(8'h00, 8'h04, 0, 0, 0);
        want("mouse ignored", 0, 0);
        typ <= 1; repeat (8) @(posedge clk);

        report(8'h00, 8'h04, 0, 0, 0);          want("a down", 1, 64'h1E);
        report(8'h00, 0, 0, 0, 0);              want("a up", 1, 64'h9E);
        report(8'h02, 0, 0, 0, 0);              want("shift down", 1, 64'h2A);
        report(8'h02, 8'h04, 0, 0, 0);          want("A down", 1, 64'h1E);
        report(8'h00, 0, 0, 0, 0);              want("A and shift up", 2, 64'h9EAA);
        report(8'h00, 8'h52, 0, 0, 0);          want("up arrow", 2, 64'hE048);
        report(8'h00, 0, 0, 0, 0);              want("up arrow up", 2, 64'hE0C8);
        report(8'h10, 0, 0, 0, 0);              want("right ctrl", 2, 64'hE01D);
        report(8'h40, 0, 0, 0, 0);              want("to right alt", 4, 64'hE09DE038);
        report(8'h00, 0, 0, 0, 0);              want("right alt up", 2, 64'hE0B8);
        // Two keys, the first released while the second is held; the
        // keyboard moves the survivor to the first place.
        report(8'h00, 8'h1A, 0, 0, 0);          want("w", 1, 64'h11);
        report(8'h00, 8'h1A, 8'h07, 0, 0);      want("w d", 1, 64'h20);
        report(8'h00, 8'h07, 0, 0, 0);          want("d alone", 1, 64'h91);
        report(8'h00, 8'h01, 8'h01, 8'h01, 8'h01); want("rollover", 0, 0);
        report(8'h00, 0, 0, 0, 0);              want("d up", 1, 64'hA0);
        // Ctrl-Alt-Del.
        report(8'h05, 8'h4C, 0, 0, 0);          want("ctrl alt del", 4, 64'h1D38E053);
        report(8'h00, 0, 0, 0, 0);              want("all up", 4, 64'hE0D39DB8);
        // A key with no PC meaning says nothing.
        report(8'h00, 8'h68, 0, 0, 0);          want("F13", 0, 0);
        report(8'h00, 0, 0, 0, 0);              want("F13 up", 0, 0);

        // Repeat: nothing for half a second, then eleven a second.
        report(8'h00, 8'h1B, 0, 0, 0);          want("x", 1, 64'h2D);
        repeat (480 * 100 - 400) @(posedge clk); want("x, 480 ms", 0, 0);
        repeat (40 * 100) @(posedge clk);       want("x, first repeat", 1, 64'h2D);
        repeat (92 * 3 * 100) @(posedge clk);   want("x, three more", 3, 64'h2D2D2D);
        // Shift does not stop it; another key takes it over.
        report(8'h02, 8'h1B, 0, 0, 0);          want("shift", 1, 64'h2A);
        report(8'h02, 8'h1B, 8'h51, 0, 0);      want("down arrow", 2, 64'hE050);
        repeat (505 * 100 - 400) @(posedge clk);
        want("down arrow repeats", 2, 64'hE050);
        report(8'h00, 8'h1B, 0, 0, 0);          want("arrow, shift up", 3, 64'hE0D0AA);
        repeat (700 * 100) @(posedge clk);      want("x no longer repeats", 0, 0);
        // Unplugged with a key down: nothing more.
        typ <= 0; repeat (700 * 100) @(posedge clk);
        want("unplugged", 0, 0);

        if (errors == 0) $display("usbkbd: pass");
        else $display("usbkbd: FAIL (%0d)", errors);
        $finish;
    end
endmodule
