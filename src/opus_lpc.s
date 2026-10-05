# Handwritten SSE2 CELT float autocorrelation, LPC, FIR and IIR.
# RFC6716 celt_lpc.c, BSD conditions in THIRD_PARTY_NOTICES.
# Copyright (c) 2009-2012 IETF Trust, Xiph.Org Foundation.
# Jean-Marc Valin. No CRT, heap or runtime reference-C dependencies.
.include "lamp.inc"
.include "opus_lpc_layout.inc"
RODATA
lp_ten: .float 10.0
lp_stop: .float 0.001
.text
# All public value/capacity checks precede writes. X magnitude <=2^50.
FN op_celt_autocorr
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    mov rbx, rcx
    test rbx, rbx
    jz .Lla_bad
    mov rsi, [rbx + LA_X]
    mov rdi, [rbx + LA_SCRATCH]
    mov r12, [rbx + LA_AC]
    mov r13, [rbx + LA_WINDOW]
    test rsi, rsi
    jz .Lla_bad
    test rdi, rdi
    jz .Lla_bad
    test r12, r12
    jz .Lla_bad
    mov r8d, [rbx + LA_N]
    test r8d, r8d
    jle .Lla_bad
    cmp r8d, 2048
    ja .Lla_bad
    cmp [rbx + LA_X_CAP], r8d
    jb .Lla_bad
    cmp [rbx + LA_SCRATCH_CAP], r8d
    jb .Lla_bad
    mov r9d, [rbx + LA_LAG]
    cmp r9d, 24
    ja .Lla_bad
    cmp r9d, r8d
    jae .Lla_bad
    lea eax, [r9 + 1]
    cmp [rbx + LA_AC_CAP], eax
    jb .Lla_bad
    mov r10d, [rbx + LA_OVERLAP]
    cmp r10d, 120
    ja .Lla_bad
    mov eax, r8d
    shr eax, 1
    cmp r10d, eax
    ja .Lla_bad
    test r10d, r10d
    jz .Lla_x_guard
    test r13, r13
    jz .Lla_bad
    cmp [rbx + LA_WINDOW_CAP], r10d
    jb .Lla_bad
    xor ecx, ecx
.Lla_window_guard:
    mov eax, [r13 + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x3f800000
    ja .Lla_bad
    inc ecx
    cmp ecx, r10d
    jb .Lla_window_guard
.Lla_x_guard:
    xor ecx, ecx
.Lla_x_guard_loop:
    mov eax, [rsi + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x58800000
    ja .Lla_bad
    inc ecx
    cmp ecx, r8d
    jb .Lla_x_guard_loop
    xor ecx, ecx
.Lla_copy:
    mov eax, [rsi + rcx*4]
    mov [rdi + rcx*4], eax
    inc ecx
    cmp ecx, r8d
    jb .Lla_copy
    xor ecx, ecx
    test r10d, r10d
    jz .Lla_lag
.Lla_window:
    movss xmm0, dword ptr [rsi + rcx*4]
    mulss xmm0, dword ptr [r13 + rcx*4]
    movss dword ptr [rdi + rcx*4], xmm0
    mov eax, r8d
    sub eax, ecx
    dec eax
    movss xmm0, dword ptr [rsi + rax*4]
    mulss xmm0, dword ptr [r13 + rcx*4]
    movss dword ptr [rdi + rax*4], xmm0
    inc ecx
    cmp ecx, r10d
    jb .Lla_window
.Lla_lag:
    xorps xmm0, xmm0
    mov ecx, r9d
    xor edx, edx
.Lla_sum:
    movss xmm1, dword ptr [rdi + rcx*4]
    mulss xmm1, dword ptr [rdi + rdx*4]
    addss xmm0, xmm1
    inc ecx
    inc edx
    cmp ecx, r8d
    jb .Lla_sum
    movss dword ptr [r12 + r9*4], xmm0
    dec r9d
    jns .Lla_lag
    movss xmm0, dword ptr [r12]
    addss xmm0, dword ptr [rip + lp_ten]
    movss dword ptr [r12], xmm0
    mov eax, 1
    jmp .Lla_done
.Lla_bad:
    xor eax, eax
.Lla_done:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_celt_autocorr

# Correlations are finite, |AC|<=2^110; AC[0]>=0. Caller supplies a physical
# autocorrelation sequence. A numerical failure may leave partial output.
FN op_celt_lpc
    push rbx
    push rsi
    push rdi
    mov rbx, rcx
    test rbx, rbx
    jz .Lll_bad
    mov rsi, [rbx + LL_AC]
    mov rdi, [rbx + LL_OUT]
    test rsi, rsi
    jz .Lll_bad
    test rdi, rdi
    jz .Lll_bad
    mov r8d, [rbx + LL_ORDER]
    test r8d, r8d
    jle .Lll_bad
    cmp r8d, 24
    ja .Lll_bad
    cmp [rbx + LL_OUT_CAP], r8d
    jb .Lll_bad
    lea eax, [r8 + 1]
    cmp [rbx + LL_AC_CAP], eax
    jb .Lll_bad
    xor ecx, ecx
.Lll_ac_guard:
    mov eax, [rsi + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x76800000
    ja .Lll_bad
    inc ecx
    cmp ecx, r8d
    jbe .Lll_ac_guard
    xorps xmm0, xmm0
    comiss xmm0, dword ptr [rsi]
    ja .Lll_bad
    xor ecx, ecx
.Lll_clear:
    mov dword ptr [rdi + rcx*4], 0
    inc ecx
    cmp ecx, r8d
    jb .Lll_clear
    movss xmm5, dword ptr [rsi]   # error
    comiss xmm5, xmm0
    je .Lll_good
    xor r9d, r9d                # iteration i
.Lll_iter:
    xorps xmm0, xmm0
    xor ecx, ecx
    test r9d, r9d
    jz .Lll_reflection
.Lll_rr:
    mov eax, r9d
    sub eax, ecx
    movss xmm1, dword ptr [rdi + rcx*4]
    mulss xmm1, dword ptr [rsi + rax*4]
    addss xmm0, xmm1
    inc ecx
    cmp ecx, r9d
    jb .Lll_rr
.Lll_reflection:
    addss xmm0, dword ptr [rsi + r9*4 + 4]
    divss xmm0, xmm5
    mov eax, 0x80000000
    movd xmm1, eax
    xorps xmm0, xmm1             # r=-rr/error
    movss dword ptr [rdi + r9*4], xmm0
    lea r10d, [r9 + 1]
    shr r10d, 1
    xor ecx, ecx
    test r10d, r10d
    jz .Lll_error
.Lll_pairs:
    mov eax, r9d
    dec eax
    sub eax, ecx
    movss xmm1, dword ptr [rdi + rcx*4]
    movss xmm2, dword ptr [rdi + rax*4]
    movaps xmm3, xmm0
    mulss xmm3, xmm2
    addss xmm3, xmm1
    movss dword ptr [rdi + rcx*4], xmm3
    mulss xmm1, xmm0
    addss xmm1, xmm2
    movss dword ptr [rdi + rax*4], xmm1
    inc ecx
    cmp ecx, r10d
    jb .Lll_pairs
.Lll_error:
    mulss xmm0, xmm0
    mulss xmm0, xmm5
    subss xmm5, xmm0
    movss xmm1, dword ptr [rsi]
    mulss xmm1, dword ptr [rip + lp_stop]
    comiss xmm5, xmm1
    jb .Lll_finish_check
    inc r9d
    cmp r9d, r8d
    jb .Lll_iter
.Lll_finish_check:
    xor ecx, ecx
.Lll_result_guard:
    mov eax, [rdi + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x76800000
    ja .Lll_bad
    inc ecx
    cmp ecx, r8d
    jb .Lll_result_guard
.Lll_good:
    mov eax, 1
    jmp .Lll_done
.Lll_bad:
    xor eax, eax
.Lll_done:
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_celt_lpc

# FIR and IIR share scalar normative accumulation and delay-line order.
FN op_celt_fir
    xor r11d, r11d
    jmp lf_entry
ENDFN op_celt_fir
FN op_celt_iir
    mov r11d, 1
lf_entry:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    mov rbx, rcx
    test rbx, rbx
    jz .Llf_bad
    mov rsi, [rbx + LF_X]
    mov rdi, [rbx + LF_OUT]
    mov r12, [rbx + LF_COEF]
    mov r13, [rbx + LF_MEM]
    test rsi, rsi
    jz .Llf_bad
    test rdi, rdi
    jz .Llf_bad
    test r12, r12
    jz .Llf_bad
    test r13, r13
    jz .Llf_bad
    mov r8d, [rbx + LF_N]
    test r8d, r8d
    jle .Llf_bad
    cmp r8d, 1200
    ja .Llf_bad
    cmp [rbx + LF_X_CAP], r8d
    jb .Llf_bad
    cmp [rbx + LF_OUT_CAP], r8d
    jb .Llf_bad
    mov r9d, [rbx + LF_ORDER]
    test r9d, r9d
    jle .Llf_bad
    cmp r9d, 24
    ja .Llf_bad
    cmp [rbx + LF_COEF_CAP], r9d
    jb .Llf_bad
    cmp [rbx + LF_MEM_CAP], r9d
    jb .Llf_bad
    xor ecx, ecx
.Llf_x_guard:
    mov eax, [rsi + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x58800000
    ja .Llf_bad
    inc ecx
    cmp ecx, r8d
    jb .Llf_x_guard
    xor ecx, ecx
.Llf_coef_guard:
    mov eax, [r12 + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x58800000
    ja .Llf_bad
    mov eax, [r13 + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x58800000
    ja .Llf_bad
    inc ecx
    cmp ecx, r9d
    jb .Llf_coef_guard
    xor r10d, r10d
.Llf_sample:
    movss xmm0, dword ptr [rsi + r10*4]
    movaps xmm2, xmm0            # saved input before in-place output
    xor ecx, ecx
    test r11d, r11d
    jnz .Llf_iir_sum
.Llf_fir_sum:
    movss xmm1, dword ptr [r12 + rcx*4]
    mulss xmm1, dword ptr [r13 + rcx*4]
    addss xmm0, xmm1
    inc ecx
    cmp ecx, r9d
    jb .Llf_fir_sum
    jmp .Llf_shift
.Llf_iir_sum:
    movss xmm1, dword ptr [r12 + rcx*4]
    mulss xmm1, dword ptr [r13 + rcx*4]
    subss xmm0, xmm1
    inc ecx
    cmp ecx, r9d
    jb .Llf_iir_sum
    movaps xmm2, xmm0
.Llf_shift:
    mov ecx, r9d
    dec ecx
    jz .Llf_store
.Llf_shift_loop:
    mov eax, [r13 + rcx*4 - 4]
    mov [r13 + rcx*4], eax
    dec ecx
    jnz .Llf_shift_loop
.Llf_store:
    movss dword ptr [r13], xmm2
    movss dword ptr [rdi + r10*4], xmm0
    inc r10d
    cmp r10d, r8d
    jb .Llf_sample
    mov eax, 1
    jmp .Llf_done
.Llf_bad:
    xor eax, eax
.Llf_done:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_celt_iir
