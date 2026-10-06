# LAMP PulseAudio native-protocol playback client: raw socket I/O, no libpulse.
# Speaks protocol version 15 over the local Unix socket, which both PulseAudio
# and PipeWire's pulse server accept. Audio travels inline as float32 stereo
# packets; the server resamples to the device. Single instance. MIT license.
.include "lamp.inc"
.include "linux.inc"

.equ PA_VERSION, 15
.equ PA_COMMAND_ERROR, 0
.equ PA_COMMAND_REPLY, 2
.equ PA_COMMAND_CREATE_PLAYBACK_STREAM, 3
.equ PA_COMMAND_DELETE_PLAYBACK_STREAM, 4
.equ PA_COMMAND_AUTH, 8
.equ PA_COMMAND_SET_CLIENT_NAME, 9
.equ PA_COMMAND_DRAIN_PLAYBACK_STREAM, 12
.equ PA_COMMAND_GET_SINK_INFO_LIST, 22
.equ PA_COMMAND_CORK_PLAYBACK_STREAM, 41
.equ PA_COMMAND_FLUSH_PLAYBACK_STREAM, 42
.equ PA_COMMAND_REQUEST, 61
.equ PA_COMMAND_UNDERFLOW, 63
.equ PA_COMMAND_PLAYBACK_STREAM_KILLED, 64
.equ PA_COMMAND_STARTED, 86
.equ PA_SAMPLE_FLOAT32LE, 5
.equ PA_VOLUME_NORM, 0x10000
.equ PA_COOKIE_BYTES, 256
.equ PA_HEADER, 20                    # length, channel, offset hi/lo, flags (big endian)
.equ PA_RECEIVE_CAP, 262144            # a sink list arrives in one packet
.equ PA_DATA_CAP, 65536               # largest audio packet this client sends
.equ PA_REPLY_CAP, PA_RECEIVE_CAP

.globl pulse_requested, pulse_underflows, pulse_started, pulse_device, pulse_sinks

.data
.p2align 3
pulse_device: .quad 0                  # sink name for new streams, 0 for the default
pa_fd: .long -1
pa_stream: .long -1
pa_runtime_name: .asciz "XDG_RUNTIME_DIR"
pa_server_name: .asciz "PULSE_SERVER"
pa_home_name: .asciz "HOME"
pa_socket_suffix: .asciz "/pulse/native"
pa_run_user: .asciz "/run/user/"
pa_cookie_suffix: .asciz "/.config/pulse/cookie"
pa_unix_prefix: .ascii "unix:"
pa_application_key: .asciz "application.name"
pa_application_value: .asciz "LAMP"
pa_media_key: .asciz "media.name"
pa_media_value: .asciz "LAMP playback"
pa_empty: .byte 0

.bss
.p2align 4
pulse_requested: .quad 0               # bytes the server asked for and has not received
pulse_underflows: .quad 0
pulse_started: .long 0
pa_tag: .long 0
pa_wait_tag: .long 0
pa_wait_result: .long 0                # 0 pending, 1 reply, 2 error
pa_killed: .long 0
pa_received: .long 0
pa_reply: .quad 0                      # copied reply payload after command/tag
pa_reply_end: .quad 0
pa_path: .zero 112
pa_number: .zero 16
.p2align 4
pa_command: .zero 1024
pa_reply_copy: .zero PA_REPLY_CAP
pa_header: .zero PA_HEADER
pa_receive: .zero PA_RECEIVE_CAP

.text
# -> EAX=1 when connected, authorized and named.
FN pulse_connect
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 296                       # 256-byte cookie, iovec scratch
    mov dword ptr [rip + pa_tag], 0
    mov dword ptr [rip + pa_received], 0
    mov dword ptr [rip + pa_killed], 0
    mov dword ptr [rip + pa_stream], -1
    call pulse_socket_path
    test eax, eax
    jz .Lpa_connect_fail
    mov edi, AF_UNIX
    mov esi, SOCK_STREAM | SOCK_CLOEXEC
    xor edx, edx
    mov eax, SYS_socket
    syscall
    test eax, eax
    js .Lpa_connect_fail
    mov [rip + pa_fd], eax
    mov edi, eax
    lea rsi, [rip + pa_path]
    mov edx, 110
    mov eax, SYS_connect
    syscall
    test eax, eax
    jnz .Lpa_connect_close
    # AUTH: version without SHM flags, then the cookie (zero when unreadable;
    # local servers accept same-user peer credentials instead).
    lea rcx, [rsp + 32]
    call pulse_read_cookie
    lea rdi, [rip + pa_command]
    mov eax, PA_COMMAND_AUTH
    call pa_begin
    mov eax, PA_VERSION
    call pa_u32
    mov byte ptr [rdi], 'x'
    mov dword ptr [rdi + 1], 0x00010000            # 256, big endian
    add rdi, 5
    lea rsi, [rsp + 32]
    mov ecx, PA_COOKIE_BYTES
    rep movsb
    call pa_send_command
    test eax, eax
    jz .Lpa_connect_close
    # SET_CLIENT_NAME with application.name
    lea rdi, [rip + pa_command]
    mov eax, PA_COMMAND_SET_CLIENT_NAME
    call pa_begin
    mov byte ptr [rdi], 'P'
    inc rdi
    lea rsi, [rip + pa_application_key]
    lea rdx, [rip + pa_application_value]
    call pa_property
    mov byte ptr [rdi], 'N'
    inc rdi
    call pa_send_command
    test eax, eax
    jz .Lpa_connect_close
    mov eax, 1
    jmp .Lpa_connect_done
.Lpa_connect_close:
    call pulse_close
.Lpa_connect_fail:
    xor eax, eax
.Lpa_connect_done:
    add rsp, 296
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN pulse_connect

# ECX=sample rate -> EAX=1 when a float32 stereo stream exists. EDX=target
# buffer in milliseconds. The server requests data as the buffer drains.
FN pulse_create_stream
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov ebx, ecx
    mov r12d, edx
    mov qword ptr [rip + pulse_requested], 0
    mov qword ptr [rip + pulse_underflows], 0
    mov dword ptr [rip + pulse_started], 0
    lea rdi, [rip + pa_command]
    mov eax, PA_COMMAND_CREATE_PLAYBACK_STREAM
    call pa_begin
    mov byte ptr [rdi], 'a'
    mov byte ptr [rdi + 1], PA_SAMPLE_FLOAT32LE
    mov byte ptr [rdi + 2], 2
    mov eax, ebx
    bswap eax
    mov [rdi + 3], eax
    mov dword ptr [rdi + 7], 0x0201026d            # 'm', 2 channels, front left, front right
    add rdi, 11
    mov eax, -1                        # the sink by name, or the default
    call pa_u32
    mov rsi, [rip + pulse_device]
    test rsi, rsi
    jz .Lpa_stream_default
    mov byte ptr [rdi], 't'
    inc rdi
    mov ecx, 256                       # names are short; a longer one fails
.Lpa_stream_name:
    movzx eax, byte ptr [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    test eax, eax
    jz .Lpa_stream_named
    dec ecx
    jnz .Lpa_stream_name
    jmp .Lpa_stream_fail
.Lpa_stream_default:
    mov byte ptr [rdi], 'N'
    inc rdi
.Lpa_stream_named:
    mov eax, -1                        # maxlength: server default
    call pa_u32
    mov byte ptr [rdi], '0'            # not corked
    inc rdi
    mov eax, ebx                       # tlength: rate * 8 bytes * milliseconds / 1000
    imul eax, r12d
    shl rax, 3
    xor edx, edx
    mov ecx, 1000
    div ecx
    and eax, -8
    call pa_u32
    mov eax, -1                        # prebuf: default (start when tlength is queued)
    call pa_u32
    mov eax, ebx                       # minreq: a quarter of tlength, so the server
    imul eax, r12d                     # asks for audio about 20 times a second
    shl rax, 3
    xor edx, edx
    mov ecx, 4000
    div ecx
    and eax, -8
    call pa_u32
    xor eax, eax                       # sync id
    call pa_u32
    mov byte ptr [rdi], 'v'
    mov byte ptr [rdi + 1], 2
    mov dword ptr [rdi + 2], 0x00000100            # PA_VOLUME_NORM, big endian
    mov dword ptr [rdi + 6], 0x00000100
    add rdi, 10
    # v12: no_remap, no_remix, fix_format, fix_rate, fix_channels, no_move, variable_rate
    # v13: start_muted, adjust_latency; v14: volume_set, early_requests
    # v15: muted_set, dont_inhibit_auto_suspend, fail_on_suspend
    mov rax, 0x3030303030303030
    mov [rdi], rax
    mov byte ptr [rdi + 8], '0'
    add rdi, 9
    mov byte ptr [rdi], 'P'
    inc rdi
    lea rsi, [rip + pa_media_key]
    lea rdx, [rip + pa_media_value]
    call pa_property
    mov byte ptr [rdi], 'N'
    mov dword ptr [rdi + 1], 0x30303030
    mov byte ptr [rdi + 5], '0'
    add rdi, 6
    call pa_send_command
    test eax, eax
    jz .Lpa_stream_fail
    mov rsi, [rip + pa_reply]
    mov rdx, [rip + pa_reply_end]
    call pa_read_u32                   # stream channel
    jc .Lpa_stream_fail
    mov [rip + pa_stream], eax
    call pa_read_u32                   # sink input
    jc .Lpa_stream_fail
    call pa_read_u32                   # initial missing bytes
    jc .Lpa_stream_fail
    mov [rip + pulse_requested], rax
    mov eax, 1
    jmp .Lpa_stream_done
.Lpa_stream_fail:
    xor eax, eax
.Lpa_stream_done:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN pulse_create_stream

# RCX=float32 stereo frames, RDX=bytes (at most PA_DATA_CAP) -> EAX=1 when sent.
FN pulse_write
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    lea rdi, [rip + pa_header]
    mov eax, r12d
    bswap eax
    mov [rdi], eax
    mov eax, [rip + pa_stream]
    bswap eax
    mov [rdi + 4], eax
    mov qword ptr [rdi + 8], 0         # offset; flags = PA_SEEK_RELATIVE
    mov dword ptr [rdi + 16], 0
    lea rcx, [rip + pa_header]
    mov edx, PA_HEADER
    mov r8, rbx
    mov r9, r12
    call pa_send2
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN pulse_write

# Reads and handles every packet already received, without blocking.
# -> EAX=0 when the connection or stream failed.
FN pulse_pump
    sub rsp, 40
.Lpa_pump_more:
    xor ecx, ecx
    call pa_receive_packet
    cmp eax, 1
    je .Lpa_pump_more
    test eax, eax
    jz .Lpa_pump_done                   # nothing complete
    xor eax, eax                       # failure
    add rsp, 40
    ret
.Lpa_pump_done:
    mov eax, 1
    cmp dword ptr [rip + pa_killed], 0
    je .Lpa_pump_return
    xor eax, eax
.Lpa_pump_return:
    add rsp, 40
    ret
ENDFN pulse_pump

# ECX=1 pauses, 0 resumes -> EAX=1 on success.
FN pulse_cork
    push rdi
    push rbx
    sub rsp, 40
    mov ebx, ecx
    lea rdi, [rip + pa_command]
    mov eax, PA_COMMAND_CORK_PLAYBACK_STREAM
    call pa_begin
    mov eax, [rip + pa_stream]
    call pa_u32
    mov al, '0'
    add al, bl
    mov [rdi], al
    inc rdi
    call pa_send_command
    add rsp, 40
    pop rbx
    pop rdi
    ret
ENDFN pulse_cork

# Discards queued server audio -> EAX=1 on success.
FN pulse_flush
    mov edx, PA_COMMAND_FLUSH_PLAYBACK_STREAM
    jmp pa_stream_command
ENDFN pulse_flush

# Waits until queued audio has played -> EAX=1 on success.
FN pulse_drain
    mov edx, PA_COMMAND_DRAIN_PLAYBACK_STREAM
    jmp pa_stream_command
ENDFN pulse_drain

# EDX=command taking only the stream channel -> EAX=1 on reply.
LOCALFN pa_stream_command
    push rdi
    push rbx
    sub rsp, 40
    mov ebx, edx
    lea rdi, [rip + pa_command]
    mov eax, ebx
    call pa_begin
    mov eax, [rip + pa_stream]
    call pa_u32
    call pa_send_command
    add rsp, 40
    pop rbx
    pop rdi
    ret
ENDFN pa_stream_command

# Deletes the stream (without waiting) and closes the connection.
FN pulse_close
    push rdi
    push rsi
    sub rsp, 40
    cmp dword ptr [rip + pa_fd], 0
    jl .Lpa_close_done
    cmp dword ptr [rip + pa_stream], 0
    jl .Lpa_close_socket
    lea rdi, [rip + pa_command]
    mov eax, PA_COMMAND_DELETE_PLAYBACK_STREAM
    call pa_begin
    mov eax, [rip + pa_stream]
    call pa_u32
    lea rcx, [rip + pa_command]
    mov rdx, rdi
    sub rdx, rcx
    call pa_send_packet
.Lpa_close_socket:
    mov edi, [rip + pa_fd]
    mov eax, SYS_close
    syscall
    mov dword ptr [rip + pa_fd], -1
    mov dword ptr [rip + pa_stream], -1
.Lpa_close_done:
    add rsp, 40
    pop rsi
    pop rdi
    ret
ENDFN pulse_close

# -> EAX=socket descriptor or -1, for poll.
FN pulse_fd
    mov eax, [rip + pa_fd]
    ret
ENDFN pulse_fd

# ---------------------------------------------------------------- helpers
# Builds pa_path from PULSE_SERVER (unix:PATH or /PATH), XDG_RUNTIME_DIR or
# /run/user/UID. -> EAX=1 when the path fits sockaddr_un.
LOCALFN pulse_socket_path
    push rsi
    push rdi
    push rbx
    sub rsp, 32
    lea rdi, [rip + pa_path]
    mov word ptr [rdi], AF_UNIX
    add rdi, 2
    lea rcx, [rip + pa_server_name]
    call env_get
    test rax, rax
    jz .Lpa_path_runtime
    mov rsi, rax
    mov eax, [rsi]
    cmp eax, [rip + pa_unix_prefix]
    jne .Lpa_path_server_absolute
    cmp byte ptr [rsi + 4], ':'
    jne .Lpa_path_server_absolute
    add rsi, 5
.Lpa_path_server_absolute:
    cmp byte ptr [rsi], '/'
    jne .Lpa_path_fail                 # remote servers are not supported
    lea rbx, [rip + pa_path + 109]
    call pa_append
    jc .Lpa_path_fail
    jmp .Lpa_path_ok
.Lpa_path_runtime:
    lea rcx, [rip + pa_runtime_name]
    call env_get
    lea rbx, [rip + pa_path + 109]
    test rax, rax
    jz .Lpa_path_uid
    mov rsi, rax
    call pa_append
    jc .Lpa_path_fail
    jmp .Lpa_path_suffix
.Lpa_path_uid:
    lea rsi, [rip + pa_run_user]
    call pa_append
    mov eax, SYS_getuid
    syscall
    lea rsi, [rip + pa_number + 15]
    mov byte ptr [rsi], 0
    mov ecx, 10
.Lpa_path_digit:
    xor edx, edx
    div ecx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test eax, eax
    jnz .Lpa_path_digit
    call pa_append
.Lpa_path_suffix:
    lea rsi, [rip + pa_socket_suffix]
    call pa_append
    jc .Lpa_path_fail
.Lpa_path_ok:
    mov byte ptr [rdi], 0
    mov eax, 1
    jmp .Lpa_path_done
.Lpa_path_fail:
    xor eax, eax
.Lpa_path_done:
    add rsp, 32
    pop rbx
    pop rdi
    pop rsi
    ret
ENDFN pulse_socket_path

# RSI=text, RDI=destination, RBX=limit -> RDI after the copy; CF on overflow.
LOCALFN pa_append
.Lpa_append_loop:
    mov al, [rsi]
    test al, al
    jz .Lpa_append_done
    cmp rdi, rbx
    jae .Lpa_append_overflow
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .Lpa_append_loop
.Lpa_append_done:
    clc
    ret
.Lpa_append_overflow:
    stc
    ret
ENDFN pa_append

# RCX=256-byte buffer, filled from $HOME/.config/pulse/cookie or zeroed.
LOCALFN pulse_read_cookie
    push rsi
    push rdi
    push rbx
    push r12
    sub rsp, 296
    mov r12, rcx
    mov rdi, rcx
    mov ecx, PA_COOKIE_BYTES
    xor eax, eax
    rep stosb
    lea rcx, [rip + pa_home_name]
    call env_get
    test rax, rax
    jz .Lpa_cookie_done
    mov rsi, rax
    lea rdi, [rsp + 32]
    lea rbx, [rsp + 32 + 200]
    call pa_append
    jc .Lpa_cookie_done
    lea rsi, [rip + pa_cookie_suffix]
    lea rbx, [rsp + 32 + 255]
    call pa_append
    jc .Lpa_cookie_done
    mov byte ptr [rdi], 0
    lea rdi, [rsp + 32]
    mov esi, O_RDONLY | O_CLOEXEC
    mov eax, SYS_open
    syscall
    test eax, eax
    js .Lpa_cookie_done
    mov ebx, eax
    mov edi, eax
    mov rsi, r12
    mov edx, PA_COOKIE_BYTES
    mov eax, SYS_read
    syscall
    cmp eax, PA_COOKIE_BYTES
    je .Lpa_cookie_close
    mov rdi, r12                       # short or failed read: send zeros
    mov ecx, PA_COOKIE_BYTES
    xor eax, eax
    rep stosb
.Lpa_cookie_close:
    mov edi, ebx
    mov eax, SYS_close
    syscall
.Lpa_cookie_done:
    add rsp, 296
    pop r12
    pop rbx
    pop rdi
    pop rsi
    ret
ENDFN pulse_read_cookie

# EAX=command, RDI=command buffer -> RDI past the command and new tag.
LOCALFN pa_begin
    add rdi, PA_HEADER
    call pa_u32
    mov eax, [rip + pa_tag]
    inc eax
    mov [rip + pa_tag], eax
    mov [rip + pa_wait_tag], eax
    jmp pa_u32
ENDFN pa_begin

# EAX=value, RDI=destination -> 'L' tag and big-endian value; RDI advances.
LOCALFN pa_u32
    mov byte ptr [rdi], 'L'
    bswap eax
    mov [rdi + 1], eax
    add rdi, 5
    ret
ENDFN pa_u32

# RSI=key, RDX=NUL-terminated value, RDI=destination: one proplist entry.
LOCALFN pa_property
    push rbx
    mov byte ptr [rdi], 't'
    inc rdi
.Lpa_property_key:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .Lpa_property_key
    mov rsi, rdx
    xor ebx, ebx
.Lpa_property_length:
    cmp byte ptr [rsi + rbx], 0
    lea rbx, [rbx + 1]                 # value bytes include the terminator
    jne .Lpa_property_length
    mov eax, ebx
    call pa_u32
    mov byte ptr [rdi], 'x'
    mov eax, ebx
    bswap eax
    mov [rdi + 1], eax
    add rdi, 5
    mov ecx, ebx
    rep movsb
    pop rbx
    ret
ENDFN pa_property

# RDI=end of a command in pa_command. Sends it and waits for its reply.
# -> EAX=1 on reply, 0 on error or disconnect; pa_reply/pa_reply_end hold the payload.
LOCALFN pa_send_command
    push rbx
    sub rsp, 32
    lea rcx, [rip + pa_command]
    mov rdx, rdi
    sub rdx, rcx
    call pa_send_packet
    test eax, eax
    jz .Lpa_command_done
    mov dword ptr [rip + pa_wait_result], 0
.Lpa_command_wait:
    mov ecx, 1                         # block until a packet arrives
    call pa_receive_packet
    cmp eax, -1
    je .Lpa_command_fail
    mov eax, [rip + pa_wait_result]
    test eax, eax
    jz .Lpa_command_wait
    mov ebx, eax
.Lpa_command_buffered:                 # handle events that arrived with the reply
    mov ecx, 2
    call pa_receive_packet
    cmp eax, 1
    je .Lpa_command_buffered
    cmp ebx, 1
    sete al
    movzx eax, al
    jmp .Lpa_command_done
.Lpa_command_fail:
    xor eax, eax
.Lpa_command_done:
    add rsp, 32
    pop rbx
    ret
ENDFN pa_send_command

# RCX=command buffer with room for its header, RDX=total bytes including the header.
LOCALFN pa_send_packet
    sub rsp, 40
    lea eax, [rdx - PA_HEADER]
    bswap eax
    mov [rcx], eax
    mov dword ptr [rcx + 4], -1        # command channel
    mov qword ptr [rcx + 8], 0
    mov dword ptr [rcx + 16], 0
    xor r8d, r8d
    xor r9d, r9d
    call pa_send2
    add rsp, 40
    ret
ENDFN pa_send_packet

# RCX/RDX=first buffer, R8/R9=second buffer -> EAX=1 when every byte was written.
LOCALFN pa_send2
    push rsi
    push rdi
    push rbx
    sub rsp, 48
    mov [rsp], rcx
    mov [rsp + 8], rdx
    mov [rsp + 16], r8
    mov [rsp + 24], r9
.Lpa_send_more:
    mov rax, [rsp + 8]
    or rax, [rsp + 24]
    jz .Lpa_send_ok
    mov edi, [rip + pa_fd]
    mov rsi, rsp
    mov edx, 2
    cmp qword ptr [rsp + 8], 0
    jne .Lpa_send_vector
    lea rsi, [rsp + 16]
    mov edx, 1
.Lpa_send_vector:
    mov eax, SYS_writev
    syscall
    cmp rax, -EINTR
    je .Lpa_send_more
    test rax, rax
    jle .Lpa_send_fail
    mov rcx, [rsp + 8]                 # consume from the first buffer, then the second
    cmp rax, rcx
    jb .Lpa_send_first
    sub rax, rcx
    mov qword ptr [rsp + 8], 0
    add [rsp + 16], rax
    sub [rsp + 24], rax
    jmp .Lpa_send_more
.Lpa_send_first:
    add [rsp], rax
    sub [rsp + 8], rax
    jmp .Lpa_send_more
.Lpa_send_ok:
    mov eax, 1
    jmp .Lpa_send_done
.Lpa_send_fail:
    xor eax, eax
.Lpa_send_done:
    add rsp, 48
    pop rbx
    pop rdi
    pop rsi
    ret
ENDFN pa_send2

# ECX=1 blocks until one packet is complete, 0 reads without blocking, and 2
# only uses bytes already received. Handles one complete packet.
# -> EAX=1 handled a packet, 0 nothing complete, -1 failure.
LOCALFN pa_receive_packet
    push rsi
    push rdi
    push rbx
    push r12
    sub rsp, 40
    mov r12d, ecx
.Lpa_receive_check:
    mov ebx, [rip + pa_received]
    cmp ebx, PA_HEADER
    jb .Lpa_receive_read
    mov eax, [rip + pa_receive]
    bswap eax
    cmp eax, PA_RECEIVE_CAP - PA_HEADER
    ja .Lpa_receive_fail
    add eax, PA_HEADER
    cmp ebx, eax
    jb .Lpa_receive_read
    mov ebx, eax                       # complete packet of EBX bytes
    lea rcx, [rip + pa_receive]
    lea rdx, [rcx + rbx]
    call pa_handle_packet
    test eax, eax
    jz .Lpa_receive_fail
    mov ecx, [rip + pa_received]       # keep any following bytes
    sub ecx, ebx
    mov [rip + pa_received], ecx
    lea rdi, [rip + pa_receive]
    lea rsi, [rdi + rbx]
    rep movsb
    mov eax, 1
    jmp .Lpa_receive_done
.Lpa_receive_read:
    cmp r12d, 2
    je .Lpa_receive_empty
    mov edi, [rip + pa_fd]
    lea rsi, [rip + pa_receive]
    add rsi, rbx
    mov edx, PA_RECEIVE_CAP
    sub edx, ebx
    xor r10d, r10d
    cmp r12d, 1
    je .Lpa_receive_call
    mov r10d, 0x40                     # MSG_DONTWAIT
.Lpa_receive_call:
    xor r8d, r8d
    xor r9d, r9d
    mov eax, SYS_recvfrom
    syscall
    cmp rax, -EINTR
    je .Lpa_receive_read
    cmp rax, -EAGAIN
    je .Lpa_receive_empty
    test rax, rax
    jle .Lpa_receive_fail              # error or server closed the connection
    add [rip + pa_received], eax
    jmp .Lpa_receive_check
.Lpa_receive_empty:
    xor eax, eax
    jmp .Lpa_receive_done
.Lpa_receive_fail:
    mov dword ptr [rip + pa_killed], 1
    mov eax, -1
.Lpa_receive_done:
    add rsp, 40
    pop r12
    pop rbx
    pop rdi
    pop rsi
    ret
ENDFN pa_receive_packet

# RCX=packet, RDX=end. Commands only: replies, errors and stream events.
# -> EAX=0 on a malformed packet.
LOCALFN pa_handle_packet
    push rsi
    push rbx
    sub rsp, 40
    cmp dword ptr [rcx + 4], -1
    jne .Lpa_handle_ignore             # this client never receives audio
    lea rsi, [rcx + PA_HEADER]
    call pa_read_u32
    jc .Lpa_handle_bad
    mov ebx, eax                       # command
    call pa_read_u32
    jc .Lpa_handle_bad                 # EAX=tag
    cmp ebx, PA_COMMAND_REPLY
    je .Lpa_handle_reply
    cmp ebx, PA_COMMAND_ERROR
    je .Lpa_handle_error
    cmp ebx, PA_COMMAND_REQUEST
    je .Lpa_handle_request
    cmp ebx, PA_COMMAND_UNDERFLOW
    je .Lpa_handle_underflow
    cmp ebx, PA_COMMAND_STARTED
    je .Lpa_handle_started
    cmp ebx, PA_COMMAND_PLAYBACK_STREAM_KILLED
    je .Lpa_handle_killed
    jmp .Lpa_handle_ignore             # overflow, suspend, move, buffer and other events
.Lpa_handle_reply:
    cmp eax, [rip + pa_wait_tag]
    jne .Lpa_handle_ignore
    push rdi                           # copy: the receive buffer is compacted next
    mov rcx, rdx
    sub rcx, rsi
    cmp rcx, PA_REPLY_CAP
    jbe .Lpa_handle_reply_copy
    mov ecx, PA_REPLY_CAP
.Lpa_handle_reply_copy:
    lea rdi, [rip + pa_reply_copy]
    mov [rip + pa_reply], rdi
    lea rax, [rdi + rcx]
    mov [rip + pa_reply_end], rax
    rep movsb
    pop rdi
    mov dword ptr [rip + pa_wait_result], 1
    jmp .Lpa_handle_ignore
.Lpa_handle_error:
    cmp eax, [rip + pa_wait_tag]
    jne .Lpa_handle_ignore
    mov dword ptr [rip + pa_wait_result], 2
    jmp .Lpa_handle_ignore
.Lpa_handle_request:
    call pa_read_u32
    jc .Lpa_handle_bad
    cmp eax, [rip + pa_stream]
    jne .Lpa_handle_ignore
    call pa_read_u32
    jc .Lpa_handle_bad
    add [rip + pulse_requested], rax
    jmp .Lpa_handle_ignore
.Lpa_handle_underflow:
    call pa_read_u32
    jc .Lpa_handle_bad
    cmp eax, [rip + pa_stream]
    jne .Lpa_handle_ignore
    inc qword ptr [rip + pulse_underflows]
    jmp .Lpa_handle_ignore
.Lpa_handle_started:
    mov dword ptr [rip + pulse_started], 1
    jmp .Lpa_handle_ignore
.Lpa_handle_killed:
    call pa_read_u32
    jc .Lpa_handle_bad
    cmp eax, [rip + pa_stream]
    jne .Lpa_handle_ignore
    mov dword ptr [rip + pa_killed], 1
.Lpa_handle_ignore:
    mov eax, 1
    jmp .Lpa_handle_done
.Lpa_handle_bad:
    xor eax, eax
.Lpa_handle_done:
    add rsp, 40
    pop rbx
    pop rsi
    ret
ENDFN pa_handle_packet

# RCX=callback, called with ECX=sink index, RDX=its name, R8=its description
# (NUL-terminated, valid during the call) for each sink -> EAX=1 when the
# server listed them. Needs pulse_connect.
FN pulse_sinks
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov r12, rcx
    lea rdi, [rip + pa_command]
    mov eax, PA_COMMAND_GET_SINK_INFO_LIST
    call pa_begin
    call pa_send_command
    test eax, eax
    jz .Lpa_sinks_fail
    mov rsi, [rip + pa_reply]
    mov rdx, [rip + pa_reply_end]
.Lpa_sinks_entry:
    cmp rsi, rdx
    jae .Lpa_sinks_done
    call pa_read_u32                   # index
    jc .Lpa_sinks_fail
    mov ebx, eax
    cmp byte ptr [rsi], 't'            # name
    jne .Lpa_sinks_fail
    lea r13, [rsi + 1]
    call pa_skip
    jc .Lpa_sinks_fail
    cmp byte ptr [rsi], 't'            # description
    lea rdi, [rsi + 1]
    je .Lpa_sinks_fields
    lea rdi, [rip + pa_empty]          # none
.Lpa_sinks_fields:
    call pa_skip
    jc .Lpa_sinks_fail
    # The rest of a version 15 entry: sample spec, channel map, owner module,
    # volume, mute, monitor source and its name, latency, driver, flags,
    # properties, configured latency, base volume, state, volume steps and
    # card.
    mov ecx, 16
.Lpa_sinks_skip:
    push rcx
    call pa_skip
    pop rcx
    jc .Lpa_sinks_fail
    dec ecx
    jnz .Lpa_sinks_skip
    push rsi
    push rdx
    mov ecx, ebx
    mov rdx, r13
    mov r8, rdi
    sub rsp, 32
    call r12
    add rsp, 32
    pop rdx
    pop rsi
    jmp .Lpa_sinks_entry
.Lpa_sinks_done:
    mov eax, 1
    jmp .Lpa_sinks_return
.Lpa_sinks_fail:
    xor eax, eax
.Lpa_sinks_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN pulse_sinks

# RSI=tagstruct cursor, RDX=end: skips one value -> RSI advances; CF when it
# is missing or of an unknown type.
LOCALFN pa_skip
    cmp rsi, rdx
    jae .Lpa_skip_bad
    movzx eax, byte ptr [rsi]
    inc rsi
    cmp eax, 't'                       # a string
    je .Lpa_skip_string
    mov ecx, 0
    cmp eax, 'N'
    je .Lpa_skip_fixed
    cmp eax, '1'
    je .Lpa_skip_fixed
    cmp eax, '0'
    je .Lpa_skip_fixed
    mov ecx, 1
    cmp eax, 'B'
    je .Lpa_skip_fixed
    mov ecx, 4
    cmp eax, 'L'
    je .Lpa_skip_fixed
    cmp eax, 'V'
    je .Lpa_skip_fixed
    mov ecx, 6
    cmp eax, 'a'                       # format, channels, rate
    je .Lpa_skip_fixed
    mov ecx, 8
    cmp eax, 'R'
    je .Lpa_skip_fixed
    cmp eax, 'r'
    je .Lpa_skip_fixed
    cmp eax, 'U'
    je .Lpa_skip_fixed
    cmp eax, 'T'                       # a timeval
    je .Lpa_skip_fixed
    cmp eax, 'm'                       # channels, then a byte each
    je .Lpa_skip_map
    cmp eax, 'v'                       # channels, then four bytes each
    je .Lpa_skip_volume
    cmp eax, 'x'
    je .Lpa_skip_arbitrary
    cmp eax, 'P'
    je .Lpa_skip_properties
    cmp eax, 'f'                       # encoding, then properties
    je .Lpa_skip_format
    jmp .Lpa_skip_bad
.Lpa_skip_string:
    cmp rsi, rdx
    jae .Lpa_skip_bad
    inc rsi
    cmp byte ptr [rsi - 1], 0
    jne .Lpa_skip_string
    clc
    ret
.Lpa_skip_fixed:
    add rsi, rcx
    cmp rsi, rdx
    ja .Lpa_skip_bad
    clc
    ret
.Lpa_skip_map:
    cmp rsi, rdx
    jae .Lpa_skip_bad
    movzx ecx, byte ptr [rsi]
    inc rsi
    jmp .Lpa_skip_fixed
.Lpa_skip_volume:
    cmp rsi, rdx
    jae .Lpa_skip_bad
    movzx ecx, byte ptr [rsi]
    inc rsi
    shl ecx, 2
    jmp .Lpa_skip_fixed
.Lpa_skip_arbitrary:
    lea rax, [rsi + 4]
    cmp rax, rdx
    ja .Lpa_skip_bad
    mov ecx, [rsi]
    bswap ecx
    add rsi, 4
    jmp .Lpa_skip_fixed
.Lpa_skip_properties:
    cmp rsi, rdx
    jae .Lpa_skip_bad
    cmp byte ptr [rsi], 'N'            # the end of the list
    je .Lpa_skip_properties_end
    call pa_skip                       # key
    jc .Lpa_skip_bad
    call pa_skip                       # length
    jc .Lpa_skip_bad
    call pa_skip                       # value
    jc .Lpa_skip_bad
    jmp .Lpa_skip_properties
.Lpa_skip_properties_end:
    inc rsi
    clc
    ret
.Lpa_skip_format:
    call pa_skip
    jc .Lpa_skip_bad
    jmp pa_skip
.Lpa_skip_bad:
    stc
    ret
ENDFN pa_skip

# RSI=tagstruct cursor, RDX=end -> EAX=u32, RSI advances; CF when missing.
LOCALFN pa_read_u32
    lea rax, [rsi + 5]
    cmp rax, rdx
    ja .Lpa_read_missing
    cmp byte ptr [rsi], 'L'
    jne .Lpa_read_missing
    mov eax, [rsi + 1]
    bswap eax
    add rsi, 5
    clc
    ret
.Lpa_read_missing:
    stc
    ret
ENDFN pa_read_u32
