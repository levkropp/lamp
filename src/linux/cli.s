# LAMP Linux command-line player, decode check and float32 export. MIT license.
# Static executable: raw system calls, no C library. Output and exit codes
# match the Windows lamp-cli: 0 success, 2 decode/input error, 3 audio error,
# 4 output error.
.include "lamp.inc"
.include "linux.inc"

.equ CHUNK_FRAMES, 2048

.data
usage:
    .ascii "LAMP 0.4.0-dev - Lev's Assembly Media Player\n"
    .ascii "Handwritten x86-64 assembly: PCM, G.711, IMA/MS/Flash ADPCM, FLAC, ALAC, WavPack, MP1/MP2/MP3, AAC-LC/HE-AAC, AC-3,\n"
    .ascii "Vorbis, Opus "
    .ascii "in WAV/W64, AIFF/AIFC, CAF, FLAC, WavPack, MP3, AAC (ADTS), AC-3, Ogg, Matroska/WebM, MP4/MOV, AVI, FLV and MPEG-TS/PS files.\n"
    .ascii "Usage: lamp-cli file.mp3 [more files...]\n"
    .ascii "       lamp-cli --check file.flac [more files...]\n"
    .ascii "       lamp-cli --decode file.flac [more files...] output.f32\n"
    .ascii "       lamp-cli --tags file.mp3\n"
    .ascii "Several files play one after another without a gap, at the first file's rate;\n"
    .ascii "M3U/M3U8 and PLS playlists add their entries.\n"
    .ascii "Playback: Space pauses/resumes; Q or Ctrl+C stops.\n"
    .ascii "RIFF/RIFX/RF64/BW64/W64 WAV: 1..8 channels, PCM 8/16/24/32 or float32/64.\n"
    .ascii "AIFF/AIFC: signed PCM 1..32 bits or float32/64, 1..8 channels.\n"
    .ascii "Native FLAC: 4..32 bit, 1..8 channels, speaker-mask-aware downmix.\n"
    .asciz "Opus families 0/1; playback and float export output stereo.\n"
open_error: .asciz "Unsupported, malformed, or inaccessible file. Supports WAV/W64, AIFF/AIFC, CAF, FLAC, WavPack, MP1/MP2/MP3, AAC (LC, HE), AC-3, Ogg (Vorbis, Opus, FLAC), Matroska/WebM, MP4/MOV, AVI, FLV and MPEG-TS/PS audio.\n"
output_error: .asciz "Cannot create output file.\n"
stats_a: .asciz "codec="
stats_b: .asciz " rate="
stats_c: .asciz " channels="
stats_d: .asciz " bits="
stats_e: .asciz " frames="
stats_f: .asciz " underruns="
stats_g: .asciz " decode_error="
stats_h: .asciz " audio_error="
stats_i: .asciz " elapsed_ms="
stats_j: .asciz " cpu_us="
stats_k: .asciz " endpoint_dry="
newline: .asciz "\n"
check_arg: .asciz "--check"
decode_arg: .asciz "--decode"
tags_arg: .asciz "--tags"
equals_text: .asciz "="
skipped_text: .asciz "Skipped (unsupported, malformed, or inaccessible): "
output_fd: .quad -1

.bss
.p2align 4
offline_pcm: .zero CHUNK_FRAMES*8
number_buffer: .zero 32
tag_line: .zero 4100
timespec: .zero 16
argc: .quad 0
argv: .quad 0
start_ms: .quad 0
operation: .long 0             # 0 play, 1 check, 2 decode, 3 tags
exit_code: .long 0

.text
FN _start
    mov rax, [rsp]
    mov [rip + argc], rax
    lea rcx, [rsp + 8]
    mov [rip + argv], rcx
    lea rcx, [rcx + rax*8 + 8]
    mov [rip + linux_envp], rcx
    and rsp, -16
    call cli_main
    mov edi, eax
    mov eax, SYS_exit_group
    syscall
ENDFN _start

LOCALFN cli_main
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov ecx, CLOCK_MONOTONIC
    call clock_ms
    mov [rip + start_ms], rax
    mov rbx, [rip + argv]
    cmp qword ptr [rip + argc], 2
    jb .Lshow_help
    mov rcx, [rbx + 8]
    lea rdx, [rip + check_arg]
    call equal_text
    test eax, eax
    jz .Ltry_decode
    cmp qword ptr [rip + argc], 3
    jb .Lshow_help
    mov dword ptr [rip + operation], 1
    lea r12, [rbx + 16]                # inputs
    mov rsi, [rip + argc]
    sub rsi, 2
    jmp .Lopen_input
.Ltry_decode:
    mov rcx, [rbx + 8]
    lea rdx, [rip + tags_arg]
    call equal_text
    test eax, eax
    jz .Ltry_decode_arg
    cmp qword ptr [rip + argc], 3
    jne .Lshow_help
    mov dword ptr [rip + operation], 3
    lea rax, [rip + engine_stop_requested]
    mov [rip + ogg_cancel_ptr], rax
    mov rcx, [rbx + 16]
    call decoder_open
    test eax, eax
    jz .Lbad_input
    jmp .Ltags_only
.Ltry_decode_arg:
    mov rcx, [rbx + 8]
    lea rdx, [rip + decode_arg]
    call equal_text
    test eax, eax
    jz .Lplay_args
    cmp qword ptr [rip + argc], 4
    jb .Lshow_help
    mov dword ptr [rip + operation], 2
    mov rax, [rip + argc]
    mov rdi, [rbx + rax*8 - 8] # the last argument; create new: never truncate
    mov esi, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
    mov edx, 0644
    mov eax, SYS_open
    syscall
    test eax, eax
    js .Lbad_output
    mov [rip + output_fd], rax
    lea r12, [rbx + 16]
    mov rsi, [rip + argc]
    sub rsi, 3
    jmp .Lopen_input
.Lplay_args:
    lea r12, [rbx + 8]
    mov rsi, [rip + argc]
    dec rsi
.Lopen_input:
    lea rax, [rip + engine_stop_requested]
    mov [rip + ogg_cancel_ptr], rax
    lea rax, [rip + report_skipped]
    mov [rip + queue_skipped], rax
    mov rcx, r12
    mov edx, esi
    call playlist_expand               # M3U and PLS playlists become their entries
    mov rcx, rax
    call queue_begin                   # files play one after another
    test eax, eax
    jz .Lbad_input
    cmp dword ptr [rip + operation], 0
    je .Lplayback
.Loffline_loop:
    lea rcx, [rip + offline_pcm]
    mov edx, CHUNK_FRAMES
    call queue_read
    test eax, eax
    jz .Loffline_finished
    add [rip + decoded_count], rax
    cmp dword ptr [rip + operation], 2
    jne .Loffline_loop
    mov r8d, eax
    shl r8d, 3
    mov rcx, [rip + output_fd]
    lea rdx, [rip + offline_pcm]
    call write_all
    test eax, eax
    jz .Lbad_output
    jmp .Loffline_loop
.Loffline_finished:
    cmp dword ptr [rip + decode_error], 0   # the queue checks each file's length
    jne .Ldecoding_failed
    jmp .Lreport_finish
.Ldecoding_failed:
    mov dword ptr [rip + exit_code], 2
    jmp .Lreport_finish
.Ltags_only:
    call print_tags
    jmp .Lcleanup
.Lplayback:
    call print_tags
    lea rax, [rip + announce_next]
    mov [rip + queue_announce], rax
    mov ecx, 1                         # console: messages, Space/Q, Ctrl+C
    call engine_start
    mov [rip + exit_code], eax
    cmp eax, 3
    je .Lcleanup                       # the engine reported the audio failure
    jmp .Lreport_finish
.Lreport_finish:
    call report_stats
    jmp .Lcleanup
.Lbad_input:
    mov dword ptr [rip + exit_code], 2
    lea rcx, [rip + open_error]
    call print_text
    jmp .Lcleanup
.Lbad_output:
    mov dword ptr [rip + exit_code], 4
    lea rcx, [rip + output_error]
    call print_text
    jmp .Lcleanup
.Lshow_help:
    lea rcx, [rip + usage]
    call print_text
.Lcleanup:
    call decoder_close
    mov rdi, [rip + output_fd]
    test rdi, rdi
    js .Lcleanup_done
    mov eax, SYS_close
    syscall
    mov qword ptr [rip + output_fd], -1
.Lcleanup_done:
    mov eax, [rip + exit_code]
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN cli_main

# RCX, RDX = NUL-terminated strings -> EAX=1 when equal.
LOCALFN equal_text
.Lequal_loop:
    movzx eax, byte ptr [rcx]
    cmp al, [rdx]
    jne .Lequal_no
    inc rcx
    inc rdx
    test eax, eax
    jnz .Lequal_loop
    mov eax, 1
    ret
.Lequal_no:
    xor eax, eax
    ret
ENDFN equal_text

# RCX=fd, RDX=buffer, R8=bytes -> EAX=1 when every byte was written.
FN write_all
    push rdi
    push rsi
    push rbx
    mov rbx, r8
    mov rsi, rdx
    mov rdi, rcx
.Lwrite_more:
    test rbx, rbx
    jz .Lwrite_done
    mov rdx, rbx
    mov eax, SYS_write
    syscall
    cmp rax, -EINTR
    je .Lwrite_more
    test rax, rax
    jle .Lwrite_failed
    add rsi, rax
    sub rbx, rax
    jmp .Lwrite_more
.Lwrite_done:
    mov eax, 1
    jmp .Lwrite_return
.Lwrite_failed:
    xor eax, eax
.Lwrite_return:
    pop rbx
    pop rsi
    pop rdi
    ret
ENDFN write_all

# RCX=NUL-terminated text, written to standard output.
FN print_text
    sub rsp, 40
    mov rdx, rcx
    xor r8d, r8d
.Ltext_length:
    cmp byte ptr [rdx + r8], 0
    je .Ltext_write
    inc r8
    jmp .Ltext_length
.Ltext_write:
    mov ecx, 1
    call write_all
    add rsp, 40
    ret
ENDFN print_text

# Queue hook: RCX=path of a file that does not play.
LOCALFN report_skipped
    push rbx
    sub rsp, 32
    mov rbx, rcx
    lea rcx, [rip + skipped_text]
    call print_text
    mov rcx, rbx
    call print_text
    lea rcx, [rip + newline]
    call print_text
    add rsp, 32
    pop rbx
    ret
ENDFN report_skipped

# Queue hook during playback: the next file's tags after a blank line.
LOCALFN announce_next
    sub rsp, 40
    lea rcx, [rip + newline]
    call print_text
    call print_tags
    add rsp, 40
    ret
ENDFN announce_next

# Writes the opened file's tags as "key=value" lines; control characters
# in values print as spaces.
LOCALFN print_tags
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    xor ebx, ebx
.Ltags_key:
    mov ecx, ebx
    call tags_get
    test rax, rax
    jz .Ltags_next
    mov rsi, rax
    mov edi, edx
    lea rax, [rip + tag_names]
    mov rcx, [rax + rbx*8]
    call print_text
    lea rcx, [rip + equals_text]
    call print_text
    lea rdx, [rip + tag_line]
    xor ecx, ecx
.Ltags_char:
    cmp ecx, edi
    jae .Ltags_write
    cmp ecx, 4096
    jae .Ltags_write
    movzx eax, byte ptr [rsi + rcx]
    cmp eax, 0x20
    jae .Ltags_store
    mov eax, 0x20
.Ltags_store:
    mov [rdx + rcx], al
    inc ecx
    jmp .Ltags_char
.Ltags_write:
    mov byte ptr [rdx + rcx], 10
    lea r8d, [rcx + 1]
    mov ecx, 1
    call write_all
.Ltags_next:
    inc ebx
    cmp ebx, 10
    jb .Ltags_key
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN print_tags

# RCX=unsigned value, written in decimal.
FN print_number
    sub rsp, 40
    mov rax, rcx
    lea r9, [rip + number_buffer + 31]
    mov byte ptr [r9], 0
    mov r8d, 10
.Lnumber_digit:
    xor edx, edx
    div r8
    add dl, '0'
    dec r9
    mov [r9], dl
    test rax, rax
    jnz .Lnumber_digit
    mov rcx, r9
    call print_text
    add rsp, 40
    ret
ENDFN print_number

# ECX=clock id -> RAX=milliseconds (CLOCK_PROCESS_CPUTIME_ID callers divide
# the nanosecond form from clock_ns instead).
LOCALFN clock_ms
    sub rsp, 40
    call clock_ns
    xor edx, edx
    mov ecx, 1000000
    div rcx
    add rsp, 40
    ret
ENDFN clock_ms

# ECX=clock id -> RAX=nanoseconds.
FN clock_ns
    push rdi
    push rsi
    mov edi, ecx
    lea rsi, [rip + timespec]
    mov eax, SYS_clock_gettime
    syscall
    mov rax, [rip + timespec]
    imul rax, rax, 1000000000
    add rax, [rip + timespec + 8]
    pop rsi
    pop rdi
    ret
ENDFN clock_ns

LOCALFN report_stats
    push rbx
    sub rsp, 32
    lea rcx, [rip + stats_a]
    call print_text
    mov ecx, [rip + codec_kind]
    call print_number
    lea rcx, [rip + stats_b]
    call print_text
    mov ecx, [rip + queue_rate]
    call print_number
    lea rcx, [rip + stats_c]
    call print_text
    mov ecx, [rip + source_channels]
    call print_number
    lea rcx, [rip + stats_d]
    call print_text
    mov ecx, [rip + source_bits]
    call print_number
    lea rcx, [rip + stats_e]
    call print_text
    mov rcx, [rip + decoded_count]
    call print_number
    lea rcx, [rip + stats_f]
    call print_text
    mov rcx, [rip + underruns]
    call print_number
    lea rcx, [rip + stats_g]
    call print_text
    mov ecx, [rip + decode_error]
    call print_number
    lea rcx, [rip + stats_h]
    call print_text
    mov ecx, [rip + audio_status]
    call print_number
    lea rcx, [rip + stats_i]
    call print_text
    mov ecx, CLOCK_MONOTONIC
    call clock_ms
    sub rax, [rip + start_ms]
    mov rcx, rax
    call print_number
    lea rcx, [rip + stats_j]
    call print_text
    mov ecx, CLOCK_PROCESS_CPUTIME_ID
    call clock_ns
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov rcx, rax
    call print_number
    lea rcx, [rip + stats_k]
    call print_text
    mov rcx, [rip + endpoint_dry]
    call print_number
    lea rcx, [rip + newline]
    call print_text
    add rsp, 32
    pop rbx
    ret
ENDFN report_stats
