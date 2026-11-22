# Original assembly Speex LPC reconstruction and stateful filters. MIT.
# BSD Speex 1.2.1 references: lsp.c (David Rowe, Jean-Marc Valin),
# math_approx.h and filters.c (Jean-Marc Valin). See THIRD_PARTY_NOTICES.
.include "lamp.inc"
RODATA
.p2align 3
spxf_pi: .double 3.14159265358979323846
spxf_half_pi: .double 1.5707963268
spxf_pi32: .float 3.14159265358979323846
spxf_one: .float 1.
spxf_half: .float .5
spxf_margin_max: .float .25
spxf_cos_coeff: .float 0.9999932946, -0.4999124376, 0.0414877472, -0.0012712095
.p2align 4
spxf_sign: .long 0x80000000, 0, 0, 0
# Reference high-pass descriptors: Z0,Z1,Z2,P1,P2 (P0 is always one).
spxf_highpass:
    .float .95654, -1.91309, .95654, -1.91120, .91498
    .float .96446, -1.92879, .96446, -1.92683, .93071
    .float .96723, -1.93445, .96723, -1.93338, .93553
    .float .98645, -1.97277, .98645, -1.97226, .97332
    .float .88000, -1.76000, .88000, -1.37000, .39900
.text

# RCX=old LSP, RDX=new LSP, R8=output, R9D=order (8/10),
# [rsp+40]=subframe, [rsp+48]=subframe count (1..64), [rsp+56]=float margin.
# Margin is 0..0.25; input coefficients must be finite with |x|<=16.
# Output commits only on success; input/output aliasing is supported.
FN spx_lsp_interpolate
    mov r10d, [rsp+40]
    mov r11d, [rsp+48]
    movss xmm5, [rsp+56]
    cmp r9d, 8
    je .Lspxi_order
    cmp r9d, 10
    jne .Lspxi_bad_leaf
.Lspxi_order:
    test r11d, r11d
    jz .Lspxi_bad_leaf
    cmp r11d, 64
    ja .Lspxi_bad_leaf
    cmp r10d, r11d
    jae .Lspxi_bad_leaf
    test rcx, rcx
    jz .Lspxi_bad_leaf
    test rdx, rdx
    jz .Lspxi_bad_leaf
    test r8, r8
    jz .Lspxi_bad_leaf
    mov eax, r9d
    shl eax, 2
    add rax, rcx
    jc .Lspxi_bad_leaf
    mov eax, r9d
    shl eax, 2
    add rax, rdx
    jc .Lspxi_bad_leaf
    mov eax, r9d
    shl eax, 2
    add rax, r8
    jc .Lspxi_bad_leaf
    movd eax, xmm5
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxi_bad_leaf
    pxor xmm0, xmm0
    ucomiss xmm5, xmm0
    jb .Lspxi_bad_leaf
    ucomiss xmm5, [rip+spxf_margin_max]
    ja .Lspxi_bad_leaf
    sub rsp, 72
    cvtsi2ss xmm0, r10d
    addss xmm0, [rip+spxf_one]
    cvtsi2ss xmm1, r11d
    divss xmm0, xmm1                     # tmp, exactly reference float division
    movss xmm1, [rip+spxf_one]
    subss xmm1, xmm0                     # 1-tmp
    xor eax, eax
.Lspxi_mix:
    mov r10d, [rcx+rax*4]
    and r10d, 0x7fffffff
    cmp r10d, 0x41800000                 # |LSP| <= 16 covers all codebook sums
    ja .Lspxi_bad
    mov r10d, [rdx+rax*4]
    and r10d, 0x7fffffff
    cmp r10d, 0x41800000
    ja .Lspxi_bad
    movss xmm2, [rcx+rax*4]
    mulss xmm2, xmm1
    movss xmm3, [rdx+rax*4]
    mulss xmm3, xmm0
    addss xmm2, xmm3
    movss [rsp+rax*4], xmm2
    inc eax
    cmp eax, r9d
    jb .Lspxi_mix
    movss xmm0, [rsp]
    ucomiss xmm0, xmm5
    jae .Lspxi_upper
    movss [rsp], xmm5
.Lspxi_upper:
    movsd xmm4, [rip+spxf_pi]
    cvtss2sd xmm0, xmm5
    subsd xmm4, xmm0                     # reference uses double pi - float margin
    lea r10d, [r9-1]
    movss xmm0, [rsp+r10*4]
    cvtss2sd xmm0, xmm0
    ucomisd xmm0, xmm4
    jbe .Lspxi_middle_start
    cvtsd2ss xmm0, xmm4
    movss [rsp+r10*4], xmm0
.Lspxi_middle_start:
    mov eax, 1
.Lspxi_middle:
    movss xmm0, [rsp+rax*4-4]
    addss xmm0, xmm5
    movss xmm1, [rsp+rax*4]
    ucomiss xmm1, xmm0
    jae .Lspxi_middle_upper
    movss [rsp+rax*4], xmm0
    movaps xmm1, xmm0
.Lspxi_middle_upper:
    movss xmm0, [rsp+rax*4+4]
    subss xmm0, xmm5
    ucomiss xmm1, xmm0
    jbe .Lspxi_middle_next
    addss xmm1, [rsp+rax*4+4]
    subss xmm1, xmm5
    mulss xmm1, [rip+spxf_half]
    movss [rsp+rax*4], xmm1
.Lspxi_middle_next:
    inc eax
    cmp eax, r10d
    jb .Lspxi_middle
    xor eax, eax
.Lspxi_commit:
    mov r10d, [rsp+rax*4]
    mov [r8+rax*4], r10d
    inc eax
    cmp eax, r9d
    jb .Lspxi_commit
    mov eax, 1
    add rsp, 72
    ret
.Lspxi_bad:
    add rsp, 72
.Lspxi_bad_leaf:
    xor eax, eax
    ret
ENDFN spx_lsp_interpolate

# RCX=LSP, RDX=LPC output, R8D=order 8/10, R9D=capacity -> 1/0.
# Finite angles in [0,float(pi)]. All input is read before output commits;
# in-place and overlapping source/output ranges are safe.
FN spx_lsp_to_lpc
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 224
    mov rsi, rcx
    mov rdi, rdx
    mov r12d, r8d
    cmp r12d, 8
    je .Lspxlpc_order
    cmp r12d, 10
    jne .Lspxlpc_bad
.Lspxlpc_order:
    cmp r9d, r12d
    jb .Lspxlpc_bad
    test rsi, rsi
    jz .Lspxlpc_bad
    test rdi, rdi
    jz .Lspxlpc_bad
    lea rax, [r12*4]
    add rax, rsi
    jc .Lspxlpc_bad
    lea rax, [r12*4]
    add rax, rdi
    jc .Lspxlpc_bad
    xor ebx, ebx
.Lspxlpc_cos:
    mov eax, [rsi+rbx*4]
    mov r11d, eax
    and r11d, 0x7fffffff
    cmp r11d, 0x7f800000
    jae .Lspxlpc_bad
    movss xmm0, [rsi+rbx*4]
    pxor xmm1, xmm1
    ucomiss xmm0, xmm1
    jb .Lspxlpc_bad
    ucomiss xmm0, [rip+spxf_pi32]
    ja .Lspxlpc_bad
    xor r11d, r11d
    cvtss2sd xmm1, xmm0
    ucomisd xmm1, [rip+spxf_half_pi]
    jb .Lspxlpc_cos_square
    movsd xmm2, [rip+spxf_pi]
    subsd xmm2, xmm1
    cvtsd2ss xmm0, xmm2
    mov r11d, 0x80000000
.Lspxlpc_cos_square:
    mulss xmm0, xmm0
    movss xmm1, [rip+spxf_cos_coeff+12]
    mulss xmm1, xmm0
    addss xmm1, [rip+spxf_cos_coeff+8]
    mulss xmm1, xmm0
    addss xmm1, [rip+spxf_cos_coeff+4]
    mulss xmm1, xmm0
    addss xmm1, [rip+spxf_cos_coeff]
    movd xmm2, r11d
    xorps xmm1, xmm2
    movss [rsp+32+rbx*4], xmm1
    inc ebx
    cmp ebx, r12d
    jb .Lspxlpc_cos
    pxor xmm0, xmm0
    movdqu [rsp+80], xmm0
    movdqu [rsp+96], xmm0
    movdqu [rsp+112], xmm0
    movdqu [rsp+128], xmm0
    movdqu [rsp+144], xmm0
    movdqu [rsp+160], xmm0              # 2*order+2 polynomial state floats
    movss xmm0, [rip+spxf_one]         # xin1
    movaps xmm1, xmm0                  # xin2
    xor r13d, r13d                     # impulse pass j = 0..order
.Lspxlpc_pass:
    xor eax, eax
    xor edx, edx
.Lspxlpc_pair:
    movss xmm2, [rsp+32+rax*4]
    addss xmm2, xmm2
    mulss xmm2, [rsp+80+rdx]
    movaps xmm4, xmm0
    subss xmm4, xmm2
    addss xmm4, [rsp+84+rdx]
    movss xmm2, [rsp+36+rax*4]
    addss xmm2, xmm2
    mulss xmm2, [rsp+88+rdx]
    movaps xmm5, xmm1
    subss xmm5, xmm2
    addss xmm5, [rsp+92+rdx]
    movss xmm2, [rsp+80+rdx]
    movss [rsp+84+rdx], xmm2
    movss xmm2, [rsp+88+rdx]
    movss [rsp+92+rdx], xmm2
    movss [rsp+80+rdx], xmm0
    movss [rsp+88+rdx], xmm1
    movaps xmm0, xmm4
    movaps xmm1, xmm5
    add eax, 2
    add edx, 16
    cmp eax, r12d
    jb .Lspxlpc_pair
    movaps xmm2, xmm0
    addss xmm2, [rsp+80+rdx]
    movaps xmm3, xmm1
    subss xmm3, [rsp+84+rdx]
    test r13d, r13d
    jz .Lspxlpc_tail
    addss xmm2, xmm3
    mulss xmm2, [rip+spxf_half]
    movss [rsp+172+r13*4], xmm2        # ak[j-1] at rsp+176
.Lspxlpc_tail:
    movss [rsp+80+rdx], xmm0
    movss [rsp+84+rdx], xmm1
    pxor xmm0, xmm0
    pxor xmm1, xmm1
    inc r13d
    cmp r13d, r12d
    jbe .Lspxlpc_pass
    xor eax, eax
.Lspxlpc_commit:
    mov edx, [rsp+176+rax*4]
    mov [rdi+rax*4], edx
    inc eax
    cmp eax, r12d
    jb .Lspxlpc_commit
    mov eax, 1
    jmp .Lspxlpc_return
.Lspxlpc_bad:
    xor eax, eax
.Lspxlpc_return:
    add rsp, 224
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN spx_lsp_to_lpc

# RCX=LPC, RDX=output, R8D=order 8/10, XMM3=float gamma [0,1] -> 1/0.
# Gamma and LPC values must be finite. Output commits only on success and
# can overlap source. No extra precision or fused operations are introduced.
FN spx_bw_lpc
    cmp r8d, 8
    je .Lspxbw_order
    cmp r8d, 10
    jne .Lspxbw_bad_leaf
.Lspxbw_order:
    test rcx, rcx
    jz .Lspxbw_bad_leaf
    test rdx, rdx
    jz .Lspxbw_bad_leaf
    mov eax, r8d
    shl eax, 2
    add rax, rcx
    jc .Lspxbw_bad_leaf
    mov eax, r8d
    shl eax, 2
    add rax, rdx
    jc .Lspxbw_bad_leaf
    movd eax, xmm3
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxbw_bad_leaf
    pxor xmm0, xmm0
    ucomiss xmm3, xmm0
    jb .Lspxbw_bad_leaf
    ucomiss xmm3, [rip+spxf_one]
    ja .Lspxbw_bad_leaf
    sub rsp, 56
    movaps xmm1, xmm3
    xor eax, eax
.Lspxbw_coefficient:
    mov r9d, [rcx+rax*4]
    and r9d, 0x7fffffff
    cmp r9d, 0x7f800000
    jae .Lspxbw_bad
    movss xmm0, [rcx+rax*4]
    mulss xmm0, xmm1
    movss [rsp+rax*4], xmm0
    mulss xmm1, xmm3
    inc eax
    cmp eax, r8d
    jb .Lspxbw_coefficient
    xor eax, eax
.Lspxbw_commit:
    mov r9d, [rsp+rax*4]
    mov [rdx+rax*4], r9d
    inc eax
    cmp eax, r8d
    jb .Lspxbw_commit
    mov eax, 1
    add rsp, 56
    ret
.Lspxbw_bad:
    add rsp, 56
.Lspxbw_bad_leaf:
    xor eax, eax
    ret
ENDFN spx_bw_lpc

# RCX=input, RDX=denominator, R8=output, R9D=samples (0..640),
# [rsp+40]=order 8/10, [rsp+48]=order-float persistent memory -> 1/0.
FN spx_iir_mem
    mov r10d, [rsp+40]
    cmp r10d, 8
    je .Lspxf_iir_order
    cmp r10d, 10
    jne .Lspxf_bad_leaf
.Lspxf_iir_order:
    mov r11, [rsp+48]
    jmp spx_filter_run
ENDFN spx_iir_mem

# RCX=input, RDX=output, R8D=samples (0..640), R9D=filter ID 0..4,
# [rsp+40]=two-float persistent memory -> 1/0.
FN spx_highpass
    cmp r9d, 4
    ja .Lspxf_bad_leaf
    mov r11, [rsp+40]
    mov eax, r8d
    mov r8, rdx
    imul r9d, r9d, 20
    lea rdx, [rip+spxf_highpass]
    add rdx, r9
    mov r9d, eax
    mov r10d, 2
    jmp spx_filter_run
ENDFN spx_highpass
.Lspxf_bad_leaf:
    xor eax, eax
    ret

# Shared bounded atomic filter runner. No heap/system calls. Temporary output
# and memory fit below a single Windows stack-guard-page interval. All input,
# coefficients and state must be finite; nonfinite computed results fail too.
# Exact input/output alias is allowed. Other overlaps and any writable state
# overlap reject. Failure leaves output and persistent memory untouched.
LOCALFN spx_filter_run
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 2720
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov r12d, r9d
    mov r13d, r10d
    mov r14, r11
    cmp r12d, 640
    ja .Lspxf_bad
    test r12d, r12d
    jz .Lspxf_ok
    test rbx, rbx
    jz .Lspxf_bad
    test rsi, rsi
    jz .Lspxf_bad
    test rdi, rdi
    jz .Lspxf_bad
    test r14, r14
    jz .Lspxf_bad
    lea rax, [r12*4]
    add rax, rbx
    jc .Lspxf_bad
    mov [rsp+2640], rax
    lea rax, [r12*4]
    add rax, rdi
    jc .Lspxf_bad
    mov [rsp+2656], rax
    mov r10d, r13d
    cmp r13d, 2
    jne .Lspxf_coeff_size
    mov r10d, 5
.Lspxf_coeff_size:
    lea rax, [r10*4]
    add rax, rsi
    jc .Lspxf_bad
    mov [rsp+2648], rax
    lea rax, [r13*4]
    add rax, r14
    jc .Lspxf_bad
    mov [rsp+2664], rax
    cmp rdi, rbx
    je .Lspxf_io_disjoint
    cmp rdi, [rsp+2640]
    jae .Lspxf_io_disjoint
    cmp rbx, [rsp+2656]
    jb .Lspxf_bad
.Lspxf_io_disjoint:
    cmp rdi, [rsp+2648]
    jae .Lspxf_out_coeff_disjoint
    cmp rsi, [rsp+2656]
    jb .Lspxf_bad
.Lspxf_out_coeff_disjoint:
    cmp r14, [rsp+2656]
    jae .Lspxf_state_out_disjoint
    cmp rdi, [rsp+2664]
    jb .Lspxf_bad
.Lspxf_state_out_disjoint:
    cmp r14, [rsp+2640]
    jae .Lspxf_state_in_disjoint
    cmp rbx, [rsp+2664]
    jb .Lspxf_bad
.Lspxf_state_in_disjoint:
    cmp r14, [rsp+2648]
    jae .Lspxf_state_coeff_disjoint
    cmp rsi, [rsp+2664]
    jb .Lspxf_bad
.Lspxf_state_coeff_disjoint:
    xor ecx, ecx
.Lspxf_validate_coeff:
    mov eax, [rsi+rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxf_bad
    inc ecx
    cmp ecx, r10d
    jb .Lspxf_validate_coeff
    xor ecx, ecx
.Lspxf_copy_state:
    mov eax, [r14+rcx*4]
    mov edx, eax
    and edx, 0x7fffffff
    cmp edx, 0x7f800000
    jae .Lspxf_bad
    mov [rsp+32+rcx*4], eax
    inc ecx
    cmp ecx, r13d
    jb .Lspxf_copy_state
    xor ecx, ecx
.Lspxf_validate_input:
    mov eax, [rbx+rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxf_bad
    inc ecx
    cmp ecx, r12d
    jb .Lspxf_validate_input
    xor r15d, r15d
    cmp r13d, 2
    je .Lspxf_highpass_sample
.Lspxf_iir_sample:
    movss xmm0, [rbx+r15*4]
    addss xmm0, [rsp+32]
    movd eax, xmm0
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxf_bad
    movaps xmm1, xmm0
    xorps xmm1, [rip+spxf_sign]
    xor ecx, ecx
    lea r10d, [r13-1]
.Lspxf_iir_memory:
    movss xmm2, [rsi+rcx*4]
    mulss xmm2, xmm1
    addss xmm2, [rsp+36+rcx*4]
    movd eax, xmm2
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxf_bad
    movss [rsp+32+rcx*4], xmm2
    inc ecx
    cmp ecx, r10d
    jb .Lspxf_iir_memory
    movss xmm2, [rsi+rcx*4]
    mulss xmm2, xmm1
    movd eax, xmm2
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxf_bad
    movss [rsp+32+rcx*4], xmm2
    movss [rsp+80+r15*4], xmm0
    inc r15d
    cmp r15d, r12d
    jb .Lspxf_iir_sample
    jmp .Lspxf_commit
.Lspxf_highpass_sample:
    movss xmm0, [rbx+r15*4]
    movaps xmm1, xmm0
    mulss xmm1, [rsi]
    addss xmm1, [rsp+32]                # vout and yi (float path never clips)
    movaps xmm2, xmm0
    mulss xmm2, [rsi+4]
    addss xmm2, [rsp+36]
    movss xmm3, [rsi+12]
    xorps xmm3, [rip+spxf_sign]
    mulss xmm3, xmm1
    addss xmm2, xmm3
    mulss xmm0, [rsi+8]
    movss xmm3, [rsi+16]
    xorps xmm3, [rip+spxf_sign]
    mulss xmm3, xmm1
    addss xmm0, xmm3
    movd eax, xmm0
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxf_bad
    movd eax, xmm1
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxf_bad
    movd eax, xmm2
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxf_bad
    movss [rsp+32], xmm2
    movss [rsp+36], xmm0
    movss [rsp+80+r15*4], xmm1
    inc r15d
    cmp r15d, r12d
    jb .Lspxf_highpass_sample
.Lspxf_commit:
    xor ecx, ecx
.Lspxf_commit_output:
    mov eax, [rsp+80+rcx*4]
    mov [rdi+rcx*4], eax
    inc ecx
    cmp ecx, r12d
    jb .Lspxf_commit_output
    xor ecx, ecx
.Lspxf_commit_state:
    mov eax, [rsp+32+rcx*4]
    mov [r14+rcx*4], eax
    inc ecx
    cmp ecx, r13d
    jb .Lspxf_commit_state
.Lspxf_ok:
    mov eax, 1
    jmp .Lspxf_return
.Lspxf_bad:
    xor eax, eax
.Lspxf_return:
    add rsp, 2720
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN spx_filter_run
