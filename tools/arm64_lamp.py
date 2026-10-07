#!/usr/bin/env python3
"""LAMP-specific extensions to Rhun's MIT build-time AArch64 translator."""
import re
import sys
import arm64 as a


class Translator(a.Translator):
    WRITES_ALL = a.Translator.WRITES_ALL | {'comisd', 'ucomisd'}

    def __init__(self, *args):
        super().__init__(*args)
        self.fp_stack = []

    def branch(self, st, mn):
        if mn in ('jp', 'jnp'):
            self.emit('%s w26, %s' % ('cbnz' if mn == 'jp' else 'cbz', st.args[0]))
            return
        return super().branch(st, mn)

    def i_comiss(self, st, ops, need, k):
        d, s = ops
        si = self.fsrc(s, st)
        self.emit('fcmp s%d, s%d' % (d.i, si))
        self.emit('cset w26, vs')
        self.emit('fccmp s%d, s%d, #4, vc' % (d.i, si))
    i_ucomiss = i_comiss

    def mem(self, inner, bits, st):
        # MASM allows globals indexed by registers; Mach-O uses ADRP+ADD first.
        inner = re.sub(r'\b(eax|ecx|edx|ebx|esp|ebp|esi|edi)\b',
                       lambda m: 'r' + m[0][1:], inner)
        terms = a.split_terms(inner)
        sym = None
        rest = []
        for sign, term in terms:
            if (term.strip().lower() not in a.REGS and term.strip().lower() != 'rip'
                    and re.fullmatch(r'[A-Za-z_]\w*', term.strip())
                    and self.value(term) is None):
                if sign < 0 or sym:
                    self.err(st, 'unsupported symbolic address')
                sym = term.strip()
            elif term.strip().lower() != 'rip':
                rest.append(('+' if sign > 0 else '-') + term)
        if not sym:
            return super().mem(''.join(rest).lstrip('+') or '0', bits, st)
        m = super().mem(''.join(rest).lstrip('+') or '0', bits, st)
        m.sym = sym
        return m

    def addr(self, m, nbytes, regoff=True):
        if m.sym and (m.base or m.index):
            self.lea_into('x10', m)
            return '[x10]'
        return super().addr(m, nbytes, regoff)

    def lea_into(self, d, m):
        if m.sym and (m.base or m.index):
            self.emit('adrp %s, %s@PAGE' % (d, m.sym))
            self.emit('add %s, %s, %s@PAGEOFF' % (d, d, m.sym))
            if m.base:
                self.emit('add %s, %s, %s' % (d, d, a.rn(m.base.i, 64)))
            if m.index:
                sh = {1: 0, 2: 1, 4: 2, 8: 3}[m.scale]
                self.emit('add %s, %s, %s, lsl #%d' % (d, d, a.rn(m.index.i, 64), sh))
            self.add_const(d, d, m.disp)
            return
        return super().lea_into(d, m)

    def i_leave(self, st, ops, need, k):
        self.emit('mov x28, x20')
        self.emit('ldr x20, [x28], #8')

    def i_adc(self, st, ops, need, k):
        d, s = ops
        bits = self.opsize(ops, st)
        D = self.get(d, bits, 11)
        S = self.get(s, bits, 12)
        self.emit('cfinv')
        self.emit('adc%s %s, %s, %s' % ('s' if need else '', a.rn(11, bits), D, S))
        if need:
            self.emit('cfinv')
        self.put(d, bits, a.rn(11, bits))

    def i_rep_movsq(self, st, ops, need, k):
        self.emit('lsl x3, x3, #3')
        self.emit('bl x_rep_movsb')

    def i_rep_movsw(self, st, ops, need, k):
        self.emit('lsl x3, x3, #1')
        self.emit('bl x_rep_movsb')

    def i_rep_stosw(self, st, ops, need, k):
        self.emit('bl x_rep_stosw')

    def i_movq(self, st, ops, need, k):
        d, s = ops
        if isinstance(d, a.Xmm):
            if isinstance(s, a.Xmm):
                self.emit('fmov d%d, d%d' % (d.i, s.i))
            elif isinstance(s, a.Reg):
                self.emit('fmov d%d, %s' % (d.i, a.rn(s.i, 64)))
            else:
                self.emit('ldr d%d, %s' % (d.i, self.addr(s, 8)))
        elif isinstance(d, a.Reg):
            self.emit('fmov %s, d%d' % (a.rn(d.i, 64), s.i))
        else:
            self.emit('str d%d, %s' % (s.i, self.addr(d, 8)))

    def i_movsd(self, st, ops, need, k):
        if not ops:
            self.emit('ldr w11, [x1], #4')
            self.emit('str w11, [x0], #4')
            return
        d, s = ops
        if isinstance(d, a.Xmm) and isinstance(s, a.Xmm):
            self.emit('ins v%d.d[0], v%d.d[0]' % (d.i, s.i))
        else:
            self.i_movq(st, ops, need, k)

    i_movupd = a.Translator.i_movups
    i_movapd = a.Translator.i_movups
    i_xorpd = a.Translator.i_xorps

    def dsrc(self, s, st):
        if isinstance(s, a.Xmm):
            return s.i
        self.emit('ldr d24, %s' % self.addr(s, 8))
        return 24

    def dop(self, st, ops, op):
        d, s = ops
        si = self.dsrc(s, st)
        # Scalar SSE operations preserve the upper lane.
        self.emit('%s d25, d%d, d%d' % (op, d.i, si))
        self.emit('ins v%d.d[0], v25.d[0]' % d.i)

    def i_addsd(self, st, ops, need, k): self.dop(st, ops, 'fadd')
    def i_subsd(self, st, ops, need, k): self.dop(st, ops, 'fsub')
    def i_mulsd(self, st, ops, need, k): self.dop(st, ops, 'fmul')
    def i_divsd(self, st, ops, need, k): self.dop(st, ops, 'fdiv')

    def dminmax(self, st, ops, op):
        d, s = ops
        si = self.dsrc(s, st)
        left, right = (si, d.i) if op == 'min' else (d.i, si)
        self.emit('fcmgt d25, d%d, d%d' % (left, right))
        self.emit('bsl v25.8b, v%d.8b, v%d.8b' % (d.i, si))
        self.emit('ins v%d.d[0], v25.d[0]' % d.i)

    def i_minsd(self, st, ops, need, k): self.dminmax(st, ops, 'min')
    def i_maxsd(self, st, ops, need, k): self.dminmax(st, ops, 'max')

    def i_sqrtsd(self, st, ops, need, k):
        d, s = ops
        si = self.dsrc(s, st)
        self.emit('fsqrt d25, d%d' % si)
        self.emit('ins v%d.d[0], v25.d[0]' % d.i)

    def i_cvtsi2sd(self, st, ops, need, k):
        d, s = ops
        S = self.get(s, s.bits or 32, 11)
        self.emit('scvtf d25, %s' % S)
        self.emit('ins v%d.d[0], v25.d[0]' % d.i)

    def i_cvtss2sd(self, st, ops, need, k):
        d, s = ops
        si = self.fsrc(s, st)
        self.emit('fcvt d25, s%d' % si)
        self.emit('ins v%d.d[0], v25.d[0]' % d.i)

    def i_cvtsd2ss(self, st, ops, need, k):
        d, s = ops
        si = self.dsrc(s, st)
        self.emit('fcvt s25, d%d' % si)
        self.emit('ins v%d.s[0], v25.s[0]' % d.i)

    def i_cvttsd2si(self, st, ops, need, k):
        d, s = ops
        si = self.dsrc(s, st)
        self.emit('fcvtzs %s, d%d' % (a.rn(d.i, d.bits), si))

    def i_cvtdq2ps(self, st, ops, need, k):
        d, s = ops
        si = self.vsrc(s, st)
        self.emit('scvtf v%d.4s, v%d.4s' % (d.i, si))

    def i_cvtpd2ps(self, st, ops, need, k):
        d, s = ops
        si = self.vsrc(s, st)
        self.emit('fcvtn v%d.2s, v%d.2d' % (d.i, si))

    def i_comisd(self, st, ops, need, k):
        d, s = ops
        si = self.dsrc(s, st)
        self.emit('fcmp d%d, d%d' % (d.i, si))
        self.emit('cset w26, vs')
        self.emit('fccmp d%d, d%d, #4, vc' % (d.i, si))
    i_ucomisd = i_comisd

    def shift(self, st, mn, ops, need):
        if need and ('C' in need or 'V' in need):
            d, c = ops
            bits = self.opsize([d], st)
            if not isinstance(c, a.Imm) or bits < 32 or mn not in ('shl','shr','sar','sal'):
                self.err(st, 'unsupported shift flags')
            n = c.value & (63 if bits == 64 else 31)
            if not n: return
            S = self.get(d, bits, 11)
            self.emit('mov %s, %s' % (a.rn(14,bits),S))
            super().shift(st, mn, ops, need - {'C','V'})
            self.emit('mrs x16, nzcv')
            if 'C' in need:
                pos = bits-n if mn in ('shl','sal') else n-1
                self.emit('ubfx %s, %s, #%d, #1' % (a.rn(15,bits), a.rn(14,bits), pos))
                self.emit('eor x15, x15, #1')
                self.emit('bfi x16, x15, #29, #1')
            if 'V' in need:
                if n != 1: self.err(st,'undefined shift overflow')
                if mn in ('shl','sal'):
                    self.emit('eor %s, %s, %s, lsl #1' % (a.rn(15,bits), a.rn(14,bits), a.rn(14,bits)))
                    self.emit('lsr %s, %s, #%d' % (a.rn(15,bits), a.rn(15,bits), bits-1))
                elif mn == 'shr':
                    self.emit('lsr %s, %s, #%d' % (a.rn(15,bits),a.rn(14,bits),bits-1))
                else: self.emit('mov x15, #0')
                self.emit('bfi x16, x15, #28, #1')
            self.emit('msr nzcv, x16')
            return
        return super().shift(st,mn,ops,need)

    def i_addps(self, st, ops, need, k): self.vop(st, ops, 'fadd', '4s')
    def i_subps(self, st, ops, need, k): self.vop(st, ops, 'fsub', '4s')
    def i_mulps(self, st, ops, need, k): self.vop(st, ops, 'fmul', '4s')
    def i_addpd(self, st, ops, need, k): self.vop(st, ops, 'fadd', '2d')
    def i_subpd(self, st, ops, need, k): self.vop(st, ops, 'fsub', '2d')
    def i_mulpd(self, st, ops, need, k): self.vop(st, ops, 'fmul', '2d')
    def i_unpcklps(self, st, ops, need, k): self.vop(st, ops, 'zip1', '4s')
    def i_unpcklpd(self, st, ops, need, k): self.vop(st, ops, 'zip1', '2d')
    def i_unpckhpd(self, st, ops, need, k): self.vop(st, ops, 'zip2', '2d')

    def i_movhlps(self, st, ops, need, k):
        d, s = ops
        self.emit('ins v%d.d[0], v%d.d[1]' % (d.i, s.i))

    def i_shufps(self, st, ops, need, k):
        d, s, c = ops
        si = self.vsrc(s, st)
        for i in range(4):
            src = d.i if i < 2 else si
            self.emit('ins v25.s[%d], v%d.s[%d]' % (i, src, (c.value >> (2*i)) & 3))
        self.emit('mov v%d.16b, v25.16b' % d.i)

    def i_shufpd(self, st, ops, need, k):
        d, s, c = ops
        si = self.vsrc(s, st)
        self.emit('ins v25.d[0], v%d.d[%d]' % (d.i, c.value & 1))
        self.emit('ins v25.d[1], v%d.d[%d]' % (si, (c.value >> 1) & 1))
        self.emit('mov v%d.16b, v25.16b' % d.i)

    # x87 is used only for Vorbis initialization/unpacking. Its stack becomes
    # dedicated d8-d15 registers; calls below save the full decoder machine.
    def operand(self, text, st):
        m = re.fullmatch(r'st\((\d)\)', text.strip(), re.I)
        if m:
            return ('fp', int(m[1]))
        return super().operand(text, st)

    def fp_push(self):
        available = next(i for i in range(8, 16) if i not in self.fp_stack)
        self.fp_stack.insert(0, available)
        return available

    def i_fild(self, st, ops, need, k):
        s = ops[0]
        S = self.get(s, s.bits, 11)
        self.emit('scvtf d%d, %s' % (self.fp_push(), S))

    def i_fld(self, st, ops, need, k):
        s = ops[0]
        self.emit('ldr d%d, %s' % (self.fp_push(), self.addr(s, 8)))

    def i_fstp(self, st, ops, need, k):
        d = ops[0]
        top = self.fp_stack.pop(0)
        if isinstance(d, tuple):
            if d[1] != 0: self.err(st, 'unsupported x87 store')
        elif d.bits == 32:
            self.emit('fcvt s25, d%d' % top)
            self.emit('str s25, %s' % self.addr(d, 4))
        else:
            self.emit('str d%d, %s' % (top, self.addr(d, 8)))

    def fp_op(self, st, ops, op, pop=False):
        if pop:
            source = self.fp_stack.pop(0)
            target = self.fp_stack[0]
        else:
            target = self.fp_stack[0]
            source = target if len(ops) == 2 else self.dsrc(ops[0], st)
        self.emit('%s d%d, d%d, d%d' % (op, target, target, source))

    def i_fadd(self, st, ops, need, k): self.fp_op(st, ops, 'fadd')
    def i_fmul(self, st, ops, need, k): self.fp_op(st, ops, 'fmul')
    def i_fdiv(self, st, ops, need, k): self.fp_op(st, ops, 'fdiv')
    def i_faddp(self, st, ops, need, k): self.fp_op(st, ops, 'fadd', True)
    def i_fmulp(self, st, ops, need, k): self.fp_op(st, ops, 'fmul', True)
    def i_fdivp(self, st, ops, need, k): self.fp_op(st, ops, 'fdiv', True)

    def i_fscale(self, st, ops, need, k):
        self.emit('fmov d24, d%d' % self.fp_stack[0])
        self.emit('fcvtzs w25, d%d' % self.fp_stack[1])
        self.emit('sub x28, x28, #8')
        self.emit('bl lamp_fp_ldexp')
        self.emit('fmov d%d, d24' % self.fp_stack[0])

    def i_fsin(self, st, ops, need, k):
        self.emit('fmov d24, d%d' % self.fp_stack[0])
        self.emit('sub x28, x28, #8')
        self.emit('bl lamp_fp_sin')
        self.emit('fmov d%d, d24' % self.fp_stack[0])

    def i_fsincos(self, st, ops, need, k):
        sine = self.fp_stack[0]
        self.emit('fmov d24, d%d' % sine)
        self.emit('sub x28, x28, #8')
        self.emit('bl lamp_fp_sincos')
        self.emit('fmov d%d, d24' % sine)
        self.emit('fmov d%d, d25' % self.fp_push())


if __name__ == '__main__':
    a.Translator = Translator
    sys.exit(a.main(sys.argv[1:]))
