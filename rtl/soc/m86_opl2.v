/*
 * Mach86 SoC -- the FM synthesiser of the AdLib card (YM3812, "OPL2").
 *
 * Source: the YM3812 application manual, for the registers and what
 * each does. How the numbers are computed is ours; sim/opl2.c is the
 * same computation in C, and the two are compared sample for sample
 * (make -C sim check-opl). docs/sound.md says what is and is not here:
 * the nine two-operator voices are, the rhythm mode's five drum
 * sounds are not.
 *
 * Two modules. m86_opl2_bus is the part a program talks to, on the
 * CPU's clock: the register index, the two timers and the status
 * byte, which is all that detecting an AdLib needs. m86_opl2 is the
 * sound: the register file, written from the CPU's side and read
 * here, and one operator's worth of arithmetic used eighteen times a
 * sample, fourteen clocks each.
 *
 * It makes one sample each time `start` comes (48,000 a second on the
 * boards, where the chip makes 49,716; the phase steps are scaled by
 * that ratio to keep the pitch) and shows it at the next.
 */
module m86_opl2 #(
    parameter ROM = "opl_rom.hex"
) (
    // Register writes, on the CPU's clock.
    input  wire        clk,
    input  wire        we,
    input  wire [7:0]  wa,
    input  wire [7:0]  wd,

    input  wire        aclk,
    input  wire        arst,
    input  wire        start,
    output reg  signed [15:0] sample
);
    // The registers: written there, read here.
    reg [7:0] regs [0:255];
    reg [7:0] ra, rq;
    integer k;
    initial for (k = 0; k < 256; k = k + 1) regs[k] = 8'd0;
    always @(posedge clk)
        if (we)
            regs[wa] <= wd;
    always @(posedge aclk)
        rq <= regs[ra];

    // The tables: a quarter sine as attenuation, and the way back
    // (tools/mkopl.py).
    reg [11:0] rom [0:511];
    reg [8:0]  roma;
    reg [11:0] romq;
    initial $readmemh(ROM, rom);
    always @(posedge aclk)
        romq <= rom[roma];

    // What each operator keeps, and each voice.
    reg [19:0] ph  [0:17];
    reg [8:0]  env [0:17];
    reg [1:0]  egs [0:17];
    reg        pk  [0:17];
    reg signed [12:0] fb1 [0:8];
    reg signed [12:0] fb2 [0:8];
    initial begin
        for (k = 0; k < 18; k = k + 1) begin
            ph[k] = 20'd0; env[k] = 9'd511; egs[k] = 2'd3; pk[k] = 1'b0;
        end
        for (k = 0; k < 9; k = k + 1) begin
            fb1[k] = 13'sd0; fb2[k] = 13'sd0;
        end
    end

    // The sequence: a prelude of three steps for the registers every
    // operator uses, then fourteen steps for each of the eighteen.
    reg        run, pre;
    reg [3:0]  t;
    reg [4:0]  s;                       // the operator: voice s / 2, its first or second
    wire [3:0] ch  = s[4:1];
    wire       op2 = s[0];
    // Where the operator's registers are: voices 0-2 at 0, 3-5 at 8,
    // 6-8 at 16, the second operator three further.
    wire [4:0] off = (ch < 4'd3) ? {1'b0, ch} + (op2 ? 5'd3 : 5'd0) :
                     (ch < 4'd6) ? {1'b0, ch} + (op2 ? 5'd8 : 5'd5) :
                                   {1'b0, ch} + (op2 ? 5'd13 : 5'd10);

    reg [7:0]  r01, rBD, rB0, rA0, r20, r40, r60, r80, rC0, rE0;
    reg [15:0] egc;
    reg [5:0]  am_div;
    reg [7:0]  am_pos;
    wire [7:0] am_fold = (am_pos < 8'd105) ? am_pos : 8'd210 - am_pos;
    reg [4:0]  am_val;
    reg [2:0]  vib_pos;
    reg signed [17:0] mix;
    reg signed [12:0] a_out;

    always @(*) begin
        ra = 8'h01;
        if (pre)
            ra = (t == 4'd0) ? 8'h01 : 8'hBD;
        else case (t)
            4'd0: ra = 8'hB0 + {4'd0, ch};
            4'd1: ra = 8'hA0 + {4'd0, ch};
            4'd2: ra = 8'h20 + {3'd0, off};
            4'd3: ra = 8'h40 + {3'd0, off};
            4'd4: ra = 8'h60 + {3'd0, off};
            4'd5: ra = 8'h80 + {3'd0, off};
            4'd6: ra = 8'hC0 + {4'd0, ch};
            default: ra = 8'hE0 + {3'd0, off};
        endcase
    end

    // ---- the phase step (steps 4 to 6) ----
    wire       kon   = rB0[5];
    wire [2:0] block = rB0[4:2];
    wire [9:0] fnum  = {rB0[1:0], rA0};
    wire [2:0] vd0   = (vib_pos[1:0] == 2'd0) ? 3'd0 :
                       vib_pos[0] ? {1'b0, fnum[9:8]} : fnum[9:7];
    wire [2:0] vd    = rBD[6] ? vd0 : {1'b0, vd0[2:1]};
    wire [10:0] f    = !r20[6] ? {1'b0, fnum} :
                       vib_pos[2] ? {1'b0, fnum} - {8'd0, vd} : {1'b0, fnum} + {8'd0, vd};
    function [4:0] multx2(input [3:0] m);
        case (m)
            4'd0: multx2 = 5'd1;   4'd1: multx2 = 5'd2;   4'd2: multx2 = 5'd4;
            4'd3: multx2 = 5'd6;   4'd4: multx2 = 5'd8;   4'd5: multx2 = 5'd10;
            4'd6: multx2 = 5'd12;  4'd7: multx2 = 5'd14;  4'd8: multx2 = 5'd16;
            4'd9: multx2 = 5'd18;  4'd10: multx2 = 5'd20; 4'd11: multx2 = 5'd20;
            4'd12: multx2 = 5'd24; 4'd13: multx2 = 5'd24; default: multx2 = 5'd30;
        endcase
    endfunction
    reg [17:0] base;
    reg [21:0] incr, inc48;
    wire [22:0] prod = base * multx2(r20[3:0]);

    // ---- the key and the rate (step 7) ----
    wire [1:0]  st_k = !kon ? 2'd3 : !pk[s] ? 2'd0 : egs[s];
    wire [19:0] p_k  = (kon && !pk[s]) ? 20'd0 : ph[s];
    wire [3:0]  ksr0 = {block, fnum[9]};
    wire [3:0]  ksr  = r20[4] ? ksr0 : {2'b00, ksr0[3:2]};
    wire [3:0]  rsel = (st_k == 2'd0) ? r60[7:4] : (st_k == 2'd1) ? r60[3:0] :
                       (st_k == 2'd2 && r20[5]) ? 4'd0 : r80[3:0];
    wire [6:0]  eff0 = {1'b0, rsel, 2'b00} + {3'd0, ksr};
    wire [5:0]  eff_c = (rsel == 4'd0) ? 6'd0 : (eff0 > 7'd63) ? 6'd63 : eff0[5:0];
    reg [1:0]   k_st;
    reg [19:0]  k_p;
    reg [5:0]   eff;

    // ---- the envelope (step 8) ----
    wire [3:0]  hi = eff[5:2];
    wire [1:0]  lo = eff[1:0];
    wire [7:0]  pat = (lo == 2'd0) ? 8'hAA : (lo == 2'd1) ? 8'hBA :
                      (lo == 2'd2) ? 8'hEE : 8'hFE;
    wire [3:0]  esh  = 4'd12 - hi;                      // for hi <= 12
    wire [12:0] emask = (13'd1 << esh) - 13'd1;
    wire [15:0] eshf = egc >> esh;
    wire        slow_go = ((egc[12:0] & emask) == 13'd0);
    wire        fastbit = pat[egc[2:0]];
    wire [3:0]  step = (eff == 6'd0) ? 4'd0 :
                       (hi <= 4'd12) ? {3'd0, slow_go && pat[eshf[2:0]]} :
                       (hi == 4'd13) ? (fastbit ? 4'd2 : 4'd1) :
                       (hi == 4'd14) ? (fastbit ? 4'd4 : 4'd2) :
                                       (fastbit ? 4'd8 : 4'd4);
    reg  [8:0]  e0;                     // env[s], read in step 7
    wire signed [10:0] e_neg = -$signed({2'b00, e0}) - 11'sd1;
    // Times the step, which in an attack is 0, 1, 2 or 4 (at 8 the
    // attack is immediate).
    wire signed [15:0] e_ext  = {{5{e_neg[10]}}, e_neg};
    reg  [3:0]  step_r;                 // the step, a cycle later (it is slow to make)
    wire signed [15:0] a_prod = step_r[2] ? (e_ext <<< 2) : step_r[1] ? (e_ext <<< 1) :
                                step_r[0] ? e_ext : 16'sd0;
    wire signed [15:0] a_new  = $signed({7'd0, e0}) + (a_prod >>> 3);
    wire [9:0]  d_sum = {1'b0, e0} + {6'd0, step_r};
    wire [8:0]  d_new = d_sum[9] ? 9'd511 : d_sum[8:0];
    wire [4:0]  sl    = (r80[7:4] == 4'd15) ? 5'd31 : {1'b0, r80[7:4]};
    reg [8:0]   e_n;
    reg [1:0]   st_n;
    always @(*) begin
        st_n = k_st;
        if (k_st == 2'd0) begin
            e_n = (eff >= 6'd60 || a_new <= 16'sd0) ? 9'd0 : a_new[8:0];
            if (e_n == 9'd0)
                st_n = 2'd1;
        end else begin
            e_n = d_new;
            if (k_st == 2'd1 && d_new[8:4] >= sl)
                st_n = 2'd2;
        end
    end
    reg [8:0]   e_r;
    reg [1:0]   st_r;

    // ---- the level and the wave (steps 9 to 11) ----
    function [6:0] kslrom(input [3:0] x);
        case (x)
            4'd0: kslrom = 7'd0;   4'd1: kslrom = 7'd32;  4'd2: kslrom = 7'd40;
            4'd3: kslrom = 7'd45;  4'd4: kslrom = 7'd48;  4'd5: kslrom = 7'd51;
            4'd6: kslrom = 7'd53;  4'd7: kslrom = 7'd55;  4'd8: kslrom = 7'd56;
            4'd9: kslrom = 7'd58;  4'd10: kslrom = 7'd59; 4'd11: kslrom = 7'd60;
            4'd12: kslrom = 7'd61; 4'd13: kslrom = 7'd62; 4'd14: kslrom = 7'd63;
            default: kslrom = 7'd64;
        endcase
    endfunction
    wire [8:0]  ksl_a = {kslrom(fnum[9:6]), 2'b00};
    wire [8:0]  ksl_b = {4'd8 - {1'b0, block}, 5'd0};
    wire [8:0]  ksl0  = (ksl_a > ksl_b) ? ksl_a - ksl_b : 9'd0;
    wire [8:0]  ksl   = (r40[7:6] == 2'd0) ? 9'd0 : (r40[7:6] == 2'd1) ? {1'b0, ksl0[8:1]} :
                        (r40[7:6] == 2'd2) ? {2'b00, ksl0[8:2]} : ksl0;
    wire [10:0] att0  = {2'b00, e_r} + {3'd0, r40[5:0], 2'b00} + {2'b00, ksl} +
                        (r20[7] ? {6'd0, am_val} : 11'd0);
    wire [8:0]  att   = (att0 > 11'd511) ? 9'd511 : att0[8:0];

    wire [2:0]  fb    = rC0[3:1];
    wire signed [13:0] fbsum = fb1[ch] + fb2[ch];
    wire signed [13:0] fbmod = fbsum >>> (4'd9 - {1'b0, fb});
    wire [9:0]  mod   = op2 ? (rC0[0] ? 10'd0 : a_out[9:0]) :
                        (fb == 3'd0) ? 10'd0 : fbmod[9:0];
    wire [9:0]  ph10  = k_p[19:10] + mod;
    wire [1:0]  ws    = r01[5] ? rE0[1:0] : 2'd0;
    reg         neg, zero;
    reg [11:0]  att8;
    reg [4:0]   lsh;
    wire [12:0] lv    = {1'b0, romq} + {1'b0, att8};
    wire [11:0] mag0  = {romq[9:0] | 10'd0, 1'b0} | 12'h800;    // (exp | 1024) * 2
    wire [11:0] mag   = (lsh > 5'd12) ? 12'd0 : (mag0 >> lsh);
    wire signed [12:0] out = zero ? 13'sd0 : neg ? -$signed({1'b0, mag}) : $signed({1'b0, mag});

    wire signed [17:0] mix_n = mix + (rC0[0] ? {{5{a_out[12]}}, a_out} + {{5{out[12]}}, out}
                                             : {{5{out[12]}}, out});
    wire signed [18:0] mix2 = {mix, 1'b0};

    always @(posedge aclk) begin
        if (run && pre) begin
            t <= t + 4'd1;
            if (t == 4'd1) r01 <= rq;
            if (t == 4'd2) begin
                rBD <= rq;
                // Tremolo: a triangle of 210 steps, a quarter of it
                // used, a quarter of that when the depth bit is off.
                am_val <= rq[7] ? am_fold[6:2] : {2'b00, am_fold[6:4]};
                pre <= 1'b0;
                t   <= 4'd0;
            end
        end else if (run) begin
            t <= t + 4'd1;
            case (t)
                4'd1: rB0 <= rq;
                4'd2: rA0 <= rq;
                4'd3: r20 <= rq;
                4'd4: begin r40 <= rq; base <= {7'd0, f} << block; end
                4'd5: begin r60 <= rq; incr <= prod[22:1]; end
                4'd6: begin
                    r80 <= rq;
                    inc48 <= incr + {5'd0, incr[21:5]} + {8'd0, incr[21:8]} + {11'd0, incr[21:11]};
                end
                4'd7: begin
                    rC0  <= rq;
                    k_st <= st_k;
                    e0   <= env[s];
                    k_p  <= p_k;
                    eff  <= eff_c;
                end
                4'd8: begin
                    rE0    <= rq;
                    step_r <= step;
                end
                4'd9: begin
                    // The quarter of the sine, and what the waveform
                    // makes of the other three.
                    roma <= {1'b0, ph10[7:0] ^ {8{ph10[8]}}};
                    neg  <= ph10[9] && (ws == 2'd0 || ws == 2'd1);
                    zero <= (ws == 2'd1 && ph10[9]) || (ws == 2'd3 && ph10[8]);
                    e_r  <= e_n;
                    st_r <= st_n;
                end
                4'd10: att8 <= {att, 3'b000};   // (the table is being read)
                4'd11: begin
                    roma <= {1'b1, ~lv[7:0]};
                    lsh  <= lv[12:8];
                end
                4'd12: ;
                4'd13: begin
                    ph[s]  <= k_p + inc48[19:0];
                    env[s] <= e_r;
                    egs[s] <= st_r;
                    pk[s]  <= kon;
                    if (!op2) begin
                        fb2[ch] <= fb1[ch];
                        fb1[ch] <= out;
                        a_out   <= out;
                    end else
                        mix <= mix_n;
                    t <= 4'd0;
                    s <= s + 5'd1;
                    if (s == 5'd17) begin
                        run <= 1'b0;
                        egc <= egc + 16'd1;
                        am_div <= am_div + 6'd1;
                        if (am_div == 6'd63)
                            am_pos <= (am_pos == 8'd209) ? 8'd0 : am_pos + 8'd1;
                    end
                end
                default: ;
            endcase
        end
        if (start) begin
            sample <= (mix2 > 19'sd32767) ? 16'sd32767 :
                      (mix2 < -19'sd32768) ? -16'sd32768 : mix2[15:0];
            mix <= 18'sd0;
            run <= 1'b1; pre <= 1'b1; t <= 4'd0; s <= 5'd0;
            vib_pos <= egc[12:10];
        end
        if (arst) begin
            run <= 1'b0; pre <= 1'b0; t <= 4'd0; s <= 5'd0;
            mix <= 18'sd0; sample <= 16'sd0;
            egc <= 16'd0; am_div <= 6'd0; am_pos <= 8'd0;
        end
    end
endmodule

/*
 * The part a program talks to. Ports 388h (write: the register index;
 * read: the status) and 389h (write: the register). The two timers
 * count up from their register every 80 and 320 microseconds and set
 * their flag when they pass 255; that, and nothing about sound, is how
 * programs look for an AdLib.
 */
module m86_opl2_bus #(
    parameter CLK_HZ = 24000000
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       wr,               // a write to 388h or 389h
    input  wire       a,                // 0: 388h, 1: 389h
    input  wire [7:0] wd,
    output wire [7:0] status,

    output reg        reg_we,           // a register write, for the sound
    output reg  [7:0] reg_a,
    output reg  [7:0] reg_d
);
    localparam integer DIV = CLK_HZ / 12500;        // 80 microseconds
    reg [15:0] div;
    reg [1:0]  div4;
    reg [7:0]  index, t1_load, t2_load, t1, t2, ctrl;
    reg        f1, f2;
    assign status = {f1 || f2, f1, f2, 5'b00110};

    wire tick80  = (div == DIV - 1);
    wire tick320 = tick80 && (div4 == 2'd3);

    always @(posedge clk) begin
        reg_we <= 1'b0;
        div <= tick80 ? 16'd0 : div + 16'd1;
        if (tick80)
            div4 <= div4 + 2'd1;
        if (tick80 && ctrl[0]) begin
            t1 <= (t1 == 8'hFF) ? t1_load : t1 + 8'd1;
            if (t1 == 8'hFF && !ctrl[6]) f1 <= 1'b1;
        end
        if (tick320 && ctrl[1]) begin
            t2 <= (t2 == 8'hFF) ? t2_load : t2 + 8'd1;
            if (t2 == 8'hFF && !ctrl[5]) f2 <= 1'b1;
        end
        if (wr && !a)
            index <= wd;
        if (wr && a) begin
            reg_we <= 1'b1;
            reg_a  <= index;
            reg_d  <= wd;
            case (index)
                8'h02: t1_load <= wd;
                8'h03: t2_load <= wd;
                8'h04: begin
                    if (wd[7]) begin
                        f1 <= 1'b0;
                        f2 <= 1'b0;
                    end else begin
                        ctrl <= wd;
                        if (wd[0] && !ctrl[0]) t1 <= t1_load;
                        if (wd[1] && !ctrl[1]) t2 <= t2_load;
                    end
                end
                default: ;
            endcase
        end
        if (rst) begin
            div <= 16'd0; div4 <= 2'd0; index <= 8'd0;
            t1_load <= 8'd0; t2_load <= 8'd0; t1 <= 8'd0; t2 <= 8'd0;
            ctrl <= 8'd0; f1 <= 1'b0; f2 <= 1'b0; reg_we <= 1'b0;
        end
    end
endmodule
