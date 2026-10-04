; Fixed-point SILK synthesis dependencies: division and LPC rewhitening.
; RFC6716 Inlines.h,LPC_analysis_filter.c. Copyright(c)2006-2012 IETF
; Trust and Skype Limited. BSD conditions in THIRD_PARTY_NOTICES.
option casemap:none
include opus_silk_prediction_layout.inc
PUBLIC op_silk_div32,op_silk_analysis_filter
.code
; ECX=numerator,EDX=nonzero denominator,R8D=Q0..30. INT_MIN inputs reject0.
op_silk_div32 PROC
    push rbx
    push rsi
    test edx,edx
    jz sp_div_bad
    cmp edx,80000000h
    je sp_div_bad
    cmp ecx,80000000h
    je sp_div_bad
    cmp r8d,30
    ja sp_div_bad
    test ecx,ecx
    jz sp_div_bad
    mov r11d,r8d
    mov r9d,ecx
    mov ebx,edx
    mov eax,ecx
    cdq
    xor eax,edx
    sub eax,edx
    bsr eax,eax
    mov r8d,30
    sub r8d,eax               ; numerator headroom
    mov ecx,r8d
    shl r9d,cl
    mov eax,ebx
    cdq
    xor eax,edx
    sub eax,edx
    bsr eax,eax
    mov r10d,30
    sub r10d,eax              ; denominator headroom
    mov ecx,r10d
    shl ebx,cl
    mov ecx,ebx
    sar ecx,16
    mov eax,536870911
    cdq
    idiv ecx
    mov esi,eax               ; reciprocal seed
    movsxd rax,r9d
    movsx rdx,si
    imul rax,rdx
    sar rax,16
    mov ecx,eax               ; first approximation
    movsxd rax,ebx
    movsxd rdx,ecx
    imul rax,rdx
    sar rax,32
    shl eax,3
    sub r9d,eax               ; normalized residual,wrapped
    movsxd rax,r9d
    movsx rdx,si
    imul rax,rdx
    sar rax,16
    add eax,ecx
    mov ecx,29
    add ecx,r8d
    sub ecx,r10d
    sub ecx,r11d
    js sp_div_left
    cmp ecx,32
    jae sp_div_bad
    sar eax,cl
    jmp sp_div_done
sp_div_left:
    neg ecx
    mov edx,7fffffffh
    sar edx,cl
    cmp eax,edx
    cmovg eax,edx
    mov edx,80000000h
    sar edx,cl
    cmp eax,edx
    cmovl eax,edx
    shl eax,cl
    jmp sp_div_done
sp_div_bad:
    xor eax,eax
sp_div_done:
    pop rsi
    pop rbx
    ret
op_silk_div32 ENDP

op_silk_analysis_filter PROC
    push rbx
    push rsi
    push rdi
    push r12
    test rcx,rcx
    jz sp_analysis_bad
    mov rdi,[rcx+SF_OUT]
    mov rsi,[rcx+SF_IN]
    mov rbx,[rcx+SF_COEF]
    test rdi,rdi
    jz sp_analysis_bad
    test rsi,rsi
    jz sp_analysis_bad
    test rbx,rbx
    jz sp_analysis_bad
    mov r12d,[rcx+SF_ORDER]
    cmp r12d,6
    jl sp_analysis_bad
    cmp r12d,16
    ja sp_analysis_bad
    test r12d,1
    jnz sp_analysis_bad
    mov r11d,[rcx+SF_N]
    cmp r11d,r12d
    jl sp_analysis_bad
    cmp r11d,480
    ja sp_analysis_bad
    cmp [rcx+SF_OUT_CAP],r11d
    jb sp_analysis_bad
    cmp [rcx+SF_IN_CAP],r11d
    jb sp_analysis_bad
    cmp [rcx+SF_COEF_CAP],r12d
    jb sp_analysis_bad
    mov r8d,r12d
    cmp r8d,r11d
    je sp_analysis_zero
sp_analysis_sample:
    xor r9d,r9d
    xor ecx,ecx
sp_analysis_prediction:
    mov edx,r8d
    sub edx,ecx
    dec edx
    movsx eax,word ptr [rsi+rdx*2]
    movsx edx,word ptr [rbx+rcx*2]
    imul eax,edx
    add r9d,eax               ; intentional normative wrap
    inc ecx
    cmp ecx,r12d
    jb sp_analysis_prediction
    movsx eax,word ptr [rsi+r8*2]
    shl eax,12
    sub eax,r9d
    sar eax,11
    inc eax
    sar eax,1
    mov edx,32767
    cmp eax,edx
    cmovg eax,edx
    mov edx,-32768
    cmp eax,edx
    cmovl eax,edx
    mov [rdi+r8*2],ax
    inc r8d
    cmp r8d,r11d
    jb sp_analysis_sample
sp_analysis_zero:
    xor ecx,ecx
sp_analysis_clear:
    mov word ptr [rdi+rcx*2],0
    inc ecx
    cmp ecx,r12d
    jb sp_analysis_clear
    mov eax,1
    jmp sp_analysis_done
sp_analysis_bad:
    xor eax,eax
sp_analysis_done:
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_silk_analysis_filter ENDP
END
