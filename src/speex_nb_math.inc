# Private fixed-size NB synthesis helpers. Speex 1.2.1 BSD reference:
# filters.c and ltp.c; see THIRD_PARTY_NOTICES. All spans are bounded by
# the owning narrowband arena. No heap, libm or system calls.

# XMM0=nonnegative float LSP distance -> float .6*exp(-.2*distance).
# Taylor series on x/64 (24 terms), then six squarings in binary64.
# Codec LSP distances are below 32; the caller's finite angle contract
# bounds the input to 320. Final binary32 rounding is oracle-checked.
LOCALFN spxn_recovery_factor
    cvtss2sd xmm0, xmm0
    mulsd xmm0, [rip+spxn_negpoint2]
    mulsd xmm0, [rip+spxn_div64]
    movsd xmm1, [rip+spxn_one64]
    movaps xmm2, xmm1
    mov ecx, 1
.Lspxn_exp_term:
    mulsd xmm1, xmm0
    cvtsi2sd xmm3, ecx
    divsd xmm1, xmm3
    addsd xmm2, xmm1
    inc ecx
    cmp ecx, 24
    jbe .Lspxn_exp_term
    mov ecx, 6
.Lspxn_exp_square:
    mulsd xmm2, xmm2
    dec ecx
    jnz .Lspxn_exp_square
    mulsd xmm2, [rip+spxn_point6]
    cvtsd2ss xmm0, xmm2
    ret
ENDFN spxn_recovery_factor

# RCX=x, EDX=count (80/160) -> XMM0=float RMS, reference float sum/division
# then double .1 addition and sqrt, finally rounded back to float.
LOCALFN spxn_rms
    pxor xmm0, xmm0
    xor eax, eax
.Lspxn_rms_loop:
    movss xmm1, [rcx+rax*4]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    inc eax
    cmp eax, edx
    jb .Lspxn_rms_loop
    cvtsi2ss xmm1, edx
    divss xmm0, xmm1
    cvtss2sd xmm0, xmm0
    addsd xmm0, [rip+spxn_point1]
    sqrtsd xmm0, xmm0
    cvtsd2ss xmm0, xmm0
    ret
ENDFN spxn_rms

# RCX=x, RDX=y -> XMM0=80-sample dot product grouped in four float MACs.
LOCALFN spxn_dot80
    pxor xmm0, xmm0
    xor eax, eax
.Lspxn_dot_loop:
    pxor xmm1, xmm1
    movss xmm2, [rcx+rax*4]
    mulss xmm2, [rdx+rax*4]
    addss xmm1, xmm2
    movss xmm2, [rcx+rax*4+4]
    mulss xmm2, [rdx+rax*4+4]
    addss xmm1, xmm2
    movss xmm2, [rcx+rax*4+8]
    mulss xmm2, [rdx+rax*4+8]
    addss xmm1, xmm2
    movss xmm2, [rcx+rax*4+12]
    mulss xmm2, [rdx+rax*4+12]
    addss xmm1, xmm2
    addss xmm0, xmm1
    add eax, 4
    cmp eax, 80
    jb .Lspxn_dot_loop
    ret
ENDFN spxn_dot80

# RCX=exc, RDX=80-sample output, R8D=signed pitch -> interpolated pitch
# vector. The enclosing 500-sample NB buffer supplies past/future margins.
LOCALFN spxn_interp_pitch
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 160
    mov rbx, rcx
    mov rsi, rdx
    mov edi, r8d
    xor r12d, r12d
.Lspxn_ip_corr:
    mov eax, r12d
    sub eax, edi
    sub eax, 3
    movsxd rax, eax
    lea rdx, [rbx+rax*4]
    mov rcx, rbx
    call spxn_dot80
    movss [rsp+32+r12*4], xmm0
    inc r12d
    cmp r12d, 7
    jb .Lspxn_ip_corr
    xor r12d, r12d
.Lspxn_ip_filter_row:
    xor r13d, r13d
.Lspxn_ip_filter_col:
    mov r14d, 3
    sub r14d, r13d
    xor eax, eax
    test r14d, r14d
    cmovs r14d, eax
    mov r15d, 10
    sub r15d, r13d
    cmp r15d, 7
    mov eax, 7
    cmova r15d, eax
    pxor xmm0, xmm0
    imul eax, r12d, 7
    lea r10, [rip+spxn_shift_filter]
    lea r10, [r10+rax*4]
.Lspxn_ip_filter_tap:
    lea eax, [r13+r14-3]
    movss xmm1, [rsp+32+rax*4]
    mulss xmm1, [r10+r14*4]
    addss xmm0, xmm1
    inc r14d
    cmp r14d, r15d
    jb .Lspxn_ip_filter_tap
    lea eax, [r12+1]
    imul eax, eax, 7
    add eax, r13d
    movss [rsp+32+rax*4], xmm0
    inc r13d
    cmp r13d, 7
    jb .Lspxn_ip_filter_col
    inc r12d
    cmp r12d, 3
    jb .Lspxn_ip_filter_row
    movss xmm0, [rsp+32]
    xor r12d, r12d                     # winning row
    xor r13d, r13d                     # winning column
    xor ecx, ecx
.Lspxn_ip_max:
    movss xmm1, [rsp+32+rcx*4]
    ucomiss xmm1, xmm0
    jbe .Lspxn_ip_max_next
    movaps xmm0, xmm1
    mov eax, ecx
    xor edx, edx
    mov r10d, 7
    div r10d
    mov r12d, eax
    mov r13d, edx
.Lspxn_ip_max_next:
    inc ecx
    cmp ecx, 28
    jb .Lspxn_ip_max
    sub edi, r13d
    add edi, 3
    xor r14d, r14d
    test r12d, r12d
    jz .Lspxn_ip_copy
    dec r12d
    imul r12d, r12d, 7
    lea r15, [rip+spxn_shift_filter]
    lea r15, [r15+r12*4]
.Lspxn_ip_sample:
    pxor xmm0, xmm0
    xor ecx, ecx
.Lspxn_ip_sample_tap:
    mov eax, r14d
    sub eax, edi
    add eax, ecx
    sub eax, 3
    movsxd rax, eax
    movss xmm1, [rbx+rax*4]
    mulss xmm1, [r15+rcx*4]
    addss xmm0, xmm1
    inc ecx
    cmp ecx, 7
    jb .Lspxn_ip_sample_tap
    movss [rsi+r14*4], xmm0
    inc r14d
    cmp r14d, 80
    jb .Lspxn_ip_sample
    jmp .Lspxn_ip_return
.Lspxn_ip_copy:
    mov eax, r14d
    sub eax, edi
    movsxd rax, eax
    mov eax, [rbx+rax*4]
    mov [rsi+r14*4], eax
    inc r14d
    cmp r14d, 80
    jb .Lspxn_ip_copy
.Lspxn_ip_return:
    add rsp, 160
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN spxn_interp_pitch

# RCX=exc, RDX=80-float output, R8D=pitch, XMM3=comb gain -> EAX=1/0.
# The reference's LPC/order parameters are unused by this comb algorithm.
LOCALFN spxn_comb80
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 1088
    mov rbx, rcx
    mov rsi, rdx
    mov edi, r8d
    movss [rsp+1024], xmm3
    lea rdx, [rsp+32]
    call spxn_interp_pitch
    mov rcx, rbx
    lea rdx, [rsp+352]
    mov r8d, edi
    neg r8d
    cmp edi, 40
    jbe .Lspxn_comb_second
    lea r8d, [rdi*2]
.Lspxn_comb_second:
    call spxn_interp_pitch
    lea rcx, [rsp+32]
    mov rdx, rcx
    call spxn_dot80
    addss xmm0, [rip+spxn_thousand]
    cvtss2sd xmm0, xmm0
    sqrtsd xmm0, xmm0
    cvtsd2ss xmm0, xmm0
    movss [rsp+1032], xmm0              # iexc0 magnitude
    lea rcx, [rsp+352]
    mov rdx, rcx
    call spxn_dot80
    addss xmm0, [rip+spxn_thousand]
    cvtss2sd xmm0, xmm0
    sqrtsd xmm0, xmm0
    cvtsd2ss xmm0, xmm0
    movss [rsp+1036], xmm0
    mov rcx, rbx
    mov rdx, rbx
    call spxn_dot80
    addss xmm0, [rip+spxn_one]
    cvtss2sd xmm0, xmm0
    sqrtsd xmm0, xmm0
    cvtsd2ss xmm0, xmm0
    movss [rsp+1040], xmm0              # excitation magnitude
    lea rcx, [rsp+32]
    mov rdx, rbx
    call spxn_dot80
    pxor xmm1, xmm1
    ucomiss xmm0, xmm1
    jae .Lspxn_comb_corr0
    pxor xmm0, xmm0
.Lspxn_comb_corr0:
    movss [rsp+1044], xmm0
    lea rcx, [rsp+352]
    mov rdx, rbx
    call spxn_dot80
    pxor xmm1, xmm1
    ucomiss xmm0, xmm1
    jae .Lspxn_comb_corr1
    pxor xmm0, xmm0
.Lspxn_comb_corr1:
    movss [rsp+1048], xmm0
    xor r12d, r12d
.Lspxn_comb_gains:
    movss xmm0, [rsp+1032+r12*4]
    mulss xmm0, [rsp+1040]
    movss xmm1, [rsp+1044+r12*4]
    ucomiss xmm1, xmm0
    jbe .Lspxn_comb_ratio
    movss xmm1, [rip+spxn_one]
    jmp .Lspxn_comb_ratio_done
.Lspxn_comb_ratio:
    divss xmm1, [rsp+1040]
    divss xmm1, [rsp+1032+r12*4]
.Lspxn_comb_ratio_done:
    movss [rsp+1052+r12*4], xmm1        # normalized correlation
    movss xmm0, [rsp+1040]
    divss xmm0, [rsp+1032+r12*4]
    movss [rsp+1060+r12*4], xmm0
    inc r12d
    cmp r12d, 2
    jb .Lspxn_comb_gains
    movss xmm0, [rsp+1024]
    cvtss2sd xmm0, xmm0
    mulsd xmm0, [rip+spxn_point4]
    addsd xmm0, [rip+spxn_point07]
    cvtsd2ss xmm0, xmm0
    movss [rsp+1068], xmm0              # c1
    cvtss2sd xmm1, xmm0
    subsd xmm1, [rip+spxn_point07]
    mulsd xmm1, [rip+spxn_1point72]
    addsd xmm1, [rip+spxn_half64]
    cvtsd2ss xmm1, xmm1
    movss [rsp+1072], xmm1              # c2
    xor r12d, r12d
.Lspxn_comb_gain:
    movss xmm0, [rsp+1072]
    mulss xmm0, [rsp+1052+r12*4]
    mulss xmm0, [rsp+1052+r12*4]
    movss xmm1, [rip+spxn_one]
    subss xmm1, xmm0
    movss xmm0, [rsp+1068]
    ucomiss xmm1, xmm0
    jae .Lspxn_comb_gain_min
    movaps xmm1, xmm0
.Lspxn_comb_gain_min:
    divss xmm0, xmm1
    mulss xmm0, [rsp+1060+r12*4]
    cvtss2sd xmm0, xmm0
    movsd xmm1, [rip+spxn_point6]
    cmp edi, 40
    jbe .Lspxn_comb_gain_factor
    movsd xmm1, [rip+spxn_point7]
    test r12d, r12d
    jz .Lspxn_comb_gain_factor
    movsd xmm1, [rip+spxn_point3]
.Lspxn_comb_gain_factor:
    mulsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    movss [rsp+1052+r12*4], xmm0
    inc r12d
    cmp r12d, 2
    jb .Lspxn_comb_gain
    xor eax, eax
.Lspxn_comb_output:
    movss xmm0, [rsp+32+rax*4]
    mulss xmm0, [rsp+1052]
    movss xmm1, [rsp+352+rax*4]
    mulss xmm1, [rsp+1056]
    addss xmm0, xmm1
    addss xmm0, [rbx+rax*4]
    movss [rsp+672+rax*4], xmm0
    inc eax
    cmp eax, 80
    jb .Lspxn_comb_output
    lea rcx, [rsp+672]
    mov edx, 80
    call spxn_rms
    movss [rsp+1032], xmm0
    mov rcx, rbx
    mov edx, 80
    call spxn_rms
    movss xmm1, [rip+spxn_one]
    ucomiss xmm0, xmm1
    jae .Lspxn_comb_old_min
    movaps xmm0, xmm1
.Lspxn_comb_old_min:
    movss xmm2, [rsp+1032]
    ucomiss xmm2, xmm1
    jae .Lspxn_comb_new_min
    movaps xmm2, xmm1
.Lspxn_comb_new_min:
    ucomiss xmm0, xmm2
    jbe .Lspxn_comb_energy
    movaps xmm0, xmm2
.Lspxn_comb_energy:
    divss xmm0, xmm2
    xor eax, eax
.Lspxn_comb_scale:
    movss xmm1, [rsp+672+rax*4]
    mulss xmm1, xmm0
    movd edx, xmm1
    and edx, 0x7fffffff
    cmp edx, 0x7f800000
    jae .Lspxn_comb_bad
    movss [rsi+rax*4], xmm1
    inc eax
    cmp eax, 80
    jb .Lspxn_comb_scale
    mov eax, 1
    jmp .Lspxn_comb_return
.Lspxn_comb_bad:
    xor eax, eax
.Lspxn_comb_return:
    add rsp, 1088
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN spxn_comb80
