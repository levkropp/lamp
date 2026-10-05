# RFC8251 updates: Copyright (c) 2017 IETF Trust, Jean-Marc Valin, Koen Vos.
# Handwritten SSE2 CELT anti-collapse and energy denormalization.
# BSD RFC6716 bands.c/quant_bands.c algorithms, see THIRD_PARTY_NOTICES.
# Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation,
# Gregory Maxwell.
# No runtime libm/CRT; original double-precision exponent approximation.
.include "lamp.inc"
.include "opus_spectral_layout.inc"
RODATA
.include "opus_spectral_tables.inc"
os_ebands: .short 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 34, 40, 48, 60, 78, 100
os_one: .float 1.0
os_half: .float 0.5
os_eighth: .float -0.125
os_sqrt2: .float 1.41421356
os_min_exp: .float -150.0
os_max_exp: .float 128.0
os_log_limit: .float 100.0
os_band_cap: .float 32.0          #RFC8251 maximum log2 band amplitude
.text
# XMM0=float x, XMM0=float 2^x. Finite range [-150,128), else 0/inf/NaN.
# The double polynomial error is below float rounding precision. This is a
# numerical helper; public callers validate their finite energy inputs first.
FN op_celt_exp2
    ucomiss xmm0, xmm0
    jp .Los_exp_done
    comiss xmm0, dword ptr [rip + os_min_exp]
    jb .Los_exp_zero
    comiss xmm0, dword ptr [rip + os_max_exp]
    jae .Los_exp_inf
    cvtss2sd xmm0, xmm0
    cvttsd2si ecx, xmm0
    cvtsi2sd xmm1, ecx
    comisd xmm0, xmm1
    jae .Los_exp_fraction
    dec ecx
    cvtsi2sd xmm1, ecx
.Los_exp_fraction:
    subsd xmm0, xmm1
    lea rax, [rip + os_exp_coeff]
    movsd xmm2, qword ptr [rax + 18*8]
    mov edx, 17
.Los_exp_horner:
    mulsd xmm2, xmm0
    addsd xmm2, qword ptr [rax + rdx*8]
    dec edx
    jns .Los_exp_horner
    add ecx, 1023
    mov eax, ecx
    shl rax, 52
    movq xmm1, rax
    mulsd xmm2, xmm1
    cvtsd2ss xmm0, xmm2
.Los_exp_done:
    ret
.Los_exp_zero:
    xorps xmm0, xmm0
    ret
.Los_exp_inf:
    mov eax, 0x7f800000
    movd xmm0, eax
    ret
ENDFN op_celt_exp2

.equ SA_N0, 32
.equ SA_N, 36
.equ SA_THRESH, 40
.equ SA_SQRT, 44
.equ SA_R, 48
.equ SA_CHANNEL, 52
.equ SA_BLOCK, 56
.equ SA_CHANGED, 60
# RCX=88-byte request, EAX=1/0. Guards precede any coefficient mutation.
# Seed is passed by value, as in the normative algorithm; it is not advanced.
FN op_celt_anti_collapse
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov rbx, rcx
    test rbx, rbx
    jz .Los_anti_bad
    xor ecx, ecx
.Los_anti_pointers:
    cmp qword ptr [rbx + rcx*8], 0
    je .Los_anti_bad
    inc ecx
    cmp ecx, 6
    jb .Los_anti_pointers
    mov ecx, [rbx + OS_LM]
    cmp ecx, 3
    ja .Los_anti_bad
    mov r13d, 1
    shl r13d, cl
    imul eax, r13d, 120
    cmp [rbx + OS_SIZE], eax
    jne .Los_anti_bad
    mov edx, [rbx + OS_CHANNELS]
    cmp edx, 1
    jb .Los_anti_bad
    cmp edx, 2
    ja .Los_anti_bad
    imul eax, edx
    cmp [rbx + OS_X_CAP], eax
    jb .Los_anti_bad
    imul eax, edx, 21
    cmp [rbx + OS_MASK_CAP], eax
    jb .Los_anti_bad
    cmp dword ptr [rbx + OS_ENERGY_CAP], 42
    jb .Los_anti_bad
    cmp dword ptr [rbx + OS_PULSE_CAP], 21
    jb .Los_anti_bad
    mov r12d, [rbx + OS_START]
    cmp r12d, 20
    ja .Los_anti_bad
    mov eax, [rbx + OS_END]
    cmp eax, 21
    ja .Los_anti_bad
    cmp eax, r12d
    jle .Los_anti_bad
    # Validate all three histories (mono merges both channels' old histories).
    mov r8, [rbx + OS_ENERGY]
    mov r9, [rbx + OS_PREV1]
    mov r10, [rbx + OS_PREV2]
    xor ecx, ecx
.Los_anti_history_guard:
    mov eax, [r8 + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x43200000        # finite magnitude <=160
    ja .Los_anti_bad
    mov eax, [r9 + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x43200000
    ja .Los_anti_bad
    mov eax, [r10 + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x43200000
    ja .Los_anti_bad
    inc ecx
    cmp ecx, 42
    jb .Los_anti_history_guard
    mov edi, [rbx + OS_SEED]
    mov r14d, r12d
.Los_anti_band_guard:
    mov r8, [rbx + OS_PULSES]
    cmp dword ptr [r8 + r14*4], 81600
    ja .Los_anti_bad
    mov ecx, r13d
    mov r11d, 1
    shl r11d, cl
    dec r11d
    mov r8, [rbx + OS_MASKS]
    mov eax, r14d
    imul eax, [rbx + OS_CHANNELS]
    movzx ecx, byte ptr [r8 + rax]
    cmp ecx, r11d
    ja .Los_anti_bad
    cmp dword ptr [rbx + OS_CHANNELS], 2
    jne .Los_anti_x_guard
    movzx ecx, byte ptr [r8 + rax + 1]
    cmp ecx, r11d
    ja .Los_anti_bad
.Los_anti_x_guard:
    lea r8, [rip + os_ebands]
    movzx r9d, word ptr [r8 + r14*2]
    movzx r10d, word ptr [r8 + r14*2 + 2]
    imul r9d, r13d
    imul r10d, r13d
    xor edx, edx
.Los_anti_x_channel:
    mov r8, [rbx + OS_X]
    mov eax, edx
    imul eax, [rbx + OS_SIZE]
    lea r8, [r8 + rax*4]
    mov ecx, r9d
.Los_anti_x_samples:
    mov eax, [r8 + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x40000000        # normalized input magnitude <=2
    ja .Los_anti_bad
    inc ecx
    cmp ecx, r10d
    jb .Los_anti_x_samples
    inc edx
    cmp edx, [rbx + OS_CHANNELS]
    jb .Los_anti_x_channel
    inc r14d
    cmp r14d, [rbx + OS_END]
    jb .Los_anti_band_guard

.Los_anti_band:
    lea r8, [rip + os_ebands]
    movzx eax, word ptr [r8 + r12*2 + 2]
    movzx edx, word ptr [r8 + r12*2]
    sub eax, edx
    mov [rsp + SA_N0], eax
    imul eax, r13d
    mov [rsp + SA_N], eax
    cvtsi2ss xmm0, eax
    sqrtss xmm0, xmm0
    movss xmm1, dword ptr [rip + os_one]
    divss xmm1, xmm0
    movss dword ptr [rsp + SA_SQRT], xmm1
    mov r8, [rbx + OS_PULSES]
    mov eax, [r8 + r12*4]
    inc eax
    xor edx, edx
    div dword ptr [rsp + SA_N]
    cvtsi2ss xmm0, eax
    mulss xmm0, dword ptr [rip + os_eighth]
    call op_celt_exp2
    mulss xmm0, dword ptr [rip + os_half]
    movss dword ptr [rsp + SA_THRESH], xmm0
    mov dword ptr [rsp + SA_CHANNEL], 0
.Los_anti_channel:
    mov eax, [rsp + SA_CHANNEL]
    imul eax, 21
    add eax, r12d
    mov r8, [rbx + OS_PREV1]
    mov r9, [rbx + OS_PREV2]
    movss xmm0, dword ptr [r8 + rax*4]
    movss xmm1, dword ptr [r9 + rax*4]
    cmp dword ptr [rbx + OS_CHANNELS], 1
    jne .Los_anti_previous
    maxss xmm0, dword ptr [r8 + rax*4 + 84]
    maxss xmm1, dword ptr [r9 + rax*4 + 84]
.Los_anti_previous:
    minss xmm0, xmm1
    mov r8, [rbx + OS_ENERGY]
    movss xmm1, dword ptr [r8 + rax*4]
    subss xmm1, xmm0
    xorps xmm0, xmm0
    maxss xmm1, xmm0
    subss xmm0, xmm1
    call op_celt_exp2
    addss xmm0, xmm0
    cmp dword ptr [rbx + OS_LM], 3
    jne .Los_anti_radius
    mulss xmm0, dword ptr [rip + os_sqrt2]
.Los_anti_radius:
    minss xmm0, dword ptr [rsp + SA_THRESH]
    mulss xmm0, dword ptr [rsp + SA_SQRT]
    movss dword ptr [rsp + SA_R], xmm0
    lea r8, [rip + os_ebands]
    movzx eax, word ptr [r8 + r12*2]
    imul eax, r13d
    mov ecx, [rsp + SA_CHANNEL]
    imul ecx, [rbx + OS_SIZE]
    add eax, ecx
    mov rsi, [rbx + OS_X]
    lea rsi, [rsi + rax*4]
    mov eax, r12d
    imul eax, [rbx + OS_CHANNELS]
    add eax, [rsp + SA_CHANNEL]
    mov r8, [rbx + OS_MASKS]
    movzx r14d, byte ptr [r8 + rax]
    mov dword ptr [rsp + SA_CHANGED], 0
    xor r15d, r15d
.Los_anti_block:
    bt r14d, r15d
    jc .Los_anti_next_block
    mov dword ptr [rsp + SA_CHANGED], 1
    xor ecx, ecx
    mov edx, r15d
.Los_anti_noise:
    imul edi, edi, 1664525
    add edi, 1013904223
    mov eax, [rsp + SA_R]
    test edi, 0x8000
    jnz .Los_anti_noise_store
    xor eax, 0x80000000
.Los_anti_noise_store:
    mov [rsi + rdx*4], eax
    add edx, r13d
    inc ecx
    cmp ecx, [rsp + SA_N0]
    jb .Los_anti_noise
.Los_anti_next_block:
    inc r15d
    cmp r15d, r13d
    jb .Los_anti_block
    cmp dword ptr [rsp + SA_CHANGED], 0
    je .Los_anti_next_channel
    mov rcx, rsi
    mov edx, [rsp + SA_N]
    movss xmm2, dword ptr [rip + os_one]
    call op_celt_renormalize
    test eax, eax
    jz .Los_anti_bad
.Los_anti_next_channel:
    inc dword ptr [rsp + SA_CHANNEL]
    mov eax, [rsp + SA_CHANNEL]
    cmp eax, [rbx + OS_CHANNELS]
    jb .Los_anti_channel
    inc r12d
    cmp r12d, [rbx + OS_END]
    jb .Los_anti_band
    mov eax, 1
    jmp .Los_anti_done
.Los_anti_bad:
    xor eax, eax
.Los_anti_done:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_celt_anti_collapse

# RCX=72-byte request, EAX=1/0. Produces full planar frequency buffers,
# zeroing inactive bands, high-frequency padding and downsample stop bands.
FN op_celt_denormalize
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rbx, rcx
    test rbx, rbx
    jz .Los_denorm_bad
    xor ecx, ecx
.Los_denorm_pointers:
    cmp qword ptr [rbx + rcx*8], 0
    je .Los_denorm_bad
    inc ecx
    cmp ecx, 4
    jb .Los_denorm_pointers
    mov eax, [rbx + OD_CHANNELS]
    cmp eax, 1
    jb .Los_denorm_bad
    cmp eax, 2
    ja .Los_denorm_bad
    imul eax, 21
    cmp [rbx + OD_ENERGY_CAP], eax
    jb .Los_denorm_bad
    cmp [rbx + OD_GAIN_CAP], eax
    jb .Los_denorm_bad
    mov ecx, [rbx + OD_LM]
    cmp ecx, 3
    ja .Los_denorm_bad
    mov r13d, 1
    shl r13d, cl
    imul r14d, r13d, 120
    mov eax, r14d
    imul eax, [rbx + OD_CHANNELS]
    cmp [rbx + OD_X_CAP], eax
    jb .Los_denorm_bad
    cmp [rbx + OD_FREQ_CAP], eax
    jb .Los_denorm_bad
    mov r12d, [rbx + OD_START]
    cmp r12d, 20
    ja .Los_denorm_bad
    mov eax, [rbx + OD_END]
    cmp eax, 21
    ja .Los_denorm_bad
    cmp eax, r12d
    jle .Los_denorm_bad
    mov eax, [rbx + OD_DOWNSAMPLE]
    cmp eax, 1
    jb .Los_denorm_bad
    cmp eax, 4
    jbe .Los_denorm_rate
    cmp eax, 6
    jne .Los_denorm_bad
.Los_denorm_rate:
    xor edi, edi
.Los_denorm_guard_channel:
    mov r12d, [rbx + OD_START]
.Los_denorm_guard_band:
    mov eax, edi
    imul eax, 21
    add eax, r12d
    mov r8, [rbx + OD_ENERGY]
    mov edx, [r8 + rax*4]
    and edx, 0x7fffffff
    cmp edx, 0x43200000
    ja .Los_denorm_bad
    movss xmm0, dword ptr [r8 + rax*4]
    lea r8, [rip + os_means]
    addss xmm0, dword ptr [r8 + r12*4]
    comiss xmm0, dword ptr [rip + os_log_limit]
    ja .Los_denorm_bad
    lea r8, [rip + os_ebands]
    movzx ecx, word ptr [r8 + r12*2]
    movzx r9d, word ptr [r8 + r12*2 + 2]
    imul ecx, r13d
    imul r9d, r13d
    mov eax, edi
    imul eax, r14d
    mov r8, [rbx + OD_X]
    lea r8, [r8 + rax*4]
.Los_denorm_guard_samples:
    mov eax, [r8 + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x40000000
    ja .Los_denorm_bad
    inc ecx
    cmp ecx, r9d
    jb .Los_denorm_guard_samples
    inc r12d
    cmp r12d, [rbx + OD_END]
    jb .Los_denorm_guard_band
    inc edi
    cmp edi, [rbx + OD_CHANNELS]
    jb .Los_denorm_guard_channel
    # All public guards have passed. Clear output and gains, then active bands.
    mov rdi, [rbx + OD_FREQ]
    mov ecx, r14d
    imul ecx, [rbx + OD_CHANNELS]
    xor eax, eax
    rep stosd
    mov rdi, [rbx + OD_GAINS]
    mov ecx, [rbx + OD_CHANNELS]
    imul ecx, 21
    rep stosd
    xor r15d, r15d
.Los_denorm_channel:
    mov r12d, [rbx + OD_START]
.Los_denorm_band:
    mov eax, r15d
    imul eax, 21
    add eax, r12d
    mov rsi, [rbx + OD_ENERGY]
    movss xmm0, dword ptr [rsi + rax*4]
    lea rsi, [rip + os_means]
    addss xmm0, dword ptr [rsi + r12*4]
    minss xmm0, dword ptr [rip + os_band_cap]
    call op_celt_exp2
    movaps xmm3, xmm0
    mov eax, r15d
    imul eax, 21
    add eax, r12d
    mov rdi, [rbx + OD_GAINS]
    movss dword ptr [rdi + rax*4], xmm3
    lea r8, [rip + os_ebands]
    movzx ecx, word ptr [r8 + r12*2]
    movzx r9d, word ptr [r8 + r12*2 + 2]
    imul ecx, r13d
    imul r9d, r13d
    mov eax, r14d
    xor edx, edx
    div dword ptr [rbx + OD_DOWNSAMPLE]
    cmp r9d, eax
    cmovg r9d, eax
    mov eax, r15d
    imul eax, r14d
    mov rsi, [rbx + OD_X]
    lea rsi, [rsi + rax*4]
    mov rdi, [rbx + OD_FREQ]
    lea rdi, [rdi + rax*4]
.Los_denorm_scale:
    cmp ecx, r9d
    jae .Los_denorm_next
    movss xmm0, dword ptr [rsi + rcx*4]
    mulss xmm0, xmm3
    movss dword ptr [rdi + rcx*4], xmm0
    inc ecx
    jmp .Los_denorm_scale
.Los_denorm_next:
    inc r12d
    cmp r12d, [rbx + OD_END]
    jb .Los_denorm_band
    inc r15d
    cmp r15d, [rbx + OD_CHANNELS]
    jb .Los_denorm_channel
    mov eax, 1
    jmp .Los_denorm_done
.Los_denorm_bad:
    xor eax, eax
.Los_denorm_done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_celt_denormalize
