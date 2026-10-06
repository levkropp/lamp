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
.include "lamp.inc"
.globl queue_begin, queue_read, queue_seek, queue_announce, queue_skipped
.globl queue_count, queue_failures, queue_rate, queue_index

.equ QUEUE_SKIPPED, 6               # decode_error after skipped files
.equ CH_SIZE, 64                    # src/ogg_chain.s link entries
.equ CH_RATE, 48

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

.text
# RCX=path pointers, EDX=count -> EAX=1 when a file opened (the first that
# opens); queue_rate is then its output rate.
FN queue_begin
    sub rsp, 40
    mov [rip + queue_paths], rcx
    mov [rip + queue_count], edx
    xor eax, eax
    mov [rip + queue_next], eax
    mov [rip + queue_rate], eax
    mov [rip + queue_failures], eax
    mov [rip + queue_resampling], eax
    mov [rip + queue_playing], eax
    mov dword ptr [rip + queue_index], -1
    call queue_advance
    test eax, eax
    jz .Lqueue_begin_return
    mov ecx, [rip + output_rate]
    mov [rip + queue_rate], ecx
.Lqueue_begin_return:
    add rsp, 40
    ret
ENDFN queue_begin

# Opens the next file that opens -> EAX=1, 0 when none is left.
LOCALFN queue_advance
    push rbx
    sub rsp, 32
.Lqueue_advance_next:
    mov dword ptr [rip + queue_playing], 0
    mov dword ptr [rip + queue_resampling], 0
    mov eax, [rip + queue_next]
    cmp eax, [rip + queue_count]
    jae .Lqueue_advance_none
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
    mov rax, [rip + queue_skipped]
    test rax, rax
    jz .Lqueue_advance_next
    mov rcx, rbx
    call rax
    jmp .Lqueue_advance_next
.Lqueue_advance_none:
    xor eax, eax
.Lqueue_advance_return:
    add rsp, 32
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
    add ebx, eax
    test eax, eax
    jnz .Lqueue_read_next
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
    mov eax, [rip + queue_next]
    cmp eax, [rip + queue_count]
    jae .Lqueue_read_stop                  # the last file keeps its error
    inc dword ptr [rip + queue_failures]
    mov dword ptr [rip + decode_error], 0
.Lqueue_read_advance:
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
    add rsp, 40
    ret
ENDFN queue_seek
