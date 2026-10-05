# RFC8251 updates: Copyright (c) 2017 IETF Trust, Jean-Marc Valin, Koen Vos.
# Handwritten SILK predictive NLSF residual reconstruction and stabilization.
# RFC6716 NLSF_decode.c,NLSF_stabilize.c,NLSF_VQ_weights_laroia.c,Inlines.h.
# Copyright(c)2006-2012 IETF Trust and Skype Limited. BSD conditions in
# THIRD_PARTY_NOTICES. No CRT/heap/C runtime; bounded caller-owned scratch.
.include "lamp.inc"
.include "opus_silk_nlsf_layout.inc"
.include "opus_silk_indices_layout.inc"
RODATA
.include "opus_silk_nlsf_tables.inc"
.text
# ECX=int32. Normative integer approximation over the full signed range.
FN op_silk_sqrt_approx
    test ecx, ecx
    jle .Lsn_sqrt_zero
    mov edx, ecx
    bsr eax, ecx
    mov r8d, 31
    sub r8d, eax
    mov ecx, 24
    sub ecx, r8d
    ror edx, cl
    and edx, 127
    mov eax, 46214
    test r8d, 1
    jz .Lsn_sqrt_scale
    mov eax, 32768
.Lsn_sqrt_scale:
    mov ecx, r8d
    sar ecx, 1
    sar eax, cl
    imul edx, edx, 213
    imul edx, eax
    sar edx, 16
    add eax, edx
    ret
.Lsn_sqrt_zero:
    xor eax, eax
    ret
ENDFN op_silk_sqrt_approx

FN op_silk_nlsf_stabilize
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov rbx, rcx
    test rbx, rbx
    jz .Lns_bad
    mov rsi, [rbx + NS_OUT]
    test rsi, rsi
    jz .Lns_bad
    mov eax, [rbx + NS_FS]
    mov r12d, 10
    lea rdi, [rip + sn_delta_nb]
    cmp eax, 8
    je .Lns_rate
    cmp eax, 12
    je .Lns_rate
    cmp eax, 16
    jne .Lns_bad
    mov r12d, 16
    lea rdi, [rip + sn_delta_wb]
.Lns_rate:
    cmp [rbx + NS_CAP], r12d
    jb .Lns_bad
    xor r13d, r13d
.Lns_iteration:
    movsx r14d, word ptr [rsi]
    movzx eax, word ptr [rdi]
    sub r14d, eax               # minimum difference
    xor r15d, r15d              # I
    mov ecx, 1
.Lns_min_middle:
    movsx eax, word ptr [rsi + rcx*2]
    movsx edx, word ptr [rsi + rcx*2 - 2]
    sub eax, edx
    movzx edx, word ptr [rdi + rcx*2]
    sub eax, edx
    cmp eax, r14d
    jge .Lns_min_next
    mov r14d, eax
    mov r15d, ecx
.Lns_min_next:
    inc ecx
    cmp ecx, r12d
    jb .Lns_min_middle
    movsx eax, word ptr [rsi + r12*2 - 2]
    movzx edx, word ptr [rdi + r12*2]
    add eax, edx
    mov edx, 32768
    sub edx, eax
    cmp edx, r14d
    jge .Lns_check_min
    mov r14d, edx
    mov r15d, r12d
.Lns_check_min:
    test r14d, r14d
    jns .Lns_good
    test r15d, r15d
    jz .Lns_low_boundary
    cmp r15d, r12d
    je .Lns_high_boundary
    xor r8d, r8d               # min center
    xor ecx, ecx
.Lns_min_center:
    movzx eax, word ptr [rdi + rcx*2]
    add r8d, eax
    inc ecx
    cmp ecx, r15d
    jb .Lns_min_center
    movzx r10d, word ptr [rdi + r15*2]
    shr r10d, 1
    add r8d, r10d
    mov r9d, 32768
    mov ecx, r12d
.Lns_max_center:
    movzx eax, word ptr [rdi + rcx*2]
    sub r9d, eax
    dec ecx
    cmp ecx, r15d
    ja .Lns_max_center
    sub r9d, r10d
    movsx eax, word ptr [rsi + r15*2 - 2]
    movsx edx, word ptr [rsi + r15*2]
    add eax, edx
    mov edx, eax
    and edx, 1
    sar eax, 1
    add eax, edx                # normative rounded half
    cmp eax, r8d
    cmovl eax, r8d
    cmp eax, r9d
    cmovg eax, r9d
    sub eax, r10d
    mov [rsi + r15*2 - 2], ax
    movzx edx, word ptr [rdi + r15*2]
    add eax, edx
    mov [rsi + r15*2], ax
    jmp .Lns_next_iteration
.Lns_low_boundary:
    mov ax, [rdi]
    mov [rsi], ax
    jmp .Lns_next_iteration
.Lns_high_boundary:
    movzx eax, word ptr [rdi + r12*2]
    neg eax
    add eax, 32768
    mov [rsi + r12*2 - 2], ax
.Lns_next_iteration:
    inc r13d
    cmp r13d, 20
    jb .Lns_iteration
    # Normative 20-iteration fallback: signed insertion sort and spacing.
    mov r8d, 1
.Lns_sort_value:
    movsx r9d, word ptr [rsi + r8*2]
    lea ecx, [r8 - 1]
.Lns_sort_shift:
    movsx eax, word ptr [rsi + rcx*2]
    cmp r9d, eax
    jge .Lns_sort_store
    mov [rsi + rcx*2 + 2], ax
    dec ecx
    jns .Lns_sort_shift
.Lns_sort_store:
    movsxd rcx, ecx
    mov [rsi + rcx*2 + 2], r9w
    inc r8d
    cmp r8d, r12d
    jb .Lns_sort_value
    movsx eax, word ptr [rsi]
    movzx edx, word ptr [rdi]
    cmp eax, edx
    cmovl eax, edx
    mov [rsi], ax
    mov ecx, 1
.Lns_forward_space:
    movsx eax, word ptr [rsi + rcx*2 - 2]
    movzx edx, word ptr [rdi + rcx*2]
    add edx, eax
    mov eax, 32767             #RFC8251 saturating signed-16 spacing sum
    cmp edx, eax
    cmovg edx, eax
    mov eax, -32768
    cmp edx, eax
    cmovl edx, eax
    movsx eax, word ptr [rsi + rcx*2]
    cmp eax, edx
    cmovl eax, edx
    mov [rsi + rcx*2], ax
    inc ecx
    cmp ecx, r12d
    jb .Lns_forward_space
    movsx eax, word ptr [rsi + r12*2 - 2]
    movzx edx, word ptr [rdi + r12*2]
    neg edx
    add edx, 32768
    cmp eax, edx
    cmovg eax, edx
    mov [rsi + r12*2 - 2], ax
    lea ecx, [r12 - 2]
.Lns_backward_space:
    movsx edx, word ptr [rsi + rcx*2 + 2]
    movzx eax, word ptr [rdi + rcx*2 + 2]
    sub edx, eax
    movsx eax, word ptr [rsi + rcx*2]
    cmp eax, edx
    cmovg eax, edx
    mov [rsi + rcx*2], ax
    dec ecx
    jns .Lns_backward_space
.Lns_good:
    # Refuse invalid spacing/range before LPC conversion.
    xor ecx, ecx
    xor edx, edx
.Lns_output_guard:
    movsx eax, word ptr [rsi + rcx*2]
    mov r8d, eax
    sub eax, edx
    movzx r9d, word ptr [rdi + rcx*2]
    cmp eax, r9d
    jl .Lns_bad
    mov edx, r8d
    inc ecx
    cmp ecx, r12d
    jb .Lns_output_guard
    mov eax, 32768
    sub eax, edx
    movzx edx, word ptr [rdi + r12*2]
    cmp eax, edx
    jl .Lns_bad
    mov eax, 1
    jmp .Lns_done
.Lns_bad:
    xor eax, eax
.Lns_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_nlsf_stabilize

FN op_silk_nlsf_decode
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
    jz .Lsn_bad
    mov rsi, [rbx + SN_IND]
    mov rdi, [rbx + SN_OUT]
    mov r12, [rbx + SN_WORK]
    test rsi, rsi
    jz .Lsn_bad
    test rdi, rdi
    jz .Lsn_bad
    test r12, r12
    jz .Lsn_bad
    cmp dword ptr [rbx + SN_WORK_CAP], NW_SIZE
    jb .Lsn_bad
    mov eax, [rbx + SN_FS]
    mov r13d, 10
    lea r14, [rip + sn_cb_nb]
    mov r15d, sn_step_nb
    cmp eax, 8
    je .Lsn_rate
    cmp eax, 12
    je .Lsn_rate
    cmp eax, 16
    jne .Lsn_bad
    mov r13d, 16
    lea r14, [rip + sn_cb_wb]
    mov r15d, sn_step_wb
.Lsn_rate:
    cmp [rbx + SN_OUT_CAP], r13d
    jb .Lsn_bad
    lea eax, [r13 + 1]
    cmp [rbx + SN_IND_CAP], eax
    jb .Lsn_bad
    movzx eax, byte ptr [rsi]
    cmp eax, 31
    ja .Lsn_bad
    imul eax, r13d
    add r14, rax
    mov ecx, 1
.Lsn_residual_guard:
    movsx eax, byte ptr [rsi + rcx]
    cmp eax, -10
    jl .Lsn_bad
    cmp eax, 10
    jg .Lsn_bad
    inc ecx
    cmp ecx, r13d
    jbe .Lsn_residual_guard
    mov [rsp + 32 + SU_EC_IX], r12
    lea rax, [r12 + NW_PRED]
    mov [rsp + 32 + SU_PRED], rax
    mov eax, [rbx + SN_FS]
    mov [rsp + 32 + SU_FS], eax
    movzx eax, byte ptr [rsi]
    mov [rsp + 32 + SU_INDEX], eax
    mov [rsp + 32 + SU_EC_CAP], r13d
    mov [rsp + 32 + SU_PRED_CAP], r13d
    lea rcx, [rsp + 32]
    call op_silk_nlsf_unpack
    xor ecx, ecx
.Lsn_first_stage:
    movzx eax, byte ptr [r14 + rcx]
    shl eax, 7
    mov [rdi + rcx*2], ax
    inc ecx
    cmp ecx, r13d
    jb .Lsn_first_stage
    lea ecx, [r13 - 1]
    xor eax, eax                # previous residual
.Lsn_residual:
    movsx eax, ax
    movzx edx, byte ptr [r12 + rcx + NW_PRED]
    imul edx, eax
    sar edx, 8
    movsx eax, byte ptr [rsi + rcx + 1]
    shl eax, 10
    test eax, eax
    jz .Lsn_residual_quant
    js .Lsn_residual_negative
    sub eax, 102
    jmp .Lsn_residual_quant
.Lsn_residual_negative:
    add eax, 102
.Lsn_residual_quant:
    imul eax, r15d
    sar eax, 16
    add eax, edx
    mov [r12 + rcx*2 + NW_RES], ax
    dec ecx
    jns .Lsn_residual
    # The equivalent per-element Laroia sums preserve exact integer divisions.
    xor r14d, r14d
.Lsn_weight:
    movzx r8d, word ptr [rdi + r14*2]
    mov edx, r8d
    test r14d, r14d
    jz .Lsn_weight_left
    movzx eax, word ptr [rdi + r14*2 - 2]
    sub edx, eax
.Lsn_weight_left:
    mov ecx, 1
    cmp edx, ecx
    cmovl edx, ecx
    mov ecx, edx
    mov eax, 131072             #1<<(15+NLSF_W_Q), Q=2
    cdq
    idiv ecx
    mov r9d, eax
    lea eax, [r14 + 1]
    cmp eax, r13d
    jb .Lsn_weight_middle
    mov edx, 32768
    sub edx, r8d
    jmp .Lsn_weight_right
.Lsn_weight_middle:
    movzx edx, word ptr [rdi + r14*2 + 2]
    sub edx, r8d
.Lsn_weight_right:
    mov ecx, 1
    cmp edx, ecx
    cmovl edx, ecx
    mov ecx, edx
    mov eax, 131072
    cdq
    idiv ecx
    add eax, r9d
    mov edx, 32767
    cmp eax, edx
    cmovg eax, edx
    mov [r12 + r14*2 + NW_WEIGHT], ax
    inc r14d
    cmp r14d, r13d
    jb .Lsn_weight
    xor r14d, r14d
.Lsn_apply:
    movzx ecx, word ptr [r12 + r14*2 + NW_WEIGHT]
    shl ecx, 16
    call op_silk_sqrt_approx
    mov ecx, eax
    movsx eax, word ptr [r12 + r14*2 + NW_RES]
    shl eax, 14
    cdq
    idiv ecx
    movzx edx, word ptr [rdi + r14*2]
    add eax, edx
    xor edx, edx
    test eax, eax
    cmovs eax, edx
    mov edx, 32767
    cmp eax, edx
    cmovg eax, edx
    mov [rdi + r14*2], ax
    inc r14d
    cmp r14d, r13d
    jb .Lsn_apply
    mov [rsp + 32 + NS_OUT], rdi
    mov eax, [rbx + SN_FS]
    mov [rsp + 32 + NS_FS], eax
    mov [rsp + 32 + NS_CAP], r13d
    lea rcx, [rsp + 32]
    call op_silk_nlsf_stabilize
    jmp .Lsn_done
.Lsn_bad:
    xor eax, eax
.Lsn_done:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_nlsf_decode
