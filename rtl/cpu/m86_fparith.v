/*
 * m86_fparith.v: the arithmetic of the floating-point unit (docs/fpu.md).
 *
 * One operation at a time on 80-bit numbers: add, subtract, multiply,
 * divide, square root, compare, round to an integer, and the
 * conversions to and from integers and the 32- and 64-bit formats.
 * The definition is sim/m86fpu.c, which was checked against a real
 * x87: this gives the same result and the same flags, bit for bit
 * (sim/fparith_tb.cpp compares the two).
 *
 * It is a state machine over one data path: a 67-bit register W (64
 * bits of significand, then guard, round and sticky), a right shifter
 * that keeps what falls off in the sticky bit, a left shifter with a
 * leading-zero count, an adder, a 32 x 32 multiplier used four times,
 * and loops of one bit a cycle for division and the square root.
 *
 * Clean-room: written from sim/m86fpu.c and IEEE 754.
 */
module m86_fparith (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,       // one cycle, with the rest below
    input  wire [4:0]  op,
    input  wire [79:0] a,           // (an integer or a short format: in the low bits)
    input  wire [79:0] b,
    input  wire [1:0]  rc,          // rounding: nearest, down, up, toward zero
    input  wire [1:0]  pc,          // precision: 0 24 bits, 2 53, otherwise 64
    input  wire [1:0]  um,          // not masked: bit 0 overflow, bit 1 underflow
    output reg         done,        // one cycle; the results stay until the next start
    output reg  [79:0] r,
    output reg  [79:0] r2,          // FXTRACT's second result, the significand
    output reg  [6:0]  fl,          // invalid, denormal, zero-divide, overflow, underflow, precision; C1
    output reg  [3:0]  cc           // C3, C2, C1, C0 of a comparison or a remainder
);
    localparam OP_ADD = 5'd0, OP_SUB = 5'd1, OP_MUL = 5'd2, OP_DIV = 5'd3,
               OP_COM = 5'd4, OP_UCOM = 5'd5, OP_SQRT = 5'd6, OP_RND = 5'd7,
               OP_TOI16 = 5'd8, OP_TOI32 = 5'd9, OP_TOI64 = 5'd10, OP_FROMI = 5'd11,
               OP_TOF32 = 5'd12, OP_TOF64 = 5'd13, OP_FROMF32 = 5'd14, OP_FROMF64 = 5'd15,
               OP_PREM = 5'd16, OP_PREM1 = 5'd17, OP_SCALE = 5'd18, OP_XTRACT = 5'd19,
               OP_FROMBCD = 5'd20, OP_TOBCD = 5'd21;
    localparam K_ZERO = 3'd0, K_DEN = 3'd1, K_NORM = 3'd2, K_INF = 3'd3,
               K_QNAN = 3'd4, K_SNAN = 3'd5, K_UNS = 3'd6;
    localparam F_I = 7'h01, F_D = 7'h02, F_Z = 7'h04, F_O = 7'h08, F_U = 7'h10,
               F_P = 7'h20, F_C1 = 7'h40;
    localparam [17:0] BIAS = 18'd16383;
    localparam [63:0] INTBIT = 64'h8000000000000000;
    localparam [79:0] INDEF = 80'hFFFFC000000000000000;

    localparam S_IDLE = 5'd0, S_CLS = 5'd1, S_CLS2 = 5'd2, S_NZ1 = 5'd3, S_NZ2 = 5'd4,
               S_SPEC = 5'd5, S_AL = 5'd6, S_ADD = 5'd7, S_M0 = 5'd8, S_M1 = 5'd9,
               S_M2 = 5'd10, S_M3 = 5'd11, S_M4 = 5'd12, S_MF = 5'd13, S_DIV = 5'd14,
               S_SQ = 5'd15, S_SQF = 5'd16, S_ISH = 5'd17, S_IRND = 5'd18, S_RND0 = 5'd19,
               S_RND1 = 5'd20, S_FIN = 5'd21, S_PK = 5'd22, S_OUT = 5'd23, S_SUBZ = 5'd24,
               S_PR = 5'd25, S_PRF = 5'd26, S_BCDI = 5'd27, S_BCDO = 5'd28;

    function [2:0] cls(input [79:0] v);
        begin
            if (v[78:64] == 15'd0)
                cls = (v[63:0] != 64'd0) ? K_DEN : K_ZERO;
            else if (!v[63])
                cls = K_UNS;
            else if (v[78:64] != 15'h7FFF)
                cls = K_NORM;
            else if (v[62:0] == 63'd0)
                cls = K_INF;
            else
                cls = v[62] ? K_QNAN : K_SNAN;
        end
    endfunction

    // Leading zeros of 67 bits (67 if there is no one).
    function [6:0] lzc(input [66:0] v);
        integer i;
        begin
            lzc = 7'd67;
            for (i = 0; i <= 66; i = i + 1)
                if (v[i])
                    lzc = 7'd66 - i[6:0];
        end
    endfunction

    reg  [4:0]  state, nret;
    reg  [4:0]  op_r;
    reg  [79:0] ra, rb;
    reg  [1:0]  rc_r, pc_r, um_r;
    reg  [2:0]  ka, kb;
    reg         sa, sb, sr;
    reg  [17:0] ea, eb, er;         // exponents, signed
    reg  [63:0] ma, mb;
    reg  [66:0] W;
    reg  [1:0]  nsel;               // what is being normalised: 0 a, 1 b, 2 W
    reg  [6:0]  nzc;
    reg  [6:0]  fl_r;
    reg  [1:0]  rp;                 // the rounding's precision: 0 24 bits, 1 53, 2 64
    reg  [14:0] emax;               // and the format's largest exponent field
    reg         f_inex, f_up, f_tiny;
    reg  [63:0] f_keep;
    reg  [17:0] f_exp;
    reg         o_s;
    reg  [14:0] o_e;
    reg  [63:0] o_m;
    reg         o_raw;              // r is o_m as it is (an integer)
    reg  [127:0] acc;
    reg  [63:0] prod;
    reg  [6:0]  cnt;
    reg  [64:0] rem;
    reg  [63:0] q;
    reg  [127:0] sq_n;
    reg  [65:0] sq_rem;
    reg         swap;
    reg         rnd_plain;              // round as the model's round_to does: no unmasked-exception form
    reg  [6:0]  pr_steps;
    reg         pr_part;
    reg  [79:0] o2;
    reg         o_raw80;
    reg  [71:0] bcd;

    wire        unary = (op != OP_ADD) && (op != OP_SUB) && (op != OP_MUL) &&
                        (op != OP_DIV) && (op != OP_COM) && (op != OP_UCOM) &&
                        (op != OP_PREM) && (op != OP_PREM1) && (op != OP_SCALE);
    wire        is80  = (emax == 15'h7FFF);
    wire        a_nan = (ka == K_QNAN) || (ka == K_SNAN);
    wire        b_nan = (kb == K_QNAN) || (kb == K_SNAN);
    wire        spec  = a_nan || b_nan || (ka == K_UNS) || (kb == K_UNS);
    wire        den   = (ka == K_DEN) || (kb == K_DEN);

    // What two operands give when one is not a number.
    wire        n2_uns = (ka == K_UNS) || (kb == K_UNS);
    wire        n2_inv = n2_uns || (ka == K_SNAN) || (kb == K_SNAN);
    wire        n2_a   = !b_nan ? 1'b1 : !a_nan ? 1'b0 :
                         (ka != kb) ? (ka == K_QNAN) :
                         (ra[63:0] != rb[63:0]) ? (ra[63:0] > rb[63:0]) : !ra[79];
    wire [79:0] n2_r   = n2_uns ? INDEF :
                         (n2_a ? ra : rb) | 80'h00004000000000000000;

    // The right shifter: what falls off stays in the lowest bit.
    reg  [66:0] sh_in;
    reg  [17:0] sh_amt;             // signed; below 0 is 0, and 67 or more leaves only the sticky bit
    wire [6:0]  sh_n   = sh_amt[17] ? 7'd0 : (|sh_amt[16:7]) ? 7'd127 : sh_amt[6:0];
    wire [133:0] sh_x  = {sh_in, 67'd0} >> sh_n;
    wire [66:0] sh_out = (sh_n >= 7'd67) ? {66'd0, |sh_in} : {sh_x[133:68], sh_x[67] | (|sh_x[66:0])};

    // The left shifter's operand.
    wire [66:0] nz_v   = (nsel == 2'd0) ? {ma, 3'd0} : (nsel == 2'd1) ? {mb, 3'd0} : W;
    wire [66:0] nz_out = nz_v << nzc;

    // One rounding of W to rp's bits.
    wire [63:0] h      = W[66:3];
    wire        p64    = (rp == 2'd2) || (state == S_IRND);
    wire        p53    = !p64 && (rp == 2'd1);
    wire        low    = |W[2:0];
    wire        r_gb   = p64 ? W[2] : p53 ? h[10] : h[39];
    wire        r_rest = p64 ? (|W[1:0]) : p53 ? ((|h[9:0]) || low) : ((|h[38:0]) || low);
    wire        r_lsb  = p64 ? h[0] : p53 ? h[11] : h[40];
    wire [63:0] r_trunc = p64 ? h : p53 ? {h[63:11], 11'd0} : {h[63:40], 40'd0};
    wire [63:0] r_unit = p64 ? 64'd1 : p53 ? 64'd2048 : 64'h0000010000000000;
    wire        r_inex = r_gb || r_rest;
    wire        r_up   = (rc_r == 2'd0) ? (r_gb && (r_rest || r_lsb)) :
                         (rc_r == 2'd1) ? (r_inex && sr) :
                         (rc_r == 2'd2) ? (r_inex && !sr) : 1'b0;
    wire [64:0] r_sum  = {1'b0, r_trunc} + {1'b0, r_unit};
    wire        r_carry = r_up && r_sum[64];
    wire [63:0] r_keep = !r_up ? r_trunc : r_sum[64] ? INTBIT : r_sum[63:0];

    wire [17:0] e_rnd  = er + {17'd0, r_carry};
    wire        e_neg  = e_rnd[17] || (e_rnd == 18'd0);        // 0 or less
    wire        e_big  = !e_rnd[17] && (e_rnd >= 18'h07FFF);
    wire        er_neg = er[17] || (er == 18'd0);
    wire [17:0] e_up   = e_rnd + 18'd24576;
    wire [17:0] e_dn   = e_rnd - 18'd24576;
    wire        to_inf = (rc_r == 2'd0) || (rc_r == 2'd1 && sr) || (rc_r == 2'd2 && !sr);

    // The adder for add and subtract: the larger operand and W.
    wire [63:0] big    = swap ? mb : ma;
    wire        eff_sub = (sa != sb);
    wire [67:0] ad_sum = {1'b0, big, 3'd0} + {1'b0, W};
    wire [66:0] ad_dif = {big, 3'd0} - W;

    // Division: one quotient bit.
    wire [65:0] dv_d   = {1'b0, rem} - {2'b00, mb};
    wire        dv_bit = !dv_d[65];
    wire [64:0] dv_r   = dv_bit ? dv_d[64:0] : rem;

    // The square root: one bit.
    wire [67:0] sq_x   = {sq_rem, sq_n[127:126]};
    wire [67:0] sq_t   = {2'b00, q, 2'b01};
    wire [68:0] sq_d   = {1'b0, sq_x} - {1'b0, sq_t};
    wire        sq_bit = !sq_d[68];

    // A pseudo-denormal (exponent field 0, top bit set) as the number it is.
    wire [79:0] canon_a = {ra[79], (ra[78:64] == 15'd0 && ra[63]) ? 15'd1 : ra[78:64], ra[63:0]};
    // The remainder: the exponents' difference, and how many steps.
    wire [17:0] dexp   = ea - eb;
    wire        ieee   = (op_r == OP_PREM1);
    wire        d_neg  = dexp[17];
    wire        d_part = !d_neg && (dexp >= 18'd64);
    wire [64:0] pr_x   = {mb, 1'b0} - {1'b0, ma};           // (FPREM1, a just under b: 2b - a)
    wire [64:0] pr_r2  = {rem[63:0], 1'b0};
    wire        pr_up  = ieee && !pr_part && (pr_r2 > {1'b0, mb} || (pr_r2 == {1'b0, mb} && q[0]));
    wire [63:0] pr_q   = q + {63'd0, pr_up};
    wire [63:0] pr_r   = pr_up ? (mb - rem[63:0]) : rem[63:0];
    // The scale: b's integer part, cut off at 2^16.
    wire [17:0] t_b    = eb - BIAS;
    wire [15:0] sc_i   = mb[63:48] >> (4'd15 - t_b[3:0]);
    wire [17:0] sc_n   = t_b[17] ? 18'd0 : (t_b >= 18'd16) ? 18'h10000 : {2'd0, sc_i};
    wire [17:0] sc_e   = sb ? (ea - sc_n) : (ea + sc_n);
    wire [17:0] sc_c   = (!sc_e[17] && sc_e > 18'h10000) ? 18'h10000 :
                         (sc_e[17] && sc_e < 18'h30000) ? 18'h30000 : sc_e;
    // Packed decimal: a digit in, and the digits out (add three where five or more, shift).
    wire [63:0] bi_v   = {q[60:0], 3'd0} + {q[62:0], 1'b0} + {60'd0, bcd[71:68]};
    reg  [71:0] bo_a;
    integer     bk;
    always @* begin
        for (bk = 0; bk < 18; bk = bk + 1)
            bo_a[4*bk +: 4] = (bcd[4*bk +: 4] >= 4'd5) ? bcd[4*bk +: 4] + 4'd3 : bcd[4*bk +: 4];
    end

    wire [17:0] t_exp  = ea - BIAS;                 // of a, as a number: (m / 2^63) 2^t
    wire        t_ge63 = !t_exp[17] && (t_exp >= 18'd63);
    wire        t_ge64 = !t_exp[17] && (t_exp >= 18'd64);
    wire [5:0]  ibits  = (op_r == OP_TOI16) ? 6'd15 : (op_r == OP_TOI32) ? 6'd31 : 6'd63;
    wire [63:0] ilim   = 64'd1 << ibits;
    wire [63:0] iindef = (op_r == OP_TOI64) ? INTBIT : ~(ilim - 64'd1);

    reg  [6:0]  nf;
    always @(posedge clk) begin
        done <= 1'b0;
        nf = fl_r;
        case (state)
        S_IDLE: ;
        S_CLS: begin
            ka <= cls(ra);
            kb <= cls(rb);
            sa <= ra[79];
            sb <= rb[79] ^ (op_r == OP_SUB);
            ea <= (ra[78:64] == 15'd0) ? 18'd1 : {3'd0, ra[78:64]};
            eb <= (rb[78:64] == 15'd0) ? 18'd1 : {3'd0, rb[78:64]};
            ma <= ra[63:0];
            mb <= rb[63:0];
            nsel <= 2'd0;
            nret <= S_CLS2;
            state <= (op_r == OP_FROMI || op_r == OP_FROMF32 || op_r == OP_FROMF64) ? S_SPEC :
                     (cls(ra) == K_DEN) ? S_NZ1 : S_CLS2;
        end
        S_CLS2: begin
            nsel <= 2'd1;
            nret <= S_SPEC;
            state <= (kb == K_DEN) ? S_NZ1 : S_SPEC;
        end
        // Normalise: count, then shift.
        S_NZ1: begin
            nzc <= lzc(nz_v);
            state <= S_NZ2;
        end
        S_NZ2: begin
            case (nsel)
            2'd0: begin ma <= nz_out[66:3]; ea <= ea - {11'd0, nzc}; end
            2'd1: begin mb <= nz_out[66:3]; eb <= eb - {11'd0, nzc}; end
            default: begin W <= nz_out; er <= er - {11'd0, nzc}; end
            endcase
            state <= nret;
        end

        // What the operation is, and the cases that need no arithmetic.
        S_SPEC: begin
            rp   <= (pc_r == 2'd0) ? 2'd0 : (pc_r == 2'd2) ? 2'd1 : 2'd2;
            emax <= 15'h7FFF;
            state <= S_OUT;                 // (unless said otherwise below)
            o_raw <= 1'b0;
            o_raw80 <= 1'b0;
            rnd_plain <= 1'b0;
            case (op_r)
            OP_ADD, OP_SUB: begin
                if (spec) begin
                    {o_s, o_e, o_m} <= n2_r;
                    if (n2_inv) nf = nf | F_I;
                end else if (ka == K_INF || kb == K_INF) begin
                    if (ka == K_INF && kb == K_INF && sa != sb) begin
                        {o_s, o_e, o_m} <= INDEF;
                        nf = nf | F_I;
                    end else begin
                        if (den) nf = nf | F_D;
                        {o_s, o_e, o_m} <= (ka == K_INF) ? ra : {sb, rb[78:0]};
                    end
                end else begin
                    if (den) nf = nf | F_D;
                    if (ka == K_ZERO && kb == K_ZERO) begin
                        o_s <= (sa == sb) ? sa : (rc_r == 2'd1);
                        o_e <= 15'd0;
                        o_m <= 64'd0;
                    end else if (ka == K_ZERO) begin
                        sr <= sb; er <= eb; W <= {mb, 3'd0};
                        state <= S_RND0;
                    end else if (kb == K_ZERO) begin
                        sr <= sa; er <= ea; W <= {ma, 3'd0};
                        state <= S_RND0;
                    end else begin
                        // The smaller is shifted down to the larger.
                        if ($signed(ea) > $signed(eb) || (ea == eb && ma >= mb)) begin
                            swap <= 1'b0; sr <= sa; er <= ea;
                        end else begin
                            swap <= 1'b1; sr <= sb; er <= eb;
                        end
                        state <= S_AL;
                    end
                end
            end
            OP_MUL: begin
                sr <= sa ^ sb;
                if (spec) begin
                    {o_s, o_e, o_m} <= n2_r;
                    if (n2_inv) nf = nf | F_I;
                end else if (ka == K_INF || kb == K_INF) begin
                    if (ka == K_ZERO || kb == K_ZERO) begin
                        {o_s, o_e, o_m} <= INDEF;
                        nf = nf | F_I;
                    end else begin
                        if (den) nf = nf | F_D;
                        {o_s, o_e, o_m} <= {sa ^ sb, 15'h7FFF, INTBIT};
                    end
                end else begin
                    if (den) nf = nf | F_D;
                    if (ka == K_ZERO || kb == K_ZERO)
                        {o_s, o_e, o_m} <= {sa ^ sb, 79'd0};
                    else begin
                        er <= ea + eb - BIAS + 18'd1;
                        state <= S_M0;
                    end
                end
            end
            OP_DIV: begin
                sr <= sa ^ sb;
                if (spec) begin
                    {o_s, o_e, o_m} <= n2_r;
                    if (n2_inv) nf = nf | F_I;
                end else if (ka == K_INF) begin
                    if (kb == K_INF) begin
                        {o_s, o_e, o_m} <= INDEF;
                        nf = nf | F_I;
                    end else begin
                        if (den) nf = nf | F_D;
                        {o_s, o_e, o_m} <= {sa ^ sb, 15'h7FFF, INTBIT};
                    end
                end else if (kb == K_INF) begin
                    if (den) nf = nf | F_D;
                    {o_s, o_e, o_m} <= {sa ^ sb, 79'd0};
                end else if (kb == K_ZERO) begin
                    if (ka == K_ZERO) begin
                        {o_s, o_e, o_m} <= INDEF;
                        nf = nf | F_I;
                    end else begin
                        nf = nf | F_Z;
                        {o_s, o_e, o_m} <= {sa ^ sb, 15'h7FFF, INTBIT};
                    end
                end else begin
                    if (den) nf = nf | F_D;
                    if (ka == K_ZERO)
                        {o_s, o_e, o_m} <= {sa ^ sb, 79'd0};
                    else begin
                        er  <= ea - eb + BIAS - {17'd0, (ma < mb)};
                        rem <= (ma < mb) ? {ma, 1'b0} : {1'b0, ma};
                        cnt <= 7'd0;
                        state <= S_DIV;
                    end
                end
            end
            OP_COM, OP_UCOM: begin
                {o_s, o_e, o_m} <= 80'd0;
                if (spec) begin
                    if (op_r == OP_COM || ka == K_SNAN || kb == K_SNAN || n2_uns)
                        nf = nf | F_I;
                    cc <= 4'b1101;
                end else begin
                    if (den) nf = nf | F_D;
                    if (ka == K_ZERO && kb == K_ZERO)
                        cc <= 4'b1000;
                    else if (ka == K_ZERO)
                        cc <= {3'b000, !sb};
                    else if (kb == K_ZERO)
                        cc <= {3'b000, sa};
                    else if (sa != sb)
                        cc <= {3'b000, sa};
                    else if (ea == eb && ma == mb)
                        cc <= 4'b1000;
                    else
                        cc <= {3'b000, (($signed(ea) != $signed(eb)) ? ($signed(ea) > $signed(eb)) : (ma > mb)) == sa};
                end
            end
            OP_SQRT: begin
                sr <= 1'b0;
                if (a_nan || ka == K_UNS) begin
                    {o_s, o_e, o_m} <= n2_r;
                    if (n2_inv) nf = nf | F_I;
                end else if (ka == K_ZERO)
                    {o_s, o_e, o_m} <= ra;
                else if (sa) begin
                    {o_s, o_e, o_m} <= INDEF;
                    nf = nf | F_I;
                end else if (ka == K_INF)
                    {o_s, o_e, o_m} <= ra;
                else begin
                    if (ka == K_DEN) nf = nf | F_D;
                    // (m / 2^63) 2^t: with t odd, twice the significand.
                    sq_n   <= t_exp[0] ? {ma, 64'd0} : {1'b0, ma, 63'd0};
                    er     <= {t_exp[17], t_exp[17:1]} + BIAS;      // (t, made even, halved)
                    sq_rem <= 66'd0;
                    q      <= 64'd0;
                    cnt    <= 7'd0;
                    state  <= S_SQ;
                end
            end
            OP_RND: begin
                sr <= sa;
                if (a_nan || ka == K_UNS) begin
                    {o_s, o_e, o_m} <= n2_r;
                    if (n2_inv) nf = nf | F_I;
                end else if (ka == K_ZERO || ka == K_INF)
                    {o_s, o_e, o_m} <= ra;
                else begin
                    if (ka == K_DEN) nf = nf | F_D;
                    if (t_ge63)
                        {o_s, o_e, o_m} <= ra;
                    else
                        state <= S_ISH;
                end
            end
            OP_TOI16, OP_TOI32, OP_TOI64: begin
                sr <= sa;
                o_raw <= 1'b1;
                if (ka == K_ZERO)
                    o_m <= 64'd0;
                else if (a_nan || ka == K_UNS || ka == K_INF || t_ge64) begin
                    nf = nf | F_I;
                    o_m <= iindef;
                end else
                    state <= S_ISH;
            end
            OP_PREM, OP_PREM1: begin
                sr <= sa;
                rp <= 2'd2;
                rnd_plain <= 1'b1;
                if (spec) begin
                    {o_s, o_e, o_m} <= n2_r;
                    if (n2_inv) nf = nf | F_I;
                end else if (ka == K_INF || kb == K_ZERO) begin
                    {o_s, o_e, o_m} <= INDEF;
                    nf = nf | F_I;
                end else begin
                    if (den) nf = nf | F_D;
                    if (ka == K_ZERO || kb == K_INF)
                        {o_s, o_e, o_m} <= canon_a;
                    else if (d_neg && !(ieee && dexp == 18'h3FFFF))
                        {o_s, o_e, o_m} <= canon_a;         // smaller than the divisor (than half of it)
                    else if (d_neg) begin
                        // FPREM1, a below b by one in the exponent: the
                        // quotient is 0 or 1, by rounding.
                        if (ma > mb) begin
                            W  <= {pr_x[63:0], 3'd0};
                            er <= ea;
                            sr <= !sa;
                            cc <= 4'b0010;
                            nsel <= 2'd2;
                            nret <= S_RND0;
                            state <= S_NZ1;
                        end else
                            {o_s, o_e, o_m} <= canon_a;
                    end else begin
                        // Long division, a quotient bit a cycle: all of it
                        // if the exponents are less than 64 apart, else
                        // a part.
                        rem <= {1'b0, ma};
                        q   <= 64'd0;
                        cnt <= 7'd0;
                        pr_part  <= d_part;
                        pr_steps <= d_part ? {2'b01, dexp[4:0]} : dexp[6:0];
                        er  <= ea - (d_part ? {11'd0, 2'b01, dexp[4:0]} : {11'd0, dexp[6:0]});
                        state <= S_PR;
                    end
                end
            end
            OP_SCALE: begin
                sr <= sa;
                rp <= 2'd2;                 // (to 64 bits whatever the precision control says)
                if (spec) begin
                    {o_s, o_e, o_m} <= n2_r;
                    if (n2_inv) nf = nf | F_I;
                end else if (kb == K_INF) begin
                    if ((ka == K_ZERO && !sb) || (ka == K_INF && sb)) begin
                        {o_s, o_e, o_m} <= INDEF;
                        nf = nf | F_I;
                    end else begin
                        if (den) nf = nf | F_D;
                        {o_s, o_e, o_m} <= sb ? {sa, 79'd0} : {sa, 15'h7FFF, INTBIT};
                    end
                end else begin
                    if (den) nf = nf | F_D;
                    if (ka == K_ZERO || ka == K_INF)
                        {o_s, o_e, o_m} <= ra;
                    else if (kb == K_ZERO)
                        {o_s, o_e, o_m} <= canon_a;
                    else begin
                        W  <= {ma, 3'd0};
                        er <= sc_c;
                        state <= S_RND0;
                    end
                end
            end
            OP_XTRACT: begin
                // The exponent in r, the significand in r2.
                if (a_nan || ka == K_UNS) begin
                    {o_s, o_e, o_m} <= n2_r;
                    o2 <= n2_r;
                    if (n2_inv) nf = nf | F_I;
                end else if (ka == K_ZERO) begin
                    nf = nf | F_Z;
                    o2 <= ra;
                    {o_s, o_e, o_m} <= {1'b1, 15'h7FFF, INTBIT};
                end else if (ka == K_INF) begin
                    o2 <= ra;
                    {o_s, o_e, o_m} <= {1'b0, 15'h7FFF, INTBIT};
                end else begin
                    if (ka == K_DEN) nf = nf | F_D;
                    o2 <= {sa, 15'h3FFF, ma};
                    sr <= t_exp[17];
                    er <= BIAS + 18'd63;
                    W  <= {46'd0, t_exp[17] ? (18'd0 - t_exp) : t_exp, 3'd0};
                    if (t_exp == 18'd0)
                        {o_s, o_e, o_m} <= 80'd0;
                    else begin
                        nsel <= 2'd2;
                        nret <= S_PK;
                        state <= S_NZ1;
                    end
                end
            end
            OP_FROMBCD: begin
                sr  <= ra[79];
                bcd <= ra[71:0];
                q   <= 64'd0;
                cnt <= 7'd0;
                state <= S_BCDI;
            end
            OP_TOBCD: begin
                sr <= sa;
                o_raw80 <= 1'b1;
                if (ka == K_ZERO)
                    o2 <= {sa, 79'd0};
                else if (a_nan || ka == K_UNS || ka == K_INF || t_ge64) begin
                    nf = nf | F_I;
                    o2 <= INDEF;
                end else
                    state <= S_ISH;
            end
            OP_FROMI: begin
                sr <= ra[63];
                er <= BIAS + 18'd63;
                W  <= {ra[63] ? (64'd0 - ra[63:0]) : ra[63:0], 3'd0};
                if (ra[63:0] == 64'd0)
                    {o_s, o_e, o_m} <= 80'd0;
                else begin
                    nsel <= 2'd2;
                    nret <= S_PK;
                    state <= S_NZ1;
                end
            end
            OP_FROMF32: begin
                sr <= ra[31];
                if (ra[30:23] == 8'hFF) begin
                    if (ra[22:0] != 23'd0 && !ra[22]) nf = nf | F_I;
                    {o_s, o_e, o_m} <= {ra[31], 15'h7FFF, 1'b1, (ra[22:0] != 23'd0) | ra[22], ra[21:0], 40'd0};
                end else if (ra[30:23] == 8'd0) begin
                    if (ra[22:0] == 23'd0)
                        {o_s, o_e, o_m} <= {ra[31], 79'd0};
                    else begin
                        nf = nf | F_D;
                        W  <= {1'b0, ra[22:0], 43'd0};
                        er <= BIAS - 18'd126;
                        nsel <= 2'd2;
                        nret <= S_PK;
                        state <= S_NZ1;
                    end
                end else
                    {o_s, o_e, o_m} <= {ra[31], 15'd16256 + {7'd0, ra[30:23]}, 1'b1, ra[22:0], 40'd0};
            end
            OP_FROMF64: begin
                sr <= ra[63];
                if (ra[62:52] == 11'h7FF) begin
                    if (ra[51:0] != 52'd0 && !ra[51]) nf = nf | F_I;
                    {o_s, o_e, o_m} <= {ra[63], 15'h7FFF, 1'b1, (ra[51:0] != 52'd0) | ra[51], ra[50:0], 11'd0};
                end else if (ra[62:52] == 11'd0) begin
                    if (ra[51:0] == 52'd0)
                        {o_s, o_e, o_m} <= {ra[63], 79'd0};
                    else begin
                        nf = nf | F_D;
                        W  <= {1'b0, ra[51:0], 14'd0};
                        er <= BIAS - 18'd1022;
                        nsel <= 2'd2;
                        nret <= S_PK;
                        state <= S_NZ1;
                    end
                end else
                    {o_s, o_e, o_m} <= {ra[63], 15'd15360 + {4'd0, ra[62:52]}, 1'b1, ra[51:0], 11'd0};
            end
            default: begin              // OP_TOF32, OP_TOF64
                sr <= sa;
                rp <= (op_r == OP_TOF32) ? 2'd0 : 2'd1;
                emax <= (op_r == OP_TOF32) ? 15'h00FF : 15'h07FF;
                o_s <= sa;
                if (ka == K_ZERO) begin
                    o_e <= 15'd0;
                    o_m <= 64'd0;
                end else if (ka == K_UNS) begin
                    nf = nf | F_I;
                    o_s <= 1'b1;
                    o_e <= 15'h7FFF;
                    o_m <= 64'hC000000000000000;
                end else if (ka == K_INF) begin
                    o_e <= 15'h7FFF;
                    o_m <= INTBIT;
                end else if (a_nan) begin
                    if (ka == K_SNAN) nf = nf | F_I;
                    o_e <= 15'h7FFF;
                    o_m <= ra[63:0] | 64'h4000000000000000;
                end else begin
                    W  <= {ma, 3'd0};
                    er <= ea - BIAS + ((op_r == OP_TOF32) ? 18'd127 : 18'd1023);
                    state <= S_RND0;
                end
            end
            endcase
        end

        // ---- add, subtract ----
        S_AL: begin
            W <= sh_out;
            state <= S_ADD;
        end
        S_ADD: begin
            if (!eff_sub) begin
                if (ad_sum[67]) begin
                    W  <= {ad_sum[67:2], ad_sum[1] | ad_sum[0]};
                    er <= er + 18'd1;
                end else
                    W <= ad_sum[66:0];
                state <= S_RND0;
            end else begin
                W <= ad_dif;
                state <= S_SUBZ;
            end
        end
        S_SUBZ: begin
            if (W == 67'd0) begin
                {o_s, o_e, o_m} <= {rc_r == 2'd1, 79'd0};
                state <= S_OUT;
            end else if (W[66])
                state <= S_RND0;
            else begin
                nsel <= 2'd2;
                nret <= S_RND0;
                state <= S_NZ1;
            end
        end

        // ---- multiply: four products of 32 bits by 32 ----
        S_M0: begin prod <= ma[31:0] * mb[31:0]; state <= S_M1; end
        S_M1: begin acc <= {64'd0, prod}; prod <= ma[63:32] * mb[31:0]; state <= S_M2; end
        S_M2: begin acc <= acc + {32'd0, prod, 32'd0}; prod <= ma[31:0] * mb[63:32]; state <= S_M3; end
        S_M3: begin acc <= acc + {32'd0, prod, 32'd0}; prod <= ma[63:32] * mb[63:32]; state <= S_M4; end
        S_M4: begin acc <= acc + {prod, 64'd0}; state <= S_MF; end
        S_MF: begin
            if (acc[127])
                W <= {acc[127:64], acc[63], acc[62], |acc[61:0]};
            else begin
                W <= {acc[126:63], acc[62], acc[61], |acc[60:0]};
                er <= er - 18'd1;
            end
            state <= S_RND0;
        end

        // ---- divide: a quotient bit a cycle, 64 and one more ----
        S_DIV: begin
            cnt <= cnt + 7'd1;
            if (cnt == 7'd64) begin
                W <= {q, dv_bit, 1'b0, dv_r != 65'd0};
                state <= S_RND0;
            end else begin
                q   <= {q[62:0], dv_bit};
                rem <= {dv_r[63:0], 1'b0};
            end
        end

        // ---- square root: a bit a cycle ----
        S_SQ: begin
            cnt    <= cnt + 7'd1;
            sq_n   <= {sq_n[125:0], 2'b00};
            q      <= {q[62:0], sq_bit};
            sq_rem <= sq_bit ? sq_d[65:0] : sq_x[65:0];
            if (cnt == 7'd63)
                state <= S_SQF;
        end
        S_SQF: begin
            // More than half a unit left over, less, or nothing.
            W <= {q, sq_rem > {2'b00, q}, sq_rem > {2'b00, q}, sq_rem != 66'd0};
            state <= S_RND0;
        end

        // ---- the remainder ----
        S_PR: begin
            cnt <= cnt + 7'd1;
            q   <= {q[62:0], dv_bit};
            if (cnt == pr_steps) begin
                rem <= dv_r;
                state <= S_PRF;
            end else
                rem <= {dv_r[63:0], 1'b0};
        end
        S_PRF: begin
            // (FPREM1 rounds the quotient to the nearest, and the
            // remainder changes sign with it.)
            cc <= pr_part ? 4'b0100 : {pr_q[1], 1'b0, pr_q[0], pr_q[2]};
            if (pr_r == 64'd0) begin
                {o_s, o_e, o_m} <= {sa, 79'd0};
                state <= S_OUT;
            end else begin
                sr <= sa ^ pr_up;
                W  <= {pr_r, 3'd0};
                nsel <= 2'd2;
                nret <= S_RND0;
                state <= S_NZ1;
            end
        end

        // ---- packed decimal ----
        S_BCDI: begin
            // Eighteen digits, the highest first.
            cnt <= cnt + 7'd1;
            q   <= bi_v;
            bcd <= {bcd[67:0], 4'd0};
            if (cnt == 7'd17) begin
                er <= BIAS + 18'd63;
                W  <= {bi_v, 3'd0};
                if (bi_v == 64'd0) begin
                    {o_s, o_e, o_m} <= {sr, 79'd0};
                    state <= S_OUT;
                end else begin
                    nsel <= 2'd2;
                    nret <= S_PK;
                    state <= S_NZ1;
                end
            end
        end
        S_BCDO: begin
            cnt <= cnt + 7'd1;
            bcd <= {bo_a[70:0], q[63]};
            q   <= {q[62:0], 1'b0};
            if (cnt == 7'd63) begin
                o2 <= {sr ? 8'h80 : 8'h00, bo_a[70:0], q[63]};
                state <= S_OUT;
            end
        end

        // ---- to an integer ----
        S_ISH: begin
            W <= sh_out;
            state <= S_IRND;
        end
        S_IRND: begin
            if (r_inex) begin
                nf = nf | F_P;
                if (r_up) nf = nf | F_C1;
            end
            if (op_r == OP_RND) begin
                if (r_keep == 64'd0 && !r_carry) begin
                    {o_s, o_e, o_m} <= {sr, 79'd0};
                    state <= S_OUT;
                end else begin
                    W  <= {r_keep, 3'd0};
                    er <= BIAS + 18'd63;
                    nsel <= 2'd2;
                    nret <= S_PK;
                    state <= S_NZ1;
                end
            end else if (op_r == OP_TOBCD) begin
                if (r_carry || r_keep > 64'd999999999999999999) begin
                    nf = F_I;
                    o2 <= INDEF;
                    state <= S_OUT;
                end else begin
                    q   <= r_keep;
                    bcd <= 72'd0;
                    cnt <= 7'd0;
                    state <= S_BCDO;
                end
            end else begin
                if (r_carry || r_keep > ilim || (r_keep == ilim && !sr)) begin
                    nf = F_I;
                    o_m <= iindef;
                end else
                    o_m <= sr ? (64'd0 - r_keep) : r_keep;
                state <= S_OUT;
            end
        end

        // ---- round and pack ----
        S_RND0: begin
            f_keep <= r_keep;
            f_inex <= r_inex;
            f_up   <= r_up;
            f_exp  <= e_rnd;
            f_tiny <= 1'b0;
            state  <= S_FIN;
            if (is80 && !rnd_plain && um_r != 2'd0 && ((e_neg && um_r[1]) || (e_big && um_r[0]))) begin
                // Not masked: the result with its exponent moved into range.
                nf = nf | (e_neg ? F_U : F_O);
                if (r_inex) begin
                    nf = nf | F_P;
                    if (r_up) nf = nf | F_C1;
                end
                o_s <= sr;
                o_e <= e_neg ? e_up[14:0] : e_dn[14:0];
                o_m <= r_keep;
                if (e_neg && (e_up[17] || e_up == 18'd0)) begin
                    nf = (nf | F_P) & ~F_C1;
                    o_e <= 15'd0;
                    o_m <= 64'd0;
                end
                if (!e_neg && !e_dn[17] && e_dn >= 18'h07FFF) begin
                    nf = nf | F_P | F_C1;
                    o_e <= 15'h7FFF;
                    o_m <= INTBIT;
                end
                state <= S_OUT;
            end else if (er_neg) begin
                // Tiny (unless it rounds up to the smallest normal
                // number): shifted down to exponent 1, and rounded there.
                f_tiny <= !(er == 18'd0 && r_carry);
                state  <= S_RND1;
            end
        end
        S_RND1: begin
            // (The shift, then the rounding of what it left.)
            if (!er[17] && er == 18'd1) begin
                f_keep <= r_keep;
                f_inex <= r_inex;
                f_up   <= r_up;
                f_exp  <= (r_carry || r_keep[63]) ? 18'd1 : 18'd0;
                state  <= S_FIN;
            end else begin
                W  <= sh_out;
                er <= 18'd1;
            end
        end
        S_FIN: begin
            if (f_inex) begin
                nf = nf | F_P;
                if (f_up) nf = nf | F_C1;
                if (f_tiny) nf = nf | F_U;
            end
            if (f_tiny && um_r[1])
                nf = nf | F_U;
            o_s <= sr;
            o_e <= f_exp[14:0];
            o_m <= f_keep;
            if (!f_exp[17] && f_exp >= {3'd0, emax}) begin
                nf = nf | F_O | F_P;
                if (to_inf) begin
                    nf = nf | F_C1;
                    o_e <= emax;
                    o_m <= INTBIT;
                end else begin
                    nf = nf & ~F_C1;
                    o_e <= emax - 15'd1;
                    o_m <= (rp == 2'd2) ? 64'hFFFFFFFFFFFFFFFF :
                           (rp == 2'd1) ? 64'hFFFFFFFFFFFFF800 : 64'hFFFFFF0000000000;
                end
            end
            state <= S_OUT;
        end
        // An exact result in W.
        S_PK: begin
            o_s <= sr;
            o_e <= er[14:0];
            o_m <= W[66:3];
            state <= S_OUT;
        end
        S_OUT: begin
            r2 <= o2;
            if (o_raw80)
                r <= o2;
            else if (o_raw)
                r <= {16'd0, o_m};
            else if (op_r == OP_TOF32)
                r <= {48'd0, o_s, o_e[7:0], o_m[62:40]};
            else if (op_r == OP_TOF64)
                r <= {16'd0, o_s, o_e[10:0], o_m[62:11]};
            else
                r <= {o_s, o_e, o_m};
            fl <= fl_r;
            done <= 1'b1;
            state <= S_IDLE;
        end
        default: state <= S_IDLE;
        endcase
        fl_r <= nf;

        if (start) begin
            op_r <= op;
            ra   <= a;
            rb   <= unary ? a : b;
            rc_r <= rc;
            pc_r <= pc;
            um_r <= um;
            fl_r <= 7'd0;
            cc   <= 4'd0;
            state <= S_CLS;
        end
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
        end
    end

    // The right shifter's operand, by what is going on.
    always @(*) begin
        case (state)
        S_AL: begin
            sh_in  = {swap ? ma : mb, 3'd0};
            sh_amt = swap ? (eb - ea) : (ea - eb);
        end
        S_ISH: begin
            sh_in  = {ma, 3'd0};
            sh_amt = 18'd63 - t_exp;
        end
        default: begin              // S_RND1: down to exponent 1
            sh_in  = W;
            sh_amt = 18'd1 - er;
        end
        endcase
    end
endmodule
