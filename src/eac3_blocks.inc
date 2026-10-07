# Bounded E-AC-3 block snapshots, separating parsing from synthesis.
# Adjacent spectra can be inspected before rendering a block. SPX noise
# is reserved in parse order, preserving its ordering with mantissa dither.
# Explicit OFFSET operands make layout-derived sizes immediate on LLVM too.
.bss
.p2align 6
eac3_block_params: .zero 6*AC3_PARAMS_BYTES
eac3_final_params: .zero AC3_PARAMS_BYTES
eac3_block_fixed: .zero 6*7*256*4
eac3_block_noise: .zero 6*1024*4       # at most five FBW channels * 180 bins
eac3_block_noise_count: .zero 6*4
eac3_block_valid: .zero 8
.text

# ECX=block. Capture coefficients/parameters and reserve SPX LFG words.
# Returns 1; a noise span exceeding the fixed row capacity returns 0.
LOCALFN eac3_capture_block
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov ebx, ecx
    mov edi, offset AC3_PARAMS_BYTES
    imul edi, ebx
    lea rax, [rip + eac3_block_params]
    add rdi, rax
    lea rsi, [rip + ac3_params]
    mov ecx, offset AC3_PARAMS_WORDS
    rep movsq
    imul edi, ebx, 7*256*4
    lea rax, [rip + eac3_block_fixed]
    add rdi, rax
    lea rsi, [rip + ac3_fixed]
    mov ecx, 7*256
    rep movsd
    xor r12d, r12d
    cmp dword ptr [rip + eac3_spx_active], 0
    je .Leac3_capture_count
    mov eax, [rip + eac3_spx_end]
    sub eax, [rip + eac3_spx_start]
    mov ecx, 1
    lea rdx, [rip + eac3_spx_ch]
.Leac3_capture_channels:
    cmp ecx, [rip + ac3_nf]
    ja .Leac3_capture_count
    cmp dword ptr [rdx + rcx*4], 0
    je .Leac3_capture_next_channel
    add r12d, eax
.Leac3_capture_next_channel:
    inc ecx
    jmp .Leac3_capture_channels
.Leac3_capture_count:
    cmp r12d, 1024
    ja .Leac3_capture_bad
    lea rax, [rip + eac3_block_noise_count]
    mov [rax + rbx*4], r12d
    shl ebx, 12
    lea rdi, [rip + eac3_block_noise]
    add rdi, rbx
.Leac3_capture_noise:
    test r12d, r12d
    jz .Leac3_capture_done
    call eac3_random
    mov [rdi], eax
    add rdi, 4
    dec r12d
    jmp .Leac3_capture_noise
.Leac3_capture_done:
    mov eax, 1
    jmp .Leac3_capture_return
.Leac3_capture_bad:
    xor eax, eax
.Leac3_capture_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN eac3_capture_block

# ECX=initial CRC/BSI error. Parse at most six blocks, then render in order.
# Synthesis history is never restored from a parser snapshot.
LOCALFN eac3_decode_blocks
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov r12d, ecx
    mov qword ptr [rip + eac3_spx_reserved_ptr], 0
    mov qword ptr [rip + eac3_spx_reserved_end], 0
    xor ebx, ebx
.Leac3_blocks_parse:
    lea rax, [rip + eac3_block_valid]
    mov byte ptr [rax + rbx], 0
    test r12d, r12d
    jnz .Leac3_blocks_parse_next
    mov ecx, ebx
    call ac3_block
    cmp eax, AC3_UNSUPPORTED
    je .Leac3_blocks_unsupported
    test eax, eax
    jz .Leac3_blocks_parse_bad
    mov ecx, ebx
    call eac3_capture_block
    test eax, eax
    jz .Leac3_blocks_parse_bad
    lea rax, [rip + eac3_block_valid]
    mov byte ptr [rax + rbx], 1
    jmp .Leac3_blocks_parse_next
.Leac3_blocks_parse_bad:
    mov r12d, 1
.Leac3_blocks_parse_next:
    inc ebx
    cmp ebx, [rip + ac3_blocks]
    jb .Leac3_blocks_parse
    lea rsi, [rip + ac3_params]
    lea rdi, [rip + eac3_final_params]
    mov ecx, offset AC3_PARAMS_WORDS
    rep movsq
    xor ebx, ebx
.Leac3_blocks_render:
    lea rax, [rip + eac3_block_valid]
    cmp byte ptr [rax + rbx], 0
    je .Leac3_blocks_conceal
    mov esi, offset AC3_PARAMS_BYTES
    imul esi, ebx
    lea rax, [rip + eac3_block_params]
    add rsi, rax
    lea rdi, [rip + ac3_params]
    mov ecx, offset AC3_PARAMS_WORDS
    rep movsq
    imul esi, ebx, 7*256*4
    lea rax, [rip + eac3_block_fixed]
    add rsi, rax
    lea rdi, [rip + ac3_fixed]
    mov ecx, 7*256
    rep movsd
    mov eax, ebx
    shl eax, 12
    lea rcx, [rip + eac3_block_noise]
    add rcx, rax
    mov [rip + eac3_spx_reserved_ptr], rcx
    lea rax, [rip + eac3_block_noise_count]
    mov eax, [rax + rbx*4]
    lea rax, [rcx + rax*4]
    mov [rip + eac3_spx_reserved_end], rax
    mov ecx, ebx
    call ac3_transform
    mov rax, [rip + eac3_spx_reserved_ptr]
    cmp rax, [rip + eac3_spx_reserved_end]
    jne .Leac3_blocks_bad
    jmp .Leac3_blocks_keep
.Leac3_blocks_conceal:
    xor r13d, r13d
.Leac3_blocks_conceal_channel:
    cmp r13d, [rip + ac3_channels]
    jae .Leac3_blocks_keep
    imul edi, r13d, AC3_FRAME*4
    lea rax, [rip + ac3_pcm]
    add rdi, rax
    mov eax, ebx
    shl eax, 10
    add rdi, rax
    mov esi, r13d
    shl esi, 10
    lea rax, [rip + ac3_last]
    add rsi, rax
    xor ecx, ecx
.Leac3_blocks_conceal_value:
    xor eax, eax
    cmp dword ptr [rip + ac3_has_last], 0
    je .Leac3_blocks_conceal_store
    mov eax, [rsi + rcx*4]
.Leac3_blocks_conceal_store:
    mov [rdi + rcx*4], eax
    inc ecx
    cmp ecx, AC3_BLOCK
    jb .Leac3_blocks_conceal_value
    inc r13d
    jmp .Leac3_blocks_conceal_channel
.Leac3_blocks_keep:
    xor r13d, r13d
.Leac3_blocks_keep_channel:
    cmp r13d, [rip + ac3_channels]
    jae .Leac3_blocks_render_next
    imul esi, r13d, AC3_FRAME*4
    lea rax, [rip + ac3_pcm]
    add rsi, rax
    mov eax, ebx
    shl eax, 10
    add rsi, rax
    mov edi, r13d
    shl edi, 10
    lea rax, [rip + ac3_last]
    add rdi, rax
    mov ecx, AC3_BLOCK
    rep movsd
    inc r13d
    jmp .Leac3_blocks_keep_channel
.Leac3_blocks_render_next:
    mov dword ptr [rip + ac3_has_last], 1
    inc ebx
    cmp ebx, [rip + ac3_blocks]
    jb .Leac3_blocks_render
    lea rsi, [rip + eac3_final_params]
    lea rdi, [rip + ac3_params]
    mov ecx, offset AC3_PARAMS_WORDS
    rep movsq
    mov eax, 1
    jmp .Leac3_blocks_return
.Leac3_blocks_unsupported:
    mov dword ptr [rip + decode_error], AC3_UNSUPPORTED
    jmp .Leac3_blocks_fail
.Leac3_blocks_bad:
    mov dword ptr [rip + decode_error], AC3_MALFORMED
.Leac3_blocks_fail:
    xor eax, eax
.Leac3_blocks_return:
    mov qword ptr [rip + eac3_spx_reserved_ptr], 0
    mov qword ptr [rip + eac3_spx_reserved_end], 0
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN eac3_decode_blocks
