# Original x86-64 CELT signed-pulse enumeration. Algorithm: RFC6716 cwrs.c.
# General small-footprint recurrence, unsigned 32-bit arithmetic throughout.
# Reference license and algorithm attribution: THIRD_PARTY_NOTICES.
.include "lamp.inc"
.bss
op_cwrs_workspace: .zero 32769*4
.text
# RCX=row, EDX=length, R8D=initial -> next row, in place.
LOCALFN op_cwrs_next
    mov r9d, 1
.Lop_cwrs_next_loop:
    mov eax, [rcx + r9*4]
    add eax, [rcx + r9*4 - 4]
    add eax, r8d
    mov [rcx + r9*4 - 4], r8d
    mov r8d, eax
    inc r9d
    cmp r9d, edx
    jb .Lop_cwrs_next_loop
    mov [rcx + r9*4 - 4], r8d
    ret
ENDFN op_cwrs_next

# ECX=N>=2, EDX=K>=1, R8=row[K+2] -> EAX=V(N,K).
# Caller ensures the unsigned enumeration fits in 32 bits.
FN op_cwrs_urow
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov ebx, ecx
    mov esi, edx
    mov rdi, r8
    mov dword ptr [rdi], 0
    mov dword ptr [rdi + 4], 1
    mov ecx, 2
    lea edx, [rsi + 2]
.Lop_cwrs_init:
    lea eax, [rcx + rcx - 1]
    mov [rdi + rcx*4], eax
    inc ecx
    cmp ecx, edx
    jb .Lop_cwrs_init
    sub ebx, 2
    jle .Lop_cwrs_count
.Lop_cwrs_build:
    lea rcx, [rdi + 4]
    lea edx, [rsi + 1]
    mov r8d, 1
    call op_cwrs_next
    dec ebx
    jnz .Lop_cwrs_build
.Lop_cwrs_count:
    mov eax, [rdi + rsi*4]
    add eax, [rdi + rsi*4 + 4]
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_cwrs_urow

# ECX=N, EDX=K, R8D=index, R9=output[N], [rsp+40]=row[K+2].
# Destructively consumes the row; output has sum(abs(pulse)) exactly K.
FN op_cwrs_decode
    push rbx
    push rsi
    push rdi
    push r12
    mov ebx, ecx
    mov esi, edx
    mov edi, r8d
    mov r12, [rsp + 72]
.Lop_cwrs_coordinate:
    mov eax, [r12 + rsi*4 + 4]
    xor edx, edx
    cmp edi, eax
    jb .Lop_cwrs_positive
    mov edx, -1
    sub edi, eax
.Lop_cwrs_positive:
    mov r8d, esi
    mov eax, [r12 + rsi*4]
.Lop_cwrs_search:
    cmp eax, edi
    jbe .Lop_cwrs_found
    dec esi
    mov eax, [r12 + rsi*4]
    jmp .Lop_cwrs_search
.Lop_cwrs_found:
    sub edi, eax
    sub r8d, esi
    add r8d, edx
    xor r8d, edx
    mov [r9], r8d
    add r9, 4
    # U(N-1,k) = U(N,k)-U(N,k-1)-U(N-1,k-1).
    lea ecx, [rsi + 2]
    xor edx, edx
    mov r8d, 1
.Lop_cwrs_previous:
    mov eax, [r12 + r8*4]
    sub eax, [r12 + r8*4 - 4]
    sub eax, edx
    mov [r12 + r8*4 - 4], edx
    mov edx, eax
    inc r8d
    cmp r8d, ecx
    jb .Lop_cwrs_previous
    mov [r12 + r8*4 - 4], edx
    dec ebx
    jnz .Lop_cwrs_coordinate
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_cwrs_decode

# RCX=output, EDX=N>=2, R8D=K, R9=range context -> EAX=1/0.
# Scratch is single-instance, like the rest of the decoder; no per-frame heap.
FN op_decode_pulses
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 56
    mov rbx, rcx
    mov esi, edx
    mov edi, r8d
    mov r12, r9
    cmp esi, 2
    jb .Lop_pulses_bad
    cmp esi, 1024
    ja .Lop_pulses_bad
    cmp edi, 1
    jb .Lop_pulses_bad
    cmp edi, 32767
    ja .Lop_pulses_bad
    mov ecx, esi
    mov edx, edi
    lea r8, [rip + op_cwrs_workspace]
    call op_cwrs_urow
    test eax, eax
    jz .Lop_pulses_bad
    mov edx, eax
    mov rcx, r12
    call op_ec_uint
    mov r8d, eax
    mov ecx, esi
    mov edx, edi
    mov r9, rbx
    lea rax, [rip + op_cwrs_workspace]
    mov [rsp + 32], rax
    call op_cwrs_decode
    mov eax, 1
    jmp .Lop_pulses_done
.Lop_pulses_bad:
    xor eax, eax
.Lop_pulses_done:
    add rsp, 56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_decode_pulses
