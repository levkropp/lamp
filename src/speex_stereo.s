# Original bounded intensity-stereo reconstruction. MIT + retained BSD.
# Speex 1.2.1 stereo.c, Copyright (C) 2002 Jean-Marc Valin; see notices.
.include "lamp.inc"
.include "speex_stereo.inc"
RODATA
.include "speex_stereo_tables.inc"
.p2align 3
spxs_one64: .double 1.
spxs_point98: .float .98
spxs_point02: .float .02
spxs_one: .float 1.
spxs_half: .float .5
spxs_ratios: .float .25, .315, .397, .5
.text
# RCX=arena, EDX=bytes>=6144 ->1/0. Clear state and scratch after validation.
FN spx_stereo_init
    test rcx, rcx
    jz .Lspxs_init_bad
    cmp edx, SPXS_SIZE
    jb .Lspxs_init_bad
    mov rax, rcx
    add rax, SPXS_SIZE
    jc .Lspxs_init_bad
    xor eax, eax
.Lspxs_init_zero:
    mov qword ptr [rcx+rax], 0
    add eax, 8
    cmp eax, SPXS_SIZE
    jb .Lspxs_init_zero
    mov eax, [rip+spxs_one]
    mov [rcx+SPXS_BALANCE], eax
    mov [rcx+SPXS_LEFT], eax
    mov [rcx+SPXS_RIGHT], eax
    mov eax, [rip+spxs_half]
    mov [rcx+SPXS_RATIO], eax
    mov eax, 1
    ret
.Lspxs_init_bad:
    xor eax, eax
    ret
ENDFN spx_stereo_init

# RCX=24-byte live stereo state, EDX=complete 8-bit in-band control ->1/0.
FN spx_stereo_control
    test rcx, rcx
    jz .Lspxs_control_bad
    cmp edx, 255
    ja .Lspxs_control_bad
    mov rax, rcx
    add rax, SPXS_LIVE
    jc .Lspxs_control_bad
    mov eax, edx
    shr eax, 2
    lea r8, [rip+spxs_balance]
    mov eax, [r8+rax*4]
    and edx, 3
    lea r8, [rip+spxs_ratios]
    mov edx, [r8+rdx*4]
    mov [rcx+SPXS_BALANCE], eax
    mov [rcx+SPXS_RATIO], edx
    mov eax, 1
    ret
.Lspxs_control_bad:
    xor eax, eax
    ret
ENDFN spx_stereo_control

# RCX=arena, RDX=mono, R8=interleaved output, R9D=frames1..640,
# stack5=capacity in floats >=2*frames. Returns frames/0.
# Input/output may overlap; full arena is disjoint from both. Output and
# the live 24-byte stereo state commit together. Scratch can change on error.
FN spx_stereo_apply
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 96
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov r12d, r9d
    test r12d, r12d
    jz .Lspxs_bad
    cmp r12d, 640
    ja .Lspxs_bad
    lea eax, [r12*2]
    cmp [rsp+176], eax
    jb .Lspxs_bad
    test rbx, rbx
    jz .Lspxs_bad
    test rsi, rsi
    jz .Lspxs_bad
    test rdi, rdi
    jz .Lspxs_bad
    mov rax, rbx
    add rax, SPXS_SIZE
    jc .Lspxs_bad
    lea rdx, [r12*4]
    add rdx, rsi
    jc .Lspxs_bad
    cmp rsi, rax
    jae .Lspxs_mono_separate
    cmp rbx, rdx
    jb .Lspxs_bad
.Lspxs_mono_separate:
    lea rdx, [r12*8]
    add rdx, rdi
    jc .Lspxs_bad
    cmp rdi, rax
    jae .Lspxs_output_separate
    cmp rbx, rdx
    jb .Lspxs_bad
.Lspxs_output_separate:
    xor ecx, ecx
.Lspxs_validate_state:
    mov eax, [rbx+rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxs_bad
    inc ecx
    cmp ecx, 4
    jb .Lspxs_validate_state
    pxor xmm0, xmm0
    ucomiss xmm0, [rbx+SPXS_BALANCE]
    jae .Lspxs_bad
    ucomiss xmm0, [rbx+SPXS_RATIO]
    jae .Lspxs_bad
    # Inner response/sqrt uses double. DIV32 and MULT16_16 explicitly cast
    # their operands back to float before division/multiplication.
    movss xmm0, [rbx+SPXS_BALANCE]
    cvtss2sd xmm0, xmm0
    movaps xmm1, xmm0
    addsd xmm1, [rip+spxs_one64]
    movss xmm2, [rbx+SPXS_RATIO]
    cvtss2sd xmm2, xmm2
    mulsd xmm1, xmm2
    sqrtsd xmm1, xmm1
    cvtsd2ss xmm1, xmm1
    movss xmm2, [rip+spxs_one]
    divss xmm2, xmm1                 # float e_right
    movss [rsp+32], xmm2
    sqrtsd xmm0, xmm0
    cvtsd2ss xmm0, xmm0
    mulss xmm0, xmm2                 # float e_left
    movss [rsp+36], xmm0
    movss xmm0, [rbx+SPXS_LEFT]
    movss xmm1, [rbx+SPXS_RIGHT]
    mov r13d, r12d
.Lspxs_frame:
    dec r13d                        # reference smoothing runs backwards
    mov eax, [rsi+r13*4]
    mov edx, eax
    and edx, 0x7fffffff
    cmp edx, 0x7f800000
    jae .Lspxs_bad
    movd xmm4, eax
    mulss xmm0, [rip+spxs_point98]
    movss xmm2, [rsp+36]
    mulss xmm2, [rip+spxs_point02]
    addss xmm0, xmm2
    mulss xmm1, [rip+spxs_point98]
    movss xmm2, [rsp+32]
    mulss xmm2, [rip+spxs_point02]
    addss xmm1, xmm2
    movaps xmm2, xmm0
    mulss xmm2, xmm4
    movaps xmm3, xmm1
    mulss xmm3, xmm4
    movd eax, xmm2
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxs_bad
    movd eax, xmm3
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxs_bad
    movss [rbx+SPXS_OUT+r13*8], xmm2
    movss [rbx+SPXS_OUT+r13*8+4], xmm3
    test r13d, r13d
    jnz .Lspxs_frame
    movd eax, xmm0
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxs_bad
    movd eax, xmm1
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxs_bad
    movss [rbx+SPXS_LEFT], xmm0
    movss [rbx+SPXS_RIGHT], xmm1
    lea edx, [r12*2]
    xor ecx, ecx
.Lspxs_commit:
    mov eax, [rbx+SPXS_OUT+rcx*4]
    mov [rdi+rcx*4], eax
    inc ecx
    cmp ecx, edx
    jb .Lspxs_commit
    mov eax, r12d
    jmp .Lspxs_return
.Lspxs_bad:
    xor eax, eax
.Lspxs_return:
    add rsp, 96
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN spx_stereo_apply
