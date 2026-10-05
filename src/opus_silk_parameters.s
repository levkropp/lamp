# Handwritten SILK gain and pitch/LTP parameter reconstruction.
# RFC6716 gain_quant.c,log2lin.c,decode_pitch.c,decode_parameters.c.
# Copyright(c)2006-2012 IETF Trust and Skype Limited, BSD conditions
# in THIRD_PARTY_NOTICES. Integer assembly only; no CRT/C runtime.
.include "lamp.inc"
.include "opus_silk_parameters_layout.inc"
.include "opus_silk_indices_layout.inc"
RODATA
.include "opus_silk_parameters_tables.inc"
.text
# ECX=Q7 log value, EAX=normative linear approximation. Negative values map
# to0; supported nonnegative range0..3967, higher values reject with0.
FN op_silk_log2lin
    test ecx, ecx
    js .Lsg_log_zero
    cmp ecx, 3967
    ja .Lsg_log_zero
    mov r9d, ecx
    mov r8d, ecx
    and r8d, 127
    mov edx, 128
    sub edx, r8d
    imul edx, r8d
    imul edx, edx, -174
    sar edx, 16
    add r8d, edx
    sar ecx, 7
    mov eax, 1
    shl eax, cl
    mov edx, eax
    cmp r9d, 2048
    jge .Lsg_log_high
    imul edx, r8d
    sar edx, 7
    add eax, edx
    ret
.Lsg_log_high:
    sar edx, 7
    imul edx, r8d
    add eax, edx
    ret
.Lsg_log_zero:
    xor eax, eax
    ret
ENDFN op_silk_log2lin

FN op_silk_gains
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rbx, rcx
    test rbx, rbx
    jz .Lsg_bad
    mov rsi, [rbx + SG_IND]
    mov rdi, [rbx + SG_OUT]
    mov r12, [rbx + SG_PREV]
    test rsi, rsi
    jz .Lsg_bad
    test rdi, rdi
    jz .Lsg_bad
    test r12, r12
    jz .Lsg_bad
    mov eax, [rbx + SG_SUBFR]
    cmp eax, 2
    je .Lsg_subfr
    cmp eax, 4
    jne .Lsg_bad
.Lsg_subfr:
    cmp [rbx + SG_IND_CAP], eax
    jb .Lsg_bad
    cmp [rbx + SG_OUT_CAP], eax
    jb .Lsg_bad
    cmp dword ptr [rbx + SG_PREV_CAP], 1
    jb .Lsg_bad
    cmp dword ptr [rbx + SG_CONDITIONAL], 1
    ja .Lsg_bad
    cmp byte ptr [r12], 63
    ja .Lsg_bad
    xor ecx, ecx
.Lsg_index_guard:
    movzx edx, byte ptr [rsi + rcx]
    test ecx, ecx
    jnz .Lsg_delta_guard
    cmp dword ptr [rbx + SG_CONDITIONAL], 0
    jne .Lsg_delta_guard
    cmp edx, 63
    ja .Lsg_bad
    jmp .Lsg_guard_next
.Lsg_delta_guard:
    cmp edx, 40
    ja .Lsg_bad
.Lsg_guard_next:
    inc ecx
    cmp ecx, eax
    jb .Lsg_index_guard
    xor r13d, r13d
.Lsg_subframe:
    movzx eax, byte ptr [rsi + r13]
    movzx edx, byte ptr [r12]
    test r13d, r13d
    jnz .Lsg_delta
    cmp dword ptr [rbx + SG_CONDITIONAL], 0
    jne .Lsg_delta
    sub edx, 16
    cmp eax, edx
    cmovl eax, edx
    jmp .Lsg_clamp
.Lsg_delta:
    sub eax, 4
    lea r8d, [rdx + 8]            # threshold=2*36-64+last
    cmp eax, r8d
    jle .Lsg_single_step
    add eax, eax
    sub eax, r8d
.Lsg_single_step:
    add eax, edx
.Lsg_clamp:
    xor edx, edx
    test eax, eax
    cmovs eax, edx
    mov edx, 63
    cmp eax, edx
    cmovg eax, edx
    mov [r12], al
    imul ecx, eax, 1907825       # INV_SCALE_Q16
    sar ecx, 16
    add ecx, 2090               # OFFSET
    mov eax, 3967
    cmp ecx, eax
    cmovg ecx, eax
    call op_silk_log2lin
    mov [rdi + r13*4], eax
    inc r13d
    cmp r13d, [rbx + SG_SUBFR]
    jb .Lsg_subframe
    mov eax, 1
    jmp .Lsg_done
.Lsg_bad:
    xor eax, eax
.Lsg_done:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_gains

FN op_silk_pitch_ltp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov rbx, rcx
    test rbx, rbx
    jz .Lsp_bad
    mov rsi, [rbx + SP_IND]
    mov rdi, [rbx + SP_PITCH]
    mov r12, [rbx + SP_LTP]
    mov r13, [rbx + SP_SCALE]
    test rsi, rsi
    jz .Lsp_bad
    test rdi, rdi
    jz .Lsp_bad
    test r12, r12
    jz .Lsp_bad
    test r13, r13
    jz .Lsp_bad
    mov eax, [rbx + SP_FS]
    cmp eax, 8
    je .Lsp_rate
    cmp eax, 12
    je .Lsp_rate
    cmp eax, 16
    jne .Lsp_bad
.Lsp_rate:
    mov ecx, [rbx + SP_SUBFR]
    cmp ecx, 2
    je .Lsp_subfr
    cmp ecx, 4
    jne .Lsp_bad
.Lsp_subfr:
    cmp [rbx + SP_PITCH_CAP], ecx
    jb .Lsp_bad
    imul edx, ecx, 5
    cmp [rbx + SP_LTP_CAP], edx
    jb .Lsp_bad
    cmp dword ptr [rbx + SP_SCALE_CAP], 1
    jb .Lsp_bad
    cmp byte ptr [rsi + SX_SIGNAL], 2
    ja .Lsp_bad
    jne .Lsp_unvoiced
    lea r14, [rip + sp_contour]
    mov r10d, 34
    cmp ecx, 4
    jne .Lsp_choose10
    cmp eax, 8
    jne .Lsp_contour_chosen
    lea r14, [rip + sp_contour_nb]
    mov r10d, 11
    jmp .Lsp_contour_chosen
.Lsp_choose10:
    lea r14, [rip + sp_contour10]
    mov r10d, 12
    cmp eax, 8
    jne .Lsp_contour_chosen
    lea r14, [rip + sp_contour10_nb]
    mov r10d, 3
.Lsp_contour_chosen:
    movzx eax, byte ptr [rsi + SX_CONTOUR]
    cmp eax, r10d
    jae .Lsp_bad
    add r14, rax
    movzx eax, byte ptr [rsi + SX_PER]
    cmp eax, 2
    ja .Lsp_bad
    lea rdx, [rip + sp_ltp_ptr]
    mov r15, [rdx + rax*8]
    mov ecx, eax
    mov r8d, 8
    shl r8d, cl
    cmp byte ptr [rsi + SX_SCALE], 2
    ja .Lsp_bad
    xor ecx, ecx
.Lsp_ltp_guard:
    movzx eax, byte ptr [rsi + rcx + SX_LTP]
    cmp eax, r8d
    jae .Lsp_bad
    inc ecx
    cmp ecx, [rbx + SP_SUBFR]
    jb .Lsp_ltp_guard
    mov r8d, [rbx + SP_FS]
    imul r9d, r8d, 18            # max18ms
    add r8d, r8d                # min2ms
    movsx r11d, word ptr [rsi + SX_LAG]
    add r11d, r8d
    xor ecx, ecx
.Lsp_pitch_loop:
    movsx eax, byte ptr [r14]
    add eax, r11d
    cmp eax, r8d
    cmovl eax, r8d
    cmp eax, r9d
    cmovg eax, r9d
    mov [rdi + rcx*4], eax
    add r14, r10
    inc ecx
    cmp ecx, [rbx + SP_SUBFR]
    jb .Lsp_pitch_loop
    xor r8d, r8d
.Lsp_ltp_subframe:
    movzx eax, byte ptr [rsi + r8 + SX_LTP]
    imul eax, 5
    lea r9, [r15 + rax]
    imul eax, r8d, 5
    lea r10, [r12 + rax*2]
    xor ecx, ecx
.Lsp_ltp_tap:
    movsx eax, byte ptr [r9 + rcx]
    shl eax, 7
    mov [r10 + rcx*2], ax
    inc ecx
    cmp ecx, 5
    jb .Lsp_ltp_tap
    inc r8d
    cmp r8d, [rbx + SP_SUBFR]
    jb .Lsp_ltp_subframe
    movzx eax, byte ptr [rsi + SX_SCALE]
    lea rdx, [rip + sp_scales]
    movsx eax, word ptr [rdx + rax*2]
    mov [r13], eax
    jmp .Lsp_good
.Lsp_unvoiced:
    xor ecx, ecx
.Lsp_clear_pitch:
    mov dword ptr [rdi + rcx*4], 0
    inc ecx
    cmp ecx, [rbx + SP_SUBFR]
    jb .Lsp_clear_pitch
    imul edx, ecx, 5
    xor ecx, ecx
.Lsp_clear_ltp:
    mov word ptr [r12 + rcx*2], 0
    inc ecx
    cmp ecx, edx
    jb .Lsp_clear_ltp
    mov dword ptr [r13], 0
.Lsp_good:
    mov eax, 1
    jmp .Lsp_done
.Lsp_bad:
    xor eax, eax
.Lsp_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_pitch_ltp
