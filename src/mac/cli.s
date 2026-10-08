// Native ARM64 command line. Assembly runtime, no C/Swift/Objective-C sources.
.include "mac.inc"

FN _main
    ENTER
    mov x19, x0
    mov x20, x1
    bl _lamp_init
    cbz w0, cli_init_bad
    cmp x19, #2
    b.ne 1f
    ldr x0, [x20, #8]
    ADR x1, version_opt
    bl _strcmp
    cbnz w0, 1f
    ADR x0, _lamp_version
    bl _puts
    mov w0, #0
    b cli_return
1:  mov x0, x19
    mov x1, x20
    bl cli_parse
    cbz w0, cli_usage
    sub w19, w19, w0
    add x20, x20, x0, lsl #3
    ADR x9, cli_operation
    ldr w22, [x9]
    cmp w22, #3
    b.hs cli_metadata
    cbz w19, cli_usage
    cbz w22, cli_play
    cmp w22, #2
    b.ne cli_open
    cmp w19, #2
    b.lo cli_usage
    sub w19, w19, #1
    ldr x0, [x20, x19, lsl #3]
    mov w1, #0xa01 // O_WRONLY | O_CREAT | O_EXCL
    mov w9, #420
    sub sp, sp, #16
    str x9, [sp]
    bl _open
    add sp, sp, #16
    tbnz w0, #31, cli_bad
    ADR x9, cli_output
    str w0, [x9]
cli_open:
    mov x0, x20
    mov w1, w19
    bl _lamp_prepare_paths
    cbz x0, cli_decoder_bad
    ADR x9, cli_paths
    str x0, [x9]
    ldr w1, [x0, #-16]
    ADR x9, _queue_skipped
    ADR x10, cli_skipped
    str x10, [x9]
    bl _queue_begin
    cbz w0, cli_decoder_bad
    ADR x9, cli_start_ms
    ldr x0, [x9]
    bl _queue_start
    mov x22, #0
cli_read:
    ADR x0, pcm
    mov w1, #4096
    bl _queue_read
    cbz w0, cli_done
    add x22, x22, x0
    mov x23, x0
    ADR x9, cli_output
    ldr w0, [x9]
    tbnz w0, #31, cli_read
    lsl x2, x23, #3
    ADR x1, pcm
    bl cli_write_all
    cbz w0, cli_close_bad
    b cli_read
cli_done:
    ADR x9, decode_error
    ldr w23, [x9]
    ADR x0, done_format
    sub sp, sp, #48
    ADR x9, codec_kind
    ldr w9, [x9]
    str x9, [sp]
    ADR x9, _queue_rate
    ldr w9, [x9]
    str x9, [sp, #8]
    ADR x9, source_channels
    ldr w9, [x9]
    str x9, [sp, #16]
    ADR x9, source_bits
    ldr w9, [x9]
    str x9, [sp, #24]
    str x22, [sp, #32]
    str x23, [sp, #40]
    bl _printf
    add sp, sp, #48
    cmp w23, #0
    cset w0, ne
    lsl w0, w0, #1
    b cli_finish
cli_decoder_bad:
    ADR x0, decode_message
    bl _puts
    mov w0, #2
    b cli_finish
cli_close_bad:
cli_bad:
    ADR x0, bad_message
    bl _puts
    mov w0, #1
cli_finish:
    mov w19, w0
    bl _decoder_close
    ADR x9, cli_paths
    ldr x0, [x9]
    str xzr, [x9]
    bl _lamp_free_paths
    ADR x9, cli_output
    ldr w0, [x9]
    tbnz w0, #31, 1f
    bl _close
    cmp w0, #0
    mov w9, #1
    csel w19, w19, w9, eq
1:  mov w0, w19
    b cli_return
cli_init_bad:
    ADR x0, bad_message
    bl _puts
    mov w0, #1
    b cli_return
cli_usage:
    ADR x0, usage
    bl _puts
    mov w0, #2
    b cli_return
cli_metadata:
    cmp w22, #5
    mov w9, #1
    cinc w9, w9, eq
    cmp w19, w9
    b.ne cli_usage
    ldr x0, [x20]
    bl _decoder_open
    cbz w0, cli_decoder_bad
    cmp w22, #3
    b.ne 1f
    bl cli_print_tags
    b cli_finish
1:  cmp w22, #4
    b.ne 2f
    bl cli_print_chapters
    b cli_finish
2:  ldr x0, [x20, #8]
    bl cli_export_cover
    b cli_finish
cli_play:
    bl _lamp_audio_init
    ADR x9, _queue_skipped
    ADR x10, cli_skipped
    str x10, [x9]
    mov x0, x20
    mov w1, w19
    ADR x9, cli_start_ms
    ldr x2, [x9]
    bl _lamp_play_list
    cbnz w0, 7f
    ADR x9, _lamp_decode_error
    ldr w9, [x9]
    cbnz w9, cli_decoder_bad
    b cli_bad
7:
    ADR x0, playing_message
    bl _puts
    bl terminal_enter
1:  ADR x9, interrupted
    ldr w9, [x9]
    cbnz w9, 3f
    ADR x0, poll_input
    mov w1, #1
    mov w2, #200
    bl _poll
    cmp w0, #0
    b.le 2f
    ADR x9, poll_input
    ldrh w9, [x9, #6]
    tbz w9, #0, 2f
    mov w0, #0
    ADR x1, key_byte
    mov w2, #1
    bl _read
    cmp x0, #1
    b.ne 4f
    ADR x9, key_byte
    ldrb w9, [x9]
    cmp w9, #113 // Q/q, Ctrl+C
    b.eq 3f
    cmp w9, #81
    b.eq 3f
    cmp w9, #3
    b.eq 3f
    cmp w9, #32
    b.ne 2f
    bl _lamp_pause
    b 2f
4:  ADR x9, poll_input
    mov w10, #-1 // no interactive input; keep playing to EOF
    str w10, [x9]
2:
    bl _lamp_tick
    cmp w0, #1
    b.eq 1b
    cmp w0, #2
    b.eq 1b
    cmp w0, #4
    cset w19, eq
    ADR x9, _lamp_decode_error
    ldr w9, [x9]
    cbz w9, 6f
    mov w19, #2
6:
    b 5f
3:  mov w19, #0
5:  bl terminal_leave
    bl _lamp_stop
    mov w0, w19
cli_return:
    LEAVE
    ret

// Keep output processing and signals, but read keys without Return or echo.
terminal_enter:
    ENTER
    mov w0, #2 // SIGINT; handler only writes a flag
    ADR x1, cli_interrupt
    bl _signal
    ADR x9, old_sigint
    str x0, [x9]
    mov w0, #0
    ADR x1, old_terminal
    bl _tcgetattr
    cbnz w0, 1f
    ADR x0, active_terminal
    ADR x1, old_terminal
    mov x2, #72
    bl _memcpy
    ADR x2, active_terminal
    ldr x9, [x2, #24]
    mov x10, #0x108 // ICANON | ECHO
    bic x9, x9, x10
    str x9, [x2, #24]
    mov w9, #1
    strb w9, [x2, #48] // VMIN
    strb wzr, [x2, #49] // VTIME
    mov w0, #0
    mov w1, #0 // TCSANOW
    bl _tcsetattr
    cbnz w0, 1f
    ADR x9, terminal_changed
    mov w10, #1
    str w10, [x9]
1:  LEAVE
    ret
terminal_leave:
    ENTER
    ADR x9, terminal_changed
    ldr w9, [x9]
    cbz w9, 1f
    mov w0, #0
    mov w1, #0
    ADR x2, old_terminal
    bl _tcsetattr
1:  mov w0, #2
    ADR x9, old_sigint
    ldr x1, [x9]
    bl _signal
    LEAVE
    ret
cli_interrupt:
    ADR x9, interrupted
    mov w10, #1
    str w10, [x9]
    ret

.include "cli_metadata.inc"
.include "cli_options.inc"

.section __TEXT,__cstring,cstring_literals
check_opt: .asciz "--check"
decode_opt: .asciz "--decode"
version_opt: .asciz "--version"
tags_opt: .asciz "--tags"
chapters_opt: .asciz "--chapters"
cover_opt: .asciz "--cover"
usage: .asciz "LAMP macOS ARM64\nUsage: lamp-cli [--repeat] [--start TIME] [--rate HZ] [--track N] FILE [MORE...]\n       lamp-cli --check [--start TIME] [--rate HZ] [--track N] FILE [MORE...]\n       lamp-cli --decode [--start TIME] [--rate HZ] [--track N] FILE [MORE...] NEW.f32\n       lamp-cli --tags FILE\n       lamp-cli --chapters FILE\n       lamp-cli --cover FILE NEW-IMAGE"
playing_message: .asciz "LAMP: Core Audio playback. Space pauses/resumes; Q or Ctrl+C stops."
bad_message: .asciz "LAMP: cannot open, decode or write this file."
decode_message: .asciz "Unsupported, malformed, or inaccessible audio file. See docs/compatibility.md for codec and container limits."
done_format: .asciz "codec=%u rate=%u channels=%u bits=%u frames=%llu decode_error=%u\n"
.bss
.p2align 3
old_sigint: .zero 8
old_terminal: .zero 72
active_terminal: .zero 72
terminal_changed: .zero 4
interrupted: .zero 4
key_byte: .zero 1
.p2align 4
pcm: .zero 32768
.data
.p2align 3
poll_input: .long 0
    .short 1, 0 // POLLIN
