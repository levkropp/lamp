#!/usr/bin/env python3
"""Normalize LAMP's MASM sources for the build-time Rhun AArch64 translator.

Windows sources remain authoritative. No code is interpreted at runtime.
"""
import ast
import re
from pathlib import Path

TYPES = {'db': ('.byte', 1), 'dw': ('.short', 2), 'dd': ('.long', 4),
         'dq': ('.quad', 8), 'real4': ('.float', 4), 'real8': ('.double', 8)}


def expression(s):
    s = re.sub(r'\b([0-9][0-9a-fA-F]*)h\b', lambda m: '0x' + m[1], s)
    return s


def arguments(s):
    # Commas inside DUP and strings are not separators.
    return re.split(r",(?=(?:[^'\"]|'[^']*'|\"[^\"]*\")*$)(?![^()]*\))", s)


def data(kind, text):
    directive, width = TYPES[kind]
    out = []
    for arg in arguments(text):
        arg = arg.strip()
        m = re.fullmatch(r'(.*?)\s+dup\s*\((.*)\)', arg, re.I)
        if m:
            count_expr = expression(m[1]).strip()
            if m[2].strip() in ('?', '0', '0.0'):
                out.append('.zero (%s)*%d' % (count_expr, width))
            else:
                if not re.fullmatch(r'[0-9xa-fA-F*+ ()-]+', count_expr):
                    raise ValueError('Unsupported DUP count: ' + count_expr)
                count = eval(count_expr, {'__builtins__': {}}, {})
                out += data(kind, m[2]) * count
        elif arg == '?':
            out.append('.zero %d' % width)
        elif arg.startswith(("'", '"')):
            value = ast.literal_eval(arg)
            if width == 1:
                out.append('.byte ' + ','.join(str(b) for b in value.encode('utf-8')))
            else:
                out.append(directive + ' ' + ','.join(str(ord(c)) for c in value))
        else:
            out.append(directive + ' ' + expression(arg))
    return out


def procedures(path, seen=None):
    """Include-defined entry points need ABI bridges too (e.g. Vorbis native)."""
    seen = set() if seen is None else seen
    path = path.resolve()
    if path in seen:
        return set()
    seen.add(path)
    text = path.read_text()
    result = set(re.findall(r'^(\w+)\s+PROC\b', text, re.M | re.I))
    for name in re.findall(r'^\s*include\s+(\S+)', text, re.M | re.I):
        result |= procedures(path.parent / name, seen)
    return result


def data_size(kind, text):
    size = 0
    for arg in arguments(text):
        arg = arg.strip()
        dup = re.fullmatch(r'(.*?)\s+dup\s*\((.*)\)', arg, re.I)
        if dup:
            count = expression(dup[1]).strip()
            if not re.fullmatch(r'[0-9xa-fA-F*+ ()-]+', count):
                return None
            size += eval(count, {'__builtins__': {}}, {}) * data_size(kind, dup[2])
        elif arg.startswith(("'", '"')):
            size += len(ast.literal_eval(arg).encode('utf-8')) * TYPES[kind][1]
        else:
            size += TYPES[kind][1]
    return size


def normalize(path):
    out = ['.intel_syntax noprefix']
    params = []
    publics = []
    functions = procedures(path)
    for raw in path.read_text().splitlines():
        quote = None
        end = len(raw)
        for i, ch in enumerate(raw):
            if ch in "'\"":
                quote = None if ch == quote else (ch if quote is None else quote)
            elif ch == ';' and quote is None:
                end = i
                break
        s = raw[:end].strip()
        if not s:
            continue
        low = s.lower()
        if low.startswith(('option ', 'extern ', 'endp', 'end ')) or low == 'end':
            continue
        if low.startswith('public '):
            publics += [x.strip() for x in s[7:].split(',')]
            out.append('.globl ' + s[7:])
        elif low in ('.data', '.data?', '.code', '.const'):
            out.append({'.data': '.data', '.data?': '.bss', '.code': '.text',
                        '.const': '.section .rodata'}[low])
        elif low.startswith('include '):
            out.append('.include "' + s.split()[1] + '"')
        elif low.startswith('align '):
            out.append('.p2align ' + str(int(s.split()[1]).bit_length() - 1))
        elif re.match(r'^\w+\s+equ\s+', s, re.I):
            name, _, value = s.split(None, 2)
            out.append('.equ ' + name + ', ' + expression(value))
        elif re.match(r'^\w+\s+proc\b', s, re.I):
            out += ['.p2align 4', s.split()[0] + ':']
        elif re.match(r'^\w+\s+endp\b', s, re.I):
            continue
        elif re.match(r'^\w+\s+macro\b', s, re.I):
            fields = s.split(None, 2)
            params = [x.strip() for x in fields[2].split(',')] if len(fields) > 2 else []
            out.append('.macro ' + fields[0] + ' ' + ','.join(params))
        elif low == 'endm':
            out.append('.endm')
            params = []
        elif low.startswith('if '):
            cond = expression(s[3:])
            cond = re.sub(r'\bNE\b', '!=', cond)
            cond = re.sub(r'\bEQ\b', '==', cond)
            for p in params:
                cond = re.sub(r'\b' + re.escape(p) + r'\b', lambda m: '\\' + p, cond)
            out.append('.if ' + cond)
        elif low == 'endif':
            out.append('.endif')
        else:
            m = re.match(r'^(?:(\w+)\s+)?(db|dw|dd|dq|real4|real8)\s+(.+)$', s, re.I)
            if m:
                if m[1]:
                    out.append(m[1] + ':')
                out += data(m[2].lower(), m[3])
                if m[1]:
                    size = data_size(m[2].lower(), m[3])
                    if size is not None:
                        out.append('.equ %s__size, %d' % (m[1], size))
                continue
            if re.match(r'^\w+\s+label\s+\w+$', low):
                out.append(s.split()[0] + ':')
                continue
            s = expression(s)
            s = s.replace('::', ':')
            m = re.match(r'lea\s+(\w+)\s*,\s*([^\[].*)$', s, re.I)
            if m:
                s = 'lea %s,[rip+%s]' % (m[1], m[2].strip())
            s = re.sub(r'\bSIZEOF\s+(\w+)\b', r'\1__size', s)
            # MASM's OFFSET is an address; Rhun expects RIP-relative LEA.
            m = re.match(r'mov\s+(\w+)\s*,\s*offset\s+(\w+)', s, re.I)
            if m:
                s = 'lea %s,[rip+%s]' % (m[1], m[2])
            # RIP-relative globals; symbol+register is split before translation below.
            def address(m):
                inner = m[1]
                terms = re.findall(r'[A-Za-z_]\w*', inner)
                if not any(x.lower() in REGISTERS for x in terms):
                    return '[rip+' + inner + ']'
                return '[' + inner + ']'
            s = re.sub(r'\[([^]]+)\]', address, s)
            for p in params:
                s = re.sub(r'\b' + re.escape(p) + r'\b', lambda m: '\\' + p, s)
            out.append(s)
    for name in publics:
        if name not in functions:
            out += ['.globl _' + name, '.set _%s, %s' % (name, name)]
    return '\n'.join(out) + '\n'


REGISTERS = {'rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi',
             *('r%d' % i for i in range(8, 16))}


def main():
    import argparse
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path)
    p.add_argument('output', type=Path)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for path in sorted(args.source.iterdir()):
        if path.suffix in ('.asm', '.inc'):
            (args.output / path.name).write_text(normalize(path))


if __name__ == '__main__':
    main()
