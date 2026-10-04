; Handwritten SSE2 CELT float autocorrelation, LPC, FIR and IIR.
; RFC6716 celt_lpc.c, BSD conditions in THIRD_PARTY_NOTICES.
; Copyright (c) 2009-2012 IETF Trust, Xiph.Org Foundation.
; Jean-Marc Valin. No CRT, heap or runtime reference-C dependencies.
option casemap:none
include opus_lpc_layout.inc
PUBLIC op_celt_autocorr, op_celt_lpc, op_celt_fir, op_celt_iir
.const
lp_ten real4 10.0
lp_stop real4 0.001
.code
; All public value/capacity checks precede writes. X magnitude <=2^50.
op_celt_autocorr PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    mov rbx,rcx
    test rbx,rbx
    jz la_bad
    mov rsi,[rbx+LA_X]
    mov rdi,[rbx+LA_SCRATCH]
    mov r12,[rbx+LA_AC]
    mov r13,[rbx+LA_WINDOW]
    test rsi,rsi
    jz la_bad
    test rdi,rdi
    jz la_bad
    test r12,r12
    jz la_bad
    mov r8d,[rbx+LA_N]
    test r8d,r8d
    jle la_bad
    cmp r8d,2048
    ja la_bad
    cmp [rbx+LA_X_CAP],r8d
    jb la_bad
    cmp [rbx+LA_SCRATCH_CAP],r8d
    jb la_bad
    mov r9d,[rbx+LA_LAG]
    cmp r9d,24
    ja la_bad
    cmp r9d,r8d
    jae la_bad
    lea eax,[r9+1]
    cmp [rbx+LA_AC_CAP],eax
    jb la_bad
    mov r10d,[rbx+LA_OVERLAP]
    cmp r10d,120
    ja la_bad
    mov eax,r8d
    shr eax,1
    cmp r10d,eax
    ja la_bad
    test r10d,r10d
    jz la_x_guard
    test r13,r13
    jz la_bad
    cmp [rbx+LA_WINDOW_CAP],r10d
    jb la_bad
    xor ecx,ecx
la_window_guard:
    mov eax,[r13+rcx*4]
    and eax,7fffffffh
    cmp eax,3f800000h
    ja la_bad
    inc ecx
    cmp ecx,r10d
    jb la_window_guard
la_x_guard:
    xor ecx,ecx
la_x_guard_loop:
    mov eax,[rsi+rcx*4]
    and eax,7fffffffh
    cmp eax,58800000h
    ja la_bad
    inc ecx
    cmp ecx,r8d
    jb la_x_guard_loop
    xor ecx,ecx
la_copy:
    mov eax,[rsi+rcx*4]
    mov [rdi+rcx*4],eax
    inc ecx
    cmp ecx,r8d
    jb la_copy
    xor ecx,ecx
    test r10d,r10d
    jz la_lag
la_window:
    movss xmm0,dword ptr [rsi+rcx*4]
    mulss xmm0,dword ptr [r13+rcx*4]
    movss dword ptr [rdi+rcx*4],xmm0
    mov eax,r8d
    sub eax,ecx
    dec eax
    movss xmm0,dword ptr [rsi+rax*4]
    mulss xmm0,dword ptr [r13+rcx*4]
    movss dword ptr [rdi+rax*4],xmm0
    inc ecx
    cmp ecx,r10d
    jb la_window
la_lag:
    xorps xmm0,xmm0
    mov ecx,r9d
    xor edx,edx
la_sum:
    movss xmm1,dword ptr [rdi+rcx*4]
    mulss xmm1,dword ptr [rdi+rdx*4]
    addss xmm0,xmm1
    inc ecx
    inc edx
    cmp ecx,r8d
    jb la_sum
    movss dword ptr [r12+r9*4],xmm0
    dec r9d
    jns la_lag
    movss xmm0,dword ptr [r12]
    addss xmm0,dword ptr [lp_ten]
    movss dword ptr [r12],xmm0
    mov eax,1
    jmp la_done
la_bad:
    xor eax,eax
la_done:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_celt_autocorr ENDP

; Correlations are finite, |AC|<=2^110; AC[0]>=0. Caller supplies a physical
; autocorrelation sequence. A numerical failure may leave partial output.
op_celt_lpc PROC
    push rbx
    push rsi
    push rdi
    mov rbx,rcx
    test rbx,rbx
    jz ll_bad
    mov rsi,[rbx+LL_AC]
    mov rdi,[rbx+LL_OUT]
    test rsi,rsi
    jz ll_bad
    test rdi,rdi
    jz ll_bad
    mov r8d,[rbx+LL_ORDER]
    test r8d,r8d
    jle ll_bad
    cmp r8d,24
    ja ll_bad
    cmp [rbx+LL_OUT_CAP],r8d
    jb ll_bad
    lea eax,[r8+1]
    cmp [rbx+LL_AC_CAP],eax
    jb ll_bad
    xor ecx,ecx
ll_ac_guard:
    mov eax,[rsi+rcx*4]
    and eax,7fffffffh
    cmp eax,76800000h
    ja ll_bad
    inc ecx
    cmp ecx,r8d
    jbe ll_ac_guard
    xorps xmm0,xmm0
    comiss xmm0,dword ptr [rsi]
    ja ll_bad
    xor ecx,ecx
ll_clear:
    mov dword ptr [rdi+rcx*4],0
    inc ecx
    cmp ecx,r8d
    jb ll_clear
    movss xmm5,dword ptr [rsi]   ; error
    comiss xmm5,xmm0
    je ll_good
    xor r9d,r9d                ; iteration i
ll_iter:
    xorps xmm0,xmm0
    xor ecx,ecx
    test r9d,r9d
    jz ll_reflection
ll_rr:
    mov eax,r9d
    sub eax,ecx
    movss xmm1,dword ptr [rdi+rcx*4]
    mulss xmm1,dword ptr [rsi+rax*4]
    addss xmm0,xmm1
    inc ecx
    cmp ecx,r9d
    jb ll_rr
ll_reflection:
    addss xmm0,dword ptr [rsi+r9*4+4]
    divss xmm0,xmm5
    mov eax,80000000h
    movd xmm1,eax
    xorps xmm0,xmm1             ; r=-rr/error
    movss dword ptr [rdi+r9*4],xmm0
    lea r10d,[r9+1]
    shr r10d,1
    xor ecx,ecx
    test r10d,r10d
    jz ll_error
ll_pairs:
    mov eax,r9d
    dec eax
    sub eax,ecx
    movss xmm1,dword ptr [rdi+rcx*4]
    movss xmm2,dword ptr [rdi+rax*4]
    movaps xmm3,xmm0
    mulss xmm3,xmm2
    addss xmm3,xmm1
    movss dword ptr [rdi+rcx*4],xmm3
    mulss xmm1,xmm0
    addss xmm1,xmm2
    movss dword ptr [rdi+rax*4],xmm1
    inc ecx
    cmp ecx,r10d
    jb ll_pairs
ll_error:
    mulss xmm0,xmm0
    mulss xmm0,xmm5
    subss xmm5,xmm0
    movss xmm1,dword ptr [rsi]
    mulss xmm1,dword ptr [lp_stop]
    comiss xmm5,xmm1
    jb ll_finish_check
    inc r9d
    cmp r9d,r8d
    jb ll_iter
ll_finish_check:
    xor ecx,ecx
ll_result_guard:
    mov eax,[rdi+rcx*4]
    and eax,7fffffffh
    cmp eax,76800000h
    ja ll_bad
    inc ecx
    cmp ecx,r8d
    jb ll_result_guard
ll_good:
    mov eax,1
    jmp ll_done
ll_bad:
    xor eax,eax
ll_done:
    pop rdi
    pop rsi
    pop rbx
    ret
op_celt_lpc ENDP

; FIR and IIR share scalar normative accumulation and delay-line order.
op_celt_fir PROC
    xor r11d,r11d
    jmp lf_entry
op_celt_fir ENDP
op_celt_iir PROC
    mov r11d,1
lf_entry::
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    mov rbx,rcx
    test rbx,rbx
    jz lf_bad
    mov rsi,[rbx+LF_X]
    mov rdi,[rbx+LF_OUT]
    mov r12,[rbx+LF_COEF]
    mov r13,[rbx+LF_MEM]
    test rsi,rsi
    jz lf_bad
    test rdi,rdi
    jz lf_bad
    test r12,r12
    jz lf_bad
    test r13,r13
    jz lf_bad
    mov r8d,[rbx+LF_N]
    test r8d,r8d
    jle lf_bad
    cmp r8d,1200
    ja lf_bad
    cmp [rbx+LF_X_CAP],r8d
    jb lf_bad
    cmp [rbx+LF_OUT_CAP],r8d
    jb lf_bad
    mov r9d,[rbx+LF_ORDER]
    test r9d,r9d
    jle lf_bad
    cmp r9d,24
    ja lf_bad
    cmp [rbx+LF_COEF_CAP],r9d
    jb lf_bad
    cmp [rbx+LF_MEM_CAP],r9d
    jb lf_bad
    xor ecx,ecx
lf_x_guard:
    mov eax,[rsi+rcx*4]
    and eax,7fffffffh
    cmp eax,58800000h
    ja lf_bad
    inc ecx
    cmp ecx,r8d
    jb lf_x_guard
    xor ecx,ecx
lf_coef_guard:
    mov eax,[r12+rcx*4]
    and eax,7fffffffh
    cmp eax,58800000h
    ja lf_bad
    mov eax,[r13+rcx*4]
    and eax,7fffffffh
    cmp eax,58800000h
    ja lf_bad
    inc ecx
    cmp ecx,r9d
    jb lf_coef_guard
    xor r10d,r10d
lf_sample:
    movss xmm0,dword ptr [rsi+r10*4]
    movaps xmm2,xmm0            ; saved input before in-place output
    xor ecx,ecx
    test r11d,r11d
    jnz lf_iir_sum
lf_fir_sum:
    movss xmm1,dword ptr [r12+rcx*4]
    mulss xmm1,dword ptr [r13+rcx*4]
    addss xmm0,xmm1
    inc ecx
    cmp ecx,r9d
    jb lf_fir_sum
    jmp lf_shift
lf_iir_sum:
    movss xmm1,dword ptr [r12+rcx*4]
    mulss xmm1,dword ptr [r13+rcx*4]
    subss xmm0,xmm1
    inc ecx
    cmp ecx,r9d
    jb lf_iir_sum
    movaps xmm2,xmm0
lf_shift:
    mov ecx,r9d
    dec ecx
    jz lf_store
lf_shift_loop:
    mov eax,[r13+rcx*4-4]
    mov [r13+rcx*4],eax
    dec ecx
    jnz lf_shift_loop
lf_store:
    movss dword ptr [r13],xmm2
    movss dword ptr [rdi+r10*4],xmm0
    inc r10d
    cmp r10d,r8d
    jb lf_sample
    mov eax,1
    jmp lf_done
lf_bad:
    xor eax,eax
lf_done:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_celt_iir ENDP
END
