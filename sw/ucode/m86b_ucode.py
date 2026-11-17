#!/usr/bin/env python3
"""Microcode for Mach86 CPU design B, and its assembler.

usage: m86b_ucode.py OUTDIR      writes ucode.hex and attr.hex

Sources: I386-PRM ch. 17 (what each instruction does), ch. 9 and 14
(interrupts in real mode). The word formats are described at the top
of rtl/cpu/m86b_core.v.

The microcode is written below as Python calls. `u(...)` is one ROM
word; `at(...)` says which opcodes start there.
"""
import sys

# Registers.
EAX, ECX, EDX, EBX, ESP, EBP, ESI, EDI = range(8)
ZERO, T1, T2, T3, T4, T5, T6, T7 = range(8, 16)
ES, CS, SS, DS, FS, GS, FLAT, IO = range(8)

# Units.
ALU, ALUI, LOAD, LOADOP, STORE, SHIFT, MUL, SPEC = range(8)
# ALU operations.
ADD, OR, ADC, SBB, AND, SUB, XOR, CMP, INC, DEC, SEXT, SIGN, RCR1 = range(13)
# Microcode jump conditions on the zero latch (others are x86 conditions).
UZ, UNZ = 16, 17
# ... and on the REP prefix.
UREP, UNREP, UREPNE, UNREPNE = 32, 33, 34, 35
# ... and on this uop's register A not being one: a count that is
# being decremented does not reach zero.
UA_NOT1 = 64
# ... on CR0.PE, and on whether what is being delivered is a fault.
UPE, UNPE, UFLT, UNFLT = 128, 129, 256, 257
# Special operations.
NOP, SETSEG, READ, WRFL, FLBIT, RAISE, CHKCS, LEA = range(8)
# Things READ reads.
R_EIP, R_FLAGS, R_SEGSEL, R_NEXT, R_IMM, R_DISP, R_VEC, R_ESP0 = range(8)
# ... of the system registers: where the descriptor of the selector
# being loaded is, CR0, the two table registers' limits and bases.
R_DESC, R_CR0, R_GDTL, R_GDTB, R_IDTL, R_IDTB, R_CR2, R_CR3 = range(8, 16)
# A NOP with one of these in cc writes register A to a system register.
W_CR0, W_GDTL, W_GDTB, W_IDTL, W_IDTB, W_CR2, W_CR3, W_CLTS, W_MSW = range(1, 10)
# What a STORE stores (its aop): register C, the immediate, or what READ
# reads (B says what; for a segment selector, C says which segment).
ST_REG, ST_IMM, ST_READ = range(3)
# Jumps of br=7, by cc: to register C; relative unless A is one;
# relative if A is zero.
J_REG, J_NOT1, J_ZERO = range(3)
# cc bits of a memory access with aupd: move A as a string instruction
# does; a STORE at A that then adds the size to A.
STR, UP = 1, 8
# Operand selectors.
LIT, RM, REG, OPR = range(4)
ISIZE = 3                       # the instruction's operand size
# Immediate kinds.
I_NONE, I_8, I_Z, I_16, I_S8, I_FAR, I_OFFS, I_ENTER = range(8)

words = []
labels = {}
attr = [0] * 1024


def u(a=0, b=0, c=0, d=None, size=2, unit=ALU, aop=0, fm=0, seg=0, scale=0,
      a16=0, disp=0, aupd=0, br=0, cc=0, idx=0, k=0, jmp=None, ucc=None,
      end=0, usek=0, sela=LIT, selb=LIT, selc=LIT, seld=LIT, ea=0, selaop=0,
      selcc=0, hi=0, selseg=0, asz=0, a16as=0, ssz=0):
    """One microcode ROM word."""
    assert not (usek and jmp is not None), 'k is the constant or the target'
    d_we = 0 if d is None else 1
    # An access to the stack: the offset is SP or ESP, as the stack
    # segment says, and so is a size given with ssz.
    a16ss = 0
    if seg == SS and a16 and not selseg and unit in (LOAD, LOADOP, STORE):
        a16, a16ss = 0, 1
    w = (a | b << 4 | c << 8 | (d or 0) << 12 | d_we << 16 | size << 17
         | hi << 19
         | unit << 23 | aop << 26 | fm << 30 | seg << 32 | scale << 35
         | a16 << 37 | disp << 38 | aupd << 39 | br << 40 | cc << 43
         | idx << 47)
    words.append(dict(w=w, k=k, jmp=jmp, ucc=ucc, end=end, usek=usek,
                      sel=(sela | selb << 2 | selc << 4 | seld << 6 | ea << 8
                           | selaop << 9 | selcc << 11 | selseg << 12
                           | asz << 14 | a16as << 16),
                      ext=a16ss | ssz << 1))


def label(name):
    labels[name] = len(words)


def org(addr):
    while len(words) < addr:
        u(unit=SPEC, aop=NOP, end=1)


def at(opcodes, modrm=0, imm=I_NONE, byte=0, mem=None, group=0, rel=0,
       map0f=0, lock=0):
    """The words that follow are the microcode of these opcodes.

    mem: None for instructions without ModRM; False for the register
    form, True for the memory form.
    """
    entry = len(words)
    if byte is PAIR:
        (lo, hi), = opcodes
        at([lo], modrm, imm, 1, mem, group, rel, map0f, lock)
        at([hi], modrm, imm, 0, mem, group, rel, map0f, lock)
        return
    for op in opcodes:
        forms = [0, 1] if mem is None else [1 if mem else 0]
        for form in forms:
            attr[form << 9 | map0f << 8 | op] = (
                entry | modrm << 10 | imm << 11 | byte << 14 | 1 << 15
                | group << 16 | (rel | lock) << 17)


def invalid(n=1):
    """n words that raise the invalid-opcode fault."""
    for _ in range(n):
        u(unit=SPEC, aop=RAISE, usek=1, k=6, end=1)


PAIR = 'pair'


def pair(lo):
    """An opcode pair whose byte and word forms share their microcode."""
    return [((lo, lo + 1), PAIR)]


def both(lo):
    """An opcode pair: byte form, then word form."""
    return [(lo, 1), (lo + 1, 0)]


# ---------------------------------------------------------------------
# Fixed entry points.

# Word 0: reset.
u(unit=SPEC, aop=NOP, jmp='reset')

org(4)
label('irq')
# A hardware interrupt: the vector arrives while the first word waits.
u(unit=SPEC, aop=NOP)
u(unit=SPEC, aop=READ, b=R_VEC, d=T1)
u(unit=SPEC, aop=READ, b=R_EIP, d=T4, jmp='int')

org(8)
label('fault')
# A fault: put ESP back, then deliver the interrupt in T1 with the
# faulting instruction's address as the return address.
u(unit=SPEC, aop=READ, b=R_ESP0, d=ESP)
u(unit=SPEC, aop=READ, b=R_VEC, d=T1)
u(unit=SPEC, aop=READ, b=R_EIP, d=T4)
label('int')
# Deliver interrupt T1, returning to T4 (real mode): the new IP and CS
# from the vector, then flags, CS and the return address on the stack.
u(unit=SPEC, aop=READ, b=R_IDTB, d=T5,                  # the table is where LIDT put it
  jmp='int_pm', ucc=UPE)
u(unit=LOAD, a=T5, b=T1, idx=1, scale=2, seg=FLAT, d=T2, size=1)
u(unit=LOAD, a=T5, b=T1, idx=1, scale=2, disp=1, usek=1, k=2, seg=FLAT,
  d=T3, size=1)
u(unit=STORE, a=ESP, aop=ST_READ, b=R_FLAGS, seg=SS, a16=1, aupd=1, size=1)
u(unit=STORE, a=ESP, aop=ST_READ, b=R_SEGSEL, c=CS, seg=SS, a16=1, aupd=1,
  size=1)
u(unit=STORE, a=ESP, c=T4, seg=SS, a16=1, aupd=1, size=1)
u(unit=SPEC, aop=FLBIT, cc=8)                           # IF and TF off
u(unit=SPEC, aop=SETSEG, a=T3, seg=CS)
u(unit=SPEC, aop=NOP, c=T2, size=1, br=7, cc=J_REG, end=1)

org(24)
label('pmseg')
# A segment load in protected mode: the core sends every SETSEG here
# when CR0.PE is set (rtl/cpu/m86b_core.v, UC_PMSEG). The descriptor's
# two halves are read from the GDT; the first is kept by the core, the
# second is in T7 for the SETSEG that ends this, which does the load
# and goes back to where the first SETSEG would have gone on. T7 is
# used by nothing that loads a segment.
u(unit=SPEC, aop=READ, b=R_DESC, d=T7)
u(unit=LOAD, a=T7, seg=FLAT, size=2)
u(unit=LOAD, a=T7, disp=1, usek=1, k=4, seg=FLAT, d=T7, size=2)
u(unit=SPEC, aop=SETSEG, a=T7)
assert len(words) <= 32

org(32)

label('reset')
# Registers as a 386 leaves them: zero, but for the processor
# signature in EDX, and CS:IP = F000:FFF0. (The flags are reset in
# hardware.)
for r in (EAX, ECX, EBX, ESP, EBP, ESI, EDI):
    u(unit=ALU, aop=OR, a=ZERO, b=ZERO, d=r)
u(unit=ALUI, aop=OR, a=ZERO, d=EDX, usek=1, k=0x108)    # 0420h (a 486SX), in three steps
u(unit=ALU, aop=ADD, a=EDX, b=EDX, d=EDX)
u(unit=ALU, aop=ADD, a=EDX, b=EDX, d=EDX)
for seg in (ES, SS, DS, FS, GS):
    u(unit=SPEC, aop=SETSEG, a=ZERO, seg=seg, size=1)
u(unit=ALUI, aop=OR, a=ZERO, d=T1, usek=1, k=-64)       # F000h, in two steps
u(unit=SHIFT, aop=4, a=T1, d=T1, usek=1, k=6)
u(unit=SPEC, aop=SETSEG, a=T1, seg=CS, size=1)
u(unit=ALUI, aop=OR, a=ZERO, d=T2, usek=1, k=-16)       # FFF0h
u(unit=ALU, aop=OR, a=ZERO, b=T2, d=T2, size=1, br=3, a16=1, end=1)

# ---------------------------------------------------------------------
# MOV

for op, byte in pair(0x88):                             # MOV r/m, r
    at([op], modrm=1, byte=byte, mem=False)
    u(unit=ALU, aop=OR, a=ZERO, selb=REG, seld=RM, d=0, size=ISIZE, end=1)
    at([op], modrm=1, byte=byte, mem=True)
    u(unit=STORE, ea=1, selc=REG, size=ISIZE, end=1)
for op, byte in pair(0x8A):                             # MOV r, r/m
    at([op], modrm=1, byte=byte, mem=False)
    u(unit=ALU, aop=OR, a=ZERO, selb=RM, seld=REG, d=0, size=ISIZE, end=1)
    at([op], modrm=1, byte=byte, mem=True)
    u(unit=LOAD, ea=1, seld=REG, d=0, size=ISIZE, end=1)
at(range(0xB0, 0xB8), imm=I_8, byte=1)                  # MOV r8, imm
u(unit=ALUI, aop=OR, a=ZERO, seld=OPR, d=0, size=ISIZE, end=1)
at(range(0xB8, 0xC0), imm=I_Z)                          # MOV r, imm
u(unit=ALUI, aop=OR, a=ZERO, seld=OPR, d=0, size=ISIZE, end=1)
for op, byte in both(0xC6):                             # MOV r/m, imm
    imm = I_8 if byte else I_Z
    # (Only /0 exists; the decoder refuses the rest, and POP r/m's
    # and the byte INC/DEC group's, so they need no words here.)
    at([op], modrm=1, imm=imm, byte=byte, mem=False)
    u(unit=ALUI, aop=OR, a=ZERO, seld=RM, d=0, size=ISIZE, end=1)
    at([op], modrm=1, imm=imm, byte=byte, mem=True)
    u(unit=STORE, ea=1, aop=ST_IMM, size=ISIZE, end=1)
label('mov_mi')
u(unit=STORE, ea=1, c=T1, size=ISIZE, end=1)

# LEA
at([0x8D], modrm=1, mem=False)
invalid(1)
at([0x8D], modrm=1, mem=True)
u(unit=SPEC, aop=LEA, ea=1, seld=REG, d=0, size=ISIZE, end=1)

# ---------------------------------------------------------------------
# ADD OR ADC SBB AND SUB XOR CMP

for base in range(0x00, 0x40, 8):
    is_cmp = base == 0x38
    for op, byte in pair(base):                         # r/m, r
        at([op], modrm=1, byte=byte, mem=False)
        u(unit=ALU, selaop=1, sela=RM, selb=REG, seld=RM, d=0, size=ISIZE,
          fm=1, end=1)
        at([op], modrm=1, byte=byte, mem=True, lock=0 if is_cmp else 1)
        if is_cmp:
            u(unit=LOADOP, selaop=1, ea=1, selc=REG, cc=1, size=ISIZE, fm=1,
              end=1)
        else:
            u(unit=LOADOP, selaop=1, ea=1, selc=REG, cc=1, d=T1, size=ISIZE,
              fm=1)
            u(unit=STORE, cc=2, c=T1, size=ISIZE, end=1)
    for op, byte in pair(base + 2):                     # r, r/m
        at([op], modrm=1, byte=byte, mem=False)
        u(unit=ALU, selaop=1, sela=REG, selb=RM, seld=REG, d=0, size=ISIZE,
          fm=1, end=1)
        at([op], modrm=1, byte=byte, mem=True)
        u(unit=LOADOP, selaop=1, ea=1, selc=REG, seld=REG, d=0, size=ISIZE,
          fm=1, end=1)
    at([base + 4], imm=I_8, byte=1)                     # AL, imm
    u(unit=ALUI, selaop=1, a=EAX, d=EAX, size=ISIZE, fm=1, end=1)
    at([base + 5], imm=I_Z)                             # eAX, imm
    u(unit=ALUI, selaop=1, a=EAX, d=EAX, size=ISIZE, fm=1, end=1)

for op, byte, imm in [(0x80, 1, I_8), (0x81, 0, I_Z), (0x82, 1, I_8),
                      (0x83, 0, I_S8)]:                 # r/m, imm
    at([op], modrm=1, imm=imm, byte=byte, mem=False)
    u(unit=ALUI, selaop=2, sela=RM, seld=RM, d=0, size=ISIZE, fm=1, end=1)
    at([op], modrm=1, imm=imm, byte=byte, mem=True, lock=1)
    u(unit=LOAD, ea=1, d=T1, size=ISIZE)
    u(unit=ALUI, selaop=2, a=T1, d=T1, size=ISIZE, fm=1)
    u(unit=STORE, cc=2, c=T1, size=ISIZE, end=1)

for op, byte in pair(0x84):                             # TEST r/m, r
    at([op], modrm=1, byte=byte, mem=False)
    u(unit=ALU, aop=AND, sela=RM, selb=REG, size=ISIZE, fm=1, end=1)
    at([op], modrm=1, byte=byte, mem=True)
    u(unit=LOADOP, aop=AND, ea=1, selc=REG, size=ISIZE, fm=1, end=1)
at([0xA8], imm=I_8, byte=1)                             # TEST AL, imm
u(unit=ALUI, aop=AND, a=EAX, size=ISIZE, fm=1, end=1)
at([0xA9], imm=I_Z)
u(unit=ALUI, aop=AND, a=EAX, size=ISIZE, fm=1, end=1)

# INC, DEC register
at(range(0x40, 0x48))
u(unit=ALU, aop=INC, sela=OPR, seld=OPR, d=0, size=ISIZE, fm=2, end=1)
at(range(0x48, 0x50))
u(unit=ALU, aop=DEC, sela=OPR, seld=OPR, d=0, size=ISIZE, fm=2, end=1)

# ---------------------------------------------------------------------
# Stack

at(range(0x50, 0x58))                                   # PUSH r
u(unit=STORE, a=ESP, selc=OPR, seg=SS, a16=1, aupd=1, size=ISIZE, end=1)
at(range(0x58, 0x60))                                   # POP r
u(unit=LOAD, a=ESP, seg=SS, a16=1, aupd=1, seld=OPR, d=0, size=ISIZE, end=1)

# ---------------------------------------------------------------------
# Control transfer

at(range(0x70, 0x80), imm=I_S8, rel=1)                  # Jcc short
u(unit=SPEC, aop=NOP, br=1, selcc=1, end=1)
at([0xEB], imm=I_S8, rel=1)                             # JMP short
u(unit=SPEC, aop=NOP, br=2, end=1)
at([0xE9], imm=I_Z, rel=1)                              # JMP near
u(unit=SPEC, aop=NOP, br=2, end=1)
at([0xE8], imm=I_Z, rel=1)                              # CALL near
# The return address is stored and the jump made in one step.
u(unit=STORE, a=ESP, aop=ST_READ, b=R_NEXT, seg=SS, a16=1, aupd=1,
  size=ISIZE, br=2, end=1)
at([0xC3])                                              # RET near
u(unit=LOAD, a=ESP, seg=SS, a16=1, aupd=1, d=T1, size=ISIZE)
u(unit=SPEC, aop=NOP, c=T1, size=ISIZE, br=7, cc=J_REG, end=1)

# ---------------------------------------------------------------------
# Small things

# ---------------------------------------------------------------------
# Segment registers

SEG_REG, SEG_OP = 1, 2          # selseg: ModRM reg, opcode bits 5:3
H_A, H_B, H_D, H_C = 1, 2, 4, 8  # hi: which register fields are AH-style
W16 = 4                         # cc for a memory uop: 16-bit access

at([0x8C], modrm=1, mem=False, group=1)                 # MOV r, sreg
for r in range(8):
    if r < 6:
        u(unit=SPEC, aop=READ, b=R_SEGSEL, selseg=SEG_REG, seld=RM, d=0,
          size=ISIZE, end=1)
    else:
        invalid()
at([0x8C], modrm=1, mem=True, group=1)                  # MOV m16, sreg
for r in range(8):
    if r < 6:
        u(unit=SPEC, aop=READ, b=R_SEGSEL, selseg=SEG_REG, d=T1,
          jmp='mov_m16')
    else:
        invalid()
label('mov_m16')
u(unit=STORE, ea=1, c=T1, size=1, end=1)
at([0x8E], modrm=1, mem=False, group=1)                 # MOV sreg, r
for r in range(8):
    if r < 6 and r != CS:
        u(unit=SPEC, aop=SETSEG, sela=RM, size=1, selseg=SEG_REG, end=1)
    else:
        invalid()
at([0x8E], modrm=1, mem=True, group=1)                  # MOV sreg, m16
for r in range(8):
    if r < 6 and r != CS:
        u(unit=LOAD, ea=1, d=T1, size=1, jmp='setseg_t1')
    else:
        invalid()
label('setseg_t1')
u(unit=SPEC, aop=SETSEG, a=T1, size=1, selseg=SEG_REG, end=1)

for ops, m in [([0x06, 0x0E, 0x16, 0x1E], 0), ([0xA0, 0xA8], 1)]:
    for op in ops:                                      # PUSH sreg
        at([op], map0f=m)
        u(unit=STORE, a=ESP, aop=ST_READ, b=R_SEGSEL, c=(op >> 3) & 7,
          seg=SS, a16=1, aupd=1, size=ISIZE, cc=W16, end=1)
for ops, m in [([0x07, 0x17, 0x1F], 0), ([0xA1, 0xA9], 1)]:
    at(ops, map0f=m)                                    # POP sreg
    u(unit=LOAD, a=ESP, seg=SS, a16=1, aupd=1, d=T1, size=ISIZE, cc=W16)
    u(unit=SPEC, aop=SETSEG, a=T1, size=1, selseg=SEG_OP, end=1)

# ---------------------------------------------------------------------
# Flags register

at([0x9C])                                              # PUSHF
u(unit=STORE, a=ESP, aop=ST_READ, b=R_FLAGS, seg=SS, a16=1, aupd=1,
  size=ISIZE, end=1)
at([0x9D])                                              # POPF
u(unit=LOAD, a=ESP, seg=SS, a16=1, aupd=1, d=T1, size=ISIZE)
u(unit=SPEC, aop=WRFL, a=T1, size=ISIZE, usek=1, k=-1, end=1)
at([0x9E])                                              # SAHF
u(unit=SPEC, aop=WRFL, a=EAX, hi=H_A, size=0, usek=1, k=0xD5, end=1)
at([0x9F])                                              # LAHF
u(unit=SPEC, aop=READ, b=R_FLAGS, d=EAX, hi=H_D, size=0, end=1)

# ---------------------------------------------------------------------
# XCHG, sign extension, moves to and from a bare offset

for op, byte in pair(0x86):
    at([op], modrm=1, byte=byte, mem=False)
    u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=ISIZE)
    u(unit=ALU, aop=OR, a=ZERO, selb=REG, seld=RM, d=0, size=ISIZE)
    u(unit=ALU, aop=OR, a=ZERO, b=T1, seld=REG, d=0, size=ISIZE, end=1)
    at([op], modrm=1, byte=byte, mem=True, lock=1)
    u(unit=LOAD, ea=1, d=T1, size=ISIZE)
    u(unit=STORE, cc=2, selc=REG, size=ISIZE)
    u(unit=ALU, aop=OR, a=ZERO, b=T1, seld=REG, d=0, size=ISIZE, end=1)
at(range(0x91, 0x98))                                   # XCHG eAX, r
u(unit=ALU, aop=OR, a=ZERO, b=EAX, d=T1, size=ISIZE)
u(unit=ALU, aop=OR, a=ZERO, selb=OPR, d=EAX, size=ISIZE)
u(unit=ALU, aop=OR, a=ZERO, b=T1, seld=OPR, d=0, size=ISIZE, end=1)

at([0x98])                                              # CBW, CWDE
u(unit=ALU, aop=SEXT, b=EAX, d=EAX, size=ISIZE, end=1)
at([0x99])                                              # CWD, CDQ
u(unit=ALU, aop=SIGN, a=EAX, d=EDX, size=ISIZE, end=1)

at([0xA0], imm=I_OFFS, byte=1)                          # MOV AL, moffs
u(unit=LOAD, ea=1, d=EAX, size=ISIZE, end=1)
at([0xA1], imm=I_OFFS)
u(unit=LOAD, ea=1, d=EAX, size=ISIZE, end=1)
at([0xA2], imm=I_OFFS, byte=1)                          # MOV moffs, AL
u(unit=STORE, ea=1, c=EAX, size=ISIZE, end=1)
at([0xA3], imm=I_OFFS)
u(unit=STORE, ea=1, c=EAX, size=ISIZE, end=1)

# ---------------------------------------------------------------------
# More stack and control transfer

at([0x68], imm=I_Z)                                     # PUSH imm
u(unit=STORE, a=ESP, aop=ST_IMM, seg=SS, a16=1, aupd=1, size=ISIZE, end=1)
at([0x6A], imm=I_S8)
u(unit=STORE, a=ESP, aop=ST_IMM, seg=SS, a16=1, aupd=1, size=ISIZE, end=1)
at([0xC9])                                              # LEAVE
u(unit=ALU, aop=OR, a=ZERO, b=EBP, d=ESP, ssz=1)
u(unit=LOAD, a=ESP, seg=SS, a16=1, aupd=1, d=EBP, size=ISIZE, end=1)
at([0xC2], imm=I_16)                                    # RET imm16
u(unit=LOAD, a=ESP, seg=SS, a16=1, aupd=1, d=T1, size=ISIZE)
u(unit=ALUI, aop=ADD, a=ESP, d=ESP, ssz=1)
u(unit=SPEC, aop=NOP, c=T1, size=ISIZE, br=7, cc=J_REG, end=1)

at(range(0x80, 0x90), imm=I_Z, rel=1, map0f=1)          # Jcc near
u(unit=SPEC, aop=NOP, br=1, selcc=1, end=1)

Z, NZ = 4, 5                                            # x86 conditions
at([0xE2], imm=I_S8, rel=1)                             # LOOP
# One step: the jump is taken unless the count is one before.
u(unit=ALU, aop=DEC, a=ECX, d=ECX, size=ISIZE, asz=1, br=7, cc=J_NOT1, end=1)
at([0xE1], imm=I_S8, rel=1)                             # LOOPE
u(unit=ALU, aop=DEC, a=ECX, d=ECX, size=ISIZE, asz=1)
u(unit=SPEC, aop=NOP, jmp='no_jump', ucc=NZ)
u(unit=SPEC, aop=NOP, br=5, end=1)
at([0xE0], imm=I_S8, rel=1)                             # LOOPNE
u(unit=ALU, aop=DEC, a=ECX, d=ECX, size=ISIZE, asz=1)
u(unit=SPEC, aop=NOP, jmp='no_jump', ucc=Z)
u(unit=SPEC, aop=NOP, br=5, end=1)
at([0xE3], imm=I_S8, rel=1)                             # JCXZ
u(unit=SPEC, aop=NOP, a=ECX, size=ISIZE, asz=1, br=7, cc=J_ZERO, end=1)
label('no_jump')
u(unit=SPEC, aop=NOP, end=1)

# ---------------------------------------------------------------------
# Far transfers and interrupts (real mode)

SEG_EA = 3                      # selseg: the ModRM operand's segment


def push(reg, **kw):
    u(unit=STORE, a=ESP, c=reg, seg=SS, a16=1, aupd=1, size=ISIZE, **kw)


def pop(reg, **kw):
    u(unit=LOAD, a=ESP, seg=SS, a16=1, aupd=1, d=reg, size=ISIZE, **kw)


def far_pointer_from_memory():
    """T2 = offset, T3 = selector, from the operand whose address is in T5."""
    u(unit=LOAD, a=T5, selseg=SEG_EA, aupd=1, d=T2, size=ISIZE)
    u(unit=LOAD, a=T5, selseg=SEG_EA, d=T3, size=1)


label('farjmp')
# Jump to T3:T2. The offset is checked before CS changes.
u(unit=ALU, aop=OR, a=ZERO, b=T2, d=T2, size=ISIZE)
u(unit=SPEC, aop=CHKCS, a=T2, size=ISIZE)
u(unit=SPEC, aop=SETSEG, a=T3, seg=CS, size=1)
u(unit=ALU, aop=OR, a=ZERO, b=T2, d=T2, br=3, end=1)
label('farcall')
u(unit=SPEC, aop=READ, b=R_SEGSEL, seg=CS, d=T4)
push(T4)
u(unit=SPEC, aop=READ, b=R_NEXT, d=T4)
push(T4, jmp='farjmp')
label('jmpf_m')
far_pointer_from_memory()
u(unit=SPEC, aop=NOP, jmp='farjmp')
label('callf_m')
far_pointer_from_memory()
u(unit=SPEC, aop=NOP, jmp='farcall')

at([0xEA], imm=I_FAR)                                   # JMP far
u(unit=SPEC, aop=READ, b=R_IMM, d=T2)
u(unit=SPEC, aop=READ, b=R_DISP, d=T3, jmp='farjmp')
at([0x9A], imm=I_FAR)                                   # CALL far
u(unit=SPEC, aop=READ, b=R_IMM, d=T2)
u(unit=SPEC, aop=READ, b=R_DISP, d=T3, jmp='farcall')
at([0xCB])                                              # RETF
pop(T2)
pop(T3, jmp='farjmp')
at([0xCA], imm=I_16)                                    # RETF imm16
pop(T2)
pop(T3)
u(unit=ALUI, aop=ADD, a=ESP, d=ESP, ssz=1, jmp='farjmp')
at([0xCF])                                              # IRET
pop(T2)
pop(T3)
pop(T6)
u(unit=SPEC, aop=CHKCS, a=T2, size=ISIZE)
u(unit=SPEC, aop=SETSEG, a=T3, seg=CS, size=1)
u(unit=SPEC, aop=WRFL, a=T6, size=ISIZE, usek=1, k=-1)
u(unit=SPEC, aop=NOP, c=T2, size=ISIZE, br=7, cc=J_REG, end=1)

at([0xCD], imm=I_8)                                     # INT n
u(unit=SPEC, aop=READ, b=R_NEXT, d=T4)
u(unit=ALUI, aop=OR, a=ZERO, d=T1, jmp='int')
at([0xCC])                                              # INT3
u(unit=SPEC, aop=READ, b=R_NEXT, d=T4)
u(unit=ALUI, aop=OR, a=ZERO, d=T1, usek=1, k=3)     # k is not free for a jump
u(unit=SPEC, aop=NOP, jmp='int')
at([0xCE])                                              # INTO
u(unit=SPEC, aop=READ, b=R_NEXT, d=T4)
u(unit=SPEC, aop=NOP, jmp='no_jump', ucc=1)
u(unit=ALUI, aop=OR, a=ZERO, d=T1, usek=1, k=4)
u(unit=SPEC, aop=NOP, jmp='int')

for op, seg, m in [(0xC4, ES, 0), (0xC5, DS, 0), (0xB2, SS, 1), (0xB4, FS, 1),
                   (0xB5, GS, 1)]:                      # LES LDS LSS LFS LGS
    at([op], modrm=1, mem=False, map0f=m)
    invalid()
    at([op], modrm=1, mem=True, map0f=m)
    u(unit=SPEC, aop=LEA, ea=1, d=T5)
    far_pointer_from_memory()
    u(unit=SPEC, aop=SETSEG, a=T3, seg=seg, size=1)
    u(unit=ALU, aop=OR, a=ZERO, b=T2, seld=REG, d=0, size=ISIZE, end=1)

# ---------------------------------------------------------------------
# Groups FE and FF, and POP r/m

label('call_t2')
u(unit=STORE, a=ESP, aop=ST_READ, b=R_NEXT, c=T2, seg=SS, a16=1, aupd=1,
  size=ISIZE, br=7, cc=J_REG, end=1)
label('jmp_t2')
u(unit=SPEC, aop=NOP, c=T2, size=ISIZE, br=7, cc=J_REG, end=1)
label('inc_m')
u(unit=ALU, aop=INC, a=T1, d=T1, size=ISIZE, fm=2)
u(unit=STORE, cc=2, c=T1, size=ISIZE, end=1)
label('dec_m')
u(unit=ALU, aop=DEC, a=T1, d=T1, size=ISIZE, fm=2)
u(unit=STORE, cc=2, c=T1, size=ISIZE, end=1)
label('push_t1')
push(T1, end=1)
label('pop_m')
u(unit=STORE, ea=1, c=T1, size=ISIZE, end=1)

for op, byte in both(0xFE):
    at([op], modrm=1, byte=byte, mem=False, group=1)
    u(unit=ALU, aop=INC, sela=RM, seld=RM, d=0, size=ISIZE, fm=2, end=1)
    u(unit=ALU, aop=DEC, sela=RM, seld=RM, d=0, size=ISIZE, fm=2, end=1)
    if not byte:
        u(unit=STORE, a=ESP, aop=ST_READ, b=R_NEXT, selc=RM, seg=SS, a16=1,
          aupd=1, size=ISIZE, br=7, cc=J_REG, end=1)
        invalid()
        u(unit=SPEC, aop=NOP, selc=RM, size=ISIZE, br=7, cc=J_REG, end=1)
        invalid()
        u(unit=STORE, a=ESP, selc=RM, seg=SS, a16=1, aupd=1, size=ISIZE, end=1)
        invalid()
    at([op], modrm=1, byte=byte, mem=True, group=1, lock=1)
    u(unit=LOAD, ea=1, d=T1, size=ISIZE, jmp='inc_m')
    u(unit=LOAD, ea=1, d=T1, size=ISIZE, jmp='dec_m')
    if not byte:
        u(unit=LOAD, ea=1, d=T2, size=ISIZE, jmp='call_t2')
        u(unit=SPEC, aop=LEA, ea=1, d=T5, jmp='callf_m')
        u(unit=LOAD, ea=1, d=T2, size=ISIZE, jmp='jmp_t2')
        u(unit=SPEC, aop=LEA, ea=1, d=T5, jmp='jmpf_m')
        u(unit=LOAD, ea=1, d=T1, size=ISIZE, jmp='push_t1')
        invalid()

at([0x8F], modrm=1, mem=False)                          # POP r/m
u(unit=LOAD, a=ESP, seg=SS, a16=1, aupd=1, seld=RM, d=0, size=ISIZE, end=1)
at([0x8F], modrm=1, mem=True)
# The address is formed after the stack pointer has moved.
u(unit=LOAD, a=ESP, seg=SS, a16=1, aupd=1, d=T1, size=ISIZE, jmp='pop_m')

# ---------------------------------------------------------------------
# MOVZX, MOVSX, XLAT

label('t1_to_reg')
u(unit=ALU, aop=OR, a=ZERO, b=T1, seld=REG, d=0, size=ISIZE, end=1)
label('sx8_to_reg')
u(unit=ALU, aop=SEXT, b=T1, d=T1, size=1)
label('sx16_to_reg')
u(unit=ALU, aop=SEXT, b=T1, d=T1, size=2, jmp='t1_to_reg')

for op, size, tail in [(0xB6, 0, 't1_to_reg'), (0xB7, 1, 't1_to_reg'),
                       (0xBE, 0, 'sx8_to_reg'), (0xBF, 1, 'sx16_to_reg')]:
    at([op], modrm=1, mem=False, map0f=1)
    u(unit=ALU, aop=OR, a=ZERO, b=ZERO, d=T1)
    u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=size, jmp=tail)
    at([op], modrm=1, mem=True, map0f=1)
    u(unit=ALU, aop=OR, a=ZERO, b=ZERO, d=T1)
    u(unit=LOAD, ea=1, d=T1, size=size, jmp=tail)

at([0xD7])                                              # XLAT
u(unit=ALU, aop=OR, a=ZERO, b=ZERO, d=T1)
u(unit=ALU, aop=OR, a=ZERO, b=EAX, d=T1, size=0)
u(unit=LOAD, a=EBX, b=T1, idx=1, selseg=SEG_EA, d=EAX, size=0, end=1)

# ---------------------------------------------------------------------
# Shifts and rotates. The shift kind is the ModRM reg field.

SETCC = 8                       # special operation
BY_IMM, BY_ONE, BY_CL = range(3)


def shift_uop(by, **kw):
    if by == BY_ONE:
        kw.update(usek=1, k=1)
    elif by == BY_CL:
        kw.update(b=ECX, cc=1)
    u(unit=SHIFT, selaop=2, size=ISIZE, fm=1, **kw)


for by in (BY_IMM, BY_ONE, BY_CL):
    label('shift_m%d' % by)
    shift_uop(by, a=T1, d=T1)
    u(unit=STORE, cc=2, c=T1, size=ISIZE, end=1)

# RCL and RCR: one place at a time, T2 counting down. RCL of one place
# is T1 + T1 + carry, which also gives the right carry and overflow.
# The group's own word puts the count in T2 (see below); the operand
# is fetched here.
for r in (2, 3):
    for form in 'rm':
        label('rc%d_%s' % (r, form))
        if form == 'r':
            u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=ISIZE)
        else:
            u(unit=LOAD, ea=1, d=T1, size=ISIZE)
        u(unit=ALUI, aop=AND, a=T2, d=T2, size=0, usek=1, k=31)
        here = len(words)
        u(unit=SPEC, aop=NOP, jmp=here + 3, ucc=UZ)
        u(unit=ALU, aop=DEC, a=T2, d=T2, size=0)
        if r == 2:
            u(unit=ALU, aop=ADC, a=T1, b=T1, d=T1, size=ISIZE, fm=3,
              jmp=here + 1, ucc=UNZ)
        else:
            u(unit=ALU, aop=RCR1, a=T1, d=T1, size=ISIZE, fm=3,
              jmp=here + 1, ucc=UNZ)
        if form == 'r':
            u(unit=ALU, aop=OR, a=ZERO, b=T1, seld=RM, d=0, size=ISIZE,
              end=1)
        else:
            u(unit=STORE, cc=2, c=T1, size=ISIZE, end=1)


def rc_count(by, target):
    """The count of an RCL or RCR to T2, and on to the routine."""
    if by == BY_IMM:
        u(unit=ALUI, aop=OR, a=ZERO, d=T2, size=0, jmp=target)
    elif by == BY_ONE:
        u(unit=ALU, aop=INC, a=ZERO, d=T2, size=0, jmp=target)
    else:
        u(unit=ALU, aop=OR, a=ZERO, b=ECX, d=T2, size=0, jmp=target)


for lo, by, imm in [(0xC0, BY_IMM, I_8), (0xD0, BY_ONE, I_NONE),
                    (0xD2, BY_CL, I_NONE)]:
    for op, byte in pair(lo):
        at([op], modrm=1, imm=imm, byte=byte, mem=False, group=1)
        for r in range(8):
            if r in (2, 3):
                rc_count(by, 'rc%d_r' % r)
            else:
                shift_uop(by, sela=RM, seld=RM, d=0, end=1)
        at([op], modrm=1, imm=imm, byte=byte, mem=True, group=1)
        for r in range(8):
            if r in (2, 3):
                rc_count(by, 'rc%d_m' % r)
            else:
                u(unit=LOAD, ea=1, d=T1, size=ISIZE, jmp='shift_m%d' % by)

at(range(0x90, 0xA0), modrm=1, byte=1, mem=False, map0f=1)   # SETcc
u(unit=SPEC, aop=SETCC, selcc=1, seld=RM, d=0, size=ISIZE, end=1)
at(range(0x90, 0xA0), modrm=1, byte=1, mem=True, map0f=1)
u(unit=SPEC, aop=SETCC, selcc=1, d=T1, size=ISIZE, jmp='mov_mi')

# ---------------------------------------------------------------------
# Multiply, divide, and group F6/F7.

MULHI = 9                       # special: upper half of the last product
UNSIGNED, SIGNED = 0, 1

for name, sign in [('mul', UNSIGNED), ('imul', SIGNED)]:
    label(name + '8')                                   # AX = AL * T1
    u(unit=MUL, aop=sign, a=EAX, b=T1, d=EAX, size=0, fm=1)
    u(unit=SPEC, aop=MULHI, d=EAX, hi=H_D, size=0, end=1)
    label(name)                                         # eDX:eAX = eAX * T1
    u(unit=MUL, aop=sign, a=EAX, b=T1, d=EAX, size=ISIZE, fm=1)
    u(unit=SPEC, aop=MULHI, d=EDX, size=ISIZE, end=1)
label('test_t1')
u(unit=ALUI, aop=AND, a=T1, size=ISIZE, fm=1, end=1)
label('not_m')
u(unit=ALUI, aop=XOR, a=T1, d=T1, size=ISIZE, usek=1, k=-1)
u(unit=STORE, cc=2, c=T1, size=ISIZE, end=1)
label('neg_m')
u(unit=ALU, aop=SUB, a=ZERO, b=T1, d=T1, size=ISIZE, fm=1)
u(unit=STORE, cc=2, c=T1, size=ISIZE, end=1)

# Divide. One routine for all four kinds, a bit of the quotient per
# turn of a loop. T1 divisor, T4:T5 dividend then remainder:quotient,
# T2 bit counter, T7 the flags (the loop uses the carry; DIV changes
# no flags), T3 what kind: bit 0 negate the quotient, bit 1 negate the
# remainder, bit 2 signed, bit 3 byte form, bit 4 AAM.
BITS = 11                       # special: the operand size in bits
DIVGO, DIVQ, DIVR = 13, 14, 15  # special: divide; its quotient; its remainder
SZP = 12                        # special: sign, zero and parity of A
B, AE, S, NS = 2, 3, 8, 9       # x86 conditions


def t(aop, a, b, d, **kw):
    u(unit=ALU, aop=aop, a=a, b=b, d=d, size=ISIZE, **kw)


for name, kind in [('div8', 8), ('div', 0), ('idiv8', 12), ('idiv', 4)]:
    label(name)
    u(unit=ALUI, aop=OR, a=ZERO, d=T3, usek=1, k=kind)
    if kind & 8:
        u(unit=ALU, aop=OR, a=ZERO, b=EAX, hi=H_B, d=T4, size=0)
    else:
        t(OR, ZERO, EDX, T4)
    t(OR, ZERO, EAX, T5, jmp='div_common')

label('div_common')
u(unit=SPEC, aop=READ, b=R_FLAGS, d=T7)
u(unit=ALUI, aop=AND, a=T3, usek=1, k=4)
u(unit=SPEC, aop=NOP, jmp='div_core', ucc=UZ)
# Signed: make both operands positive and remember the signs.
t(OR, T4, T4, None, fm=1)
u(unit=SPEC, aop=NOP, jmp='div_s1', ucc=NS)
t(SUB, ZERO, T5, T5, fm=1)
t(SBB, ZERO, T4, T4)
u(unit=ALUI, aop=OR, a=T3, d=T3, usek=1, k=3)
label('div_s1')
t(OR, T1, T1, None, fm=1)
u(unit=SPEC, aop=NOP, jmp='div_core', ucc=NS)
t(SUB, ZERO, T1, T1)
u(unit=ALUI, aop=XOR, a=T3, d=T3, usek=1, k=1)
label('div_core')
# The quotient must fit: the upper half is below the divisor. This
# also catches a divisor of zero.
t(SUB, T4, T1, None, fm=3)
u(unit=SPEC, aop=BITS, d=T2, size=ISIZE, jmp='div_error', ucc=AE)
# The division itself is the core's: a bit a cycle. T4:T5 by T1 gives
# the quotient in T5 and the remainder in T4.
u(unit=SPEC, aop=DIVGO, a=T4, b=T5, c=T1, size=ISIZE)
u(unit=SPEC, aop=DIVQ, d=T5)
u(unit=SPEC, aop=DIVR, d=T4)
u(unit=ALUI, aop=AND, a=T3, usek=1, k=4)
u(unit=SPEC, aop=NOP, jmp='div_store', ucc=UZ)
# Signed: the quotient's range, then the signs.
u(unit=ALUI, aop=AND, a=T3, usek=1, k=1)
u(unit=SPEC, aop=NOP, jmp='div_posq', ucc=UZ)
t(SUB, ZERO, T5, T5, fm=1)
u(unit=SPEC, aop=NOP, jmp='div_rem', ucc=Z)
u(unit=SPEC, aop=NOP, jmp='div_rem', ucc=S)
u(unit=SPEC, aop=NOP, jmp='div_error')
label('div_posq')
t(OR, T5, T5, None, fm=1)
u(unit=SPEC, aop=NOP, jmp='div_error', ucc=S)
label('div_rem')
u(unit=ALUI, aop=AND, a=T3, usek=1, k=2)
u(unit=SPEC, aop=NOP, jmp='div_store', ucc=UZ)
t(SUB, ZERO, T4, T4)
label('div_store')
u(unit=ALUI, aop=AND, a=T3, usek=1, k=16)
u(unit=SPEC, aop=NOP, jmp='aam_store', ucc=UNZ)
u(unit=ALUI, aop=AND, a=T3, usek=1, k=8)
u(unit=SPEC, aop=NOP, jmp='div_store_w', ucc=UZ)
u(unit=ALU, aop=OR, a=ZERO, b=T5, d=EAX, size=0)
u(unit=ALU, aop=OR, a=ZERO, b=T4, d=EAX, hi=H_D, size=0, jmp='div_done')
label('div_store_w')
t(OR, ZERO, T5, EAX)
t(OR, ZERO, T4, EDX)
label('div_done')
u(unit=SPEC, aop=WRFL, a=T7, usek=1, k=-1, end=1)
label('aam_store')
# AAM: the quotient to AH, the remainder to AL, and its sign, zero and
# parity; the other flags as they were.
u(unit=SPEC, aop=WRFL, a=T7, usek=1, k=-1)
u(unit=ALU, aop=OR, a=ZERO, b=T5, d=EAX, hi=H_D, size=0)
u(unit=ALU, aop=OR, a=ZERO, b=T4, d=EAX, size=0)
u(unit=SPEC, aop=SZP, a=T4, size=0, end=1)
label('div_error')
u(unit=SPEC, aop=WRFL, a=T7, usek=1, k=-1)
u(unit=SPEC, aop=RAISE, usek=1, k=0, end=1)

for op, byte in both(0xF6):
    imm = I_8 if byte else I_Z
    sfx = '8' if byte else ''
    at([op], modrm=1, imm=imm, byte=byte, mem=False, group=1)
    u(unit=ALUI, aop=AND, sela=RM, size=ISIZE, fm=1, end=1)
    u(unit=ALUI, aop=AND, sela=RM, size=ISIZE, fm=1, end=1)
    u(unit=ALUI, aop=XOR, sela=RM, seld=RM, d=0, size=ISIZE, usek=1, k=-1,
      end=1)
    u(unit=ALU, aop=SUB, a=ZERO, selb=RM, seld=RM, d=0, size=ISIZE, fm=1,
      end=1)
    u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=ISIZE, jmp='mul' + sfx)
    u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=ISIZE, jmp='imul' + sfx)
    u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=ISIZE, jmp='div' + sfx)
    u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=ISIZE, jmp='idiv' + sfx)
    at([op], modrm=1, imm=imm, byte=byte, mem=True, group=1, lock=1)
    for tail in ['test_t1', 'test_t1', 'not_m', 'neg_m', 'mul' + sfx,
                 'imul' + sfx, 'div' + sfx, 'idiv' + sfx]:
        u(unit=LOAD, ea=1, d=T1, size=ISIZE, jmp=tail)

at([0xAF], modrm=1, mem=False, map0f=1)                 # IMUL r, r/m
u(unit=MUL, aop=SIGNED, sela=REG, selb=RM, seld=REG, d=0, size=ISIZE, fm=1,
  end=1)
at([0xAF], modrm=1, mem=True, map0f=1)
u(unit=LOAD, ea=1, d=T1, size=ISIZE)
u(unit=MUL, aop=SIGNED, sela=REG, b=T1, seld=REG, d=0, size=ISIZE, fm=1,
  end=1)
for op, imm in [(0x69, I_Z), (0x6B, I_S8)]:             # IMUL r, r/m, imm
    at([op], modrm=1, imm=imm, mem=False)
    u(unit=ALUI, aop=OR, a=ZERO, d=T2, size=ISIZE)
    u(unit=MUL, aop=SIGNED, a=T2, selb=RM, seld=REG, d=0, size=ISIZE, fm=1,
      end=1)
    at([op], modrm=1, imm=imm, mem=True)
    u(unit=LOAD, ea=1, d=T1, size=ISIZE)
    u(unit=ALUI, aop=OR, a=ZERO, d=T2, size=ISIZE)
    u(unit=MUL, aop=SIGNED, a=T1, b=T2, seld=REG, d=0, size=ISIZE, fm=1,
      end=1)

# ---------------------------------------------------------------------
# String instructions. T3 is the step, plus or minus the operand size.
# With a REP prefix the count is checked first, and an element is
# complete, pointers and count, before the next begins.

STEP = 10                       # special: the string step
SRC = dict(unit=LOAD, a=ESI, selseg=SEG_EA, size=ISIZE)
DST = dict(a=EDI, seg=ES, a16as=1, size=ISIZE)
NEXT_SI = dict(unit=ALU, aop=ADD, a=ESI, b=T3, d=ESI, size=ISIZE, asz=1)
NEXT_DI = dict(unit=ALU, aop=ADD, a=EDI, b=T3, d=EDI, size=ISIZE, asz=1)


def string_op(lo, body, compare=False):
    """A string instruction whose pointers are moved by steps of their
    own (T3 holds the step): the compares, and the port forms.

    Layout: the entry is the form without REP; the word after it is
    where the form with REP starts (the core adds one to the entry).
    """
    at([(lo, lo + 1)], byte=PAIR)
    start = len(words)
    n = len(body)
    rep_len = 3 + (n + 7 if compare else n + 2)
    u(unit=SPEC, aop=STEP, d=T3, size=ISIZE, jmp=start + 1 + rep_len)
    # The repeated form.
    u(unit=SPEC, aop=STEP, d=T3, size=ISIZE)
    u(unit=ALU, aop=OR, a=ECX, b=ZERO, size=ISIZE, asz=1)
    done = len(words) + 1 + n + (4 if compare else 1)
    u(unit=SPEC, aop=NOP, jmp=done, ucc=UZ)
    loop = len(words)
    count = dict(unit=ALU, aop=DEC, a=ECX, d=ECX, size=ISIZE, asz=1)
    if compare:
        for kw in body:
            u(**kw)
        u(**count)
        u(unit=SPEC, aop=NOP, jmp=done, ucc=UZ)
        u(unit=SPEC, aop=NOP, jmp=done + 1, ucc=UREPNE)
        u(unit=SPEC, aop=NOP, jmp=loop, ucc=Z)          # REPE: while equal
        assert len(words) == done
        u(unit=SPEC, aop=NOP, end=1)
        u(unit=SPEC, aop=NOP, jmp=loop, ucc=NZ)         # REPNE: while not
        u(unit=SPEC, aop=NOP, end=1)
    else:
        for kw in body[:-1]:
            u(**kw)
        u(**count)
        u(jmp=loop, ucc=UNZ, **body[-1])
        assert len(words) == done
        u(unit=SPEC, aop=NOP, end=1)
    assert len(words) == start + 1 + rep_len, (len(words), start, rep_len)
    # The form without REP.
    for i, kw in enumerate(body):
        u(end=1 if i == n - 1 else 0, **kw)


def string_move(lo, body):
    """MOVS, STOS, LODS: each access moves its own pointer (cc=STR), so
    an element is its accesses and nothing more, and with REP one step
    for the count as well.

    Layout as string_op: the entry, then the form with REP.
    """
    at([(lo, lo + 1)], byte=PAIR)
    n = len(body)
    start = len(words)
    rep_len = n + 4
    # Without REP. A second access follows the form with REP.
    if n == 1:
        u(end=1, **body[0])
    else:
        u(jmp=start + 1 + rep_len, **body[0])
    # With REP: nothing if the count is zero; else the accesses, then
    # the count, which also decides whether to go round. The count
    # comes after the accesses so that one that faults has not changed
    # it.
    u(unit=ALU, aop=OR, a=ECX, b=ZERO, size=ISIZE, asz=1)
    done = len(words) + 1 + n + 1
    u(unit=SPEC, aop=NOP, jmp=done, ucc=UZ)
    loop = len(words)
    for kw in body:
        u(**kw)
    u(unit=ALU, aop=DEC, a=ECX, d=ECX, size=ISIZE, asz=1, jmp=loop,
      ucc=UA_NOT1)
    assert len(words) == done
    u(unit=SPEC, aop=NOP, end=1)
    assert len(words) == start + 1 + rep_len
    for i, kw in enumerate(body[1:]):
        u(end=1 if i == n - 2 else 0, **kw)


SRC_STR = dict(SRC, aupd=1, cc=STR, a16as=1)
DST_STR = dict(DST, unit=STORE, aupd=1, cc=STR)
string_move(0xA4, [dict(SRC_STR, d=T1), dict(DST_STR, c=T1)])        # MOVS
string_move(0xAA, [dict(DST_STR, c=EAX)])                            # STOS
string_move(0xAC, [dict(SRC_STR, d=EAX)])                            # LODS
string_op(0xA6, [dict(SRC, d=T1),                                   # CMPS
                 dict(DST, unit=LOADOP, aop=CMP, c=T1, fm=1),
                 NEXT_SI, NEXT_DI], compare=True)
string_op(0xAE, [dict(DST, unit=LOADOP, aop=CMP, c=EAX, fm=1),      # SCAS
                 NEXT_DI], compare=True)

# ---------------------------------------------------------------------
# I/O ports

for lo in (0xE4, 0xE6):                                 # IN, OUT with imm8
    at([(lo, lo + 1)], imm=I_8, byte=PAIR)
    u(unit=ALUI, aop=OR, a=ZERO, d=T1)
    if lo == 0xE4:
        u(unit=LOAD, a=T1, seg=IO, d=EAX, size=ISIZE, end=1)
    else:
        u(unit=STORE, a=T1, seg=IO, c=EAX, size=ISIZE, end=1)
at([(0xEC, 0xED)], byte=PAIR)                           # IN, OUT with DX
u(unit=LOAD, a=EDX, seg=IO, a16=1, d=EAX, size=ISIZE, end=1)
at([(0xEE, 0xEF)], byte=PAIR)
u(unit=STORE, a=EDX, seg=IO, a16=1, c=EAX, size=ISIZE, end=1)
PORT = dict(a=EDX, seg=IO, a16=1, size=ISIZE)
string_op(0x6C, [dict(PORT, unit=LOAD, d=T1),                       # INS
                 dict(DST, unit=STORE, c=T1), NEXT_DI])
string_op(0x6E, [dict(SRC, d=T1),                                   # OUTS
                 dict(PORT, unit=STORE, c=T1), NEXT_SI])

# ---------------------------------------------------------------------
# PUSHA, POPA, ENTER

at([0x60])                                              # PUSHA
# Written from the lowest address upwards, as hardware does, so that a
# fault part-way leaves what was stored so far and ESP unchanged.
u(unit=SPEC, aop=BITS, d=T4, size=ISIZE)                # eight times the size
u(unit=ALU, aop=SUB, a=ESP, b=T4, d=T2, ssz=1)
for r in (EDI, ESI, EBP, ESP, EBX, EDX, ECX, EAX):
    u(unit=STORE, a=T2, seg=SS, a16=1, aupd=1, cc=UP, c=r, size=ISIZE)
u(unit=ALU, aop=SUB, a=ESP, b=T4, d=ESP, ssz=1, end=1)

at([0x61])                                              # POPA
for r in (EDI, ESI, EBP, T1, EBX, EDX, ECX):
    pop(r)
pop(EAX)
# ESP is not restored, but with a 32-bit operand its upper half takes
# the stored value (observed on hardware).
u(unit=ALU, aop=OR, a=ZERO, b=ESP, d=T1, size=1)
u(unit=ALU, aop=OR, a=ZERO, b=T1, d=ESP, size=ISIZE, end=1)

at([0xC8], imm=I_ENTER)                                 # ENTER
push(EBP)
u(unit=ALU, aop=OR, a=ZERO, b=ESP, d=T1)                # the new frame
u(unit=SPEC, aop=READ, b=R_DISP, d=T2)
u(unit=ALUI, aop=AND, a=T2, d=T2, usek=1, k=31)         # the nesting level
u(unit=SPEC, aop=BITS, d=T4, size=ISIZE, jmp='enter_done', ucc=UZ)
u(unit=SHIFT, aop=5, a=T4, d=T3, usek=1, k=3)
u(unit=ALU, aop=OR, a=ZERO, b=EBP, d=T5)
label('enter_loop')
u(unit=ALU, aop=DEC, a=T2, d=T2)
u(unit=SPEC, aop=NOP, jmp='enter_last', ucc=UZ)
u(unit=ALU, aop=SUB, a=T5, b=T3, d=T5, ssz=1)
u(unit=LOAD, a=T5, seg=SS, a16=1, d=T6, size=ISIZE)
push(T6, jmp='enter_loop')
label('enter_last')
push(T1)
label('enter_done')
u(unit=ALU, aop=OR, a=ZERO, b=T1, d=EBP, size=ISIZE)
u(unit=ALUI, aop=SUB, a=ESP, d=ESP, ssz=1, end=1)

# ---------------------------------------------------------------------
# Decimal adjustments, SALC, and the coprocessor escapes

at([0xD4], imm=I_8, byte=1)                             # AAM: AL / imm8
u(unit=ALUI, aop=OR, a=ZERO, d=T1, size=0)
u(unit=ALUI, aop=OR, a=ZERO, d=T3, usek=1, k=24)
u(unit=ALU, aop=OR, a=ZERO, b=ZERO, d=T4)
u(unit=ALU, aop=OR, a=ZERO, b=EAX, d=T5, size=0, jmp='div_common')

at([0xD5], imm=I_8, byte=1)                             # AAD: AL += AH * imm8
u(unit=ALUI, aop=OR, a=ZERO, d=T1, size=0)
u(unit=MUL, aop=UNSIGNED, a=EAX, hi=H_A, b=T1, d=T2, size=0)
u(unit=ALU, aop=ADD, a=EAX, b=T2, d=EAX, size=0, fm=1)
u(unit=ALU, aop=OR, a=ZERO, b=ZERO, d=EAX, hi=H_D, size=0, end=1)

AFLAG, CFLAG = 0x10, 0x01
for op, adj in [(0x27, ADD), (0x2F, SUB)]:              # DAA, DAS
    at([op], byte=1)
    start = len(words)
    u(unit=SPEC, aop=READ, b=R_FLAGS, d=T7)             # the flags as they were
    u(unit=ALU, aop=OR, a=ZERO, b=EAX, d=T5, size=0)    # AL as it was
    u(unit=ALU, aop=OR, a=ZERO, b=ZERO, d=T6)           # the new carry and half-carry
    u(unit=ALUI, aop=AND, a=EAX, d=T1, size=0, usek=1, k=15)
    u(unit=ALUI, aop=SUB, a=T1, size=0, fm=3, usek=1, k=10)
    low = len(words)
    n1 = 4 if adj == SUB else 2
    u(unit=SPEC, aop=NOP, jmp=low + 3, ucc=AE)          # low digit above 9
    u(unit=ALUI, aop=AND, a=T7, usek=1, k=AFLAG)
    u(unit=SPEC, aop=NOP, jmp=low + 3 + n1, ucc=UZ)     # or a half-carry
    u(unit=ALUI, aop=adj, a=EAX, d=EAX, size=0, fm=3, usek=1, k=6)
    if adj == SUB:                                      # DAS: a borrow here counts
        u(unit=SPEC, aop=NOP, jmp=len(words) + 2, ucc=AE)
        u(unit=ALUI, aop=OR, a=T6, d=T6, usek=1, k=CFLAG)
    u(unit=ALUI, aop=OR, a=T6, d=T6, usek=1, k=AFLAG)
    assert len(words) == low + 3 + n1
    u(unit=ALUI, aop=SUB, a=T5, size=0, fm=3, usek=1, k=0x9A)
    high = len(words)
    u(unit=SPEC, aop=NOP, jmp=high + 3, ucc=AE)         # AL was above 99h
    u(unit=ALUI, aop=AND, a=T7, usek=1, k=CFLAG)
    u(unit=SPEC, aop=NOP, jmp=high + 5, ucc=UZ)         # or a carry
    u(unit=ALUI, aop=adj, a=EAX, d=EAX, size=0, usek=1, k=0x60)
    u(unit=ALUI, aop=OR, a=T6, d=T6, usek=1, k=CFLAG)
    u(unit=SPEC, aop=WRFL, a=T7, usek=1, k=-1)
    u(unit=SPEC, aop=WRFL, a=T6, usek=1, k=AFLAG | CFLAG)
    u(unit=SPEC, aop=SZP, a=EAX, size=0, end=1)

for op, adj in [(0x37, ADD), (0x3F, SUB)]:              # AAA, AAS
    at([op], byte=1)
    u(unit=SPEC, aop=READ, b=R_FLAGS, d=T7)
    u(unit=ALUI, aop=AND, a=EAX, d=T1, size=0, usek=1, k=15)
    u(unit=ALUI, aop=SUB, a=T1, size=0, fm=3, usek=1, k=10)
    here = len(words)
    u(unit=SPEC, aop=NOP, jmp=here + 3, ucc=AE)
    u(unit=ALUI, aop=AND, a=T7, usek=1, k=AFLAG)
    u(unit=SPEC, aop=NOP, jmp=here + 8, ucc=UZ)
    u(unit=ALUI, aop=adj, a=EAX, d=EAX, size=1, usek=1, k=0x106)
    u(unit=SPEC, aop=WRFL, a=T7, usek=1, k=-1)
    u(unit=ALUI, aop=OR, a=ZERO, d=T6, usek=1, k=AFLAG | CFLAG)
    u(unit=SPEC, aop=WRFL, a=T6, usek=1, k=AFLAG | CFLAG)
    u(unit=SPEC, aop=NOP, jmp=here + 10)
    assert len(words) == here + 8
    u(unit=SPEC, aop=WRFL, a=T7, usek=1, k=-1)
    u(unit=SPEC, aop=WRFL, a=ZERO, usek=1, k=AFLAG | CFLAG)
    u(unit=ALUI, aop=AND, a=EAX, d=EAX, size=0, usek=1, k=15, end=1)

at([0xD6], byte=1)                                      # SALC: AL = carry ? FFh : 0
u(unit=ALU, aop=SBB, a=EAX, b=EAX, d=EAX, size=0, end=1)

at([0x9B])                                              # WAIT: nothing to wait for
u(unit=SPEC, aop=NOP, end=1)
at(range(0xD8, 0xE0), modrm=1)                          # coprocessor: there is none
u(unit=SPEC, aop=NOP, end=1)

at([0x90])                                              # NOP
u(unit=SPEC, aop=NOP, end=1)
at([0xF4])                                              # HLT
u(unit=SPEC, aop=NOP, br=4, end=1)
for op, code in [(0xF8, 0), (0xF9, 1), (0xFA, 2), (0xFB, 3), (0xFC, 4),
                 (0xFD, 5), (0xF5, 6)]:                 # CLC STC CLI STI CLD STD CMC
    at([op])
    u(unit=SPEC, aop=FLBIT, cc=code, end=1)


# ---------------------------------------------------------------------
# Protected mode, the first part: the table registers, CR0.

at([0x01], modrm=1, mem=False, group=1, map0f=1)
for r in range(8):
    if r == 4:                                          # SMSW r
        u(unit=SPEC, aop=READ, b=R_CR0, seld=RM, d=0, size=ISIZE, end=1)
    elif r == 6:                                        # LMSW r
        u(unit=SPEC, aop=NOP, sela=RM, cc=W_MSW, end=1)
    else:
        invalid()
at([0x01], modrm=1, mem=True, group=1, map0f=1)
u(unit=SPEC, aop=LEA, ea=1, d=T5, jmp='sgdt')
u(unit=SPEC, aop=LEA, ea=1, d=T5, jmp='sidt')
u(unit=SPEC, aop=LEA, ea=1, d=T5, jmp='lgdt')
u(unit=SPEC, aop=LEA, ea=1, d=T5, jmp='lidt')
u(unit=SPEC, aop=READ, b=R_CR0, d=T1, jmp='mov_m16')    # SMSW m16
invalid()
u(unit=LOAD, ea=1, d=T1, size=1, jmp='lmsw_t1')         # LMSW m16
u(unit=SPEC, aop=NOP, end=1)                            # INVLPG (a 486's): no paging yet
label('lmsw_t1')
u(unit=SPEC, aop=NOP, a=T1, cc=W_MSW, end=1)
for name, lim, base in (('sgdt', R_GDTL, R_GDTB), ('sidt', R_IDTL, R_IDTB)):
    label(name)
    u(unit=SPEC, aop=READ, b=lim, d=T1)
    u(unit=STORE, a=T5, selseg=SEG_EA, c=T1, size=1, aupd=1, cc=UP)
    u(unit=SPEC, aop=READ, b=base, d=T1)
    u(unit=STORE, a=T5, selseg=SEG_EA, c=T1, size=2, end=1)
for name, lim, base in (('lgdt', W_GDTL, W_GDTB), ('lidt', W_IDTL, W_IDTB)):
    label(name)
    u(unit=LOAD, a=T5, selseg=SEG_EA, aupd=1, d=T1, size=1)
    u(unit=LOAD, a=T5, selseg=SEG_EA, d=T2, size=2)
    u(unit=SPEC, aop=NOP, a=T1, cc=lim)
    u(unit=SPEC, aop=NOP, a=T2, cc=base, end=1)         # 24 bits of it with a 16-bit operand

at([0x06], map0f=1)                                     # CLTS
u(unit=SPEC, aop=NOP, cc=W_CLTS, end=1)

at([0x20], modrm=1, mem=False, group=1, map0f=1)        # MOV r32, CRn
for r in range(8):
    if r in (0, 2, 3):
        u(unit=SPEC, aop=READ, b={0: R_CR0, 2: R_CR2, 3: R_CR3}[r], seld=RM, d=0,
          size=2, end=1)
    else:
        invalid()
at([0x22], modrm=1, mem=False, group=1, map0f=1)        # MOV CRn, r32
for r in range(8):
    if r in (0, 2, 3):
        u(unit=SPEC, aop=NOP, sela=RM, size=2, cc={0: W_CR0, 2: W_CR2, 3: W_CR3}[r],
          end=1)
    else:
        invalid()


# ---------------------------------------------------------------------
# Round 26: the double shifts, the bit instructions, and what a 486
# has that a 386 has not.

at([0x08, 0x09], map0f=1)                               # INVD, WBINVD: no cache to empty
label('nop_end')
u(unit=SPEC, aop=NOP, end=1)

# SHLD and SHRD: the destination shifted, the bits the source gives
# OR-ed in (the shifter's "other half"). The destination is copied to
# T1 first, the count to T3, and T7 says whether the result goes to a
# register (1) or back to memory (0), so that one routine serves both.
# Nothing happens with a count of zero. With 16-bit operands and more
# than 16 places the hardware goes on shifting and the source comes
# round again: the result is the source rotated.
OFLAG_AB = 10                   # FLBIT: overflow if A's sign is not B's
for right, op_imm, op_cl in [(0, 0xA4, 0xA5), (1, 0xAC, 0xAD)]:
    name = 'shd%d' % right
    at([op_imm], modrm=1, imm=I_8, mem=False, map0f=1)
    u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=ISIZE)
    u(unit=ALUI, aop=OR, a=ZERO, d=T7, usek=1, k=1)
    u(unit=ALUI, aop=OR, a=ZERO, d=T3, size=0, jmp=name)
    at([op_cl], modrm=1, mem=False, map0f=1)
    u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=ISIZE)
    u(unit=ALUI, aop=OR, a=ZERO, d=T7, usek=1, k=1)
    u(unit=ALU, aop=OR, a=ZERO, b=ECX, d=T3, size=0, jmp=name)
    at([op_imm], modrm=1, imm=I_8, mem=True, map0f=1)
    u(unit=LOAD, ea=1, d=T1, size=ISIZE)
    u(unit=ALUI, aop=OR, a=ZERO, d=T3, size=0)
    u(unit=ALU, aop=OR, a=ZERO, b=ZERO, d=T7, jmp=name)
    at([op_cl], modrm=1, mem=True, map0f=1)
    u(unit=LOAD, ea=1, d=T1, size=ISIZE)
    u(unit=ALU, aop=OR, a=ZERO, b=ECX, d=T3, size=0)
    u(unit=ALU, aop=OR, a=ZERO, b=ZERO, d=T7, jmp=name)
    label(name)
    u(unit=ALUI, aop=AND, a=T3, d=T3, size=0, usek=1, k=31)
    u(unit=SPEC, aop=NOP, jmp='nop_end', ucc=UZ)
    u(unit=SPEC, aop=BITS, d=T5, size=ISIZE)
    u(unit=ALUI, aop=AND, a=T5, d=T5, usek=1, k=16)
    u(unit=ALU, aop=AND, a=T3, b=T5, d=T6)
    u(unit=SPEC, aop=NOP, jmp=name + '_n', ucc=UZ)
    u(unit=ALUI, aop=AND, a=T3, d=T6, usek=1, k=15)
    u(unit=SPEC, aop=NOP, jmp=name + '_n', ucc=UZ)
    u(unit=SPEC, aop=WRFL, a=ZERO, usek=1, k=AFLAG)
    u(unit=SHIFT, aop=right, sela=REG, b=T3, cc=1, d=T2, size=ISIZE, fm=1,
      jmp=name + '_f')
    label(name + '_n')
    u(unit=SHIFT, aop=4 + right, a=T1, b=T3, cc=1, d=T2, size=ISIZE, fm=1)
    u(unit=SHIFT, aop=2 + right, sela=REG, b=T3, cc=1, d=T4, size=ISIZE)
    u(unit=ALU, aop=OR, a=T2, b=T4, d=T2, size=ISIZE)
    label(name + '_f')
    u(unit=SPEC, aop=FLBIT, cc=OFLAG_AB, a=T2, b=T1, size=ISIZE)
    u(unit=SPEC, aop=SZP, a=T2, size=ISIZE)
    u(unit=ALU, aop=OR, a=T7, b=ZERO, d=T7)
    u(unit=SPEC, aop=NOP, jmp=name + '_m', ucc=UZ)
    u(unit=ALU, aop=OR, a=ZERO, b=T2, seld=RM, d=0, size=ISIZE, end=1)
    label(name + '_m')
    u(unit=STORE, cc=2, c=T2, size=ISIZE, end=1)

# BT, BTS, BTR, BTC. The ALU has the bit operations (13 set, 14 clear,
# 15 turn over; the carry is the bit as it was), and operation
# selector 3 picks one by the opcode. With a register for the bit
# number and memory for the operand the number reaches outside the
# operand, either way: the byte it falls in is found (the number,
# signed, over eight) and the operation done on that byte.
BSET, BCLR, BFLIP = 13, 14, 15
BITOPS = [0xA3, 0xAB, 0xB3, 0xBB]
at(BITOPS, modrm=1, mem=False, map0f=1)
u(unit=ALU, selaop=3, sela=RM, selb=REG, seld=RM, d=0, size=ISIZE, fm=3, end=1)
at([0xA3], modrm=1, mem=True, map0f=1)
at([0xAB, 0xB3, 0xBB], modrm=1, mem=True, map0f=1, lock=1)
u(unit=ALU, aop=OR, a=ZERO, selb=REG, d=T6, size=ISIZE)
u(unit=ALU, aop=SIGN, a=T6, d=T7, size=ISIZE)
u(unit=SHIFT, aop=4, a=T7, d=T7, usek=1, k=16)          # the sign above a 16-bit number
u(unit=SHIFT, aop=7, a=T6, d=T4, size=ISIZE, usek=1, k=3)
u(unit=ALU, aop=OR, a=T4, b=T7, d=T4)
u(unit=SPEC, aop=LEA, ea=1, d=T5)
u(unit=ALU, aop=ADD, a=T5, b=T4, d=T5)
u(unit=LOAD, a=T5, selseg=SEG_EA, d=T1, size=0)
u(unit=ALU, selaop=3, a=T1, b=T6, d=T1, size=0, fm=3)
u(unit=STORE, selaop=3, cc=2, c=T1, size=0, end=1)

at([0xBA], modrm=1, imm=I_8, mem=False, group=1, map0f=1)
for r in range(8):
    if r < 4:
        invalid()
    else:
        u(unit=ALUI, aop=BSET if r < 6 else r + 8, sela=RM, seld=RM,
          d=(None if r == 4 else 0), size=ISIZE, fm=3, end=1)
at([0xBA], modrm=1, imm=I_8, mem=True, group=1, map0f=1, lock=1)
for r in range(8):
    if r < 4:
        invalid()
    else:
        u(unit=LOAD, ea=1, d=T1, size=ISIZE, jmp='btm%d' % r)
label('btm4')
u(unit=ALUI, aop=BSET, a=T1, size=ISIZE, fm=3, end=1)
for r in (5, 6, 7):
    label('btm%d' % r)
    u(unit=ALUI, aop=BSET if r == 5 else r + 8, a=T1, d=T1, size=ISIZE, fm=3)
    u(unit=STORE, cc=2, c=T1, size=ISIZE, end=1)

# BSWAP: by halves. The register turned by 16, its lower half's bytes
# exchanged, is the result's lower half; the register's own lower
# half, bytes exchanged, the upper.
at(range(0xC8, 0xD0), map0f=1)
u(unit=ALU, aop=OR, a=ZERO, selb=OPR, d=T4)
u(unit=SHIFT, aop=0, a=T4, d=T1, usek=1, k=16)
u(unit=SHIFT, aop=0, a=T1, d=T2, size=1, usek=1, k=8)
u(unit=SHIFT, aop=0, a=T4, d=T3, size=1, usek=1, k=8)
u(unit=SHIFT, aop=4, a=T3, d=T3, usek=1, k=16)
u(unit=ALU, aop=OR, a=T3, b=T2, seld=OPR, d=0, end=1)

for op, byte in pair(0xC0):                             # XADD
    at([op], modrm=1, byte=byte, mem=False, map0f=1)
    u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=ISIZE)
    u(unit=ALU, aop=ADD, a=T1, selb=REG, d=T2, size=ISIZE, fm=1)
    u(unit=ALU, aop=OR, a=ZERO, b=T1, seld=REG, d=0, size=ISIZE)
    u(unit=ALU, aop=OR, a=ZERO, b=T2, seld=RM, d=0, size=ISIZE, end=1)
    at([op], modrm=1, byte=byte, mem=True, map0f=1, lock=1)
    u(unit=LOAD, ea=1, d=T1, size=ISIZE)
    u(unit=ALU, aop=ADD, a=T1, selb=REG, d=T2, size=ISIZE, fm=1)
    u(unit=ALU, aop=OR, a=ZERO, b=T1, seld=REG, d=0, size=ISIZE)
    u(unit=STORE, cc=2, c=T2, size=ISIZE, end=1)

for op, byte in pair(0xB0):                             # CMPXCHG
    at([op], modrm=1, byte=byte, mem=False, map0f=1)
    u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=ISIZE)
    u(unit=ALU, aop=CMP, a=EAX, b=T1, size=ISIZE, fm=1)
    u(unit=SPEC, aop=NOP, jmp='cx_ne', ucc=5)
    u(unit=ALU, aop=OR, a=ZERO, selb=REG, seld=RM, d=0, size=ISIZE, end=1)
    at([op], modrm=1, byte=byte, mem=True, map0f=1, lock=1)
    u(unit=LOAD, ea=1, d=T1, size=ISIZE)
    u(unit=ALU, aop=CMP, a=EAX, b=T1, size=ISIZE, fm=1)
    u(unit=SPEC, aop=NOP, jmp='cx_ne', ucc=5)
    u(unit=ALU, aop=OR, a=ZERO, selb=REG, d=T2, size=ISIZE)
    u(unit=STORE, cc=2, c=T2, size=ISIZE, end=1)
label('cx_ne')
u(unit=ALU, aop=OR, a=ZERO, b=T1, d=EAX, size=ISIZE, end=1)


# ---------------------------------------------------------------------
# Protected mode, the second part.

# An interrupt or fault with PE set: T1 the vector, T4 the return
# address, T5 the IDT's base. Through a gate to the same privilege
# level; nothing is checked. A 32-bit gate pushes doublewords; an
# interrupt gate clears IF; a fault of 8 to 15 pushes an error code,
# always zero.
W_LDT, W_LDTB, W_TR = 10, 11, 12
TF_OFF = 14                     # FLBIT
label('int_pm')
u(unit=LOAD, a=T5, b=T1, idx=1, scale=3, seg=FLAT, d=T2)
u(unit=LOAD, a=T5, b=T1, idx=1, scale=3, disp=1, usek=1, k=4, seg=FLAT, d=T3)
u(unit=ALUI, aop=AND, a=T3, hi=H_A, d=T6, size=0, usek=1, k=8)
u(unit=SPEC, aop=NOP, jmp='int_pm16', ucc=UZ)
for size, name in ((2, 'int_pm32'), (1, 'int_pm16')):
    if size == 1:
        label('int_pm16')
    u(unit=STORE, a=ESP, aop=ST_READ, b=R_FLAGS, seg=SS, a16=1, aupd=1, size=size)
    u(unit=STORE, a=ESP, aop=ST_READ, b=R_SEGSEL, c=CS, seg=SS, a16=1, aupd=1,
      size=size)
    u(unit=STORE, a=ESP, c=T4, seg=SS, a16=1, aupd=1, size=size)
    u(unit=SPEC, aop=NOP, jmp=name + '_n', ucc=UNFLT)
    u(unit=ALUI, aop=AND, a=T1, d=T6, usek=1, k=8)
    u(unit=SPEC, aop=NOP, jmp=name + '_n', ucc=UZ)
    u(unit=STORE, a=ESP, c=ZERO, seg=SS, a16=1, aupd=1, size=size)
    label(name + '_n')
    if size == 2:
        u(unit=ALU, aop=OR, a=ZERO, b=T3, d=T6)         # the offset's upper half
        u(unit=ALU, aop=OR, a=ZERO, b=T2, d=T6, size=1, jmp='int_pm_go')
    else:
        u(unit=ALU, aop=OR, a=ZERO, b=ZERO, d=T6)
        u(unit=ALU, aop=OR, a=ZERO, b=T2, d=T6, size=1)
label('int_pm_go')
u(unit=SHIFT, aop=5, a=T2, d=T2, usek=1, k=16)          # the selector
u(unit=ALUI, aop=AND, a=T3, hi=H_A, d=T3, size=0, usek=1, k=1)
u(unit=SPEC, aop=FLBIT, cc=TF_OFF, jmp='int_pm_cs', ucc=UNZ)    # a trap gate: IF stays
u(unit=SPEC, aop=FLBIT, cc=8)
label('int_pm_cs')
u(unit=SPEC, aop=SETSEG, a=T2, seg=CS)
u(unit=SPEC, aop=NOP, c=T6, br=7, cc=J_REG, end=1)

# SLDT, STR, LLDT, LTR (0F 00; the decoder refuses it in real mode).
# The selectors read as segments 6 and 7. VERR and VERW are not here.
SEG_LDT, SEG_TR = 6, 7
at([0x00], modrm=1, mem=False, group=1, map0f=1)
u(unit=SPEC, aop=READ, b=R_SEGSEL, seg=SEG_LDT, seld=RM, d=0, size=ISIZE, end=1)
u(unit=SPEC, aop=READ, b=R_SEGSEL, seg=SEG_TR, seld=RM, d=0, size=ISIZE, end=1)
u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=1, jmp='lldt')
u(unit=SPEC, aop=NOP, sela=RM, cc=W_TR, end=1)
u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=1, jmp='verx')     # VERR
u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=1, jmp='verx')     # VERW
invalid(2)
at([0x00], modrm=1, mem=True, group=1, map0f=1)
u(unit=SPEC, aop=READ, b=R_SEGSEL, seg=SEG_LDT, d=T1, jmp='mov_m16')
u(unit=SPEC, aop=READ, b=R_SEGSEL, seg=SEG_TR, d=T1, jmp='mov_m16')
u(unit=LOAD, ea=1, d=T1, size=1, jmp='lldt')
u(unit=LOAD, ea=1, d=T1, size=1, jmp='ltr')
u(unit=LOAD, ea=1, d=T1, size=1, jmp='verx')
u(unit=LOAD, ea=1, d=T1, size=1, jmp='verx')
invalid(2)
label('ltr')
u(unit=SPEC, aop=NOP, a=T1, cc=W_TR, end=1)
label('lldt')
u(unit=SPEC, aop=NOP, a=T1, cc=W_LDT)
u(unit=SPEC, aop=READ, b=R_DESC, d=T7)
u(unit=LOAD, a=T7, seg=FLAT, d=T2)
u(unit=LOAD, a=T7, disp=1, usek=1, k=4, seg=FLAT, d=T3)
u(unit=SPEC, aop=NOP, a=T3, b=T2, cc=W_LDTB, end=1)


# BSF and BSR: a loop, a bit a round (three words). BSF walks a mask
# up from bit 0; BSR doubles the operand until its top bit is set.
# Zero: ZF set and nothing written.
ZF_OFF, ZF_ON = 12, 13          # FLBIT
for op, name in ((0xBC, 'bsf'), (0xBD, 'bsr')):
    at([op], modrm=1, mem=False, map0f=1)
    u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=ISIZE, jmp=name)
    at([op], modrm=1, mem=True, map0f=1)
    u(unit=LOAD, ea=1, d=T1, size=ISIZE, jmp=name)
label('bsf')
u(unit=ALU, aop=OR, a=T1, b=ZERO, d=T1, size=ISIZE)
u(unit=SPEC, aop=FLBIT, cc=ZF_ON, jmp='nop_end', ucc=UZ)
u(unit=ALU, aop=OR, a=ZERO, b=ZERO, d=T2)
u(unit=ALU, aop=INC, a=ZERO, d=T3)
label('bsf_loop')
u(unit=ALU, aop=AND, a=T1, b=T3, d=T4)
u(unit=SPEC, aop=NOP, jmp='bs_done', ucc=UNZ)
u(unit=ALU, aop=ADD, a=T3, b=T3, d=T3)
u(unit=ALU, aop=INC, a=T2, d=T2, jmp='bsf_loop')
label('bsr')
u(unit=ALU, aop=OR, a=T1, b=ZERO, d=T1, size=ISIZE)
u(unit=SPEC, aop=FLBIT, cc=ZF_ON, jmp='nop_end', ucc=UZ)
u(unit=SPEC, aop=BITS, d=T2, size=ISIZE)
u(unit=ALU, aop=DEC, a=T2, d=T2)
u(unit=ALU, aop=INC, a=ZERO, d=T3)
u(unit=SHIFT, aop=4, a=T3, b=T2, cc=1, d=T3)            # the operand's top bit
label('bsr_loop')
u(unit=ALU, aop=AND, a=T1, b=T3, d=T4)
u(unit=SPEC, aop=NOP, jmp='bs_done', ucc=UNZ)
u(unit=ALU, aop=ADD, a=T1, b=T1, d=T1, size=ISIZE)
u(unit=ALU, aop=DEC, a=T2, d=T2, jmp='bsr_loop')
label('bs_done')
u(unit=SPEC, aop=FLBIT, cc=ZF_OFF)
u(unit=ALU, aop=OR, a=ZERO, b=T2, seld=REG, d=0, size=ISIZE, end=1)


# LAR, LSL, VERR, VERW: the selector in T1 is looked up (W_SEL); if it
# names no descriptor ZF is cleared and that is all. Otherwise the
# core makes what the instruction gives out of the descriptor's
# halves (READ of R_DESC with a cc: 2 LAR, 3 LSL -- the opcode's own
# low bits -- and 1 for VERR or VERW, told apart by the ModRM reg
# field put where a segment goes). Privilege is not looked at, nor
# the descriptor's type for LAR and LSL.
W_SEL = 13
at([0x02, 0x03], modrm=1, mem=False, map0f=1)
u(unit=ALU, aop=OR, a=ZERO, selb=RM, d=T1, size=1, jmp='larlsl')
at([0x02, 0x03], modrm=1, mem=True, map0f=1)
u(unit=LOAD, ea=1, d=T1, size=1, jmp='larlsl')
for name in ('larlsl', 'verx'):
    label(name)
    u(unit=SPEC, aop=NOP, a=T1, cc=W_SEL)
    u(unit=SPEC, aop=READ, b=R_DESC, d=T7)
    u(unit=ALU, aop=OR, a=T7, b=ZERO, d=T7)
    u(unit=SPEC, aop=FLBIT, cc=ZF_OFF, jmp='nop_end', ucc=UZ)
    if name == 'larlsl':
        u(unit=LOAD, a=T7, seg=FLAT, d=T3)
        u(unit=LOAD, a=T7, disp=1, usek=1, k=4, seg=FLAT, d=T2)
        u(unit=SPEC, aop=READ, b=R_DESC, selcc=1, a=T2, c=T3, seld=REG, d=0,
          size=ISIZE)
        u(unit=SPEC, aop=FLBIT, cc=ZF_ON, end=1)
    else:
        u(unit=LOAD, a=T7, disp=1, usek=1, k=4, seg=FLAT, d=T2)
        u(unit=SPEC, aop=READ, b=R_DESC, cc=1, selseg=SEG_REG, a=T2, d=T4)
        u(unit=ALU, aop=OR, a=T4, b=ZERO, d=T4)
        u(unit=SPEC, aop=FLBIT, cc=ZF_OFF, jmp='nop_end', ucc=UZ)
        u(unit=SPEC, aop=FLBIT, cc=ZF_ON, end=1)


def main():
    out = sys.argv[1]
    # An instruction's first word is cached with one immediate. If that
    # is the word's constant, nothing later may need the real one.
    for a in attr:
        if a >> 15 & 1:
            for e in range(a & 0x3FF, (a & 0x3FF) + (8 if a >> 16 & 1 else 1)):
                assert not words[e]['usek'] or words[e]['end'], \
                    'word %d: a first word with a constant must be the last' % e
                # Its jump is settled when it is cached.
                assert words[e]['ucc'] is None or UREP <= words[e]['ucc'] < UA_NOT1, \
                    'word %d: a first word may not jump on flags' % e
    with open(out + '/ucode.hex', 'w') as f:
        for i in range(1024):
            if i >= len(words):
                f.write('0\n')
                continue
            x = words[i]
            jmp = x['jmp']
            target = labels[jmp] if isinstance(jmp, str) else (jmp or 0)
            k = target if jmp is not None else x['k'] & 0x3FF
            w = (x['w'] | k << 48 | (1 if jmp is not None else 0) << 58
                 | (1 if x['ucc'] is not None else 0) << 59
                 | ((x['ucc'] or 0) & 15) << 60 | ((x['ucc'] or 0) >> 4 & 1) << 81
                 | ((x['ucc'] or 0) >> 5 & 3) << 83
                 | ((x['ucc'] or 0) >> 7 & 3) << 88 | x['ext'] << 86
                 | x['end'] << 64 | x['usek'] << 65
                 | x['sel'] << 66)
            f.write('%x\n' % w)
    with open(out + '/attr.hex', 'w') as f:
        for a in attr:
            f.write('%x\n' % a)
    print('microcode: %d words' % len(words))


if __name__ == '__main__':
    main()
