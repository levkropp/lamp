# Bounded next-frame block-zero parsing. The current frame's bit reader,
# frame syntax, parameters and shared mantissa/SPX LFG are restored exactly.
# Current coefficients were captured already; next-frame AHT scratch may be
# overwritten, because its real block zero will rebuild it before use.
.bss
.p2align 6
eac3_ecpl_next: .zero 256*4
eac3_peek_frame: .zero AC3_MAX_BYTES+16
eac3_peek_context: .zero 8*AC3_FRAME_CONTEXT_WORDS
eac3_peek_data: .zero 8*EAC3_FRAME_DATA_WORDS
eac3_peek_arrays: .zero 8*EAC3_FRAME_ARRAY_WORDS
eac3_peek_lfg: .zero 64*4
eac3_peek_error: .zero 4
.text

# RCX=float[256] output. Raw C0, zero outside this block's own ECPL range.
# Returns 1 if a channel participates in ECPL, otherwise an all-zero row.
LOCALFN eac3_ecpl_spectrum
    push rdi
    mov r8, rcx
    mov rdi, rcx
    xor eax, eax
    mov ecx, 256
    rep stosd
    cmp dword ptr [rip + eac3_ecpl_active], 0
    je .Lecpl_spectrum_done
    mov ecx, 1
    lea rdx, [rip + ac3_incpl]
.Lecpl_spectrum_selected:
    cmp ecx, [rip + ac3_nf]
    ja .Lecpl_spectrum_done
    cmp dword ptr [rdx + rcx*4], 0
    jne .Lecpl_spectrum_values
    inc ecx
    jmp .Lecpl_spectrum_selected
.Lecpl_spectrum_values:
    lea rdx, [rip + ac3_fixed]
    mov ecx, [rip + ac3_start]
    movss xmm1, [rip + ac3_gain_scale]
.Lecpl_spectrum_bin:
    cvtsi2ss xmm0, dword ptr [rdx + rcx*4]
    mulss xmm0, xmm1
    movss [r8 + rcx*4], xmm0
    inc ecx
    cmp ecx, [rip + ac3_end]
    jb .Lecpl_spectrum_bin
    mov eax, 1
.Lecpl_spectrum_done:
    pop rdi
    ret
ENDFN eac3_ecpl_spectrum

# Current final parameters have already been saved by eac3_decode_blocks.
# Missing/incompatible/CRC-invalid/non-ECPL/malformed next blocks yield zero.
# This does not consume output samples or change the next frame's RNG state.
LOCALFN eac3_ecpl_lookahead
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    lea rdi, [rip + eac3_ecpl_next]
    xor eax, eax
    mov ecx, 256
    rep stosd
    mov rcx, [rip + ac3_next_pointer]
    test rcx, rcx
    jz .Lecpl_peek_return
    mov edx, [rip + ac3_next_bytes]
    cmp edx, 8
    jb .Lecpl_peek_return
    call ac3_header
    test eax, eax
    jz .Lecpl_peek_return
    cmp eax, [rip + ac3_next_bytes]
    ja .Lecpl_peek_return
    cmp edx, [rip + ac3_key]
    jne .Lecpl_peek_return
    mov r12d, eax
    mov r13d, r11d
    mov rcx, [rip + ac3_next_pointer]
    mov edx, r12d
    call ac3_crc
    test eax, eax
    jnz .Lecpl_peek_return
    lea rsi, [rip + ac3_frame]
    lea rdi, [rip + eac3_peek_frame]
    mov ecx, (AC3_MAX_BYTES+16)/8
    rep movsq
    lea rsi, [rip + ac3_frame_context]
    lea rdi, [rip + eac3_peek_context]
    mov ecx, offset AC3_FRAME_CONTEXT_WORDS
    rep movsq
    lea rsi, [rip + eac3_frame_data]
    lea rdi, [rip + eac3_peek_data]
    mov ecx, offset EAC3_FRAME_DATA_WORDS
    rep movsq
    lea rsi, [rip + eac3_frame_arrays]
    lea rdi, [rip + eac3_peek_arrays]
    mov ecx, offset EAC3_FRAME_ARRAY_WORDS
    rep movsq
    lea rsi, [rip + ac3_lfg]
    lea rdi, [rip + eac3_peek_lfg]
    mov ecx, 32
    rep movsq
    mov eax, [rip + decode_error]
    mov [rip + eac3_peek_error], eax
    mov rsi, [rip + ac3_next_pointer]
    lea rdi, [rip + ac3_frame]
    mov ecx, r12d
    rep movsb
    xor eax, eax
    mov ecx, 16
    rep stosb
    mov [rip + ac3_bitlimit], r12d
    mov dword ptr [rip + ac3_bitpos], 40
    mov [rip + ac3_blocks], r13d
    shl r13d, 8
    mov [rip + ac3_frame_samples], r13d
    call ac3_bsi
    cmp eax, 1
    jne .Lecpl_peek_restore
    xor ecx, ecx
    call ac3_block
    cmp eax, 1
    jne .Lecpl_peek_restore
    lea rcx, [rip + eac3_ecpl_next]
    call eac3_ecpl_spectrum
.Lecpl_peek_restore:
    lea rsi, [rip + eac3_peek_frame]
    lea rdi, [rip + ac3_frame]
    mov ecx, (AC3_MAX_BYTES+16)/8
    rep movsq
    lea rsi, [rip + eac3_peek_context]
    lea rdi, [rip + ac3_frame_context]
    mov ecx, offset AC3_FRAME_CONTEXT_WORDS
    rep movsq
    lea rsi, [rip + eac3_peek_data]
    lea rdi, [rip + eac3_frame_data]
    mov ecx, offset EAC3_FRAME_DATA_WORDS
    rep movsq
    lea rsi, [rip + eac3_peek_arrays]
    lea rdi, [rip + eac3_frame_arrays]
    mov ecx, offset EAC3_FRAME_ARRAY_WORDS
    rep movsq
    lea rsi, [rip + eac3_peek_lfg]
    lea rdi, [rip + ac3_lfg]
    mov ecx, 32
    rep movsq
    lea rsi, [rip + eac3_final_params]
    lea rdi, [rip + ac3_params]
    mov ecx, offset AC3_PARAMS_WORDS
    rep movsq
    mov eax, [rip + eac3_peek_error]
    mov [rip + decode_error], eax
.Lecpl_peek_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN eac3_ecpl_lookahead
