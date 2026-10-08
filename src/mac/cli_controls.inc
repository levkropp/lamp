// Stateful terminal escapes can arrive across separate reads. Plain brackets
// select chapters; ESC [ / ESC O introduce arrow and Home keys.
.text
cli_key:
    ENTER
    ADR x9, cli_escape
    ldr w10, [x9]
    str wzr, [x9]
    cmp w0, #27
    b.eq escape
    cmp w10, #1
    b.eq escape_prefix
    cmp w10, #2
    b.eq escape_key
    cmp w0, #32
    b.eq pause_key
    cmp w0, #110 // N/n/>
    b.eq next_key
    cmp w0, #78
    b.eq next_key
    cmp w0, #62
    b.eq next_key
    cmp w0, #112 // P/p/<
    b.eq previous_key
    cmp w0, #80
    b.eq previous_key
    cmp w0, #60
    b.eq previous_key
    cmp w0, #114
    b.eq repeat_key
    cmp w0, #82
    b.eq repeat_key
    cmp w0, #93
    b.eq chapter_next
    cmp w0, #91
    b.eq chapter_previous
    b key_done
escape:
    mov w10, #1
    str w10, [x9]
    b key_done
escape_prefix:
    cmp w0, #91
    b.eq 1f
    cmp w0, #79
    b.ne key_done
1:  mov w10, #2
    str w10, [x9]
    b key_done
escape_key:
    mov w1, #5
    cmp w0, #67
    b.eq seek_key
    mov w1, #-5
    cmp w0, #68
    b.eq seek_key
    mov w1, #60
    cmp w0, #65
    b.eq seek_key
    mov w1, #-60
    cmp w0, #66
    b.eq seek_key
    cmp w0, #72
    b.ne key_done
    mov x0, #0
    bl _lamp_seek
    b key_done
seek_key:
    mov w0, #3
    bl _lamp_navigate
    b key_done
next_key:
    mov w0, #1
    b navigate_key
previous_key:
    mov w0, #2
    b navigate_key
chapter_next:
    mov w0, #6
    b navigate_key
chapter_previous:
    mov w0, #7
navigate_key:
    mov w1, #0
    bl _lamp_navigate
    b key_done
pause_key:
    bl _lamp_pause
    b key_done
repeat_key:
    bl _lamp_toggle_repeat
    ADR x9, repeat_on
    ADR x10, repeat_off
    cmp w0, #0
    csel x0, x9, x10, ne
    bl _puts
key_done:
    LEAVE
    ret
.section __TEXT,__cstring,cstring_literals
repeat_on: .asciz "Repeat: on"
repeat_off: .asciz "Repeat: off"
.data
.p2align 2
cli_escape: .long 0
