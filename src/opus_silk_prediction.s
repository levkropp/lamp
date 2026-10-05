# Fixed-point SILK synthesis dependencies: division and LPC rewhitening.
# RFC6716 Inlines.h,LPC_analysis_filter.c. Copyright(c)2006-2012 IETF
# Trust and Skype Limited. BSD conditions in THIRD_PARTY_NOTICES.
.include "lamp.inc"
.include "opus_silk_prediction_layout.inc"
.text
# ECX=numerator,EDX=nonzero denominator,R8D=Q0..30. INT_MIN inputs reject0.
FN op_silk_div32
    push rbx
    push rsi
    test edx, edx
    jz .Lsp_div_bad
    cmp edx, 0x80000000
    je .Lsp_div_bad
    cmp ecx, 0x80000000
    je .Lsp_div_bad
    cmp r8d, 30
    ja .Lsp_div_bad
    test ecx, ecx
    jz .Lsp_div_bad
    mov r11d, r8d
    mov r9d, ecx
    mov ebx, edx
    mov eax, ecx
    cdq
    xor eax, edx
    sub eax, edx
    bsr eax, eax
    mov r8d, 30
    sub r8d, eax               # numerator headroom
    mov ecx, r8d
    shl r9d, cl
    mov eax, ebx
    cdq
    xor eax, edx
    sub eax, edx
    bsr eax, eax
    mov r10d, 30
    sub r10d, eax              # denominator headroom
    mov ecx, r10d
    shl ebx, cl
    mov ecx, ebx
    sar ecx, 16
    mov eax, 536870911
    cdq
    idiv ecx
    mov esi, eax               # reciprocal seed
    movsxd rax, r9d
    movsx rdx, si
    imul rax, rdx
    sar rax, 16
    mov ecx, eax               # first approximation
    movsxd rax, ebx
    movsxd rdx, ecx
    imul rax, rdx
    sar rax, 32
    shl eax, 3
    sub r9d, eax               # normalized residual,wrapped
    movsxd rax, r9d
    movsx rdx, si
    imul rax, rdx
    sar rax, 16
    add eax, ecx
    mov ecx, 29
    add ecx, r8d
    sub ecx, r10d
    sub ecx, r11d
    js .Lsp_div_left
    cmp ecx, 32
    jae .Lsp_div_bad
    sar eax, cl
    jmp .Lsp_div_done
.Lsp_div_left:
    neg ecx
    mov edx, 0x7fffffff
    sar edx, cl
    cmp eax, edx
    cmovg eax, edx
    mov edx, 0x80000000
    sar edx, cl
    cmp eax, edx
    cmovl eax, edx
    shl eax, cl
    jmp .Lsp_div_done
.Lsp_div_bad:
    xor eax, eax
.Lsp_div_done:
    pop rsi
    pop rbx
    ret
ENDFN op_silk_div32

FN op_silk_analysis_filter
    push rbx
    push rsi
    push rdi
    push r12
    test rcx, rcx
    jz .Lsp_analysis_bad
    mov rdi, [rcx + SF_OUT]
    mov rsi, [rcx + SF_IN]
    mov rbx, [rcx + SF_COEF]
    test rdi, rdi
    jz .Lsp_analysis_bad
    test rsi, rsi
    jz .Lsp_analysis_bad
    test rbx, rbx
    jz .Lsp_analysis_bad
    mov r12d, [rcx + SF_ORDER]
    cmp r12d, 6
    jl .Lsp_analysis_bad
    cmp r12d, 16
    ja .Lsp_analysis_bad
    test r12d, 1
    jnz .Lsp_analysis_bad
    mov r11d, [rcx + SF_N]
    cmp r11d, r12d
    jl .Lsp_analysis_bad
    cmp r11d, 480
    ja .Lsp_analysis_bad
    cmp [rcx + SF_OUT_CAP], r11d
    jb .Lsp_analysis_bad
    cmp [rcx + SF_IN_CAP], r11d
    jb .Lsp_analysis_bad
    cmp [rcx + SF_COEF_CAP], r12d
    jb .Lsp_analysis_bad
    mov r8d, r12d
    cmp r8d, r11d
    je .Lsp_analysis_zero
.Lsp_analysis_sample:
    xor r9d, r9d
    xor ecx, ecx
.Lsp_analysis_prediction:
    mov edx, r8d
    sub edx, ecx
    dec edx
    movsx eax, word ptr [rsi + rdx*2]
    movsx edx, word ptr [rbx + rcx*2]
    imul eax, edx
    add r9d, eax               # intentional normative wrap
    inc ecx
    cmp ecx, r12d
    jb .Lsp_analysis_prediction
    movsx eax, word ptr [rsi + r8*2]
    shl eax, 12
    sub eax, r9d
    sar eax, 11
    inc eax
    sar eax, 1
    mov edx, 32767
    cmp eax, edx
    cmovg eax, edx
    mov edx, -32768
    cmp eax, edx
    cmovl eax, edx
    mov [rdi + r8*2], ax
    inc r8d
    cmp r8d, r11d
    jb .Lsp_analysis_sample
.Lsp_analysis_zero:
    xor ecx, ecx
.Lsp_analysis_clear:
    mov word ptr [rdi + rcx*2], 0
    inc ecx
    cmp ecx, r12d
    jb .Lsp_analysis_clear
    mov eax, 1
    jmp .Lsp_analysis_done
.Lsp_analysis_bad:
    xor eax, eax
.Lsp_analysis_done:
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_analysis_filter
