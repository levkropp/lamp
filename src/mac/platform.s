// macOS services for shared assembly decoders. UTF-8 paths on macOS.
.include "mac.inc"

.include "abi.inc"

// The shared service ABI uses UTF-8 paths, matching the Linux source branch.
// A mapping owns its length; several decoder/playlist mappings may coexist.
FN file_map
    WIN_ENTER
    mov x0, x3
    mov w1, #0
    bl _open
    cmp w0, #0
    b.lt 3f
    mov w19, w0
    mov x1, #0
    mov w2, #2
    bl _lseek
    mov x20, x0
    cmp x0, #0
    b.le 2f
    mov x1, x0
    mov x0, #0
    mov w2, #1
    mov w3, #2
    mov w4, w19
    mov x5, #0
    bl _mmap
    mov x21, x0
    mov w0, w19
    bl _close
    cmn x21, #1
    b.eq 3f
    mov x0, x21
    mov x2, x20
    mov x4, #0
    WIN_LEAVE
2:  mov w0, w19
    bl _close
3:  mov x0, #0
    mov x2, #0
    mov x4, #0
    WIN_LEAVE

FN file_unmap
    WIN_ENTER
    mov x0, x3
    mov x1, x2
    bl _munmap
    WIN_LEAVE

// Reserve/allocate page-aligned memory with a private header page. Commit
// changes protection inside a reservation, preserving its existing contents.
// Apple Silicon uses 16 KiB pages; the deployment target is ARM64 macOS only.
FN mem_alloc
    mov w2, #3
    b mem_map
FN mem_reserve
    mov w2, #0
mem_map:
    WIN_ENTER
    mov x19, x3
    mov w20, w2
    adds x21, x19, #0x4000
    b.cs 3f
    mov x9, #0x3fff
    adds x21, x21, x9
    b.cs 3f
    and x21, x21, #0xffffffffffffc000
    mov x0, #0
    mov x1, x21
    mov w2, #3
    mov w3, #0x1002
    mov w4, #-1
    mov x5, #0
    bl _mmap
    cmn x0, #1
    b.eq 3f
    mov x22, x0
    stp x21, x19, [x22]
    cbnz w20, 1f
    sub x1, x21, #0x4000
    cbz x1, 1f
    add x0, x22, #0x4000
    mov w2, #0
    bl _mprotect
    cbnz w0, 2f
1:  ADR x9, _lamp_allocated_bytes
    ldr x10, [x9]
    add x10, x10, x19
    str x10, [x9]
    add x0, x22, #0x4000
    WIN_LEAVE
2:  mov x0, x22
    mov x1, x21
    bl _munmap
3:  mov x0, #0
    WIN_LEAVE

FN mem_commit
    WIN_ENTER
    mov x19, x3
    and x0, x3, #0xffffffffffffc000
    adds x1, x3, x2
    b.cs 1f
    mov x9, #0x3fff
    adds x1, x1, x9
    b.cs 1f
    and x1, x1, #0xffffffffffffc000
    sub x1, x1, x0
    mov w2, #3
    bl _mprotect
    cmp w0, #0
    csel x0, x19, xzr, eq
    WIN_LEAVE
1:  mov x0, #0
    WIN_LEAVE

FN mem_free
    WIN_ENTER
    cbz x3, 1f
    sub x0, x3, #0x4000
    ldp x1, x19, [x0]
    bl _munmap
    cbnz w0, 1f
    ADR x9, _lamp_allocated_bytes
    ldr x10, [x9]
    sub x10, x10, x19
    str x10, [x9]
1:  WIN_LEAVE

// Math helpers used solely to initialize Vorbis tables. Native libSystem math,
// preserving all decoder GPRs and vectors; d24/d25 carry their results.
.macro FP_ENTER
    WIN_ENTER
    mrs x26, nzcv
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #416]
    stp x6, x7, [sp, #432]
    mov x19, x8
    fmov d0, d24
.endm
.macro FP_LEAVE
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #416]
    ldp x6, x7, [sp, #432]
    mov x0, x19
    msr nzcv, x26
    // WIN_LEAVE sets x8 to this saved rax.
    WIN_LEAVE
.endm

FN lamp_fp_sin
    FP_ENTER
    bl _sin
    fmov d24, d0
    FP_LEAVE

FN lamp_fp_sincos
    FP_ENTER
    fmov x20, d0
    bl _cos
    fmov x21, d0
    fmov d0, x20
    bl _sin
    fmov d24, d0
    fmov d25, x21
    FP_LEAVE

FN lamp_fp_ldexp
    FP_ENTER
    mov w0, w25
    bl _ldexp
    fmov d24, d0
    FP_LEAVE

.data
.p2align 3
.globl _lamp_allocated_bytes
_lamp_allocated_bytes: .quad 0
