# Original playback queue in x86-64 assembly. MIT, see LICENSE.
# Plays a list of files one after another without a gap: queue_read reads the
# current file and, at its end, opens the next one in the same call. The
# first file that opens sets the session rate (queue_rate), which output
# uses, unless queue_target names one; files at another rate pass through
# the windowed-sinc resampler (src/resample.s), as chained Ogg links do,
# while output_rate stays each file's own. A file that does not open, or fails or ends early
# while decoding, is skipped (queue_failures counts it) unless it is the
# last; a decode error in the last file stays in decode_error, and skipped
# files leave decode_error 6 at the end. A chained Ogg file whose own links
# change rate cannot be resampled again and is skipped when its rate differs.
# Navigation: queue_read notes where each file starts in its output
# (queue_heard finds the file at an output frame), queue_goto reopens the
# list at a file, and queue_repeat wraps the list around.
.include "lamp.inc"
.globl queue_begin, queue_read, queue_seek, queue_announce, queue_skipped
.globl queue_count, queue_failures, queue_rate, queue_index, queue_repeat, queue_goto, queue_heard
.globl queue_navigate, parse_time, queue_start, queue_open, queue_paths, queue_output, queue_target, queue_frames
.globl queue_chapter_target

.equ QUEUE_SKIPPED, 6               # decode_error after skipped files
.equ CH_SIZE, 64                    # src/ogg_chain.s link entries
.equ CH_RATE, 48
.equ QUEUE_MARKS, 1 << 19           # bounded timeline; 8 MiB of demand-zero BSS

.data
queue_paths: .quad 0
queue_announce: .quad 0             # called after a later file opens
queue_skipped: .quad 0              # called with RCX=path for a skipped file
queue_file_frames: .quad 0          # source frames read from the current file
queue_file_total: .quad 0           # its declared frames (0 unknown)
queue_count: .long 0
queue_index: .long 0                # current file, -1 before the first
queue_next: .long 0                 # next path to try
queue_rate: .long 0
queue_target: .long 0               # the session rate to resample every file to, 0 for the first file's
queue_resampling: .long 0
queue_failures: .long 0
queue_playing: .long 0              # a file is open
queue_open_error: .long 0           # decode_error of the last file that did not open
queue_repeat: .long 0               # 1: after the last file, the first again
queue_first_open: .long 1          # suppress the first successful open's announcement
queue_idle: .long 0                 # files ended in a row without a frame
.p2align 3
queue_mark_count: .quad 0           # distinct boundaries since queue_begin/queue_goto
queue_mark_version: .quad 0         # even outside the bounded record update; reader retries changes
queue_output: .quad 0               # frames queue_read returned, from the first file's start

.bss
.p2align 3
queue_marks: .zero QUEUE_MARKS*16    # (output frame where a file starts, its index)
queue_skip_pcm: .zero 2048*8         # frames read and dropped by queue_start

.text
# RCX=path pointers, EDX=count -> EAX=1 when a file opened (the first that
# opens); queue_rate is then its output rate.
FN queue_begin
    xor r8d, r8d
    jmp queue_open
ENDFN queue_begin

# RCX=path pointers, EDX=count, R8D=index of the first file to try -> as
# queue_begin, the list starting there (with repeat, wrapping around).
FN queue_open
    sub rsp, 40
    mov [rip + queue_paths], rcx
    mov [rip + queue_count], edx
    mov [rip + queue_next], r8d
    mov eax, [rip + queue_target]
    mov [rip + queue_rate], eax
    xor eax, eax
    mov [rip + queue_failures], eax
    mov [rip + queue_resampling], eax
    mov [rip + queue_playing], eax
    mov dword ptr [rip + queue_open_error], 1  # an empty queue: decoder_open's generic error
    mov dword ptr [rip + queue_index], -1
    mov [rip + queue_output], rax
    mov [rip + queue_mark_count], rax
    mov dword ptr [rip + queue_first_open], 1
    mov [rip + queue_idle], eax
    call queue_advance
    test eax, eax
    jz .Lqueue_begin_none
    cmp dword ptr [rip + queue_target], 0
    jne .Lqueue_begin_return
    mov ecx, [rip + output_rate]
    mov [rip + queue_rate], ecx
    jmp .Lqueue_begin_return
.Lqueue_begin_none:
    mov ecx, [rip + queue_open_error]     # nothing opened: the last reason
    mov [rip + decode_error], ecx
.Lqueue_begin_return:
    add rsp, 40
    ret
ENDFN queue_open

# Opens the next file that opens -> EAX=1, 0 when none is left.
LOCALFN queue_advance
    push rbx
    push rsi
    sub rsp, 40
    xor esi, esi                          # files tried
.Lqueue_advance_next:
    mov dword ptr [rip + queue_playing], 0
    mov dword ptr [rip + queue_resampling], 0
    mov eax, [rip + queue_count]
    cmp esi, eax
    jae .Lqueue_advance_none              # every file failed (with repeat)
    mov eax, [rip + queue_next]
    cmp eax, [rip + queue_count]
    jb .Lqueue_advance_try
    cmp dword ptr [rip + queue_repeat], 0
    je .Lqueue_advance_none
    xor eax, eax                          # repeat: the first file again
    mov [rip + queue_next], eax
.Lqueue_advance_try:
    inc esi
    inc dword ptr [rip + queue_next]
    mov rcx, [rip + queue_paths]
    mov rbx, [rcx + rax*8]
    call decoder_close
    mov dword ptr [rip + decode_error], 0
    mov rcx, rbx
    call decoder_open
    test eax, eax
    jz .Lqueue_advance_skip
    mov eax, [rip + queue_next]
    dec eax
    mov [rip + queue_index], eax
    mov qword ptr [rip + queue_file_frames], 0
    mov rax, [rip + output_frames]
    mov [rip + queue_file_total], rax
    mov ecx, [rip + output_rate]
    mov edx, [rip + queue_rate]
    test edx, edx
    jz .Lqueue_advance_open                # the first file sets the rate
    cmp ecx, edx
    je .Lqueue_advance_later
    call queue_mixed_rates
    test eax, eax
    jnz .Lqueue_advance_skip               # its links already resample
    mov ecx, [rip + output_rate]
    mov edx, [rip + queue_rate]
    lea r8, [rip + queue_source]
    call resample_open
    test eax, eax
    jz .Lqueue_advance_skip
    xor ecx, ecx
    call resample_reset
    mov dword ptr [rip + queue_resampling], 1
.Lqueue_advance_later:
    jmp .Lqueue_advance_mark
.Lqueue_advance_open:
.Lqueue_advance_mark:
    # Publish only validated opens. Empty files at the same frame replace
    # the last boundary, so their number cannot evict audible history.
    inc qword ptr [rip + queue_mark_version]
    lea rdx, [rip + queue_marks]
    mov r8, [rip + queue_output]
    mov r9, [rip + queue_mark_count]
    test r9, r9
    jz .Lqueue_advance_new_mark
    lea rcx, [r9 - 1]
    and ecx, QUEUE_MARKS - 1
    shl ecx, 4
    cmp [rdx + rcx], r8
    je .Lqueue_advance_replace_mark
.Lqueue_advance_new_mark:
    mov ecx, r9d
    and ecx, QUEUE_MARKS - 1
    shl ecx, 4
    mov [rdx + rcx], r8
    mov eax, [rip + queue_index]
    mov [rdx + rcx + 8], eax
    inc r9
    mov [rip + queue_mark_count], r9      # published after both fields
    jmp .Lqueue_advance_marked
.Lqueue_advance_replace_mark:
    mov eax, [rip + queue_index]
    mov [rdx + rcx + 8], eax
.Lqueue_advance_marked:
    inc qword ptr [rip + queue_mark_version]
    mov dword ptr [rip + queue_playing], 1
    xor eax, eax
    xchg eax, [rip + queue_first_open]
    test eax, eax
    jnz .Lqueue_advance_done
    mov rax, [rip + queue_announce]
    test rax, rax
    jz .Lqueue_advance_done
    call rax
    jmp .Lqueue_advance_done
.Lqueue_advance_done:
    mov eax, 1
    jmp .Lqueue_advance_return
.Lqueue_advance_skip:
    inc dword ptr [rip + queue_failures]
    mov eax, [rip + decode_error]
    mov [rip + queue_open_error], eax
    mov dword ptr [rip + decode_error], 0  # skipped files end the run with 6
    mov rax, [rip + queue_skipped]
    test rax, rax
    jz .Lqueue_advance_next
    mov rcx, rbx
    call rax
    jmp .Lqueue_advance_next
.Lqueue_advance_none:
    xor eax, eax
.Lqueue_advance_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN queue_advance

# -> EAX=1 when the open file is a chained Ogg file whose links change rate
# (its own resampler is in use).
LOCALFN queue_mixed_rates
    xor eax, eax
    cmp dword ptr [rip + chain_active], 0
    je .Lqueue_mixed_return
    mov rcx, [rip + chain_links]
    mov edx, [rip + chain_count]
    mov r8d, [rcx + CH_RATE]
    mov r9d, 1
.Lqueue_mixed_link:
    cmp r9d, edx
    jae .Lqueue_mixed_return
    mov r10d, r9d
    shl r10, 6
    cmp [rcx + r10 + CH_RATE], r8d
    jne .Lqueue_mixed_yes
    inc r9d
    jmp .Lqueue_mixed_link
.Lqueue_mixed_yes:
    mov eax, 1
.Lqueue_mixed_return:
    ret
ENDFN queue_mixed_rates

# The resampler's source: RCX=stereo float output, EDX=frames -> EAX=frames
# of the current file.
LOCALFN queue_source
    sub rsp, 40
    call decoder_read
    add [rip + queue_file_frames], rax
    add rsp, 40
    ret
ENDFN queue_source

# RCX=stereo float output, EDX=frame capacity -> EAX=frames; 0 at the end of
# the queue or on a decode error in its last file. Crosses files within one
# call.
FN queue_read
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rdi, rcx
    mov esi, edx
    xor ebx, ebx
.Lqueue_read_next:
    cmp ebx, esi
    jae .Lqueue_read_done
    cmp dword ptr [rip + queue_playing], 0
    je .Lqueue_read_done
    lea rcx, [rdi + rbx*8]
    mov edx, esi
    sub edx, ebx
    cmp dword ptr [rip + queue_resampling], 0
    jne .Lqueue_read_resampled
    call queue_source
    jmp .Lqueue_read_count
.Lqueue_read_resampled:
    call resample_read
.Lqueue_read_count:
    mov eax, eax
    add ebx, eax
    add [rip + queue_output], rax         # before a later file's mark is taken
    test eax, eax
    jz .Lqueue_read_ended
    mov dword ptr [rip + queue_idle], 0
    jmp .Lqueue_read_next
.Lqueue_read_ended:
    # The file ended: completely, or with an error.
    cmp dword ptr [rip + decode_error], 0
    jne .Lqueue_read_failed
    mov rax, [rip + queue_file_total]
    test rax, rax
    jz .Lqueue_read_advance
    cmp rax, [rip + queue_file_frames]
    je .Lqueue_read_advance
    mov dword ptr [rip + decode_error], 5   # it ended before its declared length
.Lqueue_read_failed:
    cmp dword ptr [rip + queue_repeat], 0
    jne .Lqueue_read_skip                  # with repeat, no file is the last
    mov eax, [rip + queue_next]
    cmp eax, [rip + queue_count]
    jae .Lqueue_read_stop                  # the last file keeps its error
.Lqueue_read_skip:
    inc dword ptr [rip + queue_failures]
    mov dword ptr [rip + decode_error], 0
.Lqueue_read_advance:
    inc dword ptr [rip + queue_idle]       # a whole round without a frame ends it
    mov eax, [rip + queue_idle]
    cmp eax, [rip + queue_count]
    ja .Lqueue_read_stop
    call queue_advance
    test eax, eax
    jnz .Lqueue_read_next
    cmp dword ptr [rip + queue_failures], 0
    je .Lqueue_read_done
    cmp dword ptr [rip + decode_error], 0
    jne .Lqueue_read_done
    mov dword ptr [rip + decode_error], QUEUE_SKIPPED
    jmp .Lqueue_read_done
.Lqueue_read_stop:
    mov dword ptr [rip + queue_playing], 0
.Lqueue_read_done:
    mov eax, ebx
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN queue_read

# RCX=frame of the current file at the session rate -> RAX=resume frame
# (decoder_seek's), at or before it. A resampled file seeks its decoder a
# filter half-width before the target's input span and restarts the filter
# there, so its output from the resume frame on equals a continuous read's.
FN queue_seek
    sub rsp, 40
    cmp dword ptr [rip + queue_resampling], 0
    jne .Lqueue_seek_resampled
    call decoder_seek
    mov [rip + queue_file_frames], rax
    jmp .Lqueue_seek_return
.Lqueue_seek_resampled:
    mov rax, rcx
    mov ecx, [rip + output_rate]
    mul rcx
    mov ecx, [rip + queue_rate]
    div rcx
    mov ecx, [rip + resample_half]
    inc rcx
    xor edx, edx
    sub rax, rcx
    cmovb rax, rdx
    mov rcx, rax
    call decoder_seek
    mov [rip + queue_file_frames], rax
    mov rcx, rax
    call resample_reset
.Lqueue_seek_return:
    mov [rip + queue_output], rax         # before any later file starts
    add rsp, 40
    ret
ENDFN queue_seek

# ECX=file index -> EAX=1 when that file, or a later one (or with repeat,
# any), opened; output positions start again from it. The session rate
# stays the first file's.
FN queue_goto
    sub rsp, 40
    mov [rip + queue_next], ecx
    xor eax, eax
    mov [rip + queue_output], rax
    mov [rip + queue_mark_count], rax
    mov dword ptr [rip + queue_first_open], 1
    mov [rip + queue_idle], eax
    mov [rip + decode_error], eax
    call queue_advance
    add rsp, 40
    ret
ENDFN queue_goto

# RCX=output frame (counted as queue_output counts) -> EAX=the file playing
# there, RDX=its start; EAX=-1 when no retained boundary precedes the request.
# Marks are written before the frames they describe are returned, so a
# reader of returned frames sees them.
FN queue_heard
    push rbx
.Lqueue_heard_retry:
    mov rbx, [rip + queue_mark_version]
    test bl, 1
    jz .Lqueue_heard_stable
    pause
    jmp .Lqueue_heard_retry
.Lqueue_heard_stable:
    mov r8, [rip + queue_mark_count]     # exclusive upper bound, sampled once
    mov r9, r8
    sub r9, QUEUE_MARKS
    jae .Lqueue_heard_oldest
    xor r9d, r9d
.Lqueue_heard_oldest:
    mov rdx, r9                         # original lower bound
    lea r10, [rip + queue_marks]
.Lqueue_heard_mark:
    # Upper bound in the chronological ring: logarithmic even for dense
    # queues. Logical ordinals are 64-bit, independent of the ring slot.
    cmp r9, r8
    jae .Lqueue_heard_found
    mov r11, r8
    sub r11, r9
    shr r11, 1
    add r11, r9
    mov eax, r11d
    and eax, QUEUE_MARKS - 1
    shl eax, 4
    cmp [r10 + rax], rcx
    ja .Lqueue_heard_before
    lea r9, [r11 + 1]
    jmp .Lqueue_heard_mark
.Lqueue_heard_before:
    mov r8, r11
    jmp .Lqueue_heard_mark
.Lqueue_heard_found:
    cmp r9, rdx
    je .Lqueue_heard_none
    lea rax, [r9 - 1]
    and eax, QUEUE_MARKS - 1
    shl eax, 4
    mov rdx, [r10 + rax]
    mov eax, [r10 + rax + 8]
    jmp .Lqueue_heard_validate
.Lqueue_heard_none:
    mov eax, -1
    xor edx, edx
.Lqueue_heard_validate:
    cmp rbx, [rip + queue_mark_version]
    jne .Lqueue_heard_retry              # an overwritten slot cannot mix its start/index
    pop rbx
    ret
ENDFN queue_heard

# A player's navigation. ECX=command (1 next, 2 previous, 3 seek, 4 the list
# again, 6 next chapter, 7 previous chapter), EDX=queue index heard,
# R8=milliseconds into it, R9D=seek seconds ->
# EAX=1 with a file open (queue_goto), RDX=milliseconds to start it at; 0
# when playback ends. Next: the file after the one heard (the first again
# with repeat). Previous: the heard file from its start after 3 s of it,
# else the one before. Seek: the heard file at the heard position plus R9D
# seconds (from its start when that is before it). A later file opened in
# place of the target starts at 0. queue_announce is not called.
FN queue_navigate
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov r12d, ecx
    mov ebx, edx                          # target
    xor esi, esi                          # start, ms
    cmp ecx, 4
    jne .Lqueue_navigate_command
    xor ebx, ebx
    jmp .Lqueue_navigate_open
.Lqueue_navigate_command:
    test ebx, ebx
    js .Lqueue_navigate_unknown         # never navigate from an unknown heard file
    cmp ecx, 1
    je .Lqueue_navigate_next
    cmp ecx, 2
    je .Lqueue_navigate_previous
    cmp ecx, 6
    je .Lqueue_navigate_chapter
    cmp ecx, 7
    je .Lqueue_navigate_chapter
    movsxd rax, r9d
    imul rax, rax, 1000
    add rax, r8
    jns .Lqueue_navigate_seek
    xor eax, eax
.Lqueue_navigate_seek:
    mov rsi, rax
    jmp .Lqueue_navigate_open
.Lqueue_navigate_chapter:
    mov rsi, r8
    jmp .Lqueue_navigate_open
.Lqueue_navigate_next:
    inc ebx
    cmp ebx, [rip + queue_count]
    jb .Lqueue_navigate_open
    xor ebx, ebx
    cmp dword ptr [rip + queue_repeat], 0
    jne .Lqueue_navigate_open
    xor eax, eax                          # past the last file: the end
    jmp .Lqueue_navigate_return
.Lqueue_navigate_previous:
    cmp r8, 3000
    ja .Lqueue_navigate_open              # its start again
    dec ebx
    jns .Lqueue_navigate_open
    xor ebx, ebx
    cmp dword ptr [rip + queue_repeat], 0
    je .Lqueue_navigate_open
    mov ebx, [rip + queue_count]
    dec ebx
.Lqueue_navigate_open:
    mov rdi, [rip + queue_announce]
    mov qword ptr [rip + queue_announce], 0
    mov ecx, ebx
    call queue_goto
    mov [rip + queue_announce], rdi
    test eax, eax
    jz .Lqueue_navigate_return
    cmp ebx, [rip + queue_index]
    jne .Lqueue_navigate_other
    cmp r12d, 6
    jb .Lqueue_navigate_position
    cmp r12d, 7
    ja .Lqueue_navigate_position
    # Reopening the heard file restores its chapters: metadata of a file
    # decoded ahead must never choose the target.
    mov ecx, r12d
    mov rdx, rsi
    call queue_chapter_target
    mov rsi, rax
    jmp .Lqueue_navigate_position
.Lqueue_navigate_other:
    xor esi, esi                          # a later file opened instead
.Lqueue_navigate_position:
    mov eax, 1
    jmp .Lqueue_navigate_return
.Lqueue_navigate_unknown:
    xor eax, eax
.Lqueue_navigate_return:
    mov rdx, rsi
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN queue_navigate

# ECX=6/7, RDX=heard ms -> RAX=chapter target in the current opened file.
FN queue_chapter_target
    sub rsp, 40
    mov [rsp + 32], ecx
    mov r10, rdx
    mov rax, [rip + output_frames]
    mov ecx, 1000
    mul rcx
    mov ecx, [rip + output_rate]
    xor r8d, r8d
    test ecx, ecx
    jz .Lqueue_chapter_select
    cmp rdx, rcx
    jae .Lqueue_chapter_select          # unrepresentable duration: unknown
    div rcx
    mov r8, rax
.Lqueue_chapter_select:
    mov ecx, [rsp + 32]
    mov rdx, r10
    call chapter_target
    add rsp, 40
    ret
ENDFN queue_chapter_target

# RCX=NUL-terminated time: seconds, M:S or H:M:S, the seconds with an
# optional fraction -> RAX=milliseconds; CF when it is not a time.
FN parse_time
    xor eax, eax                       # whole units before this field
    xor r8d, r8d                       # this field
    xor r9d, r9d                       # its digits
    xor r10d, r10d                     # colons
.Lparse_time_char:
    movzx edx, byte ptr [rcx]
    inc rcx
    lea r11d, [rdx - '0']
    cmp r11d, 9
    ja .Lparse_time_separator
    mov r11, 100000000000
    cmp r8, r11
    jae .Lparse_time_bad
    imul r8, r8, 10
    sub edx, '0'
    add r8, rdx
    inc r9d
    jmp .Lparse_time_char
.Lparse_time_separator:
    test r9d, r9d
    jz .Lparse_time_bad
    add rax, r8
    xor r8d, r8d
    xor r9d, r9d
    cmp edx, ':'
    jne .Lparse_time_seconds
    inc r10d
    cmp r10d, 2
    ja .Lparse_time_bad
    imul rax, rax, 60
    jmp .Lparse_time_char
.Lparse_time_seconds:
    imul rax, rax, 1000
    test edx, edx
    jz .Lparse_time_done
    cmp edx, '.'
    jne .Lparse_time_bad
    mov r8d, 100                       # milliseconds: three digits count
.Lparse_time_fraction:
    movzx edx, byte ptr [rcx]
    inc rcx
    test edx, edx
    jz .Lparse_time_fraction_end
    sub edx, '0'
    cmp edx, 9
    ja .Lparse_time_bad
    inc r9d
    imul edx, r8d
    add rax, rdx
    mov edx, r8d
    mov r8d, 10
    cmp edx, 100
    je .Lparse_time_fraction
    mov r8d, 1
    cmp edx, 10
    je .Lparse_time_fraction
    xor r8d, r8d
    jmp .Lparse_time_fraction
.Lparse_time_fraction_end:
    test r9d, r9d
    jz .Lparse_time_bad
.Lparse_time_done:
    clc
    ret
.Lparse_time_bad:
    stc
    ret
ENDFN parse_time

# -> RAX=the current file's frames at the session rate (as the resampler
# yields them: ceil(N*session/own)), 0 when unknown. Leaf; keeps R8.
FN queue_frames
    mov rax, [rip + output_frames]
    mov ecx, [rip + output_rate]
    test ecx, ecx
    jz .Lqueue_frames_done
    cmp ecx, [rip + queue_rate]
    je .Lqueue_frames_done
    mov r9d, [rip + queue_rate]
    mul r9
    dec rcx
    add rax, rcx
    adc rdx, 0
    inc rcx
    div rcx
.Lqueue_frames_done:
    ret
ENDFN queue_frames

# RCX=milliseconds: the first file (just opened by queue_begin) continues
# from there, exactly: a seek, then the frames before it read and dropped.
# A start past its known end is its end.
FN queue_start
    push rbx
    push rsi
    sub rsp, 40
    mov rax, rcx
    test rax, rax
    jz .Lqueue_start_done
    mov ecx, [rip + queue_rate]
    mul rcx
    mov ecx, 1000
    cmp rdx, rcx
    jae .Lqueue_start_far
    div rcx
    jmp .Lqueue_start_frames
.Lqueue_start_far:
    mov rax, -1
.Lqueue_start_frames:
    mov r8, rax
    call queue_frames                  # the file's length at the session rate
    mov rcx, rax
    mov rax, r8
    test rcx, rcx
    jz .Lqueue_start_seek
    cmp rax, rcx
    cmova rax, rcx
.Lqueue_start_seek:
    mov rbx, rax                          # the start
    mov rcx, rax
    call queue_seek
    mov rsi, rax                          # where the decoder resumed
.Lqueue_start_skip:
    mov rdx, rbx
    sub rdx, rsi
    jbe .Lqueue_start_done
    mov eax, 2048
    cmp rdx, rax
    cmova rdx, rax
    lea rcx, [rip + queue_skip_pcm]
    call queue_read
    test eax, eax
    jz .Lqueue_start_done
    add rsi, rax
    jmp .Lqueue_start_skip
.Lqueue_start_done:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN queue_start
