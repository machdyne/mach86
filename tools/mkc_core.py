#!/usr/bin/env python3
"""Make design C's first form from design B's source (docs/cpu_c.md,
step 2): the same logic, every register clocked once in PH cycles of a
faster clock, the bus and the interrupt lines adapted to that. Run once;
rtl/cpu/m86c_core.v is a source file of its own from then on.

usage: tools/mkc_core.py rtl/cpu/m86b_core.v rtl/cpu/m86c_core.v
"""
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()


def rep(a, b, n=1):
    global s
    assert s.count(a) == n, (s.count(a), a[:70])
    s = s.replace(a, b)


# ---- the header ----
a = s.index("/*")
b = s.index(" * A micro-operation (\"uop\"), 48 bits:")
s = s[:a] + '''/*
 * Mach86 CPU, design C -- design B's micro-op engine, cut into steps
 * for a faster clock. See docs/cpu_c.md. NOT ON ANY BOARD.
 *
 * This file began as a copy of m86b_core.v (tools/mkc_core.py) and is
 * a source of its own. What it is so far, step 2 of the plan:
 *
 *   - Design B does a micro-operation's whole work in one clock cycle
 *     of 30 ns. Here that cycle is PH cycles of a faster clock (3 by
 *     default): every register of design B is written only in the
 *     last of them ("tick"), so between ticks the machine is design
 *     B's exactly, standing still.
 *   - Standing still, its long paths can be cut: a wire in the middle
 *     of one is given a register that is clocked every cycle (`CUT`).
 *     Such a register only ever holds what the wire would have
 *     settled to, a cycle late. As long as no path passes more than
 *     PH - 1 of them, everything has settled when the tick comes, and
 *     what is written is what design B would have written. The
 *     lockstep bench checks that: a path with too many cuts shows as
 *     a difference from the model (and goes away with PH one larger).
 *   - The bus and the interrupt lines are design B's, for a machine
 *     at the fast clock: a request is made once, its answer is kept
 *     until the tick, and the inputs that may change at any time are
 *     looked at only at a tick.
 *
 * So it is design B, slower: PH clock cycles for each of design B's.
 * It is here to be right and to find out what clock the steps allow.
 * Running several micro-operations in the steps at once, which is
 * what makes it fast, is step 3.
 *
 * Sources: as m86b_core.v.
 *
''' + s[b:]

rep("module m86b_core #(", "module m86c_core #(")
rep('''    parameter DC_AW = 11,
''', '''    parameter DC_AW = 11,
    // Clock cycles for each of design B's: 2 or more. Every path may
    // pass PH - 1 of the cut registers.
    parameter PH    = 3,
''')

# ---- ports keep their names; inside, the adapted signals are *_c ----
for name in ["dma_ack", "inta", "step_done"]:
    k = s.index("output reg ", s.index("module m86c_core"))
rep("    output reg         dma_ack,", "    output wire        dma_ack,")
rep("    output reg         inta,", "    output wire        inta,")
rep("    output reg         step_done,", "    output wire        step_done,")
pe = s.index(");", s.index("module m86c_core")) + 2
body = s[pe:]
for name in ["d_rdata", "d_ack", "d_st_rdy", "dma_req", "dma_addr", "slow", "irq", "irq_vec",
             "d_req", "e_req", "inta", "dma_ack", "step_done"]:
    body = re.sub(r"\b" + name + r"\b", name + "_c", body)
s = s[:pe] + body

a = s.index(");", s.index("module m86c_core")) + 2
s = s[:a] + '''

    // ---- the steps ----
    // ph counts the fast clock's cycles; design B's registers are
    // written in the last one.
    reg  [2:0] ph;
    wire       tick = (ph == PH - 1);
    wire       ph0  = (ph == 3'd0);
    always @(posedge clk)
        ph <= (rst || tick) ? 3'd0 : ph + 3'd1;

    // A cut: a register in the middle of a long path, clocked every
    // cycle. `CUT(width, name, value) declares `name`, which is
    // `value` a cycle late.
`define CUT(W, NAME, VALUE) \\
    reg [(W) - 1:0] NAME; \\
    always @(posedge clk) NAME <= (VALUE);

    // ---- the bus and the lines from outside ----
    // (Inside, the adapted signals have the ports' names with _c.)
    // A request is on the bus until it is answered. An answer that
    // comes in the first cycle is passed on at once and kept; one that
    // comes later is kept for the next tick's cycles, so that what the
    // core sees does not change between ticks. When the core takes its
    // request back, an answer on its way is dropped.
    wire        d_req_c, e_req_c;
    reg         inta_c, dma_ack_c, step_done_c;
    reg         b_got, b_late;
    reg  [31:0] b_data;
    assign      d_req = d_req_c && !b_got && !b_late;
    wire        b_take  = d_req && d_ack;
    wire        d_ack_c = b_got || (ph0 && b_take);
    wire [31:0] d_rdata_c = b_got ? b_data : d_rdata;
    always @(posedge clk) begin
        if (b_take)
            b_data <= d_rdata;
        if (rst || !d_req_c) begin
            b_got  <= 1'b0;
            b_late <= 1'b0;
        end else if (tick) begin
            // (What the core saw in these cycles it has used.)
            b_got  <= (b_late || b_take) && !d_ack_c;
            b_late <= 1'b0;
        end else if (b_take) begin
            if (ph0) b_got  <= 1'b1;
            else     b_late <= 1'b1;
        end
    end
    // The address of a read a cycle ahead is ready in the last cycle.
    assign      e_req = e_req_c && tick;
    // Pulses are one fast cycle long, the first.
    assign      inta      = inta_c && ph0;
    assign      dma_ack   = dma_ack_c && ph0;
    assign      step_done = step_done_c && ph0;
    // What may change at any time is looked at once, in the first
    // cycle, and counts as a cut: an interrupt asked for as an
    // instruction ends is seen before the next one starts.
    reg         d_st_rdy_c, dma_req_c, irq_c;
    reg  [23:0] dma_addr_c;
    reg  [7:0]  slow_c, vec_h;
    always @(posedge clk) begin
        if (ph0 || rst) begin
            d_st_rdy_c <= d_st_rdy;
            dma_req_c  <= dma_req && !dma_ack_c;
            dma_addr_c <= dma_addr;
            slow_c     <= slow;
            irq_c      <= irq;
        end
        if (inta)
            vec_h <= irq_vec;       // (given in the cycle of the pulse)
    end
    wire [7:0]  irq_vec_c = inta ? irq_vec : vec_h;
''' + s[a:]

# ---- every register of design B: written at the tick ----
n = s.count("always @(posedge clk)")
k = s.index("    wire [7:0]  irq_vec_c = inta ? irq_vec : vec_h;")
head, tail = s[:k], s[k:]
m = tail.count("always @(posedge clk)")
tail = tail.replace("always @(posedge clk)", "always @(posedge clk) if (tick || rst)")
s = head + tail
print("clocked blocks gated:", m)
open(dst, "w").write(s)
