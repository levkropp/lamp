# LAMP Linux command-line player, decode check and float32 export. MIT license.
# Static executable: raw system calls, no C library. Output and exit codes
# match the Windows lamp-cli: 0 success, 2 decode/input error, 3 audio error,
# 4 output error.
.include "lamp.inc"
.include "linux.inc"

.equ CHUNK_FRAMES, 2048
.equ RESUME_PATH, 8192

.data
usage:
    .ascii "LAMP 0.4.0-dev - Lev's Assembly Media Player\n"
    .ascii "Handwritten x86-64 assembly: PCM, G.711, IMA/MS/Flash ADPCM, FLAC, ALAC, WavPack, MP1/MP2/MP3, AAC-LC/HE-AAC, AC-3,\n"
    .ascii "Vorbis, Opus "
    .ascii "in WAV/W64, AIFF/AIFC, CAF, AU, FLAC, WavPack, MP3, AAC (ADTS), AC-3, Ogg, Matroska/WebM, MP4/MOV, AVI, FLV and MPEG-TS/PS files.\n"
    .ascii "Usage: lamp-cli [--start TIME] [--repeat] [--resume] file.mp3 [more files...]\n"
    .ascii "       lamp-cli --check [--start TIME] file.flac [more files...]\n"
    .ascii "       lamp-cli --decode [--start TIME] file.flac [more files...] output.f32\n"
    .ascii "       lamp-cli --tags file.mp3\n"
    .ascii "       lamp-cli --chapters file.m4b\n"
    .ascii "       lamp-cli --cover file.mp3 cover-image\n"
    .ascii "Several files play one after another without a gap, at the first file's rate;\n"
    .ascii "M3U/M3U8 and PLS playlists add their entries. --start begins the first file at TIME\n"
    .ascii "(seconds, M:S or H:M:S, with an optional fraction); --repeat plays the list again and again;\n"
    .ascii "--resume starts where Q stopped the same list and keeps where it stops.\n"
    .ascii "Playback: Space pauses/resumes; N/P next/previous file; arrows seek 5 s or 60 s;\n"
    .ascii "R toggles repeat; Q or Ctrl+C stops.\n"
    .ascii "RIFF/RIFX/RF64/BW64/W64 WAV: 1..8 channels, PCM 8/16/24/32 or float32/64.\n"
    .ascii "AIFF/AIFC: signed PCM 1..32 bits or float32/64, 1..8 channels.\n"
    .ascii "Native FLAC: 4..32 bit, 1..8 channels, speaker-mask-aware downmix.\n"
    .asciz "Opus families 0/1; playback and float export output stereo.\n"
open_error: .asciz "Unsupported, malformed, or inaccessible file. Supports WAV/W64, AIFF/AIFC, CAF, AU, FLAC, WavPack, MP1/MP2/MP3, AAC (LC, HE), AC-3, Ogg (Vorbis, Opus, FLAC), Matroska/WebM, MP4/MOV, AVI, FLV and MPEG-TS/PS audio.\n"
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
chapters_arg: .asciz "--chapters"
cover_arg: .asciz "--cover"
repeat_arg: .asciz "--repeat"
start_arg: .asciz "--start"
resume_arg: .asciz "--resume"
resume_xdg: .asciz "XDG_STATE_HOME"
resume_home: .asciz "HOME"
resume_xdg_tail: .asciz "/lamp/resume"
resume_home_tail: .asciz "/.local/state/lamp/resume"
resuming_text: .asciz "Resuming at "
.p2align 3
cli_modes: .quad check_arg, 1, decode_arg, 2, tags_arg, 3, chapters_arg, 4, cover_arg, 5, 0, 0
cli_start_ms: .quad 0
cli_repeat: .long 0
cli_resume: .long 0
cli_count: .long 0
.p2align 3
cli_paths: .quad 0                     # the expanded list
resume_ms: .quad 0
no_cover: .asciz "No embedded cover art.\n"
bytes_text: .asciz " bytes\n"
space_text: .asciz " "
equals_text: .asciz "="
skipped_text: .asciz "Skipped (unsupported, malformed, or inaccessible): "
output_fd: .quad -1

.bss
.p2align 4
offline_pcm: .zero CHUNK_FRAMES*8
number_buffer: .zero 32
tag_line: .zero 4100
resume_state: .zero RESUME_PATH
resume_temp: .zero RESUME_PATH
resume_key: .zero RESUME_PATH
resume_heard: .zero RESUME_PATH
resume_found: .zero RESUME_PATH
timespec: .zero 16
argc: .quad 0
argv: .quad 0
start_ms: .quad 0
operation: .long 0             # 0 play, 1 check, 2 decode, 3 tags, 4 chapters, 5 cover
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
    mov r12d, 1                        # argument index
    # Options before the files: one mode, --start TIME, --repeat, "--".
.Lcli_option:
    cmp r12, [rip + argc]
    jae .Lcli_files
    mov rsi, [rbx + r12*8]
    cmp word ptr [rsi], 0x2d2d         # "--"
    jne .Lcli_files
    inc r12
    cmp byte ptr [rsi + 2], 0
    je .Lcli_files                     # "--" ends the options
    lea rdi, [rip + cli_modes]
.Lcli_mode_entry:
    mov rdx, [rdi]
    test rdx, rdx
    jz .Lcli_other_option
    mov rcx, rsi
    call equal_text
    test eax, eax
    jnz .Lcli_mode
    add rdi, 16
    jmp .Lcli_mode_entry
.Lcli_mode:
    cmp dword ptr [rip + operation], 0
    jne .Lshow_help                    # one mode
    mov eax, [rdi + 8]
    mov [rip + operation], eax
    jmp .Lcli_option
.Lcli_other_option:
    mov rcx, rsi
    lea rdx, [rip + repeat_arg]
    call equal_text
    test eax, eax
    jz .Lcli_start_option
    mov dword ptr [rip + cli_repeat], 1
    jmp .Lcli_option
.Lcli_start_option:
    mov rcx, rsi
    lea rdx, [rip + resume_arg]
    call equal_text
    test eax, eax
    jz .Lcli_start_name
    mov dword ptr [rip + cli_resume], 1
    jmp .Lcli_option
.Lcli_start_name:
    mov rcx, rsi
    lea rdx, [rip + start_arg]
    call equal_text
    test eax, eax
    jz .Lshow_help
    cmp r12, [rip + argc]
    jae .Lshow_help
    mov rcx, [rbx + r12*8]
    inc r12
    call parse_time
    jc .Lshow_help
    mov [rip + cli_start_ms], rax
    jmp .Lcli_option
.Lcli_files:
    mov rsi, [rip + argc]
    sub rsi, r12                       # file arguments
    lea r12, [rbx + r12*8]
    mov eax, [rip + operation]
    mov ecx, [rip + cli_repeat]
    or ecx, [rip + cli_resume]
    jz .Lcli_repeat_checked
    test eax, eax
    jnz .Lshow_help                    # --repeat and --resume play
.Lcli_repeat_checked:
    cmp eax, 3
    jb .Lcli_queue_mode
    cmp qword ptr [rip + cli_start_ms], 0
    jne .Lshow_help                    # --start decodes or plays
    lea rax, [rip + engine_stop_requested]
    mov [rip + ogg_cancel_ptr], rax
    cmp dword ptr [rip + operation], 5
    je .Lcli_cover
    cmp rsi, 1
    jne .Lshow_help
    mov rcx, [r12]
    call decoder_open
    test eax, eax
    jz .Lbad_input
    jmp .Ltags_only
.Lcli_cover:
    cmp rsi, 2
    jne .Lshow_help
    mov rcx, [r12]
    call decoder_open
    test eax, eax
    jz .Lbad_input
    mov rcx, [r12 + 8]
    call write_cover
    jmp .Lcleanup
.Lcli_queue_mode:
    test rsi, rsi
    jz .Lshow_help
    cmp eax, 2
    jne .Lopen_input
    cmp rsi, 2
    jb .Lshow_help
    dec rsi
    mov rdi, [r12 + rsi*8]             # the last argument; create new: never truncate
    mov [rsp + 32], rsi
    mov esi, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
    mov edx, 0644
    mov eax, SYS_open
    syscall
    mov rsi, [rsp + 32]
    test eax, eax
    js .Lbad_output
    mov [rip + output_fd], rax
.Lopen_input:
    lea rax, [rip + engine_stop_requested]
    mov [rip + ogg_cancel_ptr], rax
    lea rax, [rip + report_skipped]
    mov [rip + queue_skipped], rax
    mov rcx, r12
    mov edx, esi
    call playlist_expand               # M3U and PLS playlists become their entries
    mov [rip + cli_paths], rax
    mov [rip + cli_count], edx
    mov rcx, rax
    call queue_begin                   # files play one after another
    test eax, eax
    jz .Lbad_input
    cmp dword ptr [rip + operation], 0
    je .Lplayback
    mov rcx, [rip + cli_start_ms]      # --start, read exactly
    call queue_start
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
    cmp dword ptr [rip + operation], 4
    je .Lchapters_only
    call print_tags
    jmp .Lcleanup
.Lchapters_only:
    call print_chapters
    jmp .Lcleanup
.Lplayback:
    mov rax, [rip + cli_start_ms]
    mov [rip + engine_seek_ms], rax
    cmp dword ptr [rip + cli_resume], 0
    je .Lplayback_tags
    test rax, rax
    jnz .Lplayback_tags                # --start wins over --resume
    mov rcx, [rip + cli_paths]
    mov edx, [rip + cli_count]
    call resume_lookup
    test eax, eax
    jz .Lplayback_tags
    mov [rip + engine_seek_ms], rdx
    cmp ecx, [rip + queue_index]
    je .Lplayback_resuming
    mov [rsp + 32], ecx
    call queue_goto                    # a later file of the list
    test eax, eax
    jz .Lbad_input
    mov ecx, [rsp + 32]
    cmp ecx, [rip + queue_index]
    je .Lplayback_resuming
    mov qword ptr [rip + engine_seek_ms], 0   # it did not open; the next did
    jmp .Lplayback_tags
.Lplayback_resuming:
    lea rcx, [rip + resuming_text]
    call print_text
    mov rcx, [rip + engine_seek_ms]
    call print_clock
    lea rcx, [rip + newline]
    call print_text
.Lplayback_tags:
    call print_tags
    lea rax, [rip + announce_next]
    mov [rip + queue_announce], rax
    mov eax, [rip + cli_repeat]
    mov [rip + queue_repeat], eax
.Lplay_run:
    mov ecx, 1                         # console: messages, keys, Ctrl+C
    call engine_start
    mov [rip + exit_code], eax
    cmp eax, 3
    je .Lcleanup                       # the engine reported the audio failure
    cmp dword ptr [rip + engine_command], 0
    je .Lplay_ended
    call navigate
    test eax, eax
    jnz .Lplay_run
.Lplay_ended:
    cmp dword ptr [rip + cli_resume], 0
    je .Lreport_finish
    xor edx, edx                       # the list ended: forget it
    cmp dword ptr [rip + engine_quit], 0
    je .Lplay_resume
    call engine_note_heard             # stopped: keep where
    mov edx, 1
.Lplay_resume:
    mov rcx, [rip + cli_paths]
    call resume_save
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


# After the engine stopped with an engine_command: reopens the queue there
# (queue_navigate) -> EAX=1 to play again, 0 to finish. Another file's tags
# are printed.
LOCALFN navigate
    sub rsp, 40
    mov ecx, [rip + engine_command]
    mov edx, [rip + engine_heard_index]
    mov r8, [rip + engine_heard_ms]
    mov r9d, [rip + engine_seek_delta]
    cmp ecx, 4
    jne .Lnavigate_go
    mov dword ptr [rip + engine_heard_index], -1   # the list again: its tags
.Lnavigate_go:
    call queue_navigate
    test eax, eax
    jz .Lnavigate_return
    mov [rip + engine_seek_ms], rdx
    mov eax, [rip + queue_index]
    cmp eax, [rip + engine_heard_index]
    je .Lnavigate_play
    call announce_next                 # another file: its tags
.Lnavigate_play:
    mov eax, 1
.Lnavigate_return:
    add rsp, 40
    ret
ENDFN navigate


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

# RCX=path: writes the opened file's cover art to it (a new file) and reports
# its type and size; exit code 2 when it has none, 4 when the file fails.
LOCALFN write_cover
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    call cover_get
    test rax, rax
    jz .Lcover_none
    mov rdi, rbx                       # create new: never truncate
    mov esi, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
    mov edx, 0644
    mov eax, SYS_open
    syscall
    test eax, eax
    js .Lcover_failed
    mov [rip + output_fd], rax
    call cover_get
    mov r8, rdx
    mov rdx, rax
    mov rcx, [rip + output_fd]
    call write_all
    test eax, eax
    jz .Lcover_failed
    call cover_get
    mov rbx, rdx
    lea rax, [rip + cover_mimes]
    mov rcx, [rax + r8*8]
    call print_text
    lea rcx, [rip + space_text]
    call print_text
    mov rcx, rbx
    call print_number
    lea rcx, [rip + bytes_text]
    call print_text
    jmp .Lcover_return
.Lcover_none:
    mov dword ptr [rip + exit_code], 2
    lea rcx, [rip + no_cover]
    call print_text
    jmp .Lcover_return
.Lcover_failed:
    mov dword ptr [rip + exit_code], 4
    lea rcx, [rip + output_error]
    call print_text
.Lcover_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN write_cover

# Writes the opened file's chapters as "HH:MM:SS.mmm title" lines.
LOCALFN print_chapters
    push rbx
    push rsi
    sub rsp, 40
    call chapters_count
    mov esi, eax
    xor ebx, ebx
.Lchapters_next:
    cmp ebx, esi
    jae .Lchapters_done
    mov ecx, ebx
    lea rdx, [rip + tag_line]
    call chapter_line
    lea rdx, [rip + tag_line]
    mov byte ptr [rdx + rax], 10
    lea r8d, [rax + 1]
    mov ecx, 1
    call write_all
    inc ebx
    jmp .Lchapters_next
.Lchapters_done:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN print_chapters

# RCX=milliseconds, written as H:MM:SS.mmm.
LOCALFN print_clock
    push rbx
    sub rsp, 32
    mov rax, rcx
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov rbx, rdx                       # milliseconds
    lea r9, [rip + number_buffer + 31]
    mov byte ptr [r9], 0
    mov r8d, 3                         # .mmm
.Lclock_milliseconds:
    mov r10, rax
    mov rax, rbx
    xor edx, edx
    mov ecx, 10
    div rcx
    mov rbx, rax
    add dl, '0'
    dec r9
    mov [r9], dl
    mov rax, r10
    dec r8d
    jnz .Lclock_milliseconds
    dec r9
    mov byte ptr [r9], '.'
    mov r8d, 2                         # seconds, then minutes
.Lclock_field:
    xor edx, edx
    mov ecx, 60
    div rcx
    mov r10, rax
    mov eax, edx
    xor edx, edx
    mov ecx, 10
    div ecx
    add dl, '0'
    dec r9
    mov [r9], dl
    add al, '0'
    dec r9
    mov [r9], al
    dec r9
    mov byte ptr [r9], ':'
    mov rax, r10
    dec r8d
    jnz .Lclock_field
    mov r8d, 10                        # hours
.Lclock_hours:
    xor edx, edx
    div r8
    add dl, '0'
    dec r9
    mov [r9], dl
    test rax, rax
    jnz .Lclock_hours
    mov rcx, r9
    call print_text
    add rsp, 32
    pop rbx
    ret
ENDFN print_clock

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

# --resume: RCX=address of the expanded list's paths, EDX=their count ->
# EAX=1 when the list's key has a saved position in one of its files:
# ECX=that file's index, RDX=milliseconds.
LOCALFN resume_lookup
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    mov edi, edx
    call resume_state_path
    test eax, eax
    jz .Lresume_lookup_none
    mov rcx, [rsi]
    lea rdx, [rip + resume_key]
    call absolute_path
    test eax, eax
    jz .Lresume_lookup_none
    lea rcx, [rip + resume_state]
    call file_map
    test rax, rax
    jz .Lresume_lookup_none
    mov [rsp + 32], rax                # view, bytes, token
    mov rbx, rdx
    mov r12, r8
    mov rcx, rax
    lea rdx, [rax + rdx]
    lea r8, [rip + resume_key]
    call resume_find
    test eax, eax
    jz .Lresume_lookup_unmap
    mov [rip + resume_ms], rdx
    cmp r9d, RESUME_PATH - 1
    jae .Lresume_lookup_unmap_none
    lea r10, [rip + resume_found]     # the heard file, NUL-terminated
    xor ecx, ecx
.Lresume_lookup_copy:
    cmp ecx, r9d
    jae .Lresume_lookup_copied
    mov al, [r8 + rcx]
    mov [r10 + rcx], al
    inc ecx
    jmp .Lresume_lookup_copy
.Lresume_lookup_copied:
    mov byte ptr [r10 + rcx], 0
    mov rcx, [rsp + 32]
    mov rdx, rbx
    mov r8, r12
    call file_unmap
    xor ebx, ebx                       # find it in the list
.Lresume_lookup_file:
    cmp ebx, edi
    jae .Lresume_lookup_none
    mov rcx, [rsi + rbx*8]
    lea rdx, [rip + resume_heard]
    call absolute_path
    test eax, eax
    jz .Lresume_lookup_next
    lea rcx, [rip + resume_heard]
    lea rdx, [rip + resume_found]
    call equal_text
    test eax, eax
    jnz .Lresume_lookup_found
.Lresume_lookup_next:
    inc ebx
    jmp .Lresume_lookup_file
.Lresume_lookup_found:
    mov ecx, ebx
    mov rdx, [rip + resume_ms]
    mov eax, 1
    jmp .Lresume_lookup_return
.Lresume_lookup_unmap_none:
.Lresume_lookup_unmap:
    mov rcx, [rsp + 32]
    mov rdx, rbx
    mov r8, r12
    call file_unmap
.Lresume_lookup_none:
    xor eax, eax
.Lresume_lookup_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN resume_lookup

# --resume after playback: RCX=the list's paths, EDX=1 to save the heard
# file (engine_heard_index, engine_heard_ms), 0 to forget the list. Rewrites
# the state file through a temporary file; failures are silent.
LOCALFN resume_save
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 56
    mov rsi, rcx
    mov r13d, edx
    call resume_state_path
    test eax, eax
    jz .Lresume_save_return
    mov rcx, [rsi]
    lea rdx, [rip + resume_key]
    call absolute_path
    test eax, eax
    jz .Lresume_save_return
    xor r14d, r14d                     # the heard file, or 0 to forget
    test r13d, r13d
    jz .Lresume_save_old
    mov eax, [rip + engine_heard_index]
    test eax, eax
    js .Lresume_save_return
    mov rcx, [rsi + rax*8]
    lea rdx, [rip + resume_heard]
    call absolute_path
    test eax, eax
    jz .Lresume_save_return
    lea r14, [rip + resume_heard]
.Lresume_save_old:
    xor ebx, ebx                       # the old file (none)
    xor r12d, r12d
    mov qword ptr [rsp + 48], 0
    lea rcx, [rip + resume_state]
    call file_map
    test rax, rax
    jz .Lresume_save_buffer
    mov rbx, rax
    mov r12, rdx
    mov [rsp + 48], r8
.Lresume_save_buffer:
    lea rcx, [r12 + 2*RESUME_PATH + 64]
    call mem_alloc
    test rax, rax
    jz .Lresume_save_unmap
    mov rdi, rax
    mov rcx, rbx
    lea rdx, [rbx + r12]
    lea r8, [rip + resume_key]
    mov r9, r14
    mov rax, [rip + engine_heard_ms]
    mov [rsp + 32], rax
    mov [rsp + 40], rdi
    call resume_write
    mov r13, rax                       # new bytes
    test rbx, rbx
    jz .Lresume_save_write
    mov rcx, rbx
    mov rdx, r12
    mov r8, [rsp + 48]
    call file_unmap
    xor ebx, ebx
.Lresume_save_write:
    call resume_directories
    push rdi
    push rsi
    lea rdi, [rip + resume_temp]
    mov esi, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    mov edx, 0600
    mov eax, SYS_open
    syscall
    pop rsi
    pop rdi
    test eax, eax
    js .Lresume_save_free
    mov [rsp + 48], rax
    mov rcx, rax
    mov rdx, rdi
    mov r8, r13
    call write_all
    mov r12d, eax
    push rdi
    mov rdi, [rsp + 48 + 8]
    mov eax, SYS_close
    syscall
    pop rdi
    test r12d, r12d
    jz .Lresume_save_free
    push rdi
    push rsi
    lea rdi, [rip + resume_temp]
    lea rsi, [rip + resume_state]
    mov eax, SYS_rename
    syscall
    pop rsi
    pop rdi
.Lresume_save_free:
    mov rcx, rdi
    call mem_free
.Lresume_save_unmap:
    test rbx, rbx
    jz .Lresume_save_return
    mov rcx, rbx
    mov rdx, r12
    mov r8, [rsp + 48]
    call file_unmap
.Lresume_save_return:
    add rsp, 56
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN resume_save

# -> EAX=1 with resume_state = $XDG_STATE_HOME/lamp/resume or
# $HOME/.local/state/lamp/resume, and resume_temp = it and ".tmp".
LOCALFN resume_state_path
    push rsi
    push rdi
    sub rsp, 40
    lea rcx, [rip + resume_xdg]
    call env_get
    lea rdx, [rip + resume_xdg_tail]
    test rax, rax
    jz .Lresume_state_home
    cmp byte ptr [rax], '/'
    je .Lresume_state_build
.Lresume_state_home:
    lea rcx, [rip + resume_home]
    call env_get
    lea rdx, [rip + resume_home_tail]
    test rax, rax
    jz .Lresume_state_none
    cmp byte ptr [rax], '/'
    jne .Lresume_state_none
.Lresume_state_build:
    lea rdi, [rip + resume_state]
    lea r8, [rdi + RESUME_PATH - 64]  # room for the tail
    mov rsi, rax
.Lresume_state_base:
    movzx eax, byte ptr [rsi]
    test eax, eax
    jz .Lresume_state_tail
    cmp rdi, r8
    jae .Lresume_state_none
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .Lresume_state_base
.Lresume_state_tail:
    mov rsi, rdx
.Lresume_state_tail_char:
    movzx eax, byte ptr [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    test eax, eax
    jnz .Lresume_state_tail_char
    lea rsi, [rip + resume_state]     # and the temporary file
    lea rdi, [rip + resume_temp]
.Lresume_state_temp:
    movzx eax, byte ptr [rsi]
    test eax, eax
    jz .Lresume_state_suffix
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .Lresume_state_temp
.Lresume_state_suffix:
    mov dword ptr [rdi], 0x706d742e    # ".tmp"
    mov byte ptr [rdi + 4], 0
    mov eax, 1
    jmp .Lresume_state_return
.Lresume_state_none:
    xor eax, eax
.Lresume_state_return:
    add rsp, 40
    pop rdi
    pop rsi
    ret
ENDFN resume_state_path

# Creates the directories above resume_state (errors ignored).
LOCALFN resume_directories
    push rsi
    push rdi
    push rbx
    lea rbx, [rip + resume_state]
    lea rcx, [rbx + 1]
.Lresume_dirs_char:
    movzx eax, byte ptr [rcx]
    test eax, eax
    jz .Lresume_dirs_done
    cmp eax, '/'
    jne .Lresume_dirs_next
    mov byte ptr [rcx], 0
    push rcx
    mov rdi, rbx
    mov esi, 0700
    mov eax, SYS_mkdir
    syscall
    pop rcx
    mov byte ptr [rcx], '/'
.Lresume_dirs_next:
    inc rcx
    jmp .Lresume_dirs_char
.Lresume_dirs_done:
    pop rbx
    pop rdi
    pop rsi
    ret
ENDFN resume_directories

# RCX=path, RDX=destination of RESUME_PATH bytes -> EAX=1 with the absolute
# path (relative paths joined to the working directory), 0 when too long.
LOCALFN absolute_path
    push rsi
    push rdi
    mov rsi, rcx
    mov rdi, rdx
    lea r8, [rdx + RESUME_PATH - 1]
    cmp byte ptr [rsi], '/'
    je .Labsolute_copy
    push rsi
    push rdi
    mov esi, RESUME_PATH / 2
    mov eax, SYS_getcwd
    syscall
    pop rdi
    pop rsi
    test rax, rax
    jle .Labsolute_fail
.Labsolute_cwd:
    cmp byte ptr [rdi], 0
    je .Labsolute_slash
    inc rdi
    jmp .Labsolute_cwd
.Labsolute_slash:
    cmp byte ptr [rdi - 1], '/'
    je .Labsolute_copy
    mov byte ptr [rdi], '/'
    inc rdi
.Labsolute_copy:
    movzx eax, byte ptr [rsi]
    cmp rdi, r8
    jae .Labsolute_fail
    mov [rdi], al
    inc rdi
    inc rsi
    test eax, eax
    jnz .Labsolute_copy
    mov eax, 1
    jmp .Labsolute_return
.Labsolute_fail:
    xor eax, eax
.Labsolute_return:
    pop rdi
    pop rsi
    ret
ENDFN absolute_path
