# Original bounded WASAPI exclusive setup, rendering and device clock. MIT.
.include "lamp.inc"
RODATA
.p2align 2
ex_iid_client: .long 0x1cb9ad4c
    .short 0xdbfa, 0x4c32
    .byte 0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 3, 0xb2
ex_iid_render: .long 0xf294acfc
    .short 0x3146, 0x4483
    .byte 0xa7, 0xbf, 0xad, 0xdc, 0xa7, 0xc2, 0x60, 0xe2
ex_iid_clock: .long 0xcd63314f
    .short 0x3fba, 0x4a1b
    .byte 0x81, 0x2c, 0xef, 0x96, 0x35, 0x87, 0x28, 0xe7
ex_block_bytes: .byte 8,8,8,6,4,8,8,6,4
.p2align 2
ex_one: .float 1.0
.text
# State (96 bytes): profile[48], client*, render*, clock*, frequency QWORD,
# buffer frames DWORD, reserved DWORD, requested period QWORD (100 ns).
# RCX=zero-initialized state. Caller stops the client before closing.
FN output_exclusive_close
    push rbx
    sub rsp, 32
    mov rbx, rcx
    test rbx, rbx
    jz .Lex_close_done
    mov rcx, [rbx+64]
    mov qword ptr [rbx+64], 0
    test rcx, rcx
    jz .Lex_close_render
    mov rax, [rcx]
    call qword ptr [rax+16]
.Lex_close_render:
    mov rcx, [rbx+56]
    mov qword ptr [rbx+56], 0
    test rcx, rcx
    jz .Lex_close_client
    mov rax, [rcx]
    call qword ptr [rax+16]
.Lex_close_client:
    mov rcx, [rbx+48]
    mov qword ptr [rbx+48], 0
    test rcx, rcx
    jz .Lex_close_clear
    mov rax, [rcx]
    call qword ptr [rax+16]
.Lex_close_clear:
    pxor xmm0, xmm0
    movdqu [rbx], xmm0
    movdqu [rbx+16], xmm0
    movdqu [rbx+32], xmm0
    movdqu [rbx+48], xmm0
    movdqu [rbx+64], xmm0
    movdqu [rbx+80], xmm0
.Lex_close_done:
    add rsp, 32
    pop rbx
    ret
ENDFN output_exclusive_close

# RCX=IMMDevice, EDX=rate, R8=event, R9=96-byte destination state.
# Destination must be empty (no owned interfaces); unchanged on failure.
# No Start, no shared fallback, one alignment retry with a fresh client.
# Calls may acquire the endpoint; unlike output_format_choose this is NOT a
# capability-only query. All calls and releases stay on the owner STA thread.
FN output_exclusive_open
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 192
    mov rsi, rcx
    mov edi, edx
    mov r12, r8
    mov r13, r9
    test rsi, rsi
    jz .Lex_invalid
    test r12, r12
    jz .Lex_invalid
    cmp r12, -1
    je .Lex_invalid
    test r13, r13
    jz .Lex_invalid
    cmp edi, 8000
    jb .Lex_invalid
    cmp edi, 192000
    ja .Lex_invalid
    mov rax, [r13+48]
    or rax, [r13+56]
    or rax, [r13+64]
    jnz .Lex_invalid
    pxor xmm0, xmm0
    movdqu [rsp+64], xmm0
    movdqu [rsp+80], xmm0
    movdqu [rsp+96], xmm0
    movdqu [rsp+112], xmm0
    movdqu [rsp+128], xmm0
    movdqu [rsp+144], xmm0
    xor ebx, ebx                       # at most one alignment recovery
.Lex_activate:
    mov rcx, rsi
    lea rdx, [rip+ex_iid_client]
    mov r8d, 1                         # CLSCTX_INPROC_SERVER
    xor r9d, r9d
    lea rax, [rsp+112]
    mov [rsp+32], rax
    mov rax, [rcx]
    call qword ptr [rax+24]
    test eax, eax
    jne .Lex_failed
    cmp qword ptr [rsp+112], 0
    je .Lex_unexpected
    test ebx, ebx
    jnz .Lex_initialize
    mov rcx, [rsp+112]
    mov edx, edi
    lea r8, [rsp+64]
    mov r9d, 48
    call output_format_choose
    test eax, eax
    jne .Lex_failed
    mov rcx, [rsp+112]
    lea rdx, [rsp+152]                  # default period, becomes state.period
    lea r8, [rsp+160]                   # minimum period
    mov rax, [rcx]
    call qword ptr [rax+72]
    test eax, eax
    jne .Lex_failed
    mov rax, [rsp+152]
    mov rdx, [rsp+160]
    test rax, rax
    jle .Lex_unexpected
    test rdx, rdx
    jle .Lex_unexpected
    cmp rax, rdx
    cmovb rax, rdx
    mov edx, 100000                    # relaxed >=10ms; no minimum-latency claim
    cmp rax, rdx
    cmovb rax, rdx
    cmp rax, 2000000                   # bound requested period at 200ms
    ja .Lex_unexpected
    mov [rsp+152], rax
.Lex_initialize:
    mov rcx, [rsp+112]
    mov edx, 1                         # EXCLUSIVE
    mov r8d, 0x40000                   # EVENTCALLBACK, no engine conversion
    mov r9, [rsp+152]
    mov [rsp+32], r9                    # matching duration and period
    lea rax, [rsp+64]
    mov [rsp+40], rax
    mov qword ptr [rsp+48], 0
    mov rax, [rcx]
    call qword ptr [rax+24]
    test eax, eax
    jz .Lex_initialized
    cmp eax, 0x88890019                 # BUFFER_SIZE_NOT_ALIGNED
    jne .Lex_failed
    test ebx, ebx
    jnz .Lex_failed
    mov rcx, [rsp+112]
    lea rdx, [rsp+144]
    mov rax, [rcx]
    call qword ptr [rax+32]
    test eax, eax
    jne .Lex_failed
    mov eax, [rsp+144]
    test eax, eax
    jz .Lex_unexpected
    cmp eax, 262144
    ja .Lex_unexpected
    imul rax, rax, 10000000
    mov edx, edi
    shr edx, 1
    add rax, rdx
    xor edx, edx
    div rdi                            # nearest whole 100ns, integer arithmetic
    test rax, rax
    jz .Lex_unexpected
    cmp rax, 2000000
    ja .Lex_unexpected
    mov [rsp+152], rax
    mov rcx, [rsp+112]
    mov qword ptr [rsp+112], 0
    mov rax, [rcx]
    call qword ptr [rax+16]
    inc ebx
    jmp .Lex_activate
.Lex_initialized:
    mov rcx, [rsp+112]
    mov rdx, r12
    mov rax, [rcx]
    call qword ptr [rax+104]            # attach event promptly after Initialize
    test eax, eax
    jne .Lex_failed
    mov rcx, [rsp+112]
    lea rdx, [rsp+144]
    mov rax, [rcx]
    call qword ptr [rax+32]
    test eax, eax
    jne .Lex_failed
    mov eax, [rsp+144]
    test eax, eax
    jz .Lex_unexpected
    cmp eax, 262144
    ja .Lex_unexpected
    mov rcx, [rsp+112]
    lea rdx, [rip+ex_iid_render]
    lea r8, [rsp+120]
    mov rax, [rcx]
    call qword ptr [rax+112]
    test eax, eax
    jne .Lex_failed
    cmp qword ptr [rsp+120], 0
    je .Lex_unexpected
    mov rcx, [rsp+112]
    lea rdx, [rip+ex_iid_clock]
    lea r8, [rsp+128]
    mov rax, [rcx]
    call qword ptr [rax+112]
    test eax, eax
    jne .Lex_failed
    cmp qword ptr [rsp+128], 0
    je .Lex_unexpected
    mov rcx, [rsp+128]
    lea rdx, [rsp+136]
    mov rax, [rcx]
    call qword ptr [rax+24]
    test eax, eax
    jne .Lex_failed
    cmp qword ptr [rsp+136], 0
    je .Lex_unexpected
    movdqu xmm0, [rsp+64]
    movdqu xmm1, [rsp+80]
    movdqu xmm2, [rsp+96]
    movdqu xmm3, [rsp+112]
    movdqu xmm4, [rsp+128]
    movdqu xmm5, [rsp+144]
    movdqu [r13], xmm0
    movdqu [r13+16], xmm1
    movdqu [r13+32], xmm2
    movdqu [r13+48], xmm3
    movdqu [r13+64], xmm4
    movdqu [r13+80], xmm5
    xor eax, eax
    jmp .Lex_return
.Lex_unexpected:
    mov eax, 0x8000ffff
.Lex_failed:
    test eax, eax
    js .Lex_save_error
    mov eax, 0x8000ffff                 # only S_OK means valid ownership
.Lex_save_error:
    mov [rsp+176], eax
    lea rcx, [rsp+64]
    call output_exclusive_close
    mov eax, [rsp+176]
    jmp .Lex_return
.Lex_invalid:
    mov eax, 0x80070057
.Lex_return:
    add rsp, 192
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN output_exclusive_open

# RCX=state, RDX=contiguous float stereo input, R8D=real frames,
# XMM3=volume. Writes/releases exactly state.buffer_frames, padding the last
# block with silence. Zero real frames uses SILENT without touching ppData.
# No Start/Stop, heap or waits. EAX=HRESULT; caller advances its queue only
# after S_OK. BUFFER_ERROR is returned unchanged, without ReleaseBuffer.
FN output_exclusive_write
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 96
    mov rbx, rcx
    mov rsi, rdx
    mov r12d, r8d
    movss dword ptr [rsp+56], xmm3
    test rbx, rbx
    jz .Lex_write_invalid
    cmp qword ptr [rbx+56], 0
    je .Lex_write_invalid
    mov r13d, [rbx+80]
    test r13d, r13d
    jz .Lex_write_invalid
    cmp r13d, 262144
    ja .Lex_write_invalid
    cmp r12d, r13d
    ja .Lex_write_invalid
    test r12d, r12d
    jz .Lex_write_input_valid
    test rsi, rsi
    jz .Lex_write_invalid
.Lex_write_input_valid:
    mov eax, [rbx+40]
    cmp eax, 9
    jae .Lex_write_invalid
    lea rdx, [rip+ex_block_bytes]
    movzx eax, byte ptr [rdx+rax]
    cmp ax, [rbx+12]
    jne .Lex_write_invalid
    imul eax, r13d
    mov [rsp+72], rax
    pxor xmm0, xmm0
    ucomiss xmm3, xmm0
    jp .Lex_write_invalid
    jb .Lex_write_invalid
    ucomiss xmm3, dword ptr [rip+ex_one]
    ja .Lex_write_invalid
    mov qword ptr [rsp+64], 0
    mov rcx, [rbx+56]
    mov edx, r13d
    lea r8, [rsp+64]
    mov rax, [rcx]
    call qword ptr [rax+24]
    test eax, eax
    jne .Lex_write_status
    test r12d, r12d
    jz .Lex_write_silent
    cmp qword ptr [rsp+64], 0
    je .Lex_write_pack_failed
    mov rcx, [rsp+64]
    mov rdx, rsi
    mov r8d, r12d
    mov r9d, [rbx+40]
    mov rax, [rsp+72]
    mov [rsp+32], rax
    mov eax, [rsp+56]
    mov [rsp+40], eax
    call output_format_pack
    test eax, eax
    jz .Lex_write_pack_failed
    movzx eax, word ptr [rbx+12]
    imul eax, r12d
    mov rdi, [rsp+64]
    add rdi, rax
    mov rcx, [rsp+72]
    sub rcx, rax
    xor eax, eax
    rep stosb                          # final/starved partial block is explicit zero
    xor r8d, r8d
    jmp .Lex_write_release
.Lex_write_silent:
    mov r8d, 2                         # AUDCLNT_BUFFERFLAGS_SILENT
.Lex_write_release:
    mov rcx, [rbx+56]
    mov edx, r13d
    mov rax, [rcx]
    call qword ptr [rax+32]
    jmp .Lex_write_status
.Lex_write_pack_failed:
    mov rcx, [rbx+56]                  # pair even a defensive packing failure
    mov edx, r13d
    mov r8d, 2
    mov rax, [rcx]
    call qword ptr [rax+32]
.Lex_write_invalid:
    mov eax, 0x80070057
    jmp .Lex_write_return
.Lex_write_status:
    test eax, eax
    jle .Lex_write_return
    mov eax, 0x8000ffff
.Lex_write_return:
    add rsp, 96
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN output_exclusive_write

# RCX=state, RDX=QWORD result in session frames. Failure leaves it untouched.
# GetPosition's S_FALSE is a valid, less precise reading, not a reason to spin.
# Exact 128-bit integer multiply/divide handles arbitrary clock frequencies.
FN output_exclusive_position
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    test rbx, rbx
    jz .Lex_position_invalid
    test rsi, rsi
    jz .Lex_position_invalid
    cmp qword ptr [rbx+64], 0
    je .Lex_position_invalid
    cmp qword ptr [rbx+72], 0
    je .Lex_position_invalid
    mov eax, [rbx+4]
    cmp eax, 8000
    jb .Lex_position_invalid
    cmp eax, 192000
    ja .Lex_position_invalid
    mov rcx, [rbx+64]
    lea rdx, [rsp+32]
    xor r8d, r8d
    mov rax, [rcx]
    call qword ptr [rax+32]
    test eax, eax
    js .Lex_position_return
    cmp eax, 1
    ja .Lex_position_unexpected
    mov rax, [rsp+32]
    mov ecx, [rbx+4]
    mul rcx
    mov rcx, [rbx+72]
    cmp rdx, rcx
    jae .Lex_position_unexpected
    div rcx
    mov [rsi], rax
    xor eax, eax
    jmp .Lex_position_return
.Lex_position_unexpected:
    mov eax, 0x8000ffff
    jmp .Lex_position_return
.Lex_position_invalid:
    mov eax, 0x80070057
.Lex_position_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN output_exclusive_position
