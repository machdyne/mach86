/*
 * Mach86 CPU core -- the slow path.
 *
 * Sources: I386-PRM ch. 14 (real mode), ch. 17 (instruction set),
 * ch. 9 (exceptions); I86-UM; SST-386 for behaviour the manuals leave
 * open (docs/model.md, "What the vectors taught").
 *
 * This is the sequencer that can execute every instruction: one byte
 * fetched at a time, one memory access at a time, results written only
 * when the instruction can no longer fault. It was superseded by
 * design B (m86b_core.v, docs/cpu_b.md) and is kept as a reference.
 *
 * Level implemented: the 386 instruction set in real mode. Setting CR0.PE or CR0.PG stops the
 * core and raises `unsupported`.
 *
 * Bus: one request at a time. `mem_size` is 1, 2 or 4 bytes at any
 * alignment; the bus unit outside splits and aligns. Data is
 * little-endian in the low bits.
 */
`default_nettype none

module m86_core (
    input  wire        clk,
    input  wire        rst,

    output wire        mem_req,
    output wire        mem_wr,
    output wire [31:0] mem_addr,
    output wire [2:0]  mem_size,
    output wire [31:0] mem_wdata,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ack,

    output wire        io_req,
    output wire        io_wr,
    output wire [15:0] io_addr,
    output wire [2:0]  io_size,
    output wire [31:0] io_wdata,
    input  wire [31:0] io_rdata,
    input  wire        io_ack,

    input  wire        irq,         // maskable interrupt request (level)
    input  wire [7:0]  irq_vec,     // its vector, valid the cycle after inta
    output reg         inta,        // one cycle: the request is taken
    input  wire        nmi,         // rising edge requests an NMI

    output reg         halted,
    output reg         shutdown,
    output reg         unsupported,
    output reg         insn_done,   // one cycle per retired instruction
    output reg         step_done,   // one cycle per instruction, fault or
                                    // interrupt completed: what the
                                    // reference model counts as one step
    output reg  [7:0]  last_exc     // vector of the last fault taken
);

    // ---- architectural state ------------------------------------

    localparam ES = 3'd0, CS = 3'd1, SS = 3'd2, DS = 3'd3, FS = 3'd4, GS = 3'd5;
    localparam EAX = 3'd0, ECX = 3'd1, EDX = 3'd2, EBX = 3'd3,
               ESP = 3'd4, EBP = 3'd5, ESI = 3'd6, EDI = 3'd7;
    localparam F_CF = 0, F_PF = 2, F_AF = 4, F_ZF = 6, F_SF = 7, F_TF = 8,
               F_IF = 9, F_DF = 10, F_OF = 11;
    localparam [17:0] FL_MASK = 18'h37FD5;

    reg [255:0] gprs      /* verilator public_flat_rw */;
    reg [31:0]  eip       /* verilator public_flat_rw */;
    reg [17:0]  fl        /* verilator public_flat_rw */;
    reg [95:0]  ssel      /* verilator public_flat_rw */;
    reg [191:0] sbase     /* verilator public_flat_rw */;
    reg [31:0]  cr0       /* verilator public_flat_rw */;
    reg [31:0]  cr2, cr3;
    reg [31:0]  gdtr_base, idtr_base /* verilator public_flat_rw */;
    reg [15:0]  gdtr_lim, idtr_lim   /* verilator public_flat_rw */;

    // Real mode: every limit is FFFFh and nothing changes it.
    wire [31:0] seg_limit = 32'h0000FFFF;

    wire [31:0] eax = gprs[0*32 +: 32];
    wire [31:0] ecx = gprs[1*32 +: 32];
    wire [31:0] edx = gprs[2*32 +: 32];
    wire [31:0] ebx = gprs[3*32 +: 32];
    wire [31:0] esp = gprs[4*32 +: 32];
    wire [31:0] ebp = gprs[5*32 +: 32];
    wire [31:0] esi = gprs[6*32 +: 32];
    wire [31:0] edi = gprs[7*32 +: 32];
    wire [15:0] sp16 = esp[15:0];

    function [31:0] rdreg(input [2:0] sz, input [2:0] idx);
        reg [31:0] v;
        begin
            if (sz == 3'd1) begin
                v = gprs[{idx[1:0], 5'd0} +: 32];
                rdreg = {24'd0, idx[2] ? v[15:8] : v[7:0]};
            end else begin
                v = gprs[{idx, 5'd0} +: 32];
                rdreg = (sz == 3'd2) ? {16'd0, v[15:0]} : v;
            end
        end
    endfunction

    // Register writes go through two write ports, applied at the end
    // of the clocked block, so that a write is one decoder and not a
    // 256-bit shift at every place a register is written. A write
    // through a port wins over a direct assignment in the same cycle.
    reg        wa_en, wb_en;
    reg [2:0]  wa_sz, wa_idx, wb_sz, wb_idx;
    reg [31:0] wa_val, wb_val;

    task wrreg(input [2:0] sz, input [2:0] idx, input [31:0] v);
        begin
            if (!wa_en) begin
                wa_en = 1'b1; wa_sz = sz; wa_idx = idx; wa_val = v;
            end else begin
                wb_en = 1'b1; wb_sz = sz; wb_idx = idx; wb_val = v;
            end
        end
    endtask

    task wrport(input [2:0] sz, input [2:0] idx, input [31:0] v);
        integer k;
        begin
            for (k = 0; k < 8; k = k + 1) begin
                if (sz == 3'd1) begin
                    if (idx[1:0] == k[1:0] && k < 4) begin
                        if (idx[2]) gprs[k*32+8 +: 8] <= v[7:0];
                        else        gprs[k*32 +: 8]   <= v[7:0];
                    end
                end else if (idx == k[2:0]) begin
                    if (sz == 3'd2) gprs[k*32 +: 16] <= v[15:0];
                    else            gprs[k*32 +: 32] <= v;
                end
            end
        end
    endtask

    task segload(input [2:0] seg, input [15:0] sel);
        begin
            ssel[{seg, 4'd0} +: 16]  <= sel;
            sbase[{seg, 5'd0} +: 32] <= {12'd0, sel, 4'd0};
        end
    endtask

    task wrfl(input [31:0] v, input [17:0] change);
        fl <= (((fl & ~change) | (v[17:0] & change)) & FL_MASK) | 18'h2;
    endtask

    function cond(input [3:0] cc);
        reg r;
        begin
            case (cc[3:1])
                3'd0: r = fl[F_OF];
                3'd1: r = fl[F_CF];
                3'd2: r = fl[F_ZF];
                3'd3: r = fl[F_CF] | fl[F_ZF];
                3'd4: r = fl[F_SF];
                3'd5: r = fl[F_PF];
                3'd6: r = fl[F_SF] ^ fl[F_OF];
                default: r = fl[F_ZF] | (fl[F_SF] ^ fl[F_OF]);
            endcase
            cond = r ^ cc[0];
        end
    endfunction

    // ---- the instruction being executed --------------------------

    reg [8:0]  op;              // opcode; bit 8: the 0F map
    reg [7:0]  modrm, sib;
    reg        os32, as32;      // operand and address size are 32-bit
    reg        ovr_v;
    reg [2:0]  ovr;             // segment override
    reg [1:0]  rep;             // 1: F3 (REP/REPE), 2: F2 (REPNE)
    reg        lock;
    reg [4:0]  ilen;
    reg [31:0] disp, imm;
    reg [15:0] imm2;
    reg [31:0] ea_off;
    reg [2:0]  ea_seg;
    reg [31:0] eip_start;
    reg        tf_start;

    wire [1:0] m_mod = modrm[7:6];
    wire [2:0] m_reg = modrm[5:3];
    wire [2:0] m_rm  = modrm[2:0];
    wire       is_mem = (m_mod != 2'd3);
    wire [2:0] osz = os32 ? 3'd4 : 3'd2;
    wire [2:0] dseg = ovr_v ? ovr : DS;
    wire [31:0] amask = as32 ? 32'hFFFFFFFF : 32'h0000FFFF;

    // ---- decode: what the opcode needs ---------------------------

    reg       d_valid, d_modrm, d_byte, d_rdrm;
    reg [2:0] d_imm;            // 0 none, 1 imm8, 2 imm16/32, 3 imm16,
                                // 4 imm8 sign-extended, 5 far pointer,
                                // 6 offset of address size, 7 imm16+imm8
    wire [7:0] o = op[7:0];

    always @* begin
        d_valid = 1'b1;
        d_modrm = 1'b0;
        d_byte  = 1'b0;
        d_rdrm  = 1'b0;
        d_imm   = 3'd0;
        if (!op[8]) begin
            casez (o)
                8'b00???0??: begin d_modrm = 1; d_rdrm = 1; d_byte = ~o[0]; end
                8'b00???10?: begin d_imm = o[0] ? 3'd2 : 3'd1; d_byte = ~o[0]; end
                8'b00???11?: ;                          // push/pop segment, BCD
                8'b0100????, 8'b0101????: ;             // INC/DEC/PUSH/POP reg
                8'h60, 8'h61: ;
                8'h62: d_modrm = 1;
                8'h68: d_imm = 3'd2;
                8'h69: begin d_modrm = 1; d_rdrm = 1; d_imm = 3'd2; end
                8'h6A: d_imm = 3'd4;
                8'h6B: begin d_modrm = 1; d_rdrm = 1; d_imm = 3'd4; end
                8'h6C, 8'h6D, 8'h6E, 8'h6F: d_byte = ~o[0];
                8'b0111????: d_imm = 3'd4;
                8'h80, 8'h82: begin d_modrm = 1; d_rdrm = 1; d_imm = 3'd1; d_byte = 1; end
                8'h81: begin d_modrm = 1; d_rdrm = 1; d_imm = 3'd2; end
                8'h83: begin d_modrm = 1; d_rdrm = 1; d_imm = 3'd4; end
                8'h84, 8'h85, 8'h86, 8'h87:
                       begin d_modrm = 1; d_rdrm = 1; d_byte = ~o[0]; end
                8'h88, 8'h89: begin d_modrm = 1; d_byte = ~o[0]; end
                8'h8A, 8'h8B: begin d_modrm = 1; d_rdrm = 1; d_byte = ~o[0]; end
                8'h8C, 8'h8D, 8'h8F: d_modrm = 1;
                8'h8E: begin d_modrm = 1; d_rdrm = 1; end
                8'b10010???: ;                          // NOP, XCHG
                8'h98, 8'h99, 8'h9B, 8'h9C, 8'h9D, 8'h9E, 8'h9F: ;
                8'h9A, 8'hEA: d_imm = 3'd5;
                8'hA0, 8'hA1, 8'hA2, 8'hA3: begin d_imm = 3'd6; d_byte = ~o[0]; end
                8'hA4, 8'hA5, 8'hA6, 8'hA7, 8'hAA, 8'hAB, 8'hAC, 8'hAD,
                8'hAE, 8'hAF: d_byte = ~o[0];
                8'hA8: begin d_imm = 3'd1; d_byte = 1; end
                8'hA9: d_imm = 3'd2;
                8'b10110???: begin d_imm = 3'd1; d_byte = 1; end
                8'b10111???: d_imm = 3'd2;
                8'hC0, 8'hC1: begin d_modrm = 1; d_rdrm = 1; d_imm = 3'd1; d_byte = ~o[0]; end
                8'hC2, 8'hCA: d_imm = 3'd3;
                8'hC3, 8'hCB, 8'hC9, 8'hCC, 8'hCE, 8'hCF: ;
                8'hC4, 8'hC5: d_modrm = 1;
                8'hC6: begin d_modrm = 1; d_imm = 3'd1; d_byte = 1; end
                8'hC7: begin d_modrm = 1; d_imm = 3'd2; end
                8'hC8: d_imm = 3'd7;
                8'hCD, 8'hD4, 8'hD5: d_imm = 3'd1;
                8'hD0, 8'hD1, 8'hD2, 8'hD3:
                       begin d_modrm = 1; d_rdrm = 1; d_byte = ~o[0]; end
                8'hD6, 8'hD7: ;
                8'b11011???: d_modrm = 1;               // coprocessor escape
                8'hE0, 8'hE1, 8'hE2, 8'hE3, 8'hEB: d_imm = 3'd4;
                8'hE4, 8'hE5, 8'hE6, 8'hE7: begin d_imm = 3'd1; d_byte = ~o[0]; end
                8'hE8, 8'hE9: d_imm = 3'd2;
                8'hEC, 8'hED, 8'hEE, 8'hEF: d_byte = ~o[0];
                8'hF1, 8'hF4, 8'hF5, 8'hF8, 8'hF9, 8'hFA, 8'hFB, 8'hFC, 8'hFD: ;
                8'hF6: begin d_modrm = 1; d_rdrm = 1; d_byte = 1;
                             d_imm = (m_reg < 3'd2) ? 3'd1 : 3'd0; end
                8'hF7: begin d_modrm = 1; d_rdrm = 1;
                             d_imm = (m_reg < 3'd2) ? 3'd2 : 3'd0; end
                8'hFE: begin d_modrm = 1; d_rdrm = 1; d_byte = 1; end
                8'hFF: begin d_modrm = 1;
                             d_rdrm = (m_reg != 3'd3) && (m_reg != 3'd5); end
                default: d_valid = 1'b0;                // includes 63h (ARPL)
            endcase
        end else begin
            casez (o)
                8'h01, 8'h20, 8'h21, 8'h22, 8'h23: d_modrm = 1;
                8'h06: ;
                8'b1000????: d_imm = 3'd2;              // Jcc near
                8'b1001????: begin d_modrm = 1; d_byte = 1; end
                8'hA0, 8'hA1, 8'hA8, 8'hA9: ;
                8'hA3, 8'hAB, 8'hB3, 8'hBB: d_modrm = 1;
                8'hA4, 8'hAC: begin d_modrm = 1; d_rdrm = 1; d_imm = 3'd1; end
                8'hA5, 8'hAD, 8'hAF, 8'hBC, 8'hBD:
                       begin d_modrm = 1; d_rdrm = 1; end
                8'hB2, 8'hB4, 8'hB5: d_modrm = 1;
                8'hB6, 8'hB7, 8'hBE, 8'hBF: begin d_modrm = 1; d_rdrm = 1; end
                8'hBA: begin d_modrm = 1; d_rdrm = 1; d_imm = 3'd1; end
                default: d_valid = 1'b0;
            endcase
        end
    end

    wire [2:0] opsz = d_byte ? 3'd1 : osz;
    // Size of the r/m operand where it differs from the operand size.
    wire [2:0] rmsz = (!op[8] && o == 8'h8E) ? 3'd2 :
                      (op[8] && (o == 8'hB6 || o == 8'hBE)) ? 3'd1 :
                      (op[8] && (o == 8'hB7 || o == 8'hBF)) ? 3'd2 : opsz;
    wire [31:0] regv = rdreg(opsz, m_reg);
    wire [31:0] acc  = rdreg(opsz, EAX);

    // LOCK is accepted only on these, with a memory destination.
    reg lockable;
    always @* begin
        lockable = 1'b0;
        if (!op[8]) begin
            casez (o)
                8'b00???00?: lockable = (o[5:3] != 3'd7);
                8'h80, 8'h81, 8'h82, 8'h83: lockable = (m_reg != 3'd7);
                8'h86, 8'h87: lockable = 1'b1;
                8'hF6, 8'hF7: lockable = (m_reg == 3'd2) || (m_reg == 3'd3);
                8'hFE, 8'hFF: lockable = (m_reg < 3'd2);
                default: ;
            endcase
        end else begin
            case (o)
                8'hAB, 8'hB3, 8'hBB: lockable = 1'b1;
                8'hBA: lockable = (m_reg >= 3'd5);
                default: ;
            endcase
        end
    end

    // Encodings that are invalid for reasons other than the opcode.
    reg ud;
    always @* begin
        ud = lock && (!d_modrm || !lockable || !is_mem);
        if (!op[8]) begin
            case (o)
                8'h62, 8'h8D, 8'hC4, 8'hC5: if (!is_mem) ud = 1'b1;
                8'h8C: if (m_reg > 3'd5) ud = 1'b1;
                8'h8E: if (m_reg > 3'd5 || m_reg == CS) ud = 1'b1;
                8'h8F, 8'hC6, 8'hC7: if (m_reg != 3'd0) ud = 1'b1;
                8'hFE: if (m_reg > 3'd1) ud = 1'b1;
                8'hFF: if (m_reg == 3'd7 ||
                           ((m_reg == 3'd3 || m_reg == 3'd5) && !is_mem)) ud = 1'b1;
                default: ;
            endcase
        end else begin
            case (o)
                8'h01: if (m_reg == 3'd5 || m_reg == 3'd7 ||
                           (m_reg < 3'd4 && !is_mem)) ud = 1'b1;
                8'h20, 8'h22: if (m_reg != 3'd0 && m_reg != 3'd2 && m_reg != 3'd3)
                                  ud = 1'b1;
                8'hB2, 8'hB4, 8'hB5: if (!is_mem) ud = 1'b1;
                8'hBA: if (m_reg < 3'd4) ud = 1'b1;
                default: ;
            endcase
        end
    end

    // ---- effective address ---------------------------------------

    reg [31:0] ea_c;
    reg [2:0]  ea_cseg;
    reg [31:0] ea_base;
    wire       pop_rm = !op[8] && (o == 8'h8F);
    always @* begin
        ea_cseg = DS;
        ea_base = 32'd0;
        if (!as32) begin
            case (m_rm)
                3'd0: ea_base = ebx + esi;
                3'd1: ea_base = ebx + edi;
                3'd2: begin ea_base = ebp + esi; ea_cseg = SS; end
                3'd3: begin ea_base = ebp + edi; ea_cseg = SS; end
                3'd4: ea_base = esi;
                3'd5: ea_base = edi;
                3'd6: if (m_mod != 2'd0) begin ea_base = ebp; ea_cseg = SS; end
                3'd7: ea_base = ebx;
            endcase
            ea_c = {16'd0, ea_base[15:0] + disp[15:0]};
        end else if (m_rm == 3'd4) begin
            // SIB. A scale with no index scales the base: not a
            // documented encoding, but what the hardware does.
            if (!(sib[2:0] == 3'd5 && m_mod == 2'd0)) begin
                ea_base = gprs[{sib[2:0], 5'd0} +: 32];
                // POP r/m forms its address after ESP has moved.
                if (sib[2:0] == ESP && pop_rm)
                    ea_base = ea_base + {29'd0, osz};
                if (sib[2:0] == ESP || sib[2:0] == EBP)
                    ea_cseg = SS;
            end
            if (sib[5:3] != 3'd4)
                ea_c = ea_base + (gprs[{sib[5:3], 5'd0} +: 32] << sib[7:6]) + disp;
            else
                ea_c = (ea_base << sib[7:6]) + disp;
        end else begin
            if (!(m_rm == 3'd5 && m_mod == 2'd0)) begin
                ea_base = gprs[{m_rm, 5'd0} +: 32];
                if (m_rm == EBP)
                    ea_cseg = SS;
            end
            ea_c = ea_base + disp;
        end
    end

    // Offset of the second part of a two-part operand.
    function [31:0] ea_plus(input [2:0] n);
        reg [31:0] t;
        begin
            t = ea_off + {29'd0, n};
            ea_plus = as32 ? t : {16'd0, t[15:0]};
        end
    endfunction

    // ---- sequencer state -----------------------------------------

    localparam [4:0]
        ST_START = 5'd0,  ST_OPC   = 5'd1,  ST_OP2   = 5'd2,  ST_DEC  = 5'd3,
        ST_MODRM = 5'd4,  ST_SIB   = 5'd5,  ST_DISP  = 5'd6,  ST_EA   = 5'd7,
        ST_IMMGO = 5'd8,  ST_IMM   = 5'd9,  ST_IMM2  = 5'd10, ST_CHK  = 5'd11,
        ST_RDRM  = 5'd12, ST_EXEC  = 5'd13, ST_MEM   = 5'd14, ST_ALU  = 5'd15,
        ST_PUSH  = 5'd16, ST_PUSH2 = 5'd17, ST_SHIFT = 5'd18, ST_DIV  = 5'd19,
        ST_INT   = 5'd20, ST_DONE  = 5'd21, ST_STOP  = 5'd22, ST_MODRM2 = 5'd23,
        ST_INTA  = 5'd24;

    reg [4:0]  state /* verilator public_flat_rw */;
    reg [4:0]  ret_state, alu_ret;
    reg [4:0]  step;

    // One bus access.
    reg [2:0]  m_seg;
    reg [31:0] m_off;
    reg [2:0]  m_size;
    reg        m_wr, m_phys, m_io, m_fetch, m_chk;
    reg [31:0] m_wdata;
    reg [31:0] mdr;

    // Temporaries.
    reg [31:0] ta, tb, tc, res;
    reg [3:0]  aluop;
    reg [2:0]  asz;
    reg [1:0]  alu_fm;          // 1: all six flags; 2: all but carry
    reg [5:0]  cnt, sh_n;
    reg        sh_cf, sh_dbl, sh_right;
    reg [15:0] tsp;
    reg        push_w2;         // PUSH writes only two bytes of the slot

    reg [7:0]  int_vec;
    reg [31:0] int_ret;
    reg        int_insn;        // delivery was asked for by an instruction
    reg        in_fault;
    reg        fdepth;
    reg        inhibit;         // no interrupts before the next instruction
    reg        nmi_pending, nmi_last;

    // Multiplier and divider.
    reg  signed [32:0] mul_a, mul_b;
    reg  signed [65:0] prod;
    always @(posedge clk)
        prod <= mul_a * mul_b;

    reg [32:0] dv_r;
    reg [31:0] dv_q, dv_d;
    reg [5:0]  dv_n;
    reg        dv_qneg, dv_rneg, dv_signed;

    // ---- bus ------------------------------------------------------

    wire [31:0] m_last = m_off + {29'd0, m_size} - 32'd1;
    wire        lim_fault = !m_phys && !m_io &&
                            (m_off > seg_limit || m_last > seg_limit || m_last < m_off);
    wire        len_fault = m_fetch && ({1'b0, ilen} + {3'd0, m_size} > 6'd15);
    wire        in_mem    = (state == ST_MEM);
    wire        bus_go    = in_mem && !lim_fault && !len_fault && !m_chk;

    assign mem_req   = bus_go && !m_io;
    assign mem_wr    = m_wr;
    assign mem_addr  = m_phys ? m_off : (sbase[{m_seg, 5'd0} +: 32] + m_off);
    assign mem_size  = m_size;
    assign mem_wdata = m_wdata;
    assign io_req    = bus_go && m_io;
    assign io_wr     = m_wr;
    assign io_addr   = m_off[15:0];
    assign io_size   = m_size;
    assign io_wdata  = m_wdata;

    wire        bus_ack = m_io ? io_ack : mem_ack;
    wire [31:0] bus_rd  = m_io ? io_rdata : mem_rdata;
    wire [31:0] bus_rdz = (m_size == 3'd1) ? {24'd0, bus_rd[7:0]} :
                          (m_size == 3'd2) ? {16'd0, bus_rd[15:0]} : bus_rd;

    // ---- shared arithmetic -----------------------------------------

    wire [31:0] alu_res;
    wire        alu_cf, alu_of, alu_af, alu_zf, alu_sf, alu_pf;
    m86_alu alu (
        .op(aluop), .a(ta), .b(tb), .cin(fl[F_CF]), .size(asz),
        .res(alu_res), .cf(alu_cf), .of(alu_of), .af(alu_af),
        .zf(alu_zf), .sf(alu_sf), .pf(alu_pf));

    function [31:0] szmask(input [2:0] sz);
        szmask = (sz == 3'd1) ? 32'h000000FF :
                 (sz == 3'd2) ? 32'h0000FFFF : 32'hFFFFFFFF;
    endfunction
    function [31:0] sext(input [2:0] sz, input [31:0] v);
        sext = (sz == 3'd1) ? {{24{v[7]}}, v[7:0]} :
               (sz == 3'd2) ? {{16{v[15]}}, v[15:0]} : v;
    endfunction
    function msb_of(input [2:0] sz, input [31:0] v);
        msb_of = (sz == 3'd1) ? v[7] : (sz == 3'd2) ? v[15] : v[31];
    endfunction
    function msb1_of(input [2:0] sz, input [31:0] v);  // the bit below
        msb1_of = (sz == 3'd1) ? v[6] : (sz == 3'd2) ? v[14] : v[30];
    endfunction
    function [31:0] top_bit(input [2:0] sz);
        top_bit = (sz == 3'd1) ? 32'h00000080 :
                  (sz == 3'd2) ? 32'h00008000 : 32'h80000000;
    endfunction

    // A near branch target, and whether it is inside the code segment.
    function [31:0] tgt(input [31:0] t);
        tgt = os32 ? t : {16'd0, t[15:0]};
    endfunction
    function tgt_bad(input [31:0] t);
        tgt_bad = tgt(t) > seg_limit;
    endfunction

    // Set the six arithmetic flags from a result.
    task set_szp(input [2:0] sz, input [31:0] v);
        begin
            fl[F_ZF] <= ((v & szmask(sz)) == 32'd0);
            fl[F_SF] <= msb_of(sz, v);
            fl[F_PF] <= ~^v[7:0];
        end
    endtask

    // Shifter, one position a cycle (ST_SHIFT).
    wire [31:0] sh_mask = szmask(opsz);
    wire        sh_msb  = msb_of(opsz, ta);
    wire [31:0] sh_top  = top_bit(opsz);
    wire [31:0] sh_l    = (ta << 1) & sh_mask;
    wire [31:0] sh_r    = (ta & sh_mask) >> 1;

    // Divider inputs (group 3, AAM).
    wire        div_signed = !op[8] && (o == 8'hF6 || o == 8'hF7) && (m_reg == 3'd7);
    wire        is_aam     = !op[8] && (o == 8'hD4);
    wire [63:0] dvd_raw =
        is_aam        ? {56'd0, eax[7:0]} :
        (opsz == 3'd1) ? {{48{div_signed & eax[15]}}, eax[15:0]} :
        (opsz == 3'd2) ? {{32{div_signed & edx[15]}}, edx[15:0], eax[15:0]} :
                         {edx, eax};
    wire        dvd_neg = div_signed & dvd_raw[63];
    wire [63:0] dvd_mag = dvd_neg ? (64'd0 - dvd_raw) : dvd_raw;
    wire [31:0] dvs_raw = is_aam ? {24'd0, imm[7:0]} : ta;
    wire        dvs_neg = div_signed & msb_of(opsz, dvs_raw);
    wire [31:0] dvs_mag = dvs_neg ? ((32'd0 - dvs_raw) & szmask(opsz)) : dvs_raw;
    wire [31:0] dvd_hi  = (opsz == 3'd1) ? {24'd0, dvd_mag[15:8]} :
                          (opsz == 3'd2) ? {16'd0, dvd_mag[31:16]} : dvd_mag[63:32];
    wire [31:0] dvd_lo  = (opsz == 3'd1) ? {dvd_mag[7:0], 24'd0} :
                          (opsz == 3'd2) ? {dvd_mag[15:0], 16'd0} : dvd_mag[31:0];
    wire [32:0] dv_try  = {dv_r[31:0], dv_q[31]};
    wire        dv_ge   = dv_try >= {1'b0, dv_d};
    wire [31:0] dv_qm   = dv_q & szmask(opsz);
    wire [31:0] dv_half = top_bit(opsz);        // 2^(n-1)

    // String instructions.
    wire        str_cmp = (o == 8'hA6 || o == 8'hA7 || o == 8'hAE || o == 8'hAF);
    wire [31:0] str_d   = fl[F_DF] ? (32'd0 - {29'd0, opsz}) : {29'd0, opsz};
    wire [31:0] si_a    = esi & amask;
    wire [31:0] di_a    = edi & amask;
    wire [31:0] cx_a    = ecx & amask;
    wire        irq_now = nmi_pending || (irq && fl[F_IF]);

    task str_advance(input use_si, input use_di);
        begin
            if (use_si) begin
                if (as32) gprs[6*32 +: 32] <= esi + str_d;
                else      gprs[6*32 +: 16] <= esi[15:0] + str_d[15:0];
            end
            if (use_di) begin
                if (as32) gprs[7*32 +: 32] <= edi + str_d;
                else      gprs[7*32 +: 16] <= edi[15:0] + str_d[15:0];
            end
            if (rep != 2'd0) begin
                if (as32) gprs[1*32 +: 32] <= ecx - 32'd1;
                else      gprs[1*32 +: 16] <= ecx[15:0] - 16'd1;
            end
        end
    endtask

    // ---- faults and interrupts -------------------------------------

    task fault(input [7:0] v);
        begin
            last_exc <= in_fault ? 8'd8 : v;
            if (in_fault && fdepth) begin
                shutdown <= 1'b1;
                state <= ST_STOP;
            end else begin
                if (in_fault)
                    fdepth <= 1'b1;
                in_fault <= 1'b1;
                int_vec  <= in_fault ? 8'd8 : v;
                int_ret  <= eip_start;
                int_insn <= 1'b0;
                state    <= ST_INT;
                step     <= 5'd0;
            end
        end
    endtask

    task start_int(input [7:0] v, input [31:0] ret, input from_insn);
        begin
            int_vec  <= v;
            int_ret  <= ret;
            int_insn <= from_insn;
            state    <= ST_INT;
            step     <= 5'd0;
        end
    endtask

    // ---- bus request helpers ---------------------------------------

`define MEMOP(seg, off, sz, wr, data, ret) begin \
        m_seg <= (seg); m_off <= (off); m_size <= (sz); m_wr <= (wr); \
        m_wdata <= (data); m_phys <= 1'b0; m_io <= 1'b0; m_fetch <= 1'b0; \
        m_chk <= 1'b0; ret_state <= (ret); state <= ST_MEM; end
`define RD(seg, off, sz)        begin `MEMOP(seg, off, sz, 1'b0, 32'd0, ST_EXEC) step <= step + 5'd1; end
`define WR(seg, off, sz, data)  begin `MEMOP(seg, off, sz, 1'b1, data, ST_EXEC) step <= step + 5'd1; end
`define WR_DONE(seg, off, sz, data) `MEMOP(seg, off, sz, 1'b1, data, ST_DONE)
`define FETCH(sz, ret) begin \
        m_seg <= CS; m_off <= eip; m_size <= (sz); m_wr <= 1'b0; \
        m_phys <= 1'b0; m_io <= 1'b0; m_fetch <= 1'b1; m_chk <= 1'b0; \
        ret_state <= (ret); state <= ST_MEM; end
`define IO(port, sz, wr, data) begin \
        m_off <= {16'd0, (port)}; m_size <= (sz); m_wr <= (wr); m_wdata <= (data); \
        m_phys <= 1'b0; m_io <= 1'b1; m_fetch <= 1'b0; m_chk <= 1'b0; \
        ret_state <= ST_EXEC; state <= ST_MEM; step <= step + 5'd1; end
`define ALU(aop, a, b, sz, fm) begin \
        aluop <= (aop); ta <= (a); tb <= (b); asz <= (sz); alu_fm <= (fm); \
        alu_ret <= ST_EXEC; state <= ST_ALU; step <= step + 5'd1; end
`define DONE   state <= ST_DONE
`define NEXT   step <= step + 5'd1
// Write a result to the r/m operand and finish.
`define WBRM(sz, v) begin \
        if (is_mem) `WR_DONE(ea_seg, ea_off, sz, v) \
        else begin wrreg(sz, m_rm, v); `DONE; end end
`define PUSH(v, two) begin res <= (v); push_w2 <= (two); state <= ST_PUSH; end
// Stack offsets: the stack pointer is SP in real mode.
`define SPM(n) {16'd0, sp16 - (n)}
`define SPP(n) {16'd0, sp16 + (n)}
`define OSZ16  {13'd0, osz}

    wire [15:0] osz2 = {12'd0, osz, 1'b0};      // two slots
    wire [31:0] near_rel = eip + imm;

    // ---- the sequencer ---------------------------------------------

    integer i;
    always @(posedge clk) begin
        wa_en = 1'b0;
        wb_en = 1'b0;
        inta      <= 1'b0;
        insn_done <= 1'b0;
        step_done <= 1'b0;
        nmi_last  <= nmi;
        if (nmi && !nmi_last)
            nmi_pending <= 1'b1;

        if (rst) begin
            gprs      <= 256'd0;
            gprs[2*32 +: 32] <= 32'h00000300;   // DX: a 386
            eip       <= 32'h0000FFF0;
            fl        <= 18'h2;
            for (i = 0; i < 6; i = i + 1) begin
                ssel[i*16 +: 16]  <= 16'd0;
                sbase[i*32 +: 32] <= 32'd0;
            end
            ssel[1*16 +: 16]  <= 16'hF000;
            sbase[1*32 +: 32] <= 32'h000F0000;
            cr0 <= 32'd0; cr2 <= 32'd0; cr3 <= 32'd0;
            gdtr_base <= 32'd0; gdtr_lim <= 16'hFFFF;
            idtr_base <= 32'd0; idtr_lim <= 16'hFFFF;
            state <= ST_START;
            halted <= 1'b0; shutdown <= 1'b0; unsupported <= 1'b0;
            inhibit <= 1'b0; nmi_pending <= 1'b0; in_fault <= 1'b0;
            fdepth <= 1'b0; last_exc <= 8'hFF;
            m_chk <= 1'b0; m_io <= 1'b0; m_phys <= 1'b0; m_fetch <= 1'b0;
            mul_a <= 33'sd0; mul_b <= 33'sd0;
        end else case (state)

        // ---- instruction boundary --------------------------------
        ST_START: begin
            in_fault  <= 1'b0;
            fdepth    <= 1'b0;
            inhibit   <= 1'b0;
            eip_start <= eip;
            tf_start  <= fl[F_TF];
            os32 <= 1'b0; as32 <= 1'b0; ovr_v <= 1'b0; rep <= 2'd0;
            lock <= 1'b0; ilen <= 5'd0;
            modrm <= 8'hC0; sib <= 8'd0; disp <= 32'd0;
            if (!inhibit && irq_now) begin
                halted <= 1'b0;
                if (nmi_pending) begin
                    nmi_pending <= 1'b0;
                    start_int(8'd2, eip, 1'b0);
                end else begin
                    inta  <= 1'b1;
                    state <= ST_INTA;
                end
            end else if (!halted)
                `FETCH(3'd1, ST_OPC)
        end

        // The interrupt controller answers the acknowledge with a vector.
        ST_INTA:
            start_int(irq_vec, eip, 1'b0);

        // ---- prefixes and opcode ----------------------------------
        ST_OPC: begin
            case (mdr[7:0])
                8'h26: begin ovr_v <= 1; ovr <= ES; `FETCH(3'd1, ST_OPC) end
                8'h2E: begin ovr_v <= 1; ovr <= CS; `FETCH(3'd1, ST_OPC) end
                8'h36: begin ovr_v <= 1; ovr <= SS; `FETCH(3'd1, ST_OPC) end
                8'h3E: begin ovr_v <= 1; ovr <= DS; `FETCH(3'd1, ST_OPC) end
                8'h64: begin ovr_v <= 1; ovr <= FS; `FETCH(3'd1, ST_OPC) end
                8'h65: begin ovr_v <= 1; ovr <= GS; `FETCH(3'd1, ST_OPC) end
                8'h66: begin os32 <= 1; `FETCH(3'd1, ST_OPC) end
                8'h67: begin as32 <= 1; `FETCH(3'd1, ST_OPC) end
                8'hF0: begin lock <= 1; `FETCH(3'd1, ST_OPC) end
                8'hF2: begin rep <= 2'd2; `FETCH(3'd1, ST_OPC) end
                8'hF3: begin rep <= 2'd1; `FETCH(3'd1, ST_OPC) end
                8'h0F: `FETCH(3'd1, ST_OP2)
                default: begin op <= {1'b0, mdr[7:0]}; state <= ST_DEC; end
            endcase
        end
        ST_OP2: begin
            op <= {1'b1, mdr[7:0]};
            state <= ST_DEC;
        end
        ST_DEC: begin
            if (!d_valid)
                fault(8'd6);
            else if (d_modrm)
                `FETCH(3'd1, ST_MODRM)
            else if (lock)
                fault(8'd6);
            else
                state <= ST_IMMGO;
        end

        // ---- ModRM, SIB, displacement ------------------------------
        ST_MODRM: begin
            modrm <= mdr[7:0];
            state <= ST_MODRM2;
        end
        ST_MODRM2: begin
            // A misplaced LOCK is reported before the rest is fetched.
            if (lock && (!lockable || !is_mem))
                fault(8'd6);
            else if (!is_mem)
                state <= ST_IMMGO;
            else if (as32 && m_rm == 3'd4)
                `FETCH(3'd1, ST_SIB)
            else if (!as32 && ((m_mod == 2'd0 && m_rm == 3'd6) || m_mod == 2'd2))
                `FETCH(3'd2, ST_DISP)
            else if (as32 && ((m_mod == 2'd0 && m_rm == 3'd5) || m_mod == 2'd2))
                `FETCH(3'd4, ST_DISP)
            else if (m_mod == 2'd1)
                `FETCH(3'd1, ST_DISP)
            else
                state <= ST_EA;
        end
        ST_SIB: begin
            sib <= mdr[7:0];
            if ((m_mod == 2'd0 && mdr[2:0] == 3'd5) || m_mod == 2'd2)
                `FETCH(3'd4, ST_DISP)
            else if (m_mod == 2'd1)
                `FETCH(3'd1, ST_DISP)
            else
                state <= ST_EA;
        end
        ST_DISP: begin
            disp  <= (m_mod == 2'd1) ? {{24{mdr[7]}}, mdr[7:0]} : mdr;
            state <= ST_EA;
        end
        ST_EA: begin
            ea_off <= ea_c;
            ea_seg <= ovr_v ? ovr : ea_cseg;
            state  <= ST_IMMGO;
        end

        // ---- immediate ---------------------------------------------
        ST_IMMGO: begin
            if (ud)
                fault(8'd6);
            else case (d_imm)
                3'd0: state <= ST_CHK;
                3'd1, 3'd4: `FETCH(3'd1, ST_IMM)
                3'd2, 3'd5: `FETCH(osz, ST_IMM)
                3'd3, 3'd7: `FETCH(3'd2, ST_IMM)
                default:    `FETCH(as32 ? 3'd4 : 3'd2, ST_IMM)
            endcase
        end
        ST_IMM: begin
            imm <= (d_imm == 3'd4) ? {{24{mdr[7]}}, mdr[7:0]} :
                   (d_imm == 3'd2 && !os32 &&
                    (!op[8] ? (o == 8'hE8 || o == 8'hE9) : (o[7:4] == 4'h8)))
                       ? {{16{mdr[15]}}, mdr[15:0]} : mdr;
            if (d_imm == 3'd5)
                `FETCH(3'd2, ST_IMM2)
            else if (d_imm == 3'd7)
                `FETCH(3'd1, ST_IMM2)
            else
                state <= ST_CHK;
        end
        ST_IMM2: begin
            imm2  <= mdr[15:0];
            state <= ST_CHK;
        end

        // ---- validity, then the r/m operand -------------------------
        ST_CHK: begin
            step <= 5'd0;
            if (d_rdrm && is_mem)
                `MEMOP(ea_seg, ea_off, rmsz, 1'b0, 32'd0, ST_RDRM)
            else begin
                if (d_rdrm)
                    ta <= rdreg(rmsz, m_rm);
                state <= ST_EXEC;
            end
        end
        ST_RDRM: begin
            ta    <= mdr;
            state <= ST_EXEC;
        end

        // ---- one bus access ------------------------------------------
        ST_MEM: begin
            if (lim_fault)
                fault(m_seg == SS ? 8'd12 : 8'd13);
            else if (len_fault)
                fault(8'd13);
            else if (m_chk || bus_ack) begin
                mdr   <= bus_rdz;
                state <= ret_state;
                if (m_fetch) begin
                    eip  <= eip + {29'd0, m_size};
                    ilen <= ilen + {2'd0, m_size};
                end
            end
        end

        // ---- ALU ------------------------------------------------------
        ST_ALU: begin
            res <= alu_res;
            fl[F_OF] <= alu_of; fl[F_AF] <= alu_af; fl[F_ZF] <= alu_zf;
            fl[F_SF] <= alu_sf; fl[F_PF] <= alu_pf;
            if (alu_fm == 2'd1)
                fl[F_CF] <= alu_cf;
            state <= alu_ret;
        end

        // ---- push `res` and finish -------------------------------------
        ST_PUSH:
            `MEMOP(SS, `SPM(`OSZ16), push_w2 ? 3'd2 : osz, 1'b1, res, ST_PUSH2)
        ST_PUSH2: begin
            gprs[4*32 +: 16] <= sp16 - `OSZ16;
            `DONE;
        end

        // ---- shifts and rotates, one position a cycle -------------------
        ST_SHIFT: begin
            if (cnt != 6'd0) begin
                cnt <= cnt - 6'd1;
                if (sh_dbl) begin
                    if (!sh_right) begin        // SHLD
                        sh_cf <= sh_msb;
                        ta <= sh_l | {31'd0, msb_of(opsz, tc)};
                        tc <= ((tc << 1) & sh_mask) | {31'd0, msb_of(opsz, tc)};
                    end else begin              // SHRD
                        sh_cf <= ta[0];
                        ta <= sh_r | (tc[0] ? sh_top : 32'd0);
                        tc <= ((tc & sh_mask) >> 1) | (tc[0] ? sh_top : 32'd0);
                    end
                end else case (m_reg)
                    3'd0: begin sh_cf <= sh_msb; ta <= sh_l | {31'd0, sh_msb}; end
                    3'd1: begin sh_cf <= ta[0];  ta <= sh_r | (ta[0] ? sh_top : 32'd0); end
                    3'd2: begin sh_cf <= sh_msb; ta <= sh_l | {31'd0, sh_cf}; end
                    3'd3: begin sh_cf <= ta[0];  ta <= sh_r | (sh_cf ? sh_top : 32'd0); end
                    3'd5: begin sh_cf <= ta[0];  ta <= sh_r; end
                    3'd7: begin sh_cf <= ta[0];  ta <= sh_r | (sh_msb ? sh_top : 32'd0); end
                    default: begin sh_cf <= sh_msb; ta <= sh_l; end
                endcase
            end else begin
                // Flags from the finished result.
                fl[F_CF] <= sh_cf;
                if (sh_dbl) begin
                    fl[F_OF] <= msb_of(opsz, ta ^ tb);
                    set_szp(opsz, ta);
                    fl[F_AF] <= 1'b0;
                end else case (m_reg)
                    3'd0, 3'd2: fl[F_OF] <= sh_msb ^ sh_cf;
                    3'd1, 3'd3: fl[F_OF] <= sh_msb ^ msb1_of(opsz, ta);
                    default: begin
                        fl[F_OF] <= (m_reg == 3'd7) ? 1'b0 :
                                    (m_reg == 3'd5) ? msb1_of(opsz, ta) :
                                                      (sh_msb ^ sh_cf);
                        set_szp(opsz, ta);
                        fl[F_AF] <= 1'b0;
                        // Byte shifts by 16 or 24 report the carry of a
                        // count of 8 (docs/model.md).
                        if (opsz == 3'd1 && (sh_n == 6'd16 || sh_n == 6'd24) &&
                            m_reg != 3'd7) begin
                            fl[F_CF] <= (m_reg == 3'd5) ? tb[7] : tb[0];
                            if (m_reg != 3'd5)
                                fl[F_OF] <= tb[0];
                        end
                    end
                endcase
                `WBRM(opsz, ta)
            end
        end

        // ---- restoring division, one bit a cycle --------------------------
        ST_DIV: begin
            if (dv_n != 6'd0) begin
                dv_n <= dv_n - 6'd1;
                dv_r <= dv_ge ? (dv_try - {1'b0, dv_d}) : dv_try;
                dv_q <= {dv_q[30:0], dv_ge};
            end else
                state <= ST_EXEC;
        end

        // ---- interrupt and exception delivery (real mode) -----------------
        ST_INT: begin
            case (step)
                5'd0: begin
                    if ({22'd0, int_vec, 2'b11} > {16'd0, idtr_lim})
                        fault(8'd13);
                    else begin
                        m_off <= idtr_base + {22'd0, int_vec, 2'b00};
                        m_size <= 3'd4; m_wr <= 1'b0; m_phys <= 1'b1;
                        m_io <= 1'b0; m_fetch <= 1'b0; m_chk <= 1'b0;
                        ret_state <= ST_INT; state <= ST_MEM; step <= 5'd1;
                    end
                end
                5'd1: begin
                    tb <= mdr;
                    `MEMOP(SS, `SPM(16'd2), 3'd2, 1'b1, {14'd0, fl}, ST_INT)
                    step <= 5'd2;
                end
                5'd2: begin
                    `MEMOP(SS, `SPM(16'd4), 3'd2, 1'b1, {16'd0, ssel[1*16 +: 16]}, ST_INT)
                    step <= 5'd3;
                end
                5'd3: begin
                    `MEMOP(SS, `SPM(16'd6), 3'd2, 1'b1, int_ret, ST_INT)
                    step <= 5'd4;
                end
                default: begin
                    gprs[4*32 +: 16] <= sp16 - 16'd6;
                    fl[F_IF] <= 1'b0;
                    fl[F_TF] <= 1'b0;
                    segload(CS, tb[31:16]);
                    eip <= {16'd0, tb[15:0]};
                    state <= int_insn ? ST_DONE : ST_START;
                    step_done <= !int_insn;
                end
            endcase
        end

        // ---- end of an instruction -----------------------------------------
        ST_DONE: begin
            insn_done <= 1'b1;
            if (tf_start)
                start_int(8'd1, eip, 1'b0);
            else begin
                state <= ST_START;
                step_done <= 1'b1;
            end
        end

        ST_STOP: ;

        // ---- execution ------------------------------------------------------
        ST_EXEC: begin
            if (!op[8]) casez (o)

            // ALU: r/m,r   r,r/m   accumulator,immediate
            8'b00???00?: case (step)
                5'd0: `ALU({1'b0, o[5:3]}, ta, regv, opsz, 2'd1)
                default: if (o[5:3] == 3'd7) `DONE; else `WBRM(opsz, res)
            endcase
            8'b00???01?: case (step)
                5'd0: `ALU({1'b0, o[5:3]}, regv, ta, opsz, 2'd1)
                default: begin
                    if (o[5:3] != 3'd7) wrreg(opsz, m_reg, res);
                    `DONE;
                end
            endcase
            8'b00???10?: case (step)
                5'd0: `ALU({1'b0, o[5:3]}, acc, imm & szmask(opsz), opsz, 2'd1)
                default: begin
                    if (o[5:3] != 3'd7) wrreg(opsz, EAX, res);
                    `DONE;
                end
            endcase

            // PUSH and POP of a segment register
            8'b000??110: `PUSH({16'd0, ssel[{1'b0, o[4:3], 4'd0} +: 16]}, 1'b1)
            8'b000??111: case (step)
                5'd0: `RD(SS, {16'd0, sp16}, 3'd2)
                default: begin
                    gprs[4*32 +: 16] <= sp16 + `OSZ16;
                    segload({1'b0, o[4:3]}, mdr[15:0]);
                    if (o[4:3] == 2'd2) inhibit <= 1'b1;
                    `DONE;
                end
            endcase

            // DAA, DAS
            8'h27, 8'h2F: begin : bcd_da
                reg [7:0] al;
                reg       af, cf;
                al = eax[7:0];
                af = fl[F_AF];
                cf = 1'b0;
                if (eax[3:0] > 4'd9 || fl[F_AF]) begin
                    if (o == 8'h2F && eax[7:0] < 8'd6) cf = 1'b1;
                    al = (o == 8'h27) ? al + 8'd6 : al - 8'd6;
                    af = 1'b1;
                end
                if (eax[7:0] > 8'h99 || fl[F_CF]) begin
                    al = (o == 8'h27) ? al + 8'h60 : al - 8'h60;
                    cf = 1'b1;
                end
                gprs[7:0] <= al;
                fl[F_CF] <= cf;
                fl[F_AF] <= af;
                set_szp(3'd1, {24'd0, al});
                `DONE;
            end
            // AAA, AAS
            8'h37, 8'h3F: begin : bcd_aa
                reg [15:0] ax;
                ax = eax[15:0];
                if (eax[3:0] > 4'd9 || fl[F_AF]) begin
                    ax = (o == 8'h37) ? ax + 16'h0106 : ax - 16'h0106;
                    fl[F_AF] <= 1'b1;
                    fl[F_CF] <= 1'b1;
                end else begin
                    fl[F_AF] <= 1'b0;
                    fl[F_CF] <= 1'b0;
                end
                gprs[15:0] <= ax & 16'hFF0F;
                `DONE;
            end

            // INC, DEC register
            8'b0100????: case (step)
                5'd0: `ALU(o[3] ? 4'd9 : 4'd8, rdreg(osz, o[2:0]), 32'd0, osz, 2'd2)
                default: begin wrreg(osz, o[2:0], res); `DONE; end
            endcase
            // PUSH, POP register
            8'b01010???: `PUSH(rdreg(osz, o[2:0]), 1'b0)
            8'b01011???: case (step)
                5'd0: `RD(SS, {16'd0, sp16}, osz)
                default: begin
                    gprs[4*32 +: 16] <= sp16 + `OSZ16;
                    wrreg(osz, o[2:0], mdr);
                    `DONE;
                end
            endcase

            // PUSHA: the frame is written from its lowest address up.
            8'h60: begin
                if (step == 5'd0) begin
                    tsp <= sp16 - {osz2[13:0], 2'b00};
                    cnt <= 6'd0;
                    `NEXT;
                end else if (cnt[3]) begin
                    gprs[4*32 +: 16] <= tsp - {osz2[13:0], 2'b00};
                    `DONE;
                end else begin
                    `MEMOP(SS, {16'd0, tsp}, osz, 1'b1, rdreg(osz, ~cnt[2:0]), ST_EXEC)
                    tsp <= tsp + `OSZ16;
                    cnt <= cnt + 6'd1;
                end
            end
            // POPA: a register popped before a fault stays popped.
            8'h61: begin
                if (step == 5'd0) begin
                    tsp <= sp16;
                    cnt <= 6'd0;
                    tc  <= esp;
                    `NEXT;
                end else if (step == 5'd1) begin
                    if (cnt[3]) begin
                        gprs[4*32 +: 16] <= tsp;
                        if (os32) gprs[4*32+16 +: 16] <= tc[31:16];
                        `DONE;
                    end else begin
                        `MEMOP(SS, {16'd0, tsp}, osz, 1'b0, 32'd0, ST_EXEC)
                        step <= 5'd2;
                    end
                end else begin
                    if (cnt[2:0] == 3'd3) tc <= mdr;            // the ESP slot
                    else wrreg(osz, ~cnt[2:0], mdr);
                    tsp <= tsp + `OSZ16;
                    cnt <= cnt + 6'd1;
                    step <= 5'd1;
                end
            end

            // BOUND
            8'h62: case (step)
                5'd0: `RD(ea_seg, ea_off, osz)
                5'd1: begin ta <= mdr; `RD(ea_seg, ea_plus(osz), osz) end
                default: begin
                    if ($signed(sext(osz, regv)) < $signed(sext(osz, ta)) ||
                        $signed(sext(osz, regv)) > $signed(sext(osz, mdr)))
                        fault(8'd5);
                    else
                        `DONE;
                end
            endcase

            8'h68, 8'h6A: `PUSH(imm, 1'b0)

            // IMUL r, r/m, imm
            8'h69, 8'h6B: case (step)
                5'd0: begin
                    mul_a <= {ta[31] & os32 | ta[15] & ~os32, sext(osz, ta)};
                    mul_b <= {imm[31] & os32 | imm[15] & ~os32, sext(osz, imm)};
                    `NEXT;
                end
                5'd1: `NEXT;
                default: begin
                    wrreg(osz, m_reg, prod[31:0]);
                    fl[F_CF] <= os32 ? (prod[63:32] != {32{prod[31]}})
                                     : (prod[31:16] != {16{prod[15]}});
                    fl[F_OF] <= os32 ? (prod[63:32] != {32{prod[31]}})
                                     : (prod[31:16] != {16{prod[15]}});
                    `DONE;
                end
            endcase

            // String instructions, with REP
            8'h6C, 8'h6D, 8'h6E, 8'h6F, 8'hA4, 8'hA5, 8'hA6, 8'hA7,
            8'hAA, 8'hAB, 8'hAC, 8'hAD, 8'hAE, 8'hAF: case (step)
                5'd0: begin
                    if (rep != 2'd0 && cx_a == 32'd0)
                        `DONE;
                    else case (o)
                        8'h6C, 8'h6D: begin     // INS: check the store first
                            m_seg <= ES; m_off <= di_a; m_size <= opsz;
                            m_wr <= 1'b1; m_phys <= 1'b0; m_io <= 1'b0;
                            m_fetch <= 1'b0; m_chk <= 1'b1;
                            ret_state <= ST_EXEC; state <= ST_MEM; step <= 5'd1;
                        end
                        8'hAA, 8'hAB: begin `WR(ES, di_a, opsz, acc) step <= 5'd3; end
                        8'hAE, 8'hAF: begin `RD(ES, di_a, opsz) step <= 5'd2; end
                        default:      `RD(dseg, si_a, opsz)     // MOVS CMPS LODS OUTS
                    endcase
                end
                5'd1: case (o)
                    8'h6C, 8'h6D: `IO(edx[15:0], opsz, 1'b0, 32'd0)
                    8'h6E, 8'h6F: begin `IO(edx[15:0], opsz, 1'b1, mdr) step <= 5'd3; end
                    8'hA4, 8'hA5: begin `WR(ES, di_a, opsz, mdr) step <= 5'd3; end
                    8'hA6, 8'hA7: begin ta <= mdr; `RD(ES, di_a, opsz) end
                    default: begin              // LODS
                        wrreg(opsz, EAX, mdr);
                        step <= 5'd3;
                    end
                endcase
                5'd2: case (o)
                    8'h6C, 8'h6D: begin `WR(ES, di_a, opsz, mdr) step <= 5'd3; end
                    8'hA6, 8'hA7: begin
                        `ALU(4'd7, ta, mdr, opsz, 2'd1)
                        step <= 5'd3;
                    end
                    default: begin              // SCAS
                        `ALU(4'd7, acc, mdr, opsz, 2'd1)
                        step <= 5'd3;
                    end
                endcase
                5'd3: begin
                    str_advance(o == 8'h6E || o == 8'h6F || o == 8'hA4 || o == 8'hA5 ||
                                o == 8'hA6 || o == 8'hA7 || o == 8'hAC || o == 8'hAD,
                                !(o == 8'h6E || o == 8'h6F || o == 8'hAC || o == 8'hAD));
                    step <= 5'd4;
                end
                default: begin
                    if (rep == 2'd0)
                        `DONE;
                    else if (str_cmp && ((rep == 2'd1 && !fl[F_ZF]) ||
                                         (rep == 2'd2 && fl[F_ZF])))
                        `DONE;
                    else if (cx_a == 32'd0)
                        `DONE;
                    else if (irq_now) begin
                        // Let the interrupt in; the instruction resumes.
                        eip <= eip_start;
                        state <= ST_START;
                    end else
                        step <= 5'd0;
                end
            endcase

            // Jcc short
            8'b0111????: begin
                if (!cond(o[3:0])) `DONE;
                else if (tgt_bad(near_rel)) fault(8'd13);
                else begin eip <= tgt(near_rel); `DONE; end
            end

            // ALU r/m, imm
            8'h80, 8'h81, 8'h82, 8'h83: case (step)
                5'd0: `ALU({1'b0, m_reg}, ta, imm & szmask(opsz), opsz, 2'd1)
                default: if (m_reg == 3'd7) `DONE; else `WBRM(opsz, res)
            endcase
            8'h84, 8'h85: case (step)
                5'd0: `ALU(4'd4, ta, regv, opsz, 2'd1)
                default: `DONE;
            endcase
            8'h86, 8'h87: begin
                wrreg(opsz, m_reg, ta);
                `WBRM(opsz, regv)
            end
            8'h88, 8'h89: `WBRM(opsz, regv)
            8'h8A, 8'h8B: begin wrreg(opsz, m_reg, ta); `DONE; end
            8'h8C: begin
                if (is_mem) `WR_DONE(ea_seg, ea_off, 3'd2, {16'd0, ssel[{m_reg, 4'd0} +: 16]})
                else begin wrreg(osz, m_rm, {16'd0, ssel[{m_reg, 4'd0} +: 16]}); `DONE; end
            end
            8'h8D: begin wrreg(osz, m_reg, ea_off); `DONE; end
            8'h8E: begin
                segload(m_reg, ta[15:0]);
                if (m_reg == SS) inhibit <= 1'b1;
                `DONE;
            end
            8'h8F: case (step)
                5'd0: `RD(SS, {16'd0, sp16}, osz)
                5'd1: begin
                    if (is_mem) `WR(ea_seg, ea_off, osz, mdr)
                    else begin
                        gprs[4*32 +: 16] <= sp16 + `OSZ16;
                        wrreg(osz, m_rm, mdr);
                        `DONE;
                    end
                end
                default: begin gprs[4*32 +: 16] <= sp16 + `OSZ16; `DONE; end
            endcase

            8'h90: `DONE;
            8'b10010???: begin
                wrreg(osz, o[2:0], rdreg(osz, EAX));
                wrreg(osz, EAX, rdreg(osz, o[2:0]));
                `DONE;
            end
            8'h98: begin
                if (os32) gprs[31:0] <= {{16{eax[15]}}, eax[15:0]};
                else      gprs[15:0] <= {{8{eax[7]}}, eax[7:0]};
                `DONE;
            end
            8'h99: begin
                if (os32) gprs[2*32 +: 32] <= {32{eax[31]}};
                else      gprs[2*32 +: 16] <= {16{eax[15]}};
                `DONE;
            end

            // CALL far
            8'h9A: case (step)
                5'd0: `WR(SS, `SPM(`OSZ16), osz, {16'd0, ssel[1*16 +: 16]})
                5'd1: `WR(SS, `SPM(osz2), osz, eip)
                default: begin
                    if (tgt_bad(imm)) fault(8'd13);
                    else begin
                        gprs[4*32 +: 16] <= sp16 - osz2;
                        segload(CS, imm2);
                        eip <= tgt(imm);
                        `DONE;
                    end
                end
            endcase
            8'h9B: begin
                if (cr0[1] && cr0[3]) fault(8'd7); else `DONE;
            end
            8'h9C: `PUSH({16'd0, fl[15:0]}, 1'b0)
            8'h9D: case (step)
                5'd0: `RD(SS, {16'd0, sp16}, osz)
                default: begin
                    gprs[4*32 +: 16] <= sp16 + `OSZ16;
                    wrfl(mdr, os32 ? 18'h0FFFF : 18'h0FFFF);
                    `DONE;
                end
            endcase
            8'h9E: begin wrfl({24'd0, eax[15:8]}, 18'h000D5); `DONE; end
            8'h9F: begin gprs[15:8] <= fl[7:0]; `DONE; end

            // MOV accumulator, memory at an absolute offset
            8'hA0, 8'hA1: case (step)
                5'd0: `RD(dseg, imm & amask, opsz)
                default: begin wrreg(opsz, EAX, mdr); `DONE; end
            endcase
            8'hA2, 8'hA3: `WR_DONE(dseg, imm & amask, opsz, acc)
            8'hA8, 8'hA9: case (step)
                5'd0: `ALU(4'd4, acc, imm & szmask(opsz), opsz, 2'd1)
                default: `DONE;
            endcase

            8'b10110???: begin wrreg(3'd1, o[2:0], imm); `DONE; end
            8'b10111???: begin wrreg(osz, o[2:0], imm); `DONE; end

            // Shifts and rotates
            8'hC0, 8'hC1, 8'hD0, 8'hD1, 8'hD2, 8'hD3: begin
                tb     <= ta;
                sh_dbl <= 1'b0;
                sh_cf  <= fl[F_CF];
                cnt    <= (o[7:4] == 4'hC) ? {1'b0, imm[4:0]} :
                          o[1] ? {1'b0, ecx[4:0]} : 6'd1;
                sh_n   <= (o[7:4] == 4'hC) ? {1'b0, imm[4:0]} :
                          o[1] ? {1'b0, ecx[4:0]} : 6'd1;
                if (((o[7:4] == 4'hC) ? imm[4:0] : o[1] ? ecx[4:0] : 5'd1) == 5'd0)
                    `DONE;
                else
                    state <= ST_SHIFT;
            end

            // RET near
            8'hC2, 8'hC3: case (step)
                5'd0: `RD(SS, {16'd0, sp16}, osz)
                default: begin
                    if (tgt_bad(mdr)) fault(8'd13);
                    else begin
                        gprs[4*32 +: 16] <= sp16 + `OSZ16 + (o[0] ? 16'd0 : imm[15:0]);
                        eip <= tgt(mdr);
                        `DONE;
                    end
                end
            endcase

            // LES, LDS
            8'hC4, 8'hC5: case (step)
                5'd0: `RD(ea_seg, ea_off, osz)
                5'd1: begin ta <= mdr; `RD(ea_seg, ea_plus(osz), 3'd2) end
                default: begin
                    segload(o[0] ? DS : ES, mdr[15:0]);
                    wrreg(osz, m_reg, ta);
                    `DONE;
                end
            endcase
            8'hC6, 8'hC7: `WBRM(opsz, imm)

            // ENTER
            8'hC8: case (step)
                5'd0: begin
                    tsp <= sp16 - `OSZ16;
                    tc  <= {esp[31:16], sp16 - `OSZ16};        // the frame
                    ta  <= ebp;
                    cnt <= {1'b0, imm2[4:0]};
                    `WR(SS, `SPM(`OSZ16), osz, rdreg(osz, EBP))
                end
                5'd1: begin
                    if (cnt > 6'd1) begin
                        // Copy one outer frame pointer.
                        ta[15:0] <= ta[15:0] - `OSZ16;
                        `MEMOP(SS, {16'd0, ta[15:0] - `OSZ16}, osz, 1'b0, 32'd0, ST_EXEC)
                        step <= 5'd2;
                    end else if (cnt == 6'd1) begin
                        `MEMOP(SS, {16'd0, tsp - `OSZ16}, osz, 1'b1, tc, ST_EXEC)
                        tsp  <= tsp - `OSZ16;
                        cnt  <= 6'd0;
                    end else begin
                        wrreg(osz, EBP, tc);
                        gprs[4*32 +: 16] <= tsp - imm[15:0];
                        `DONE;
                    end
                end
                default: begin
                    `MEMOP(SS, {16'd0, tsp - `OSZ16}, osz, 1'b1, mdr, ST_EXEC)
                    tsp  <= tsp - `OSZ16;
                    cnt  <= cnt - 6'd1;
                    step <= 5'd1;
                end
            endcase
            // LEAVE
            8'hC9: case (step)
                5'd0: `RD(SS, {16'd0, ebp[15:0]}, osz)
                default: begin
                    gprs[4*32 +: 16] <= ebp[15:0] + `OSZ16;
                    wrreg(osz, EBP, mdr);
                    `DONE;
                end
            endcase

            // RET far
            8'hCA, 8'hCB: case (step)
                5'd0: `RD(SS, {16'd0, sp16}, osz)
                5'd1: begin ta <= mdr; `RD(SS, `SPP(`OSZ16), osz) end
                default: begin
                    if (tgt_bad(ta)) fault(8'd13);
                    else begin
                        gprs[4*32 +: 16] <= sp16 + osz2 + (o[0] ? 16'd0 : imm[15:0]);
                        segload(CS, mdr[15:0]);
                        eip <= tgt(ta);
                        `DONE;
                    end
                end
            endcase

            8'hCC: start_int(8'd3, eip, 1'b1);
            8'hCD: start_int(imm[7:0], eip, 1'b1);
            8'hCE: begin
                if (fl[F_OF]) start_int(8'd4, eip, 1'b1); else `DONE;
            end
            8'hF1: start_int(8'd1, eip, 1'b1);

            // IRET
            8'hCF: case (step)
                5'd0: `RD(SS, {16'd0, sp16}, osz)
                5'd1: begin ta <= mdr; `RD(SS, `SPP(`OSZ16), osz) end
                5'd2: begin tb <= mdr; `RD(SS, `SPP(osz2), osz) end
                default: begin
                    if (tgt_bad(ta)) fault(8'd13);
                    else begin
                        gprs[4*32 +: 16] <= sp16 + osz2 + `OSZ16;
                        segload(CS, tb[15:0]);
                        eip <= tgt(ta);
                        wrfl(mdr, 18'h0FFFF);
                        `DONE;
                    end
                end
            endcase

            // AAM: AL divided by the immediate
            8'hD4: case (step)
                5'd0: begin
                    if (imm[7:0] == 8'd0) fault(8'd0);
                    else begin
                        dv_d <= {24'd0, imm[7:0]};
                        dv_r <= 33'd0;
                        dv_q <= {eax[7:0], 24'd0};
                        dv_n <= 6'd8;
                        state <= ST_DIV;
                        `NEXT;
                    end
                end
                default: begin
                    gprs[15:0] <= {dv_q[7:0], dv_r[7:0]};
                    set_szp(3'd1, dv_r[31:0]);
                    `DONE;
                end
            endcase
            // AAD: AL + AH * immediate
            8'hD5: case (step)
                5'd0: begin
                    mul_a <= {25'd0, eax[15:8]};
                    mul_b <= {25'd0, imm[7:0]};
                    `NEXT;
                end
                5'd1: `NEXT;
                5'd2: `ALU(4'd0, {24'd0, eax[7:0]}, {24'd0, prod[7:0]}, 3'd1, 2'd1)
                default: begin gprs[15:0] <= {8'd0, res[7:0]}; `DONE; end
            endcase
            8'hD6: begin gprs[7:0] <= {8{fl[F_CF]}}; `DONE; end
            8'hD7: case (step)
                5'd0: `RD(dseg, (ebx + {24'd0, eax[7:0]}) & amask, 3'd1)
                default: begin gprs[7:0] <= mdr[7:0]; `DONE; end
            endcase
            // Coprocessor escape: there is no coprocessor.
            8'b11011???: begin
                if (cr0[2] || cr0[3]) fault(8'd7); else `DONE;
            end

            // LOOPNE, LOOPE, LOOP, JCXZ
            8'hE0, 8'hE1, 8'hE2, 8'hE3: begin : loops
                reg [31:0] cx1;
                reg        take;
                cx1 = (ecx - 32'd1) & amask;
                if (o[1:0] == 2'd3)
                    take = (cx_a == 32'd0);
                else begin
                    if (as32) gprs[1*32 +: 32] <= ecx - 32'd1;
                    else      gprs[1*32 +: 16] <= ecx[15:0] - 16'd1;
                    take = (cx1 != 32'd0) &&
                           (o[1:0] == 2'd2 || (fl[F_ZF] == o[0]));
                end
                if (!take) `DONE;
                else if (tgt_bad(near_rel)) begin
                    // The count is not changed if the jump faults.
                    gprs[1*32 +: 32] <= ecx;
                    fault(8'd13);
                end else begin eip <= tgt(near_rel); `DONE; end
            end

            // IN, OUT
            8'hE4, 8'hE5, 8'hEC, 8'hED: case (step)
                5'd0: `IO(o[3] ? edx[15:0] : {8'd0, imm[7:0]}, opsz, 1'b0, 32'd0)
                default: begin wrreg(opsz, EAX, mdr); `DONE; end
            endcase
            8'hE6, 8'hE7, 8'hEE, 8'hEF: case (step)
                5'd0: `IO(o[3] ? edx[15:0] : {8'd0, imm[7:0]}, opsz, 1'b1, acc)
                default: `DONE;
            endcase

            // CALL, JMP near
            8'hE8: case (step)
                5'd0: `WR(SS, `SPM(`OSZ16), osz, eip)
                default: begin
                    if (tgt_bad(near_rel)) fault(8'd13);
                    else begin
                        gprs[4*32 +: 16] <= sp16 - `OSZ16;
                        eip <= tgt(near_rel);
                        `DONE;
                    end
                end
            endcase
            8'hE9, 8'hEB: begin
                if (tgt_bad(near_rel)) fault(8'd13);
                else begin eip <= tgt(near_rel); `DONE; end
            end
            8'hEA: begin
                if (tgt_bad(imm)) fault(8'd13);
                else begin segload(CS, imm2); eip <= tgt(imm); `DONE; end
            end

            8'hF4: begin halted <= 1'b1; `DONE; end
            8'hF5: begin fl[F_CF] <= ~fl[F_CF]; `DONE; end
            8'hF8: begin fl[F_CF] <= 1'b0; `DONE; end
            8'hF9: begin fl[F_CF] <= 1'b1; `DONE; end
            8'hFA: begin fl[F_IF] <= 1'b0; `DONE; end
            8'hFB: begin
                if (!fl[F_IF]) inhibit <= 1'b1;
                fl[F_IF] <= 1'b1;
                `DONE;
            end
            8'hFC: begin fl[F_DF] <= 1'b0; `DONE; end
            8'hFD: begin fl[F_DF] <= 1'b1; `DONE; end

            // Group 3: TEST, NOT, NEG, MUL, IMUL, DIV, IDIV
            8'hF6, 8'hF7: case (m_reg)
                3'd0, 3'd1: case (step)
                    5'd0: `ALU(4'd4, ta, imm & szmask(opsz), opsz, 2'd1)
                    default: `DONE;
                endcase
                3'd2: `WBRM(opsz, ~ta)
                3'd3: case (step)
                    5'd0: `ALU(4'd5, 32'd0, ta, opsz, 2'd1)
                    default: `WBRM(opsz, res)
                endcase
                3'd4, 3'd5: case (step)
                    5'd0: begin
                        mul_a <= {m_reg[0] & msb_of(opsz, acc),
                                  m_reg[0] ? sext(opsz, acc) : acc};
                        mul_b <= {m_reg[0] & msb_of(opsz, ta),
                                  m_reg[0] ? sext(opsz, ta) : ta};
                        `NEXT;
                    end
                    5'd1: `NEXT;
                    default: begin : mul_done
                        reg ovf;
                        case (opsz)
                            3'd1: begin
                                gprs[15:0] <= prod[15:0];
                                ovf = m_reg[0] ? (prod[15:8] != {8{prod[7]}})
                                               : (prod[15:8] != 8'd0);
                            end
                            3'd2: begin
                                gprs[15:0] <= prod[15:0];
                                gprs[2*32 +: 16] <= prod[31:16];
                                ovf = m_reg[0] ? (prod[31:16] != {16{prod[15]}})
                                               : (prod[31:16] != 16'd0);
                            end
                            default: begin
                                gprs[31:0] <= prod[31:0];
                                gprs[2*32 +: 32] <= prod[63:32];
                                ovf = m_reg[0] ? (prod[63:32] != {32{prod[31]}})
                                               : (prod[63:32] != 32'd0);
                            end
                        endcase
                        fl[F_CF] <= ovf;
                        fl[F_OF] <= ovf;
                        `DONE;
                    end
                endcase
                default: case (step)
                    5'd0: begin
                        if (dvs_mag == 32'd0 || dvd_hi >= dvs_mag)
                            fault(8'd0);
                        else begin
                            dv_d <= dvs_mag;
                            dv_r <= {1'b0, dvd_hi};
                            dv_q <= dvd_lo;
                            dv_n <= {opsz, 3'd0};
                            dv_qneg <= dvd_neg ^ dvs_neg;
                            dv_rneg <= dvd_neg;
                            dv_signed <= div_signed;
                            state <= ST_DIV;
                            `NEXT;
                        end
                    end
                    default: begin : div_done
                        reg [31:0] q, r;
                        q = dv_qneg ? (32'd0 - dv_qm) : dv_qm;
                        r = dv_rneg ? (32'd0 - dv_r[31:0]) : dv_r[31:0];
                        if (dv_signed && (dv_qneg ? (dv_qm > dv_half)
                                                  : (dv_qm >= dv_half)))
                            fault(8'd0);
                        else begin
                            if (opsz == 3'd1)
                                gprs[15:0] <= {r[7:0], q[7:0]};
                            else begin
                                wrreg(opsz, EAX, q);
                                wrreg(opsz, EDX, r);
                            end
                            `DONE;
                        end
                    end
                endcase
            endcase

            // Group 4 and 5
            8'hFE, 8'hFF: case (m_reg)
                3'd0, 3'd1: case (step)
                    5'd0: `ALU(m_reg[0] ? 4'd9 : 4'd8, ta, 32'd0, opsz, 2'd2)
                    default: `WBRM(opsz, res)
                endcase
                3'd2: case (step)               // CALL near, indirect
                    5'd0: `WR(SS, `SPM(`OSZ16), osz, eip)
                    default: begin
                        if (tgt_bad(ta)) fault(8'd13);
                        else begin
                            gprs[4*32 +: 16] <= sp16 - `OSZ16;
                            eip <= tgt(ta);
                            `DONE;
                        end
                    end
                endcase
                3'd4: begin                     // JMP near, indirect
                    if (tgt_bad(ta)) fault(8'd13);
                    else begin eip <= tgt(ta); `DONE; end
                end
                3'd3, 3'd5: case (step)         // CALL, JMP far, indirect
                    5'd0: `RD(ea_seg, ea_off, osz)
                    5'd1: begin ta <= mdr; `RD(ea_seg, ea_plus(osz), 3'd2) end
                    5'd2: begin
                        tb <= mdr;
                        if (m_reg == 3'd3) `WR(SS, `SPM(`OSZ16), osz, {16'd0, ssel[1*16 +: 16]})
                        else step <= 5'd4;
                    end
                    5'd3: `WR(SS, `SPM(osz2), osz, eip)
                    default: begin
                        if (tgt_bad(ta)) fault(8'd13);
                        else begin
                            if (m_reg == 3'd3) gprs[4*32 +: 16] <= sp16 - osz2;
                            segload(CS, tb[15:0]);
                            eip <= tgt(ta);
                            `DONE;
                        end
                    end
                endcase
                default: `PUSH(ta, 1'b0)        // PUSH r/m
            endcase

            default: fault(8'd6);
            endcase

            // ---- the 0F map -------------------------------------------
            else casez (o)

            8'h01: case (m_reg)
                3'd0, 3'd1: case (step)         // SGDT, SIDT
                    5'd0: `WR(ea_seg, ea_off, 3'd2,
                              {16'd0, m_reg[0] ? idtr_lim : gdtr_lim})
                    default: `WR_DONE(ea_seg, ea_plus(3'd2), 3'd4,
                                      m_reg[0] ? idtr_base : gdtr_base)
                endcase
                3'd2, 3'd3: case (step)         // LGDT, LIDT
                    5'd0: `RD(ea_seg, ea_off, 3'd2)
                    5'd1: begin ta <= mdr; `RD(ea_seg, ea_plus(3'd2), 3'd4) end
                    default: begin
                        if (m_reg[0]) begin
                            idtr_lim  <= ta[15:0];
                            idtr_base <= os32 ? mdr : {8'd0, mdr[23:0]};
                        end else begin
                            gdtr_lim  <= ta[15:0];
                            gdtr_base <= os32 ? mdr : {8'd0, mdr[23:0]};
                        end
                        `DONE;
                    end
                endcase
                3'd4: begin                     // SMSW
                    if (is_mem) `WR_DONE(ea_seg, ea_off, 3'd2, cr0)
                    else begin wrreg(osz, m_rm, cr0); `DONE; end
                end
                default: case (step)            // LMSW: cannot clear PE
                    5'd0: begin
                        if (is_mem) `RD(ea_seg, ea_off, 3'd2)
                        else begin mdr <= rdreg(3'd2, m_rm); `NEXT; end
                    end
                    default: begin
                        cr0[3:1] <= mdr[3:1];
                        if (mdr[0]) begin
                            cr0[0] <= 1'b1;
                            unsupported <= 1'b1;
                            state <= ST_STOP;
                        end else
                            `DONE;
                    end
                endcase
            endcase
            8'h06: begin cr0[3] <= 1'b0; `DONE; end

            // MOV to and from control registers. Debug registers are
            // accepted and ignored until the level that has them.
            8'h20: begin
                wrreg(3'd4, m_rm, (m_reg == 3'd0) ? cr0 :
                                  (m_reg == 3'd2) ? cr2 : cr3);
                `DONE;
            end
            8'h22: begin
                if (m_reg == 3'd0) begin
                    cr0 <= gprs[{m_rm, 5'd0} +: 32];
                    if (gprs[{m_rm, 5'd0} + 31] || gprs[{m_rm, 5'd0}]) begin
                        unsupported <= 1'b1;
                        state <= ST_STOP;
                    end else
                        `DONE;
                end else begin
                    if (m_reg == 3'd2) cr2 <= gprs[{m_rm, 5'd0} +: 32];
                    else               cr3 <= gprs[{m_rm, 5'd0} +: 32];
                    `DONE;
                end
            end
            8'h21: begin wrreg(3'd4, m_rm, 32'd0); `DONE; end
            8'h23: `DONE;

            // Jcc near
            8'b1000????: begin
                if (!cond(o[3:0])) `DONE;
                else if (tgt_bad(near_rel)) fault(8'd13);
                else begin eip <= tgt(near_rel); `DONE; end
            end
            // SETcc
            8'b1001????: `WBRM(3'd1, {31'd0, cond(o[3:0])})

            8'hA0, 8'hA8: `PUSH({16'd0, ssel[(o[3] ? 5*16 : 4*16) +: 16]}, 1'b1)
            8'hA1, 8'hA9: case (step)
                5'd0: `RD(SS, {16'd0, sp16}, 3'd2)
                default: begin
                    gprs[4*32 +: 16] <= sp16 + `OSZ16;
                    segload(o[3] ? GS : FS, mdr[15:0]);
                    `DONE;
                end
            endcase

            // BT, BTS, BTR, BTC with the bit number in a register
            8'hA3, 8'hAB, 8'hB3, 8'hBB: case (step)
                5'd0: begin : bit_ea
                    reg [31:0] adj;
                    // The bit number reaches outside the operand.
                    adj = os32 ? {{3{regv[31]}}, regv[31:5], 2'b00}
                               : {{19{regv[15]}}, regv[15:4], 1'b0};
                    if (is_mem) begin
                        ea_off <= (ea_off + adj) & amask;
                        `MEMOP(ea_seg, (ea_off + adj) & amask, osz, 1'b0, 32'd0, ST_EXEC)
                        step <= 5'd1;
                    end else begin
                        mdr <= rdreg(osz, m_rm);
                        `NEXT;
                    end
                end
                default: begin : bit_reg
                    reg [4:0]  b;
                    reg [31:0] bitm;
                    b = os32 ? regv[4:0] : {1'b0, regv[3:0]};
                    bitm = 32'd1 << b;
                    fl[F_CF] <= mdr[b];
                    case (o[4:3])
                        2'd0: `DONE;                                    // BT
                        2'd1: `WBRM(osz, mdr | bitm)                    // BTS
                        2'd2: `WBRM(osz, mdr & ~bitm)                   // BTR
                        default: `WBRM(osz, mdr ^ bitm)                 // BTC
                    endcase
                end
            endcase
            // The same with an immediate bit number
            8'hBA: begin : bit_imm
                reg [4:0]  b;
                reg [31:0] bitm;
                b = os32 ? imm[4:0] : {1'b0, imm[3:0]};
                bitm = 32'd1 << b;
                fl[F_CF] <= ta[b];
                case (m_reg[1:0])
                    2'd0: `DONE;
                    2'd1: `WBRM(osz, ta | bitm)
                    2'd2: `WBRM(osz, ta & ~bitm)
                    default: `WBRM(osz, ta ^ bitm)
                endcase
            end

            // SHLD, SHRD
            8'hA4, 8'hA5, 8'hAC, 8'hAD: begin
                tb       <= ta;
                tc       <= regv;
                sh_dbl   <= 1'b1;
                sh_right <= o[3];
                sh_cf    <= fl[F_CF];
                cnt      <= {1'b0, o[0] ? ecx[4:0] : imm[4:0]};
                if ((o[0] ? ecx[4:0] : imm[4:0]) == 5'd0)
                    `DONE;
                else
                    state <= ST_SHIFT;
            end

            // IMUL r, r/m
            8'hAF: case (step)
                5'd0: begin
                    mul_a <= {msb_of(osz, regv), sext(osz, regv)};
                    mul_b <= {msb_of(osz, ta), sext(osz, ta)};
                    `NEXT;
                end
                5'd1: `NEXT;
                default: begin
                    wrreg(osz, m_reg, prod[31:0]);
                    fl[F_CF] <= os32 ? (prod[63:32] != {32{prod[31]}})
                                     : (prod[31:16] != {16{prod[15]}});
                    fl[F_OF] <= os32 ? (prod[63:32] != {32{prod[31]}})
                                     : (prod[31:16] != {16{prod[15]}});
                    `DONE;
                end
            endcase

            // LSS, LFS, LGS
            8'hB2, 8'hB4, 8'hB5: case (step)
                5'd0: `RD(ea_seg, ea_off, osz)
                5'd1: begin ta <= mdr; `RD(ea_seg, ea_plus(osz), 3'd2) end
                default: begin
                    segload(o[2] ? (o[0] ? GS : FS) : SS, mdr[15:0]);
                    wrreg(osz, m_reg, ta);
                    if (!o[2]) inhibit <= 1'b1;
                    `DONE;
                end
            endcase

            // MOVZX, MOVSX
            8'hB6, 8'hB7: begin wrreg(osz, m_reg, ta); `DONE; end
            8'hBE, 8'hBF: begin wrreg(osz, m_reg, sext(rmsz, ta)); `DONE; end

            // BSF, BSR: scan a bit a cycle
            8'hBC, 8'hBD: case (step)
                5'd0: begin
                    if ((ta & szmask(osz)) == 32'd0) begin
                        fl[F_ZF] <= 1'b1;
                        `DONE;
                    end else begin
                        cnt <= o[0] ? (os32 ? 6'd31 : 6'd15) : 6'd0;
                        `NEXT;
                    end
                end
                default: begin
                    if (ta[cnt[4:0]]) begin
                        fl[F_ZF] <= 1'b0;
                        wrreg(osz, m_reg, {26'd0, cnt});
                        `DONE;
                    end else
                        cnt <= o[0] ? cnt - 6'd1 : cnt + 6'd1;
                end
            endcase

            default: fault(8'd6);
            endcase
        end

        default: state <= ST_STOP;
        endcase

        if (!rst) begin
            if (wa_en) wrport(wa_sz, wa_idx, wa_val);
            if (wb_en) wrport(wb_sz, wb_idx, wb_val);
        end
    end

`undef MEMOP
`undef RD
`undef WR
`undef WR_DONE
`undef FETCH
`undef IO
`undef ALU
`undef DONE
`undef NEXT
`undef WBRM
`undef PUSH
`undef SPM
`undef SPP
`undef OSZ16

endmodule

`default_nettype wire
