# Handwritten SSE2 inverse mixed-radix CELT FFT (60/120/240/480 complex).
# BSD normative RFC6716 kiss_fft.c butterfly algorithms and mode data.
# Copyright (c) 2003-2012 IETF Trust, Mark Borgerding, Jean-Marc Valin,
# Xiph.Org Foundation, CSIRO. See THIRD_PARTY_NOTICES.
.include "lamp.inc"
RODATA
.include "opus_fft_tables.inc"
.p2align 4
of_neg_real: .long 0x80000000, 0, 0, 0
of_neg_imag: .long 0, 0x80000000, 0, 0
of_half: .float 0.5, 0.5, 0.5, 0.5
.text
# Scratch holds complex pairs. Packed arithmetic preserves reference order
# independently for real/imaginary lanes, without fused multiply-add.
.macro OF_LOAD index
    movq xmm0, qword ptr [rsp + 32 + \index*8]
.endm
.macro OF_STORE index
    movq qword ptr [rsp + 32 + \index*8], xmm0
.endm
.macro OF_ADD a, b, dest
    OF_LOAD \a
    movq xmm1, qword ptr [rsp + 32 + \b*8]
    addps xmm0, xmm1
    OF_STORE \dest
.endm
.macro OF_SUB a, b, dest
    OF_LOAD \a
    movq xmm1, qword ptr [rsp + 32 + \b*8]
    subps xmm0, xmm1
    OF_STORE \dest
.endm
# Multiply Fout[k*m] by the conjugate of its stage twiddle.
.macro OF_MULC k, dest
    mov rax, r12
    imul rax, \k
    movq xmm0, qword ptr [rsi + rax]
    mov eax, ebx
    imul eax, dword ptr [r14 + 16]
    imul eax, \k
    movss xmm1, dword ptr [rdi + rax*8]
    shufps xmm1, xmm1, 0
    mulps xmm1, xmm0
    movss xmm2, dword ptr [rdi + rax*8 + 4]
    shufps xmm2, xmm2, 0
    shufps xmm0, xmm0, 0xb1
    mulps xmm0, xmm2
    xorps xmm0, xmmword ptr [rip + of_neg_imag]
    addps xmm0, xmm1
    OF_STORE \dest
.endm
.macro OF_OUTPUT k, src
    OF_LOAD \src
    mov rax, r12
    imul rax, \k
    movq qword ptr [rsi + rax], xmm0
.endm
# RCX=in, RDX=out, R8D=LM0..3. Arrays hold 60*2^LM complex pairs.
# EAX=1/0. Nonoverlapping buffers; finite inputs have magnitude <=2^110.
# Guards precede all writes. Unscaled inverse transform, no heap/static scratch.
FN op_celt_ifft
    test rcx, rcx
    jz .Lof_public_bad
    test rdx, rdx
    jz .Lof_public_bad
    cmp rcx, rdx
    je .Lof_public_bad
    cmp r8d, 3
    ja .Lof_public_bad
    mov r9, rcx
    mov ecx, r8d
    mov r10d, 60
    shl r10d, cl
    mov rcx, r9
    lea r11d, [r10 + r10]
    xor eax, eax
.Lof_guard:
    mov r9d, [rcx + rax*4]
    and r9d, 0x7fffffff
    cmp r9d, 0x76800000
    ja .Lof_public_bad
    inc eax
    cmp eax, r11d
    jb .Lof_guard
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 144
    mov r13, rdx
    lea rax, [rip + of_bitrev_ptrs]
    mov r11, [rax + r8*8]
    lea rax, [rip + of_stage_ptrs]
    mov r14, [rax + r8*8]
    xor eax, eax
.Lof_bitrev:
    movzx edx, word ptr [r11 + rax*2]
    mov r9, [rcx + rax*8]
    mov [r13 + rdx*8], r9
    inc eax
    cmp eax, r10d
    jb .Lof_bitrev
    lea rdi, [rip + of_twiddles]
.Lof_stage:
    cmp dword ptr [r14], 0
    je .Lof_good
    mov r12d, [r14 + 4]
    shl r12, 3              # bytes between butterfly arms
    xor r15d, r15d
.Lof_group:
    mov eax, r15d
    imul eax, dword ptr [r14 + 12]
    lea rsi, [r13 + rax*8]
    xor ebx, ebx
.Lof_butterfly:
    movq xmm0, qword ptr [rsi]
    OF_STORE 0
    OF_MULC 1, 1
    cmp dword ptr [r14], 2
    je .Lof_radix2
    OF_MULC 2, 2
    cmp dword ptr [r14], 3
    je .Lof_radix3
    OF_MULC 3, 3
    cmp dword ptr [r14], 4
    je .Lof_radix4
    OF_MULC 4, 4
    # Radix five, preserving the normative pair sums and accumulation order.
    OF_ADD 1, 4, 7
    OF_SUB 1, 4, 10
    OF_ADD 2, 3, 8
    OF_SUB 2, 3, 9
    OF_ADD 7, 8, 11
    OF_ADD 0, 11, 11
    OF_OUTPUT 0, 11
    mov eax, [r14 + 20]
    movss xmm4, dword ptr [rdi + rax*8]
    shufps xmm4, xmm4, 0
    mov eax, [r14 + 24]
    movss xmm5, dword ptr [rdi + rax*8]
    shufps xmm5, xmm5, 0
    OF_LOAD 7
    mulps xmm0, xmm4
    movq xmm1, qword ptr [rsp + 32]
    addps xmm0, xmm1
    movq xmm1, qword ptr [rsp + 32 + 8*8]
    mulps xmm1, xmm5
    addps xmm0, xmm1
    OF_STORE 5
    OF_LOAD 7
    mulps xmm0, xmm5
    movq xmm1, qword ptr [rsp + 32]
    addps xmm0, xmm1
    movq xmm1, qword ptr [rsp + 32 + 8*8]
    mulps xmm1, xmm4
    addps xmm0, xmm1
    OF_STORE 11
    mov eax, [r14 + 20]
    movss xmm4, dword ptr [rdi + rax*8 + 4]
    shufps xmm4, xmm4, 0
    mov eax, [r14 + 24]
    movss xmm5, dword ptr [rdi + rax*8 + 4]
    shufps xmm5, xmm5, 0
    OF_LOAD 10
    shufps xmm0, xmm0, 0xb1
    mulps xmm0, xmm4
    xorps xmm0, xmmword ptr [rip + of_neg_real]
    movq xmm1, qword ptr [rsp + 32 + 9*8]
    shufps xmm1, xmm1, 0xb1
    mulps xmm1, xmm5
    xorps xmm1, xmmword ptr [rip + of_neg_real]
    addps xmm0, xmm1
    OF_STORE 6
    OF_LOAD 10
    shufps xmm0, xmm0, 0xb1
    mulps xmm0, xmm5
    xorps xmm0, xmmword ptr [rip + of_neg_imag]
    movq xmm1, qword ptr [rsp + 32 + 9*8]
    shufps xmm1, xmm1, 0xb1
    mulps xmm1, xmm4
    xorps xmm1, xmmword ptr [rip + of_neg_real]
    addps xmm0, xmm1
    OF_STORE 12
    OF_SUB 5, 6, 1
    OF_ADD 5, 6, 4
    OF_ADD 11, 12, 2
    OF_SUB 11, 12, 3
    OF_OUTPUT 1, 1
    OF_OUTPUT 2, 2
    OF_OUTPUT 3, 3
    OF_OUTPUT 4, 4
    jmp .Lof_next
.Lof_radix2:
    OF_SUB 0, 1, 2
    OF_ADD 0, 1, 0
    OF_OUTPUT 0, 0
    OF_OUTPUT 1, 2
    jmp .Lof_next
.Lof_radix3:
    OF_ADD 1, 2, 3
    OF_SUB 1, 2, 4
    OF_LOAD 3
    mulps xmm0, xmmword ptr [rip + of_half]
    movq xmm1, qword ptr [rsp + 32]
    subps xmm1, xmm0
    movq qword ptr [rsp + 32 + 5*8], xmm1
    OF_ADD 0, 3, 0
    mov eax, [r14 + 20]
    movss xmm1, dword ptr [rdi + rax*8 + 4]
    movd eax, xmm1
    xor eax, 0x80000000
    movd xmm1, eax
    shufps xmm1, xmm1, 0
    OF_LOAD 4
    mulps xmm0, xmm1
    shufps xmm0, xmm0, 0xb1
    xorps xmm0, xmmword ptr [rip + of_neg_imag]
    OF_STORE 4
    OF_ADD 5, 4, 2
    OF_SUB 5, 4, 1
    OF_OUTPUT 0, 0
    OF_OUTPUT 1, 1
    OF_OUTPUT 2, 2
    jmp .Lof_next
.Lof_radix4:
    OF_SUB 0, 2, 5
    OF_ADD 0, 2, 0
    OF_ADD 1, 3, 4
    OF_SUB 1, 3, 1
    OF_SUB 0, 4, 2
    OF_ADD 0, 4, 0
    OF_LOAD 1
    shufps xmm0, xmm0, 0xb1
    xorps xmm0, xmmword ptr [rip + of_neg_imag]
    OF_STORE 1
    OF_ADD 5, 1, 3
    OF_SUB 5, 1, 1
    OF_OUTPUT 0, 0
    OF_OUTPUT 1, 1
    OF_OUTPUT 2, 2
    OF_OUTPUT 3, 3
.Lof_next:
    add rsi, 8
    inc ebx
    cmp ebx, [r14 + 4]
    jb .Lof_butterfly
    inc r15d
    cmp r15d, [r14 + 8]
    jb .Lof_group
    add r14, 32
    jmp .Lof_stage
.Lof_good:
    mov eax, 1
    add rsp, 144
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.Lof_public_bad:
    xor eax, eax
    ret
ENDFN op_celt_ifft
