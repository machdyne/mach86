#!/usr/bin/env python3
"""The transcendental functions' constants (sim/m86fconst.h) as a Verilog
function, for rtl/cpu/m86_fpu.v: it replaces the text between the lines
"// BEGIN constants" and "// END constants" there.

usage: mkfpuconst_v.py sim/m86fconst.h rtl/cpu/m86_fpu.v
"""
import re, sys
h = open(sys.argv[1]).read()
def one(name):
    m = re.search(r"\b%s = \{ 0x([0-9A-F]+)ull, 0x([0-9A-F]+) \}" % name, h)
    return int(m.group(2), 16) << 64 | int(m.group(1), 16)
def arr(name):
    m = re.search(r"\b%s\[\d+\] = \{(.*?)\};" % name, h, re.S)
    return [int(se, 16) << 64 | int(mm, 16) for mm, se in re.findall(r"0x([0-9A-F]+)ull, 0x([0-9A-F]+)", m.group(1))]
names = ["K_2OPI", "K_PIO2_1", "K_PIO2_2", "K_PIO2_3", "K_LN2", "K_L2E", "K_PI_HI", "K_PI_LO",
         "K_PIO2_HI", "K_PIO2_LO", "K_PIO4_HI", "K_PIO4_LO", "K_3PIO4_HI", "K_3PIO4_LO"]
vals = {0: (0x3FFF << 64 | 1 << 63, "one"), 1: (0, "zero"), 2: (0x4000 << 64 | 1 << 63, "two"),
        3: (0x4003 << 64 | 1 << 63, "sixteen")}
for i, n in enumerate(names):
    vals[4 + i] = (one(n), n)
for base, n in ((20, "K_SIN"), (30, "K_COS"), (40, "K_EXP"), (62, "K_LOG"), (76, "K_ATAN"), (84, "K_ATANT")):
    for i, v in enumerate(arr(n)):
        vals[base + i] = (v, "%s[%d]" % (n, i))
out = ["    // BEGIN constants (made by tools/mkfpuconst_v.py from sim/m86fconst.h: do not edit)",
       "    function [79:0] kconst(input [6:0] i);", "        case (i)"]
for i in sorted(vals):
    out.append("        7'd%d: kconst = 80'h%020X;   // %s" % (i, vals[i][0], vals[i][1]))
out += ["        default: kconst = 80'd0;", "        endcase", "    endfunction", "    // END constants"]
p = sys.argv[2]
s = open(p).read()
a = s.index("    // BEGIN constants"); b = s.index("    // END constants") + len("    // END constants")
open(p, "w").write(s[:a] + "\n".join(out) + s[b:])
