# Original assembly Speex adaptive/innovation excitation. MIT.
# BSD Speex 1.2.1 references: ltp.c, cb_search.c, math_approx.h and
# codebook source files. Copyright Jean-Marc Valin; THIRD_PARTY_NOTICES.
.include "lamp.inc"
.include "speex_packet.inc"
.include "speex_excitation.inc"
RODATA
.include "speex_excitation_tables.inc"
.p2align 3
spxe_half64: .double .5
spxe_neg_half64: .double -.5
spxe_limit95: .double .95
spxe_limit99: .double .99
spxe_noise_scale: .double 3.4642
spxe_noise_center: .double 1.5
spxe_shape_scale: .double .03125
spxe_shape_neg_scale: .double -.03125
spxe_gain_scale: .float .015625
spxe_half: .float .5
spxe_gain95: .float .95
spxe_gain99: .float .99
.p2align 4
spxe_sign: .long 0x80000000, 0, 0, 0
spxe_pitch_books:
    .quad spx_gain_cdbk_nb
    .long 7, 7
    .quad spx_gain_cdbk_lbr
    .long 7, 5
    .quad spx_gain_cdbk_lbr
    .long 0, 5
# Pointer, subvector width/count, index bits, separate sign bit.
spxe_shape_books:
    .quad spx_exc_10_16_table
    .long 10, 4, 4, 0
    .quad spx_exc_20_32_table
    .long 20, 2, 5, 0
    .quad spx_exc_10_32_table
    .long 10, 4, 5, 0
    .quad spx_exc_5_64_table
    .long 5, 8, 6, 0
    .quad spx_exc_8_128_table
    .long 8, 5, 7, 0
    .quad spx_exc_5_256_table
    .long 5, 8, 8, 0
    .quad spx_hexc_10_32_table
    .long 10, 4, 5, 0
    .quad spx_hexc_table
    .long 8, 5, 7, 1
.text

# RCX=initialized Bits -> EAX=1 valid/0, EDX=remaining bits,
# R8=whole source begin, R9=end. Does not modify caller state.
LOCALFN spxe_bits_valid
    test rcx, rcx
    jz .Lspxe_bv_bad
    mov r10, rcx
    add r10, SPXB_SIZE
    jc .Lspxe_bv_bad
    cmp dword ptr [rcx+SPXB_ERROR], 0
    jne .Lspxe_bv_bad
    mov edx, [rcx+SPXB_BITS]
    cmp edx, SPX_MAX_PACKET*8
    ja .Lspxe_bv_bad
    mov r11d, edx
    sub edx, [rcx+SPXB_POS]
    jc .Lspxe_bv_bad
    add r11d, 7
    shr r11d, 3
    mov r8, [rcx+SPXB_DATA]
    mov r9, r8
    test r11d, r11d
    jz .Lspxe_bv_ok
    test r8, r8
    jz .Lspxe_bv_bad
    add r9, r11
    jc .Lspxe_bv_bad
    cmp rcx, r9
    jae .Lspxe_bv_ok
    cmp r8, r10
    jb .Lspxe_bv_bad
.Lspxe_bv_ok:
    mov eax, 1
    ret
.Lspxe_bv_bad:
    xor eax, eax
    ret
ENDFN spxe_bits_valid

# RCX=array of [begin,end) qword pairs, EDX=count -> 1 when ordered and
# pairwise disjoint. Empty ranges are ignored. No memory is written.
LOCALFN spxe_disjoint
    push rbx
    xor r8d, r8d
.Lspxe_d_outer:
    mov eax, r8d
    shl eax, 4
    mov r10, [rcx+rax]
    mov r11, [rcx+rax+8]
    cmp r10, r11
    ja .Lspxe_d_bad
    je .Lspxe_d_next
    lea r9d, [r8+1]
.Lspxe_d_inner:
    cmp r9d, edx
    jae .Lspxe_d_next
    mov ebx, r9d
    shl ebx, 4
    mov rax, [rcx+rbx]
    cmp rax, [rcx+rbx+8]
    ja .Lspxe_d_bad
    je .Lspxe_d_skip
    cmp r10, [rcx+rbx+8]
    jae .Lspxe_d_skip
    cmp rax, r11
    jb .Lspxe_d_bad
.Lspxe_d_skip:
    inc r9d
    jmp .Lspxe_d_inner
.Lspxe_d_next:
    inc r8d
    cmp r8d, edx
    jb .Lspxe_d_outer
    mov eax, 1
    pop rbx
    ret
.Lspxe_d_bad:
    xor eax, eax
    pop rbx
    ret
ENDFN spxe_disjoint

# RCX=three finite float gains -> XMM0=float gain_3tap_to_1tap.
# Preserve the macro's double promotions and signed-zero ABS behavior.
LOCALFN spxe_gain_sum
    pxor xmm3, xmm3
    movss xmm0, [rcx+4]
    ucomiss xmm0, xmm3
    jae .Lspxe_gs_middle
    xorps xmm0, [rip+spxe_sign]
.Lspxe_gs_middle:
    cvtss2sd xmm0, xmm0
    movss xmm1, [rcx]
    ucomiss xmm1, xmm3
    cvtss2sd xmm1, xmm1
    ja .Lspxe_gs_left
    mulsd xmm1, [rip+spxe_neg_half64]
.Lspxe_gs_left:
    addsd xmm0, xmm1
    movss xmm1, [rcx+8]
    ucomiss xmm1, xmm3
    cvtss2sd xmm1, xmm1
    ja .Lspxe_gs_right
    mulsd xmm1, [rip+spxe_neg_half64]
.Lspxe_gs_right:
    addsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    ret
ENDFN spxe_gain_sum

# RCX=Bits, RDX=80-byte pitch request/result -> EAX=1/0.
# Kinds 0/1/2 decode three-tap pitch/gain books; kind 3 reconstructs forced
# pitch recursively and updates exc[0..samples). Samples 1..80, history <=512,
# start/end 1..144. All caller regions are disjoint. Decode and numeric
# failure roll back output, history, request results and bit position;
# only truncated-bit failure sets the original sticky reader error.
FN spx_pitch_decode
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 576
    mov rsi, rcx
    mov rbx, rdx
    test rbx, rbx
    jz .Lspxe_p_bad
    mov rax, rbx
    add rax, SPXE_SIZE
    jc .Lspxe_p_bad
    mov [rsp+88], rax
    mov [rsp+80], rbx
    call spxe_bits_valid
    test eax, eax
    jz .Lspxe_p_bad
    mov [rsp+520], edx
    mov [rsp+128], r8
    mov [rsp+136], r9
    mov [rsp+64], rsi
    lea rax, [rsi+SPXB_SIZE]
    mov [rsp+72], rax
    cmp rbx, rax
    jae .Lspxe_p_job_bits_clear
    cmp rsi, [rsp+88]
    jb .Lspxe_p_bad
.Lspxe_p_job_bits_clear:
    cmp r8, r9
    je .Lspxe_p_read_job
    cmp rbx, r9
    jae .Lspxe_p_read_job
    cmp r8, [rsp+88]
    jb .Lspxe_p_bad
.Lspxe_p_read_job:
    mov r12, [rbx+SPXE_EXC]
    mov rdi, [rbx+SPXE_OUT]
    test r12, r12
    jz .Lspxe_p_bad
    test rdi, rdi
    jz .Lspxe_p_bad
    mov r13d, [rbx+SPXE_SAMPLES]
    lea eax, [r13-1]
    cmp eax, 79
    ja .Lspxe_p_bad
    cmp [rbx+SPXE_CAPACITY], r13d
    jb .Lspxe_p_bad
    mov eax, [rbx+SPXE_HISTORY]
    lea ecx, [rax-1]
    cmp ecx, 511
    ja .Lspxe_p_bad
    shl eax, 2
    mov rcx, r12
    sub rcx, rax
    jc .Lspxe_p_bad
    mov [rsp+96], rcx
    lea rax, [r13*4]
    add rax, r12
    jc .Lspxe_p_bad
    mov [rsp+104], rax
    lea rax, [r13*4]
    add rax, rdi
    jc .Lspxe_p_bad
    mov [rsp+112], rdi
    mov [rsp+120], rax
    mov r14d, [rbx+SPXE_KIND]
    cmp r14d, 3
    ja .Lspxe_p_bad
    mov eax, [rbx+SPXE_START]
    lea ecx, [rax-1]
    cmp ecx, 143
    ja .Lspxe_p_bad
    cmp eax, [rbx+SPXE_END]
    ja .Lspxe_p_bad
    cmp dword ptr [rbx+SPXE_END], 144
    ja .Lspxe_p_bad
    lea rcx, [rsp+64]
    mov edx, 5
    call spxe_disjoint
    test eax, eax
    jz .Lspxe_p_bad
    movdqu xmm0, [rsi]
    movdqu [rsp+32], xmm0
    mov rax, [rsi+16]
    mov [rsp+48], rax
    cmp r14d, 3
    je .Lspxe_p_forced
    shl r14d, 4
    lea rax, [rip+spxe_pitch_books]
    add r14, rax
    mov edx, [r14+8]
    add edx, [r14+12]
    cmp [rsp+520], edx
    jb .Lspxe_p_truncated
    mov edx, [r14+8]
    lea rcx, [rsp+32]
    call spx_bits_read
    add eax, [rbx+SPXE_START]
    cmp eax, [rbx+SPXE_END]
    ja .Lspxe_p_bad
    mov r15d, eax
    lea ecx, [rax+1]
    mov [rsp+516], ecx
    cmp ecx, [rbx+SPXE_HISTORY]
    ja .Lspxe_p_bad
    mov edx, [r14+12]
    lea rcx, [rsp+32]
    call spx_bits_read
    shl eax, 2
    mov rdx, [r14]
    add rdx, rax
    xor ecx, ecx
.Lspxe_p_gain:
    movsx eax, byte ptr [rdx+rcx]
    cvtsi2ss xmm0, eax
    mulss xmm0, [rip+spxe_gain_scale]
    addss xmm0, [rip+spxe_half]
    movss [rsp+480+rcx*4], xmm0
    inc ecx
    cmp ecx, 3
    jb .Lspxe_p_gain
    cmp dword ptr [rbx+SPXE_LOST], 0
    je .Lspxe_p_history
    cmp r15d, [rbx+SPXE_OFFSET]
    jbe .Lspxe_p_history
    mov eax, [rbx+SPXE_LAST_GAIN]
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxe_p_bad
    movss xmm0, [rbx+SPXE_LAST_GAIN]
    pxor xmm1, xmm1
    ucomiss xmm0, xmm1
    jb .Lspxe_p_bad
    cmp dword ptr [rbx+SPXE_LOST], 4
    jb .Lspxe_p_limit
    cvtss2sd xmm0, xmm0
    mulsd xmm0, [rip+spxe_half64]
    cvtsd2ss xmm0, xmm0
.Lspxe_p_limit:
    cvtss2sd xmm1, xmm0
    ucomisd xmm1, [rip+spxe_limit95]
    jbe .Lspxe_p_limit_ready
    movss xmm0, [rip+spxe_gain95]
.Lspxe_p_limit_ready:
    movss [rsp+496], xmm0
    lea rcx, [rsp+480]
    call spxe_gain_sum
    movss xmm1, [rsp+496]
    ucomiss xmm0, xmm1
    jbe .Lspxe_p_history
    divss xmm1, xmm0
    movss xmm0, [rsp+480]
    mulss xmm0, xmm1
    movss [rsp+480], xmm0
    movss xmm0, [rsp+484]
    mulss xmm0, xmm1
    movss [rsp+484], xmm0
    movss xmm0, [rsp+488]
    mulss xmm0, xmm1
    movss [rsp+488], xmm0
.Lspxe_p_history:
    mov ecx, [rsp+516]
    neg rcx
.Lspxe_p_validate_history:
    mov eax, [r12+rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxe_p_bad
    inc rcx
    jnz .Lspxe_p_validate_history
    cmp dword ptr [rbx+SPXE_KIND], 3
    je .Lspxe_p_forced_samples
    xor eax, eax
.Lspxe_p_zero:
    mov dword ptr [rsp+160+rax*4], 0
    inc eax
    cmp eax, r13d
    jb .Lspxe_p_zero
    xor r14d, r14d
.Lspxe_p_tap:
    lea r10d, [r15+1]
    sub r10d, r14d                    # pp=pitch+1-i
    mov r11d, r13d
    cmp r11d, r10d
    cmova r11d, r10d
    mov ecx, 2
    sub ecx, r14d
    movss xmm0, [rsp+480+rcx*4]
    xor r8d, r8d
.Lspxe_p_first:
    cmp r8d, r11d
    jae .Lspxe_p_second_start
    mov eax, r8d
    sub eax, r10d
    movsxd rax, eax
    movss xmm1, [r12+rax*4]
    mulss xmm1, xmm0
    addss xmm1, [rsp+160+r8*4]
    movd eax, xmm1
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxe_p_bad
    movss [rsp+160+r8*4], xmm1
    inc r8d
    jmp .Lspxe_p_first
.Lspxe_p_second_start:
    lea r11d, [r10+r15]
    cmp r11d, r13d
    cmova r11d, r13d
.Lspxe_p_second:
    cmp r8d, r11d
    jae .Lspxe_p_next_tap
    mov eax, r8d
    sub eax, r10d
    sub eax, r15d
    movsxd rax, eax
    movss xmm1, [r12+rax*4]
    mulss xmm1, xmm0
    addss xmm1, [rsp+160+r8*4]
    movd eax, xmm1
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxe_p_bad
    movss [rsp+160+r8*4], xmm1
    inc r8d
    jmp .Lspxe_p_second
.Lspxe_p_next_tap:
    inc r14d
    cmp r14d, 3
    jb .Lspxe_p_tap
    jmp .Lspxe_p_commit
.Lspxe_p_forced:
    mov r15d, [rbx+SPXE_START]
    cmp r15d, [rbx+SPXE_HISTORY]
    ja .Lspxe_p_bad
    mov [rsp+516], r15d
    mov eax, [rbx+SPXE_COEF]
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxe_p_bad
    movss xmm0, [rbx+SPXE_COEF]
    pxor xmm1, xmm1
    ucomiss xmm0, xmm1
    jb .Lspxe_p_bad
    cvtss2sd xmm1, xmm0
    ucomisd xmm1, [rip+spxe_limit99]
    jbe .Lspxe_p_forced_coef
    movss xmm0, [rip+spxe_gain99]
.Lspxe_p_forced_coef:
    mov dword ptr [rsp+480], 0
    movss [rsp+484], xmm0
    mov dword ptr [rsp+488], 0
    jmp .Lspxe_p_history
.Lspxe_p_forced_samples:
    movss xmm0, [rsp+484]
    xor r8d, r8d
.Lspxe_p_forced_loop:
    mov eax, r8d
    sub eax, r15d
    js .Lspxe_p_forced_old
    movss xmm1, [rsp+160+rax*4]
    jmp .Lspxe_p_forced_multiply
.Lspxe_p_forced_old:
    movsxd rax, eax
    movss xmm1, [r12+rax*4]
.Lspxe_p_forced_multiply:
    mulss xmm1, xmm0
    movd eax, xmm1
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxe_p_bad
    movss [rsp+160+r8*4], xmm1
    inc r8d
    cmp r8d, r13d
    jb .Lspxe_p_forced_loop
.Lspxe_p_commit:
    lea rcx, [rsp+480]
    call spxe_gain_sum
    movss [rsp+500], xmm0
    xor ecx, ecx
.Lspxe_p_commit_samples:
    mov eax, [rsp+160+rcx*4]
    mov [rdi+rcx*4], eax
    cmp dword ptr [rbx+SPXE_KIND], 3
    jne .Lspxe_p_commit_next
    mov [r12+rcx*4], eax
.Lspxe_p_commit_next:
    inc ecx
    cmp ecx, r13d
    jb .Lspxe_p_commit_samples
    mov [rbx+SPXE_PITCH], r15d
    mov eax, [rsp+480]
    mov [rbx+SPXE_GAINS], eax
    mov eax, [rsp+484]
    mov [rbx+SPXE_GAINS+4], eax
    mov eax, [rsp+488]
    mov [rbx+SPXE_GAINS+8], eax
    mov eax, [rsp+500]
    mov [rbx+SPXE_GAIN_SUM], eax
    mov dword ptr [rbx+SPXE_RESERVED], 0
    mov eax, [rsp+32+SPXB_POS]
    mov [rsi+SPXB_POS], eax
    mov eax, 1
    jmp .Lspxe_p_return
.Lspxe_p_truncated:
    mov rcx, rsi
    call spx_bits_advance
.Lspxe_p_bad:
    xor eax, eax
.Lspxe_p_return:
    add rsp, 576
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN spx_pitch_decode

# RCX=Bits, RDX=40-float additive excitation, R8D=book 0..7,
# R9D=capacity -> EAX=40/0. All bit/out regions must be disjoint. Existing
# excitation is added to in double exactly as the float reference does.
# Output and position commit together; short input only sets sticky error.
FN spx_innovation_decode
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 384
    mov rbx, rcx
    mov rsi, rdx
    cmp r8d, 7
    ja .Lspxe_i_bad
    cmp r9d, 40
    jb .Lspxe_i_bad
    test rsi, rsi
    jz .Lspxe_i_bad
    mov [rsp+352], r8d
    mov rax, rsi
    add rax, 160
    jc .Lspxe_i_bad
    mov [rsp+96], rsi
    mov [rsp+104], rax
    call spxe_bits_valid
    test eax, eax
    jz .Lspxe_i_bad
    mov [rsp+356], edx
    mov [rsp+64], rbx
    lea rax, [rbx+SPXB_SIZE]
    mov [rsp+72], rax
    mov [rsp+80], r8
    mov [rsp+88], r9
    lea rcx, [rsp+64]
    mov edx, 3
    call spxe_disjoint
    test eax, eax
    jz .Lspxe_i_bad
    mov eax, [rsp+352]
    imul eax, eax, 24
    lea rdi, [rip+spxe_shape_books]
    add rdi, rax
    mov r13d, [rdi+8]
    mov r12d, [rdi+12]
    mov r14d, [rdi+16]
    mov edx, r14d
    add edx, [rdi+20]
    imul edx, r12d
    cmp [rsp+356], edx
    jb .Lspxe_i_truncated
    xor ecx, ecx
.Lspxe_i_validate:
    mov eax, [rsi+rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxe_i_bad
    inc ecx
    cmp ecx, 40
    jb .Lspxe_i_validate
    movdqu xmm0, [rbx]
    movdqu [rsp+32], xmm0
    mov rax, [rbx+16]
    mov [rsp+48], rax
    xor r15d, r15d
.Lspxe_i_index:
    xor eax, eax
    cmp dword ptr [rdi+20], 0
    je .Lspxe_i_index_sign
    lea rcx, [rsp+32]
    mov edx, 1
    call spx_bits_read
.Lspxe_i_index_sign:
    mov [rsp+320+r15*4], eax
    lea rcx, [rsp+32]
    mov edx, r14d
    call spx_bits_read
    mov [rsp+288+r15*4], eax
    inc r15d
    cmp r15d, r12d
    jb .Lspxe_i_index
    xor r15d, r15d
.Lspxe_i_vector:
    mov eax, [rsp+288+r15*4]
    imul eax, r13d
    mov rdx, [rdi]
    add rdx, rax
    mov r10d, r15d
    imul r10d, r13d
    movsd xmm2, [rip+spxe_shape_scale]
    cmp dword ptr [rsp+320+r15*4], 0
    je .Lspxe_i_vector_scale
    movsd xmm2, [rip+spxe_shape_neg_scale]
.Lspxe_i_vector_scale:
    mov r8d, r13d
.Lspxe_i_sample:
    movsx eax, byte ptr [rdx]
    cvtsi2sd xmm0, eax
    mulsd xmm0, xmm2
    movss xmm1, [rsi+r10*4]
    cvtss2sd xmm1, xmm1
    addsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    movd eax, xmm0
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxe_i_bad
    movss [rsp+128+r10*4], xmm0
    inc rdx
    inc r10d
    dec r8d
    jnz .Lspxe_i_sample
    inc r15d
    cmp r15d, r12d
    jb .Lspxe_i_vector
    xor ecx, ecx
.Lspxe_i_commit:
    mov eax, [rsp+128+rcx*4]
    mov [rsi+rcx*4], eax
    inc ecx
    cmp ecx, 40
    jb .Lspxe_i_commit
    mov eax, [rsp+32+SPXB_POS]
    mov [rbx+SPXB_POS], eax
    mov eax, 40
    jmp .Lspxe_i_return
.Lspxe_i_truncated:
    mov rcx, rbx
    call spx_bits_advance
.Lspxe_i_bad:
    xor eax, eax
.Lspxe_i_return:
    add rsp, 384
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN spx_innovation_decode

# RCX=output, EDX=samples 0..640, R8=uint32 seed, XMM3=float deviation >=0
# -> EAX=1/0. Output and seed must be disjoint. Bit-exact reference LCG and
# double 3.4642*deviation*centered_mantissa, followed by float conversion.
# Atomic output/seed commit, including on late nonfinite arithmetic failure.
FN spx_noise_decode
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 2640
    mov rbx, rcx
    mov rsi, r8
    mov r12d, edx
    cmp r12d, 640
    ja .Lspxe_n_bad
    test r12d, r12d
    jz .Lspxe_n_ok
    test rbx, rbx
    jz .Lspxe_n_bad
    test rsi, rsi
    jz .Lspxe_n_bad
    lea rax, [r12*4]
    add rax, rbx
    jc .Lspxe_n_bad
    mov rdx, rsi
    add rdx, 4
    jc .Lspxe_n_bad
    cmp rbx, rdx
    jae .Lspxe_n_disjoint
    cmp rsi, rax
    jb .Lspxe_n_bad
.Lspxe_n_disjoint:
    movd eax, xmm3
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxe_n_bad
    pxor xmm0, xmm0
    ucomiss xmm3, xmm0
    jb .Lspxe_n_bad
    cvtss2sd xmm2, xmm3
    mulsd xmm2, [rip+spxe_noise_scale]
    mov r13d, [rsi]
    xor edi, edi
.Lspxe_n_sample:
    imul r13d, r13d, 1664525
    add r13d, 1013904223
    mov eax, r13d
    and eax, 0x007fffff
    or eax, 0x3f800000
    movd xmm0, eax
    cvtss2sd xmm0, xmm0
    subsd xmm0, [rip+spxe_noise_center]
    mulsd xmm0, xmm2
    cvtsd2ss xmm0, xmm0
    movd eax, xmm0
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxe_n_bad
    movss [rsp+32+rdi*4], xmm0
    inc edi
    cmp edi, r12d
    jb .Lspxe_n_sample
    xor ecx, ecx
.Lspxe_n_commit:
    mov eax, [rsp+32+rcx*4]
    mov [rbx+rcx*4], eax
    inc ecx
    cmp ecx, r12d
    jb .Lspxe_n_commit
    mov [rsi], r13d
.Lspxe_n_ok:
    mov eax, 1
    jmp .Lspxe_n_return
.Lspxe_n_bad:
    xor eax, eax
.Lspxe_n_return:
    add rsp, 2640
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN spx_noise_decode
