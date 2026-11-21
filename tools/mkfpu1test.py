#!/usr/bin/env python3
"""tests/prog/fpu1test.asm from tests/prog/fputest.asm: the same program
without the step the lockstep bench has no hardware for (interrupt
13).  usage: mkfpu1test.py fputest.asm > fpu1test.asm"""
import sys
s = open(sys.argv[1]).read()
def cut(a, b):
    return s[s.index(a):s.index(b)]
head = s[:s.index("; ---- 7: the stack's faults ----")]
head = head.replace("""; Mach86 test program: the floating-point unit (docs/fpu.md). A
; bootable diskette image, for make -C sim check-fpu: on the model with
; its FPU (m86pc -fpu).""", """; Mach86 test program: the floating-point unit in RTL
; (rtl/cpu/m86_fpu.v, docs/fpu.md). MADE FROM fputest.asm by
; tools/mkfpu1test.py: do not edit. A bootable diskette image, for
; make -C sim check-fpu-rtl: design C with its FPU in lockstep with the
; model (m86pc -fpu).""")
sys.stdout.write(head
    + cut("; ---- 7: the stack's faults ----", "; ---- 9: an exception that is not masked")
    + cut("; ---- 10: and the processor's own way", "        mov     si, m_ok\n        jmp     print")
    + s[s.index("        mov     si, m_ok\n        jmp     print"):])
