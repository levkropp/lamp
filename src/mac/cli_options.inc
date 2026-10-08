// Options precede paths; -- ends option processing, including names starting
// with a dash. Modes, argument limits and time syntax match the shared CLI.
.include "abi.inc"
.text
cli_parse:
    ENTER
    mov x19, x0
    mov x20, x1
    mov x21, #1
1:  cmp x21, x19
    b.hs 8f
    ldr x22, [x20, x21, lsl #3]
    ldrb w9, [x22]
    cmp w9, #45
    b.ne 8f
    ldrb w9, [x22, #1]
    cmp w9, #45
    b.ne 8f
    add x21, x21, #1
    ldrb w9, [x22, #2]
    cbz w9, 8f
    ADR x23, cli_modes
2:  ldr x1, [x23]
    cbz x1, 4f
    mov x0, x22
    bl _strcmp
    cbz w0, 3f
    add x23, x23, #16
    b 2b
3:  ADR x9, cli_operation
    ldr w10, [x9]
    cbnz w10, 9f
    ldr w10, [x23, #8]
    str w10, [x9]
    b 1b
4:  mov x0, x22
    ADR x1, repeat_opt
    bl _strcmp
    cbnz w0, 5f
    ADR x9, _queue_repeat
    mov w10, #1
    str w10, [x9]
    b 1b
5:  cmp x21, x19
    b.hs 9f
    ldr x23, [x20, x21, lsl #3]
    add x21, x21, #1
    mov x0, x22
    ADR x1, start_opt
    bl _strcmp
    cbnz w0, 6f
    mov x0, x23
    ADR x1, cli_start_ms
    bl _lamp_parse_time
    cbz w0, 9f
    b 1b
6:  mov x0, x22
    ADR x1, rate_opt
    bl _strcmp
    cbnz w0, 7f
    mov x0, x23
    mov w1, #7
    mov w2, #1000
    mov w3, #0xb800
    movk w3, #11, lsl #16 // 768000
    bl cli_number
    cbz w0, 9f
    ADR x9, _queue_target
    str w0, [x9]
    b 1b
7:  mov x0, x22
    ADR x1, track_opt
    bl _strcmp
    cbnz w0, 9f
    mov x0, x23
    mov w1, #4
    mov w2, #1
    mov w3, #9999
    bl cli_number
    cbz w0, 9f
    ADR x9, _track_choice
    str w0, [x9]
    b 1b
8:  ADR x9, cli_operation
    ldr w10, [x9]
    cbz w10, 10f
    ADR x9, _queue_repeat
    ldr w9, [x9]
    cbnz w9, 9f
    cmp w10, #3
    b.lo 10f
    ADR x9, cli_start_ms
    ldr x9, [x9]
    cbnz x9, 9f
    ADR x9, _queue_target
    ldr w9, [x9]
    cbnz w9, 9f
10: mov x0, x21
    b 11f
9:  mov x0, #0
11: LEAVE
    ret

// text, maximum digit count, minimum, maximum -> number, or 0 on error.
cli_number:
    mov x4, x0
    mov w0, #0
    mov w5, #0
    mov w7, #10
1:  ldrb w6, [x4], #1
    cbz w6, 2f
    sub w6, w6, #48
    cmp w6, #9
    b.hi 3f
    cmp w5, w1
    b.hs 3f
    madd w0, w0, w7, w6
    add w5, w5, #1
    b 1b
2:  cmp w0, w2
    b.lo 3f
    cmp w0, w3
    b.hi 3f
    ret
3:  mov w0, #0
    ret

// Shared queue callback, entered in the private decoder convention. Keep the
// machine intact while printing a skipped path through native libSystem.
FN cli_skipped
    WIN_ENTER
    sub sp, sp, #16
    str x3, [sp]
    GOT x9, ___stderrp
    ldr x0, [x9]
    ADR x1, skipped_format
    bl _fprintf
    add sp, sp, #16
    mov w0, #0
    WIN_LEAVE

.section __TEXT,__cstring,cstring_literals
repeat_opt: .asciz "--repeat"
start_opt: .asciz "--start"
rate_opt: .asciz "--rate"
track_opt: .asciz "--track"
skipped_format: .asciz "Skipped (unsupported, malformed, or inaccessible): %s\n"
.data
.p2align 3
cli_modes: .quad check_opt, 1, decode_opt, 2, tags_opt, 3, chapters_opt, 4, cover_opt, 5, 0, 0
cli_paths: .quad 0
cli_start_ms: .quad 0
cli_operation: .long 0
cli_output: .long -1
