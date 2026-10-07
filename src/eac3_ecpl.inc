# Enhanced-coupling DSP, handwritten from ATSC A/52:2018 E.3.5.5.
# Three adjacent spectra -> non-aliased complex carrier -> channel spectrum.
# These bounded kernels do not yet enable ECPL bitstream acceptance.
RODATA
.include "eac3_ecpl_tables.inc"
eac3_ecpl_norm: .double 0.001953125       # 1/512 (DFT normalization)
eac3_ecpl_half: .double 0.5
eac3_ecpl_one: .double 1.0
eac3_ecpl_two: .double 2.0
eac3_ecpl_minus_two: .double -2.0
eac3_ecpl_compensation: .double 0.38
eac3_ecpl_pi: .double 3.1415926535897932384626433832795
.bss
.p2align 6
eac3_ecpl_time: .zero 3*512*8
eac3_ecpl_fft: .zero 512*16
eac3_ecpl_band_amp: .zero 22*8
eac3_ecpl_band_angle: .zero 22*8
eac3_ecpl_band_chaos: .zero 22*8
eac3_ecpl_band_center: .zero 22*8
.text

# RCX=float[256] spectrum; RDX=double[512] windowed IMDCT output.
# A/52 7.9.4.1 steps 1-5, excluding step 6's overlap factor 2.
LOCALFN eac3_ecpl_imdct
    push rbx
    sub rsp, 32
    mov rbx, rdx
    mov edx, 4
    mov r8d, 256
    lea r9, [rip + ac3_y]
    call ac3_dct4
    lea r8, [rip + ac3_y]
    lea r9, [rip + ac3_window]
    xor ecx, ecx
.Lecpl_imdct_value:
    movsd xmm0, [r8 + rcx*8 + 128*8]
    cvtss2sd xmm1, [r9 + rcx*4]
    mulsd xmm1, xmm0
    xorpd xmm2, xmm2
    subsd xmm2, xmm1
    movsd [rbx + rcx*8], xmm2
    mov eax, 255
    sub eax, ecx
    cvtss2sd xmm1, [r9 + rax*4]
    mulsd xmm0, xmm1
    movsd [rbx + rax*8], xmm0
    mov edx, 127
    sub edx, ecx
    movsd xmm0, [r8 + rdx*8]
    mulsd xmm1, xmm0
    movsd [rbx + rcx*8 + 256*8], xmm1
    cvtss2sd xmm1, [r9 + rcx*4]
    mulsd xmm0, xmm1
    movsd [rbx + rax*8 + 256*8], xmm0
    inc ecx
    cmp ecx, 128
    jb .Lecpl_imdct_value
    add rsp, 32
    pop rbx
    ret
ENDFN eac3_ecpl_imdct

# RCX/RDX/R8 = previous/current/next float[256], already zero outside each
# block's ECPL range. R9 = complex double[256] (real,imag interleaved).
# No delay/sample output: all neighboring spectra are supplied explicitly.
FN eac3_ecpl_carrier
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov r12, rdx
    mov r13, r8
    mov r14, r9
    lea rdx, [rip + eac3_ecpl_time]
    call eac3_ecpl_imdct
    mov rcx, r12
    lea rdx, [rip + eac3_ecpl_time + 512*8]
    call eac3_ecpl_imdct
    mov rcx, r13
    lea rdx, [rip + eac3_ecpl_time + 1024*8]
    call eac3_ecpl_imdct
    lea r12, [rip + eac3_ecpl_time]
    lea r13, [rip + eac3_ecpl_fft]
    lea r15, [rip + eac3_ecpl_rotation]
    lea r8, [rip + ac3_window]
    lea r9, [rip + eac3_ecpl_rev512]
    xor ecx, ecx
.Lecpl_carrier_overlap:
    # First half prev[256+n]+curr[n]; second curr[256+n]+next[n].
    cmp ecx, 256
    jae .Lecpl_carrier_overlap_second
    movsd xmm0, [r12 + rcx*8 + 256*8]
    addsd xmm0, [r12 + rcx*8 + 512*8]
    mov eax, ecx
    jmp .Lecpl_carrier_window
.Lecpl_carrier_overlap_second:
    movsd xmm0, [r12 + rcx*8 + 512*8]
    addsd xmm0, [r12 + rcx*8 + 768*8]
    mov eax, 511
    sub eax, ecx
.Lecpl_carrier_window:
    cvtss2sd xmm1, [r8 + rax*4]
    mulsd xmm0, xmm1
    unpcklpd xmm0, xmm0
    mov eax, ecx
    shl eax, 4
    mulpd xmm0, [r15 + rax]
    movzx eax, word ptr [r9 + rcx*2]
    shl eax, 4
    movapd [r13 + rax], xmm0
    inc ecx
    cmp ecx, 512
    jb .Lecpl_carrier_overlap
    lea r10, [rip + eac3_ecpl_twiddle]
    mov r8d, 2
.Lecpl_carrier_stage:
    cmp r8d, 512
    ja .Lecpl_carrier_normalize
    mov r9d, r8d
    shr r9d, 1
    mov eax, 512
    xor edx, edx
    div r8d
    shl eax, 5
    mov r11d, eax
    mov edi, r9d
    shl edi, 4
    xor ecx, ecx
.Lecpl_carrier_fft_block:
    cmp ecx, 512
    jae .Lecpl_carrier_stage_next
    mov eax, ecx
    shl eax, 4
    lea rsi, [r13 + rax]
    lea rbx, [rsi + rdi]
    xor edx, edx
    mov eax, r9d
.Lecpl_carrier_butterfly:
    movapd xmm0, [rbx]
    movapd xmm1, xmm0
    shufpd xmm1, xmm1, 1
    mulpd xmm0, [r10 + rdx]
    mulpd xmm1, [r10 + rdx + 16]
    addpd xmm0, xmm1
    movapd xmm1, [rsi]
    movapd xmm2, xmm1
    subpd xmm2, xmm0
    addpd xmm1, xmm0
    movapd [rsi], xmm1
    movapd [rbx], xmm2
    add rsi, 16
    add rbx, 16
    add edx, r11d
    dec eax
    jnz .Lecpl_carrier_butterfly
    add ecx, r8d
    jmp .Lecpl_carrier_fft_block
.Lecpl_carrier_stage_next:
    shl r8d, 1
    jmp .Lecpl_carrier_stage
.Lecpl_carrier_normalize:
    movsd xmm1, [rip + eac3_ecpl_norm]
    unpcklpd xmm1, xmm1
    xor ecx, ecx
.Lecpl_carrier_store:
    movapd xmm0, [r13 + rcx]
    mulpd xmm0, xmm1
    movupd [r14 + rcx], xmm0
    add ecx, 16
    cmp ecx, 256*16
    jb .Lecpl_carrier_store
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN eac3_ecpl_carrier

# Descriptor: uint32 count,flags; int32 edges[23]; uint8 amp[22],angle[22],
# chaos[22]. Flags FIRST=1, TRANSIENT=2, INTERPOLATE=4. R9=float[256] random
# values in [-1,1], per bin (transient callers duplicate per-band draws).
# RCX=carrier double[256][2], RDX=descriptor, R8=float[256] channel spectrum.
# Returns 1; invalid descriptors return 0 before writing any output.
# Only the selected range is written. Non-ECPL coefficients remain intact.
FN eac3_ecpl_channel
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov r13, rcx
    mov r12, rdx
    mov r14, r8
    mov r15, r9
    mov ebx, [r12]
    cmp ebx, 1
    jb .Lecpl_channel_bad
    cmp ebx, 22
    ja .Lecpl_channel_bad
    test dword ptr [r12 + 4], -8
    jnz .Lecpl_channel_bad
    mov eax, [r12 + 8]
    cmp eax, 13
    jb .Lecpl_channel_bad
    xor ecx, ecx
.Lecpl_channel_validate:
    mov edx, [r12 + rcx*4 + 12]
    cmp edx, eax
    jbe .Lecpl_channel_bad
    cmp edx, 253
    ja .Lecpl_channel_bad
    mov eax, edx
    cmp byte ptr [r12 + rcx + 100], 31
    ja .Lecpl_channel_bad
    cmp byte ptr [r12 + rcx + 122], 63
    ja .Lecpl_channel_bad
    cmp byte ptr [r12 + rcx + 144], 7
    ja .Lecpl_channel_bad
    inc ecx
    cmp ecx, ebx
    jb .Lecpl_channel_validate
    lea rsi, [rip + eac3_ecpl_band_amp]
    lea rdi, [rip + eac3_ecpl_band_angle]
    lea r8, [rip + eac3_ecpl_band_chaos]
    lea r9, [rip + eac3_ecpl_band_center]
    xor ecx, ecx
.Lecpl_channel_parameters:
    mov eax, [r12 + rcx*4 + 8]
    add eax, [r12 + rcx*4 + 12]
    dec eax
    cvtsi2sd xmm0, eax
    mulsd xmm0, [rip + eac3_ecpl_half]
    movsd [r9 + rcx*8], xmm0
    movzx eax, byte ptr [r12 + rcx + 100]
    lea rdx, [rip + eac3_ecpl_amp]
    movsd xmm0, [rdx + rax*8]
    xorpd xmm1, xmm1
    xorpd xmm2, xmm2
    test dword ptr [r12 + 4], 1
    jnz .Lecpl_channel_parameter_store
    movzx eax, byte ptr [r12 + rcx + 122]
    lea rdx, [rip + eac3_ecpl_angle]
    movsd xmm1, [rdx + rax*8]
    movzx eax, byte ptr [r12 + rcx + 144]
    lea rdx, [rip + eac3_ecpl_chaos]
    movsd xmm2, [rdx + rax*8]
    test dword ptr [r12 + 4], 2
    jnz .Lecpl_channel_parameter_store
    movsd xmm3, [rip + eac3_ecpl_compensation]
    mulsd xmm3, xmm2
    addsd xmm3, [rip + eac3_ecpl_one]
    mulsd xmm0, xmm3
.Lecpl_channel_parameter_store:
    movsd [rsi + rcx*8], xmm0
    movsd [rdi + rcx*8], xmm1
    movsd [r8 + rcx*8], xmm2
    inc ecx
    cmp ecx, ebx
    jb .Lecpl_channel_parameters
    xor r9d, r9d                         # bin's amplitude/chaos band
    xor r10d, r10d                       # interpolation segment
    mov ecx, [r12 + 8]
.Lecpl_channel_bin:
    cmp ecx, [r12 + r9*4 + 12]
    jb .Lecpl_channel_band_ready
    inc r9d
.Lecpl_channel_band_ready:
    movsd xmm0, [rdi + r9*8]
    cmp ebx, 1
    je .Lecpl_channel_decorrelate
    test dword ptr [r12 + 4], 4
    jz .Lecpl_channel_decorrelate
    lea r8, [rip + eac3_ecpl_band_center]
    cvtsi2sd xmm1, ecx
.Lecpl_channel_segment:
    lea eax, [r10 + 2]
    cmp eax, ebx
    jae .Lecpl_channel_interpolate
    ucomisd xmm1, [r8 + r10*8 + 8]
    jbe .Lecpl_channel_interpolate
    inc r10d
    jmp .Lecpl_channel_segment
.Lecpl_channel_interpolate:
    movsd xmm0, [rdi + r10*8]
    movsd xmm2, [rdi + r10*8 + 8]
    subsd xmm2, xmm0
    ucomisd xmm2, [rip + eac3_ecpl_one]
    jbe .Lecpl_channel_delta_lower
    subsd xmm2, [rip + eac3_ecpl_two]
.Lecpl_channel_delta_lower:
    movsd xmm3, [rip + eac3_ecpl_one]
    xorpd xmm4, xmm4
    subsd xmm4, xmm3
    ucomisd xmm2, xmm4
    jae .Lecpl_channel_slope
    addsd xmm2, [rip + eac3_ecpl_two]
.Lecpl_channel_slope:
    movsd xmm3, [r8 + r10*8 + 8]
    subsd xmm3, [r8 + r10*8]
    divsd xmm2, xmm3
    subsd xmm1, [r8 + r10*8]
    mulsd xmm1, xmm2
    addsd xmm0, xmm1
.Lecpl_channel_wrap_upper:
    ucomisd xmm0, [rip + eac3_ecpl_one]
    jbe .Lecpl_channel_wrap_lower
    subsd xmm0, [rip + eac3_ecpl_two]
    jmp .Lecpl_channel_wrap_upper
.Lecpl_channel_wrap_lower:
    movsd xmm1, [rip + eac3_ecpl_one]
    xorpd xmm2, xmm2
    subsd xmm2, xmm1
    ucomisd xmm0, xmm2
    jae .Lecpl_channel_decorrelate
    addsd xmm0, [rip + eac3_ecpl_two]
    jmp .Lecpl_channel_wrap_lower
.Lecpl_channel_decorrelate:
    lea r8, [rip + eac3_ecpl_band_chaos]
    movsd xmm1, [r8 + r9*8]
    cvtss2sd xmm2, [r15 + rcx*4]
    mulsd xmm1, xmm2
    addsd xmm0, xmm1
    movsd xmm1, [rip + eac3_ecpl_one]
    xorpd xmm2, xmm2
    subsd xmm2, xmm1
    ucomisd xmm0, xmm2
    jae .Lecpl_channel_chaos_upper
    addsd xmm0, [rip + eac3_ecpl_two]
.Lecpl_channel_chaos_upper:
    ucomisd xmm0, xmm1
    jb .Lecpl_channel_rotate
    subsd xmm0, [rip + eac3_ecpl_two]
.Lecpl_channel_rotate:
    movsd [rsp + 32], xmm0
    fld qword ptr [rsp + 32]
    fmul qword ptr [rip + eac3_ecpl_pi]
    fsincos
    fstp qword ptr [rsp + 32]             # cos
    fstp qword ptr [rsp + 40]             # sin; x87 stack empty
    mov eax, ecx
    shl eax, 4
    movsd xmm0, [r13 + rax]
    movsd xmm1, [r13 + rax + 8]
    movsd xmm2, xmm0
    movsd xmm3, xmm1
    mulsd xmm0, [rsp + 32]
    mulsd xmm1, [rsp + 40]
    subsd xmm0, xmm1                      # rotated real
    mulsd xmm2, [rsp + 40]
    mulsd xmm3, [rsp + 32]
    addsd xmm2, xmm3                      # rotated imaginary
    lea r8, [rip + eac3_ecpl_projection]
    mulsd xmm0, [r8 + rcx*8]
    mov eax, 255
    sub eax, ecx
    mulsd xmm2, [r8 + rax*8]
    addsd xmm0, xmm2
    mulsd xmm0, [rsi + r9*8]
    mulsd xmm0, [rip + eac3_ecpl_minus_two]
    cvtsd2ss xmm0, xmm0
    movss [r14 + rcx*4], xmm0
    inc ecx
    cmp ecx, [r12 + rbx*4 + 8]
    jb .Lecpl_channel_bin
    mov eax, 1
    jmp .Lecpl_channel_return
.Lecpl_channel_bad:
    xor eax, eax
.Lecpl_channel_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN eac3_ecpl_channel
