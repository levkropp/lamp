# SILK stereo predictor entropy and adaptive mid/side reconstruction.
# RFC6716 stereo_decode_pred.c/stereo_MS_to_LR.c, Copyright(c)2006-2012
# IETF Trust/Skype Limited. BSD conditions in THIRD_PARTY_NOTICES.
.include "lamp.inc"
.include "opus_silk_stereo_layout.inc"
RODATA
.include "opus_silk_stereo_tables.inc"
.text
FN op_silk_stereo_indices
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rbx, rcx
    test rbx, rbx
    jz .Lst_bad
    mov rsi, [rbx + ST_EC]
    mov rdi, [rbx + ST_OUT]
    test rsi, rsi
    jz .Lst_bad
    test rdi, rdi
    jz .Lst_bad
    cmp dword ptr [rbx + ST_KIND], 1
    ja .Lst_bad
    mov eax, 2
    sub eax, [rbx + ST_KIND]
    cmp [rbx + ST_OUT_CAP], eax
    jb .Lst_bad
    cmp dword ptr [rbx + ST_EC_CAP], 64
    jb .Lst_bad
    cmp qword ptr [rsi], 0
    je .Lst_bad
    cmp dword ptr [rsi + 8], 1275
    ja .Lst_bad
    mov eax, [rsi + 8]
    cmp [rsi + 12], eax
    ja .Lst_bad
    cmp [rsi + 28], eax
    ja .Lst_bad
    cmp dword ptr [rsi + 32], 0x800000
    jbe .Lst_bad
    cmp dword ptr [rsi + 32], 0x80000000
    ja .Lst_bad
    mov eax, [rsi + 32]
    cmp [rsi + 36], eax
    jae .Lst_bad
    cmp dword ptr [rsi + 20], 32
    ja .Lst_bad
    cmp dword ptr [rsi + 24], 32768
    ja .Lst_bad
    cmp dword ptr [rbx + ST_KIND], 0
    je .Lst_predictors
    mov rcx, rsi
    lea rdx, [rip + st_mid]
    mov r8d, 8
    call op_ec_icdf
    mov [rdi], eax
    jmp .Lst_good
.Lst_predictors:
    mov rcx, rsi
    lea rdx, [rip + st_joint]
    mov r8d, 8
    call op_ec_icdf
    xor edx, edx
    mov ecx, 5
    div ecx
    lea r12d, [rax + rax*2]
    lea r13d, [rdx + rdx*2]
    mov rcx, rsi
    lea rdx, [rip + st_uniform3]
    mov r8d, 8
    call op_ec_icdf
    add r12d, eax
    mov rcx, rsi
    lea rdx, [rip + st_uniform5]
    mov r8d, 8
    call op_ec_icdf
    mov ecx, eax
    lea r8, [rip + st_quant]
    movsx edx, word ptr [r8 + r12*2]
    movsx eax, word ptr [r8 + r12*2 + 2]
    sub eax, edx
    imul eax, 6554                #round(.1*65536)
    sar eax, 16
    lea ecx, [rcx + rcx + 1]
    imul eax, ecx
    add eax, edx
    mov r12d, eax
    mov rcx, rsi
    lea rdx, [rip + st_uniform3]
    mov r8d, 8
    call op_ec_icdf
    add r13d, eax
    mov rcx, rsi
    lea rdx, [rip + st_uniform5]
    mov r8d, 8
    call op_ec_icdf
    mov ecx, eax
    lea r8, [rip + st_quant]
    movsx edx, word ptr [r8 + r13*2]
    movsx eax, word ptr [r8 + r13*2 + 2]
    sub eax, edx
    imul eax, 6554
    sar eax, 16
    lea ecx, [rcx + rcx + 1]
    imul eax, ecx
    add eax, edx
    mov [rdi + 4], eax
    sub r12d, eax
    mov [rdi], r12d
.Lst_good:
    mov eax, 1
    jmp .Lst_done
.Lst_bad:
    xor eax, eax
.Lst_done:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_stereo_indices
FN op_silk_stereo
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov rbx, rcx
    test rbx, rbx
    jz .Lsm_bad
    mov rsi, [rbx + SM_MID]
    mov rdi, [rbx + SM_SIDE]
    mov r12, [rbx + SM_STATE]
    mov r13, [rbx + SM_PRED]
    test rsi, rsi
    jz .Lsm_bad
    test rdi, rdi
    jz .Lsm_bad
    test r12, r12
    jz .Lsm_bad
    test r13, r13
    jz .Lsm_bad
    cmp dword ptr [rbx + SM_STATE_CAP], 12
    jb .Lsm_bad
    cmp dword ptr [rbx + SM_PRED_CAP], 2
    jb .Lsm_bad
    mov eax, [rbx + SM_FS]
    cmp eax, 8
    je .Lsm_rate
    cmp eax, 12
    je .Lsm_rate
    cmp eax, 16
    jne .Lsm_bad
.Lsm_rate:
    lea r15d, [rax*8]             #interpolation length
    imul ecx, eax, 10
    mov r14d, [rbx + SM_N]
    cmp r14d, ecx
    je .Lsm_length
    add ecx, ecx
    cmp r14d, ecx
    jne .Lsm_bad
.Lsm_length:
    lea ecx, [r14 + 2]
    cmp [rbx + SM_MID_CAP], ecx
    jb .Lsm_bad
    cmp [rbx + SM_SIDE_CAP], ecx
    jb .Lsm_bad
    cmp dword ptr [r13], -32768
    jl .Lsm_bad
    cmp dword ptr [r13], 32767
    jg .Lsm_bad
    cmp dword ptr [r13 + 4], -32768
    jl .Lsm_bad
    cmp dword ptr [r13 + 4], 32767
    jg .Lsm_bad
    mov eax, [r12 + SN_MID]
    mov [rsi], eax
    mov eax, [r12 + SN_SIDE]
    mov [rdi], eax
    mov eax, [rsi + r14*2]
    mov [r12 + SN_MID], eax
    mov eax, [rdi + r14*2]
    mov [r12 + SN_SIDE], eax
    mov eax, 65536
    xor edx, edx
    div r15d
    movsx r10d, word ptr [r12 + SN_PRED]
    movsx r11d, word ptr [r12 + SN_PRED + 2]
    mov ecx, [r13]
    sub ecx, r10d
    movsx ecx, cx
    imul ecx, eax
    sar ecx, 15
    inc ecx
    sar ecx, 1
    mov [rsp], ecx
    mov ecx, [r13 + 4]
    sub ecx, r11d
    movsx ecx, cx
    imul ecx, eax
    sar ecx, 15
    inc ecx
    sar ecx, 1
    mov [rsp + 4], ecx
    xor r8d, r8d
.Lsm_side_sample:
    cmp r8d, r15d
    jae .Lsm_target_predictors
    add r10d, [rsp]
    add r11d, [rsp + 4]
    jmp .Lsm_predict
.Lsm_target_predictors:
    mov r10d, [r13]
    mov r11d, [r13 + 4]
.Lsm_predict:
    movsx eax, word ptr [rsi + r8*2]
    movsx edx, word ptr [rsi + r8*2 + 4]
    add eax, edx
    movsx edx, word ptr [rsi + r8*2 + 2]
    lea eax, [rax + rdx*2]
    shl eax, 9
    movsxd rax, eax
    movsx rcx, r10w
    imul rax, rcx
    sar rax, 16
    mov r9d, eax
    movsx edx, word ptr [rdi + r8*2 + 2]
    shl edx, 8
    add r9d, edx
    movsx eax, word ptr [rsi + r8*2 + 2]
    shl eax, 11
    movsxd rax, eax
    movsx rcx, r11w
    imul rax, rcx
    sar rax, 16
    add eax, r9d
    sar eax, 7
    inc eax
    sar eax, 1
    mov edx, 32767
    cmp eax, edx
    cmovg eax, edx
    mov edx, -32768
    cmp eax, edx
    cmovl eax, edx
    mov [rdi + r8*2 + 2], ax
    inc r8d
    cmp r8d, r14d
    jb .Lsm_side_sample
    mov eax, [r13]
    mov [r12 + SN_PRED], ax
    mov eax, [r13 + 4]
    mov [r12 + SN_PRED + 2], ax
    xor r8d, r8d
.Lsm_left_right:
    movsx eax, word ptr [rsi + r8*2 + 2]
    movsx edx, word ptr [rdi + r8*2 + 2]
    mov ecx, eax
    add eax, edx
    sub ecx, edx
    mov edx, 32767
    cmp eax, edx
    cmovg eax, edx
    cmp ecx, edx
    cmovg ecx, edx
    mov edx, -32768
    cmp eax, edx
    cmovl eax, edx
    cmp ecx, edx
    cmovl ecx, edx
    mov [rsi + r8*2 + 2], ax
    mov [rdi + r8*2 + 2], cx
    inc r8d
    cmp r8d, r14d
    jb .Lsm_left_right
    mov eax, 1
    jmp .Lsm_done
.Lsm_bad:
    xor eax, eax
.Lsm_done:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_stereo
