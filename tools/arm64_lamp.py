#!/usr/bin/env python3
"""LAMP-specific extensions to Rhun's MIT build-time AArch64 translator."""
import re
import sys
import arm64 as a


class Source(a.Source):
    """GNU source, including assembly-time assertions on data label distances."""

    def run(self, path):
        try:
            return super().run(path)
        finally:
            self.locations = {}

    def lookup(self, name):
        if name == '.':
            # Use a plain Source for layout constants to avoid recursive layout.
            partial = a.Source(self.incdirs, self.consts)
            partial.lazy = dict(self.lazy)
            partial.stmts = self.stmts + [a.Stmt('label', '.', ('<location>', 0), name='.')]
            layout = Translator(partial, '<location>')
            self.locations = {partial.stmts[k].name: ((section + 1) << 44) + offset
                              for k, (section, offset) in layout.data_off.items()}
            if '.' not in self.locations:
                raise a.Error('location assertion requires a known data-section offset')
            return self.locations['.']
        if name in self.consts:
            return self.consts[name]
        if name in self.lazy:
            # A forward reference must survive an unsuccessful early lookup.
            value = a.evaluate(self.lazy[name], self.lookup)
            self.consts[name] = value
            del self.lazy[name]
            return value
        if name in getattr(self, 'locations', {}):
            return self.locations[name]
        raise a.Unknown(name)

    def read_file(self, path):
        lines = []
        for line, origin in super().read_file(path):
            for st in a.split_statements(line):
                while (label := a.LABEL.match(st)):
                    lines.append((label[1] + ':', origin))
                    st = st[label.end():]
                if st: lines.append((st, origin))
        def expand(start, nested=False):
            out, i = [], start
            while i < len(lines):
                line, origin = lines[i]
                i += 1
                if line == '.endr':
                    if not nested: raise a.Error('unmatched .endr at %s:%s' % origin)
                    return out, i
                if line.startswith('.rept '):
                    count = a.evaluate(line[6:], self.lookup)
                    if not 0 <= count <= 65536: raise a.Error('repeat count exceeds build limit')
                    body, i = expand(i, True)
                    out.extend(body * count)
                else:
                    out.append((line, origin))
            if nested: raise a.Error('unterminated .rept in ' + path)
            return out, i
        return expand(0)[0]

    def statement(self, st, where):
        self.locations = {}  # data locations are only for the preceding .if expression
        if st.startswith('.error '):
            raise a.Error('%s:%s: %s' % (*where, st))
        return super().statement(st, where)


class Translator(a.Translator):
    WRITES_ALL = a.Translator.WRITES_ALL | {'comisd', 'ucomisd'}

    def __init__(self, *args):
        super().__init__(*args)
        self.fp_stack = []

    def analyze(self):
        # Native adapters consume this public function's carry result. Its
        # callers are outside the translated unit, invisible to Rhun's local
        # flag liveness analysis.
        for name in ('parse_time',):
            target = self.target(name, 0)
            if target is not None:
                self.mark_exports(target, {'C'})
        return super().analyze()

    def layout(self):
        # Shared GNU sources already specify their alignment. Inserting padding
        # before every .quad corrupts packed structures and table-relative offsets.
        self.data_off, self.pad = {}, set()
        sections, offsets, stack = {}, {}, []
        current = '.text'
        sizes = {'.byte': 1, '.short': 2, '.value': 2, '.word': 2, '.hword': 2,
                 '.long': 4, '.int': 4, '.quad': 8, '.float': 4, '.single': 4, '.double': 8}
        for k, st in enumerate(self.stmts):
            offset = offsets.setdefault(current, 0)
            if st.kind == 'label':
                if current != '.text' and offset is not None:
                    self.data_off[k] = (sections.setdefault(current, len(sections)), offset)
                continue
            if st.kind == 'ins':
                offsets[current] = None
                continue
            d, arg = st.name, st.args
            if d in ('.text', '.data', '.bss'):
                current = d
            elif d in ('.section', '.pushsection'):
                if d == '.pushsection': stack.append(current)
                current = self.section_for(arg) or current
            elif d == '.popsection':
                current = stack.pop()
            elif offset is not None:
                if d in sizes:
                    offsets[current] += sizes[d] * len(a.split_args(arg))
                elif d in ('.ascii', '.asciz', '.string'):
                    offsets[current] += sum(len(a.string_bytes(x)) + (d != '.ascii')
                                            for x in a.split_args(arg))
                elif d in ('.zero', '.skip', '.space'):
                    n = self.value(a.split_args(arg)[0])
                    offsets[current] = None if n is None else offset + n
                elif d == '.fill':
                    count, width, *_ = a.split_args(arg)
                    offsets[current] += self.value(count) * min(self.value(width), 8)
                elif d in ('.p2align', '.balign', '.align'):
                    n = self.src.value(a.split_args(arg)[0])
                    alignment = 1 << n if d == '.p2align' else n
                    offsets[current] = (offset + alignment - 1) // alignment * alignment
                elif d == '.incbin':
                    self.err(st, 'binary include layout is not supported')

    def label_lookup(self, name):
        if name in self.src.lazy:
            return a.evaluate(self.src.lazy[name], self.label_lookup)
        return super().label_lookup(name)

    def directive(self, st, sect, stack):
        if st.name in ('.equ', '.set'):
            name, expr = map(str.strip, st.args.split(',', 1))
            value = self.value(expr)
            if value is not None:
                self.out.append('.set %s, %d' % (self.ren(name), value))
                return None
        if st.name == '.fill':
            values = [self.value(x) for x in a.split_args(st.args)]
            if any(x is None for x in values): self.err(st, 'unknown fill constant')
            self.out.append('.fill ' + ', '.join(map(str, values)))
            return None
        return super().directive(st, sect, stack)

    def branch(self, st, mn):
        if mn in ('jp', 'jnp'):
            self.emit('%s w26, %s' % ('cbnz' if mn == 'jp' else 'cbz', self.ren(st.args[0])))
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

    def i_sbb(self, st, ops, need, k):
        d, s = ops
        bits = self.opsize(ops, st)
        if bits < 32: self.err(st, 'unsupported narrow borrow')
        D, S = self.get(d, bits, 11), self.get(s, bits, 12)
        # ARM's C is already !CF, exactly the borrow convention SBC needs.
        self.emit('sbc%s %s, %s, %s' % ('s' if need else '', a.rn(11, bits), D, S))
        self.put(d, bits, a.rn(11, bits))

    def i_loop(self, st, ops, need, k):
        self.emit('sub x3, x3, #1')  # LOOP preserves flags and tests full RCX.
        self.emit('cbnz x3, %s' % self.ren(st.args[0]))

    def i_pause(self, st, ops, need, k):
        self.emit('yield')

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
    i_movdqa = a.Translator.i_movups
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
        self.double_to_integer(st, ops, 'frintz')

    def i_cvtsd2si(self, st, ops, need, k):
        self.double_to_integer(st, ops, 'frintn')

    def double_to_integer(self, st, ops, rounding):
        d, s = ops
        si = self.dsrc(s, st)
        # Match SSE's indefinite integer for NaN/overflow, rather than ARM's
        # zero/saturation. Preserve integer flags through the range comparison.
        self.emit('mrs x16, nzcv')
        self.emit('%s d26, d%d' % (rounding, si))
        self.emit('mov x11, #%d' % ((1023 + d.bits - 1) << 52))
        self.emit('fmov d27, x11')
        self.emit('fcmp d26, d27')
        self.emit('cset w12, lt')  # NaN fails both ordered comparisons.
        self.emit('fneg d27, d27')
        self.emit('fcmp d26, d27')
        self.emit('cset w13, ge')
        self.emit('and w12, w12, w13')
        self.emit('fcvtzs %s, d26' % a.rn(d.i, d.bits))
        self.emit('mov %s, #%d' % (a.rn(11, d.bits), 1 << (d.bits - 1)))
        self.emit('cmp w12, #0')
        self.emit('csel %s, %s, %s, ne' % (a.rn(d.i, d.bits), a.rn(d.i, d.bits), a.rn(11, d.bits)))
        self.emit('msr nzcv, x16')

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
    def i_paddd(self, st, ops, need, k): self.vop(st, ops, 'add', '4s')

    def i_pmaddwd(self, st, ops, need, k):
        d, s = ops
        si = self.vsrc(s, st)
        self.emit('smull v25.4s, v%d.4h, v%d.4h' % (d.i, si))
        self.emit('smull2 v26.4s, v%d.8h, v%d.8h' % (d.i, si))
        self.emit('addp v%d.4s, v25.4s, v26.4s' % d.i)

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
    def i_fnstcw(self, st, ops, need, k):
        # The translated x87 machine uses double precision, nearest-even.
        self.emit('mov w11, #0x27f')
        self.put(ops[0], 16, 'w11')

    def i_fldcw(self, st, ops, need, k):
        # Vorbis selects double precision then restores our saved control word.
        # Reject other uses until their precision/rounding behavior is implemented.
        if not isinstance(ops[0], a.Mem) or ops[0].sym not in ('vt_fpu_double', 'vt_fpu_saved'):
            self.err(st, 'unsupported x87 control word')
        self.emit('// x87 control remains double precision, nearest-even')

    def operand(self, text, st):
        if text.strip().lower().startswith('offset '):
            return a.Imm(text[7:].strip(), self.value(text[7:].strip()))
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
