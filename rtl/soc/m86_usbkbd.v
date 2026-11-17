/*
 * Mach86 SoC -- a USB keyboard as a PC keyboard.
 *
 * Sources: USB HID 1.11 (the boot keyboard report: a byte of modifier
 * keys, then the usages of the keys held), HID usage tables (the
 * keyboard page), and the PC keyboard's scancode set 1 as the IBM AT
 * technical reference lists it for the 101-key keyboard.
 *
 * The USB side is not here: a HID host (rtl/ext/usb_hid_host on the
 * boards) reads the keyboard and hands over each report as it comes,
 * on its own clock: hid_report for a cycle, with hid_mod and four key
 * usages steady from then until well after. This module compares each
 * report with the last and sends what a PC keyboard would have sent
 * for the difference -- releases, then modifier keys, then presses --
 * a byte at a time to the keyboard controller (m86_kbd.v).
 *
 * A PC keyboard repeats a held key by itself; a USB one leaves that
 * to the host. So: the key pressed last repeats after half a second,
 * about eleven times a second, until it is released or another is
 * pressed. Modifier keys do not repeat.
 *
 * Keys of the 101-key keyboard that send E0h and a code do so here.
 * Not here: Pause (its six-byte sequence), the fake shifts around the
 * grey keys and Print Screen, the keyboard's lights. A report of
 * "too many keys" (usage 01h) is ignored: the keys stay as they were.
 */
module m86_usbkbd #(
    parameter CLK_HZ = 31500000,
    parameter DELAY_MS = 500,       // before the first repeat
    parameter RATE_MS = 92          // between repeats
) (
    input  wire       clk,
    input  wire       rst,
    // From the HID host, on its clock.
    input  wire       hid_clk,
    input  wire       hid_report,
    input  wire [1:0] hid_typ,      // 1: a keyboard
    input  wire [7:0] hid_mod,
    input  wire [7:0] hid_k1,
    input  wire [7:0] hid_k2,
    input  wire [7:0] hid_k3,
    input  wire [7:0] hid_k4,
    // To the keyboard controller: a byte when it has room.
    output reg        sc_valid,
    output reg  [7:0] sc_data,
    input  wire       sc_ready,
    output wire       present       // a keyboard is plugged in
);
    // A HID usage as {E0h first, set-1 code}; zero: no such key here.
    function [7:0] code(input [7:0] u);
        begin
            case (u)
                8'h04: code = 8'h1E; 8'h05: code = 8'h30; 8'h06: code = 8'h2E;
                8'h07: code = 8'h20; 8'h08: code = 8'h12; 8'h09: code = 8'h21;
                8'h0A: code = 8'h22; 8'h0B: code = 8'h23; 8'h0C: code = 8'h17;
                8'h0D: code = 8'h24; 8'h0E: code = 8'h25; 8'h0F: code = 8'h26;
                8'h10: code = 8'h32; 8'h11: code = 8'h31; 8'h12: code = 8'h18;
                8'h13: code = 8'h19; 8'h14: code = 8'h10; 8'h15: code = 8'h13;
                8'h16: code = 8'h1F; 8'h17: code = 8'h14; 8'h18: code = 8'h16;
                8'h19: code = 8'h2F; 8'h1A: code = 8'h11; 8'h1B: code = 8'h2D;
                8'h1C: code = 8'h15; 8'h1D: code = 8'h2C;
                8'h1E: code = 8'h02; 8'h1F: code = 8'h03; 8'h20: code = 8'h04;
                8'h21: code = 8'h05; 8'h22: code = 8'h06; 8'h23: code = 8'h07;
                8'h24: code = 8'h08; 8'h25: code = 8'h09; 8'h26: code = 8'h0A;
                8'h27: code = 8'h0B;
                8'h28: code = 8'h1C; 8'h29: code = 8'h01; 8'h2A: code = 8'h0E;
                8'h2B: code = 8'h0F; 8'h2C: code = 8'h39; 8'h2D: code = 8'h0C;
                8'h2E: code = 8'h0D; 8'h2F: code = 8'h1A; 8'h30: code = 8'h1B;
                8'h31: code = 8'h2B; 8'h32: code = 8'h2B; 8'h33: code = 8'h27;
                8'h34: code = 8'h28; 8'h35: code = 8'h29; 8'h36: code = 8'h33;
                8'h37: code = 8'h34; 8'h38: code = 8'h35; 8'h39: code = 8'h3A;
                8'h3A: code = 8'h3B; 8'h3B: code = 8'h3C; 8'h3C: code = 8'h3D;
                8'h3D: code = 8'h3E; 8'h3E: code = 8'h3F; 8'h3F: code = 8'h40;
                8'h40: code = 8'h41; 8'h41: code = 8'h42; 8'h42: code = 8'h43;
                8'h43: code = 8'h44; 8'h44: code = 8'h57; 8'h45: code = 8'h58;
                8'h46: code = 8'hB7;            // Print Screen: E0 37
                8'h47: code = 8'h46;
                8'h49: code = 8'hD2; 8'h4A: code = 8'hC7; 8'h4B: code = 8'hC9;
                8'h4C: code = 8'hD3; 8'h4D: code = 8'hCF; 8'h4E: code = 8'hD1;
                8'h4F: code = 8'hCD; 8'h50: code = 8'hCB; 8'h51: code = 8'hD0;
                8'h52: code = 8'hC8;
                8'h53: code = 8'h45;
                8'h54: code = 8'hB5;            // keypad /: E0 35
                8'h55: code = 8'h37; 8'h56: code = 8'h4A; 8'h57: code = 8'h4E;
                8'h58: code = 8'h9C;            // keypad Enter: E0 1C
                8'h59: code = 8'h4F; 8'h5A: code = 8'h50; 8'h5B: code = 8'h51;
                8'h5C: code = 8'h4B; 8'h5D: code = 8'h4C; 8'h5E: code = 8'h4D;
                8'h5F: code = 8'h47; 8'h60: code = 8'h48; 8'h61: code = 8'h49;
                8'h62: code = 8'h52; 8'h63: code = 8'h53;
                8'h64: code = 8'h56;            // the 102nd key
                8'h65: code = 8'hDD;            // menu: E0 5D
                default: code = 8'h00;
            endcase
        end
    endfunction

    // The modifier keys, by their bit in the report.
    function [7:0] modcode(input [2:0] b);
        begin
            case (b)
                3'd0: modcode = 8'h1D;          // left Ctrl
                3'd1: modcode = 8'h2A;          // left Shift
                3'd2: modcode = 8'h38;          // left Alt
                3'd3: modcode = 8'hDB;          // left GUI: E0 5B
                3'd4: modcode = 8'h9D;          // right Ctrl: E0 1D
                3'd5: modcode = 8'h36;          // right Shift
                3'd6: modcode = 8'hB8;          // right Alt: E0 38
                default: modcode = 8'hDC;       // right GUI: E0 5C
            endcase
        end
    endfunction

    // ---- the report, across the clocks ----
    reg rep_t = 1'b0;
    always @(posedge hid_clk)
        if (hid_report)
            rep_t <= !rep_t;
    reg [2:0] rep_s;
    reg [1:0] typ_s0, typ_s1;
    always @(posedge clk) begin
        rep_s  <= {rep_s[1:0], rep_t};
        typ_s0 <= hid_typ;
        typ_s1 <= typ_s0;
    end
    wire is_kbd = (typ_s1 == 2'd1);
    assign present = is_kbd;
    wire new_rep = (rep_s[2] != rep_s[1]) && is_kbd;

    // ---- what is held, and what the new report says ----
    reg [7:0]  p_mod, n_mod, h_mod;
    reg [31:0] p_keys, n_keys, h_keys;  // four usages each
    reg        pend;                // a report (h_) waiting to be worked through

    // ---- working through a report ----
    // Twelve steps: four releases, eight modifier bits, four presses;
    // each sends nothing, one byte or two.
    localparam S_IDLE = 2'd0, S_STEP = 2'd1, S_E0 = 2'd2, S_CODE = 2'd3;
    reg [1:0] st;
    reg [4:0] step;                 // 0-3 releases, 4-11 modifiers, 12-15 presses
    reg [7:0] cur;                  // {E0, code} being sent
    reg       cur_brk;
    reg       cur_rpt;              // it is a repeat: nothing follows

    wire [1:0] ki   = step[1:0];
    wire [7:0] p_k  = p_keys[8*ki +: 8];
    wire [7:0] n_k  = n_keys[8*ki +: 8];
    wire p_in_n = (p_k == n_keys[7:0])  || (p_k == n_keys[15:8]) ||
                  (p_k == n_keys[23:16]) || (p_k == n_keys[31:24]);
    wire n_in_p = (n_k == p_keys[7:0])  || (n_k == p_keys[15:8]) ||
                  (n_k == p_keys[23:16]) || (n_k == p_keys[31:24]);
    wire [3:0] mstep = step[3:0] - 4'd4;

    // ---- repeat ----
    localparam integer MS = CLK_HZ / 1000;
    reg [7:0]  rpt_key;             // usage of the key that repeats; 0: none
    reg [15:0] ms_div;
    reg [9:0]  rpt_ms;
    reg        rpt_go;
    wire       ms_tick = (ms_div == MS - 1);

    always @(posedge clk) begin
        ms_div <= ms_tick ? 16'd0 : ms_div + 16'd1;
        if (rpt_key != 8'd0 && ms_tick) begin
            if (rpt_ms == 10'd0) begin
                rpt_go <= 1'b1;
                rpt_ms <= RATE_MS - 1;
            end else
                rpt_ms <= rpt_ms - 10'd1;
        end

        if (new_rep) begin
            // "Too many keys" changes nothing.
            if (hid_k1 != 8'h01) begin
                h_mod  <= hid_mod;
                h_keys <= {hid_k4, hid_k3, hid_k2, hid_k1};
                pend   <= 1'b1;
            end
        end

        case (st)
            S_IDLE: begin
                sc_valid <= 1'b0;
                cur_rpt  <= 1'b0;
                if (pend && !new_rep) begin
                    pend   <= 1'b0;
                    n_mod  <= h_mod;
                    n_keys <= h_keys;
                    step   <= 5'd0;
                    st     <= S_STEP;
                end else if (rpt_go) begin
                    rpt_go <= 1'b0;
                    if (code(rpt_key) != 8'd0) begin
                        cur     <= code(rpt_key);
                        cur_brk <= 1'b0;
                        cur_rpt <= 1'b1;
                        st      <= code(rpt_key) >= 8'h80 ? S_E0 : S_CODE;
                    end
                end
            end
            S_STEP: begin
                sc_valid <= 1'b0;
                if (step == 5'd16) begin
                    p_mod  <= n_mod;
                    p_keys <= n_keys;
                    st     <= S_IDLE;
                end else begin
                    step <= step + 5'd1;
                    if (step < 5'd4) begin
                        // A key that is no longer in the report.
                        if (p_k != 8'd0 && !p_in_n) begin
                            if (p_k == rpt_key)
                                rpt_key <= 8'd0;
                            if (code(p_k) != 8'd0) begin
                                cur <= code(p_k); cur_brk <= 1'b1;
                                st  <= code(p_k) >= 8'h80 ? S_E0 : S_CODE;
                            end
                        end
                    end else if (step < 5'd12) begin
                        if (p_mod[mstep[2:0]] != n_mod[mstep[2:0]]) begin
                            cur <= modcode(mstep[2:0]);
                            cur_brk <= p_mod[mstep[2:0]];
                            st  <= modcode(mstep[2:0]) >= 8'h80 ? S_E0 : S_CODE;
                        end
                    end else begin
                        // A key that was not in the last report.
                        if (n_k != 8'd0 && !n_in_p) begin
                            rpt_key <= n_k;
                            rpt_ms  <= DELAY_MS - 1;
                            rpt_go  <= 1'b0;
                            if (code(n_k) != 8'd0) begin
                                cur <= code(n_k); cur_brk <= 1'b0;
                                st  <= code(n_k) >= 8'h80 ? S_E0 : S_CODE;
                            end
                        end
                    end
                end
            end
            S_E0: begin
                sc_valid <= 1'b1;
                sc_data  <= 8'hE0;
                if (sc_valid && sc_ready) begin
                    sc_valid <= 1'b0;
                    st <= S_CODE;
                end
            end
            S_CODE: begin
                sc_valid <= 1'b1;
                sc_data  <= {cur_brk, cur[6:0]};
                if (sc_valid && sc_ready) begin
                    sc_valid <= 1'b0;
                    st <= cur_rpt ? S_IDLE : S_STEP;
                end
            end
        endcase

        // Unplugged: every key is up, and nothing is said about it.
        if (rst || !is_kbd) begin
            p_mod <= 8'd0; p_keys <= 32'd0; pend <= 1'b0;
            st <= S_IDLE; sc_valid <= 1'b0;
            rpt_key <= 8'd0; rpt_go <= 1'b0;
        end
        if (rst) begin
            ms_div <= 16'd0; rpt_ms <= 10'd0;
        end
    end
endmodule
