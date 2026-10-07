# LAMP Linux playback engine: decode worker, PCM ring and PulseAudio output.
# Same design as the Windows engine (src/win/player.s): a single producer
# decodes into a ring; the render loop sends exactly what the sound server
# requests. x86 TSO publishes complete PCM before write_count; the consumer
# publishes read_count after sending. Waits are event-driven (poll on the
# server socket, eventfds and the terminal); there is no periodic polling.
# MIT license.
.include "lamp.inc"
.include "linux.inc"

.equ RING_FRAMES, 262144
.equ RING_MASK, RING_FRAMES - 1
.equ CHUNK_FRAMES, 2048
.equ SEND_FRAMES, 8192                # 64 KiB per audio packet
.equ BUFFER_MS, 200                   # server buffer target, as on Windows
.equ REFILL_FRAMES, RING_FRAMES*3/4    # a full ring refills once it holds no more

.globl engine_mode, engine_stop_requested, pause_requested, engine_ready, engine_volume
.globl engine_position, engine_seek_ms, decoded_count, underruns, endpoint_dry, audio_status
.globl engine_command, engine_seek_delta, engine_heard_index, engine_heard_ms, engine_quit, engine_note_heard

.data
playing_text: .ascii "Playing. Space: pause / resume. N / P: next / previous file. Left / Right: -5 / +5 s.\n"
    .asciz "Down / Up: -60 / +60 s. [ / ]: previous / next chapter. R: repeat. Q or Ctrl+C: stop.\n"
repeat_on_text: .asciz "Repeat: on\n"
audio_lost_text: .asciz "Audio output lost; reopening.\n"
repeat_off_text: .asciz "Repeat: off\n"
audio_error_text: .asciz "Audio output unavailable. Start PulseAudio or PipeWire (pipewire-pulse), or use --check.\n"
engine_volume: .float 1.0
data_event: .long -1
space_event: .long -1
stop_event: .long -1

.bss
.p2align 6
write_count: .quad 0
    .zero 56
read_count: .quad 0
    .zero 56
decoded_count: .quad 0
underruns: .quad 0
endpoint_dry: .quad 0
engine_position: .quad 0
engine_seek_frames: .quad 0
engine_seek_ms: .quad 0                # where engine_start begins, in the current file
engine_heard_ms: .quad 0               # position in the heard file at a command
producer_thread: .quad 0
dry_mark: .quad 0                      # server underflows when a pause began
dry_ignored: .quad 0                   # underflows from pause/resume transitions
audio_status: .long 0                  # 0, or the failing step: 1 connect, 2 stream, 3 write/server
engine_mode: .long 0                   # 0 console, 1 API
engine_stop_requested: .long 0
pause_requested: .long 0
engine_ready: .long 0
engine_command: .long 0                # set by a key: 1 next, 2 previous, 3 seek by engine_seek_delta;
                                       # 4 at the end with repeat on: the list again;
                                       # 5 the stream failed: the heard file where it was
engine_seek_delta: .long 0             # seconds
engine_heard_index: .long 0            # queue index heard at the command
engine_greeted: .long 0
engine_quit: .long 0                   # Q or a signal stopped the last run
producer_done: .long 0
corked: .long 0
waiting_data: .long 0
terminal_changed: .long 0
prebuffer_frames: .long 0
dry_ignoring: .long 0
.p2align 4
terminal_original: .zero 64
terminal_raw: .zero 64
poll_fds: .zero 32
key_buffer: .zero 16
.p2align 4
ring_pcm: .zero RING_FRAMES*8
offline_pcm: .zero CHUNK_FRAMES*8

.text
# Plays the queue already opened with queue_begin. ECX=1 for the console
# (messages, Space/Q and Ctrl+C), 0 for API callers. -> EAX=exit code:
# 0 played, 2 decode error, 3 audio error.
FN engine_start
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    xor ecx, 1
    mov [rip + engine_mode], ecx
    xor eax, eax
    mov [rip + write_count], rax
    mov [rip + read_count], rax
    mov [rip + decoded_count], rax
    mov [rip + underruns], rax
    mov [rip + endpoint_dry], rax
    mov [rip + producer_thread], rax
    mov [rip + dry_ignored], rax
    mov [rip + audio_status], eax
    mov [rip + dry_ignoring], eax
    mov [rip + pulse_underflows], rax  # also reset if a stop precedes the stream
    mov [rip + pulse_started], eax
    mov [rip + producer_done], eax
    mov [rip + engine_ready], eax
    mov [rip + corked], eax
    mov [rip + waiting_data], eax
    mov [rip + terminal_changed], eax
    mov r13d, 0                        # exit code
    mov [rip + engine_command], eax
    mov [rip + engine_quit], eax
    mov rax, [rip + engine_seek_ms]    # milliseconds to frames
    mov ecx, [rip + queue_rate]
    mul rcx
    mov ecx, 1000
    cmp rdx, rcx
    jae .Leng_seek_far
    div rcx
    jmp .Leng_seek_frames
.Leng_seek_far:
    mov rax, -1
.Leng_seek_frames:
    mov r8, rax
    call queue_frames                  # the file's length at the session rate
    mov rcx, rax
    mov rax, r8
    test rcx, rcx
    jz .Leng_seek_ready
    cmp rax, rcx
    cmova rax, rcx
.Leng_seek_ready:
    mov [rip + engine_seek_frames], rax
    mov [rip + engine_position], rax
    call event_create
    mov [rip + data_event], eax
    call event_create
    mov [rip + space_event], eax
    call event_create
    mov [rip + stop_event], eax
    cmp dword ptr [rip + data_event], 0
    jl .Leng_audio_error
    cmp dword ptr [rip + space_event], 0
    jl .Leng_audio_error
    cmp dword ptr [rip + stop_event], 0
    jl .Leng_audio_error
    cmp dword ptr [rip + engine_mode], 0
    jne .Leng_no_signals
    mov ecx, SIGINT
    lea rdx, [rip + engine_signal]
    call signal_set
    mov ecx, SIGTERM
    lea rdx, [rip + engine_signal]
    call signal_set
.Leng_no_signals:
    mov ecx, SIGPIPE                   # a closed server socket reports EPIPE instead
    mov edx, SIG_IGN
    call signal_set
    cmp dword ptr [rip + engine_stop_requested], 0
    jne .Leng_stopped
    mov dword ptr [rip + audio_status], 1
    call pulse_connect
    test eax, eax
    jz .Leng_audio_error
    mov dword ptr [rip + audio_status], 0
    lea rcx, [rip + producer]
    xor edx, edx
    call thread_create
    mov [rip + producer_thread], rax
    test rax, rax
    jz .Leng_audio_error
    # Prebuffer three quarters of a second, or the whole stream if shorter.
    mov eax, [rip + queue_rate]
    imul eax, eax, 3
    shr eax, 2
    cmp eax, RING_FRAMES / 2
    jbe .Leng_prebuffer_set
    mov eax, RING_FRAMES / 2
.Leng_prebuffer_set:
    mov [rip + prebuffer_frames], eax
.Leng_prebuffer_wait:
    cmp dword ptr [rip + engine_stop_requested], 0
    jne .Leng_stopped
    mov rax, [rip + write_count]
    cmp eax, [rip + prebuffer_frames]
    jae .Leng_prebuffer_ready
    cmp dword ptr [rip + producer_done], 0
    jne .Leng_prebuffer_ready
    mov ecx, [rip + data_event]
    call event_clear
    mov rax, [rip + write_count]       # recheck after clearing to avoid a lost wakeup
    cmp eax, [rip + prebuffer_frames]
    jae .Leng_prebuffer_ready
    cmp dword ptr [rip + producer_done], 0
    jne .Leng_prebuffer_ready
    xor ecx, ecx                       # wait for data or stop
    call engine_wait
    jmp .Leng_prebuffer_wait
.Leng_prebuffer_ready:
    mov dword ptr [rip + engine_ready], 1
    cmp qword ptr [rip + write_count], 0
    je .Leng_stopped
    mov dword ptr [rip + audio_status], 2
    mov ecx, [rip + queue_rate]            # the session rate; later files may differ
    mov edx, BUFFER_MS
    call pulse_create_stream
    test eax, eax
    jz .Leng_audio_error
    mov dword ptr [rip + audio_status], 3
    cmp dword ptr [rip + engine_mode], 0
    jne .Leng_loop
    cmp dword ptr [rip + engine_greeted], 0
    jne .Leng_greeted                  # once, not again after each key
    mov dword ptr [rip + engine_greeted], 1
    lea rcx, [rip + playing_text]
    call print_text
.Leng_greeted:
    call terminal_raw_mode
.Leng_loop:
    cmp dword ptr [rip + engine_stop_requested], 0
    jne .Leng_stopped
    # The server reports an underflow whenever its queue is unreadable, including
    # while a pause or resume prebuffers. Count only those during playback.
    cmp dword ptr [rip + dry_ignoring], 0
    je .Leng_dry_counted
    cmp dword ptr [rip + corked], 0
    jne .Leng_dry_counted
    cmp dword ptr [rip + pulse_started], 0
    je .Leng_dry_counted
    mov rax, [rip + pulse_underflows]
    sub rax, [rip + dry_mark]
    add [rip + dry_ignored], rax
    mov dword ptr [rip + dry_ignoring], 0
.Leng_dry_counted:
    mov eax, [rip + pause_requested]
    cmp eax, [rip + corked]
    je .Leng_pause_applied
    mov [rip + corked], eax
    test eax, eax
    jz .Leng_resume
    cmp dword ptr [rip + dry_ignoring], 0
    jne .Leng_cork
    mov rcx, [rip + pulse_underflows]
    mov [rip + dry_mark], rcx
    mov dword ptr [rip + dry_ignoring], 1
    jmp .Leng_cork
.Leng_resume:
    mov dword ptr [rip + pulse_started], 0
.Leng_cork:
    mov ecx, eax
    call pulse_cork
    test eax, eax
    jz .Leng_audio_error
.Leng_pause_applied:
    mov dword ptr [rip + waiting_data], 0
    cmp dword ptr [rip + corked], 0
    jne .Leng_wait
    mov rax, [rip + read_count]
    cmp rax, [rip + write_count]
    jne .Leng_send
    cmp dword ptr [rip + producer_done], 0
    jne .Leng_drain
.Leng_send:
    mov rbx, [rip + read_count]
    mov r12, [rip + write_count]
    sub r12, rbx                       # frames available
    jz .Leng_starved
    mov rax, [rip + pulse_requested]
    shr rax, 3                         # requested frames
    jz .Leng_wait
    cmp r12, rax
    cmova r12, rax
    mov rsi, rbx
    and esi, RING_MASK
    mov eax, RING_FRAMES
    sub eax, esi
    cmp r12, rax
    cmova r12, rax
    cmp r12, SEND_FRAMES
    jbe .Leng_send_size
    mov r12d, SEND_FRAMES
.Leng_send_size:
    lea rdi, [rip + ring_pcm]
    lea rdi, [rdi + rsi*8]
    cmp dword ptr [rip + engine_volume], 0x3f800000
    je .Leng_send_volume_done
    mov rcx, rdi
    mov rdx, r12
    call engine_apply_volume
.Leng_send_volume_done:
    mov rcx, rdi
    lea rdx, [r12*8]
    call pulse_write
    test eax, eax
    jz .Leng_audio_error
    lea rax, [r12*8]
    sub [rip + pulse_requested], rax
    add rbx, r12
    mov [rip + read_count], rbx        # publish after sending
    mov rax, [rip + write_count]       # wake the producer only once it can refill
    sub rax, rbx
    add rbx, [rip + engine_seek_frames]
    mov [rip + engine_position], rbx
    cmp rax, REFILL_FRAMES
    ja .Leng_loop
    mov ecx, [rip + space_event]
    call event_signal
    jmp .Leng_loop
.Leng_starved:
    cmp qword ptr [rip + pulse_requested], 8
    jb .Leng_wait
    cmp dword ptr [rip + producer_done], 0
    jne .Leng_wait
    inc qword ptr [rip + underruns]    # the server asked before PCM was ready
    mov dword ptr [rip + waiting_data], 1
    mov ecx, [rip + data_event]
    call event_clear
    mov rax, [rip + read_count]        # recheck after clearing
    cmp rax, [rip + write_count]
    jne .Leng_loop
    cmp dword ptr [rip + producer_done], 0
    jne .Leng_loop
.Leng_wait:
    mov ecx, 1                         # include the server socket
    call engine_wait
    test eax, eax
    jz .Leng_audio_error
    jmp .Leng_loop
.Leng_drain:
    call engine_count_dry              # underflow while draining is the expected end
    call pulse_drain
    test eax, eax
    jz .Leng_audio_error
    mov dword ptr [rip + audio_status], 0
    # Repeat turned on after the producer read the last file: play the list
    # again from its first file (when this run played anything).
    cmp dword ptr [rip + queue_repeat], 0
    je .Leng_cleanup
    cmp qword ptr [rip + read_count], 0
    je .Leng_cleanup
    cmp dword ptr [rip + engine_command], 0
    jne .Leng_cleanup
    mov dword ptr [rip + engine_command], 4
    jmp .Leng_cleanup
.Leng_stopped:
    mov dword ptr [rip + audio_status], 0
    call engine_count_dry
    jmp .Leng_cleanup
.Leng_audio_error:
    # A console stream that played and then failed (killed, or the server
    # lost it): the caller reopens the heard file where it was.
    cmp dword ptr [rip + engine_mode], 0
    jne .Leng_audio_failed
    cmp dword ptr [rip + audio_status], 3
    jne .Leng_audio_failed
    cmp qword ptr [rip + read_count], 0
    je .Leng_audio_failed
    cmp dword ptr [rip + engine_command], 0
    jne .Leng_audio_failed
    call engine_note_heard
    mov dword ptr [rip + engine_command], 5
    lea rcx, [rip + audio_lost_text]
    call print_text
    jmp .Leng_cleanup
.Leng_audio_failed:
    mov r13d, 3
    cmp dword ptr [rip + engine_mode], 0
    jne .Leng_cleanup
    lea rcx, [rip + audio_error_text]
    call print_text
.Leng_cleanup:
    mov dword ptr [rip + engine_stop_requested], 1
    mov ecx, [rip + stop_event]
    test ecx, ecx
    js .Leng_cleanup_join
    call event_signal
.Leng_cleanup_join:
    mov rcx, [rip + producer_thread]
    call thread_join
    mov qword ptr [rip + producer_thread], 0
    call pulse_close
    call terminal_restore
    mov ecx, [rip + data_event]
    call event_close
    mov ecx, [rip + space_event]
    call event_close
    mov ecx, [rip + stop_event]
    call event_close
    mov dword ptr [rip + data_event], -1
    mov dword ptr [rip + space_event], -1
    mov dword ptr [rip + stop_event], -1
    test r13d, r13d
    jnz .Leng_return
    cmp dword ptr [rip + decode_error], 0
    je .Leng_return
    mov r13d, 2
.Leng_return:
    mov dword ptr [rip + engine_stop_requested], 0
    mov eax, r13d
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN engine_start

# endpoint_dry = server underflows outside pause/resume transitions.
LOCALFN engine_count_dry
    mov rax, [rip + pulse_underflows]
    sub rax, [rip + dry_ignored]
    cmp dword ptr [rip + dry_ignoring], 0
    je .Leng_count_dry_store
    mov rcx, [rip + pulse_underflows]
    sub rcx, [rip + dry_mark]
    sub rax, rcx
.Leng_count_dry_store:
    mov [rip + endpoint_dry], rax
    ret
ENDFN engine_count_dry

# Requests a stop from any thread or a signal handler.
FN engine_stop
    mov dword ptr [rip + engine_stop_requested], 1
    mov ecx, [rip + stop_event]
    test ecx, ecx
    js .Leng_stop_done
    jmp event_signal
.Leng_stop_done:
    ret
ENDFN engine_stop

# Toggles pause from any thread.
FN engine_pause
    xor dword ptr [rip + pause_requested], 1
    mov ecx, [rip + stop_event]        # wakes the render loop to apply it
    test ecx, ecx
    js .Leng_pause_done
    jmp event_signal
.Leng_pause_done:
    ret
ENDFN engine_pause

# ECX=1 to include the server socket. Waits for stop, data (when starved or
# prebuffering), server packets and console keys. -> EAX=0 on server failure.
LOCALFN engine_wait
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov ebx, ecx
    lea rdi, [rip + poll_fds]
    xor esi, esi                       # descriptor count
    mov eax, [rip + stop_event]
    mov [rdi], eax
    mov dword ptr [rdi + 4], POLLIN
    inc esi
    test ebx, ebx
    jz .Leng_wait_data
    call pulse_fd
    mov [rdi + rsi*8], eax
    mov dword ptr [rdi + rsi*8 + 4], POLLIN
    inc esi
    cmp dword ptr [rip + waiting_data], 0
    je .Leng_wait_keys
.Leng_wait_data:
    mov eax, [rip + data_event]
    mov [rdi + rsi*8], eax
    mov dword ptr [rdi + rsi*8 + 4], POLLIN
    inc esi
.Leng_wait_keys:
    cmp dword ptr [rip + terminal_changed], 0
    je .Leng_wait_poll
    mov dword ptr [rdi + rsi*8], 0
    mov dword ptr [rdi + rsi*8 + 4], POLLIN
    inc esi
.Leng_wait_poll:
    mov rcx, rdi
    mov edx, esi
    mov r8d, -1
    call poll_wait
    cmp eax, -EINTR
    je .Leng_wait_ok                   # a signal handler may have requested a stop
    test eax, eax
    js .Leng_wait_fail
    # Stop wakeups are level-triggered flags; clear the eventfd.
    test dword ptr [rdi + 6], 0xffff
    jz .Leng_wait_server
    mov ecx, [rip + stop_event]
    call event_clear
.Leng_wait_server:
    test ebx, ebx
    jz .Leng_wait_ok
    test word ptr [rdi + 14], POLLIN | POLLERR | POLLHUP
    jz .Leng_wait_keys_check
    call pulse_pump
    test eax, eax
    jz .Leng_wait_fail
.Leng_wait_keys_check:
    cmp dword ptr [rip + terminal_changed], 0
    je .Leng_wait_ok
    lea eax, [rsi - 1]
    test word ptr [rdi + rax*8 + 6], POLLIN
    jz .Leng_wait_ok
    call engine_read_keys
.Leng_wait_ok:
    mov eax, 1
    jmp .Leng_wait_done
.Leng_wait_fail:
    xor eax, eax
.Leng_wait_done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN engine_wait

# Space toggles pause; Q stops; R toggles repeat. N or >, P or <, the arrow
# keys (ESC [ C/D/A/B), [ and ] stop with an engine_command for the caller, noting
# the file heard and the position in it.
LOCALFN engine_read_keys
    push rdi
    push rsi
    push rbx
    sub rsp, 32
    xor edi, edi
    lea rsi, [rip + key_buffer]
    mov edx, 16
    mov eax, SYS_read
    syscall
    test eax, eax
    jle .Leng_keys_done
    mov ebx, eax
    lea rsi, [rip + key_buffer]
.Leng_keys_next:
    movzx eax, byte ptr [rsi]
    cmp al, ' '
    jne .Leng_keys_escape
    xor dword ptr [rip + pause_requested], 1
    jmp .Leng_keys_advance
.Leng_keys_escape:
    cmp al, 27
    jne .Leng_keys_letter
    cmp ebx, 3                         # ESC [ and a letter
    jb .Leng_keys_advance
    cmp byte ptr [rsi + 1], '['
    jne .Leng_keys_advance
    movzx eax, byte ptr [rsi + 2]
    add rsi, 2
    sub ebx, 2
    mov ecx, 5
    cmp al, 'C'                        # right
    je .Leng_keys_seek
    mov ecx, -5
    cmp al, 'D'                        # left
    je .Leng_keys_seek
    mov ecx, 60
    cmp al, 'A'                        # up
    je .Leng_keys_seek
    mov ecx, -60
    cmp al, 'B'                        # down
    jne .Leng_keys_advance
.Leng_keys_seek:
    mov [rip + engine_seek_delta], ecx
    mov ecx, 3
    jmp .Leng_keys_command
.Leng_keys_letter:
    mov ecx, 6
    cmp al, ']'
    je .Leng_keys_command
    mov ecx, 7
    cmp al, '['
    je .Leng_keys_command
    mov ecx, 1
    cmp al, '>'
    je .Leng_keys_command
    mov ecx, 2
    cmp al, '<'
    je .Leng_keys_command
    or al, 0x20
    mov ecx, 1
    cmp al, 'n'
    je .Leng_keys_command
    mov ecx, 2
    cmp al, 'p'
    je .Leng_keys_command
    cmp al, 'r'
    je .Leng_keys_repeat
    cmp al, 'q'
    jne .Leng_keys_advance
    mov dword ptr [rip + engine_quit], 1
    mov dword ptr [rip + engine_stop_requested], 1
    jmp .Leng_keys_advance
.Leng_keys_repeat:
    xor dword ptr [rip + queue_repeat], 1
    lea rcx, [rip + repeat_on_text]
    jnz .Leng_keys_repeat_text
    lea rcx, [rip + repeat_off_text]
.Leng_keys_repeat_text:
    call print_text
    jmp .Leng_keys_advance
.Leng_keys_command:
    cmp dword ptr [rip + engine_command], 0
    jne .Leng_keys_advance             # the first command counts
    mov [rip + engine_command], ecx
    call engine_note_heard
    cmp dword ptr [rip + engine_heard_index], 0
    jns .Leng_keys_known
    mov dword ptr [rip + engine_command], 0
    jmp .Leng_keys_advance
.Leng_keys_known:
    mov dword ptr [rip + engine_stop_requested], 1
.Leng_keys_advance:
    inc rsi
    dec ebx
    jnz .Leng_keys_next
.Leng_keys_done:
    add rsp, 32
    pop rbx
    pop rsi
    pop rdi
    ret
ENDFN engine_read_keys

# engine_heard_index and engine_heard_ms <- the file at engine_position.
FN engine_note_heard
    sub rsp, 40
    mov rcx, [rip + engine_position]
    mov [rsp + 32], rcx
    call queue_heard
    mov [rip + engine_heard_index], eax
    test eax, eax
    js .Leng_heard_none
    mov rax, [rsp + 32]
    sub rax, rdx
    jae .Leng_heard_offset
    xor eax, eax
.Leng_heard_offset:
    mov ecx, 1000
    mul rcx
    mov ecx, [rip + queue_rate]
    test ecx, ecx
    jz .Leng_heard_none
    div rcx
    jmp .Leng_heard_store
.Leng_heard_none:
    xor eax, eax
.Leng_heard_store:
    mov [rip + engine_heard_ms], rax
    add rsp, 40
    ret
ENDFN engine_note_heard

# Unbuffered, unechoed terminal input while playing, when stdin is a terminal.
LOCALFN terminal_raw_mode
    push rdi
    push rsi
    xor edi, edi
    mov esi, TCGETS
    lea rdx, [rip + terminal_original]
    mov eax, SYS_ioctl
    syscall
    test eax, eax
    jnz .Lterm_raw_done
    lea rsi, [rip + terminal_original]
    lea rdi, [rip + terminal_raw]
    mov ecx, TERMIOS_SIZE
    rep movsb
    lea rdx, [rip + terminal_raw]
    and dword ptr [rdx + TERMIOS_LFLAG], ~(ICANON | ECHO)
    mov byte ptr [rdx + TERMIOS_CC + VMIN], 1
    mov byte ptr [rdx + TERMIOS_CC + VTIME], 0
    xor edi, edi
    mov esi, TCSETS
    mov eax, SYS_ioctl
    syscall
    test eax, eax
    jnz .Lterm_raw_done
    mov dword ptr [rip + terminal_changed], 1
.Lterm_raw_done:
    pop rsi
    pop rdi
    ret
ENDFN terminal_raw_mode

LOCALFN terminal_restore
    cmp dword ptr [rip + terminal_changed], 0
    je .Lterm_restore_done
    push rdi
    push rsi
    xor edi, edi
    mov esi, TCSETS
    lea rdx, [rip + terminal_original]
    mov eax, SYS_ioctl
    syscall
    pop rsi
    pop rdi
    mov dword ptr [rip + terminal_changed], 0
.Lterm_restore_done:
    ret
ENDFN terminal_restore

# SIGINT/SIGTERM handler (System V entry; the kernel restores all registers).
LOCALFN engine_signal
    mov dword ptr [rip + engine_quit], 1
    mov dword ptr [rip + engine_stop_requested], 1
    mov ecx, [rip + stop_event]
    test ecx, ecx
    js .Leng_signal_done
    sub rsp, 8
    call event_signal
    add rsp, 8
.Leng_signal_done:
    ret
ENDFN engine_signal

# RCX=interleaved stereo frames, RDX=frame count; scales by engine_volume.
LOCALFN engine_apply_volume
    movss xmm0, dword ptr [rip + engine_volume]
    shufps xmm0, xmm0, 0
    shl rdx, 1
.Leng_volume_four:
    cmp rdx, 4
    jb .Leng_volume_tail
    movups xmm1, [rcx]
    mulps xmm1, xmm0
    movups [rcx], xmm1
    add rcx, 16
    sub rdx, 4
    jmp .Leng_volume_four
.Leng_volume_tail:
    test rdx, rdx
    jz .Leng_volume_done
    movss xmm1, dword ptr [rcx]
    mulss xmm1, xmm0
    movss dword ptr [rcx], xmm1
    add rcx, 4
    dec rdx
    jmp .Leng_volume_tail
.Leng_volume_done:
    ret
ENDFN engine_apply_volume

# Decode worker. Only this thread touches the decoder during playback.
LOCALFN producer
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rcx, [rip + engine_seek_frames]
    test rcx, rcx
    jz .Lprod_loop
    call queue_seek
    mov [rip + decoded_count], rax
.Lprod_seek:
    cmp dword ptr [rip + engine_stop_requested], 0
    jne .Lprod_exit
    mov rax, [rip + engine_seek_frames]
    sub rax, [rip + decoded_count]
    jbe .Lprod_loop
    mov edx, CHUNK_FRAMES
    cmp rax, rdx
    cmovb edx, eax
    lea rcx, [rip + offline_pcm]
    call queue_read
    test eax, eax
    jz .Lprod_eof
    add [rip + decoded_count], rax
    jmp .Lprod_seek
.Lprod_loop:
    cmp dword ptr [rip + engine_stop_requested], 0
    jne .Lprod_exit
    mov rbx, [rip + write_count]
    mov rax, rbx
    sub rax, [rip + read_count]
    cmp rax, RING_FRAMES
    jae .Lprod_full
    mov edx, RING_FRAMES
    sub edx, eax
    cmp edx, CHUNK_FRAMES
    jbe .Lprod_chunk
    mov edx, CHUNK_FRAMES
.Lprod_chunk:
    mov rsi, rbx
    and esi, RING_MASK
    mov eax, RING_FRAMES
    sub eax, esi
    cmp edx, eax
    jbe .Lprod_contiguous
    mov edx, eax
.Lprod_contiguous:
    lea rcx, [rip + ring_pcm]
    lea rcx, [rcx + rsi*8]
    call queue_read
    test eax, eax
    jz .Lprod_eof
    add [rip + decoded_count], rax
    add rbx, rax
    mov [rip + write_count], rbx       # publish after all samples are written
    mov ecx, [rip + data_event]
    call event_signal
    jmp .Lprod_loop
.Lprod_full:
    # A full ring waits until a quarter of it has played, so the producer
    # wakes about once a second rather than at every send.
    mov ecx, [rip + space_event]
    call event_clear
    mov rax, [rip + write_count]       # recheck after clearing to avoid a lost wakeup
    sub rax, [rip + read_count]
    cmp rax, REFILL_FRAMES
    jbe .Lprod_loop
    lea rdi, [rsp + 16]                # wait for space or stop
    mov eax, [rip + space_event]
    mov [rdi], eax
    mov dword ptr [rdi + 4], POLLIN
    mov eax, [rip + stop_event]
    mov [rsp + 24], eax
    mov dword ptr [rsp + 28], POLLIN
    mov rcx, rdi
    mov edx, 2
    mov r8d, -1
    call poll_wait
    jmp .Lprod_loop
.Lprod_eof:                             # the queue checked each file's length
.Lprod_exit:
    mov dword ptr [rip + producer_done], 1
    mov ecx, [rip + data_event]
    call event_signal
    xor eax, eax
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN producer
