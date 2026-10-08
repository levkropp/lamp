// Native CLI formatting over the shared metadata readers. Borrowed pointers
// stay valid until decoder_close. Output errors use the other CLIs' status 4.
.text
cli_print_tags:
    ENTER 16
    mov w19, #0
1:  mov w0, w19
    mov x1, sp
    bl _lamp_tag_info
    cbz x0, 5f
    mov x20, x0
    ldr w21, [sp]
    ADR x9, _tag_names
    ldr x0, [x9, x19, lsl #3]
    mov x22, x0
    bl _strlen
    mov x23, x0
    ADR x0, metadata_line
    mov x1, x22
    mov x2, x23
    bl _memcpy
    ADR x9, metadata_line
    add x9, x9, x23
    mov w10, #61 // '='
    strb w10, [x9], #1
    mov w10, #4096
    cmp w21, w10
    csel w21, w21, w10, lo
    mov w11, #0
2:  cmp w11, w21
    b.hs 3f
    ldrb w12, [x20, x11]
    cmp w12, #32
    mov w13, #32
    csel w12, w12, w13, hs
    strb w12, [x9, x11]
    add w11, w11, #1
    b 2b
3:  mov w12, #10
    strb w12, [x9, x21]
    mov w0, #1
    ADR x1, metadata_line
    add x2, x23, x21
    add x2, x2, #2 // '=' and newline
    bl cli_write_all
    cbz w0, 6f
5:  add w19, w19, #1
    cmp w19, #10
    b.lo 1b
    mov w0, #0
    b 7f
6:  mov w0, #4
7:  LEAVE
    ret

cli_print_chapters:
    ENTER
    bl _chapters_count
    mov w20, w0
    mov w19, #0
1:  cmp w19, w20
    b.hs 3f
    mov w0, w19
    ADR x1, metadata_line
    bl _chapter_line
    ADR x1, metadata_line
    mov w9, #10
    strb w9, [x1, x0]
    add x2, x0, #1
    mov w0, #1
    bl cli_write_all
    cbz w0, 4f
    add w19, w19, #1
    b 1b
3:  mov w0, #0
    b 5f
4:  mov w0, #4
5:  LEAVE
    ret

cli_export_cover:
    ENTER 32
    mov x19, x0
    mov x0, sp
    add x1, sp, #8
    bl _lamp_cover_info
    cbz x0, 3f
    mov x20, x0
    ldr x21, [sp]
    ldr w22, [sp, #8]
    mov x0, x19
    mov w1, #0xa01 // O_WRONLY | O_CREAT | O_EXCL
    mov x9, #420
    str x9, [sp] // open's variadic mode
    bl _open
    tbnz w0, #31, 4f
    mov w19, w0
    mov x1, x20
    mov x2, x21
    bl cli_write_all
    mov w20, w0
    mov w0, w19
    bl _close
    cbnz w0, 4f
    cbz w20, 4f
    ADR x9, _cover_mimes
    ldr x9, [x9, x22, lsl #3]
    stp x9, x21, [sp]
    ADR x0, cover_format
    bl _printf
    tbnz w0, #31, 4f
    mov w0, #0
    b 5f
3:  ADR x0, no_cover_message
    bl _puts
    mov w0, #2
    b 5f
4:  ADR x0, cover_write_error
    bl _puts
    mov w0, #4
5:  LEAVE
    ret

// fd, bytes, count -> 1 on complete write; retry interrupted system calls.
cli_write_all:
    ENTER
    mov w19, w0
    mov x20, x1
    mov x21, x2
1:  cbz x21, 3f
    mov w0, w19
    mov x1, x20
    mov x2, x21
    bl _write
    cmp x0, #0
    b.gt 2f
    b.eq 4f
    bl ___error
    ldr w9, [x0]
    cmp w9, #4 // EINTR
    b.eq 1b
    b 4f
2:  add x20, x20, x0
    sub x21, x21, x0
    b 1b
3:  mov w0, #1
    b 5f
4:  mov w0, #0
5:  LEAVE
    ret

.section __TEXT,__cstring,cstring_literals
cover_format: .asciz "%s %llu bytes\n"
no_cover_message: .asciz "No embedded cover art."
cover_write_error: .asciz "Cannot create or write the cover destination."
.bss
.p2align 4
metadata_line: .zero 4160 // longest key + '=' + 4096 UTF-8 bytes + newline
