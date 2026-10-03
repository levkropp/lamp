; Original FFT-based inverse MDCT, x86-64 SSE2. MIT.
; FFT is positive-sign and unnormalised. Coefficients follow Vorbis convention.
option casemap:none
PUBLIC vb_transform_init, vb_imdct, vb_windows
.data
vt_pi real8 3.1415926535897931
vt_half real8 0.5
vt_four real8 4.0
vt_two real8 2.0
vt_tmp real8 0.0
vt_n dd 0
.const
ALIGN 16
vt_neg_real dq 8000000000000000h,0
.data?
ALIGN 16
vb_windows real8 16384 dup (?)
vt_pre real8 32768 dup (?)
vt_post real8 32768 dup (?)
vt_twiddle real8 32768 dup (?)
vt_fft real8 16384 dup (?)
.code
; ECX=short N, EDX=long N. Initialises two table sets of 8192 entries.
vb_transform_init PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    mov r12d,ecx
    mov r13d,edx
    xor ebx,ebx
vt_init_set:
    mov [vt_n],r12d
    mov esi,ebx
    shl esi,17
    lea r8,vt_pre
    add r8,rsi
    lea r9,vt_post
    add r9,rsi
    lea r10,vt_twiddle
    add r10,rsi
    shl ebx,16
    lea r11,vb_windows
    add r11,rbx
    shr ebx,16
    xor edi,edi
vt_init_entry:
    ; exp(i*(pi/2+pi/N)*k)
    mov [vt_tmp],rdi
    fild qword ptr [vt_tmp]
    fld qword ptr [vt_pi]
    fild dword ptr [vt_n]
    fdivp st(1),st(0)
    fld qword ptr [vt_pi]
    fmul qword ptr [vt_half]
    faddp st(1),st(0)
    fmulp st(1),st(0)
    fsincos
    mov eax,edi
    shl eax,4
    fstp qword ptr [r8+rax]
    fstp qword ptr [r8+rax+8]
    ; post exp(i*pi/N*(k+.5+N/4))
    mov [vt_tmp],rdi
    fild qword ptr [vt_tmp]
    fadd qword ptr [vt_half]
    fild dword ptr [vt_n]
    fdiv qword ptr [vt_four]
    faddp st(1),st(0)
    fmul qword ptr [vt_pi]
    fild dword ptr [vt_n]
    fdivp st(1),st(0)
    fsincos
    fstp qword ptr [r9+rax]
    fstp qword ptr [r9+rax+8]
    ; FFT twiddle exp(i*2*pi*k/N)
    mov [vt_tmp],rdi
    fild qword ptr [vt_tmp]
    fmul qword ptr [vt_pi]
    fmul qword ptr [vt_two]
    fild dword ptr [vt_n]
    fdivp st(1),st(0)
    fsincos
    fstp qword ptr [r10+rax]
    fstp qword ptr [r10+rax+8]
    ; sin(pi/2 * sin(pi*(k+.5)/N)^2), half window
    mov [vt_tmp],rdi
    fild qword ptr [vt_tmp]
    fadd qword ptr [vt_half]
    fmul qword ptr [vt_pi]
    fild dword ptr [vt_n]
    fdivp st(1),st(0)
    fsin
    fmul st(0),st(0)
    fmul qword ptr [vt_pi]
    fmul qword ptr [vt_half]
    fsin
    fstp qword ptr [r11+rdi*8]
    inc edi
    cmp edi,r12d
    jb vt_init_entry
    test ebx,ebx
    jnz vt_init_done
    inc ebx
    mov r12d,r13d
    jmp vt_init_set
vt_init_done:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
vb_transform_init ENDP

; RCX=float coefficients, RDX=float output, R8D=N, R9D=table set (0/1).
vb_imdct PROC
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov r12,rcx
    mov r13,rdx
    mov r14d,r8d
    mov eax,r9d
    shl eax,17
    lea r15,vt_twiddle
    add r15,rax
    lea rsi,vt_pre
    add rsi,rax
    lea rdi,vt_post
    add rdi,rax
    lea rbx,vt_fft
    xor r10d,r10d
    mov r11d,r14d
    shr r11d,1
vt_fill:
    pxor xmm0,xmm0
    cmp r10d,r11d
    jae vt_fill_zero
    cvtss2sd xmm0,dword ptr [r12+r10*4]
vt_fill_zero:
    mov eax,r10d
    shl eax,4
    movsd xmm1,qword ptr [rsi+rax]
    mulsd xmm1,xmm0
    movsd qword ptr [rbx+rax],xmm1
    mulsd xmm0,qword ptr [rsi+rax+8]
    movsd qword ptr [rbx+rax+8],xmm0
    inc r10d
    cmp r10d,r14d
    jb vt_fill
    ; Iterative bit reversal.
    xor r10d,r10d
    xor r11d,r11d
vt_reverse:
    cmp r10d,r11d
    jae vt_reverse_next
    mov eax,r10d
    shl eax,4
    mov edx,r11d
    shl edx,4
    movupd xmm0,[rbx+rax]
    movupd xmm1,[rbx+rdx]
    movupd [rbx+rax],xmm1
    movupd [rbx+rdx],xmm0
vt_reverse_next:
    mov edx,r14d
    shr edx,1
vt_reverse_carry:
    test r11d,edx
    jz vt_reverse_set
    xor r11d,edx
    shr edx,1
    jnz vt_reverse_carry
vt_reverse_set:
    xor r11d,edx
    inc r10d
    cmp r10d,r14d
    jb vt_reverse
    mov r8d,2
vt_stage:
    mov r9d,r8d
    shr r9d,1
    mov eax,r14d
    xor edx,edx
    div r8d
    mov r11d,eax             ; twiddle step
    xor r10d,r10d           ; block
vt_block:
    xor ecx,ecx
    xor edx,edx             ; twiddle index
vt_butterfly:
    mov eax,r10d
    add eax,ecx
    shl eax,4
    lea rsi,[rbx+rax]
    mov eax,r9d
    shl eax,4
    add rax,rsi
    movupd xmm0,[rax]
    movapd xmm1,xmm0
    shufpd xmm1,xmm1,1
    mov ebp,edx
    shl ebp,4
    movupd xmm2,[r15+rbp]
    movapd xmm3,xmm2
    unpcklpd xmm2,xmm2
    unpckhpd xmm3,xmm3
    mulpd xmm0,xmm2
    mulpd xmm1,xmm3
    xorpd xmm1,[vt_neg_real]
    addpd xmm0,xmm1
    movupd xmm4,[rsi]
    movapd xmm5,xmm4
    addpd xmm4,xmm0
    subpd xmm5,xmm0
    movupd [rsi],xmm4
    movupd [rax],xmm5
    add edx,r11d
    inc ecx
    cmp ecx,r9d
    jb vt_butterfly
    add r10d,r8d
    cmp r10d,r14d
    jb vt_block
    shl r8d,1
    cmp r8d,r14d
    jbe vt_stage
    xor ecx,ecx
vt_output:
    mov eax,ecx
    shl eax,4
    movsd xmm0,qword ptr [rbx+rax]
    mulsd xmm0,qword ptr [rdi+rax]
    movsd xmm1,qword ptr [rbx+rax+8]
    mulsd xmm1,qword ptr [rdi+rax+8]
    subsd xmm0,xmm1
    cvtsd2ss xmm0,xmm0
    movss dword ptr [r13+rcx*4],xmm0
    inc ecx
    cmp ecx,r14d
    jb vt_output
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
vb_imdct ENDP
END
