// Native Apple ABI -> shared decoder ABI. One decoder instance, one owner thread.
.include "mac.inc"

FN _lamp_init
    ENTER
    ADR x9, _lamp_stack_top
    ldr x9, [x9]
    cbnz x9, 4f
    mov x0, #0
    mov x1, #0x1000000
    mov w2, #3
    mov w3, #0x1002
    mov w4, #-1
    mov x5, #0
    bl _mmap
    cmn x0, #1
    b.eq 1f
    mov x19, x0
    mov x1, #16384
    mov w2, #0
    bl _mprotect
    cbnz w0, 2f
    mov x9, #0x1000000
    add x9, x19, x9
    ADR x10, _lamp_stack_top
    str x9, [x10]
4:
    mov w0, #1
    b 3f
2:  mov x0, x19
    mov x1, #0x1000000
    bl _munmap
1:  mov w0, #0
3:  LEAVE
    ret

// AAPCS integer arguments x0-x7 become RCX/RDX/R8/R9 and Windows stack args.
// Translated SIMD registers do not alias AAPCS's saved d8-d15 (x87 does).
.macro BRIDGE name
FN _\name
    ENTER 192
    stp q8, q9, [sp]
    stp q10, q11, [sp, #32]
    stp q12, q13, [sp, #64]
    stp q14, q15, [sp, #96]
    stp x0, x1, [sp, #128]
    stp x2, x3, [sp, #144]
    stp x4, x5, [sp, #160]
    stp x6, x7, [sp, #176]
    ADR x9, _lamp_stack_top
    ldr x28, [x9]
    sub x28, x28, #64
    stp x4, x5, [x28, #32]
    stp x6, x7, [x28, #48]
    mov x5, x3
    mov x4, x2
    mov x2, x1
    mov x3, x0
    .ifc \name,op_celt_renormalize
    ins v2.s[0], v0.s[0]
    .endif
    XCALL \name
    mov x0, x8
    ldp q8, q9, [sp]
    ldp q10, q11, [sp, #32]
    ldp q12, q13, [sp, #64]
    ldp q14, q15, [sp, #96]
    LEAVE
    ret
.endm

BRIDGE decoder_open
BRIDGE decoder_read
BRIDGE decoder_seek
BRIDGE decoder_close

// These leaf getters return several private-ABI registers. Give native callers
// explicit output pointers; the generic C bridges remain single-result calls.
// lamp_tag_info(index, uint32_t *length) -> UTF-8 pointer.
FN _lamp_tag_info
    ENTER
    mov x19, x1
    mov x3, x0
    ADR x9, _lamp_stack_top
    ldr x28, [x9]
    sub x28, x28, #32
    XCALL tags_get
    str w2, [x19]
    mov x0, x8
    LEAVE
    ret

// lamp_cover_info(uint64_t *bytes, uint32_t *kind) -> borrowed image pointer.
FN _lamp_cover_info
    ENTER
    mov x19, x0
    mov x20, x1
    ADR x9, _lamp_stack_top
    ldr x28, [x9]
    sub x28, x28, #32
    XCALL cover_get
    str x2, [x19]
    str w4, [x20]
    mov x0, x8
    LEAVE
    ret

.data
.p2align 3
.globl _lamp_stack_top
_lamp_stack_top: .quad 0
