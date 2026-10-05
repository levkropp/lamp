# Handwritten x86-64 Opus range decoder. Reference: RFC6716 entdec.c/entcode.c.
# Algorithm attribution and RFC BSD notice: see THIRD_PARTY_NOTICES.
.include "lamp.inc"
.equ EC_BUF, 0
.equ EC_SIZE, 8
.equ EC_END, 12
.equ EC_WINDOW, 16
.equ EC_NEND, 20
.equ EC_TOTAL, 24
.equ EC_OFF, 28
.equ EC_RNG, 32
.equ EC_VAL, 36
.equ EC_EXT, 40
.equ EC_REM, 44
.equ EC_ERROR, 48
.text
# RCX=context. End-of-frame zero padding is normative, not a bounds failure.
LOCALFN op_ec_normalize
    mov r8d, [rcx + EC_RNG]
    test r8d, r8d
    jz .Lop_ec_zero_range
    mov r9d, [rcx + EC_VAL]
.Lop_ec_normalize_loop:
    cmp r8d, 0x800000
    ja .Lop_ec_normalize_done
    add dword ptr [rcx + EC_TOTAL], 8
    shl r8d, 8
    mov eax, [rcx + EC_REM]
    shl eax, 8
    mov edx, [rcx + EC_OFF]
    cmp edx, [rcx + EC_SIZE]
    jae .Lop_ec_padding
    push rax
    mov rax, [rcx + EC_BUF]
    movzx edx, byte ptr [rax + rdx]
    pop rax
    inc dword ptr [rcx + EC_OFF]
    jmp .Lop_ec_symbol
.Lop_ec_padding:
    xor edx, edx
.Lop_ec_symbol:
    mov [rcx + EC_REM], edx
    or eax, edx
    shr eax, 1
    not eax
    and eax, 255
    shl r9d, 8
    add r9d, eax
    and r9d, 0x7fffffff
    jmp .Lop_ec_normalize_loop
.Lop_ec_normalize_done:
    mov [rcx + EC_RNG], r8d
    mov [rcx + EC_VAL], r9d
    ret
.Lop_ec_zero_range:
    mov dword ptr [rcx + EC_ERROR], 1
    ret
ENDFN op_ec_normalize

# RCX=context (64 bytes), RDX=frame bytes, R8D=byte length.
FN op_ec_init
    mov [rcx + EC_BUF], rdx
    mov [rcx + EC_SIZE], r8d
    mov qword ptr [rcx + EC_END], 0
    mov dword ptr [rcx + EC_NEND], 0
    mov dword ptr [rcx + EC_TOTAL], 9
    mov dword ptr [rcx + EC_OFF], 0
    mov dword ptr [rcx + EC_RNG], 128
    mov dword ptr [rcx + EC_ERROR], 0
    mov dword ptr [rcx + EC_EXT], 0
    xor eax, eax
    test r8d, r8d
    jz .Lop_ec_init_empty
    movzx eax, byte ptr [rdx]
    mov dword ptr [rcx + EC_OFF], 1
.Lop_ec_init_empty:
    mov [rcx + EC_REM], eax
    shr eax, 1
    mov edx, 127
    sub edx, eax
    mov [rcx + EC_VAL], edx
    jmp op_ec_normalize
ENDFN op_ec_init

# RCX=context, EDX=total frequency -> EAX=cumulative frequency.
FN op_ec_decode
    mov r8d, edx
    test edx, edx
    jz .Lop_ec_decode_bad
    mov eax, [rcx + EC_RNG]
    xor edx, edx
    div r8d
    test eax, eax
    jz .Lop_ec_decode_bad
    mov [rcx + EC_EXT], eax
    mov r9d, eax
    mov eax, [rcx + EC_VAL]
    xor edx, edx
    div r9d
    inc eax
    cmp eax, r8d
    cmova eax, r8d
    sub r8d, eax
    mov eax, r8d
    ret
.Lop_ec_decode_bad:
    mov dword ptr [rcx + EC_ERROR], 1
    xor eax, eax
    ret
ENDFN op_ec_decode
FN op_ec_bin
    push rcx
    mov ecx, edx
    mov edx, 1
    shl edx, cl
    pop rcx
    jmp op_ec_decode
ENDFN op_ec_bin

# RCX=context, EDX=fl, R8D=fh, R9D=ft. Uses ext from op_ec_decode.
FN op_ec_update
    mov eax, r9d
    sub eax, r8d
    imul eax, [rcx + EC_EXT]
    sub [rcx + EC_VAL], eax
    test edx, edx
    jz .Lop_ec_update_zero
    sub r8d, edx
    imul r8d, [rcx + EC_EXT]
    mov [rcx + EC_RNG], r8d
    jmp op_ec_normalize
.Lop_ec_update_zero:
    sub [rcx + EC_RNG], eax
    jmp op_ec_normalize
ENDFN op_ec_update

# RCX=context, EDX=log2 reciprocal probability of one -> EAX=bit.
FN op_ec_logp
    sub rsp, 40
    mov r8d, [rcx + EC_RNG]
    mov r9d, [rcx + EC_VAL]
    push rcx
    mov ecx, edx
    mov eax, r8d
    shr eax, cl
    pop rcx
    xor r10d, r10d
    cmp r9d, eax
    setb r10b
    test r10d, r10d
    jnz .Lop_ec_logp_one
    sub r9d, eax
    sub r8d, eax
    jmp .Lop_ec_logp_store
.Lop_ec_logp_one:
    mov r8d, eax
.Lop_ec_logp_store:
    mov [rcx + EC_VAL], r9d
    mov [rcx + EC_RNG], r8d
    call op_ec_normalize
    mov eax, r10d
    add rsp, 40
    ret
ENDFN op_ec_logp

# RCX=context, RDX=ICDF bytes ending in zero, R8D=probability precision.
FN op_ec_icdf
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, rcx
    mov rbx, rdx
    mov eax, [rsi + EC_RNG]
    mov r11d, eax
    mov ecx, r8d
    shr eax, cl
    mov r8d, eax
    mov r9d, [rsi + EC_VAL]
    xor r10d, r10d
.Lop_ec_icdf_symbol:
    movzx eax, byte ptr [rbx + r10]
    imul eax, r8d
    cmp r9d, eax
    jae .Lop_ec_icdf_found
    mov r11d, eax
    inc r10d
    cmp r10d, 256
    jb .Lop_ec_icdf_symbol
    mov dword ptr [rsi + EC_ERROR], 1
    xor r10d, r10d
    jmp .Lop_ec_icdf_return
.Lop_ec_icdf_found:
    sub r9d, eax
    sub r11d, eax
    mov [rsi + EC_VAL], r9d
    mov [rsi + EC_RNG], r11d
    mov rcx, rsi
    call op_ec_normalize
.Lop_ec_icdf_return:
    mov eax, r10d
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN op_ec_icdf

# RCX=context, EDX=0..25 raw bits, read backwards LSB first.
FN op_ec_bits
    push rbx
    push rsi
    mov rsi, rcx
    mov ebx, edx
    mov r8d, [rsi + EC_WINDOW]
    mov r9d, [rsi + EC_NEND]
    cmp r9d, ebx
    jae .Lop_ec_bits_extract
.Lop_ec_bits_load:
    mov eax, [rsi + EC_END]
    cmp eax, [rsi + EC_SIZE]
    jae .Lop_ec_bits_padding
    inc eax
    mov [rsi + EC_END], eax
    mov edx, [rsi + EC_SIZE]
    sub edx, eax
    mov rax, [rsi + EC_BUF]
    movzx eax, byte ptr [rax + rdx]
    jmp .Lop_ec_bits_insert
.Lop_ec_bits_padding:
    xor eax, eax
.Lop_ec_bits_insert:
    mov ecx, r9d
    shl eax, cl
    or r8d, eax
    add r9d, 8
    cmp r9d, 24
    jbe .Lop_ec_bits_load
.Lop_ec_bits_extract:
    mov ecx, ebx
    mov eax, 1
    shl eax, cl
    dec eax
    and eax, r8d
    shr r8d, cl
    sub r9d, ebx
    mov [rsi + EC_WINDOW], r8d
    mov [rsi + EC_NEND], r9d
    add [rsi + EC_TOTAL], ebx
    pop rsi
    pop rbx
    ret
ENDFN op_ec_bits

# RCX=context, EDX=ft>1. Uniform integer up to 2^32-1 values.
FN op_ec_uint
    push rbx
    push rsi
    push r12
    sub rsp, 48
    mov rsi, rcx
    mov ebx, edx
    dec ebx
    bsr r12d, ebx
    inc r12d
    cmp r12d, 8
    jbe .Lop_ec_uint_small
    sub r12d, 8
    mov eax, ebx
    mov ecx, r12d
    shr eax, cl
    inc eax
    mov [rsp + 32], eax
    mov edx, eax
    jmp .Lop_ec_uint_decode
.Lop_ec_uint_small:
    mov dword ptr [rsp + 32], edx
    xor r12d, r12d
.Lop_ec_uint_decode:
    mov rcx, rsi
    call op_ec_decode
    mov [rsp + 36], eax
    mov edx, eax
    lea r8d, [eax + 1]
    mov r9d, [rsp + 32]
    mov rcx, rsi
    call op_ec_update
    mov eax, [rsp + 36]
    test r12d, r12d
    jz .Lop_ec_uint_done
    mov ecx, r12d
    shl eax, cl
    mov [rsp + 36], eax
    mov rcx, rsi
    mov edx, r12d
    call op_ec_bits
    or eax, [rsp + 36]
    cmp eax, ebx
    jbe .Lop_ec_uint_done
    mov eax, ebx
    mov dword ptr [rsi + EC_ERROR], 1
.Lop_ec_uint_done:
    add rsp, 48
    pop r12
    pop rsi
    pop rbx
    ret
ENDFN op_ec_uint

FN op_ec_tell
    mov eax, [rcx + EC_RNG]
    bsr edx, eax
    inc edx
    mov eax, [rcx + EC_TOTAL]
    sub eax, edx
    ret
ENDFN op_ec_tell
FN op_ec_frac
    mov r8d, [rcx + EC_TOTAL]
    shl r8d, 3
    mov eax, [rcx + EC_RNG]
    bsr edx, eax
    inc edx
    mov ecx, edx
    sub ecx, 16
    shr eax, cl
    mov r9d, 3
.Lop_ec_frac_bit:
    imul eax, eax
    shr eax, 15
    mov ecx, eax
    shr ecx, 16
    shl edx, 1
    or edx, ecx
    shr eax, cl
    dec r9d
    jnz .Lop_ec_frac_bit
    mov eax, r8d
    sub eax, edx
    ret
ENDFN op_ec_frac
