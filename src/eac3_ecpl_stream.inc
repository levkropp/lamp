# Enhanced-coupling bitstream parameters and decoder DSP integration.
# Syntax: ATSC A/52:2018 E.2.2.4, E.2.3.3.14-26. Numeric data is generated
# from the hash-pinned specification; the DSP is in eac3_ecpl.inc.
.data
eac3_ecpl_random_initialized: .long 0
RODATA
eac3_ecpl_random_scale: .float 4.656612873077392578125e-10 # 2^-31
.bss
.p2align 6
eac3_ecpl_random_static: .zero 8*256*4
eac3_ecpl_random_work: .zero 256*4
eac3_ecpl_carrier_work: .zero 256*16
.text

# Parse ecplbegf/endf/band structure after channel-selection bits. EAX=1/0.
LOCALFN eac3_ecpl_strategy
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov dword ptr [rip + ac3_phsinu], 0
    mov ecx, 4
    call ac3_get
    mov [rip + eac3_ecpl_begin], eax
    lea r12d, [rax*2]
    cmp eax, 3
    jb .Lecpl_strategy_begin
    lea r12d, [rax + 2]
    cmp eax, 13
    jb .Lecpl_strategy_begin
    lea r12d, [rax*2 - 10]
.Lecpl_strategy_begin:
    cmp dword ptr [rip + eac3_spx_active], 0
    jne .Lecpl_strategy_spx_end
    mov ecx, 4
    call ac3_get
    lea ebx, [rax + 7]
    jmp .Lecpl_strategy_range
.Lecpl_strategy_spx_end:
    # The SPX begin bin maps exactly to one ECPL subband boundary.
    lea rdx, [rip + eac3_ecpl_edges]
    xor ebx, ebx
    mov eax, [rip + eac3_spx_start]
.Lecpl_strategy_find_end:
    cmp ebx, 23
    jae .Lecpl_strategy_bad
    movzx ecx, word ptr [rdx + rbx*2]
    cmp eax, ecx
    je .Lecpl_strategy_range
    inc ebx
    jmp .Lecpl_strategy_find_end
.Lecpl_strategy_range:
    cmp r12d, ebx
    jae .Lecpl_strategy_bad
    lea rdx, [rip + eac3_ecpl_edges]
    movzx eax, word ptr [rdx + r12*2]
    mov [rip + ac3_start], eax
    movzx eax, word ptr [rdx + rbx*2]
    mov [rip + ac3_end], eax
    mov ecx, 1
    call ac3_get
    test eax, eax
    jz .Lecpl_strategy_sizes
    lea esi, [r12 + 1]
    cmp esi, 9
    jae .Lecpl_strategy_struct
    mov esi, 9
.Lecpl_strategy_struct:
    cmp esi, ebx
    jae .Lecpl_strategy_sizes
    mov ecx, 1
    call ac3_get
    lea rdx, [rip + eac3_ecpl_struct]
    mov [rdx + rsi], al
    inc esi
    jmp .Lecpl_strategy_struct
.Lecpl_strategy_sizes:
    lea r8, [rip + eac3_ecpl_edges]
    lea r9, [rip + eac3_ecpl_struct]
    lea r10, [rip + ac3_bndsz]
    lea r11, [rip + eac3_ecpl_coords + 8] # slot zero holds shared edges
    mov eax, [rip + ac3_start]
    mov [r11], eax
    xor edi, edi
    mov esi, r12d
.Lecpl_strategy_subband:
    cmp esi, ebx
    jae .Lecpl_strategy_count
    movzx eax, word ptr [r8 + rsi*2]
    movzx edx, word ptr [r8 + rsi*2 + 2]
    sub edx, eax
    cmp esi, r12d
    je .Lecpl_strategy_new_band
    cmp byte ptr [r9 + rsi], 0
    je .Lecpl_strategy_new_band
    add byte ptr [r10 + rdi - 1], dl
    jmp .Lecpl_strategy_edge
.Lecpl_strategy_new_band:
    mov [r10 + rdi], dl
    inc edi
.Lecpl_strategy_edge:
    movzx eax, word ptr [r8 + rsi*2 + 2]
    mov [r11 + rdi*4], eax
    inc esi
    jmp .Lecpl_strategy_subband
.Lecpl_strategy_count:
    mov [rip + ac3_ncplbnd], edi
    mov eax, 1
    jmp .Lecpl_strategy_return
.Lecpl_strategy_bad:
    xor eax, eax
.Lecpl_strategy_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN eac3_ecpl_strategy

# ECPL coordinate presence/reuse, first-channel rules, angles and transients.
LOCALFN eac3_ecpl_coordinates
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov ecx, 1
    call ac3_get
    shl eax, 2
    mov [rip + eac3_ecpl_interp], eax
    mov r12d, 1
    xor r13d, r13d                       # first selected channel
.Lecpl_coords_channel:
    cmp r12d, [rip + ac3_nf]
    ja .Lecpl_coords_done
    AC3_SLOT rax, ac3_incpl, r12
    cmp dword ptr [rax], 0
    je .Lecpl_coords_unused
    test r13d, r13d
    jnz .Lecpl_coords_presence
    mov r13d, r12d
.Lecpl_coords_presence:
    AC3_SLOT rax, eac3_first_coords, r12
    cmp dword ptr [rax], 0
    je .Lecpl_coords_read_presence
    mov dword ptr [rax], 0
    mov ebx, 1
    cmp r12d, r13d
    je .Lecpl_coords_descriptor
    or ebx, 2
    jmp .Lecpl_coords_descriptor
.Lecpl_coords_read_presence:
    mov ecx, 1
    call ac3_get
    mov ebx, eax
    cmp r12d, r13d
    je .Lecpl_coords_descriptor
    mov ecx, 1
    call ac3_get
    shl eax, 1
    or ebx, eax
.Lecpl_coords_descriptor:
    imul r14d, r12d, 168
    lea rax, [rip + eac3_ecpl_coords]
    add r14, rax
    mov edi, [rip + ac3_ncplbnd]
    mov [r14], edi
    mov eax, [rip + eac3_ecpl_interp]
    cmp r12d, r13d
    jne .Lecpl_coords_flags
    or eax, 1
.Lecpl_coords_flags:
    mov [r14 + 4], eax
    lea r8, [rip + eac3_ecpl_coords + 8]
    xor ecx, ecx
.Lecpl_coords_edges:
    mov eax, [r8 + rcx*4]
    mov [r14 + rcx*4 + 8], eax
    inc ecx
    cmp ecx, edi
    jbe .Lecpl_coords_edges
    test ebx, 1
    jz .Lecpl_coords_phase
    xor r15d, r15d
.Lecpl_coords_amplitude:
    cmp r15d, edi
    jae .Lecpl_coords_phase
    mov ecx, 5
    call ac3_get
    mov [r14 + r15 + 100], al
    inc r15d
    jmp .Lecpl_coords_amplitude
.Lecpl_coords_phase:
    test ebx, 2
    jz .Lecpl_coords_transient
    xor r15d, r15d
.Lecpl_coords_angle:
    cmp r15d, edi
    jae .Lecpl_coords_transient
    mov ecx, 6
    call ac3_get
    mov [r14 + r15 + 122], al
    mov ecx, 3
    call ac3_get
    mov [r14 + r15 + 144], al
    inc r15d
    jmp .Lecpl_coords_angle
.Lecpl_coords_transient:
    cmp r12d, r13d
    je .Lecpl_coords_next
    mov ecx, 1
    call ac3_get
    shl eax, 1
    or [r14 + 4], eax
    jmp .Lecpl_coords_next
.Lecpl_coords_unused:
    AC3_SLOT rax, eac3_first_coords, r12
    mov dword ptr [rax], 1
.Lecpl_coords_next:
    inc r12d
    jmp .Lecpl_coords_channel
.Lecpl_coords_done:
    mov eax, 1
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN eac3_ecpl_coordinates

# A separate non-normative xorshift32 sequence. Fixed per-channel/bin values
# are initialized once for the process, never on a stream/seek reset.
LOCALFN eac3_ecpl_random_init
    cmp dword ptr [rip + eac3_ecpl_random_initialized], 0
    jne .Lecpl_random_init_done
    mov eax, 0x6d2b79f5
    lea r8, [rip + eac3_ecpl_random_static]
    xor ecx, ecx
.Lecpl_random_init_word:
    mov edx, eax
    shl edx, 13
    xor eax, edx
    mov edx, eax
    shr edx, 17
    xor eax, edx
    mov edx, eax
    shl edx, 5
    xor eax, edx
    cvtsi2ss xmm0, eax
    mulss xmm0, [rip + eac3_ecpl_random_scale]
    movss [r8 + rcx*4], xmm0
    inc ecx
    cmp ecx, 8*256
    jb .Lecpl_random_init_word
    mov dword ptr [rip + eac3_ecpl_random_initialized], 1
.Lecpl_random_init_done:
    ret
ENDFN eac3_ecpl_random_init

# ECX=channel: replace only its ECPL slice in ac3_coef, then apply channel
# DRC. Base spectra already include the shared 2^-22 fixed-to-float scale.
LOCALFN eac3_ecpl_apply
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov ebx, ecx
    imul esi, ebx, 168
    lea rax, [rip + eac3_ecpl_coords]
    add rsi, rax
    mov eax, ebx
    shl eax, 10
    lea r9, [rip + eac3_ecpl_random_static]
    add r9, rax
    test dword ptr [rsi + 4], 2
    jz .Lecpl_apply_channel
    lea r9, [rip + eac3_ecpl_random_work]
    mov eax, [rip + eac3_ecpl_trans_seed]
    xor edi, edi
.Lecpl_apply_trans_band:
    mov edx, eax
    shl edx, 13
    xor eax, edx
    mov edx, eax
    shr edx, 17
    xor eax, edx
    mov edx, eax
    shl edx, 5
    xor eax, edx
    cvtsi2ss xmm0, eax
    mulss xmm0, [rip + eac3_ecpl_random_scale]
    mov ecx, [rsi + rdi*4 + 8]
    mov edx, [rsi + rdi*4 + 12]
.Lecpl_apply_trans_bin:
    movss [r9 + rcx*4], xmm0
    inc ecx
    cmp ecx, edx
    jb .Lecpl_apply_trans_bin
    inc edi
    cmp edi, [rsi]
    jb .Lecpl_apply_trans_band
    mov [rip + eac3_ecpl_trans_seed], eax
.Lecpl_apply_channel:
    lea rcx, [rip + eac3_ecpl_carrier_work]
    mov rdx, rsi
    lea r8, [rip + ac3_coef]
    call eac3_ecpl_channel
    test eax, eax
    jz .Lecpl_apply_bad
    movss xmm1, [rip + ac3_dyn]           # ECPL only in acmod 2..7
    lea rdx, [rip + ac3_coef]
    mov ecx, [rip + ac3_start]
.Lecpl_apply_gain:
    movss xmm0, [rdx + rcx*4]
    mulss xmm0, xmm1
    movss [rdx + rcx*4], xmm0
    inc ecx
    cmp ecx, [rip + ac3_end]
    jb .Lecpl_apply_gain
    jmp .Lecpl_apply_done
.Lecpl_apply_bad:
    mov dword ptr [rip + decode_error], AC3_MALFORMED
.Lecpl_apply_done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN eac3_ecpl_apply
