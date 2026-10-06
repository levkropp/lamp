# Original playback queue in x86-64 assembly. MIT, see LICENSE.
# Plays a list of files one after another without a gap: queue_read reads the
# current file and, at its end, opens the next one in the same call. The
# first file that opens sets the session rate (queue_rate), which output
# uses; later files at another rate pass through the windowed-sinc resampler
# (src/resample.s), as chained Ogg links do, while output_rate stays each
# file's own. A file that does not open, or fails or ends early
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
.globl queue_navigate, parse_time, queue_start, queue_open, queue_paths, queue_output

.equ QUEUE_SKIPPED, 6               # decode_error after skipped files
.equ CH_SIZE, 64                    # src/ogg_chain.s link entries
.equ CH_RATE, 48
.equ QUEUE_MARKS, 64                # files whose start in the output is kept

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
queue_resampling: .long 0
queue_failures: .long 0
queue_playing: .long 0              # a file is open
queue_open_error: .long 0           # decode_error of the last file that did not open
queue_repeat: .long 0               # 1: after the last file, the first again
queue_mark_count: .long 0           # marks written since queue_begin/queue_goto
queue_idle: .long 0                 # files ended in a row without a frame
.p2align 3
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
    xor eax, eax
    mov [rip + queue_rate], eax
    mov [rip + queue_failures], eax
    mov [rip + queue_resampling], eax
    mov [rip + queue_playing], eax
    mov dword ptr [rip + queue_open_error], 1  # an empty queue: decoder_open's generic error
    mov dword ptr [rip + queue_index], -1
    mov [rip + queue_output], rax
    mov [rip + queue_mark_count], eax
    mov [rip + queue_idle], eax
    call queue_advance
    test eax, eax
    jz .Lqueue_begin_none
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
    mov ecx, [rip + queue_mark_count]     # where it starts in the output
    and ecx, QUEUE_MARKS - 1
    shl ecx, 4
    lea rdx, [rip + queue_marks]
    mov r8, [rip + queue_output]
    mov [rdx + rcx], r8
    mov [rdx + rcx + 8], eax
    inc dword ptr [rip + queue_mark_count]
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
    mov dword ptr [rip + queue_playing], 1
    mov rax, [rip + queue_announce]
    test rax, rax
    jz .Lqueue_advance_done
    call rax
    jmp .Lqueue_advance_done
.Lqueue_advance_open:
    mov dword ptr [rip + queue_playing], 1
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

# RCX=frame of the current file -> RAX=resume frame (decoder_seek's). Files
# read through the resampler do not seek: RAX=their current frame.
FN queue_seek
    sub rsp, 40
    cmp dword ptr [rip + queue_resampling], 0
    jne .Lqueue_seek_none
    call decoder_seek
    mov [rip + queue_file_frames], rax
    jmp .Lqueue_seek_return
.Lqueue_seek_none:
    mov rax, [rip + queue_file_frames]
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
    mov [rip + queue_mark_count], eax
    mov [rip + queue_idle], eax
    mov [rip + decode_error], eax
    call queue_advance
    add rsp, 40
    ret
ENDFN queue_goto

# RCX=output frame (counted as queue_output counts) -> EAX=the file playing
# there, RDX=the output frame where it started; EAX=-1 when no mark is left.
# Marks are written before the frames they describe are returned, so a
# reader of returned frames sees them.
FN queue_heard
    mov r8d, [rip + queue_mark_count]
    mov r9d, r8d
    sub r9d, QUEUE_MARKS
    jae .Lqueue_heard_oldest
    xor r9d, r9d
.Lqueue_heard_oldest:
    lea r10, [rip + queue_marks]
.Lqueue_heard_mark:
    cmp r8d, r9d
    jbe .Lqueue_heard_first
    dec r8d
    mov eax, r8d
    and eax, QUEUE_MARKS - 1
    shl eax, 4
    mov rdx, [r10 + rax]
    cmp rdx, rcx
    ja .Lqueue_heard_mark
    mov eax, [r10 + rax + 8]
    ret
.Lqueue_heard_first:
    cmp r8d, [rip + queue_mark_count]     # no mark at all
    je .Lqueue_heard_none
    mov eax, r9d                          # the oldest kept: before it, unknown
    and eax, QUEUE_MARKS - 1
    shl eax, 4
    mov rdx, [r10 + rax]
    mov eax, [r10 + rax + 8]
    ret
.Lqueue_heard_none:
    mov eax, -1
    xor edx, edx
    ret
ENDFN queue_heard

# A player's navigation. ECX=command (1 next, 2 previous, 3 seek, 4 the list
# again), EDX=queue index heard, R8=milliseconds into it, R9D=seek seconds ->
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
    sub rsp, 32
    mov ebx, edx                          # target
    xor esi, esi                          # start, ms
    cmp ecx, 4
    jne .Lqueue_navigate_command
    xor ebx, ebx
    jmp .Lqueue_navigate_open
.Lqueue_navigate_command:
    cmp ecx, 1
    je .Lqueue_navigate_next
    cmp ecx, 2
    je .Lqueue_navigate_previous
    movsxd rax, r9d
    imul rax, rax, 1000
    add rax, r8
    jns .Lqueue_navigate_seek
    xor eax, eax
.Lqueue_navigate_seek:
    mov rsi, rax
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
    je .Lqueue_navigate_position
    xor esi, esi                          # a later file opened instead
.Lqueue_navigate_position:
    mov eax, 1
.Lqueue_navigate_return:
    mov rdx, rsi
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN queue_navigate

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
    mov rcx, [rip + output_frames]
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
