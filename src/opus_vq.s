# Handwritten x86-64 CELT pulse-band normalization, spreading and collapse masks.
# Algorithms: BSD normative RFC6716 vq.c, rate.c and mathops.h.
# Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation.
# No runtime C or libm. SSE2 scalar float arithmetic; cosine uses a double polynomial.
.include "lamp.inc"
RODATA
ov_one: .float 1.0
ov_epsilon: .float 1.0E-15
ov_half: .float 0.5
ov_half_pi: .float 1.5707963705062866
ov_one64: .double 1.0
.p2align 4
ov_negative: .long 0x80000000, 0, 0, 0
ov_factors: .long 15, 10, 5
ov_maxn: .short 32767, 32767, 32767, 1476, 283, 109, 60, 40, 29, 24, 20, 18, 16, 14, 13
ov_maxk: .short 32767, 32767, 32767, 32767, 1172, 238, 95, 53, 36, 27, 22, 18, 16, 15, 13
# cos(x) = 1 + x*x*P(x*x), degree 20, for |x| <= pi/2.
ov_cos_coeff: .double -0.5, 0.041666666666666664, -0.001388888888888889
    .double 0.0000248015873015873, -0.0000002755731922398589, 0.00000000208767569878681
    .double -0.00000000001147074559772972, 0.00000000000004779477332387385
    .double -1.561920696858623E-16, 4.110317623312165E-19
.bss
.p2align 4
ov_pulses: .zero 1024*4
.text
# XMM0=float normalized angle [0,1] -> XMM0=float cosine.
# Match the reference's single-precision angle before its double cos().
LOCALFN ov_cos_norm
    mulss xmm0, dword ptr [rip + ov_half_pi]
    cvtss2sd xmm0, xmm0
    mulsd xmm0, xmm0
    lea rax, [rip + ov_cos_coeff]
    movsd xmm1, qword ptr [rax + 72]
    mov edx, 8
.Lov_cos_horner:
    mulsd xmm1, xmm0
    addsd xmm1, qword ptr [rax + rdx*8]
    dec edx
    jns .Lov_cos_horner
    mulsd xmm1, xmm0
    addsd xmm1, qword ptr [rip + ov_one64]
    cvtsd2ss xmm0, xmm1
    ret
ENDFN ov_cos_norm

# Private leaf: RCX=vector, EDX=len, R8D=stride, XMM0=c, XMM1=s.
LOCALFN ov_rotation1
    lea r11, [rcx + r8*4]
    mov r9d, edx
    sub r9d, r8d
    xor eax, eax
.Lov_rotation_forward:
    cmp eax, r9d
    jge .Lov_rotation_reverse_start
    movss xmm2, dword ptr [rcx + rax*4]
    movss xmm3, dword ptr [r11 + rax*4]
    movaps xmm4, xmm3
    mulss xmm4, xmm0
    movaps xmm5, xmm2
    mulss xmm5, xmm1
    addss xmm4, xmm5
    movss dword ptr [r11 + rax*4], xmm4
    mulss xmm2, xmm0
    mulss xmm3, xmm1
    subss xmm2, xmm3
    movss dword ptr [rcx + rax*4], xmm2
    inc eax
    jmp .Lov_rotation_forward
.Lov_rotation_reverse_start:
    mov eax, edx
    sub eax, r8d
    sub eax, r8d
    dec eax
    js .Lov_rotation_done
.Lov_rotation_reverse:
    movss xmm2, dword ptr [rcx + rax*4]
    movss xmm3, dword ptr [r11 + rax*4]
    movaps xmm4, xmm3
    mulss xmm4, xmm0
    movaps xmm5, xmm2
    mulss xmm5, xmm1
    addss xmm4, xmm5
    movss dword ptr [r11 + rax*4], xmm4
    mulss xmm2, xmm0
    mulss xmm3, xmm1
    subss xmm2, xmm3
    movss dword ptr [rcx + rax*4], xmm2
    dec eax
    jns .Lov_rotation_reverse
.Lov_rotation_done:
    ret
ENDFN ov_rotation1

# RCX=X, EDX=N, R8D=dir (-1 inverse/+1 forward), R9D=blocks (1,2,4,8,16),
# stack argument 5=K (0..32767), argument 6=spread (0..3). EAX=1/0.
# Buffers are caller-owned and contain N float32 entries.
FN op_celt_spread
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 112
    mov rbx, rcx
    mov r12d, edx
    mov r13d, r8d
    mov r14d, r9d
    mov r15d, [rsp + 208]
    mov esi, [rsp + 216]
    test rbx, rbx
    jz .Lov_spread_bad
    cmp r12d, 2
    jb .Lov_spread_bad
    cmp r12d, 1024
    ja .Lov_spread_bad
    cmp r13d, -1
    je .Lov_spread_direction
    cmp r13d, 1
    jne .Lov_spread_bad
.Lov_spread_direction:
    cmp r14d, 1
    jb .Lov_spread_bad
    cmp r14d, 16
    ja .Lov_spread_bad
    lea eax, [r14 - 1]
    test eax, r14d
    jnz .Lov_spread_bad
    test eax, r12d
    jnz .Lov_spread_bad
    cmp r15d, 32767
    ja .Lov_spread_bad
    cmp esi, 3
    ja .Lov_spread_bad
    test esi, esi
    jz .Lov_spread_good
    lea eax, [r15 + r15]
    cmp eax, r12d
    jge .Lov_spread_good
    lea rax, [rip + ov_factors]
    mov edx, [rax + rsi*4 - 4]
    imul edx, r15d
    add edx, r12d
    cvtsi2ss xmm0, r12d
    cvtsi2ss xmm1, edx
    divss xmm0, xmm1
    mulss xmm0, xmm0
    mulss xmm0, dword ptr [rip + ov_half]
    movss dword ptr [rsp + 48], xmm0
    call ov_cos_norm
    movss dword ptr [rsp + 40], xmm0  # c
    movss xmm0, dword ptr [rip + ov_one]
    subss xmm0, dword ptr [rsp + 48]
    call ov_cos_norm
    movss dword ptr [rsp + 44], xmm0  # s
    xor edi, edi
    lea eax, [r14*8]
    cmp r12d, eax
    jl .Lov_spread_stride_ready
    mov edi, 1
.Lov_spread_stride:
    mov eax, edi
    imul eax, edi
    add eax, edi
    imul eax, r14d
    mov edx, r14d
    shr edx, 2
    add eax, edx
    cmp eax, r12d
    jge .Lov_spread_stride_ready
    inc edi
    jmp .Lov_spread_stride
.Lov_spread_stride_ready:
    mov eax, r12d
    xor edx, edx
    div r14d
    mov [rsp + 52], eax
    mov dword ptr [rsp + 56], 0
.Lov_spread_block:
    mov eax, [rsp + 56]
    imul eax, [rsp + 52]
    lea rsi, [rbx + rax*4]
    cmp r13d, 0
    jg .Lov_spread_forward
    test edi, edi
    jz .Lov_spread_inverse_unit
    mov rcx, rsi
    mov edx, [rsp + 52]
    mov r8d, edi
    movss xmm0, dword ptr [rsp + 44]
    movss xmm1, dword ptr [rsp + 40]
    call ov_rotation1
.Lov_spread_inverse_unit:
    mov rcx, rsi
    mov edx, [rsp + 52]
    mov r8d, 1
    movss xmm0, dword ptr [rsp + 40]
    movss xmm1, dword ptr [rsp + 44]
    call ov_rotation1
    jmp .Lov_spread_next
.Lov_spread_forward:
    mov rcx, rsi
    mov edx, [rsp + 52]
    mov r8d, 1
    movss xmm0, dword ptr [rsp + 40]
    movss xmm1, dword ptr [rsp + 44]
    xorps xmm1, xmmword ptr [rip + ov_negative]
    call ov_rotation1
    test edi, edi
    jz .Lov_spread_next
    mov rcx, rsi
    mov edx, [rsp + 52]
    mov r8d, edi
    movss xmm0, dword ptr [rsp + 44]
    movss xmm1, dword ptr [rsp + 40]
    xorps xmm1, xmmword ptr [rip + ov_negative]
    call ov_rotation1
.Lov_spread_next:
    inc dword ptr [rsp + 56]
    mov eax, [rsp + 56]
    cmp eax, r14d
    jb .Lov_spread_block
.Lov_spread_good:
    mov eax, 1
    jmp .Lov_spread_done
.Lov_spread_bad:
    xor eax, eax
.Lov_spread_done:
    add rsp, 112
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_celt_spread

# RCX=request (40 bytes): X*q0, ec*q8, N*d16, K*d20, spread*d24,
# blocks*d28, gain*f32, collapse_mask*d36. EAX=1 success, 0 invalid.
# Original signed-pulse enumeration is reused; scratch is single-instance.
FN op_celt_unquant
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 80
    mov rbx, rcx
    test rbx, rbx
    jz .Lov_unquant_bad
    mov r14, [rbx]
    mov r15, [rbx + 8]
    mov esi, [rbx + 16]
    mov edi, [rbx + 20]
    mov r13d, [rbx + 24]
    mov r12d, [rbx + 28]
    test r14, r14
    jz .Lov_unquant_bad
    test r15, r15
    jz .Lov_unquant_bad
    cmp esi, 2
    jb .Lov_unquant_bad
    cmp esi, 1024
    ja .Lov_unquant_bad
    cmp edi, 1
    jb .Lov_unquant_bad
    cmp edi, 32767
    ja .Lov_unquant_bad
    cmp r13d, 3
    ja .Lov_unquant_bad
    cmp r12d, 1
    jb .Lov_unquant_bad
    cmp r12d, 16
    ja .Lov_unquant_bad
    lea eax, [r12 - 1]
    test eax, r12d
    jnz .Lov_unquant_bad
    test eax, esi
    jnz .Lov_unquant_bad
    cmp dword ptr [rbx + 32], 0x3f800000
    ja .Lov_unquant_bad
    cmp esi, 14
    jb .Lov_unquant_small_n
    cmp edi, 14
    jae .Lov_unquant_bad
    lea rax, [rip + ov_maxn]
    movzx eax, word ptr [rax + rdi*2]
    cmp esi, eax
    ja .Lov_unquant_bad
    jmp .Lov_unquant_decode
.Lov_unquant_small_n:
    lea rax, [rip + ov_maxk]
    movzx eax, word ptr [rax + rsi*2]
    cmp edi, eax
    ja .Lov_unquant_bad
.Lov_unquant_decode:
    lea rcx, [rip + ov_pulses]
    mov edx, esi
    mov r8d, edi
    mov r9, r15
    call op_decode_pulses
    test eax, eax
    jz .Lov_unquant_bad
    lea r8, [rip + ov_pulses]
    xorps xmm0, xmm0
    xor ecx, ecx
.Lov_unquant_energy:
    cvtsi2ss xmm1, dword ptr [r8 + rcx*4]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    inc ecx
    cmp ecx, esi
    jb .Lov_unquant_energy
    sqrtss xmm0, xmm0
    movss xmm1, dword ptr [rip + ov_one]
    divss xmm1, xmm0
    mulss xmm1, dword ptr [rbx + 32]
    shufps xmm1, xmm1, 0
    xor ecx, ecx
.Lov_unquant_normalize4:
    lea eax, [rcx + 4]
    cmp eax, esi
    ja .Lov_unquant_normalize
    movdqu xmm0, xmmword ptr [r8 + rcx*4]
    cvtdq2ps xmm0, xmm0
    mulps xmm0, xmm1
    movups xmmword ptr [r14 + rcx*4], xmm0
    add ecx, 4
    jmp .Lov_unquant_normalize4
.Lov_unquant_normalize:
    cmp ecx, esi
    jae .Lov_unquant_normalized
    cvtsi2ss xmm0, dword ptr [r8 + rcx*4]
    mulss xmm0, xmm1
    movss dword ptr [r14 + rcx*4], xmm0
    inc ecx
    cmp ecx, esi
    jb .Lov_unquant_normalize
.Lov_unquant_normalized:
    mov dword ptr [rsp + 56], 1
    cmp r12d, 1
    jle .Lov_unquant_rotate
    mov dword ptr [rsp + 56], 0
    mov eax, esi
    xor edx, edx
    div r12d
    mov r9d, eax
    xor r10d, r10d
    xor r11d, r11d
.Lov_unquant_mask_block:
    xor edx, edx
    xor eax, eax
.Lov_unquant_mask_bin:
    cmp dword ptr [r8 + r10*4], 0
    je .Lov_unquant_mask_next
    mov eax, 1
.Lov_unquant_mask_next:
    inc r10d
    inc edx
    cmp edx, r9d
    jb .Lov_unquant_mask_bin
    mov ecx, r11d
    shl eax, cl
    or [rsp + 56], eax
    inc r11d
    cmp r11d, r12d
    jb .Lov_unquant_mask_block
.Lov_unquant_rotate:
    mov rcx, r14
    mov edx, esi
    mov r8d, -1
    mov r9d, r12d
    mov [rsp + 32], edi
    mov [rsp + 40], r13d
    call op_celt_spread
    test eax, eax
    jz .Lov_unquant_bad
    mov eax, [rsp + 56]
    mov [rbx + 36], eax
    mov eax, 1
    jmp .Lov_unquant_done
.Lov_unquant_bad:
    xor eax, eax
.Lov_unquant_done:
    add rsp, 80
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_celt_unquant

# RCX=X, EDX=N (1..1024), XMM2=gain (third ABI argument, 0..1).
# EAX=1 success / 0 invalid or nonfinite energy; rejection precedes writes.
FN op_celt_renormalize
    test rcx, rcx
    jz .Lov_renorm_bad
    cmp edx, 1
    jb .Lov_renorm_bad
    cmp edx, 1024
    ja .Lov_renorm_bad
    movd eax, xmm2
    cmp eax, 0x3f800000
    ja .Lov_renorm_bad
    movss xmm0, dword ptr [rip + ov_epsilon]
    xor r8d, r8d
.Lov_renorm_energy:
    movss xmm1, dword ptr [rcx + r8*4]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    inc r8d
    cmp r8d, edx
    jb .Lov_renorm_energy
    movd eax, xmm0
    and eax, 0x7f800000
    cmp eax, 0x7f800000
    je .Lov_renorm_bad
    sqrtss xmm0, xmm0
    movss xmm3, dword ptr [rip + ov_one]
    divss xmm3, xmm0
    mulss xmm3, xmm2
    shufps xmm3, xmm3, 0
    xor r8d, r8d
.Lov_renorm_scale4:
    lea eax, [r8 + 4]
    cmp eax, edx
    ja .Lov_renorm_scale
    movups xmm0, xmmword ptr [rcx + r8*4]
    mulps xmm0, xmm3
    movups xmmword ptr [rcx + r8*4], xmm0
    add r8d, 4
    jmp .Lov_renorm_scale4
.Lov_renorm_scale:
    cmp r8d, edx
    jae .Lov_renorm_good
    movss xmm0, dword ptr [rcx + r8*4]
    mulss xmm0, xmm3
    movss dword ptr [rcx + r8*4], xmm0
    inc r8d
    cmp r8d, edx
    jb .Lov_renorm_scale
.Lov_renorm_good:
    mov eax, 1
    ret
.Lov_renorm_bad:
    xor eax, eax
    ret
ENDFN op_celt_renormalize
