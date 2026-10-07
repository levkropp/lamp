// macOS services for main's shared assembly decoders. UTF-8 paths on macOS.
.include "mac.inc"

// Preserve Windows nonvolatile registers, the SIMD machine, and x87 temporaries
// around libSystem. Return in x8 and consume Rhun's private return slot.
.macro WIN_ENTER
    ENTER 448
    stp x0, x1, [sp]
    stp q0, q1, [sp, #32]
    stp q2, q3, [sp, #64]
    stp q4, q5, [sp, #96]
    stp q6, q7, [sp, #128]
    stp q8, q9, [sp, #160]
    stp q10, q11, [sp, #192]
    stp q12, q13, [sp, #224]
    stp q14, q15, [sp, #256]
    stp q16, q17, [sp, #288]
    stp q18, q19, [sp, #320]
    stp q20, q21, [sp, #352]
    stp q22, q23, [sp, #384]
.endm
.macro WIN_LEAVE
    mov x8, x0
    ldp x0, x1, [sp]
    ldp q0, q1, [sp, #32]
    ldp q2, q3, [sp, #64]
    ldp q4, q5, [sp, #96]
    ldp q6, q7, [sp, #128]
    ldp q8, q9, [sp, #160]
    ldp q10, q11, [sp, #192]
    ldp q12, q13, [sp, #224]
    ldp q14, q15, [sp, #256]
    ldp q16, q17, [sp, #288]
    ldp q18, q19, [sp, #320]
    ldp q20, q21, [sp, #352]
    ldp q22, q23, [sp, #384]
    LEAVE
    XRET
.endm

FN CreateFileW
    WIN_ENTER
    mov x0, x3
    mov w1, #0
    bl _open
    sxtw x0, w0
    WIN_LEAVE

FN GetFileSizeEx
    WIN_ENTER
    mov x19, x2
    mov x0, x3
    mov x1, #0
    mov w2, #2
    bl _lseek
    cmp x0, #0
    b.lt 1f
    str x0, [x19]
    mov w0, #1
    b 2f
1:  mov w0, #0
2:  WIN_LEAVE

FN CreateFileMappingW
    WIN_ENTER
    mov x0, x3
    bl _dup
    cmp w0, #0
    b.lt 1f
    add x0, x0, #1
    orr x0, x0, #0x100000000
    b 2f
1:  mov x0, #0
2:  WIN_LEAVE

FN MapViewOfFile
    WIN_ENTER
    sub w19, w3, #1
    mov x0, x19
    mov x1, #0
    mov w2, #2
    bl _lseek
    cmp x0, #0
    b.le 1f
    mov x1, x0
    ADR x9, mapped_size
    str x1, [x9]
    mov x0, #0
    mov w2, #1
    mov w3, #2
    mov x4, x19
    mov x5, #0
    bl _mmap
    cmn x0, #1
    b.ne 2f
1:  mov x0, #0
2:  WIN_LEAVE

FN UnmapViewOfFile
    WIN_ENTER
    mov x0, x3
    ADR x9, mapped_size
    ldr x1, [x9]
    bl _munmap
    cmp w0, #0
    cset w0, eq
    WIN_LEAVE

FN CloseHandle
    WIN_ENTER
    // The mapping fd is tagged with bit 32 to distinguish it from file fd.
    mov x0, x3
    tbnz x3, #32, 1f
    b 2f
1:  sub w0, w3, #1
2:  bl _close
    cmp w0, #0
    cset w0, eq
    WIN_LEAVE

FN VirtualAlloc
    WIN_ENTER
    // Vorbis reserves one zeroed arena, then commits successive ranges inside
    // it. calloc supplies lazy zero pages for the entire reservation. A commit
    // at an existing address must return that address, never allocate a block.
    cbz x3, 3f
    tbz x4, #12, 2f // MEM_COMMIT
    mov x0, x3
    b 1f
3:
    adds x1, x2, #16
    b.cs 2f
    mov x19, x2
    mov x0, #1
    bl _calloc
    cbz x0, 1f
    str x19, [x0]
    ADR x9, _lamp_allocated_bytes
    ldr x10, [x9]
    add x10, x10, x19
    str x10, [x9]
    add x0, x0, #16
    b 1f
2:  mov x0, #0
1:  WIN_LEAVE

FN VirtualFree
    WIN_ENTER
    sub x0, x3, #16
    ldr x10, [x0]
    ADR x9, _lamp_allocated_bytes
    ldr x11, [x9]
    sub x11, x11, x10
    str x11, [x9]
    bl _free
    mov w0, #1
    WIN_LEAVE

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
mapped_size: .quad 0
.globl _lamp_allocated_bytes
_lamp_allocated_bytes: .quad 0
