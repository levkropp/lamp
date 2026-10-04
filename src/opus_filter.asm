; Handwritten CELT postfilter and deemphasis/output downsampling.
; Normative BSD RFC6716 celt.c algorithms/data, see THIRD_PARTY_NOTICES.
; Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation,
; Gregory Maxwell.
option casemap:none
include opus_filter_layout.inc
EXTERN op_celt_window:DWORD
PUBLIC op_celt_comb_filter, op_celt_deemphasis
.const
of_gains real4 0.3066406250,0.2170410156,0.1296386719
    real4 0.4638671875,0.2680664062,0.0
    real4 0.7998046875,0.1000976562,0.0
oe_coef0 real4 0.85000610
oe_one real4 1.0
oe_pcm_scale real4 0.000030517578125
.code
; Accumulate a single normative comb-filter term without reassociation.
OF_TERM MACRO base,offset,coefficient,weight
    movss xmm1,dword ptr [rsp+coefficient]
    IF weight NE 0
        mulss xmm1,dword ptr [rsp+weight]
    ENDIF
    mulss xmm1,dword ptr [base+offset]
    addss xmm0,xmm1
ENDM
; RCX=request, EAX=1/0. Output may equal X for the decoder's causal filter.
; Separate output must not overlap input. Periods15..1022, tapsets0..2,
; gains[-1,1], N1..960, overlap0..min(N,120), history<=2048 floats.
; Finite input |value|<=2^110; all public guards precede writes.
op_celt_comb_filter PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,64
    mov rbx,rcx
    test rbx,rbx
    jz of_comb_bad
    cmp qword ptr [rbx+OF_BUFFER],0
    je of_comb_bad
    mov rsi,[rbx+OF_OUT]
    test rsi,rsi
    jz of_comb_bad
    mov eax,[rbx+OF_N]
    cmp eax,1
    jb of_comb_bad
    cmp eax,960
    ja of_comb_bad
    cmp [rbx+OF_OUT_CAP],eax
    jb of_comb_bad
    mov edx,[rbx+OF_OVERLAP]
    cmp edx,120
    ja of_comb_bad
    cmp edx,eax
    ja of_comb_bad
    mov r14d,[rbx+OF_PERIOD0]
    mov r15d,[rbx+OF_PERIOD1]
    cmp r14d,15
    jb of_comb_bad
    cmp r14d,1022
    ja of_comb_bad
    cmp r15d,15
    jb of_comb_bad
    cmp r15d,1022
    ja of_comb_bad
    mov edx,r14d
    cmp edx,r15d
    cmovl edx,r15d
    add edx,2
    mov ecx,[rbx+OF_HISTORY]
    cmp ecx,edx
    jb of_comb_bad
    cmp ecx,2048
    ja of_comb_bad
    add eax,ecx
    cmp [rbx+OF_BUFFER_CAP],eax
    jb of_comb_bad
    mov r11d,eax
    cmp dword ptr [rbx+OF_TAP0],2
    ja of_comb_bad
    cmp dword ptr [rbx+OF_TAP1],2
    ja of_comb_bad
    mov eax,[rbx+OF_GAIN0]
    and eax,7fffffffh
    cmp eax,3f800000h
    ja of_comb_bad
    mov eax,[rbx+OF_GAIN1]
    and eax,7fffffffh
    cmp eax,3f800000h
    ja of_comb_bad
    mov r13,[rbx+OF_BUFFER]
    xor ecx,ecx
of_comb_guard:
    mov eax,[r13+rcx*4]
    and eax,7fffffffh
    cmp eax,76800000h
    ja of_comb_bad
    inc ecx
    cmp ecx,r11d
    jb of_comb_guard
    mov eax,[rbx+OF_HISTORY]
    lea r13,[r13+rax*4]
    lea rdi,of_gains
    mov eax,[rbx+OF_TAP0]
    imul eax,3
    movss xmm3,dword ptr [rbx+OF_GAIN0]
    movss xmm0,dword ptr [rdi+rax*4]
    mulss xmm0,xmm3
    movss dword ptr [rsp+32],xmm0
    movss xmm0,dword ptr [rdi+rax*4+4]
    mulss xmm0,xmm3
    movss dword ptr [rsp+36],xmm0
    movss xmm0,dword ptr [rdi+rax*4+8]
    mulss xmm0,xmm3
    movss dword ptr [rsp+40],xmm0
    mov eax,[rbx+OF_TAP1]
    imul eax,3
    movss xmm3,dword ptr [rbx+OF_GAIN1]
    movss xmm0,dword ptr [rdi+rax*4]
    mulss xmm0,xmm3
    movss dword ptr [rsp+44],xmm0
    movss xmm0,dword ptr [rdi+rax*4+4]
    mulss xmm0,xmm3
    movss dword ptr [rsp+48],xmm0
    movss xmm0,dword ptr [rdi+rax*4+8]
    mulss xmm0,xmm3
    movss dword ptr [rsp+52],xmm0
    lea rdi,op_celt_window
    xor r12d,r12d
of_comb_sample:
    lea r8,[r13+r12*4]
    movss xmm0,dword ptr [r8]
    mov r9,r8
    mov rax,r15
    shl rax,2
    sub r9,rax
    cmp r12d,[rbx+OF_OVERLAP]
    jae of_comb_steady
    mov rax,r14
    shl rax,2
    sub r8,rax
    movss xmm3,dword ptr [rdi+r12*4]
    mulss xmm3,xmm3
    movss dword ptr [rsp+56],xmm3
    movss xmm4,dword ptr [oe_one]
    subss xmm4,xmm3
    movss dword ptr [rsp+60],xmm4
    OF_TERM r8,0,32,60
    OF_TERM r8,-4,36,60
    OF_TERM r8,4,36,60
    OF_TERM r8,-8,40,60
    OF_TERM r8,8,40,60
    OF_TERM r9,0,44,56
    OF_TERM r9,-4,48,56
    OF_TERM r9,4,48,56
    OF_TERM r9,-8,52,56
    OF_TERM r9,8,52,56
    jmp of_comb_store
of_comb_steady:
    OF_TERM r9,0,44,0
    OF_TERM r9,-4,48,0
    OF_TERM r9,4,48,0
    OF_TERM r9,-8,52,0
    OF_TERM r9,8,52,0
of_comb_store:
    movss dword ptr [rsi+r12*4],xmm0
    inc r12d
    cmp r12d,[rbx+OF_N]
    jb of_comb_sample
    mov eax,1
    jmp of_comb_done
of_comb_bad:
    xor eax,eax
of_comb_done:
    add rsp,64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_celt_comb_filter ENDP

; RCX=request, EAX=1/0. Standard 48k CELT preemphasis coefficients.
; N=120/240/480/960, C1/2, downsample1/2/3/4/6. Memory consumes all samples;
; output stores every downsample-th sample as interleaved float PCM /32768.
op_celt_deemphasis PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    test rcx,rcx
    jz oe_bad
    mov rbx,rcx
    mov rsi,[rbx+OE_X]
    mov rdi,[rbx+OE_PCM]
    mov r13,[rbx+OE_MEM]
    test rsi,rsi
    jz oe_bad
    test rdi,rdi
    jz oe_bad
    test r13,r13
    jz oe_bad
    mov r12d,[rbx+OE_CHANNELS]
    cmp r12d,1
    jb oe_bad
    cmp r12d,2
    ja oe_bad
    cmp [rbx+OE_MEM_CAP],r12d
    jb oe_bad
    mov eax,[rbx+OE_N]
    cmp eax,120
    je oe_n_valid
    cmp eax,240
    je oe_n_valid
    cmp eax,480
    je oe_n_valid
    cmp eax,960
    jne oe_bad
oe_n_valid:
    imul eax,r12d
    cmp [rbx+OE_X_CAP],eax
    jb oe_bad
    mov r11d,eax
    mov ecx,[rbx+OE_DOWNSAMPLE]
    cmp ecx,1
    jb oe_bad
    cmp ecx,4
    jbe oe_rate_valid
    cmp ecx,6
    jne oe_bad
oe_rate_valid:
    xor edx,edx
    div ecx
    cmp [rbx+OE_PCM_CAP],eax
    jb oe_bad
    xor ecx,ecx
oe_x_guard:
    mov eax,[rsi+rcx*4]
    and eax,7fffffffh
    cmp eax,7b800000h
    ja oe_bad
    inc ecx
    cmp ecx,r11d
    jb oe_x_guard
    xor ecx,ecx
oe_mem_guard:
    mov eax,[r13+rcx*4]
    and eax,7fffffffh
    cmp eax,7b800000h
    ja oe_bad
    inc ecx
    cmp ecx,r12d
    jb oe_mem_guard
    xor r10d,r10d          ; channel index
oe_channel:
    movss xmm3,dword ptr [r13+r10*4]
    mov eax,r10d
    imul eax,[rbx+OE_N]
    lea r8,[rsi+rax*4]
    lea r9,[rdi+r10*4]
    xor ecx,ecx
    xor edx,edx
oe_sample:
    movss xmm0,dword ptr [r8+rcx*4]
    movaps xmm1,xmm0
    addss xmm0,xmm3
    movaps xmm3,xmm0
    mulss xmm3,dword ptr [oe_coef0]
    xorps xmm2,xmm2
    mulss xmm1,xmm2
    subss xmm3,xmm1
    mulss xmm0,dword ptr [oe_one]
    mulss xmm0,dword ptr [oe_pcm_scale]
    test edx,edx
    jnz oe_skip
    movss dword ptr [r9],xmm0
oe_skip:
    inc edx
    cmp edx,[rbx+OE_DOWNSAMPLE]
    jne oe_next_sample
    lea r9,[r9+r12*4]
    xor edx,edx
oe_next_sample:
    inc ecx
    cmp ecx,[rbx+OE_N]
    jb oe_sample
    movss dword ptr [r13+r10*4],xmm3
    inc r10d
    cmp r10d,r12d
    jb oe_channel
    mov eax,1
    jmp oe_done
oe_bad:
    xor eax,eax
oe_done:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_celt_deemphasis ENDP
END
