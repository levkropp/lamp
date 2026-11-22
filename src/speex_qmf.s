# Original bounded QMF synthesis, following BSD Speex 1.2.1 filters.c.
# Coefficients from sb_celp.c; see THIRD_PARTY_NOTICES. MIT + retained BSD.
.include "lamp.inc"
.include "speex_qmf.inc"
RODATA
.include "speex_high_tables.inc"
.text
# RCX=arena, EDX=capacity >=6144 ->1/0. Clears state and scratch.
FN spx_qmf_init
    test rcx, rcx
    jz .Lspxq_init_bad
    cmp edx, SPXQ_SIZE
    jb .Lspxq_init_bad
    mov rax, rcx
    add rax, SPXQ_SIZE
    jc .Lspxq_init_bad
    xor eax, eax
.Lspxq_init_zero:
    mov qword ptr [rcx+rax], 0
    add eax, 8
    cmp eax, SPXQ_SIZE
    jb .Lspxq_init_zero
    mov eax, 1
    ret
.Lspxq_init_bad:
    xor eax, eax
    ret
ENDFN spx_qmf_init

# RCX=arena, RDX=low, R8=high, R9=out, stack5=N, stack6=out capacity.
# N=4..640, multiple of4. Sources contain N/2 samples; success=1/fail=0.
# Sources/output may overlap freely. Full arena is disjoint from all I/O.
# Live history and output commit together. Scratch may change on failure.
FN spx_qmf_synth
    push rbx
    push rsi
    push rdi
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 168
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov r14, r9
    mov r12d, [rsp+272]
    cmp r12d, 4
    jb .Lspxq_bad
    cmp r12d, 640
    ja .Lspxq_bad
    test r12d, 3
    jnz .Lspxq_bad
    cmp [rsp+280], r12d
    jb .Lspxq_bad
    test rbx, rbx
    jz .Lspxq_bad
    mov rax, rbx
    add rax, SPXQ_SIZE
    jc .Lspxq_bad
    mov [rsp+96], rax
    mov [rsp+32], rsi
    mov [rsp+48], rdi
    mov [rsp+64], r14
    mov r13d, r12d
    shr r13d, 1
    lea edx, [r13*4]
    xor ecx, ecx
.Lspxq_ranges:
    mov r8, [rsp+32+rcx]
    test r8, r8
    jz .Lspxq_bad
    mov rax, r8
    add rax, rdx
    jc .Lspxq_bad
    mov [rsp+40+rcx], rax
    cmp r8, [rsp+96]
    jae .Lspxq_range_next
    cmp rbx, rax
    jb .Lspxq_bad
.Lspxq_range_next:
    add ecx, 16
    cmp ecx, 32
    jne .Lspxq_range_length
    lea edx, [r12*4]
.Lspxq_range_length:
    cmp ecx, 48
    jb .Lspxq_ranges
    xor ecx, ecx
.Lspxq_validate_memory:
    mov eax, [rbx+rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxq_bad
    inc ecx
    cmp ecx, 128
    jb .Lspxq_validate_memory
    xor ecx, ecx
.Lspxq_copy_input:
    mov eax, r13d
    sub eax, ecx
    dec eax
    mov edx, [rsi+rax*4]
    mov r8d, edx
    and r8d, 0x7fffffff
    cmp r8d, 0x7f800000
    jae .Lspxq_bad
    mov [rbx+SPXQ_LOW+rcx*4], edx
    mov edx, [rdi+rax*4]
    mov r8d, edx
    and r8d, 0x7fffffff
    cmp r8d, 0x7f800000
    jae .Lspxq_bad
    mov [rbx+SPXQ_HIGH+rcx*4], edx
    inc ecx
    cmp ecx, r13d
    jb .Lspxq_copy_input
    xor ecx, ecx
.Lspxq_copy_tail:
    lea eax, [r13+rcx]
    lea edx, [rcx*8+4]
    mov r8d, [rbx+rdx]
    mov [rbx+SPXQ_LOW+rax*4], r8d
    mov r8d, [rbx+256+rdx]
    mov [rbx+SPXQ_HIGH+rax*4], r8d
    inc ecx
    cmp ecx, 32
    jb .Lspxq_copy_tail
    xor r15d, r15d
    lea r10, [rip+spxh_qmf_h0]
.Lspxq_pair:
    pxor xmm0, xmm0
    pxor xmm1, xmm1
    pxor xmm2, xmm2
    pxor xmm3, xmm3
    xor ebp, ebp
.Lspxq_tap:
    mov eax, r13d
    add eax, ebp
    sub eax, r15d
    dec eax                            # A=N/2-1+j-i
    movss xmm4, [rbx+SPXQ_LOW+rax*4]
    subss xmm4, [rbx+SPXQ_HIGH+rax*4]
    mulss xmm4, [r10+rbp*8]
    addss xmm0, xmm4
    movss xmm4, [rbx+SPXQ_LOW+rax*4]
    addss xmm4, [rbx+SPXQ_HIGH+rax*4]
    mulss xmm4, [r10+rbp*8+4]
    addss xmm1, xmm4
    dec eax                            # B=N/2-2+j-i
    movss xmm4, [rbx+SPXQ_LOW+rax*4]
    subss xmm4, [rbx+SPXQ_HIGH+rax*4]
    mulss xmm4, [r10+rbp*8]
    addss xmm2, xmm4
    movss xmm4, [rbx+SPXQ_LOW+rax*4]
    addss xmm4, [rbx+SPXQ_HIGH+rax*4]
    mulss xmm4, [r10+rbp*8+4]
    addss xmm3, xmm4
    add eax, 2                         # C=N/2+j-i
    movss xmm4, [rbx+SPXQ_LOW+rax*4]
    subss xmm4, [rbx+SPXQ_HIGH+rax*4]
    mulss xmm4, [r10+rbp*8+8]
    addss xmm0, xmm4
    movss xmm4, [rbx+SPXQ_LOW+rax*4]
    addss xmm4, [rbx+SPXQ_HIGH+rax*4]
    mulss xmm4, [r10+rbp*8+12]
    addss xmm1, xmm4
    dec eax                            # A again
    movss xmm4, [rbx+SPXQ_LOW+rax*4]
    subss xmm4, [rbx+SPXQ_HIGH+rax*4]
    mulss xmm4, [r10+rbp*8+8]
    addss xmm2, xmm4
    movss xmm4, [rbx+SPXQ_LOW+rax*4]
    addss xmm4, [rbx+SPXQ_HIGH+rax*4]
    mulss xmm4, [r10+rbp*8+12]
    addss xmm3, xmm4
    add ebp, 2
    cmp ebp, 32
    jb .Lspxq_tap
    addss xmm0, xmm0
    addss xmm1, xmm1
    addss xmm2, xmm2
    addss xmm3, xmm3
    movss [rbx+SPXQ_OUT+r15*8], xmm0
    movss [rbx+SPXQ_OUT+r15*8+4], xmm1
    movss [rbx+SPXQ_OUT+r15*8+8], xmm2
    movss [rbx+SPXQ_OUT+r15*8+12], xmm3
    add r15d, 2
    cmp r15d, r13d
    jb .Lspxq_pair
    xor ecx, ecx
.Lspxq_validate_result:
    mov eax, [rbx+SPXQ_OUT+rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxq_bad
    inc ecx
    cmp ecx, r12d
    jb .Lspxq_validate_result
    xor ecx, ecx
.Lspxq_commit_memory:
    mov eax, [rbx+SPXQ_LOW+rcx*4]
    mov [rbx+rcx*8+4], eax
    mov eax, [rbx+SPXQ_HIGH+rcx*4]
    mov [rbx+rcx*8+260], eax
    inc ecx
    cmp ecx, 32
    jb .Lspxq_commit_memory
    xor ecx, ecx
.Lspxq_commit_output:
    mov eax, [rbx+SPXQ_OUT+rcx*4]
    mov [r14+rcx*4], eax
    inc ecx
    cmp ecx, r12d
    jb .Lspxq_commit_output
    mov eax, 1
    jmp .Lspxq_return
.Lspxq_bad:
    xor eax, eax
.Lspxq_return:
    add rsp, 168
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN spx_qmf_synth
