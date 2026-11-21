/*
 * m86_fpu.v: the floating-point unit's registers and instructions
 * (docs/fpu.md), for design C. The arithmetic is m86_fparith.v; the
 * definition of all of it is the model's (sim/m86x87.h), and the two
 * are compared instruction by instruction in lockstep.
 *
 * The processor's microcode does the instruction's memory accesses and
 * tells this unit what to do, one command a time (stb with cmd):
 *
 *   START   an instruction begins: esc and modrm say which. For a
 *           memory operand, din is its offset.
 *   PUT     din is the next part of the memory operand (or, for the
 *           register forms of DF, the value of EAX).
 *   RUN     work it out; done rises when that is over.
 *   GET     dout is the next part of what is to be stored (or the new
 *           value of EAX); the unit moves on to the part after.
 *   COMMIT  the instruction is over: registers, tags and the status
 *           word take their new values. Until then nothing has
 *           changed, so a fault in one of the memory accesses leaves
 *           the unit as it was.
 *
 * more says there is another part to PUT (before RUN) or to GET
 * (after); p16 that this part is 16 bits and not 32.
 *
 * NOT ALL OF IT YET. Done: loads and stores of all formats, the arithmetic of D8 to DE, comparisons, FXCH, FCHS,
 * FABS, FTST, FXAM, the constants, FSQRT, FRNDINT, FPREM, FPREM1,
 * FSCALE, FXTRACT, packed decimal, the transcendental functions, FLDCW, FNSTCW,
 * FNSTSW, FNINIT, FNCLEX, FFREE, FINCSTP, FDECSTP, and the saved state
 * (FLDENV, FNSTENV, FNSAVE, FRSTOR) with the instruction and operand
 * pointers. Not done (the
 * instruction does nothing, and `undone` counts it): the saved state
 * (FLDENV, FNSTENV, FNSAVE, FRSTOR), packed decimal, FPREM, FPREM1,
 * FSCALE, FXTRACT and the transcendental functions; the instruction
 * and operand pointers; and waiting for an interrupt when an exception
 * that is not masked is pending.
 */
module m86_fpu (
    input  wire        clk,
    input  wire        rst,
    input  wire        stb,
    input  wire [2:0]  cmd,
    input  wire [31:0] din,
    input  wire [2:0]  esc,         // the opcode's low three bits
    input  wire [7:0]  modrm,
    input  wire        os32,        // the instruction's operand size is 32 bits
    input  wire        prot,        // protected mode (and not virtual 8086 mode)
    input  wire [31:0] ip,          // where the instruction is,
    input  wire [15:0] cs,
    input  wire [15:0] dsel,        // and its memory operand's segment
    input  wire [3:0]  cr,          // CR0's NE, TS, EM and MP
    output wire        trap,        // the instruction is not to be run: exception 7, or (with p16) 16
    output reg  [31:0] dout,
    output wire        done,
    output wire        more,
    output wire        p16,
    output wire        ferr         // an exception that is not masked is pending
);
    localparam C_START = 3'd0, C_PUT = 3'd1, C_GET = 3'd2, C_RUN = 3'd3, C_COMMIT = 3'd4,
               C_WAIT = 3'd5;           // the WAIT instruction: only the exceptions are looked at

    // ---- the state a program sees ----
    reg [79:0] st [0:7] /* verilator public_flat_rd */;
    reg [15:0] cw /* verilator public_flat_rd */;
    reg [15:0] sw /* verilator public_flat_rd */;
    reg [7:0]  empty /* verilator public_flat_rd */;
    reg [31:0] undone /* verilator public_flat_rd */;
    // The last instruction that was not a control instruction: where
    // it and its operand were, and its opcode.
    reg [31:0] fip /* verilator public_flat_rd */;
    reg [31:0] fdp /* verilator public_flat_rd */;
    reg [15:0] fcs /* verilator public_flat_rd */;
    reg [15:0] fds /* verilator public_flat_rd */;
    reg [10:0] fop /* verilator public_flat_rd */;
    assign ferr = sw[7];

    // ---- the instruction ----
    localparam K_NONE = 4'd0, K_ARITH = 4'd1, K_COMP = 4'd2, K_LDMEM = 4'd3, K_STMEM = 4'd4,
               K_LDREG = 4'd5, K_STREG = 4'd6, K_XCH = 4'd7, K_UNARY = 4'd8, K_SIGN = 4'd9,
               K_XAM = 4'd10, K_CONST = 4'd11, K_CTL = 4'd12, K_ENV = 4'd13,
               K_BIN2 = 4'd14, K_XTR = 4'd15;     // ST = f(ST, ST(1)): FPREM, FPREM1, FSCALE; FXTRACT
    localparam M_F32 = 3'd0, M_F64 = 3'd1, M_I16 = 3'd2, M_I32 = 3'd3, M_I64 = 3'd4,
               M_T80 = 3'd5, M_W16 = 3'd6, M_REG = 3'd7;
    localparam T_NOP = 4'd0, T_INIT = 4'd1, T_CLEX = 4'd2, T_LDCW = 4'd3, T_STCW = 4'd4,
               T_STSW = 4'd5, T_FREE = 4'd6, T_FREEP = 4'd7, T_INC = 4'd8, T_DEC = 4'd9,
               T_STAX = 4'd10,
               T_LDENV = 4'd11, T_STENV = 4'd12, T_SAVE = 4'd13, T_RSTOR = 4'd14;

    // The transcendental functions (trn): which, and for the sine and
    // cosine which instruction (FSIN, FCOS, FSINCOS, FPTAN).
    localparam TF_SINCOS = 3'd0, TF_ATAN = 3'd1, TF_2XM1 = 3'd2, TF_YL2X = 3'd3, TF_YL2XP1 = 3'd4;
    reg        trn;
    reg [2:0]  tfn;
    reg [1:0]  tsub;
    wire       t2op = trn && (tfn == TF_ATAN || tfn == TF_YL2X || tfn == TF_YL2XP1);  // of ST and ST(1)
    reg [3:0]  kind, ctl;
    reg [2:0]  mfmt, aop, rm;
    reg        dst_i, quiet, pop1, pop2, tst, isabs, issqrt, isbcd;
    reg [1:0]  bin2;                    // K_BIN2: 0 FPREM, 1 FPREM1, 2 FSCALE
    reg [4:0]  rd_n, wr_n, xi;
    reg [1:0]  rpart;                   // of a saved register: which of its three parts
    reg [2:0]  rk;                      // and which register, counted from the top
    reg        o32, pm, is_mem, ctrl;
    reg [31:0] s_ip, s_dp;
    reg [15:0] s_cs, s_ds;
    reg [10:0] s_op;
    reg        after;                   // RUN has been
    reg [79:0] mbuf, wbuf;
    reg [31:0] ax;

    // What the instruction is (from esc and modrm, at START).
    reg [3:0]  d_kind, d_ctl;
    reg [2:0]  d_mfmt;
    reg        d_dst_i, d_quiet, d_pop1, d_pop2, d_tst, d_abs, d_sqrt, d_undone, d_ctrl, d_bcd;
    reg [1:0]  d_bin2, d_tsub;
    reg        d_trn;
    reg [2:0]  d_tfn;
    wire       d_mem = (modrm[7:6] != 2'b11);
    wire [2:0] d_reg = modrm[5:3];
    wire [2:0] d_rm  = modrm[2:0];
    always @* begin
        d_kind = K_NONE; d_ctl = T_NOP; d_mfmt = M_REG; d_dst_i = 1'b0; d_quiet = 1'b0;
        d_pop1 = 1'b0; d_pop2 = 1'b0; d_tst = 1'b0; d_abs = 1'b0; d_sqrt = 1'b0; d_undone = 1'b0;
        d_bcd = 1'b0; d_bin2 = 2'd0; d_trn = 1'b0; d_tfn = 3'd0; d_tsub = 2'd0;
        // (The control instructions, which leave the pointers alone.)
        d_ctrl = d_mem ? ((esc == 3'd1 && d_reg >= 3'd4) || (esc == 3'd5 && (d_reg == 3'd4 || d_reg >= 3'd6)))
                       : ((esc == 3'd3 && d_reg == 3'd4 && d_rm <= 3'd4) || (esc == 3'd7 && d_reg == 3'd4 && d_rm == 3'd0));
        if (d_mem) begin
            case (esc)
            3'd0, 3'd2, 3'd4, 3'd6: begin           // arithmetic with a memory operand
                d_mfmt = (esc == 3'd0) ? M_F32 : (esc == 3'd2) ? M_I32 : (esc == 3'd4) ? M_F64 : M_I16;
                d_kind = (d_reg == 3'd2 || d_reg == 3'd3) ? K_COMP : K_ARITH;
                d_pop1 = (d_reg == 3'd3);
            end
            3'd1: case (d_reg)
                3'd0: begin d_kind = K_LDMEM; d_mfmt = M_F32; end
                3'd2, 3'd3: begin d_kind = K_STMEM; d_mfmt = M_F32; d_pop1 = d_reg[0]; end
                3'd4: begin d_kind = K_ENV; d_ctl = T_LDENV; d_mfmt = M_W16; end
                3'd5: begin d_kind = K_CTL; d_ctl = T_LDCW; d_mfmt = M_W16; end
                3'd6: begin d_kind = K_ENV; d_ctl = T_STENV; d_mfmt = M_W16; end
                3'd7: begin d_kind = K_CTL; d_ctl = T_STCW; d_mfmt = M_W16; end
                default: d_undone = 1'b1;
            endcase
            3'd3: case (d_reg)
                3'd0: begin d_kind = K_LDMEM; d_mfmt = M_I32; end
                3'd2, 3'd3: begin d_kind = K_STMEM; d_mfmt = M_I32; d_pop1 = d_reg[0]; end
                3'd5: begin d_kind = K_LDMEM; d_mfmt = M_T80; end
                3'd7: begin d_kind = K_STMEM; d_mfmt = M_T80; d_pop1 = 1'b1; end
                default: d_undone = 1'b1;
            endcase
            3'd5: case (d_reg)
                3'd0: begin d_kind = K_LDMEM; d_mfmt = M_F64; end
                3'd2, 3'd3: begin d_kind = K_STMEM; d_mfmt = M_F64; d_pop1 = d_reg[0]; end
                3'd4: begin d_kind = K_ENV; d_ctl = T_RSTOR; d_mfmt = M_W16; end
                3'd6: begin d_kind = K_ENV; d_ctl = T_SAVE; d_mfmt = M_W16; end
                3'd7: begin d_kind = K_CTL; d_ctl = T_STSW; d_mfmt = M_W16; end
                default: d_undone = 1'b1;
            endcase
            default: case (d_reg)                   // DF
                3'd0: begin d_kind = K_LDMEM; d_mfmt = M_I16; end
                3'd2, 3'd3: begin d_kind = K_STMEM; d_mfmt = M_I16; d_pop1 = d_reg[0]; end
                3'd4: begin d_kind = K_LDMEM; d_mfmt = M_T80; d_bcd = 1'b1; end         // FBLD
                3'd5: begin d_kind = K_LDMEM; d_mfmt = M_I64; end
                3'd6: begin d_kind = K_STMEM; d_mfmt = M_T80; d_bcd = 1'b1; d_pop1 = 1'b1; end  // FBSTP
                3'd7: begin d_kind = K_STMEM; d_mfmt = M_I64; d_pop1 = 1'b1; end
                default: d_undone = 1'b1;
            endcase
            endcase
        end else begin
            case ({esc, d_reg})
            6'o00, 6'o01, 6'o04, 6'o05, 6'o06, 6'o07: d_kind = K_ARITH;                    // D8: ST = ST op ST(i)
            6'o40, 6'o41, 6'o44, 6'o45, 6'o46, 6'o47: begin d_kind = K_ARITH; d_dst_i = 1'b1; end
            6'o60, 6'o61, 6'o64, 6'o65, 6'o66, 6'o67: begin d_kind = K_ARITH; d_dst_i = 1'b1; d_pop1 = 1'b1; end
            6'o02, 6'o42: d_kind = K_COMP;                                                  // FCOM
            6'o03, 6'o43, 6'o62: begin d_kind = K_COMP; d_pop1 = 1'b1; end                  // FCOMP
            6'o63: begin d_kind = K_COMP; d_pop1 = 1'b1; d_pop2 = 1'b1; end                 // FCOMPP (DE D9)
            6'o54: begin d_kind = K_COMP; d_quiet = 1'b1; end                               // FUCOM
            6'o55: begin d_kind = K_COMP; d_quiet = 1'b1; d_pop1 = 1'b1; end                // FUCOMP
            6'o25: begin d_kind = K_COMP; d_quiet = 1'b1; d_pop1 = 1'b1; d_pop2 = 1'b1; end // FUCOMPP (DA E9)
            6'o10: d_kind = K_LDREG;                                                        // FLD ST(i)
            6'o11, 6'o51, 6'o71: d_kind = K_XCH;                                            // FXCH
            6'o12: d_kind = K_CTL;                                                          // FNOP
            6'o50: begin d_kind = K_CTL; d_ctl = T_FREE; end
            6'o70: begin d_kind = K_CTL; d_ctl = T_FREEP; end
            6'o52: d_kind = K_STREG;                                                        // FST ST(i)
            6'o53, 6'o13, 6'o72, 6'o73: begin d_kind = K_STREG; d_pop1 = 1'b1; end          // FSTP ST(i)
            6'o14: case (d_rm)
                3'd0: d_kind = K_SIGN;                                                      // FCHS
                3'd1: begin d_kind = K_SIGN; d_abs = 1'b1; end                              // FABS
                3'd4: begin d_kind = K_COMP; d_tst = 1'b1; end                              // FTST
                3'd5: d_kind = K_XAM;
                default: d_undone = 1'b1;
            endcase
            6'o15: d_kind = K_CONST;                                                        // FLD1 ... FLDZ
            6'o16: case (d_rm)
                3'd0: begin d_trn = 1'b1; d_tfn = TF_2XM1; end                              // F2XM1
                3'd1: begin d_trn = 1'b1; d_tfn = TF_YL2X; end                              // FYL2X
                3'd2: begin d_trn = 1'b1; d_tfn = TF_SINCOS; d_tsub = 2'd3; end             // FPTAN
                3'd3: begin d_trn = 1'b1; d_tfn = TF_ATAN; end                              // FPATAN
                3'd4: d_kind = K_XTR;                                                       // FXTRACT
                3'd5: begin d_kind = K_BIN2; d_bin2 = 2'd1; end                             // FPREM1
                3'd6: begin d_kind = K_CTL; d_ctl = T_DEC; end
                3'd7: begin d_kind = K_CTL; d_ctl = T_INC; end
                default: d_undone = 1'b1;
            endcase
            6'o17: case (d_rm)
                3'd1: begin d_trn = 1'b1; d_tfn = TF_YL2XP1; end                            // FYL2XP1
                3'd3: begin d_trn = 1'b1; d_tfn = TF_SINCOS; d_tsub = 2'd2; end             // FSINCOS
                3'd6: begin d_trn = 1'b1; d_tfn = TF_SINCOS; d_tsub = 2'd0; end             // FSIN
                3'd7: begin d_trn = 1'b1; d_tfn = TF_SINCOS; d_tsub = 2'd1; end             // FCOS
                3'd0: d_kind = K_BIN2;                                                      // FPREM
                3'd5: begin d_kind = K_BIN2; d_bin2 = 2'd2; end                             // FSCALE
                3'd2: begin d_kind = K_UNARY; d_sqrt = 1'b1; end                            // FSQRT
                3'd4: d_kind = K_UNARY;                                                     // FRNDINT
                default: d_undone = 1'b1;
            endcase
            6'o34: case (d_rm)
                3'd2: begin d_kind = K_CTL; d_ctl = T_CLEX; end
                3'd3: begin d_kind = K_CTL; d_ctl = T_INIT; end
                default: d_kind = K_CTL;                                                    // FNENI and the like: nothing
            endcase
            6'o74: begin d_kind = K_CTL; d_ctl = (d_rm == 3'd0) ? T_STAX : T_NOP; end       // FNSTSW AX
            default: d_undone = 1'b1;
            endcase
        end
    end
    // The parts of the memory operand: how many are read, how many written.
    function [4:0] parts(input [2:0] f);
        parts = (f == M_T80) ? 5'd3 : (f == M_F64 || f == M_I64) ? 5'd2 : (f == M_REG) ? 5'd0 : 5'd1;
    endfunction
    // (The saved state: seven words, and with the registers 24 parts more.)
    wire [4:0] d_env_n = (d_ctl == T_SAVE || d_ctl == T_RSTOR) ? 5'd31 : 5'd7;
    wire d_reads  = (d_kind == K_ARITH || d_kind == K_COMP || d_kind == K_LDMEM ||
                     (d_kind == K_CTL && d_ctl == T_LDCW)) && d_mem;
    wire d_writes = (d_kind == K_STMEM || (d_kind == K_CTL && (d_ctl == T_STCW || d_ctl == T_STSW)));

    wire last16 = (mfmt == M_I16 || mfmt == M_W16 || mfmt == M_T80);
    wire in_reg = (xi >= 5'd7);         // of a saved state: in the registers
    assign more = after ? (xi < wr_n) : (xi < rd_n);
    // Exception 7 with CR0's EM or TS (for WAIT: MP and TS); exception
    // 16 when one that is not masked is pending, CR0's NE is set, and
    // the instruction is one that looks.
    reg        trap_r, trap_mf;
    wire       d_nowait = d_mem ? ((esc == 3'd1 || esc == 3'd5) && d_reg >= 3'd6)
                                : ((esc == 3'd3 && d_reg == 3'd4 && d_rm <= 3'd4) ||
                                   (esc == 3'd7 && d_reg == 3'd4 && d_rm == 3'd0));
    assign trap = trap_r;
    assign p16  = trap_r ? trap_mf : (kind == K_ENV) ? (in_reg ? (rpart == 2'd2) : !o32)
                                  : (last16 && (xi == (after ? wr_n : rd_n) - 5'd1));

    // ---- working it out ----
    localparam F_IDLE = 4'd0, F_CONV = 4'd1, F_CONVW = 4'd2, F_MAIN = 4'd3, F_MAINW = 4'd4,
               F_FIN = 4'd5, F_DONE = 4'd6, F_TRANS = 4'd7, F_TAN = 4'd8, F_TANW = 4'd9;
    reg [3:0]  fs;
    assign done = (fs == F_DONE);

    wire [2:0] top  = sw[13:11];
    wire [2:0] pi   = top + rm;
    wire       e0   = empty[top];
    wire       ei   = empty[pi];
    wire [79:0] st0 = st[top];
    wire [79:0] sti = st[pi];
    localparam [79:0] INDEF = 80'hFFFFC000000000000000;

    reg         ar_start;
    reg         ar_tctx;                // a step of a transcendental function: to nearest, 64 bits, no traps
    reg  [4:0]  ar_op;
    reg  [79:0] ar_a, ar_b;
    wire        ar_done;
    wire [79:0] ar_r, ar_r2;
    wire [6:0]  ar_fl;
    wire [3:0]  ar_c4;                  // C3, C2, C1, C0
    wire [2:0]  ar_cc = {ar_c4[3], ar_c4[2], ar_c4[0]};
    m86_fparith arith (.clk(clk), .rst(rst), .start(ar_start), .op(ar_op), .a(ar_a), .b(ar_b),
                       .rc(ar_tctx ? 2'd0 : cw[11:10]), .pc(ar_tctx ? 2'd3 : cw[9:8]),
                       .um(ar_tctx ? 2'd0 : {!cw[4], !cw[3]}),
                       .done(ar_done), .r(ar_r), .r2(ar_r2), .fl(ar_fl), .cc(ar_c4));

    reg  [79:0] opnd;
    reg  [6:0]  pre;                    // the flags of the memory operand's conversion
    wire        mem_op = (mfmt != M_REG);
    wire        fault_a = e0 || ((kind == K_ARITH || kind == K_COMP || kind == K_BIN2) && !mem_op && !tst && ei) ||
                          (t2op && ei);     // an operand's register is empty

    // The constants, by the rounding (the model's m86f_const).
    reg  [79:0] konst;
    wire        k_dn = (cw[11:10] == 2'd1) || (cw[11:10] == 2'd3);
    always @* begin
        case (rm)
        3'd0: konst = 80'h3FFF8000000000000000;
        3'd1: konst = {16'h4000, 64'hD49A784BCD1B8AFE + {63'd0, cw[11:10] == 2'd2}};
        3'd2: konst = {16'h3FFF, k_dn ? 64'hB8AA3B295C17F0BB : 64'hB8AA3B295C17F0BC};
        3'd3: konst = {16'h4000, k_dn ? 64'hC90FDAA22168C234 : 64'hC90FDAA22168C235};
        3'd4: konst = {16'h3FFD, k_dn ? 64'h9A209A84FBCFF798 : 64'h9A209A84FBCFF799};
        3'd5: konst = {16'h3FFE, k_dn ? 64'hB17217F7D1CF79AB : 64'hB17217F7D1CF79AC};
        default: konst = 80'd0;
        endcase
    end

    // ---- the saved state (FLDENV, FNSTENV, FNSAVE, FRSTOR) ----
    reg  [31:0] ew [0:6];               // the seven words, as they are read
    reg  [63:0] rbuf;
    reg  [15:0] tags;
    integer     tk;
    always @* begin
        for (tk = 0; tk < 8; tk = tk + 1)
            tags[2*tk +: 2] = empty[tk] ? 2'b11 :
                              (st[tk][78:64] == 15'd0) ? ((st[tk][63:0] == 64'd0) ? 2'b01 : 2'b10) :
                              (st[tk][63] && st[tk][78:64] != 15'h7FFF) ? 2'b00 : 2'b10;
    end
    wire [31:0] lip = {12'd0, fcs, 4'd0} + fip;         // (real mode keeps linear addresses)
    wire [31:0] ldp = {12'd0, fds, 4'd0} + fdp;
    reg  [31:0] envw;
    always @* begin
        case (xi[2:0])
        3'd0: envw = {16'hFFFF, cw};
        3'd1: envw = {16'hFFFF, sw};
        3'd2: envw = {16'hFFFF, tags};
        3'd3: envw = pm ? fip : {16'd0, lip[15:0]};
        3'd4: envw = pm ? {5'd0, fop, fcs} :
                     o32 ? {4'd0, lip[31:16], 1'b0, fop} : {16'd0, lip[19:16], 1'b0, fop};
        3'd5: envw = pm ? fdp : {16'd0, ldp[15:0]};
        default: envw = pm ? {16'hFFFF, fds} :
                        o32 ? {4'd0, ldp[31:16], 12'd0} : {16'd0, ldp[19:16], 12'd0};
        endcase
    end
    wire [2:0]  e_top = ew[1][13:11];   // the stack's top in a state being loaded
    wire [79:0] st_k  = st[top + rk];
    reg         n_env;

    // ---- the transcendental functions ----
    // Each is the model's sequence of operations (sim/m86fpu.c, from
    // "transcendental functions" on), step for step, on the arithmetic
    // above: to nearest and 64 bits, flags not kept (ar_tctx), but for
    // the last, which rounds as the control word says. The same
    // steps give the same bits.
    // BEGIN constants (made by tools/mkfpuconst_v.py from sim/m86fconst.h: do not edit)
    function [79:0] kconst(input [6:0] i);
        case (i)
        7'd0: kconst = 80'h3FFF8000000000000000;   // one
        7'd1: kconst = 80'h00000000000000000000;   // zero
        7'd2: kconst = 80'h40008000000000000000;   // two
        7'd3: kconst = 80'h40038000000000000000;   // sixteen
        7'd4: kconst = 80'h3FFEA2F9836E4E44152A;   // K_2OPI
        7'd5: kconst = 80'h3FFFC90FDAA200000000;   // K_PIO2_1
        7'd6: kconst = 80'h3FDD85A308D300000000;   // K_PIO2_2
        7'd7: kconst = 80'h3FBA98CC51701B839A25;   // K_PIO2_3
        7'd8: kconst = 80'h3FFEB17217F7D1CF79AC;   // K_LN2
        7'd9: kconst = 80'h3FFFB8AA3B295C17F0BC;   // K_L2E
        7'd10: kconst = 80'h4000C90FDAA22168C234;   // K_PI_HI
        7'd11: kconst = 80'h3FC0C4C6628B80DC1CD1;   // K_PI_LO
        7'd12: kconst = 80'h3FFFC90FDAA22168C234;   // K_PIO2_HI
        7'd13: kconst = 80'h3FBFC4C6628B80DC1CD1;   // K_PIO2_LO
        7'd14: kconst = 80'h3FFEC90FDAA22168C234;   // K_PIO4_HI
        7'd15: kconst = 80'h3FBEC4C6628B80DC1CD1;   // K_PIO4_LO
        7'd16: kconst = 80'h400096CBE3F9990E91A7;   // K_3PIO4_HI
        7'd17: kconst = 80'h3FC09394C9E8A0A5159D;   // K_3PIO4_LO
        7'd20: kconst = 80'hBFFCAAAAAAAAAAAAAAAB;   // K_SIN[0]
        7'd21: kconst = 80'h3FF88888888888888889;   // K_SIN[1]
        7'd22: kconst = 80'hBFF2D00D00D00D00D00D;   // K_SIN[2]
        7'd23: kconst = 80'h3FECB8EF1D2AB6399C7D;   // K_SIN[3]
        7'd24: kconst = 80'hBFE5D7322B3FAA271C7F;   // K_SIN[4]
        7'd25: kconst = 80'h3FDEB092309D43684BE5;   // K_SIN[5]
        7'd26: kconst = 80'hBFD6D73F9F399DC0F88F;   // K_SIN[6]
        7'd27: kconst = 80'h3FCECA963B81856A5359;   // K_SIN[7]
        7'd28: kconst = 80'hBFC697A4DA340A0AB926;   // K_SIN[8]
        7'd29: kconst = 80'h3FBDB8DC77B6E7AB8C5F;   // K_SIN[9]
        7'd30: kconst = 80'h3FFAAAAAAAAAAAAAAAAB;   // K_COS[0]
        7'd31: kconst = 80'hBFF5B60B60B60B60B60B;   // K_COS[1]
        7'd32: kconst = 80'h3FEFD00D00D00D00D00D;   // K_COS[2]
        7'd33: kconst = 80'hBFE993F27DBBC4FAE397;   // K_COS[3]
        7'd34: kconst = 80'h3FE28F76C77FC6C4BDAA;   // K_COS[4]
        7'd35: kconst = 80'hBFDAC9CBA54603E4E906;   // K_COS[5]
        7'd36: kconst = 80'h3FD2D73F9F399DC0F88F;   // K_COS[6]
        7'd37: kconst = 80'hBFCAB413C31DCBECBBDE;   // K_COS[7]
        7'd38: kconst = 80'h3FC1F2A15D201011283D;   // K_COS[8]
        7'd39: kconst = 80'hBFB98671CB6DBFC294A3;   // K_COS[9]
        7'd40: kconst = 80'h3FFE8000000000000000;   // K_EXP[0]
        7'd41: kconst = 80'h3FFCAAAAAAAAAAAAAAAB;   // K_EXP[1]
        7'd42: kconst = 80'h3FFAAAAAAAAAAAAAAAAB;   // K_EXP[2]
        7'd43: kconst = 80'h3FF88888888888888889;   // K_EXP[3]
        7'd44: kconst = 80'h3FF5B60B60B60B60B60B;   // K_EXP[4]
        7'd45: kconst = 80'h3FF2D00D00D00D00D00D;   // K_EXP[5]
        7'd46: kconst = 80'h3FEFD00D00D00D00D00D;   // K_EXP[6]
        7'd47: kconst = 80'h3FECB8EF1D2AB6399C7D;   // K_EXP[7]
        7'd48: kconst = 80'h3FE993F27DBBC4FAE397;   // K_EXP[8]
        7'd49: kconst = 80'h3FE5D7322B3FAA271C7F;   // K_EXP[9]
        7'd50: kconst = 80'h3FE28F76C77FC6C4BDAA;   // K_EXP[10]
        7'd51: kconst = 80'h3FDEB092309D43684BE5;   // K_EXP[11]
        7'd52: kconst = 80'h3FDAC9CBA54603E4E906;   // K_EXP[12]
        7'd53: kconst = 80'h3FD6D73F9F399DC0F88F;   // K_EXP[13]
        7'd54: kconst = 80'h3FD2D73F9F399DC0F88F;   // K_EXP[14]
        7'd55: kconst = 80'h3FCECA963B81856A5359;   // K_EXP[15]
        7'd56: kconst = 80'h3FCAB413C31DCBECBBDE;   // K_EXP[16]
        7'd57: kconst = 80'h3FC697A4DA340A0AB926;   // K_EXP[17]
        7'd58: kconst = 80'h3FC1F2A15D201011283D;   // K_EXP[18]
        7'd59: kconst = 80'h3FBDB8DC77B6E7AB8C5F;   // K_EXP[19]
        7'd60: kconst = 80'h3FB98671CB6DBFC294A3;   // K_EXP[20]
        7'd61: kconst = 80'h3FB4BB0DA098B1C0CECC;   // K_EXP[21]
        7'd62: kconst = 80'h3FFF8000000000000000;   // K_LOG[0]
        7'd63: kconst = 80'h3FFDAAAAAAAAAAAAAAAB;   // K_LOG[1]
        7'd64: kconst = 80'h3FFCCCCCCCCCCCCCCCCD;   // K_LOG[2]
        7'd65: kconst = 80'h3FFC9249249249249249;   // K_LOG[3]
        7'd66: kconst = 80'h3FFBE38E38E38E38E38E;   // K_LOG[4]
        7'd67: kconst = 80'h3FFBBA2E8BA2E8BA2E8C;   // K_LOG[5]
        7'd68: kconst = 80'h3FFB9D89D89D89D89D8A;   // K_LOG[6]
        7'd69: kconst = 80'h3FFB8888888888888889;   // K_LOG[7]
        7'd70: kconst = 80'h3FFAF0F0F0F0F0F0F0F1;   // K_LOG[8]
        7'd71: kconst = 80'h3FFAD79435E50D79435E;   // K_LOG[9]
        7'd72: kconst = 80'h3FFAC30C30C30C30C30C;   // K_LOG[10]
        7'd73: kconst = 80'h3FFAB21642C8590B2164;   // K_LOG[11]
        7'd74: kconst = 80'h3FFAA3D70A3D70A3D70A;   // K_LOG[12]
        7'd75: kconst = 80'h3FFA97B425ED097B425F;   // K_LOG[13]
        7'd76: kconst = 80'h3FFF8000000000000000;   // K_ATAN[0]
        7'd77: kconst = 80'hBFFDAAAAAAAAAAAAAAAB;   // K_ATAN[1]
        7'd78: kconst = 80'h3FFCCCCCCCCCCCCCCCCD;   // K_ATAN[2]
        7'd79: kconst = 80'hBFFC9249249249249249;   // K_ATAN[3]
        7'd80: kconst = 80'h3FFBE38E38E38E38E38E;   // K_ATAN[4]
        7'd81: kconst = 80'hBFFBBA2E8BA2E8BA2E8C;   // K_ATAN[5]
        7'd82: kconst = 80'h3FFB9D89D89D89D89D8A;   // K_ATAN[6]
        7'd83: kconst = 80'hBFFB8888888888888889;   // K_ATAN[7]
        7'd84: kconst = 80'h00000000000000000000;   // K_ATANT[0]
        7'd85: kconst = 80'h3FFAFFAADDB967EF4E37;   // K_ATANT[1]
        7'd86: kconst = 80'h3FFBFEADD4D5617B6E33;   // K_ATANT[2]
        7'd87: kconst = 80'h3FFCBDCBDA5E72D81134;   // K_ATANT[3]
        7'd88: kconst = 80'h3FFCFADBAFC96406EB15;   // K_ATANT[4]
        7'd89: kconst = 80'h3FFD9B13B9B83F5E5E6A;   // K_ATANT[5]
        7'd90: kconst = 80'h3FFDB7B0CA0F26F78474;   // K_ATANT[6]
        7'd91: kconst = 80'h3FFDD327761E611FE5B6;   // K_ATANT[7]
        7'd92: kconst = 80'h3FFDED63382B0DDA7B45;   // K_ATANT[8]
        7'd93: kconst = 80'h3FFE832BF4A6D9867E2A;   // K_ATANT[9]
        7'd94: kconst = 80'h3FFE8F005D5EF7F59F9B;   // K_ATANT[10]
        7'd95: kconst = 80'h3FFE9A2F80E671BDDA20;   // K_ATANT[11]
        7'd96: kconst = 80'h3FFEA4BC7D1934F70924;   // K_ATANT[12]
        7'd97: kconst = 80'h3FFEAEAC4C38B4D8C080;   // K_ATANT[13]
        7'd98: kconst = 80'h3FFEB8053E2BC2319E74;   // K_ATANT[14]
        7'd99: kconst = 80'h3FFEC0CE85B8AC526641;   // K_ATANT[15]
        7'd100: kconst = 80'h3FFEC90FDAA22168C235;   // K_ATANT[16]
        default: kconst = 80'd0;
        endcase
    endfunction
    // END constants
    // The working registers: ST and ST(1) as they are (0 and 1), twelve
    // in LUT RAM with two read ports (2 to 13), and the two results.
    localparam X0 = 4'd0, X1 = 4'd1, RR = 4'd2, RZ = 4'd3, RP = 4'd4, TA = 4'd5, TB = 4'd6,
               RU = 4'd7, HI = 4'd8, LO = 4'd9, SR = 4'd10, CR = 4'd11, FN = 4'd12, SG = 4'd13,
               RS = 4'd14, RC = 4'd15;
    reg  [79:0] tm [0:15];
    reg  [79:0] rs_r, rc_r;             // the function's results
    reg  [79:0] tlast;                  // the last operation's result,
    reg  [79:0] tx2;                    // its second result,
    reg  [3:0]  tcc;                    // and its condition bits
    reg  [6:0]  tfl;                    // the function's flags
    reg         t_range;                // the operand is too large (C2)
    reg  [5:0]  ts, ts_ret, p_ret, f_ret;
    reg  [3:0]  ts_dst;
    reg         ts_real;
    reg  [6:0]  p_base;
    reg  [4:0]  p_cnt;
    reg         t_swap, t_big, t_z1, e_nz;
    reg  [4:0]  t_k;
    // A step's operands: a register or (bit 7) a constant, and what is
    // done to it on the way: its magnitude, its negative, half of it,
    // twice it, a sixteenth of it; or (6) the logarithm's argument made
    // from FXTRACT's significand.
    reg  [7:0]  sa, sb;
    reg  [2:0]  sma, smb;
    reg  [4:0]  q_op;
    localparam M_NO = 3'd0, M_MAG = 3'd1, M_NEG = 3'd2, M_HALF = 3'd3, M_TWICE = 3'd4,
               M_16TH = 3'd5, M_FX = 3'd6;
    localparam [79:0] K_ONE = 80'h3FFF8000000000000000;

    function [2:0] kls(input [79:0] v);     // zero, denormal, normal, infinite, quiet NaN, signalling, unsupported
        kls = (v[78:64] == 15'd0) ? ((v[63:0] != 64'd0) ? 3'd1 : 3'd0) :
              !v[63] ? 3'd6 : (v[78:64] != 15'h7FFF) ? 3'd2 :
              (v[62:0] == 63'd0) ? 3'd3 : v[62] ? 3'd4 : 3'd5;
    endfunction
    // What two operands give when one is not a number: the result, and
    // above it whether that is an invalid operation.
    function [80:0] nan2(input [79:0] a, input [79:0] b);
        reg [2:0] ka, kb;
        reg an, bn, pa;
        begin
            ka = kls(a); kb = kls(b);
            an = (ka == 3'd4 || ka == 3'd5); bn = (kb == 3'd4 || kb == 3'd5);
            pa = !bn ? 1'b1 : !an ? 1'b0 : (ka != kb) ? (ka == 3'd4) :
                 (a[63:0] != b[63:0]) ? (a[63:0] > b[63:0]) : !a[79];
            if (ka == 3'd6 || kb == 3'd6)
                nan2 = {1'b1, INDEF};
            else
                nan2 = {ka == 3'd5 || kb == 3'd5, (pa ? a : b) | 80'h00004000000000000000};
        end
    endfunction
    wire [79:0] x0 = st0, x1 = sti;
    wire [2:0]  k0 = kls(x0), k1 = kls(x1);
    wire        nn0 = (k0 >= 3'd4), nn1 = (k1 >= 3'd4);         // not a number (or unsupported)
    wire [80:0] n2_00 = nan2(x0, x0);
    wire [80:0] n2_10 = nan2(x1, x0);
    wire        den01 = (k0 == 3'd1) || (k1 == 3'd1);
    wire        fx_big = (tx2[63:0] > 64'hB504F333F9DE6484);    // over the square root of 2

    function [79:0] modify(input [79:0] v, input [2:0] m, input [79:0] fx);
        case (m)
        M_MAG:   modify = {1'b0, v[78:0]};
        M_NEG:   modify = {!v[79], v[78:0]};
        M_HALF:  modify = (v[78:0] == 79'd0) ? v : {v[79], v[78:64] - 15'd1, v[63:0]};
        M_TWICE: modify = (v[78:0] == 79'd0) ? v : {v[79], v[78:64] + 15'd1, v[63:0]};
        M_16TH:  modify = {v[79], v[78:64] - 15'd4, v[63:0]};
        M_FX:    modify = fx;
        default: modify = v;
        endcase
    endfunction
    wire [79:0] ka_q = kconst(sa[6:0]);
    wire [79:0] kb_q = kconst(sb[6:0]);
    wire [79:0] ta_q = tm[sa[3:0]];
    wire [79:0] tb_q = tm[sb[3:0]];
    wire [79:0] fx_v = {1'b0, fx_big ? 15'h3FFE : 15'h3FFF, tx2[63:0]};
    wire [79:0] opA  = modify(sa[7] ? ka_q : (sa[3:0] == X0) ? x0 : (sa[3:0] == X1) ? x1 : ta_q, sma, fx_v);
    wire [79:0] opB  = modify(sb[7] ? kb_q : (sb[3:0] == X0) ? x0 : (sb[3:0] == X1) ? x1 : tb_q, smb, fx_v);
    // The working registers' one write: an operation's result, or a move.
    reg         tw_en;
    reg  [3:0]  tw_a;
    reg  [79:0] tw_d;
    always @(posedge clk)
        if (tw_en) tm[tw_a] <= tw_d;

    localparam TS_START = 6'd0, TS_WAIT = 6'd1, TS_DONE = 6'd2, TS_GO = 6'd3,
               TS_P0 = 6'd4, TS_P1 = 6'd5, TS_P2 = 6'd6, G0 = 6'd7,
               SC1 = 6'd8, SC2 = 6'd9, SC3 = 6'd10, SC4 = 6'd11, SC5 = 6'd12, SC6 = 6'd13, SC7 = 6'd14,
               SC8 = 6'd15, SC10 = 6'd16, SC11 = 6'd17, SC12 = 6'd18, SC13 = 6'd19, SC14 = 6'd20,
               SC15 = 6'd21, SC16 = 6'd22, SC17 = 6'd23, SC18 = 6'd24, SC19 = 6'd25, SC20 = 6'd26,
               SC21 = 6'd27, TS_F2 = 6'd28, AT5B = 6'd29,
               AT1 = 6'd30, AT2 = 6'd31, AT3 = 6'd32, AT4 = 6'd33, AT5 = 6'd34, AT6 = 6'd35, AT7 = 6'd36,
               AT8 = 6'd37, AT9 = 6'd38, AT10 = 6'd39, AT11 = 6'd40, AT12 = 6'd41, AT13 = 6'd42,
               AT14 = 6'd43, AT15 = 6'd44, AT16 = 6'd45, AT17 = 6'd46, AT20 = 6'd47, AT21 = 6'd48,
               EX1 = 6'd49, EX2 = 6'd50, EX3 = 6'd51, EX4 = 6'd52, EX5 = 6'd53,
               LG1 = 6'd54, LG2 = 6'd55, LG3 = 6'd56, LG4 = 6'd57, LG5 = 6'd58, LG10 = 6'd59,
               LG11 = 6'd60, LG20 = 6'd61, LG21 = 6'd62, LG2B = 6'd63;
    // (More states than six bits number: the rest are told apart by these.)
    reg  [2:0]  gs;                     // the logarithm's shared part
    reg  [1:0]  xs2;                    // AT12's and AT17's later parts
    localparam [4:0] A_ADD = 5'd0, A_SUB = 5'd1, A_MUL = 5'd2, A_DIV = 5'd3, A_UCOM = 5'd5,
                     A_TOI16 = 5'd8, A_TOI64 = 5'd10, A_FROMI = 5'd11, A_XTR = 5'd19,
                     A_MOVE = 5'd31;    // (no operation: the first operand as it is)
    wire [7:0]  p_sel  = {1'b1, p_base + {2'd0, p_cnt}};       // a polynomial's next constant
    wire [7:0]  at_sel = {1'b1, 7'd84 + {2'd0, t_k}};          // atan(k/16)
`define RG(R) {4'd0, R}
`define KC(I) {1'b1, I}
    // One step: the operation, its operands, where the result goes, what is next.
`define TDO(OPC, SA, MA, SB, MB, DST, NXT) \
    begin q_op <= OPC; sa <= SA; sma <= MA; sb <= SB; smb <= MB; \
          ts_dst <= DST; ts_ret <= NXT; ts_real <= 1'b0; ts <= TS_GO; end
    // The same, rounding as the control word says, and its flags kept.
`define TDOR(OPC, SA, MA, SB, MB, DST, NXT) \
    begin q_op <= OPC; sa <= SA; sma <= MA; sb <= SB; smb <= MB; \
          ts_dst <= DST; ts_ret <= NXT; ts_real <= 1'b1; ts <= TS_GO; end
    // A polynomial in RZ by the constants from BASE, N of them, into RP.
`define TPOLY(BASE, N, NXT) \
    begin p_base <= BASE; p_cnt <= N - 5'd1; p_ret <= NXT; ts <= TS_P0; end
    // The final result: SRC (MA: as it is, or its negative) rounded as
    // the control word says into DST.
`define TFINAL(SRC, MA, DST, NXT) \
    begin sa <= SRC; sma <= MA; ts_dst <= DST; f_ret <= NXT; ts <= TS_F2; end

    // ---- the new state, kept until COMMIT ----
    reg  [15:0] n_sw, n_cw;
    reg  [7:0]  n_empty;
    reg         w0_en, w1_en;
    reg  [2:0]  w0_i, w1_i;
    reg  [79:0] w0_v, w1_v;
    reg         n_init;

    // (Worked on in F_FIN with blocking assignments.)
    reg  [15:0] t_sw;
    reg  [7:0]  t_em;
    reg  [2:0]  t_top;
    reg         t_go;
    reg  [6:0]  t_fl;
    reg  [79:0] t_v;
    reg  [2:0]  t_cc;
    integer     j;

    wire [2:0]  cls0 = (st0[78:64] == 15'd0) ? ((st0[63:0] != 64'd0) ? 3'd1 : 3'd0) :
                       !st0[63] ? 3'd6 : (st0[78:64] != 15'h7FFF) ? 3'd2 :
                       (st0[62:0] == 63'd0) ? 3'd3 : 3'd4;       // zero, denormal, normal, infinite, NaN; 6 unsupported

    always @(posedge clk) begin
        ar_start <= 1'b0;
        ar_tctx  <= 1'b0;
        tw_en    <= 1'b0;
        case (fs)
        F_CONV: begin
            // The memory operand as a number.
            opnd <= mem_op ? mbuf : tst ? 80'd0 : sti;
            pre  <= 7'd0;
            fs   <= F_MAIN;
            if (mem_op && (mfmt != M_T80 || isbcd) && (kind == K_ARITH || kind == K_COMP || kind == K_LDMEM)) begin
                ar_start <= 1'b1;
                ar_op <= isbcd ? 5'd20 : (mfmt == M_F32) ? 5'd14 : (mfmt == M_F64) ? 5'd15 : 5'd11;
                ar_a  <= (mfmt == M_I16) ? {16'd0, {48{mbuf[15]}}, mbuf[15:0]} :
                         (mfmt == M_I32) ? {16'd0, {32{mbuf[31]}}, mbuf[31:0]} : mbuf;
                ar_b  <= 80'd0;
                fs    <= F_CONVW;
            end
        end
        F_CONVW: if (ar_done) begin
            opnd <= ar_r;
            pre  <= ar_fl;
            fs   <= F_MAIN;
        end
        F_MAIN: begin
            fs <= F_FIN;
            if (trn && !fault_a) begin
                ts <= TS_START;
                fs <= F_TRANS;
            end
            if (!fault_a && (kind == K_ARITH || kind == K_COMP || kind == K_UNARY || kind == K_BIN2 ||
                             kind == K_XTR || (kind == K_STMEM && (mfmt != M_T80 || isbcd)))) begin
                ar_start <= 1'b1;
                fs <= F_MAINW;
                ar_a <= st0;
                ar_b <= opnd;
                case (kind)
                K_ARITH: begin
                    ar_op <= (aop == 3'd0) ? 5'd0 : (aop == 3'd1) ? 5'd2 : aop[2:1] == 2'b10 ? 5'd1 : 5'd3;
                    if (aop == 3'd5 || aop == 3'd7) begin   // the other way round
                        ar_a <= opnd;
                        ar_b <= st0;
                    end
                end
                K_COMP: ar_op <= quiet ? 5'd5 : 5'd4;
                K_UNARY: ar_op <= issqrt ? 5'd6 : 5'd7;
                K_BIN2: ar_op <= (bin2 == 2'd0) ? 5'd16 : (bin2 == 2'd1) ? 5'd17 : 5'd18;
                K_XTR: ar_op <= 5'd19;
                default: ar_op <= isbcd ? 5'd21 : (mfmt == M_F32) ? 5'd12 : (mfmt == M_F64) ? 5'd13 :
                                  (mfmt == M_I16) ? 5'd8 : (mfmt == M_I32) ? 5'd9 : 5'd10;
                endcase
            end
        end
        F_MAINW: if (ar_done) fs <= F_FIN;
        // ---- a transcendental function, step by step ----
        F_TRANS: case (ts)
        TS_GO: begin
            if (q_op == A_MOVE) begin
                if (ts_dst == RS) rs_r <= opA;
                else if (ts_dst == RC) rc_r <= opA;
                else begin tw_en <= 1'b1; tw_a <= ts_dst; tw_d <= opA; end
                ts <= ts_ret;
            end else begin
                ar_start <= 1'b1;
                ar_tctx  <= !ts_real;
                ar_op <= q_op;
                ar_a  <= opA;
                ar_b  <= opB;
                ts <= TS_WAIT;
            end
        end
        TS_WAIT: if (ar_done) begin
            if (ts_dst == RS) rs_r <= ar_r;
            else if (ts_dst == RC) rc_r <= ar_r;
            else begin tw_en <= 1'b1; tw_a <= ts_dst; tw_d <= ar_r; end
            tlast <= ar_r;
            tx2 <= ar_r2;
            tcc <= ar_c4;
            if (ts_real) tfl <= tfl | ar_fl;
            ts <= ts_ret;
        end
        TS_F2: begin
            // (Zero stays as it is, sign and all, and is exact.)
            if (kls(opA) == 3'd0) begin
                if (ts_dst == RS) rs_r <= opA; else rc_r <= opA;
                ts <= f_ret;
            end else begin
                tfl <= tfl | 7'h20;
                ar_start <= 1'b1;
                ar_op <= A_ADD;
                ar_a  <= opA;
                ar_b  <= 80'd0;
                ts_ret <= f_ret;
                ts_real <= 1'b1;
                ts <= TS_WAIT;
            end
        end
        TS_P0: begin
            `TDO(A_MOVE, p_sel, M_NO, `KC(7'd1), M_NO, RP, TS_P1)
            p_cnt <= p_cnt - 5'd1;
        end
        TS_P1: `TDO(A_MUL, `RG(RP), M_NO, `RG(RZ), M_NO, RP, TS_P2)
        TS_P2: begin
            `TDO(A_ADD, `RG(RP), M_NO, p_sel, M_NO, RP, (p_cnt == 5'd0) ? p_ret : TS_P1)
            p_cnt <= p_cnt - 5'd1;
        end
        TS_DONE: fs <= (tfn == TF_SINCOS && tsub == 2'd3) ? F_TAN : F_FIN;

        TS_START: begin
            tfl <= 7'd0;
            t_range <= 1'b0;
            gs <= 3'd0;
            xs2 <= 2'd0;
            ts <= TS_DONE;                  // (unless said otherwise below)
            case (tfn)
            TF_SINCOS: begin
                if (nn0) begin
                    rs_r <= n2_00[79:0]; rc_r <= n2_00[79:0];
                    tfl <= {6'd0, n2_00[80]};
                end else if (k0 == 3'd3) begin
                    rs_r <= INDEF; rc_r <= INDEF;
                    tfl <= 7'h01;
                end else if (k0 == 3'd0) begin
                    rs_r <= x0; rc_r <= K_ONE;
                end else begin
                    tfl <= {5'd0, k0 == 3'd1, 1'b0};
                    if (x0[78:64] >= 15'd16446)             // 2^63 or more
                        t_range <= 1'b1;
                    else if (x0[78:64] < 15'd16349) begin   // x and 1 to more than 64 bits
                        tfl <= {1'b0, 1'b1, 3'd0, k0 == 3'd1, 1'b0};
                        rc_r <= K_ONE;
                        `TFINAL(`RG(X0), M_NO, RS, TS_DONE)
                    end else
                        `TDO(A_MUL, `RG(X0), M_NO, `KC(7'd4), M_NO, TA, SC1)
                end
            end
            TF_ATAN: begin                  // atan2(y, x): y is ST(1), x is ST
                if (nn0 || nn1) begin
                    rs_r <= n2_10[79:0];
                    tfl <= {6'd0, n2_10[80]};
                end else begin
                    tfl <= {5'd0, den01, 1'b0};
                    if (k1 == 3'd0) begin
                        if (!x0[79]) rs_r <= x1;
                        else `TDO(A_ADD, `KC(7'd10), M_NO, `KC(7'd11), M_NO, RR, AT21)
                    end else if (k0 == 3'd0 || (k1 == 3'd3 && k0 != 3'd3))
                        `TDO(A_ADD, `KC(7'd12), M_NO, `KC(7'd13), M_NO, RR, AT21)
                    else if (k1 == 3'd3) begin
                        if (x0[79]) `TDO(A_ADD, `KC(7'd16), M_NO, `KC(7'd17), M_NO, RR, AT21)
                        else        `TDO(A_ADD, `KC(7'd14), M_NO, `KC(7'd15), M_NO, RR, AT21)
                    end else if (k0 == 3'd3) begin
                        if (!x0[79]) rs_r <= {x1[79], 79'd0};
                        else `TDO(A_ADD, `KC(7'd10), M_NO, `KC(7'd11), M_NO, RR, AT21)
                    end else
                        `TDO(A_UCOM, `RG(X1), M_MAG, `RG(X0), M_MAG, TA, AT1)
                end
            end
            TF_2XM1: begin
                if (nn0) begin
                    rs_r <= n2_00[79:0];
                    tfl <= {6'd0, n2_00[80]};
                end else if (k0 == 3'd0)
                    rs_r <= x0;
                else if (k0 == 3'd3)
                    rs_r <= x0[79] ? {1'b1, K_ONE[78:0]} : x0;
                else begin
                    tfl <= {5'd0, k0 == 3'd1, 1'b0};
                    `TDO(A_MUL, `RG(X0), M_NO, `KC(7'd8), M_NO, RZ, EX1)
                end
            end
            TF_YL2X: begin                  // y log2(x): x is ST, y is ST(1)
                if (nn0 || nn1) begin
                    rs_r <= n2_10[79:0];
                    tfl <= {6'd0, n2_10[80]};
                end else if (k0 == 3'd0) begin
                    if (k1 == 3'd0) begin
                        rs_r <= INDEF; tfl <= 7'h01;
                    end else begin
                        tfl <= (k1 != 3'd3) ? 7'h04 : 7'h00;
                        rs_r <= {!x1[79], 15'h7FFF, 64'h8000000000000000};
                    end
                end else if (x0[79]) begin
                    rs_r <= INDEF; tfl <= 7'h01;
                end else begin
                    tfl <= {5'd0, den01, 1'b0};
                    if (k0 == 3'd3)
                        `TDOR(A_MUL, `RG(X1), M_NO, `RG(X0), M_NO, RS, LG21)
                    else
                        `TDO(A_XTR, `RG(X0), M_NO, `KC(7'd1), M_NO, FN, LG1)
                end
            end
            default: begin                  // y log2(1 + x)
                if (nn0 || nn1) begin
                    rs_r <= n2_10[79:0];
                    tfl <= {6'd0, n2_10[80]};
                end else begin
                    tfl <= {5'd0, den01, 1'b0};
                    if (k0 == 3'd0 || k0 == 3'd3)
                        `TDOR(A_MUL, `RG(X1), M_NO, `RG(X0), M_NO, RS, LG21)
                    else
                        `TDO(A_ADD, `KC(7'd2), M_NO, `RG(X0), M_NO, TA, LG2B)
                end
            end
            endcase
        end

        // sine and cosine: r = x - n pi/2, n the nearest integer to x * 2/pi
        SC1: `TDO(A_TOI64, `RG(TA), M_NO, `KC(7'd1), M_NO, FN, SC2)
        SC2: begin
            t_k <= {3'd0, tlast[1:0]};      // (the quadrant: n's lowest bits)
            if (tlast[63:0] == 64'd0)
                `TDO(A_MOVE, `RG(X0), M_NO, `KC(7'd1), M_NO, RR, SC10)
            else
                `TDO(A_FROMI, `RG(FN), M_NO, `KC(7'd1), M_NO, FN, SC3)
        end
        SC3: `TDO(A_MUL, `RG(FN), M_NO, `KC(7'd5), M_NO, TA, SC4)
        SC4: `TDO(A_SUB, `RG(X0), M_NO, `RG(TA), M_NO, RR, SC5)
        SC5: `TDO(A_MUL, `RG(FN), M_NO, `KC(7'd6), M_NO, TA, SC6)
        SC6: `TDO(A_SUB, `RG(RR), M_NO, `RG(TA), M_NO, RR, SC7)
        SC7: `TDO(A_MUL, `RG(FN), M_NO, `KC(7'd7), M_NO, TA, SC8)
        SC8: `TDO(A_SUB, `RG(RR), M_NO, `RG(TA), M_NO, RR, SC10)
        SC10: `TDO(A_MUL, `RG(RR), M_NO, `RG(RR), M_NO, RZ, SC11)
        SC11: `TPOLY(7'd20, 5'd10, SC12)
        SC12: `TDO(A_MUL, `RG(RR), M_NO, `RG(RZ), M_NO, TA, SC13)
        SC13: `TDO(A_MUL, `RG(TA), M_NO, `RG(RP), M_NO, TA, SC14)
        SC14: `TDO(A_ADD, `RG(RR), M_NO, `RG(TA), M_NO, SR, SC15)
        SC15: `TPOLY(7'd30, 5'd10, SC16)
        SC16: `TDO(A_MUL, `RG(RZ), M_NO, `RG(RZ), M_NO, TA, SC17)
        SC17: `TDO(A_MUL, `RG(TA), M_NO, `RG(RP), M_NO, TA, SC18)
        SC18: `TDO(A_SUB, `KC(7'd0), M_NO, `RG(RZ), M_HALF, TB, SC19)
        SC19: `TDO(A_ADD, `RG(TB), M_NO, `RG(TA), M_NO, CR, SC20)
        // By the quadrant: the sine is s, c, -s, -c and the cosine c, -s, -c, s.
        SC20: `TFINAL(t_k[0] ? `RG(CR) : `RG(SR), t_k[1] ? M_NEG : M_NO, RS, SC21)
        SC21: `TFINAL(t_k[0] ? `RG(SR) : `RG(CR), (t_k[1] ^ t_k[0]) ? M_NEG : M_NO, RC, TS_DONE)

        // arctangent
        AT1: begin
            t_swap <= (tcc[3:2] == 2'b00) && !tcc[0];       // |y| > |x|
            if ((tcc[3:2] == 2'b00) && !tcc[0])
                `TDO(A_DIV, `RG(X0), M_MAG, `RG(X1), M_MAG, RU, AT3)
            else
                `TDO(A_DIV, `RG(X1), M_MAG, `RG(X0), M_MAG, RU, AT3)
        end
        AT3: `TDO(A_MUL, `RG(RU), M_NO, `KC(7'd3), M_NO, TA, AT4)
        AT4: `TDO(A_TOI16, `RG(TA), M_NO, `KC(7'd1), M_NO, FN, AT5)
        AT5: begin
            t_k <= tlast[4:0];
            `TDO(A_MOVE, `RG(RU), M_NO, `KC(7'd1), M_NO, SG, AT5B)      // (t itself)
        end
        AT5B: begin
            if (t_k == 5'd0)
                ts <= AT10;
            else
                `TDO(A_FROMI, `RG(FN), M_NO, `KC(7'd1), M_NO, TB, AT6)
        end
        AT6: `TDO(A_MOVE, `RG(TB), M_16TH, `KC(7'd1), M_NO, TB, AT7)   // k / 16
        AT7: `TDO(A_SUB, `RG(SG), M_NO, `RG(TB), M_NO, TA, AT8)
        AT8: `TDO(A_MUL, `RG(SG), M_NO, `RG(TB), M_NO, TB, AT9)
        AT9: `TDO(A_ADD, `KC(7'd0), M_NO, `RG(TB), M_NO, TB, AT2)
        AT2: `TDO(A_DIV, `RG(TA), M_NO, `RG(TB), M_NO, RU, AT10)
        AT10: `TDO(A_MUL, `RG(RU), M_NO, `RG(RU), M_NO, RZ, AT11)
        AT11: `TPOLY(7'd76, 5'd8, AT12)
        AT12: begin
            if (xs2 == 2'd0) begin
                `TDO(A_MUL, `RG(RU), M_NO, `RG(RP), M_NO, LO, AT12)
                xs2 <= 2'd1;
            end else begin
                `TDO(A_MOVE, at_sel, M_NO, `KC(7'd1), M_NO, HI, AT13)
                xs2 <= 2'd0;
            end
        end
        AT13: if (t_swap) `TDO(A_SUB, `KC(7'd12), M_NO, `RG(HI), M_NO, HI, AT14) else ts <= AT15;
        AT14: `TDO(A_SUB, `KC(7'd13), M_NO, `RG(LO), M_NO, LO, AT15)
        AT15: if (x0[79]) `TDO(A_SUB, `KC(7'd10), M_NO, `RG(HI), M_NO, HI, AT16) else ts <= AT17;
        AT16: `TDO(A_SUB, `KC(7'd11), M_NO, `RG(LO), M_NO, LO, AT17)
        AT17: begin
            // Both parts nothing (the quotient underflowed): zero.
            case (xs2)
            2'd0: begin sa <= `RG(HI); sma <= M_NO; xs2 <= 2'd1; end
            2'd1: begin t_z1 <= (kls(opA) == 3'd0); sa <= `RG(LO); xs2 <= 2'd2; end
            default: begin
                xs2 <= 2'd0;
                if (t_z1 && kls(opA) == 3'd0) begin
                    tfl <= tfl | 7'h30;
                    rs_r <= {x1[79], 79'd0};
                    ts <= TS_DONE;
                end else
                    ts <= AT20;
            end
            endcase
        end
        AT20: `TDO(A_ADD, `RG(HI), M_NO, `RG(LO), M_NO, RR, AT21)
        AT21: `TFINAL(`RG(RR), x1[79] ? M_NEG : M_NO, RS, TS_DONE)

        // 2^x - 1 = e^z - 1 = z + z^2 (1/2 + z/6 + ...), z = x ln 2
        EX1: `TPOLY(7'd40, 5'd22, EX2)
        EX2: `TDO(A_MUL, `RG(RZ), M_NO, `RG(RZ), M_NO, TA, EX3)
        EX3: `TDO(A_MUL, `RG(TA), M_NO, `RG(RP), M_NO, TA, EX4)
        EX4: `TDO(A_ADD, `RG(RZ), M_NO, `RG(TA), M_NO, RR, EX5)
        EX5: begin
            if (kls(tlast) == 3'd1 || kls(tlast) == 3'd0) begin
                tfl <= tfl | 7'h30;
                rs_r <= tlast;
                ts <= TS_DONE;
            end else
                `TFINAL(`RG(RR), M_NO, RS, TS_DONE)
        end

        // y log2(x): x as f 2^e with f between root one-half and root two
        LG1: begin
            // (FXTRACT's two results: e in FN, the significand in tx2.)
            t_big <= fx_big;
            `TDO(A_MOVE, `KC(7'd1), M_FX, `KC(7'd1), M_NO, SG, LG2)
        end
        LG2: if (t_big) `TDO(A_ADD, `RG(FN), M_NO, `KC(7'd0), M_NO, FN, LG3) else ts <= LG3;
        LG3: begin
            e_nz <= (kls(tlast) != 3'd0);   // (e, with the one added if it was)
            `TDO(A_SUB, `RG(SG), M_NO, `KC(7'd0), M_NO, TA, LG4)
        end
        LG4: `TDO(A_ADD, `RG(SG), M_NO, `KC(7'd0), M_NO, TB, LG5)
        LG5: begin
            f_ret <= LG10;
            `TDO(A_DIV, `RG(TA), M_NO, `RG(TB), M_NO, SG, G0)
        end
        LG10: if (e_nz) `TDO(A_ADD, `RG(FN), M_NO, `RG(TB), M_NO, TB, LG11) else ts <= LG11;
        LG11: begin
            if (kls(tlast) == 3'd0) begin   // x is one: y times nothing
                if (k1 == 3'd3) begin rs_r <= INDEF; tfl <= tfl | 7'h01; end
                else rs_r <= {x1[79], 79'd0};
                ts <= TS_DONE;
            end else
                ts <= LG20;
        end
        // y log2(1 + x): the same series with x / (2 + x)
        LG2B: begin
            f_ret <= LG20;
            `TDO(A_DIV, `RG(X0), M_NO, `RG(TA), M_NO, SG, G0)
        end
        // The result: y times the logarithm (in TB), rounded as the
        // control word says.
        LG20: `TDOR(A_MUL, `RG(X1), M_NO, `RG(TB), M_NO, RS, LG21)
        LG21: begin
            if (kls(rs_r) == 3'd2 || kls(rs_r) == 3'd1)
                tfl <= tfl | 7'h20;
            ts <= TS_DONE;
        end

        // ln((1 + s) / (1 - s)) = 2 s (1 + s^2/3 + ...), as log2: s in SG, the result in TB
        G0: begin
            case (gs)
            3'd0: begin `TDO(A_MUL, `RG(SG), M_NO, `RG(SG), M_NO, RZ, G0) gs <= 3'd1; end
            3'd1: begin `TPOLY(7'd62, 5'd14, G0) gs <= 3'd2; end
            3'd2: begin `TDO(A_MUL, `RG(SG), M_NO, `RG(RP), M_NO, TA, G0) gs <= 3'd3; end
            3'd3: begin `TDO(A_MUL, `RG(TA), M_TWICE, `KC(7'd9), M_NO, TB, G0) gs <= 3'd4; end
            default: begin gs <= 3'd0; ts <= f_ret; end
            endcase
        end
        default: ts <= TS_DONE;
        endcase

        // FPTAN: the sine over the cosine, rounded as the control word says.
        F_TAN: begin
            fs <= F_FIN;
            if (!t_range && (kls(rc_r) != 3'd0 || kls(rs_r) != 3'd0) &&
                (kls(rs_r) == 3'd2 || kls(rs_r) == 3'd1)) begin
                ar_start <= 1'b1;
                ar_op <= A_DIV;
                ar_a  <= rs_r;
                ar_b  <= rc_r;
                fs <= F_TANW;
            end
        end
        F_TANW: if (ar_done) begin
            rs_r <= ar_r;
            fs <= F_FIN;
        end

        F_FIN: begin
            t_sw = sw; t_em = empty; t_top = top; t_go = 1'b1; t_fl = ar_fl | pre; t_v = ar_r; t_cc = ar_cc;
            w0_en <= 1'b0; w1_en <= 1'b0; n_cw <= cw; n_init <= 1'b0; wr_n <= 5'd0; n_env <= 1'b0;
            case (kind)
            K_ARITH, K_UNARY, K_BIN2: begin
                if (fault_a) begin
                    t_sw = (t_sw | 16'h0041) & ~16'h0200;
                    t_go = cw[0];
                    t_v  = INDEF;
                end else if (|(t_fl[2:0] & ~cw[2:0])) begin
                    t_sw = t_sw | {13'd0, t_fl[2:0]};
                    t_go = 1'b0;
                end else begin
                    t_sw = (t_sw | {10'd0, t_fl[5:0]}) & ~16'h0200 | {6'd0, t_fl[6], 9'd0};
                end
                if (t_go) begin
                    w0_en <= 1'b1;
                    w0_i  <= dst_i ? pi : top;
                    w0_v  <= t_v;
                    if (pop1) begin t_em[t_top] = 1'b1; t_top = t_top + 3'd1; end
                    // (A remainder's quotient bits, or none after a fault.)
                    if (kind == K_BIN2 && bin2 != 2'd2)
                        t_sw = (t_sw & ~16'h4700) |
                               (fault_a ? 16'd0 : {1'b0, ar_c4[3], 3'd0, ar_c4[2:0], 8'd0});
                end
            end
            K_XTR: begin
                // The exponent in ST, then the significand pushed.
                t_v = ar_r2;
                if (e0) begin
                    t_sw = (t_sw | 16'h0041) & ~16'h0200;
                    t_go = cw[0];
                    t_v  = INDEF;
                    if (t_go) begin w0_en <= 1'b1; w0_i <= top; w0_v <= INDEF; end
                end else if (|(ar_fl[2:0] & ~cw[2:0])) begin
                    t_sw = t_sw | {13'd0, ar_fl[2:0]};
                    t_go = 1'b0;
                end else begin
                    t_sw = (t_sw | {10'd0, ar_fl[5:0]}) & ~16'h0200 | {6'd0, ar_fl[6], 9'd0};
                    w0_en <= 1'b1; w0_i <= top; w0_v <= ar_r;
                end
                if (t_go) begin
                    if (!t_em[t_top - 3'd1]) begin
                        t_sw = t_sw | 16'h0241;
                        t_go = cw[0];
                        t_v  = INDEF;
                    end else
                        t_sw = t_sw & ~16'h0200;
                    if (t_go) begin
                        t_top = t_top - 3'd1;
                        t_em[t_top] = 1'b0;
                        w1_en <= 1'b1; w1_i <= t_top; w1_v <= t_v;
                    end
                end
            end
            K_COMP: begin
                if (mem_op && |(pre[1] & ~cw[1])) begin
                    t_sw = t_sw | 16'h0002;         // a denormal operand, not masked
                    t_go = 1'b0;
                end else begin
                    if (mem_op) t_sw = t_sw | {14'd0, pre[1], 1'b0};
                    t_fl = ar_fl;
                    if (fault_a) begin
                        t_sw = (t_sw | 16'h0041) & ~16'h0200;
                        t_go = cw[0];
                        t_cc = 3'b111;
                    end else if (|(t_fl[2:0] & ~cw[2:0])) begin
                        t_sw = t_sw | {13'd0, t_fl[2:0]};
                        t_go = 1'b0;
                    end else
                        t_sw = (t_sw | {10'd0, t_fl[5:0]}) & ~16'h0200;
                    if (t_go) begin
                        t_sw = (t_sw & ~16'h4500) | {1'b0, t_cc[2], 3'd0, t_cc[1], 1'b0, t_cc[0], 8'd0};
                        if (pop1) begin t_em[t_top] = 1'b1; t_top = t_top + 3'd1; end
                        if (pop2) begin t_em[t_top] = 1'b1; t_top = t_top + 3'd1; end
                    end
                end
            end
            K_LDMEM, K_LDREG, K_CONST: begin
                t_v = (kind == K_CONST) ? konst : opnd;
                t_fl = pre;
                if (kind == K_LDREG && ei) begin
                    t_sw = (t_sw | 16'h0041) & ~16'h0200;
                    t_go = cw[0];
                    t_v  = INDEF;
                end
                if (kind == K_LDMEM && (mfmt == M_F32 || mfmt == M_F64) && (t_fl[0] & ~cw[0])) begin
                    t_sw = t_sw | 16'h0001;
                    t_go = 1'b0;
                end
                if (t_go) begin
                    // Push: onto a register that is not empty is a fault.
                    if (!t_em[t_top - 3'd1]) begin
                        t_sw = t_sw | 16'h0241;
                        t_go = cw[0];
                        t_v  = INDEF;
                    end else
                        t_sw = t_sw & ~16'h0200;
                    if (t_go) begin
                        t_top = t_top - 3'd1;
                        t_em[t_top] = 1'b0;
                        w0_en <= 1'b1;
                        w0_i  <= t_top;
                        w0_v  <= t_v;
                        if (kind == K_LDMEM && (mfmt == M_F32 || mfmt == M_F64))
                            t_sw = t_sw | {10'd0, t_fl[5:0]};
                    end
                end
            end
            K_STMEM: begin
                wbuf <= (mfmt == M_T80 && !isbcd) ? st0 : ar_r;
                if (e0) begin
                    t_sw = (t_sw | 16'h0041) & ~16'h0200;
                    t_go = cw[0];
                    wbuf <= (mfmt == M_T80) ? INDEF :
                            (mfmt == M_F32) ? 80'h000000000000FFC00000 :
                            (mfmt == M_F64) ? 80'h0000FFF8000000000000 :
                            (mfmt == M_I16) ? 80'h00000000000000008000 :
                            (mfmt == M_I32) ? 80'h00000000000080000000 : 80'h00008000000000000000;
                end else if (mfmt == M_T80 && !isbcd)
                    t_sw = t_sw & ~16'h0200;
                else if (ar_fl[0] & ~cw[0]) begin
                    t_sw = t_sw | 16'h0001;
                    t_go = 1'b0;
                end else if (|(ar_fl[4:3] & ~cw[4:3])) begin
                    t_sw = t_sw | {11'd0, ar_fl[4:3], 3'd0};
                    t_go = 1'b0;
                end else
                    t_sw = (t_sw | {10'd0, ar_fl[5:0]}) & ~16'h0200 | {6'd0, ar_fl[6], 9'd0};
                if (t_go) begin
                    wr_n <= parts(mfmt);
                    if (pop1) begin t_em[t_top] = 1'b1; t_top = t_top + 3'd1; end
                end
            end
            K_STREG: begin
                t_v = st0;
                if (e0) begin
                    t_sw = (t_sw | 16'h0041) & ~16'h0200;
                    t_go = cw[0];
                    t_v  = INDEF;
                end else
                    t_sw = t_sw & ~16'h0200;
                if (t_go) begin
                    w0_en <= 1'b1; w0_i <= pi; w0_v <= t_v;
                    t_em[pi] = 1'b0;
                    if (pop1) begin t_em[t_top] = 1'b1; t_top = t_top + 3'd1; end
                end
            end
            K_XCH: begin
                if (e0 || ei) begin
                    t_sw = (t_sw | 16'h0041) & ~16'h0200;
                    t_go = cw[0];
                end
                if (t_go) begin
                    w0_en <= 1'b1; w0_i <= top; w0_v <= ei ? INDEF : sti;
                    w1_en <= 1'b1; w1_i <= pi;  w1_v <= e0 ? INDEF : st0;
                    t_em[top] = 1'b0;
                    t_em[pi]  = 1'b0;
                    t_sw = t_sw & ~16'h0200;
                end
            end
            K_SIGN: begin
                if (e0) begin
                    t_sw = (t_sw | 16'h0041) & ~16'h0200;
                    if (cw[0]) begin w0_en <= 1'b1; w0_i <= top; w0_v <= INDEF; end
                end else begin
                    w0_en <= 1'b1; w0_i <= top;
                    w0_v  <= {isabs ? 1'b0 : !st0[79], st0[78:0]};
                    t_sw = t_sw & ~16'h0200;
                end
            end
            K_XAM: begin
                t_cc = e0 ? 3'b101 : (cls0 == 3'd0) ? 3'b100 : (cls0 == 3'd1) ? 3'b110 :
                       (cls0 == 3'd2) ? 3'b010 : (cls0 == 3'd3) ? 3'b011 : (cls0 == 3'd6) ? 3'b000 : 3'b001;
                t_sw = (t_sw & ~16'h4700) | {1'b0, t_cc[2], 3'd0, t_cc[1], st0[79], t_cc[0], 8'd0};
            end
            K_ENV: case (ctl)
                T_LDENV, T_RSTOR: begin
                    n_cw  <= ew[0][15:0] | 16'h0040;
                    t_sw  = ew[1][15:0];
                    t_top = ew[1][13:11];
                    for (j = 0; j < 8; j = j + 1)
                        t_em[j] = (ew[2][2*j +: 2] == 2'b11);
                    n_env <= 1'b1;
                end
                T_STENV: begin wr_n <= 5'd7; n_cw <= cw | 16'h003F; end
                default: begin wr_n <= 5'd31; n_init <= 1'b1; end
            endcase
            K_CTL: case (ctl)
                T_INIT: n_init <= 1'b1;
                T_CLEX: t_sw = t_sw & 16'h7F00;
                T_LDCW: n_cw <= mbuf[15:0] | 16'h0040;
                T_STCW: begin wbuf <= {64'd0, cw}; wr_n <= 5'd1; end
                T_STSW: begin wbuf <= {64'd0, sw}; wr_n <= 5'd1; end
                T_FREE: t_em[pi] = 1'b1;
                T_FREEP: begin t_em[pi] = 1'b1; t_em[t_top] = 1'b1; t_top = t_top + 3'd1; end
                T_INC: begin t_top = t_top + 3'd1; t_sw = t_sw & ~16'h0200; end
                T_DEC: begin t_top = t_top - 3'd1; t_sw = t_sw & ~16'h0200; end
                default: ;
            endcase
            default: ;
            endcase
            // A transcendental function's results.
            if (trn) begin
                t_v = INDEF;                // (what is pushed, if anything is)
                t_go = 1'b0;                // (whether anything is)
                if (fault_a) begin
                    t_sw = (t_sw | 16'h0041) & ~16'h0200;
                    if (cw[0]) begin
                        w0_en <= 1'b1; w0_v <= INDEF;
                        w0_i  <= t2op ? pi : top;
                        if (t2op) begin t_em[t_top] = 1'b1; t_top = t_top + 3'd1; end
                        t_go = (tfn == TF_SINCOS) && tsub[1];
                    end
                end else if (tfn == TF_SINCOS && t_range)
                    t_sw = t_sw | 16'h0400;
                else if (|(tfl[2:0] & ~cw[2:0]))
                    t_sw = t_sw | {13'd0, tfl[2:0]};
                else begin
                    t_sw = (t_sw | {10'd0, tfl[5:0]}) & ~16'h0200 | {6'd0, tfl[6], 9'd0};
                    w0_en <= 1'b1;
                    w0_i  <= t2op ? pi : top;
                    w0_v  <= (tfn == TF_SINCOS && tsub == 2'd1) ? rc_r : rs_r;
                    if (t2op) begin t_em[t_top] = 1'b1; t_top = t_top + 3'd1; end
                    if (tfn == TF_SINCOS) begin
                        t_sw = t_sw & ~16'h0400;
                        t_go = tsub[1];
                        t_v  = (tsub == 2'd2) ? rc_r : (kls(rs_r) == 3'd4) ? rs_r : K_ONE;
                    end
                end
                if (t_go) begin
                    // Push (FSINCOS's cosine, FPTAN's one).
                    if (!t_em[t_top - 3'd1]) begin
                        t_sw = t_sw | 16'h0241;
                        t_go = cw[0];
                        t_v  = INDEF;
                    end else
                        t_sw = t_sw & ~16'h0200;
                    if (t_go) begin
                        t_top = t_top - 3'd1;
                        t_em[t_top] = 1'b0;
                        w1_en <= 1'b1; w1_i <= t_top; w1_v <= t_v;
                    end
                end
            end
            n_sw    <= {t_sw[15:14], t_top, t_sw[10:0]};
            n_empty <= t_em;
            fs <= F_DONE;
        end
        default: ;
        endcase

`ifdef M86_FPU_TRACE
        if (stb)
            $display("fpu: cmd %0d din %h esc %0d modrm %h  sw %h empty %h fs %0d kind %0d", cmd, din, esc, modrm, sw, empty, fs, kind);
`endif
        if (stb) begin
            case (cmd)
            C_START: begin
                kind <= d_kind; ctl <= d_ctl; mfmt <= d_mfmt; aop <= d_reg;
                rm <= (d_kind == K_BIN2 || d_trn) ? 3'd1 : d_rm;     // (FPREM and the like: ST(1))
                trn <= d_trn; tfn <= d_tfn; tsub <= d_tsub;
                isbcd <= d_bcd; bin2 <= d_bin2;
                dst_i <= d_dst_i; quiet <= d_quiet; pop1 <= d_pop1; pop2 <= d_pop2;
                tst <= d_tst; isabs <= d_abs; issqrt <= d_sqrt;
                rd_n <= (d_kind == K_ENV) ? ((d_ctl == T_LDENV || d_ctl == T_RSTOR) ? d_env_n : 5'd0) :
                        d_reads ? parts(d_mfmt) : 5'd0;
                wr_n <= (d_kind == K_ENV) ? ((d_ctl == T_STENV || d_ctl == T_SAVE) ? d_env_n : 5'd0) :
                        d_writes ? parts(d_mfmt) : 5'd0;
                xi <= 5'd0; after <= 1'b0; fs <= F_IDLE;
                rpart <= 2'd0; rk <= 3'd0;
                o32 <= os32; pm <= prot; is_mem <= d_mem; ctrl <= d_ctrl;
                trap_r  <= cr[1] || cr[2] || (!d_nowait && sw[7] && cr[3]);
                trap_mf <= !(cr[1] || cr[2]);
                s_ip <= ip; s_cs <= cs; s_dp <= din; s_ds <= dsel; s_op <= {esc, modrm};
                if (d_undone) undone <= undone + 32'd1;
            end
            C_PUT: begin
                ax <= din;
                if (kind == K_ENV) begin
                    if (!in_reg)
                        ew[xi[2:0]] <= o32 ? din : {16'd0, din[15:0]};
                    else begin
                        // A register of a state being restored: straight
                        // into its place under the new top.
                        case (rpart)
                        2'd0: rbuf[31:0]  <= din;
                        2'd1: rbuf[63:32] <= din;
                        default: st[e_top + rk] <= {din[15:0], rbuf};
                        endcase
                        rpart <= (rpart == 2'd2) ? 2'd0 : rpart + 2'd1;
                        if (rpart == 2'd2) rk <= rk + 3'd1;
                    end
                end else
                    case (xi)
                    5'd0: mbuf[31:0]  <= din;
                    5'd1: mbuf[63:32] <= din;
                    default: mbuf[79:64] <= din[15:0];
                    endcase
                xi <= xi + 5'd1;
            end
            C_RUN: begin
                fs <= F_CONV;
                xi <= 5'd0;
                rpart <= 2'd0; rk <= 3'd0;
                after <= 1'b1;
            end
            C_GET: begin
                xi <= xi + 5'd1;
                if (kind == K_ENV && in_reg) begin
                    rpart <= (rpart == 2'd2) ? 2'd0 : rpart + 2'd1;
                    if (rpart == 2'd2) rk <= rk + 3'd1;
                end
            end
            C_WAIT: begin
                trap_r  <= (cr[0] && cr[2]) || (sw[7] && cr[3]);
                trap_mf <= !(cr[0] && cr[2]);
            end
            C_COMMIT: begin
                // The pointers: FNINIT's zeros, a loaded state's, or this
                // instruction's (unless it is a control instruction).
                if (n_init) begin
                    fip <= 32'd0; fdp <= 32'd0; fcs <= 16'd0; fds <= 16'd0; fop <= 11'd0;
                end else if (n_env) begin
                    if (pm) begin
                        fip <= ew[3]; fcs <= ew[4][15:0]; fop <= o32 ? ew[4][26:16] : 11'd0;
                        fdp <= ew[5]; fds <= ew[6][15:0];
                    end else begin
                        fop <= ew[4][10:0]; fcs <= 16'd0; fds <= 16'd0;
                        fip <= o32 ? {ew[4][27:12], ew[3][15:0]} : {12'd0, ew[4][15:12], ew[3][15:0]};
                        fdp <= o32 ? {ew[6][27:12], ew[5][15:0]} : {12'd0, ew[6][15:12], ew[5][15:0]};
                    end
                end else if (!ctrl) begin
                    fip <= s_ip; fcs <= s_cs; fop <= s_op;
                    if (is_mem) begin fdp <= s_dp; fds <= s_ds; end
                end
                if (n_init) begin
                    cw <= 16'h037F; sw <= 16'h0000; empty <= 8'hFF;
                end else begin
                    cw <= n_cw;
                    // (The summary bits follow the flags and the new masks.)
                    sw <= (|(n_sw[5:0] & ~n_cw[5:0])) ? (n_sw | 16'h8080) : (n_sw & 16'h7F7F);
                    empty <= n_empty;
                    if (w0_en) st[w0_i] <= w0_v;
                    if (w1_en) st[w1_i] <= w1_v;
                end
                fs <= F_IDLE;
                after <= 1'b0;
            end
            default: ;
            endcase
        end
        if (rst) begin
            cw <= 16'h037F; sw <= 16'h0000; empty <= 8'hFF; undone <= 32'd0;
            fs <= F_IDLE; after <= 1'b0; xi <= 5'd0; rd_n <= 5'd0; wr_n <= 5'd0; trap_r <= 1'b0;
            fip <= 32'd0; fdp <= 32'd0; fcs <= 16'd0; fds <= 16'd0; fop <= 11'd0;
        end
    end

    // What GET gives: the next part of the store, or EAX's new value.
    always @* begin
        if (ctl == T_STAX && kind == K_CTL)
            dout = {ax[31:16], sw};
        else if (mfmt == M_REG)
            dout = ax;
        else if (kind == K_ENV)
            dout = !in_reg ? envw :
                   (rpart == 2'd0) ? st_k[31:0] : (rpart == 2'd1) ? st_k[63:32] : {16'd0, st_k[79:64]};
        else
            case (xi)
            5'd0: dout = wbuf[31:0];
            5'd1: dout = wbuf[63:32];
            default: dout = {16'd0, wbuf[79:64]};
            endcase
    end

    integer i;
    initial for (i = 0; i < 8; i = i + 1) st[i] = 80'd0;
endmodule
