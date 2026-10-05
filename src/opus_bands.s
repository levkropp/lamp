# RFC8251 updates: Copyright (c) 2017 IETF Trust, Jean-Marc Valin, Koen Vos.
# Handwritten normal-mode CELT spectral frame orchestration.
# Normative BSD RFC6716 quant_all_bands, see THIRD_PARTY_NOTICES.
# Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation.
.include "lamp.inc"
.include "opus_bands_layout.inc"
.include "opus_band_layout.inc"
RODATA
oa_ebands: .short 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 34, 40, 48, 60, 78, 100
oa_half: .float 0.5
.text
.equ AA_N, 144
.equ AA_TELL, 148
.equ AA_BUDGET, 152
.equ AA_REMAIN, 156
.equ AA_BAL, 160
.equ AA_LOW_OFF, 164
.equ AA_UPDATE, 168
.equ AA_EFFECT, 172
.equ AA_XCM, 176
.equ AA_YCM, 180
.equ AA_DUAL, 184
.equ AA_BLOCK, 188
.equ AA_POS, 192
.equ AA_SIZE, 196
.equ AA_FEND, 200

# RCX=request. EAX=1 success / 0 invalid or band failure.
# Caller buffers are nonoverlapping. Capacity/parameter guards precede writes.
# Reconstructs normalized spectral coefficients only; synthesis is separate.
FN op_celt_bands
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 208
    mov rbx, rcx
    test rbx, rbx
    jz .Loa_bad
    cmp qword ptr [rbx + OA_EC], 0
    je .Loa_bad
    mov ecx, 3
.Loa_pointer_guard:
    cmp qword ptr [rbx + rcx*8], 0
    je .Loa_bad
    inc ecx
    cmp ecx, 9
    jb .Loa_pointer_guard
    cmp qword ptr [rbx + OA_X], 0
    je .Loa_bad
    mov r12d, [rbx + OA_START]
    cmp r12d, 20
    ja .Loa_bad
    mov eax, [rbx + OA_END]
    cmp eax, 21
    ja .Loa_bad
    cmp eax, r12d
    jle .Loa_bad
    cmp dword ptr [rbx + OA_LM], 3
    ja .Loa_bad
    cmp dword ptr [rbx + OA_SHORT], 1
    ja .Loa_bad
    cmp dword ptr [rbx + OA_SPREAD], 3
    ja .Loa_bad
    cmp dword ptr [rbx + OA_DUAL], 1
    ja .Loa_bad
    cmp dword ptr [rbx + OA_INTENSITY], 21
    ja .Loa_bad
    cmp dword ptr [rbx + OA_TOTAL], 81600
    ja .Loa_bad
    cmp dword ptr [rbx + OA_BALANCE], -81600
    jl .Loa_bad
    cmp dword ptr [rbx + OA_BALANCE], 81600
    jg .Loa_bad
    mov eax, [rbx + OA_CODED]
    cmp eax, r12d
    jl .Loa_bad
    cmp eax, [rbx + OA_END]
    jg .Loa_bad
    mov ecx, [rbx + OA_LM]
    mov r13d, 1
    shl r13d, cl
    imul eax, r13d, 100
    mov [rsp + AA_SIZE], eax
    cmp [rbx + OA_X_CAP], eax
    jb .Loa_bad
    mov r14d, 1
    xor r15d, r15d
    cmp qword ptr [rbx + OA_Y], 0
    je .Loa_mono
    inc r14d
    cmp [rbx + OA_Y_CAP], eax
    jb .Loa_bad
    lea r15, [rax*4]
    add r15, [rbx + OA_NORM]
    jmp .Loa_capacities
.Loa_mono:
    cmp dword ptr [rbx + OA_DUAL], 0
    jne .Loa_bad
.Loa_capacities:
    imul eax, r14d
    cmp [rbx + OA_NORM_CAP], eax
    jb .Loa_bad
    imul eax, r13d, 22
    cmp [rbx + OA_SCRATCH_CAP], eax
    jb .Loa_bad
    imul eax, r14d, 21
    cmp [rbx + OA_MASK_CAP], eax
    jb .Loa_bad
    mov eax, 1
    cmp dword ptr [rbx + OA_SHORT], 0
    cmovne eax, r13d
    mov [rsp + AA_BLOCK], eax
    # Check all active TF decisions and pulse budgets before any band writes.
    mov r10, [rbx + OA_TF]
    mov r11, [rbx + OA_PULSES]
    mov edx, r12d
.Loa_array_guard:
    cmp dword ptr [r11 + rdx*4], 81600
    ja .Loa_bad
    mov r8d, [r10 + rdx*4]
    cmp r8d, -3
    jl .Loa_bad
    cmp r8d, 3
    jg .Loa_bad
    lea r9, [rip + oa_ebands]
    movzx eax, word ptr [r9 + rdx*2 + 2]
    movzx ecx, word ptr [r9 + rdx*2]
    sub eax, ecx
    imul eax, r13d
    cmp eax, 1
    je .Loa_array_next
    test r8d, r8d
    jle .Loa_guard_negative
    bsr ecx, dword ptr [rsp + AA_BLOCK]
    cmp r8d, ecx
    jg .Loa_bad
    jmp .Loa_array_next
.Loa_guard_negative:
    mov ecx, [rsp + AA_BLOCK]
    # B is a power of two, so divide without disturbing the band index.
    bsr r9d, ecx
    xchg ecx, r9d
    shr eax, cl
    mov ecx, r9d
.Loa_guard_time:
    test r8d, r8d
    jz .Loa_array_next
    test eax, 1
    jnz .Loa_array_next
    shr eax, 1
    shl ecx, 1
    cmp ecx, 16
    ja .Loa_bad
    inc r8d
    jmp .Loa_guard_time
.Loa_array_next:
    inc edx
    cmp edx, [rbx + OA_END]
    jb .Loa_array_guard
    mov r8, [rbx + OA_EC]
    cmp dword ptr [r8 + 8], 1275
    ja .Loa_bad
    cmp dword ptr [r8 + 8], 0
    je .Loa_buffer_guard
    cmp qword ptr [r8], 0
    je .Loa_bad
.Loa_buffer_guard:
    mov eax, [r8 + 28]
    cmp eax, [r8 + 8]
    ja .Loa_bad
    mov eax, [r8 + 12]
    cmp eax, [r8 + 8]
    ja .Loa_bad
    cmp dword ptr [r8 + 32], 0x800000
    jbe .Loa_bad
    cmp dword ptr [r8 + 32], 0x80000000
    ja .Loa_bad
    cmp dword ptr [r8 + 20], 32
    ja .Loa_bad
    cmp dword ptr [r8 + 24], 32768
    ja .Loa_bad
    # Seed one immutable-input band request, replacing per-band fields below.
    mov rax, [rbx + OA_EC]
    mov [rsp + 32 + OB_EC], rax
    lea rax, [rsp + AA_REMAIN]
    mov [rsp + 32 + OB_REMAIN], rax
    mov rax, [rbx + OA_SEED]
    mov [rsp + 32 + OB_SEED], rax
    mov rax, [rbx + OA_SCRATCH]
    mov [rsp + 32 + OB_SCRATCH], rax
    mov eax, [rbx + OA_LM]
    mov [rsp + 32 + OB_LM], eax
    mov eax, [rbx + OA_SPREAD]
    mov [rsp + 32 + OB_SPREAD], eax
    mov eax, [rsp + AA_BLOCK]
    mov [rsp + 32 + OB_BLOCKS], eax
    mov eax, [rbx + OA_INTENSITY]
    mov [rsp + 32 + OB_INTENSITY], eax
    mov dword ptr [rsp + 32 + OB_LEVEL], 0
    mov dword ptr [rsp + 32 + OB_GAIN], 0x3f800000
    mov eax, [rbx + OA_BALANCE]
    mov [rsp + AA_BAL], eax
    mov eax, [rbx + OA_DUAL]
    mov [rsp + AA_DUAL], eax
    mov dword ptr [rsp + AA_LOW_OFF], 0
    mov dword ptr [rsp + AA_UPDATE], 1
.Loa_band_loop:
    lea rdx, [rip + oa_ebands]
    movzx eax, word ptr [rdx + r12*2]
    imul eax, r13d
    mov [rsp + AA_POS], eax
    movzx ecx, word ptr [rdx + r12*2 + 2]
    imul ecx, r13d
    sub ecx, eax
    mov [rsp + AA_N], ecx
    mov [rsp + 32 + OB_N], ecx
    mov [rsp + 32 + OB_BAND], r12d
    lea rsi, [rax*4]
    add rsi, [rbx + OA_X]
    xor edi, edi
    cmp r14d, 2
    jne .Loa_band_pointers
    lea rdi, [rax*4]
    add rdi, [rbx + OA_Y]
.Loa_band_pointers:
    mov rcx, [rbx + OA_EC]
    call op_ec_frac
    mov [rsp + AA_TELL], eax
    cmp r12d, [rbx + OA_START]
    je .Loa_band_remaining
    sub [rsp + AA_BAL], eax
.Loa_band_remaining:
    mov edx, [rbx + OA_TOTAL]
    sub edx, eax
    dec edx
    mov [rsp + AA_REMAIN], edx
    xor eax, eax
    cmp r12d, [rbx + OA_CODED]
    jge .Loa_band_budget_ready
    mov ecx, [rbx + OA_CODED]
    sub ecx, r12d
    mov eax, 3
    cmp ecx, eax
    cmovg ecx, eax
    mov eax, [rsp + AA_BAL]
    cdq
    idiv ecx
    mov rdx, [rbx + OA_PULSES]
    add eax, [rdx + r12*4]
    mov edx, [rsp + AA_REMAIN]
    inc edx
    cmp eax, edx
    cmovg eax, edx
    mov edx, 16383
    cmp eax, edx
    cmovg eax, edx
    xor edx, edx
    cmp eax, edx
    cmovl eax, edx
.Loa_band_budget_ready:
    mov [rsp + AA_BUDGET], eax
    mov [rsp + 32 + OB_BUDGET], eax
    lea rdx, [rip + oa_ebands]
    mov ecx, [rbx + OA_START]
    movzx ecx, word ptr [rdx + rcx*2]
    imul ecx, r13d
    mov eax, [rsp + AA_POS]
    sub eax, [rsp + AA_N]
    cmp eax, ecx
    jge .Loa_lowband_candidate
    mov eax, [rbx + OA_START]
    inc eax
    cmp r12d, eax
    jne .Loa_lowband_selected
.Loa_lowband_candidate:
    cmp dword ptr [rsp + AA_UPDATE], 0
    jne .Loa_lowband_update
    cmp dword ptr [rsp + AA_LOW_OFF], 0
    jne .Loa_lowband_selected
.Loa_lowband_update:
    mov [rsp + AA_LOW_OFF], r12d
.Loa_lowband_selected:
    # RFC8251: duplicate the tail of the first hybrid band for folding into
    # the wider second band. CELT-only bands have equal widths and copy zero.
    mov ecx, [rbx + OA_START]
    lea eax, [rcx + 1]
    cmp r12d, eax
    jne .Loa_fold_duplicate_done
    lea rdx, [rip + oa_ebands]
    movzx r8d, word ptr [rdx + rcx*2]       #offset / M
    movzx r9d, word ptr [rdx + rcx*2 + 2]
    movzx r10d, word ptr [rdx + rcx*2 + 4]
    sub r10d, r9d                      #n2 / M
    sub r9d, r8d                       #n1 / M
    imul r8d, r13d
    imul r9d, r13d
    imul r10d, r13d
    sub r10d, r9d                      #copy count n2-n1
    lea ecx, [r8 + r9]                    #destination offset+n1
    mov eax, ecx
    sub eax, r10d                      #source offset+2*n1-n2
    mov rdx, [rbx + OA_NORM]
.Loa_fold_duplicate:
    test r10d, r10d
    jle .Loa_fold_duplicate_done
    mov r8d, [rdx + rax*4]
    mov [rdx + rcx*4], r8d
    cmp r14d, 2
    jne .Loa_fold_duplicate_next
    mov r8d, [r15 + rax*4]
    mov [r15 + rcx*4], r8d
.Loa_fold_duplicate_next:
    inc eax
    inc ecx
    dec r10d
    jmp .Loa_fold_duplicate
.Loa_fold_duplicate_done:
    mov rdx, [rbx + OA_TF]
    mov eax, [rdx + r12*4]
    mov [rsp + 32 + OB_TF], eax
    mov dword ptr [rsp + AA_EFFECT], -1
    mov ecx, [rsp + AA_BLOCK]
    mov eax, 1
    shl eax, cl
    dec eax
    mov [rsp + AA_XCM], eax
    mov [rsp + AA_YCM], eax
    cmp dword ptr [rsp + AA_LOW_OFF], 0
    je .Loa_fold_ready
    cmp dword ptr [rbx + OA_SPREAD], 3
    jne .Loa_fold_masks
    cmp dword ptr [rsp + AA_BLOCK], 1
    ja .Loa_fold_masks
    cmp dword ptr [rsp + 32 + OB_TF], 0
    jge .Loa_fold_ready
.Loa_fold_masks:
    lea rdx, [rip + oa_ebands]
    mov ecx, [rbx + OA_START]
    movzx eax, word ptr [rdx + rcx*2]
    imul eax, r13d
    mov ecx, [rsp + AA_LOW_OFF]
    movzx r8d, word ptr [rdx + rcx*2]
    imul r8d, r13d
    sub r8d, [rsp + AA_N]
    cmp r8d, eax
    cmovl r8d, eax
    mov [rsp + AA_EFFECT], r8d
.Loa_fold_start:
    dec ecx
    movzx eax, word ptr [rdx + rcx*2]
    imul eax, r13d
    cmp eax, r8d
    jg .Loa_fold_start
    mov r9d, [rsp + AA_LOW_OFF]
    dec r9d
    add r8d, [rsp + AA_N]
.Loa_fold_end:
    inc r9d
    cmp r9d, r12d
    jge .Loa_fold_end_ready
    movzx eax, word ptr [rdx + r9*2]
    imul eax, r13d
    cmp eax, r8d
    jl .Loa_fold_end
.Loa_fold_end_ready:
    mov rdx, [rbx + OA_MASKS]
    xor r8d, r8d
    xor r10d, r10d
.Loa_fold_mask_loop:
    mov eax, ecx
    imul eax, r14d
    movzx r11d, byte ptr [rdx + rax]
    or r8d, r11d
    add eax, r14d
    dec eax
    movzx r11d, byte ptr [rdx + rax]
    or r10d, r11d
    inc ecx
    cmp ecx, r9d
    jl .Loa_fold_mask_loop
    mov [rsp + AA_XCM], r8d
    mov [rsp + AA_YCM], r10d
.Loa_fold_ready:
    cmp dword ptr [rsp + AA_DUAL], 0
    je .Loa_setup_band
    cmp r12d, [rbx + OA_INTENSITY]
    jne .Loa_setup_band
    mov dword ptr [rsp + AA_DUAL], 0
    lea rdx, [rip + oa_ebands]
    mov ecx, [rbx + OA_START]
    movzx ecx, word ptr [rdx + rcx*2]
    imul ecx, r13d
    mov rdx, [rbx + OA_NORM]
.Loa_mix_norm:
    cmp ecx, [rsp + AA_POS]
    jae .Loa_setup_band
    movss xmm0, dword ptr [rdx + rcx*4]
    addss xmm0, dword ptr [r15 + rcx*4]
    mulss xmm0, dword ptr [rip + oa_half]
    movss dword ptr [rdx + rcx*4], xmm0
    inc ecx
    jmp .Loa_mix_norm
.Loa_setup_band:
    mov [rsp + 32 + OB_X], rsi
    mov rax, [rbx + OA_NORM]
    mov edx, [rsp + AA_POS]
    lea rax, [rax + rdx*4]
    mov [rsp + 32 + OB_OUT], rax
    xor eax, eax
    mov edx, [rsp + AA_EFFECT]
    test edx, edx
    js .Loa_setup_low
    mov rax, [rbx + OA_NORM]
    lea rax, [rax + rdx*4]
.Loa_setup_low:
    mov [rsp + 32 + OB_LOW], rax
    cmp dword ptr [rsp + AA_DUAL], 0
    jne .Loa_dual_bands
    mov [rsp + 32 + OB_Y], rdi
    mov eax, [rsp + AA_XCM]
    or eax, [rsp + AA_YCM]
    mov [rsp + 32 + OB_FILL], eax
    lea rcx, [rsp + 32]
    call op_celt_band
    test eax, eax
    jz .Loa_bad
    mov eax, [rsp + 32 + OB_CM]
    mov [rsp + AA_XCM], eax
    mov [rsp + AA_YCM], eax
    jmp .Loa_band_masks
.Loa_dual_bands:
    mov qword ptr [rsp + 32 + OB_Y], 0
    sar dword ptr [rsp + 32 + OB_BUDGET], 1
    mov eax, [rsp + AA_XCM]
    mov [rsp + 32 + OB_FILL], eax
    lea rcx, [rsp + 32]
    call op_celt_band
    test eax, eax
    jz .Loa_bad
    mov eax, [rsp + 32 + OB_CM]
    mov [rsp + AA_XCM], eax
    mov [rsp + 32 + OB_X], rdi
    mov edx, [rsp + AA_POS]
    lea rax, [r15 + rdx*4]
    mov [rsp + 32 + OB_OUT], rax
    xor eax, eax
    mov edx, [rsp + AA_EFFECT]
    test edx, edx
    js .Loa_dual_low
    lea rax, [r15 + rdx*4]
.Loa_dual_low:
    mov [rsp + 32 + OB_LOW], rax
    mov eax, [rsp + AA_YCM]
    mov [rsp + 32 + OB_FILL], eax
    lea rcx, [rsp + 32]
    call op_celt_band
    test eax, eax
    jz .Loa_bad
    mov eax, [rsp + 32 + OB_CM]
    mov [rsp + AA_YCM], eax
.Loa_band_masks:
    mov rdx, [rbx + OA_MASKS]
    mov eax, r12d
    imul eax, r14d
    mov ecx, [rsp + AA_XCM]
    mov [rdx + rax], cl
    add eax, r14d
    dec eax
    mov ecx, [rsp + AA_YCM]
    mov [rdx + rax], cl
    mov rdx, [rbx + OA_PULSES]
    mov eax, [rdx + r12*4]
    add eax, [rsp + AA_TELL]
    add [rsp + AA_BAL], eax
    mov eax, [rsp + AA_N]
    shl eax, 3
    cmp [rsp + AA_BUDGET], eax
    setg al
    movzx eax, al
    mov [rsp + AA_UPDATE], eax
    inc r12d
    cmp r12d, [rbx + OA_END]
    jl .Loa_band_loop
    mov eax, [rsp + AA_BAL]
    mov [rbx + OA_BALANCE_OUT], eax
    mov eax, [rsp + AA_REMAIN]
    mov [rbx + OA_REMAIN_OUT], eax
    mov eax, 1
    jmp .Loa_done
.Loa_bad:
    xor eax, eax
.Loa_done:
    add rsp, 208
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_celt_bands
