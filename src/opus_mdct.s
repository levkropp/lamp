# Handwritten CELT inverse MDCT and long/short overlap synthesis.
# Normative BSD RFC6716 mdct.c/celt.c algorithms and mode data.
# Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation,
# Gregory Maxwell.
# See THIRD_PARTY_NOTICES. Caller-owned scratch; no heap, CRT or libm.
.include "lamp.inc"
.include "opus_mdct_layout.inc"
.globl op_celt_window
RODATA
op_celt_window:
.include "opus_mdct_tables.inc"
.p2align 4
om_negative: .long 0x80000000, 0, 0, 0
.text
# RCX=request. EAX=1/0. S=120*2^LM coefficients with stride1/2/4/8.
# Output is S+120 floats; its first 120 floats contain prior overlap.
# Scratch is 2*S floats. Nonoverlapping buffers, checked capacities/values.
FN op_celt_imdct
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rbx, rcx
    test rbx, rbx
    jz .Lom_bad
    mov rsi, [rbx + OM_IN]
    mov rdi, [rbx + OM_OUT]
    mov r12, [rbx + OM_SCRATCH]
    test rsi, rsi
    jz .Lom_bad
    test rdi, rdi
    jz .Lom_bad
    test r12, r12
    jz .Lom_bad
    mov ecx, [rbx + OM_LM]
    cmp ecx, 3
    ja .Lom_bad
    mov r14d, 120
    shl r14d, cl
    mov r15d, 3
    sub r15d, ecx
    mov eax, [rbx + OM_STRIDE]
    cmp eax, 1
    jb .Lom_bad
    cmp eax, 8
    ja .Lom_bad
    lea edx, [rax - 1]
    test edx, eax
    jnz .Lom_bad
    mov edx, r14d
    dec edx
    imul edx, eax
    inc edx
    cmp [rbx + OM_IN_CAP], edx
    jb .Lom_bad
    lea edx, [r14 + 120]
    cmp [rbx + OM_OUT_CAP], edx
    jb .Lom_bad
    lea edx, [r14 + r14]
    cmp [rbx + OM_SCRATCH_CAP], edx
    jb .Lom_bad
    xor ecx, ecx
    xor edx, edx
.Lom_input_guard:
    mov eax, [rsi + rdx*4]
    and eax, 0x7fffffff
    cmp eax, 0x74800000        # |frequency|<=2^106
    ja .Lom_bad
    add edx, [rbx + OM_STRIDE]
    inc ecx
    cmp ecx, r14d
    jb .Lom_input_guard
    xor ecx, ecx
.Lom_overlap_guard:
    mov eax, [rdi + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x7b800000        # |existing overlap|<=2^120
    ja .Lom_bad
    inc ecx
    cmp ecx, 120
    jb .Lom_overlap_guard
    lea r13, [r12 + r14*4]     # f2, following f
    xor edi, edi
.Lom_pre_rotate:
    mov ecx, r15d
    mov r8d, edi
    shl r8d, cl
    mov r9d, r14d
    shr r9d, 1
    sub r9d, edi
    shl r9d, cl
    lea r11, [rip + om_trig]
    lea eax, [rdi + rdi]
    imul eax, [rbx + OM_STRIDE]
    movss xmm1, dword ptr [rsi + rax*4]
    mov eax, r14d
    dec eax
    sub eax, edi
    sub eax, edi
    imul eax, [rbx + OM_STRIDE]
    movss xmm0, dword ptr [rsi + rax*4]
    movaps xmm2, xmm0
    mulss xmm2, dword ptr [r11 + r8*4]
    xorps xmm2, xmmword ptr [rip + om_negative]
    movaps xmm3, xmm1
    mulss xmm3, dword ptr [r11 + r9*4]
    addss xmm2, xmm3         # yr
    mulss xmm0, dword ptr [r11 + r9*4]
    xorps xmm0, xmmword ptr [rip + om_negative]
    mulss xmm1, dword ptr [r11 + r8*4]
    subss xmm0, xmm1         # yi
    mov eax, [rbx + OM_LM]
    lea r11, [rip + om_sines]
    movss xmm3, dword ptr [r11 + rax*4]
    movaps xmm4, xmm0
    mulss xmm4, xmm3
    movaps xmm5, xmm2
    subss xmm5, xmm4
    movss dword ptr [r13 + rdi*8], xmm5
    mulss xmm2, xmm3
    addss xmm0, xmm2
    movss dword ptr [r13 + rdi*8 + 4], xmm0
    inc edi
    lea eax, [rdi + rdi]
    cmp eax, r14d
    jb .Lom_pre_rotate
    mov rcx, r13
    mov rdx, r12
    mov r8d, [rbx + OM_LM]
    call op_celt_ifft
    test eax, eax
    jz .Lom_bad
    xor edi, edi
.Lom_post_rotate:
    mov ecx, r15d
    mov r8d, edi
    shl r8d, cl
    mov r9d, r14d
    shr r9d, 1
    sub r9d, edi
    shl r9d, cl
    lea r11, [rip + om_trig]
    movss xmm0, dword ptr [r12 + rdi*8]
    movss xmm1, dword ptr [r12 + rdi*8 + 4]
    movaps xmm2, xmm0
    mulss xmm2, dword ptr [r11 + r8*4]
    movaps xmm3, xmm1
    mulss xmm3, dword ptr [r11 + r9*4]
    subss xmm2, xmm3         # yr
    mulss xmm1, dword ptr [r11 + r8*4]
    mulss xmm0, dword ptr [r11 + r9*4]
    addss xmm0, xmm1         # yi
    mov eax, [rbx + OM_LM]
    lea r11, [rip + om_sines]
    movss xmm3, dword ptr [r11 + rax*4]
    movaps xmm4, xmm0
    mulss xmm4, xmm3
    movaps xmm5, xmm2
    subss xmm5, xmm4
    movss dword ptr [r12 + rdi*8], xmm5
    mulss xmm2, xmm3
    addss xmm0, xmm2
    movss dword ptr [r12 + rdi*8 + 4], xmm0
    inc edi
    lea eax, [rdi + rdi]
    cmp eax, r14d
    jb .Lom_post_rotate
    xor ecx, ecx
.Lom_deshuffle:
    mov eax, [r12 + rcx*8]
    xor eax, 0x80000000
    mov [r13 + rcx*8], eax
    mov edx, r14d
    dec edx
    sub edx, ecx
    sub edx, ecx
    mov eax, [r12 + rdx*4]
    mov [r13 + rcx*8 + 4], eax
    inc ecx
    lea eax, [rcx + rcx]
    cmp eax, r14d
    jb .Lom_deshuffle
    mov rdi, [rbx + OM_OUT]
    mov r8d, r14d
    shr r8d, 1              # half
    mov r9d, r8d
    sub r9d, 60             # middle samples on each side
    mov r10d, r8d
    add r10d, 60
    xor ecx, ecx
.Lom_mirror_middle:
    cmp ecx, r9d
    jae .Lom_mirror_overlap
    mov edx, r8d
    dec edx
    sub edx, ecx
    mov eax, [r13 + rdx*4]
    mov edx, r10d
    dec edx
    sub edx, ecx
    mov [rdi + rdx*4], eax
    lea edx, [r8 + rcx]
    mov eax, [r13 + rdx*4]
    lea edx, [r10 + rcx]
    mov [rdi + rdx*4], eax
    inc ecx
    jmp .Lom_mirror_middle
.Lom_mirror_overlap:
    lea r11, [rip + om_window]
    xor ecx, ecx
.Lom_overlap:
    mov edx, 59
    sub edx, ecx
    movss xmm2, dword ptr [r13 + rdx*4]
    movss xmm0, dword ptr [r11 + rcx*4]
    mulss xmm0, xmm2
    xorps xmm0, xmmword ptr [rip + om_negative]
    addss xmm0, dword ptr [rdi + rcx*4]
    movss dword ptr [rdi + rcx*4], xmm0
    mov edx, 119
    sub edx, ecx
    movss xmm0, dword ptr [r11 + rdx*4]
    mulss xmm0, xmm2
    addss xmm0, dword ptr [rdi + rdx*4]
    movss dword ptr [rdi + rdx*4], xmm0
    lea eax, [r14 + rcx - 60]
    movss xmm2, dword ptr [r13 + rax*4]
    movss xmm0, dword ptr [r11 + rcx*4]
    mulss xmm0, xmm2
    lea eax, [r14 + 119]
    sub eax, ecx
    movss dword ptr [rdi + rax*4], xmm0
    movss xmm0, dword ptr [r11 + rdx*4]
    mulss xmm0, xmm2
    lea eax, [r14 + rcx]
    movss dword ptr [rdi + rax*4], xmm0
    inc ecx
    cmp ecx, 60
    jb .Lom_overlap
    mov eax, 1
    jmp .Lom_done
.Lom_bad:
    xor eax, eax
.Lom_done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_celt_imdct

# RCX=64-byte request. EAX=1/0. S=120*2^LM, mono/stereo, long/transient.
# Freq/out each C*S floats, overlap C*120, scratch 3*S+120 floats.
# All arrays are caller-owned/nonoverlapping; rejected parameters don't write.
# Successful calls update overlap; later helper failure means discard the frame.
FN op_celt_synthesis
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96
    mov rbx, rcx
    test rbx, rbx
    jz .Loy_bad
    xor ecx, ecx
.Loy_pointers:
    cmp qword ptr [rbx + rcx*8], 0
    je .Loy_bad
    inc ecx
    cmp ecx, 4
    jb .Loy_pointers
    mov eax, [rbx + OY_CHANNELS]
    cmp eax, 1
    jb .Loy_bad
    cmp eax, 2
    ja .Loy_bad
    mov ecx, [rbx + OY_LM]
    cmp ecx, 3
    ja .Loy_bad
    cmp dword ptr [rbx + OY_SHORT], 1
    ja .Loy_bad
    mov r14d, 120
    shl r14d, cl
    imul eax, r14d
    cmp [rbx + OY_FREQ_CAP], eax
    jb .Loy_bad
    cmp [rbx + OY_OUT_CAP], eax
    jb .Loy_bad
    mov r11d, eax
    mov eax, [rbx + OY_CHANNELS]
    imul eax, 120
    cmp [rbx + OY_OVERLAP_CAP], eax
    jb .Loy_bad
    mov r10d, eax
    lea eax, [r14 + r14*2 + 120]
    cmp [rbx + OY_SCRATCH_CAP], eax
    jb .Loy_bad
    xor ecx, ecx
    mov r8, [rbx + OY_FREQ]
.Loy_freq_guard:
    mov eax, [r8 + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x74800000
    ja .Loy_bad
    inc ecx
    cmp ecx, r11d
    jb .Loy_freq_guard
    xor ecx, ecx
    mov r8, [rbx + OY_OVERLAP]
.Loy_overlap_guard:
    mov eax, [r8 + rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x7b800000
    ja .Loy_bad
    inc ecx
    cmp ecx, r10d
    jb .Loy_overlap_guard
    mov rsi, [rbx + OY_SCRATCH]
    lea eax, [r14 + 120]
    lea r12, [rsi + rax*4]
    mov [rsp + 32 + OM_SCRATCH], r12
    lea eax, [r14 + r14]
    mov [rsp + 32 + OM_SCRATCH_CAP], eax
    mov eax, [rbx + OY_LM]
    mov edx, 1
    mov ecx, r14d
    cmp dword ptr [rbx + OY_SHORT], 0
    je .Loy_mode_ready
    mov ecx, eax
    shl edx, cl
    xor eax, eax
    mov ecx, 120
.Loy_mode_ready:
    mov [rsp + 32 + OM_LM], eax
    mov [rsp + 32 + OM_STRIDE], edx
    mov [rsp + 80], edx         # block count
    mov [rsp + 84], ecx         # samples per block
    xor r13d, r13d
.Loy_channel:
    mov rdi, rsi
    xor eax, eax
    mov ecx, 120
    rep stosd
    xor r15d, r15d
.Loy_block:
    mov eax, r13d
    imul eax, r14d
    add eax, r15d
    mov rdx, [rbx + OY_FREQ]
    lea rdx, [rdx + rax*4]
    mov [rsp + 32 + OM_IN], rdx
    mov eax, r14d
    sub eax, r15d
    mov [rsp + 32 + OM_IN_CAP], eax
    mov eax, r15d
    imul eax, [rsp + 84]
    lea rdx, [rsi + rax*4]
    mov [rsp + 32 + OM_OUT], rdx
    mov edx, r14d
    add edx, 120
    sub edx, eax
    mov [rsp + 32 + OM_OUT_CAP], edx
    lea rcx, [rsp + 32]
    call op_celt_imdct
    test eax, eax
    jz .Loy_bad
    inc r15d
    cmp r15d, [rsp + 80]
    jb .Loy_block
    mov eax, r13d
    imul eax, r14d
    mov rdi, [rbx + OY_OUT]
    lea rdi, [rdi + rax*4]
    mov eax, r13d
    imul eax, 120
    mov r12, [rbx + OY_OVERLAP]
    lea r12, [r12 + rax*4]
    xor ecx, ecx
.Loy_head:
    movss xmm0, dword ptr [rsi + rcx*4]
    addss xmm0, dword ptr [r12 + rcx*4]
    movss dword ptr [rdi + rcx*4], xmm0
    inc ecx
    cmp ecx, 120
    jb .Loy_head
.Loy_middle:
    cmp ecx, r14d
    jae .Loy_tail_init
    mov eax, [rsi + rcx*4]
    mov [rdi + rcx*4], eax
    inc ecx
    jmp .Loy_middle
.Loy_tail_init:
    xor ecx, ecx
    lea r8, [rsi + r14*4]
.Loy_tail:
    mov eax, [r8 + rcx*4]
    mov [r12 + rcx*4], eax
    inc ecx
    cmp ecx, 120
    jb .Loy_tail
    inc r13d
    cmp r13d, [rbx + OY_CHANNELS]
    jb .Loy_channel
    mov eax, 1
    jmp .Loy_done
.Loy_bad:
    xor eax, eax
.Loy_done:
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_celt_synthesis
