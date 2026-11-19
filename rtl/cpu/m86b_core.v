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
 *   [57:48] k      jump target, or a constant (its eleventh bit is [85])
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
    parameter UC_AW = 11,
    // The decoder's window (see below): 1 with it, 0 without. It makes
    // an instruction's first execution about twice as fast and costs
    // about 600 LUTs, which Lakritz does not have.
    parameter WIN   = 1,
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
    // With paging on, an access that lies across two pages is made a
    // byte at a time by the core itself. What it read that way is
    // here; the core then reads it back as I/O port 1E8h, which the
    // machine must answer with this (and whose writes it must ignore).
    output reg  [31:0] x_rd,
    // A byte of memory for someone else (the Sound Blaster's DMA): while
    // dma_req is up the core reads the byte at dma_addr between two
    // instructions and gives it on dma_q, with dma_ack up for a cycle.
    // dma_req must then fall. (Tie dma_req low if nobody asks.)
    input  wire        dma_req,
    input  wire [23:0] dma_addr,
    output reg         dma_ack,
    output reg  [7:0]  dma_q,

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
    //   0 subtract  1 B is one (INC, DEC)  2 the adder's result (not a
    //   logic operation's)  3 (not of the uop: the code segment's D
    //   bit when the entry was made)  4 load-and-operate  5 ALU with
    //   the immediate
    localparam PW  = 6;
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
    reg        sg_we, sg_drop;
    wire       sg_v86 = vm_ld;
    reg [2:0]  sg_wa;
    reg [15:0] sg_sel;
    reg        sg_pm;                   // from a descriptor: base and limit both
    reg [31:0] sg_base, sg_lim;
    reg        sg_nl;                   // a null selector: base and limit stay
    always @(posedge clk)
        if (sg_we && sg_nl)
            seg_sel[sg_wa]  <= sg_sel;
        else if (sg_we) begin
            // (A virtual 8086 task's segments are 64 KB.)
            if (sg_v86) seg_lim[sg_wa] <= 32'h0000FFFF;
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
    // ---- privilege levels (docs/pmode.md) ----
    // The current level, and the level a transfer in progress is
    // going to (the same, between instructions). A code segment load
    // with PE set makes the second the first.
    reg [1:0]         cpl /* verilator public_flat_rw */;
    reg [1:0]         tpl;
    reg [15:0]        err;              // the error code of the fault being raised
    reg               ud_keep;          // ... which a RAISE says to keep
    reg               in_hw;            // the microcode running is delivering a hardware interrupt
    wire              ext = in_flt || in_hw;
    // Virtual 8086 mode: EFLAGS.VM with PE set. Segment loads are then
    // real mode's and the level is 3. vm_ld: the microcode is loading
    // a virtual 8086 task's registers (IRET from level 0) and wants
    // loads of that kind already. vm_int: it is on the way out of one,
    // into a handler: VM is clear, but the flags it pushes say VM.
    reg               vm_ld, vm_int;
    // What a descriptor said of each segment: loaded with a null
    // selector, not writable, not readable, its level, and whether an
    // outer level loses it (data, or code that is not conforming).
    reg [5:0]         sg_null, sg_nw, sg_nr, sg_prot;
    reg [11:0]        sg_dpl;
    // What the last look at a descriptor found.
    reg               chk_ok, chk_p, chk_a, chk_sys, chk_inner, gate_trap;
    reg [31:0]        new_lim;          // the limit of the code segment looked at
    reg [31:0]        pm_hi;            // the descriptor's second half
    reg               sel_null;         // the selector being loaded is a null selector
    reg [31:0]        tr_base;
    reg               tr_32;            // the task state segment is a 386's
    reg [15:0]        ss_prev;          // the stack segment before the last load of SS
    reg [31:0]        tss_sp;           // where the TSS keeps the stack of the level being gone to
    always @(posedge clk)
        tss_sp <= tr_base + (tr_32 ? {27'd0, tpl, 3'b100} : {28'd0, tpl, 2'b10});
    // Where the top of the stack was, in memory, when the instruction began.
    reg [31:0]        ostk;
    always @(posedge clk)
        ostk <= seg_base[2] + (ss_b ? esp0 : {16'd0, esp0[15:0]});
    reg [31:0] cs_base /* verilator public_flat_rw */;

    // ---- paging (docs/pmode.md) ----
    // With CR0.PG set every memory access of a uop, and every fetch of
    // the decoder, waits for this unit first: it looks the page up in
    // a translation buffer (32 entries, one per value of address bits
    // 16:12), walks the page tables itself when it is not there, sets
    // the accessed and dirty bits, and raises the page fault. The uop
    // or the fetch then goes ahead with the physical address. The
    // cost is two cycles an access, and nothing when paging is off.
    wire       pg = cr0[31] && cr0[0];
    localparam [3:0] X_IDLE = 4'd0, X_LOOK = 4'd1, X_RDY = 4'd2, X_W1 = 4'd3, X_W2 = 4'd4,
                     X_W3 = 4'd5, X_W4 = 4'd6, X_W5 = 4'd7, X_W6 = 4'd8, X_W7 = 4'd9,
                     X_W8 = 4'd10, X_BI = 4'd11, X_BW = 4'd12, X_IOA = 4'd13, X_IOB = 4'd14,
                     X_IOC = 4'd15;
    localparam [4:0] X_D1 = 5'd16, X_D2 = 5'd17;
    reg [4:0]  xs /* verilator public_flat */;
    reg [31:0] x_lin;               // the linear address
    reg [19:0] x_cur;               // the page being looked up (the second, of an access across two)
    reg        x_wr, x_rmw;         // a write; the read of a read-modify-write
    reg        x_user;              // made at level 3 (the core's own are not)
    reg        x_dec;               // for the decoder
    reg        x_cross, x_second;   // across two pages; on the second
    reg        x_wok;               // looked up as a write
    reg        x_st;                // the bytes are to be written
    // The same unit asks the task state segment whether a port may be
    // used (outside the I/O privilege level, and always in virtual
    // 8086 mode): 1 it is reading where the permission map begins,
    // 2 the map's bits for the port; 3 on its way from one to the other.
    reg [1:0]  x_io;
    reg [19:0] tr_lim;
    reg [31:0] tr_io;               // where the TSS says where its map is
    always @(posedge clk)
        tr_io <= tr_base + 32'h66;
    reg [1:0]  x_size;
    reg [19:0] x_ppn, x_ppn2;
    reg [31:0] x_pde, x_pte;
    reg [12:0] x_off;
    reg [2:0]  x_i;
    reg        xf_now;              // a page fault is being raised
    reg        un_new;              // no uop of this instruction has run yet
    reg        x_flush;             // empty the instruction cache: the mapping changed
    reg [31:0] tlb_v;
    (* ram_style = "distributed" *)
    reg [37:0] tlb [0:31];          // dirty, writable, user, page frame, tag
    initial for (k = 0; k < 32; k = k + 1) tlb[k] = 38'd0;
    wire [37:0] tlb_q = tlb[x_cur[4:0]];
    wire        tlb_hit = tlb_v[x_cur[4:0]] && (tlb_q[14:0] == x_cur[19:5]);
    wire [19:0] tlb_ppn = pg ? tlb_q[34:15] : x_cur;
    wire        x_wall = !x_user && !cr0[16];       // level 0 writes anything, without CR0.WP
    // (Without paging the unit only ever looks at the TSS, where it is.)
    wire        tlb_ok = !pg || (tlb_hit && (!x_user || tlb_q[35]) &&
                                 (!x_wr || (tlb_q[37] && (tlb_q[36] || x_wall))));
    wire [2:0]  x_bytes = (x_size == 2'd0) ? 3'd1 : (x_size == 2'd1) ? 3'd2 : 3'd4;
    wire [12:0] x_last = {1'b0, x_lin[11:0]} + {10'd0, x_bytes} - 13'd1;
    wire        x_crosses = x_last[12] && pg;
    wire        x_pu = x_pde[2] && x_pte[2];
    wire        x_pw = x_pde[1] && x_pte[1];
    wire        x_wal = x_pw || x_wall;
    wire [31:0] x_pa = {x_off[12] ? x_ppn2 : x_ppn, x_off[11:0]};
    wire [31:0] x_addr = x_cross ? 32'h000001E8 : {x_ppn, x_lin[11:0]};
    wire [31:0] x_pdea = {cr3[31:12], x_cur[19:10], 2'b00};
    // (The port's number is registered as the question is asked: it
    // comes out of the address adder.)
    reg  [15:0] x_port;
    wire [15:0] io_last = x_port + {14'd0, e_size == 2'd2, e_size == 2'd1} + {15'd0, e_size == 2'd2};
    wire [3:0]  io_mask = (e_size == 2'd0) ? 4'b0001 : (e_size == 2'd1) ? 4'b0011 : 4'b1111;
    wire [31:0] x_ptea = {x_pde[31:12], x_cur[9:0], 2'b00};
    // The frames the instruction being decoded begins and ends in.
    reg [19:0] i_ppn, i_ppn_e;

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
    // (Read in the very cycle the opcode byte is seen: attr_ra.)
    wire [9:0]  attr_ra;
    always @(posedge clk)
        attr_q <= attr[attr_ra];

    // Which 64-byte blocks of memory hold cached instructions, by
    // generation. Generation 0 means none.
    (* no_rw_check *)
    reg  [GW-1:0] cmap [0:32767];
    reg  [GW-1:0] cmap_q /* verilator public_flat */;
    reg  [GW-1:0] gen /* verilator public_flat_rw */;
    reg           st_chk /* verilator public_flat */;
    reg           dc_fill;
    reg           cm2_pend;
    reg           fill_r;
    reg  [31:0]   f_pa, f_pe;
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
        // (The marks are made a cycle after the entry: where the
        // instruction is, in memory, is registered first. The first
        // store that could matter is later than that.)
        fill_r <= dc_fill;
        f_pa   <= i_pa;
        f_pe   <= i_pe;
        if (fill_r) cmap[f_pa[20:6]] <= gen;
        else if (cm2_pend) cmap[cm2_blk] <= gen;
        else if (cm_clr) cmap[cm_clr_blk] <= {GW{1'b0}};
        cm2_pend <= fill_r && (f_pe[20:6] != f_pa[20:6]);
        cm2_blk  <= f_pe[20:6];
    end
    // Above two megabytes the map is coarser: a mark for each 32 KB,
    // of 64 MB (addresses 64 MB apart share one, which costs only
    // time), in LUT RAM: block RAM is what Lakritz has none of. A
    // store to a marked page is followed by the search for the
    // instructions it overlaps, as below two megabytes, but the page
    // is not looked through and its mark never taken off: a page of
    // code and data mixed pays about twenty cycles a store.
    (* ram_style = "distributed" *)
    reg  [GW-1:0] cmaph [0:2047];
    reg  [GW-1:0] cmaph_q;
    reg           cmh_pend;
    reg  [10:0]   cmh_blk;
    initial for (k = 0; k < 2048; k = k + 1) cmaph[k] = {GW{1'b0}};
    wire          f_hi = (f_pa[31:21] != 11'd0);
    always @(posedge clk) begin
        cmaph_q <= cmaph[d_addr[25:15]];
        if (fill_r && f_hi) cmaph[f_pa[25:15]] <= gen;
        else if (cmh_pend) cmaph[cmh_blk] <= gen;
        cmh_pend <= fill_r && f_hi && (f_pe[25:15] != f_pa[25:15]);
        cmh_blk  <= f_pe[25:15];
    end

    // ---- state ----------------------------------------------------------

    reg [31:0] lk_eip /* verilator public_flat_rw */;
    reg [31:0] lk_lin /* verilator public_flat_rw */;
    reg        lk_pend /* verilator public_flat_rw */;
    reg [18:0] fl /* verilator public_flat_rw */;   // EFLAGS bits 18..0 (18: AC, a 486's)
    wire       v86 = cr0[0] && fl[17];
    wire       pmode = cr0[0] && !fl[17] && !vm_ld;     // segment loads go through descriptors
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
    // (Where they are in memory: that is what stores are compared with.)
    wire [31:0] i_pa = pg ? {i_ppn, i_lin[11:0]} : i_lin;
    wire [31:0] i_pe = pg ? {i_ppn_e, i_end[11:0]} : i_end;
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
    wire [UC_AW-1:0] w_k = {w[85], w[57:48]};
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
        w_aop == 4'd3 || w_aop == 4'd5 || w_aop == 4'd7 || w_aop == 4'd9 };

    // The ROM uop ready to execute, with its sequencing.
    reg [UW-1:0]    r_uop;
    reg [PW-1:0]    r_pre;
    reg [UC_AW-1:0] r_k;
    reg             r_ujmp, r_ucond, r_end, r_usek, r_ucz, r_ucx, r_uca, r_ucpe, r_ucflt;
    reg             r_pj;           // a protection condition, already chosen and settled
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
                        q_pre[3] == cs_d && mode_ok));
    // An interrupt request is taken between instructions, and not
    // straight after an instruction that holds interrupts off for one
    // more (a load of SS, or STI).
    reg        inh, inh_next;
    reg        rst_seq /* verilator public_flat_rw */;   // the reset microcode is running
    // Between instructions: nothing has begun.
    wire       between  = !rst && lk_pend && !in_rom && !jt_pend && !flt_now &&
                          !cyc2 && !cyc3 && (xs == X_IDLE);

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
    // A byte wanted from outside is fetched here too, when no store
    // is waiting to be looked into.
    wire       dma_take = between && dma_req && !dma_ack && !pr_v;
    wire       phold = probe_take || probing || sl_hold || dma_take || xs[4];
    wire       p_match = p_ev && dc_q[DCW-1] &&
                         (pg ? (q_tag[0] == p_evaddr[DC_AW]) : (q_tag == p_evaddr[31:DC_AW])) &&
                         (p_dist <= 8'sd0 || $signed({4'b0000, q_len}) > p_dist);
    wire       p_kill /* verilator public_flat */ = p_match && !p_scan;
    reg [31:0] p_evaddr;

    wire       irq_take = between && !phold && irq && fl[9] && !inh;
    wire       miss /* verilator public_flat */ = lk_pend && !hit && !in_rom && !halted && !jt_pend && !irq_take && !phold;
    wire       hot   = !in_rom;
    wire [UW-1:0] uop = hot ? q_uop : r_uop;
    wire [PW-1:0] pre = hot ? q_pre : r_pre;
    wire       p_sub = pre[0], p_one = pre[1], p_arith = pre[2];
    wire       p_usec = (u_aop == 4'd2 || u_aop == 4'd3);   // (the carry in: not a hurry)
    wire       p_loadop = pre[4], p_alui = pre[5];
    wire       valid00 = !rst && !halted && !jt_pend && !flt_now && !irq_take && !phold &&
                        (hot ? hit : s2_v);
    wire       xl_block;            // an access that the paging unit is not ready for
    wire       valid0 = valid00 && !xl_block;
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
    // (A SETSEG with cc 2 empties a segment an outer level may not
    // keep, on the spot.)
    wire        pm_div = valid && is_setseg && pmode && !in_pm && !u_cc[1];
    wire        pm_fin = valid && is_setseg && in_pm;
    wire        last = !is_setseg ? last0 : in_pm ? pm_last : (last0 && (!pmode || u_cc[1]));
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
    // What a memory access is wide: the size; 16 bits with cc bit 2;
    // and a byte for a LOAD with aop bit 0, which then fills the
    // register's whole size with it, zero-extended (MOVZX).
    wire        ld_b   = (u_unit == U_LOAD) && u_aop[0];
    wire [1:0]  m_size = ld_b ? 2'd0 : u_cc[2] ? 2'd1 : u_size;
    wire [31:0] vm = d_rdata & (ld_b ? 32'h000000FF :
                                (u_unit == U_LOAD && u_cc[2]) ? (smask & 32'h0000FFFF) : smask);

    // ---- address generation ----------------------------------------------

    wire        is_mem  = (u_unit == U_LOAD || u_unit == U_LOADOP || u_unit == U_STORE);
    assign      st_block = valid0 && (u_unit == U_STORE) && !d_st_rdy;
    // (A store that follows its load to the same place needs the unit
    // again only if the load was not looked up as a write, or lies
    // across two pages.)
    wire        xl_need = is_mem && !cyc2 &&
                          ((u_seg != 3'd7) ? (pg && (!relatch || x_cross || !x_wok))
                                           : (cr0[0] && (fl[17] || cpl > fl[13:12])));
    assign      xl_block = xl_need && !(xs == X_RDY && !x_dec);
    wire        xl_start = valid00 && xl_need && (xs == X_IDLE);
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
                    (u_seg != 3'd7) && !pg;
    assign e_addr = lin;
    assign e_size = m_size;

    // The limit check is made a cycle later, from registers.
    reg        chk_v;
    // (The limit kept is the highest offset the first byte may have:
    // the segment's limit less the access's other bytes, taken off as
    // it is registered; bit 32 says that no offset will do. So the
    // check is one comparison.)
    reg [31:0] chk_off;
    reg [32:0] chk_lim;
    reg        chk_ss, chk_bad;
    wire       acc_bad = cr0[0] && (u_seg != 3'd7) && (u_seg != 3'd6) &&
                         (sg_null[u_seg] ||
                          ((u_unit == U_STORE) ? sg_nw[u_seg] : sg_nr[u_seg]));
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
    wire       flt_now /* verilator public_flat */ = lim_now || ud_now || jmp_bad;

    // ---- ALU ----------------------------------------------------------------

    wire        op2    = p_loadop && cyc2;
    wire        swap   = u_cc[0];
    // (A LOAD-OP with cc bit 3: memory and the immediate, in that
    // order -- CMP, TEST and the rest with a memory operand.)
    wire        ld_imm = p_loadop && u_cc[3];
    wire [31:0] alu_a  = op2 ? (swap ? vm : vc) : va;
    wire [31:0] alu_b  = p_one ? 32'd1 :
                         (op2 && !ld_imm) ? (swap ? vc : vm) :
                         (p_alui || ld_imm) ? (imm & smask) : vb;
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
    // (The double shifts: see below.)
    wire        sh_dbl  = (u_unit == U_SHIFT) && (u_aop[2:1] == 2'd1);
    wire        sh_d16x = sh_dbl && (u_size == 2'd1) && sh_n[4] && (sh_n[3:0] != 4'd0);
    wire [31:0] va_rep = (u_size == 2'd0) ? {4{va[7:0]}} :
                         (u_size == 2'd1) ? {2{va[15:0]}} : va;
    wire        a_sign = (u_size == 2'd0) ? va[7] : (u_size == 2'd1) ? va[15] : va[31];
    wire        b_sign = (u_size == 2'd0) ? vb[7] : (u_size == 2'd1) ? vb[15] : vb[31];
    wire [32:0] m_a = (u_unit == U_MUL)
                        ? {u_aop[0] & a_sign, u_aop[0] ? (va | ({32{a_sign}} & ~smask)) : va}
                        : (u_aop[2:1] == 2'd0) ? {1'b0, va_rep}
                        : sh_d16x ? {1'b0, vc[15:0], vc[15:0]}
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
    // Kinds 2 and 3 are the double shifts, SHLD and SHRD: register A
    // shifted, and the bits register C gives OR-ed in where A's left.
    // Those are "the other half" of the same shift of C, which a
    // second multiplier makes beside the first, so that a double
    // shift is one uop like any other. (DOOM draws its floors with
    // them.) With 16-bit operands and more than 16 places the
    // hardware's result is C rotated; the first multiplier does that
    // and the second's bits are left out.
    reg  [31:0] m_c_r;
    reg  [63:0] prod2;
    always @(posedge clk) begin
        m_c_r <= vc;
        prod2 <= m_c_r * m_b_r[31:0];
    end
    wire [31:0] sh_oth = sh_d16x ? 32'd0 :
                         (u_size == 2'd1) ? {16'd0, prod2[31:16]} :
                         sh_rt ? prod2[31:0] : prod2[63:32];
    // Multiply: the upper half of the product, and whether it holds
    // more than the sign (or zero) extension of the lower half.
    wire [31:0] mul_hi = (u_size == 2'd0) ? {24'd0, prod[15:8]} :
                         (u_size == 2'd1) ? {16'd0, prod[31:16]} : prod[63:32];
    wire        mul_ls = (u_size == 2'd0) ? prod[7] :
                         (u_size == 2'd1) ? prod[15] : prod[31];
    wire        mul_ov = mul_hi != ((u_aop[0] && mul_ls) ? smask : 32'd0);

    wire        sh_rot = (u_aop[2:1] == 2'd0);
    wire [31:0] sh_raw = (sh_rot || sh_d16x) ? (prod[31:0] | prod[63:32]) :
                         (sh_rt ? prod[63:32] : prod[31:0]) | (sh_dbl ? sh_oth : 32'd0);
    // A count of zero changes nothing.
    wire        sh_nz  = (sh_n != 5'd0);
    wire [31:0] sh_res = sh_nz ? (sh_raw & smask) : va;
    wire        sh_msb = (u_size == 2'd0) ? sh_res[7] :
                         (u_size == 2'd1) ? sh_res[15] : sh_res[31];
    wire        sh_nxt = (u_size == 2'd0) ? sh_res[6] :
                         (u_size == 2'd1) ? sh_res[14] : sh_res[30];
    // A byte shifted by 16 or 24 reports the carry of a shift by 8
    // (observed on hardware).
    wire        sh_b8  = (u_size == 2'd0) && (sh_n == 5'd16 || sh_n == 5'd24);
    wire        sh_cf  = (sh_rot || sh_d16x) ? (sh_rt ? sh_msb : sh_res[0]) :
                         sh_rt  ? (sh_b8 && !sh_sx ? va[7] : prod[31]) :
                         sh_b8  ? va[0] :
                         (u_size == 2'd0) ? prod[8] :
                         (u_size == 2'd1) ? prod[16] : prod[32];
    wire        sh_of  = sh_dbl ? sh_msb ^ a_sign :      // the sign changed
                         sh_rot ? (sh_rt ? sh_msb ^ sh_nxt : sh_msb ^ sh_cf) :
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
    // DIVGO divides {A, B} by C, unsigned, two bits a cycle (two
    // subtractions one after the other): half as many cycles as the
    // size has bits. Microcode has made sure that A is
    // below C, so the quotient fits. DIVQ and DIVR read the quotient
    // and the remainder afterwards.
    reg  [31:0] dv_r, dv_q, dv_d, dv_mask;
    reg  [5:0]  dv_n;
    reg         dv_run;
    wire        is_div  = (u_unit == U_SPEC) && (u_aop == SP_DIVGO);
    wire        dv_last = dv_run && (dv_n == 6'd2);
    wire        dv_msb  = (dv_mask[31]) ? dv_q[31] : (dv_mask[15]) ? dv_q[15] : dv_q[7];
    wire        dv_msb2 = (dv_mask[31]) ? dv_q[30] : (dv_mask[15]) ? dv_q[14] : dv_q[6];
    wire [32:0] dv_sh   = {dv_r, dv_msb};
    wire [32:0] dv_df   = dv_sh - {1'b0, dv_d};
    wire [31:0] dv_r1   = dv_df[32] ? dv_sh[31:0] : dv_df[31:0];
    wire [32:0] dv_sh2  = {dv_r1, dv_msb2};
    wire [32:0] dv_df2  = dv_sh2 - {1'b0, dv_d};
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
            dv_r <= dv_df2[32] ? dv_sh2[31:0] : dv_df2[31:0];
            dv_q <= {dv_q[29:0], !dv_df[32], !dv_df2[32]};
            dv_n <= dv_n - 6'd2;
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
            4'd1: sp_e = {13'd0, fl[18], vm_int, fl[16:0]};     // (VM shows only in an interrupt's frame)
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
            4'd8: case (u_cc)
                4'd2: sp_e = ra & 32'h00F0FF00;
                4'd3: sp_e = ck_lim;
                4'd12: sp_e = {16'd0, err};
                // Where the task state segment keeps the stack of the
                // level being gone to.
                4'd13: sp_e = tss_sp;
                4'd14: sp_e = ostk;
                4'd15: sp_e = {16'd0, ss_prev};
                default: sp_e = sel_ok ? pm_desc : 32'd0;
            endcase
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
    // ---- a look at a descriptor (READ of R_DESC with a cc) ----
    // Its second half is in A (in pm_hi for 4, the segment load's own
    // look), its first in C; the selector is the one last looked up.
    wire [31:0] ck_h   = (u_cc == 4'd4) ? pm_hi : ra;
    wire [31:0] ck_lim = ck_h[23] ? {ck_h[19:16], rc[15:0], 12'hFFF}
                                  : {12'd0, ck_h[19:16], rc[15:0]};
    wire        ck_s = ck_h[12], ck_code = ck_h[11], ck_conf = ck_h[10], ck_rw = ck_h[9];
    wire [1:0]  ck_dpl = ck_h[14:13], ck_rpl = pm_sel[1:0];
    wire [3:0]  ck_type = ck_h[11:8];
    wire        ck_vis = (ck_dpl >= cpl) && (ck_dpl >= ck_rpl);     // this level may name it
    wire        ck_stack = ck_s && !ck_code && ck_rw && (ck_rpl == tpl) && (ck_dpl == tpl);
    wire        ck_data = ck_s && (!ck_code || ck_rw) && ((ck_code && ck_conf) || ck_vis);
    wire [15:0] ck_lar = 16'h1A3E, ck_lsl = 16'h0A0E;
    reg         ck_ok, ck_in;
    always @* begin
        ck_in = 1'b0;
        case (u_cc)
            // VERR (segment field even) or VERW (odd).
            4'd1: ck_ok = ck_s && (u_seg[0] ? (!ck_code && ck_rw) : (!ck_code || ck_rw)) &&
                          ((ck_code && ck_conf) || ck_vis);
            4'd2: ck_ok = (ck_s || ck_lar[ck_type]) && ((ck_s && ck_code && ck_conf) || ck_vis);
            4'd3: ck_ok = (ck_s || ck_lsl[ck_type]) && ((ck_s && ck_code && ck_conf) || ck_vis);
            // A segment register's load: SS by the stack's rule.
            4'd4: ck_ok = sel_ok && ((pm_seg == 3'd2) ? ck_stack : ck_data);
            4'd5: ck_ok = sel_ok && ck_stack;
            // Code, named by a far jump or call.
            4'd6: ck_ok = sel_ok && ck_s && ck_code &&
                          (ck_conf ? (ck_dpl <= cpl) : (ck_rpl <= cpl && ck_dpl == cpl));
            // Code behind a gate, called (an inner level is allowed) ...
            4'd7: begin
                // (Out of virtual 8086 mode: to level 0 only.)
                ck_ok = sel_ok && ck_s && ck_code &&
                        ((v86 || vm_int) ? (ck_dpl == 2'd0 && !ck_conf) : (ck_dpl <= cpl));
                ck_in = !ck_conf && (ck_dpl < cpl);
            end
            // ... or jumped to.
            4'd8: ck_ok = sel_ok && ck_s && ck_code &&
                          (ck_conf ? (ck_dpl <= cpl) : (ck_dpl == cpl));
            // Code returned to (an outer level is allowed).
            4'd9: begin
                ck_ok = sel_ok && (ck_rpl >= cpl) && ck_s && ck_code &&
                        (ck_conf ? (ck_dpl <= ck_rpl) : (ck_dpl == ck_rpl));
                ck_in = ck_rpl > cpl;
            end
            // A call gate. An interrupt or trap gate (software needs
            // the gate's level; an interrupt or a fault does not).
            4'd10: ck_ok = !ck_s && (ck_type == 4'd4 || ck_type == 4'd12) && ck_vis;
            4'd11: ck_ok = !ck_s && (ck_h[10:9] == 2'b11) && (ext || ck_dpl >= cpl);
            4'd13: ck_ok = tr_32;
            default: ck_ok = 1'b0;
        endcase
    end
    wire        ck_now = (u_unit == U_SPEC) && (u_aop == SP_READ) && (u_b == 4'd8) &&
                         (u_cc != 4'd0) && (u_cc < 4'd12 || u_cc == 4'd13);

    // With PE set IF changes only at or inside the I/O privilege
    // level, and that level itself only at level 0.
    wire        if_bad = cr0[0] && (cpl > fl[13:12]);
    wire [15:0] wf_mask = imm[15:0] & ~{2'b00, {2{cr0[0] && cpl != 2'd0}}, 2'b00, if_bad, 9'd0};
    wire        is_lea = (u_unit == U_SPEC) && (u_aop == SP_LEA);
    wire [31:0] sp_val = is_lea ? off : sp_e;

    // What a STORE stores. (Of what READ reads, only the first eight:
    // the system registers go through a temporary, to keep them off
    // this path.)
    reg [31:0] sp_st;
    always @* begin
        case (u_b[2:0])
            3'd0: sp_st = i_eip;
            3'd1: sp_st = {13'd0, fl[18], vm_int, fl[16:0]};
            3'd2: sp_st = {16'd0, ss_q};
            3'd3: sp_st = cur_eip + {28'd0, len};
            3'd4: sp_st = imm;
            3'd5: sp_st = disp;
            // (The descriptor's type byte, marked accessed.)
            3'd6: sp_st = {24'd0, pm_hi[15:8] | 8'd1};
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
    wire busy      = (valid && (first || stall || (is_div && !dv_last))) || st_block ||
                     (valid00 && xl_block);

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
    // Conditions of the protection microcode: PE; a null selector for
    // a data segment; the segment being loaded is CS; and what the
    // last look at a descriptor found.
    // (As they will be once the word now running is done: the word
    // that asks is being fetched while the one that looks runs, and
    // the answer is registered with it.)
    wire [2:0] pm_seg_n = pm_div ? u_seg : pm_seg;
    wire       sel_null_n = pm_div ? (va[15:2] == 14'd0) : sel_null;
    // A second set (ROM bits 88 and 89 both): in virtual 8086 mode;
    // there, and outside the I/O privilege level; coming out of it;
    // at level 0; in protected mode proper.
    wire [7:0] pcx = {3'd0, cr0[0] && !fl[17], cpl == 2'd0, vm_int,
                      v86 && (fl[13:12] != 2'b11), v86};
    wire       ck_x = ck_now && s2_v && in_rom;
    wire [7:0] pcond = {ck_x ? ck_in : chk_inner,
                        ck_x ? (sel_ok && !ck_s) : chk_sys,
                        ck_x ? ck_h[8] : chk_a,
                        ck_x ? ck_h[15] : chk_p,
                        ck_x ? ck_ok : chk_ok,
                        pm_seg_n == 3'd1,
                        sel_null_n && pm_seg_n != 3'd1 && pm_seg_n != 3'd2,
                        cr0[0]};
    wire done = (fin && u_br != 3'd3) || jt_pend;
    wire hot_fin = hot && valid && !busy && !last;
    wire ujump = valid && !busy && !hot && r_ujmp &&
                 (!r_ucond || (r_ucpe ? r_pj :
                               r_ucflt ? (in_flt ^ r_ucc[0]) :
                               r_uca ? !a_is1 :
                               r_ucx ? ((r_ucc[1] ? c_rep[1] : c_rep[0]) ^ r_ucc[0]) :
                               r_ucz ? (uz ^ r_ucc[0]) : cond(r_ucc, fl)));

    // ---- decoder: reads the bytes of an instruction not in the cache -------------------

    localparam [3:0] DS_IDLE = 4'd0, DS_PFX = 4'd1, DS_ATTR = 4'd2, DS_OPC = 4'd3,
                     DS_MODRM = 4'd4, DS_SIB = 4'd5, DS_DISP = 4'd6, DS_ATTR2 = 4'd7,
                     DS_IMMGO = 4'd8, DS_IMM = 4'd9, DS_IMM2 = 4'd10, DS_GO = 4'd11,
                     DS_WAIT = 4'd12, DS_XL = 4'd13, DS_WOPC = 4'd14;
    reg [3:0]  ds /* verilator public_flat */;
    reg [3:0]  ds_next;
    reg [3:0]  d_len;
    // (Where the decoder is: the instruction's address and the bytes
    // read so far.)
    wire [31:0] d_ip = i_eip + {28'd0, d_len};
    reg        d_map;
    reg [7:0]  d_op, d_modrm, d_sib;
    reg        d_os32, d_as32, d_ovr_v, d_lock;
    reg [1:0]  d_rep;
    // LOCK is valid only on some memory forms. Opcode groups decide by
    // the ModRM reg field.
    // ---- the decoder's window ----
    // When the instruction's first eight bytes may all be read (they
    // lie inside the code segment and, with paging, in one page) the
    // decoder reads them as two words and takes the instruction's
    // fields from those, in the cycle it knows where each is, instead
    // of asking the bus for every field. win holds the seven bytes
    // after the first (after the last prefix, if there are prefixes:
    // each moves the window down a byte); w_n says how many are
    // there; w2: the second word is still on its way. ModRM, SIB and
    // displacement are taken together; wp is then where the immediate
    // begins. A field that is not in the window is read the old way,
    // as is all of an instruction whose eight bytes may not be read.
    reg [55:0] win;
    reg [2:0]  w_n, wp;
    reg        wmode_r, w2;
    wire       wmode = (WIN != 0) && wmode_r;
    // The ModRM byte: the window's, in the cycle it is taken from there.
    wire [7:0] mq = (ds == DS_OPC && wmode && attr_q[10]) ? win[7:0] : d_modrm;
    reg        grp_lock;
    always @* begin
        case (d_op)
            8'h80, 8'h81, 8'h82, 8'h83: grp_lock = (mq[5:3] != 3'd7);
            8'hF6, 8'hF7: grp_lock = (mq[5:3] == 3'd2 || mq[5:3] == 3'd3);
            8'hFE, 8'hFF: grp_lock = (mq[5:3] < 3'd2);
            8'hBA: grp_lock = !d_map || (mq[5:3] >= 3'd5);
            default: grp_lock = 1'b1;
        endcase
    end
    // Opcode groups of which only some members exist, and which have
    // no microcode words for the others.
    wire       grp_ud = (!d_map &&
                         (((d_op == 8'hC6 || d_op == 8'hC7 || d_op == 8'h8F) &&
                           mq[5:3] != 3'd0) ||
                          (d_op == 8'hFE && mq[5:3] > 3'd1))) ||
                        // (0F 00, SLDT and its kin, LAR and LSL: protected mode only.)
                        (d_map && (d_op == 8'h00 || d_op == 8'h02 || d_op == 8'h03) &&
                         (!cr0[0] || fl[17])) ||
                        (!d_map && d_op == 8'h63 && (!cr0[0] || fl[17]));     // (and ARPL)
    // What only level 0 may do. These are never cached: the level is
    // looked at as they are decoded.
    wire       d_priv = d_map ? (d_op == 8'h06 || d_op == 8'h08 || d_op == 8'h09 ||
                                 d_op[7:2] == 6'b001000 ||
                                 (d_op == 8'h00 && mq[5:4] == 2'b01) ||
                                 (d_op == 8'h01 && (mq[5:4] == 2'b01 || mq[5:4] == 2'b11)))
                              : (d_op == 8'hF4);
    reg [2:0]  d_ovr;
    reg [31:0] d_disp, d_imm;
    reg        dreq_r, dwr_r;
    wire       d_ismem = (mq[7:6] != 2'd3);
    wire [1:0] d_osz = d_os32 ? 2'd2 : 2'd1;

    assign d_req = dreq_r && !lim_now && !fetch_bad;
    assign d_wr  = dwr_r && !lim_now;

    // ---- combinational control ------------------------------------------------------------

    wire [3:0] lane_d = (u_size == 2'd0) ? (u_hi[2] ? 4'b0010 : 4'b0001) :
                        (u_size == 2'd1) ? 4'b0011 : 4'b1111;
    wire      go = (ds == DS_GO) && !w2;
    // The string instructions: 6C-6F, A4-A7, AA-AF.
    wire       d_str = !d_map && (d_op[7:2] == 6'b011011 || d_op[7:2] == 6'b101001 ||
                                  d_op[7:1] == 7'b1010101 || d_op[7:2] == 6'b101011);

    // What is written to a register, apart from the adder's sum.
    wire        wr_aupd = is_mem && u_aupd && !cyc2;        // a pointer moves
    wire        und_now = lim_now || xf_now;
    wire        wr_undo = (und_now && un0_v) || un_second;
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
    wire [31:0] wr_early = (und_now && un0_v) ? un0_d : un_second ? un1_d :
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
        if (und_now && un0_v) begin
            rf_we = 1'b1; rf_wa = un0_r; rf_lane = 4'b1111;
        end else if (un_second) begin
            rf_we = 1'b1; rf_wa = un1_r; rf_lane = 4'b1111;
        end
        // The data: the adder's sum is the last thing to arrive, so it
        // is chosen last, against everything else chosen before. Bytes
        // outside the lanes written do not matter and are not cleared.
        rf_wd = wr_sum ? {alu_sum[31:16], wr_ah ? alu_sum[7:0] : alu_sum[15:8], alu_sum[7:0]}
                       : wr_early;

        // A segment an outer level may not keep is emptied (cc 2).
        sg_drop = cr0[0] && !in_pm && u_cc[1] && !sg_null[u_seg] && sg_prot[u_seg] &&
                  ({sg_dpl[{u_seg, 1'b1}], sg_dpl[{u_seg, 1'b0}]} < cpl);
        sg_we  = valid && is_setseg && !pm_div && (!(cr0[0] && !in_pm && u_cc[1]) || sg_drop);
        sg_wa  = pm_fin ? pm_seg : u_seg;
        sg_nl  = (pm_fin && u_cc[0]) || sg_drop;
        // (CS takes the level being gone to as its selector's.)
        sg_sel = sg_drop ? 16'd0 :
                 pm_fin ? ((pm_seg == 3'd1) ? {pm_sel[15:2], tpl} : pm_sel) : va[15:0];
        sg_pm  = pm_fin;
        // The descriptor's two halves were kept as they were read.
        sg_base = pm_fin ? {pm_hi[31:24], pm_hi[7:0], pm_lo[31:16]} : {12'd0, va[15:0], 4'd0};
        sg_lim  = pm_hi[23] ? {pm_hi[19:16], pm_lo[15:0], 12'hFFF}
                            : {12'd0, pm_hi[19:16], pm_lo[15:0]};

        // The first uop of a newly decoded instruction goes to the cache
        // as it moves from the ROM to execution.
        dc_fill = i_first && s1_v && !busy && !flt_now && !flushing && mode_ok && !d_priv;
        dc_we = dc_fill || flushing || p_kill;
        dc_wa = flushing ? fl_idx : p_kill ? p_evaddr[DC_AW-1:0] : i_lin[DC_AW-1:0];
        dc_wd = {1'b1, gen, i_lin[31:DC_AW], i_len,
                 // Where the instruction continues. A first word's jump is
                 // settled here if it is unconditional or depends only on
                 // the REP prefix; it may not depend on anything else
                 // (the microassembler checks).
                 w[64] ? {UC_AW{1'b0}} :
                 (w[58] && (!w[59] || (w[83] && ((w[61] ? c_rep[1] : c_rep[0]) ^ w[60]))))
                     ? w_k : upc1 + 1'b1,
                 w_pre, w_res, i_ctx,
                 // A constant from the ROM word takes the place of the
                 // immediate and displacement, as it does when the word
                 // runs from the ROM. Only single-uop instructions use
                 // this (the microassembler checks).
                 w[65] ? {{(32-UC_AW){w_k[UC_AW-1]}}, w_k} : i_imm,
                 w[65] ? {{(32-UC_AW){w_k[UC_AW-1]}}, w_k} : i_disp};
        if (flushing || p_kill)
            dc_wd = {DCW{1'b0}};

        // The read port: the next instruction's entry; during a probe,
        // the entries being checked, and then the next instruction's again.
        dc_re = done || rst || phold;
        dc_ra = rst ? {DC_AW{1'b0}} :
                probe_take ? pr_addr[DC_AW-1:0] - 4'd14 :
                probing ? (p_restore ? lk_lin[DC_AW-1:0] : p_cand[DC_AW-1:0]) :
                (sl_hold || dma_take || xs[4]) ? lk_lin[DC_AW-1:0] :  // waiting: the next instruction's again
                ra_next;

        // Where the microcode goes on, if nothing sends it elsewhere.
        if (go)
            ur_n = {1'b0, attr_q[9:0]} + (attr_q[16] ? {8'd0, d_modrm[5:3]} : 11'd0)
                               + {10'd0, d_rep[0] && d_str};
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
    wire [31:0] f_lin = i_lin + {28'd0, d_len};
    task dfetch(input [1:0] size, input [3:0] next);
        begin
            d_size  <= size;
            ds_next <= next;
            if (pg) begin
                // The paging unit first; DS_XL makes the request.
                x_lin  <= f_lin;
                x_cur  <= f_lin[31:12];
                x_wr   <= 1'b0;  x_rmw <= 1'b0;  x_st <= 1'b0;
                x_user <= (cpl == 2'd3);
                x_size <= size;
                x_dec  <= 1'b1;  x_second <= 1'b0;  x_io <= 2'd0;
                xs     <= X_LOOK;
                ds     <= DS_XL;
            end else begin
                dreq_r  <= 1'b1;
                dwr_r   <= 1'b0;
                d_io    <= 1'b0;
                d_addr  <= f_lin;
                ds      <= DS_WAIT;
            end
        end
    endtask

    wire [2:0] f_bytes = (d_size == 2'd0) ? 3'd1 : (d_size == 2'd1) ? 3'd2 : 3'd4;
    // Group F6/F7 has an immediate only for TEST (ModRM reg 0 and 1).
    wire [2:0] a_immk = (!d_map && d_op[7:1] == 7'b1111011 && mq[5:3] > 3'd1)
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

    // The opcode byte (or a prefix): from the bus as the first word
    // arrives, from the window after a prefix. The attribute ROM is
    // read with it at once, and for the memory or register form by
    // the byte after it, which is the ModRM byte if there is one
    // (opcodes without one have the same word for both forms).
    wire        bus_ok  = (ds == DS_WAIT) && !fetch_bad && d_ack;
    wire        w_first = wmode && (ds_next == DS_OPC);
    wire        op_win  = (ds == DS_WOPC) && !w2 && (w_n >= 3'd2);
    wire        op_now  = (bus_ok && ds_next == DS_OPC) || op_win;
    wire [7:0]  ob      = (ds == DS_WOPC) ? win[7:0] : d_rdata[7:0];
    wire        ob_mem  = (ds == DS_WOPC) ? (win[15:14] != 2'd3)
                                          : (wmode && d_rdata[15:14] != 2'd3);
    assign      attr_ra = ((ds == DS_WOPC) || ((ds == DS_WAIT) && (ds_next == DS_OPC)))
                          ? {ob_mem, d_map, ob} : attr_a;
    // ModRM, SIB and displacement, taken together.
    wire [7:0]  wm     = win[7:0];
    wire        w_hsib = d_as32 && (wm[7:6] != 2'd3) && (wm[2:0] == 3'd4);
    wire        w_d32  = (wm[7:6] == 2'd2) ||
                         (wm[7:6] == 2'd0 && (w_hsib ? (win[10:8] == 3'd5) : (wm[2:0] == 3'd5)));
    wire        w_d16  = (wm[7:6] == 2'd2) || (wm[7:6] == 2'd0 && wm[2:0] == 3'd6);
    // (The displacement's size as a bus size, and whether there is one.)
    wire        w_dany = (wm[7:6] != 2'd3) && (wm[7:6] == 2'd1 || (d_as32 ? w_d32 : w_d16));
    wire [1:0]  w_dsc  = (wm[7:6] == 2'd1) ? 2'd0 : d_as32 ? 2'd2 : 2'd1;
    wire [2:0]  w_need1 = 3'd1 + {2'd0, w_hsib} +
                          (!w_dany ? 3'd0 : (w_dsc == 2'd0) ? 3'd1 : (w_dsc == 2'd1) ? 3'd2 : 3'd4);
    // The immediate: its size, and whether the window may give it (a
    // far pointer and ENTER's two numbers go the old way).
    wire [1:0]  w_isc  = (a_immk == 3'd1 || a_immk == 3'd4) ? 2'd0 :
                         (a_immk == 3'd3) ? 2'd1 :
                         (a_immk == 3'd2) ? (d_os32 ? 2'd2 : 2'd1) : (d_as32 ? 2'd2 : 2'd1);
    wire [2:0]  w_isz  = (w_isc == 2'd0) ? 3'd1 : (w_isc == 2'd1) ? 3'd2 : 3'd4;
    wire        w_iok  = (a_immk != 3'd0) && (a_immk != 3'd5) && (a_immk != 3'd7);
    // The checks made once ModRM is known.
    wire        ig_ud  = !attr_q[15] || grp_ud ||
                         (d_lock && attr_q[10] && !(d_ismem && attr_q[17] && grp_lock));
    wire        ig_gp  = d_priv && cr0[0] && cpl != 2'd0;
    wire        ig_bad = ig_ud || ig_gp;
    // In DS_OPC: ModRM and what belongs to it are in the window.
    wire        w_mfit  = (ds == DS_OPC) && wmode && attr_q[15] && attr_q[10] &&
                          (w_need1 <= w_n);
    wire        w_mtake = w_mfit && !ig_bad;
    // An opcode without ModRM goes on to its immediate in DS_OPC itself.
    wire        at_immgo = (ds == DS_IMMGO) ||
                           ((ds == DS_OPC) && attr_q[15] && !attr_q[10] && !d_lock);
    wire [3:0]  w_iend  = {1'b0, wp} + {1'b0, w_isz};
    wire        w_itake = at_immgo && !ig_bad && wmode && w_iok && (w_iend <= {1'b0, w_n});
    // What the window gives: the displacement (after ModRM, or after
    // SIB) or the immediate (at wp).
    wire [2:0]  w_off = (ds == DS_OPC && attr_q[10]) ? (w_hsib ? 3'd2 : 3'd1) : wp;
    reg  [31:0] w_at;
    always @* begin
        case (w_off)
            3'd0:    w_at = win[31:0];
            3'd1:    w_at = win[39:8];
            3'd2:    w_at = win[47:16];
            3'd3:    w_at = win[55:24];
            3'd5:    w_at = {16'd0, win[55:40]};
            default: w_at = {24'd0, win[55:48]};
        endcase
    end
    // What a fetch gave, whichever way: cut to its size.
    wire        f_win  = w_mtake || w_itake;
    wire [31:0] f_raw  = f_win ? w_at : d_rdata;
    wire [1:0]  f_szc  = w_mtake ? w_dsc : w_itake ? w_isc : d_size;
    wire [31:0] f_data = (f_szc == 2'd0) ? {24'd0, f_raw[7:0]} :
                         (f_szc == 2'd1) ? {16'd0, f_raw[15:0]} : f_raw;
    wire        disp_now = (bus_ok && ds_next == DS_DISP) || (w_mtake && w_dany);
    wire        imm_now  = (bus_ok && ds_next == DS_IMM) || w_itake;
    // The first fetch may be the window's.
    reg  [32:0] cs_lim7;
    always @(posedge clk)
        cs_lim7 <= {1'b0, cs_lim} - 33'd7;
    wire        w_can = (WIN != 0) && !cs_lim7[32] && (lk_eip <= cs_lim7[31:0]) &&
                        !(pg && lk_lin[11:0] > 12'hFF8);

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
        ud_keep <= 1'b0;
        x_flush <= 1'b0;
        xf_now  <= 1'b0;
        dma_ack <= 1'b0;

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
            cpl <= 2'd0; tpl <= 2'd0; err <= 16'd0; in_hw <= 1'b0; sg_null <= 6'd0;
            xs <= X_IDLE; tlb_v <= 32'd0; x_cross <= 1'b0; x_wok <= 1'b0; x_dec <= 1'b0;
            xf_now <= 1'b0; un_new <= 1'b1; x_flush <= 1'b0; x_second <= 1'b0;
            vm_ld <= 1'b0; vm_int <= 1'b0; x_io <= 2'd0; tr_lim <= 20'd0;
            sg_nw <= 6'd0; sg_nr <= 6'd0; sg_prot <= 6'h3F; sg_dpl <= 12'd0;
            chk_ok <= 1'b0; chk_p <= 1'b0; chk_a <= 1'b0; chk_sys <= 1'b0; chk_inner <= 1'b0;
            gate_trap <= 1'b0; tr_base <= 32'd0; tr_32 <= 1'b0; sel_null <= 1'b0; chk_bad <= 1'b0;
            gdt_base <= 32'd0; gdt_lim <= 16'hFFFF; idt_base <= 32'd0; idt_lim <= 16'hFFFF;
            dreq_r <= 1'b0; dwr_r <= 1'b0; ds <= DS_IDLE; i_first <= 1'b0;
            wmode_r <= 1'b0; w2 <= 1'b0;
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
            un_second <= und_now && un1_v;
            if (und_now || un_second) begin
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
                r_uop <= w_res;  r_pre <= w_pre;  r_k <= w_k;  r_ujmp <= w[58];
                r_ucond <= w[59]; r_ucc <= w[63:60]; r_end <= w[64];
                r_ucz <= w[81];  r_ucx <= w[83];  r_uca <= w[84];
                r_ucpe <= w[88]; r_ucflt <= w[89];
                r_pj <= (w[89] ? pcx[w[63:61]] : pcond[w[63:61]]) ^ w[60];
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

            if (fin) begin in_flt <= 1'b0; in_hw <= 1'b0; vm_int <= 1'b0; tpl <= (sg_we && sg_wa == 3'd1 && sg_pm) ? tpl : cpl; end
`ifdef M86_DBG
            if (flt_now) $display("DBG fault lim=%b ud=%b jmp=%b vec=%h eip=%h upc=%h chk_off=%h chk_lim=%h bad=%b ss=%b err=%h cr2=%h",
                                  lim_now, ud_now, jmp_bad, ud_vec, i_eip, upc1, chk_off, chk_lim, chk_bad, chk_ss, err, cr2);
`endif
            if (flt_now) begin
                // Deliver a fault: microcode takes over.
                in_flt <= 1'b1;
                flt_vec  <= ud_now ? ud_vec : (lim_now && chk_ss && !chk_bad) ? 8'd12 : 8'd13;
                last_exc <= ud_now ? ud_vec : (lim_now && chk_ss && !chk_bad) ? 8'd12 : 8'd13;
                if (!(ud_now && ud_keep)) err <= 16'd0;
                in_pm <= 1'b0; tpl <= cpl; in_hw <= 1'b0; vm_ld <= 1'b0;
                // (A fault on the way out of virtual 8086 mode: back in.)
                if (vm_int) begin fl[17] <= 1'b1; vm_int <= 1'b0; end
                in_rom <= 1'b1; lk_pend <= 1'b0; s1_v <= 1'b1; s2_v <= 1'b0;
                cyc2 <= 1'b0; cyc3 <= 1'b0; ds <= DS_IDLE; i_first <= 1'b0;
                dreq_r <= 1'b0; wmode_r <= 1'b0; w2 <= 1'b0;
            end else if (irq_take) begin
                // Deliver an interrupt: microcode, returning to the
                // instruction that was about to run.
                in_rom <= 1'b1; lk_pend <= 1'b0; s1_v <= 1'b1; s2_v <= 1'b0;
                i_eip <= lk_eip; i_lin <= lk_lin; i_first <= 1'b0;
                esp0 <= esp_now;
                in_hw <= 1'b1;
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
                d_len <= 4'd0; d_map <= 1'b0;
                esp0 <= esp_now;
                d_os32 <= cs_d; d_as32 <= cs_d; d_ovr_v <= 1'b0; d_lock <= 1'b0;
                d_rep <= 2'd0;
                d_modrm <= 8'hC0; d_sib <= 8'd0; d_disp <= 32'd0; d_imm <= 32'd0;
                // The first fetch, at once: the window's first word if
                // the window may be read, or one byte.
                wmode_r <= w_can;  w2 <= 1'b0;  wp <= 3'd0;
                d_size  <= w_can ? 2'd2 : 2'd0;
                ds_next <= DS_OPC;
                if (WIN == 0)
                    ds     <= DS_PFX;           // (without the window: a cycle later)
                else if (pg) begin
                    x_lin  <= lk_lin;
                    x_cur  <= lk_lin[31:12];
                    x_wr   <= 1'b0;  x_rmw <= 1'b0;  x_st <= 1'b0;
                    x_user <= (cpl == 2'd3);
                    x_size <= w_can ? 2'd2 : 2'd0;
                    x_dec  <= 1'b1;  x_second <= 1'b0;  x_io <= 2'd0;
                    xs     <= X_LOOK;
                    ds     <= DS_XL;
                end else begin
                    dreq_r <= 1'b1;
                    dwr_r  <= 1'b0;
                    d_io   <= 1'b0;
                    d_addr <= lk_lin;
                    ds     <= DS_WAIT;
                end
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
                    d_io    <= (u_seg == 3'd7) || (pg && x_cross);
                    dwr_r   <= (u_unit == U_STORE);
                    // (d_addr: at the end of this block.)
                    d_size  <= m_size;
                    d_wdata <= st_data;
                    chk_v     <= 1'b1;
                    chk_off   <= off;
                    // (No offset will do if the segment may not be
                    // used this way, or the port not at this level.)
                    chk_lim   <= acc_bad ? 33'h1_0000_0000 :
                                 {1'b0, seg_lim[u_seg]} -
                                 {31'd0, m_size[1], m_size[1] | m_size[0]};
                    chk_bad   <= acc_bad;
                    chk_ss    <= (u_seg == 3'd2);
                end
                if (relatch) begin
                    dreq_r  <= 1'b1;
                    dwr_r   <= 1'b1;
                    d_wdata <= st_data;
                    // (The paging unit may have used the bus since the load.)
                    if (pg) begin
                        d_addr <= x_addr;
                        d_io   <= x_cross;
                        d_size <= u_size;
                    end
                end
                if (!cyc2 && !cyc3) un_new <= 1'b0;
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
                                     ((({fl[17:0]} & ~{2'd0, wf_mask}) |
                                       (va[17:0] & {2'd0, wf_mask})) & 18'h37FD5) | 18'h2};
                    SP_SZP: begin               // sign, zero, parity of A
                        fl[6] <= (va == 32'd0);
                        fl[7] <= (u_size == 2'd0) ? va[7] :
                                 (u_size == 2'd1) ? va[15] : va[31];
                        fl[2] <= ~^va[7:0];
                    end
                    // (Real mode only: with PE set the new segment's
                    // limit is what counts, and the fetch finds out.)
                    SP_CHKCS: if (va > (pmode ? new_lim : cs_lim)) begin
                        // A far jump's offset is outside the code segment.
                        ud_now <= 1'b1;
                        ud_vec <= 8'd13;
                    end
                    SP_RAISE: begin
                        ud_now <= 1'b1;
                        // (Not present, of a stack segment, is a stack fault.)
                        ud_vec <= (imm[7:0] == 8'd11 && in_pm && pm_seg == 3'd2) ? 8'd12 : imm[7:0];
                        ud_keep <= u_cc[0];
                    end
                    // A NOP with a condition code is a write to a
                    // system register, from A.
                    SP_NOP: if (u_br == 3'd0) case (u_cc)
                        4'd1: begin
                            cr0 <= va;
                            if (!va[0]) begin cpl <= 2'd0; tpl <= 2'd0; end
                            if ((va[31] && va[0]) || pg) x_flush <= 1'b1;
                        end
                        4'd2: gdt_lim <= va[15:0];
                        4'd3: gdt_base <= c_os32 ? va : {8'd0, va[23:0]};
                        4'd4: idt_lim <= va[15:0];
                        4'd5: idt_base <= c_os32 ? va : {8'd0, va[23:0]};
                        4'd6: cr2 <= va;
                        4'd7: begin cr3 <= va; if (pg) x_flush <= 1'b1; end
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
                            pm_sel  <= va[15:0];
                            pm_desc <= (va[2] ? ldt_base : gdt_base) + {16'd0, va[15:3], 3'd0};
                            sel_ok  <= (va[15:2] != 14'd0) &&
                                       ({va[15:3], 3'b111} <= (va[2] ? ldt_lim : gdt_lim));
                        end
                        4'd12: tr_sel <= va[15:0];
                        // The level being gone to, and the error code
                        // (the B field says which): 1 a descriptor's
                        // level, 2 a selector's; 3 the selector last
                        // looked up, 4 register A, as an error code.
                        4'd14: case (u_b)
                            4'd1: tpl <= va[14:13];
                            4'd2: tpl <= va[1:0];
                            4'd3: err <= {pm_sel[15:2], 1'b0, ext};
                            4'd4: err <= {va[15:1], va[0] | ext};
                            4'd5: if (pg) x_flush <= 1'b1;     // INVLPG
                            // Virtual 8086 mode: 6 its registers are
                            // being loaded; 7 into it; 8 out of it.
                            4'd6: vm_ld <= 1'b1;
                            4'd7: begin
                                fl[17] <= 1'b1;  vm_ld <= 1'b0;
                                cpl <= 2'd3;     tpl <= 2'd3;
                            end
                            4'd8: begin
                                vm_int <= fl[17];
                                fl[17] <= 1'b0;
                            end
                            default: ;
                        endcase
                        // LTR: where the task state segment is (A the
                        // descriptor's second half, B its first).
                        4'd15: begin
                            tr_base <= {va[31:24], va[7:0], vb[31:16]};
                            tr_32   <= va[11];
                            tr_lim  <= {va[19:16], vb[15:0]};
                        end
                        default: ;
                    endcase
                    SP_FLBIT: case (u_cc[3:1])
                        3'd0: fl[0]  <= u_cc[0];
                        // (CLI and STI: not above the I/O privilege level.)
                        3'd1: if (if_bad) begin
                            ud_now <= 1'b1;
                            ud_vec <= 8'd13;
                        end else
                            fl[9]  <= u_cc[0];
                        3'd2: fl[10] <= u_cc[0];
                        3'd3: fl[0]  <= ~fl[0];
                        // (Into a handler: a trap gate leaves IF; NT goes.)
                        3'd4: begin
                            if (!(cr0[0] && gate_trap)) fl[9] <= 1'b0;
                            fl[8] <= 1'b0;
                            if (cr0[0]) fl[14] <= 1'b0;
                        end
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
                    if (sg_pm) cs_d <= pm_hi[22];
                    if (sg_pm) cpl <= tpl;
                    if (sg_v86) begin cs_lim <= 32'h0000FFFF; cs_d <= 1'b0; end
                end
                if (sg_we && sg_wa == 3'd2 && sg_pm) ss_b <= pm_hi[22];
                if (sg_we && sg_wa == 3'd2 && sg_v86) ss_b <= 1'b0;
                if (sg_we && sg_wa == 3'd2) ss_prev <= seg_sel[2];
                // The segment's rights: from the descriptor; none for
                // a null selector; anything goes for a real-mode load.
                if (sg_we && sg_wa < 3'd6) begin
                    sg_null[sg_wa] <= sg_nl;
                    if (!sg_nl) begin
                        sg_nw[sg_wa]   <= sg_pm && (pm_hi[11] || !pm_hi[9]);
                        sg_nr[sg_wa]   <= sg_pm && pm_hi[11] && !pm_hi[9];
                        // (A real-mode load is level-0 data.)
                        sg_prot[sg_wa] <= !sg_pm || !(pm_hi[11] && pm_hi[10]);
                        sg_dpl[{sg_wa, 1'b1}] <= sg_pm ? pm_hi[14] : (v86 || vm_ld);
                        sg_dpl[{sg_wa, 1'b0}] <= sg_pm ? pm_hi[13] : (v86 || vm_ld);
                    end
                end
                if (valid && !busy && ck_now) begin
                    chk_ok <= ck_ok;  chk_inner <= ck_in;
                    chk_p  <= ck_h[15]; chk_a <= ck_h[8]; chk_sys <= sel_ok && !ck_s;
                    if (u_cc == 4'd11) gate_trap <= ck_h[8];
                    if (u_cc >= 4'd6 && u_cc <= 4'd9) new_lim <= ck_lim;
                end
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
                    sel_null <= (va[15:2] == 14'd0);
                    sel_ok  <= (va[15:2] != 14'd0) &&
                               ({va[15:3], 3'b111} <= (va[2] ? ldt_lim : gdt_lim));
                end
                if (pm_fin)
                    in_pm <= 1'b0;
                if (in_pm && u_unit == U_LOAD && !first && !u_dwe) begin
                    if (u_disp) pm_hi <= result;
                    else        pm_lo <= result;
                end

                if (fin && u_br == 3'd3) begin
                    jt_pend <= 1'b1;
                    jt_eip  <= u_a16 ? {16'd0, result[15:0]} : result;
                    lk_pend <= 1'b0;
                end else if (done) begin
                    // (A word that raises a fault ends its routine, but
                    // the instruction is not done: the fault's delivery
                    // is the step.)
                    if (!(u_unit == U_SPEC && (u_aop == SP_RAISE ||
                                               (u_aop == SP_FLBIT && u_cc[3:1] == 3'd1 && if_bad)))) begin
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
            // The window's second word arrives.
            if (w2) begin
                if (d_ack) begin
                    w2  <= 1'b0;
                    win[55:24] <= d_rdata;
                    w_n <= w_n + 3'd4;
                end else if (!flt_now)
                    dreq_r <= 1'b1;
            end
            if (!flt_now) case (ds)
                DS_PFX: dfetch(2'd0, DS_OPC);
                DS_XL: if (xs == X_RDY) begin
                    dreq_r <= 1'b1;
                    dwr_r  <= 1'b0;
                    d_io   <= x_cross;
                    d_addr <= x_addr;
                    d_size <= x_size;
                    xs     <= X_IDLE;
                    ds     <= DS_WAIT;
                    if (d_len == 4'd0) i_ppn <= x_ppn;
                    i_ppn_e <= x_cross ? x_ppn2 : x_ppn;
                end
                DS_WAIT: if (fetch_bad) begin
                    ud_now <= 1'b1;
                    ud_vec <= 8'd13;
                    dreq_r <= 1'b0;
                    ds     <= DS_IDLE;
                end else if (!d_ack)
                    dreq_r <= 1'b1;
                else begin
                    dreq_r <= 1'b0;
                    d_len  <= d_len + {1'b0, f_bytes};
                    ds     <= ds_next;
                    if (w_first) begin
                        // The window's first word: its first byte is
                        // looked at now (below), the rest kept, and
                        // the second word asked for.
                        d_len  <= d_len + 4'd1;
                        win[23:0] <= d_rdata[31:8];
                        w_n    <= 3'd3;
                        w2     <= 1'b1;
                        dreq_r <= 1'b1;
                        d_addr <= d_addr + 32'd4;
                    end
                    case (ds_next)
                        DS_MODRM: begin
                            d_modrm <= f_data[7:0];
                            attr_a  <= {f_data[7:6] != 2'd3, d_map, d_op};
                        end
                        DS_SIB:  d_sib  <= f_data[7:0];
                        DS_DISP: ds <= DS_ATTR2;            // (the displacement: below)
                        DS_GO: d_disp <= f_data;
                        default: ;                          // (opcode, immediate: below)
                    endcase
                end
                // After a prefix, in the window: the next byte (below),
                // if it and the one after it are there.
                DS_WOPC: if (!w2 && w_n < 3'd2) begin
                    wmode_r <= 1'b0;
                    ds    <= DS_PFX;
                end
                // The attribute word is here. (Nothing is raised and
                // nothing else asked of the bus while the window's
                // second word is on its way.)
                DS_OPC: if (!attr_q[15] || (d_lock && !attr_q[10])) begin
                    if (!w2) begin
                        ud_now <= 1'b1;
                        ds <= DS_IDLE;
                    end
                end else if (w_mfit) begin
                    if (!ig_bad) begin
                        // ModRM, SIB and displacement from the window.
                        d_modrm <= wm;
                        if (w_hsib) d_sib <= win[15:8];
                        wp    <= w_need1;
                        d_len <= d_len + {1'b0, w_need1};
                        ds    <= (a_immk == 3'd0) ? DS_GO : DS_IMMGO;
                    end else if (!w2) begin
                        ud_now <= 1'b1;
                        if (!ig_ud) ud_vec <= 8'd13;
                        ds <= DS_IDLE;
                    end
                end else if (attr_q[10] && !w2) begin
                    wmode_r <= 1'b0;
                    dfetch(2'd0, DS_MODRM);
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
                DS_IMMGO: ;                     // (below)
                DS_GO: if (!w2) begin

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

            // The opcode byte, or a prefix.
            if (!flt_now && op_now) begin
                if (ds == DS_WOPC) begin
                    win   <= {8'd0, win[55:8]};
                    w_n   <= w_n - 3'd1;
                    d_len <= d_len + 4'd1;
                end
                ds <= wmode ? DS_WOPC : DS_PFX;
                case (ob)
                    8'h26: begin d_ovr_v <= 1; d_ovr <= 3'd0; end
                    8'h2E: begin d_ovr_v <= 1; d_ovr <= 3'd1; end
                    8'h36: begin d_ovr_v <= 1; d_ovr <= 3'd2; end
                    8'h3E: begin d_ovr_v <= 1; d_ovr <= 3'd3; end
                    8'h64: begin d_ovr_v <= 1; d_ovr <= 3'd4; end
                    8'h65: begin d_ovr_v <= 1; d_ovr <= 3'd5; end
                    8'h66: d_os32 <= !cs_d;
                    8'h67: d_as32 <= !cs_d;
                    8'hF0: d_lock <= 1;
                    8'hF2, 8'hF3: d_rep <= {!ob[0], 1'b1};
                    8'h0F: d_map <= 1;
                    default: begin
                        // (The attribute word is being read already.)
                        d_op   <= ob;
                        attr_a <= {ob_mem, d_map, ob};
                        ds     <= DS_OPC;
                    end
                endcase
            end
            // What follows the opcode and ModRM: the immediate.
            if (!flt_now && at_immgo) begin
                if (ig_bad) begin
                    if (!w2) begin
                        ud_now <= 1'b1;
                        if (!ig_ud) ud_vec <= 8'd13;
                        ds <= DS_IDLE;
                    end
                end else if (a_immk == 3'd0)
                    ds <= DS_GO;
                else if (w_itake)
                    d_len <= d_len + {1'b0, w_isz};     // from the window (below)
                else if (!w2) begin
                    wmode_r <= 1'b0;
                    case (a_immk)
                        3'd1, 3'd4: dfetch(2'd0, DS_IMM);
                        3'd2, 3'd5: dfetch(d_osz, DS_IMM);
                        3'd3, 3'd7: dfetch(2'd1, DS_IMM);
                        default: dfetch(d_as32 ? 2'd2 : 2'd1, DS_IMM);
                    endcase
                end
            end
            // The displacement and the immediate, from the bus or the window.
            if (!flt_now && disp_now)
                d_disp <= (mq[7:6] == 2'd1) ? {{24{f_data[7]}}, f_data[7:0]} : f_data;
            if (!flt_now && imm_now) begin
                if (a_immk == 3'd6) begin
                    // A bare offset: make it a ModRM operand with
                    // only a displacement.
                    d_disp  <= f_data;
                    d_modrm <= d_as32 ? 8'h05 : 8'h06;
                end
                d_imm <= (a_immk == 3'd4) ? {{24{f_data[7]}}, f_data[7:0]} :
                         (a_immk == 3'd2 && !d_os32 && attr_q[17])
                             ? {{16{f_data[15]}}, f_data[15:0]} : f_data;
                // A far pointer's selector follows its offset.
                ds <= (a_immk == 3'd5 || a_immk == 3'd7) ? DS_IMM2 : DS_GO;
            end

            // ---- the paging unit ----
            if (done || flt_now || irq_take) un_new <= 1'b1;
            case (xs)
                X_D1: begin
                    d_addr <= {8'd0, dma_addr};  d_size <= 2'd0;  d_io <= 1'b0;
                    dreq_r <= 1'b1;  dwr_r <= 1'b0;
                    xs <= X_D2;
                end
                X_D2: if (d_ack) begin
                    dma_q   <= d_rdata[7:0];
                    dma_ack <= 1'b1;
                    xs <= X_IDLE;
                end else
                    dreq_r <= 1'b1;
                X_IDLE: if (dma_take)
                    xs <= X_D1;
                else if (xl_start && u_seg == 3'd7) begin
                    // A port: is it allowed? A 386's TSS says, if it
                    // is long enough to.
                    x_lin  <= tr_io;
                    x_cur  <= tr_io[31:12];
                    x_wr   <= 1'b0;  x_rmw <= 1'b0;  x_st <= 1'b0;
                    x_user <= 1'b0;  x_dec <= 1'b0;  x_second <= 1'b0;
                    x_size <= 2'd1;
                    x_io   <= 2'd1;
                    x_port <= off[15:0];
                    if (!tr_32 || tr_lim < 20'h67) begin
                        ud_now <= 1'b1;
                        ud_vec <= 8'd13;
                    end else
                        xs <= X_LOOK;
                end else if (xl_start) begin
                    x_io <= 2'd0;
                    if (!relatch) begin
                        x_lin  <= lin;
                        x_cur  <= lin[31:12];
                        x_wr   <= (u_unit == U_STORE) || (u_unit == U_LOAD && u_aop[3]) ||
                                  (u_unit == U_LOADOP && u_cc[1]);
                        // (aop 8: a read-modify-write's read; 12: a look
                        // ahead of a write, which is treated as the write.
                        // A LOAD-OP says the first with cc bit 1.)
                        x_rmw  <= (u_unit == U_LOAD && u_aop[3] && !u_aop[2]) ||
                                  (u_unit == U_LOADOP && u_cc[1]);
                        // (On the way to an inner level the pushes are
                        // already that level's.)
                        x_user <= (cpl == 2'd3) && (tpl == 2'd3) && (u_seg != 3'd6);
                        x_size <= e_size;
                        x_st   <= (u_unit == U_STORE);
                        // (The segment's check comes first, as it would.)
                        chk_v   <= 1'b1;
                        chk_off <= off;
                        chk_lim <= acc_bad ? 33'h1_0000_0000 :
                                   {1'b0, seg_lim[u_seg]} -
                                   {31'd0, m_size[1], m_size[1] | m_size[0]};
                        chk_bad <= acc_bad;
                        chk_ss  <= (u_seg == 3'd2);
                        xs <= X_LOOK;
                    end else begin
                        // The store of a read-modify-write: as a write
                        // now, if the load was not; then its bytes, if
                        // it lies across two pages.
                        x_cur <= x_lin[31:12];
                        x_wr  <= 1'b1;  x_rmw <= 1'b0;  x_st <= 1'b1;
                        x_off <= {1'b0, x_lin[11:0]};
                        x_i   <= 3'd0;
                        xs <= x_wok ? X_BI : X_LOOK;
                    end
                    x_dec <= 1'b0;
                    x_second <= 1'b0;
                end
                X_LOOK: if (tlb_ok) begin
                    if (x_second) x_ppn2 <= tlb_ppn;
                    else begin
                        x_ppn   <= tlb_ppn;
                        x_cross <= x_crosses;
                        x_wok   <= x_wr;
                    end
                    x_off <= {1'b0, x_lin[11:0]};
                    x_i   <= 3'd0;
                    if (!x_second && x_crosses) begin
                        x_second <= 1'b1;
                        x_cur    <= x_cur + 20'd1;
                    end else if (x_second)
                        xs <= X_BI;
                    else
                        xs <= (x_io != 2'd0) ? X_IOA : X_RDY;
                end else
                    xs <= X_W1;
                // The walk: the directory entry, then the table's.
                X_W1: begin
                    d_addr <= x_pdea;  d_size <= 2'd2;  d_io <= 1'b0;
                    dreq_r <= 1'b1;    dwr_r <= 1'b0;
                    xs <= X_W2;
                end
                X_W2: if (d_ack) begin
                    x_pde <= d_rdata;
                    xs <= X_W3;
                end else
                    dreq_r <= 1'b1;
                X_W3: if (!x_pde[0])
                    page_fault(1'b0, x_wr && !x_rmw);
                else begin
                    d_addr <= x_ptea;  d_size <= 2'd2;  d_io <= 1'b0;
                    dreq_r <= 1'b1;    dwr_r <= 1'b0;
                    xs <= X_W4;
                end
                X_W4: if (d_ack) begin
                    x_pte <= d_rdata;
                    xs <= X_W5;
                end else
                    dreq_r <= 1'b1;
                // Allowed? (A read-modify-write is first a read: its
                // write is refused only after the accessed bits are set.)
                X_W5: if (!x_pte[0])
                    page_fault(1'b0, x_wr && !x_rmw);
                else if (x_user && !x_pu)
                    page_fault(1'b1, x_wr && !x_rmw);
                else if (x_wr && !x_rmw && !x_wal)
                    page_fault(1'b1, 1'b1);
                else
                    xs <= X_W6;
                // The accessed bits, and the dirty bit of a page written.
                X_W6: if (x_pde[5])
                    xs <= X_W7;
                else if (d_st_rdy) begin
                    d_addr <= x_pdea;  d_size <= 2'd0;  d_io <= 1'b0;
                    d_wdata <= {24'd0, x_pde[7:0] | 8'h20};
                    dreq_r <= 1'b1;    dwr_r <= 1'b1;
                    xs <= X_W7;
                end
                X_W7: if (x_pte[5] && !(x_wr && x_wal && !x_pte[6]))
                    xs <= X_W8;
                else if (d_st_rdy) begin
                    d_addr <= x_ptea;  d_size <= 2'd0;  d_io <= 1'b0;
                    d_wdata <= {24'd0, x_pte[7:0] | 8'h20 | ((x_wr && x_wal) ? 8'h40 : 8'h00)};
                    dreq_r <= 1'b1;    dwr_r <= 1'b1;
                    xs <= X_W8;
                end
                X_W8: if (x_wr && !x_wal)
                    page_fault(1'b1, 1'b1);
                else begin
                    tlb[x_cur[4:0]]   <= {x_pte[6] || x_wr, x_pw, x_pu, x_pte[31:12], x_cur[19:5]};
                    tlb_v[x_cur[4:0]] <= 1'b1;
                    xs <= X_LOOK;
                end
                // An access across two pages, a byte at a time.
                X_BI: if (x_st) begin
                    if (d_st_rdy) begin
                        d_addr <= x_pa;  d_size <= 2'd0;  d_io <= 1'b0;
                        d_wdata <= {24'd0, x_i[1] ? (x_i[0] ? st_data[31:24] : st_data[23:16])
                                                  : (x_i[0] ? st_data[15:8] : st_data[7:0])};
                        dreq_r <= 1'b1;  dwr_r <= 1'b1;
                        x_off <= x_off + 13'd1;
                        x_i   <= x_i + 3'd1;
                        if (x_i + 3'd1 == x_bytes) xs <= X_RDY;
                    end
                end else begin
                    d_addr <= x_pa;  d_size <= 2'd0;  d_io <= 1'b0;
                    dreq_r <= 1'b1;  dwr_r <= 1'b0;
                    xs <= X_BW;
                end
                X_BW: if (d_ack) begin
                    case (x_i[1:0])
                        2'd0: x_rd[7:0]   <= d_rdata[7:0];
                        2'd1: x_rd[15:8]  <= d_rdata[7:0];
                        2'd2: x_rd[23:16] <= d_rdata[7:0];
                        default: x_rd[31:24] <= d_rdata[7:0];
                    endcase
                    x_off <= x_off + 13'd1;
                    x_i   <= x_i + 3'd1;
                    xs <= (x_i + 3'd1 != x_bytes) ? X_BI : (x_io != 2'd0) ? X_IOC : X_RDY;
                end else
                    dreq_r <= 1'b1;
                // The permission map: a word of the TSS is read ...
                X_IOA: if (x_io == 2'd3) begin
                    x_cur <= x_lin[31:12];
                    x_io  <= 2'd2;
                    xs <= X_LOOK;
                end else begin
                    d_addr <= {x_ppn, x_lin[11:0]};  d_size <= 2'd1;  d_io <= 1'b0;
                    dreq_r <= 1'b1;  dwr_r <= 1'b0;
                    xs <= X_IOB;
                end
                X_IOB: if (d_ack) begin
                    x_rd[15:0] <= d_rdata[15:0];
                    xs <= X_IOC;
                end else
                    dreq_r <= 1'b1;
                // ... first the one that says where the map is, then
                // the map's bits for the port (off: the port's number).
                X_IOC: if (x_io == 2'd1) begin
                    if ({4'd0, x_rd[15:0]} + {7'd0, io_last[15:3]} > tr_lim) begin
                        ud_now <= 1'b1;
                        ud_vec <= 8'd13;
                        xs <= X_IDLE;
                    end else begin
                        x_lin <= tr_base + {16'd0, x_rd[15:0]} + {19'd0, x_port[15:3]};
                        x_second <= 1'b0;
                        x_io <= 2'd3;
                        xs <= X_IOA;
                    end
                end else begin
                    x_io <= 2'd0;
                    if (((x_rd[15:0] >> x_port[2:0]) & {12'd0, io_mask}) != 16'd0) begin
                        ud_now <= 1'b1;
                        ud_vec <= 8'd13;
                        xs <= X_IDLE;
                    end else
                        xs <= X_RDY;
                end
                // Ready: the uop takes it from here (the decoder takes
                // its own, in DS_XL).
                X_RDY: if (!x_dec && valid && !stall && is_mem && !cyc2)
                    xs <= X_IDLE;
                default: xs <= X_IDLE;
            endcase
            if (flt_now) xs <= X_IDLE;
            // The mapping changed: the buffer is emptied, and the
            // instruction cache with it (its entries are found by
            // linear address).
            if (x_flush) begin
                tlb_v <= 32'd0;
                if (gen == {GW{1'b1}}) begin
                    gen <= {GW{1'b0}} + 1'b1;
                    flushing <= 1'b1;
                    fl_idx <= {DC_AW{1'b0}};
                end else
                    gen <= gen + 1'b1;
            end
            // A uop's memory access: its address to the bus. Written
            // here, last, because the address is the last thing to
            // arrive in the cycle and so should have one choice to
            // pass, not one for every other user of the bus above
            // (none of which is at work in a cycle a uop runs).
            if (valid && !stall && is_mem && !cyc2 && !relatch)
                d_addr <= (pg && u_seg != 3'd7) ? x_addr : lin;
        end
    end

    // A page fault: CR2 is the address, the error code says what was
    // being done (bit 0 the page was present, 1 a write, 2 at level 3).
    task page_fault(input present, input write);
        begin
            cr2 <= {x_cur, x_second ? 12'd0 : x_lin[11:0]};
            err <= {13'd0, x_user, write, present};
            ud_now  <= 1'b1;
            ud_vec  <= 8'd14;
            ud_keep <= 1'b1;
            xf_now  <= !un_new;
            xs <= X_IDLE;
            ds <= DS_IDLE;
        end
    endtask

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
