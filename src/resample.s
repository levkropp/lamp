# Original windowed-sinc polyphase resampler for stereo float PCM. MIT, see LICENSE.
# Kaiser window (beta 9) over 64 sinc zero crossings per side at the lower
# rate's cutoff (0.955 of its Nyquist frequency): passband to about 0.91 of
# Nyquist, at least 90 dB stopband attenuation from Nyquist upward.
# Output frame k is the input interpolated at k*in/out; the filter is
# symmetric, so there is no delay. Each phase is normalized to unit DC gain.
# All arithmetic is SSE2, so Windows and Linux compute identical tables.
# A link of N input frames yields ceil(N*out/in) output frames.
.include "lamp.inc"
.globl resample_half

.equ RS_ZEROS, 64
.equ RS_CHUNK, 4096
.equ RS_TABLE_CAP, 1048576        # phase rows times taps; 8 MiB of duplicated floats

RODATA
.p2align 3
rs_rho: .double 0.955
rs_beta: .double 9.0
rs_one: .double 1.0
rs_quarter: .double 0.25
rs_epsilon: .double 1.0e-17
rs_pi: .quad 0x400921fb54442d18
# sin(pi*f) = f*(c0 + f^2*(c1 + ...)), Taylor terms through f^23, |f| <= 0.5.
rs_sin_terms:
    .quad 0xbda7215f879e1ac9, 0x3e02877020d52cf0, 0xbe58a404211f9547
    .quad 0x3eaaaec32af93359, 0xbef6fadb9f155744, 0x3f3e8f434d018d63
    .quad 0xbf7e3074fde8871f, 0x3fb50783487ee782, 0xbfe32d2cce62bd86
    .quad 0x400466bc6775aae2, 0xc014abbce625be53, 0x400921fb54442d18

.data
rs_memory: .quad 0
rs_table: .quad 0                 # rows of 2*taps floats, each coefficient twice
rs_row: .quad 0                   # interpolated row scratch, also setup doubles
rs_buffer: .quad 0                # stereo float input frames
rs_capacity: .quad 0              # frames
rs_source: .quad 0                # RCX=stereo float output, EDX=frames -> EAX=frames
rs_in: .quad 0                    # reduced input rate
rs_out: .quad 0                   # reduced output rate
resample_half: .long 0            # H: taps span input frames index-H+1 .. index+H
rs_taps: .long 0
rs_phases: .long 0
rs_exact: .long 0
rs_step: .quad 0
rs_step_frac: .quad 0
rs_base: .quad 0                  # signed input frame of buffer[0]
rs_fill: .quad 0
rs_index: .quad 0                 # floor(k*in/out)
rs_phase: .quad 0                 # k*in mod out
rs_eof: .long 0
rs_end: .quad 0
rs_fc: .double 0.0
rs_i0_beta: .double 0.0

.text
FN resample_close
    sub rsp, 40
    mov rcx, [rip + rs_memory]
    test rcx, rcx
    jz .Lrs_close_done
    call mem_free
    mov qword ptr [rip + rs_memory], 0
.Lrs_close_done:
    add rsp, 40
    ret
ENDFN resample_close

# ECX=input rate, EDX=output rate, R8=source function -> EAX=1 on success.
# Builds the tables; call resample_reset before reading.
FN resample_open
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov esi, ecx
    mov edi, edx
    mov [rip + rs_source], r8
    call resample_close
    test esi, esi
    jz .Lrs_open_bad
    test edi, edi
    jz .Lrs_open_bad
    mov eax, esi
    mov ecx, edi
.Lrs_gcd:
    test ecx, ecx
    jz .Lrs_gcd_done
    xor edx, edx
    div ecx
    mov eax, ecx
    mov ecx, edx
    jmp .Lrs_gcd
.Lrs_gcd_done:
    mov ecx, eax
    mov eax, esi
    xor edx, edx
    div ecx
    mov [rip + rs_in], rax
    mov eax, edi
    xor edx, edx
    div ecx
    mov [rip + rs_out], rax
    mov rax, [rip + rs_in]
    xor edx, edx
    div qword ptr [rip + rs_out]
    mov [rip + rs_step], rax
    mov [rip + rs_step_frac], rdx
    # Half width in input frames: the zero crossings stretch when downsampling.
    mov eax, RS_ZEROS
    cmp esi, edi
    jbe .Lrs_half_ready
    mov eax, esi
    imul rax, rax, RS_ZEROS
    add rax, rdi
    dec rax
    xor edx, edx
    div rdi
.Lrs_half_ready:
    inc eax
    and eax, -2                   # even, so taps are a multiple of four
    mov [rip + resample_half], eax
    lea ebx, [rax + rax]
    mov [rip + rs_taps], ebx
    mov eax, RS_TABLE_CAP
    xor edx, edx
    div ebx
    mov ecx, [rip + rs_out]
    mov dword ptr [rip + rs_exact], 1
    cmp rcx, rax
    jbe .Lrs_phases_ready
    mov ecx, eax                  # interpolate between this many phase rows
    mov dword ptr [rip + rs_exact], 0
.Lrs_phases_ready:
    mov [rip + rs_phases], ecx
    mov r12d, ecx                 # rows
    cmp dword ptr [rip + rs_exact], 0
    jne .Lrs_rows_ready
    inc r12d
.Lrs_rows_ready:
    mov eax, r12d
    imul rax, rbx
    shl rax, 3
    mov r13, rax                  # table bytes
    mov eax, [rip + resample_half]
    imul rax, rax, 3
    add rax, RS_CHUNK
    mov [rip + rs_capacity], rax
    shl rax, 3
    lea rcx, [r13 + rbx*8]
    add rcx, rax
    call mem_alloc
    test rax, rax
    jz .Lrs_open_bad
    mov [rip + rs_memory], rax
    mov [rip + rs_table], rax
    add rax, r13
    mov [rip + rs_row], rax
    lea rax, [rax + rbx*8]
    mov [rip + rs_buffer], rax
    # Cutoff relative to the input Nyquist frequency.
    movsd xmm0, [rip + rs_rho]
    cmp esi, edi
    jbe .Lrs_cutoff_ready
    cvtsi2sd xmm1, edi
    cvtsi2sd xmm2, esi
    divsd xmm1, xmm2
    mulsd xmm0, xmm1
.Lrs_cutoff_ready:
    movsd [rip + rs_fc], xmm0
    movsd xmm0, [rip + rs_beta]
    call rs_bessel_i0
    movsd [rip + rs_i0_beta], xmm0
    xor r14d, r14d                # row
.Lrs_row:
    cmp r14d, r12d
    jae .Lrs_rows_done
    xorpd xmm0, xmm0
    movsd [rsp + 32], xmm0        # row sum
    xor r15d, r15d                # tap
.Lrs_tap:
    cmp r15d, ebx
    jae .Lrs_row_normalize
    # x = (tap - H + 1) - row/phases
    mov eax, r15d
    sub eax, [rip + resample_half]
    inc eax
    cvtsi2sd xmm0, eax
    cvtsi2sd xmm1, r14d
    cvtsi2sd xmm2, dword ptr [rip + rs_phases]
    divsd xmm1, xmm2
    subsd xmm0, xmm1
    call rs_kernel
    mov rax, [rip + rs_row]
    movsd [rax + r15*8], xmm0
    addsd xmm0, [rsp + 32]
    movsd [rsp + 32], xmm0
    inc r15d
    jmp .Lrs_tap
.Lrs_row_normalize:
    movsd xmm1, [rip + rs_one]
    divsd xmm1, [rsp + 32]
    mov eax, r14d
    imul rax, rbx
    shl rax, 3
    add rax, [rip + rs_table]
    mov rdx, [rip + rs_row]
    xor ecx, ecx
.Lrs_store:
    movsd xmm0, [rdx + rcx*8]
    mulsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    movss [rax + rcx*8], xmm0
    movss [rax + rcx*8 + 4], xmm0
    inc ecx
    cmp ecx, ebx
    jb .Lrs_store
    inc r14d
    jmp .Lrs_row
.Lrs_rows_done:
    mov eax, 1
    jmp .Lrs_open_return
.Lrs_open_bad:
    call resample_close
    xor eax, eax
.Lrs_open_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN resample_open

# XMM0=x input frames from the output instant -> XMM0=windowed-sinc weight.
LOCALFN rs_kernel
    sub rsp, 56
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jne .Lrs_kernel_sinc
    movsd xmm0, [rip + rs_fc]
    jmp .Lrs_kernel_return
.Lrs_kernel_sinc:
    movsd [rsp + 32], xmm0
    # Window first: zero outside the span.
    cvtsi2sd xmm1, dword ptr [rip + resample_half]
    divsd xmm0, xmm1
    mulsd xmm0, xmm0
    movsd xmm1, [rip + rs_one]
    subsd xmm1, xmm0
    xorpd xmm0, xmm0
    ucomisd xmm1, xmm0
    jbe .Lrs_kernel_return
    sqrtsd xmm1, xmm1
    mulsd xmm1, [rip + rs_beta]
    movapd xmm0, xmm1
    call rs_bessel_i0
    divsd xmm0, [rip + rs_i0_beta]
    movsd [rsp + 40], xmm0
    # sin(pi*fc*x)/(pi*x), reduced to |f| <= 1/2 half-cycles.
    movsd xmm0, [rsp + 32]
    mulsd xmm0, [rip + rs_fc]
    cvtsd2si rax, xmm0
    cvtsi2sd xmm1, rax
    subsd xmm0, xmm1
    movapd xmm2, xmm0
    mulsd xmm2, xmm2
    lea rdx, [rip + rs_sin_terms]
    movsd xmm1, [rdx]
    mov ecx, 1
.Lrs_sin_term:
    mulsd xmm1, xmm2
    addsd xmm1, [rdx + rcx*8]
    inc ecx
    cmp ecx, 12
    jb .Lrs_sin_term
    mulsd xmm1, xmm0
    test eax, 1
    jz .Lrs_sin_sign
    xorpd xmm0, xmm0
    subsd xmm0, xmm1
    movapd xmm1, xmm0
.Lrs_sin_sign:
    movsd xmm0, [rsp + 32]
    mulsd xmm0, [rip + rs_pi]
    divsd xmm1, xmm0
    mulsd xmm1, [rsp + 40]
    movapd xmm0, xmm1
.Lrs_kernel_return:
    add rsp, 56
    ret
ENDFN rs_kernel

# XMM0=y -> XMM0=I0(y), the zeroth-order modified Bessel function.
LOCALFN rs_bessel_i0
    mulsd xmm0, xmm0
    mulsd xmm0, [rip + rs_quarter]
    movsd xmm1, [rip + rs_one]    # sum
    movsd xmm2, xmm1              # term
    mov ecx, 1
.Lrs_i0_term:
    cvtsi2sd xmm3, ecx
    mulsd xmm3, xmm3
    mulsd xmm2, xmm0
    divsd xmm2, xmm3
    addsd xmm1, xmm2
    movsd xmm3, xmm1
    mulsd xmm3, [rip + rs_epsilon]
    ucomisd xmm2, xmm3
    jbe .Lrs_i0_done
    inc ecx
    cmp ecx, 500
    jb .Lrs_i0_term
.Lrs_i0_done:
    movapd xmm0, xmm1
    ret
ENDFN rs_bessel_i0

# RCX=first input frame the source will deliver (0 for the start) ->
# RAX=first output frame produced. A nonzero start yields the first output
# whose whole span lies at or after it.
FN resample_reset
    push rdi
    mov dword ptr [rip + rs_eof], 0
    mov qword ptr [rip + rs_end], 0
    test rcx, rcx
    jnz .Lrs_reset_later
    mov ecx, [rip + resample_half]
    mov [rip + rs_fill], rcx
    neg rcx
    mov [rip + rs_base], rcx
    mov rdi, [rip + rs_buffer]
    mov ecx, [rip + resample_half]
    shl ecx, 1                    # two floats per frame
    xor eax, eax
    rep stosd
    mov qword ptr [rip + rs_index], 0
    mov qword ptr [rip + rs_phase], 0
    xor eax, eax
    jmp .Lrs_reset_return
.Lrs_reset_later:
    mov [rip + rs_base], rcx
    mov qword ptr [rip + rs_fill], 0
    mov eax, [rip + resample_half]
    lea rax, [rcx + rax - 1]
    mul qword ptr [rip + rs_out]
    mov rcx, [rip + rs_in]
    dec rcx
    add rax, rcx
    adc rdx, 0
    div qword ptr [rip + rs_in]
    mov rdi, rax                  # first output frame
    mul qword ptr [rip + rs_in]
    div qword ptr [rip + rs_out]
    mov [rip + rs_index], rax
    mov [rip + rs_phase], rdx
    mov rax, rdi
.Lrs_reset_return:
    pop rdi
    ret
ENDFN resample_reset

# RCX=stereo float output, EDX=frame capacity -> EAX=frames. 0 at the end or
# when the source fails; the source sets decode_error.
FN resample_read
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov r13, rcx
    mov r12d, edx
    xor ebx, ebx
.Lrs_read_next:
    cmp ebx, r12d
    jae .Lrs_read_done
    mov rax, [rip + rs_index]
    cmp dword ptr [rip + rs_eof], 0
    je .Lrs_read_need
    cmp rax, [rip + rs_end]
    jge .Lrs_read_done
.Lrs_read_need:
    mov ecx, [rip + resample_half]
    add rcx, rax                  # last input frame needed
    mov r8, [rip + rs_base]
    add r8, [rip + rs_fill]
    cmp rcx, r8
    jl .Lrs_read_ready
    cmp dword ptr [rip + rs_eof], 0
    jne .Lrs_read_done
    # Drop frames before the first one still needed, then refill.
    mov ecx, [rip + resample_half]
    mov rdx, rax
    sub rdx, rcx
    inc rdx
    sub rdx, [rip + rs_base]
    jle .Lrs_read_pull
    mov rax, [rip + rs_fill]
    cmp rdx, rax
    cmova rdx, rax
    add [rip + rs_base], rdx
    sub [rip + rs_fill], rdx
    mov rdi, [rip + rs_buffer]
    lea rsi, [rdi + rdx*8]
    mov rcx, [rip + rs_fill]
    shl rcx, 3
    rep movsb
.Lrs_read_pull:
    mov rcx, [rip + rs_fill]
    mov rdx, [rip + rs_capacity]
    sub rdx, rcx
    mov eax, [rip + resample_half]
    sub rdx, rax                  # keep room for the closing zeros
    shl rcx, 3
    add rcx, [rip + rs_buffer]
    call qword ptr [rip + rs_source]
    test eax, eax
    jz .Lrs_read_source_end
    add [rip + rs_fill], rax
    jmp .Lrs_read_next
.Lrs_read_source_end:
    cmp dword ptr [rip + decode_error], 0
    jne .Lrs_read_done
    mov dword ptr [rip + rs_eof], 1
    mov rax, [rip + rs_base]
    add rax, [rip + rs_fill]
    mov [rip + rs_end], rax
    mov rdi, [rip + rs_fill]
    shl rdi, 3
    add rdi, [rip + rs_buffer]
    mov ecx, [rip + resample_half]
    add [rip + rs_fill], rcx
    shl ecx, 1
    xor eax, eax
    rep stosd
    jmp .Lrs_read_next
.Lrs_read_ready:
    mov r14d, [rip + rs_taps]
    mov rax, r14
    shl rax, 3                    # row bytes
    cmp dword ptr [rip + rs_exact], 0
    je .Lrs_read_interpolate
    mul qword ptr [rip + rs_phase]
    mov r9, rax
    add r9, [rip + rs_table]
    jmp .Lrs_read_dot
.Lrs_read_interpolate:
    mov r15, rax
    cvtsi2sd xmm0, qword ptr [rip + rs_phase]
    cvtsi2sd xmm1, dword ptr [rip + rs_phases]
    mulsd xmm0, xmm1
    cvtsi2sd xmm1, qword ptr [rip + rs_out]
    divsd xmm0, xmm1
    cvttsd2si rax, xmm0
    cvtsi2sd xmm1, rax
    subsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    shufps xmm0, xmm0, 0
    mul r15
    mov r10, rax
    add r10, [rip + rs_table]
    lea r11, [r10 + r15]
    mov r9, [rip + rs_row]
    xor ecx, ecx
.Lrs_read_blend:
    movaps xmm1, [r10 + rcx]
    movaps xmm2, [r11 + rcx]
    subps xmm2, xmm1
    mulps xmm2, xmm0
    addps xmm1, xmm2
    movaps [r9 + rcx], xmm1
    add rcx, 16
    cmp rcx, r15
    jb .Lrs_read_blend
.Lrs_read_dot:
    mov rax, [rip + rs_index]
    mov ecx, [rip + resample_half]
    sub rax, rcx
    inc rax
    sub rax, [rip + rs_base]
    shl rax, 3
    add rax, [rip + rs_buffer]
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    mov ecx, r14d
    shr ecx, 2
.Lrs_read_taps:
    movups xmm2, [rax]
    movups xmm3, [rax + 16]
    mulps xmm2, [r9]
    mulps xmm3, [r9 + 16]
    addps xmm0, xmm2
    addps xmm1, xmm3
    add rax, 32
    add r9, 32
    dec ecx
    jnz .Lrs_read_taps
    addps xmm0, xmm1
    movhlps xmm1, xmm0
    addps xmm0, xmm1
    movsd [r13 + rbx*8], xmm0
    inc ebx
    mov rax, [rip + rs_phase]
    add rax, [rip + rs_step_frac]
    mov rcx, [rip + rs_step]
    cmp rax, [rip + rs_out]
    jb .Lrs_read_advance
    sub rax, [rip + rs_out]
    inc rcx
.Lrs_read_advance:
    mov [rip + rs_phase], rax
    add [rip + rs_index], rcx
    jmp .Lrs_read_next
.Lrs_read_done:
    mov eax, ebx
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN resample_read
