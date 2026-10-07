# ATSC A/52:2018 Annex E adaptive hybrid transform mantissas.
# Numeric facts are extracted from the pinned standard, not decoder sources.
# Six blocks are unpacked together in block zero; later blocks reuse the cache.
RODATA
.include "eac3_aht_tables.inc"
.text

# ECX=channel. Channel/bin/block cache has a 24-byte stride per bin.
LOCALFN eac3_aht_mantissas
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96
    mov ebx, ecx
    mov eax, ebx
    shl eax, 8
    lea r12, [rip + ac3_bap]
    add r12, rax
    lea r13, [rip + ac3_dexps]
    add r13, rax
    imul eax, eax, 24
    lea r14, [rip + eac3_aht_pre]
    add r14, rax
    AC3_SLOT rax, ac3_end, rbx
    mov r15d, [rax]
    cmp dword ptr [rip + eac3_current_block], 0
    jne .Laht_output
    mov ecx, 2
    call ac3_get
    mov [rsp + 32], eax                 # gaqmod
    mov ecx, 12
    cmp eax, 2
    jb .Laht_gain_limit
    mov ecx, 17
.Laht_gain_limit:
    mov [rsp + 36], ecx
    mov dword ptr [rsp + 40], 0         # gain count/index
    mov dword ptr [rsp + 72], 0         # spare gains in ternary group
    test eax, eax
    jz .Laht_unpack_start
    AC3_SLOT rax, ac3_start, rbx
    mov esi, [rax]
.Laht_gain_bin:
    cmp esi, r15d
    jae .Laht_unpack_start
    movzx eax, byte ptr [r12 + rsi]
    cmp eax, 8
    jb .Laht_gain_next
    cmp eax, [rsp + 36]
    jae .Laht_gain_next
    cmp dword ptr [rsp + 32], 3
    je .Laht_gain_group
    mov ecx, 1
    call ac3_get
    mov ecx, [rsp + 32]
    dec ecx
    shl eax, cl
    lea rdx, [rip + eac3_aht_gains]
    mov ecx, [rsp + 40]
    mov [rdx + rcx], al
    inc dword ptr [rsp + 40]
    jmp .Laht_gain_next
.Laht_gain_group:
    cmp dword ptr [rsp + 72], 0
    jne .Laht_gain_spare
    mov ecx, 5
    call ac3_get
    cmp eax, 26                         # reserved codes conceal as group 26
    jbe .Laht_gain_valid
    mov eax, 26
.Laht_gain_valid:
    xor edx, edx
    mov ecx, 9
    div ecx
    lea r8, [rip + eac3_aht_gains]
    mov ecx, [rsp + 40]
    mov [r8 + rcx], al
    mov eax, edx
    xor edx, edx
    mov r9d, 3
    div r9d
    mov [r8 + rcx + 1], al
    mov [r8 + rcx + 2], dl
    add dword ptr [rsp + 40], 3
    mov dword ptr [rsp + 72], 3
.Laht_gain_spare:
    dec dword ptr [rsp + 72]
.Laht_gain_next:
    inc esi
    jmp .Laht_gain_bin
.Laht_unpack_start:
    mov dword ptr [rsp + 40], 0
    AC3_SLOT rax, ac3_start, rbx
    mov esi, [rax]
.Laht_unpack_bin:
    cmp esi, r15d
    jae .Laht_output
    imul edi, esi, 24
    add rdi, r14
    movzx eax, byte ptr [r12 + rsi]
    mov [rsp + 64], eax                 # hebap
    lea rdx, [rip + eac3_aht_bits]
    movzx ecx, byte ptr [rdx + rax]
    mov [rsp + 48], ecx
    test eax, eax
    jz .Laht_dither
    cmp eax, 8
    jae .Laht_scalar
    call ac3_get
    imul eax, eax, 12
    lea rdx, [rip + eac3_aht_vq_offsets]
    mov ecx, [rsp + 64]
    add eax, [rdx + rcx*4]
    lea r8, [rip + eac3_aht_vq]
    add r8, rax
    xor ecx, ecx
.Laht_vector_value:
    movsx eax, word ptr [r8 + rcx*2]
    shl eax, 8
    mov [rdi + rcx*4], eax
    inc ecx
    cmp ecx, 6
    jb .Laht_vector_value
    jmp .Laht_inverse
.Laht_dither:
    mov dword ptr [rsp + 56], 0
.Laht_dither_value:
    call eac3_spx_random
    and eax, 0x7fffff
    sub eax, 0x400000
    mov ecx, [rsp + 56]
    mov [rdi + rcx*4], eax
    inc dword ptr [rsp + 56]
    cmp dword ptr [rsp + 56], 6
    jb .Laht_dither_value
    jmp .Laht_inverse
.Laht_scalar:
    xor edx, edx
    cmp dword ptr [rsp + 32], 0
    je .Laht_scalar_gain
    cmp eax, [rsp + 36]
    jae .Laht_scalar_gain
    lea rdx, [rip + eac3_aht_gains]
    mov ecx, [rsp + 40]
    movzx edx, byte ptr [rdx + rcx]
    inc dword ptr [rsp + 40]
.Laht_scalar_gain:
    mov [rsp + 52], edx
    mov eax, [rsp + 48]
    sub eax, edx
    mov [rsp + 60], eax                 # small mantissa width
    mov dword ptr [rsp + 56], 0
.Laht_scalar_value:
    mov ecx, [rsp + 60]
    call ac3_get
    mov ecx, 32
    sub ecx, [rsp + 60]
    shl eax, cl
    sar eax, cl                        # signed small mantissa
    cmp dword ptr [rsp + 52], 0
    je .Laht_small
    mov ecx, [rsp + 60]
    dec ecx
    mov edx, -1
    shl edx, cl
    cmp eax, edx
    jne .Laht_small
    mov ecx, [rsp + 48]
    sub ecx, 2
    add ecx, [rsp + 52]
    mov [rsp + 68], ecx                # large mantissa width
    call ac3_get
    mov ecx, 32
    sub ecx, [rsp + 68]
    shl eax, cl
    sar eax, 8                         # signed large mantissa, Q24-bits
    movsxd r8, eax
    mov eax, [rsp + 64]
    sub eax, 8
    imul eax, eax, 10
    lea r10, [rip + eac3_aht_remap]
    add r10, rax
    mov ecx, [rsp + 52]
    test r8d, r8d
    js .Laht_negative_bias
    mov r9d, 1
    mov edx, 23
    sub edx, ecx
    mov ecx, edx
    shl r9d, cl
    jmp .Laht_large_remap
.Laht_negative_bias:
    movsx r9d, word ptr [r10 + rcx*2 + 4]
    shl r9d, 8
.Laht_large_remap:
    mov ecx, [rsp + 52]
    movsx rax, word ptr [r10 + rcx*2]
    imul rax, r8
    sar rax, 15
    add eax, r8d
    add eax, r9d
    jmp .Laht_scalar_store
.Laht_small:
    mov ecx, 24
    sub ecx, [rsp + 48]
    shl eax, cl
    cmp dword ptr [rsp + 52], 0
    jne .Laht_scalar_store
    movsxd r8, eax
    mov eax, [rsp + 64]
    sub eax, 8
    imul eax, eax, 10
    lea r10, [rip + eac3_aht_remap]
    movsx rax, word ptr [r10 + rax]
    imul rax, r8
    sar rax, 15
    add eax, r8d
.Laht_scalar_store:
    mov ecx, [rsp + 56]
    mov [rdi + rcx*4], eax
    inc dword ptr [rsp + 56]
    cmp dword ptr [rsp + 56], 6
    jb .Laht_scalar_value
.Laht_inverse:
    mov rcx, rdi
    call eac3_aht_idct6
    inc esi
    jmp .Laht_unpack_bin
.Laht_output:
    AC3_SLOT rax, ac3_start, rbx
    mov esi, [rax]
    shl ebx, 10
    lea rdi, [rip + ac3_fixed]
    add rdi, rbx
    mov ebx, [rip + eac3_current_block]
.Laht_output_bin:
    cmp esi, r15d
    jae .Laht_return
    imul eax, esi, 24
    lea rdx, [r14 + rax]
    mov eax, [rdx + rbx*4]
    movzx ecx, byte ptr [r13 + rsi]
    sar eax, cl
    mov [rdi + rsi*4], eax
    inc esi
    jmp .Laht_output_bin
.Laht_return:
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN eac3_aht_mantissas

# RCX points at six Q23 pre-mantissas. A symmetric six-point inverse cosine
# transform, with each product rounded down before sums (Annex E 3.4.5).
LOCALFN eac3_aht_idct6
    push rbx
    push rsi
    push rdi
    mov r10, rcx
    mov r8d, [r10]
    movsxd rax, dword ptr [r10 + 16]
    imul rax, rax, EAC3_AHT_COS1
    sar rax, 23
    mov r9d, r8d
    sub r9d, eax                       # even centre
    sar eax, 1
    lea r11d, [r8 + rax]               # even side
    movsxd rax, dword ptr [r10 + 8]
    imul rax, rax, EAC3_AHT_COS0
    sar rax, 23
    mov r8d, r11d
    sub r8d, eax                       # even far
    add r11d, eax                      # even near
    mov eax, [r10 + 4]
    add eax, [r10 + 20]
    cdqe
    imul rax, rax, EAC3_AHT_COS2
    sar rax, 23
    mov edx, eax
    add edx, [r10 + 4]
    add edx, [r10 + 12]                # odd near
    add eax, [r10 + 20]
    sub eax, [r10 + 12]                # odd far
    mov ecx, [r10 + 4]
    sub ecx, [r10 + 12]
    sub ecx, [r10 + 20]                # odd centre
    mov ebx, r11d
    sub ebx, edx
    add r11d, edx
    mov esi, r9d
    sub esi, ecx
    add r9d, ecx
    mov edi, r8d
    sub edi, eax
    add r8d, eax
    mov [r10], r11d
    mov [r10 + 4], r9d
    mov [r10 + 8], r8d
    mov [r10 + 12], edi
    mov [r10 + 16], esi
    mov [r10 + 20], ebx
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN eac3_aht_idct6
