# Handwritten SILK comfort-noise estimation and synthesis, RFC6716 CNG.c.
# Copyright(c)2006-2012 IETF Trust and Skype Limited. BSD conditions in
# THIRD_PARTY_NOTICES. Caller-owned state/scratch; no CRT or heap.
.include "lamp.inc"
.include "opus_silk_cng_layout.inc"
.include "opus_silk_synthesis_layout.inc"
.include "opus_silk_state_layout.inc"
.include "opus_silk_lpc_layout.inc"
.text
FN op_silk_cng
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
    jz .Lcg_bad
    mov rsi, [rbx + CG_STATE]
    mov r15, [rbx + CG_CORE]
    mov rdi, [rbx + CG_PCM]
    mov r12, [rbx + CG_WORK]
    test rsi, rsi
    jz .Lcg_bad
    test r15, r15
    jz .Lcg_bad
    test rdi, rdi
    jz .Lcg_bad
    test r12, r12
    jz .Lcg_bad
    cmp qword ptr [rbx + CG_PARAM], 0
    je .Lcg_bad
    cmp qword ptr [rbx + CG_CTRL], 0
    je .Lcg_bad
    cmp dword ptr [rbx + CG_STATE_CAP], CN_SIZE
    jb .Lcg_bad
    cmp dword ptr [rbx + CG_CORE_CAP], CS_SIZE
    jb .Lcg_bad
    cmp dword ptr [rbx + CG_PARAM_CAP], DS_SIZE
    jb .Lcg_bad
    cmp dword ptr [rbx + CG_CTRL_CAP], DC_SIZE
    jb .Lcg_bad
    cmp dword ptr [rbx + CG_WORK_CAP], CW_SIZE
    jb .Lcg_bad
    mov eax, [rbx + CG_FS]
    mov r13d, 10
    cmp eax, 8
    je .Lcg_rate
    cmp eax, 12
    je .Lcg_rate
    cmp eax, 16
    jne .Lcg_bad
    mov r13d, 16
.Lcg_rate:
    mov ecx, [rbx + CG_SUBFR]
    cmp ecx, 2
    je .Lcg_subfr
    cmp ecx, 4
    jne .Lcg_bad
.Lcg_subfr:
    imul eax, ecx
    imul eax, 5
    mov r14d, [rbx + CG_N]
    cmp r14d, 1
    jl .Lcg_bad
    cmp r14d, eax
    ja .Lcg_bad
    cmp [rbx + CG_PCM_CAP], r14d
    jb .Lcg_bad
    cmp dword ptr [r15 + CS_LOSS], 0
    jl .Lcg_bad
    cmp dword ptr [r15 + CS_SIGNAL], 2
    ja .Lcg_bad
    mov eax, [rbx + CG_FS]
    cmp eax, [rsi + CN_FS]
    jne .Lcg_input_guard
    cmp dword ptr [rsi + CN_GAIN], 0
    jl .Lcg_bad
    xor ecx, ecx
.Lcg_history_guard:
    cmp word ptr [rsi + rcx*2 + CN_NLSF], 32767
    ja .Lcg_bad
    inc ecx
    cmp ecx, r13d
    jb .Lcg_history_guard
.Lcg_input_guard:
    cmp dword ptr [r15 + CS_LOSS], 0
    jne .Lcg_reset_check
    cmp dword ptr [r15 + CS_SIGNAL], 0
    jne .Lcg_reset_check
    mov r8, [rbx + CG_PARAM]
    xor ecx, ecx
.Lcg_nlsf_guard:
    cmp word ptr [r8 + rcx*2 + DS_PREV], 32767
    ja .Lcg_bad
    inc ecx
    cmp ecx, r13d
    jb .Lcg_nlsf_guard
    mov r8, [rbx + CG_CTRL]
    xor ecx, ecx
.Lcg_gain_guard:
    cmp dword ptr [r8 + rcx*4 + DC_GAINS], 0
    jle .Lcg_bad
    inc ecx
    cmp ecx, [rbx + CG_SUBFR]
    jb .Lcg_gain_guard
.Lcg_reset_check:
    mov eax, [rbx + CG_FS]
    cmp eax, [rsi + CN_FS]
    je .Lcg_update_check
    mov [rsi + CN_FS], eax
    mov eax, 32767
    lea ecx, [r13 + 1]
    xor edx, edx
    div ecx
    mov r8d, eax               #uniform NLSF step
    xor ecx, ecx
    xor eax, eax
.Lcg_reset_nlsf:
    add eax, r8d
    mov [rsi + rcx*2 + CN_NLSF], ax
    inc ecx
    cmp ecx, r13d
    jb .Lcg_reset_nlsf
    mov dword ptr [rsi + CN_GAIN], 0
    mov dword ptr [rsi + CN_RNG], 3176576
.Lcg_update_check:
    cmp dword ptr [r15 + CS_LOSS], 0
    jne .Lcg_synthesis
    cmp dword ptr [r15 + CS_SIGNAL], 0
    jne .Lcg_clear_synthesis
    mov r8, [rbx + CG_PARAM]
    xor ecx, ecx
.Lcg_smooth_nlsf:
    movsx eax, word ptr [r8 + rcx*2 + DS_PREV]
    movsx edx, word ptr [rsi + rcx*2 + CN_NLSF]
    sub eax, edx
    imul eax, 16348
    sar eax, 16
    add eax, edx
    mov [rsi + rcx*2 + CN_NLSF], ax
    inc ecx
    cmp ecx, r13d
    jb .Lcg_smooth_nlsf
    mov r8, [rbx + CG_CTRL]
    xor ecx, ecx
    xor edx, edx               #highest gain
    xor r9d, r9d               #chosen subframe
.Lcg_choose_subframe:
    mov eax, [r8 + rcx*4 + DC_GAINS]
    cmp eax, edx
    jle .Lcg_choose_next
    mov edx, eax
    mov r9d, ecx
.Lcg_choose_next:
    inc ecx
    cmp ecx, [rbx + CG_SUBFR]
    jb .Lcg_choose_subframe
    imul r10d, dword ptr [rbx + CG_FS], 5
    mov ecx, [rbx + CG_SUBFR]
    dec ecx
    imul ecx, r10d
    # Backward memmove of excitation history by one subframe.
.Lcg_move_excitation:
    dec ecx
    mov eax, [rsi + rcx*4 + CN_EXC]
    lea edx, [rcx + r10]
    mov [rsi + rdx*4 + CN_EXC], eax
    test ecx, ecx
    jnz .Lcg_move_excitation
    imul r9d, r10d
    lea r9, [r15 + r9*4 + CS_EXC]
    xor ecx, ecx
.Lcg_copy_excitation:
    mov eax, [r9 + rcx*4]
    mov [rsi + rcx*4 + CN_EXC], eax
    inc ecx
    cmp ecx, r10d
    jb .Lcg_copy_excitation
    xor ecx, ecx
.Lcg_smooth_gain:
    mov eax, [r8 + rcx*4 + DC_GAINS]
    sub eax, [rsi + CN_GAIN]
    movsxd rax, eax
    imul rax, 4634
    sar rax, 16
    add [rsi + CN_GAIN], eax
    inc ecx
    cmp ecx, [rbx + CG_SUBFR]
    jb .Lcg_smooth_gain
.Lcg_clear_synthesis:
    xor ecx, ecx
.Lcg_clear_history:
    mov dword ptr [rsi + rcx*4 + CN_SYN], 0
    inc ecx
    cmp ecx, r13d
    jb .Lcg_clear_history
    jmp .Lcg_good
.Lcg_synthesis:
    mov r8d, 255
.Lcg_noise_mask:
    cmp r8d, r14d
    jle .Lcg_noise_start
    shr r8d, 1
    jmp .Lcg_noise_mask
.Lcg_noise_start:
    mov ecx, [rsi + CN_RNG]
    mov r10d, [rsi + CN_GAIN]
    sar r10d, 4
    xor r9d, r9d
.Lcg_noise_sample:
    imul ecx, ecx, 196314165
    add ecx, 907633515
    mov eax, ecx
    sar eax, 24
    and eax, r8d
    movsxd rax, dword ptr [rsi + rax*4 + CN_EXC]
    imul rax, r10
    sar rax, 16
    mov edx, 32767
    cmp eax, edx
    cmovg eax, edx
    mov edx, -32768
    cmp eax, edx
    cmovl eax, edx
    mov [r12 + r9*4 + CW_SIG + 64], eax
    inc r9d
    cmp r9d, r14d
    jb .Lcg_noise_sample
    mov [rsi + CN_RNG], ecx
    lea rax, [rsi + CN_NLSF]
    mov [rsp + 32 + SA_NLSF], rax
    lea rax, [r12 + CW_COEF]
    mov [rsp + 32 + SA_OUT], rax
    mov [rsp + 32 + SA_ORDER], r13d
    mov [rsp + 32 + SA_IN_CAP], r13d
    mov [rsp + 32 + SA_OUT_CAP], r13d
    lea rcx, [rsp + 32]
    call op_silk_nlsf2a
    xor ecx, ecx
.Lcg_copy_synthesis:
    mov eax, [rsi + rcx*4 + CN_SYN]
    mov [r12 + rcx*4 + CW_SIG], eax
    inc ecx
    cmp ecx, 16
    jb .Lcg_copy_synthesis
    xor r8d, r8d
.Lcg_filter_sample:
    mov r11d, r13d
    shr r11d, 1
    xor ecx, ecx
.Lcg_filter_tap:
    lea edx, [r8 + 15]
    sub edx, ecx
    movsxd rax, dword ptr [r12 + rdx*4 + CW_SIG]
    movsx rdx, word ptr [r12 + rcx*2 + CW_COEF]
    imul rax, rdx
    sar rax, 16
    add r11d, eax
    inc ecx
    cmp ecx, r13d
    jb .Lcg_filter_tap
    mov eax, r11d
    shl eax, 4
    add [r12 + r8*4 + CW_SIG + 64], eax
    mov eax, r11d
    sar eax, 5
    inc eax
    sar eax, 1
    movsx edx, word ptr [rdi + r8*2]
    add eax, edx
    mov edx, 32767
    cmp eax, edx
    cmovg eax, edx
    mov edx, -32768
    cmp eax, edx
    cmovl eax, edx
    mov [rdi + r8*2], ax
    inc r8d
    cmp r8d, r14d
    jb .Lcg_filter_sample
    xor ecx, ecx
    mov r8d, r14d
.Lcg_save_synthesis:
    mov eax, [r12 + r8*4 + CW_SIG]
    mov [rsi + rcx*4 + CN_SYN], eax
    inc r8d
    inc ecx
    cmp ecx, 16
    jb .Lcg_save_synthesis
.Lcg_good:
    mov eax, 1
    jmp .Lcg_done
.Lcg_bad:
    xor eax, eax
.Lcg_done:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_cng
