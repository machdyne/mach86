/*
 * Mach86 SoC -- the display, text mode: 80 columns by 25 rows of 8 x 16
 * characters, in a 640 x 480 picture at 60 Hz (the 400 lines of text
 * are centred, with 40 black lines above and below).
 *
 * Sources: the timing is the industry-standard 640 x 480 at 60 Hz
 * (25.175 MHz nominal; 25.2 here). The character vcell, attribute byte
 * and 16-colour palette are as the IBM colour adapters document them:
 * bits 3:0 foreground, 6:4 background, bit 7 blink. The cursor is
 * the bottom two lines of its vcell, blinking; display controller
 * register 0Ah bit 5 turns it off.
 *
 * Everything here is on the pixel clock. cursor and cursor_off come
 * from the system clock; they change rarely and are taken once a
 * frame.
 */
module m86_vtext #(
    parameter FONT = "font.hex"
) (
    input  wire        vclk,
    output wire [10:0] vcell,        // to the screen memory
    input  wire [15:0] vcell_q,      // {attribute, character}, a cycle later
    input  wire [15:0] cursor,      // the cursor's vcell
    input  wire        cursor_off,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b,
    output reg         hsync,
    output reg         vsync,
    output reg         de
);
    // 640 x 480: 800 clocks a line, 525 lines.
    reg [9:0] hc = 10'd0, vc = 10'd0;
    always @(posedge vclk) begin
        if (hc == 10'd799) begin
            hc <= 10'd0;
            vc <= (vc == 10'd524) ? 10'd0 : vc + 10'd1;
        end else
            hc <= hc + 10'd1;
    end

    reg [5:0]  frame = 6'd0;
    reg [15:0] cur0, cur;
    reg        coff0, coff;
    always @(posedge vclk) begin
        if (hc == 10'd0) begin              // every line, across the clocks
            cur0 <= cursor;
            coff0 <= cursor_off;
        end
        if (hc == 10'd0 && vc == 10'd480) begin
            frame <= frame + 6'd1;
            cur <= cur0;                    // and the picture uses one value
            coff <= coff0;
        end
    end

    // Stage 0: which vcell, and where in it.
    wire [9:0] ty   = vc - 10'd40;              // line of the text area
    wire [4:0] row  = ty[8:4];
    wire [6:0] col  = hc[9:3];
    assign vcell = {row, 6'd0} + {2'd0, row, 4'd0} + {4'd0, col};    // row * 80 + col

    // Stage 1: the vcell is being read. Stage 2: its font row is being
    // read. Stage 3: the pixel.
    reg [2:0] x1, x2;
    reg [3:0] y1, y2;
    reg       in1, in2, de1, de2, hs1, hs2, vs1, vs2;
    reg       cu1, cu2;
    reg [7:0] attr2;
    reg [7:0] font [0:4095];
    reg [7:0] bits;
    initial $readmemh(FONT, font);

    wire vis = (hc < 10'd640) && (vc < 10'd480);
    wire txt = vis && (vc >= 10'd40) && (vc < 10'd440);

    always @(posedge vclk) begin
        x1 <= hc[2:0]; y1 <= ty[3:0];
        in1 <= txt; de1 <= vis;
        hs1 <= !(hc >= 10'd656 && hc < 10'd752);
        vs1 <= !(vc >= 10'd490 && vc < 10'd492);
        cu1 <= ({5'd0, vcell} == cur) && !coff && ty[3:0] >= 4'd14 && frame[4];

        x2 <= x1; y2 <= y1; in2 <= in1; de2 <= de1; hs2 <= hs1; vs2 <= vs1;
        cu2 <= cu1;
        attr2 <= vcell_q[15:8];
        bits  <= font[{vcell_q[7:0], y1}];

    end

    // The 16 colours: bit 3 adds 55h to each of red, green, blue; and
    // colour 6 is brown, not dark yellow.
    function [23:0] colour(input [3:0] c);
        reg [7:0] rr, gg, bb;
        begin
            rr = (c[2] ? 8'hAA : 8'h00) + (c[3] ? 8'h55 : 8'h00);
            gg = (c[1] ? 8'hAA : 8'h00) + (c[3] ? 8'h55 : 8'h00);
            bb = (c[0] ? 8'hAA : 8'h00) + (c[3] ? 8'h55 : 8'h00);
            if (c == 4'd6)
                gg = 8'h55;
            colour = {rr, gg, bb};
        end
    endfunction

    wire        ink  = (bits[3'd7 - x2] && !(attr2[7] && frame[5])) || cu2;
    wire [23:0] rgb  = colour(ink ? attr2[3:0] : {1'b0, attr2[6:4]});

    always @(posedge vclk) begin
        {r, g, b} <= in2 ? rgb : 24'd0;
        de <= de2; hsync <= hs2; vsync <= vs2;
    end
endmodule
