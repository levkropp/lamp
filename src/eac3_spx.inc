# Spectral extension, ATSC A/52:2018 Annex E 3.6. Handwritten bounded
# parser and float coefficient synthesis; numeric facts in eac3_tables.inc.
RODATA
.p2align 2
eac3_spx_three: .float 3.0
eac3_spx_blend_scale: .float 0.03125
eac3_spx_coord_scale: .float 1.1920928955078125e-7
eac3_spx_noise_scale: .float -4.656612873077392578125e-10
.text

# ECX=block -> EAX=0 success, 1 invalid ranges. Preserve nonvolatile state.
LOCALFN eac3_spx_parse
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov ebx, ecx
    test ebx, ebx
    jz .Lspx_strategy
    mov ecx, 1
    call ac3_get
    test eax, eax
    jz .Lspx_coords
.Lspx_strategy:
    mov ecx, 1
    call ac3_get
    mov [rip + eac3_spx_active], eax
    test eax, eax
    jz .Lspx_disable
    mov esi, 1
.Lspx_channels:
    mov eax, 1
    cmp dword ptr [rip + ac3_acmod], 1
    je .Lspx_channel_store
    mov ecx, 1
    call ac3_get
.Lspx_channel_store:
    AC3_SLOT rcx, eac3_spx_ch, rsi
    mov [rcx], eax
    inc esi
    cmp esi, [rip + ac3_nf]
    jbe .Lspx_channels
    mov ecx, 2
    call ac3_get
    imul eax, eax, 12
    add eax, 25
    mov [rip + eac3_spx_copy], eax
    mov ecx, 3
    call ac3_get
    lea r12d, [rax + 2]
    cmp r12d, 7
    jbe .Lspx_begin
    lea r12d, [r12 + r12 - 7]
.Lspx_begin:
    mov ecx, 3
    call ac3_get
    lea r13d, [rax + 5]
    cmp r13d, 7
    jbe .Lspx_end
    lea r13d, [r13 + r13 - 7]
.Lspx_end:
    cmp r12d, r13d
    jae .Lspx_invalid
    imul eax, r12d, 12
    add eax, 25
    cmp eax, [rip + eac3_spx_copy]
    jbe .Lspx_invalid
    mov [rip + eac3_spx_start], eax
    imul eax, r13d, 12
    add eax, 25
    mov [rip + eac3_spx_end], eax
    mov ecx, 1
    call ac3_get
    test eax, eax
    jz .Lspx_bands
    lea esi, [r12 + 1]
.Lspx_struct:
    cmp esi, r13d
    jae .Lspx_bands
    mov ecx, 1
    call ac3_get
    lea rcx, [rip + eac3_spx_struct]
    mov [rcx + rsi], al
    inc esi
    jmp .Lspx_struct
.Lspx_bands:
    xor edi, edi
    lea r14, [rip + eac3_spx_sizes]
    mov dword ptr [r14], 12
    lea esi, [r12 + 1]
.Lspx_band:
    cmp esi, r13d
    jae .Lspx_band_count
    lea rax, [rip + eac3_spx_struct]
    cmp byte ptr [rax + rsi], 0
    jne .Lspx_band_join
    inc edi
    mov dword ptr [r14 + rdi*4], 0
.Lspx_band_join:
    add dword ptr [r14 + rdi*4], 12
    inc esi
    jmp .Lspx_band
.Lspx_band_count:
    inc edi
    mov [rip + eac3_spx_count], edi
.Lspx_coords:
    mov esi, 1
.Lspx_coord_channel:
    cmp esi, [rip + ac3_nf]
    ja .Lspx_success
    AC3_SLOT rcx, eac3_spx_ch, rsi
    cmp dword ptr [rcx], 0
    je .Lspx_coord_reset
    AC3_SLOT rcx, eac3_spx_first, rsi
    cmp dword ptr [rcx], 0
    jne .Lspx_coord_read
    mov ecx, 1
    call ac3_get
    test eax, eax
    jz .Lspx_coord_next
.Lspx_coord_read:
    AC3_SLOT rcx, eac3_spx_first, rsi
    mov dword ptr [rcx], 0
    mov ecx, 5
    call ac3_get
    cvtsi2ss xmm0, eax
    mulss xmm0, [rip + eac3_spx_blend_scale]
    movss [rsp + 32], xmm0
    mov ecx, 2
    call ac3_get
    lea r15d, [rax + rax*2]              # master coordinate exponent
    mov r12d, [rip + eac3_spx_start]
    imul r13d, esi, 17
    xor edi, edi
.Lspx_coord_band:
    cmp edi, [rip + eac3_spx_count]
    jae .Lspx_coord_next
    AC3_SLOT rax, eac3_spx_sizes, rdi
    mov r14d, [rax]
    mov eax, r14d
    shr eax, 1
    add eax, r12d
    cvtsi2ss xmm0, eax
    cvtsi2ss xmm1, dword ptr [rip + eac3_spx_end]
    divss xmm0, xmm1
    subss xmm0, [rsp + 32]
    xorps xmm1, xmm1
    maxss xmm0, xmm1
    minss xmm0, [rip + ac3_one]
    movss xmm1, [rip + ac3_one]
    subss xmm1, xmm0
    sqrtss xmm1, xmm1                    # signal blend
    mulss xmm0, [rip + eac3_spx_three]
    sqrtss xmm0, xmm0                    # noise blend
    mov ecx, 4
    call ac3_get
    mov ebx, eax
    mov ecx, 2
    call ac3_get
    cmp ebx, 15
    je .Lspx_coord_denormal
    add eax, 4
    jmp .Lspx_coord_scale
.Lspx_coord_denormal:
    shl eax, 1
.Lspx_coord_scale:
    mov ecx, 25
    sub ecx, ebx
    sub ecx, r15d
    shl eax, cl
    cvtsi2ss xmm2, eax
    mulss xmm2, [rip + eac3_spx_coord_scale]
    mulss xmm0, xmm2
    mulss xmm1, xmm2
    lea eax, [r13 + rdi]
    AC3_SLOT rcx, eac3_spx_noise, rax
    movss [rcx], xmm0
    AC3_SLOT rcx, eac3_spx_signal, rax
    movss [rcx], xmm1
    add r12d, r14d
    inc edi
    jmp .Lspx_coord_band
.Lspx_coord_reset:
    AC3_SLOT rcx, eac3_spx_first, rsi
    mov dword ptr [rcx], 1
.Lspx_coord_next:
    inc esi
    jmp .Lspx_coord_channel
.Lspx_disable:
    lea rcx, [rip + eac3_spx_ch]
    xorps xmm0, xmm0
    movups [rcx], xmm0
    movups [rcx + 16], xmm0
    jmp .Lspx_coords
.Lspx_invalid:
    mov eax, 1
    jmp .Lspx_return
.Lspx_success:
    xor eax, eax
.Lspx_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN eac3_spx_parse

# Full signed 32-bit LFG word, shared with ordinary mantissa dithering.
LOCALFN eac3_random
    mov ecx, [rip + ac3_lfg_index]
    lea r8d, [rcx - 24]
    and r8d, 63
    lea r9d, [rcx - 55]
    and r9d, 63
    lea r10, [rip + ac3_lfg]
    mov eax, [r10 + r8*4]
    add eax, [r10 + r9*4]
    mov edx, ecx
    and edx, 63
    mov [r10 + rdx*4], eax
    inc ecx
    mov [rip + ac3_lfg_index], ecx
    ret
ENDFN eac3_random

# Rendering uses noise reserved at this block's original LFG position.
# Ordinary/AHT dithering never consumes the reserved SPX row.
LOCALFN eac3_spx_random
    mov rdx, [rip + eac3_spx_reserved_ptr]
    test rdx, rdx
    jz eac3_random
    xor eax, eax
    cmp rdx, [rip + eac3_spx_reserved_end]
    jae .Leac3_reserved_step
    mov eax, [rdx]
.Leac3_reserved_step:
    add rdx, 4
    mov [rip + eac3_spx_reserved_ptr], rdx
    ret
ENDFN eac3_spx_random

# ECX=selected FBW channel. Synthesize in ac3_coef before its IMDCT.
# At most 180 extension bins and 15 bands; source [copy,start) is immutable
# during translation. RMS precedes the five-bin boundary filters.
LOCALFN eac3_spx_apply
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov ebx, ecx
    lea rsi, [rip + ac3_coef]
    mov r12d, [rip + eac3_spx_copy]
    mov r13d, [rip + eac3_spx_start]
    xor edi, edi
.Lspx_copy_band:
    AC3_SLOT rax, eac3_spx_sizes, rdi
    mov r14d, [rax]
    xor r15d, r15d
    lea eax, [r12 + r14]
    cmp eax, [rip + eac3_spx_start]
    jbe .Lspx_copy_boundary
    mov r12d, [rip + eac3_spx_copy]
    mov r15d, 1
.Lspx_copy_boundary:
    test edi, edi
    jnz .Lspx_copy_wrap_store
    mov r15d, 1
.Lspx_copy_wrap_store:
    AC3_SLOT rax, eac3_spx_wrap, rdi
    mov [rax], r15d
    xorps xmm1, xmm1
.Lspx_copy_bin:
    cmp r12d, [rip + eac3_spx_start]
    jne .Lspx_copy_value
    mov r12d, [rip + eac3_spx_copy]
.Lspx_copy_value:
    movss xmm0, [rsi + r12*4]
    movss [rsi + r13*4], xmm0
    mulss xmm0, xmm0
    addss xmm1, xmm0
    inc r12d
    inc r13d
    dec r14d
    jnz .Lspx_copy_bin
    AC3_SLOT rax, eac3_spx_sizes, rdi
    cvtsi2ss xmm0, dword ptr [rax]
    divss xmm1, xmm0
    sqrtss xmm1, xmm1
    AC3_SLOT rax, eac3_spx_rms, rdi
    movss [rax], xmm1
    inc edi
    cmp edi, [rip + eac3_spx_count]
    jb .Lspx_copy_band
    AC3_SLOT rax, eac3_spx_atten_code, rbx
    mov eax, [rax]
    test eax, eax
    js .Lspx_blend
    imul eax, eax, 12
    lea r12, [rip + eac3_spx_atten]
    add r12, rax
    mov r13d, [rip + eac3_spx_start]
    sub r13d, 2
    xor edi, edi
.Lspx_atten_band:
    AC3_SLOT rax, eac3_spx_wrap, rdi
    cmp dword ptr [rax], 0
    je .Lspx_atten_next
    movss xmm0, [r12]
    movss xmm1, [r12 + 4]
    movss xmm2, [r12 + 8]
    movss xmm3, [rsi + r13*4]
    mulss xmm3, xmm0
    movss [rsi + r13*4], xmm3
    movss xmm3, [rsi + r13*4 + 4]
    mulss xmm3, xmm1
    movss [rsi + r13*4 + 4], xmm3
    movss xmm3, [rsi + r13*4 + 8]
    mulss xmm3, xmm2
    movss [rsi + r13*4 + 8], xmm3
    movss xmm3, [rsi + r13*4 + 12]
    mulss xmm3, xmm1
    movss [rsi + r13*4 + 12], xmm3
    movss xmm3, [rsi + r13*4 + 16]
    mulss xmm3, xmm0
    movss [rsi + r13*4 + 16], xmm3
.Lspx_atten_next:
    AC3_SLOT rax, eac3_spx_sizes, rdi
    add r13d, [rax]
    inc edi
    cmp edi, [rip + eac3_spx_count]
    jb .Lspx_atten_band
.Lspx_blend:
    imul ebx, ebx, 17
    mov r13d, [rip + eac3_spx_start]
    xor edi, edi
.Lspx_blend_band:
    lea eax, [rbx + rdi]
    AC3_SLOT rcx, eac3_spx_noise, rax
    movss xmm4, [rcx]
    AC3_SLOT rcx, eac3_spx_signal, rax
    movss xmm5, [rcx]
    AC3_SLOT rax, eac3_spx_rms, rdi
    mulss xmm4, [rax]
    mulss xmm4, [rip + eac3_spx_noise_scale]
    AC3_SLOT rax, eac3_spx_sizes, rdi
    mov r14d, [rax]
.Lspx_blend_bin:
    call eac3_spx_random
    cvtsi2ss xmm0, eax
    mulss xmm0, xmm4
    movss xmm1, [rsi + r13*4]
    mulss xmm1, xmm5
    addss xmm1, xmm0
    movss [rsi + r13*4], xmm1
    inc r13d
    dec r14d
    jnz .Lspx_blend_bin
    inc edi
    cmp edi, [rip + eac3_spx_count]
    jb .Lspx_blend_band
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN eac3_spx_apply
