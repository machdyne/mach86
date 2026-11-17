/*
 * Mach86 CPU, design B -- micro-op engine with a decoded-instruction
 * cache. See docs/cpu_b.md.
 *
 * Sources: I386-PRM ch. 17 (instruction formats, ModRM and SIB), ch. 14
 * (real mode); SST-386 for the undocumented SIB case.
 *
 * An x86 instruction is decoded once. A small state machine reads its
 * bytes; a ROM says where its microcode starts; the first
 * micro-operation, with the instruction's registers filled in, is
 * written to the decoded-instruction cache. Every later execution
 * reads that entry and runs it directly, one micro-operation a cycle.
 * Instructions that need more than one micro-operation continue in the
 * microcode ROM.
 *
 * STATUS: runs the instructions that have microcode (sw/ucode); the
 * rest raise the invalid-opcode fault. No interrupts, no I/O.
 *
 * A micro-operation ("uop"), 48 bits:
 *
 *   [3:0]   a      register A: base of an address, or left operand
 *   [7:4]   b      register B: index of an address, or right operand
 *   [11:8]  c      register C: data to store, or the register operand
 *                  of a load-and-operate
 *   [15:12] d      destination register
 *   [16]    d_we   write the destination
 *   [18:17] size   0: 8 bits, 1: 16, 2: 32
 *   [22:19] hi     use bits 15:8 of A, B, D, C (AH-style registers)
 *   [25:23] unit   0 ALU(a,b)  1 ALU(a,imm)  2 LOAD  3 LOAD-OP
 *                  4 STORE     5 SHIFT       6 MUL   7 SPECIAL
 *   [29:26] aop    ALU operation, shift kind, or special operation.
 *                  For a STORE, what is stored: 0 register C, 1 the
 *                  immediate, 2 what the special operation READ reads
 *                  (B says what; for a segment selector, C says which)
 *   [31:30] fmask  flags: 0 none, 1 all six, 2 all but carry,
 *                  3 carry and overflow only
 *   [34:32] seg    segment of a memory operand (6: flat, base 0;
 *                  7: an I/O port)
 *   [36:35] scale  index scale
 *   [37]    a16    offsets and jump targets are 16 bits
 *   [38]    disp   the address includes the displacement
 *   [39]    aupd   stack-style access: STORE at A - size and write
 *                  that back to A; LOAD at A and add size to A.
 *                  With cc bit 3, a STORE is at A and adds size to A.
 *                  With cc bit 0, a LOAD or STORE is at A and then
 *                  moves A as a string instruction does: up by the
 *                  size, or down if the direction flag is set
 *   [42:40] br     0 next  1 Jcc rel  2 JMP rel  3 jump to result
 *                  4 halt  5 jump rel if the last ALU result was not
 *                  zero  6 jump rel if it was zero  7 by cc: 0 jump
 *                  to register C (16 bits of it if the size is 16),
 *                  1 jump rel unless A is one (LOOP: A is the count
 *                  before it is decremented), 2 jump rel if A is zero
 *   [46:43] cc     condition for Jcc and SETcc. For a shift: bit 0
 *                  takes the count from register B, not the
 *                  immediate. Otherwise: bit 0 swaps the
 *                  operands of a LOAD-OP; bit 1 makes a STORE reuse
 *                  the address of the previous access; bit 2 makes
 *                  a memory access 16 bits wide whatever the size
 *                  (the stack pointer still moves by the size)
 *   [47]    idx    the address includes the scaled index
 *
 * Registers 0-7 are EAX..EDI; 8 always holds zero; 9-15 are
 * temporaries for microcode.
 *
 * A microcode ROM word, 90 bits (81 used), is a uop with holes plus sequencing:
 *
 *   [47:0]  uop    with literal fields
 *   [57:48] k      jump target, or a constant
 *   [58]    ujmp   jump to k after this uop   [59] only if ucc holds
 *   [63:60] ucc    condition for the jump
 *   [64]    end    last uop of the instruction
 *   [65]    usek   k replaces the immediate and the displacement
 *   [67:66] sela   register A from: 0 the field, 1 ModRM r/m,
 *   [69:68] selb     2 ModRM reg, 3 the low three opcode bits
 *   [71:70] selc
 *   [73:72] seld
 *   [74]    selea  address fields from the instruction's ModRM/SIB
 *   [76:75] selaop 0 the field, 1 opcode bits 5:3, 2 ModRM reg
 *   [77]    selcc  condition from opcode bits 3:0
 *   [79:78] selseg segment from: 0 the field, 1 ModRM reg, 2 opcode
 *                  bits 5:3, 3 the segment of the ModRM operand (and
 *                  the offset wraps as that operand's does)
 *   [80]    asz    size 3 means the address size, not the operand size
 *   [82]    a16as  offsets are 16 bits unless the address size is 32
 *   [83]    ucx    the jump condition is the REP prefix: ucc 0 any
 *                  REP, 2 REPNE; bit 0 inverts
 *   [81]    ucz    the jump condition is the zero latch (the last ALU
 *                  result was zero), inverted if ucc bit 0 is set
 *   [84]    uca    the jump condition is that this uop's A is not one
 *                  (a count that is being decremented does not reach
 *                  zero)
 *   size = 3 in the uop means the instruction's operand size.
 *
 * The opcode attribute ROM, 18 bits, indexed by {memory form, 0F map,
 * opcode}:
 *
 *   [9:0] microcode entry  [10] has ModRM  [13:11] immediate kind
 *   [14] byte operand      [15] valid      [16] group: add ModRM reg
 *   to the entry           [17] without ModRM: the immediate is a jump
 *   displacement; with ModRM: LOCK is allowed on the memory form
 *
 * A string instruction with a REP prefix starts one word after its
 * entry.
 */
`default_nettype none

module m86b_core #(
    parameter DC_AW = 11,
    parameter UC_AW = 10,
    parameter UCODE = "ucode.hex",
    parameter ATTR  = "attr.hex"
) (
    input  wire        clk,
    input  wire        rst,

    // Data bus. A request made in one cycle is answered in the next if
    // the cache hits. Sizes are 0: 1 byte, 1: 2 bytes, 2: 4 bytes, at
    // any alignment.
    output wire        d_req,
    output wire        d_wr,
    output reg  [31:0] d_addr,
    output reg  [1:0]  d_size,
    output reg  [31:0] d_wdata,
    input  wire [31:0] d_rdata,
    input  wire        d_ack,
    // A write is never held on the bus: it is taken in the cycle it is
    // asked. Instead the memory says beforehand, with d_st_rdy, whether
    // a write may be started; one that may not waits in the CPU.
    input  wire        d_st_rdy,
    // A read of memory, a cycle before it is on the bus: the address
    // as it is being worked out. A memory that looks it up at once can
    // answer in the cycle the request appears. It may not appear: a
    // fault found meanwhile cancels it. Reads by the instruction
    // decoder are not announced.
    output wire        e_req,
    output wire [31:0] e_addr,
    output wire [1:0]  e_size,
    output reg         d_io,        // the request is to an I/O port

    // Interrupts. inta is high for one cycle when a request is taken;
    // the vector is read from irq_vec at the end of that cycle.
    // A speed control: wait this many cycles after every instruction
    // (0: none). For programs that fail on a machine this fast.
    input  wire [7:0]  slow,
    input  wire        irq,
    input  wire [7:0]  irq_vec,
    output reg         inta,

    output reg         halted,
    output reg         step_done,   // an instruction, fault or interrupt finished
    output reg  [7:0]  last_exc,
    output reg  [31:0] dbg_insns
);
    localparam UW  = 48;
    localparam RW  = 90;
    localparam TW  = 32 - DC_AW;
    localparam GW  = 1;     // generation bits: with 1, every emptying is a real clearing
    localparam CW  = 33;                // decode context kept per entry
    // Decoded ahead: what of a uop the first logic of a cycle needs,
    // worked out when the uop is resolved and kept beside it (in the
    // cache: in bits its block RAMs had spare).
    //   0 subtract  1 with carry  2 B is one (INC, DEC)  3 the adder's
    //   result (not a logic operation's)  4 (not of the uop: the code
    //   segment's D bit when the entry was made)  5 load-and-
    //   operate  6 ALU with the immediate
    localparam PW  = 7;
    // valid, generation, tag, length, continuation, decoded-ahead, uop,
    // context, imm, disp
    localparam DCW = 1 + GW + TW + 4 + UC_AW + PW + UW + CW + 32 + 32;

    localparam [UC_AW-1:0] UC_FAULT = 'h008;
    localparam [UC_AW-1:0] UC_IRQ   = 'h004;
    localparam [UC_AW-1:0] UC_PMSEG = 'h018;
    localparam [3:0] ZERO = 4'd8;

    // ---- register file: 16 x 32 in byte lanes, three read ports ----

    reg [7:0] rf0 [0:15] /* verilator public_flat_rw */;
    reg [7:0] rf1 [0:15] /* verilator public_flat_rw */;
    reg [7:0] rf2 [0:15] /* verilator public_flat_rw */;
    reg [7:0] rf3 [0:15] /* verilator public_flat_rw */;
    integer k;
    initial for (k = 0; k < 16; k = k + 1) begin
        rf0[k] = 8'd0; rf1[k] = 8'd0; rf2[k] = 8'd0; rf3[k] = 8'd0;
    end
    reg         rf_we;
    reg  [3:0]  rf_wa, rf_lane;
    reg  [31:0] rf_wd;
    always @(posedge clk) begin
        if (rf_we && rf_lane[0]) rf0[rf_wa] <= rf_wd[7:0];
        if (rf_we && rf_lane[1]) rf1[rf_wa] <= rf_wd[15:8];
        if (rf_we && rf_lane[2]) rf2[rf_wa] <= rf_wd[23:16];
        if (rf_we && rf_lane[3]) rf3[rf_wa] <= rf_wd[31:24];
    end

    // ESP as it was when the instruction began, for faults.
    reg [31:0] esp_now /* verilator public_flat_rw */;
    reg [31:0] esp0;

    // ---- segments ---------------------------------------------------

    reg [31:0] seg_base [0:7] /* verilator public_flat_rw */;
    reg [31:0] seg_lim  [0:7] /* verilator public_flat_rw */;
    reg [15:0] seg_sel  [0:7] /* verilator public_flat_rw */;
    // The upper half of each base, plus one: what the upper half of a
    // linear address is when a 16-bit offset carries into it.
    reg [15:0] seg_hi1  [0:7] /* verilator public_flat_rw */;
    initial for (k = 0; k < 8; k = k + 1) begin
        seg_base[k] = 32'd0; seg_sel[k] = 16'd0; seg_hi1[k] = 16'd1;
        seg_lim[k] = (k < 6) ? 32'h0000FFFF : 32'hFFFFFFFF;
    end
    reg        sg_we;
    reg [2:0]  sg_wa;
    reg [15:0] sg_sel;
    reg        sg_pm;                   // from a descriptor: base and limit both
    reg [31:0] sg_base, sg_lim;
    always @(posedge clk)
        if (sg_we) begin
            seg_sel[sg_wa]  <= sg_sel;
            seg_base[sg_wa] <= sg_base;
            seg_hi1[sg_wa]  <= sg_base[31:16] + 16'd1;
            // In real mode a load leaves the limit as it is: that is
            // what lets a program reach past 64 KB after a visit to
            // protected mode ("unreal mode").
            if (sg_pm)
                seg_lim[sg_wa] <= sg_lim;
        end

    // ---- protected mode: the first part (docs/pmode.md) ----
    // CR0, the two table registers, and segment loads from the GDT.
    reg [31:0] cr0 /* verilator public_flat_rw */;
    reg [31:0] cr2, cr3;
    reg [31:0] gdt_base /* verilator public_flat_rw */;
    reg [31:0] idt_base /* verilator public_flat_rw */;
    reg [15:0] gdt_lim /* verilator public_flat_rw */;
    reg [15:0] idt_lim /* verilator public_flat_rw */;
    // A segment load with CR0.PE set does not happen where the
    // microcode has it: the microcode is sent to a routine (UC_PMSEG)
    // that reads the descriptor and ends with a SETSEG of its own,
    // which does the load and goes back to where the first would have
    // gone on. So every instruction that loads a segment register
    // gets this without knowing of it.
    reg               in_pm;            // in that routine
    reg [UC_AW-1:0]   pm_ret;           // where to go on
    reg               pm_last;          // ... or the instruction ends
    reg [2:0]         pm_seg;
    reg [15:0]        pm_sel;
    reg [31:0]        pm_lo;            // the descriptor's first half
    reg [31:0]        pm_desc;          // where the descriptor is
    // The D bit of the code segment's descriptor (operands and
    // addresses are 32 bits unless a prefix says otherwise) and the
    // B bit of the stack segment's (the stack pointer is ESP, not SP).
    reg               cs_d /* verilator public_flat_rw */;
    reg               ss_b /* verilator public_flat_rw */;
    // The local descriptor table and the task register: selectors,
    // and where the table is. (Limits are not kept: nothing is checked.)
    reg [15:0]        ldt_sel, tr_sel;
    reg [31:0]        ldt_base;
    reg [15:0]        ldt_lim;
    reg               sel_ok;           // the selector last looked up names a descriptor
    reg               in_flt;           // the microcode running is delivering a fault
    reg [31:0] cs_base /* verilator public_flat_rw */;

    // ---- decoded-instruction cache -----------------------------------

    (* no_rw_check *)
    reg  [DCW-1:0] dc [0:(1<<DC_AW)-1] /* verilator public_flat_rw */;
    reg  [DCW-1:0] dc_q;
    reg  [DC_AW-1:0] dc_ra, dc_wa;
    reg            dc_re, dc_we;
    reg  [DCW-1:0] dc_wd;
    initial for (k = 0; k < (1 << DC_AW); k = k + 1) dc[k] = {DCW{1'b0}};
    always @(posedge clk) begin
        if (dc_re) dc_q <= dc[dc_ra];
        if (dc_we) dc[dc_wa] <= dc_wd;
    end
    wire [31:0]      q_disp = dc_q[31:0];
    wire [31:0]      q_imm  = dc_q[63:32];
    wire [CW-1:0]    q_ctx  = dc_q[64 +: CW];
    wire [UW-1:0]    q_uop  = dc_q[64+CW +: UW];
    wire [PW-1:0]    q_pre  = dc_q[64+CW+UW +: PW];
    wire [UC_AW-1:0] q_cont = dc_q[64+CW+UW+PW +: UC_AW];
    wire [3:0]       q_len  = dc_q[64+CW+UW+PW+UC_AW +: 4];
    wire [TW-1:0]    q_tag  = dc_q[64+CW+UW+PW+UC_AW+4 +: TW];
    wire [GW-1:0]    q_gen  = dc_q[64+CW+UW+PW+UC_AW+4+TW +: GW];
    wire             q_v    = dc_q[DCW-1];

    // ---- ROMs ----------------------------------------------------------

    reg  [RW-1:0] urom [0:(1<<UC_AW)-1];
    reg  [RW-1:0] ur_q;
    reg  [UC_AW-1:0] ur_a, ur_n;
    initial $readmemh(UCODE, urom);
    always @(posedge clk)
        ur_q <= urom[ur_a];

    reg  [17:0] attr [0:1023];
    reg  [17:0] attr_q;
    reg  [9:0]  attr_a;
    initial $readmemh(ATTR, attr);
    always @(posedge clk)
        attr_q <= attr[attr_a];

    // Which 64-byte blocks of memory hold cached instructions, by
    // generation. Generation 0 means none.
    (* no_rw_check *)
    reg  [GW-1:0] cmap [0:32767];
    reg  [GW-1:0] cmap_q /* verilator public_flat */;
    reg  [GW-1:0] gen /* verilator public_flat_rw */;
    reg           st_chk /* verilator public_flat */;
    reg           dc_fill;
    reg           cm2_pend;
    reg  [14:0]   cm2_blk;
    reg           cm_clr;           // a block found to hold no cached instruction
    reg  [14:0]   cm_clr_blk;
    // The generation number has wrapped: every entry is being cleared,
    // and until that is done nothing is served from the cache or put
    // into it.
    reg           flushing /* verilator public_flat */;
    reg  [DC_AW-1:0] fl_idx /* verilator public_flat */;
    initial for (k = 0; k < 32768; k = k + 1) cmap[k] = {GW{1'b0}};
    // (Two megabytes: in real mode addresses go up to 10FFEFh, and a
    // block above the first megabyte must not share its mark with one
    // below, or taking the mark off one would take it off both.)
    always @(posedge clk) begin
        cmap_q <= cmap[d_addr[20:6]];
        // An instruction's first and last bytes may lie in two blocks;
        // the second is marked a cycle later.
        if (dc_fill) cmap[i_lin[20:6]] <= gen;
        else if (cm2_pend) cmap[cm2_blk] <= gen;
        else if (cm_clr) cmap[cm_clr_blk] <= {GW{1'b0}};
        cm2_pend <= dc_fill && (i_end[20:6] != i_lin[20:6]);
        cm2_blk  <= i_end[20:6];
    end
    // Above two megabytes the map is coarser: a mark for each 4 KB,
    // of 64 MB (addresses 64 MB apart share one, which costs only
    // time). A store to a marked page is followed by the search for
    // the instructions it overlaps, as below two megabytes, but the
    // page is not looked through and its mark never taken off: a
    // page of code and data mixed pays about twenty cycles a store.
    (* no_rw_check *)
    reg  [GW-1:0] cmaph [0:16383];
    reg  [GW-1:0] cmaph_q;
    reg           cmh_pend;
    reg  [13:0]   cmh_blk;
    initial for (k = 0; k < 16384; k = k + 1) cmaph[k] = {GW{1'b0}};
    wire          i_hi = (i_lin[31:21] != 11'd0);
    always @(posedge clk) begin
        cmaph_q <= cmaph[d_addr[25:12]];
        if (dc_fill && i_hi) cmaph[i_lin[25:12]] <= gen;
        else if (cmh_pend) cmaph[cmh_blk] <= gen;
        cmh_pend <= dc_fill && i_hi && (i_end[25:12] != i_lin[25:12]);
        cmh_blk  <= i_end[25:12];
    end

    // ---- state ----------------------------------------------------------

    reg [31:0] lk_eip /* verilator public_flat_rw */;
    reg [31:0] lk_lin /* verilator public_flat_rw */;
    reg        lk_pend /* verilator public_flat_rw */;
    reg [18:0] fl /* verilator public_flat_rw */;   // EFLAGS bits 18..0 (18: AC, a 486's)
    reg        in_rom;          // executing from the microcode ROM
    reg        s1_v, s2_v;      // ROM word fetched; ROM uop ready
    reg [UC_AW-1:0] upc1;       // address of the word in ur_q
    reg        cyc2, cyc3;
    reg        uz;              // the last ALU result was zero
    reg        jt_pend;
    reg [31:0] jt_eip;

    // The instruction being executed.
    reg [31:0] i_eip, i_lin, i_imm, i_disp;
    reg [3:0]  i_len;
    reg [CW-1:0] i_ctx;
    reg        i_first;         // its first uop is still to be cached

    wire [7:0] c_modrm = i_ctx[7:0];
    wire [7:0] c_sib   = i_ctx[15:8];
    wire [7:0] c_op    = i_ctx[23:16];
    wire       c_os32  = i_ctx[25];
    wire       c_as32  = i_ctx[26];
    wire       c_ovr_v = i_ctx[27];
    wire [2:0] c_ovr   = i_ctx[30:28];
    wire [1:0] c_rep   = i_ctx[32:31];  // bit 0: REP or REPNE prefix; bit 1: REPNE

    // Fault in progress.
    reg        flt_v;
    reg [7:0]  flt_vec;

    // ---- resolving a ROM word against the instruction -------------------

    wire [31:0] i_end = i_lin + {28'd0, i_len} - 32'd1;   // the instruction's last byte
    wire [1:0] c_mod = c_modrm[7:6];
    wire [2:0] c_reg = c_modrm[5:3];
    wire [2:0] c_rm  = c_modrm[2:0];
    wire       c_byte = attr_byte_r;
    reg        attr_byte_r;
    wire [1:0] c_size = c_byte ? 2'd0 : c_os32 ? 2'd2 : 2'd1;

    // Address fields from ModRM and SIB.
    reg [3:0] ea_base, ea_index;
    reg       ea_idx, ea_disp, ea_ss;
    reg [1:0] ea_scale;
    always @* begin
        ea_base = ZERO; ea_index = ZERO; ea_idx = 1'b0; ea_scale = 2'd0;
        ea_ss = 1'b0;
        ea_disp = (c_mod == 2'd1 || c_mod == 2'd2);
        if (!c_as32) begin
            case (c_rm)
                3'd0: begin ea_base = 4'd3; ea_index = 4'd6; ea_idx = 1'b1; end
                3'd1: begin ea_base = 4'd3; ea_index = 4'd7; ea_idx = 1'b1; end
                3'd2: begin ea_base = 4'd5; ea_index = 4'd6; ea_idx = 1'b1; ea_ss = 1'b1; end
                3'd3: begin ea_base = 4'd5; ea_index = 4'd7; ea_idx = 1'b1; ea_ss = 1'b1; end
                3'd4: ea_base = 4'd6;
                3'd5: ea_base = 4'd7;
                3'd6: if (c_mod == 2'd0) ea_disp = 1'b1;
                      else begin ea_base = 4'd5; ea_ss = 1'b1; end
                3'd7: ea_base = 4'd3;
            endcase
        end else if (c_rm == 3'd4) begin
            if (c_sib[2:0] == 3'd5 && c_mod == 2'd0)
                ea_disp = 1'b1;
            else begin
                ea_base = {1'b0, c_sib[2:0]};
                ea_ss = (c_sib[2:0] == 3'd4 || c_sib[2:0] == 3'd5);
            end
            if (c_sib[5:3] != 3'd4) begin
                ea_index = {1'b0, c_sib[5:3]};
                ea_idx = 1'b1;
                ea_scale = c_sib[7:6];
            end else if (c_sib[7:6] != 2'd0) begin
                // A scale with no index scales the base (undocumented).
                ea_index = ea_base;
                ea_base = ZERO;
                ea_idx = 1'b1;
                ea_scale = c_sib[7:6];
            end
        end else if (c_rm == 3'd5 && c_mod == 2'd0)
            ea_disp = 1'b1;
        else begin
            ea_base = {1'b0, c_rm};
            ea_ss = (c_rm == 3'd5);
        end
    end

    // One register field: the index and whether it is an AH-style byte.
    // (Everything the function reads is an argument: a simulator need
    // not re-evaluate a function call when a signal it reads from the
    // module changes.)
    function [4:0] regsel(input [1:0] sel, input [3:0] lit, input lit_hi,
                          input [1:0] size, input [2:0] rm, input [2:0] rg,
                          input [2:0] opr);
        reg [2:0] r;
        begin
            r = (sel == 2'd1) ? rm : (sel == 2'd2) ? rg : opr;
            if (sel == 2'd0)
                regsel = {lit_hi, lit};
            else if (size == 2'd0)
                regsel = {r[2], 2'b00, r[1:0]};
            else
                regsel = {1'b0, 1'b0, r};
        end
    endfunction

    wire [RW-1:0] w = ur_q;
    // (Bit 87: the size is the stack's width. Bit 86, below: so is
    // the offset's.)
    wire [1:0] w_size = w[87] ? (ss_b ? 2'd2 : 2'd1) :
                        (w[18:17] != 2'd3) ? w[18:17] :
                        w[80] ? (c_as32 ? 2'd2 : 2'd1) : c_size;
    wire [4:0] w_a = regsel(w[67:66], w[3:0],   w[19], w_size, c_rm, c_reg, c_op[2:0]);
    wire [4:0] w_b = regsel(w[69:68], w[7:4],   w[20], w_size, c_rm, c_reg, c_op[2:0]);
    wire [4:0] w_c = regsel(w[71:70], w[11:8],  w[22], w_size, c_rm, c_reg, c_op[2:0]);
    wire [4:0] w_d = regsel(w[73:72], w[15:12], w[21], w_size, c_rm, c_reg, c_op[2:0]);
    wire       w_ea = w[74];
    // (Selector 3: the bit instruction named by the opcode's bits
    // 4:3 -- BT, BTS, BTR, BTC -- as the ALU's bit operation. BT writes
    // nothing: its ALU word's result is dropped and its STORE is a
    // NOP.)
    wire       w_bit  = (w[76:75] == 2'd3);
    wire       w_bt   = w_bit && (c_op[4:3] == 2'd0);
    wire       w_btst = w_bt && (w[25:23] == 3'd4);
    wire [3:0] w_aop = w_btst ? 4'd0 :
                       (w_bit && w[25:23] != 3'd4) ? (w_bt ? 4'd13 : {2'b11, c_op[4:3]}) :
                       (w[76:75] == 2'd1) ? {1'b0, c_op[5:3]} :
                       (w[76:75] == 2'd2) ? {1'b0, c_reg} : w[29:26];
    wire [2:0] w_unit = w_btst ? 3'd7 : w[25:23];
    // A compare writes nothing.
    wire       w_cmp = (w_unit == 3'd0 || w_unit == 3'd1 || w_unit == 3'd3) &&
                       (w_aop == 4'd7);
    wire [UW-1:0] w_res = {
        w_ea ? ea_idx : w[47],
        w_btst ? 4'd0 : w[77] ? c_op[3:0] : w[46:43],
        w[42:40],
        w[39],
        w_ea ? ea_disp : w[38],
        (w[86] ? !ss_b :
         (w_ea || w[79:78] == 2'd3 || w[82]) ? !c_as32 :
         (w[42:40] != 3'd0 && w_unit != 3'd4) ? !c_os32 : w[37]),
        w_ea ? ea_scale : w[36:35],
        w_ea ? (c_ovr_v ? c_ovr : ea_ss ? 3'd2 : 3'd3) :
            (w[79:78] == 2'd1) ? c_reg : (w[79:78] == 2'd2) ? c_op[5:3] :
            (w[79:78] == 2'd3) ? (c_ovr_v ? c_ovr : ea_ss ? 3'd2 : 3'd3) : w[34:32],
        w[31:30],
        w_aop,
        w_unit,
        w_c[4], w_d[4], (w_ea ? 1'b0 : w_b[4]), (w_ea ? 1'b0 : w_a[4]),
        w_size,
        w[16] && !w_cmp && !w_bt,
        w_d[3:0], w_c[3:0],
        w_ea ? ea_index : w_b[3:0],
        w_ea ? ea_base  : w_a[3:0] };

    wire [PW-1:0] w_pre = {
        w_unit == 3'd1,
        w_unit == 3'd3,
        cs_d,
        w_aop == 4'd0 || w_aop == 4'd2 || w_aop == 4'd3 || w_aop == 4'd5 ||
            w_aop == 4'd7 || w_aop == 4'd8 || w_aop == 4'd9,
        w_aop == 4'd8 || w_aop == 4'd9,
        w_aop == 4'd2 || w_aop == 4'd3,
        w_aop == 4'd3 || w_aop == 4'd5 || w_aop == 4'd7 || w_aop == 4'd9 };

    // The ROM uop ready to execute, with its sequencing.
    reg [UW-1:0]    r_uop;
    reg [PW-1:0]    r_pre;
    reg [UC_AW-1:0] r_k;
    reg             r_ujmp, r_ucond, r_end, r_usek, r_ucz, r_ucx, r_uca, r_ucpe, r_ucflt;
    reg [3:0]       r_ucc;

    // ---- the uop being executed -----------------------------------------

    // An entry is good for the default sizes it was decoded under. The
    // stack's width is in it too (a PUSH's offset), but not marked:
    // while code and stack segments disagree -- a few instructions of
    // a mode switch, as a rule -- the cache is neither used nor filled.
    wire       mode_ok = (cs_d == ss_b);

    // Once a cached uop has begun (a load waiting for its data, say), it
    // finishes even if the cache is emptied under it by an earlier store.
    wire       hit   = lk_pend && ((!in_rom && (cyc2 || cyc3)) ||
                       (!flushing && q_v && q_gen == gen && q_tag == lk_lin[31:DC_AW] &&
                        q_pre[4] == cs_d && mode_ok));
    // An interrupt request is taken between instructions, and not
    // straight after an instruction that holds interrupts off for one
    // more (a load of SS, or STI).
    reg        inh, inh_next;
    reg        rst_seq /* verilator public_flat_rw */;   // the reset microcode is running
    // Between instructions: nothing has begun.
    wire       between  = !rst && lk_pend && !in_rom && !jt_pend && !flt_now &&
                          !cyc2 && !cyc3;

    // A store into a block that holds cached instructions. The entries
    // of the instructions it overlaps are found and removed, between
    // instructions: an instruction that covers the stored bytes starts
    // at most 14 bytes before them, so 14 + size entries are read, one a
    // cycle. One more such store can wait its turn; a third empties
    // the whole cache instead.
    reg [31:0] st_addr;                 // the last store
    reg [2:0]  st_n;
    reg        pr_v, pq_v;              // a probe to do; another queued
    reg [31:0] pr_addr, pq_addr;
    reg [2:0]  pr_n, pq_n;
    reg        probing /* verilator public_flat */;
    reg [31:0] p_cand;                  // start address of the entry being read
    reg [6:0]  p_left;                  // entries still to read
    reg signed [7:0] p_dist;            // stored address minus the entry read last
    // When the entries near a store hold nothing, the whole block is
    // looked through (p_scan); if it holds no cached instruction its
    // mark is taken off, and stores there cost nothing from then on.
    // Without this a block where code once ran -- memory a program
    // was loaded into before, a stack where a program used to be --
    // made every store into it wait for a search, for ever. A block
    // that does hold instructions is remembered (one of them), so
    // that it is not looked through again at every store.
    reg        p_scan, p_found, p_dirty;
    reg [14:0] p_dblk;
    reg        p_dblk_v;
    reg        p_ev;                    // an entry read last cycle is in dc_q
    reg        p_restore;
    wire       probe_take /* verilator public_flat */ = between && pr_v && !probing;
    reg  [7:0] sl_cnt;
    reg        sl_hold;                 // waiting (sl_cnt is not zero)
    wire       phold = probe_take || probing || sl_hold;
    wire       p_match = p_ev && dc_q[DCW-1] && q_tag == p_evaddr[31:DC_AW] &&
                         (p_dist <= 8'sd0 || $signed({4'b0000, q_len}) > p_dist);
    wire       p_kill /* verilator public_flat */ = p_match && !p_scan;
    reg [31:0] p_evaddr;

    wire       irq_take = between && !phold && irq && fl[9] && !inh;
    wire       miss /* verilator public_flat */ = lk_pend && !hit && !in_rom && !halted && !jt_pend && !irq_take && !phold;
    wire       hot   = !in_rom;
    wire [UW-1:0] uop = hot ? q_uop : r_uop;
    wire [PW-1:0] pre = hot ? q_pre : r_pre;
    wire       p_sub = pre[0], p_usec = pre[1], p_one = pre[2], p_arith = pre[3];
    wire       p_loadop = pre[5], p_alui = pre[6];
    wire       valid0 = !rst && !halted && !jt_pend && !flt_now && !irq_take && !phold &&
                        (hot ? hit : s2_v);
    wire       st_block;            // a store that the memory is not ready for
    wire       valid = valid0 && !st_block;
    wire       usek  = !hot && r_usek;
    wire [31:0] kext = {{(32-UC_AW){r_k[UC_AW-1]}}, r_k};
    wire [31:0] imm  = usek ? kext : hot ? q_imm : i_imm;
    wire [31:0] disp = usek ? kext : hot ? q_disp : i_disp;
    wire [3:0]  len  = hot ? q_len : i_len;
    wire        last0 = hot ? (q_cont == {UC_AW{1'b0}}) : r_end;
    // A segment load sent to the descriptor routine is not the end;
    // the routine's own is, if the first was.
    wire        is_setseg = (u_unit == U_SPEC) && (u_aop == SP_SETSEG);
    wire        pm_div = valid && is_setseg && cr0[0] && !in_pm;
    wire        pm_fin = valid && is_setseg && in_pm;
    wire        last = !is_setseg ? last0 : in_pm ? pm_last : (last0 && !cr0[0]);
    // Going there and coming back are jumps in the microcode.
    wire        pm_jump = (pm_div || (pm_fin && !pm_last)) && !hot;
    wire [31:0] cur_eip = (hot && !cyc2 && !cyc3) ? lk_eip : i_eip;

    wire [3:0] u_a = uop[3:0],   u_b = uop[7:4];
    wire [3:0] u_c = uop[11:8],  u_d = uop[15:12];
    wire       u_dwe  = uop[16];
    wire [1:0] u_size = uop[18:17];
    wire [3:0] u_hi   = uop[22:19];
    wire [2:0] u_unit = uop[25:23];
    wire [3:0] u_aop  = uop[29:26];
    wire [1:0] u_fm   = uop[31:30];
    wire [2:0] u_seg  = uop[34:32];
    wire [1:0] u_scale = uop[36:35];
    wire       u_a16  = uop[37];
    wire       u_disp = uop[38];
    wire       u_aupd = uop[39];
    wire [2:0] u_br   = uop[42:40];
    wire [3:0] u_cc   = uop[46:43];
    wire       u_idx  = uop[47];

    localparam U_ALU = 3'd0, U_ALUI = 3'd1, U_LOAD = 3'd2, U_LOADOP = 3'd3,
               U_STORE = 3'd4, U_SHIFT = 3'd5, U_MUL = 3'd6, U_SPEC = 3'd7;

    wire [2:0] bytes = (u_size == 2'd0) ? 3'd1 : (u_size == 2'd1) ? 3'd2 : 3'd4;
    wire [31:0] smask = (u_size == 2'd0) ? 32'h000000FF :
                        (u_size == 2'd1) ? 32'h0000FFFF : 32'hFFFFFFFF;

    wire [31:0] ra = {rf3[u_a], rf2[u_a], rf1[u_a], rf0[u_a]};
    wire [31:0] rb = {rf3[u_b], rf2[u_b], rf1[u_b], rf0[u_b]};
    wire [31:0] rc = {rf3[u_c], rf2[u_c], rf1[u_c], rf0[u_c]};
    wire [31:0] va = (u_hi[0] ? {24'd0, ra[15:8]} : ra) & smask;
    wire [31:0] vb = (u_hi[1] ? {24'd0, rb[15:8]} : rb) & smask;
    wire [31:0] vc = (u_hi[3] ? {24'd0, rc[15:8]} : rc) & smask;
    wire [31:0] vm = d_rdata & smask;

    // ---- address generation ----------------------------------------------

    wire        is_mem  = (u_unit == U_LOAD || u_unit == U_LOADOP || u_unit == U_STORE);
    assign      st_block = valid0 && (u_unit == U_STORE) && !d_st_rdy;
    wire        relatch = (u_unit == U_STORE) && u_cc[1] && (u_br != 3'd1);
    wire        mem_ls  = (u_unit == U_LOAD || u_unit == U_STORE);
    wire        strstep = mem_ls && u_aupd && u_cc[0];      // as a string instruction
    wire        push    = (u_unit == U_STORE) && u_aupd && !u_cc[3] && !u_cc[0];
    // The offset is register + index + displacement (a push: register
    // - size), cut to 16 bits with 16-bit addressing, and the linear
    // address is the segment's base + that. Four numbers: they are
    // reduced three-to-two twice, so that one carry chain makes the
    // offset and one, beside it, the address. With 16-bit addressing
    // the address's upper half is the base's, or the base's plus one
    // (kept with the base) if the cut offset carries into it -- which
    // is told from the two chains' carries at bit 16 (cy16).
    wire [31:0] ad_y  = u_idx ? (rb << u_scale) : 32'd0;
    wire [31:0] ad_z  = push ? -{29'd0, bytes} : (u_disp ? disp : 32'd0);
    wire [31:0] ad_s1 = ra ^ ad_y ^ ad_z;
    wire [32:0] ad_c1 = {(ra & ad_y) | (ra & ad_z) | (ad_y & ad_z), 1'b0};
    wire [16:0] off_lo = {1'b0, ad_s1[15:0]} + {1'b0, ad_c1[15:0]};
    wire [15:0] off_hi = ad_s1[31:16] + ad_c1[31:16] + {15'd0, off_lo[16]};
    wire [31:0] off    = u_a16 ? {16'd0, off_lo[15:0]} : {off_hi, off_lo[15:0]};
    wire [31:0] ad_b  = seg_base[u_seg];
    wire [31:0] ad_s2 = ad_b ^ ad_s1 ^ ad_c1[31:0];
    wire [32:0] ad_c2 = {(ad_b & ad_s1) | (ad_b & ad_c1[31:0]) | (ad_s1 & ad_c1[31:0]), 1'b0};
    wire [16:0] lin_lo = {1'b0, ad_s2[15:0]} + {1'b0, ad_c2[15:0]};
    wire [15:0] lin_hi = ad_s2[31:16] + ad_c2[31:16] + {15'd0, lin_lo[16]};
    wire        cy16   = lin_lo[16] ^ ad_c2[16] ^ off_lo[16];
    wire [31:0] lin    = {u_a16 ? (cy16 ? seg_hi1[u_seg] : ad_b[31:16]) : lin_hi,
                          lin_lo[15:0]};

    assign e_req  = valid && !stall && is_mem && !cyc2 && (u_unit != U_STORE) &&
                    (u_seg != 3'd7);
    assign e_addr = lin;
    assign e_size = u_cc[2] ? 2'd1 : u_size;

    // The limit check is made a cycle later, from registers.
    reg        chk_v;
    // (The limit kept is the highest offset the first byte may have:
    // the segment's limit less the access's other bytes, taken off as
    // it is registered; bit 32 says that no offset will do. So the
    // check is one comparison.)
    reg [31:0] chk_off;
    reg [32:0] chk_lim;
    reg        chk_ss;
    wire       lim_now = chk_v && (chk_lim[32] || chk_off > chk_lim[31:0]);

    // A jump target outside the code segment, likewise a cycle late.
    reg        jchk_v;
    reg [31:0] cs_lim;
    wire       jmp_bad = jchk_v && lk_eip > cs_lim;

    // A string access moves its pointer in the cycle it is asked for,
    // and whether it was allowed is known a cycle later. If it was not,
    // the pointer is put back, and so is the pointer that the access
    // straight before it in the same instruction moved (MOVS reads,
    // then writes): an instruction that faults changes nothing. Two
    // such moves are remembered; a uop of any other kind between them,
    // or the start of an instruction, forgets the older.
    reg        un0_v, un1_v, un_second;
    reg [3:0]  un0_r, un1_r;
    reg [31:0] un0_d, un1_d;

    // A fault found this cycle cancels the uop that is running.
    reg        ud_now;          // from the decoder or from microcode
    reg [7:0]  ud_vec;
    wire       flt_now = lim_now || ud_now || jmp_bad;

    // ---- ALU ----------------------------------------------------------------

    wire        op2    = p_loadop && cyc2;
    wire        swap   = u_cc[0];
    wire [31:0] alu_a  = op2 ? (swap ? vm : vc) : va;
    wire [31:0] alu_b  = p_one ? 32'd1 :
                         op2 ? (swap ? vc : vm) :
                         p_alui ? (imm & smask) : vb;
    wire [31:0] alu_res, alu_sum, alu_other;
    wire        alu_cf, alu_of, alu_af, alu_zf, alu_sf, alu_pf;
    m86b_alu alu (
        .op(u_aop), .sub(p_sub), .usec(p_usec), .arith(p_arith),
        .a(alu_a), .b(alu_b), .cin(fl[0]), .size(bytes),
        .res(alu_res), .sum(alu_sum), .other(alu_other),
        .cf(alu_cf), .of(alu_of), .af(alu_af),
        .zf(alu_zf), .sf(alu_sf), .pf(alu_pf));
    wire        alu_arith = p_arith;

    // A pointer that moves with its access (a stack pointer, a string
    // pointer) has an adder of its own: up or down by the operand's
    // size, the whole register whatever the operand's size.
    wire        ptr_dn  = push || (strstep && fl[10]);
    wire [31:0] ptr_sum = ra + (ptr_dn ? -{29'd0, bytes} : {29'd0, bytes});

    // ---- shifter and multiplier ------------------------------------------------

    // The count is the immediate, or register B when cc[0] is set.
    wire [4:0]  sh_n   = (u_unit != U_SHIFT) ? 5'd0 : u_cc[0] ? vb[4:0] : imm[4:0];
    wire        sh_rt  = u_aop[0];
    wire [4:0]  sh_k   = sh_rt ? (5'd0 - sh_n) : sh_n;
    wire [32:0] pow2   = 33'd1 << sh_k;
    wire        sh_sx  = (u_aop == 4'd7);
    wire [31:0] va_rep = (u_size == 2'd0) ? {4{va[7:0]}} :
                         (u_size == 2'd1) ? {2{va[15:0]}} : va;
    wire        a_sign = (u_size == 2'd0) ? va[7] : (u_size == 2'd1) ? va[15] : va[31];
    wire        b_sign = (u_size == 2'd0) ? vb[7] : (u_size == 2'd1) ? vb[15] : vb[31];
    wire [32:0] m_a = (u_unit == U_MUL)
                        ? {u_aop[0] & a_sign, u_aop[0] ? (va | ({32{a_sign}} & ~smask)) : va}
                        : (u_aop[2:1] == 2'd0) ? {1'b0, va_rep}
                        : {sh_sx & a_sign, sh_sx ? (va | ({32{a_sign}} & ~smask)) : va};
    wire [32:0] m_b = (u_unit == U_MUL)
                        ? {u_aop[0] & b_sign, u_aop[0] ? (vb | ({32{b_sign}} & ~smask)) : vb}
                        : pow2;
    reg  signed [32:0] m_a_r, m_b_r;
    reg  signed [65:0] prod;
    always @(posedge clk) begin
        m_a_r <= m_a;
        m_b_r <= m_b;
        prod  <= m_a_r * m_b_r;
    end
    // Multiply: the upper half of the product, and whether it holds
    // more than the sign (or zero) extension of the lower half.
    wire [31:0] mul_hi = (u_size == 2'd0) ? {24'd0, prod[15:8]} :
                         (u_size == 2'd1) ? {16'd0, prod[31:16]} : prod[63:32];
    wire        mul_ls = (u_size == 2'd0) ? prod[7] :
                         (u_size == 2'd1) ? prod[15] : prod[31];
    wire        mul_ov = mul_hi != ((u_aop[0] && mul_ls) ? smask : 32'd0);

    wire        sh_rot = (u_aop[2:1] == 2'd0);
    // Kinds 2 and 3 (RCL and RCR are microcode) give the other half
    // of a left or right shift: the bits that left the operand, at the
    // end they would enter a neighbour at. SHLD and SHRD are made of
    // a shift of one operand and this of the other.
    wire        sh_oth = (u_aop[2:1] == 2'd1);
    wire [31:0] sh_raw = sh_rot ? (prod[31:0] | prod[63:32]) :
                         sh_oth ? ((u_size == 2'd1) ? {16'd0, prod[31:16]} :
                                   sh_rt ? prod[31:0] : prod[63:32]) :
                         sh_rt ? prod[63:32] : prod[31:0];
    // A count of zero changes nothing (and nothing leaves).
    wire        sh_nz  = (sh_n != 5'd0);
    wire [31:0] sh_res = sh_nz ? (sh_raw & smask) : sh_oth ? 32'd0 : va;
    wire        sh_msb = (u_size == 2'd0) ? sh_res[7] :
                         (u_size == 2'd1) ? sh_res[15] : sh_res[31];
    wire        sh_nxt = (u_size == 2'd0) ? sh_res[6] :
                         (u_size == 2'd1) ? sh_res[14] : sh_res[30];
    // A byte shifted by 16 or 24 reports the carry of a shift by 8
    // (observed on hardware).
    wire        sh_b8  = (u_size == 2'd0) && (sh_n == 5'd16 || sh_n == 5'd24);
    wire        sh_cf  = sh_rot ? (sh_rt ? sh_msb : sh_res[0]) :
                         sh_rt  ? (sh_b8 && !sh_sx ? va[7] : prod[31]) :
                         sh_b8  ? va[0] :
                         (u_size == 2'd0) ? prod[8] :
                         (u_size == 2'd1) ? prod[16] : prod[32];
    wire        sh_of  = sh_rot ? (sh_rt ? sh_msb ^ sh_nxt : sh_msb ^ sh_cf) :
                         sh_sx  ? 1'b0 :
                         sh_rt  ? sh_nxt : sh_msb ^ sh_cf;
    wire        sh_pf  = ~^sh_res[7:0];

    // ---- special operations -------------------------------------------------------

    localparam SP_NOP = 4'd0, SP_SETSEG = 4'd1, SP_READ = 4'd2, SP_WRFL = 4'd3,
               SP_FLBIT = 4'd4, SP_RAISE = 4'd5, SP_CHKCS = 4'd6, SP_LEA = 4'd7,
               SP_SETCC = 4'd8, SP_MULHI = 4'd9, SP_STEP = 4'd10,
               SP_BITS = 4'd11, SP_SZP = 4'd12, SP_DIVGO = 4'd13,
               SP_DIVQ = 4'd14, SP_DIVR = 4'd15;

    // ---- divider ----
    // DIVGO divides {A, B} by C, unsigned, a bit a cycle: as many
    // cycles as the size has bits. Microcode has made sure that A is
    // below C, so the quotient fits. DIVQ and DIVR read the quotient
    // and the remainder afterwards.
    reg  [31:0] dv_r, dv_q, dv_d, dv_mask;
    reg  [5:0]  dv_n;
    reg         dv_run;
    wire        is_div  = (u_unit == U_SPEC) && (u_aop == SP_DIVGO);
    wire        dv_last = dv_run && (dv_n == 6'd1);
    wire        dv_msb  = (dv_mask[31]) ? dv_q[31] : (dv_mask[15]) ? dv_q[15] : dv_q[7];
    wire [32:0] dv_sh   = {dv_r, dv_msb};
    wire [32:0] dv_df   = dv_sh - {1'b0, dv_d};
    always @(posedge clk) begin
        if (rst || !valid || !is_div)
            dv_run <= 1'b0;
        else if (!dv_run) begin
            dv_run  <= 1'b1;
            dv_r    <= va;
            dv_q    <= vb;
            dv_d    <= vc;
            dv_mask <= smask;
            dv_n    <= {bytes, 3'd0};
        end else begin
            dv_r <= dv_df[32] ? dv_sh[31:0] : dv_df[31:0];
            dv_q <= {dv_q[30:0], !dv_df[32]};
            dv_n <= dv_n - 6'd1;
            if (dv_last)
                dv_run <= 1'b0;
        end
    end
    // (One read of the selectors for both users: a store names the
    // segment in its C field.)
    wire [2:0]  ss_ra = (u_unit == U_STORE) ? u_c[2:0] : u_seg;
    wire [15:0] ss_q  = (ss_ra == 3'd6) ? ldt_sel : (ss_ra == 3'd7) ? tr_sel :
                        seg_sel[ss_ra];
    // sp_e: all of them but LEA's sum, which arrives late and is put
    // in after (sp_val).
    reg [31:0] sp_e;
    always @* begin
        case (u_b)
            4'd0: sp_e = i_eip;
            4'd1: sp_e = {13'd0, fl};
            4'd2: sp_e = {16'd0, ss_q};
            4'd3: sp_e = cur_eip + {28'd0, len};
            4'd4: sp_e = imm;
            4'd5: sp_e = disp;
            4'd6: sp_e = {24'd0, flt_vec};
            4'd7: sp_e = esp0;
            // Where the descriptor of the selector being loaded is.
            // Where the descriptor of the selector last looked up is
            // (nowhere, zero, if it names none). Or, by cc, something
            // of a descriptor whose second half is in A: 2 what LAR
            // gives, 3 what LSL gives (the first half in C), 1 whether
            // VERR (segment field even) or VERW (odd) accepts it.
            4'd8: sp_e = (u_cc == 4'd2) ? (ra & 32'h00F0FF00) :
                         (u_cc == 4'd3) ? (ra[23] ? {ra[19:16], rc[15:0], 12'hFFF}
                                                  : {12'd0, ra[19:16], rc[15:0]}) :
                         (u_cc == 4'd1) ? {31'd0, ra[12] && (u_seg[0] ? (!ra[11] && ra[9])
                                                                      : (!ra[11] || ra[9]))} :
                         sel_ok ? pm_desc : 32'd0;
            4'd9: sp_e = cr0;
            4'd10: sp_e = {16'd0, gdt_lim};
            4'd11: sp_e = gdt_base;
            4'd12: sp_e = {16'd0, idt_lim};
            4'd13: sp_e = idt_base;
            4'd14: sp_e = cr2;
            default: sp_e = cr3;
        endcase
        if (u_aop == SP_LEA)
            sp_e = 32'd0;
        if (u_aop == SP_STEP)       // a string instruction's step
            sp_e = fl[10] ? -{29'd0, bytes} : {29'd0, bytes};
        if (u_aop == SP_BITS)       // the operand size in bits
            sp_e = {26'd0, bytes, 3'd0};
        if (u_aop == SP_MULHI)
            sp_e = mul_hi;
        if (u_aop == SP_SETCC)
            sp_e = {31'd0, cond(u_cc, fl)};
        if (u_aop == SP_DIVQ)
            sp_e = dv_q & dv_mask;
        if (u_aop == SP_DIVR)
            sp_e = dv_r;
    end
    wire        is_lea = (u_unit == U_SPEC) && (u_aop == SP_LEA);
    wire [31:0] sp_val = is_lea ? off : sp_e;

    // What a STORE stores. (Of what READ reads, only the first eight:
    // the system registers go through a temporary, to keep them off
    // this path.)
    reg [31:0] sp_st;
    always @* begin
        case (u_b[2:0])
            3'd0: sp_st = i_eip;
            3'd1: sp_st = {13'd0, fl};
            3'd2: sp_st = {16'd0, ss_q};
            3'd3: sp_st = cur_eip + {28'd0, len};
            3'd4: sp_st = imm;
            3'd5: sp_st = disp;
            3'd6: sp_st = {24'd0, flt_vec};
            default: sp_st = esp0;
        endcase
    end
    wire [31:0] st_data = (u_aop[1:0] == 2'd1) ? (imm & smask) :
                          (u_aop[1:0] == 2'd2) ? (sp_st & smask) : vc;

    // ---- result ------------------------------------------------------------------------

    wire slow_unit = (u_unit == U_SHIFT || u_unit == U_MUL);
    wire two_cycle = (u_unit == U_LOAD || u_unit == U_LOADOP || slow_unit);
    wire first     = two_cycle && !(slow_unit ? cyc3 : cyc2);
    wire stall     = cyc2 && is_mem && !d_ack;
    // (A divide is busy from its first cycle to the one before its last.)
    wire busy      = (valid && (first || stall || (is_div && !dv_last))) || st_block;

    reg [31:0] result;
    always @* begin
        case (u_unit)
            U_LOAD:   result = vm;
            U_SHIFT:  result = sh_res;
            U_MUL:    result = prod[31:0];
            U_SPEC:   result = sp_val;
            default:  result = alu_res;
        endcase
    end

    function cond(input [3:0] cc, input [18:0] fl);
        reg r;
        begin
            case (cc[3:1])
                3'd0: r = fl[11];
                3'd1: r = fl[0];
                3'd2: r = fl[6];
                3'd3: r = fl[0] | fl[6];
                3'd4: r = fl[7];
                3'd5: r = fl[2];
                3'd6: r = fl[7] ^ fl[11];
                default: r = fl[6] | (fl[7] ^ fl[11]);
            endcase
            cond = r ^ cc[0];
        end
    endfunction

    // ---- where the next instruction is ------------------------------------------------

    // Register A is one, or zero, at 16 or 32 bits: straight from the
    // register, since this decides where the next instruction is.
    wire        a_hi0    = (u_size != 2'd2) || (ra[31:16] == 16'd0);
    wire        a_is1    = a_hi0 && (ra[15:0] == 16'd1);
    wire        a_is0    = a_hi0 && (ra[15:0] == 16'd0);
    wire        br7      = (u_br == 3'd7);
    wire        j_reg    = br7 && (u_cc[1:0] == 2'd0);      // to register C
    wire        taken    = (u_br == 3'd2) || (u_br == 3'd1 && cond(u_cc, fl)) ||
                           (u_br == 3'd5 && !uz) || (u_br == 3'd6 && uz) ||
                           (br7 && u_cc[0] && !a_is1) ||
                           (br7 && u_cc[1] && a_is0);
    wire [31:0] eip_seq  = cur_eip + {28'd0, len};
    wire [31:0] eip_tgt  = taken ? (eip_seq + imm) : eip_seq;
    wire [31:0] eip_reg  = (u_size == 2'd1) ? {16'd0, rc[15:0]} : rc;
    // A relative jump wraps at 16 bits with a 16-bit operand: a16 says
    // so, but a STORE's a16 is its address's, and its size says it.
    wire        j_16     = (u_unit == U_STORE) ? (u_size == 2'd1) : u_a16;
    wire [31:0] eip_next = jt_pend ? jt_eip : j_reg ? eip_reg :
                           (j_16 && taken) ? {16'd0, eip_tgt[15:0]} : eip_tgt;
    wire [31:0] lin_next = cs_base + eip_next;

    // The cache is read at the low bits of lin_next, and that is the
    // longest way through the core when the jump depends on a register
    // (LOOP, a jump to a register). So those bits are worked out for
    // each case side by side, and the case chosen last.
    wire [DC_AW-1:0] cur_lin_lo = (hot && !cyc2 && !cyc3) ? lk_lin[DC_AW-1:0]
                                                          : i_lin[DC_AW-1:0];
    wire [DC_AW-1:0] ra_seq = cur_lin_lo + {{(DC_AW-4){1'b0}}, len};
    wire [DC_AW-1:0] ra_tk  = ra_seq + imm[DC_AW-1:0];
    wire [DC_AW-1:0] ra_reg = cs_base[DC_AW-1:0] + rc[DC_AW-1:0];
    wire [DC_AW-1:0] ra_jt  = cs_base[DC_AW-1:0] + jt_eip[DC_AW-1:0];
    wire [DC_AW-1:0] ra_next = jt_pend ? ra_jt : j_reg ? ra_reg :
                               taken ? ra_tk : ra_seq;

    wire fin  = valid && !busy && last;
    wire done = (fin && u_br != 3'd3) || jt_pend;
    wire hot_fin = hot && valid && !busy && !last;
    wire ujump = valid && !busy && !hot && r_ujmp &&
                 (!r_ucond || (r_ucpe ? (cr0[0] ^ r_ucc[0]) :
                               r_ucflt ? (in_flt ^ r_ucc[0]) :
                               r_uca ? !a_is1 :
                               r_ucx ? ((r_ucc[1] ? c_rep[1] : c_rep[0]) ^ r_ucc[0]) :
                               r_ucz ? (uz ^ r_ucc[0]) : cond(r_ucc, fl)));

    // ---- decoder: reads the bytes of an instruction not in the cache -------------------

    localparam [3:0] DS_IDLE = 4'd0, DS_PFX = 4'd1, DS_ATTR = 4'd2, DS_OPC = 4'd3,
                     DS_MODRM = 4'd4, DS_SIB = 4'd5, DS_DISP = 4'd6, DS_ATTR2 = 4'd7,
                     DS_IMMGO = 4'd8, DS_IMM = 4'd9, DS_IMM2 = 4'd10, DS_GO = 4'd11,
                     DS_WAIT = 4'd12;
    reg [3:0]  ds /* verilator public_flat */;
    reg [3:0]  ds_next;
    reg [31:0] d_ip;
    reg [3:0]  d_len;
    reg        d_map;
    reg [7:0]  d_op, d_modrm, d_sib;
    reg        d_os32, d_as32, d_ovr_v, d_lock;
    reg [1:0]  d_rep;
    // LOCK is valid only on some memory forms. Opcode groups decide by
    // the ModRM reg field.
    reg        grp_lock;
    always @* begin
        case (d_op)
            8'h80, 8'h81, 8'h82, 8'h83: grp_lock = (d_modrm[5:3] != 3'd7);
            8'hF6, 8'hF7: grp_lock = (d_modrm[5:3] == 3'd2 || d_modrm[5:3] == 3'd3);
            8'hFE, 8'hFF: grp_lock = (d_modrm[5:3] < 3'd2);
            8'hBA: grp_lock = !d_map || (d_modrm[5:3] >= 3'd5);
            default: grp_lock = 1'b1;
        endcase
    end
    // Opcode groups of which only some members exist, and which have
    // no microcode words for the others.
    wire       grp_ud = (!d_map &&
                         (((d_op == 8'hC6 || d_op == 8'hC7 || d_op == 8'h8F) &&
                           d_modrm[5:3] != 3'd0) ||
                          (d_op == 8'hFE && d_modrm[5:3] > 3'd1))) ||
                        // (0F 00, SLDT and its kin, LAR and LSL: protected mode only.)
                        (d_map && (d_op == 8'h00 || d_op == 8'h02 || d_op == 8'h03) && !cr0[0]);
    reg [2:0]  d_ovr;
    reg [31:0] d_disp, d_imm;
    reg        dreq_r, dwr_r;
    wire       d_ismem = (d_modrm[7:6] != 2'd3);
    wire [1:0] d_osz = d_os32 ? 2'd2 : 2'd1;

    assign d_req = dreq_r && !lim_now && !fetch_bad;
    assign d_wr  = dwr_r && !lim_now;

    // ---- combinational control ------------------------------------------------------------

    wire [3:0] lane_d = (u_size == 2'd0) ? (u_hi[2] ? 4'b0010 : 4'b0001) :
                        (u_size == 2'd1) ? 4'b0011 : 4'b1111;
    wire      go = (ds == DS_GO);
    // The string instructions: 6C-6F, A4-A7, AA-AF.
    wire       d_str = !d_map && (d_op[7:2] == 6'b011011 || d_op[7:2] == 6'b101001 ||
                                  d_op[7:1] == 7'b1010101 || d_op[7:2] == 6'b101011);

    // What is written to a register, apart from the adder's sum.
    wire        wr_aupd = is_mem && u_aupd && !cyc2;        // a pointer moves
    wire        wr_undo = (lim_now && un0_v) || un_second;
    wire        wr_ah   = (u_size == 2'd0) && u_hi[2] && !wr_aupd;
    wire        wr_alu  = (u_unit == U_ALU || u_unit == U_ALUI || u_unit == U_LOADOP ||
                           u_unit == U_STORE);
    wire        wr_sum  = !wr_undo && !wr_aupd && wr_alu && alu_arith;
    reg  [31:0] res_e;
    always @* begin
        case (u_unit)
            U_LOAD:   res_e = vm;
            U_SHIFT:  res_e = sh_res;
            U_MUL:    res_e = prod[31:0];
            U_SPEC:   res_e = sp_e;
            default:  res_e = alu_other;
        endcase
    end
    wire [31:0] wr_early = (lim_now && un0_v) ? un0_d : un_second ? un1_d :
                           wr_aupd ? ptr_sum : is_lea ? off :
                           wr_ah ? {16'd0, res_e[7:0], 8'd0} : res_e;

    always @* begin
        rf_we   = 1'b0;
        rf_wa   = u_d;
        rf_lane = (u_unit == U_SPEC && (u_aop == SP_STEP || u_aop == SP_BITS))
                  ? 4'b1111 : lane_d;
        if (valid && !stall) begin
            if (wr_aupd) begin
                rf_we   = 1'b1;
                rf_wa   = u_a;
                rf_lane = u_a16 ? 4'b0011 : 4'b1111;
            end else if (u_dwe && !first && u_unit != U_STORE)
                rf_we = 1'b1;
        end
        if (rf_wa == ZERO)
            rf_we = 1'b0;
        // Putting string pointers back after a fault (nothing else
        // writes in these two cycles).
        if (lim_now && un0_v) begin
            rf_we = 1'b1; rf_wa = un0_r; rf_lane = 4'b1111;
        end else if (un_second) begin
            rf_we = 1'b1; rf_wa = un1_r; rf_lane = 4'b1111;
        end
        // The data: the adder's sum is the last thing to arrive, so it
        // is chosen last, against everything else chosen before. Bytes
        // outside the lanes written do not matter and are not cleared.
        rf_wd = wr_sum ? {alu_sum[31:16], wr_ah ? alu_sum[7:0] : alu_sum[15:8], alu_sum[7:0]}
                       : wr_early;

        sg_we  = valid && is_setseg && !pm_div;
        sg_wa  = pm_fin ? pm_seg : u_seg;
        sg_sel = pm_fin ? pm_sel : va[15:0];
        sg_pm  = pm_fin;
        // The descriptor: A has its second half, pm_lo its first.
        sg_base = pm_fin ? {va[31:24], va[7:0], pm_lo[31:16]} : {12'd0, va[15:0], 4'd0};
        sg_lim  = va[23] ? {va[19:16], pm_lo[15:0], 12'hFFF}
                         : {12'd0, va[19:16], pm_lo[15:0]};

        // The first uop of a newly decoded instruction goes to the cache
        // as it moves from the ROM to execution.
        dc_fill = i_first && s1_v && !busy && !flt_now && !flushing && mode_ok;
        dc_we = dc_fill || flushing || p_kill;
        dc_wa = flushing ? fl_idx : p_kill ? p_evaddr[DC_AW-1:0] : i_lin[DC_AW-1:0];
        dc_wd = {1'b1, gen, i_lin[31:DC_AW], i_len,
                 // Where the instruction continues. A first word's jump is
                 // settled here if it is unconditional or depends only on
                 // the REP prefix; it may not depend on anything else
                 // (the microassembler checks).
                 w[64] ? {UC_AW{1'b0}} :
                 (w[58] && (!w[59] || (w[83] && ((w[61] ? c_rep[1] : c_rep[0]) ^ w[60]))))
                     ? w[57:48] : upc1 + 1'b1,
                 w_pre, w_res, i_ctx,
                 // A constant from the ROM word takes the place of the
                 // immediate and displacement, as it does when the word
                 // runs from the ROM. Only single-uop instructions use
                 // this (the microassembler checks).
                 w[65] ? {{(32-UC_AW){w[57]}}, w[57:48]} : i_imm,
                 w[65] ? {{(32-UC_AW){w[57]}}, w[57:48]} : i_disp};
        if (flushing || p_kill)
            dc_wd = {DCW{1'b0}};

        // The read port: the next instruction's entry; during a probe,
        // the entries being checked, and then the next instruction's again.
        dc_re = done || rst || phold;
        dc_ra = rst ? {DC_AW{1'b0}} :
                probe_take ? pr_addr[DC_AW-1:0] - 4'd14 :
                probing ? (p_restore ? lk_lin[DC_AW-1:0] : p_cand[DC_AW-1:0]) :
                sl_hold ? lk_lin[DC_AW-1:0] :     // waiting: the next instruction's again
                ra_next;

        // Where the microcode goes on, if nothing sends it elsewhere.
        if (go)
            ur_n = attr_q[9:0] + (attr_q[16] ? {7'd0, d_modrm[5:3]} : 10'd0)
                               + {9'd0, d_rep[0] && d_str};
        else if (hot && hit && !cyc2 && !cyc3)
            ur_n = q_cont;
        else if (ujump)
            ur_n = r_k;
        else if (busy || !s1_v)
            ur_n = upc1;
        else
            ur_n = upc1 + 1'b1;
        // Microcode address.
        if (rst)
            ur_a = {UC_AW{1'b0}};
        else if (flt_now)
            ur_a = UC_FAULT;
        else if (irq_take)
            ur_a = UC_IRQ;
        else if (pm_div)
            ur_a = UC_PMSEG;
        else if (pm_fin && !pm_last)
            ur_a = pm_ret;
        else
            ur_a = ur_n;
    end

    // ---- sequential ---------------------------------------------------------------------------

    // Ask for instruction bytes. The request is made at once; whether
    // it may be made is checked in the next cycle, from registers, by
    // one comparator for all the places that fetch (fetch_bad).
    task dfetch(input [1:0] size, input [3:0] next);
        begin
            dreq_r  <= 1'b1;
            dwr_r   <= 1'b0;
            d_io    <= 1'b0;
            d_addr  <= cs_base + d_ip;
            d_size  <= size;
            ds      <= DS_WAIT;
            ds_next <= next;
        end
    endtask

    wire [2:0] f_bytes = (d_size == 2'd0) ? 3'd1 : (d_size == 2'd1) ? 3'd2 : 3'd4;
    wire [31:0] f_data = (d_size == 2'd0) ? {24'd0, d_rdata[7:0]} :
                         (d_size == 2'd1) ? {16'd0, d_rdata[15:0]} : d_rdata;
    // Group F6/F7 has an immediate only for TEST (ModRM reg 0 and 1).
    wire [2:0] a_immk = (!d_map && d_op[7:1] == 7'b1111011 && d_modrm[5:3] > 3'd1)
                        ? 3'd0 : attr_q[13:11];

    // An instruction longer than 15 bytes, or one that runs past the
    // end of the code segment, is a general protection fault.
    wire [4:0]  f_len = {1'b0, d_len} + {2'd0, f_bytes};
    // (As for data: the highest address a fetch of each size may
    // start at is kept ready, a cycle behind the limit, which changes
    // only with a jump.)
    reg  [32:0] cs_lim1, cs_lim3;
    always @(posedge clk) begin
        cs_lim1 <= {1'b0, cs_lim} - 33'd1;
        cs_lim3 <= {1'b0, cs_lim} - 33'd3;
    end
    wire [32:0] f_lim = (d_size == 2'd0) ? {1'b0, cs_lim} :
                        (d_size == 2'd1) ? cs_lim1 : cs_lim3;
    wire        fetch_bad = (ds == DS_WAIT) && dreq_r && !dwr_r &&
                            (f_len > 5'd15 || f_lim[32] || d_ip > f_lim[31:0]);

    // A load of SS, or STI when interrupts were off.
    wire set_inh = valid && !stall && u_unit == U_SPEC &&
                   ((sg_we && sg_wa == 3'd2) ||
                    (u_aop == SP_FLBIT && u_cc == 4'd3 && !fl[9]));

    always @(posedge clk) begin
        upc1   <= ur_a;
        inta   <= 1'b0;
        step_done <= 1'b0;
        if (inta) flt_vec <= irq_vec;
        if (set_inh) inh_next <= 1'b1;
        st_chk <= d_req && d_wr && !d_io;
        if (rf_we && rf_wa == 4'd4) begin
            if (rf_lane[0]) esp_now[7:0]   <= rf_wd[7:0];
            if (rf_lane[1]) esp_now[15:8]  <= rf_wd[15:8];
            if (rf_lane[2]) esp_now[23:16] <= rf_wd[23:16];
            if (rf_lane[3]) esp_now[31:24] <= rf_wd[31:24];
        end
        ud_now <= 1'b0;
        ud_vec <= 8'd6;

        if (rst) begin
            // Reset continues in microcode, from word 0, which sets the
            // registers and jumps to F000:FFF0.
            halted <= 1'b0; in_rom <= 1'b1; lk_pend <= 1'b0; rst_seq <= 1'b1;
            s1_v <= 1'b1; s2_v <= 1'b0; cyc2 <= 1'b0; cyc3 <= 1'b0;
            jt_pend <= 1'b0; chk_v <= 1'b0; flt_v <= 1'b0;
            lk_eip <= 32'h0000FFF0; lk_lin <= 32'h000FFFF0; cs_base <= 32'h000F0000;
            fl <= 19'h2; gen <= {GW{1'b0}} + 1'b1; jchk_v <= 1'b0;
            cs_lim <= 32'h0000FFFF; sl_cnt <= 8'd0; sl_hold <= 1'b0;
            cr0 <= 32'd0; cr2 <= 32'd0; cr3 <= 32'd0; in_pm <= 1'b0;
            cs_d <= 1'b0; ss_b <= 1'b0; ldt_sel <= 16'd0; tr_sel <= 16'd0;
            ldt_base <= 32'd0; in_flt <= 1'b0; ldt_lim <= 16'd0; sel_ok <= 1'b1;
            gdt_base <= 32'd0; gdt_lim <= 16'hFFFF; idt_base <= 32'd0; idt_lim <= 16'hFFFF;
            dreq_r <= 1'b0; dwr_r <= 1'b0; ds <= DS_IDLE; i_first <= 1'b0;
            inh <= 1'b0; inh_next <= 1'b0; d_io <= 1'b0; inta <= 1'b0;
            flushing <= 1'b0;
            pr_v <= 1'b0; pq_v <= 1'b0; probing <= 1'b0; p_ev <= 1'b0; p_restore <= 1'b0;
            un0_v <= 1'b0; un1_v <= 1'b0; un_second <= 1'b0;
            p_scan <= 1'b0; p_found <= 1'b0; p_dirty <= 1'b0; p_dblk_v <= 1'b0;
            cm_clr <= 1'b0;
            dbg_insns <= 32'd0; last_exc <= 8'hFF; esp_now <= 32'd0;
            attr_byte_r <= 1'b0;
        end else begin
            // A store into a block that holds cached instructions empties
            // the cache by starting a new generation.
            if (d_req && d_wr && !d_io) begin
                st_addr <= d_addr;
                st_n    <= 3'd1 << d_size;
            end
            // (Which map: the fine one below two megabytes, the coarse above.)
            if (st_chk && ((st_addr[31:21] != 11'd0) ? cmaph_q : cmap_q) == gen) begin
                if (!pr_v) begin
                    pr_v <= 1'b1; pr_addr <= st_addr; pr_n <= st_n;
                end else if (!pq_v) begin
                    pq_v <= 1'b1; pq_addr <= st_addr; pq_n <= st_n;
                end else begin
                    // Too many at once: empty the cache by starting a
                    // new generation.
                    pq_v <= 1'b0;
                    if (gen == {GW{1'b1}}) begin
                        gen <= {GW{1'b0}} + 1'b1;
                        flushing <= 1'b1;
                        fl_idx <= {DC_AW{1'b0}};
                    end else
                        gen <= gen + 1'b1;
                end
            end

            // String pointers to put back.
            un_second <= lim_now && un1_v;
            if (lim_now || un_second) begin
                un0_v <= 1'b0;
                if (un_second || !un1_v) un1_v <= 1'b0;
            end else if (valid && !stall && !cyc2 && !cyc3) begin
                if (strstep) begin
                    un0_v <= 1'b1; un0_r <= u_a; un0_d <= ra;
                    un1_v <= un0_v && !hot;
                    un1_r <= un0_r; un1_d <= un0_d;
                end else begin
                    un0_v <= 1'b0; un1_v <= 1'b0;
                end
            end

            // The probe.
            p_ev <= 1'b0;
            cm_clr <= 1'b0;
            if (probe_take) begin
                probing   <= 1'b1;
                p_restore <= 1'b0;
                p_cand    <= pr_addr - 32'd13;      // the entry to read next
                p_left    <= 7'd13 + {4'd0, pr_n};
                p_ev      <= 1'b1;
                p_evaddr  <= pr_addr - 32'd14;
                p_dist    <= 8'sd14;
                p_scan    <= 1'b0;
                p_found   <= 1'b0;
                p_dirty   <= 1'b0;
            end else if (probing && !p_restore) begin
                p_ev     <= 1'b1;
                p_evaddr <= p_cand;
                p_dist   <= p_dist - 8'sd1;
                p_cand   <= p_cand + 32'd1;
                p_left   <= p_left - 7'd1;
                if (p_kill) p_found <= 1'b1;
                if (p_match && p_scan) p_dirty <= 1'b1;
                if (p_left == 7'd0) begin
                    // All read; the last is being checked now.
                    p_ev <= 1'b0;
                    if (!p_scan && !p_found && !p_kill && pr_addr[31:21] == 11'd0 &&
                        !(p_dblk_v && p_dblk == pr_addr[20:6])) begin
                        // Nothing near the store: look through its block,
                        // from 14 bytes before it to its end.
                        p_scan  <= 1'b1;
                        p_cand  <= {pr_addr[31:6], 6'd0} - 32'd14;
                        p_left  <= 7'd78;
                        p_dist  <= 8'sd15;
                    end else begin
                        // Then the next instruction's entry is read again.
                        p_restore <= 1'b1;
                        if (p_scan) begin
                            if (p_dirty || p_match) begin
                                p_dblk <= pr_addr[20:6]; p_dblk_v <= 1'b1;
                            end else begin
                                cm_clr <= 1'b1; cm_clr_blk <= pr_addr[20:6];
                            end
                        end
                    end
                end
            end else if (probing) begin
                probing <= 1'b0;
                pr_v <= pq_v; pr_addr <= pq_addr; pr_n <= pq_n;
                pq_v <= 1'b0;
            end
            if (flushing) begin
                fl_idx <= fl_idx + 1'b1;
                if (&fl_idx) flushing <= 1'b0;
            end

            dreq_r <= stall && !flt_now;
            dwr_r  <= 1'b0;
            chk_v  <= 1'b0;
            jchk_v <= 1'b0;
            jt_pend <= 1'b0;

            // The speed control's wait, started as an instruction ends.
            if (done && slow != 8'd0) begin
                sl_cnt  <= slow;
                sl_hold <= 1'b1;
            end else if (sl_hold) begin
                sl_cnt  <= sl_cnt - 8'd1;
                sl_hold <= (sl_cnt != 8'd1);
            end

            // ROM pipeline: the fetched word becomes the uop to execute.
            if (!busy) begin
                r_uop <= w_res;  r_pre <= w_pre;  r_k <= w[57:48];  r_ujmp <= w[58];
                r_ucond <= w[59]; r_ucc <= w[63:60]; r_end <= w[64];
                r_ucz <= w[81];  r_ucx <= w[83];  r_uca <= w[84];
                r_ucpe <= w[88]; r_ucflt <= w[89];
                r_usek <= w[65];
                s2_v <= s1_v && (in_rom || hot_fin) && !ujump && !pm_jump;
                // (hot_fin: a cached first uop that took two cycles has
                // just finished, and the word after its continuation
                // is being read.)
                s1_v <= (in_rom && ds == DS_IDLE) || go || hot_fin;
                if (s1_v && in_rom && !ujump)
                    i_first <= 1'b0;
            end
            if (ujump || pm_jump) begin
                s1_v <= 1'b1;
                s2_v <= 1'b0;
            end

            if (fin) in_flt <= 1'b0;
            if (flt_now) begin
                // Deliver a fault: microcode takes over.
                in_flt <= 1'b1;
                flt_vec  <= ud_now ? ud_vec : (lim_now && chk_ss) ? 8'd12 : 8'd13;
                last_exc <= ud_now ? ud_vec : (lim_now && chk_ss) ? 8'd12 : 8'd13;
                in_rom <= 1'b1; lk_pend <= 1'b0; s1_v <= 1'b1; s2_v <= 1'b0;
                cyc2 <= 1'b0; cyc3 <= 1'b0; ds <= DS_IDLE; i_first <= 1'b0;
                dreq_r <= 1'b0;
            end else if (irq_take) begin
                // Deliver an interrupt: microcode, returning to the
                // instruction that was about to run.
                in_rom <= 1'b1; lk_pend <= 1'b0; s1_v <= 1'b1; s2_v <= 1'b0;
                i_eip <= lk_eip; i_lin <= lk_lin; i_first <= 1'b0;
                esp0 <= esp_now;
                inta <= 1'b1;
                halted <= 1'b0;
            end else if (jt_pend) begin
                // (The end of the reset sequence is not a step.)
                rst_seq <= 1'b0;
                step_done <= !rst_seq;
                inh <= inh_next; inh_next <= 1'b0;
                if (!rst_seq) dbg_insns <= dbg_insns + 32'd1;
                lk_eip <= eip_next; lk_lin <= lin_next; lk_pend <= 1'b1;
                in_rom <= 1'b0; s1_v <= 1'b0; s2_v <= 1'b0;
                jchk_v <= 1'b1;
            end else if (miss) begin
                // Not in the cache: decode it.
                in_rom <= 1'b1; lk_pend <= 1'b0; s1_v <= 1'b0; s2_v <= 1'b0;
                cyc2 <= 1'b0; cyc3 <= 1'b0;
                i_eip <= lk_eip; i_lin <= lk_lin;
                d_ip <= lk_eip; d_len <= 4'd0; d_map <= 1'b0;
                esp0 <= esp_now;
                d_os32 <= cs_d; d_as32 <= cs_d; d_ovr_v <= 1'b0; d_lock <= 1'b0;
                d_rep <= 2'd0;
                d_modrm <= 8'hC0; d_sib <= 8'd0; d_disp <= 32'd0; d_imm <= 32'd0;
                ds <= DS_PFX;
            end else if (valid && !stall) begin
                if (hot && !cyc2 && !cyc3) begin
                    i_eip <= lk_eip; i_lin <= lk_lin;
                    i_imm <= q_imm;  i_disp <= q_disp; i_len <= q_len;
                    i_ctx <= q_ctx;  attr_byte_r <= q_ctx[24];
                    esp0  <= esp_now;
                    s1_v <= 1'b1;    // the continuation word is being read
                end
                if (is_mem && !cyc2 && !relatch) begin
                    dreq_r  <= 1'b1;
                    d_io    <= (u_seg == 3'd7);
                    dwr_r   <= (u_unit == U_STORE);
                    d_addr  <= lin;
                    d_size  <= u_cc[2] ? 2'd1 : u_size;
                    d_wdata <= st_data;
                    chk_v     <= 1'b1;
                    chk_off   <= off;
                    chk_lim   <= {1'b0, seg_lim[u_seg]} -
                                 {31'd0, u_cc[2] ? 2'd1 : (bytes[1:0] - 2'd1)};
                    chk_ss    <= (u_seg == 3'd2);
                end
                if (relatch) begin
                    dreq_r  <= 1'b1;
                    dwr_r   <= 1'b1;
                    d_wdata <= st_data;
                end
                cyc2 <= first && !cyc2;
                cyc3 <= first && cyc2;

                if (!first && u_fm != 2'd0) begin
                    if (u_unit == U_MUL) begin
                        fl[0]  <= mul_ov;
                        fl[11] <= mul_ov;
                    end else if (u_unit == U_SHIFT) begin
                        if (sh_nz) begin
                            fl[0]  <= sh_cf;
                            fl[11] <= sh_of;
                            if (!sh_rot) begin
                                fl[6] <= (sh_res == 32'd0);
                                fl[7] <= sh_msb;
                                fl[2] <= sh_pf;
                                fl[4] <= 1'b0;
                            end
                        end
                    end else begin
                        if (u_aop < 4'd13) fl[11] <= alu_of;
                        if (u_fm != 2'd3) begin
                            fl[4] <= alu_af; fl[6] <= alu_zf;
                            fl[7] <= alu_sf; fl[2] <= alu_pf;
                        end
                        if (u_fm != 2'd2) fl[0] <= alu_cf;
                    end
                end
                if (!first && (u_unit == U_ALU || u_unit == U_ALUI))
                    uz <= alu_zf;
                if (u_unit == U_SPEC) case (u_aop)
                    // (Bits 16 and 17 are never written this way; bit
                    // 18 with a 32-bit operand and the whole mask.)
                    SP_WRFL:  fl <= {(u_size == 2'd2 && imm[15]) ? ra[18] : fl[18],
                                     ((({fl[17:0]} & ~{2'd0, imm[15:0]}) |
                                       (va[17:0] & {2'd0, imm[15:0]})) & 18'h37FD5) | 18'h2};
                    SP_SZP: begin               // sign, zero, parity of A
                        fl[6] <= (va == 32'd0);
                        fl[7] <= (u_size == 2'd0) ? va[7] :
                                 (u_size == 2'd1) ? va[15] : va[31];
                        fl[2] <= ~^va[7:0];
                    end
                    // (Real mode only: with PE set the new segment's
                    // limit is what counts, and the fetch finds out.)
                    SP_CHKCS: if (va > cs_lim && !cr0[0]) begin
                        // A far jump's offset is outside the code segment.
                        ud_now <= 1'b1;
                        ud_vec <= 8'd13;
                    end
                    SP_RAISE: begin
                        ud_now <= 1'b1;
                        ud_vec <= imm[7:0];
                    end
                    // A NOP with a condition code is a write to a
                    // system register, from A.
                    SP_NOP: if (u_br == 3'd0) case (u_cc)
                        4'd1: cr0 <= va;
                        4'd2: gdt_lim <= va[15:0];
                        4'd3: gdt_base <= c_os32 ? va : {8'd0, va[23:0]};
                        4'd4: idt_lim <= va[15:0];
                        4'd5: idt_base <= c_os32 ? va : {8'd0, va[23:0]};
                        4'd6: cr2 <= va;
                        4'd7: cr3 <= va;
                        4'd8: cr0[3] <= 1'b0;               // CLTS
                        4'd9: cr0[3:0] <= {va[3:1], va[0] | cr0[0]};    // LMSW: PE stays set
                        // LLDT: the selector, and where its descriptor
                        // is; then the table's base from the descriptor
                        // (A its second half, B its first). LTR.
                        4'd10: begin
                            ldt_sel <= va[15:0];
                            sel_ok  <= 1'b1;
                            pm_desc <= gdt_base + {16'd0, va[15:3], 3'd0};
                        end
                        4'd11: begin
                            ldt_base <= {va[31:24], va[7:0], vb[31:16]};
                            ldt_lim  <= vb[15:0];
                        end
                        // A selector to look up (LAR, LSL, VERR, VERW):
                        // where its descriptor is, and whether there is
                        // one -- not the null selector, and inside its
                        // table.
                        4'd13: begin
                            pm_desc <= (va[2] ? ldt_base : gdt_base) + {16'd0, va[15:3], 3'd0};
                            sel_ok  <= (va[15:2] != 14'd0) &&
                                       ({va[15:3], 3'b111} <= (va[2] ? ldt_lim : gdt_lim));
                        end
                        4'd12: tr_sel <= va[15:0];
                        default: ;
                    endcase
                    SP_FLBIT: case (u_cc[3:1])
                        3'd0: fl[0]  <= u_cc[0];
                        3'd1: fl[9]  <= u_cc[0];
                        3'd2: fl[10] <= u_cc[0];
                        3'd3: fl[0]  <= ~fl[0];
                        3'd4: begin fl[9] <= 1'b0; fl[8] <= 1'b0; end
                        // Overflow: A's sign is not B's.
                        3'd5: fl[11] <= (u_size == 2'd0) ? va[7] ^ vb[7] :
                                        (u_size == 2'd1) ? va[15] ^ vb[15] : va[31] ^ vb[31];
                        3'd6: fl[6]  <= u_cc[0];
                        default: fl[8] <= 1'b0;
                    endcase
                    default: ;
                endcase
                if (sg_we && sg_wa == 3'd1) begin
                    cs_base <= sg_base;
                    if (sg_pm) cs_lim <= sg_lim;
                    if (sg_pm) cs_d <= va[22];
                end
                if (sg_we && sg_wa == 3'd2 && sg_pm) ss_b <= va[22];
                // The descriptor routine: in, and out again.
                if (pm_div) begin
                    in_pm   <= 1'b1;
                    // (The word after this one is already read, and
                    // is dropped: it is where to come back to.)
                    pm_ret  <= hot ? q_cont : ujump ? r_k : upc1;
                    pm_last <= last0;
                    pm_seg  <= u_seg;
                    pm_sel  <= va[15:0];
                    pm_desc <= (va[2] ? ldt_base : gdt_base) + {16'd0, va[15:3], 3'b000};
                    sel_ok  <= 1'b1;
                end
                if (pm_fin)
                    in_pm <= 1'b0;
                if (in_pm && u_unit == U_LOAD && !first && !u_dwe)
                    pm_lo <= result;

                if (fin && u_br == 3'd3) begin
                    jt_pend <= 1'b1;
                    jt_eip  <= u_a16 ? {16'd0, result[15:0]} : result;
                    lk_pend <= 1'b0;
                end else if (done) begin
                    // (A word that raises a fault ends its routine, but
                    // the instruction is not done: the fault's delivery
                    // is the step.)
                    if (!(u_unit == U_SPEC && u_aop == SP_RAISE)) begin
                        step_done <= 1'b1;
                        dbg_insns <= dbg_insns + 32'd1;
                    end
                    inh <= inh_next || set_inh; inh_next <= 1'b0;
                    lk_eip <= eip_next; lk_lin <= lin_next; lk_pend <= 1'b1;
                    in_rom <= 1'b0; s1_v <= 1'b0; s2_v <= 1'b0;
                    jchk_v <= taken || j_reg;
                    if (u_br == 3'd4) halted <= 1'b1;
                end else if (!first && hot) begin
                    in_rom  <= 1'b1;
                    lk_pend <= 1'b0;
                end
            end

            // ---- the decoder ----
            if (!flt_now) case (ds)
                DS_PFX: dfetch(2'd0, DS_OPC);
                DS_WAIT: if (fetch_bad) begin
                    ud_now <= 1'b1;
                    ud_vec <= 8'd13;
                    dreq_r <= 1'b0;
                    ds     <= DS_IDLE;
                end else if (!d_ack)
                    dreq_r <= 1'b1;
                else begin
                    dreq_r <= 1'b0;
                    d_ip   <= d_ip + {29'd0, f_bytes};
                    d_len  <= d_len + {1'b0, f_bytes};
                    ds     <= ds_next;
                    case (ds_next)
                        DS_OPC: begin
                            case (f_data[7:0])
                                8'h26: begin d_ovr_v <= 1; d_ovr <= 3'd0; ds <= DS_PFX; end
                                8'h2E: begin d_ovr_v <= 1; d_ovr <= 3'd1; ds <= DS_PFX; end
                                8'h36: begin d_ovr_v <= 1; d_ovr <= 3'd2; ds <= DS_PFX; end
                                8'h3E: begin d_ovr_v <= 1; d_ovr <= 3'd3; ds <= DS_PFX; end
                                8'h64: begin d_ovr_v <= 1; d_ovr <= 3'd4; ds <= DS_PFX; end
                                8'h65: begin d_ovr_v <= 1; d_ovr <= 3'd5; ds <= DS_PFX; end
                                8'h66: begin d_os32 <= !cs_d; ds <= DS_PFX; end
                                8'h67: begin d_as32 <= !cs_d; ds <= DS_PFX; end
                                8'hF0: begin d_lock <= 1; ds <= DS_PFX; end
                                8'hF2, 8'hF3: begin d_rep <= {!f_data[0], 1'b1}; ds <= DS_PFX; end
                                8'h0F: begin d_map <= 1; ds <= DS_PFX; end
                                default: begin
                                    d_op   <= f_data[7:0];
                                    attr_a <= {1'b0, d_map, f_data[7:0]};
                                    ds     <= DS_ATTR;
                                end
                            endcase
                        end
                        DS_MODRM: begin
                            d_modrm <= f_data[7:0];
                            attr_a  <= {f_data[7:6] != 2'd3, d_map, d_op};
                        end
                        DS_SIB:  d_sib  <= f_data[7:0];
                        DS_DISP: begin
                            d_disp <= (d_modrm[7:6] == 2'd1) ? {{24{f_data[7]}}, f_data[7:0]}
                                                            : f_data;
                            ds <= DS_ATTR2;
                        end
                        DS_IMM: begin
                            if (a_immk == 3'd6) begin
                                // A bare offset: make it a ModRM
                                // operand with only a displacement.
                                d_disp  <= f_data;
                                d_modrm <= d_as32 ? 8'h05 : 8'h06;
                            end
                            d_imm <= (a_immk == 3'd4) ? {{24{f_data[7]}}, f_data[7:0]} :
                                     (a_immk == 3'd2 && !d_os32 && attr_q[17])
                                         ? {{16{f_data[15]}}, f_data[15:0]} : f_data;
                            // A far pointer's selector follows its offset.
                            ds <= (a_immk == 3'd5 || a_immk == 3'd7) ? DS_IMM2 : DS_GO;
                        end
                        DS_GO: d_disp <= f_data;
                        default: ;
                    endcase
                end
                DS_ATTR: ds <= DS_OPC;          // the attribute word arrives
                DS_OPC: begin
                    if (!attr_q[15] || (d_lock && !attr_q[10])) begin
                        ud_now <= 1'b1;
                        ds <= DS_IDLE;
                    end else if (attr_q[10])
                        dfetch(2'd0, DS_MODRM);
                    else
                        ds <= DS_IMMGO;
                end
                DS_MODRM: begin
                    if (!d_ismem)
                        ds <= DS_ATTR2;
                    else if (d_as32 && d_modrm[2:0] == 3'd4)
                        dfetch(2'd0, DS_SIB);
                    else if (!d_as32 && ((d_modrm[7:6] == 2'd0 && d_modrm[2:0] == 3'd6) ||
                                         d_modrm[7:6] == 2'd2))
                        dfetch(2'd1, DS_DISP);
                    else if (d_as32 && ((d_modrm[7:6] == 2'd0 && d_modrm[2:0] == 3'd5) ||
                                        d_modrm[7:6] == 2'd2))
                        dfetch(2'd2, DS_DISP);
                    else if (d_modrm[7:6] == 2'd1)
                        dfetch(2'd0, DS_DISP);
                    else
                        ds <= DS_ATTR2;
                end
                DS_SIB: begin
                    if ((d_modrm[7:6] == 2'd0 && d_sib[2:0] == 3'd5) || d_modrm[7:6] == 2'd2)
                        dfetch(2'd2, DS_DISP);
                    else if (d_modrm[7:6] == 2'd1)
                        dfetch(2'd0, DS_DISP);
                    else
                        ds <= DS_ATTR2;
                end
                // The selector of a far pointer, or ENTER's nesting level.
                DS_IMM2: dfetch((a_immk == 3'd7) ? 2'd0 : 2'd1, DS_GO);
                DS_ATTR2: ds <= DS_IMMGO;       // attributes of the memory or register form
                DS_IMMGO: begin
                    if (!attr_q[15] || grp_ud ||
                        (d_lock && attr_q[10] && !(d_ismem && attr_q[17] && grp_lock))) begin
                        ud_now <= 1'b1;
                        ds <= DS_IDLE;
                    end else case (a_immk)
                        3'd0: ds <= DS_GO;
                        3'd1, 3'd4: dfetch(2'd0, DS_IMM);
                        3'd2, 3'd5: dfetch(d_osz, DS_IMM);
                        3'd3, 3'd7: dfetch(2'd1, DS_IMM);
                        default: dfetch(d_as32 ? 2'd2 : 2'd1, DS_IMM);
                    endcase
                end
                DS_GO: begin
                    // Start the instruction's microcode; its first uop
                    // will be cached on the way.
                    i_imm  <= d_imm;
                    i_disp <= d_disp;
                    i_len  <= d_len;
                    i_ctx  <= {d_rep, d_ovr, d_ovr_v, d_as32, d_os32, attr_q[14],
                               d_op, d_sib, d_modrm};
                    attr_byte_r <= attr_q[14];
                    esp0    <= esp_now;
                    i_first <= 1'b1;
                    ds <= DS_IDLE;
                end
                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire

/*
 * The ALU of this core: m86_alu.v's operations and flags, with one
 * adder, its controls decoded by the caller, and the sum and the rest
 * given separately for a user that picks between them late.
 */
module m86b_alu (
    input  wire [3:0]  op,      // 0-7: ADD OR ADC SBB AND SUB XOR CMP; 8 INC; 9 DEC
    // What of `op` the adder needs, decoded by the caller (who can do
    // it a cycle ahead): subtract; with the carry; the result is the
    // adder's. For INC and DEC the caller makes B one.
    input  wire        sub,
    input  wire        usec,
    input  wire        arith,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        cin,
    input  wire [2:0]  size,
    output reg  [31:0] res,
    // The sum or difference as it leaves the adder, and the result
    // of everything else (zero for a sum): the two halves of `res`
    // for a user that picks between them itself, late.
    output wire [31:0] sum,
    output reg  [31:0] other,
    output reg         cf,
    output reg         of,
    output reg         af,
    output wire        zf,
    output wire        sf,
    output wire        pf
);
    wire        is_add = arith && !sub;
    wire        is_sub = arith && sub;
    wire [31:0] bb     = b;
    wire        c      = usec & cin;

    // One adder: a - b - c is a + ~b + ~c, in 33 bits.
    wire [32:0] w    = {1'b0, a} + ({1'b0, bb} ^ {33{sub}}) + {32'd0, c ^ sub};
    assign      sum   = w[31:0];

    wire [4:0]  bitn = (size == 3'd1) ? {2'd0, bb[2:0]} :
                       (size == 3'd2) ? {1'b0, bb[3:0]} : bb[4:0];
    wire [31:0] bit1 = 32'd1 << bitn;
    reg  [31:0] rl;
    always @* begin
        case (op)
            4'd1:    rl = a | bb;
            4'd4:    rl = a & bb;
            4'd6:    rl = a ^ bb;
            // 10: B's lower half sign-extended to the operand size.
            // 11: every bit a copy of A's sign bit. No flags are defined.
            4'd10:   rl = (size == 3'd2) ? {16'd0, {8{bb[7]}}, bb[7:0]}
                                         : {{16{bb[15]}}, bb[15:0]};
            4'd11:   rl = {32{(size == 3'd2) ? a[15] : a[31]}};
            // 12: A rotated right one place through the carry.
            4'd12:   rl = (size == 3'd1) ? {24'd0, cin, a[7:1]} :
                          (size == 3'd2) ? {16'd0, cin, a[15:1]} : {cin, a[31:1]};
            // 13, 14, 15: bit B of A (B taken modulo the size in
            // bits) set, cleared, turned over. The carry is the bit
            // as it was: BT is one of these with nothing written.
            4'd13:   rl = a | bit1;
            4'd14:   rl = a & ~bit1;
            4'd15:   rl = a ^ bit1;
            default: rl = 32'd0;
        endcase
    end
    wire [31:0] r = arith ? w[31:0] : rl;

    wire [31:0] x_add = (a ^ r) & (bb ^ r);
    wire [31:0] x_sub = (a ^ bb) & (a ^ r);
    wire [31:0] x     = is_add ? x_add : x_sub;

    reg msb;
    always @* begin
        case (size)
            3'd1: begin res = {24'd0, r[7:0]};  other = {24'd0, rl[7:0]}; cf = w[8];  of = x[7];  msb = r[7];  end
            3'd2: begin res = {16'd0, r[15:0]}; other = {16'd0, rl[15:0]}; cf = w[16]; of = x[15]; msb = r[15]; end
            default: begin res = r;             other = rl; cf = w[32]; of = x[31]; msb = r[31]; end
        endcase
        af = a[4] ^ bb[4] ^ r[4];
        if (!is_add && !is_sub) begin
            cf = 1'b0;
            of = 1'b0;
            af = 1'b0;
        end
        if (op >= 4'd13)
            cf = a[bitn];
        if (op == 4'd12) begin
            cf = a[0];
            of = msb ^ ((size == 3'd1) ? r[6] : (size == 3'd2) ? r[14] : r[30]);
        end
    end

    // Zero: of the sum and of the rest separately, by bytes, so that
    // the adder's bits have few steps to go.
    function zero3(input [31:0] v, input [2:0] sz);
        zero3 = (v[7:0] == 8'd0) && (sz == 3'd1 || ((v[15:8] == 8'd0) &&
                (sz == 3'd2 || v[31:16] == 16'd0)));
    endfunction
    assign zf = arith ? zero3(w[31:0], size) : zero3(rl, size);
    assign sf = msb;
    assign pf = ~^r[7:0];
endmodule
