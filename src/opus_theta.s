# Handwritten x86-64 CELT recursive/stereo split-angle decoding.
# Normative RFC6716 bands.c/mathops.c algorithms (BSD).
# Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation,
# Gregory Maxwell. See THIRD_PARTY_NOTICES. No reference C runtime.
.include "lamp.inc"
.include "opus_theta_layout.inc"
RODATA
op_theta_exp2: .short 16384, 17866, 19483, 21247, 23170, 25267, 27554, 30048
op_theta_logn: .short 0, 0, 0, 0, 0, 0, 0, 0, 8, 8, 8, 8, 16, 16, 16, 21, 21, 24, 29, 34, 36
.text
# ECX is a signed Q14 angle. Match the normative int16 polynomial exactly.
FN op_celt_bitexact_cos
    movsx eax, cx
    imul eax, eax
    add eax, 4096
    sar eax, 13
    movsx r8d, ax
    imul eax, r8d, -626
    add eax, 16384
    sar eax, 15
    add eax, 8277
    movsx eax, ax
    imul eax, r8d
    add eax, 16384
    sar eax, 15
    sub eax, 7651
    movsx eax, ax
    imul eax, r8d
    add eax, 16384
    sar eax, 15
    add eax, 32768
    sub eax, r8d
    movsx eax, ax
    ret
ENDFN op_celt_bitexact_cos

# ECX=positive sine and EDX=positive cosine, each <=32767.
# EAX=normative log2 tangent approximation in Q11.
FN op_celt_log2tan
    bsr r8d, ecx
    inc r8d
    bsr r9d, edx
    inc r9d
    mov r10d, r8d
    sub r10d, r9d
    shl r10d, 11
    mov eax, ecx
    mov ecx, 15
    sub ecx, r8d
    shl eax, cl
    mov r8d, eax
    mov ecx, 15
    sub ecx, r9d
    shl edx, cl
    mov r9d, edx
    imul eax, r8d, -2597
    add eax, 16384
    sar eax, 15
    add eax, 7932
    movsx eax, ax
    imul eax, r8d
    add eax, 16384
    sar eax, 15
    add r10d, eax
    imul eax, r9d, -2597
    add eax, 16384
    sar eax, 15
    add eax, 7932
    movsx eax, ax
    imul eax, r9d
    add eax, 16384
    sar eax, 15
    sub r10d, eax
    mov eax, r10d
    ret
ENDFN op_celt_log2tan

# ECX=uint32, EAX=floor(sqrt(ECX)). Double precision is exact at these bounds.
FN op_celt_isqrt
    mov eax, ecx
    cvtsi2sd xmm0, rax
    sqrtsd xmm0, xmm0
    cvttsd2si eax, xmm0
    ret
ENDFN op_celt_isqrt

.equ OT_TELL, 32
.equ OT_FT, 36
.equ OT_FL, 40
.equ OT_FS, 44
.equ OT_HALF, 48
.equ OT_ANGLE, 52

# RCX=request, EAX=1/0. Invalid requests do not modify output or entropy.
# This stage computes theta, gains, allocation delta, inversion and fill mask.
# The recursive band caller applies the measured entropy cost to its budget.
FN op_celt_theta
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 104
    mov rbx, rcx
    test rbx, rbx
    jz .Lop_theta_bad
    mov rsi, [rbx + OTT_EC]
    test rsi, rsi
    jz .Lop_theta_bad
    cmp qword ptr [rbx + OTT_REMAINING], 0
    je .Lop_theta_bad
    mov edi, [rbx + OTT_N]
    cmp edi, 2
    jl .Lop_theta_bad
    cmp edi, 1024
    jg .Lop_theta_bad
    mov r12d, [rbx + OTT_BUDGET]
    cmp r12d, -16384
    jl .Lop_theta_bad
    cmp r12d, 81600
    jg .Lop_theta_bad
    mov r14d, [rbx + OTT_BAND]
    cmp r14d, 20
    ja .Lop_theta_bad
    mov r13d, [rbx + OTT_LM]
    lea eax, [r13 + 1]
    cmp eax, 4
    ja .Lop_theta_bad
    mov r15d, [rbx + OTT_STEREO]
    cmp r15d, 1
    ja .Lop_theta_bad
    mov eax, [rbx + OTT_BLOCKS]
    test eax, eax
    jz .Lop_theta_bad
    cmp eax, 16
    ja .Lop_theta_bad
    lea edx, [rax - 1]
    test eax, edx
    jnz .Lop_theta_bad
    mov eax, [rbx + OTT_ORIGINAL_BLOCKS]
    test eax, eax
    jz .Lop_theta_bad
    cmp eax, 16
    ja .Lop_theta_bad
    lea edx, [rax - 1]
    test eax, edx
    jnz .Lop_theta_bad
    cmp dword ptr [rbx + OTT_INTENSITY], 21
    ja .Lop_theta_bad
    cmp dword ptr [rsi + 8], 1275
    ja .Lop_theta_bad
    cmp dword ptr [rsi + 8], 0
    je .Lop_theta_buffer_valid
    cmp qword ptr [rsi], 0
    je .Lop_theta_bad
.Lop_theta_buffer_valid:
    mov eax, [rsi + 28]
    cmp eax, [rsi + 8]
    ja .Lop_theta_bad
    mov eax, [rsi + 12]
    cmp eax, [rsi + 8]
    ja .Lop_theta_bad
    cmp dword ptr [rsi + 32], 0x800000
    jbe .Lop_theta_bad
    cmp dword ptr [rsi + 32], 0x80000000
    ja .Lop_theta_bad
    cmp dword ptr [rsi + 20], 32
    ja .Lop_theta_bad
    cmp dword ptr [rsi + 24], 32768
    ja .Lop_theta_bad
    # All validation precedes writes and symbol decoding.
    lea rax, [rip + op_theta_logn]
    movzx r8d, word ptr [rax + r14*2]
    lea r8d, [r8 + r13*8]        # pulse_cap
    mov r9d, r8d
    sar r9d, 1
    sub r9d, 4                # theta offset
    test r15d, r15d
    jz .Lop_theta_qn
    cmp edi, 2
    jne .Lop_theta_qn
    sub r9d, 12
.Lop_theta_qn:
    lea ecx, [rdi*2 - 1]
    test r15d, r15d
    jz .Lop_theta_n2
    cmp edi, 2
    jne .Lop_theta_n2
    dec ecx
.Lop_theta_n2:
    mov eax, ecx
    imul eax, r9d
    add eax, r12d
    cdq
    idiv ecx
    mov edx, r12d
    sub edx, r8d
    sub edx, 32
    cmp eax, edx
    cmovg eax, edx
    mov edx, 64
    cmp eax, edx
    cmovg eax, edx
    mov ebp, 1
    cmp eax, 4
    jl .Lop_theta_intensity
    mov edx, eax
    and edx, 7
    lea rcx, [rip + op_theta_exp2]
    movzx ebp, word ptr [rcx + rdx*2]
    sar eax, 3
    mov ecx, 14
    sub ecx, eax
    sar ebp, cl
    inc ebp
    and ebp, -2
.Lop_theta_intensity:
    test r15d, r15d
    jz .Lop_theta_ready
    cmp r14d, [rbx + OTT_INTENSITY]
    jl .Lop_theta_ready
    mov ebp, 1
.Lop_theta_ready:
    mov [rbx + OTT_QN], ebp
    mov dword ptr [rbx + OTT_INVERT], 0
    mov dword ptr [rsp + OT_ANGLE], 0
    mov rcx, rsi
    call op_ec_frac
    mov [rsp + OT_TELL], eax
    cmp ebp, 1
    je .Lop_theta_no_angle
    test r15d, r15d
    jz .Lop_theta_uniform_check
    cmp edi, 2
    jle .Lop_theta_uniform_check
    # Stereo step PDF: weight three in the lower half, one in the upper.
    mov eax, ebp
    shr eax, 1
    mov [rsp + OT_HALF], eax
    lea edx, [rax*4 + 3]
    mov [rsp + OT_FT], edx
    mov rcx, rsi
    call op_ec_decode
    mov ecx, [rsp + OT_HALF]
    lea r8d, [rcx + rcx*2 + 3]
    cmp eax, r8d
    jae .Lop_theta_step_high
    xor edx, edx
    mov ecx, 3
    div ecx
    lea edx, [rax + rax*2]
    lea r8d, [rdx + 3]
    jmp .Lop_theta_symbol_update
.Lop_theta_step_high:
    sub eax, r8d
    lea eax, [rax + rcx + 1]
    mov edx, eax
    dec edx
    sub edx, ecx
    add edx, r8d
    lea r8d, [rdx + 1]
    jmp .Lop_theta_symbol_update
.Lop_theta_uniform_check:
    test r15d, r15d
    jnz .Lop_theta_uniform
    cmp dword ptr [rbx + OTT_ORIGINAL_BLOCKS], 1
    jg .Lop_theta_uniform
    # Triangular PDF for a single-block mono recursive split.
    mov eax, ebp
    shr eax, 1
    mov [rsp + OT_HALF], eax
    inc eax
    imul eax, eax
    mov [rsp + OT_FT], eax
    mov edx, eax
    mov rcx, rsi
    call op_ec_decode
    mov [rsp + OT_FS], eax      # cumulative frequency until integer sqrt
    mov ecx, [rsp + OT_HALF]
    lea edx, [rcx + 1]
    imul edx, ecx
    shr edx, 1
    cmp eax, edx
    jae .Lop_theta_triangle_high
    lea ecx, [rax*8 + 1]
    call op_celt_isqrt
    dec eax
    shr eax, 1
    lea r8d, [rax + 1]
    mov edx, eax
    imul edx, r8d
    shr edx, 1
    add r8d, edx
    jmp .Lop_theta_symbol_update
.Lop_theta_triangle_high:
    mov ecx, [rsp + OT_FT]
    sub ecx, eax
    dec ecx
    lea ecx, [rcx*8 + 1]
    call op_celt_isqrt
    lea edx, [rbp*2 + 2]
    sub edx, eax
    shr edx, 1
    mov eax, edx
    lea r8d, [rbp + 1]
    sub r8d, eax             # frequency of this angle
    lea edx, [r8 + 1]
    imul edx, r8d
    shr edx, 1
    mov ecx, [rsp + OT_FT]
    sub ecx, edx
    mov edx, ecx
    add r8d, edx
.Lop_theta_symbol_update:
    mov [rsp + OT_ANGLE], eax
    mov r9d, [rsp + OT_FT]
    mov rcx, rsi
    call op_ec_update
    mov eax, [rsp + OT_ANGLE]
    jmp .Lop_theta_scale_angle
.Lop_theta_uniform:
    lea edx, [rbp + 1]
    mov rcx, rsi
    call op_ec_uint
.Lop_theta_scale_angle:
    shl eax, 14
    xor edx, edx
    div ebp
    mov [rsp + OT_ANGLE], eax
    jmp .Lop_theta_measure
.Lop_theta_no_angle:
    test r15d, r15d
    jz .Lop_theta_measure
    cmp r12d, 16
    jle .Lop_theta_measure
    mov rax, [rbx + OTT_REMAINING]
    cmp dword ptr [rax], 16
    jle .Lop_theta_measure
    mov rcx, rsi
    mov edx, 2
    call op_ec_logp
    mov [rbx + OTT_INVERT], eax
.Lop_theta_measure:
    mov rcx, rsi
    call op_ec_frac
    sub eax, [rsp + OT_TELL]
    mov [rbx + OTT_COST], eax
    mov eax, [rsp + OT_ANGLE]
    mov [rbx + OTT_ANGLE], eax
    mov r12d, [rbx + OTT_FILL]
    mov ecx, [rbx + OTT_BLOCKS]
    mov edx, 1
    shl edx, cl
    dec edx
    test eax, eax
    jz .Lop_theta_all_mid
    cmp eax, 16384
    je .Lop_theta_all_side
    mov ecx, eax
    call op_celt_bitexact_cos
    mov [rbx + OTT_MID], eax
    mov ecx, 16384
    sub ecx, [rsp + OT_ANGLE]
    call op_celt_bitexact_cos
    mov [rbx + OTT_SIDE], eax
    mov ecx, eax
    mov edx, [rbx + OTT_MID]
    call op_celt_log2tan
    movsx ecx, ax
    lea eax, [rdi - 1]
    shl eax, 7
    movsx eax, ax
    imul eax, ecx
    add eax, 16384
    sar eax, 15
    mov [rbx + OTT_DELTA], eax
    jmp .Lop_theta_store_fill
.Lop_theta_all_mid:
    mov dword ptr [rbx + OTT_MID], 32767
    mov dword ptr [rbx + OTT_SIDE], 0
    mov dword ptr [rbx + OTT_DELTA], -16384
    and r12d, edx
    jmp .Lop_theta_store_fill
.Lop_theta_all_side:
    mov dword ptr [rbx + OTT_MID], 0
    mov dword ptr [rbx + OTT_SIDE], 32767
    mov dword ptr [rbx + OTT_DELTA], 16384
    shl edx, cl
    and r12d, edx
.Lop_theta_store_fill:
    mov [rbx + OTT_OUTPUT_FILL], r12d
    mov eax, 1
    jmp .Lop_theta_done
.Lop_theta_bad:
    xor eax, eax
.Lop_theta_done:
    add rsp, 104
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN op_celt_theta
